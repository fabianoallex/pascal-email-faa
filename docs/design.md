# pascal-email-faa: contract design (2026-11-12)

Status: **accepted 2026-11-12, with the proposed answers to every open question** (section 9).
Core, mock, file sender and the SMTP adapter implemented the same day; section 10 lists what the
implementation settled. Telemetry (section 13) accepted and implemented 2026-11-13. The probe of section 8 ran against Mailpit; "finding N" points to
[`findings.md`](findings.md). Every decision is numbered (E1...).

## 1. Scope

A contract for sending e-mail that behaves the same on Delphi 12 and FPC 3.2.2, one adapter per
final engine, and an in-memory mock:

- **In the contract**: a message (sender, recipients, Reply-To, subject, text and HTML bodies,
  attachments, inline images referenced by `cid:`, custom headers, Message-ID, date, tags and
  metadata for engines that have them); one RFC 5322 / MIME writer; sending one message, and
  several through one connection; errors classified as permanent, transient or of unknown
  outcome, so a caller (or the outbox) knows whether to retry.
- **Through the adapter's native access**: provider features with no common ground (SendGrid
  categories and ASM groups, SES configuration sets, Mailgun options, scheduled sending, a
  provider's templates).
- **Not here**: receiving (IMAP, POP3), bounce and webhook processing, templating (the
  application renders the bodies; see Q6), list management, deliverability checks (MX lookup),
  DKIM signing in 0.x (needs RSA, which neither RTL nor pascal-common-faa has; every provider
  and most relays sign on their side; see Q7).

## 2. Packages and dependencies

| Package | Units | Depends on |
|---|---|---|
| `pascal_email_faa` (core, `src/`) | `PascalEmail.Version`, `.Interfaces`, `.Address`, `.Message`, `.Mime`, `.Errors`, `.Mock`, `.FileSender` | pascal-common-faa (`PascalCommon.Utf8`, `.Random`, `.SystemContext`; standard Base64, see E5) |
| `pascal_email_faa_smtp` (`adapters/smtp/`) | `PascalEmail.Smtp` | core, pascal-common-faa 1.27.0+ (`PascalCommon.Transport`, `.Tcp`, `.Tls`) |
| `pascal_email_faa_<provider>` (`adapters/<provider>/`) | `PascalEmail.<Provider>` | core, pascal-common-faa 1.31.0+ (`PascalCommon.Http`), pascal-jsonmapper-faa (JSON DOM) |
| `pascal_email_faa_outbox` (`bridges/outbox/`) | `PascalEmail.Outbox` | core, pascal-db-faa (`PascalDb.Outbox`) |

Same anatomy as pascal-db-faa and pascal-search-faa: the core knows no engine, each adapter is
its own package, and only the bridge depends on pascal-db-faa.

**E1. SMTP is written here, in plain Pascal over `PascalCommon.Transport`, not on Indy or
Synapse.** Reasons:

- One code path on both compilers. Indy on Lazarus is a separate port, and its stock OpenSSL
  handler targets OpenSSL 1.0.x; Synapse needs its own SSL plugin choice per platform. Either
  would bring a second TLS stack next to the one the family already verified.
- `PascalCommon.Transport` already has what SMTP needs: TCP with a connect budget, TLS with
  SChannel or OpenSSL 3 chosen at run time, certificate and host name verified, a private CA,
  per-direction deadlines, `CloseAbort` from another thread, and **`PcTlsWrap`, which upgrades an
  established connection to TLS: that is STARTTLS**, with no extra code.
- An SMTP client is small (EHLO, STARTTLS, AUTH, MAIL/RCPT/DATA, dot-stuffing, multi-line
  replies, enhanced status codes): a few hundred lines, all testable without a server.

Adapters for third-party components (Indy, Synapse, ACBrMail) stay possible as their own
packages, if an application already depends on one (Q1).

## 3. The message

