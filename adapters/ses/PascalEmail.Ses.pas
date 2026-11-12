unit PascalEmail.Ses;

{$I pascalemail.inc}

{ The Amazon SES sender (API v2, SendEmail with raw content), on
  pascal-common-faa's HTTP client (design, section 12).

  The message goes as PascalEmail.Mime writes it, Base64 in
  Content.Raw.Data, so SES sends the same bytes SMTP would. The envelope
  is explicit (Destination: To, Cc and Bcc): Bcc isn't in the headers, and
  SES would otherwise take the recipients from them. FromEmailAddress is
  left out: SES then uses the From header. Metadata becomes EmailTags (SES's
  event destinations see them); tags (names alone) become EmailTags with
  the value 'true'. SES accepts only letters, digits, '_' and '-' there,
  up to 256 characters: anything else is EEmailArgumentError before the
  request.

  Requests are signed with AWS Signature Version 4 (PascalEmail.AwsSigV4)
  at the clock's time (TClock, through EmailUtcNow), with static
  credentials or, for an IAM role, from an ISesCredentialsProvider asked at
  every send (it caches and refreshes; the library doesn't).

  Errors (design, E8 and section 12): an HTTP status is mapped by the
  x-amzn-ErrorType header (or the body's __type) first, then by the status:
  - MessageRejected, BadRequestException, any other 4xx: EEmailRejected;
  - 401, 403 (signature, keys, permissions), NotFoundException (a
    configuration set that doesn't exist), MailFromDomainNotVerified,
    AccountSuspended, SendingPaused: EEmailAuthError (the account's
    configuration: a retry after fixing it);
  - 429, TooManyRequests, LimitExceeded, Throttling, any 5xx:
    EEmailTransient;
  - no HTTP answer at all (EPcHttpTransport): EEmailOutcomeUnknown. The
    transport raises the same class when the connection failed (nothing
    sent) and when the request went out and the answer never came, and a
    POST is never sent twice by it; so the library can't tell those apart
    and says the safe thing (a retry may duplicate).
  None of this was measured against AWS (no account): the error names come
  from the SES v2 API reference (docs/findings.md, finding 12).

  A sender is thread-safe (one HTTP transport, kept for the process, with
  its keep-alive pool). }

interface

uses
  SysUtils,
  PascalCommon.Http,
  PascalCommon.Http.Client,
  PascalEmail.Errors,
  PascalEmail.Address,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.Interfaces,
  PascalEmail.AwsSigV4;

const
  SES_SERVICE = 'ses';
  SES_SEND_PATH = '/v2/email/outbound-emails';

type
  /// Temporary credentials for an IAM role (instance profile, ECS task,
  /// STS): asked at every send, from the sending thread.
  ISesCredentialsProvider = interface
    ['{3F8B1D2C-6E47-4A95-B0C3-8D1E5F7A2B96}']
    function Credentials: TAwsCredentials;
  end;

  TSesOptions = record
    /// 'us-east-1', 'sa-east-1' ...
    Region: string;
    AccessKeyId: string;
    SecretAccessKey: string;
    SessionToken: string;
    /// Takes the place of the three fields above when set.
    CredentialsProvider: ISesCredentialsProvider;
    /// SES's configuration set (event publishing, dedicated IPs); '' none.
    ConfigurationSetName: string;
    /// '' = https://email.<Region>.amazonaws.com. Another base URL for a
    /// VPC endpoint or an emulator.
    Endpoint: string;
    /// Per request; 0 = PascalCommon.Http's default (15 s).
    TimeoutMs: Integer;
    /// For the transport the sender creates (not used when one is given).
    Http: TPcHttpOptions;
    class function Create(const ARegion, AAccessKeyId, ASecretAccessKey: string): TSesOptions; static;
    function BaseUrl: string;
  end;

  TSesSender = class(TEmailSenderBase)
  private
    FOptions: TSesOptions;
    FHttp: IPcHttpTransport;
    FIds: IEmailIdSource;
    function CurrentCredentials: TAwsCredentials;
    function RequestBody(const AMessage: IEmailMessage; const AMime: TEmailMime): string;
    procedure RaiseForStatus(const AResponse: TPcHttpResponse);
  public
    /// EEmailArgumentError for options that can't work (no region, a region
    /// that isn't a name, no credentials, a bad configuration set name).
    /// ATransport nil = a new pascal-common-faa HTTP transport; AIds nil =
    /// random ids.
    constructor Create(const AOptions: TSesOptions; const ATransport: IPcHttpTransport = nil;
      const AIds: IEmailIdSource = nil);
    function Name: string; override;
    function Send(const AMessage: IEmailMessage): TEmailSendResult; override;
    property Options: TSesOptions read FOptions;
  end;

/// The request SendEmail's body is, for AMessage written as AMime (tests).
function SesRequestBody(const AMessage: IEmailMessage; const AMime: TEmailMime;
  const AConfigurationSetName: string): string;

implementation

uses
  PascalCommon.Version,
  PascalCommon.Crypto;

{$IF PASCALCOMMON_VERSION < 13200}
  {$MESSAGE FATAL 'pascal-email-faa needs pascal-common-faa 1.32.0 or later'}
{$IFEND}

{ Helpers }

function JsonString(const AText: string): string;
var
  I: Integer;
begin
  // Every value written here is ASCII (checked or Base64); the escapes are
  // for '"' and '\' only, defensively.
  Result := '"';
  for I := 1 to Length(AText) do
    case AText[I] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
    else
      Result := Result + AText[I];
    end;
  Result := Result + '"';
end;

function IsSesName(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := (AText <> '') and (Length(AText) <= 256);
  for I := 1 to Length(AText) do
    if not CharInSet(AText[I], ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then
      Exit(False);
end;

function JsonAddressList(const AList: TArray<string>): string;
var
  I: Integer;
begin
  Result := '[';
  for I := 0 to High(AList) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + JsonString(AList[I]);
  end;
  Result := Result + ']';
end;

function Addresses(const AList: TEmailAddresses): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(AList));
  for I := 0 to High(AList) do
    Result[I] := AList[I].Address;
end;

// A string field of a small JSON object ('' when missing), case-insensitive
// on the name. AWS's answers here are flat objects.
function JsonField(const AJson, AName: string): string;
var
  P: Integer;
  LLower: string;
begin
  Result := '';
  LLower := LowerCase(AJson);
  P := Pos('"' + LowerCase(AName) + '"', LLower);
  if P = 0 then
    Exit;
  P := P + Length(AName) + 2;
  while (P <= Length(AJson)) and CharInSet(AJson[P], [' ', ':', #9, #10, #13]) do
    Inc(P);
  if (P > Length(AJson)) or (AJson[P] <> '"') then
    Exit;
  Inc(P);
  while (P <= Length(AJson)) and (AJson[P] <> '"') do
  begin
    if (AJson[P] = '\') and (P < Length(AJson)) then
      Inc(P);
    Result := Result + AJson[P];
    Inc(P);
  end;
end;

function SesRequestBody(const AMessage: IEmailMessage; const AMime: TEmailMime;
  const AConfigurationSetName: string): string;
var
  LDest, LTags: string;
  LMeta: TEmailHeaders;
  LTagNames: TArray<string>;
  I: Integer;

  procedure AddTag(const AName, AValue: string);
  begin
    if not IsSesName(AName) or not IsSesName(AValue) then
      raise EEmailArgumentError.CreateFmt('SES tag "%s"="%s": only letters, digits, "_" and "-", ' +
        'up to 256 characters', [AName, AValue]);
    if LTags <> '' then
      LTags := LTags + ',';
    LTags := LTags + '{"Name":' + JsonString(AName) + ',"Value":' + JsonString(AValue) + '}';
  end;

begin
  LDest := '';
  if Length(AMessage.ToList) > 0 then
    LDest := '"ToAddresses":' + JsonAddressList(Addresses(AMessage.ToList));
  if Length(AMessage.CcList) > 0 then
  begin
    if LDest <> '' then
      LDest := LDest + ',';
    LDest := LDest + '"CcAddresses":' + JsonAddressList(Addresses(AMessage.CcList));
  end;
  if Length(AMessage.BccList) > 0 then
  begin
    if LDest <> '' then
      LDest := LDest + ',';
    LDest := LDest + '"BccAddresses":' + JsonAddressList(Addresses(AMessage.BccList));
  end;
  LTags := '';
  LTagNames := AMessage.Tags;
  for I := 0 to High(LTagNames) do
    AddTag(LTagNames[I], 'true');
  LMeta := AMessage.Metadata;
  for I := 0 to High(LMeta) do
    AddTag(LMeta[I].Name, LMeta[I].Value);
  Result := '{"Content":{"Raw":{"Data":' + JsonString(PcBase64Encode(AMime.Data)) + '}},' +
    '"Destination":{' + LDest + '}';
  if AConfigurationSetName <> '' then
    Result := Result + ',"ConfigurationSetName":' + JsonString(AConfigurationSetName);
  if LTags <> '' then
    Result := Result + ',"EmailTags":[' + LTags + ']';
  Result := Result + '}';
end;

{ TSesOptions }

class function TSesOptions.Create(const ARegion, AAccessKeyId,
  ASecretAccessKey: string): TSesOptions;
begin
  Result := Default(TSesOptions);
  Result.Region := ARegion;
  Result.AccessKeyId := AAccessKeyId;
  Result.SecretAccessKey := ASecretAccessKey;
end;

function TSesOptions.BaseUrl: string;
begin
  if Endpoint <> '' then
  begin
    Result := Endpoint;
    while (Result <> '') and (Result[Length(Result)] = '/') do
      SetLength(Result, Length(Result) - 1);
  end
  else
    Result := 'https://email.' + Region + '.amazonaws.com';
end;

{ TSesSender }

constructor TSesSender.Create(const AOptions: TSesOptions;
  const ATransport: IPcHttpTransport; const AIds: IEmailIdSource);
var
  I: Integer;
begin
  inherited Create;
  // The interfaces first (gotcha 1).
  FHttp := ATransport;
  FIds := AIds;
  FOptions := AOptions;
  if FOptions.Region = '' then
    raise EEmailArgumentError.Create('TSesSender: no region');
  for I := 1 to Length(FOptions.Region) do
    if not CharInSet(FOptions.Region[I], ['a'..'z', '0'..'9', '-']) then
      raise EEmailArgumentError.CreateFmt('TSesSender: "%s" is not a region name',
        [FOptions.Region]);
  if (FOptions.CredentialsProvider = nil) and
    ((FOptions.AccessKeyId = '') or (FOptions.SecretAccessKey = '')) then
    raise EEmailArgumentError.Create('TSesSender: no credentials (AccessKeyId and ' +
      'SecretAccessKey, or a CredentialsProvider)');
  if (FOptions.ConfigurationSetName <> '') and not IsSesName(FOptions.ConfigurationSetName) then
    raise EEmailArgumentError.CreateFmt('TSesSender: invalid configuration set name "%s"',
      [FOptions.ConfigurationSetName]);
  if FHttp = nil then
    FHttp := PcNewHttpTransport(FOptions.Http);
end;

function TSesSender.Name: string;
begin
  Result := 'ses';
end;

function TSesSender.CurrentCredentials: TAwsCredentials;
begin
  if FOptions.CredentialsProvider <> nil then
  begin
    Result := FOptions.CredentialsProvider.Credentials;
    if (Result.AccessKeyId = '') or (Result.SecretAccessKey = '') then
      raise EEmailAuthError.Create('SES: the credentials provider gave empty credentials');
  end
  else
  begin
    Result.AccessKeyId := FOptions.AccessKeyId;
    Result.SecretAccessKey := FOptions.SecretAccessKey;
    Result.SessionToken := FOptions.SessionToken;
  end;
end;

function TSesSender.RequestBody(const AMessage: IEmailMessage; const AMime: TEmailMime): string;
begin
  Result := SesRequestBody(AMessage, AMime, FOptions.ConfigurationSetName);
end;

procedure TSesSender.RaiseForStatus(const AResponse: TPcHttpResponse);
var
  LType, LText, LMessage: string;
  P: Integer;
begin
  LType := AResponse.Header('x-amzn-ErrorType');
  if LType = '' then
    LType := JsonField(AResponse.Body, '__type');
  // 'MessageRejected:http://internal.amazon.com/...' and
  // 'com.amazonaws...#MessageRejected' are both seen in AWS answers.
  P := Pos(':', LType);
  if P > 0 then
    LType := Copy(LType, 1, P - 1);
  P := LastDelimiter('#', LType);
  if P > 0 then
    LType := Copy(LType, P + 1, MaxInt);
  LText := JsonField(AResponse.Body, 'message');
  if LText = '' then
    LText := Copy(AResponse.Body, 1, 300);
  LMessage := Format('SES: HTTP %d %s: %s', [AResponse.Status, LType, LText]);
  if (LType = 'TooManyRequestsException') or (LType = 'LimitExceededException') or
    (LType = 'ThrottlingException') or (AResponse.Status = 429) or (AResponse.Status >= 500) then
    raise EEmailTransient.CreateReply(LMessage, AResponse.Status, '', AResponse.Body);
  if (AResponse.Status = 401) or (AResponse.Status = 403) or (LType = 'NotFoundException') or
    (LType = 'MailFromDomainNotVerifiedException') or (LType = 'AccountSuspendedException') or
    (LType = 'SendingPausedException') then
    raise EEmailAuthError.CreateReply(LMessage, AResponse.Status, '', AResponse.Body);
  raise EEmailRejected.CreateReply(LMessage, AResponse.Status, '', AResponse.Body);
end;

function TSesSender.Send(const AMessage: IEmailMessage): TEmailSendResult;
var
  LMime: TEmailMime;
  LRequest: TPcHttpRequest;
  LResponse: TPcHttpResponse;
begin
  LMime := EmailBuildMime(AMessage, FIds);
  LRequest := TPcHttpRequest.Create('POST', FOptions.BaseUrl + SES_SEND_PATH);
  LRequest.AddHeader('Content-Type', 'application/json');
  LRequest.Body := RequestBody(AMessage, LMime);
  LRequest.TimeoutMs := FOptions.TimeoutMs;
  try
    AwsSigV4Sign(LRequest, CurrentCredentials, FOptions.Region, SES_SERVICE, EmailUtcNow);
  except
    on E: EArgumentException do
      raise EEmailAuthError.Create('SES: ' + E.Message);
  end;
  try
    LResponse := FHttp.Send(LRequest);
  except
    on E: EPcHttpTransport do
      raise EEmailOutcomeUnknown.CreateReply('SES: no answer; the message may have been ' +
        'accepted (' + E.Message + ')', 0, '', '');
    on E: EArgumentException do
      raise EEmailArgumentError.Create('SES: ' + E.Message);
  end;
  if (LResponse.Status < 200) or (LResponse.Status > 299) then
    RaiseForStatus(LResponse);
  Result := Default(TEmailSendResult);
  Result.MessageId := LMime.MessageId;
  Result.ProviderId := JsonField(LResponse.Body, 'MessageId');
end;

end.
