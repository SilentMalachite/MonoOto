# MonoOto

[日本語](README.ja.md)

MonoOto is an experimental macOS audio project exploring whether timbral cues can help a person listening through one ear distinguish information derived from the left and right channels of stereo music.

The project does not claim to restore binaural hearing, reproduce natural stereo localization, improve hearing, or guarantee a safe sound pressure level. A successful channel-identification experiment would demonstrate use of an artificial cue, not natural spatial hearing.

## Project status

MonoOto is an early Stage A engineering prototype. It is not a finished music player and has no published release.

Implemented so far:

- deterministic stereo-to-mono encoding, common gain, SRC, and a final look-ahead limiter;
- WAV/AIFF validation and bounded worker-side processing;
- a C11 frame queue and AudioBufferList render boundary;
- explicit device/ear selection, file playback, retained-state pause, stop, and seek;
- a short in-memory confirmation tone through the same processing path;
- a minimal SwiftUI host and automated lifecycle/PCM tests.

As of 2026-09-11, Task 6 playback integration is implemented. The app starts stopped; opening a file or changing its output never starts playback. Play and the confirmation tone require an explicit action and a selected device and ear. Pause retains the pipeline and queued PCM; stop and seek discard the old session.

Task 6 is **not fully accepted**. Physical stop/pause/EOF continuity, disconnect/sleep behavior on the integrated audio path, a 60-minute device playback run, and the full callback allocation/lifetime profile remain unverified. macOS 14.2 hardware coverage and perceptual evaluation also remain open. The earlier Task 5 C-queue load test does not substitute for these checks. See the [verification log](docs/verification/stage-a.md) for current commands, results, and evidence limits. The finished settings UI and evaluation features remain later tasks.

## Requirements

- macOS 14.2 or later as the initial deployment target;
- Apple Silicon for the initial hardware-validation scope;
- a Swift 6 toolchain and Xcode for the macOS app host.

The latest recorded automated verification used macOS 26.6.2, Xcode 26.6, and Swift 6.3.3. That result is not evidence that every supported OS and device combination works.

## Build and test

Run the package tests:

```sh
swift test
```

Build and test the shared Xcode scheme:

```sh
xcodebuild \
  -project MonoOto.xcodeproj \
  -scheme MonoOto \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Opening `MonoOto.xcodeproj` in Xcode provides the minimal playback host. Do not treat a successful build or mocked test as proof that a physical device is pinned or stopped on disconnect.

Playback owners should call `stop()` and then await `waitUntilSettled()` when their use ends. Stop closes the audio gate immediately; processing resources remain owned until producer and render ownership have ended. A last release off the main thread dispatches output teardown to MainActor. A blocked MainActor or hardware shutdown is not an immediate physical-silence guarantee.

## Repository layout

- `App/` — the minimal SwiftUI playback host.
- `Sources/MonoOtoCore/` — deterministic DSP, output limiting, and file processing.
- `Sources/MonoOtoAudio/` — Core Audio output, playback controller, and bounded file worker.
- `Sources/MonoOtoRealtime/` — C11 queue and render boundary.
- `Tests/` — offline DSP, file pipeline, playback state, and output-boundary tests.
- `SPEC.md` — current Japanese product and evaluation specification.
- `docs/superpowers/plans/` — implementation plan and task gates.
- `docs/verification/` — executed checks and explicitly unverified conditions.

## Safety and scope

- Keep the application and operating-system volume low when hardware testing begins.
- A digital dBFS ceiling does not limit acoustic dB SPL at the ear.
- Stop immediately if listening causes discomfort, pain, tinnitus, or fatigue.
- Do not use MonoOto for diagnosis, hearing assessment, hearing-aid adjustment, cochlear-implant adjustment, or emergency-sound detection.
- Do not describe timbral-cue discrimination as proof of stereo localization.

MonoOto processes audio locally. The current implementation does not transmit audio, save ordinary playback audio, or require an account or cloud service.

## Documentation languages

English public documents are canonical. Files ending in `.ja.md` and Japanese GitHub templates are translations provided for convenience. When the versions disagree, use the English document and open an issue or pull request to update the translation.

The current product specification, implementation plan, and engineering verification log were written in Japanese during the initial exploration. They remain the development contracts until a separately reviewed canonical migration is approved.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) before proposing changes and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) when participating in the project. Report suspected vulnerabilities according to [SECURITY.md](SECURITY.md); do not publish sensitive exploit details in a public issue.

Notable changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## License

Licensed under the [Apache License 2.0](LICENSE). The [Japanese license guide](LICENSE.ja.md) is non-authoritative and does not replace the English license text.
