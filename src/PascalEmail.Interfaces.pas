unit PascalEmail.Interfaces;

{$I pascalemail.inc}

{ The sending contract every engine implements: IEmailSender (design,
  section 5).

  A sender is thread-safe and meant to be kept for the process (design,
  E6): it holds configuration, never a message. Send hands one message to
  the engine and either returns what the engine said (TEmailSendResult) or
  raises one of PascalEmail.Errors' classes, which say whether a retry may
  help. SendMany sends several through one connection where the engine
  allows it; each message's failure is in its outcome, not raised, so one
  bad address doesn't stop the others.

  TEmailSenderBase gives an engine SendMany as a loop over Send, inside an
  'email send_many' span (PascalEmail.Telemetry); the SMTP adapter
  overrides it to keep one connection. }

interface

uses
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Message;

type
  TEmailSendResult = record
    /// The Message-ID header sent, without angle brackets.
    MessageId: string;
    /// The engine's own id for the message, when it gives one: the queue id
    /// in an SMTP server's final reply, a provider's message id. '' when
    /// the engine said nothing usable.
    ProviderId: string;
    /// SMTP only: recipients the server refused while it accepted others
    /// (design, E7).
    Rejected: TEmailRejections;
  end;

  /// One message of SendMany.
  TEmailSendOutcome = record
    Sent: Boolean;
    /// When Sent.
    SendResult: TEmailSendResult;
    /// When not Sent: the exception Send would have raised.
    ErrorClass: ExceptClass;
    ErrorMessage: string;
    Code: Integer;
    EnhancedCode: string;
    /// EmailIsRetryable of the error.
    Retryable: Boolean;
  end;

  TEmailSendOutcomes = TArray<TEmailSendOutcome>;

  IEmailSender = interface
    ['{8A3F2C61-0E9B-4D75-A1C8-5B7E4F29D603}']
    /// 'smtp', 'mock', 'file' ...: for logs.
    function Name: string;
    function Send(const AMessage: IEmailMessage): TEmailSendResult;
    function SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes;
  end;

  TEmailSenderBase = class(TInterfacedObject, IEmailSender)
  public
    function Name: string; virtual; abstract;
    function Send(const AMessage: IEmailMessage): TEmailSendResult; virtual; abstract;
    /// Send for each message; an EEmailError becomes the message's outcome,
    /// any other exception (a bug) propagates.
    function SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes; virtual;
  end;

/// The outcome of a failed send, from its exception.
function EmailFailedOutcome(E: Exception): TEmailSendOutcome;
/// The outcome of a sent message.
function EmailSentOutcome(const AResult: TEmailSendResult): TEmailSendOutcome;

implementation

uses
  PascalEmail.Telemetry;

function EmailFailedOutcome(E: Exception): TEmailSendOutcome;
begin
  Result := Default(TEmailSendOutcome);
  Result.Sent := False;
  Result.ErrorClass := ExceptClass(E.ClassType);
  Result.ErrorMessage := E.Message;
  if E is EEmailError then
  begin
    Result.Code := EEmailError(E).Code;
    Result.EnhancedCode := EEmailError(E).EnhancedCode;
  end;
  Result.Retryable := EmailIsRetryable(E);
end;

function EmailSentOutcome(const AResult: TEmailSendResult): TEmailSendOutcome;
begin
  Result := Default(TEmailSendOutcome);
  Result.Sent := True;
  Result.SendResult := AResult;
end;

{ TEmailSenderBase }

function TEmailSenderBase.SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes;
var
  I: Integer;
  LBatch: TEmailBatchTelemetry;
begin
  Result := nil;
  SetLength(Result, Length(AMessages));
  LBatch := TEmailBatchTelemetry.Start(Name, Length(AMessages));
  try
    for I := 0 to High(AMessages) do
      try
        Result[I] := EmailSentOutcome(Send(AMessages[I]));
      except
        on E: EEmailError do
          Result[I] := EmailFailedOutcome(E);
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
