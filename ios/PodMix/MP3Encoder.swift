import Foundation

/// WAV (or any audio) → MP3 via the vendored LAME 3.100 encoder.
/// iOS ships no MP3 encoder, hence LAME. See vendor/lame/README-LAME.md
/// for the LGPL licensing note.
enum MP3Encoder {

    /// Encodes `inputURL` to MP3 at `outputURL` using CBR `bitrateKbps`.
    /// Input is resampled to 44.1 kHz stereo, the MP3-native format.
    /// `phase` reports which stage we're in ("Reading audio…"/"Encoding MP3…")
    /// so a stall is localizable from the UI.
    static func encode(inputURL: URL, outputURL: URL, bitrateKbps: Int,
                       phase: @escaping (String) -> Void = { _ in },
                       progress: @escaping (Double) -> Void) async throws {
        phase("Reading audio…")
        let (leftF, rightF) = try await AudioIO.readStereoFloat(url: inputURL, targetSampleRate: 44100)
        let frames = min(leftF.count, rightF.count)
        guard frames > 0 else { throw AppError.lameFailed("No audio samples in \(inputURL.lastPathComponent)") }

        phase("Encoding MP3…")
        var interleaved = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let l = Int((Double(leftF[i]) * 32767.0).rounded())
            let r = Int((Double(rightF[i]) * 32767.0).rounded())
            interleaved[i * 2] = Int16(clamping: l)
            interleaved[i * 2 + 1] = Int16(clamping: r)
        }

        guard let gfp = lame_init() else { throw AppError.lameFailed("lame_init returned nil") }
        defer { lame_close(gfp) }
        lame_set_in_samplerate(gfp, 44100)
        lame_set_num_channels(gfp, 2)
        lame_set_brate(gfp, Int32(bitrateKbps))
        lame_set_quality(gfp, 2) // high quality, still fast
        guard lame_init_params(gfp) >= 0 else { throw AppError.lameFailed("lame_init_params failed") }

        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputURL.path) else {
            throw AppError.lameFailed("Could not create \(outputURL.lastPathComponent)")
        }
        defer { try? handle.close() }

        let chunkFrames = 8192
        var mp3buf = [UInt8](repeating: 0, count: Int(1.25 * Double(chunkFrames)) + 7200)
        var done = 0
        while done < frames {
            let count = min(chunkFrames, frames - done)
            let base = done * 2
            let written: Int32 = interleaved.withUnsafeBufferPointer { pcmBuf in
                mp3buf.withUnsafeMutableBufferPointer { mp3 in
                    lame_encode_buffer_interleaved(
                        gfp,
                        UnsafeMutablePointer(mutating: pcmBuf.baseAddress! + base),
                        Int32(count),
                        mp3.baseAddress!,
                        Int32(mp3.count))
                }
            }
            if written < 0 { throw AppError.lameFailed("encode error \(written)") }
            if written > 0 { try handle.write(contentsOf: Data(mp3buf[0..<Int(written)])) }
            done += count
            progress(Double(done) / Double(frames) * 0.95)
        }
        let flushed: Int32 = mp3buf.withUnsafeMutableBufferPointer { mp3 in
            lame_encode_flush(gfp, mp3.baseAddress!, Int32(mp3.count))
        }
        if flushed < 0 { throw AppError.lameFailed("flush error \(flushed)") }
        if flushed > 0 { try handle.write(contentsOf: Data(mp3buf[0..<Int(flushed)])) }
        progress(1.0)
    }
}
