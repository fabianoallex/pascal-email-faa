unit PascalEmail.Smtp;

{$I pascalemail.inc}

{ The SMTP sender (RFC 5321), written on pascal-common-faa's
  PascalCommon.Transport rather than on Indy or Synapse (design, E1): the
  same code on Delphi and FPC, and the family's verified TLS (SChannel or
  OpenSSL 3, chain and host name checked, a private CA, mTLS). STARTTLS is
  PcTlsWrap over the connection already open.

  One connection per Send, and one per SendMany call (design, E6); a sender
  holds only its options, so it is thread-safe and kept for the process.

  What it does, in order: greeting (220), EHLO (HELO when EHLO is refused),
  STARTTLS and EHLO again (ssStartTls), AUTH (PLAIN, LOGIN, or XOAUTH2 with
  a token from the application), MAIL FROM (with SIZE when the server
  advertises it), one RCPT TO per recipient, DATA with dot-stuffing, QUIT.
  The message is what PascalEmail.Mime writes: 7-bit, CRLF, so neither
  8BITMIME nor SMTPUTF8 is used.

  Security defaults (design, E9): ssStartTls requires the server to offer
  STARTTLS; without it the send fails (EEmailTransient) instead of falling
  back to plaintext, unless AllowPlaintext. Credentials are never sent over
  a plaintext connection unless AllowPlaintext: an ssNone sender with a
  user name and without it is refused when created.

  Errors (design, E8): a reply 4xx or 421 is EEmailTransient, 5xx
  EEmailRejected (535/534/530 during AUTH: EEmailAuthError); a connection
  failure before the message's final '.' was written is EEmailTransient (a
  server discards an unfinished DATA); after it, with no reply, it is
  EEmailOutcomeUnknown. A recipient refused while others were accepted is
  reported in TEmailSendResult.Rejected (design, E7), or fails the send
  with RequireAllRecipients.

  ISmtpConnector is the seam for tests: the unit suite scripts a server's
  replies over a fake endpoint, the integration suite talks to Mailpit.

  Telemetry (PascalEmail.Telemetry; design, section 13): each message is an
  'email send' client span with server.address and server.port (the
  options' host and port) and a point of pascalemail.send.duration; a
  SendMany is an 'email send_many' span around them. A Send's duration
  includes connecting, TLS, EHLO and AUTH; in a SendMany the first message
  carries them, and a reconnection falls on the message that needed it. No
  reply text reaches a span (it can quote the recipient). }

interface

uses
  SysUtils,
  PascalCommon.Transport,
  PascalEmail.Errors,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.Interfaces;

const
  /// The deadline of each wait on the server, by default (RFC 5321 section
  /// 4.5.3.2 suggests minutes; most servers answer in milliseconds).
  SMTP_DEFAULT_TIMEOUT_MS = 120000;

