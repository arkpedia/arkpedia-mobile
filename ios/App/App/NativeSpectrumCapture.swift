import AVFoundation
import MediaToolbox

/// A pass-through AVPlayer tap. Copy PCM only while the foreground visualizer
/// requests it; never allocate, run an FFT, or wait for a lock on the audio thread.
/// The tap receives audio ahead of the speakers (about 0.3 s, more on some routes),
/// so the ring keeps enough history to analyse the samples at the playhead itself.
final class NativeSpectrumCapture {
    static let capacity = 65536
    private let lock = NSLock()
    private var left = [Float](repeating: 0, count: capacity)
    private var right = [Float](repeating: 0, count: capacity)
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
        // Audio that does not continue the ring (a seek the reset has not reached) restarts it.
        if endTime.isFinite, range.start.seconds.isFinite, abs(range.start.seconds - endTime) > 0.05 { filled = 0 }
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
            position = (position + 1) % Self.capacity
            filled = min(Self.capacity, filled + 1)
        }
        updated = now
        endTime = CMTimeRangeGetEnd(range).seconds
    }
    func snapshot(at seconds: Double) -> (channels: [[Float]], sampleRate: Double)? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        requested = now
        let size = SpectrumAnalyzer.size, rate = format.mSampleRate
        guard filled >= size, now - updated < 1, rate > 0 else { return nil }
        // Step back from the newest sample to the one now playing. Samples from another
        // position (before a seek) are never shown; a lead beyond the ring uses its oldest window.
        var ahead = 0
        if endTime.isFinite {
            let lead = (endTime - seconds) * rate
            guard lead.isFinite, lead > -0.25 * rate, lead < Double(Self.capacity) + 0.5 * rate else { return nil }
            ahead = min(max(0, Int(lead)), filled - size)
        }
        let start = ((position - ahead - size) % Self.capacity + Self.capacity) % Self.capacity
        func window(_ ring: [Float]) -> [Float] {
            start + size <= Self.capacity ? Array(ring[start..<start + size])
                : Array(ring[start...]) + Array(ring[..<(start + size - Self.capacity)])
        }
        return (channels == 2 ? [window(left), window(right)] : [window(left)], rate)
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
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
            retained.release(); return nil
        }
        return tap
    }
}
