import AVFoundation

/// Thin wrapper around AVAssetExportSession with progress polling.
enum Exporter {

    static func exportVideo(composition: AVComposition,
                           videoComposition: AVVideoComposition?,
                           audioMix: AVAudioMix?,
                           to url: URL,
                           progress: @escaping (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw AppError.exportFailed("Could not create export session")
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        try await run(session: session, progress: progress)
    }

    static func exportAudio(composition: AVComposition,
                           audioMix: AVAudioMix?,
                           to url: URL,
                           progress: @escaping (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw AppError.exportFailed("Could not create export session")
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.audioMix = audioMix
        try await run(session: session, progress: progress)
    }

    private static func run(session: AVAssetExportSession,
                            progress: @escaping (Double) -> Void) async throws {
        if FileManager.default.fileExists(atPath: session.outputURL?.path ?? "") {
            try? FileManager.default.removeItem(at: session.outputURL!)
        }
        session.exportAsynchronously {}
        while session.status == .unknown || session.status == .waiting || session.status == .exporting {
            progress(Double(session.progress))
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        progress(1.0)
        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw AppError.cancelled
        case .failed:
            throw AppError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        default:
            throw AppError.exportFailed("unexpected status \(session.status.rawValue)")
        }
    }
}
