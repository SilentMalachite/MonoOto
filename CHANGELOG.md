# Changelog

[日本語](CHANGELOG.ja.md)

English is the canonical language for this changelog. All notable changes to MonoOto will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). MonoOto has not published a stable release, so all current work remains under `Unreleased`.

## [Unreleased]

### Added

- Deterministic stereo-to-mono cue encoder with cancellation diagnostics.
- Common gain ramp and look-ahead output limiter with a −3 dBFS ceiling.
- WAV and AIFF validation, decoding, conversion, and bounded reads.
- Generation-based playback-state handling that rejects stale completions.
- Explicit Core Audio output-device discovery, pinning, format readback, silent rendering, and change monitoring.
- SwiftUI host for listing and selecting supported output devices and explicitly starting a silent route test.
- Swift Package and shared Xcode scheme tests for DSP, file handling, state, and the output boundary.
- Engineering verification log that separates automated results from unverified hardware behavior.
- English canonical and Japanese-translated public project documentation.

### Fixed

- Preserve readable output devices when another device fails property inspection.
- Stop and dispose the output backend after device, route, format, sleep, or render-fault notifications.
- Clear stale callback diagnostics when a new preparation attempt begins.
- Prevent unsupported channel counts and sample rates from being selected for the Stage A route test.

[Unreleased]: https://github.com/SilentMalachite/MonoOto/commits/main
