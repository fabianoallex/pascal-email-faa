unit PascalEmail.Decorators;

{$I pascalemail.inc}

{ Senders that wrap another sender, for development and staging (design,
  section 11): the real engine still sends, but only to people who expect
  it.

  - TRedirectEmailSender sends every message to a fixed list of addresses
    (a QA mailbox) instead of its recipients. The original To, Cc and Bcc
    go in X-Original-To / X-Original-Cc / X-Original-Bcc headers, and the
    subject gets a prefix ('[REDIRECTED] ' by default), so whoever reads it
    sees who it was for.
  - TAllowlistEmailSender delivers only to addresses or domains on a list
    ('@empresa.com.br', 'ana@example.com'); the other recipients are left
    out and reported in TEmailSendResult.Rejected (Code 0), like a server's
    partial refusal. A message with no allowed recipient is not sent at
    all, and no exception is raised: ProviderId is '' and every recipient
    is in Rejected.

  Neither changes the caller's message: they send a copy
  (EmailCopyMessage). Both validate the original first, so a message
  without From or recipients is still EEmailArgumentError, as on a real
  engine. The inner sender's errors pass through unchanged. SendMany goes
  to the inner sender's SendMany, so SMTP keeps one connection.

  They compose: TAllowlistEmailSender.Create(TRedirectEmailSender.Create(
  Smtp, ...), ...) is pointless, but an allowlist around SMTP in staging and
  a redirect around SMTP in a shared test environment are the usual uses.
  For a laptop, an SMTP sender pointed at Mailpit (nothing leaves the
  machine) or TFileEmailSender is simpler. }

interface

uses
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Address,
  PascalEmail.Message,
  PascalEmail.Interfaces;

const
  EMAIL_REDIRECT_SUBJECT_PREFIX = '[REDIRECTED] ';
  /// TEmailRejection.Text of a recipient TAllowlistEmailSender left out.
  EMAIL_NOT_ALLOWED_TEXT = 'not in the allowlist (TAllowlistEmailSender)';

type
  TRedirectEmailSender = class(TEmailSenderBase)
  private
    FInner: IEmailSender;
    FTo: TArray<string>;
    FSubjectPrefix: string;
    function Redirected(const AMessage: IEmailMessage): IEmailMessage;
  public
    /// ARedirectTo: the addresses every message goes to instead (at least
    /// one, each valid: EEmailArgumentError). ASubjectPrefix '' leaves the
    /// subject alone.
    constructor Create(const AInner: IEmailSender; const ARedirectTo: array of string;
      const ASubjectPrefix: string = EMAIL_REDIRECT_SUBJECT_PREFIX);
    function Name: string; override;
    function Send(const AMessage: IEmailMessage): TEmailSendResult; override;
    function SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes; override;
  end;

  TAllowlistEmailSender = class(TEmailSenderBase)
  private
    FInner: IEmailSender;
    FDomains: TArray<string>;   // lower case, without '@'
    FAddresses: TArray<string>; // lower case
    /// The message with only the allowed recipients (nil when none is), and
    /// the recipients left out.
    function Filtered(const AMessage: IEmailMessage; out ADropped: TEmailRejections): IEmailMessage;
    /// Adds AList's allowed addresses to ATarget (AKind 0 To, 1 Cc, 2 Bcc)
    /// and the others to ADropped.
    procedure Take(const AList: TEmailAddresses; AKind: Integer; const ATarget: IEmailMessage;
      var ADropped: TEmailRejections; var ACount: Integer);
  public
    /// AAllowed: '@domain' entries allow that domain (exactly, without
    /// case; not its subdomains), the others are whole addresses. At least
    /// one entry, each valid: EEmailArgumentError.
    constructor Create(const AInner: IEmailSender; const AAllowed: array of string);
    function Name: string; override;
    function IsAllowed(const AAddress: string): Boolean;
    function Send(const AMessage: IEmailMessage): TEmailSendResult; override;
    function SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes; override;
  end;

implementation

function JoinAddresses(const AList: TEmailAddresses): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AList) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + AList[I].Address;
  end;
end;

procedure AppendRejections(var ATarget: TEmailRejections; const AMore: TEmailRejections);
var
  I, LBase: Integer;
begin
  LBase := Length(ATarget);
  SetLength(ATarget, LBase + Length(AMore));
  for I := 0 to High(AMore) do
    ATarget[LBase + I] := AMore[I];
end;

{ TRedirectEmailSender }

constructor TRedirectEmailSender.Create(const AInner: IEmailSender;
  const ARedirectTo: array of string; const ASubjectPrefix: string);
