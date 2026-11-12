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