**E2. A message is an interface with a fluent builder**, like the family's other contracts
(`Result := Self` first in each chainable method). `To` is a reserved word, so recipients go in
with `AddTo`/`AddCc`/`AddBcc`.

```pascal
TEmailAddress = record
  Name: string;       // display name, any Unicode
  Address: string;    // local@domain
  class function Create(const AAddress: string; const AName: string = ''): TEmailAddress; static;
  /// 'Ana Souza <ana@example.com>', 'ana@example.com', '"Souza, Ana" <ana@example.com>'.
  /// EEmailArgumentError on anything else.
  class function Parse(const AText: string): TEmailAddress; static;
end;

IEmailAttachment = interface
  function FileName: string;
  function ContentType: string;      // guessed from the extension when not given
  function Content: TBytes;
  function ContentId: string;        // '' = a regular attachment; set = inline (cid:)
end;

IEmailMessage = interface
  function SetFrom(const AAddress: string; const AName: string = ''): IEmailMessage;
  function SetSender(const AAddress: string; const AName: string = ''): IEmailMessage;
  function AddTo(const AAddress: string; const AName: string = ''): IEmailMessage;
  function AddCc(const AAddress: string; const AName: string = ''): IEmailMessage;
  function AddBcc(const AAddress: string; const AName: string = ''): IEmailMessage;
  function AddReplyTo(const AAddress: string; const AName: string = ''): IEmailMessage;
  function SetSubject(const ASubject: string): IEmailMessage;
  function SetText(const ABody: string): IEmailMessage;
  function SetHtml(const ABody: string): IEmailMessage;
  function Attach(const AFileName: string; const AContent: TBytes;
    const AContentType: string = ''): IEmailMessage;
  function AttachFile(const APath: string; const AContentType: string = ''): IEmailMessage;
  /// An image for the HTML body: <img src="cid:logo">.
  function Embed(const AContentId, AFileName: string; const AContent: TBytes;
    const AContentType: string = ''): IEmailMessage;
  function AddHeader(const AName, AValue: string): IEmailMessage;
  function SetMessageId(const AId: string): IEmailMessage;   // generated when empty
  function SetDate(const AUtc: TDateTime): IEmailMessage;     // the clock's when not set
  /// Provider-side tags and key/value metadata; SMTP writes neither (Q5).
  function AddTag(const ATag: string): IEmailMessage;
  function SetMetadata(const AKey, AValue: string): IEmailMessage;
  // ...plus the matching getters (From, ToList, Subject, TextBody, Attachments, ...)
end;

TEmailMessage = class
  class function New: IEmailMessage; static;
end;
```

**E3. Content lives in memory as `TBytes`.** Engines cap a message at 10-40 MB (SES 40 MB raw,
SendGrid 30 MB, Gmail 25 MB), so streaming buys little and costs a second code path. Revisit if
a real application needs it.

**E4. Header injection is impossible by construction.** Every address, display name, subject
and custom header value is checked for CR and LF at the call (`EEmailArgumentError`). A custom
header name must be a valid field name, and the structural headers (`From`, `To`, `Cc`, `Bcc`,
`Subject`, `Date`, `Message-ID`, `MIME-Version`, `Content-*`) can't be set through `AddHeader`.

## 4. The MIME writer

**E5. One writer in the core, `EmailToMime(AMessage): TBytes`**, used by the SMTP adapter, the
file sender, providers that take raw MIME (SES `Raw`, Mailgun `messages.mime`, Microsoft Graph,
Gmail API) and the tests. Rules:

- CRLF everywhere; header lines folded before 78 characters, never past 998.
- Non-ASCII in a display name or the subject as RFC 2047 encoded-words, UTF-8 (`B` or `Q`,
  whichever is shorter), split on character boundaries, never inside a UTF-8 sequence.
