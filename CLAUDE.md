# pascal-email-faa — Guide for AI agents

A **dual-compiler** (Delphi + Lazarus/FPC) e-mail sending contract: a message with a fluent
builder, one RFC 5322/MIME writer, senders whose exceptions say whether a retry can help; an SMTP
adapter on pascal-common-faa's TLS transport, an in-memory mock and an `.eml` file sender.

For the general dual-compiler rules (project anatomy, `.inc`, mirrored tests, CI), use the
`dual-compiler-delphi-lazarus` skill; for consuming the other `*-faa` libraries, the
`using-faa-libraries` skill. Both live in
[pascal-skills-faa](https://github.com/fabianoallex/pascal-skills-faa) (a Claude Code plugin);
if they aren't loaded, ask the user to install it: `/plugin marketplace add
fabianoallex/pascal-skills-faa`, then `/plugin install pascal-skills-faa@pascal-skills-faa`.
This file records only what is specific to this repository.

---

## Where things stand (2026-11-12)

- **0.1.0, not released** (first commit 2026-11-12). Core, mock, file
  sender, the SMTP adapter and the decorators (redirect, allowlist; design section 11). Unit
  112/112 and integration 18/18, 0 leaks, on FPC 3.2.2 Windows
  (SChannel and OpenSSL) and Linux (Docker, OpenSSL 3), and on Delphi 12 Win32 and Win64 (the
  user built both suites in the IDE; the `.exe` were run from here, 2026-11-12).
- **Decisions**: `docs/design.md` (E1-E25, accepted 2026-11-12; Q1-Q7 closed with the
  proposals). **What servers and parsers did**: `docs/findings.md`, numbered; the design cites
  "finding N". Read both before changing the contract.
- **Depends on pascal-common-faa 1.32.0** (`PcBase64Encode`/`PcBase64Decode`, added for this
  library; `$MESSAGE FATAL` in `PascalEmail.Smtp`, `MinVersion` in both `.lpk`). It is a **git
  submodule in `external/pascal-common-faa`, for tests, CI and samples only**: the application
  provides the single copy. The packages require `pascal_common_faa` by name, with no
  `DefaultFilename`; the test `.lpi` files point at the submodule's `.lpk` with `Prefer="True"`;
  the Delphi projects add `external/pascal-common-faa/src` to the search path. Checkout without
  `--recursive` (pascal-common-faa's own submodules are for its tests).
- **Next** (design Q1): one HTTP provider to validate the contract (Amazon SES v2 leads: SigV4
  is pascal-common-faa's SHA-256/HMAC, and it takes the raw MIME), as its own package on
  `PascalCommon.Http`; then the outbox bridge (design E11, pascal-db-faa's `TOutboxLocalSink`,
  its own package); then an entry in the skill's `faa-libraries.md` once a version is published.

---

## Language

Everything in this repository is in **English**: code, identifiers, comments, runtime messages,
test names and assertion messages, documentation and commit messages. Test *data* has accents
and emoji on purpose (`'João Conceição'`, `'Relatório — março'`).

---

## Code rules (every unit in `src/` and `adapters/`)

- **Each adapter is its own package** (`adapters/<engine>/`, `pascal_email_faa_<engine>.lpk`);
  the core knows no engine and no network.
- **Every `.pas`/`.dpr`/`.lpr` is UTF-8 with a BOM** (a file written by a tool has none: add
  it). Delphi reads a file without one as ANSI and garbles accented literals.
- **`{$I pascalemail.inc}` right after `unit ...;`**: `{$MODE DELPHI}{$H+}` on FPC,
  `PASCALEMAIL_WINDOWS`, `PASCALEMAIL_FUNCREFS` (`reference to` on Delphi, `of object` on FPC,
  for any public callback).
- **Prefixes**: units `PascalEmail.*`, types `TEmail*`/`IEmail*`/`EEmail*` (SMTP: `TSmtp*`,
  `ISmtp*`), free functions `Email*`.
- **`uses` without namespaces**; **no anonymous methods**; atomics and monotonic time only
  through `PascalCommon.Threading`; the clock through `TClock` (`EmailUtcNow`).
- **Store interface parameters before anything can raise** (gotcha 1): a `TFoo.Create` passed
  to a `const` interface parameter leaks if the callee raises before keeping it.
- **Every value that reaches a header is checked when it enters the message** (`EmailCheckHeaderText`,
  `TEmailAddress.Create`): no CR, LF or other control character. Never add a path that writes
  caller text into a header without it.
- **The MIME writer's output is 7-bit ASCII, CRLF, lines within 76** (design E5, E17); its unit
  tests compare exact bytes. A change to the output changes those tests on purpose, and must be
  checked again with `.ci/probe-smtp/check.py` (Python's `email` package) and the integration
  suite (Mailpit's parser).
- **Error classes are the contract** (design E8, E13): an adapter maps every failure onto one
  of the five; the outbox bridge and applications decide retries by class.
- **Top-of-file comment in every unit, program and test** (plain prose, no banners). If it
  quotes a `}`, use `(* ... *)`.

---

## Tests

- DUnitX masters in `tests/Unit/*Tests.pas` and `tests/Integration/*Tests.pas`, in FPCUnit's
  assertion dialect (through `PascalEmail.DUnitXCompat`); the FPCUnit mirrors in `*/fpc` are
  **generated** by `python tools/gen_fpc_mirror.py`: never edit them. The generator and the
  compat unit are the skill's canonical test kit, unchanged (`check_test_kit.py` in the skill).
  `PascalEmail.TestSupport` (tests/Unit) and `PascalEmail.IntegrationEnv` are not test units:
  both runners use the same file.
- **Unit**: `TFakeSmtpServer` (TestSupport) is an `ISmtpConnector` that answers with queued
  replies and records what the client wrote; `TCountingIdSource` makes MIME output exact.
  Exceptions: `try ... TAssert.Fail(...) except on E: EClass do ... end`.
- **Integration**: Mailpit v1.33.1 three ways (`sh tools/mailpit.sh`: STARTTLS on 12587, implicit
  TLS on 12465, plain on 12525; APIs on 18025-18027; CA in `.ci/it-certs`; AUTH `it-user` /
  `it-pass`; only `@example.com` recipients accepted on the TLS ones). Each test clears the three
  servers and reads its messages back from the API.
- Runs: `sh tools/test_fpc.sh` (unit, lazbuild, Windows), `sh tools/test_fpc.sh integration`
  (needs `sh tools/mailpit.sh` first), `sh tools/test_fpc_docker.sh` (unit, Linux),
  `sh tools/test_integration_docker.sh` (integration, Linux; starts and removes Mailpit),
  `sh tools/ci-test.sh` (what CI runs). Delphi: the user builds both `.dproj` in the IDE (Delphi
  CE has no command-line compiler: `dcc32` prints a refusal and exits 0) and runs the `.exe`.
  Criterion: all green, 0 leaks, on both.
- `python ../skills/dual-compiler-delphi-lazarus/scripts/verify_test_mirrors.py --root .
  --ignore-glob /lib/` is a second, independent check of the mirrors.
- New `.dproj` go into `PascalEmail.groupproj`, new `.lpi` into `PascalEmail.lpg`.

---

## Docker

Pinned: `axllent/mailpit:v1.33.1`. Probes go in `.ci/probe-*` (git-ignored); their findings get a
numbered entry in `docs/findings.md`. Don't restart the user's stopped containers; create your
own with their own names and remove them at the end (`tools/mailpit.sh` uses `pascalemail-it-*`
and the network `pascalemail-it-net`).

## Gotchas

Numbered in [`docs/gotchas.md`](docs/gotchas.md); add new ones there, keeping the numbering.

Ask before committing or pushing.
