import AVFoundation

/// Builds an AVMutableComposition that appends the clips' video+audio
/// tracks in order, honoring each clip's trim points.
enum StitchEngine {

    struct Stitched {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition?
        let duration: CMTime
    }

    static func build(clips: [ClipItem]) async throws -> Stitched {
        guard !clips.isEmpty else { throw AppError.noClips }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError.exportFailed("Could not create composition tracks")
        }

        var cursor = CMTime.zero
        var firstTransform: CGAffineTransform?
        var firstNaturalSize = CGSize.zero

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideo = videoTracks.first else {
                throw AppError.noVideoTrack(clip.displayName)
            }
            let duration = clip.trimmedDuration
            guard duration > 0.01 else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: clip.trimStart, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600))

            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            if firstTransform == nil {
                firstTransform = try await sourceVideo.load(.preferredTransform)
                firstNaturalSize = try await sourceVideo.load(.naturalSize)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        // Orientation: apply the first clip's transform to the whole timeline.
        // Mixed-orientation clip sets are a known v1 limit (see README).
        var videoComposition: AVMutableVideoComposition?
        if let transform = firstTransform {
            let vc = AVMutableVideoComposition()
            let transformed = firstNaturalSize.applying(transform)
            vc.renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layer]
            vc.instructions = [instruction]
            videoComposition = vc
        }

        return Stitched(composition: composition, videoComposition: videoComposition, duration: cursor)
    }
}