- Text bodies in UTF-8, quoted-printable; attachments in Base64, 76 columns.
- Attachment file names with RFC 2231 (`filename*=UTF-8''...`) plus an encoded-word `name=`
  fallback for older clients (measured in the probe, section 8).
- Structure: `multipart/mixed` ( `multipart/related` ( `multipart/alternative` (text, html),
  inline images ), attachments ), each level only when needed; a text-only message is a single
  part.
- Bcc is never written into the headers.
- **Deterministic**: the boundaries and the generated Message-ID come from an injectable source
  and the date from `TClock` (`PascalCommon.SystemContext`), so the unit tests compare exact
  bytes, the same on both compilers.

Standard Base64 is needed here, in SMTP AUTH and in HTTP Basic auth (Mailgun).
pascal-common-faa has only the URL alphabet (`PcBase64UrlEncode`); pascal-api-infra-faa has two
private decoders of the standard alphabet (`PascalApi.JwtKeys`, `PascalApi.SignedLinks`); and the
RTLs differ (Delphi's `TNetEncoding.Base64` breaks lines at 76 by default, FPC's `base64` unit
doesn't). That is a second user: proposal (Q3) **`PcBase64Encode`/`PcBase64Decode` in
pascal-common-faa's `PascalCommon.Crypto`** (one line, no breaks; MIME's line wrapping stays
here), a minor release there before this core.

## 5. Sending

```pascal
TEmailSendResult = record
  MessageId: string;            // the Message-ID header that was sent
  ProviderId: string;           // the engine's own id: SMTP queue id from the 250 reply,
                                // SES MessageId, SendGrid X-Message-Id ...
  Rejected: TArray<TEmailRejection>;  // recipients refused while others were accepted (SMTP)
end;

IEmailSender = interface
  function Name: string;        // 'smtp', 'ses', 'mock' ...
  function Send(const AMessage: IEmailMessage): TEmailSendResult;
  /// Several messages through one connection or request batch, where the engine allows it.
  /// One result per message; a failure of one message is in its result, not raised.
  function SendMany(const AMessages: array of IEmailMessage): TArray<TEmailSendOutcome>;
end;
```

**E6. A sender is thread-safe and kept for the process** (as pascal-common-faa's HTTP
transport): SMTP opens one connection per `Send` and per `SendMany` call in 0.1 (no pool:
servers drop idle connections within a minute, and a pool's checks cost more than they save at
transactional volumes). HTTP adapters reuse `PascalCommon.Http`'s keep-alive pool.

**E7. Partial recipient refusal (SMTP).** A server can refuse one `RCPT TO` and accept the
others. Default: send to the accepted ones and list the others in `Rejected`; if every
recipient is refused, `EEmailRejected`. `TSmtpOptions.RequireAllRecipients` aborts with `RSET`
instead. HTTP providers accept or refuse the whole request.

**E8. Errors**, all in `PascalEmail.Errors`:

| Class | When | Retry? |
|---|---|---|
| `EEmailArgumentError` | the message is invalid (no sender, no recipient, bad address, CR/LF) | never: the caller's bug |
| `EEmailAuthError` | credentials refused (SMTP 535, HTTP 401/403) | not by itself (configuration) |
| `EEmailRejected` | permanent refusal: SMTP 5xx, provider validation errors (HTTP 400/422) | never |
| `EEmailTransient` | SMTP 4xx, HTTP 429/5xx, connection refused, timeout before the message was handed over | yes, with backoff |
| `EEmailOutcomeUnknown` | the connection was lost after the whole message was sent and before the server answered | yes, but it may duplicate |

Each carries `Code` (SMTP reply or HTTP status), `EnhancedCode` (`5.1.1`) and the engine's text.
`EEmailOutcomeUnknown` exists for the same reason as pascal-search-faa's "a write without an
answer is not resent by the library": the library never retries by itself, the caller decides,
and a retry keeps the same Message-ID so the duplicate is recognizable.

