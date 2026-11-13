unit PascalEmail.AwsSigV4;

{$I pascalemail.inc}

{ AWS Signature Version 4 for one HTTP request (the Authorization header,
  X-Amz-Date and, with temporary credentials, X-Amz-Security-Token), the
  same on Delphi and FPC, on pascal-common-faa's SHA-256 and HMAC.

  Written for the SES adapter, but nothing in it is SES: a second library
  that talks to AWS would make it a pascal-common-faa candidate (its
  docs/plan.md rule). Checked against AWS's own vectors (docs/findings.md,
  findings 9-11): the signing-key example of AWS's documentation, the
  get-vanilla case of AWS's SigV4 test suite, and SES requests signed by
  botocore 1.44.1 (AWS's Python signer), with and without a session token.

  Every header of the request is signed, plus host, which the HTTP
  transport writes itself (pascal-common-faa refuses a request that sets
  Host): it is computed from the URL exactly as the transport writes it
  (TPcHttpUrl.HostHeader). The path and the query are used as given, so
  they must already be encoded (PcPercentEncode); AWS's double encoding of
  paths for services other than S3 makes no difference to a path of
  unreserved characters, such as SES's. The body is hashed as the UTF-8 the
  transport sends. }

interface

uses
  SysUtils,
  PascalCommon.Http;

type
  TAwsCredentials = record
    AccessKeyId: string;
    SecretAccessKey: string;
    /// Only for temporary credentials (an IAM role, STS); '' otherwise.
    SessionToken: string;
  end;

/// The derived signing key (kSigning): HMAC of 'AWS4' + secret over the date
/// ('yyyymmdd'), the region, the service and 'aws4_request'.
function AwsSigV4SigningKey(const ASecret, ADate, ARegion, AService: string): TBytes;

/// 'yyyymmddThhnnssZ'.
function AwsSigV4Timestamp(const AUtc: TDateTime): string;

/// The canonical request (AWS's step 1), for tests and for debugging a
/// refused signature.
function AwsSigV4CanonicalRequest(const ARequest: TPcHttpRequest): string;

/// Signs ARequest at AUtc: adds X-Amz-Date, X-Amz-Security-Token (with a
/// session token) and Authorization. Any of them already present is
/// replaced. EArgumentException for credentials, a region or a service
/// that are empty.
procedure AwsSigV4Sign(var ARequest: TPcHttpRequest; const ACredentials: TAwsCredentials;
  const ARegion, AService: string; const AUtc: TDateTime);

implementation

uses
  DateUtils,
  PascalCommon.Crypto,
  PascalCommon.Utf8;

const
  LF = #10;
  ALGORITHM = 'AWS4-HMAC-SHA256';

function Utf8(const AText: string): TBytes;
begin
  Result := PcStringToUtf8Bytes(AText);
end;

function Hmac(const AKey: TBytes; const AText: string): TBytes;
begin
  Result := PcDigestToBytes(PcHmacSha256(AKey, Utf8(AText)));
end;

function HexSha256(const AText: string): string;
begin
  Result := LowerCase(PcBytesToHex(PcDigestToBytes(PcSha256(Utf8(AText)))));
end;

function AwsSigV4SigningKey(const ASecret, ADate, ARegion, AService: string): TBytes;
begin
  Result := Hmac(Utf8('AWS4' + ASecret), ADate);
  Result := Hmac(Result, ARegion);
  Result := Hmac(Result, AService);
  Result := Hmac(Result, 'aws4_request');
end;

function AwsSigV4Timestamp(const AUtc: TDateTime): string;
var
  Y, M, D, H, N, S, MS: Word;
begin
  DecodeDateTime(AUtc, Y, M, D, H, N, S, MS);
  Result := Format('%.4d%.2d%.2dT%.2d%.2d%.2dZ', [Y, M, D, H, N, S]);
end;

// A header's value as AWS canonicalizes it: trimmed, inner runs of blanks
// made one space.
function CanonicalValue(const AValue: string): string;
var
  I: Integer;
  LBlank: Boolean;
