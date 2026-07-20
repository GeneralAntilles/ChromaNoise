# ChromaNoiseKit

Host-agnostic DSP core for ChromaNoise. Everything here is pure Swift +
Foundation + swift-atomics — **no AVFoundation, no AVAudioSession, no UI**.
This is enforced by `HostAgnosticismTests` and is what makes the engine
reusable verbatim inside a future AUv3 extension (where the host owns the
audio session and the render contract is the same raw-pointer pull).

## Layout

- `DSP/` — band math, gain LUT, windows, FFT, noise source, tremolo.
- `Audio/` — the streaming synthesis (`NoiseStream`), the SPSC ring
  (`RenderRingBuffer`), and the `NoiseEngine` facade the app/AU wraps.
- `Analysis/` — the "clone this sound" pipeline (Welch PSD → band
  aggregation → peak-anchored slider normalization → flatness guard).
  File decoding lives in the app target (it needs `AVAudioFile`); only the
  pure-DSP half is here.
- `Models/` — `Phonon` (the preset struct) and the built-in presets.

## Verification

The algorithm is specified by `tools/reference_dsp.py` at the repo root — a
numpy implementation whose 18 checks all pass at machine precision. The tests
here mirror those checks; if Swift and Python disagree, Python wins until
proven otherwise.

```sh
swift test -c release   # release! the synthesis tests run ~1000 FFTs
```

`PureSwiftFFT` is deliberately dependency-free and portable. If profiling on
device shows the worker thread matters (it shouldn't — the budget is 2 FFTs
per 21 ms hop), swap in a vDSP-backed `RealFFT` conformance behind the same
protocol.

## Integration notes for the app target

- Wrap `NoiseEngine.render(left:right:frameCount:)` in an
  `AVAudioSourceNode` render block. The block must do nothing else.
- Call `prepare(sampleRate:maxFrames:)` after the session/route is known;
  call it again (after `teardown()`) on sample-rate or route changes.
- Push UI state via `setBandGains` / `setMasterVolume` / `setTremolo` from
  any thread; the worker picks changes up at the next hop boundary and the
  75% overlap crossfades spectral changes over ~85 ms automatically.
