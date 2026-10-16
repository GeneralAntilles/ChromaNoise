# ChromaNoise iOS — Port/Reimplementation Plan

## Status (2026-10-16)

- **DSP math verified**: `tools/reference_dsp.py` (numpy) implements the full
  pipeline and passes all 18 checks at machine precision. It is the golden
  reference — Swift mirrors it.
- **Kit compiles and passes**: `Packages/ChromaNoiseKit` builds with Swift 6.1
  on Linux and all 26 tests pass under `swift test -c release` (the engine
  threading tests are also clean under ThreadSanitizer). CI runs both the
  Python reference and the kit tests on every push. Still unbuilt on Apple
  platforms — expect no surprises (the kit uses only Foundation + swift-atomics).
- **Engine lifecycle hardened** (found on first compile/review):
  - `prepare` after `teardown` used to leave the old worker running against
    the new ring (two producers on an SPSC ring) on every route/sample-rate
    change; workers are now per-session and `teardown` joins them.
  - The render path no longer retains: it reads an `Unmanaged` ring pointer.
    Contract: the host stops rendering before `prepare`/`teardown` (same as
    AUv3 allocate/deallocateRenderResources).
  - The worker used to fill the whole ring (~170 ms queued at 48 kHz);
    it now keeps `2 hops + maxFrames` queued (~53 ms with 512-frame pulls).
    Slider-to-ear is that plus the ~85 ms OLA crossfade.
  - Master volume, applied after overlap-add, is now ramped across each hop.
- **Design simplification found during verification**: 75% OLA overlap already
  crossfades spectral changes over ~4 hops (~85 ms), so the per-hop gain ramp
  originally planned is unnecessary.
- **CPU**: the pure-Swift FFT runs ~20× realtime for stereo on x86 — fine
  functionally, but the < 3% CPU target will likely need the vDSP-backed
  `RealFFT` conformance on device (the protocol seam already exists).
- **App bootstrapped** (2026-10-16): `project.yml` (XcodeGen) defines the
  iOS target; `Audio/StandaloneAudioHost.swift` drives the kit through an
  `AVAudioSourceNode`, and a one-screen UI (`UI/RootView.swift`) plays the
  built-in presets with a volume slider. CI compiles it on macOS. Covers most
  of milestones 1 + 3. See `CLAUDE.md` for the Mac workflow.
- **Not started**: equalizer painter, SwiftData store, services (Now Playing,
  interruptions, sleep timer), clone file ingestion.

## Context

