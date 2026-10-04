import AVFoundation

/// Audio file reading/writing helpers. Everything is normalized to
/// 48 kHz stereo float for processing; callers pick their own rate.
enum AudioIO {

    /// Reads any audio file (or the audio track of a video) as stereo float.
    ///
    /// Two paths:
    /// - Fast path: the file is already stereo at the target rate — read
    ///   straight from disk with no converter involved.
    /// - Converter path: AVAudioConverter for anything else, with a stall
    ///   guard. The converter's input block can report "no data now"
    ///   indefinitely; without the guard the `while true` loop below would
    ///   spin forever showing "Converting…" and never failing. That exact
    ///   hang bit PodMix v1.0.0's WAV→MP3 on real hardware.
    static func readStereoFloat(url: URL, targetSampleRate: Double = 48000) throws -> (left: [Float], right: [Float]) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AppError.fileError("Could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }

        let src = file.processingFormat
        if src.sampleRate == targetSampleRate && src.channelCount == 2 &&
            (src.commonFormat == .pcmFormatFloat32 || src.commonFormat == .pcmFormatInt16) {
            return try readDirect(file: file)
        }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: targetSampleRate,
                                        channels: 2,
                                        interleaved: false) else {
            throw AppError.fileError("Could not make target format")
        }
        guard let converter = AVAudioConverter(from: src, to: target) else {
            throw AppError.fileError("Could not make sample-rate converter")
        }

        var left = [Float]()
        var right = [Float]()
        let estimate = Int(Double(file.length) * targetSampleRate / max(1, src.sampleRate)) + 1024
        left.reserveCapacity(estimate)
        right.reserveCapacity(estimate)

        // A read failure inside the block can't throw (the block isn't
        // throwing), so capture it and rethrow after convert() returns.
        // Signalling endOfStream here guarantees the loop below terminates.
        var inputError: Error?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputError != nil {
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 4096) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: buf)
            } catch {
                inputError = error
                outStatus.pointee = .endOfStream
                return nil
            }
            if buf.frameLength == 0 {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return buf
        }

        var emptyRuns = 0
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
                throw AppError.fileError("Could not make output buffer")
            }
            var convertError: NSError?
            let status = converter.convert(to: outBuf, error: &convertError, withInputFrom: inputBlock)
            if let e = inputError {
                throw AppError.fileError("Read failed: \(e.localizedDescription)")
            }
            if status == .error {
                throw AppError.fileError(convertError?.localizedDescription ?? "Conversion failed")
            }
            let frames = Int(outBuf.frameLength)
            if frames > 0 {
                emptyRuns = 0
                if let channels = outBuf.floatChannelData {
                    left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
                    right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
                }
            } else if status == .haveData {
                // The converter asked for more input but produced nothing.
                // A few of these are normal (priming); hundreds means stuck.
                emptyRuns += 1
                if emptyRuns > 500 {
                    throw AppError.fileError("Converter stalled after 500 empty pulls — the input may be unreadable")
                }
            }
            if status == .endOfStream { break }
        }
        return (left, right)
    }

    /// Direct disk read for files already in the target layout
    /// (stereo, target rate, float32 or int16). No converter, no stalls.
    private static func readDirect(file: AVAudioFile) throws -> (left: [Float], right: [Float]) {
        let fmt = file.processingFormat
        var left = [Float]()
        var right = [Float]()
        let estimate = Int(file.length) + 1024
        left.reserveCapacity(estimate)
        right.reserveCapacity(estimate)
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8192) else {
                throw AppError.fileError("Could not make read buffer")
            }
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            if fmt.commonFormat == .pcmFormatFloat32, let ch = buf.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                right.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: n))
            } else if fmt.commonFormat == .pcmFormatInt16, let ch = buf.int16ChannelData {
                let s = Float(1.0 / 32768.0)
                for i in 0..<n {
                    left.append(Float(ch[0][i]) * s)
                    right.append(Float(ch[1][i]) * s)
                }
            } else {
                throw AppError.fileError("Unsupported direct-read format")
            }
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
