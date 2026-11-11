import Accelerate
import Foundation

/// Peak levels in the same 48 logarithmic bands as the website. Never touches playback.
final class SpectrumAnalyzer {
    static let size = 8192
    static let bands = 48
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: size)
    private var input = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var windowSum: Float = 1

    init?() {
        guard let setup = vDSP_create_fftsetup(13, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        vDSP_blkman_window(&window, vDSP_Length(Self.size), 0)
        vDSP_sve(window, 1, &windowSum, vDSP_Length(Self.size))
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func levels(channels: [[Float]], sampleRate: Double) -> [Int] {
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
                    // vDSP's real FFT is doubled. Dividing by the window sum gives
                    // a full-scale bin-centred sine an amplitude of 1 (0 dBFS).
                    for band in 0..<Self.bands {
                        for bin in max(1, edges[band])..<max(1, edges[band + 1]) {
                            let amplitude = hypot(r[bin], i[bin]) / windowSum
                            if amplitude.isFinite { peaks[band] = max(peaks[band], amplitude) }
                        }
                    }
                }
            }
        }
        return peaks.map { amplitude in
            let db = 20 * log10(max(amplitude, 0.000001))
            return Int((min(1, max(0, (db + 90) / 72)) * 255).rounded())
        }
    }
}
