# MonoOto

[日本語](README.ja.md)

MonoOto is an experimental macOS audio project exploring whether timbral cues can help a person listening through one ear distinguish information derived from the left and right channels of stereo music.

The project does not claim to restore binaural hearing, reproduce natural stereo localization, improve hearing, or guarantee a safe sound pressure level. A successful channel-identification experiment would demonstrate use of an artificial cue, not natural spatial hearing.

## Project status

MonoOto is an early Stage A engineering prototype. It is not a finished music player and has no published release.

Implemented so far:

- deterministic offline stereo-to-mono cue encoding;
- common gain and a look-ahead peak limiter;
- WAV and AIFF validation, decoding, and sample-rate conversion;
- generation-based playback state management;
- explicit Core Audio output-device selection and a silent output-path host;
- automated Swift Package and Xcode tests.

Still incomplete:

- the bounded real-time queue and file-playback controller;
- normal playback, pause, seek, ear selection, and listening-comparison UI;
- hardware verification of device pinning, disconnect handling, callback shutdown, and macOS 14.2;
- perceptual evaluation with the intended listener.

The current app host outputs silence only. Selecting a device does not start the audio graph; starting the silent path requires a separate explicit action.

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

Opening `MonoOto.xcodeproj` in Xcode provides the silent output-device test host. Do not treat a successful build or mocked test as proof that a physical device is pinned or stopped on disconnect.

## Repository layout

- `App/` — the minimal SwiftUI host for selecting and testing an output device with silence.
- `Sources/MonoOtoCore/` — deterministic DSP, output limiting, and file processing.
- `Sources/MonoOtoAudio/` — Core Audio output-device and lifecycle boundary.
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
