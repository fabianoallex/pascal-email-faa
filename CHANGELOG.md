# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

## [Unreleased]

## [0.1.0] - unreleased

First version (`docs/design.md`, E1-E21; `docs/findings.md`, findings 1-8).

### Added

- The core (`pascal_email_faa`, on pascal-common-faa 1.32.0+): `IEmailMessage` with a fluent
  builder (`TEmailMessage.New`), `TEmailAddress` (`Create`, `Parse`), header-injection checks,
  `EmailBuildMime` (RFC 5322 / MIME: encoded-words, quoted-printable, Base64, RFC 2231 file
  names, mixed/related/alternative, lines within 76 characters, deterministic with an
  `IEmailIdSource`), `IEmailSender` with `Send` and `SendMany`, the error classes
  (`EEmailArgumentError`, `EEmailAuthError`, `EEmailRejected`, `EEmailTransient`,
  `EEmailOutcomeUnknown`) and `EmailIsRetryable`.
- `TMockEmailSender` (keeps messages and their MIME, `FailNext`) and `TFileEmailSender` (`.eml`
  files, written under a temporary name and renamed).
- The SMTP adapter (`pascal_email_faa_smtp`): `TSmtpSender` on pascal-common-faa's
  `PascalCommon.Transport` (STARTTLS through `PcTlsWrap`, implicit TLS, verified certificates,
  private CA), AUTH PLAIN, LOGIN and XOAUTH2 (`IEmailTokenProvider`), SIZE, partial recipient
  refusal reported in the result (`RequireAllRecipients` to refuse it), `SendMany` on one
  connection with `RSET` between messages.
- Tests: the unit suite (94; a scripted SMTP server, exact MIME bytes) and the integration suite
  (18; Mailpit v1.33.1 in Docker, three servers), DUnitX masters with generated FPCUnit mirrors;
  `tools/ci-test.sh` and the GitHub Actions workflow (FPC 3.2.2 on Linux).
