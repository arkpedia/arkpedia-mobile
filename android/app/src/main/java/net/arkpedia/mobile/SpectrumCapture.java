package net.arkpedia.mobile;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * A copy of the PCM on its way to the speakers, kept only while the foreground visualizer
 * requests it. The player hands audio over well before it is heard, so the ring keeps
 * enough history to analyse the samples at the playhead itself. Mirrors the iOS capture.
 */
final class SpectrumCapture {
    static final int CAPACITY = 65536;
    private static final long NEVER = Long.MIN_VALUE, HALF_SECOND = 500_000_000L;
    private final float[] left = new float[CAPACITY], right = new float[CAPACITY];
    private int position, filled, channels, frameChannels, bytesPerSample, sampleRate;
    private long endUs = NEVER, playheadUs = NEVER, playheadNanos, requestedNanos;
    private boolean requested;

    /** bytesPerSample: 2 for 16-bit PCM, 4 for float PCM, anything else is not analysed. */
    synchronized void prepare(int sampleRate, int channelCount, int bytesPerSample) {
        boolean supported = sampleRate > 0 && channelCount > 0 && (bytesPerSample == 2 || bytesPerSample == 4);
        this.sampleRate = sampleRate; this.bytesPerSample = bytesPerSample;
        frameChannels = channelCount; channels = supported ? Math.min(2, channelCount) : 0;
        reset();
    }
    synchronized void reset() { filled = 0; position = 0; endUs = NEVER; playheadUs = NEVER; }
    synchronized int sampleRate() { return sampleRate; }

    /** Never changes the caller's buffer: playback continues from the original untouched. */
    synchronized void write(ByteBuffer pcm, long startUs, long nowNanos) {
        if (channels == 0 || !requested || nowNanos - requestedNanos > HALF_SECOND) { filled = 0; return; }
        // Audio that does not continue the ring (a seek the reset has not reached) restarts it.
        if (endUs != NEVER && Math.abs(startUs - endUs) > 50_000) filled = 0;
        ByteBuffer data = pcm.duplicate().order(ByteOrder.nativeOrder());
        int frames = data.remaining() / (bytesPerSample * frameChannels);
        for (int frame = 0; frame < frames; frame++) {
            for (int channel = 0; channel < frameChannels; channel++) {
                float value = bytesPerSample == 2 ? data.getShort() / 32768f : data.getFloat();
                if (channel == 0) left[position] = value; else if (channel == 1) right[position] = value;
            }
            position = (position + 1) % CAPACITY;
            filled = Math.min(CAPACITY, filled + 1);
        }
        endUs = startUs + frames * 1_000_000L / sampleRate;
    }
    /** The position now audible, in the same time base as write(). */
    synchronized void playhead(long positionUs, long nowNanos) { playheadUs = positionUs; playheadNanos = nowNanos; }

    /** The 8192 samples ending at the playhead, per channel, or null if they are not known. */
    synchronized float[][] snapshot(long nowNanos) {
        requested = true; requestedNanos = nowNanos;
        int size = SpectrumAnalyzer.SIZE;
        if (filled < size || endUs == NEVER || playheadUs == NEVER || nowNanos - playheadNanos > HALF_SECOND) return null;
        // Step back from the newest sample to the one now playing. Samples from another
        // position (before a seek) are never shown; a lead beyond the ring uses its oldest window.
        long audibleUs = playheadUs + (nowNanos - playheadNanos) / 1000;
        long lead = Math.round((endUs - audibleUs) * (double) sampleRate / 1_000_000);
        if (lead < -sampleRate / 4 || lead > CAPACITY + sampleRate / 2) return null;
        int ahead = (int) Math.min(Math.max(0, lead), filled - size);
        int start = Math.floorMod(position - ahead - size, CAPACITY);
        float[][] result = new float[channels][size];
        for (int i = 0; i < size; i++) {
            result[0][i] = left[(start + i) % CAPACITY];
            if (channels == 2) result[1][i] = right[(start + i) % CAPACITY];
        }
        return result;
    }
}
