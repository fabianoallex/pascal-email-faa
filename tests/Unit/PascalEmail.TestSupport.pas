unit PascalEmail.TestSupport;

{ What the unit tests share: a counting IEmailIdSource (boundaries "=_b1",
  "=_b2"..., Message-IDs "id1@<domain>"...), so the MIME writer's output can
  be compared byte for byte, and a scripted SMTP server: TFakeSmtpServer is
  an ISmtpConnector whose endpoints answer with the replies queued in it, in
  order, and record everything the client writes. Its "STARTTLS" just
  returns the same endpoint, so the conversation around it is tested here
  and the TLS itself in the integration suite (Mailpit).

  For the telemetry tests: TCapturingSpanExporter keeps what
  TPcTracing.FlushNow hands it (tracing started with AAutoFlush = False),
  SpanAttribute reads one attribute, and MetricPointCount reads a series of
  PcMetrics (a counter's value or a histogram's count), so a test compares
  before and after.

  Not a test unit: the mirror generator leaves it alone, and both runners
  use this same file. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  PascalCommon.Transport,
  PascalCommon.Tracing,
  PascalEmail.Mime,
  PascalEmail.Smtp;

type
  TCountingIdSource = class(TInterfacedObject, IEmailIdSource)
  private
    FBoundaries: Integer;
    FIds: Integer;
  public
    function NewBoundary: string;
    function NewMessageId(const ADomain: string): string;
  end;

  TFakeSmtpServer = class(TInterfacedObject, ISmtpConnector)
  private
    FReplies: TArray<string>;
    FNext: Integer;
    FTranscript: string;
    FConnects: Integer;
    FTlsConnects: Integer;
    FStartTlsCount: Integer;
    FRefuseConnect: Boolean;
    FFailWritesFrom: Integer;
    FWrites: Integer;
    FLastHost: string;
    FLastPort: Word;
  public
    constructor Create;
    /// Queues one reply; lines separated by '|' ('250-a|250 b'), CRLF added.
    procedure Reply(const AText: string);
    /// Queues a dropped connection: the read that reaches it raises
    /// EPcTransportClosed.
    procedure Drop;
    /// The client's writes from the AWrite-th on (1-based) raise
    /// EPcTransportClosed.
    procedure FailWritesFrom(AWrite: Integer);
    /// Every connect raises EPcTransportRefused.
    procedure RefuseConnect;
    /// Replies not read yet.
    function Pending: Integer;
    /// Everything the client wrote, CRLF line endings kept.
    function Transcript: string;
    /// The client's lines, without the message itself (between DATA's 354
    /// and the final '.'), joined by '|'.
    function Commands: string;
    property Connects: Integer read FConnects;
    property TlsConnects: Integer read FTlsConnects;
    property StartTlsCount: Integer read FStartTlsCount;
    property LastHost: string read FLastHost;
    property LastPort: Word read FLastPort;
    function NextRead(out AText: string): Boolean;
    procedure Written(const AText: string);
    function Connect(const AHost: string; APort: Word; const ATcp: TPcTcpOptions): TPcEndpoint;
    function ConnectTls(const AHost: string; APort: Word; const ATcp: TPcTcpOptions;
      const ATls: TPcTlsOptions): TPcEndpoint;
    function StartTls(AInner: TPcEndpoint; const AHost: string;
      const ATls: TPcTlsOptions): TPcEndpoint;
  end;

  TFakeSmtpEndpoint = class(TPcEndpoint)
  private
    FServer: TFakeSmtpServer;
    FPending: TBytes;
    FClosed: Boolean;
  public
    constructor Create(AServer: TFakeSmtpServer);
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
    procedure SetIoDeadline(ATimeoutMs: Cardinal); override;
  end;

  TFixedTokenProvider = class(TInterfacedObject, IEmailTokenProvider)
  private
    FToken: string;
    FCalls: Integer;
  public
    constructor Create(const AToken: string);
    function AccessToken: string;
    property Calls: Integer read FCalls;
  end;

  TCapturingSpanExporter = class(TInterfacedObject, IPcSpanExporter)
  public
    Spans: TPcSpanDataArray;
    function ExportSpans(const ASpans: TPcSpanDataArray; out AError: string): Boolean;
    /// The spans exported so far named AName, in order.
    function Named(const AName: string): TPcSpanDataArray;
  end;

/// The attribute AKey of AData as text, and whether it is there.
function SpanAttribute(const AData: TPcSpanData; const AKey: string; out AValue: string): Boolean;
/// The point of metric AName on PcMetrics with exactly these label values:
/// a histogram's count, a counter's value; 0 when it doesn't exist yet.
function MetricPointCount(const AName: string; const ALabels: array of string): Double;

/// AText ACount times. StringOfChar takes one Char, and on FPC an accented
/// letter is a two-byte string.
function RepeatText(const AText: string; ACount: Integer): string;
/// 'n' bytes 0, 1, 2 ... (mod 256).
function SampleBytes(ACount: Integer): TBytes;
/// A file's bytes as an ASCII string (the MIME writer's output is ASCII).
function ReadFileText(const APath: string): string;
/// A fresh empty folder under the system's temporary folder.
function NewTempDir(const APrefix: string): string;
procedure RemoveTempDir(const APath: string);
/// The number of lines in AText longer than ALimit characters (CRLF not
/// counted).
function LinesLongerThan(const AText: string; ALimit: Integer): Integer;

implementation

uses
  Classes,
  PascalCommon.Metrics,
  PascalCommon.Crypto,
  PascalCommon.Random
  {$IFNDEF FPC}
  , System.IOUtils
  {$ENDIF};

// The system's temporary folder: FPC's SysUtils has GetTempDir, Delphi's
// doesn't (TPath.GetTempPath, System.IOUtils; gotcha 4).
function TempFolder: string;
begin
  {$IFDEF FPC}
  Result := GetTempDir;
  {$ELSE}
  Result := TPath.GetTempPath;
  {$ENDIF}
end;

const
  CRLF = #13#10;
  DROP_MARK = #0'drop';

{ TCapturingSpanExporter }

function TCapturingSpanExporter.ExportSpans(const ASpans: TPcSpanDataArray;
  out AError: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(ASpans) do
  begin
    SetLength(Spans, Length(Spans) + 1);
    Spans[High(Spans)] := ASpans[I];
  end;
  AError := '';
  Result := True;
end;

function TCapturingSpanExporter.Named(const AName: string): TPcSpanDataArray;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(Spans) do
    if Spans[I].Name = AName then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Spans[I];
    end;
end;

function SpanAttribute(const AData: TPcSpanData; const AKey: string; out AValue: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AData.Attributes) do
    if AData.Attributes[I].Key = AKey then
    begin
      case AData.Attributes[I].ValueType of
        satInt: AValue := IntToStr(AData.Attributes[I].IntValue);
        satBool: AValue := BoolToStr(AData.Attributes[I].BoolValue, True);
      else
        AValue := AData.Attributes[I].StringValue;
      end;
      Exit(True);
    end;
  AValue := '';
  Result := False;
end;

function MetricPointCount(const AName: string; const ALabels: array of string): Double;
var
  LMetrics: TPcMetricList;
  LPoints: TPcMetricPoints;
  I, J, M: Integer;
  LSame: Boolean;
begin
  Result := 0;
  LMetrics := PcMetrics.Metrics;
  for M := 0 to High(LMetrics) do
    if LMetrics[M].Name = AName then
    begin
      LPoints := LMetrics[M].Snapshot;
      for I := 0 to High(LPoints) do
      begin
        LSame := Length(LPoints[I].LabelValues) = Length(ALabels);
        J := 0;
        while LSame and (J <= High(ALabels)) do
        begin
          LSame := LPoints[I].LabelValues[J] = ALabels[J];
          Inc(J);
        end;
        if LSame then
        begin
          if LMetrics[M].Kind = mkHistogram then
            Result := LPoints[I].Count
          else
            Result := LPoints[I].Value;
          Exit;
        end;
      end;
    end;
end;

{ TCountingIdSource }

function TCountingIdSource.NewBoundary: string;
begin
  Inc(FBoundaries);
  Result := '=_b' + IntToStr(FBoundaries);
end;

function TCountingIdSource.NewMessageId(const ADomain: string): string;
begin
  Inc(FIds);
  Result := 'id' + IntToStr(FIds) + '@' + ADomain;
end;

{ TFakeSmtpServer }

constructor TFakeSmtpServer.Create;
begin
  inherited Create;
  FFailWritesFrom := MaxInt;
end;

procedure TFakeSmtpServer.Reply(const AText: string);
begin
  SetLength(FReplies, Length(FReplies) + 1);
  FReplies[High(FReplies)] := StringReplace(AText, '|', CRLF, [rfReplaceAll]) + CRLF;
end;

procedure TFakeSmtpServer.Drop;
begin
  SetLength(FReplies, Length(FReplies) + 1);
  FReplies[High(FReplies)] := DROP_MARK;
end;

procedure TFakeSmtpServer.FailWritesFrom(AWrite: Integer);
begin
  FFailWritesFrom := AWrite;
end;

procedure TFakeSmtpServer.RefuseConnect;
begin
  FRefuseConnect := True;
end;

function TFakeSmtpServer.Pending: Integer;
begin
  Result := Length(FReplies) - FNext;
end;

function TFakeSmtpServer.Transcript: string;
begin
  Result := FTranscript;
end;

function TFakeSmtpServer.Commands: string;
var
  LLines: TStringList;
  I: Integer;
  LInData: Boolean;
begin
  Result := '';
  LLines := TStringList.Create;
  try
    LLines.Text := FTranscript;
    LInData := False;
    for I := 0 to LLines.Count - 1 do
    begin
      if LInData then
      begin
        if LLines[I] = '.' then
          LInData := False;
        Continue;
      end;
      if Result <> '' then
        Result := Result + '|';
      Result := Result + LLines[I];
      if LLines[I] = 'DATA' then
        LInData := True;
    end;
  finally
    LLines.Free;
  end;
end;

function TFakeSmtpServer.NextRead(out AText: string): Boolean;
begin
  if FNext > High(FReplies) then
    raise EPcTransportClosed.Create('fake SMTP server: no more replies scripted');
  AText := FReplies[FNext];
  Inc(FNext);
  Result := AText <> DROP_MARK;
end;

procedure TFakeSmtpServer.Written(const AText: string);
begin
  Inc(FWrites);
  if FWrites >= FFailWritesFrom then
    raise EPcTransportClosed.Create('fake SMTP server: connection lost while writing');
  FTranscript := FTranscript + AText;
end;

function TFakeSmtpServer.Connect(const AHost: string; APort: Word;
  const ATcp: TPcTcpOptions): TPcEndpoint;
begin
  FLastHost := AHost;
  FLastPort := APort;
  if FRefuseConnect then
    raise EPcTransportRefused.Create('fake SMTP server: connection refused');
  Inc(FConnects);
  Result := TFakeSmtpEndpoint.Create(Self);
end;

function TFakeSmtpServer.ConnectTls(const AHost: string; APort: Word;
  const ATcp: TPcTcpOptions; const ATls: TPcTlsOptions): TPcEndpoint;
begin
  Inc(FTlsConnects);
  Result := Connect(AHost, APort, ATcp);
end;

function TFakeSmtpServer.StartTls(AInner: TPcEndpoint; const AHost: string;
  const ATls: TPcTlsOptions): TPcEndpoint;
begin
  Inc(FStartTlsCount);
  Result := AInner;
end;

{ TFakeSmtpEndpoint }

constructor TFakeSmtpEndpoint.Create(AServer: TFakeSmtpServer);
begin
  inherited Create;
  FServer := AServer;
end;

function TFakeSmtpEndpoint.Read(var ABuffer; ACount: Integer): Integer;
var
  LText: string;
  I: Integer;
  LOut: PByte;
begin
  if FClosed then
    raise EPcTransportClosed.Create('fake endpoint closed');
  if Length(FPending) = 0 then
  begin
    if not FServer.NextRead(LText) then
    begin
      FClosed := True;
      raise EPcTransportClosed.Create('fake SMTP server: connection dropped');
    end;
    SetLength(FPending, Length(LText));
    for I := 1 to Length(LText) do
      FPending[I - 1] := Byte(Ord(LText[I]));
  end;
  Result := Length(FPending);
  if Result > ACount then
    Result := ACount;
  LOut := @ABuffer;
  for I := 0 to Result - 1 do
    LOut[I] := FPending[I];
  FPending := Copy(FPending, Result, MaxInt);
end;

procedure TFakeSmtpEndpoint.WriteExactly(const ABuffer; ACount: Integer);
var
  LText: string;
  I: Integer;
  LIn: PByte;
begin
  if FClosed then
    raise EPcTransportClosed.Create('fake endpoint closed');
  LIn := @ABuffer;
  SetLength(LText, ACount);
  for I := 0 to ACount - 1 do
    LText[I + 1] := Char(LIn[I]);
  FServer.Written(LText);
end;

procedure TFakeSmtpEndpoint.CloseAbort;
begin
  FClosed := True;
end;

procedure TFakeSmtpEndpoint.SetIoDeadline(ATimeoutMs: Cardinal);
begin
end;

{ TFixedTokenProvider }

constructor TFixedTokenProvider.Create(const AToken: string);
begin
  inherited Create;
  FToken := AToken;
end;

function TFixedTokenProvider.AccessToken: string;
begin
  Inc(FCalls);
  Result := FToken;
end;

{ Helpers }

function RepeatText(const AText: string; ACount: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ACount do
    Result := Result + AText;
end;

function SampleBytes(ACount: Integer): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte(I and $FF);
end;

function ReadFileText(const APath: string): string;
var
  LStream: TFileStream;
  LBytes: TBytes;
  I: Integer;
begin
  LBytes := nil;
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(LBytes, LStream.Size);
    if Length(LBytes) > 0 then
      LStream.ReadBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
  SetLength(Result, Length(LBytes));
  for I := 0 to High(LBytes) do
    Result[I + 1] := Char(LBytes[I]);
end;

var
  GTempCounter: Integer = 0;

function NewTempDir(const APrefix: string): string;
begin
  repeat
    Inc(GTempCounter);
    Result := IncludeTrailingPathDelimiter(TempFolder) + APrefix + '-' +
      PcBytesToHex(PcRandomBytes(4)) + '-' + IntToStr(GTempCounter);
  until not DirectoryExists(Result);
  ForceDirectories(Result);
end;

procedure RemoveTempDir(const APath: string);
var
  LInfo: TSearchRec;
  LDir: string;
begin
  LDir := IncludeTrailingPathDelimiter(APath);
  if FindFirst(LDir + '*', faAnyFile, LInfo) = 0 then
  try
    repeat
      if (LInfo.Name <> '.') and (LInfo.Name <> '..') then
        DeleteFile(LDir + LInfo.Name);
    until FindNext(LInfo) <> 0;
  finally
    FindClose(LInfo);
  end;
  SysUtils.RemoveDir(APath);
end;

function LinesLongerThan(const AText: string; ALimit: Integer): Integer;
var
  LLines: TStringList;
  I: Integer;
begin
  Result := 0;
  LLines := TStringList.Create;
  try
    LLines.Text := AText;
    for I := 0 to LLines.Count - 1 do
      if Length(LLines[I]) > ALimit then
        Inc(Result);
  finally
    LLines.Free;
  end;
end;

end.
