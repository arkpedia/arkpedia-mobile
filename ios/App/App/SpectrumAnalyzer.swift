import Accelerate
import Foundation

/// Peak levels in the same 48 logarithmic bands, on the same scale and with the same
/// smoothing as the website's Web Audio analyser. Never touches playback.
final class SpectrumAnalyzer {
    static let size = 8192
    static let bands = 48
    /// AnalyserNode.smoothingTimeConstant on the website, applied once per drawn frame.
    static let smoothing: Float = 0.68
    private var previous = [Float](repeating: 0, count: bands)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: size)
    private var input = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)

    init?() {
        guard let setup = vDSP_create_fftsetup(13, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        vDSP_blkman_window(&window, vDSP_Length(Self.size), 0)
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func levels(channels: [[Float]], sampleRate: Double) -> [Int] {
        Self.bytes(amplitudes(channels: channels, sampleRate: sampleRate))
    }
    /// Blend with the previous frame like the website's analyser; `reset` starts a new plot.
    func smoothed(_ amplitudes: [Float]) -> [Float] {
        guard amplitudes.count == Self.bands else { return amplitudes }
        for band in 0..<Self.bands {
            previous[band] = Self.smoothing * previous[band] + (1 - Self.smoothing) * amplitudes[band]
        }
        return previous
    }
    func reset() { previous = [Float](repeating: 0, count: Self.bands) }
    static func bytes(_ amplitudes: [Float]) -> [Int] {
        amplitudes.map { amplitude in
            let db = 20 * log10(max(amplitude, 0.000001))
            return Int((min(1, max(0, (db + 90) / 72)) * 255).rounded())
        }
    }
    func amplitudes(channels: [[Float]], sampleRate: Double) -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0 else { return [] }
        let binHz = sampleRate / Double(Self.size)
        let edges = (0...Self.bands).map {
            min(Self.size / 2, Int(ceil(62.5 * pow(256, Double($0) / Double(Self.bands)) / binHz)))
        }
        var peaks = [Float](repeating: 0, count: Self.bands)
        // Analyse stereo channels separately: anti-phase stereo must not cancel a visible signal.
        for channel in channels.prefix(2) where channel.count == Self.size {
            vDSP_vmul(channel, 1, window, 1, &input, 1, vDSP_Length(Self.size))
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    input.withUnsafeBufferPointer { values in
                        values.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, 13, FFTDirection(FFT_FORWARD))
                    // vDSP's real FFT is doubled. Web Audio divides the transform by its
                    // size and does not undo the Blackman window, so a full-scale sine
                    // reads 0.21 (-13.6 dB): the website's bar heights exactly.
                    for band in 0..<Self.bands {
                        for bin in max(1, edges[band])..<max(1, edges[band + 1]) {
                            let amplitude = hypot(r[bin], i[bin]) / Float(2 * Self.size)
                            if amplitude.isFinite { peaks[band] = max(peaks[band], amplitude) }
                        }
                    }
                }
            }
        }
        return peaks
    }
}
