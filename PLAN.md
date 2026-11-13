# ChromaNoise — Plan

What is left to build and to check. How the shipped app works is in the
code, `CLAUDE.md` and `Packages/ChromaNoiseKit/README.md`; how it got there
is in git history (the original design document was this file, up to
November 2026).

## Status (2026-11-10)

Shipped in 1.0 (TestFlight build 51): the 32-band painter, built-in and
saved sounds, swell (tremolo), sleep timer, background playback with
lock-screen controls and artwork, interruption and route handling, App
Intents (Play, Pause, Sleep Timer), iPhone landscape and iPad layouts.

New in build 51 (since 46), so not yet checked on a device:

- Saved sounds load with the bars they were painted with (only built-ins
  are scaled to fill the painter).
- The ring lead grows with the output rate above 48 kHz.
- Turning swell on keeps a period the user chose, however fast.
- The play button shows Pause as soon as a start is under way.

**Not started**: clone file ingestion and UI (the kit's analysis half is
done and tested), ChromaDoze preset import.

## Open

- Marketing page at abelify.com/chromanoise (Ryan's portfolio site), then
  set it as the listing's marketing URL; the URL there now is a 404.
- App Store promotional text (optional, editable without review).
- iPhone Duo inner-display screenshots: duoctl's hinge helper is killed at
  launch (exit 137) since Nov 13, so only the cover display is shot.

- Unplugging while playing: `.configurationChanged` restarts the engine at
  once and `.oldDeviceUnavailable` arrives separately, so a restart on the
  speaker may be audible before the stop.
- Saved sounds: `context.save()` errors are dropped; a store that fails
  to open is a `fatalError` at launch.
- The built-in sound-alikes (Ocean, Rain, Fan, Cabin) are first guesses,
  to be tuned by ear.
- CI runs on Xcode 16, which compiles only the fallback session activation,
  not the iOS 27 asynchronous one the app ships with.

## Device checks

None of these can be done in the simulator.

- Locked screen for 30 min with no underruns logged after the first start
  (subsystem = bundle ID, category `audio`, logged at every engine stop).
- The sleep fade curve, by ear.
- A 96 kHz DAC, if one is to hand: every band audible, and no underruns
  with the screen locked (the ring assumes the pull grows with the rate, to
  8192 frames at 96 kHz; that size is a guess).
- A media-services reset (Settings > Developer > Reset Media Services):
  the code path compiles but has never run.
- Siri with the App Intents.
- Stage Manager / Split View window resizing on iPad.
- CPU and energy: Instruments on the render thread (no retains or mallocs),
  Energy Log, under 3% CPU on an iPhone 13. The worker's half-hop idle
  sleep has not been measured for energy.

## Audio clone

The planned differentiator: the user picks an audio file, we analyze its
long-term spectrum and save a sound that approximates it. Entirely
on-device.

### Analysis (built: `Analysis/` in the kit)

- **Welch's method**: N = 16384 (~2.93 Hz/bin @ 48 kHz), periodic Hann, 50%
  hop (independent frames matter more than reconstruction here).
  Accumulate `|X[k]|²`, divide by frame count and window power.
- **Band aggregation**: mean of bin powers over each band (mean, not sum,
  which would favor the wider high bands), then the square root.
- **Slider inversion**: `v[i] = clamp((log10(A_band[i]/A_ref) + 3) / 3, 0, 1)`.
- **Normalization**: peak-anchored, `A_ref = max(A_band) / 0.85`; bands
  more than 60 dB below the peak go to 0.
- **Equal-loudness compensation**: off (the user already heard the source
  through their own ears).
- **Tonal guard**: spectral flatness (Wiener entropy) below 0.05 is a soft
  warning ("captures timbre, not tone"), not a rejection.
- **Silence guard**: reject below −60 dBFS RMS. **Minimum length**: 3 s.

### Ingestion (to build, in the app target: it needs `AVAudioFile`)

- `.fileImporter(allowedContentTypes: [.audio])` with security-scoped
  resource access.
- `AVAudioFile` decodes wav/aiff/caf/m4a/mp3/ALAC/FLAC; chunked reads into
  Float32 non-interleaved `AVAudioPCMBuffer`.
- Mono-sum `(L+R) * 0.5` before analysis.
- Cap at 120 s: a centered slice, trimming 5% from head and tail.
- Bin-to-Hz mapping uses the file's own sample rate; no resampling.
- DRM files: surface the error; don't work around it.

### UX (to build)

1. **+ → Clone a sound** → file picker.
2. Analysis sheet: name, duration, cancelable progress.
3. Dual spectrum view: the source PSD as a continuous curve above our 32
   bars animating in, so the lossy quantization is visible.
4. Auto-name from the filename stem; editable.
5. Audition live before saving.
6. Tonal-warning banner when applicable.

### Verification

Round-trip tests are ship-blockers: synthetic white/pink/brown → sounds
within ±1.5 dB of theory (white and pink are covered by
`CloneRoundTripTests`); a pure 1 kHz tone → flatness warning and band 17
maxed; a 1 s clip → "too short"; a silent file → "no audible content".

## ChromaDoze preset import

Not started. A ChromaDoze preset's `period` field is a tremolo slider slot
(0–53 → 10 ms–60 s, piecewise), paired with `minVol` for depth
(`depth = 1 − minVol`, bypassed above 0.999).
`Phonon.legacyPeriodSeconds(slot:)` already holds the slot mapping. Clean
reimplementation only: no upstream (GPL-3.0) code.

## Later

- **AUv3 instrument extension**: the kit is host-agnostic for this. An App
  Extension target with an `AUAudioUnit` whose `internalRenderBlock` calls
  `NoiseEngine.render`; an `AUParameterTree` with `band_00`…`band_31`,
  `master_volume`, `tremolo_period_seconds`, `tremolo_depth`, `bypass`;
  `fullState` serializes a `Phonon`; the view wraps `EqualizerView`;
  Info.plist `AudioComponents` entry of type `aumu`. Footguns: the host
  owns the audio session (never touch it from the AU); `fullState` may be
  set before `allocateRenderResources` (stage and apply); no Swift retain
  traffic in the render block.
- **"Play alongside other audio" toggle**: a mixable session, at the cost
  of lock-screen controls (a mixable session can't be the Now Playing app).
- **Multi-sound layering**: sum gain LUTs at the multiply step.
- **Spatial audio** via `AVAudioEnvironmentNode`.
- **Live Activity / Dynamic Island** sleep-timer countdown.
- **Watch companion**; **video-with-audio import** for clone
  (`AVAssetReader`).
- **Visualizer** (idea stage). A literal noise waveform is dull; show the
  sound's *shape*. Steps: (1) a "breathing" 32-band view of live energy
  (moves with swell and the sleep fade); (2) a spectral waterfall, one row
  per frame, colored with the band palette, as the large-screen
  centerpiece; (3) maybe a generative "aurora". Side-by-side on iPad and
  the foldable inner display, full-screen ambient mode on phones.
  Constraints: no extra FFT (the worker already has each hop's spectrum, so
  publish a 32-band snapshot through a lock-free handoff; render-thread
  rule and host-agnostic kit unchanged); sleep-appropriate (dim, slow,
  black background, capped frame rate, auto-dim). Prior art to study
  (check licenses; clean-room): barbulescualex/MetalAudioVisualizer,
  hotpaw2's MyMetalWaterfall gist, sandner-art/Audio-Shader-Studio (MIT),
  Keith-43/MuVis.
- **Subjective A/B** against ChromaDoze on Android with matched spectra.
