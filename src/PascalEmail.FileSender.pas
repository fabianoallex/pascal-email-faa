unit PascalEmail.FileSender;

{$I pascalemail.inc}

{ A sender that writes each message as an .eml file into a folder (design,
  E10): for development (open the file in a mail client to see what would
  have been sent), and as the pickup directory of a relay that watches a
  folder (IIS SMTP, some MTAs).

  The file is written under a temporary name and then renamed, so a relay
  watching the folder never picks up half a message. The name is the
  Message-ID with every character other than letters, digits, '.', '-' and
  '_' turned into '_' (unique: the generated ids are random); ProviderId is
  the full path. A failure to write is EEmailTransient (a full disk or a
  missing share can come back).

  Each send is recorded (PascalEmail.Telemetry: an 'email send' client
  span, sender 'file', and the metrics); provider_id on the span is the
  file's path. }

interface

uses
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Message,
  PascalCommon.Tracing,
  PascalEmail.Mime,
  PascalEmail.Interfaces,
  PascalEmail.Telemetry;

type
  TFileEmailSender = class(TEmailSenderBase)
  private
    FDirectory: string;
    FIds: IEmailIdSource;
    function WriteMessage(const AMessage: IEmailMessage;
      var ARec: TEmailSendTelemetry): TEmailSendResult;
  public
    /// ADirectory is created when missing. AIds nil = random ids.
    constructor Create(const ADirectory: string; const AIds: IEmailIdSource = nil);
    function Name: string; override;
    function Send(const AMessage: IEmailMessage): TEmailSendResult; override;
    property Directory: string read FDirectory;
  end;

implementation

uses
  Classes;

function SafeFileName(const AMessageId: string): string;
var
  I: Integer;
begin
  Result := AMessageId;
  for I := 1 to Length(Result) do
    if not CharInSet(Result[I], ['A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_']) then
      Result[I] := '_';
end;

constructor TFileEmailSender.Create(const ADirectory: string; const AIds: IEmailIdSource);
begin
  inherited Create;
  FIds := AIds; // before anything can raise (gotcha 1)
  if ADirectory = '' then
    raise EEmailArgumentError.Create('TFileEmailSender: the directory is empty');
  FDirectory := IncludeTrailingPathDelimiter(ExpandFileName(ADirectory));
end;

function TFileEmailSender.Name: string;
begin
  Result := 'file';
end;

function TFileEmailSender.Send(const AMessage: IEmailMessage): TEmailSendResult;
var
  LRec: TEmailSendTelemetry;
begin
  LRec := TEmailSendTelemetry.Start(Name, skClient, AMessage);
  try
    Result := WriteMessage(AMessage, LRec);
    LRec.Done(Result);
  except
    on E: Exception do
    begin
      LRec.Fail(E);
      raise;
    end;
  end;
end;

function TFileEmailSender.WriteMessage(const AMessage: IEmailMessage;
  var ARec: TEmailSendTelemetry): TEmailSendResult;
var
  LMime: TEmailMime;
  LPath, LTemp: string;
  LStream: TFileStream;
begin
  LMime := EmailBuildMime(AMessage, FIds);
  ARec.Identify(LMime.MessageId);
  LPath := FDirectory + SafeFileName(LMime.MessageId) + '.eml';
  LTemp := LPath + '.tmp';
  try
    if not ForceDirectories(FDirectory) then
      raise EInOutError.CreateFmt('cannot create %s', [FDirectory]);
    LStream := TFileStream.Create(LTemp, fmCreate);
    try
      if Length(LMime.Data) > 0 then
        LStream.WriteBuffer(LMime.Data[0], Length(LMime.Data));
    finally
      LStream.Free;
    end;
    if FileExists(LPath) then
      DeleteFile(LPath);
    if not RenameFile(LTemp, LPath) then
      raise EInOutError.CreateFmt('cannot rename %s to %s', [LTemp, LPath]);
  except
    on E: Exception do
    begin
      if FileExists(LTemp) then
        DeleteFile(LTemp);
      raise EEmailTransient.CreateFmt('file sender: %s', [E.Message]);
    end;
  end;
  Result := Default(TEmailSendResult);
  Result.MessageId := LMime.MessageId;
  Result.ProviderId := LPath;
end;

end.
