import AVFoundation

@main enum SpectrumTests {
    static func main() {
        let analyzer = SpectrumAnalyzer()!
        for rate in [44100.0, 48000.0] {
            for hz in [167.0, 1060.0, 8000.0] {
                let tone = (0..<SpectrumAnalyzer.size).map { Float(0.01 * sin(Double($0) * hz * 2 * .pi / rate)) }
                let levels = analyzer.levels(channels: [tone], sampleRate: rate)
                let peak = levels.max()!, band = levels.firstIndex(of: peak)!
                let low = 62.5 * pow(256, Double(band) / 48)
                let high = 62.5 * pow(256, Double(band + 1) / 48)
                precondition(hz >= low - rate / 8192 && hz <= high + rate / 8192, "Frequency must land in its real band")
                let db = Double(peak) / 255 * 72 - 90
                precondition(abs(db + 53.6) < 2, "A 0.01 amplitude sine reads -53.6 dB, as in a Web Audio analyser")
                precondition(analyzer.levels(channels: [tone, tone.map { -$0 }], sampleRate: rate) == levels,
                             "Anti-phase stereo must not cancel the spectrum")
            }
        }
        precondition(analyzer.levels(channels: [Array(repeating: 0, count: 8192)], sampleRate: 48000).allSatisfy { $0 == 0 })
        precondition(analyzer.levels(channels: [[Float.nan]], sampleRate: .nan).isEmpty)
        // Loud music must leave headroom: a full-scale sine stays below the top of the plot's range.
        let loud: [Float] = (0..<SpectrumAnalyzer.size).map { (index: Int) -> Float in Float(sin(Double(index) * 1060.0 * 2.0 * Double.pi / 48000.0)) }
        let top = analyzer.levels(channels: [loud], sampleRate: 48000).max()!
        let quieter: [Int] = SpectrumAnalyzer.bytes([Float(0.1)])
        precondition(top == 255, "A full-scale tone reaches the top")
        precondition(quieter[0] < 255, "Only near full-scale tones reach the top")
        // Frames blend like the website's analyser (0.68), and a reset starts from an empty plot.
        var eased = analyzer.smoothed([Float](repeating: 1, count: 48))
        precondition(abs(eased[0] - 0.32) < 0.001)
        eased = analyzer.smoothed([Float](repeating: 1, count: 48))
        precondition(abs(eased[0] - 0.5376) < 0.001)
        analyzer.reset()
        precondition(abs(analyzer.smoothed([Float](repeating: 1, count: 48))[0] - 0.32) < 0.001)

        // The tap's planar and interleaved PCM formats must both preserve channel samples.
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
            pcm.frameLength = 8192
            let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            let tone: [Float] = (0..<8192).map { (index: Int) -> Float in Float(0.01 * sin(Double(index) * 1060.0 * 2.0 * Double.pi / 48000.0)) }
            for index in 0..<8192 {
                if interleaved {
                    let data = buffers[0].mData!.assumingMemoryBound(to: Float.self)
                    data[index * 2] = tone[index]; data[index * 2 + 1] = -tone[index]
                } else {
                    buffers[0].mData!.assumingMemoryBound(to: Float.self)[index] = tone[index]
                    buffers[1].mData!.assumingMemoryBound(to: Float.self)[index] = -tone[index]
                }
            }
            let capture = NativeSpectrumCapture()
            capture.prepare(format.streamDescription.pointee)
            let range = CMTimeRange(start: .zero, duration: CMTime(value: 8192, timescale: 48000))
            // Without a foreground request, the callback does not retain samples.
            capture.receive(pcm.mutableAudioBufferList, frames: 8192, range: range)
            precondition(capture.snapshot(at: range.duration.seconds) == nil)
            capture.receive(pcm.mutableAudioBufferList, frames: 8192, range: range)
            let snapshot = capture.snapshot(at: range.duration.seconds)!
            precondition(snapshot.channels[0] == tone && snapshot.channels[1] == tone.map { -$0 })
            precondition(capture.snapshot(at: 42) == nil, "Samples from before a seek must not be displayed")
            // The tap runs ahead of the speakers. A later, different block must not replace
            // the samples at the playhead, however far ahead the tap has got.
            let later = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
            later.frameLength = 8192
            for buffer in UnsafeMutableAudioBufferListPointer(later.mutableAudioBufferList) {
                memset(buffer.mData!, 0, Int(buffer.mDataByteSize))
            }
            var end = range.end
            for _ in 0..<3 {
                let next = CMTimeRange(start: end, duration: range.duration)
                capture.receive(later.mutableAudioBufferList, frames: 8192, range: next)
                end = next.end
                let playhead = capture.snapshot(at: range.duration.seconds)!
                precondition(playhead.channels[0] == tone, "The plot follows the playhead, not the tap")
            }
            precondition(capture.snapshot(at: end.seconds)!.channels[0].allSatisfy { $0 == 0 })
            // Audio from another position restarts the ring even if no reset arrived.
            capture.receive(pcm.mutableAudioBufferList, frames: 4096, range: CMTimeRange(start: CMTime(seconds: 90, preferredTimescale: 48000), duration: CMTime(value: 4096, timescale: 48000)))
            precondition(capture.snapshot(at: 90) == nil, "A partial window after a jump is not displayed")
            capture.reset()
            precondition(capture.snapshot(at: range.duration.seconds) == nil)
            precondition(capture.tap() != nil, "A pass-through audio tap can be created")
        }
        print("Spectrum frequency, level, headroom, smoothing, silence, stereo, PCM layout, playhead sync, seek freshness and reset checks passed.")
    }
}
