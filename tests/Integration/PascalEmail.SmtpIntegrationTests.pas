unit PascalEmail.SmtpIntegrationTests;

{ The SMTP sender against real servers: Mailpit in Docker, three ways
  (tools/mailpit.sh; PascalEmail.IntegrationEnv says where). What the unit
  suite can't show: STARTTLS and implicit TLS through PascalCommon.Transport
  on both TLS backends (SChannel and OpenSSL where the platform has both),
  the certificate checks (private CA, wrong host name, unknown CA), a real
  server's AUTH and recipient refusals, and a real MIME parser's view of
  what the library writes (Mailpit's JSON: decoded subject, names, bodies,
  attachments). The raw message Mailpit stored must be the library's MIME
  byte for byte, after the Return-Path and Received lines it adds.

  The expected replies were measured first with a probe (docs/findings.md,
  findings 1-6).

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalEmail.DUnitXCompat). The mirror in tests/Integration/fpc is
  generated from the master by tools/gen_fpc_mirror.py: edit only the
  master. }

interface

uses
  DUnitX.TestFramework,
  PascalEmail.DUnitXCompat,
  SysUtils,
  Classes,
  PascalCommon.Transport,
  PascalEmail.Errors,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.Interfaces,
  PascalEmail.Smtp,
  PascalEmail.TestSupport,
  PascalEmail.IntegrationEnv;

type
  [TestFixture]
  TSmtpIntegrationTests = class
  private
    function Msg(const ASubject: string): IEmailMessage;
    function SendError(const AOptions: TSmtpOptions): string;
  public
    [Setup] procedure Setup;
    [Test] procedure StartTls_Auth_Delivered_ByteForByte;
    [Test] procedure StartTls_OpenSsl_Delivered;
    [Test] procedure ImplicitTls_Delivered;
    [Test] procedure Parsed_SubjectNamesBodiesAttachments;
    [Test] procedure Bcc_ReceivesButIsNotInTheHeaders;
    [Test] procedure LargeAttachment_Delivered;
    [Test] procedure WrongPassword_AuthError;
    [Test] procedure NoAuth_OnAServerThatRequiresIt_AuthError;
    [Test] procedure WrongHostName_Refused;
    [Test] procedure UnknownCa_Refused;
    [Test] procedure ServerWithoutStartTls_Refused;
    [Test] procedure ServerWithoutStartTls_AllowPlaintext_Delivered;
    [Test] procedure PlainRelay_NoAuth_Delivered;
    [Test] procedure PartialRefusal_DeliveredToTheOthers;
    [Test] procedure AllRefused_Rejected;
    [Test] procedure ClosedPort_Transient;
    [Test] procedure SendMany_OneConnection_AllDelivered;
    [Test] procedure SharedSender_FourThreads_AllDelivered;
  end;

implementation

type
  { Sends ACount messages through a shared sender (no anonymous threads:
    stable FPC has none). }
  TSendThread = class(TThread)
  private
    FSender: IEmailSender;
    FCount: Integer;
    FTag: string;
    FFailures: Integer;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASender: IEmailSender; ACount: Integer; const ATag: string);
    property Failures: Integer read FFailures;
    property Error: string read FError;
  end;

constructor TSendThread.Create(const ASender: IEmailSender; ACount: Integer; const ATag: string);
begin
  FSender := ASender;
  FCount := ACount;
  FTag := ATag;
  inherited Create(False);
end;

procedure TSendThread.Execute;
var
  I: Integer;
begin
  for I := 1 to FCount do
    try
      FSender.Send(TEmailMessage.New.SetFrom('app@example.com').AddTo('bob@example.com')
        .SetSubject(Format('thread %s message %d', [FTag, I])).SetText('x'));
    except
      on E: Exception do
      begin
        Inc(FFailures);
        FError := E.ClassName + ': ' + E.Message;
      end;
    end;
end;

const
  CRLF = #13#10;

procedure TSmtpIntegrationTests.Setup;
begin
  MailpitClear(StartTlsApi);
  MailpitClear(TlsApi);
  MailpitClear(PlainApi);
end;

function TSmtpIntegrationTests.Msg(const ASubject: string): IEmailMessage;
begin
  Result := TEmailMessage.New.SetFrom('app@example.com', 'App').AddTo('bob@example.com', 'Bob')
    .SetSubject(ASubject).SetText('Olá, Bob.');
end;

function TSmtpIntegrationTests.SendError(const AOptions: TSmtpOptions): string;
var
  LSender: IEmailSender;
begin
  Result := '';
  try
    LSender := TSmtpSender.Create(AOptions);
    LSender.Send(Msg('should fail'));
  except
    on E: Exception do
      Result := E.ClassName;
  end;
