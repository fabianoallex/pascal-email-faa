# Gotchas

Numbered (symptom → cause → fix), never renumbered; references elsewhere ("gotcha 1") point here.
General Delphi × FPC divergences are in the `dual-compiler-delphi-lazarus` skill's
`references/rtl-gotchas.md`; this file keeps what this repository met.

1. **An interface created in the call leaked when a constructor raised.** Symptom: one block of
   40 bytes unfreed under heaptrc after `TSmtpSender.Create(Options, Connector,
   TCountingIdSource.Create)` with options the constructor refuses. Cause: an object passed to a
   `const` interface parameter has no reference until someone stores it; the constructor raised
   before `FIds := AIds`, so nobody ever released it (Delphi behaves the same). Fix: every
   constructor and `EmailBuildMime` store their interface parameters first, before any check that
   can raise (`TSmtpSender.Create`, `TFileEmailSender.Create`, `EmailBuildMime`). Keep that
   order in new code.

2. **`StringOfChar('á', N)` doesn't compile on FPC.** In `{$MODE DELPHI}` on FPC an accented
   literal in a UTF-8 source is a two-byte string, not a `Char`. Tests use `RepeatText`
   (`PascalEmail.TestSupport`).

3. **A shell heredoc ate the backslashes of a Windows path** (tooling, not the library): a Python
   snippet written through the agent's shell turned `..\adapters` into `..` + BEL + `dapters`
   (`\a`) in a generated `.lpk`, and lazbuild then didn't find the unit. Write generated files
   with a real file (or forward slashes and `chr(92)`), and grep generated project files for
   control characters.

4. **`GetTempDir` doesn't exist on Delphi.** Symptom: `E2003 Undeclared identifier: 'GetTempDir'`
   building the Delphi unit suite (FPC built it fine). Cause: it is FPC's SysUtils only. Fix:
   `TempFolder` in `PascalEmail.TestSupport`, `TPath.GetTempPath` (`System.IOUtils`) on Delphi.
