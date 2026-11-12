unit PascalEmail.SmtpTests;

{ Tests for the SMTP conversation (PascalEmail.Smtp) against a scripted
  server (PascalEmail.TestSupport's TFakeSmtpServer): what the client says
  and in what order, and how each reply and each broken connection maps onto
  the error classes (design, E8): STARTTLS required by default, AUTH
  PLAIN/LOGIN/XOAUTH2 and their refusals, partial and total recipient
  refusal (E7), SIZE, a connection lost before and after the message was
  handed over, HELO fallback, SendMany on one connection and its recovery
  from a broken one. The TLS itself, and a real server's view of the
  message, are the integration suite's (Mailpit).

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalEmail.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalEmail.DUnitXCompat,
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.Interfaces,
  PascalEmail.Smtp,
  PascalEmail.TestSupport;

type
  [TestFixture]
  TSmtpTests = class
  private
    FServer: TFakeSmtpServer;
    FConnector: ISmtpConnector;
    function Options: TSmtpOptions;
    function Sender(const AOptions: TSmtpOptions): IEmailSender;
    function Msg: IEmailMessage;
    /// Greeting, EHLO with STARTTLS, 220, EHLO with AUTH and SIZE, 235.
    procedure ScriptLogin;
    function SendError(const AOptions: TSmtpOptions; const AMessage: IEmailMessage): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure Send_StartTls_AuthPlain_Conversation;
    [Test] procedure Send_Result_ProviderIdAndMessageId;
    [Test] procedure Send_MessageEndsWithDot_AndIsTheMime;
    [Test] procedure Send_DefaultPorts;
    [Test] procedure StartTls_NotOffered_Refused;
    [Test] procedure StartTls_NotOffered_AllowPlaintext_GoesOn;
    [Test] procedure ImplicitTls_NoStartTls;
    [Test] procedure None_WithCredentials_RefusedAtCreate;
    [Test] procedure Auth_Refused_IsAuthError;
    [Test] procedure Auth_LoginWhenOnlyLoginOffered;
    [Test] procedure Auth_NoAuthOffered_IsAuthError;
    [Test] procedure Auth_XOAuth2_TokenAndFailure;
    [Test] procedure Auth_None_WithoutUser;
    [Test] procedure Rcpt_PartialRefusal_ReportedInResult;
    [Test] procedure Rcpt_AllRefused_Rejected_WithRset;
    [Test] procedure Rcpt_RequireAll_Rejected;
    [Test] procedure Rcpt_AllTemporary_Transient;
    [Test] procedure Mail_Temporary_Transient;
    [Test] procedure Data_Refused_Rejected;
    [Test] procedure Size_TooBig_RejectedBeforeMail;
    [Test] procedure Greeting_421_Transient;
    [Test] procedure Connect_Refused_Transient;
    [Test] procedure Dropped_BeforeTheMessage_Transient;
    [Test] procedure Dropped_WhileWritingTheMessage_Transient;
    [Test] procedure Dropped_AfterTheMessage_OutcomeUnknown;
    [Test] procedure Ehlo_Refused_FallsBackToHelo;
    [Test] procedure MultiLineReply_And_EnhancedCode;
    [Test] procedure SendMany_OneConnection_RsetBetween;
    [Test] procedure SendMany_OneRefused_OthersGo;
    [Test] procedure SendMany_ReconnectsAfterADrop;
    [Test] procedure Envelope_UsesSender_WhenSet;
  end;

implementation

const
  EHLO_TLS = '250-mail.example.com|250-STARTTLS|250 8BITMIME';
  EHLO_AUTH = '250-mail.example.com|250-AUTH PLAIN LOGIN|250-SIZE 1000000|250 8BITMIME';

procedure TSmtpTests.Setup;
begin
  FServer := TFakeSmtpServer.Create;
  FConnector := FServer;
end;

procedure TSmtpTests.TearDown;
begin
  FConnector := nil;
  FServer := nil;
end;

function TSmtpTests.Options: TSmtpOptions;
begin
  Result := TSmtpOptions.Create('mail.example.com');
  Result.UserName := 'user';
  Result.Password := 'pass';
end;

function TSmtpTests.Sender(const AOptions: TSmtpOptions): IEmailSender;
begin
  Result := TSmtpSender.Create(AOptions, FConnector, TCountingIdSource.Create);
end;

function TSmtpTests.Msg: IEmailMessage;
begin
  Result := TEmailMessage.New.SetFrom('ana@example.com', 'Ana').AddTo('bob@example.com')
    .AddCc('carl@example.com').SetSubject('Hi').SetText('Hello');
end;

procedure TSmtpTests.ScriptLogin;
begin
  FServer.Reply('220 mail.example.com ESMTP');
  FServer.Reply(EHLO_TLS);
  FServer.Reply('220 2.0.0 Ready to start TLS');
  FServer.Reply(EHLO_AUTH);
  FServer.Reply('235 2.7.0 Authentication successful');
end;

function TSmtpTests.SendError(const AOptions: TSmtpOptions;
  const AMessage: IEmailMessage): string;
begin
  Result := '';
  try
    Sender(AOptions).Send(AMessage);
  except
    on E: Exception do
      Result := E.ClassName;
  end;
end;

procedure TSmtpTests.Send_StartTls_AuthPlain_Conversation;
var
  LSize: Integer;
begin
  ScriptLogin;
  FServer.Reply('250 2.1.0 Ok');
  FServer.Reply('250 2.1.5 Ok');
  FServer.Reply('250 2.1.5 Ok');
  FServer.Reply('354 End data with <CR><LF>.<CR><LF>');
  FServer.Reply('250 2.0.0 Ok: queued as 4F3D2A1');
  FServer.Reply('221 2.0.0 Bye');
  Sender(Options).Send(Msg);
  LSize := Length(EmailBuildMime(Msg, TCountingIdSource.Create).Data);
  // AUTH PLAIN's argument is Base64 of #0'user'#0'pass'.
  TAssert.AssertEquals('EHLO localhost|STARTTLS|EHLO localhost|AUTH PLAIN AHVzZXIAcGFzcw==|' +
    'MAIL FROM:<ana@example.com> SIZE=' + IntToStr(LSize) + '|RCPT TO:<bob@example.com>|' +
    'RCPT TO:<carl@example.com>|DATA|QUIT', FServer.Commands);
  TAssert.AssertEquals(1, FServer.StartTlsCount);
  TAssert.AssertEquals(0, FServer.TlsConnects);
  TAssert.AssertEquals(0, FServer.Pending);
end;

procedure TSmtpTests.Send_Result_ProviderIdAndMessageId;
var
  R: TEmailSendResult;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 2.0.0 Ok: queued as 4F3D2A1');
  FServer.Reply('221 Bye');
  R := Sender(Options).Send(Msg);
  TAssert.AssertEquals('4F3D2A1', R.ProviderId);
  TAssert.AssertEquals('id1@example.com', R.MessageId);
  TAssert.AssertEquals(0, Length(R.Rejected));
end;

procedure TSmtpTests.Send_MessageEndsWithDot_AndIsTheMime;
var
  LMime, LTranscript: string;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 2.0.0 OK id=1abc');
  FServer.Reply('221 Bye');
  Sender(Options).Send(Msg);
  LMime := EmailBuildMime(Msg, TCountingIdSource.Create).AsText;
  LTranscript := FServer.Transcript;
  TAssert.AssertTrue('the MIME, then the final dot', Pos('DATA'#13#10 + LMime + '.'#13#10 +
    'QUIT'#13#10, LTranscript) > 0);
end;

procedure TSmtpTests.Send_DefaultPorts;
var
  O: TSmtpOptions;
begin
  O := TSmtpOptions.Create('h');
  TAssert.AssertEquals(587, Integer(O.EffectivePort));
  O := TSmtpOptions.Create('h', 0, ssImplicitTls);
  TAssert.AssertEquals(465, Integer(O.EffectivePort));
  O := TSmtpOptions.Create('h', 0, ssNone);
  TAssert.AssertEquals(25, Integer(O.EffectivePort));
  O := TSmtpOptions.Create('h', 2525, ssNone);
  TAssert.AssertEquals(2525, Integer(O.EffectivePort));
end;

procedure TSmtpTests.StartTls_NotOffered_Refused;
begin
  FServer.Reply('220 hi');
  FServer.Reply('250-mail.example.com|250 AUTH PLAIN');
  TAssert.AssertEquals('EEmailTransient', SendError(Options, Msg));
  TAssert.AssertEquals('nothing after EHLO', 'EHLO localhost', FServer.Commands);
end;

procedure TSmtpTests.StartTls_NotOffered_AllowPlaintext_GoesOn;
var
  O: TSmtpOptions;
begin
  O := Options;
  O.AllowPlaintext := True;
  FServer.Reply('220 hi');
  FServer.Reply('250-mail.example.com|250 AUTH PLAIN');
  FServer.Reply('235 ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  Sender(O).Send(Msg);
  TAssert.AssertEquals(0, FServer.StartTlsCount);
  TAssert.AssertTrue(Pos('EHLO localhost|AUTH PLAIN', FServer.Commands) = 1);
end;

procedure TSmtpTests.ImplicitTls_NoStartTls;
var
  O: TSmtpOptions;
begin
  O := Options;
  O.Security := ssImplicitTls;
  FServer.Reply('220 hi');
  FServer.Reply(EHLO_AUTH);
  FServer.Reply('235 ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  Sender(O).Send(Msg);
  TAssert.AssertEquals(1, FServer.TlsConnects);
  TAssert.AssertEquals(0, FServer.StartTlsCount);
  TAssert.AssertEquals(465, Integer(FServer.LastPort));
  TAssert.AssertEquals('mail.example.com', FServer.LastHost);
end;

procedure TSmtpTests.None_WithCredentials_RefusedAtCreate;
var
  O: TSmtpOptions;
begin
  O := Options;
  O.Security := ssNone;
  TAssert.AssertEquals('EEmailArgumentError', SendError(O, Msg));
  TAssert.AssertEquals(0, FServer.Connects);
  O.AllowPlaintext := True;
  FServer.Reply('220 hi');
  FServer.Reply('250-relay|250 AUTH LOGIN PLAIN');
  FServer.Reply('235 ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  Sender(O).Send(Msg);
  TAssert.AssertEquals(25, Integer(FServer.LastPort));
end;

procedure TSmtpTests.Auth_Refused_IsAuthError;
begin
  FServer.Reply('220 hi');
  FServer.Reply(EHLO_TLS);
  FServer.Reply('220 go');
  FServer.Reply(EHLO_AUTH);
  FServer.Reply('535 5.7.8 Authentication credentials invalid');
  try
    Sender(Options).Send(Msg);
    TAssert.Fail('a refused AUTH sent the message');
  except
    on E: EEmailAuthError do
    begin
      TAssert.AssertEquals(535, E.Code);
      TAssert.AssertEquals('5.7.8', E.EnhancedCode);
      TAssert.AssertTrue(Pos('credentials invalid', E.EngineText) > 0);
    end;
  end;
  TAssert.AssertEquals(0, Pos('MAIL FROM', FServer.Commands));
end;

procedure TSmtpTests.Auth_LoginWhenOnlyLoginOffered;
begin
  FServer.Reply('220 hi');
  FServer.Reply(EHLO_TLS);
  FServer.Reply('220 go');
  FServer.Reply('250-mail|250 AUTH LOGIN');
  FServer.Reply('334 VXNlcm5hbWU6');
  FServer.Reply('334 UGFzc3dvcmQ6');
  FServer.Reply('235 ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  Sender(Options).Send(Msg);
  TAssert.AssertTrue(Pos('|AUTH LOGIN|dXNlcg==|cGFzcw==|MAIL FROM', FServer.Commands) > 0);
end;

procedure TSmtpTests.Auth_NoAuthOffered_IsAuthError;
begin
  FServer.Reply('220 hi');
  FServer.Reply(EHLO_TLS);
  FServer.Reply('220 go');
  FServer.Reply('250 mail');
  TAssert.AssertEquals('EEmailAuthError', SendError(Options, Msg));
end;

procedure TSmtpTests.Auth_XOAuth2_TokenAndFailure;
var
  O: TSmtpOptions;
  LToken: TFixedTokenProvider;
begin
  LToken := TFixedTokenProvider.Create('ya29.token');
  O := Options;
  O.UserName := 'ana@example.com';
  O.TokenProvider := LToken;
  FServer.Reply('220 hi');
  FServer.Reply(EHLO_TLS);
  FServer.Reply('220 go');
  FServer.Reply('250-mail|250 AUTH XOAUTH2 PLAIN');
  FServer.Reply('334 eyJzdGF0dXMiOiI0MDAifQ==');
  FServer.Reply('535 5.7.8 Username and Password not accepted');
  try
    Sender(O).Send(Msg);
    TAssert.Fail('a refused token sent the message');
  except
    on E: EEmailAuthError do
      TAssert.AssertEquals(535, E.Code);
  end;
  TAssert.AssertEquals(1, LToken.Calls);
  // Base64 of 'user=ana@example.com'#1'auth=Bearer ya29.token'#1#1, then the
  // empty line that ends a failed exchange.
  TAssert.AssertTrue(Pos('|AUTH XOAUTH2 dXNlcj1hbmFAZXhhbXBsZS5jb20BYXV0aD1CZWFyZXIgeWEyOS50b2tlbgEB||',
    FServer.Commands + '|') > 0);
end;

procedure TSmtpTests.Auth_None_WithoutUser;
var
  O: TSmtpOptions;
begin
  O := TSmtpOptions.Create('relay.local', 0, ssNone);
  FServer.Reply('220 hi');
  FServer.Reply('250-relay|250 AUTH PLAIN');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  Sender(O).Send(Msg);
  TAssert.AssertEquals(0, Pos('AUTH', FServer.Commands));
end;

procedure TSmtpTests.Rcpt_PartialRefusal_ReportedInResult;
var
  R: TEmailSendResult;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('550 5.1.1 <bob@example.com>: Recipient address rejected');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok: queued as X1');
  FServer.Reply('221 Bye');
  R := Sender(Options).Send(Msg);
  TAssert.AssertEquals(1, Length(R.Rejected));
  TAssert.AssertEquals('bob@example.com', R.Rejected[0].Address);
  TAssert.AssertEquals(550, R.Rejected[0].Code);
  TAssert.AssertEquals('5.1.1', R.Rejected[0].EnhancedCode);
  TAssert.AssertEquals('X1', R.ProviderId);
end;

procedure TSmtpTests.Rcpt_AllRefused_Rejected_WithRset;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('550 5.1.1 unknown');
  FServer.Reply('553 5.1.3 bad');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  try
    Sender(Options).Send(Msg);
    TAssert.Fail('sent with every recipient refused');
  except
    on E: EEmailRejected do
    begin
      TAssert.AssertEquals(550, E.Code);
      TAssert.AssertTrue(Pos('bob@example.com', E.Message) > 0);
    end;
  end;
  TAssert.AssertTrue(Pos('RCPT TO:<carl@example.com>|RSET', FServer.Commands) > 0);
  TAssert.AssertEquals(0, Pos('DATA', FServer.Commands));
end;

procedure TSmtpTests.Rcpt_RequireAll_Rejected;
var
  O: TSmtpOptions;
begin
  O := Options;
  O.RequireAllRecipients := True;
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('550 5.1.1 unknown');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  TAssert.AssertEquals('EEmailRejected', SendError(O, Msg));
  TAssert.AssertEquals(0, Pos('DATA', FServer.Commands));
end;

procedure TSmtpTests.Rcpt_AllTemporary_Transient;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('450 4.2.0 greylisted');
  FServer.Reply('450 4.2.0 greylisted');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  TAssert.AssertEquals('EEmailTransient', SendError(Options, Msg));
end;

procedure TSmtpTests.Mail_Temporary_Transient;
begin
  ScriptLogin;
  FServer.Reply('451 4.3.0 try again later');
  TAssert.AssertEquals('EEmailTransient', SendError(Options, Msg));
end;

procedure TSmtpTests.Data_Refused_Rejected;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('554 5.7.1 message rejected as spam');
  try
    Sender(Options).Send(Msg);
    TAssert.Fail('a refused message was reported as sent');
  except
    on E: EEmailRejected do
    begin
      TAssert.AssertEquals(554, E.Code);
      TAssert.AssertEquals('5.7.1', E.EnhancedCode);
    end;
  end;
end;

procedure TSmtpTests.Size_TooBig_RejectedBeforeMail;
begin
  FServer.Reply('220 hi');
  FServer.Reply(EHLO_TLS);
  FServer.Reply('220 go');
  FServer.Reply('250-mail|250-AUTH PLAIN|250 SIZE 100');
  FServer.Reply('235 ok');
  TAssert.AssertEquals('EEmailRejected', SendError(Options, Msg));
  TAssert.AssertEquals(0, Pos('MAIL FROM', FServer.Commands));
end;

procedure TSmtpTests.Greeting_421_Transient;
begin
  FServer.Reply('421 4.3.2 Service not available');
  TAssert.AssertEquals('EEmailTransient', SendError(Options, Msg));
end;

procedure TSmtpTests.Connect_Refused_Transient;
begin
  FServer.RefuseConnect;
  try
    Sender(Options).Send(Msg);
    TAssert.Fail('sent without a connection');
  except
    on E: EEmailTransient do
      TAssert.AssertTrue(Pos('mail.example.com:587', E.Message) > 0);
  end;
end;

procedure TSmtpTests.Dropped_BeforeTheMessage_Transient;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Drop;
  TAssert.AssertEquals('EEmailTransient', SendError(Options, Msg));
end;

procedure TSmtpTests.Dropped_WhileWritingTheMessage_Transient;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  // Writes: EHLO, STARTTLS, EHLO, AUTH, MAIL, RCPT, RCPT, DATA; the 9th is
  // the message.
  FServer.FailWritesFrom(9);
  TAssert.AssertEquals('EEmailTransient', SendError(Options, Msg));
end;

procedure TSmtpTests.Dropped_AfterTheMessage_OutcomeUnknown;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Drop;
  try
    Sender(Options).Send(Msg);
    TAssert.Fail('no reply taken as success');
  except
    on E: EEmailOutcomeUnknown do
      TAssert.AssertTrue(Pos('may have been accepted', E.Message) > 0);
  end;
end;

procedure TSmtpTests.Ehlo_Refused_FallsBackToHelo;
var
  O: TSmtpOptions;
begin
  O := TSmtpOptions.Create('old.example.com', 0, ssNone);
  O.HeloName := 'app.example.com';
  FServer.Reply('220 hi');
  FServer.Reply('502 5.5.2 command not recognized');
  FServer.Reply('250 old.example.com');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  Sender(O).Send(Msg);
  TAssert.AssertTrue(Pos('EHLO app.example.com|HELO app.example.com|MAIL FROM:<ana@example.com>|',
    FServer.Commands) = 1);
end;

procedure TSmtpTests.MultiLineReply_And_EnhancedCode;
begin
  ScriptLogin;
  FServer.Reply('550-5.7.1 Our system has detected|550-5.7.1 an unusual rate|550 5.7.1 of mail.');
  try
    Sender(Options).Send(Msg);
    TAssert.Fail('MAIL refused yet sent');
  except
    on E: EEmailRejected do
    begin
      TAssert.AssertEquals('5.7.1', E.EnhancedCode);
      TAssert.AssertEquals('5.7.1 Our system has detected 5.7.1 an unusual rate 5.7.1 of mail.',
        E.EngineText);
    end;
  end;
end;

procedure TSmtpTests.SendMany_OneConnection_RsetBetween;
var
  O: TEmailSendOutcomes;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok: queued as A');
  FServer.Reply('250 reset');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok: queued as B');
  FServer.Reply('221 Bye');
  O := Sender(Options).SendMany([Msg, Msg]);
  TAssert.AssertEquals(1, FServer.Connects);
  TAssert.AssertTrue(O[0].Sent and O[1].Sent);
  TAssert.AssertEquals('A', O[0].SendResult.ProviderId);
  TAssert.AssertEquals('B', O[1].SendResult.ProviderId);
  TAssert.AssertTrue(Pos('|DATA|RSET|MAIL FROM', FServer.Commands) > 0);
  TAssert.AssertEquals(0, FServer.Pending);
end;

procedure TSmtpTests.SendMany_OneRefused_OthersGo;
var
  O: TEmailSendOutcomes;
begin
  ScriptLogin;
  FServer.Reply('550 5.7.1 sender refused');
  FServer.Reply('250 reset');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok: queued as B');
  FServer.Reply('221 Bye');
  O := Sender(Options).SendMany([Msg, TEmailMessage.New.AddTo('x@example.com'), Msg]);
  TAssert.AssertFalse(O[0].Sent);
  TAssert.AssertTrue(O[0].ErrorClass = EEmailRejected);
  TAssert.AssertEquals(550, O[0].Code);
  TAssert.AssertFalse(O[1].Sent);
  TAssert.AssertTrue(O[1].ErrorClass = EEmailArgumentError);
  TAssert.AssertTrue(O[2].Sent);
  TAssert.AssertEquals(1, FServer.Connects);
end;

procedure TSmtpTests.SendMany_ReconnectsAfterADrop;
var
  O: TEmailSendOutcomes;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Drop;
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok: queued as B');
  FServer.Reply('221 Bye');
  O := Sender(Options).SendMany([Msg, Msg]);
  TAssert.AssertFalse(O[0].Sent);
  TAssert.AssertTrue(O[0].Retryable);
  TAssert.AssertTrue(O[1].Sent);
  TAssert.AssertEquals(2, FServer.Connects);
end;

procedure TSmtpTests.Envelope_UsesSender_WhenSet;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  Sender(Options).Send(Msg.SetSender('bounces@example.com'));
  TAssert.AssertTrue(Pos('MAIL FROM:<bounces@example.com>', FServer.Commands) > 0);
end;

initialization
  TDUnitX.RegisterTestFixture(TSmtpTests);

end.
