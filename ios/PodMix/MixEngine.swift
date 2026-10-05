import AVFoundation

/// Mixes an MP3 music bed under a voice source (the stitched MP4 or any
/// picked video). Voice stays at full volume; the music gets the volume
/// slider level, fade in/out, and optional auto-ducking driven by a
/// loudness envelope measured off the voice track.
enum MixEngine {

    struct Mixed {
        let composition: AVMutableComposition
        let videoComposition: AVVideoComposition?
        let audioMix: AVAudioMix
        let duration: CMTime
        /// True when the voice had no video and a branded title card was synthesized.
        let isTitleCard: Bool
    }

    struct VolumeRamp {
        let from: Float
        let to: Float
        let range: CMTimeRange
    }

    /// Builds the mix. Raw system errors are wrapped with the stage they
    /// failed in — a bare `Foundation._GenericObjCError error 0` tells you
    /// nothing unless you know whether it was the voice read, the music
    /// read, or the composition step.
    static func build(voiceURL: URL, musicURL: URL, settings: MixSettings) async throws -> Mixed {
        var stage = "starting"
        do {
            return try await buildInner(voiceURL: voiceURL, musicURL: musicURL, settings: settings, stage: &stage)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.exportFailed("Mix failed (\(stage)): \(error.localizedDescription)")
        }
    }

