unit PascalEmail.TelemetryTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalEmail.TelemetryTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for what the senders record (PascalEmail.Telemetry; design, section
  13): the 'email send' span per message (parent, kind, attributes), a root
  span when there is no current one, an error described by its class and
  codes only (an SMTP refusal quotes the recipient), the 'email send_many'
  span around its messages (SMTP's own SendMany and TEmailSenderBase's), the
  decorators recording through their inner sender, and the two metrics.

  Tracing is started without its export thread (AAutoFlush = False) and
  FlushNow hands the spans to TCapturingSpanExporter. The metrics are the
  process-wide ones on PcMetrics, which other suites also record into (any
  send does): each test reads its series before and after.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalEmail.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalCommon.Tracing,
  PascalEmail.Errors,
  PascalEmail.Message,
  PascalEmail.Interfaces,
  PascalEmail.Mock,
  PascalEmail.Decorators,
  PascalEmail.Smtp,
  PascalEmail.Telemetry,
  PascalEmail.TestSupport;

type
  TTelemetryTests = class(TTestCase)
  private
    FExporterObj: TCapturingSpanExporter;
    FExporter: IPcSpanExporter;
    FServer: TFakeSmtpServer;
    FConnector: ISmtpConnector;
    function Msg: IEmailMessage;
    /// A mock with counting ids (Message-ID id1@example.com...).
    function Mock: IEmailSender;
    function Smtp: IEmailSender;
    procedure ScriptLogin;
    /// The 'email send' spans exported so far.
    function SendSpans: TPcSpanDataArray;
    function Attr(const AData: TPcSpanData; const AKey: string): string;
    function HasAttr(const AData: TPcSpanData; const AKey: string): Boolean;
    /// No attribute other than the Message-ID, and not the status, holds '@'.
    procedure AssertNoAddress(const AData: TPcSpanData);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Send_ChildSpan_AttributesAndMetrics;
    procedure Send_NoCurrentSpan_IsARoot;
    procedure Send_Failure_ClassAndCodesOnly;
    procedure Send_InvalidMessage_Recorded;
    procedure Smtp_PartialRefusal_ServerAndRejected;
    procedure Smtp_AllRefused_NoAddressInTheSpan;
    procedure Smtp_SendMany_BatchSpanAroundEachMessage;
    procedure Base_SendMany_BatchSpanAroundEachMessage;
    procedure Redirect_RecordsWhatWentOut;
    procedure Allowlist_NothingAllowed_NothingRecorded;
  end;

implementation

const
  EHLO_TLS = '250-mail.example.com|250-STARTTLS|250 8BITMIME';
  EHLO_AUTH = '250-mail.example.com|250-AUTH PLAIN LOGIN|250-SIZE 1000000|250 8BITMIME';

procedure TTelemetryTests.Setup;
begin
  FExporterObj := TCapturingSpanExporter.Create;
  FExporter := FExporterObj;
  TPcTracing.Start(TPcTracingOptions.Default('svc', '1.0.0'), FExporter, False);
  FServer := TFakeSmtpServer.Create;
  FConnector := FServer;
end;

procedure TTelemetryTests.TearDown;
begin
  FConnector := nil;
  FServer := nil;
  TPcTracing.Shutdown;
  FExporter := nil;
  FExporterObj := nil;
end;

function TTelemetryTests.Msg: IEmailMessage;
begin
  Result := TEmailMessage.New.SetFrom('ana@example.com', 'Ana').AddTo('bob@example.com')
    .AddCc('carl@example.com').AddBcc('audit@example.com').SetSubject('Relatório — março')
    .SetText('Olá');
end;

function TTelemetryTests.Mock: IEmailSender;
begin
  Result := TMockEmailSender.Create(TCountingIdSource.Create);
end;

function TTelemetryTests.Smtp: IEmailSender;
var
  O: TSmtpOptions;
begin
  O := TSmtpOptions.Create('mail.example.com');
  O.UserName := 'user';
  O.Password := 'pass';
  Result := TSmtpSender.Create(O, FConnector, TCountingIdSource.Create);
end;

procedure TTelemetryTests.ScriptLogin;
begin
  FServer.Reply('220 mail.example.com ESMTP');
  FServer.Reply(EHLO_TLS);
  FServer.Reply('220 2.0.0 Ready to start TLS');
  FServer.Reply(EHLO_AUTH);
  FServer.Reply('235 2.7.0 Authentication successful');
end;

function TTelemetryTests.SendSpans: TPcSpanDataArray;
begin
  TPcTracing.FlushNow;
  Result := FExporterObj.Named(EMAIL_SEND_SPAN);
end;

