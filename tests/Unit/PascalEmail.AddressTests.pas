unit PascalEmail.AddressTests;

{ Tests for PascalEmail.Address: which addresses are accepted (the dot-atom
  common ground, design E9), the forms Parse reads, and the refusal of
  control characters that would let a value add a header (design, E4).

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalEmail.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalEmail.DUnitXCompat,
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Address;

type
  [TestFixture]
  TAddressTests = class
  public
    [Test] procedure Valid_CommonForms;
    [Test] procedure Invalid_Forms;
    [Test] procedure Invalid_NonAscii;
    [Test] procedure Parse_BareAddress;
    [Test] procedure Parse_NameAndAddress;
    [Test] procedure Parse_QuotedNameWithEscapes;
    [Test] procedure Parse_NonAsciiName;
    [Test] procedure Parse_Refuses;
    [Test] procedure Create_RefusesLineBreaksInTheName;
    [Test] procedure Domain_LowerCase;
    [Test] procedure ToString_WithAndWithoutName;
    [Test] procedure HeaderText_RefusesControlCharacters;
  end;

implementation

function ParseError(const AText: string): string;
begin
  Result := '';
  try
    TEmailAddress.Parse(AText);
  except
    on E: Exception do
      Result := E.ClassName;
  end;
end;

procedure TAddressTests.Valid_CommonForms;
begin
  TAssert.AssertTrue(EmailIsValidAddress('ana@example.com'));
  TAssert.AssertTrue(EmailIsValidAddress('ana.souza+tag@mail.example.com.br'));
  TAssert.AssertTrue(EmailIsValidAddress('o''neil@example.com'));
  TAssert.AssertTrue(EmailIsValidAddress('x_y-z=1@sub-domain.example'));
  TAssert.AssertTrue('one label, for tests', EmailIsValidAddress('test@localhost'));
  TAssert.AssertTrue(EmailIsValidAddress('UPPER@EXAMPLE.COM'));
end;

procedure TAddressTests.Invalid_Forms;
begin
  TAssert.AssertFalse('empty', EmailIsValidAddress(''));
  TAssert.AssertFalse('no @', EmailIsValidAddress('ana.example.com'));
  TAssert.AssertFalse('two @', EmailIsValidAddress('ana@b@example.com'));
  TAssert.AssertFalse('no local part', EmailIsValidAddress('@example.com'));
  TAssert.AssertFalse('no domain', EmailIsValidAddress('ana@'));
  TAssert.AssertFalse('leading dot', EmailIsValidAddress('.ana@example.com'));
  TAssert.AssertFalse('trailing dot', EmailIsValidAddress('ana.@example.com'));
  TAssert.AssertFalse('two dots', EmailIsValidAddress('ana..souza@example.com'));
  TAssert.AssertFalse('space', EmailIsValidAddress('ana souza@example.com'));
  TAssert.AssertFalse('quoted local part', EmailIsValidAddress('"ana"@example.com'));
  TAssert.AssertFalse('domain label starting with -', EmailIsValidAddress('ana@-example.com'));
  TAssert.AssertFalse('empty label', EmailIsValidAddress('ana@example..com'));
  TAssert.AssertFalse('domain literal', EmailIsValidAddress('ana@[127.0.0.1]'));
  TAssert.AssertFalse('angle bracket', EmailIsValidAddress('<ana@example.com>'));
  TAssert.AssertFalse('local part over 64',
    EmailIsValidAddress(StringOfChar('a', 65) + '@example.com'));
  TAssert.AssertTrue('local part of 64',
    EmailIsValidAddress(StringOfChar('a', 64) + '@example.com'));
end;

procedure TAddressTests.Invalid_NonAscii;
begin
  TAssert.AssertFalse('local part', EmailIsValidAddress('joão@example.com'));
  TAssert.AssertFalse('domain (IDN)', EmailIsValidAddress('ana@exemplo.com.br.ação'));
end;

procedure TAddressTests.Parse_BareAddress;
var
  A: TEmailAddress;
begin
  A := TEmailAddress.Parse('  ana@example.com ');
  TAssert.AssertEquals('ana@example.com', A.Address);
  TAssert.AssertEquals('', A.Name);
  A := TEmailAddress.Parse('<ana@example.com>');
  TAssert.AssertEquals('ana@example.com', A.Address);
  TAssert.AssertEquals('', A.Name);
end;

procedure TAddressTests.Parse_NameAndAddress;
var
  A: TEmailAddress;
begin
  A := TEmailAddress.Parse('Ana Souza <ana@example.com>');
  TAssert.AssertEquals('Ana Souza', A.Name);
  TAssert.AssertEquals('ana@example.com', A.Address);
  A := TEmailAddress.Parse('Ana Souza<ana@example.com>');
  TAssert.AssertEquals('Ana Souza', A.Name);
end;

procedure TAddressTests.Parse_QuotedNameWithEscapes;
var
  A: TEmailAddress;
begin
  A := TEmailAddress.Parse('"Souza, Ana" <ana@example.com>');
  TAssert.AssertEquals('Souza, Ana', A.Name);
  A := TEmailAddress.Parse('"Ana \"Nana\" \\ Souza" <ana@example.com>');
  TAssert.AssertEquals('Ana "Nana" \ Souza', A.Name);
end;

procedure TAddressTests.Parse_NonAsciiName;
var
  A: TEmailAddress;
begin
  A := TEmailAddress.Parse('João da Conceição <joao@example.com>');
  TAssert.AssertEquals('João da Conceição', A.Name);
  TAssert.AssertEquals('joao@example.com', A.Address);
end;

procedure TAddressTests.Parse_Refuses;
begin
  TAssert.AssertEquals('no closing bracket', 'EEmailArgumentError',
    ParseError('Ana <ana@example.com'));
  TAssert.AssertEquals('text after bracket', 'EEmailArgumentError',
    ParseError('Ana <ana@example.com> x'));
  TAssert.AssertEquals('stray quote', 'EEmailArgumentError',
    ParseError('Ana "x <ana@example.com>'));
  TAssert.AssertEquals('bad address', 'EEmailArgumentError', ParseError('Ana <ana>'));
  TAssert.AssertEquals('empty', 'EEmailArgumentError', ParseError(''));
  TAssert.AssertEquals('line break', 'EEmailArgumentError',
    ParseError('Ana <ana@example.com>'#13#10'Bcc: x@example.com'));
end;

procedure TAddressTests.Create_RefusesLineBreaksInTheName;
begin
  try
    TEmailAddress.Create('ana@example.com', 'Ana'#10'Bcc: x@example.com');
    TAssert.Fail('a name with LF was accepted');
  except
    on E: EEmailArgumentError do
      TAssert.AssertTrue(Pos('display name', E.Message) > 0);
  end;
end;

procedure TAddressTests.Domain_LowerCase;
begin
  TAssert.AssertEquals('example.com', TEmailAddress.Create('Ana@Example.COM').Domain);
end;

procedure TAddressTests.ToString_WithAndWithoutName;
begin
  TAssert.AssertEquals('ana@example.com', TEmailAddress.Create('ana@example.com').ToString);
  TAssert.AssertEquals('Ana <ana@example.com>',
    TEmailAddress.Create('ana@example.com', 'Ana').ToString);
end;

procedure TAddressTests.HeaderText_RefusesControlCharacters;
var
  LCode: Integer;
  LRefused: Integer;
begin
  LRefused := 0;
  for LCode := 0 to 31 do
    try
      EmailCheckHeaderText('x', 'a' + Char(LCode) + 'b');
    except
      on E: EEmailArgumentError do
        Inc(LRefused);
    end;
  TAssert.AssertEquals('every control character but tab', 31, LRefused);
  try
    EmailCheckHeaderText('x', 'a'#127'b');
    TAssert.Fail('DEL accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
  try
    EmailCheckHeaderText('x', 'a'#9'b', False);
    TAssert.Fail('tab accepted with AAllowTab = False');
  except
    on E: EEmailArgumentError do
      ;
  end;
  EmailCheckHeaderText('x', 'Olá, mundo — ok');
end;

initialization
  TDUnitX.RegisterTestFixture(TAddressTests);

end.
