unit PascalEmail.IntegrationEnv;

{ Where the integration suite finds the SMTP servers (Mailpit, three ways:
  tools/mailpit.sh) and how it reads back what they received (Mailpit's
  HTTP API, through pascal-common-faa's HTTP client). Each value comes from
  an environment variable, with a default for the containers
  tools/mailpit.sh starts on this machine, so the Delphi and FPC Windows
  runners need no setup; tools/test_integration_docker.sh sets them to the
  Docker network's names.

    EMAIL_IT_STARTTLS_HOST  localhost      STARTTLS required, AUTH
    EMAIL_IT_STARTTLS_PORT  12587
    EMAIL_IT_STARTTLS_API   http://localhost:18025
    EMAIL_IT_TLS_HOST       localhost      TLS from the first byte, AUTH
    EMAIL_IT_TLS_PORT       12465
    EMAIL_IT_TLS_API        http://localhost:18026
    EMAIL_IT_TLS_WRONG_HOST 127.0.0.1      a name the certificate doesn't hold
    EMAIL_IT_PLAIN_HOST     localhost      no TLS, no AUTH
    EMAIL_IT_PLAIN_PORT     12525
    EMAIL_IT_PLAIN_API      http://localhost:18027
    EMAIL_IT_CA_FILE        the private CA (PEM); default: the first
                            .ci/it-certs/ca.pem above the executable

  The JSON is read with Pos, on purpose: the suite needs a handful of
  fields, and a JSON library would be a dependency for the tests alone.

  Not a test unit: the mirror generator leaves it alone, and both runners
  use this file. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  PascalEmail.Smtp;

const
  IT_USER = 'it-user';
  IT_PASSWORD = 'it-pass';

function StartTlsHost: string;
function StartTlsPort: Word;
function StartTlsApi: string;
function TlsHost: string;
function TlsPort: Word;
function TlsApi: string;
function TlsWrongHost: string;
function PlainHost: string;
function PlainPort: Word;
function PlainApi: string;
function CaFile: string;

/// STARTTLS server, with AUTH and the private CA.
function StartTlsOptions: TSmtpOptions;
/// Implicit TLS server, with AUTH and the private CA.
function TlsOptions: TSmtpOptions;
/// The plain server, ssNone, no AUTH.
function PlainOptions: TSmtpOptions;

/// Deletes every message of the server behind AApi.
procedure MailpitClear(const AApi: string);
/// The message as Mailpit received it (Return-Path and Received first).
function MailpitRaw(const AApi, AId: string): string;
/// Mailpit's JSON summary of the message (decoded subject, names, text...).
function MailpitJson(const AApi, AId: string): string;
/// How many messages the server holds.
function MailpitCount(const AApi: string): Integer;
/// AJson's string field AName, JSON escapes undone ('' when missing).
function JsonField(const AJson, AName: string): string;

implementation

uses
  PascalCommon.Http,
  PascalCommon.Http.Client,
  PascalCommon.Utf8;

var
  GHttp: IPcHttpTransport;

function EnvOr(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function StartTlsHost: string;
begin
  Result := EnvOr('EMAIL_IT_STARTTLS_HOST', 'localhost');
end;

function StartTlsPort: Word;
begin
  Result := StrToInt(EnvOr('EMAIL_IT_STARTTLS_PORT', '12587'));
end;

function StartTlsApi: string;
begin
  Result := EnvOr('EMAIL_IT_STARTTLS_API', 'http://localhost:18025');
end;

function TlsHost: string;
begin
  Result := EnvOr('EMAIL_IT_TLS_HOST', 'localhost');
end;

function TlsPort: Word;
begin
  Result := StrToInt(EnvOr('EMAIL_IT_TLS_PORT', '12465'));
end;

function TlsApi: string;
begin
  Result := EnvOr('EMAIL_IT_TLS_API', 'http://localhost:18026');
end;

function TlsWrongHost: string;
begin
  Result := EnvOr('EMAIL_IT_TLS_WRONG_HOST', '127.0.0.1');
end;

function PlainHost: string;
begin
  Result := EnvOr('EMAIL_IT_PLAIN_HOST', 'localhost');
end;

function PlainPort: Word;
begin
  Result := StrToInt(EnvOr('EMAIL_IT_PLAIN_PORT', '12525'));
end;

function PlainApi: string;
begin
  Result := EnvOr('EMAIL_IT_PLAIN_API', 'http://localhost:18027');
end;

function CaFile: string;
var
  LDir, LParent: string;
begin
  Result := GetEnvironmentVariable('EMAIL_IT_CA_FILE');
  if Result <> '' then
    Exit;
  LDir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  while LDir <> '' do
  begin
    Result := IncludeTrailingPathDelimiter(LDir) + '.ci' + PathDelim + 'it-certs' + PathDelim +
      'ca.pem';
    if FileExists(Result) then
      Exit;
    LParent := ExtractFileDir(LDir);
    if LParent = LDir then
      Break;
    LDir := LParent;
  end;
  raise Exception.Create('the private CA was not found: run sh tools/mailpit.sh, or set ' +
    'EMAIL_IT_CA_FILE');
end;

function StartTlsOptions: TSmtpOptions;
begin
  Result := TSmtpOptions.Create(StartTlsHost, StartTlsPort, ssStartTls);
  Result.UserName := IT_USER;
  Result.Password := IT_PASSWORD;
  Result.Tls.CaFile := CaFile;
  Result.TimeoutMs := 15000;
end;

function TlsOptions: TSmtpOptions;
begin
  Result := TSmtpOptions.Create(TlsHost, TlsPort, ssImplicitTls);
  Result.UserName := IT_USER;
  Result.Password := IT_PASSWORD;
  Result.Tls.CaFile := CaFile;
  Result.TimeoutMs := 15000;
end;

function PlainOptions: TSmtpOptions;
begin
  Result := TSmtpOptions.Create(PlainHost, PlainPort, ssNone);
  Result.TimeoutMs := 15000;
end;

function Call(const AMethod, AUrl: string): string;
var
  LResponse: TPcHttpResponse;
begin
  LResponse := GHttp.Send(TPcHttpRequest.Create(AMethod, AUrl));
  if (LResponse.Status < 200) or (LResponse.Status > 299) then
    raise Exception.CreateFmt('Mailpit %s %s: HTTP %d %s', [AMethod, AUrl, LResponse.Status,
      Copy(LResponse.Body, 1, 200)]);
  Result := LResponse.Body;
end;

procedure MailpitClear(const AApi: string);
begin
  Call('DELETE', AApi + '/api/v1/messages');
end;

function MailpitRaw(const AApi, AId: string): string;
begin
  Result := Call('GET', AApi + '/api/v1/message/' + AId + '/raw');
end;

function MailpitJson(const AApi, AId: string): string;
begin
  Result := Call('GET', AApi + '/api/v1/message/' + AId);
end;

function MailpitCount(const AApi: string): Integer;
var
  LJson, LText: string;
  P, I: Integer;
begin
  LJson := Call('GET', AApi + '/api/v1/messages?limit=1');
  P := Pos('"messages_count":', LJson);
  if P = 0 then
    raise Exception.Create('Mailpit: no messages_count in ' + Copy(LJson, 1, 200));
  LText := '';
  I := P + Length('"messages_count":');
  while (I <= Length(LJson)) and CharInSet(LJson[I], ['0'..'9']) do
  begin
    LText := LText + LJson[I];
    Inc(I);
  end;
  Result := StrToInt(LText);
end;

function JsonField(const AJson, AName: string): string;
var
  P: Integer;
  C: Char;
  LCode: Integer;
begin
  Result := '';
  P := Pos('"' + AName + '":"', AJson);
  if P = 0 then
    Exit;
  P := P + Length(AName) + 4;
  while (P <= Length(AJson)) and (AJson[P] <> '"') do
  begin
    C := AJson[P];
    if (C = '\') and (P < Length(AJson)) then
    begin
      Inc(P);
      case AJson[P] of
        'n': Result := Result + #10;
        'r': Result := Result + #13;
        't': Result := Result + #9;
        'u':
          begin
            // Only the ASCII escapes Go writes (<, &...).
            LCode := StrToInt('$' + Copy(AJson, P + 1, 4));
            Result := Result + Char(LCode);
            Inc(P, 4);
          end;
      else
        Result := Result + AJson[P];
      end;
    end
    else
      Result := Result + C;
    Inc(P);
  end;
end;

initialization
  GHttp := PcNewHttpTransport;

finalization
  GHttp := nil;

end.
