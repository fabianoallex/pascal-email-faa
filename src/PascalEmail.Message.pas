unit PascalEmail.Message;

{$I pascalemail.inc}

{ The message: what an application builds and every engine sends.

  An interface with a fluent builder (design, E2): each setter returns the
  message, so a message is one expression. "To" is a reserved word, hence
  AddTo/AddCc/AddBcc. Every value is checked when it goes in (an address, a
  header, CR or LF anywhere: EEmailArgumentError), so a message that exists
  is a message an engine can write; Validate only adds what can't be known
  until the end (a sender, at least one recipient).

  Content lives in memory as TBytes (design, E3): engines cap a message at
  10-40 MB, so streaming would cost a second code path for little.

  A message is not thread-safe while it is built; sending only reads it, so
  one finished message may be handed to several senders. }

interface

uses
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Address;

type
  TEmailHeader = record
    Name: string;
    Value: string;
  end;

  TEmailHeaders = TArray<TEmailHeader>;

  IEmailAttachment = interface
    ['{2B7D0A8E-5C1F-4E8B-9A57-3F0C6D9E1A42}']
    function FileName: string;
    function ContentType: string;
    function Content: TBytes;
    /// '' for a regular attachment; set for an inline part the HTML body
    /// refers to as cid:<ContentId>.
    function ContentId: string;
    function IsInline: Boolean;
  end;

  TEmailAttachments = TArray<IEmailAttachment>;

  IEmailMessage = interface
    ['{6E1C4B93-8D2A-4F57-B0E6-91A3C5D7F208}']
    function SetFrom(const AAddress: string; const AName: string = ''): IEmailMessage;
    /// The Sender header: who actually sends on behalf of From (a system
    /// sending for a user). Rarely needed.
    function SetSender(const AAddress: string; const AName: string = ''): IEmailMessage;
    function AddTo(const AAddress: string; const AName: string = ''): IEmailMessage;
    function AddCc(const AAddress: string; const AName: string = ''): IEmailMessage;
    /// Receives the message; never written into its headers.
    function AddBcc(const AAddress: string; const AName: string = ''): IEmailMessage;
    function AddReplyTo(const AAddress: string; const AName: string = ''): IEmailMessage;
    function SetSubject(const ASubject: string): IEmailMessage;
    /// The plain-text body. With an HTML body too, the message carries both
    /// (multipart/alternative) and the client picks.
    function SetText(const ABody: string): IEmailMessage;
    function SetHtml(const ABody: string): IEmailMessage;
    /// AContentType '' = guessed from the file name's extension
    /// (EmailGuessContentType).
    function Attach(const AFileName: string; const AContent: TBytes;
      const AContentType: string = ''): IEmailMessage;
    /// Reads the file now; the attachment's name is the file's.
    function AttachFile(const APath: string; const AContentType: string = ''): IEmailMessage;
    /// An image (or any part) the HTML body shows inline: <img src="cid:logo">
    /// for AContentId 'logo'.
    function Embed(const AContentId, AFileName: string; const AContent: TBytes;
      const AContentType: string = ''): IEmailMessage;
    /// A header of the application's (X-Campaign, List-Unsubscribe...). The
    /// headers the library writes itself (From, To, Subject, Date,
    /// Message-ID, MIME-Version, Content-*...) are refused.
    function AddHeader(const AName, AValue: string): IEmailMessage;
    /// Without angle brackets ('abc@example.com'); generated when not set.
    function SetMessageId(const AId: string): IEmailMessage;
    /// The Date header, UTC; the clock's (TClock) at writing time when not
    /// set.
    function SetDate(const AUtc: TDateTime): IEmailMessage;
    /// A provider-side tag (SES, SendGrid, Mailgun...); SMTP ignores tags
    /// (design, Q5).
    function AddTag(const ATag: string): IEmailMessage;
    /// Provider-side key/value metadata; SMTP ignores it.
    function SetMetadata(const AKey, AValue: string): IEmailMessage;

    function From: TEmailAddress;
    function HasFrom: Boolean;
    function Sender: TEmailAddress;
    function HasSender: Boolean;
    function ToList: TEmailAddresses;
    function CcList: TEmailAddresses;
    function BccList: TEmailAddresses;
    function ReplyToList: TEmailAddresses;
    function Subject: string;
    function TextBody: string;
    function HtmlBody: string;
    function Attachments: TEmailAttachments;
    function Headers: TEmailHeaders;
    function MessageId: string;
    /// 0 when not set.
    function Date: TDateTime;
    function Tags: TArray<string>;
    function Metadata: TEmailHeaders;
    /// To, Cc and Bcc addresses, each once (compared without case), in that
    /// order: the envelope's recipients.
    function Recipients: TArray<string>;
    /// EEmailArgumentError when there is no From or no recipient.
    procedure Validate;
  end;

  TEmailMessage = class
  public
    class function New: IEmailMessage; static;
  end;

