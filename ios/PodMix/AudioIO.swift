import AVFoundation

/// Audio file reading/writing helpers. Everything is normalized to
/// 48 kHz stereo float for processing; callers pick their own rate.
enum AudioIO {

    /// Reads any audio file (or the audio track of a video) as stereo float.
    static func readStereoFloat(url: URL, targetSampleRate: Double = 48000) throws -> (left: [Float], right: [Float]) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AppError.fileError("Could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: targetSampleRate,
                                        channels: 2,
                                        interleaved: false) else {
            throw AppError.fileError("Could not make target format")
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AppError.fileError("Could not make sample-rate converter")
        }

        var left = [Float]()
        var right = [Float]()
        let estimate = Int(Double(file.length) * targetSampleRate / max(1, file.processingFormat.sampleRate)) + 1024
        left.reserveCapacity(estimate)
        right.reserveCapacity(estimate)

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: buf)
            } catch {
                outStatus.pointee = .noDataNow
                return nil
            }
            if buf.frameLength == 0 {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return buf
        }

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
                throw AppError.fileError("Could not make output buffer")
            }
            var convertError: NSError?
            let status = converter.convert(to: outBuf, error: &convertError, withInputFrom: inputBlock)
            if status == .error {
                throw AppError.fileError(convertError?.localizedDescription ?? "Conversion failed")
            }
            let frames = Int(outBuf.frameLength)
            if frames > 0, let channels = outBuf.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
                right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
            }
            if status == .endOfStream { break }
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