var
  I: Integer;
begin
  inherited Create;
  FInner := AInner; // before anything can raise (gotcha 1)
  if FInner = nil then
    raise EEmailArgumentError.Create('TRedirectEmailSender: no inner sender');
  if Length(ARedirectTo) = 0 then
    raise EEmailArgumentError.Create('TRedirectEmailSender: no address to redirect to');
  SetLength(FTo, Length(ARedirectTo));
  for I := 0 to High(ARedirectTo) do
  begin
    // Parse accepts 'Name <a@b>' too; the name is dropped.
    FTo[I] := TEmailAddress.Parse(ARedirectTo[I]).Address;
  end;
  EmailCheckHeaderText('subject prefix', ASubjectPrefix);
  FSubjectPrefix := ASubjectPrefix;
end;

function TRedirectEmailSender.Name: string;
begin
  Result := 'redirect(' + FInner.Name + ')';
end;

function TRedirectEmailSender.Redirected(const AMessage: IEmailMessage): IEmailMessage;
var
  I: Integer;
begin
  if AMessage = nil then
    raise EEmailArgumentError.Create('the message is nil');
  AMessage.Validate;
  Result := EmailCopyMessage(AMessage, False);
  for I := 0 to High(FTo) do
    Result.AddTo(FTo[I]);
  if Length(AMessage.ToList) > 0 then
    Result.AddHeader('X-Original-To', JoinAddresses(AMessage.ToList));
  if Length(AMessage.CcList) > 0 then
    Result.AddHeader('X-Original-Cc', JoinAddresses(AMessage.CcList));
  if Length(AMessage.BccList) > 0 then
    Result.AddHeader('X-Original-Bcc', JoinAddresses(AMessage.BccList));
  if FSubjectPrefix <> '' then
    Result.SetSubject(FSubjectPrefix + AMessage.Subject);
end;

function TRedirectEmailSender.Send(const AMessage: IEmailMessage): TEmailSendResult;
begin
  Result := FInner.Send(Redirected(AMessage));
end;

function TRedirectEmailSender.SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes;
var
  LCopies: array of IEmailMessage;
  LIndex: array of Integer;
  LInner: TEmailSendOutcomes;
  I, N: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AMessages));
  SetLength(LCopies, Length(AMessages));
  SetLength(LIndex, Length(AMessages));
  N := 0;
  for I := 0 to High(AMessages) do
    try
      LCopies[N] := Redirected(AMessages[I]);
      LIndex[N] := I;
      Inc(N);
    except
      on E: EEmailError do
        Result[I] := EmailFailedOutcome(E);
    end;
  SetLength(LCopies, N);
  if N = 0 then
    Exit;
  LInner := FInner.SendMany(LCopies);
  for I := 0 to N - 1 do
    Result[LIndex[I]] := LInner[I];
end;

{ TAllowlistEmailSender }

constructor TAllowlistEmailSender.Create(const AInner: IEmailSender;
  const AAllowed: array of string);
var
  I: Integer;
  LEntry: string;
begin
  inherited Create;
  FInner := AInner; // before anything can raise (gotcha 1)
  if FInner = nil then
    raise EEmailArgumentError.Create('TAllowlistEmailSender: no inner sender');
  if Length(AAllowed) = 0 then
    raise EEmailArgumentError.Create('TAllowlistEmailSender: the allowlist is empty');
  for I := 0 to High(AAllowed) do
  begin
    LEntry := LowerCase(Trim(AAllowed[I]));
    if (LEntry <> '') and (LEntry[1] = '@') then
    begin
      // A domain: valid when 'x@domain' is a valid address.
      if not EmailIsValidAddress('x' + LEntry) then
        raise EEmailArgumentError.CreateFmt('TAllowlistEmailSender: invalid domain "%s"',
          [AAllowed[I]]);
      SetLength(FDomains, Length(FDomains) + 1);
      FDomains[High(FDomains)] := Copy(LEntry, 2, MaxInt);
    end
    else
    begin
      if not EmailIsValidAddress(LEntry) then
        raise EEmailArgumentError.CreateFmt('TAllowlistEmailSender: invalid entry "%s" ' +
          '(an address, or @domain)', [AAllowed[I]]);
      SetLength(FAddresses, Length(FAddresses) + 1);
      FAddresses[High(FAddresses)] := LEntry;
    end;
  end;
end;

function TAllowlistEmailSender.Name: string;
begin
  Result := 'allowlist(' + FInner.Name + ')';
end;

