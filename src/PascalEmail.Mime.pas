unit PascalEmail.Mime;

{$I pascalemail.inc}

{ The RFC 5322 / MIME writer: one IEmailMessage in, the bytes of the message
  out, the same on Delphi and FPC (design, E5). Every engine that takes a
  whole message (SMTP, the file sender, providers that accept raw MIME)
  sends what this unit writes.

  The output is 7-bit ASCII with CRLF line endings, so no engine needs
  8BITMIME, and every line is under SMTP's 998 characters:

  - Headers: a display name or a subject with any non-ASCII character goes
    out as RFC 2047 encoded-words in UTF-8, the whole value, Q or B,
    whichever is shorter; each word is at most 75 characters and never
    splits a UTF-8 sequence. Header lines fold at 76 columns, between
    words; the words are sized so that no line passes 76 (an ASCII word too
    long for a line makes the value go out as encoded-words, which can be
    split). An address longer than a line is the one exception.
  - Bodies (text, HTML): UTF-8, quoted-printable, any line ending turned
    into CRLF. A '.' starting a line is written =2E, so a relay that gets
    dot-stuffing wrong can't eat it.
  - Attachments: Base64 at 76 columns (PascalCommon.Crypto's
    PcBase64Encode, 1.32.0). Their names go out twice: RFC 2231
    (filename*=UTF-8''...) in Content-Disposition, and an encoded-word in
    Content-Type's name parameter, which older Outlook versions read.
  - Structure: multipart/mixed (attachments) around multipart/related
    (inline parts, only with an HTML body) around multipart/alternative
    (text and HTML); each level only when it has something to hold, so a
    text-only message is a single part.
  - Bcc never appears in the headers.
  - The Date header is UTC (+0000), from the message or TClock.

  Boundaries and generated Message-IDs come from an IEmailIdSource, random
  by default (PascalCommon.Random); a test passes a counting one and
  compares exact bytes. A boundary starts with '=_', which neither
  quoted-printable nor Base64 can produce, so it can't occur in a body. }

interface

uses
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Address,
  PascalEmail.Message;

type
  /// Where boundaries and generated Message-IDs come from.
  IEmailIdSource = interface
    ['{C4F1A9E2-7B3D-4C68-8E05-D2A6B19F4C37}']
    /// A boundary, unique within the message; must start with '=_'.
    function NewBoundary: string;
    /// A Message-ID without angle brackets, for a sender in ADomain.
    function NewMessageId(const ADomain: string): string;
  end;

  /// The written message.
  TEmailMime = record
    /// The Message-ID written (without angle brackets): the message's own,
    /// or the generated one.
    MessageId: string;
    /// The whole message: headers, a blank line, the body; CRLF line
    /// endings, ending with CRLF.
    Data: TBytes;
    /// Data as a string (it is ASCII).
    function AsText: string;
  end;

/// Random boundaries and Message-IDs (16 random bytes, hex).
function EmailRandomIdSource: IEmailIdSource;

/// Validates AMessage (EEmailArgumentError) and writes it. AIds nil = the
/// random source.
function EmailBuildMime(const AMessage: IEmailMessage;
  const AIds: IEmailIdSource = nil): TEmailMime;

/// Quoted-printable (RFC 2045 section 6.7) of UTF-8 bytes: lines of at most
/// 76 characters, CRLF line endings whatever the input had, no trailing
/// CRLF. A '.' at the start of a line is written =2E.
function EmailQuotedPrintable(const ABytes: TBytes): string;

/// A header value as RFC 2047 encoded-words (UTF-8; Q or B, the shorter),
/// separated by single spaces; the value unchanged when it is printable
/// ASCII.
function EmailEncodeHeaderText(const AText: string): string;

/// An address as a header writes it: 'ana@example.com',
/// 'Ana <ana@example.com>', '"Souza, Ana" <ana@example.com>', or the name
/// as encoded-words.
function EmailFormatAddress(const AAddress: TEmailAddress): string;

/// 'Thu, 12 Nov 2026 14:05:09 +0000' (RFC 5322 section 3.3), English names
/// whatever the locale.
function EmailFormatDate(const AUtc: TDateTime): string;

/// The current UTC time from TClock (PascalCommon.SystemContext).
function EmailUtcNow: TDateTime;

implementation

uses
  DateUtils,
  PascalCommon.Crypto,
  PascalCommon.Random,
  PascalCommon.SystemContext,
  PascalCommon.Utf8;

const
  CRLF = #13#10;
  HEX_DIGITS = '0123456789ABCDEF';
  MAX_LINE = 76;
  // '=?UTF-8?Q?' + '?=' is 12 characters; a word is at most 75.
  MAX_WORD_PAYLOAD = 63;
  WORD_OVERHEAD = 12;

type
  TRandomIdSource = class(TInterfacedObject, IEmailIdSource)
  public
    function NewBoundary: string;
    function NewMessageId(const ADomain: string): string;
  end;

  { An ASCII byte buffer that grows by doubling: attachments of several MB
    go through it. Every character added must be ASCII (the writer only
    produces ASCII); anything else is a bug here, raised as such. }
  TAsciiBuffer = class
  private
    FData: TBytes;
    FCount: Integer;
    procedure Grow(ANeeded: Integer);
  public
    procedure Add(const S: string);
    procedure AddLine(const S: string);
    function ToBytes: TBytes;
  end;

function RandomHex(ABytes: Integer): string;
begin
  Result := LowerCase(PcBytesToHex(PcRandomBytes(ABytes)));
end;

{ TRandomIdSource }

function TRandomIdSource.NewBoundary: string;
begin
  Result := '=_pe_' + RandomHex(12);
end;

function TRandomIdSource.NewMessageId(const ADomain: string): string;
begin
  Result := RandomHex(16) + '@' + ADomain;
end;

function EmailRandomIdSource: IEmailIdSource;
begin
  Result := TRandomIdSource.Create;
end;

{ TAsciiBuffer }

procedure TAsciiBuffer.Grow(ANeeded: Integer);
var
  LCap: Integer;
begin
  LCap := Length(FData);
  if LCap < 1024 then
    LCap := 1024;
  while LCap < FCount + ANeeded do
    LCap := LCap * 2;
  SetLength(FData, LCap);
end;

procedure TAsciiBuffer.Add(const S: string);
var
  I: Integer;
begin
  if FCount + Length(S) > Length(FData) then
    Grow(Length(S));
  for I := 1 to Length(S) do
  begin
    if Ord(S[I]) > 127 then
      raise EEmailError.Create('MIME writer: non-ASCII character in the output (a bug)');
    FData[FCount] := Byte(Ord(S[I]));
    Inc(FCount);
  end;
end;

procedure TAsciiBuffer.AddLine(const S: string);
begin
  Add(S);
  Add(CRLF);
end;

function TAsciiBuffer.ToBytes: TBytes;
begin
  Result := Copy(FData, 0, FCount);
end;

{ TEmailMime }

function TEmailMime.AsText: string;
var
  I: Integer;
begin
  SetLength(Result, Length(Data));
  for I := 0 to High(Data) do
    Result[I + 1] := Char(Data[I]);
end;

{ Encoding helpers }

function IsPrintableAscii(const S: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    if (S[I] < ' ') or (S[I] > '~') then
      if S[I] <> #9 then
        Exit(False);
  Result := True;
end;

function HexByte(B: Byte): string;
begin
  Result := HEX_DIGITS[(B shr 4) + 1] + HEX_DIGITS[(B and $F) + 1];
end;

// Lengths of the UTF-8 characters in ABytes (a lead byte and its
// continuation bytes stay together).
function Utf8CharLength(const ABytes: TBytes; AIndex: Integer): Integer;
begin
  Result := 1;
  while (AIndex + Result <= High(ABytes)) and ((ABytes[AIndex + Result] and $C0) = $80) do
    Inc(Result);
end;

function QChar(B: Byte): string;
begin
  if CharInSet(Char(B), ['A'..'Z', 'a'..'z', '0'..'9', '!', '*', '+', '-', '/']) then
    Result := Char(B)
  else if B = 32 then
    Result := '_'
  else
    Result := '=' + HexByte(B);
end;

function EncodeWordsQ(const ABytes: TBytes; AMaxPayload: Integer): TArray<string>;
var
  I, J, LLen: Integer;
  LCur, LChunk: string;
begin
  Result := nil;
  LCur := '';
  I := 0;
  while I <= High(ABytes) do
  begin
    LLen := Utf8CharLength(ABytes, I);
    LChunk := '';
    for J := I to I + LLen - 1 do
      LChunk := LChunk + QChar(ABytes[J]);
    if (LCur <> '') and (Length(LCur) + Length(LChunk) > AMaxPayload) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := '=?UTF-8?Q?' + LCur + '?=';
      LCur := '';
    end;
    LCur := LCur + LChunk;
    Inc(I, LLen);
  end;
  if LCur <> '' then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := '=?UTF-8?Q?' + LCur + '?=';
  end;
end;

procedure AddBWord(var AWords: TArray<string>; const ABytes: TBytes; AStart, AEnd: Integer);
begin
  if AEnd > AStart then
  begin
    SetLength(AWords, Length(AWords) + 1);
    AWords[High(AWords)] := '=?UTF-8?B?' + PcBase64Encode(Copy(ABytes, AStart, AEnd - AStart)) + '?=';
  end;
end;

function EncodeWordsB(const ABytes: TBytes; AMaxPayload: Integer): TArray<string>;
var
  I, LLen, LStart, LMaxBytes: Integer;
begin
  Result := nil;
  // Every 3 bytes are 4 Base64 characters.
  LMaxBytes := (AMaxPayload div 4) * 3;
  LStart := 0;
  I := 0;
  while I <= High(ABytes) do
  begin
    LLen := Utf8CharLength(ABytes, I);
    if I + LLen - LStart > LMaxBytes then
    begin
      AddBWord(Result, ABytes, LStart, I);
      LStart := I;
    end;
    Inc(I, LLen);
  end;
  AddBWord(Result, ABytes, LStart, Length(ABytes));
end;

function TotalLength(const AWords: TArray<string>): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AWords) do
    Inc(Result, Length(AWords[I]) + 1);
end;

// AFirstColumn: the column the first word starts at (after 'Name: '); every
// word is sized so that even the first line stays within MAX_LINE.
function EncodedWords(const AText: string; AFirstColumn: Integer): TArray<string>;
var
  LBytes: TBytes;
  LQ, LB: TArray<string>;
  LPayload: Integer;
begin
  LPayload := MAX_LINE - AFirstColumn - WORD_OVERHEAD;
  if LPayload > MAX_WORD_PAYLOAD then
    LPayload := MAX_WORD_PAYLOAD;
  if LPayload < 16 then
    LPayload := 16;
  LBytes := PcStringToUtf8Bytes(AText);
  LQ := EncodeWordsQ(LBytes, LPayload);
  LB := EncodeWordsB(LBytes, LPayload);
  if TotalLength(LB) < TotalLength(LQ) then
    Result := LB
  else
    Result := LQ;
end;

function JoinWords(const AWords: TArray<string>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AWords) do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + AWords[I];
  end;
end;

// Splits ASCII text at spaces, keeping the words (a run of blanks becomes
// one fold point, as RFC 5322 unfolding gives back).
function SplitAtSpaces(const AText: string): TArray<string>;
var
  I, LStart: Integer;
begin
  Result := nil;
  LStart := 1;
  for I := 1 to Length(AText) + 1 do
    if (I > Length(AText)) or (AText[I] = ' ') then
    begin
      if I > LStart then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Copy(AText, LStart, I - LStart);
      end;
      LStart := I + 1;
    end;
end;

// A header's value as words to fold between: encoded-words when the text
// isn't printable ASCII, contains what a reader would take for one, or has a
// word too long for a line (encoded-words can be split, a word can't).
function UnstructuredWords(const AName, AText: string): TArray<string>;
var
  I, LFirst: Integer;
begin
  LFirst := Length(AName) + 2;
  if IsPrintableAscii(AText) and (Pos('=?', AText) = 0) then
  begin
    Result := SplitAtSpaces(AText);
    for I := 0 to High(Result) do
      if LFirst + Length(Result[I]) > MAX_LINE then
        Exit(EncodedWords(AText, LFirst));
  end
  else
    Result := EncodedWords(AText, LFirst);
end;

function EmailEncodeHeaderText(const AText: string): string;
begin
  if IsPrintableAscii(AText) and (Pos('=?', AText) = 0) then
    Result := AText
  else
    Result := JoinWords(EncodedWords(AText, 0));
end;

function NeedsQuoting(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(AName) do
    if Pos(AName[I], '()<>[]:;@\,."') > 0 then
      Exit(True);
  Result := False;
end;

function QuoteString(const AText: string): string;
var
  I: Integer;
begin
  Result := '"';
  for I := 1 to Length(AText) do
  begin
    if (AText[I] = '"') or (AText[I] = '\') then
      Result := Result + '\';
    Result := Result + AText[I];
  end;
  Result := Result + '"';
end;

// The words of one address: the name's words, then '<address>'. AFirstColumn
// as in EncodedWords.
function AddressWords(const AAddress: TEmailAddress; AFirstColumn: Integer): TArray<string>;
begin
  if AAddress.Name = '' then
    Result := nil
  else if not IsPrintableAscii(AAddress.Name) or (Pos('=?', AAddress.Name) > 0) then
    Result := EncodedWords(AAddress.Name, AFirstColumn)
  else if NeedsQuoting(AAddress.Name) then
  begin
    SetLength(Result, 1);
    Result[0] := QuoteString(AAddress.Name);
  end
  else
    Result := SplitAtSpaces(AAddress.Name);
  SetLength(Result, Length(Result) + 1);
  if AAddress.Name = '' then
    Result[High(Result)] := AAddress.Address
  else
    Result[High(Result)] := '<' + AAddress.Address + '>';
end;

function EmailFormatAddress(const AAddress: TEmailAddress): string;
begin
  Result := JoinWords(AddressWords(AAddress, 0));
end;

{ Header folding: words joined by single spaces, a new line (CRLF + space)
  before a word that would pass column 76. A word is never split. }

procedure WriteHeader(ABuffer: TAsciiBuffer; const AName: string;
  const AWords: TArray<string>);
var
  I, LCol: Integer;
begin
  ABuffer.Add(AName + ':');
  LCol := Length(AName) + 1;
  for I := 0 to High(AWords) do
  begin
    if (I > 0) and (LCol + 1 + Length(AWords[I]) > MAX_LINE) then
    begin
      ABuffer.Add(CRLF);
      LCol := 0;
    end;
    ABuffer.Add(' ' + AWords[I]);
    Inc(LCol, 1 + Length(AWords[I]));
  end;
  ABuffer.Add(CRLF);
end;

procedure AppendWords(var ATarget: TArray<string>; const AWords: TArray<string>);
var
  I, LBase: Integer;
begin
  LBase := Length(ATarget);
  SetLength(ATarget, LBase + Length(AWords));
  for I := 0 to High(AWords) do
    ATarget[LBase + I] := AWords[I];
end;

procedure WriteAddressHeader(ABuffer: TAsciiBuffer; const AName: string;
  const AList: TEmailAddresses);
var
  I: Integer;
  LWords, LOne: TArray<string>;
begin
  if Length(AList) = 0 then
    Exit;
  LWords := nil;
  for I := 0 to High(AList) do
  begin
    LOne := AddressWords(AList[I], Length(AName) + 2);
    if I < High(AList) then
      LOne[High(LOne)] := LOne[High(LOne)] + ',';
    AppendWords(LWords, LOne);
  end;
  WriteHeader(ABuffer, AName, LWords);
end;

procedure WriteSimpleHeader(ABuffer: TAsciiBuffer; const AName, AValue: string);
var
  LWords: TArray<string>;
begin
  SetLength(LWords, 1);
  LWords[0] := AValue;
  WriteHeader(ABuffer, AName, LWords);
end;

{ Bodies }

function EmailQuotedPrintable(const ABytes: TBytes): string;
var
  I, LLineStart: Integer;
  LOut, LCur, LTok: string;
  B: Byte;
  LAtLineEnd: Boolean;
begin
  LOut := '';
  LCur := '';
  LLineStart := 0;
  I := 0;
  while I <= High(ABytes) do
  begin
    B := ABytes[I];
    if (B = 13) or (B = 10) then
    begin
      // CRLF, CR or LF: one hard line break.
      LOut := LOut + LCur + CRLF;
      LCur := '';
      if (B = 13) and (I < High(ABytes)) and (ABytes[I + 1] = 10) then
        Inc(I);
      Inc(I);
      LLineStart := I;
      Continue;
    end;
    LAtLineEnd := (I = High(ABytes)) or (ABytes[I + 1] = 13) or (ABytes[I + 1] = 10);
    if (I = LLineStart) and (B = Ord('.')) then
      LTok := '=2E'
    else if ((B >= 33) and (B <= 126) and (B <> Ord('='))) or
      (((B = 32) or (B = 9)) and not LAtLineEnd) then
      LTok := Char(B)
    else
      LTok := '=' + HexByte(B);
    // 75 characters and the soft break's '='.
    if Length(LCur) + Length(LTok) > MAX_LINE - 1 then
    begin
      LOut := LOut + LCur + '=' + CRLF;
      LCur := '';
    end;
    LCur := LCur + LTok;
    Inc(I);
  end;
  Result := LOut + LCur;
end;

procedure WriteBase64Body(ABuffer: TAsciiBuffer; const ABytes: TBytes);
var
  LText: string;
  I: Integer;
begin
  LText := PcBase64Encode(ABytes);
  I := 1;
  while I <= Length(LText) do
  begin
    ABuffer.AddLine(Copy(LText, I, MAX_LINE));
    Inc(I, MAX_LINE);
  end;
end;

{ Parameters (RFC 2045 and RFC 2231) }

function IsTokenText(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if (S[I] <= ' ') or (S[I] > '~') or (Pos(S[I], '()<>@,;:\"/[]?=') > 0) then
      Exit(False);
end;

function PercentEncode2231(const ABytes: TBytes): TArray<string>;
var
  I: Integer;
  B: Byte;
begin
  SetLength(Result, Length(ABytes));
  for I := 0 to High(ABytes) do
  begin
    B := ABytes[I];
    if CharInSet(Char(B), ['A'..'Z', 'a'..'z', '0'..'9', '!', '#', '$', '&', '+', '-', '.',
      '^', '_', '`', '|', '~']) then
      Result[I] := Char(B)
    else
      Result[I] := '%' + HexByte(B);
  end;
end;

// The words of 'name="value"' (ASCII) or of RFC 2231's 'name*=UTF-8''...',
// split into name*0*=, name*1*= ... sections when long.
function FileNameParamWords(const AParam, AFileName: string): TArray<string>;
const
  MAX_SECTION = 60;
var
  LPieces: TArray<string>;
  LSections: TArray<string>;
  LCur: string;
  I: Integer;
begin
  Result := nil;
  if IsPrintableAscii(AFileName) and (Length(AFileName) + Length(AParam) < 70) then
  begin
    SetLength(Result, 1);
    Result[0] := AParam + '=' + QuoteString(AFileName) ;
    Exit;
  end;
  LPieces := PercentEncode2231(PcStringToUtf8Bytes(AFileName));
  LSections := nil;
  LCur := 'UTF-8''''';
  for I := 0 to High(LPieces) do
  begin
    if Length(LCur) + Length(LPieces[I]) > MAX_SECTION then
    begin
      SetLength(LSections, Length(LSections) + 1);
      LSections[High(LSections)] := LCur;
      LCur := '';
    end;
    LCur := LCur + LPieces[I];
  end;
  SetLength(LSections, Length(LSections) + 1);
  LSections[High(LSections)] := LCur;
  SetLength(Result, Length(LSections));
  if Length(LSections) = 1 then
    Result[0] := AParam + '*=' + LSections[0]
  else
    for I := 0 to High(LSections) do
    begin
      // The sections are parameters of their own: ';' between them.
      Result[I] := Format('%s*%d*=%s', [AParam, I, LSections[I]]);
      if I < High(LSections) then
        Result[I] := Result[I] + ';';
    end;
end;

// name="..." for Content-Type: the file name itself when it is short
// printable ASCII, encoded-words otherwise (the form Outlook reads). Each
// word leaves room for ' name="', the closing '";' and the fold's space.
function NameParamWords(const AFileName: string): TArray<string>;
var
  LWords: TArray<string>;
begin
  if IsPrintableAscii(AFileName) and (Pos('=?', AFileName) = 0) and
    (Length(AFileName) < 60) then
  begin
    SetLength(Result, 1);
    Result[0] := 'name=' + QuoteString(AFileName);
    Exit;
  end;
  LWords := EncodedWords(AFileName, 10);
  LWords[0] := 'name="' + LWords[0];
  LWords[High(LWords)] := LWords[High(LWords)] + '"';
  Result := LWords;
end;

// Adds ';' to every word that ends a parameter (all but the last word).
function WithSemicolons(const AParams: array of TArray<string>): TArray<string>;
var
  I, J: Integer;
  LWords: TArray<string>;
begin
  Result := nil;
  for I := 0 to High(AParams) do
  begin
    LWords := Copy(AParams[I]);
    for J := 0 to High(LWords) do
      if (J = High(LWords)) and (I < High(AParams)) then
        LWords[J] := LWords[J] + ';';
    AppendWords(Result, LWords);
  end;
end;

function One(const S: string): TArray<string>;
begin
  SetLength(Result, 1);
  Result[0] := S;
end;

{ The part tree }

type
  TPartKind = (pkText, pkHtml, pkAttachment, pkMultipart);

  TPart = class
  public
    Kind: TPartKind;
    Subtype: string;            // multipart: mixed, related, alternative
    RelatedType: string;        // multipart/related: the root's type
    Body: TBytes;               // text and HTML: UTF-8
    Attachment: IEmailAttachment;
    Children: array of TPart;
    destructor Destroy; override;
    procedure AddChild(APart: TPart);
    function ContentType: string;
  end;

destructor TPart.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Children) do
    Children[I].Free;
  inherited Destroy;
end;

procedure TPart.AddChild(APart: TPart);
begin
  SetLength(Children, Length(Children) + 1);
  Children[High(Children)] := APart;
end;

function TPart.ContentType: string;
begin
  case Kind of
    pkText: Result := 'text/plain';
    pkHtml: Result := 'text/html';
    pkAttachment: Result := Attachment.ContentType;
  else
    Result := 'multipart/' + Subtype;
  end;
end;

function NewTextPart(AKind: TPartKind; const AText: string): TPart;
begin
  Result := TPart.Create;
  Result.Kind := AKind;
  Result.Body := PcStringToUtf8Bytes(AText);
end;

function NewAttachmentPart(const AAttachment: IEmailAttachment): TPart;
begin
  Result := TPart.Create;
  Result.Kind := pkAttachment;
  Result.Attachment := AAttachment;
end;

// Wraps AParts in a multipart of ASubtype, or returns the only part.
function Wrap(const ASubtype: string; const AParts: array of TPart): TPart;
var
  I: Integer;
begin
  if Length(AParts) = 1 then
    Exit(AParts[0]);
  Result := TPart.Create;
  Result.Kind := pkMultipart;
  Result.Subtype := ASubtype;
  for I := 0 to High(AParts) do
    Result.AddChild(AParts[I]);
end;

function BuildTree(const AMessage: IEmailMessage): TPart;
var
  LAttachments: TEmailAttachments;
  LBody, LText, LHtml: TPart;
  LInline, LRegular: array of TPart;
  I: Integer;
  LHasHtml: Boolean;
begin
  LHasHtml := AMessage.HtmlBody <> '';
  LAttachments := AMessage.Attachments;
  LInline := nil;
  LRegular := nil;
  for I := 0 to High(LAttachments) do
    if LAttachments[I].IsInline and LHasHtml then
    begin
      SetLength(LInline, Length(LInline) + 1);
      LInline[High(LInline)] := NewAttachmentPart(LAttachments[I]);
    end
    else
    begin
      SetLength(LRegular, Length(LRegular) + 1);
      LRegular[High(LRegular)] := NewAttachmentPart(LAttachments[I]);
    end;

  LBody := nil;
  if LHasHtml then
  begin
    LHtml := NewTextPart(pkHtml, AMessage.HtmlBody);
    if AMessage.TextBody <> '' then
    begin
      LText := NewTextPart(pkText, AMessage.TextBody);
      LBody := Wrap('alternative', [LText, LHtml]);
    end
    else
      LBody := LHtml;
  end
  else if (AMessage.TextBody <> '') or (Length(LRegular) = 0) then
    LBody := NewTextPart(pkText, AMessage.TextBody);

  if Length(LInline) > 0 then
  begin
    Result := TPart.Create;
    Result.Kind := pkMultipart;
    Result.Subtype := 'related';
    Result.RelatedType := LBody.ContentType;
    Result.AddChild(LBody);
    for I := 0 to High(LInline) do
      Result.AddChild(LInline[I]);
    LBody := Result;
  end;

  if Length(LRegular) = 0 then
    Exit(LBody);
  Result := TPart.Create;
  Result.Kind := pkMultipart;
  Result.Subtype := 'mixed';
  if LBody <> nil then
    Result.AddChild(LBody);
  for I := 0 to High(LRegular) do
    Result.AddChild(LRegular[I]);
end;

procedure WritePart(ABuffer: TAsciiBuffer; APart: TPart; const AIds: IEmailIdSource);
var
  LBoundary: string;
  I: Integer;
  LParams: TArray<string>;
  LAtt: IEmailAttachment;
begin
  case APart.Kind of
    pkText, pkHtml:
      begin
        WriteHeader(ABuffer, 'Content-Type',
          WithSemicolons([One(APart.ContentType), One('charset=utf-8')]));
        WriteSimpleHeader(ABuffer, 'Content-Transfer-Encoding', 'quoted-printable');
        ABuffer.Add(CRLF);
        ABuffer.AddLine(EmailQuotedPrintable(APart.Body));
      end;
    pkAttachment:
      begin
        LAtt := APart.Attachment;
        WriteHeader(ABuffer, 'Content-Type',
          WithSemicolons([One(LAtt.ContentType), NameParamWords(LAtt.FileName)]));
        WriteSimpleHeader(ABuffer, 'Content-Transfer-Encoding', 'base64');
        if LAtt.IsInline then
        begin
          WriteSimpleHeader(ABuffer, 'Content-ID', '<' + LAtt.ContentId + '>');
          LParams := WithSemicolons([One('inline'), FileNameParamWords('filename', LAtt.FileName)]);
        end
        else
          LParams := WithSemicolons([One('attachment'), FileNameParamWords('filename', LAtt.FileName)]);
        WriteHeader(ABuffer, 'Content-Disposition', LParams);
        ABuffer.Add(CRLF);
        WriteBase64Body(ABuffer, LAtt.Content);
      end;
    pkMultipart:
      begin
        LBoundary := AIds.NewBoundary;
        if APart.RelatedType <> '' then
          LParams := WithSemicolons([One(APart.ContentType),
            One('type="' + APart.RelatedType + '"'), One('boundary="' + LBoundary + '"')])
        else
          LParams := WithSemicolons([One(APart.ContentType), One('boundary="' + LBoundary + '"')]);
        WriteHeader(ABuffer, 'Content-Type', LParams);
        ABuffer.Add(CRLF);
        for I := 0 to High(APart.Children) do
        begin
          ABuffer.AddLine('--' + LBoundary);
          WritePart(ABuffer, APart.Children[I], AIds);
        end;
        ABuffer.AddLine('--' + LBoundary + '--');
      end;
  end;
end;

{ Dates }

function EmailFormatDate(const AUtc: TDateTime): string;
const
  DAYS: array[1..7] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  MONTHS: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul',
    'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
var
  Y, M, D, H, N, S, MS: Word;
begin
  DecodeDateTime(AUtc, Y, M, D, H, N, S, MS);
  Result := Format('%s, %d %s %.4d %.2d:%.2d:%.2d +0000',
    [DAYS[DayOfWeek(AUtc)], D, MONTHS[M], Y, H, N, S]);
end;

function EmailUtcNow: TDateTime;
begin
  // TClock.Now is local time; DateTimeToUnix(.., False) converts it to UTC
  // on both compilers (FPC 3.2.2 on Linux already returns UTC from Now, and
  // then converts with an offset of 0).
  Result := UnixToDateTime(DateTimeToUnix(TClock.Now, False), True);
end;

{ The message }

function EmailBuildMime(const AMessage: IEmailMessage; const AIds: IEmailIdSource): TEmailMime;
var
  LIds: IEmailIdSource;
  LBuffer: TAsciiBuffer;
  LTree: TPart;
  LDate: TDateTime;
  LHeaders: TEmailHeaders;
  I: Integer;
  LList: TEmailAddresses;
begin
  // Held before anything can raise (gotcha 1).
  LIds := AIds;
  if AMessage = nil then
    raise EEmailArgumentError.Create('the message is nil');
  AMessage.Validate;
  if LIds = nil then
    LIds := EmailRandomIdSource;
  Result.MessageId := AMessage.MessageId;
  if Result.MessageId = '' then
    Result.MessageId := LIds.NewMessageId(AMessage.From.Domain);
  LDate := AMessage.Date;
  if LDate = 0 then
    LDate := EmailUtcNow;

  LBuffer := TAsciiBuffer.Create;
  try
    WriteSimpleHeader(LBuffer, 'Date', EmailFormatDate(LDate));
    SetLength(LList, 1);
    LList[0] := AMessage.From;
    WriteAddressHeader(LBuffer, 'From', LList);
    if AMessage.HasSender then
    begin
      LList[0] := AMessage.Sender;
      WriteAddressHeader(LBuffer, 'Sender', LList);
    end;
    WriteAddressHeader(LBuffer, 'Reply-To', AMessage.ReplyToList);
    WriteAddressHeader(LBuffer, 'To', AMessage.ToList);
    WriteAddressHeader(LBuffer, 'Cc', AMessage.CcList);
    if AMessage.Subject <> '' then
      WriteHeader(LBuffer, 'Subject', UnstructuredWords('Subject', AMessage.Subject));
    WriteSimpleHeader(LBuffer, 'Message-ID', '<' + Result.MessageId + '>');
    LHeaders := AMessage.Headers;
    for I := 0 to High(LHeaders) do
      WriteHeader(LBuffer, LHeaders[I].Name,
        UnstructuredWords(LHeaders[I].Name, LHeaders[I].Value));
    WriteSimpleHeader(LBuffer, 'MIME-Version', '1.0');
    LTree := BuildTree(AMessage);
    try
      WritePart(LBuffer, LTree, LIds);
    finally
      LTree.Free;
    end;
    Result.Data := LBuffer.ToBytes;
  finally
    LBuffer.Free;
  end;
end;

end.
