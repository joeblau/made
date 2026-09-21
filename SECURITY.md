# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's
[private vulnerability reporting form](https://github.com/joeblau/made/security/advisories/new)
so the report, proof of concept, and remediation discussion remain private.

Include the affected app or service, tested revision, platform/toolchain
version, reproduction steps, impact, and any proposed mitigation. Avoid placing
real credentials, pairing keys, private user data, or destructive payloads in
the report; use clearly synthetic test material.

Maintainers will acknowledge the report in the private advisory, coordinate a
fix and disclosure timeline, and credit the reporter if desired. There is no
bug-bounty promise.

## Supported version

Security fixes target the current `main` branch and the currently deployed Web
and rendezvous services. Older source revisions and locally modified builds are
not separately supported.
