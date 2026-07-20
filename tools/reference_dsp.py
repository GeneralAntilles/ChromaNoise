#!/usr/bin/env python3
"""ChromaNoise DSP golden reference.

Numerically verifies every constant and algorithm in the Swift DSP core
(Packages/ChromaNoiseKit). The Swift implementation is a translation of
this file; the XCTest suite mirrors these checks. If Swift and this file
disagree, this file wins until proven otherwise.

Run: python3 tools/reference_dsp.py   (exits nonzero on any failure)
"""

import numpy as np

# ---------------------------------------------------------------- constants

N = 4096          # FFT size
HOP = 1024        # 75% overlap; Hann*Hann COLA requires hop <= N/4
SR = 48000
BANDS = 32
FMIN = 100.0
FMAX = 20000.0
COLA_SUM = 1.5    # sum of squared periodic Hann at hop N/4

# ---------------------------------------------------------------- band math

def band_edges():
    """33 edges, log-spaced 100 Hz .. 20 kHz: edge[i] = 100 * 200^(i/32)."""
    i = np.arange(BANDS + 1)
    return FMIN * (FMAX / FMIN) ** (i / BANDS)

def band_of_bin(sr, n):
    """Map FFT bin -> band index, or -1 if out of range. Bins are rfft bins 0..n/2."""
    edges = band_edges()
    freqs = np.arange(n // 2 + 1) * sr / n
    band = np.full(n // 2 + 1, -1, dtype=int)
    for b in range(BANDS):
        mask = (freqs >= edges[b]) & (freqs < edges[b + 1])
        band[mask] = b
    return band

def slider_to_amp(v):
    """v in [0,1] -> amplitude, 60 dB exponential. v=0 -> 0.001, v=1 -> 1.0."""
    return 0.001 * np.power(1000.0, v)

def amp_to_slider(a, ref=1.0):
    """Inverse curve relative to a reference amplitude; clamped to [0,1]."""
    with np.errstate(divide="ignore"):
        v = (np.log10(np.maximum(a / ref, 1e-30)) + 3.0) / 3.0
    return np.clip(v, 0.0, 1.0)

# ---------------------------------------------------------------- gain LUT

def build_gain(band_amps, sr=SR, n=N, normalize=True):
    """Per-rfft-bin gain from 32 post-curve band amplitudes.
    Flat fill within each band; constant-power normalization:
    sum(gain^2) over active bins == number of active bins
    (so an all-ones spectrum is the unit gain)."""
    bmap = band_of_bin(sr, n)
    gain = np.zeros(n // 2 + 1)
    active = bmap >= 0
    gain[active] = np.asarray(band_amps)[bmap[active]]
    if normalize:
        power = np.sum(gain ** 2)
        if power > 1e-12:
            gain *= np.sqrt(np.count_nonzero(active) / power)
        else:
            gain[:] = 0.0
    return gain

# ---------------------------------------------------------------- synthesis

def hann_periodic(n):
    """Periodic Hann. NOT scipy.signal.windows.hann(sym=True)."""
    return 0.5 * (1.0 - np.cos(2.0 * np.pi * np.arange(n) / n))

def synthesize(gain, seconds, sr=SR, seed=1):
    """Streaming STFT-multiply-OLA over one continuous white noise stream.
    Returns float array of len seconds*sr (after discarding N of warmup)."""
    rng = np.random.default_rng(seed)
    w = hann_periodic(N)
    total = int(seconds * sr) + 2 * N
    noise = rng.uniform(-1.0, 1.0, total)
    out = np.zeros(total + N)
    for start in range(0, total - N, HOP):
        frame = noise[start:start + N] * w
        spec = np.fft.rfft(frame)
        spec *= gain
        y = np.fft.irfft(spec, N) * w
        out[start:start + N] += y
    out /= COLA_SUM
    return out[N:N + int(seconds * sr)]

def tremolo_envelope(num, period_s, depth, sr=SR):
    """Sine LFO between (1-depth) and 1.0. Bypass if depth or period < 1e-3."""
    if depth < 1e-3 or period_s < 1e-3:
        return np.ones(num)
    t = np.arange(num) / sr
    return (1.0 - depth) + depth * (0.5 + 0.5 * np.sin(2.0 * np.pi * t / period_s))

# ---------------------------------------------------------------- presets

def preset(name):
    f_center = np.sqrt(band_edges()[:-1] * band_edges()[1:])  # geometric centers
    if name == "white":
        return np.ones(BANDS)
    if name == "pink":       # -3 dB/oct power -> amp ~ 1/sqrt(f)
        return 1.0 / np.sqrt(f_center / FMIN)
    if name == "brown":      # -6 dB/oct power -> amp ~ 1/f
        return FMIN / f_center
    if name == "blue":       # +3 dB/oct
        return np.sqrt(f_center / FMIN)
    raise ValueError(name)

# ---------------------------------------------------------------- clone

N_WELCH = 16384

def welch_psd(x, sr):
    """Welch's method: N=16384, periodic Hann, 50% hop, mean of |X|^2.
    Normalized by window power so a flat-PSD input gives flat output."""
    w = hann_periodic(N_WELCH)
    wp = np.sum(w ** 2)
    frames = []
    for start in range(0, len(x) - N_WELCH + 1, N_WELCH // 2):
        spec = np.fft.rfft(x[start:start + N_WELCH] * w)
        frames.append((np.abs(spec) ** 2) / wp)
    if len(frames) < 2:
        raise ValueError("clip too short")
    return np.mean(frames, axis=0)

def clone(x, sr):
    """Audio samples -> 32 slider values. Peak band anchored to slider 0.85."""
    if np.sqrt(np.mean(x ** 2)) < 10 ** (-60 / 20):
        raise ValueError("no audible content")
    psd = welch_psd(x, sr)
    bmap = band_of_bin(sr, N_WELCH)
    band_amp = np.zeros(BANDS)
    for b in range(BANDS):
        bins = psd[bmap == b]
        if len(bins):
            band_amp[b] = np.sqrt(np.mean(bins))       # mean power, then sqrt
    a_ref = band_amp.max() / slider_to_amp(0.85)       # peak -> slider 0.85
    floor = band_amp.max() * 10 ** (-60 / 20)          # 60 dB floor -> 0
    v = amp_to_slider(band_amp, ref=a_ref)
    v[band_amp < floor] = 0.0
    return v

def spectral_flatness(psd):
    """Wiener entropy: geometric mean / arithmetic mean of power bins."""
    p = psd[psd > 0]
    return np.exp(np.mean(np.log(p))) / np.mean(p)

# ---------------------------------------------------------------- checks

def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
    return ok

def fit_slope_db_per_decade(psd, sr, n, f_lo, f_hi):
    freqs = np.arange(n // 2 + 1) * sr / n
    m = (freqs >= f_lo) & (freqs <= f_hi)
    return np.polyfit(np.log10(freqs[m]), 10 * np.log10(psd[m]), 1)[0]

def main():
    ok = True
    edges = band_edges()

    # 1. Band edges hit the documented anchors.
    ok &= check("band edges", abs(edges[0] - 100) < 1e-9 and abs(edges[-1] - 20000) < 1e-6,
                f"edge0={edges[0]:.1f} edge32={edges[-1]:.1f}")

    # 2. Slider curve endpoints and inverse round-trip.
    v = np.linspace(0, 1, 11)
    ok &= check("slider curve round-trip",
                np.allclose(amp_to_slider(slider_to_amp(v)), v, atol=1e-12)
                and abs(slider_to_amp(0.0) - 0.001) < 1e-12
                and abs(slider_to_amp(1.0) - 1.0) < 1e-12)

    # 3. COLA: periodic Hann^2 shifts at hop N/4 sum to exactly 1.5.
    w2 = hann_periodic(N) ** 2
    acc = np.zeros(N)
    for s in range(0, N, HOP):
        acc += np.roll(w2, s)
    ok &= check("COLA sum == 1.5", np.allclose(acc, COLA_SUM, atol=1e-9),
                f"max dev {np.abs(acc - COLA_SUM).max():.2e}")

    # 4. Perfect reconstruction: gain == 1 everywhere reproduces the input.
    rng = np.random.default_rng(7)
    x = rng.uniform(-1, 1, 6 * N)
    w = hann_periodic(N)
    y = np.zeros(len(x))
    for start in range(0, len(x) - N, HOP):
        y[start:start + N] += np.fft.irfft(np.fft.rfft(x[start:start + N] * w), N) * w
    y /= COLA_SUM
    core = slice(N, len(x) - N)
    ok &= check("identity reconstruction", np.allclose(y[core], x[core], atol=1e-9),
                f"max err {np.abs(y[core] - x[core]).max():.2e}")

    # 5. Constant-power normalization invariant.
    for name in ("white", "pink", "brown", "blue"):
        g = build_gain(preset(name))
        tot = np.sum(g ** 2)
        expect = np.count_nonzero(band_of_bin(SR, N) >= 0)
        ok &= check(f"sum(gain^2) const [{name}]", abs(tot / expect - 1) < 1e-9,
                    f"{tot:.1f} vs {expect}")

    # 6. White preset: band-averaged PSD flat +-1 dB, out-of-band down >40 dB.
    # (Bin-level p2p is dominated by Welch estimator variance — ~58 frames
    # gives +-0.5 dB/bin — so flatness is asserted on band means, matching
    # the 32-band flat-fill spec.)
    out = synthesize(build_gain(preset("white")), 10.0)
    psd = welch_psd(out, SR)
    freqs = np.arange(N_WELCH // 2 + 1) * SR / N_WELCH
    inband = (freqs > 150) & (freqs < 18000)
    bmap = band_of_bin(SR, N_WELCH)
    band_db = np.array([10 * np.log10(psd[bmap == b].mean())
                        for b in range(1, BANDS - 1)])  # skip edge bands
    flat_dev = band_db.max() - band_db.min()
    below = psd[(freqs > 10) & (freqs < 80)].mean() / psd[inband].mean()
    ok &= check("white flat in-band", flat_dev < 1.0, f"band p2p {flat_dev:.2f} dB")
    ok &= check("white rejects <100 Hz", below < 1e-4, f"leak {10*np.log10(below):.1f} dB")

    # 7. Pink preset: fitted PSD slope -10 dB/decade (+-1.5).
    out = synthesize(build_gain(preset("pink")), 10.0)
    slope = fit_slope_db_per_decade(welch_psd(out, SR), SR, N_WELCH, 200, 10000)
    ok &= check("pink slope -10 dB/dec", abs(slope + 10) < 1.5, f"{slope:.2f}")

    # 8. Brown preset: -20 dB/decade (+-2).
    out = synthesize(build_gain(preset("brown")), 10.0)
    slope = fit_slope_db_per_decade(welch_psd(out, SR), SR, N_WELCH, 200, 10000)
    ok &= check("brown slope -20 dB/dec", abs(slope + 20) < 2.0, f"{slope:.2f}")

    # 9. Stationarity: 100 ms RMS windows vary < 3 dB (no OLA pumping).
    out = synthesize(build_gain(preset("white")), 10.0)
    win = int(0.1 * SR)
    rms = np.array([np.sqrt(np.mean(out[i:i+win]**2))
                    for i in range(0, len(out)-win, win)])
    pump = 20 * np.log10(rms.max() / rms.min())
    ok &= check("stationary output", pump < 3.0, f"pump {pump:.2f} dB")

    # 10. Clone round-trip: white -> all sliders ~0.85.
    v = clone(synthesize(build_gain(preset("white")), 12.0), SR)
    ok &= check("clone(white) ~= 0.85 flat", np.all(np.abs(v - 0.85) < 0.025),
                f"range [{v.min():.3f},{v.max():.3f}]")

    # 11. Clone round-trip: pink synth -> declining ~0.050/octave slider slope.
    v = clone(synthesize(build_gain(preset("pink")), 12.0), SR)
    octaves_per_band = np.log2(FMAX / FMIN) / BANDS
    slope_per_band = np.polyfit(np.arange(BANDS), v, 1)[0]
    expect = -np.log10(np.sqrt(2)) / 3 * octaves_per_band / np.log10(2) * np.log10(2)
    # amp halves every 2 octaves -> dv/octave = log10(sqrt(2))/3 ~ 0.0502
    expect = -0.0502 * octaves_per_band
    ok &= check("clone(pink) slider slope", abs(slope_per_band - expect) < 0.01,
                f"{slope_per_band:.4f} vs {expect:.4f}")

    # 12. Tonal guard: pure 1 kHz tone -> flatness < 0.05; noise -> > 0.2.
    t = np.arange(SR * 5) / SR
    tone_f = spectral_flatness(welch_psd(0.5 * np.sin(2 * np.pi * 1000 * t), SR))
    noise_f = spectral_flatness(welch_psd(np.random.default_rng(3).uniform(-1, 1, SR * 5), SR))
    ok &= check("flatness separates tone/noise", tone_f < 0.05 < 0.2 < noise_f,
                f"tone {tone_f:.4f} noise {noise_f:.3f}")

    # 13. Silence guard.
    try:
        clone(np.zeros(SR * 5), SR)
        ok &= check("silence rejected", False)
    except ValueError:
        ok &= check("silence rejected", True)

    # 14. Tremolo: envelope min == 1-depth, bypass at depth 0.
    env = tremolo_envelope(SR * 2, 1.0, 0.6)
    ok &= check("tremolo depth", abs(env.min() - 0.4) < 1e-3 and abs(env.max() - 1.0) < 1e-3,
                f"[{env.min():.4f},{env.max():.4f}]")
    ok &= check("tremolo bypass", np.all(tremolo_envelope(100, 1.0, 0.0) == 1.0))

    print("\nALL PASS" if ok else "\nFAILURES PRESENT")
    return 0 if ok else 1

if __name__ == "__main__":
    raise SystemExit(main())