type
  TSmtpSecurity = (
    /// Plain TCP, then STARTTLS (port 587 by default). The default.
    ssStartTls,
    /// TLS from the first byte (port 465 by default).
    ssImplicitTls,
    /// No TLS (port 25 by default): a relay inside a trusted network.
    ssNone);

  TSmtpAuth = (
    /// XOAUTH2 when a token provider is set; otherwise PLAIN, or LOGIN when
    /// the server offers only LOGIN; none without a user name.
    saAuto,
    saNone,
    saPlain,
    saLogin,
    saXOAuth2);

  /// The application's source of OAuth 2.0 access tokens (Gmail,
  /// Microsoft 365). Called once per connection, from the sending thread;
  /// getting and refreshing tokens is the application's.
  IEmailTokenProvider = interface
    ['{5D0E7C3A-9F14-4B2E-86A1-C7D3E9F0B254}']
    function AccessToken: string;
  end;

  TSmtpOptions = record
    Host: string;
    /// 0 = 587, 465 or 25 by Security.
    Port: Word;
    Security: TSmtpSecurity;
    /// ssStartTls: go on in plaintext when the server doesn't offer
    /// STARTTLS. Any security: allow AUTH over a plaintext connection.
    /// For a lab only.
    AllowPlaintext: Boolean;
    UserName: string;
    Password: string;
    Auth: TSmtpAuth;
    TokenProvider: IEmailTokenProvider;
    /// The name sent in EHLO; '' = 'localhost'. Servers on port 25 may
    /// check it: use the client's public host name there.
    HeloName: string;
    /// Each wait's deadline; 0 = SMTP_DEFAULT_TIMEOUT_MS.
    TimeoutMs: Cardinal;
    /// True: a refused recipient fails the whole send (RSET, nothing sent).
    RequireAllRecipients: Boolean;
    Tcp: TPcTcpOptions;
    Tls: TPcTlsOptions;
    class function Create(const AHost: string; APort: Word = 0;
      ASecurity: TSmtpSecurity = ssStartTls): TSmtpOptions; static;
    function EffectivePort: Word;
  end;

  /// How the sender gets its connections; the default uses
  /// PascalCommon.Transport. Tests replace it.
  ISmtpConnector = interface
    ['{A6B3D8F1-2C4E-4F09-9B7A-E15D3C8F6A20}']
    function Connect(const AHost: string; APort: Word; const ATcp: TPcTcpOptions): TPcEndpoint;
    function ConnectTls(const AHost: string; APort: Word; const ATcp: TPcTcpOptions;
      const ATls: TPcTlsOptions): TPcEndpoint;
    /// Takes ownership of AInner, also when it raises.
    function StartTls(AInner: TPcEndpoint; const AHost: string;
      const ATls: TPcTlsOptions): TPcEndpoint;
  end;

  TSmtpSender = class(TEmailSenderBase)
  private
    FOptions: TSmtpOptions;
    FConnector: ISmtpConnector;
    FIds: IEmailIdSource;
  public
    /// EEmailArgumentError for options that can't work (no host,
    /// credentials over plaintext without AllowPlaintext, XOAUTH2 without a
    /// token provider). AConnector nil = the real network; AIds nil = random
    /// ids.
    constructor Create(const AOptions: TSmtpOptions; const AConnector: ISmtpConnector = nil;
      const AIds: IEmailIdSource = nil);
    function Name: string; override;
    function Send(const AMessage: IEmailMessage): TEmailSendResult; override;
    /// One connection for every message (RSET between them); a message
    /// that fails leaves the others going. A broken connection is opened
    /// again for the next message.
    function SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes; override;
    property Options: TSmtpOptions read FOptions;
  end;

/// The default connector (PcTcpConnect, PcTlsConnect, PcTlsWrap).
function SmtpTransportConnector: ISmtpConnector;

implementation

uses
  PascalCommon.Version,
  PascalCommon.Crypto,
  PascalCommon.Utf8,
  PascalEmail.Address,
  PascalCommon.Transport.Tcp,
  PascalCommon.Transport.Tls,
  PascalCommon.Tracing,
  PascalEmail.Telemetry;

{$IF PASCALCOMMON_VERSION < 13200}
  {$MESSAGE FATAL 'pascal-email-faa needs pascal-common-faa 1.32.0 or later'}
{$IFEND}

const
  CRLF = #13#10;
  MAX_REPLY_LINE = 4096;
  MAX_REPLY_LINES = 200;

type
  TTransportConnector = class(TInterfacedObject, ISmtpConnector)
  public
    function Connect(const AHost: string; APort: Word; const ATcp: TPcTcpOptions): TPcEndpoint;
    function ConnectTls(const AHost: string; APort: Word; const ATcp: TPcTcpOptions;
      const ATls: TPcTlsOptions): TPcEndpoint;
    function StartTls(AInner: TPcEndpoint; const AHost: string;
      const ATls: TPcTlsOptions): TPcEndpoint;
  end;

  TSmtpReply = record
    Code: Integer;
    EnhancedCode: string;
    /// Every line's text after the code, joined by ' '.
    Text: string;
    Lines: TArray<string>;
  end;

  { One connection and its conversation. Raises EEmailError classes only;
    Broken says whether the connection can still be used. }
  TSmtpSession = class
  private
    FOptions: TSmtpOptions;
    FConnector: ISmtpConnector;
    FEndpoint: TPcEndpoint;
    FBuffer: TBytes;
    FBufPos: Integer;
    FBufLen: Integer;
    FBroken: Boolean;
    FTls: Boolean;
    FExtensions: TArray<string>;
    FMaxSize: Int64;
    function ReadLine: string;
    function ReadReply: TSmtpReply;
    procedure WriteText(const AText: string);
    procedure WriteBytes(const ABytes: TBytes);
    function Command(const ALine: string): TSmtpReply;
    procedure Ehlo;
    function HasExtension(const AName: string): Boolean;
    function ExtensionParams(const AName: string): string;
    procedure Authenticate;
    procedure FailOnReply(const AStep: string; const AReply: TSmtpReply);
    procedure TransportFailed(const AStep: string; E: Exception);
  public
    constructor Create(const AOptions: TSmtpOptions; const AConnector: ISmtpConnector);
    destructor Destroy; override;
    procedure Open;
    function SendOne(const AMime: TEmailMime; const AMessage: IEmailMessage): TEmailSendResult;
    procedure Reset;
    procedure Quit;
    property Broken: Boolean read FBroken;
  end;