function TAllowlistEmailSender.IsAllowed(const AAddress: string): Boolean;
var
  I: Integer;
  LAddress, LDomain: string;
begin
  LAddress := LowerCase(AAddress);
  for I := 0 to High(FAddresses) do
    if LAddress = FAddresses[I] then
      Exit(True);
  LDomain := Copy(LAddress, LastDelimiter('@', LAddress) + 1, MaxInt);
  for I := 0 to High(FDomains) do
    if LDomain = FDomains[I] then
      Exit(True);
  Result := False;
end;

procedure TAllowlistEmailSender.Take(const AList: TEmailAddresses; AKind: Integer;
  const ATarget: IEmailMessage; var ADropped: TEmailRejections; var ACount: Integer);
var
  I: Integer;
begin
  for I := 0 to High(AList) do
    if IsAllowed(AList[I].Address) then
    begin
      case AKind of
        0: ATarget.AddTo(AList[I].Address, AList[I].Name);
        1: ATarget.AddCc(AList[I].Address, AList[I].Name);
      else
        ATarget.AddBcc(AList[I].Address, AList[I].Name);
      end;
      Inc(ACount);
    end
    else
    begin
      SetLength(ADropped, Length(ADropped) + 1);
      ADropped[High(ADropped)].Address := AList[I].Address;
      ADropped[High(ADropped)].Code := 0;
      ADropped[High(ADropped)].EnhancedCode := '';
      ADropped[High(ADropped)].Text := EMAIL_NOT_ALLOWED_TEXT;
    end;
end;

function TAllowlistEmailSender.Filtered(const AMessage: IEmailMessage;
  out ADropped: TEmailRejections): IEmailMessage;
var
  LCopy: IEmailMessage;
  LCount: Integer;
begin
  ADropped := nil;
  if AMessage = nil then
    raise EEmailArgumentError.Create('the message is nil');
  AMessage.Validate;
  LCopy := EmailCopyMessage(AMessage, False);
  LCount := 0;
  Take(AMessage.ToList, 0, LCopy, ADropped, LCount);
  Take(AMessage.CcList, 1, LCopy, ADropped, LCount);
  Take(AMessage.BccList, 2, LCopy, ADropped, LCount);
  if LCount = 0 then
    Result := nil
  else
    Result := LCopy;
end;

function TAllowlistEmailSender.Send(const AMessage: IEmailMessage): TEmailSendResult;
var
  LCopy: IEmailMessage;
  LDropped: TEmailRejections;
begin
  LCopy := Filtered(AMessage, LDropped);
  if LCopy = nil then
  begin
    Result := Default(TEmailSendResult);
    Result.MessageId := AMessage.MessageId;
    Result.Rejected := LDropped;
    Exit;
  end;
  Result := FInner.Send(LCopy);
  AppendRejections(LDropped, Result.Rejected);
  Result.Rejected := LDropped;
end;

function TAllowlistEmailSender.SendMany(const AMessages: array of IEmailMessage): TEmailSendOutcomes;
var
  LCopies: array of IEmailMessage;
  LIndex: array of Integer;
  LDropped: array of TEmailRejections;
  LCopy: IEmailMessage;
  LThis: TEmailRejections;
  LInner: TEmailSendOutcomes;
  LResult: TEmailSendResult;
  I, N: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AMessages));
  SetLength(LCopies, Length(AMessages));
  SetLength(LIndex, Length(AMessages));
  SetLength(LDropped, Length(AMessages));
  N := 0;
  for I := 0 to High(AMessages) do
    try
      LCopy := Filtered(AMessages[I], LThis);
      LDropped[I] := LThis;
      if LCopy = nil then
      begin
        LResult := Default(TEmailSendResult);
        LResult.MessageId := AMessages[I].MessageId;
        LResult.Rejected := LThis;
        Result[I] := EmailSentOutcome(LResult);
      end
      else
      begin
        LCopies[N] := LCopy;
        LIndex[N] := I;
        Inc(N);
      end;
    except
      on E: EEmailError do
        Result[I] := EmailFailedOutcome(E);
    end;
  SetLength(LCopies, N);
  if N = 0 then
    Exit;
  LInner := FInner.SendMany(LCopies);
  for I := 0 to N - 1 do
  begin
    Result[LIndex[I]] := LInner[I];
    if LInner[I].Sent then
    begin
      LThis := Copy(LDropped[LIndex[I]]);
      AppendRejections(LThis, LInner[I].SendResult.Rejected);
      Result[LIndex[I]].SendResult.Rejected := LThis;
    end;
  end;
end;

end.