/// A MIME type from a file name's extension (the common ones: images, PDF,
/// Office, text, archives, calendar); 'application/octet-stream' otherwise.
function EmailGuessContentType(const AFileName: string): string;

/// True when AName is one of the headers the library writes itself.
function EmailIsReservedHeader(const AName: string): Boolean;

implementation

uses
  Classes;

type
  TEmailAttachment = class(TInterfacedObject, IEmailAttachment)
  private
    FFileName: string;
    FContentType: string;
    FContent: TBytes;
    FContentId: string;
  public
    constructor Create(const AFileName, AContentType: string; const AContent: TBytes;
      const AContentId: string);
    function FileName: string;
    function ContentType: string;
    function Content: TBytes;
    function ContentId: string;
    function IsInline: Boolean;
  end;

  TEmailMessageImpl = class(TInterfacedObject, IEmailMessage)
  private
    FFrom: TEmailAddress;
    FHasFrom: Boolean;
    FSender: TEmailAddress;
    FHasSender: Boolean;
    FTo: TEmailAddresses;
    FCc: TEmailAddresses;
    FBcc: TEmailAddresses;
    FReplyTo: TEmailAddresses;
    FSubject: string;
    FText: string;
    FHtml: string;
    FAttachments: TEmailAttachments;
    FHeaders: TEmailHeaders;
    FMessageId: string;
    FDate: TDateTime;
    FTags: TArray<string>;
    FMetadata: TEmailHeaders;
    procedure AddAttachment(const AAttachment: IEmailAttachment);
  public
    function SetFrom(const AAddress: string; const AName: string = ''): IEmailMessage;
    function SetSender(const AAddress: string; const AName: string = ''): IEmailMessage;
    function AddTo(const AAddress: string; const AName: string = ''): IEmailMessage;
    function AddCc(const AAddress: string; const AName: string = ''): IEmailMessage;
    function AddBcc(const AAddress: string; const AName: string = ''): IEmailMessage;
    function AddReplyTo(const AAddress: string; const AName: string = ''): IEmailMessage;
    function SetSubject(const ASubject: string): IEmailMessage;
    function SetText(const ABody: string): IEmailMessage;
    function SetHtml(const ABody: string): IEmailMessage;
    function Attach(const AFileName: string; const AContent: TBytes;
      const AContentType: string = ''): IEmailMessage;
    function AttachFile(const APath: string; const AContentType: string = ''): IEmailMessage;
    function Embed(const AContentId, AFileName: string; const AContent: TBytes;
      const AContentType: string = ''): IEmailMessage;
    function AddHeader(const AName, AValue: string): IEmailMessage;
    function SetMessageId(const AId: string): IEmailMessage;
    function SetDate(const AUtc: TDateTime): IEmailMessage;
    function AddTag(const ATag: string): IEmailMessage;
    function SetMetadata(const AKey, AValue: string): IEmailMessage;
    function From: TEmailAddress;
    function HasFrom: Boolean;
    function Sender: TEmailAddress;
    function HasSender: Boolean;
    function ToList: TEmailAddresses;
    function CcList: TEmailAddresses;
    function BccList: TEmailAddresses;
    function ReplyToList: TEmailAddresses;
    function Subject: string;
    function TextBody: string;
    function HtmlBody: string;
    function Attachments: TEmailAttachments;
    function Headers: TEmailHeaders;
    function MessageId: string;
    function Date: TDateTime;
    function Tags: TArray<string>;
    function Metadata: TEmailHeaders;
    function Recipients: TArray<string>;
    procedure Validate;
  end;

const
  RESERVED_HEADERS: array[0..15] of string = (
    'from', 'sender', 'to', 'cc', 'bcc', 'reply-to', 'subject', 'date',
    'message-id', 'mime-version', 'content-type', 'content-transfer-encoding',
    'content-disposition', 'content-id', 'return-path', 'received');

function EmailIsReservedHeader(const AName: string): Boolean;
var
  I: Integer;
  LName: string;
begin
  LName := LowerCase(AName);
  for I := Low(RESERVED_HEADERS) to High(RESERVED_HEADERS) do
    if LName = RESERVED_HEADERS[I] then
      Exit(True);
  Result := False;
end;