{ TTransportConnector }

function TTransportConnector.Connect(const AHost: string; APort: Word;
  const ATcp: TPcTcpOptions): TPcEndpoint;
begin
  Result := PcTcpConnect(AHost, APort, ATcp);
end;

function TTransportConnector.ConnectTls(const AHost: string; APort: Word;
  const ATcp: TPcTcpOptions; const ATls: TPcTlsOptions): TPcEndpoint;
begin
  Result := PcTlsConnect(AHost, APort, ATcp, ATls);
end;

function TTransportConnector.StartTls(AInner: TPcEndpoint; const AHost: string;
  const ATls: TPcTlsOptions): TPcEndpoint;
begin
  Result := PcTlsWrap(AInner, AHost, ATls);
end;

function SmtpTransportConnector: ISmtpConnector;
begin
  Result := TTransportConnector.Create;
end;

{ TSmtpOptions }

class function TSmtpOptions.Create(const AHost: string; APort: Word;
  ASecurity: TSmtpSecurity): TSmtpOptions;
begin
  Result := Default(TSmtpOptions);
  Result.Host := AHost;
  Result.Port := APort;
  Result.Security := ASecurity;
end;

function TSmtpOptions.EffectivePort: Word;
begin
  Result := Port;
  if Result = 0 then
    case Security of
      ssStartTls: Result := 587;
      ssImplicitTls: Result := 465;
    else
      Result := 25;
    end;
end;

{ Helpers }

function Base64Text(const AText: string): string;
begin
  Result := PcBase64Encode(PcStringToUtf8Bytes(AText));
end;

// Reply text as a string: ASCII as is, anything else '?' (replies are
// ASCII; a server's odd byte must not make the error itself fail).
function AsciiText(const ABytes: TBytes; AStart, ACount: Integer): string;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    if ABytes[AStart + I] < 128 then
      Result[I + 1] := Char(ABytes[AStart + I])
    else
      Result[I + 1] := '?';
end;

