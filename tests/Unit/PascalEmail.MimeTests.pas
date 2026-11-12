unit PascalEmail.MimeTests;

{ Tests for the message builder (PascalEmail.Message) and the MIME writer
  (PascalEmail.Mime): exact bytes for the basic structures, with a counting
  id source, so both compilers are held to the same output (design, E5);
  the encodings (quoted-printable, RFC 2047 words, RFC 2231 file names,
  Base64 at 76 columns); line lengths; Bcc kept out of the headers; and the
  checks that keep a value from adding a header (design, E4).

  Expected values were checked independently: each structure was parsed by
  Python's email package (policy.default), which gave back the subject,
  names, bodies and attachments these messages were built with.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalEmail.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalEmail.DUnitXCompat,
  SysUtils,
  DateUtils,
  PascalCommon.Utf8,
  PascalCommon.SystemContext,
  PascalEmail.Errors,
  PascalEmail.Address,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.TestSupport;

type
  [TestFixture]
  TMimeTests = class
  private
    function Basic: IEmailMessage;
    function Build(const AMessage: IEmailMessage): string;
    function QP(const AText: string): string;
  public
    [Test] procedure TextOnly_ExactBytes;
    [Test] procedure TextAndHtml_Alternative_ExactBytes;
    [Test] procedure Attachment_Mixed_ExactBytes;
    [Test] procedure Inline_Related_InsideMixed;
    [Test] procedure Inline_WithoutHtml_BecomesAnAttachment;
    [Test] procedure AttachmentsOnly_NoEmptyBody;
    [Test] procedure Empty_SingleEmptyTextPart;
    [Test] procedure Headers_Order_And_Bcc_Hidden;
    [Test] procedure Headers_ReplyTo_Cc_Sender_Custom;
    [Test] procedure Subject_Ascii_AsIs;
    [Test] procedure Subject_NonAscii_ShorterEncoding;
    [Test] procedure Subject_LooksEncoded_IsEncoded;
    [Test] procedure Subject_Long_FoldsWithin76;
    [Test] procedure Address_Names_QuotedOrEncoded;
    [Test] procedure Address_ManyRecipients_FoldBetween;
    [Test] procedure FileName_NonAscii_Rfc2231AndEncodedWord;
    [Test] procedure FileName_Long_SplitIntoSections;
    [Test] procedure Base64_Lines76;
    [Test] procedure EveryLine_Within76_ForAHardMessage;
    [Test] procedure QuotedPrintable_Basics;
    [Test] procedure QuotedPrintable_LineEndingsBecomeCrlf;
    [Test] procedure QuotedPrintable_SoftBreaksAt76;
    [Test] procedure QuotedPrintable_DoesNotSplitAnEscape;
    [Test] procedure QuotedPrintable_LeadingDot;
    [Test] procedure Date_Format;
    [Test] procedure Date_FromTheClockWhenNotSet;
    [Test] procedure MessageId_Given_Kept;
    [Test] procedure MessageId_Generated_FromTheSendersDomain;
    [Test] procedure Random_Ids_DifferAndAreSafe;
    [Test] procedure Validate_NoFrom;
    [Test] procedure Validate_NoRecipient;
    [Test] procedure Recipients_EachOnce;
    [Test] procedure Refuses_LineBreakInSubject;
    [Test] procedure Refuses_ReservedHeader;
    [Test] procedure Refuses_BadHeaderName;
    [Test] procedure Refuses_LineBreakInHeaderValue;
    [Test] procedure Refuses_BadContentId_AndDuplicate;
    [Test] procedure Refuses_BadContentType;
    [Test] procedure GuessContentType;
    [Test] procedure AttachFile_ReadsTheFile;
    [Test] procedure AttachFile_Missing_IsArgumentError;
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

const
  CRLF = #13#10;
  HEAD =
    'Date: Thu, 12 Nov 2026 14:05:09 +0000' + CRLF +
    'From: Ana <ana@example.com>' + CRLF +
    'To: bob@example.com' + CRLF +
    'Subject: Hello' + CRLF +
    'Message-ID: <id1@example.com>' + CRLF +
    'MIME-Version: 1.0' + CRLF;

function TMimeTests.Basic: IEmailMessage;
begin
  Result := TEmailMessage.New
    .SetFrom('ana@example.com', 'Ana')
    .AddTo('bob@example.com')
    .SetSubject('Hello')
    .SetDate(EncodeDateTime(2026, 11, 12, 14, 5, 9, 0));
end;

function TMimeTests.Build(const AMessage: IEmailMessage): string;
begin
  Result := EmailBuildMime(AMessage, TCountingIdSource.Create).AsText;
end;

function TMimeTests.QP(const AText: string): string;
begin
  Result := EmailQuotedPrintable(PcStringToUtf8Bytes(AText));
end;

function Between(const AText, AStart, AEnd: string): string;
var
  P: Integer;
begin
  P := Pos(AStart, AText);
  if P = 0 then
    Exit('<' + AStart + ' not found>');
  Result := Copy(AText, P + Length(AStart), MaxInt);
  P := Pos(AEnd, Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
end;

// The header block (everything before the first blank line).
function HeaderBlock(const AMime: string): string;
begin
  Result := Copy(AMime, 1, Pos(CRLF + CRLF, AMime) + 1);
end;

{ Structures }

procedure TMimeTests.TextOnly_ExactBytes;
begin
  TAssert.AssertEquals(HEAD +
    'Content-Type: text/plain; charset=utf-8' + CRLF +
    'Content-Transfer-Encoding: quoted-printable' + CRLF +
    CRLF +
    'Hi Bob' + CRLF,
    Build(Basic.SetText('Hi Bob')));
end;

procedure TMimeTests.TextAndHtml_Alternative_ExactBytes;
begin
  TAssert.AssertEquals(HEAD +
    'Content-Type: multipart/alternative; boundary="=_b1"' + CRLF +
    CRLF +
    '--=_b1' + CRLF +
    'Content-Type: text/plain; charset=utf-8' + CRLF +
    'Content-Transfer-Encoding: quoted-printable' + CRLF +
    CRLF +
    'Hi' + CRLF +
    '--=_b1' + CRLF +
    'Content-Type: text/html; charset=utf-8' + CRLF +
    'Content-Transfer-Encoding: quoted-printable' + CRLF +
    CRLF +
    '<p class=3D"x">Hi</p>' + CRLF +
    '--=_b1--' + CRLF,
    Build(Basic.SetText('Hi').SetHtml('<p class="x">Hi</p>')));
end;

procedure TMimeTests.Attachment_Mixed_ExactBytes;
begin
  TAssert.AssertEquals(HEAD +
    'Content-Type: multipart/mixed; boundary="=_b1"' + CRLF +
    CRLF +
    '--=_b1' + CRLF +
    'Content-Type: text/plain; charset=utf-8' + CRLF +
    'Content-Transfer-Encoding: quoted-printable' + CRLF +
    CRLF +
    'See attached.' + CRLF +
    '--=_b1' + CRLF +
    'Content-Type: application/pdf; name="report.pdf"' + CRLF +
    'Content-Transfer-Encoding: base64' + CRLF +
    'Content-Disposition: attachment; filename="report.pdf"' + CRLF +
    CRLF +
    'AAECAw==' + CRLF +
    '--=_b1--' + CRLF,
    Build(Basic.SetText('See attached.').Attach('report.pdf', SampleBytes(4))));
end;

procedure TMimeTests.Inline_Related_InsideMixed;
var
  S: string;
begin
  S := Build(Basic.SetText('t').SetHtml('<img src="cid:logo">')
    .Embed('logo', 'logo.png', SampleBytes(3))
    .Attach('a.txt', SampleBytes(2)));
  TAssert.AssertTrue('mixed outside',
    Pos('Content-Type: multipart/mixed; boundary="=_b1"', S) > 0);
  TAssert.AssertTrue('related with the root''s type', Pos('Content-Type: multipart/related;' +
    ' type="multipart/alternative";' + CRLF + ' boundary="=_b2"', S) > 0);
  TAssert.AssertTrue('alternative inside',
    Pos('Content-Type: multipart/alternative; boundary="=_b3"', S) > 0);
  TAssert.AssertTrue('inline part', Pos('Content-Type: image/png; name="logo.png"' + CRLF +
    'Content-Transfer-Encoding: base64' + CRLF + 'Content-ID: <logo>' + CRLF +
    'Content-Disposition: inline; filename="logo.png"', S) > 0);
  TAssert.AssertTrue('order: alternative, then the image, then the attachment',
    (Pos('--=_b3--', S) < Pos('Content-ID: <logo>', S)) and
    (Pos('--=_b2--', S) < Pos('filename="a.txt"', S)));
  TAssert.AssertTrue('closing order', (Pos('--=_b3--', S) < Pos('--=_b2--', S)) and
    (Pos('--=_b2--', S) < Pos('--=_b1--', S)));
end;

procedure TMimeTests.Inline_WithoutHtml_BecomesAnAttachment;
var
  S: string;
begin
  S := Build(Basic.SetText('t').Embed('logo', 'logo.png', SampleBytes(3)));
  TAssert.AssertTrue(Pos('multipart/mixed', S) > 0);
  TAssert.AssertEquals('no related without HTML', 0, Pos('multipart/related', S));
  TAssert.AssertTrue('keeps its Content-ID', Pos('Content-ID: <logo>', S) > 0);
end;

procedure TMimeTests.AttachmentsOnly_NoEmptyBody;
var
  S: string;
begin
  S := Build(Basic.Attach('a.bin', SampleBytes(1)));
  TAssert.AssertTrue(Pos('multipart/mixed', S) > 0);
  TAssert.AssertEquals('no text part', 0, Pos('text/plain', S));
end;

procedure TMimeTests.Empty_SingleEmptyTextPart;
begin
  TAssert.AssertEquals(HEAD +
    'Content-Type: text/plain; charset=utf-8' + CRLF +
    'Content-Transfer-Encoding: quoted-printable' + CRLF +
    CRLF + CRLF,
    Build(Basic));
end;

procedure TMimeTests.Headers_Order_And_Bcc_Hidden;
var
  S: string;
begin
  S := HeaderBlock(Build(Basic.AddBcc('secret@example.com').SetText('x')));
  TAssert.AssertEquals('no Bcc header', 0, Pos('Bcc', S));
  TAssert.AssertEquals('no Bcc address', 0, Pos('secret', S));
  TAssert.AssertTrue(Pos('Date:', S) = 1);
  TAssert.AssertTrue((Pos('From:', S) < Pos('To:', S)) and (Pos('To:', S) < Pos('Subject:', S))
    and (Pos('Subject:', S) < Pos('Message-ID:', S)) and (Pos('Message-ID:', S) < Pos('MIME-Version:', S)));
end;

procedure TMimeTests.Headers_ReplyTo_Cc_Sender_Custom;
var
  S: string;
begin
  S := HeaderBlock(Build(Basic.AddCc('carl@example.com', 'Carl')
    .AddReplyTo('help@example.com', 'Help desk').SetSender('robot@example.com')
    .AddHeader('X-Campaign', 'Novembro / 2026').AddHeader('List-Unsubscribe',
      '<mailto:unsub@example.com>').SetText('x')));
  TAssert.AssertTrue(Pos('Sender: robot@example.com' + CRLF, S) > 0);
  TAssert.AssertTrue(Pos('Reply-To: Help desk <help@example.com>' + CRLF, S) > 0);
  TAssert.AssertTrue(Pos('Cc: Carl <carl@example.com>' + CRLF, S) > 0);
  TAssert.AssertTrue(Pos('X-Campaign: Novembro / 2026' + CRLF, S) > 0);
  TAssert.AssertTrue(Pos('List-Unsubscribe: <mailto:unsub@example.com>' + CRLF, S) > 0);
  TAssert.AssertTrue('custom headers before MIME-Version',
    Pos('X-Campaign', S) < Pos('MIME-Version', S));
end;

procedure TMimeTests.Subject_Ascii_AsIs;
begin
  TAssert.AssertTrue(Pos('Subject: Order #123 (shipped)' + CRLF,
    Build(Basic.SetSubject('Order #123 (shipped)'))) > 0);
end;

procedure TMimeTests.Subject_NonAscii_ShorterEncoding;
begin
  // 'Café': B is one character shorter than Q.
  TAssert.AssertTrue('B', Pos('Subject: =?UTF-8?B?Q2Fmw6k=?=' + CRLF,
    Build(Basic.SetSubject('Café'))) > 0);
  // A tie goes to Q, the readable one.
  TAssert.AssertTrue('Q', Pos('Subject: =?UTF-8?Q?Relat=C3=B3rio_de_mar=C3=A7o?=' + CRLF,
    Build(Basic.SetSubject('Relatório de março'))) > 0);
  TAssert.AssertEquals('=?UTF-8?B?Q2Fmw6k=?=', EmailEncodeHeaderText('Café'));
  TAssert.AssertEquals('plain', EmailEncodeHeaderText('plain'));
end;

procedure TMimeTests.Subject_LooksEncoded_IsEncoded;
begin
  // A literal '=?' would be read as the start of an encoded-word.
  TAssert.AssertTrue(Pos('Subject: =?UTF-8?', Build(Basic.SetSubject('a =?b?= c'))) > 0);
end;

procedure TMimeTests.Subject_Long_FoldsWithin76;
var
  S, LSubject: string;
  I: Integer;
begin
  LSubject := '';
  for I := 1 to 12 do
    LSubject := LSubject + 'Relatório de vendas ' + IntToStr(I) + ' — ';
  S := HeaderBlock(Build(Basic.SetSubject(LSubject)));
  TAssert.AssertEquals('lines over 76', 0, LinesLongerThan(S, 76));
  TAssert.AssertTrue('folded', Pos(CRLF + ' =?UTF-8?', S) > 0);
  // A long ASCII text folds between its words.
  S := HeaderBlock(Build(Basic.SetSubject(StringOfChar('x', 30) + ' ' +
    StringOfChar('y', 30) + ' ' + StringOfChar('z', 30))));
  TAssert.AssertTrue(Pos('Subject: ' + StringOfChar('x', 30) + ' ' + StringOfChar('y', 30) +
    CRLF + ' ' + StringOfChar('z', 30) + CRLF, S) > 0);
  // One ASCII word longer than a line goes out encoded, in pieces.
  S := HeaderBlock(Build(Basic.SetSubject(StringOfChar('w', 200))));
  TAssert.AssertEquals('long word', 0, LinesLongerThan(S, 76));
end;

procedure TMimeTests.Address_Names_QuotedOrEncoded;
var
  S: string;
begin
  S := HeaderBlock(Build(TEmailMessage.New.SetFrom('ana@example.com', 'Souza, Ana')
    .AddTo('joao@example.com', 'João Conceição').AddTo('x@example.com', 'Dr. "X"')
    .SetDate(EncodeDateTime(2026, 11, 12, 14, 5, 9, 0))));
  TAssert.AssertTrue('quoted (comma)', Pos('From: "Souza, Ana" <ana@example.com>', S) > 0);
  // B (24 characters) is shorter than Q (29) here.
  TAssert.AssertTrue('encoded', Pos('To: =?UTF-8?B?Sm/Do28gQ29uY2Vpw6fDo28=?= ' +
    '<joao@example.com>,', S) > 0);
  // The line folds between the name and the address here.
  TAssert.AssertTrue('quotes escaped', Pos(' "Dr. \"X\""' + CRLF + ' <x@example.com>', S) > 0);
  TAssert.AssertEquals('"Souza, Ana" <ana@example.com>',
    EmailFormatAddress(TEmailAddress.Create('ana@example.com', 'Souza, Ana')));
end;

procedure TMimeTests.Address_ManyRecipients_FoldBetween;
var
  M: IEmailMessage;
  S: string;
  I: Integer;
begin
  M := Basic;
  for I := 1 to 20 do
    M.AddCc(Format('person%d@example.com', [I]), Format('Person %d', [I]));
  S := HeaderBlock(Build(M));
  TAssert.AssertEquals(0, LinesLongerThan(S, 76));
  TAssert.AssertTrue(Pos('Person 20 <person20@example.com>' + CRLF, S) > 0);
  TAssert.AssertTrue('comma after each but the last', Pos('<person19@example.com>,', S) > 0);
end;

procedure TMimeTests.FileName_NonAscii_Rfc2231AndEncodedWord;
var
  S: string;
begin
  S := Build(Basic.Attach('relatório.pdf', SampleBytes(1)));
  TAssert.AssertTrue('name= for Outlook',
    Pos('Content-Type: application/pdf; name="=?UTF-8?Q?relat=C3=B3rio=2Epdf?="', S) > 0);
  TAssert.AssertTrue('RFC 2231',
    Pos('Content-Disposition: attachment; filename*=UTF-8''''relat%C3%B3rio.pdf', S) > 0);
end;

procedure TMimeTests.FileName_Long_SplitIntoSections;
var
  S: string;
begin
  S := Build(Basic.Attach('relatório de vendas do mês de março de 2026 final versão 2.pdf',
    SampleBytes(1)));
  TAssert.AssertTrue(Pos('filename*0*=UTF-8''''relat%C3%B3rio%20de%20', S) > 0);
  TAssert.AssertTrue('a ";" between sections', Pos(';' + CRLF + ' filename*1*=', S) > 0);
  TAssert.AssertEquals(0, LinesLongerThan(S, 76));
end;

procedure TMimeTests.Base64_Lines76;
var
  S, LBody: string;
begin
  S := Build(Basic.Attach('a.bin', SampleBytes(200)));
  LBody := Between(S, 'filename="a.bin"' + CRLF + CRLF, '--=_b1--');
  // 200 bytes are 268 characters: three lines of 76 and one of 40.
  TAssert.AssertEquals((76 + 2) * 3 + 40 + 2, Length(LBody));
  TAssert.AssertTrue(Copy(LBody, 77, 2) = CRLF);
end;

procedure TMimeTests.EveryLine_Within76_ForAHardMessage;
var
  S, LLong: string;
begin
  LLong := RepeatText('á', 300) + ' ' + StringOfChar('=', 100);
  S := Build(Basic.SetSubject(LLong).AddTo('z@example.com', RepeatText('ç', 80))
    .SetText(LLong).SetHtml(LLong).Attach(RepeatText('ã', 90) + '.txt', SampleBytes(500))
    .Embed('img1', RepeatText('é', 70) + '.png', SampleBytes(100))
    .AddHeader('X-Long', LLong));
  TAssert.AssertEquals(0, LinesLongerThan(S, 76));
end;

{ Quoted-printable }

procedure TMimeTests.QuotedPrintable_Basics;
begin
  TAssert.AssertEquals('plain', QP('plain'));
  TAssert.AssertEquals('a=3Db', QP('a=b'));
  TAssert.AssertEquals('Ol=C3=A1', QP('Olá'));
  TAssert.AssertEquals('trailing space', 'end=20', QP('end '));
  TAssert.AssertEquals('trailing tab', 'end=09', QP('end'#9));
  TAssert.AssertEquals('inner space', 'a b', QP('a b'));
  TAssert.AssertEquals('space before a line break', 'a=20' + CRLF + 'b', QP('a '#10'b'));
  TAssert.AssertEquals('', QP(''));
end;

procedure TMimeTests.QuotedPrintable_LineEndingsBecomeCrlf;
begin
  TAssert.AssertEquals('a' + CRLF + 'b' + CRLF + 'c' + CRLF + 'd',
    QP('a'#13#10'b'#10'c'#13'd'));
  TAssert.AssertEquals('blank lines kept', 'a' + CRLF + CRLF + 'b', QP('a'#10#10'b'));
  TAssert.AssertEquals('final break kept', 'a' + CRLF, QP('a'#10));
end;

procedure TMimeTests.QuotedPrintable_SoftBreaksAt76;
var
  S: string;
begin
  S := QP(StringOfChar('a', 200));
  TAssert.AssertEquals(StringOfChar('a', 75) + '=' + CRLF + StringOfChar('a', 75) + '=' + CRLF +
    StringOfChar('a', 50), S);
  TAssert.AssertEquals('76 characters: 75 and a soft break (room for the =)', StringOfChar('b', 75) + '=' + CRLF + 'b',
    QP(StringOfChar('b', 76)));
end;

procedure TMimeTests.QuotedPrintable_DoesNotSplitAnEscape;
var
  S: string;
begin
  // 74 letters then 'é' (=C3=A9): the escape doesn't fit and moves whole.
  S := QP(StringOfChar('a', 74) + 'é');
  TAssert.AssertEquals(StringOfChar('a', 74) + '=' + CRLF + '=C3=A9', S);
  TAssert.AssertEquals(0, LinesLongerThan(QP(RepeatText('ç', 500)), 76));
end;

procedure TMimeTests.QuotedPrintable_LeadingDot;
begin
  TAssert.AssertEquals('=2E' + CRLF + '=2Ea.b' + CRLF + 'x.', QP('.'#10'.a.b'#10'x.'));
end;

{ Date and ids }

procedure TMimeTests.Date_Format;
begin
  TAssert.AssertEquals('Thu, 12 Nov 2026 14:05:09 +0000',
    EmailFormatDate(EncodeDateTime(2026, 11, 12, 14, 5, 9, 0)));
  TAssert.AssertEquals('Sun, 1 Feb 2026 00:00:00 +0000',
    EmailFormatDate(EncodeDateTime(2026, 2, 1, 0, 0, 0, 0)));
end;

procedure TMimeTests.Date_FromTheClockWhenNotSet;
var
  S: string;
  LLocal: TDateTime;
begin
  LLocal := EncodeDateTime(2026, 7, 4, 10, 30, 0, 0);
  TClock.SetClock(TFixedClock.Create(LLocal));
  try
    S := Build(TEmailMessage.New.SetFrom('a@example.com').AddTo('b@example.com'));
  finally
    TClock.Reset;
  end;
  // The clock is local time; the header is the same instant in UTC.
  TAssert.AssertTrue(Pos('Date: ' + EmailFormatDate(UnixToDateTime(
    DateTimeToUnix(LLocal, False), True)) + CRLF, S) = 1);
end;

procedure TMimeTests.MessageId_Given_Kept;
var
  LMime: TEmailMime;
begin
  LMime := EmailBuildMime(Basic.SetMessageId('<order-42@shop.example.com>'), TCountingIdSource.Create);
  TAssert.AssertEquals('order-42@shop.example.com', LMime.MessageId);
  TAssert.AssertTrue(Pos('Message-ID: <order-42@shop.example.com>' + CRLF, LMime.AsText) > 0);
end;

procedure TMimeTests.MessageId_Generated_FromTheSendersDomain;
var
  LMime: TEmailMime;
begin
  LMime := EmailBuildMime(TEmailMessage.New.SetFrom('a@Mail.Example.com').AddTo('b@x.com'),
    TCountingIdSource.Create);
  TAssert.AssertEquals('id1@mail.example.com', LMime.MessageId);
end;

procedure TMimeTests.Random_Ids_DifferAndAreSafe;
var
  A, B: TEmailMime;
begin
  A := EmailBuildMime(Basic.SetText('x').Attach('a', SampleBytes(1)));
  B := EmailBuildMime(Basic.SetText('x').Attach('a', SampleBytes(1)));
  TAssert.AssertTrue(A.MessageId <> B.MessageId);
  TAssert.AssertTrue(Pos('@example.com', A.MessageId) = 33);
  TAssert.AssertTrue('boundary starts with =_', Pos('boundary="=_pe_', A.AsText) > 0);
end;

procedure TMimeTests.Validate_NoFrom;
begin
  try
    EmailBuildMime(TEmailMessage.New.AddTo('b@example.com'));
    TAssert.Fail('no From accepted');
  except
    on E: EEmailArgumentError do
      TAssert.AssertTrue(Pos('From', E.Message) > 0);
  end;
end;

procedure TMimeTests.Validate_NoRecipient;
begin
  try
    EmailBuildMime(TEmailMessage.New.SetFrom('a@example.com'));
    TAssert.Fail('no recipient accepted');
  except
    on E: EEmailArgumentError do
      TAssert.AssertTrue(Pos('recipient', E.Message) > 0);
  end;
  // Bcc alone is a recipient.
  TAssert.AssertTrue(EmailBuildMime(TEmailMessage.New.SetFrom('a@example.com')
    .AddBcc('b@example.com')).MessageId <> '');
end;

procedure TMimeTests.Recipients_EachOnce;
var
  R: TArray<string>;
begin
  R := TEmailMessage.New.AddTo('a@example.com').AddCc('B@example.com').AddBcc('A@EXAMPLE.com')
    .AddBcc('c@example.com').AddTo('b@example.com').Recipients;
  TAssert.AssertEquals(3, Length(R));
  TAssert.AssertEquals('a@example.com', R[0]);
  // To first (a, b), then Cc and Bcc add only what is new (c).
  TAssert.AssertEquals('b@example.com', R[1]);
  TAssert.AssertEquals('c@example.com', R[2]);
end;

{ Refusals }

procedure TMimeTests.Refuses_LineBreakInSubject;
begin
  try
    TEmailMessage.New.SetSubject('Hi'#13#10'Bcc: victim@example.com');
    TAssert.Fail('CRLF in the subject accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
end;

procedure TMimeTests.Refuses_ReservedHeader;
const
  NAMES: array[0..5] of string = ('Bcc', 'from', 'Content-Type', 'MIME-Version',
    'Message-ID', 'Subject');
var
  I, LRefused: Integer;
begin
  LRefused := 0;
  for I := Low(NAMES) to High(NAMES) do
    try
      TEmailMessage.New.AddHeader(NAMES[I], 'x');
    except
      on E: EEmailArgumentError do
        Inc(LRefused);
    end;
  TAssert.AssertEquals(Length(NAMES), LRefused);
end;

procedure TMimeTests.Refuses_BadHeaderName;
begin
  try
    TEmailMessage.New.AddHeader('X Bad', 'x');
    TAssert.Fail('a space in a header name accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
  try
    TEmailMessage.New.AddHeader('X-A:B', 'x');
    TAssert.Fail('a colon in a header name accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
end;

procedure TMimeTests.Refuses_LineBreakInHeaderValue;
begin
  try
    TEmailMessage.New.AddHeader('X-Ok', 'a'#10'Bcc: x@example.com');
    TAssert.Fail('LF in a header value accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
end;

procedure TMimeTests.Refuses_BadContentId_AndDuplicate;
var
  M: IEmailMessage;
begin
  try
    TEmailMessage.New.Embed('a b', 'x.png', SampleBytes(1));
    TAssert.Fail('a space in a content id accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
  M := TEmailMessage.New.Embed('logo', 'x.png', SampleBytes(1));
  try
    M.Embed('LOGO', 'y.png', SampleBytes(1));
    TAssert.Fail('a content id used twice accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
end;

procedure TMimeTests.Refuses_BadContentType;
begin
  try
    TEmailMessage.New.Attach('a.bin', SampleBytes(1), 'text/plain; charset=x');
    TAssert.Fail('parameters in a content type accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
  TAssert.AssertEquals('lower case', 'image/png',
    TEmailMessage.New.Attach('a', SampleBytes(1), 'IMAGE/PNG').Attachments[0].ContentType);
end;

procedure TMimeTests.GuessContentType;
begin
  TAssert.AssertEquals('application/pdf', EmailGuessContentType('a.PDF'));
  TAssert.AssertEquals('image/jpeg', EmailGuessContentType('photo.jpeg'));
  TAssert.AssertEquals('text/csv', EmailGuessContentType('x.csv'));
  TAssert.AssertEquals('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    EmailGuessContentType('planilha.xlsx'));
  TAssert.AssertEquals('application/octet-stream', EmailGuessContentType('noext'));
  TAssert.AssertEquals('application/octet-stream', EmailGuessContentType('x.unknown'));
end;

procedure TMimeTests.AttachFile_ReadsTheFile;
var
  LDir, LPath: string;
  LFile: THandle;
  LBytes: TBytes;
  A: IEmailAttachment;
begin
  LDir := NewTempDir('pascalemail-attach');
  try
    LPath := IncludeTrailingPathDelimiter(LDir) + 'dados.csv';
    LBytes := PcStringToUtf8Bytes('a;b' + CRLF + '1;2' + CRLF);
    LFile := FileCreate(LPath);
    FileWrite(LFile, LBytes[0], Length(LBytes));
    FileClose(LFile);
    A := TEmailMessage.New.AttachFile(LPath).Attachments[0];
    TAssert.AssertEquals('dados.csv', A.FileName);
    TAssert.AssertEquals('text/csv', A.ContentType);
    TAssert.AssertEquals(Length(LBytes), Length(A.Content));
    TAssert.AssertFalse(A.IsInline);
  finally
    RemoveTempDir(LDir);
  end;
end;

procedure TMimeTests.AttachFile_Missing_IsArgumentError;
begin
  try
    TEmailMessage.New.AttachFile('Z:\no\such\file.pdf');
    TAssert.Fail('a missing file accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMimeTests);

end.
