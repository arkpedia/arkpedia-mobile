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
                precondition(abs(db + 40) < 2, "A 0.01 amplitude sine should measure approximately -40 dBFS")
                precondition(analyzer.levels(channels: [tone, tone.map { -$0 }], sampleRate: rate) == levels,
                             "Anti-phase stereo must not cancel the spectrum")
            }
        }
        precondition(analyzer.levels(channels: [Array(repeating: 0, count: 8192)], sampleRate: 48000).allSatisfy { $0 == 0 })
        precondition(analyzer.levels(channels: [[Float.nan]], sampleRate: .nan).isEmpty)

        // The tap's planar and interleaved PCM formats must both preserve channel samples.
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
            pcm.frameLength = 8192
            let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            let tone = (0..<8192).map { Float(0.01 * sin(Double($0) * 1060 * 2 * .pi / 48000)) }
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
            capture.reset()
            precondition(capture.snapshot(at: range.duration.seconds) == nil)
            precondition(capture.tap() != nil, "A pass-through audio tap can be created")
        }
        print("Spectrum frequency, dBFS, silence, stereo, PCM layout, seek freshness and reset checks passed.")
    }
}