**E9. SMTP specifics** (`TSmtpOptions`): host, port, security `ssNone | ssStartTls |
ssImplicitTls` (587 and 465), TLS required by default (STARTTLS not offered = error unless `AllowPlaintext`, never a
silent plaintext fallback), `TPcTlsOptions` passed through (private CA, mTLS, backend), AUTH
`PLAIN`/`LOGIN`, and `XOAUTH2` with a token from an application callback (Gmail, Microsoft 365,
which is retiring basic authentication for SMTP AUTH); token acquisition stays outside (Q4).
EHLO name configurable; `8BITMIME` not used (the writer is 7-bit safe); `SMTPUTF8` (non-ASCII
addresses) out of 0.1: such an address is `EEmailArgumentError`.

## 6. Mock, file sender and the outbox

**E10. `TMockEmailSender`** keeps every message sent (thread-safe), with its MIME bytes and the
result it returned; it can be told to fail the next sends with a given error class, so an
application tests its retry handling with no server. **`TFileEmailSender`** writes each message
as an `.eml` file into a folder (development, and a pickup directory for IIS-style relays).

**E11. Outbox bridge** (`bridges/outbox`), as pascal-search-faa's: the application writes "send
e-mail X" into pascal-db-faa's outbox in the same transaction as its data, and a handler of
`TOutboxLocalSink` sends it later with the outbox's retries. **The event carries the
application's key, not the message**: the outbox's payload is bounded (`NVARCHAR(4000)` on SQL
Server, `VARCHAR(8000)` on Firebird, pascal-db-faa gotchas 58-59), too small for attachments,
so a loader callback rebuilds the `IEmailMessage` from the key. Errors map as E8 says:
`EEmailArgumentError` and `EEmailRejected` become `EOutboxGiveUp` (dead at once); everything
else is raised for the outbox to retry, `EEmailAuthError` included (a configuration fix
should not lose mail). Delivery is at-least-once: a crash between the server's 250 and the
outbox's commit sends the message again, with the same Message-ID.

## 7. Repository layout

The `dual-compiler-delphi-lazarus` anatomy, the same as pascal-search-faa:

```
src/pascalemail.inc            {$MODE DELPHI}{$H+}, PASCALEMAIL_WINDOWS, PASCALEMAIL_FUNCREFS
src/PascalEmail.*.pas          core
adapters/smtp/, adapters/<provider>/
bridges/outbox/
packages/pascal_email_faa*.lpk
tests/Unit/ (DUnitX masters, FPCUnit's assertion dialect) + tests/Unit/fpc/ (generated)
tests/Integration/ (+ fpc/)
samples/
tools/ (gen_fpc_mirror.py, test_fpc.sh, test_fpc_docker.sh, test_integration_docker.sh, ci-test.sh)
external/pascal-common-faa (+ pascal-jsonmapper-faa, pascal-db-faa when needed)
PascalEmail.groupproj, PascalEmail.lpg, CLAUDE.md, README.md, CHANGELOG.md, docs/
```

Prefixes: units `PascalEmail.*`, types `TEmail*`/`IEmail*`/`EEmail*`, free functions `Email*`.
Version in `PascalEmail.Version` (`MMmmpp`), 0.x until the contract holds on SMTP and one HTTP
provider.

## 8. Probe (before the final contract)

In `.ci/probe-smtp` (git-ignored), FPC 3.2.2 on Linux and Windows, Delphi 12 Win32/Win64, results
as numbered findings in `docs/findings.md`:

- **Servers in Docker, pinned**: Mailpit (`axllent/mailpit`: SMTP with STARTTLS, implicit TLS and
  AUTH, plus an HTTP API to read back what arrived, so the integration suite can compare headers,
  bodies and attachments) and a real MTA (Postfix) for reply codes, partial `RCPT` refusal and
  a connection dropped after `DATA`.
- STARTTLS through `PcTlsWrap` on both TLS backends; a private CA; a server that doesn't offer
  STARTTLS.