end;

procedure TSmtpIntegrationTests.StartTls_Auth_Delivered_ByteForByte;
var
  LSender: IEmailSender;
  LMessage: IEmailMessage;
  LMime: string;
  R: TEmailSendResult;
  LJson, LRaw: string;
begin
  // A fixed date and counting ids, so the MIME can be written again here.
  LMessage := Msg('Relatório — março').SetDate(EncodeDate(2026, 3, 1))
    .SetHtml('<p>Olá</p>').Attach('dados.csv', SampleBytes(500));
  LSender := TSmtpSender.Create(StartTlsOptions, nil, TCountingIdSource.Create);
  R := LSender.Send(LMessage);
  LMime := EmailBuildMime(LMessage, TCountingIdSource.Create).AsText;
  TAssert.AssertEquals('id1@example.com', R.MessageId);
  TAssert.AssertEquals(1, MailpitCount(StartTlsApi));
  // On Mailpit, ProviderId ("queued as ...") is the API's id (finding 3).
  LJson := MailpitJson(StartTlsApi, R.ProviderId);
  TAssert.AssertEquals('id1@example.com', JsonField(LJson, 'MessageID'));
  TAssert.AssertEquals('Relatório — março', JsonField(LJson, 'Subject'));
  LRaw := MailpitRaw(StartTlsApi, R.ProviderId);
  TAssert.AssertTrue('Return-Path first', Pos('Return-Path: <app@example.com>', LRaw) = 1);
  TAssert.AssertTrue('then our MIME, byte for byte, to the end',
    Copy(LRaw, Length(LRaw) - Length(LMime) + 1, MaxInt) = LMime);
  TAssert.AssertTrue('right after Mailpit''s Received header',
    Pos(CRLF + LMime, LRaw) > Pos('Received: ', LRaw));
end;

procedure TSmtpIntegrationTests.StartTls_OpenSsl_Delivered;
var
  O: TSmtpOptions;
  LSender: IEmailSender;
  R: TEmailSendResult;
begin
  O := StartTlsOptions;
  O.Tls.Backend := tbOpenSsl;
  LSender := TSmtpSender.Create(O);
  R := LSender.Send(Msg('via OpenSSL'));
  TAssert.AssertEquals('via OpenSSL', JsonField(MailpitJson(StartTlsApi, R.ProviderId), 'Subject'));
end;

procedure TSmtpIntegrationTests.ImplicitTls_Delivered;
var
  LSender: IEmailSender;
  R: TEmailSendResult;
begin
  LSender := TSmtpSender.Create(TlsOptions);
  R := LSender.Send(Msg('implicit TLS'));
  TAssert.AssertEquals('implicit TLS', JsonField(MailpitJson(TlsApi, R.ProviderId), 'Subject'));
  TAssert.AssertEquals(1, MailpitCount(TlsApi));
end;

procedure TSmtpIntegrationTests.Parsed_SubjectNamesBodiesAttachments;
var
  LSender: IEmailSender;
  R: TEmailSendResult;
  LJson, LSubject: string;
  I: Integer;