function TTelemetryTests.Attr(const AData: TPcSpanData; const AKey: string): string;
begin
  SpanAttribute(AData, AKey, Result);
end;

function TTelemetryTests.HasAttr(const AData: TPcSpanData; const AKey: string): Boolean;
var
  LIgnored: string;
begin
  Result := SpanAttribute(AData, AKey, LIgnored);
end;

procedure TTelemetryTests.AssertNoAddress(const AData: TPcSpanData);
var
  I: Integer;
begin
  for I := 0 to High(AData.Attributes) do
    if AData.Attributes[I].Key <> 'pascalemail.message_id' then
      TAssert.AssertEquals(AData.Attributes[I].Key, 0,
        Pos('@', Attr(AData, AData.Attributes[I].Key)));
  TAssert.AssertEquals('status: ' + AData.StatusMessage, 0, Pos('@', AData.StatusMessage));
end;

procedure TTelemetryTests.Send_ChildSpan_AttributesAndMetrics;
var
  LParent: IPcSpan;
  LSpans: TPcSpanDataArray;
  LDuration, LAccepted: Double;
begin
  LDuration := MetricPointCount(EMAIL_SEND_DURATION_METRIC, ['mock', '']);
  LAccepted := MetricPointCount(EMAIL_RECIPIENTS_METRIC, ['mock', 'accepted']);
  LParent := TPcTracing.StartSpan('handler', skServer);
  try
    Mock.Send(Msg);
  finally
    LParent.Finish;
  end;
  LSpans := SendSpans;
  TAssert.AssertEquals(1, Length(LSpans));
  TAssert.AssertTrue(LSpans[0].Kind = skClient);
  TAssert.AssertEquals(LParent.TraceId, LSpans[0].TraceId);
  TAssert.AssertEquals(LParent.SpanId, LSpans[0].ParentSpanId);
  LParent := nil;
  TAssert.AssertEquals('mock', Attr(LSpans[0], 'pascalemail.sender'));
  TAssert.AssertEquals('To, Cc and Bcc', '3', Attr(LSpans[0], 'pascalemail.recipients'));
  TAssert.AssertEquals('id1@example.com', Attr(LSpans[0], 'pascalemail.message_id'));
  TAssert.AssertEquals('mock-1', Attr(LSpans[0], 'pascalemail.provider_id'));
  TAssert.AssertFalse(HasAttr(LSpans[0], 'pascalemail.rejected'));
  TAssert.AssertFalse(HasAttr(LSpans[0], 'server.address'));
  TAssert.AssertFalse(HasAttr(LSpans[0], 'error.type'));
  TAssert.AssertTrue(LSpans[0].Status = ssUnset);
  AssertNoAddress(LSpans[0]);
  TAssert.AssertEquals(LDuration + 1,
    MetricPointCount(EMAIL_SEND_DURATION_METRIC, ['mock', '']), 0);
  TAssert.AssertEquals(LAccepted + 3,
    MetricPointCount(EMAIL_RECIPIENTS_METRIC, ['mock', 'accepted']), 0);
end;

procedure TTelemetryTests.Send_NoCurrentSpan_IsARoot;
var
  LSpans: TPcSpanDataArray;
begin
  TAssert.AssertTrue(TPcTracing.Current = nil);
  Mock.Send(Msg);
  LSpans := SendSpans;
  TAssert.AssertEquals(1, Length(LSpans));
  TAssert.AssertEquals('', LSpans[0].ParentSpanId);
  TAssert.AssertTrue('finished: no current span left', TPcTracing.Current = nil);
end;

procedure TTelemetryTests.Send_Failure_ClassAndCodesOnly;
var
  LMock: TMockEmailSender;
  LSender: IEmailSender;
  LSpans: TPcSpanDataArray;
  LFailed, LRejected: Double;
begin
  LFailed := MetricPointCount(EMAIL_SEND_DURATION_METRIC, ['mock', 'EEmailRejected']);
  LRejected := MetricPointCount(EMAIL_RECIPIENTS_METRIC, ['mock', 'rejected']);
  LMock := TMockEmailSender.Create(TCountingIdSource.Create);
  LSender := LMock;
  LMock.FailNext(EEmailRejected, 1, '<bob@example.com>: Recipient address rejected', 550);
  try
    LSender.Send(Msg);
    TAssert.Fail('the failure was not raised');
  except
    on E: EEmailRejected do
      TAssert.AssertTrue('the exception keeps its text', Pos('bob@', E.Message) > 0);
  end;
  LSpans := SendSpans;
  TAssert.AssertEquals(1, Length(LSpans));
  TAssert.AssertTrue(LSpans[0].Status = ssError);
  TAssert.AssertEquals('EEmailRejected 550', LSpans[0].StatusMessage);
  TAssert.AssertEquals('EEmailRejected', Attr(LSpans[0], 'error.type'));
  TAssert.AssertEquals('550', Attr(LSpans[0], 'pascalemail.reply.code'));
  TAssert.AssertEquals('written before it failed', 'id1@example.com',
    Attr(LSpans[0], 'pascalemail.message_id'));
  TAssert.AssertFalse(HasAttr(LSpans[0], 'pascalemail.provider_id'));
  AssertNoAddress(LSpans[0]);
  TAssert.AssertEquals(LFailed + 1,
    MetricPointCount(EMAIL_SEND_DURATION_METRIC, ['mock', 'EEmailRejected']), 0);
  TAssert.AssertEquals('a send that raised counts no recipient', LRejected,
    MetricPointCount(EMAIL_RECIPIENTS_METRIC, ['mock', 'rejected']), 0);
