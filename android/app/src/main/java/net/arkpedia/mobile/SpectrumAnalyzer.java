package net.arkpedia.mobile;

/**
 * Peak levels in the same 48 logarithmic bands, on the same scale and with the same
 * smoothing as the website's Web Audio analyser. Mirrors the iOS SpectrumAnalyzer.
 */
final class SpectrumAnalyzer {
    static final int SIZE = 8192, BANDS = 48;
    /** AnalyserNode.smoothingTimeConstant on the website, applied once per drawn frame. */
    static final float SMOOTHING = 0.68f;
    private final float[] window = new float[SIZE], cos = new float[SIZE / 2], sin = new float[SIZE / 2];
    private final int[] reversed = new int[SIZE];
    private final float[] real = new float[SIZE], imaginary = new float[SIZE];
    private float[] previous = new float[BANDS];

    SpectrumAnalyzer() {
        int bits = Integer.numberOfTrailingZeros(SIZE);
        for (int i = 0; i < SIZE; i++) {
            double phase = 2 * Math.PI * i / SIZE;
            window[i] = (float) (0.42 - 0.5 * Math.cos(phase) + 0.08 * Math.cos(2 * phase));
            reversed[i] = Integer.reverse(i) >>> (32 - bits);
            if (i < SIZE / 2) { cos[i] = (float) Math.cos(phase); sin[i] = (float) -Math.sin(phase); }
        }
    }

    /** Loudest bin per band across the channels: anti-phase stereo must not cancel a visible signal. */
    float[] amplitudes(float[][] channels, int sampleRate) {
        float[] peaks = new float[BANDS];
        if (sampleRate <= 0) return peaks;
        double binHz = (double) sampleRate / SIZE;
        int[] edges = new int[BANDS + 1];
        for (int i = 0; i <= BANDS; i++) {
            edges[i] = Math.max(1, Math.min(SIZE / 2, (int) Math.ceil(62.5 * Math.pow(256, (double) i / BANDS) / binHz)));
        }
        for (int c = 0; c < Math.min(2, channels.length); c++) {
            float[] channel = channels[c];
            if (channel.length != SIZE) continue;
            for (int i = 0; i < SIZE; i++) { real[reversed[i]] = channel[i] * window[i]; imaginary[reversed[i]] = 0; }
            for (int half = 1; half < SIZE; half <<= 1) {
                int step = SIZE / (half * 2);
                for (int start = 0; start < SIZE; start += half * 2) {
                    for (int k = 0; k < half; k++) {
                        int a = start + k, b = a + half;
                        float wr = cos[k * step], wi = sin[k * step];
                        float tr = real[b] * wr - imaginary[b] * wi, ti = real[b] * wi + imaginary[b] * wr;
                        real[b] = real[a] - tr; imaginary[b] = imaginary[a] - ti;
                        real[a] += tr; imaginary[a] += ti;
                    }
                }
            }
            // Web Audio divides the transform by its size and does not undo the Blackman
            // window, so a full-scale sine reads 0.21 (-13.6 dB): the website's bar heights.
            for (int band = 0; band < BANDS; band++) {
                for (int bin = edges[band]; bin < edges[band + 1]; bin++) {
                    float amplitude = (float) Math.hypot(real[bin], imaginary[bin]) / SIZE;
                    if (!Float.isNaN(amplitude) && !Float.isInfinite(amplitude)) peaks[band] = Math.max(peaks[band], amplitude);
                }
            }
        }
        return peaks;
    }

    /** Blend with the previous frame like the website's analyser; reset() starts a new plot. */
    float[] smoothed(float[] amplitudes) {
        for (int band = 0; band < BANDS; band++) previous[band] = SMOOTHING * previous[band] + (1 - SMOOTHING) * amplitudes[band];
        return previous.clone();
    }
    void reset() { previous = new float[BANDS]; }

    /** -90 dB to -18 dB as 0 to 255, the range the website draws. */
    static int[] bytes(float[] amplitudes) {
        int[] levels = new int[amplitudes.length];
        for (int i = 0; i < amplitudes.length; i++) {
            double db = 20 * Math.log10(Math.max(amplitudes[i], 0.000001f));
            levels[i] = (int) Math.round(Math.min(1, Math.max(0, (db + 90) / 72)) * 255);
        }
        return levels;
    }
    int[] levels(float[][] channels, int sampleRate) { return bytes(amplitudes(channels, sampleRate)); }
}