begin
  LSubject := '';
  for I := 1 to 6 do
    LSubject := LSubject + 'Relatório de vendas ' + IntToStr(I) + ' — ação ';
  LSubject := Trim(LSubject);
  LSender := TSmtpSender.Create(StartTlsOptions);
  R := LSender.Send(TEmailMessage.New.SetFrom('app@example.com', 'Souza, Ana')
    .AddTo('joao@example.com', 'João Conceição').AddCc('carl@example.com', 'Dr. "C"')
    .AddReplyTo('help@example.com', 'Atendimento').SetSubject(LSubject)
    .SetText('Olá João,'#10'.linha com ponto'#10'fim')
    .SetHtml('<p>Olá <b>João</b> <img src="cid:logo"></p>')
    .Embed('logo', 'logo.png', SampleBytes(300))
    .Attach('relatório de março.pdf', SampleBytes(1000)));
  LJson := MailpitJson(StartTlsApi, R.ProviderId);
  TAssert.AssertEquals('subject', LSubject, JsonField(LJson, 'Subject'));
  TAssert.AssertTrue('from name', Pos('"From":{"Name":"Souza, Ana","Address":"app@example.com"}',
    LJson) > 0);
  TAssert.AssertTrue('to name', Pos('{"Name":"João Conceição","Address":"joao@example.com"}',
    LJson) > 0);
  TAssert.AssertTrue('cc name', Pos('{"Name":"Dr. \"C\"","Address":"carl@example.com"}',
    LJson) > 0);
  TAssert.AssertTrue('reply-to', Pos('"ReplyTo":[{"Name":"Atendimento"', LJson) > 0);
  TAssert.AssertEquals('text', 'Olá João,'#13#10'.linha com ponto'#13#10'fim',
    JsonField(LJson, 'Text'));
  TAssert.AssertTrue('html', Pos('<p>Olá <b>João</b>', JsonField(LJson, 'HTML')) = 1);
  TAssert.AssertTrue('attachment name and size',
    Pos('"FileName":"relatório de março.pdf","ContentType":"application/pdf"', LJson) > 0);
  TAssert.AssertTrue('attachment size', Pos('"Size":1000', LJson) > 0);
  TAssert.AssertTrue('inline image', Pos('"Inline":[{"PartID":', LJson) > 0);
  TAssert.AssertTrue('inline content id', Pos('"ContentID":"logo"', LJson) > 0);
end;

procedure TSmtpIntegrationTests.Bcc_ReceivesButIsNotInTheHeaders;
var
  LSender: IEmailSender;
  R: TEmailSendResult;
  LRaw: string;
begin
  LSender := TSmtpSender.Create(StartTlsOptions);
  R := LSender.Send(Msg('bcc').AddBcc('hidden@example.com'));
  LRaw := MailpitRaw(StartTlsApi, R.ProviderId);
  // Mailpit itself puts a "Bcc:" line above its Return-Path, to record the
  // envelope-only recipients (finding 4); what the library sent starts after
  // Mailpit's lines.
  LRaw := Copy(LRaw, Pos('Return-Path:', LRaw), MaxInt);
  TAssert.AssertEquals('not in the headers', 0, Pos('Bcc:', LRaw));
  TAssert.AssertTrue('but in the envelope (Mailpit lists it)',
    Pos('"Bcc":[{"Name":"","Address":"hidden@example.com"}]',
    MailpitJson(StartTlsApi, R.ProviderId)) > 0);
end;

procedure TSmtpIntegrationTests.LargeAttachment_Delivered;
var
  LSender: IEmailSender;
  R: TEmailSendResult;
begin
  LSender := TSmtpSender.Create(StartTlsOptions);
  R := LSender.Send(Msg('large').Attach('big.bin', SampleBytes(3 * 1024 * 1024)));
  TAssert.AssertTrue(Pos('"Size":3145728', MailpitJson(StartTlsApi, R.ProviderId)) > 0);
end;

procedure TSmtpIntegrationTests.WrongPassword_AuthError;
var
  O: TSmtpOptions;
  LSender: IEmailSender;
begin
  O := StartTlsOptions;
  O.Password := 'wrong';
  LSender := TSmtpSender.Create(O);
  try
    LSender.Send(Msg('x'));
    TAssert.Fail('a wrong password sent the message');
  except
    on E: EEmailAuthError do
    begin
      TAssert.AssertEquals(535, E.Code);
      TAssert.AssertEquals('5.7.8', E.EnhancedCode);
    end;
  end;
  TAssert.AssertEquals(0, MailpitCount(StartTlsApi));
end;

procedure TSmtpIntegrationTests.NoAuth_OnAServerThatRequiresIt_AuthError;
var
  O: TSmtpOptions;
begin
  O := StartTlsOptions;
  O.UserName := '';
  O.Password := '';
  // Mailpit answers MAIL FROM with 530 5.7.0 (finding 2).
  TAssert.AssertEquals('EEmailAuthError', SendError(O));
end;

procedure TSmtpIntegrationTests.WrongHostName_Refused;
var
  O: TSmtpOptions;
begin
  O := TlsOptions;
  O.Host := TlsWrongHost;
  TAssert.AssertEquals('EEmailTransient', SendError(O));
  O := StartTlsOptions;
  O.Host := TlsWrongHost;
  O.Port := TlsPort;
  O.Security := ssImplicitTls;
  TAssert.AssertEquals('EEmailTransient', SendError(O));
  TAssert.AssertEquals(0, MailpitCount(TlsApi));
end;

procedure TSmtpIntegrationTests.UnknownCa_Refused;
var
  O: TSmtpOptions;
begin
  O := TlsOptions;
  O.Tls.CaFile := '';
  TAssert.AssertEquals('implicit', 'EEmailTransient', SendError(O));
  O := StartTlsOptions;
  O.Tls.CaFile := '';
  TAssert.AssertEquals('STARTTLS', 'EEmailTransient', SendError(O));
  TAssert.AssertEquals(0, MailpitCount(StartTlsApi));
end;

procedure TSmtpIntegrationTests.ServerWithoutStartTls_Refused;
var
  O: TSmtpOptions;
begin
  O := PlainOptions;
  O.Security := ssStartTls;
  TAssert.AssertEquals('EEmailTransient', SendError(O));
  TAssert.AssertEquals(0, MailpitCount(PlainApi));
end;

procedure TSmtpIntegrationTests.ServerWithoutStartTls_AllowPlaintext_Delivered;
var
  O: TSmtpOptions;
  LSender: IEmailSender;
begin
  O := PlainOptions;
  O.Security := ssStartTls;
  O.AllowPlaintext := True;
  LSender := TSmtpSender.Create(O);
  LSender.Send(Msg('plaintext allowed'));
  TAssert.AssertEquals(1, MailpitCount(PlainApi));
end;

procedure TSmtpIntegrationTests.PlainRelay_NoAuth_Delivered;
var
  LSender: IEmailSender;
  R: TEmailSendResult;
begin
  LSender := TSmtpSender.Create(PlainOptions);
  R := LSender.Send(Msg('relay'));
  TAssert.AssertEquals('relay', JsonField(MailpitJson(PlainApi, R.ProviderId), 'Subject'));
end;

procedure TSmtpIntegrationTests.PartialRefusal_DeliveredToTheOthers;
var
  LSender: IEmailSender;
  R: TEmailSendResult;
begin
  LSender := TSmtpSender.Create(StartTlsOptions);
  R := LSender.Send(Msg('partial').AddTo('nobody@refused.example'));
  TAssert.AssertEquals(1, Length(R.Rejected));
  TAssert.AssertEquals('nobody@refused.example', R.Rejected[0].Address);
  TAssert.AssertEquals(550, R.Rejected[0].Code);
  TAssert.AssertEquals(1, MailpitCount(StartTlsApi));
end;

procedure TSmtpIntegrationTests.AllRefused_Rejected;
var
  LSender: IEmailSender;
begin
  LSender := TSmtpSender.Create(StartTlsOptions);
  try
    LSender.Send(TEmailMessage.New.SetFrom('app@example.com').AddTo('a@refused.example')
      .AddTo('b@refused.example').SetSubject('x'));
    TAssert.Fail('sent with every recipient refused');
  except
    on E: EEmailRejected do
      TAssert.AssertEquals(550, E.Code);
  end;
  TAssert.AssertEquals(0, MailpitCount(StartTlsApi));
end;

procedure TSmtpIntegrationTests.ClosedPort_Transient;
var
  O: TSmtpOptions;
begin
  O := PlainOptions;
  O.Port := 1;
  O.Tcp.ConnectTimeoutMs := 3000;
  TAssert.AssertEquals('EEmailTransient', SendError(O));
end;

procedure TSmtpIntegrationTests.SendMany_OneConnection_AllDelivered;
var
  LSender: IEmailSender;
  O: TEmailSendOutcomes;
  I: Integer;
begin
  LSender := TSmtpSender.Create(StartTlsOptions);
  O := LSender.SendMany([Msg('many 1'), Msg('many 2').AddTo('x@refused.example'),
    TEmailMessage.New.SetFrom('app@example.com').AddTo('only@refused.example'), Msg('many 4')]);
  TAssert.AssertTrue(O[0].Sent);
  TAssert.AssertTrue(O[1].Sent);
  TAssert.AssertEquals('partial refusal reported', 1, Length(O[1].SendResult.Rejected));
  TAssert.AssertFalse(O[2].Sent);
  TAssert.AssertTrue(O[2].ErrorClass = EEmailRejected);
  TAssert.AssertTrue(O[3].Sent);
  TAssert.AssertEquals(3, MailpitCount(StartTlsApi));
  for I := 0 to 3 do
    if O[I].Sent then
      TAssert.AssertTrue(JsonField(MailpitJson(StartTlsApi, O[I].SendResult.ProviderId),
        'Subject') <> '');
end;

procedure TSmtpIntegrationTests.SharedSender_FourThreads_AllDelivered;
var
  LSender: IEmailSender;
  LThreads: array[0..3] of TSendThread;
  I, LFailures: Integer;
  LError: string;
begin
  LSender := TSmtpSender.Create(StartTlsOptions);
  for I := 0 to High(LThreads) do
    LThreads[I] := TSendThread.Create(LSender, 5, IntToStr(I));
  LFailures := 0;
  LError := '';
  for I := 0 to High(LThreads) do
  begin
    LThreads[I].WaitFor;
    Inc(LFailures, LThreads[I].Failures);
    if LThreads[I].Error <> '' then
      LError := LThreads[I].Error;
    LThreads[I].Free;
  end;
  TAssert.AssertEquals('failures (' + LError + ')', 0, LFailures);
  TAssert.AssertEquals(20, MailpitCount(StartTlsApi));
end;

initialization
  TDUnitX.RegisterTestFixture(TSmtpIntegrationTests);

end.
