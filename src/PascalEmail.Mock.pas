unit PascalEmail.Mock;

{$I pascalemail.inc}

{ An in-memory sender, for an application's tests without a server
  (design, E10).

  Every message sent is kept with the MIME the library wrote for it (the
  same EmailBuildMime the SMTP adapter sends) and the result returned, so a
  test checks what would have gone out: recipients, subject, or exact bytes
  with a counting IEmailIdSource. FailNext makes the next sends raise a
  chosen class, so a test exercises the application's retry handling
  (EEmailTransient), a bounce (EEmailRejected) or a lost answer
  (EEmailOutcomeUnknown).

  Thread-safe: a sender is shared by the threads of an application. }

interface

uses
  SysUtils,
  SyncObjs,
  PascalEmail.Errors,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.Interfaces;

type
  EEmailErrorClass = class of EEmailError;

  TMockSentEmail = record
    Message: IEmailMessage;
    Mime: TEmailMime;
    SendResult: TEmailSendResult;
  end;

  TMockEmailSender = class(TEmailSenderBase)
  private
    FLock: TCriticalSection;
    FIds: IEmailIdSource;
    FSent: TArray<TMockSentEmail>;
    FFailClass: EEmailErrorClass;
    FFailMessage: string;
    FFailCode: Integer;
    FFailCount: Integer;
    FAttempts: Integer;
  public
    /// AIds nil = random boundaries and Message-IDs.
    constructor Create(const AIds: IEmailIdSource = nil);
    destructor Destroy; override;
    function Name: string; override;
    /// Validates and writes the message (EEmailArgumentError, as the real
    /// engines), then keeps it; or raises what FailNext asked for.
    function Send(const AMessage: IEmailMessage): TEmailSendResult; override;
    /// The next ACount sends raise AClass (after validating the message,
    /// like an engine), with ACode as its Code; they keep nothing.
    procedure FailNext(AClass: EEmailErrorClass; ACount: Integer = 1;
      const AMessage: string = 'mock failure'; ACode: Integer = 0);
    /// Messages kept, in the order sent.
    function Count: Integer;
    function Sent(AIndex: Integer): TMockSentEmail;
    /// The last one; EEmailError when nothing was sent.
    function Last: TMockSentEmail;
    /// Every call to Send, failed ones included.
    function Attempts: Integer;
    procedure Clear;
  end;

implementation

{ TMockEmailSender }

constructor TMockEmailSender.Create(const AIds: IEmailIdSource);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FIds := AIds;
end;

destructor TMockEmailSender.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TMockEmailSender.Name: string;
begin
  Result := 'mock';
end;

function TMockEmailSender.Send(const AMessage: IEmailMessage): TEmailSendResult;
var
  LSent: TMockSentEmail;
  LFailClass: EEmailErrorClass;
  LFailMessage: string;
  LFailCode: Integer;
begin
  LFailClass := nil;
  LFailMessage := '';
  LFailCode := 0;
  FLock.Acquire;
  try
    Inc(FAttempts);
    if FFailCount > 0 then
    begin
      Dec(FFailCount);
      LFailClass := FFailClass;
      LFailMessage := FFailMessage;
      LFailCode := FFailCode;
    end;
  finally
    FLock.Release;
  end;
  LSent.Message := AMessage;
  LSent.Mime := EmailBuildMime(AMessage, FIds);
  if LFailClass <> nil then
    raise LFailClass.CreateReply(LFailMessage, LFailCode, '', LFailMessage);
  FLock.Acquire;
  try
    LSent.SendResult := Default(TEmailSendResult);
    LSent.SendResult.MessageId := LSent.Mime.MessageId;
    LSent.SendResult.ProviderId := 'mock-' + IntToStr(Length(FSent) + 1);
    SetLength(FSent, Length(FSent) + 1);
    FSent[High(FSent)] := LSent;
    Result := LSent.SendResult;
  finally
    FLock.Release;
  end;
end;

procedure TMockEmailSender.FailNext(AClass: EEmailErrorClass; ACount: Integer;
  const AMessage: string; ACode: Integer);
begin
  FLock.Acquire;
  try
    FFailClass := AClass;
    FFailCount := ACount;
    FFailMessage := AMessage;
    FFailCode := ACode;
  finally
    FLock.Release;
  end;
end;

function TMockEmailSender.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FSent);
  finally
    FLock.Release;
  end;
end;

function TMockEmailSender.Sent(AIndex: Integer): TMockSentEmail;
begin
  FLock.Acquire;
  try
    if (AIndex < 0) or (AIndex > High(FSent)) then
      raise EEmailError.CreateFmt('TMockEmailSender.Sent: no message %d (%d sent)',
        [AIndex, Length(FSent)]);
    Result := FSent[AIndex];
  finally
    FLock.Release;
  end;
end;

function TMockEmailSender.Last: TMockSentEmail;
begin
  FLock.Acquire;
  try
    if Length(FSent) = 0 then
      raise EEmailError.Create('TMockEmailSender.Last: nothing was sent');
    Result := FSent[High(FSent)];
  finally
    FLock.Release;
  end;
end;

function TMockEmailSender.Attempts: Integer;
begin
  FLock.Acquire;
  try
    Result := FAttempts;
  finally
    FLock.Release;
  end;
end;

procedure TMockEmailSender.Clear;
begin
  FLock.Acquire;
  try
    FSent := nil;
    FAttempts := 0;
    FFailCount := 0;
  finally
    FLock.Release;
  end;
end;

end.
