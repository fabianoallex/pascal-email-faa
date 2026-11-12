# pascal-email-faa

An e-mail sending contract for **Delphi and Lazarus/FPC** (one code base, the same behavior on
both): build a message once, send it through any engine, and know from the exception's class
whether a retry can help.

- **One message model** with a fluent builder: sender, To/Cc/Bcc, Reply-To, subject, text and
  HTML bodies, attachments, inline images (`cid:`), custom headers. Values that could add a
  header (CR, LF) are refused when they go in.
- **One MIME writer** (RFC 5322, 2045-2047, 2231), byte-for-byte the same on both compilers:
  7-bit, CRLF, lines within 76 characters, accents and emoji encoded, attachment names readable
  by old and new clients.
- **Senders**: SMTP (STARTTLS or implicit TLS, verified, AUTH PLAIN/LOGIN/XOAUTH2), an
  in-memory mock for your tests, and an `.eml` file writer (development, pickup folders).
- **Errors that say what to do**: invalid message, authentication, permanent refusal,
  transient failure, or "sent, but no answer came" (a retry may duplicate).

Status: **0.1.0, unreleased**. Unit suite 94 tests, integration suite 18 (SMTP against Mailpit:
STARTTLS, implicit TLS, plain; a private CA), 0 leaks, on FPC 3.2.2 Windows (SChannel and
OpenSSL 3) and Linux (OpenSSL 3), and on Delphi 12 Win32 and Win64. Decisions: [`docs/design.md`](docs/design.md); what servers did: [`docs/findings.md`](docs/findings.md).

## Contents