- AUTH PLAIN/LOGIN; XOAUTH2 against Gmail or Microsoft 365 if you provide a test account (manual,
  never in CI).
- MIME: encoded-words in the subject and display names (accents, emoji, long text), RFC 2231
  file names, inline images; checked by Mailpit's parser and by you in Outlook, Gmail and
  Thunderbird (the only check that matters for rendering).
- Line endings: a body with bare LF, bare CR, a line starting with `.`, a line over 998 bytes.

## 9. Open questions (closed 2026-11-12)

All closed with the proposals: Q1 SMTP first, one HTTP provider next to validate the contract
(not chosen yet; SES v2 leads); Q2 `PascalEmail.*`; Q3 `PcBase64Encode`/`PcBase64Decode` in
pascal-common-faa 1.32.0; Q4 XOAUTH2 in 0.1, token from the application; Q5 tags and metadata
dropped by SMTP; Q6 no templates; Q7 no DKIM in 0.x. The original questions:

- **Q1. Which "final engines" first?** The proposal is SMTP (E1) first: every provider also
  accepts SMTP (SES, SendGrid, Mailgun, Gmail, Microsoft 365, any relay), so it alone covers
  every case. Then **one HTTP provider to validate the contract**. Candidates: Amazon SES v2
  (SigV4 is SHA-256/HMAC, already in pascal-common-faa; takes our raw MIME), SendGrid v3, Mailgun,
  Microsoft Graph `sendMail`, Resend/Postmark/Brevo. Or adapters over Indy/Synapse/ACBrMail?
- **Q2. Package name prefix**: `PascalEmail.*` (proposed) or `PascalMail.*`.
- **Q3. Standard Base64 in pascal-common-faa** (E5), a minor release there first?
- **Q4. XOAUTH2 in 0.1** with the token from a callback, or later?
- **Q5. Tags/metadata over SMTP**: drop them (proposed), or write them as `X-` headers?
- **Q6. Templates**: out (proposed), or a small `{{name}}` substitution with HTML escaping?
- **Q7. DKIM**: out of 0.x (proposed; needs RSA-SHA256 or Ed25519 in pascal-common-faa first).

## 10. What 0.1.0 settled

- **E12. The sender's seams are interfaces passed to the constructor**: `ISmtpConnector` (how a
  connection is made: `PcTcpConnect`, `PcTlsConnect`, `PcTlsWrap` by default) and
  `IEmailIdSource` (boundaries and Message-IDs). The unit suite runs the whole SMTP conversation
  against a scripted server through the first, and compares MIME byte for byte through the
  second. Interface parameters are stored before anything can raise (gotcha 1).
- **E13. Reply codes** (finding 2): 530, 534 and 535 are `EEmailAuthError` at any step, not only
  during AUTH (Mailpit answers `MAIL FROM` with 530 when AUTH was skipped); 421 marks the
  connection broken; any other 4xx is `EEmailTransient`, 5xx `EEmailRejected`. `EHLO` refused
  with a 5xx other than 554 falls back to `HELO`.
- **E14. Credentials are refused over plaintext twice**: when the sender is created (`ssNone`
  with a user name or token, without `AllowPlaintext`: `EEmailArgumentError`), and before AUTH
  on a connection that isn't TLS (a STARTTLS fallback allowed by `AllowPlaintext` still sends
  them, since that flag allows both).
- **E15. `SendMany` closes each transaction with `RSET`, and a connection that fails it, or
  failed before, is replaced** before the next message, so a broken connection is never charged
  to the message after it. A connection that failed while opening (EHLO, AUTH) is never reused.
- **E16. `ProviderId` is the word after "queued as"** in the final reply when there is one
  (Postfix, Mailpit: finding 3), else the reply's text without its enhanced code.