function EmailGuessContentType(const AFileName: string): string;
var
  LExt: string;
begin
  LExt := LowerCase(ExtractFileExt(AFileName));
  if (LExt = '.jpg') or (LExt = '.jpeg') then Result := 'image/jpeg'
  else if LExt = '.png' then Result := 'image/png'
  else if LExt = '.gif' then Result := 'image/gif'
  else if LExt = '.webp' then Result := 'image/webp'
  else if LExt = '.svg' then Result := 'image/svg+xml'
  else if LExt = '.bmp' then Result := 'image/bmp'
  else if LExt = '.ico' then Result := 'image/x-icon'
  else if LExt = '.pdf' then Result := 'application/pdf'
  else if LExt = '.zip' then Result := 'application/zip'
  else if LExt = '.gz' then Result := 'application/gzip'
  else if LExt = '.json' then Result := 'application/json'
  else if LExt = '.xml' then Result := 'application/xml'
  else if (LExt = '.txt') or (LExt = '.log') then Result := 'text/plain'
  else if LExt = '.csv' then Result := 'text/csv'
  else if (LExt = '.htm') or (LExt = '.html') then Result := 'text/html'
  else if LExt = '.ics' then Result := 'text/calendar'
  else if LExt = '.eml' then Result := 'message/rfc822'
  else if LExt = '.doc' then Result := 'application/msword'
  else if LExt = '.docx' then
    Result := 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  else if LExt = '.xls' then Result := 'application/vnd.ms-excel'
  else if LExt = '.xlsx' then
    Result := 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  else if LExt = '.ppt' then Result := 'application/vnd.ms-powerpoint'
  else if LExt = '.pptx' then
    Result := 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
  else if LExt = '.odt' then Result := 'application/vnd.oasis.opendocument.text'
  else if LExt = '.ods' then Result := 'application/vnd.oasis.opendocument.spreadsheet'
  else
    Result := 'application/octet-stream';
end;

// A Content-ID or Message-ID as written between angle brackets: printable
// ASCII, no blank and no angle bracket.
procedure CheckIdText(const AWhat, AValue: string);
var
  I: Integer;
