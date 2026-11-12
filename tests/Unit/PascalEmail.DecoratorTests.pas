unit PascalEmail.DecoratorTests;

{ Tests for PascalEmail.Decorators over TMockEmailSender: what
  TRedirectEmailSender sends instead (its addresses, the X-Original-*
  headers, the subject prefix, everything else kept) and what
  TAllowlistEmailSender lets through (addresses and domains, roles kept,
  the rest reported as rejected, a message with no allowed recipient not
  sent at all); validation before the inner sender, its errors passed
  through, SendMany through the inner SendMany, the caller's message left
  unchanged; and EmailCopyMessage, which both rely on.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalEmail.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalEmail.DUnitXCompat,
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Address,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.Interfaces,
  PascalEmail.Mock,
  PascalEmail.Decorators,
  PascalEmail.TestSupport;

type
  [TestFixture]
  TDecoratorTests = class
  private
    FMock: TMockEmailSender;
    FInner: IEmailSender;
    function Msg: IEmailMessage;
    function CreateError(const AAllowed: array of string): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure Copy_KeepsEverything;
    [Test] procedure Copy_WithoutRecipients;
    [Test] procedure Redirect_SendsToTheRedirectAddresses;
    [Test] procedure Redirect_OriginalRecipientsInHeaders;
    [Test] procedure Redirect_SubjectPrefix_AndNone;
    [Test] procedure Redirect_KeepsBodiesAttachmentsAndMessageId;
    [Test] procedure Redirect_LeavesTheCallersMessageAlone;
    [Test] procedure Redirect_InvalidMessage_NotSent;
    [Test] procedure Redirect_BadConfiguration;
    [Test] procedure Redirect_InnerErrorPassesThrough;
    [Test] procedure Redirect_SendMany;
    [Test] procedure Allowlist_DomainsAndAddresses;
    [Test] procedure Allowlist_KeepsRoles_ReportsTheOthers;
    [Test] procedure Allowlist_NoneAllowed_NotSent;
    [Test] procedure Allowlist_BadEntries;
    [Test] procedure Allowlist_InvalidMessage_NotSent;
    [Test] procedure Allowlist_SendMany_MixesSentSkippedAndFailed;
    [Test] procedure Names;
  end;

implementation

procedure TDecoratorTests.Setup;
begin
  FMock := TMockEmailSender.Create(TCountingIdSource.Create);
  FInner := FMock;
end;

procedure TDecoratorTests.TearDown;
begin
  FInner := nil;
  FMock := nil;
end;

function TDecoratorTests.Msg: IEmailMessage;
begin
  Result := TEmailMessage.New.SetFrom('app@example.com', 'App')
    .AddTo('cliente@gmail.com', 'Cliente').AddTo('ana@empresa.com.br')
    .AddCc('gerente@empresa.com.br').AddBcc('auditoria@outro.com')
    .SetSubject('Pedido nº 42').SetText('texto').SetHtml('<p>html</p>');
end;

function TDecoratorTests.CreateError(const AAllowed: array of string): string;
var
  LSender: IEmailSender;
begin
  Result := '';
  try
    // Held by an interface, so the one that succeeds is released.
    LSender := TAllowlistEmailSender.Create(FInner, AAllowed);
  except
    on E: Exception do
      Result := E.ClassName;
  end;
end;

{ EmailCopyMessage }

procedure TDecoratorTests.Copy_KeepsEverything;
var
  A, B: IEmailMessage;
begin
  A := Msg.SetSender('robot@example.com').AddReplyTo('help@example.com', 'Help')
    .Attach('a.pdf', SampleBytes(10)).Embed('logo', 'logo.png', SampleBytes(5), 'image/png')
    .AddHeader('X-Campaign', 'nov').SetMessageId('m1@example.com')
    .SetDate(EncodeDate(2026, 1, 2)).AddTag('welcome').SetMetadata('user', '42');
  B := EmailCopyMessage(A, True);
  TAssert.AssertEquals('same MIME', EmailBuildMime(A, TCountingIdSource.Create).AsText,
    EmailBuildMime(B, TCountingIdSource.Create).AsText);
  TAssert.AssertEquals('Bcc', 'auditoria@outro.com', B.BccList[0].Address);
  TAssert.AssertEquals('tag', 'welcome', B.Tags[0]);
  TAssert.AssertEquals('metadata', '42', B.Metadata[0].Value);
  TAssert.AssertTrue('a new object', A <> B);
end;

procedure TDecoratorTests.Copy_WithoutRecipients;
var
  B: IEmailMessage;
begin
  B := EmailCopyMessage(Msg, False);
  TAssert.AssertEquals(0, Length(B.Recipients));
  TAssert.AssertEquals('Pedido nº 42', B.Subject);
  TAssert.AssertTrue(B.HasFrom);
end;

{ Redirect }

procedure TDecoratorTests.Redirect_SendsToTheRedirectAddresses;
var
  LSender: IEmailSender;
  LSent: IEmailMessage;
begin
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br', 'QA 2 <qa2@empresa.com.br>']);
  LSender.Send(Msg);
  LSent := FMock.Last.Message;
  TAssert.AssertEquals(2, Length(LSent.ToList));
  TAssert.AssertEquals('qa@empresa.com.br', LSent.ToList[0].Address);
  TAssert.AssertEquals('qa2@empresa.com.br', LSent.ToList[1].Address);
  TAssert.AssertEquals('no Cc', 0, Length(LSent.CcList));
  TAssert.AssertEquals('no Bcc', 0, Length(LSent.BccList));
  TAssert.AssertEquals(2, Length(LSent.Recipients));
end;

procedure TDecoratorTests.Redirect_OriginalRecipientsInHeaders;
var
  LSender: IEmailSender;
  S: string;
begin
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br']);
  LSender.Send(Msg);
  S := FMock.Last.Mime.AsText;
  TAssert.AssertTrue(Pos('X-Original-To: cliente@gmail.com, ana@empresa.com.br'#13#10, S) > 0);
  TAssert.AssertTrue(Pos('X-Original-Cc: gerente@empresa.com.br'#13#10, S) > 0);
  TAssert.AssertTrue(Pos('X-Original-Bcc: auditoria@outro.com'#13#10, S) > 0);
  TAssert.AssertTrue('the real To is the redirect',
    Pos(#13#10'To: qa@empresa.com.br'#13#10, S) > 0);
end;

procedure TDecoratorTests.Redirect_SubjectPrefix_AndNone;
var
  LSender: IEmailSender;
begin
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br']);
  LSender.Send(Msg);
  TAssert.AssertEquals('[REDIRECTED] Pedido nº 42', FMock.Last.Message.Subject);
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br'], '[HOMOLOG] ');
  LSender.Send(Msg);
  TAssert.AssertEquals('[HOMOLOG] Pedido nº 42', FMock.Last.Message.Subject);
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br'], '');
  LSender.Send(Msg);
  TAssert.AssertEquals('Pedido nº 42', FMock.Last.Message.Subject);
end;

procedure TDecoratorTests.Redirect_KeepsBodiesAttachmentsAndMessageId;
var
  LSender: IEmailSender;
  LSent: IEmailMessage;
  R: TEmailSendResult;
begin
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br']);
  R := LSender.Send(Msg.SetMessageId('order-42@example.com').Attach('nf.pdf', SampleBytes(100))
    .Embed('logo', 'logo.png', SampleBytes(20)));
  LSent := FMock.Last.Message;
  TAssert.AssertEquals('order-42@example.com', R.MessageId);
  TAssert.AssertEquals('texto', LSent.TextBody);
  TAssert.AssertEquals('<p>html</p>', LSent.HtmlBody);
  TAssert.AssertEquals(2, Length(LSent.Attachments));
  TAssert.AssertEquals(100, Length(LSent.Attachments[0].Content));
  TAssert.AssertEquals('logo', LSent.Attachments[1].ContentId);
  TAssert.AssertEquals('app@example.com', LSent.From.Address);
end;

procedure TDecoratorTests.Redirect_LeavesTheCallersMessageAlone;
var
  LSender: IEmailSender;
  M: IEmailMessage;
begin
  M := Msg;
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br']);
  LSender.Send(M);
  TAssert.AssertEquals('Pedido nº 42', M.Subject);
  TAssert.AssertEquals(2, Length(M.ToList));
  TAssert.AssertEquals(0, Length(M.Headers));
end;

procedure TDecoratorTests.Redirect_InvalidMessage_NotSent;
var
  LSender: IEmailSender;
begin
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br']);
  try
    // No recipient: a real engine refuses it, so the redirect must too.
    LSender.Send(TEmailMessage.New.SetFrom('app@example.com').SetSubject('x'));
    TAssert.Fail('a message without recipients was redirected');
  except
    on E: EEmailArgumentError do
      ;
  end;
  TAssert.AssertEquals(0, FMock.Attempts);
end;

procedure TDecoratorTests.Redirect_BadConfiguration;
var
  LErrors: Integer;
begin
  LErrors := 0;
  try
    TRedirectEmailSender.Create(FInner, []);
  except
    on E: EEmailArgumentError do
      Inc(LErrors);
  end;
  try
    TRedirectEmailSender.Create(FInner, ['not an address']);
  except
    on E: EEmailArgumentError do
      Inc(LErrors);
  end;
  try
    TRedirectEmailSender.Create(nil, ['qa@empresa.com.br']);
  except
    on E: EEmailArgumentError do
      Inc(LErrors);
  end;
  try
    TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br'], '[X]'#13#10'Bcc: x@y.com ');
  except
    on E: EEmailArgumentError do
      Inc(LErrors);
  end;
  TAssert.AssertEquals(4, LErrors);
end;

procedure TDecoratorTests.Redirect_InnerErrorPassesThrough;
var
  LSender: IEmailSender;
begin
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br']);
  FMock.FailNext(EEmailTransient, 1, 'later', 451);
  try
    LSender.Send(Msg);
    TAssert.Fail('the inner failure was swallowed');
  except
    on E: EEmailTransient do
      TAssert.AssertEquals(451, E.Code);
  end;
end;

procedure TDecoratorTests.Redirect_SendMany;
var
  LSender: IEmailSender;
  O: TEmailSendOutcomes;
begin
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br']);
  O := LSender.SendMany([Msg, TEmailMessage.New.AddTo('a@example.com'), Msg]);
  TAssert.AssertTrue(O[0].Sent);
  TAssert.AssertFalse(O[1].Sent);
  TAssert.AssertTrue(O[1].ErrorClass = EEmailArgumentError);
  TAssert.AssertTrue(O[2].Sent);
  TAssert.AssertEquals(2, FMock.Count);
  TAssert.AssertEquals('qa@empresa.com.br', FMock.Sent(1).Message.ToList[0].Address);
end;

{ Allowlist }

procedure TDecoratorTests.Allowlist_DomainsAndAddresses;
var
  A: TAllowlistEmailSender;
  LSender: IEmailSender;
begin
  A := TAllowlistEmailSender.Create(FInner, ['@Empresa.com.br', 'Dono@Gmail.com']);
  LSender := A;
  TAssert.AssertTrue('domain, any case', A.IsAllowed('ana@EMPRESA.com.br'));
  TAssert.AssertTrue('address, any case', A.IsAllowed('dono@gmail.com'));
  TAssert.AssertFalse('other address of the same domain', A.IsAllowed('outro@gmail.com'));
  TAssert.AssertFalse('subdomain', A.IsAllowed('x@mail.empresa.com.br'));
  TAssert.AssertFalse('domain as a suffix', A.IsAllowed('x@minhaempresa.com.br'));
end;

procedure TDecoratorTests.Allowlist_KeepsRoles_ReportsTheOthers;
var
  LSender: IEmailSender;
  LSent: IEmailMessage;
  R: TEmailSendResult;
begin
  LSender := TAllowlistEmailSender.Create(FInner, ['@empresa.com.br']);
  R := LSender.Send(Msg);
  LSent := FMock.Last.Message;
  TAssert.AssertEquals(1, Length(LSent.ToList));
  TAssert.AssertEquals('ana@empresa.com.br', LSent.ToList[0].Address);
  TAssert.AssertEquals('Cc stays Cc', 'gerente@empresa.com.br', LSent.CcList[0].Address);
  TAssert.AssertEquals(0, Length(LSent.BccList));
  TAssert.AssertEquals('subject untouched', 'Pedido nº 42', LSent.Subject);
  TAssert.AssertEquals(2, Length(R.Rejected));
  TAssert.AssertEquals('cliente@gmail.com', R.Rejected[0].Address);
  TAssert.AssertEquals(0, R.Rejected[0].Code);
  TAssert.AssertEquals(EMAIL_NOT_ALLOWED_TEXT, R.Rejected[0].Text);
  TAssert.AssertEquals('auditoria@outro.com', R.Rejected[1].Address);
  TAssert.AssertEquals('mock-1', R.ProviderId);
end;

procedure TDecoratorTests.Allowlist_NoneAllowed_NotSent;
var
  LSender: IEmailSender;
  R: TEmailSendResult;
begin
  LSender := TAllowlistEmailSender.Create(FInner, ['@nowhere.example']);
  R := LSender.Send(Msg.SetMessageId('m9@example.com'));
  TAssert.AssertEquals('the inner sender was not called', 0, FMock.Attempts);
  TAssert.AssertEquals('', R.ProviderId);
  TAssert.AssertEquals('m9@example.com', R.MessageId);
  TAssert.AssertEquals(4, Length(R.Rejected));
end;

procedure TDecoratorTests.Allowlist_BadEntries;
begin
  TAssert.AssertEquals('empty list', 'EEmailArgumentError', CreateError([]));
  TAssert.AssertEquals('bare word', 'EEmailArgumentError', CreateError(['empresa']));
  TAssert.AssertEquals('bad domain', 'EEmailArgumentError', CreateError(['@bad domain']));
  TAssert.AssertEquals('empty entry', 'EEmailArgumentError', CreateError(['']));
  TAssert.AssertEquals('fine', '', CreateError(['@empresa.com.br', 'a@b.com']));
end;

procedure TDecoratorTests.Allowlist_InvalidMessage_NotSent;
var
  LSender: IEmailSender;
begin
  LSender := TAllowlistEmailSender.Create(FInner, ['@empresa.com.br']);
  try
    LSender.Send(TEmailMessage.New.AddTo('a@empresa.com.br'));
    TAssert.Fail('a message without From went through');
  except
    on E: EEmailArgumentError do
      ;
  end;
  TAssert.AssertEquals(0, FMock.Attempts);
end;

procedure TDecoratorTests.Allowlist_SendMany_MixesSentSkippedAndFailed;
var
  LSender: IEmailSender;
  O: TEmailSendOutcomes;
begin
  LSender := TAllowlistEmailSender.Create(FInner, ['@empresa.com.br']);
  O := LSender.SendMany([
    Msg,
    TEmailMessage.New.SetFrom('app@example.com').AddTo('x@gmail.com'),
    TEmailMessage.New.AddTo('a@empresa.com.br'),
    TEmailMessage.New.SetFrom('app@example.com').AddTo('b@empresa.com.br')]);
  TAssert.AssertTrue(O[0].Sent);
  TAssert.AssertEquals('dropped ones reported', 2, Length(O[0].SendResult.Rejected));
  TAssert.AssertTrue('nothing allowed: not an error', O[1].Sent);
  TAssert.AssertEquals('', O[1].SendResult.ProviderId);
  TAssert.AssertEquals(1, Length(O[1].SendResult.Rejected));
  TAssert.AssertFalse(O[2].Sent);
  TAssert.AssertTrue(O[2].ErrorClass = EEmailArgumentError);
  TAssert.AssertTrue(O[3].Sent);
  TAssert.AssertEquals(0, Length(O[3].SendResult.Rejected));
  TAssert.AssertEquals('only two reached the inner sender', 2, FMock.Count);
end;

procedure TDecoratorTests.Names;
var
  LSender: IEmailSender;
begin
  LSender := TRedirectEmailSender.Create(FInner, ['qa@empresa.com.br']);
  TAssert.AssertEquals('redirect(mock)', LSender.Name);
  LSender := TAllowlistEmailSender.Create(LSender, ['@empresa.com.br']);
  TAssert.AssertEquals('allowlist(redirect(mock))', LSender.Name);
end;

initialization
  TDUnitX.RegisterTestFixture(TDecoratorTests);

end.
