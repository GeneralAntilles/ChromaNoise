# ChromaNoise

iOS spectrum-shaped noise generator (clean-room take on Android's ChromaDoze).
`PLAN.md` is the design doc and holds the current status and milestone list —
read its Status section first.

## Layout

- `Packages/ChromaNoiseKit/` — host-agnostic DSP engine (SPM). No AVFoundation,
  ever (enforced by `HostAgnosticismTests`) so it can drop into an AUv3 later.
- `Audio/`, `App/`, `UI/` — the iOS app target. `StandaloneAudioHost` is the
  only place that touches `AVAudioSession` / `AVAudioEngine`.
- `tools/reference_dsp.py` — numpy golden reference for the DSP. If Swift and
  Python disagree, Python wins until proven otherwise.
- `project.yml` — XcodeGen spec. `ChromaNoise.xcodeproj` is generated and
  gitignored: edit `project.yml`, then rerun `xcodegen`.

## Commands (macOS)

```sh
brew install xcodegen                 # once
xcodegen                              # (re)generate ChromaNoise.xcodeproj
open ChromaNoise.xcodeproj

# App build, no signing needed for the simulator
xcodebuild build -project ChromaNoise.xcodeproj -scheme ChromaNoise \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO

# Kit tests (fast; release because the synthesis tests push ~1000 FFTs)
(cd Packages/ChromaNoiseKit && swift test -c release)

python3 tools/reference_dsp.py        # needs numpy
```

The kit also builds and tests on Linux (CI does this in `swift:6.1-noble`).

## Rules that matter

- **Render thread**: `NoiseEngine.render` is the only thing an
  `AVAudioSourceNode` block may call — no allocation, locks, logging, or Swift
  retain traffic there.
- **Engine lifecycle**: stop `AVAudioEngine` *before* `NoiseEngine.prepare` /
  `teardown` (the render path reads the ring unretained).
- Parameters (`setBandGains`, `setMasterVolume`, `setTremolo`) are safe from
  any thread; the worker applies them at the next hop.
- On-device checks (background playback with the screen locked, lock-screen
  controls, audible clicks) can't be verified in the simulator — call them out
  for a human to test rather than claiming them.
