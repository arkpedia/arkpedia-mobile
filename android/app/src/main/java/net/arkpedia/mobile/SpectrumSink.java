package net.arkpedia.mobile;

import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;

/**
 * Passes every call to the player's real audio output and lets the visualizer read a copy
 * of the decoded PCM. It needs no microphone permission and never alters playback.
 */
@androidx.annotation.OptIn(markerClass = androidx.media3.common.util.UnstableApi.class)
final class SpectrumSink extends ForwardingAudioSink {
    private final SpectrumCapture capture;
    private long lastUs = Long.MIN_VALUE;

    SpectrumSink(AudioSink sink, SpectrumCapture capture) { super(sink); this.capture = capture; }

    @Override public void configure(Format inputFormat, int specifiedBufferSize, @Nullable int[] outputChannels) throws ConfigurationException {
        boolean pcm = MimeTypes.AUDIO_RAW.equals(inputFormat.sampleMimeType);
        int bytes = !pcm ? 0 : inputFormat.pcmEncoding == C.ENCODING_PCM_16BIT ? 2 : inputFormat.pcmEncoding == C.ENCODING_PCM_FLOAT ? 4 : 0;
        capture.prepare(inputFormat.sampleRate, inputFormat.channelCount, bytes);
        lastUs = Long.MIN_VALUE;
        super.configure(inputFormat, specifiedBufferSize, outputChannels);
    }
    @Override public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount) throws InitializationException, WriteException {
        // The player offers a buffer again until the output has room for all of it: copy it once.
        if (presentationTimeUs != lastUs) {
            lastUs = presentationTimeUs;
            capture.write(buffer, presentationTimeUs, System.nanoTime());
        }
        return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
    }
    @Override public long getCurrentPositionUs(boolean sourceEnded) {
        long position = super.getCurrentPositionUs(sourceEnded);
        capture.playhead(position, System.nanoTime());
        return position;
    }
    @Override public void flush() { lastUs = Long.MIN_VALUE; capture.reset(); super.flush(); }
    @Override public void reset() { lastUs = Long.MIN_VALUE; capture.reset(); super.reset(); }
}
