unit PascalEmail.Address;

{$I pascalemail.inc}

{ E-mail addresses: a record with a display name and the address itself, a
  parser for the forms people write, and the checks every header value goes
  through.

  The address accepted is the common ground every engine takes: a dot-atom
  local part (RFC 5322 section 3.4.1, no quoted local parts) and a domain of
  letters, digits and hyphens (one label allowed, for 'user@localhost' in
  tests). ASCII only: a non-ASCII address needs SMTPUTF8, out of 0.1
  (design, E9). The display name may be any Unicode text; the MIME writer
  encodes it.

  Header injection is refused here, at the call (design, E4): a CR, LF or
  any other control character in an address, a name or a header value is
  EEmailArgumentError, so nothing a user typed can add a header or a
  recipient. }

interface

uses
  SysUtils,
  PascalEmail.Errors;

type
  TEmailAddress = record
    /// Display name, any Unicode text; '' for none.
    Name: string;
    /// local@domain, ASCII.
    Address: string;
    /// Checks both parts (EEmailArgumentError).
    class function Create(const AAddress: string; const AName: string = ''): TEmailAddress; static;
    /// 'ana@example.com', 'Ana Souza <ana@example.com>',
    /// '"Souza, Ana" <ana@example.com>' (a quoted name may escape '"' and
    /// '\' with '\'). EEmailArgumentError on anything else.
    class function Parse(const AText: string): TEmailAddress; static;
    /// The domain part, lower case.
    function Domain: string;
    /// For logs and messages: 'Ana Souza <ana@example.com>', or the address
    /// alone. Not for a header: the MIME writer encodes the name there.
    function ToString: string;
  end;

  TEmailAddresses = TArray<TEmailAddress>;

/// The address rules above (no display name).
function EmailIsValidAddress(const AAddress: string): Boolean;

/// EEmailArgumentError when AValue holds a control character (CR, LF, NUL,
/// any other below #32, or DEL), tab included unless AAllowTab. AWhat names
/// the value in the message ('subject', 'header X-Foo').
procedure EmailCheckHeaderText(const AWhat, AValue: string; AAllowTab: Boolean = True);

implementation

const
  ATEXT_SPECIALS = '!#$%&''*+-/=?^_`{|}~';

function IsAText(C: Char): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9']) or (Pos(C, ATEXT_SPECIALS) > 0);
end;

function IsValidLocalPart(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (S = '') or (Length(S) > 64) or (S[1] = '.') or (S[Length(S)] = '.') then
    Exit;
  for I := 1 to Length(S) do
    if S[I] = '.' then
    begin
      if S[I - 1] = '.' then
        Exit;
    end
    else if not IsAText(S[I]) then
      Exit;
  Result := True;
end;

function IsValidDomain(const S: string): Boolean;
var
  I, LStart: Integer;
  LLabel: string;
begin
  Result := False;
  if (S = '') or (Length(S) > 253) then
    Exit;
  LStart := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = '.') then
    begin
      LLabel := Copy(S, LStart, I - LStart);
      if (LLabel = '') or (Length(LLabel) > 63) or (LLabel[1] = '-') or
        (LLabel[Length(LLabel)] = '-') then
        Exit;
      LStart := I + 1;
    end
    else if not CharInSet(S[I], ['A'..'Z', 'a'..'z', '0'..'9', '-']) then
      Exit;
  Result := True;
end;

function EmailIsValidAddress(const AAddress: string): Boolean;
var
  LAt: Integer;
begin
  LAt := LastDelimiter('@', AAddress);
  Result := (LAt > 1) and (Length(AAddress) <= 254) and
    IsValidLocalPart(Copy(AAddress, 1, LAt - 1)) and
    IsValidDomain(Copy(AAddress, LAt + 1, MaxInt));
end;

procedure EmailCheckHeaderText(const AWhat, AValue: string; AAllowTab: Boolean);
var
  I: Integer;
begin
  for I := 1 to Length(AValue) do
    if ((AValue[I] < ' ') and not (AAllowTab and (AValue[I] = #9))) or (AValue[I] = #127) then
      raise EEmailArgumentError.CreateFmt('%s: control character #%d not allowed',
        [AWhat, Ord(AValue[I])]);
end;

procedure CheckAddress(const AAddress: string);
begin
  if not EmailIsValidAddress(AAddress) then
    raise EEmailArgumentError.CreateFmt('invalid e-mail address: "%s"', [AAddress]);
end;

{ TEmailAddress }

class function TEmailAddress.Create(const AAddress, AName: string): TEmailAddress;
begin
  EmailCheckHeaderText('display name', AName, False);
  CheckAddress(AAddress);
  Result.Name := Trim(AName);
  Result.Address := AAddress;
end;

class function TEmailAddress.Parse(const AText: string): TEmailAddress;
var
  S, LName, LAddr: string;
  LOpen, I: Integer;
begin
  EmailCheckHeaderText('address', AText, False);
  S := Trim(AText);
  LOpen := LastDelimiter('<', S);
  if LOpen = 0 then
  begin
    if Pos('>', S) > 0 then
      raise EEmailArgumentError.CreateFmt('invalid e-mail address: "%s"', [AText]);
    Exit(TEmailAddress.Create(S));
  end;
  if S[Length(S)] <> '>' then
    raise EEmailArgumentError.CreateFmt('invalid e-mail address: "%s"', [AText]);
  LAddr := Trim(Copy(S, LOpen + 1, Length(S) - LOpen - 1));
  LName := Trim(Copy(S, 1, LOpen - 1));
  if (Length(LName) >= 2) and (LName[1] = '"') and (LName[Length(LName)] = '"') then
  begin
    S := LName;
    LName := '';
    I := 2;
    while I < Length(S) do
    begin
      if (S[I] = '\') and (I + 1 < Length(S)) then
        Inc(I)
      else if S[I] = '"' then
        raise EEmailArgumentError.CreateFmt('invalid display name: %s', [S]);
      LName := LName + S[I];
      Inc(I);
    end;
  end
  else if Pos('"', LName) > 0 then
    raise EEmailArgumentError.CreateFmt('invalid display name: %s', [LName]);
  Result := TEmailAddress.Create(LAddr, LName);
end;

function TEmailAddress.Domain: string;
begin
  Result := LowerCase(Copy(Address, LastDelimiter('@', Address) + 1, MaxInt));
end;

function TEmailAddress.ToString: string;
begin
  if Name = '' then
    Result := Address
  else
    Result := Name + ' <' + Address + '>';
end;

end.
