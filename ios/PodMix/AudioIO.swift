import AVFoundation

/// Audio file reading/writing helpers. Everything is normalized to
/// 48 kHz stereo float for processing; callers pick their own rate.
enum AudioIO {

    /// Reads any audio file (or the audio track of a video) as stereo float
    /// at `targetSampleRate`, via AVAssetReader.
    ///
    /// v1.0.2: replaced the AVAudioFile + AVAudioConverter implementation.
    /// AVAudioFile.read(into:) throws a bare `Foundation._GenericObjCError
    /// error 0` on some of Mike's WAV masters (most likely 24-bit, a layout
    /// AVAudioPCMBuffer cannot represent), and the converter's input block
    /// could report "no data now" forever (v1.0.0's silent hang, v1.0.1's
    /// "Read failed"). AVAssetReader decodes any source format — WAV at any
    /// bit depth, MP3, AAC/M4A, MP4 audio — straight to float PCM, with none
    /// of those traps.
    static func readStereoFloat(url: URL, targetSampleRate: Double = 48000) async throws -> (left: [Float], right: [Float]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AppError.fileError("No audio track in \(url.lastPathComponent)")
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AppError.fileError("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw AppError.fileError("Could not read \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")")
        }

        var left = [Float]()
        var right = [Float]()
        if let duration = try? await asset.load(.duration),
           duration.seconds.isFinite, duration.seconds > 0 {
            let est = Int(duration.seconds * targetSampleRate) + 1024
            left.reserveCapacity(est)
            right.reserveCapacity(est)
        }

        // Interleaved float32 stereo: the block buffer is [L R L R …].
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / (2 * MemoryLayout<Float>.size)
            guard frames > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: frames * 2 * MemoryLayout<Float>.size)
            let copyStatus: OSStatus = bytes.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: ptr.count, destination: ptr.baseAddress!)
            }
            guard copyStatus == noErr else { continue }
            bytes.withUnsafeBytes { raw in
                let f = raw.bindMemory(to: Float.self)
                for i in 0..<frames {
                    left.append(f[i * 2])
                    right.append(f[i * 2 + 1])
                }
            }
        }
        if reader.status == .failed {
            throw AppError.fileError("Read failed for \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")")
        }
        if reader.status == .cancelled {
            throw AppError.cancelled
        }
        return (left, right)
    }

    /// Writes stereo float as AAC (.m4a).
    static func writeAAC(url: URL, left: [Float], right: [Float],
                        sampleRate: Double = 48000, bitrate: Int = 256000) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitrate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate,
                                        channels: 2,
                                        interleaved: false) else {
            throw AppError.fileError("Could not make write format")
        }
        let count = min(left.count, right.count)
        var offset = 0
        while offset < count {
            let chunk = min(8192, count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
                throw AppError.fileError("Could not make write buffer")
            }
            buf.frameLength = AVAudioFrameCount(chunk)
            guard let channels = buf.floatChannelData else {
                throw AppError.fileError("No channel data")
            }
            for i in 0..<chunk {
                channels[0][i] = left[offset + i]
                channels[1][i] = right[offset + i]
            }
            try file.write(from: buf)
            offset += chunk
        }
    }
}