function IsDigits(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if not CharInSet(S[I], ['0'..'9']) then
      Exit(False);
end;

// '5.1.1' and the like (RFC 3463): class.subject.detail.
function IsEnhancedCode(const S: string): Boolean;
var
  LDot1, LDot2: Integer;
  LRest: string;
begin
  Result := False;
  LDot1 := Pos('.', S);
  if (LDot1 <> 2) or not CharInSet(S[1], ['2', '4', '5']) then
    Exit;
  LRest := Copy(S, LDot1 + 1, MaxInt);
  LDot2 := Pos('.', LRest);
  Result := (LDot2 > 1) and IsDigits(Copy(LRest, 1, LDot2 - 1)) and
    IsDigits(Copy(LRest, LDot2 + 1, MaxInt));
end;

// The id a server gives in its final DATA reply: 'queued as ABC123' (Postfix,
// Mailpit), else the reply's text without its enhanced code.
function ProviderIdFromReply(const AReply: TSmtpReply): string;
var
  LPos: Integer;
  LText: string;
begin
  LText := AReply.Text;
  LPos := Pos('queued as ', LowerCase(LText));
  if LPos > 0 then
  begin
    Result := Trim(Copy(LText, LPos + Length('queued as '), MaxInt));
    LPos := Pos(' ', Result);
    if LPos > 0 then
      Result := Copy(Result, 1, LPos - 1);
    Exit;
  end;
  if (AReply.EnhancedCode <> '') and (Pos(AReply.EnhancedCode, LText) = 1) then
    LText := Trim(Copy(LText, Length(AReply.EnhancedCode) + 1, MaxInt));
  Result := LText;
end;

// Dot-stuffing (RFC 5321 section 4.5.2) and the final '.'. AData ends with
// CRLF (the MIME writer's output always does).
function DotStuffed(const AData: TBytes): TBytes;
var
  I, LOut, LExtra: Integer;
  LLineStart: Boolean;
begin
  LExtra := 0;
  LLineStart := True;
  for I := 0 to High(AData) do
  begin
    if LLineStart and (AData[I] = Ord('.')) then
      Inc(LExtra);
    LLineStart := AData[I] = 10;
  end;
  SetLength(Result, Length(AData) + LExtra + 3);
  LOut := 0;
  LLineStart := True;
  for I := 0 to High(AData) do
  begin
    if LLineStart and (AData[I] = Ord('.')) then
    begin
      Result[LOut] := Ord('.');
      Inc(LOut);
    end;
    Result[LOut] := AData[I];
    Inc(LOut);
    LLineStart := AData[I] = 10;
  end;
  Result[LOut] := Ord('.');
  Result[LOut + 1] := 13;
  Result[LOut + 2] := 10;
end;

{ TSmtpSession }

constructor TSmtpSession.Create(const AOptions: TSmtpOptions; const AConnector: ISmtpConnector);
begin
  inherited Create;
  FOptions := AOptions;
  FConnector := AConnector;
  SetLength(FBuffer, 8192);
end;

destructor TSmtpSession.Destroy;
begin
  FEndpoint.Free;
  inherited Destroy;
end;

procedure TSmtpSession.TransportFailed(const AStep: string; E: Exception);
begin
  FBroken := True;
  raise EEmailTransient.CreateReply(Format('SMTP %s:%d, %s: %s (%s)',
    [FOptions.Host, FOptions.EffectivePort, AStep, E.Message, E.ClassName]), 0, '', '');
end;

function TSmtpSession.ReadLine: string;
var
  I, LStart: Integer;
begin
  Result := '';
  while True do
  begin
    LStart := FBufPos;
    for I := FBufPos to FBufLen - 1 do
      if FBuffer[I] = 10 then
      begin
        Result := Result + AsciiText(FBuffer, LStart, I - LStart);
        FBufPos := I + 1;
        if (Result <> '') and (Result[Length(Result)] = #13) then
          SetLength(Result, Length(Result) - 1);
        Exit;
      end;
    Result := Result + AsciiText(FBuffer, LStart, FBufLen - LStart);
    if Length(Result) > MAX_REPLY_LINE then
      raise EPcTransport.Create('reply line too long');
    FBufPos := 0;
    FBufLen := FEndpoint.Read(FBuffer[0], Length(FBuffer));
  end;
end;

function TSmtpSession.ReadReply: TSmtpReply;
var
  LLine, LText: string;
  LWords: Integer;
begin
  Result := Default(TSmtpReply);
  while True do
  begin
    LLine := ReadLine;
    if (Length(LLine) < 3) or not IsDigits(Copy(LLine, 1, 3)) or
      ((Length(LLine) > 3) and (LLine[4] <> ' ') and (LLine[4] <> '-')) then
      raise EPcTransport.CreateFmt('not an SMTP reply: "%s"', [Copy(LLine, 1, 80)]);
    if Length(Result.Lines) >= MAX_REPLY_LINES then
      raise EPcTransport.Create('reply with too many lines');
    LText := Copy(LLine, 5, MaxInt);
    SetLength(Result.Lines, Length(Result.Lines) + 1);
    Result.Lines[High(Result.Lines)] := LText;
    if Result.Text = '' then
      Result.Text := LText
    else
      Result.Text := Result.Text + ' ' + LText;
    if (Length(LLine) = 3) or (LLine[4] = ' ') then
    begin
      Result.Code := StrToInt(Copy(LLine, 1, 3));
      Break;
    end;
  end;
  LWords := Pos(' ', Result.Text);
  if LWords = 0 then
    LWords := Length(Result.Text) + 1;
  if IsEnhancedCode(Copy(Result.Text, 1, LWords - 1)) then
    Result.EnhancedCode := Copy(Result.Text, 1, LWords - 1);
end;

procedure TSmtpSession.WriteText(const AText: string);
var
  LBytes: TBytes;
begin
  LBytes := PcStringToUtf8Bytes(AText);
  WriteBytes(LBytes);
end;

procedure TSmtpSession.WriteBytes(const ABytes: TBytes);
begin
  if Length(ABytes) > 0 then
    FEndpoint.WriteExactly(ABytes[0], Length(ABytes));
end;

function TSmtpSession.Command(const ALine: string): TSmtpReply;
begin
  try
    WriteText(ALine + CRLF);
    Result := ReadReply;
  except
    on E: EPcTransport do
      TransportFailed(Copy(ALine, 1, Pos(' ', ALine + ' ') - 1), E);
  end;
  if Result.Code = 421 then
    FBroken := True;
end;

procedure TSmtpSession.FailOnReply(const AStep: string; const AReply: TSmtpReply);
var
  LMessage: string;
begin
  LMessage := Format('SMTP %s: %d %s', [AStep, AReply.Code, AReply.Text]);
  // 530 "authentication required" (RFC 4954), as Mailpit answers MAIL FROM
  // from a client that skipped AUTH (finding 2): configuration, not a
  // refusal of this message.
  if (AReply.Code = 530) or (AReply.Code = 534) or (AReply.Code = 535) then
    raise EEmailAuthError.CreateReply(LMessage, AReply.Code, AReply.EnhancedCode, AReply.Text);
  if (AReply.Code >= 400) and (AReply.Code < 500) then
    raise EEmailTransient.CreateReply(LMessage, AReply.Code, AReply.EnhancedCode, AReply.Text);
  raise EEmailRejected.CreateReply(LMessage, AReply.Code, AReply.EnhancedCode, AReply.Text);
end;

function TSmtpSession.HasExtension(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FExtensions) do
    if SameText(FExtensions[I], AName) or
      SameText(Copy(FExtensions[I], 1, Length(AName) + 1), AName + ' ') then
      Exit(True);
  Result := False;
end;

function TSmtpSession.ExtensionParams(const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(FExtensions) do
    if SameText(Copy(FExtensions[I], 1, Length(AName) + 1), AName + ' ') then
      Exit(UpperCase(Trim(Copy(FExtensions[I], Length(AName) + 2, MaxInt))));
  Result := '';
end;

procedure TSmtpSession.Ehlo;
var
  LReply: TSmtpReply;
  LName, LSize: string;
begin
  LName := FOptions.HeloName;
  if LName = '' then
    LName := 'localhost';
  LReply := Command('EHLO ' + LName);
  FExtensions := nil;
  FMaxSize := 0;
  if LReply.Code = 250 then
  begin
    // The first line is the greeting; the others are extensions.
    FExtensions := Copy(LReply.Lines, 1, MaxInt);
    LSize := ExtensionParams('SIZE');
    if IsDigits(LSize) then
      FMaxSize := StrToInt64(LSize);
    Exit;
  end;
  if (LReply.Code >= 500) and (LReply.Code <> 554) then
  begin
    LReply := Command('HELO ' + LName);
    if LReply.Code = 250 then
      Exit;
  end;
  FailOnReply('EHLO', LReply);
end;

procedure TSmtpSession.Authenticate;
var
  LMech: TSmtpAuth;
  LReply: TSmtpReply;
  LMechs, LToken: string;

  procedure Fail(const AStep: string; const AFailed: TSmtpReply);
  var
    LMessage: string;
  begin
    LMessage := Format('SMTP %s: %d %s', [AStep, AFailed.Code, AFailed.Text]);
    if (AFailed.Code >= 400) and (AFailed.Code < 500) and (AFailed.Code <> 454) then
      raise EEmailTransient.CreateReply(LMessage, AFailed.Code, AFailed.EnhancedCode, AFailed.Text);
    raise EEmailAuthError.CreateReply(LMessage, AFailed.Code, AFailed.EnhancedCode, AFailed.Text);
  end;

begin
  LMech := FOptions.Auth;
  if LMech = saAuto then
  begin
    if FOptions.TokenProvider <> nil then
      LMech := saXOAuth2
    else if FOptions.UserName = '' then
      LMech := saNone
    else
    begin
      LMechs := ' ' + ExtensionParams('AUTH') + ' ';
      if (Pos(' PLAIN ', LMechs) = 0) and (Pos(' LOGIN ', LMechs) > 0) then
        LMech := saLogin
      else
        LMech := saPlain;
    end;
  end;
  if LMech = saNone then
    Exit;
  if not HasExtension('AUTH') then
    raise EEmailAuthError.CreateFmt('SMTP %s: the server offers no AUTH (on this connection%s)',
      [FOptions.Host, ' after EHLO']);
  if not FTls and not FOptions.AllowPlaintext then
    raise EEmailAuthError.CreateFmt('SMTP %s: refusing to send credentials without TLS ' +
      '(AllowPlaintext is off)', [FOptions.Host]);
  case LMech of
    saPlain:
      begin
        LReply := Command('AUTH PLAIN ' + Base64Text(#0 + FOptions.UserName + #0 + FOptions.Password));
        if LReply.Code <> 235 then
          Fail('AUTH PLAIN', LReply);
      end;
    saLogin:
      begin
        LReply := Command('AUTH LOGIN');
        if LReply.Code <> 334 then
          Fail('AUTH LOGIN', LReply);
        LReply := Command(Base64Text(FOptions.UserName));
        if LReply.Code <> 334 then
          Fail('AUTH LOGIN', LReply);
        LReply := Command(Base64Text(FOptions.Password));
        if LReply.Code <> 235 then
          Fail('AUTH LOGIN', LReply);
      end;
    saXOAuth2:
      begin
        LToken := FOptions.TokenProvider.AccessToken;
        LReply := Command('AUTH XOAUTH2 ' + Base64Text('user=' + FOptions.UserName + #1 +
          'auth=Bearer ' + LToken + #1#1));
        if LReply.Code = 334 then
          // The server's error details, Base64 JSON; an empty line ends the
          // exchange and brings the final (failure) reply.
          LReply := Command('');
        if LReply.Code <> 235 then
          Fail('AUTH XOAUTH2', LReply);
      end;
  end;
end;

procedure TSmtpSession.Open;
var
  LReply: TSmtpReply;
  LTimeout: Cardinal;
begin
  LTimeout := FOptions.TimeoutMs;
  if LTimeout = 0 then
    LTimeout := SMTP_DEFAULT_TIMEOUT_MS;
  try
    if FOptions.Security = ssImplicitTls then
    begin
      FEndpoint := FConnector.ConnectTls(FOptions.Host, FOptions.EffectivePort, FOptions.Tcp,
        FOptions.Tls);
      FTls := True;
    end
    else
      FEndpoint := FConnector.Connect(FOptions.Host, FOptions.EffectivePort, FOptions.Tcp);
    FEndpoint.SetIoDeadline(LTimeout);
    LReply := ReadReply;
  except
    on E: EPcTransport do
      TransportFailed('connect', E);
  end;
  if LReply.Code <> 220 then
  begin
    FBroken := True;
    FailOnReply('greeting', LReply);
  end;
  Ehlo;
  if FOptions.Security = ssStartTls then
  begin
    if HasExtension('STARTTLS') then
    begin
      LReply := Command('STARTTLS');
      if LReply.Code <> 220 then
        FailOnReply('STARTTLS', LReply);
      try
        // StartTls owns the endpoint from here, also when it raises.
        FBufPos := 0;
        FBufLen := 0;
        FEndpoint := FConnector.StartTls(FEndpoint, FOptions.Host, FOptions.Tls);
        FEndpoint.SetIoDeadline(LTimeout);
      except
        on E: EPcTransport do
        begin
          FEndpoint := nil;
          TransportFailed('STARTTLS handshake', E);
        end;
      end;
      FTls := True;
      Ehlo;
    end
    else if not FOptions.AllowPlaintext then
    begin
      FBroken := True;
      raise EEmailTransient.CreateFmt('SMTP %s:%d: the server does not offer STARTTLS ' +
        '(AllowPlaintext is off)', [FOptions.Host, FOptions.EffectivePort]);
    end;
  end;
  Authenticate;
end;

function TSmtpSession.SendOne(const AMime: TEmailMime;
  const AMessage: IEmailMessage): TEmailSendResult;
var
  LReply: TSmtpReply;
  LFrom, LMail: string;
  LRecipients: TArray<string>;
  LRejected: TEmailRejections;
  LAccepted, I: Integer;
  LAnyTransient: Boolean;
  LData: TBytes;
begin
  Result := Default(TEmailSendResult);
  Result.MessageId := AMime.MessageId;
  if (FMaxSize > 0) and (Length(AMime.Data) > FMaxSize) then
    raise EEmailRejected.CreateReply(Format('SMTP %s: the message has %d bytes, the server ' +
      'takes at most %d', [FOptions.Host, Length(AMime.Data), FMaxSize]), 552, '5.3.4', '');

  if AMessage.HasSender then
    LFrom := AMessage.Sender.Address
  else
    LFrom := AMessage.From.Address;
  LMail := 'MAIL FROM:<' + LFrom + '>';
  if HasExtension('SIZE') then
    LMail := LMail + ' SIZE=' + IntToStr(Length(AMime.Data));
  LReply := Command(LMail);
  if LReply.Code <> 250 then
    FailOnReply('MAIL FROM', LReply);

  LRecipients := AMessage.Recipients;
  LRejected := nil;
  LAccepted := 0;
  LAnyTransient := False;
  for I := 0 to High(LRecipients) do
  begin
    LReply := Command('RCPT TO:<' + LRecipients[I] + '>');
    if FBroken then
      FailOnReply('RCPT TO', LReply);
    if (LReply.Code = 250) or (LReply.Code = 251) then
      Inc(LAccepted)
    else
    begin
      SetLength(LRejected, Length(LRejected) + 1);
      LRejected[High(LRejected)].Address := LRecipients[I];
      LRejected[High(LRejected)].Code := LReply.Code;
      LRejected[High(LRejected)].EnhancedCode := LReply.EnhancedCode;
      LRejected[High(LRejected)].Text := LReply.Text;
      if LReply.Code < 500 then
        LAnyTransient := True;
    end;
  end;
  if (LAccepted = 0) or ((Length(LRejected) > 0) and FOptions.RequireAllRecipients) then
  begin
    Reset;
    LReply.Code := LRejected[0].Code;
    LReply.EnhancedCode := LRejected[0].EnhancedCode;
    LReply.Text := Format('%s refused (%d of %d recipients): %s',
      [LRejected[0].Address, Length(LRejected), Length(LRecipients), LRejected[0].Text]);
    if LAnyTransient then
      raise EEmailTransient.CreateReply('SMTP RCPT TO: ' + LReply.Text, LReply.Code,
        LReply.EnhancedCode, LReply.Text);
    raise EEmailRejected.CreateReply('SMTP RCPT TO: ' + LReply.Text, LReply.Code,
      LReply.EnhancedCode, LReply.Text);
  end;

  LReply := Command('DATA');
  if LReply.Code <> 354 then
    FailOnReply('DATA', LReply);
  LData := DotStuffed(AMime.Data);
  try
    WriteBytes(LData);
  except
    on E: EPcTransport do
      TransportFailed('DATA', E);
  end;
  // The whole message is with the server now: no reply means nobody knows.
  try
    LReply := ReadReply;
  except
    on E: EPcTransport do
    begin
      FBroken := True;
      raise EEmailOutcomeUnknown.CreateReply(Format('SMTP %s:%d: no reply after the message ' +
        'was sent; it may have been accepted (%s: %s)', [FOptions.Host, FOptions.EffectivePort,
        E.ClassName, E.Message]), 0, '', '');
    end;
  end;
  if LReply.Code <> 250 then
    FailOnReply('end of DATA', LReply);
  Result.ProviderId := ProviderIdFromReply(LReply);
  Result.Rejected := LRejected;
end;

procedure TSmtpSession.Reset;
var
  LReply: TSmtpReply;
begin
  LReply := Command('RSET');
  if LReply.Code <> 250 then
    FBroken := True;
end;

procedure TSmtpSession.Quit;
begin
  if (FEndpoint = nil) or FBroken then
    Exit;
  try
    WriteText('QUIT' + CRLF);
    ReadReply;
  except
    on E: EPcTransport do
      ; // the message is sent; a server that hangs up first is fine
  end;
end;

{ TSmtpSender }

constructor TSmtpSender.Create(const AOptions: TSmtpOptions;
  const AConnector: ISmtpConnector; const AIds: IEmailIdSource);
begin
  inherited Create;
  // The interfaces first: one created in the call (TFoo.Create passed to a
  // const parameter) has no reference until it is stored, so a raise below
  // would leak it (gotcha 1).
  FConnector := AConnector;
  if FConnector = nil then
    FConnector := SmtpTransportConnector;
  FIds := AIds;
  if Trim(AOptions.Host) = '' then
    raise EEmailArgumentError.Create('TSmtpSender: no host');
  if (AOptions.Security = ssNone) and not AOptions.AllowPlaintext and
    ((AOptions.UserName <> '') or (AOptions.TokenProvider <> nil)) then
    raise EEmailArgumentError.Create('TSmtpSender: credentials over a plaintext connection ' +
      '(ssNone); use ssStartTls or ssImplicitTls, or set AllowPlaintext');
  if (AOptions.Auth = saXOAuth2) and (AOptions.TokenProvider = nil) then
    raise EEmailArgumentError.Create('TSmtpSender: XOAUTH2 needs a TokenProvider');
  if (AOptions.Auth in [saPlain, saLogin]) and (AOptions.UserName = '') then
    raise EEmailArgumentError.Create('TSmtpSender: AUTH PLAIN/LOGIN needs a UserName');
  EmailCheckHeaderText('user name', AOptions.UserName, False);
  FOptions := AOptions;
end;

function TSmtpSender.Name: string;
begin
  Result := 'smtp';
end;

function TSmtpSender.Send(const AMessage: IEmailMessage): TEmailSendResult;
var
  LMime: TEmailMime;
  LSession: TSmtpSession;
  LRec: TEmailSendTelemetry;
begin
  LRec := TEmailSendTelemetry.Start(Name, skClient, AMessage, FOptions.Host,
    FOptions.EffectivePort);
  try
    LMime := EmailBuildMime(AMessage, FIds);
    LRec.Identify(LMime.MessageId);
    LSession := TSmtpSession.Create(FOptions, FConnector);
    try
      LSession.Open;
      Result := LSession.SendOne(LMime, AMessage);
      LSession.Quit;
    finally
      LSession.Free;
    end;
    LRec.Done(Result);
  except
    on E: Exception do
    begin
      LRec.Fail(E);
      raise;
    end;
  end;
end;

function TSmtpSender.SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes;
var
  I: Integer;
  LSession: TSmtpSession;
  LMime: TEmailMime;
  LUsed: Boolean;
  LBatch: TEmailBatchTelemetry;
  LRec: TEmailSendTelemetry;
begin
  Result := nil;
  SetLength(Result, Length(AMessages));
  LSession := nil;
  LUsed := False;
  LBatch := TEmailBatchTelemetry.Start(Name, Length(AMessages));
  try
    try
      for I := 0 to High(AMessages) do
      begin
        LRec := TEmailSendTelemetry.Start(Name, skClient, AMessages[I], FOptions.Host,
          FOptions.EffectivePort);
        try
          LMime := EmailBuildMime(AMessages[I], FIds);
          LRec.Identify(LMime.MessageId);
          // The previous message's transaction is closed with RSET; a
          // connection that fails it (or failed before) is replaced, so its
          // failure is never charged to this message.
          if (LSession <> nil) and LUsed and not LSession.Broken then
            try
              LSession.Reset;
            except
              on E: EEmailError do
                ;
            end;
          if (LSession <> nil) and LSession.Broken then
            FreeAndNil(LSession);
          if LSession = nil then
          begin
            LSession := TSmtpSession.Create(FOptions, FConnector);
            LUsed := False;
            try
              LSession.Open;
            except
              // Half-open (EHLO or AUTH refused): never reused.
              FreeAndNil(LSession);
              raise;
            end;
          end;
          LUsed := True;
          Result[I] := EmailSentOutcome(LSession.SendOne(LMime, AMessages[I]));
          LRec.Done(Result[I].SendResult);
        except
          on E: EEmailError do
          begin
            LRec.Fail(E);
            Result[I] := EmailFailedOutcome(E);
          end;
          on E: Exception do
          begin
            LRec.Fail(E);
            raise;
          end;
        end;
      end;
      if LSession <> nil then
        LSession.Quit;
    finally
      LSession.Free;
    end;
    LBatch.Done(Result);
  except
    on E: Exception do
    begin
      LBatch.Fail(E);
      raise;
    end;
  end;
end;

end.
