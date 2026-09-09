# Contributing to MonoOto

This English document is the canonical contribution guide. A Japanese translation is available in [CONTRIBUTING.ja.md](CONTRIBUTING.ja.md).

Thank you for helping improve MonoOto. The project is currently validating a small Stage A prototype for exploring whether distinct timbral cues can make the left- and right-channel origins of stereo material more distinguishable through one listening ear. It does not promise natural stereo perception, restored hearing, accurate localization, or medical benefit.

Before contributing, read [SPEC.md](SPEC.md) and [AGENTS.md](AGENTS.md). `SPEC.md` is the source of truth for product requirements and acceptance criteria. `AGENTS.md` defines the working practices and safety constraints for the repository.

## Scope and design principles

Keep changes small and tied to the current stage of the specification. Discuss substantial features, architectural changes, new dependencies, audio assets, or HRTF data in a GitHub issue before implementation. Stage B system-audio capture work should not proceed until the Stage A perceptual and engineering gates in `SPEC.md` justify it.

Preserve these boundaries:

- Keep UI, audio input/output, DSP, and evaluation-record responsibilities separate.
- Prefer Swift, SwiftUI, and Apple audio APIs. Introduce C or C++ only for a demonstrated need, such as a narrowly bounded real-time requirement.
- Keep DSP deterministic and independently testable offline. State parameter units, ranges, defaults, and update behavior.
- Do not add unnecessary services, cloud processing, plugin systems, accounts, privileged helpers, or broad dependencies.
- Process audio locally. Do not persist or transmit audio during normal use, and do not log audio content or full file paths.

Scientific evidence, engineering hypotheses, and measured results must be described separately. Do not present timbral-cue discrimination as proof of spatial stereo perception. Do not make claims about diagnosis, treatment, hearing recovery, safe sound-pressure levels, or effectiveness without evidence that directly supports the exact claim and population.

## Development workflow

1. Check existing issues and open one when the intended behavior, scope, or design needs agreement.
2. Create a focused branch from the current default branch.
3. Add a meaningful regression test before a behavior-changing fix or feature.
4. Implement the smallest change that satisfies the accepted requirement.
5. Review the complete data path and failure paths, including silence, excessive input, NaN/Inf, channel reversal, antiphase audio, device loss, permission denial, stopping, and stale asynchronous work where applicable.
6. Run the relevant automated checks and record any required hardware checks that were not performed.
7. Open a pull request that explains the problem, resulting behavior, validation performed, and remaining limitations.

Avoid mixing unrelated cleanup with functional work. Preserve user-owned or concurrent changes, and update documentation when behavior or constraints change.

## Building and testing

The package and shared Xcode scheme use these standard commands:

```sh
swift test
xcodebuild -project MonoOto.xcodeproj \
  -scheme MonoOto \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Run focused tests while developing, followed by the complete relevant suite before requesting review. A passing unit test suite does not establish device routing, audible behavior, timing, or perceptual effectiveness. Record hardware model, macOS version, sample rate, buffer size, and test conditions for real-device checks. If a build, listening test, or hardware test was not run, label it as unverified rather than inferring success from source inspection or an earlier run.

For DSP changes, include deterministic coverage for the applicable invariants in `SPEC.md`, such as mono equivalence, identical-channel behavior, channel-sign behavior, antiphase cancellation, smoothing, finite output, and the final peak ceiling. Use synthetic, self-created, or appropriately licensed test material.

## Real-time audio requirements

Audio render callbacks must not allocate or free memory, wait on locks, perform file or network I/O, write logs, update UI, create tasks, or trigger ARC releases. Preallocate bounded buffers and audit implicit array copies and object lifetimes. Pass control information across the callback boundary using a bounded, real-time-safe mechanism.

Treat malformed buffers, graph failures, and NaN/Inf as fail-silent conditions and notify the control side to stop. All playback and comparison paths must pass through the final gain and peak limiter. The unselected output channel must remain zero, and loss of the selected device must stop playback rather than silently switching to another output.

Changes to render-path code require both source-level real-time safety review and appropriate profiling on supported hardware. Release-build inspection alone is not a substitute for runtime measurement.

## Local analysis artifacts

Keep `graphify-out/` and `.ai-collab/` out of commits: they contain generated graphs, caches, machine-specific paths, and review runtime state. They are currently untracked local artifacts, not ignored repository paths; stage intended files explicitly. The reusable scripts under `docs/verification/` are tracked verification sources.

## Documentation and translations

English public project documents are canonical. Japanese translations use the matching `.ja.md` filename. When changing an English document, update its Japanese translation in the same pull request, or clearly mark the translation as temporarily out of date and open a tracked follow-up. Keep links between each canonical document and its translation prominent.

Do not translate normative license text as though the translation had legal effect. The English `LICENSE` file controls; localized license notes must identify themselves as informational only.

## Pull requests

A pull request should contain:

- A concise description of the problem and the new behavior.
- The relevant requirement or issue.
- Automated checks run, with their exact outcomes.
- Manual, hardware, accessibility, and listening checks run, with conditions.
- Tests or checks that remain unverified and why.
- User-visible, safety, privacy, performance, or compatibility effects.

Screenshots are useful for UI changes, but they do not replace VoiceOver and keyboard checks. Do not include private audio, personal hearing information, full local paths, device UIDs, credentials, or other sensitive data in issues, test logs, screenshots, or pull requests.

## Contribution license

This project is licensed under the Apache License, Version 2.0. Unless you explicitly state otherwise, an intentional contribution submitted for inclusion in the project is licensed under the same license, as described in Section 5 of the Apache License. You must have the right to submit it. Identify third-party code, data, media, or other material and preserve all required notices and license terms. Do not submit material whose license is unknown or incompatible with the project.

Participation in the project is also governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