begin
  Result := '';
  LBlank := False;
  for I := 1 to Length(AValue) do
    if (AValue[I] = ' ') or (AValue[I] = #9) then
      LBlank := True
    else
    begin
      if LBlank and (Result <> '') then
        Result := Result + ' ';
      LBlank := False;
      Result := Result + AValue[I];
    end;
end;

procedure SortStrings(var AItems: TArray<string>);
var
  I, J: Integer;
  T: string;
begin
  // Ordinal order (CompareStr), as AWS sorts: a handful of items.
  for I := 1 to High(AItems) do
  begin
    T := AItems[I];
    J := I - 1;
    while (J >= 0) and (CompareStr(AItems[J], T) > 0) do
    begin
      AItems[J + 1] := AItems[J];
      Dec(J);
    end;
    AItems[J + 1] := T;
  end;
end;

procedure SplitUrl(const AUrl: string; out APath, AQuery: string);
var
  LRest: string;
  P: Integer;
begin
  // After 'scheme://host[:port]'.
  LRest := AUrl;
  P := Pos('://', LRest);
  if P > 0 then
    LRest := Copy(LRest, P + 3, MaxInt);
  P := Pos('/', LRest);
  if P = 0 then
    LRest := '/'
  else
    LRest := Copy(LRest, P, MaxInt);
  P := Pos('#', LRest);
  if P > 0 then
    LRest := Copy(LRest, 1, P - 1);
  P := Pos('?', LRest);
  if P > 0 then
  begin
    APath := Copy(LRest, 1, P - 1);
    AQuery := Copy(LRest, P + 1, MaxInt);
  end
  else
  begin
    APath := LRest;
    AQuery := '';
  end;
end;

function CanonicalQuery(const AQuery: string): string;
var
  LParts: TArray<string>;
  LPart: string;
  I, LStart: Integer;
begin
  LParts := nil;
  LStart := 1;
  for I := 1 to Length(AQuery) + 1 do
    if (I > Length(AQuery)) or (AQuery[I] = '&') then
    begin
      LPart := Copy(AQuery, LStart, I - LStart);
      if LPart <> '' then
      begin
        if Pos('=', LPart) = 0 then
          LPart := LPart + '=';
        SetLength(LParts, Length(LParts) + 1);
        LParts[High(LParts)] := LPart;
      end;
      LStart := I + 1;
    end;
  SortStrings(LParts);
  Result := '';
  for I := 0 to High(LParts) do
  begin
    if I > 0 then
      Result := Result + '&';
    Result := Result + LParts[I];
  end;
end;

// 'name:value' lines (lower-case names, sorted) and the signed-header list.
procedure CanonicalHeaders(const ARequest: TPcHttpRequest; out ALines, ASigned: string);
var
  LItems: TArray<string>;
  I, P: Integer;
  LUrl: TPcHttpUrl;
begin
  LUrl := PcParseHttpUrl(ARequest.Url);
  SetLength(LItems, 1);
  LItems[0] := 'host:' + LUrl.HostHeader;
  for I := 0 to High(ARequest.Headers) do
  begin
    SetLength(LItems, Length(LItems) + 1);
    LItems[High(LItems)] := LowerCase(Trim(ARequest.Headers[I].Name)) + ':' +
      CanonicalValue(ARequest.Headers[I].Value);
  end;
  SortStrings(LItems);
  ALines := '';
  ASigned := '';
  for I := 0 to High(LItems) do
  begin
    ALines := ALines + LItems[I] + LF;
    P := Pos(':', LItems[I]);
    if I > 0 then
      ASigned := ASigned + ';';
    ASigned := ASigned + Copy(LItems[I], 1, P - 1);
  end;
end;

function AwsSigV4CanonicalRequest(const ARequest: TPcHttpRequest): string;
var
  LPath, LQuery, LLines, LSigned: string;
begin
  SplitUrl(ARequest.Url, LPath, LQuery);
  CanonicalHeaders(ARequest, LLines, LSigned);
  Result := UpperCase(ARequest.Method) + LF + LPath + LF + CanonicalQuery(LQuery) + LF +
    LLines + LF + LSigned + LF + HexSha256(ARequest.Body);
end;

procedure RemoveHeader(var ARequest: TPcHttpRequest; const AName: string);
var
  I, J: Integer;
begin
  I := 0;
  while I <= High(ARequest.Headers) do
    if SameText(ARequest.Headers[I].Name, AName) then
    begin
      for J := I to High(ARequest.Headers) - 1 do
        ARequest.Headers[J] := ARequest.Headers[J + 1];
      SetLength(ARequest.Headers, Length(ARequest.Headers) - 1);
    end
    else
      Inc(I);
end;

procedure AwsSigV4Sign(var ARequest: TPcHttpRequest; const ACredentials: TAwsCredentials;
  const ARegion, AService: string; const AUtc: TDateTime);
var
  LStamp, LDate, LScope, LToSign, LSignature, LLines, LSigned: string;
begin
  if (ACredentials.AccessKeyId = '') or (ACredentials.SecretAccessKey = '') then
    raise EArgumentException.Create('AwsSigV4Sign: empty credentials');
  if (ARegion = '') or (AService = '') then
    raise EArgumentException.Create('AwsSigV4Sign: empty region or service');
  RemoveHeader(ARequest, 'Authorization');
  RemoveHeader(ARequest, 'X-Amz-Date');
  RemoveHeader(ARequest, 'X-Amz-Security-Token');
  LStamp := AwsSigV4Timestamp(AUtc);
  LDate := Copy(LStamp, 1, 8);
  ARequest.AddHeader('X-Amz-Date', LStamp);
  if ACredentials.SessionToken <> '' then
    ARequest.AddHeader('X-Amz-Security-Token', ACredentials.SessionToken);
  LScope := LDate + '/' + ARegion + '/' + AService + '/aws4_request';
  LToSign := ALGORITHM + LF + LStamp + LF + LScope + LF +
    HexSha256(AwsSigV4CanonicalRequest(ARequest));
  LSignature := LowerCase(PcBytesToHex(Hmac(AwsSigV4SigningKey(ACredentials.SecretAccessKey,
    LDate, ARegion, AService), LToSign)));
  CanonicalHeaders(ARequest, LLines, LSigned);
  ARequest.AddHeader('Authorization', ALGORITHM + ' Credential=' + ACredentials.AccessKeyId +
    '/' + LScope + ', SignedHeaders=' + LSigned + ', Signature=' + LSignature);
end;

end.
