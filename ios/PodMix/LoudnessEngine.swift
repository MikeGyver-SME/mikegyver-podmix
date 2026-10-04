import Foundation

/// K-weighted integrated loudness (ITU-R BS.1770-style) plus a simple
/// gain + soft-clip limiter stage.
///
/// This is an honest approximation of a two-pass loudnorm: it measures
/// gated integrated loudness, applies the makeup gain, then soft-limits
/// at the true-peak ceiling. Cross-check against loudify/ffmpeg before
/// treating numbers as gospel. Analysis always runs at 48 kHz.
enum LoudnessEngine {

    // MARK: - Biquad

    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    // BS.1770-4 K-weighting, 48 kHz coefficients.
    private static let preB = [1.53512485958697, -2.69169618940638, 1.19839281085285]
    private static let preA = [1.0, -1.69065929318241, 0.73248077421585]
    private static let rlbB = [1.0, -2.0, 1.0]
    private static let rlbA = [1.0, -1.99004745483398, 0.99007225036621]

    private static func makeBiquad(b: [Double], a: [Double]) -> Biquad {
        Biquad(b0: b[0], b1: b[1], b2: b[2], a1: a[1], a2: a[2])
    }

    // MARK: - Measurement

    /// Gated integrated loudness in LUFS. Returns −70 for digital silence.
    static func integratedLoudness(left: [Float], right: [Float]) -> Double {
        let n = min(left.count, right.count)
        let blockSize = 19200       // 400 ms @ 48 kHz
        let hop = 4800              // 75% overlap
        guard n >= blockSize else { return -70 }

        var preL = makeBiquad(b: preB, a: preA)
        var rlbL = makeBiquad(b: rlbB, a: rlbA)
        var preR = makeBiquad(b: preB, a: preA)
        var rlbR = makeBiquad(b: rlbB, a: rlbA)

        var blockLoudness = [Double]()
        var start = 0
        while start + blockSize <= n {
            var zl = 0.0
            var zr = 0.0
            for i in start..<(start + blockSize) {
                let yl = rlbL.process(preL.process(Double(left[i])))
                let yr = rlbR.process(preR.process(Double(right[i])))
                zl += yl * yl
                zr += yr * yr
            }
            zl /= Double(blockSize)
            zr /= Double(blockSize)
            blockLoudness.append(-0.691 + 10 * log10(zl + zr + 1e-12))
            start += hop
        }

        let absGated = blockLoudness.filter { $0 > -70 }
        guard !absGated.isEmpty else { return -70 }
        let meanEnergy = absGated.map { pow(10, ($0 + 0.691) / 10) }.reduce(0, +) / Double(absGated.count)
        let relativeThreshold = -0.691 + 10 * log10(meanEnergy) - 10
        let relGated = absGated.filter { $0 > relativeThreshold }
        guard !relGated.isEmpty else { return -70 }
        let gatedEnergy = relGated.map { pow(10, ($0 + 0.691) / 10) }.reduce(0, +) / Double(relGated.count)
        return -0.691 + 10 * log10(gatedEnergy)
    }

    // MARK: - Normalize

    /// Applies makeup gain toward targetLUFS, then a soft-clip limiter at
    /// the ceiling. Returns the measured loudness and applied gain.
    /// True-peak is approximated on a 4x linearly-interpolated signal.
    @discardableResult
    static func normalize(left: inout [Float], right: inout [Float],
                         targetLUFS: Double, ceilingDBTP: Double) -> (measuredLUFS: Double, appliedGainDB: Double) {
        let measured = integratedLoudness(left: left, right: right)
        let clampedGain = min(24, max(-24, targetLUFS - measured))
        let gain = Float(pow(10, clampedGain / 20))
        let n = min(left.count, right.count)
        for i in 0..<n {
            left[i] *= gain
            right[i] *= gain
        }

        let ceiling = Float(pow(10, ceilingDBTP / 20))
        var peak: Float = 0
        var i = 0
        while i < n {
            let a = abs(left[i]); if a > peak { peak = a }
            let b = abs(right[i]); if b > peak { peak = b }
            if i + 1 < n {
                for k in 1..<4 {
                    let f = Float(k) / 4
                    let li = abs(left[i] + (left[i + 1] - left[i]) * f)
                    if li > peak { peak = li }
                    let ri = abs(right[i] + (right[i + 1] - right[i]) * f)
                    if ri > peak { peak = ri }
                }
            }
            i += 1
        }
        if peak > ceiling {
            // Soft knee: tanh asymptotes at the ceiling, so transients get
            // rounded off instead of hard-clipped.
            for j in 0..<n {
                left[j] = ceiling * tanh(left[j] / ceiling)
                right[j] = ceiling * tanh(right[j] / ceiling)
            }
        }
        return (measured, clampedGain)
    }

    /// Reads `url`, normalizes to `preset`, writes a temp .m4a, returns it
    /// plus the measurement for display.
    static func normalizedFile(from url: URL, preset: LevelPreset) throws -> (url: URL, measuredLUFS: Double, appliedGainDB: Double) {
        var (left, right) = try AudioIO.readStereoFloat(url: url)
        let result = normalize(left: &left, right: &right,
                               targetLUFS: preset.targetLUFS,
                               ceilingDBTP: preset.ceilingDBTP)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try AudioIO.writeAAC(url: outURL, left: left, right: right)
        return (outURL, result.measuredLUFS, result.appliedGainDB)
    }
}
