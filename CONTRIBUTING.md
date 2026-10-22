# Contributing to VorynOS

Thank you for your interest in contributing. VorynOS is an early-stage open-source project focused on original, verifiable, and efficient implementations.

## Before You Start

1. Review existing issues and discussions to avoid duplicate work.
2. Describe the problem and expected outcome before making extensive architectural changes.
3. Keep each contribution small and focused.
4. Do not introduce runtime dependencies without justifying their cost, licensing, security, and maintenance implications.

## Coding Guidelines

- Prefer Zig (target version 0.17.0); use C23 and Assembly only when justified.
- Verify APIs against the actual toolchain. Do not assume compatibility between Zig versions.
- Handle errors explicitly, validate bounds, and avoid undefined behavior.
- Document invariants, ABI contracts, and significant design decisions.
- Include tests and reproduction instructions whenever possible.
- Do not claim successful builds or execution without evidence.

## Licensing, Authorship, and Provenance

- By contributing original code to areas covered by the project's primary license, you agree to make it available under **GPL-3.0-only**, unless explicitly agreed otherwise.
- Add `SPDX-License-Identifier: GPL-3.0-only` to new original source files when applicable.
- Preserve third-party copyright notices and licenses.
- Submit only content you have the right to license.
- Disclose external dependencies, their licenses, and the provenance of incorporated code.
- If you use AI to assist with a contribution, review the output, verify the provenance of incorporated content, and take technical responsibility for the submitted code.
- Do not assume that contributing transfers copyright to the maintainer; **no automatic copyright-assignment CLA** is established here.

## Pull Requests

Include:

- The objective and rationale.
- Affected files and interfaces.
- Build and test commands actually executed, along with their results.
- Known limitations, risks, and potential incompatibilities.

Changes involving the kernel, MMU, interrupts, boot process, ABI, drivers, parsers, or security require human review before integration.

## Conduct and Security

Keep technical discussions respectful. For vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening a public issue containing exploitable details.

## Trademarks and Branding

Forks and redistribution are permitted under the applicable license. Do not present modified versions as official VorynOS releases or imply endorsement where none exists.