end;

procedure TTelemetryTests.Send_InvalidMessage_Recorded;
var
  LSpans: TPcSpanDataArray;
begin
  try
    Mock.Send(TEmailMessage.New.SetFrom('ana@example.com'));
    TAssert.Fail('a message with no recipient was sent');
  except
    on E: EEmailArgumentError do
      ;
  end;
  LSpans := SendSpans;
  TAssert.AssertEquals(1, Length(LSpans));
  TAssert.AssertEquals('0', Attr(LSpans[0], 'pascalemail.recipients'));
  TAssert.AssertEquals('EEmailArgumentError', Attr(LSpans[0], 'error.type'));
  TAssert.AssertEquals('EEmailArgumentError', LSpans[0].StatusMessage);
end;

procedure TTelemetryTests.Smtp_PartialRefusal_ServerAndRejected;
var
  LSpans: TPcSpanDataArray;
  LAccepted, LRejected: Double;
begin
  LAccepted := MetricPointCount(EMAIL_RECIPIENTS_METRIC, ['smtp', 'accepted']);
  LRejected := MetricPointCount(EMAIL_RECIPIENTS_METRIC, ['smtp', 'rejected']);
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('550 5.1.1 <bob@example.com>: Recipient address rejected');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok: queued as X1');
  FServer.Reply('221 Bye');
  TAssert.AssertEquals(1, Length(Smtp.Send(Msg).Rejected));
  LSpans := SendSpans;
  TAssert.AssertEquals(1, Length(LSpans));
  TAssert.AssertTrue(LSpans[0].Kind = skClient);
  TAssert.AssertEquals('smtp', Attr(LSpans[0], 'pascalemail.sender'));
  TAssert.AssertEquals('mail.example.com', Attr(LSpans[0], 'server.address'));
  TAssert.AssertEquals('587', Attr(LSpans[0], 'server.port'));
  TAssert.AssertEquals('X1', Attr(LSpans[0], 'pascalemail.provider_id'));
  TAssert.AssertEquals('1', Attr(LSpans[0], 'pascalemail.rejected'));
  TAssert.AssertTrue('a partial refusal is not an error', LSpans[0].Status = ssUnset);
  AssertNoAddress(LSpans[0]);
  TAssert.AssertEquals(LAccepted + 2,
    MetricPointCount(EMAIL_RECIPIENTS_METRIC, ['smtp', 'accepted']), 0);
  TAssert.AssertEquals(LRejected + 1,
    MetricPointCount(EMAIL_RECIPIENTS_METRIC, ['smtp', 'rejected']), 0);
end;

procedure TTelemetryTests.Smtp_AllRefused_NoAddressInTheSpan;
var
  LSpans: TPcSpanDataArray;
begin
  ScriptLogin;
  FServer.Reply('250 Ok');
  FServer.Reply('550 5.1.1 <bob@example.com>: Recipient address rejected');
  FServer.Reply('550 5.1.1 <carl@example.com>: Recipient address rejected');
  FServer.Reply('550 5.1.1 <audit@example.com>: Recipient address rejected');
  FServer.Reply('250 Ok');
  FServer.Reply('221 Bye');
  try
    Smtp.Send(Msg);
    TAssert.Fail('sent with every recipient refused');
  except
    on E: EEmailRejected do
      TAssert.AssertTrue('the exception quotes the server', Pos('bob@', E.Message) > 0);
  end;
  LSpans := SendSpans;
  TAssert.AssertEquals(1, Length(LSpans));
  TAssert.AssertTrue(LSpans[0].Status = ssError);
  TAssert.AssertEquals('EEmailRejected 550 5.1.1', LSpans[0].StatusMessage);
  TAssert.AssertEquals('5.1.1', Attr(LSpans[0], 'pascalemail.reply.enhanced_code'));
  AssertNoAddress(LSpans[0]);