begin
  if AValue = '' then
    raise EEmailArgumentError.CreateFmt('%s is empty', [AWhat]);
  for I := 1 to Length(AValue) do
    if (AValue[I] <= ' ') or (AValue[I] > '~') or (AValue[I] = '<') or (AValue[I] = '>') or
      (AValue[I] = '"') or (AValue[I] = '\') then
      raise EEmailArgumentError.CreateFmt('%s: invalid character in "%s"', [AWhat, AValue]);
end;

procedure CheckContentType(const AValue: string);
var
  I: Integer;
begin
  if Pos('/', AValue) < 2 then
    raise EEmailArgumentError.CreateFmt('invalid content type: "%s"', [AValue]);
  for I := 1 to Length(AValue) do
    if (AValue[I] <= ' ') or (AValue[I] > '~') or (AValue[I] = ';') or (AValue[I] = '"') then
      raise EEmailArgumentError.CreateFmt('invalid content type: "%s"', [AValue]);
end;

procedure CheckHeaderName(const AName: string);
var
  I: Integer;
begin
  if AName = '' then
    raise EEmailArgumentError.Create('header name is empty');
  for I := 1 to Length(AName) do
    if (AName[I] <= ' ') or (AName[I] > '~') or (AName[I] = ':') then
      raise EEmailArgumentError.CreateFmt('invalid header name: "%s"', [AName]);
  if EmailIsReservedHeader(AName) then
    raise EEmailArgumentError.CreateFmt('header %s is written by the library', [AName]);
end;

procedure AppendAddress(var AList: TEmailAddresses; const AAddress: TEmailAddress);
begin
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := AAddress;
end;

function ReadFileBytes(const APath: string): TBytes;
var
  LStream: TFileStream;
begin
  Result := nil;
  try
    LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  except
    on E: EFOpenError do
      raise EEmailArgumentError.CreateFmt('cannot read attachment "%s": %s', [APath, E.Message]);
  end;
  try
    SetLength(Result, LStream.Size);
    if Length(Result) > 0 then
      LStream.ReadBuffer(Result[0], Length(Result));
  finally
    LStream.Free;
  end;
end;

{ TEmailAttachment }

constructor TEmailAttachment.Create(const AFileName, AContentType: string;
  const AContent: TBytes; const AContentId: string);
begin
  inherited Create;
  FFileName := AFileName;
  FContentType := AContentType;
  FContent := AContent;
  FContentId := AContentId;
end;

function TEmailAttachment.FileName: string;
begin
  Result := FFileName;
end;

function TEmailAttachment.ContentType: string;
begin
  Result := FContentType;
end;

function TEmailAttachment.Content: TBytes;
begin
  Result := FContent;
end;

function TEmailAttachment.ContentId: string;
begin
  Result := FContentId;
end;

function TEmailAttachment.IsInline: Boolean;
begin
  Result := FContentId <> '';
end;

function NewAttachment(const AFileName: string; const AContent: TBytes;
  const AContentType, AContentId: string): IEmailAttachment;
var
  LType: string;
begin
  EmailCheckHeaderText('attachment file name', AFileName, False);
  if Trim(AFileName) = '' then
    raise EEmailArgumentError.Create('attachment file name is empty');
  LType := AContentType;
  if LType = '' then
    LType := EmailGuessContentType(AFileName)
  else
    CheckContentType(LType);
  Result := TEmailAttachment.Create(AFileName, LowerCase(LType), Copy(AContent), AContentId);
end;

{ TEmailMessage }

class function TEmailMessage.New: IEmailMessage;
begin
  Result := TEmailMessageImpl.Create;
end;

{ TEmailMessageImpl }

function TEmailMessageImpl.SetFrom(const AAddress, AName: string): IEmailMessage;
begin
  Result := Self;
  FFrom := TEmailAddress.Create(AAddress, AName);
  FHasFrom := True;
end;

function TEmailMessageImpl.SetSender(const AAddress, AName: string): IEmailMessage;
begin
  Result := Self;
  FSender := TEmailAddress.Create(AAddress, AName);
  FHasSender := True;
end;

function TEmailMessageImpl.AddTo(const AAddress, AName: string): IEmailMessage;
begin
  Result := Self;
  AppendAddress(FTo, TEmailAddress.Create(AAddress, AName));
end;

function TEmailMessageImpl.AddCc(const AAddress, AName: string): IEmailMessage;
begin
  Result := Self;
  AppendAddress(FCc, TEmailAddress.Create(AAddress, AName));
end;

function TEmailMessageImpl.AddBcc(const AAddress, AName: string): IEmailMessage;
begin
  Result := Self;
  AppendAddress(FBcc, TEmailAddress.Create(AAddress, AName));
end;

function TEmailMessageImpl.AddReplyTo(const AAddress, AName: string): IEmailMessage;
begin
  Result := Self;
  AppendAddress(FReplyTo, TEmailAddress.Create(AAddress, AName));
end;

function TEmailMessageImpl.SetSubject(const ASubject: string): IEmailMessage;
begin
  Result := Self;
  EmailCheckHeaderText('subject', ASubject);
  FSubject := ASubject;
end;

function TEmailMessageImpl.SetText(const ABody: string): IEmailMessage;
begin
  Result := Self;
  FText := ABody;
end;

function TEmailMessageImpl.SetHtml(const ABody: string): IEmailMessage;
begin
  Result := Self;
  FHtml := ABody;
end;

procedure TEmailMessageImpl.AddAttachment(const AAttachment: IEmailAttachment);
begin
  SetLength(FAttachments, Length(FAttachments) + 1);
  FAttachments[High(FAttachments)] := AAttachment;
end;

function TEmailMessageImpl.Attach(const AFileName: string; const AContent: TBytes;
  const AContentType: string): IEmailMessage;
begin
  Result := Self;
  AddAttachment(NewAttachment(AFileName, AContent, AContentType, ''));
end;

function TEmailMessageImpl.AttachFile(const APath, AContentType: string): IEmailMessage;
begin
  Result := Self;
  AddAttachment(NewAttachment(ExtractFileName(APath), ReadFileBytes(APath), AContentType, ''));
end;

function TEmailMessageImpl.Embed(const AContentId, AFileName: string;
  const AContent: TBytes; const AContentType: string): IEmailMessage;
var
  I: Integer;
begin
  Result := Self;
  CheckIdText('content id', AContentId);
  for I := 0 to High(FAttachments) do
    if SameText(FAttachments[I].ContentId, AContentId) then
      raise EEmailArgumentError.CreateFmt('content id "%s" used twice', [AContentId]);
  AddAttachment(NewAttachment(AFileName, AContent, AContentType, AContentId));
end;

function TEmailMessageImpl.AddHeader(const AName, AValue: string): IEmailMessage;
begin
  Result := Self;
  CheckHeaderName(AName);
  EmailCheckHeaderText('header ' + AName, AValue);
  SetLength(FHeaders, Length(FHeaders) + 1);
  FHeaders[High(FHeaders)].Name := AName;
  FHeaders[High(FHeaders)].Value := AValue;
end;

function TEmailMessageImpl.SetMessageId(const AId: string): IEmailMessage;
var
  LId: string;
begin
  Result := Self;
  LId := Trim(AId);
  if (Length(LId) >= 2) and (LId[1] = '<') and (LId[Length(LId)] = '>') then
    LId := Copy(LId, 2, Length(LId) - 2);
  CheckIdText('message id', LId);
  FMessageId := LId;
end;

function TEmailMessageImpl.SetDate(const AUtc: TDateTime): IEmailMessage;
begin
  Result := Self;
  FDate := AUtc;
end;

function TEmailMessageImpl.AddTag(const ATag: string): IEmailMessage;
begin
  Result := Self;
  EmailCheckHeaderText('tag', ATag, False);
  SetLength(FTags, Length(FTags) + 1);
  FTags[High(FTags)] := ATag;
end;

function TEmailMessageImpl.SetMetadata(const AKey, AValue: string): IEmailMessage;
var
  I: Integer;
begin
  Result := Self;
  EmailCheckHeaderText('metadata key', AKey, False);
  EmailCheckHeaderText('metadata ' + AKey, AValue);
  if AKey = '' then
    raise EEmailArgumentError.Create('metadata key is empty');
  for I := 0 to High(FMetadata) do
    if FMetadata[I].Name = AKey then
    begin
      FMetadata[I].Value := AValue;
      Exit;
    end;
  SetLength(FMetadata, Length(FMetadata) + 1);
  FMetadata[High(FMetadata)].Name := AKey;
  FMetadata[High(FMetadata)].Value := AValue;
end;

function TEmailMessageImpl.From: TEmailAddress;
begin
  Result := FFrom;
end;

function TEmailMessageImpl.HasFrom: Boolean;
begin
  Result := FHasFrom;
end;

function TEmailMessageImpl.Sender: TEmailAddress;
begin
  Result := FSender;
end;

function TEmailMessageImpl.HasSender: Boolean;
begin
  Result := FHasSender;
end;

function TEmailMessageImpl.ToList: TEmailAddresses;
begin
  Result := Copy(FTo);
end;

function TEmailMessageImpl.CcList: TEmailAddresses;
begin
  Result := Copy(FCc);
end;

function TEmailMessageImpl.BccList: TEmailAddresses;
begin
  Result := Copy(FBcc);
end;

function TEmailMessageImpl.ReplyToList: TEmailAddresses;
begin
  Result := Copy(FReplyTo);
end;

function TEmailMessageImpl.Subject: string;
begin
  Result := FSubject;
end;

function TEmailMessageImpl.TextBody: string;
begin
  Result := FText;
end;

function TEmailMessageImpl.HtmlBody: string;
begin
  Result := FHtml;
end;

function TEmailMessageImpl.Attachments: TEmailAttachments;
begin
  Result := Copy(FAttachments);
end;

function TEmailMessageImpl.Headers: TEmailHeaders;
begin
  Result := Copy(FHeaders);
end;

function TEmailMessageImpl.MessageId: string;
begin
  Result := FMessageId;
end;

function TEmailMessageImpl.Date: TDateTime;
begin
  Result := FDate;
end;

function TEmailMessageImpl.Tags: TArray<string>;
begin
  Result := Copy(FTags);
end;

function TEmailMessageImpl.Metadata: TEmailHeaders;
begin
  Result := Copy(FMetadata);
end;

procedure AddRecipients(var AResult: TArray<string>; const AList: TEmailAddresses);
var
  I, J: Integer;
  LFound: Boolean;
begin
  for I := 0 to High(AList) do
  begin
    LFound := False;
    for J := 0 to High(AResult) do
      if SameText(AResult[J], AList[I].Address) then
      begin
        LFound := True;
        Break;
      end;
    if not LFound then
    begin
      SetLength(AResult, Length(AResult) + 1);
      AResult[High(AResult)] := AList[I].Address;
    end;
  end;
end;

function TEmailMessageImpl.Recipients: TArray<string>;
begin
  Result := nil;
  AddRecipients(Result, FTo);
  AddRecipients(Result, FCc);
  AddRecipients(Result, FBcc);
end;

procedure TEmailMessageImpl.Validate;
begin
  if not FHasFrom then
    raise EEmailArgumentError.Create('the message has no From address');
  if Length(FTo) + Length(FCc) + Length(FBcc) = 0 then
    raise EEmailArgumentError.Create('the message has no recipient');
end;

end.