| Unit | Package | What |
|---|---|---|
| `PascalEmail.Message` | `pascal_email_faa` | `IEmailMessage`, `TEmailMessage.New`, attachments, `EmailGuessContentType` |
| `PascalEmail.Address` | `pascal_email_faa` | `TEmailAddress` (`Create`, `Parse`), `EmailIsValidAddress`, `EmailCheckHeaderText` |
| `PascalEmail.Mime` | `pascal_email_faa` | `EmailBuildMime` (the message's bytes), `IEmailIdSource`, `EmailQuotedPrintable`, `EmailEncodeHeaderText`, `EmailFormatDate` |
| `PascalEmail.Interfaces` | `pascal_email_faa` | `IEmailSender` (`Send`, `SendMany`), `TEmailSendResult`, `TEmailSendOutcome`, `TEmailSenderBase` |
| `PascalEmail.Errors` | `pascal_email_faa` | `EEmailError` and its classes, `EmailIsRetryable` |
| `PascalEmail.Mock` | `pascal_email_faa` | `TMockEmailSender`: keeps what was sent, fails on demand |
| `PascalEmail.FileSender` | `pascal_email_faa` | `TFileEmailSender`: one `.eml` per message |
| `PascalEmail.Smtp` | `pascal_email_faa_smtp` | `TSmtpSender`, `TSmtpOptions`, `IEmailTokenProvider`, `ISmtpConnector` |
| `PascalEmail.Version` | `pascal_email_faa` | `PASCALEMAIL_VERSION` (`MMmmpp`) |

## Requirements

- Delphi 12 or Lazarus with FPC 3.2.2.
- [pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa) **1.32.0 or later**
  (standard Base64, the TLS transport). One copy for the whole application: an application that
  uses several `*-faa` libraries provides it once.
- SMTP over TLS: Windows uses SChannel (nothing to install); on Linux, OpenSSL 3
  (`libssl3` and `ca-certificates` on Debian 12).
- FPC programs: run with a UTF-8 code page (`SetMultiByteConversionCodePage(CP_UTF8)` in a
  console program; LCL programs already are), and on Unix put `cthreads` and `cwstring` in the
  program's `uses`.

## Installing

As git submodules of your application (one copy of each library):

```
git submodule add https://github.com/fabianoallex/pascal-common-faa external/pascal-common-faa
git submodule add https://github.com/fabianoallex/pascal-email-faa external/pascal-email-faa
```

- **Delphi**: add `external/pascal-common-faa/src`, `external/pascal-email-faa/src` and
  `external/pascal-email-faa/adapters/smtp` to the project's search path.
- **Lazarus**: open and register `pascal_common_faa.lpk`, then `packages/pascal_email_faa.lpk`
  and `packages/pascal_email_faa_smtp.lpk` (or `lazbuild --add-package-link`), and add them to
  the project's required packages.

## Sending

```pascal
uses
  PascalEmail.Message, PascalEmail.Interfaces, PascalEmail.Errors, PascalEmail.Smtp;

var
  LOptions: TSmtpOptions;
  LSender: IEmailSender;     // thread-safe: keep one for the process
  LResult: TEmailSendResult;
  LLogoBytes: TBytes;        // the image, loaded however the application keeps it
begin
  LOptions := TSmtpOptions.Create('smtp.example.com', 587, ssStartTls);
  LOptions.UserName := 'app@example.com';
  LOptions.Password := '...';
  LSender := TSmtpSender.Create(LOptions);

  LResult := LSender.Send(TEmailMessage.New
    .SetFrom('app@example.com', 'Minha Loja')
    .AddTo('cliente@example.com', 'João da Silva')
    .SetSubject('Seu pedido nº 1234 foi enviado')
    .SetText('Olá João, seu pedido saiu para entrega.')
    .SetHtml('<p>Olá <b>João</b>, seu pedido saiu para entrega.</p><img src="cid:logo">')
    .Embed('logo', 'logo.png', LLogoBytes)
    .AttachFile('C:\notas\nf-1234.pdf'));
  // LResult.MessageId: the Message-ID sent; LResult.ProviderId: the server's queue id;
  // LResult.Rejected: recipients the server refused while it accepted others.
end;
```

- **Security**: `ssStartTls` (587, the default) requires the server to offer STARTTLS, and
  `ssImplicitTls` (465) is TLS from the first byte; both verify the certificate and the host
  name. A private CA: `LOptions.Tls.CaFile := 'ca.pem'`. `ssNone` (25) is for a relay inside a
  trusted network, and credentials are never sent without TLS unless `AllowPlaintext` is set.
- **Gmail / Microsoft 365 with OAuth 2.0**: set `LOptions.TokenProvider` to an object of yours
  implementing `IEmailTokenProvider.AccessToken` (getting and refreshing the token is yours);
  `UserName` is the mailbox.
- **Several messages through one connection**: `LSender.SendMany([M1, M2, M3])` returns one
  outcome per message; a refused message doesn't stop the others.

## Errors and retries

| Exception | Meaning | Retry? |
|---|---|---|
| `EEmailArgumentError` | the message is invalid (no sender, no recipient, bad address, CR/LF in a header) | never |
| `EEmailAuthError` | credentials refused, or the server requires AUTH (SMTP 530/534/535) | after fixing the configuration |
| `EEmailRejected` | permanent refusal (SMTP 5xx): bad recipient, spam policy, message too big | never |
| `EEmailTransient` | try later (SMTP 4xx), connection or TLS failure before the message was handed over | yes, with backoff |
| `EEmailOutcomeUnknown` | the whole message was sent and no answer came: it may have been delivered | yes, but it may arrive twice (same Message-ID) |

Each carries `Code` (the SMTP reply), `EnhancedCode` (`5.1.1`) and `EngineText`.
`EmailIsRetryable(E)` answers the last column. The library never retries by itself.

## Testing your application

```pascal
LMock := TMockEmailSender.Create;
LSender := LMock;                       // what your code receives
...
Check(LMock.Count = 1);
Check(LMock.Last.Message.ToList[0].Address = 'cliente@example.com');
Check(Pos('Seu pedido', LMock.Last.Mime.AsText) > 0);
LMock.FailNext(EEmailTransient);        // the next Send raises it
```

`TFileEmailSender.Create('outbox')` writes each message as an `.eml` file you can open in any
mail client.

## Building and testing this library

- FPC on Windows: `sh tools/test_fpc.sh` (unit) and, with `sh tools/mailpit.sh` running,
  `sh tools/test_fpc.sh integration`.
- Linux, in Docker: `sh tools/ci-test.sh` (what CI runs: both suites on FPC 3.2.2, Mailpit
  started and removed by the script).
- Delphi: open `PascalEmail.groupproj` and run `tests/Unit/PascalEmail.UnitTests.dproj` and
  `tests/Integration/PascalEmail.IntegrationSuite.dproj` (Win32 and Win64).

## License

MIT.