    private static func buildInner(voiceURL: URL, musicURL: URL, settings: MixSettings, stage: inout String) async throws -> Mixed {
        // Optional: normalize the voice track first (Mike's podcast preset).
        stage = "leveling voice"
        var voiceSource = voiceURL
        if let preset = settings.voiceLevel.preset {
            let result = try await LoudnessEngine.normalizedFile(from: voiceURL, preset: preset)
            voiceSource = result.url
        }

        stage = "loading voice tracks"
        let voiceAsset = AVURLAsset(url: voiceSource)
        let voiceAudioTracks = try await voiceAsset.loadTracks(withMediaType: .audio)
        guard let voiceAudio = voiceAudioTracks.first else { throw AppError.noAudioTrack }
        let duration = try await voiceAsset.load(.duration)
        guard CMTimeGetSeconds(duration) > 0.1 else { throw AppError.fileError("Voice source has no duration") }

        stage = "building composition"
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid),
              let voiceTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let musicTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError.exportFailed("Could not create composition tracks")
        }

        let fullRange = CMTimeRange(start: .zero, duration: duration)

        // Video passes straight through — or, for an audio-only voice,
        // a branded title card is synthesized so the MP4 export always
        // has video to write (a video preset on an empty video track
        // fails the export with "Operation Stopped").
        stage = "preparing video"
        let voiceVideoTracks = try await voiceAsset.loadTracks(withMediaType: .video)
        let videoAsset: AVURLAsset
        let isTitleCard: Bool
        if voiceVideoTracks.isEmpty {
            stage = "rendering title card"
            let cardURL = try await TitleCard.makeVideo(duration: duration,
                                                       title: TitleCard.prettyTitle(for: voiceURL))
            videoAsset = AVURLAsset(url: cardURL)
            isTitleCard = true
        } else {
            videoAsset = voiceAsset
            isTitleCard = false
        }
        var appliedTransform: CGAffineTransform?
        var appliedSize = CGSize.zero
        if let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first {
            try videoTrack.insertTimeRange(fullRange, of: sourceVideo, at: .zero)
            appliedTransform = try await sourceVideo.load(.preferredTransform)
            appliedSize = try await sourceVideo.load(.naturalSize)
        }

        // Voice at full volume.
        try voiceTrack.insertTimeRange(fullRange, of: voiceAudio, at: .zero)

        // Music looped (or trimmed) to the voice duration.
        stage = "loading music"
        let musicAsset = AVURLAsset(url: musicURL)
        let musicAudioTracks = try await musicAsset.loadTracks(withMediaType: .audio)
        guard let musicAudio = musicAudioTracks.first else { throw AppError.noAudioTrack }
        let musicDuration = try await musicAsset.load(.duration)
        var cursor = CMTime.zero
        while cursor < duration {
            let remaining = CMTimeSubtract(duration, cursor)
            let take = CMTimeMinimum(musicDuration, remaining)
            try musicTrack.insertTimeRange(CMTimeRange(start: .zero, duration: take), of: musicAudio, at: cursor)
            cursor = CMTimeAdd(cursor, take)
        }

        // Audio mix: voice flat, music follows the envelope.
        stage = "building music envelope"
        let mix = AVMutableAudioMix()
        let voiceParams = AVMutableAudioMixInputParameters(track: voiceTrack)
        voiceParams.setVolume(1.0, at: .zero)
        let musicParams = AVMutableAudioMixInputParameters(track: musicTrack)
        let ramps = try await musicEnvelope(voiceURL: voiceSource, duration: duration, settings: settings)
        for ramp in ramps {
            musicParams.setVolumeRamp(fromStartVolume: ramp.from, toEndVolume: ramp.to, timeRange: ramp.range)
        }
        mix.inputParameters = [voiceParams, musicParams]

        // Keep the source orientation.
        var videoComposition: AVMutableVideoComposition?
        if let transform = appliedTransform {
            let vc = AVMutableVideoComposition()
            let transformed = appliedSize.applying(transform)
            vc.renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = fullRange
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layer]
            vc.instructions = [instruction]
            videoComposition = vc
        }

        return Mixed(composition: composition,
                     videoComposition: videoComposition,
                     audioMix: mix,
                     duration: duration,
                     isTitleCard: isTitleCard)
    }

    /// Piecewise-linear music volume curve: base level with ease-in/out
    /// fades, dipped wherever the voice is loud (best-effort ducking).
    static func musicEnvelope(voiceURL: URL, duration: CMTime, settings: MixSettings) async throws -> [VolumeRamp] {
        let totalSeconds = CMTimeGetSeconds(duration)
        let step = 0.1
        let count = max(1, Int((totalSeconds / step).rounded(.up)))
        var targets = [Float](repeating: Float(settings.musicVolume), count: count)

        // Fades (quadratic ease).
        let fadeInSteps = min(count, Int((settings.fadeIn / step).rounded()))
        if fadeInSteps > 1 {
            for i in 0..<fadeInSteps {
                let f = Float(i) / Float(fadeInSteps)
                targets[i] = min(targets[i], Float(settings.musicVolume) * f * f)
            }
        }
        let fadeOutSteps = min(count, Int((settings.fadeOut / step).rounded()))
        if fadeOutSteps > 1 {
            for i in 0..<fadeOutSteps {
                let f = Float(i) / Float(fadeOutSteps)
                let idx = count - 1 - i
                targets[idx] = min(targets[idx], Float(settings.musicVolume) * f * f)
            }
        }

        // Ducking: dip the bed where the voice RMS clears −35 dBFS.
        if settings.duckingEnabled {
            let (left, right) = try await AudioIO.readStereoFloat(url: voiceURL)
            let n = min(left.count, right.count)
            let windowSamples = Int(48000 * step)
            let dip = Float(settings.musicVolume * 0.3)
            var active = [Bool](repeating: false, count: count)
            for i in 0..<count {
                let start = i * windowSamples
                let end = min(start + windowSamples, n)
                guard end > start else { continue }
                var sum = 0.0
                for j in start..<end {
                    let m = (Double(left[j]) + Double(right[j])) * 0.5
                    sum += m * m
                }
                let db = 20 * log10(sqrt(sum / Double(end - start)) + 1e-9)
                active[i] = db > -35
            }
            // 300 ms hangover so the bed doesn't pump on pauses.
            var extended = active
            for i in 0..<count where active[i] {
                for k in 1...3 where i + k < count { extended[i + k] = true }
            }
            for i in 0..<count where extended[i] {
                targets[i] = min(targets[i], dip)
            }
        }

        // Continuous ramps (each segment ends where the next begins).
        var ramps = [VolumeRamp]()
        for i in 0..<count {
            let next = (i + 1 < count) ? targets[i + 1] : targets[i]
            let range = CMTimeRange(
                start: CMTime(seconds: Double(i) * step, preferredTimescale: 600),
                duration: CMTime(seconds: step, preferredTimescale: 600))
            ramps.append(VolumeRamp(from: targets[i], to: next, range: range))
        }
        return ramps
    }
}
