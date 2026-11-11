import AVFoundation
import MediaToolbox

/// A pass-through AVPlayer tap. Copy PCM only while the foreground visualizer
/// requests it; never allocate, run an FFT, or wait for a lock on the audio thread.
final class NativeSpectrumCapture {
    private let lock = NSLock()
    private var left = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var right = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var position = 0, filled = 0, channels = 0
    private var format = AudioStreamBasicDescription()
    private var requested: TimeInterval = -.infinity
    private var updated: TimeInterval = -.infinity
    private var endTime = Double.nan

    func reset() {
        lock.lock(); defer { lock.unlock() }
        filled = 0; position = 0; updated = -.infinity
    }
    func prepare(_ format: AudioStreamBasicDescription) {
        lock.lock(); defer { lock.unlock() }
        self.format = format
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let int16 = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && format.mBitsPerChannel == 16
        channels = format.mFormatID == kAudioFormatLinearPCM && (float || int16)
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 ? min(2, Int(format.mChannelsPerFrame)) : 0
        filled = 0; position = 0; updated = -.infinity
    }
    func receive(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, range: CMTimeRange) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard channels > 0, now - requested < 0.5 else { filled = 0; return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bytes = float ? 4 : 2
        // The first two channels can be interleaved in one buffer or planar in two.
        for frame in 0..<frames {
            var channel = 0
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let stride = Int(buffer.mNumberChannels)
                for offset in 0..<stride where channel < channels {
                    let index = frame * stride + offset
                    guard (index + 1) * bytes <= Int(buffer.mDataByteSize) else { continue }
                    let value = float ? data.assumingMemoryBound(to: Float.self)[index]
                        : Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                    if channel == 0 { left[position] = value } else { right[position] = value }
                    channel += 1
                }
                if channel >= channels { break }
            }
            guard channel == channels else { filled = 0; return }
            position = (position + 1) % SpectrumAnalyzer.size
            filled = min(SpectrumAnalyzer.size, filled + 1)
        }
        updated = now
        endTime = CMTimeRangeGetEnd(range).seconds
    }
    func snapshot(at seconds: Double) -> (channels: [[Float]], sampleRate: Double)? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        requested = now
        guard filled == SpectrumAnalyzer.size, now - updated < 0.5,
              !endTime.isFinite || abs(endTime - seconds) < 0.5 else { return nil }
        func ordered(_ ring: [Float]) -> [Float] { Array(ring[position...]) + Array(ring[..<position]) }
        return (channels == 2 ? [ordered(left), ordered(right)] : [ordered(left)], format.mSampleRate)
    }

    func tap() -> MTAudioProcessingTap? {
        let retained = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<NativeSpectrumCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<NativeSpectrumCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            }, unprepare: { tap in
                Unmanaged<NativeSpectrumCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().reset()
            }, process: { tap, frames, _, buffers, outputFrames, flags in
                var range = CMTimeRange.invalid
                // Always return the original audio untouched, including when analysis is idle.
                let result = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &range, outputFrames)
                guard result == noErr else { outputFrames.pointee = 0; return }
                Unmanaged<NativeSpectrumCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .receive(buffers, frames: Int(outputFrames.pointee), range: range)
            })
        var tap: Unmanaged<MTAudioProcessingTap>?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
            retained.release(); return nil
        }
        return tap?.takeRetainedValue()
    }
}