- **E17. Header lines stay within 76 characters** (a stricter reading of E5): encoded-words are
  sized by the column they start at, a printable ASCII value with a word too long for a line
  goes out as encoded-words (which can be split), and `name=` of an attachment switches to
  encoded-words from 60 characters. Only an address longer than a line can pass 76.
- **E18. A tie between Q and B goes to Q** (the readable one); B is chosen only when shorter.
- **E19. Inline parts without an HTML body become ordinary attachments** in `multipart/mixed`,
  keeping their `Content-ID` (there is no HTML to be related to).
- **E20. `TFileEmailSender` writes under a temporary name and renames**, so a pickup folder never
  sees half a message; any failure to write is `EEmailTransient`.
- **E21. The integration suite reads every message back from Mailpit's API** (the raw message
  and its parsed JSON) and checks, besides delivery, that the raw message after Mailpit's own
  lines is the library's MIME byte for byte (finding 4).

## 11. Development and staging: decorators (2026-11-12)

How an application avoids mailing real people outside production. Accepted with the user on
2026-11-12. For a developer's machine, the answer needs no code: an SMTP sender pointed at a
capture server (Mailpit, as the integration suite) keeps the real path (TLS, AUTH, MIME,
refusals) and shows every message in a web page, or `TFileEmailSender` writes `.eml` files.
The risk is a shared or staging environment with real data and a real engine, which the
decorators cover (`PascalEmail.Decorators`, core, no new dependency):

- **E22. `TRedirectEmailSender(Inner, ['qa@...'], Prefix)`** sends every message to fixed
  addresses instead of its recipients; the originals go in `X-Original-To`, `X-Original-Cc` and
  `X-Original-Bcc` (Bcc too: the reader is the team), and the subject gets `Prefix`
  (`'[REDIRECTED] '` by default, `''` for none).
- **E23. `TAllowlistEmailSender(Inner, ['@empresa.com.br', 'ana@example.com'])`** delivers only
  to listed addresses and domains (`@domain`: that domain exactly, without case; not its
  subdomains, so `@empresa.com` doesn't admit `x@minhaempresa.com` nor `x@mail.empresa.com`).
  The others are reported in `Rejected` with `Code` 0 and `EMAIL_NOT_ALLOWED_TEXT`, the shape of
  an SMTP partial refusal, and To/Cc/Bcc roles are kept. A message with no allowed recipient
  isn't handed to the inner sender at all and is **not an error**: `ProviderId` '' and every
  recipient in `Rejected` (staging must not fail where production would succeed).
- **E24. Both validate the caller's message first** (`Validate`: a missing From or recipient is
  `EEmailArgumentError` before anything, as a real engine) **and send a copy**
  (`EmailCopyMessage`, in `PascalEmail.Message`): the caller's message is never changed. The
  inner sender's exceptions pass through unchanged; `SendMany` goes to the inner `SendMany`, so
  SMTP keeps one connection.
- **E25. No configuration-driven factory in 0.1.** Choosing the sender by environment (`smtp`,
  `file`, `redirect:...`) is a few lines in the application's composition root; a factory can
  come when a second application wants the same one.

## 12. The Amazon SES adapter (2026-11-12)

Accepted with the user on 2026-11-12, to validate the contract against an HTTP provider. No AWS
account: validated against AWS's and botocore's vectors (findings 9-12).

