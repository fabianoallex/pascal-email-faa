unit PascalEmail.SesTests;

{ Tests for the SES adapter without AWS: AWS Signature Version 4
  (PascalEmail.AwsSigV4) against AWS's own vectors, and TSesSender over
  pascal-common-faa's fake HTTP transport (the request it builds, the
  answers it maps).

  The signature vectors come from outside this code (docs/findings.md,
  findings 9-11): the signing key of AWS's documentation example
  (20120215/us-east-1/iam); get-vanilla and the query-order case of AWS's
  SigV4 test suite; a header with repeated blanks; and SES SendEmail
  requests, with and without a session token, all signed by botocore 1.44.1
  (AWS's Python signer) with the same inputs. The error names in the
  mapping tests come from the SES v2 API reference (finding 12): there was
  no account to measure them.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalEmail.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalEmail.DUnitXCompat,
  SysUtils,
  DateUtils,
  PascalCommon.Crypto,
  PascalCommon.Http,
  PascalCommon.Http.Fake,
  PascalCommon.SystemContext,
  PascalEmail.Errors,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.Interfaces,
  PascalEmail.AwsSigV4,
  PascalEmail.Ses,
  PascalEmail.TestSupport;

type
  [TestFixture]
  TSesTests = class
  private
    FFake: TPcFakeHttpTransport;
    FHttp: IPcHttpTransport;
    function ExampleCredentials: TAwsCredentials;
    function Options: TSesOptions;
    function Sender(const AOptions: TSesOptions): IEmailSender;
    function Msg: IEmailMessage;
    function SendError(AStatus: Integer; const ABody: string;
      const AHeaders: array of string): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure SigV4_SigningKey_AwsDocumentation;
    [Test] procedure SigV4_GetVanilla_AwsSuite;
    [Test] procedure SigV4_GetVanilla_CanonicalRequest;
    [Test] procedure SigV4_QueryOrder_AwsSuite;
    [Test] procedure SigV4_HeaderBlanks_Botocore;
    [Test] procedure SigV4_SesRequest_Botocore;
    [Test] procedure SigV4_SesRequestWithSessionToken_Botocore;
    [Test] procedure SigV4_ReplacesAnOldSignature;
    [Test] procedure SigV4_EmptyCredentials;
    [Test] procedure Send_Request;
    [Test] procedure Send_Body_RawMimeAndEnvelope;
    [Test] procedure Send_TagsAndMetadata_AsEmailTags;
    [Test] procedure Send_BadTag_ArgumentError_NothingSent;
    [Test] procedure Send_ConfigurationSet;
    [Test] procedure Send_SessionToken_Signed;
    [Test] procedure Send_CredentialsProvider_AskedEachTime;
    [Test] procedure Send_Endpoint;
    [Test] procedure Send_InvalidMessage_NothingSent;
    [Test] procedure Errors_Rejected;
    [Test] procedure Errors_Auth;
    [Test] procedure Errors_Transient;
    [Test] procedure Errors_NoAnswer_OutcomeUnknown;
    [Test] procedure Errors_CarryStatusAndText;
    [Test] procedure Create_RefusesBadOptions;
    [Test] procedure SendMany_OnePerMessage;
  end;

implementation

type
  TFixedClock = class(TInterfacedObject, IClock)
  private
    FNow: TDateTime;
  public
    constructor Create(ANow: TDateTime);
    function Now: TDateTime;
    function Date: TDateTime;
  end;

  TCountingCredentials = class(TInterfacedObject, ISesCredentialsProvider)
  public
    Calls: Integer;
    function Credentials: TAwsCredentials;
  end;

constructor TFixedClock.Create(ANow: TDateTime);
begin
  inherited Create;
  FNow := ANow;
end;

function TFixedClock.Now: TDateTime;
begin
  Result := FNow;
end;

function TFixedClock.Date: TDateTime;
begin
  Result := Trunc(FNow);
end;

function TCountingCredentials.Credentials: TAwsCredentials;
begin
  Inc(Calls);
  Result.AccessKeyId := 'ASIAROLE' + IntToStr(Calls);
  Result.SecretAccessKey := 'secret';
  Result.SessionToken := 'token' + IntToStr(Calls);
end;

const
  EXAMPLE_KEY = 'AKIDEXAMPLE';
  EXAMPLE_SECRET = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';
  SES_URL = 'https://email.sa-east-1.amazonaws.com/v2/email/outbound-emails';
  SES_BODY = '{"Content":{"Raw":{"Data":"RnJvbTogYUBleGFtcGxlLmNvbQ0KDQpoaQ0K"}},' +
    '"Destination":{"ToAddresses":["b@example.com"]}}';

function TSesTests.ExampleCredentials: TAwsCredentials;
begin
  Result.AccessKeyId := EXAMPLE_KEY;
  Result.SecretAccessKey := EXAMPLE_SECRET;
  Result.SessionToken := '';
end;

procedure TSesTests.Setup;
begin
  FFake := TPcFakeHttpTransport.Create;
  FHttp := FFake;
  // The clock is local time; EmailUtcNow converts it. These tests only need
  // it fixed.
  TClock.SetClock(TFixedClock.Create(EncodeDateTime(2026, 11, 12, 14, 5, 9, 0)));
end;

procedure TSesTests.TearDown;
begin
  TClock.Reset;
  FHttp := nil;
  FFake := nil;
end;

function TSesTests.Options: TSesOptions;
begin
  Result := TSesOptions.Create('sa-east-1', EXAMPLE_KEY, EXAMPLE_SECRET);
end;

function TSesTests.Sender(const AOptions: TSesOptions): IEmailSender;
var
  LIds: IEmailIdSource;
begin
  LIds := TCountingIdSource.Create;
  Result := TSesSender.Create(AOptions, FHttp, LIds);
end;

function TSesTests.Msg: IEmailMessage;
begin
  Result := TEmailMessage.New.SetFrom('app@example.com', 'App').AddTo('bob@example.com')
    .AddCc('carl@example.com').AddBcc('audit@example.com').SetSubject('Olá')
    .SetText('corpo').SetDate(EncodeDateTime(2026, 11, 12, 14, 5, 9, 0));
end;

function TSesTests.SendError(AStatus: Integer; const ABody: string;
  const AHeaders: array of string): string;
begin
  Result := '';
  FFake.Answer(AStatus, ABody, AHeaders);
  try
    Sender(Options).Send(Msg);
  except
    on E: Exception do
      Result := E.ClassName;
  end;
end;

{ Signature Version 4 }

procedure TSesTests.SigV4_SigningKey_AwsDocumentation;
begin
  TAssert.AssertEquals('f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d',
    LowerCase(PcBytesToHex(AwsSigV4SigningKey(EXAMPLE_SECRET, '20120215', 'us-east-1', 'iam'))));
end;

procedure TSesTests.SigV4_GetVanilla_AwsSuite;
var
  R: TPcHttpRequest;
begin
  R := TPcHttpRequest.Create('GET', 'https://example.amazonaws.com/');
  AwsSigV4Sign(R, ExampleCredentials, 'us-east-1', 'service', EncodeDateTime(2015, 8, 30, 12, 36, 0, 0));
  TAssert.AssertEquals('20150830T123600Z', R.Header('X-Amz-Date'));
  TAssert.AssertEquals('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/' +
    'aws4_request, SignedHeaders=host;x-amz-date, ' +
    'Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
    R.Header('Authorization'));
end;

procedure TSesTests.SigV4_GetVanilla_CanonicalRequest;
var
  R: TPcHttpRequest;
begin
  R := TPcHttpRequest.Create('GET', 'https://example.amazonaws.com/');
  R.AddHeader('X-Amz-Date', '20150830T123600Z');
  TAssert.AssertEquals('GET'#10'/'#10#10'host:example.amazonaws.com'#10 +
    'x-amz-date:20150830T123600Z'#10#10'host;x-amz-date'#10 +
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    AwsSigV4CanonicalRequest(R));
end;

procedure TSesTests.SigV4_QueryOrder_AwsSuite;
var
  R: TPcHttpRequest;
begin
  R := TPcHttpRequest.Create('GET', 'https://example.amazonaws.com/?Param2=value2&Param1=value1');
  AwsSigV4Sign(R, ExampleCredentials, 'us-east-1', 'service', EncodeDateTime(2015, 8, 30, 12, 36, 0, 0));
  TAssert.AssertTrue(Pos('Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500',
    R.Header('Authorization')) > 0);
end;

procedure TSesTests.SigV4_HeaderBlanks_Botocore;
var
  R: TPcHttpRequest;
begin
  R := TPcHttpRequest.Create('GET', 'https://example.amazonaws.com/');
  R.AddHeader('My-Header1', '  value1   with   spaces  ');
  AwsSigV4Sign(R, ExampleCredentials, 'us-east-1', 'service', EncodeDateTime(2015, 8, 30, 12, 36, 0, 0));
  TAssert.AssertTrue(Pos('SignedHeaders=host;my-header1;x-amz-date, Signature=' +
    '1d3c8dacf13d565cb88f90460a561e5caf0231c1f593a60fc93953ac77d13c58',
    R.Header('Authorization')) > 0);
end;

procedure TSesTests.SigV4_SesRequest_Botocore;
var
  R: TPcHttpRequest;
begin
  R := TPcHttpRequest.Create('POST', SES_URL);
  R.AddHeader('Content-Type', 'application/json');
  R.Body := SES_BODY;
  AwsSigV4Sign(R, ExampleCredentials, 'sa-east-1', 'ses', EncodeDateTime(2026, 11, 12, 14, 5, 9, 0));
  TAssert.AssertEquals('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261112/sa-east-1/ses/' +
    'aws4_request, SignedHeaders=content-type;host;x-amz-date, ' +
    'Signature=75819559fd2ebbcf98e6ad02324e35a0d00ad469876931facc096d6200585804',
    R.Header('Authorization'));
end;

procedure TSesTests.SigV4_SesRequestWithSessionToken_Botocore;
var
  R: TPcHttpRequest;
  C: TAwsCredentials;
begin
  C := ExampleCredentials;
  C.SessionToken := 'SESSIONTOKEN/EXAMPLE+==';
  R := TPcHttpRequest.Create('POST', SES_URL);
  R.AddHeader('Content-Type', 'application/json');
  R.Body := SES_BODY;
  AwsSigV4Sign(R, C, 'sa-east-1', 'ses', EncodeDateTime(2026, 11, 12, 14, 5, 9, 0));
  TAssert.AssertEquals('SESSIONTOKEN/EXAMPLE+==', R.Header('X-Amz-Security-Token'));
  TAssert.AssertTrue(Pos('SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, ' +
    'Signature=edfb2bbb76904bd4d018f9add37d0cef01f1dfe9522bf6483c246be956a8b326',
    R.Header('Authorization')) > 0);
end;

procedure TSesTests.SigV4_ReplacesAnOldSignature;
var
  R: TPcHttpRequest;
  I, LCount: Integer;
begin
  R := TPcHttpRequest.Create('GET', 'https://example.amazonaws.com/');
  AwsSigV4Sign(R, ExampleCredentials, 'us-east-1', 'service', EncodeDateTime(2015, 1, 1, 0, 0, 0, 0));
  AwsSigV4Sign(R, ExampleCredentials, 'us-east-1', 'service', EncodeDateTime(2015, 8, 30, 12, 36, 0, 0));
  LCount := 0;
  for I := 0 to High(R.Headers) do
    if SameText(R.Headers[I].Name, 'Authorization') then
      Inc(LCount);
  TAssert.AssertEquals(1, LCount);
  TAssert.AssertTrue(Pos('Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
    R.Header('Authorization')) > 0);
end;

procedure TSesTests.SigV4_EmptyCredentials;
var
  R: TPcHttpRequest;
  C: TAwsCredentials;
begin
  C := ExampleCredentials;
  C.SecretAccessKey := '';
  R := TPcHttpRequest.Create('GET', 'https://example.amazonaws.com/');
  try
    AwsSigV4Sign(R, C, 'us-east-1', 'service', Now);
    TAssert.Fail('signed with no secret');
  except
    on E: EArgumentException do
      ;
  end;
end;

{ The sender }

procedure TSesTests.Send_Request;
var
  R: TEmailSendResult;
  Q, LCheck: TPcHttpRequest;
  I: Integer;
begin
  FFake.Answer(200, '{"MessageId":"010001934b2c6d7e-abc-000000"}');
  R := Sender(Options).Send(Msg);
  TAssert.AssertEquals('010001934b2c6d7e-abc-000000', R.ProviderId);
  TAssert.AssertEquals('id1@example.com', R.MessageId);
  Q := FFake.Request(0);
  TAssert.AssertEquals('POST', Q.Method);
  TAssert.AssertEquals(SES_URL, Q.Url);
  TAssert.AssertEquals('application/json', Q.Header('Content-Type'));
  TAssert.AssertTrue('a date (the clock''s, in UTC)', Length(Q.Header('X-Amz-Date')) = 16);
  TAssert.AssertTrue(Pos('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/', Q.Header('Authorization')) = 1);
  TAssert.AssertTrue(Pos('/sa-east-1/ses/aws4_request, SignedHeaders=content-type;host;x-amz-date, ' +
    'Signature=', Q.Header('Authorization')) > 0);
  // Signing the same request again at the same time gives the same signature.
  LCheck := TPcHttpRequest.Create('POST', Q.Url);
  LCheck.AddHeader('Content-Type', 'application/json');
  LCheck.Body := Q.Body;
  I := 0;
  AwsSigV4Sign(LCheck, ExampleCredentials, 'sa-east-1', 'ses', EncodeDateTime(
    StrToInt(Copy(Q.Header('X-Amz-Date'), 1, 4)), StrToInt(Copy(Q.Header('X-Amz-Date'), 5, 2)),
    StrToInt(Copy(Q.Header('X-Amz-Date'), 7, 2)), StrToInt(Copy(Q.Header('X-Amz-Date'), 10, 2)),
    StrToInt(Copy(Q.Header('X-Amz-Date'), 12, 2)), StrToInt(Copy(Q.Header('X-Amz-Date'), 14, 2)), I));
  TAssert.AssertEquals(LCheck.Header('Authorization'), Q.Header('Authorization'));
end;

procedure TSesTests.Send_Body_RawMimeAndEnvelope;
var
  LMime: TEmailMime;
begin
  FFake.Answer(200, '{"MessageId":"m"}');
  Sender(Options).Send(Msg);
  LMime := EmailBuildMime(Msg, TCountingIdSource.Create);
  TAssert.AssertEquals('{"Content":{"Raw":{"Data":"' + PcBase64Encode(LMime.Data) + '"}},' +
    '"Destination":{"ToAddresses":["bob@example.com"],"CcAddresses":["carl@example.com"],' +
    '"BccAddresses":["audit@example.com"]}}', FFake.Request(0).Body);
  TAssert.AssertEquals('the MIME has no Bcc', 0, Pos('audit@', LMime.AsText));
end;

procedure TSesTests.Send_TagsAndMetadata_AsEmailTags;
begin
  FFake.Answer(200, '{"MessageId":"m"}');
  Sender(Options).Send(Msg.AddTag('welcome').SetMetadata('campaign', 'nov-2026'));
  TAssert.AssertTrue(Pos(',"EmailTags":[{"Name":"welcome","Value":"true"},' +
    '{"Name":"campaign","Value":"nov-2026"}]}', FFake.Request(0).Body) > 0);
end;

procedure TSesTests.Send_BadTag_ArgumentError_NothingSent;
begin
  try
    Sender(Options).Send(Msg.SetMetadata('user', 'ana@example.com'));
    TAssert.Fail('a tag value SES refuses was sent');
  except
    on E: EEmailArgumentError do
      ;
  end;
  TAssert.AssertEquals(0, FFake.RequestCount);
end;

procedure TSesTests.Send_ConfigurationSet;
var
  O: TSesOptions;
begin
  O := Options;
  O.ConfigurationSetName := 'transactional';
  FFake.Answer(200, '{"MessageId":"m"}');
  Sender(O).Send(Msg);
  TAssert.AssertTrue(Pos(',"ConfigurationSetName":"transactional"}', FFake.Request(0).Body) > 0);
end;

procedure TSesTests.Send_SessionToken_Signed;
var
  O: TSesOptions;
begin
  O := Options;
  O.SessionToken := 'FwoGZXIvYXdzEJr//token';
  FFake.Answer(200, '{"MessageId":"m"}');
  Sender(O).Send(Msg);
  TAssert.AssertEquals('FwoGZXIvYXdzEJr//token', FFake.Request(0).Header('X-Amz-Security-Token'));
  TAssert.AssertTrue(Pos('x-amz-security-token, Signature=', FFake.Request(0).Header('Authorization')) > 0);
end;

procedure TSesTests.Send_CredentialsProvider_AskedEachTime;
var
  O: TSesOptions;
  P: TCountingCredentials;
  S: IEmailSender;
begin
  P := TCountingCredentials.Create;
  O := TSesOptions.Create('us-east-1', '', '');
  O.CredentialsProvider := P;
  FFake.Answer(200, '{"MessageId":"a"}');
  FFake.Answer(200, '{"MessageId":"b"}');
  S := Sender(O);
  S.Send(Msg);
  S.Send(Msg);
  TAssert.AssertEquals(2, P.Calls);
  TAssert.AssertTrue(Pos('Credential=ASIAROLE2/', FFake.Request(1).Header('Authorization')) > 0);
  TAssert.AssertEquals('token2', FFake.Request(1).Header('X-Amz-Security-Token'));
end;

procedure TSesTests.Send_Endpoint;
var
  O: TSesOptions;
begin
  O := Options;
  O.Endpoint := 'http://localhost:4566/';
  FFake.Answer(200, '{"MessageId":"m"}');
  Sender(O).Send(Msg);
  TAssert.AssertEquals('http://localhost:4566/v2/email/outbound-emails', FFake.Request(0).Url);
end;

procedure TSesTests.Send_InvalidMessage_NothingSent;
begin
  try
    Sender(Options).Send(TEmailMessage.New.AddTo('a@example.com'));
    TAssert.Fail('a message without From was sent');
  except
    on E: EEmailArgumentError do
      ;
  end;
  TAssert.AssertEquals(0, FFake.RequestCount);
end;

procedure TSesTests.Errors_Rejected;
begin
  TAssert.AssertEquals('MessageRejected', 'EEmailRejected', SendError(400,
    '{"message":"Email address is not verified."}',
    ['x-amzn-ErrorType: MessageRejected:http://internal.amazon.com/coral/com.amazon.ses/']));
  TAssert.AssertEquals('BadRequest', 'EEmailRejected', SendError(400, '{"message":"bad"}',
    ['x-amzn-ErrorType: BadRequestException']));
  TAssert.AssertEquals('type in the body', 'EEmailRejected', SendError(400,
    '{"__type":"com.amazonaws.sesv2#MessageRejected","message":"x"}', []));
  TAssert.AssertEquals('413', 'EEmailRejected', SendError(413, '', []));
end;

procedure TSesTests.Errors_Auth;
begin
  TAssert.AssertEquals('403', 'EEmailAuthError', SendError(403,
    '{"message":"The request signature we calculated does not match"}',
    ['x-amzn-ErrorType: InvalidSignatureException']));
  TAssert.AssertEquals('401', 'EEmailAuthError', SendError(401, '', []));
  TAssert.AssertEquals('configuration set', 'EEmailAuthError', SendError(404, '{}',
    ['x-amzn-ErrorType: NotFoundException']));
  TAssert.AssertEquals('domain', 'EEmailAuthError', SendError(400, '{}',
    ['x-amzn-ErrorType: MailFromDomainNotVerifiedException']));
  TAssert.AssertEquals('suspended', 'EEmailAuthError', SendError(400, '{}',
    ['x-amzn-ErrorType: AccountSuspendedException']));
  TAssert.AssertEquals('paused', 'EEmailAuthError', SendError(400, '{}',
    ['x-amzn-ErrorType: SendingPausedException']));
end;

procedure TSesTests.Errors_Transient;
begin
  TAssert.AssertEquals('429', 'EEmailTransient', SendError(429, '{}',
    ['x-amzn-ErrorType: TooManyRequestsException']));
  TAssert.AssertEquals('quota', 'EEmailTransient', SendError(400, '{}',
    ['x-amzn-ErrorType: LimitExceededException']));
  TAssert.AssertEquals('500', 'EEmailTransient', SendError(500, 'oops', []));
  TAssert.AssertEquals('503', 'EEmailTransient', SendError(503, '', []));
end;

procedure TSesTests.Errors_NoAnswer_OutcomeUnknown;
begin
  FFake.Fail('connection reset');
  try
    Sender(Options).Send(Msg);
    TAssert.Fail('no answer taken as sent');
  except
    on E: EEmailOutcomeUnknown do
      TAssert.AssertTrue(Pos('connection reset', E.Message) > 0);
  end;
end;

procedure TSesTests.Errors_CarryStatusAndText;
begin
  FFake.Answer(400, '{"message":"Email address is not verified. The following identities ' +
    'failed the check in region SA-EAST-1: app@example.com"}',
    ['x-amzn-ErrorType: MessageRejected:http://internal.amazon.com/coral/com.amazon.ses/']);
  try
    Sender(Options).Send(Msg);
    TAssert.Fail('a refusal taken as sent');
  except
    on E: EEmailRejected do
    begin
      TAssert.AssertEquals(400, E.Code);
      TAssert.AssertTrue(Pos('MessageRejected: Email address is not verified', E.Message) > 0);
      TAssert.AssertTrue(Pos('"message"', E.EngineText) > 0);
    end;
  end;
end;

procedure TSesTests.Create_RefusesBadOptions;
var
  O: TSesOptions;
  LErrors: Integer;

  procedure Try1(const AOptions: TSesOptions);
  begin
    try
      Sender(AOptions);
    except
      on E: EEmailArgumentError do
        Inc(LErrors);
    end;
  end;

begin
  LErrors := 0;
  Try1(TSesOptions.Create('', EXAMPLE_KEY, EXAMPLE_SECRET));
  Try1(TSesOptions.Create('sa-east-1/../x', EXAMPLE_KEY, EXAMPLE_SECRET));
  Try1(TSesOptions.Create('sa-east-1', '', ''));
  O := Options;
  O.ConfigurationSetName := 'has space';
  Try1(O);
  TAssert.AssertEquals(4, LErrors);
end;

procedure TSesTests.SendMany_OnePerMessage;
var
  O: TEmailSendOutcomes;
begin
  FFake.Answer(200, '{"MessageId":"a"}');
  FFake.Answer(400, '{}', ['x-amzn-ErrorType: MessageRejected']);
  O := Sender(Options).SendMany([Msg, Msg, TEmailMessage.New.AddTo('x@example.com')]);
  TAssert.AssertTrue(O[0].Sent);
  TAssert.AssertEquals('a', O[0].SendResult.ProviderId);
  TAssert.AssertFalse(O[1].Sent);
  TAssert.AssertTrue(O[1].ErrorClass = EEmailRejected);
  TAssert.AssertFalse(O[2].Sent);
  TAssert.AssertTrue(O[2].ErrorClass = EEmailArgumentError);
  TAssert.AssertEquals(2, FFake.RequestCount);
end;

initialization
  TDUnitX.RegisterTestFixture(TSesTests);

end.
