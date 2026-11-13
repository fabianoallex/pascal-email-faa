unit PascalEmail.Telemetry;

{$I pascalemail.inc}

(* What every sender of the library records about a send (design, section
  13): a span and two metrics, on pascal-common-faa's PascalCommon.Tracing
  and PcMetrics. OpenTelemetry has no conventions for e-mail, so the names
  are this library's (prefix 'pascalemail.'), with the general attributes
  (server.address, server.port, error.type) where they fit.

  - A span 'email send' per message, a child of the thread's current span,
    or the root of a new trace when there is none (as pascal-db-faa's
    statements). Its kind is client, except where a lower layer already
    makes the client span (SES: the HTTP POST is its child), which passes
    skInternal. Attributes: pascalemail.sender, pascalemail.recipients (the
    envelope: To + Cc + Bcc), pascalemail.message_id, pascalemail.provider_id,
    pascalemail.rejected (when > 0), server.address and server.port (when the
    sender knows them), and on failure error.type (the exception's class),
    pascalemail.reply.code and pascalemail.reply.enhanced_code.
  - A span 'email send_many' (internal) around each SendMany, with each
    message's 'email send' as its children: pascalemail.sender,
    pascalemail.messages, pascalemail.failed.
  - The histogram pascalemail.send.duration (s; pascalemail.sender,
    error.type, '' on success): its count is the number of sends and of
    failures, so there is no counter for them.
  - The counter pascalemail.recipients ({recipient}; pascalemail.sender,
    pascalemail.outcome = accepted | rejected), for messages handed over
    (a send that raised counts no recipient).

  Never an address, a subject, a body or an exception's message: a span in
  error has the status description '<class> <code> <enhanced code>' only.
  An SMTP reply can quote the recipient ('<bob@...>: Recipient address
  rejected'), SES lists identities that failed a check, and
  EEmailArgumentError names the address it refused. The Message-ID is
  generated (random@domain of From) unless the caller set one with
  SetMessageId; a caller that puts personal data there sends it to the
  collector too. No label holds a recipient's domain (cardinality, privacy).

  Use (a sender's Send):

    LRec := TEmailSendTelemetry.Start(Name, skClient, AMessage, Host, Port);
    try
      LMime := EmailBuildMime(AMessage, FIds);
      LRec.Identify(LMime.MessageId);
      ...
      LRec.Done(Result);
    except
      on E: Exception do
      begin
        LRec.Fail(E);
        raise;
      end;
    end;

  The span is started and finished on the calling thread, so the thread
  rule of PascalCommon.Tracing holds. *)

interface

uses
  SysUtils,
  PascalCommon.Tracing,
  PascalEmail.Message,
  PascalEmail.Interfaces;

const
  EMAIL_SEND_SPAN = 'email send';
  EMAIL_SEND_MANY_SPAN = 'email send_many';
  EMAIL_SEND_DURATION_METRIC = 'pascalemail.send.duration';
  EMAIL_RECIPIENTS_METRIC = 'pascalemail.recipients';

type
  /// One message's span and metrics. Start, then exactly one of Done or
  /// Fail.
  TEmailSendTelemetry = record
  private
    FSpan: IPcSpan;
    FSender: string;
    FRecipients: Integer;
    FStartUs: Int64;
    procedure Observe(const AErrorType: string);
  public
    /// AServerAddress '' and AServerPort 0 leave server.* out.
    class function Start(const ASender: string; AKind: TPcSpanKind;
      const AMessage: IEmailMessage; const AServerAddress: string = '';
      AServerPort: Integer = 0): TEmailSendTelemetry; static;
    /// The Message-ID, once the MIME is written: a failure after it keeps
    /// the id on the span.
    procedure Identify(const AMessageId: string);
    procedure Done(const AResult: TEmailSendResult);
    procedure Fail(E: Exception);
  end;

  /// A SendMany's span. Start, then exactly one of Done or Fail.
  TEmailBatchTelemetry = record
  private
    FSpan: IPcSpan;
  public
    class function Start(const ASender: string; AMessages: Integer): TEmailBatchTelemetry; static;
    procedure Done(const AOutcomes: TEmailSendOutcomes);
    procedure Fail(E: Exception);
  end;

/// The status description of a span in error: the class, and the code and
/// enhanced code of an EEmailError when it has them. Never E.Message.
function EmailErrorDescription(E: Exception): string;

implementation

uses
  PascalCommon.Threading,
  PascalCommon.Metrics,
  PascalEmail.Errors;

function DurationHistogram: TPcHistogram;
begin
  Result := PcMetrics.Histogram(EMAIL_SEND_DURATION_METRIC, 's',
    'Duration of e-mail sends, one per message.',
    ['pascalemail.sender', 'error.type'], PC_DURATION_BUCKETS);
end;

function RecipientsCounter: TPcCounter;
begin
  Result := PcMetrics.Counter(EMAIL_RECIPIENTS_METRIC, '{recipient}',
    'Recipients of the messages handed over, accepted or rejected by the engine.',
    ['pascalemail.sender', 'pascalemail.outcome']);
end;

function EmailErrorDescription(E: Exception): string;
begin
  Result := E.ClassName;
  if E is EEmailError then
  begin
    if EEmailError(E).Code <> 0 then
      Result := Result + ' ' + IntToStr(EEmailError(E).Code);
    if EEmailError(E).EnhancedCode <> '' then
      Result := Result + ' ' + EEmailError(E).EnhancedCode;
  end;
end;

{ TEmailSendTelemetry }

class function TEmailSendTelemetry.Start(const ASender: string; AKind: TPcSpanKind;
  const AMessage: IEmailMessage; const AServerAddress: string;
  AServerPort: Integer): TEmailSendTelemetry;
begin
  Result.FSender := ASender;
  Result.FRecipients := 0;
  if AMessage <> nil then
    Result.FRecipients := Length(AMessage.ToList) + Length(AMessage.CcList) +
      Length(AMessage.BccList);
  Result.FSpan := TPcTracing.StartSpan(EMAIL_SEND_SPAN, AKind);
  Result.FSpan.SetAttribute('pascalemail.sender', ASender);
  Result.FSpan.SetIntAttribute('pascalemail.recipients', Result.FRecipients);
  if AServerAddress <> '' then
    Result.FSpan.SetAttribute('server.address', AServerAddress);
  if AServerPort > 0 then
    Result.FSpan.SetIntAttribute('server.port', AServerPort);
  // Last, so the time of the span's own setup isn't counted.
  Result.FStartUs := PcTickUs;
end;

procedure TEmailSendTelemetry.Identify(const AMessageId: string);
begin
  if (FSpan <> nil) and (AMessageId <> '') then
    FSpan.SetAttribute('pascalemail.message_id', AMessageId);
end;

procedure TEmailSendTelemetry.Observe(const AErrorType: string);
begin
  DurationHistogram.Labels([FSender, AErrorType]).Observe((PcTickUs - FStartUs) / 1000000);
end;

procedure TEmailSendTelemetry.Done(const AResult: TEmailSendResult);
var
  LRejected, LAccepted: Integer;
begin
  if FSpan = nil then
    Exit;
  Observe('');
  try
    Identify(AResult.MessageId);
    if AResult.ProviderId <> '' then
      FSpan.SetAttribute('pascalemail.provider_id', AResult.ProviderId);
    LRejected := Length(AResult.Rejected);
    if LRejected > 0 then
      FSpan.SetIntAttribute('pascalemail.rejected', LRejected);
    // The envelope as the message had it, less the refused ones.
    LAccepted := FRecipients - LRejected;
    if LAccepted > 0 then
      RecipientsCounter.Labels([FSender, 'accepted']).Add(LAccepted);
    if LRejected > 0 then
      RecipientsCounter.Labels([FSender, 'rejected']).Add(LRejected);
  finally
    FSpan.Finish;
    FSpan := nil;
  end;
end;

procedure TEmailSendTelemetry.Fail(E: Exception);
begin
  if FSpan = nil then
    Exit;
  Observe(E.ClassName);
  try
    FSpan.SetAttribute('error.type', E.ClassName);
    if E is EEmailError then
    begin
      if EEmailError(E).Code <> 0 then
        FSpan.SetIntAttribute('pascalemail.reply.code', EEmailError(E).Code);
      if EEmailError(E).EnhancedCode <> '' then
        FSpan.SetAttribute('pascalemail.reply.enhanced_code', EEmailError(E).EnhancedCode);
    end;
    FSpan.SetStatus(ssError, EmailErrorDescription(E));
  finally
    FSpan.Finish;
    FSpan := nil;
  end;
end;

{ TEmailBatchTelemetry }

class function TEmailBatchTelemetry.Start(const ASender: string;
  AMessages: Integer): TEmailBatchTelemetry;
begin
  Result.FSpan := TPcTracing.StartSpan(EMAIL_SEND_MANY_SPAN, skInternal);
  Result.FSpan.SetAttribute('pascalemail.sender', ASender);
  Result.FSpan.SetIntAttribute('pascalemail.messages', AMessages);
end;

procedure TEmailBatchTelemetry.Done(const AOutcomes: TEmailSendOutcomes);
var
  I, LFailed: Integer;
begin
  if FSpan = nil then
    Exit;
  try
    LFailed := 0;
    for I := 0 to High(AOutcomes) do
      if not AOutcomes[I].Sent then
        Inc(LFailed);
    FSpan.SetIntAttribute('pascalemail.failed', LFailed);
  finally
    FSpan.Finish;
    FSpan := nil;
  end;
end;

procedure TEmailBatchTelemetry.Fail(E: Exception);
begin
  if FSpan = nil then
    Exit;
  try
    FSpan.SetAttribute('error.type', E.ClassName);
    FSpan.SetStatus(ssError, EmailErrorDescription(E));
  finally
    FSpan.Finish;
    FSpan := nil;
  end;
end;

end.