- **E26. SES API v2, `SendEmail` with raw content**, in its own package
  (`pascal_email_faa_ses`, `adapters/ses`) on `PascalCommon.Http`: the MIME of
  `PascalEmail.Mime` in Base64, so SES sends the bytes SMTP would. `Destination` is always
  explicit (Bcc isn't in the headers); `FromEmailAddress` is left out (the From header);
  metadata becomes `EmailTags`, and a tag becomes `EmailTags` with the value `true`. SES allows
  only `[A-Za-z0-9_-]{1,256}` there: anything else is `EEmailArgumentError` before the request.
  No JSON library: the request is a fixed shape of ASCII values and the answers are flat objects
  (`MessageId`, `message`, `__type`).
- **E27. Signature Version 4 in its own unit** (`PascalEmail.AwsSigV4`, no SES in it): every
  header sent plus `host` (computed as the transport writes it; the transport refuses a request
  that sets `Host`), the path and query as given (already encoded). If a second library talks
  to AWS, it is a pascal-common-faa candidate. Credentials are static, or an
  `ISesCredentialsProvider` asked at every send (IAM roles; caching is the provider's).
- **E28. Errors**: by the error name first, then the status. `TooManyRequests`, `LimitExceeded`,
  `Throttling`, 429 and 5xx are `EEmailTransient`; 401, 403, `NotFound` (configuration set),
  `MailFromDomainNotVerified`, `AccountSuspended`, `SendingPaused` are `EEmailAuthError` (the
  account's configuration); `MessageRejected`, `BadRequest` and any other 4xx are
  `EEmailRejected`. **No HTTP answer is `EEmailOutcomeUnknown`**: pascal-common-faa's transport
  raises `EPcHttpTransport` both when the connection failed and when the POST went out without
  an answer, and never sends a POST twice; the library can't tell which, so it says the safe
  thing. A subclass for "nothing was sent" (connect failures) in pascal-common-faa would let a
  refused connection be `EEmailTransient`; not needed for retries (both classes are
  retryable), so not proposed yet.
- **E29. The clock is TClock** (`EmailUtcNow`), so a test fixes the signing time.

## 13. Telemetry (2026-11-13)

Accepted with the user on 2026-11-13, before 0.1.0 is published (the contract is still free).
pascal-common-faa 1.33.0 brought `PascalCommon.Http.Telemetry` (its
`docs/http-telemetry-design.md`, HT1-HT11), which pascal-api-infra-faa 0.34.0 and
pascal-search-faa 0.3.0 already use. OpenTelemetry has no conventions for e-mail: the names
below are this library's (prefix `pascalemail.`, as pascal-db-faa uses `pascaldb.`), with the
general attributes (`server.address`, `server.port`, `error.type`) where they fit.

- **E30. The SES adapter wraps its HTTP transport with `PcNewTracedHttpTransport`, always**:
  the one it creates and the one given to `Create` (the tests' fake, an application's own), as
  pascal-search-faa does (its S32), so the tests go through the production path. A caller must
  not pass a transport already wrapped (two spans and two points per call; the unit's header
  says so). Zeroed options: the `POST` span carries the method, `server.address`
  (`email.<region>.amazonaws.com` or the endpoint), `url.full` (the base URL and the fixed
  path, no query), the status and `error.type`; the body (the MIME, with its recipients) goes
  to neither the span nor the metric. The `traceparent` is added after `AwsSigV4Sign`, outside
  `SignedHeaders`, so the signature doesn't change (finding 13, reasoned, not measured against
  AWS). `error.type = EPcHttpTransport` on that span is exactly the case the sender raises as
  `EEmailOutcomeUnknown`. pascal-common-faa 1.33.0 for the SES adapter (`$MESSAGE FATAL` in
  `PascalEmail.Ses`, `MinVersion` in its `.lpk`); the core and SMTP stay on 1.32.0 (`Tracing`
  and `Metrics` exist since 1.7.0 and 1.6.0).
- **E31. Every sender instruments itself; no decorator.** A decorator around a sender only sees
  a `SendMany` as a whole: the loop over messages (and SMTP's one connection) is inside the
  sender, so a decorator can't time or describe each message, and only the sender knows its
  server. `PascalEmail.Telemetry` (core) holds the shared code (`TEmailSendTelemetry`,
  `TEmailBatchTelemetry`), called by SMTP, SES, the file sender and the mock (so an application
  can test its own tracing without a server); `TEmailSenderBase.SendMany` opens the batch span.
  Always on, as pascal-db-faa's statements and the HTTP adapters: a span costs microseconds and
  nothing is exported until the application starts tracing. The redirect and allowlist
  decorators record nothing themselves (E35).
- **E32. The span `email send`, one per message**, started and finished on the calling thread: a
  child of the thread's current span, or the root of a new trace when there is none (as
  pascal-db-faa's statements; there is no exporter loop here, unlike HT3). Kind client (SMTP,
  file, mock), internal where a lower layer already makes the client span (SES: the `POST` is
  its child). Attributes: `pascalemail.sender`, `pascalemail.recipients` (the envelope: To + Cc
  + Bcc), `pascalemail.message_id` (set as soon as the MIME is written, so a failure keeps it),
  `pascalemail.provider_id` (SMTP's queue id, SES's MessageId, the file's path, `mock-N`),
  `pascalemail.rejected` (when > 0), `server.address` and `server.port` (SMTP: the options' host
  and effective port); on failure `error.type` (the class), `pascalemail.reply.code` and
  `pascalemail.reply.enhanced_code`. A partial refusal isn't an error (status unset).
  **Never an address, a subject, a body or an exception's message**: the SMTP refusal quotes
  the recipient (`550 5.1.1 <bob@...>: Recipient address rejected`, and `EEmailRejected`'s
  message carries it), SES lists identities that failed a check, `EEmailArgumentError` names
  the address it refused. A failed span's status description is `<class> <code> <enhanced
  code>` only (`EEmailRejected 550 5.1.1`). The Message-ID and the provider id are generated,
  not personal, and correlate a span with a server's or provider's log; a caller that sets a
  Message-ID with personal data in it sends it to the collector (README).
- **E33. Metrics, on `PcMetrics`**: the histogram `pascalemail.send.duration` (`s`,
  `PC_DURATION_BUCKETS`; labels `pascalemail.sender`, `error.type`, `''` on success), one point
  per message; its count is the number of sends and of failures, so there is no counter for
  them. The counter `pascalemail.recipients` (`{recipient}`; `pascalemail.sender`,
  `pascalemail.outcome` = `accepted` | `rejected`) for messages handed over: a send that raised
  counts no recipient (an SMTP send with every recipient refused is an `EEmailRejected` point of
  the histogram). Never a recipient's domain (cardinality, privacy). Duration from `PcTickUs`:
  SMTP's `Send` includes connecting, TLS, EHLO and AUTH; in a `SendMany` the first message
  carries them, and a reconnection falls on the message that needed it.
- **E34. `SendMany`: both levels.** A span `email send_many` (internal; `pascalemail.sender`,
  `pascalemail.messages`, `pascalemail.failed`) around the batch, with each message's `email
  send` as its child. It covers what belongs to no message (SMTP's `QUIT`). Failures are in the
  outcomes, so the batch span is an error only when an exception escapes (a bug).
- **E35. The decorators record what went out.** With the instrumentation inside the senders,
  a redirect's span counts the QA mailbox, an allowlist's counts the allowed recipients, and an
  allowlist that drops every recipient makes no span and no point (nothing was sent).
  Recording what the application asked for would need a decorator outside them; not wanted
  now.
- **The outbox (E11), when the bridge exists**: pascal-db-faa's `TOutbox.Enqueue` keeps the
  current span's `traceparent`, and the relay opens `outbox <kind>` with `StartSpanFromParent`
  before calling the sink, so an e-mail queued during a request continues its trace: `email
  send` (and SES's `POST`) become children of the outbox span with nothing extra. To be
  confirmed in the bridge's design.
- Tests: `PascalEmail.TelemetryTests` (mock, the scripted SMTP server, the decorators) and the
  SES suite's `Telemetry_` tests over the fake HTTP transport, with `TPcTracing.Start(...,
  AAutoFlush = False)`, `TCapturingSpanExporter` and `FlushNow`, and the metrics read before and
  after; two `Telemetry_` tests in the integration suite against Mailpit.
