# Findings: what the servers and parsers did

Numbered, measured, never rewritten: a finding that stops holding gets a note, not an edit. The
design ([`design.md`](design.md)) cites them as "finding N". Measured on 2026-11-12 against
Mailpit v1.33.1 (`axllent/mailpit:v1.33.1`, `tools/mailpit.sh`), from FPC 3.2.2 on Windows 11
(SChannel and OpenSSL 3) and on Linux (Debian 12's libssl3, `tools/test_integration_docker.sh`).
The probe's sources are in `.ci/probe-smtp` (git-ignored): `probe.lpr` (one send per scenario),
`gen.lpr` and `check.py` (the MIME writer's output parsed by Python's `email` package).

## Mailpit

1. **STARTTLS and implicit TLS work through pascal-common-faa's transport** as is: `PcTlsWrap`
   over the plain connection after `220 Ready to start TLS`, and `PcTlsConnect` on the implicit
   port. Measured with SChannel and OpenSSL 3 on Windows, OpenSSL 3 on Linux. EHLO after
   STARTTLS advertises `AUTH PLAIN LOGIN CRAM-MD5` (only then: before it, Mailpit with
   `--smtp-require-starttls` offers no AUTH).

2. **A client that skips AUTH on a server that requires it gets `530 5.7.0 Authentication
   required` at `MAIL FROM`**, not at connect. RFC 4954 gives 530 that meaning; the sender maps
   530 (and 534, 535) to `EEmailAuthError` wherever it comes, not to `EEmailRejected`, which the
   outbox would give up on.

3. **The final reply to DATA is `250 2.0.0 Ok: queued as <ID>`, and `<ID>` is the message's id in
   Mailpit's API** (`/api/v1/message/<ID>`). `ProviderId` takes the word after "queued as"
   (Postfix's form too); the integration suite reads each message back by it.

4. **Mailpit stores the message as received, with `Return-Path` and `Received` added on top**:
   after them, the raw message is the library's MIME byte for byte (test
   `StartTls_Auth_Delivered_ByteForByte`). **When a recipient was only in the envelope (Bcc),
   Mailpit also writes a `Bcc:` line above its `Return-Path`**, to keep the information; that
   line is Mailpit's, not the client's (the library never writes Bcc into the headers).

5. **A recipient refused by `--smtp-allowed-recipients` gets `550 5.1.0 Requested action not
   taken: mailbox unavailable`**, and the others are delivered: the partial refusal the design
   (E7) reports in `TEmailSendResult.Rejected`. With every recipient refused, the sender sends
   `RSET` and raises `EEmailRejected` without `DATA`.

6. **TLS failures, and what they become** (all `EEmailTransient`, the transport's `EPcTls` or
   `EPcTransport*` in the message):
   - a host name the certificate doesn't hold (`127.0.0.1` for a certificate of `localhost`):
     SChannel `0x800B010F` (CERT_E_CN_NO_MATCH), during the STARTTLS handshake or at connect;
   - a certificate from a CA the client doesn't trust (no `Tls.CaFile`): SChannel `0x80090325`
     (SEC_E_UNTRUSTED_ROOT);
   - a STARTTLS client on the implicit-TLS port: the server waits for a ClientHello, the client
     for a greeting, until `TimeoutMs` (`EPcTransportTimeout`): the deadline is what ends it;
   - nothing listening: `EPcTransportRefused`, at once.

7. **Mailpit's JSON gives a text part's content without the part's final line break**: a body
   `'a'#10'b'` comes back as `"a\r\nb"`, the line breaks as CRLF (what quoted-printable carries).

## Parsers

8. **Python's `email` package (3.12, `policy.default`) reads the writer's output with no
   defects** and gives back what the message was built with: a long subject with accents and an
   em dash folded over several encoded-words, display names with a comma, quotes and a
   backslash, an emoji in a name, a custom header with `✓`, RFC 2231 file names split into
   sections, multipart/mixed around multipart/related around multipart/alternative, an inline
   image by `Content-ID`, attachment bytes intact, every line ≤ 76 characters, CRLF only. Like
   Mailpit, it returns a single part's body with its final line break and the breaks as CRLF.

## AWS Signature Version 4 and SES (2026-11-12, no AWS account)

There was no AWS account to send through: these findings are vectors and documentation, not
measurements against SES. The vectors were computed outside this code and the unit tests hold
the library to them (`PascalEmail.SesTests`); the probe is `.ci/probe-ses` (`vectors.py`,
`sescheck.py`, `sesprobe.lpr`; botocore 1.44.1 in a throwaway venv).

9. **AWS's published vectors**: the derived signing key of AWS's documentation example (secret
   `wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`, 20120215, us-east-1, iam) is
   `f4780e2d...db404d`, and the `get-vanilla` case of AWS's SigV4 test suite signs as
   `5fa00fa3...763fbf31`. botocore 1.44.1 computes the same two values, so the reference itself
   is checked.

10. **botocore vectors for what the suite doesn't cover**: query parameters out of order
    (`b97d918c...`, the suite's query-order case), a header value with repeated blanks
    (`1d3c8dac...`, canonicalized to single spaces), and an SES `SendEmail` POST to
    `email.sa-east-1.amazonaws.com/v2/email/outbound-emails` with `Content-Type:
    application/json`, without (`75819559...`) and with a session token (`edfb2bbb...`, the
    token signed as `x-amz-security-token`). botocore signs `content-type`, `host` and the
    `x-amz-*` headers; the library signs every header it sends plus `host`, the same set here.

11. **End to end: botocore signs the request `TSesSender` builds identically.** The probe
    captured a real request (raw MIME with an attachment, a session token, a configuration set,
    a tag) through the fake transport and had botocore sign the same URL, `Content-Type` and
    body at the same `X-Amz-Date`: same `Authorization`. The body is valid JSON, its
    `Content.Raw.Data` decodes to a message Python's `email` package parses, and the Bcc address
    is only in `Destination`.

12. **SES v2 behavior taken from the API reference, not measured**: `SendEmail` answers 200 with
    `{"MessageId": ...}`; failures carry the error name in `x-amzn-ErrorType` (sometimes
    `Name:http://...`, sometimes in the body's `__type` as `...#Name`) and the text in the body's
    `message`. Names mapped (design E28): `MessageRejected` (an unverified address in the sandbox
    included), `BadRequestException`, `MailFromDomainNotVerifiedException`,
    `AccountSuspendedException`, `SendingPausedException`, `NotFoundException`,
    `LimitExceededException`, `TooManyRequestsException`. For raw content, the recipients come
    from the headers unless `Destination` is given, and the sender from the From header when
    `FromEmailAddress` is left out. **The first real send should confirm these**; the mapping
    is one function (`TSesSender.RaiseForStatus`).
