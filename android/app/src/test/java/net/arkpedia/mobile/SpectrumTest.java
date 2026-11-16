package net.arkpedia.mobile;

import static org.junit.Assert.*;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.Test;

/** Generated-tone checks, the same ones the iOS build runs against its analyser. */
public class SpectrumTest {
    private static final long NOW = 5_000_000_000L;

    private static float[] tone(double amplitude, double hz, double rate) {
        float[] samples = new float[SpectrumAnalyzer.SIZE];
        for (int i = 0; i < samples.length; i++) samples[i] = (float) (amplitude * Math.sin(i * hz * 2 * Math.PI / rate));
        return samples;
    }
    private static float[] negated(float[] samples) {
        float[] result = new float[samples.length];
        for (int i = 0; i < samples.length; i++) result[i] = -samples[i];
        return result;
    }

    @Test public void frequencyAndLevelMatchTheWebsiteAnalyser() {
        SpectrumAnalyzer analyzer = new SpectrumAnalyzer();
        for (int rate : new int[] { 44100, 48000 }) {
            for (double hz : new double[] { 167, 1060, 8000 }) {
                float[] tone = tone(0.01, hz, rate);
                int[] levels = analyzer.levels(new float[][] { tone }, rate);
                int band = 0;
                for (int i = 1; i < levels.length; i++) if (levels[i] > levels[band]) band = i;
                double low = 62.5 * Math.pow(256, band / 48.0), high = 62.5 * Math.pow(256, (band + 1) / 48.0);
                assertTrue("Frequency must land in its real band", hz >= low - rate / 8192.0 && hz <= high + rate / 8192.0);
                assertEquals("A 0.01 amplitude sine reads -53.6 dB, as in a Web Audio analyser", -53.6, levels[band] / 255.0 * 72 - 90, 2);
                assertArrayEquals("Anti-phase stereo must not cancel the spectrum", levels, analyzer.levels(new float[][] { tone, negated(tone) }, rate));
            }
        }
        for (int level : analyzer.levels(new float[][] { new float[SpectrumAnalyzer.SIZE] }, 48000)) assertEquals(0, level);
        for (int level : analyzer.levels(new float[][] { { Float.NaN } }, 0)) assertEquals(0, level);
        assertEquals(48, analyzer.levels(new float[][] { tone(0.01, 440, 48000) }, 48000).length);
    }

    @Test public void loudMusicKeepsHeadroomAndFramesBlend() {
        SpectrumAnalyzer analyzer = new SpectrumAnalyzer();
        int top = 0;
        for (int level : analyzer.levels(new float[][] { tone(1, 1060, 48000) }, 48000)) top = Math.max(top, level);
        assertEquals("A full-scale tone reaches the top", 255, top);
        assertTrue("Only near full-scale tones reach the top", SpectrumAnalyzer.bytes(new float[] { 0.1f })[0] < 255);
        float[] ones = new float[SpectrumAnalyzer.BANDS];
        java.util.Arrays.fill(ones, 1);
        assertEquals(0.32, analyzer.smoothed(ones)[0], 0.001);
        assertEquals(0.5376, analyzer.smoothed(ones)[0], 0.001);
        analyzer.reset();
        assertEquals(0.32, analyzer.smoothed(ones)[0], 0.001);
    }

    private static ByteBuffer pcm(float[] left, float[] right, boolean floats, int frames) {
        int channels = right == null ? 1 : 2;
        ByteBuffer buffer = ByteBuffer.allocateDirect(frames * channels * (floats ? 4 : 2)).order(ByteOrder.nativeOrder());
        for (int i = 0; i < frames; i++) {
            for (float[] channel : right == null ? new float[][] { left } : new float[][] { left, right }) {
                if (floats) buffer.putFloat(channel[i]); else buffer.putShort((short) Math.round(channel[i] * 32768));
            }
        }
        buffer.flip();
        return buffer;
    }
    private static float[] quantized(float[] samples, boolean floats) {
        float[] result = new float[samples.length];
        for (int i = 0; i < samples.length; i++) result[i] = floats ? samples[i] : (short) Math.round(samples[i] * 32768) / 32768f;
        return result;
    }

    @Test public void captureFollowsThePlayheadInEveryPcmLayout() {
        int size = SpectrumAnalyzer.SIZE;
        long block = size * 1_000_000L / 48000;
        for (boolean floats : new boolean[] { false, true }) {
            for (boolean stereo : new boolean[] { false, true }) {
                float[] tone = tone(0.01, 1060, 48000), expected = quantized(tone, floats);
                ByteBuffer audio = pcm(tone, stereo ? negated(tone) : null, floats, size);
                SpectrumCapture capture = new SpectrumCapture();
                capture.prepare(48000, stereo ? 2 : 1, floats ? 4 : 2);
                // Without a foreground request, nothing is retained.
                capture.write(audio, 0, NOW);
                capture.playhead(block, NOW);
                assertNull(capture.snapshot(NOW));
                capture.write(audio, 0, NOW);
                assertEquals("Playback keeps the original buffer untouched", 0, audio.position());
                float[][] snapshot = capture.snapshot(NOW);
                assertEquals(stereo ? 2 : 1, snapshot.length);
                assertArrayEquals(expected, snapshot[0], 0);
                if (stereo) assertArrayEquals(negated(expected), snapshot[1], 0);
                // The player hands audio over ahead of the speakers. Later, different audio
                // must not replace the samples at the playhead, however far ahead it has got.
                ByteBuffer silence = pcm(new float[size], stereo ? new float[size] : null, floats, size);
                long end = block;
                for (int i = 0; i < 3; i++) {
                    capture.write(silence, end, NOW);
                    end += block;
                    assertArrayEquals("The plot follows the playhead, not the newest audio", expected, capture.snapshot(NOW)[0], 0);
                }
                capture.playhead(end, NOW);
                for (float sample : capture.snapshot(NOW)[0]) assertEquals(0, sample, 0);
                // Stale positions, an idle player and a request that lapsed are never displayed.
                capture.playhead(42_000_000, NOW);
                assertNull("Samples from before a seek must not be displayed", capture.snapshot(NOW));
                capture.playhead(end, NOW);
                assertNull("A player that stopped reporting its position is not playing", capture.snapshot(NOW + 600_000_000L));
                capture.playhead(end, NOW + 600_000_000L);
                capture.write(silence, end, NOW + 1_300_000_000L);
                assertNull("Capture stops when the visualizer stops asking", capture.snapshot(NOW + 1_300_000_000L));
                // Audio from another position restarts the ring even if no reset arrived.
                capture.write(audio, 0, NOW + 1_300_000_000L);
                capture.write(pcm(tone, stereo ? tone : null, floats, size / 2), 90_000_000, NOW + 1_300_000_000L);
                capture.playhead(90_000_000, NOW + 1_300_000_000L);
                assertNull("A partial window after a jump is not displayed", capture.snapshot(NOW + 1_300_000_000L));
                capture.write(audio, 0, NOW + 1_300_000_000L);
                capture.playhead(block, NOW + 1_300_000_000L);
                assertNotNull(capture.snapshot(NOW + 1_300_000_000L));
                capture.reset();
                assertNull(capture.snapshot(NOW + 1_300_000_000L));
            }
        }
        SpectrumCapture unsupported = new SpectrumCapture();
        unsupported.prepare(48000, 2, 3);
        unsupported.snapshot(NOW);
        unsupported.write(ByteBuffer.allocate(size * 6), 0, NOW);
        unsupported.playhead(block, NOW);
        assertNull("Unknown PCM encodings are left alone", unsupported.snapshot(NOW));
    }
}
