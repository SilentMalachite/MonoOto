# Security Policy

English is the canonical language for this document. For a Japanese translation, see [SECURITY.ja.md](SECURITY.ja.md).

## Supported versions

MonoOto is an early-stage project and has no stable release. Security fixes are applied only to the latest revision of the `main` branch. Fixes are not backported to older commits or forks.

## Reporting a vulnerability

Please avoid disclosing a vulnerability or sensitive reproduction details in a public issue.

1. Open the repository's **Security** tab and use **Report a vulnerability** if private vulnerability reporting is enabled.
2. If that option is unavailable, open a minimal public issue titled `[Security] Request a private reporting channel`. Include only a high-level description of the affected area. Do not include exploit details, secrets, personal information, audio content, or local file paths. A maintainer can then arrange a private path using the available GitHub facilities.

There is currently no dedicated security email address. Please do not send sensitive reports to an address inferred from commit metadata or contributor profiles.

When a private channel is available, include:

- the affected commit or branch;
- the macOS version and relevant hardware or audio device, when applicable;
- the security impact and who could be affected;
- the smallest reliable reproduction steps;
- any known mitigation; and
- logs or attachments only after removing secrets, personal information, audio content, and full local paths.

Please allow maintainers time to reproduce, assess, and fix the issue before public disclosure. Because the project has no formal response team or service-level agreement, response and remediation times are not guaranteed.

## Safety and privacy reports

A software dBFS limit does not guarantee a safe sound pressure level at the ear. Stop playback if you experience pain, ringing, discomfort, or fatigue. Do not use a security report for medical advice or an emergency; contact appropriate local emergency or medical services.

For abuse involving GitHub accounts, repositories, or platform content, use [GitHub Support or the GitHub abuse-reporting facilities](https://support.github.com/).
