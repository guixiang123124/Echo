import Foundation

/// Computes audio signal levels from raw PCM data
public enum AudioLevelCalculator {
    /// Compute RMS level from an audio chunk, normalized to 0.0-1.0
    public static func rmsLevel(from chunk: AudioChunk) -> CGFloat {
        rmsLevel(from: chunk.data)
    }

    /// Compute RMS level from raw PCM Int16 data, normalized to 0.0-1.0
    public static func rmsLevel(from data: Data) -> CGFloat {
        let sampleSize = MemoryLayout<Int16>.size
        guard data.count >= sampleSize else { return 0 }

        let sampleCount = data.count / sampleSize
        guard sampleCount > 0 else { return 0 }

        let sumOfSquares: Double = data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var sum: Double = 0
            for i in 0..<sampleCount {
                let sample = Double(samples[i])
                sum += sample * sample
            }
            return sum
        }

        let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
        // Int16 max is 32767; normalize against a practical ceiling (~8000)
        // to get responsive visual feedback even at moderate volumes
        let normalized = min(rms / 8000.0, 1.0)
        return CGFloat(normalized)
    }

    /// Compute peak level from raw PCM Int16 data, normalized to 0.0-1.0
    public static func peakLevel(from data: Data) -> CGFloat {
        let sampleSize = MemoryLayout<Int16>.size
        guard data.count >= sampleSize else { return 0 }

        let sampleCount = data.count / sampleSize
        guard sampleCount > 0 else { return 0 }

        let maxAmplitude: Int16 = data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var peak: Int16 = 0
            for i in 0..<sampleCount {
                let abs = samples[i] == Int16.min ? Int16.max : Swift.abs(samples[i])
                if abs > peak { peak = abs }
            }
            return peak
        }

        return CGFloat(Double(maxAmplitude) / Double(Int16.max))
    }
}