**Why**: An iOS Swift app inspired by [ChromaDoze](https://github.com/pmarks-net/chromadoze) — an Android white-noise generator whose defining feature is a multi-band slider/spectrum painter that shapes white noise in real time. This plan was researched and designed before any code; the project will be built and shipped from a Mac with Xcode.

**Decisions**:
- **Licensing**: Clean reimplementation. Re-derive the algorithm from public description; no copying GPL-3.0 source. Fresh iOS-native UI.
- **Scope**: Full feature parity for v1 — sliders, real-time DSP, tremolo, background audio, lock-screen controls, "phonon" presets, sleep timer, plus a "clone this sound" feature as the differentiator.
- **UI**: Native SwiftUI 32-bar vertical spectrum, drag-to-paint.
- **Algorithm**: Departs from ChromaDoze where cleaner (streaming FFT overlap-add instead of DCT block shuffling).
- **AUv3**: deferred to v2, but v1 is architected so it's a drop-in addition.

---

## Algorithm: streaming FFT overlap-add

**ChromaDoze does**: pre-generate Float blocks via inverse DCT-II of a randomized spectrum, shuffle-bag-pick blocks, equal-power crossfade between blocks (93 ms), peak-normalize each chunk, time-reverse on right channel for stereo.

**We do instead**: stream continuous white noise, STFT it, multiply bin magnitudes by a per-band gain LUT, ISTFT, overlap-add. Trades the block-shuffler+crossfade for one coherent pipeline. ~25 ms slider response (vs 100+ ms in ChromaDoze), no chunk-regen CPU spikes, cleaner code.

### Numeric spec

- **Sample rate**: device-native (typically 48 kHz; 44.1 kHz on some routes; ~16 kHz over some Bluetooth profiles).
- **FFT size N**: 4096.
- **Hop**: 1024 (75% overlap) — required for proper Hann × Hann COLA.
- **Window**: Hann on analysis and synthesis sides.
- **Latency**: hop / sample_rate ≈ 21 ms @ 48 kHz; ~30–40 ms total end-to-end.
- **Frequency resolution**: 11.7 Hz/bin @ 48 kHz.
- **Bands**: 32, log-spaced 100 Hz – 20 kHz. `edgeFreq[i] = 100 * pow(200, i/32)`.
- **Slider→amplitude curve**: `amp = 0.001 * pow(1000, v)` for `v ∈ [0,1]` (60 dB range).
- **Band-to-bin mapping**: flat fill — `gain[k] = bandAmp[band(k)]`. Out-of-range bins gain = 0.
- **Loudness normalization**: rescale `gain[]` so `Σ gain[k]² = constant`.
- **Output safety net**: `tanh` soft-limit at master output.
- **Stereo decorrelation**: independent white-noise streams per channel through the same gain LUT.
- **Slider drag**: triple-buffered atomic snapshot; worker reads at hop boundaries; linear ramp `gain[]` across the hop to avoid zipper noise.

### Per-hop pipeline (worker thread)

1. Generate 1024 fresh uniform-random samples per channel.
2. Slide into the length-4096 input buffer; window with Hann.
3. Forward real FFT (`vDSP.FFT<DSPSplitComplex>`, size 4096).
4. Multiply real and imaginary parts by `gain[]`.
5. Inverse FFT, scale by `1/(2N)`.
6. Window with Hann (synthesis side).
7. Overlap-add into output ring buffer.
8. Apply tremolo LFO (see below) and master volume; `tanh` soft-limit.

Render thread: single `memcpy` from ring buffer into the `AudioBufferList`. No allocations, no Swift collections, no locks.

### Tremolo (replaces ChromaDoze's `period` field)

ChromaDoze's `period` is a tremolo LFO period (10 ms – 60 s, paired with `minVol` for depth). Drives "ocean wave" / "breathing" presets. We keep the feature but redesign storage:

- `tremoloPeriodSeconds: Float` — direct seconds, default 1.0, range 0.01–60.0.
- `tremoloDepth: Float` — direct depth, default 0.0 (off), range 0.0–1.0. Equivalent to ChromaDoze's `1.0 - minVol`.
- Bypass when `tremoloDepth < 0.001` or `tremoloPeriodSeconds < 0.001`.

Implemented as a sine LFO multiplied across the post-overlap-add output buffer immediately before the tanh — one SIMD `vDSP_vmul`. Phase advances by `2π * hop / (period * sampleRate)` per hop. Legacy ChromaDoze JSON imports run the upstream piecewise mapping (slot 0–53 → seconds) at decode time.

---

## Target & Tooling

- iOS 17.2+ (SwiftData stability, Observation macro, modern SwiftUI).
- Xcode 15+, Swift 5.10.
- Frameworks: `AVFoundation`, `Accelerate`, `MediaPlayer`, `SwiftData`, `SwiftUI`.

---

## Project Structure

Single Xcode app target with one internal SPM package (`ChromaNoiseKit`). The kit is **host-agnostic**: it imports neither `AVFoundation` nor `AVAudioSession`. This is what makes a v2 AUv3 extension a drop-in: the future AU target plugs `NoiseEngine.render(into:frameCount:)` into `AUAudioUnit.internalRenderBlock` instead of `AVAudioSourceNode.renderBlock`.

```
ChromaNoise/
  ChromaNoise.xcodeproj
  App/
    ChromaNoiseApp.swift            // @main; boots host + SwiftData container
    RootView.swift                  // TabView: Equalizer | Phonons | Timer
    Info.plist                      // UIBackgroundModes: [audio]
  UI/
    EqualizerView.swift             // Canvas + DragGesture, 32-bar painter
    BarSpectrum.swift               // pure render of [Float] -> Canvas
    PhononListView.swift            // SwiftData @Query of saved presets
    SleepTimerView.swift            // duration picker + countdown
    NowPlayingBar.swift             // play/pause + master volume
    Clone/
      CloneSheet.swift              // .fileImporter + analysis sheet
      DualSpectrumView.swift        // source PSD curve + 32-bar preview
  Audio/
    StandaloneAudioHost.swift       // AVAudioEngine + AVAudioSourceNode wrapper
                                    //   - drives ChromaNoiseKit.NoiseEngine
                                    //   - owns AVAudioSession lifecycle
  Services/
    AudioSessionCoordinator.swift   // AVAudioSession setup + interruption/route observers
    NowPlayingService.swift         // MPNowPlayingInfoCenter + MPRemoteCommandCenter wiring
    SleepTimerService.swift         // Task-based countdown + master-volume fade
Packages/ChromaNoiseKit/
  Sources/ChromaNoiseKit/
    Models/
      Phonon.swift                  // Codable: 32 amps + volume + tremolo fields + name
      SpectrumModel.swift           // @Observable live state, atomic snapshot publisher
      PhononStore.swift             // SwiftData @Model wrapper around Phonon JSON blob
      Presets.swift                 // White/Pink/Brown/Blue 32-float arrays
    DSP/
      BandMath.swift                // freq table, slider->amp curve, band-to-bin LUT
      GainLUT.swift                 // build/normalize gain[] from 32 band amps
      Windows.swift                 // Hann table builder
      Tremolo.swift                 // sine LFO + bypass guard
    Audio/
      NoiseStream.swift             // STFT pipeline: white noise -> spectrum-shape -> OLA
      RenderRingBuffer.swift        // SPSC lock-free ring of Float frames
      NoiseEngine.swift             // host-agnostic facade (see API below)
    Analysis/                       // "Clone this sound" feature
      AudioFileLoader.swift         // AVAudioFile + chunked PCM read; mono-sum
      WelchAnalyzer.swift           // 16384-pt Welch's method, Hann 50% hop
      BandAggregator.swift          // bin power -> mean per band -> sqrt -> slider value
      SpectralFlatness.swift        // Wiener entropy for tonal-content detection
      CloneNormalizer.swift         // peak-anchored normalization to slider 0.85
  Tests/ChromaNoiseKitTests/
    DSPTests.swift                  // FFT round-trip, COLA, gain normalization
    PresetsTests.swift              // pink/brown spectral slope verification
    WAVDumpTests.swift              // ear-check artifact generator
    CloneRoundTripTests.swift       // synthetic white/pink WAV -> phonon within ±1.5 dB
```

Note: `AudioFileLoader` needs AVAudioFile; if we hold the "no AVFoundation in kit" rule strictly, the Analysis file-loading half lives in the app target and only the pure-DSP analysis (Welch, aggregation, flatness, normalization) stays in the kit. Decide at implementation time; the DSP halves must stay kit-side for testability.

### `NoiseEngine` API (the host-agnostic facade)

```swift
public final class NoiseEngine {
  public init()
  public func prepare(sampleRate: Double, maxFrames: UInt32)
  public func teardown()
  public func render(into bufferList: UnsafeMutableAudioBufferListPointer,
                     frameCount: UInt32) -> Int32   // OSStatus
  public func setBandGains(_ amps: [Float])         // 32 floats, post-curve
  public func setMasterVolume(_ v: Float)
  public func setTremolo(periodSeconds: Float, depth: Float)
}
```

Both `StandaloneAudioHost` (v1) and a future `ChromaNoiseAU` (v2) are thin shells around this.

---

## Audio (standalone host)

`StandaloneAudioHost`:
- Owns the `AVAudioEngine`, `AVAudioSourceNode`, and `AVAudioSession`.
- `AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: 2)`.
- `AVAudioSourceNode(renderBlock:)` is a one-line bridge to `engine.render(into:frameCount:)`.
- Observes `AVAudioEngine.changeNotification` and `AVAudioSession.routeChangeNotification`; on change, `teardown()` then `prepare(...)` with the new sample rate.
- Worker thread: `Thread` with `qos: .userInteractive` running the per-hop STFT, pushing into `RenderRingBuffer`. Lives in the kit; started by `prepare()`.

---

## Data Model & Persistence

```swift
struct Phonon: Codable, Hashable {
  var name: String
  var amps: [Float]               // 32, post-curve amplitudes
  var masterVolume: Float         // 0..1
  var tremoloPeriodSeconds: Float // 0.01..60.0
  var tremoloDepth: Float         // 0..1
}
```

- `@Model final class StoredPhonon { @Attribute(.unique) var id: UUID; var name: String; var data: Data /*JSON of Phonon*/ }` — JSON blob avoids schema migration on the 32-float array.
- `@Observable final class SpectrumModel` mirrors Phonon fields + `isPlaying`. UI binds to it; the host pushes changes into `NoiseEngine` (no debounce — worker samples once per hop).

---

## UI

- **EqualizerView**: `Canvas` draws 32 bars; `DragGesture(minimumDistance: 0)` updates `SpectrumModel.amps`. Map `x` → band index, `y` → `v ∈ [0,1]`. When the touch jumps over bands, linearly interpolate from previous to current index (line-painting).
- **PhononListView**: `List` with `@Query(sort: \StoredPhonon.name)`, swipe-to-delete, "Save current" action.
- **Built-in presets**: White, Pink, Brown, Blue as non-deletable system phonons, plus a "Clone…" entry.
- **Tremolo controls**: period (log-scale slider, 10 ms ↔ 60 s) and depth (0–100%) in a "Modulation" disclosure group.
- **SleepTimerView**: `Picker` (5/15/30/60 min + custom); service ramps `masterVolume → 0` over the last 15 s then stops the engine.
- **NowPlayingBar**: play/pause, master volume, timer remaining.

---

## System Integration

- `Info.plist`: `UIBackgroundModes = [audio]`.
- `AVAudioSession` category `.playback`, mode `.default`, **no** `.mixWithOthers` — a mixable session can't become the Now Playing app, so lock-screen controls would never appear. (Could be a user toggle later: "play alongside other audio" at the cost of remote controls.)
- `MPNowPlayingInfoCenter` with `MPNowPlayingInfoPropertyIsLiveStream = true`.
- `MPRemoteCommandCenter`: enable play/pause/togglePlayPause/stop; disable seek/skip.
- Handle `interruptionNotification` (pause on `.began`, resume on `.ended` + `.shouldResume`) and `routeChangeNotification` (pause on `.oldDeviceUnavailable`).
- No wake locks on iOS: `.playback` + rendering audio + background mode is sufficient.

---

## Built-in Presets (post-curve amplitudes per band)

| Preset | Spectral shape | Per-band amp formula |
|---|---|---|
| White | flat | `1.0` |
| Pink  | −3 dB/oct | `1 / sqrt(f_i / 100)` |
| Brown | −6 dB/oct | `100 / f_i` |
| Blue  | +3 dB/oct | `sqrt(f_i / 100)` |

---

## Audio Clone (the differentiator)

User picks an audio file; we analyze its long-term spectrum and save a phonon that approximates it. Entirely on-device.

### Algorithm

- **Welch's method**: N_analysis = 16384 (~2.93 Hz/bin @ 48 kHz), Hann window, 50% hop (independence between frames > reconstruction quality here). Accumulate `|X[k]|²`, divide by frame count and window power.
- **Duration**: minimum 3 s non-silent (else refuse), cap 120 s (centered slice, 5% head/tail trim).
- **Band aggregation**: `P_band[i] = mean(|X[k]|²)` over the band's bins (mean, not sum — avoids bandwidth bias), `A_band[i] = sqrt(P_band[i])`.
- **Slider inversion**: `v[i] = clamp((log10(A_band[i]/A_ref) + 3) / 3, 0, 1)`.
- **Normalization**: peak-anchored — `A_ref = max(A_band) / 0.85`; bands >60 dB below peak floor to 0.
- **Equal-loudness compensation**: off (user already perceived the source through their own ears).
- **Stereo**: mono-sum `(L+R) * 0.5` before FFT.
- **Tonal guard**: spectral flatness (Wiener entropy); < 0.05 → soft warning ("captures timbre, not tone"), don't reject.
- **Silence guard**: reject if RMS < −60 dBFS.

### Ingestion

- `.fileImporter(allowedContentTypes: [.audio])` + security-scoped resource access.
- `AVAudioFile` decodes wav/aiff/caf/m4a/mp3/ALAC/FLAC on iOS 17.2. Chunked reads into Float32 non-interleaved `AVAudioPCMBuffer`.
- Bin→Hz mapping uses the file's own sample rate; no resampling.
- Video-with-audio: defer to v1.1 (`AVAssetReader` path).
- DRM files: surface the error; don't bypass.

### UX

1. **+ → Clone a sound** → file picker.
2. Analysis sheet: name, duration, cancelable progress.
3. **DualSpectrumView**: source PSD as continuous curve (top) vs our 32 bars animating in (bottom) — makes the lossy quantization visible.
4. Auto-name from filename stem; editable.
5. **Audition** live before saving.
6. Tonal-warning banner when applicable.

---

## Milestone Sequence

1. **Skeleton + silent engine** — Xcode project, SwiftData container, audio session, `StandaloneAudioHost` with zero-output source node; play/pause UI; stays alive in background.
2. **DSP offline** — `NoiseStream` + Hann + `GainLUT`; XCTest writes a 10 s WAV. Validates COLA, gain shape, no clicks.
3. **Live noise** — ring buffer wired via `NoiseEngine.render`; white preset hardcoded; listening test.
4. **Equalizer UI** — drag-paint end-to-end with per-hop gain ramping.
5. **Phonon persistence + built-in presets**.
6. **Tremolo** — LFO at pipeline output; period/depth UI.
7. **Audio clone** — picker, Welch analyzer, dual-spectrum preview, audition, save. Round-trip test is ship-blocker.
8. **Now Playing + remotes** — lock-screen controls, interruption/route handling.
9. **Sleep timer**.
10. **Polish & ship** — Instruments pass, accessibility, icon, App Store metadata.

---

## v2 Roadmap

- **AUv3 instrument extension** (~1 day given the host-agnostic engine): App Extension target, `AUAudioUnitFactory`, `ChromaNoiseAU: AUAudioUnit` whose `internalRenderBlock` calls `engine.render`; `AUParameterTree` with `band_00`…`band_31`, `master_volume`, `tremolo_period_seconds`, `tremolo_depth`, `bypass`; `fullState` serializes a Phonon snapshot; `requestViewController` returns a `UIHostingController` wrapping `EqualizerView`; Info.plist `NSExtension` + `AudioComponents` entry of type `aumu`. Footguns: host owns the audio session (never touch it from the AU); `fullState` may be set before `allocateRenderResources` (stage and apply); no Swift retain traffic in the render block.
- **Multi-phonon layering** — sum gain LUTs at the multiply step.
- **Spatial audio** via `AVAudioEnvironmentNode`.
- **App Intents / Siri / Shortcuts** — "start pink noise."
- **Live Activity / Dynamic Island** sleep-timer countdown.
- **Watch companion**; **video-with-audio import** for clone.

---

## Risks & Unknowns

- **COLA correctness**: Hann × Hann is COLA only at hop ≤ N/4; we use hop = N/4 = 1024. Unit-test the constant-sum property (±1e-5).
- **Render-thread Swift safety**: only `UnsafeMutablePointer<Float>` + `Unmanaged.passUnretained` in the render path; verify zero `swift_retain`/`malloc` with Instruments.
- **Constant-power divide-by-zero**: clamp denominator; all-zero spectrum = silence.
- **Sample-rate switches** (Bluetooth ~16 kHz): rebuild LUT + window on `AVAudioEngineConfigurationChange`.
- **AU-readiness discipline**: kit must not import `AVFoundation` — enforce with a CI grep test.
- **Clone correctness**: golden-file round-trip tests (white → flat, pink → −3 dB/oct, ±1.5 dB) are ship-blockers.
- **First-frame click**: pre-fill 2 hops of silence before unmuting.
- **Worker priority when backgrounded**: `qos: .userInteractive`; verify no underruns with screen locked.
- **CPU estimate unverified** (~2–3% iPhone 13 back-of-envelope); milestone-3 profile is the real check.
- **SwiftData**: require iOS 17.2+.

---

## Verification Plan

- **DSP** (XCTest): COLA constant-sum ±1e-5; FFT round-trip ±1e-5; single-band spectrum concentration; `Σ gain²` constant ±1%; pink/brown slope ±0.5 dB/oct; tremolo bypass exact at depth 0; WAV dump helpers for ear-checks.
- **Clone round-trip**: white/pink/brown synthetic WAVs → phonons within ±1.5 dB of theory; pure 1 kHz tone → flatness warning + band 17 maxed; 1 s clip → "too short"; silent file → "no audible content."
- **Realtime safety**: Instruments Time Profiler + System Trace on the render thread — zero retains/mallocs.
- **Background audio**: on-device, 30 min locked-screen playback; interruption resume.
- **Lock-screen controls**: physical device.
- **Battery/CPU**: Energy Log, < 3% CPU target on iPhone 13.
- **Subjective parity**: A/B against ChromaDoze on Android with matched spectra + converted tremolo settings.

---

## Research provenance (for future sessions)

Findings verified against upstream `pmarks-net/chromadoze` (read-once for understanding; no code copied):
- Upstream uses inverse DCT-II (JTransforms), chunk sizes 8192/65536, 4095-sample equal-power crossfade, flat band-to-bin fill, uniform XORShift randomization, per-chunk peak normalization, time-reversed right channel.
- Upstream `period` field = per-phonon tremolo LFO period slider (0–53 → 10 ms–60 s piecewise), paired with `minVol` depth; bypass at `minVol > 0.999`.
- AUv3 remains the current iOS plug-in API (2026); worker + SPSC ring is the canonical AU threading idiom; hosts call render with 32–4096 frames.