end;

procedure TTelemetryTests.Smtp_SendMany_BatchSpanAroundEachMessage;
var
  LParent: IPcSpan;
  LBatch, LSpans: TPcSpanDataArray;
  I: Integer;
begin
  ScriptLogin;
  FServer.Reply('550 5.7.1 sender refused');
  FServer.Reply('250 reset');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('250 Ok');
  FServer.Reply('354 go');
  FServer.Reply('250 Ok: queued as B');
  FServer.Reply('221 Bye');
  LParent := TPcTracing.StartSpan('job');
  try
    Smtp.SendMany([Msg, TEmailMessage.New.AddTo('x@example.com'), Msg]);
  finally
    LParent.Finish;
  end;
  TAssert.AssertEquals(1, FServer.Connects);
  LSpans := SendSpans;
  LBatch := FExporterObj.Named(EMAIL_SEND_MANY_SPAN);
  TAssert.AssertEquals(1, Length(LBatch));
  TAssert.AssertTrue(LBatch[0].Kind = skInternal);
  TAssert.AssertEquals(LParent.SpanId, LBatch[0].ParentSpanId);
  LParent := nil;
  TAssert.AssertEquals('smtp', Attr(LBatch[0], 'pascalemail.sender'));
  TAssert.AssertEquals('3', Attr(LBatch[0], 'pascalemail.messages'));
  TAssert.AssertEquals('2', Attr(LBatch[0], 'pascalemail.failed'));
  TAssert.AssertTrue('failures are in the outcomes', LBatch[0].Status = ssUnset);
  TAssert.AssertEquals(3, Length(LSpans));
  for I := 0 to 2 do
    TAssert.AssertEquals(LBatch[0].SpanId, LSpans[I].ParentSpanId);
  TAssert.AssertEquals('EEmailRejected', Attr(LSpans[0], 'error.type'));
  TAssert.AssertEquals('EEmailArgumentError', Attr(LSpans[1], 'error.type'));
  TAssert.AssertEquals('B', Attr(LSpans[2], 'pascalemail.provider_id'));
end;

procedure TTelemetryTests.Base_SendMany_BatchSpanAroundEachMessage;
var
  LBatch, LSpans: TPcSpanDataArray;
begin
  Mock.SendMany([Msg, Msg]);
  LSpans := SendSpans;
  LBatch := FExporterObj.Named(EMAIL_SEND_MANY_SPAN);
  TAssert.AssertEquals(1, Length(LBatch));
  TAssert.AssertEquals('', LBatch[0].ParentSpanId);
  TAssert.AssertEquals('mock', Attr(LBatch[0], 'pascalemail.sender'));
  TAssert.AssertEquals('2', Attr(LBatch[0], 'pascalemail.messages'));
  TAssert.AssertEquals('0', Attr(LBatch[0], 'pascalemail.failed'));
  TAssert.AssertEquals(2, Length(LSpans));
  TAssert.AssertEquals(LBatch[0].SpanId, LSpans[0].ParentSpanId);
  TAssert.AssertEquals(LBatch[0].SpanId, LSpans[1].ParentSpanId);
end;

procedure TTelemetryTests.Redirect_RecordsWhatWentOut;
var
  LSender: IEmailSender;
  LSpans: TPcSpanDataArray;
begin
  LSender := TRedirectEmailSender.Create(Mock, ['qa@example.com']);
  LSender.Send(Msg);
  LSender.SendMany([Msg]);
  LSpans := SendSpans;
  TAssert.AssertEquals('one span per message, the inner sender''s', 2, Length(LSpans));
  TAssert.AssertEquals('mock', Attr(LSpans[0], 'pascalemail.sender'));
  TAssert.AssertEquals('the QA mailbox only', '1', Attr(LSpans[0], 'pascalemail.recipients'));
  TAssert.AssertEquals(1, Length(FExporterObj.Named(EMAIL_SEND_MANY_SPAN)));
end;

procedure TTelemetryTests.Allowlist_NothingAllowed_NothingRecorded;
var
  LSender: IEmailSender;
  LDuration: Double;
begin
  LDuration := MetricPointCount(EMAIL_SEND_DURATION_METRIC, ['mock', '']);
  LSender := TAllowlistEmailSender.Create(Mock, ['@empresa.com.br']);
  TAssert.AssertEquals(3, Length(LSender.Send(Msg).Rejected));
  TAssert.AssertEquals('nothing was sent', 0, Length(SendSpans));
  TAssert.AssertEquals(LDuration, MetricPointCount(EMAIL_SEND_DURATION_METRIC, ['mock', '']), 0);
end;

initialization
  RegisterTest(TTelemetryTests);

end.
