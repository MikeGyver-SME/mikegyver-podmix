import AVFoundation
import UIKit

/// Branded title-card video for audio-only voices.
///
/// When the Music Bed's voice source has no video track (e.g. a WAV master),
/// the MP4 export would fail with "Operation Stopped" — a video preset can't
/// export a composition whose video track is empty. Instead we synthesize a
/// 1920×1080 MikeGyver Studio title card and write it as an H.264 still video
/// for the mix duration, so every mix can always export an MP4.
enum TitleCard {

    static let width = 1920
    static let height = 1080
    static let fps: Int32 = 30

    private static let navy = UIColor(red: 10 / 255, green: 31 / 255, blue: 68 / 255, alpha: 1)
    private static let gold = UIColor(red: 232 / 255, green: 182 / 255, blue: 42 / 255, alpha: 1)

    /// Renders the card and writes it as an H.264 MP4 of exactly `duration`.
    static func makeVideo(duration: CMTime, title: String) async throws -> URL {
        let image = render(title: title)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecard-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try await write(image: image, duration: duration, to: url)
        return url
    }

    /// "Prayer_and_Witnessing_Instrumental" → "Prayer and Witnessing Instrumental"
    static func prettyTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Rendering

    private static func render(title: String) -> UIImage {
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size).image { _ in
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            // Background.
            ctx.setFillColor(navy.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // Gold rules.
            ctx.setFillColor(gold.cgColor)
            ctx.fill(CGRect(x: 120, y: 96, width: size.width - 240, height: 6))
            ctx.fill(CGRect(x: 120, y: size.height - 102, width: size.width - 240, height: 6))

            let centerX = size.width / 2
            // Studio wordmark.
            let wordmark = NSAttributedString(
                string: "MIKEGYVER STUDIO",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                    .foregroundColor: gold,
                    .kern: 14
                ])
            let wSize = wordmark.size()
            wordmark.draw(at: CGPoint(x: centerX - wSize.width / 2, y: 170))

            // Episode title, wrapped.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let titleAttr = NSAttributedString(
                string: title,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 104, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ])
            let titleRect = CGRect(x: 140, y: 400, width: size.width - 280, height: 480)
            titleAttr.draw(in: titleRect)

            // Tagline.
            let tagline = NSAttributedString(
                string: "Sharing is Caring",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 52, weight: .medium),
                    .foregroundColor: gold.withAlphaComponent(0.85)
                ])
            let tSize = tagline.size()
            tagline.draw(at: CGPoint(x: centerX - tSize.width / 2, y: size.height - 230))
        }
    }

    // MARK: - Video writing

    private static func write(image: UIImage, duration: CMTime, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else {
            throw AppError.exportFailed("Could not set up title card writer")
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int64((CMTimeGetSeconds(duration) * Double(fps)).rounded(.up)))

        func fail(_ message: String) -> Error {
            AppError.exportFailed("Title card: \(message)")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "studio.mikegyver.podmix.titlecard")
            var frame: Int64 = 0
            var finished = false
            var pixelBuffer: CVPixelBuffer?
            input.requestMediaDataWhenReady(on: queue) {
                // Build the pixel buffer lazily — the pool only exists once writing starts.
                if pixelBuffer == nil {
                    guard let pool = adaptor.pixelBufferPool else {
                        if !finished { finished = true; input.markAsFinished(); writer.cancelWriting() }
                        cont.resume(throwing: fail("no pixel buffer pool"))
                        return
                    }
                    pixelBuffer = rasterize(image: image, pool: pool)
                    if pixelBuffer == nil {
                        if !finished { finished = true; input.markAsFinished(); writer.cancelWriting() }
                        cont.resume(throwing: fail("could not rasterize image"))
                        return
                    }
                }
                while input.isReadyForMoreMediaData && frame < totalFrames {
                    // Same immutable buffer every frame — a still video.
                    if !adaptor.append(pixelBuffer!, withPresentationTime: CMTime(value: frame, timescale: fps)) {
                        if !finished {
                            finished = true
                            input.markAsFinished()
                            writer.cancelWriting()
                        }
                        cont.resume(throwing: writer.error ?? fail("append failed"))
                        return
                    }
                    frame += 1
                }
                guard !finished, frame >= totalFrames else { return }
                finished = true
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume()
                    } else {
                        cont.resume(throwing: writer.error ?? fail("write failed"))
                    }
                }
            }
        }
    }

    /// Draws the UIImage into a 32ARGB pixel buffer from the adaptor's pool.
    private static func rasterize(image: UIImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb,
              let cgImage = image.cgImage else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        // Core Graphics is bottom-left origin; the pixel buffer is top-left.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}
