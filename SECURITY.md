# Security Policy — VorynOS

## Support Status

VorynOS is currently in **early development**, with no stable releases published and no guarantees of suitability for production environments.

| Version | Security Support |
| --- | --- |
| Development (`main`) | Reports are reviewed based on maintainer availability |
| Stable releases | No stable releases have been published |

This table describes a vulnerability triage policy, not a commitment to a specific remediation timeframe.

## Reporting a Vulnerability

**Do not disclose exploitation details, credentials, personal information, or unpatched vulnerabilities in public issues.**

Prefer the private **GitHub Security Advisories / Report a vulnerability** feature, **if enabled** for this repository. Check the project's *Security* tab.

If this feature is unavailable, open a public issue **without sensitive details** requesting a private communication channel. Do not include an exploitable proof of concept or confidential information in that issue.

When submitting a private vulnerability report, provide the following information whenever possible:

- Affected component and commit/version.
- Environment and architecture.
- Minimal reproduction steps.
- Observed and expected impact.
- Redacted logs containing no secrets.
- Potential mitigation measures.

## Vulnerability Handling

The maintainers will make reasonable efforts to confirm reported issues, assess their severity, develop appropriate fixes, and coordinate responsible disclosure.

**No service-level agreement (SLA) or guaranteed response or remediation timeframe is provided** at this stage of the project.

## Scope

Security reports involving the bootloader, kernel, memory management, isolation mechanisms, drivers, binary formats, parsers, and build pipeline are relevant to this project.

Issues affecting third-party services should be reported to their respective maintainers or service providers.

## Security Best Practices

Never share access tokens, private keys, or personal information in logs or vulnerability reports.

Security testing must only be conducted in environments that you own or are explicitly authorized to test.
