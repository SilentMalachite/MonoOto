<!-- English is canonical. Japanese template: .github/PULL_REQUEST_TEMPLATE/ja.md -->

## Summary

<!-- Describe the concrete problem and the resulting behavior. -->

## Changes

<!-- List the smallest set of material changes. -->

## Validation

<!-- List commands and hands-on checks actually performed, with their results. -->

- [ ] `swift test`
- [ ] `xcodebuild -project MonoOto.xcodeproj -scheme MonoOto -destination 'platform=macOS' test`
- [ ] Relevant device or listening checks were performed and documented

Not run or not verified:

<!-- State why each relevant check was not run. Do not treat static inspection as an executed test. -->

## Safety, privacy, and scope

- [ ] Playback still requires an explicit user action and starts at a low application gain.
- [ ] Every affected audio path still uses the final gain, peak limiter, and unselected-channel zeroing required by `SPEC.md`.
- [ ] Device loss, invalid data, and audio-graph failures fail silent and stop where applicable.
- [ ] Real-time callbacks do not allocate, block, perform I/O, log, update UI, or create tasks.
- [ ] The change does not store, transmit, or log audio content, personal data, or full local file paths.
- [ ] User-facing claims distinguish engineering hypotheses, measured results, and medical or hearing outcomes.
- [ ] Items that do not apply are explained below.

## Documentation and compatibility

- [ ] User-facing behavior is reflected in the canonical English documentation when needed.
- [ ] Relevant requirements and verification records are updated when needed.
- [ ] The Japanese translation is updated when the corresponding English document changes.
- [ ] Compatibility or migration effects are documented.

## Related issue

<!-- Example: Closes #123 -->
