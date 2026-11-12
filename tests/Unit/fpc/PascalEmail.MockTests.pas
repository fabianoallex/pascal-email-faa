unit PascalEmail.MockTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalEmail.MockTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the senders without a network: TMockEmailSender (what it keeps,
  FailNext, Attempts, Clear), SendMany's outcomes on TEmailSenderBase, the
  error classification (EmailIsRetryable) and TFileEmailSender (one .eml per
  message, the MIME bytes as written, no temporary file left behind).

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalEmail.DUnitXCompat). The mirror in tests/Unit/fpc is generated from
  the master by tools/gen_fpc_mirror.py: edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalEmail.Errors,
  PascalEmail.Message,
  PascalEmail.Mime,
  PascalEmail.Interfaces,
  PascalEmail.Mock,
  PascalEmail.FileSender,
  PascalEmail.TestSupport;

type
  TMockTests = class(TTestCase)
  private
    function Msg(const ATo: string): IEmailMessage;
  published
    procedure Mock_KeepsWhatWasSent;
    procedure Mock_InvalidMessage_IsArgumentError_AndNotKept;
    procedure Mock_FailNext_RaisesTheClass_ThenRecovers;
    procedure Mock_Clear;
    procedure Mock_Last_WhenEmpty;
    procedure SendMany_OutcomePerMessage;
    procedure Retryable_Classification;
    procedure File_WritesTheMime;
    procedure File_CreatesTheFolder_AndLeavesNoTemp;
    procedure File_EmptyDirectory_IsArgumentError;
  end;

implementation

function TMockTests.Msg(const ATo: string): IEmailMessage;
begin
  Result := TEmailMessage.New.SetFrom('app@example.com').AddTo(ATo).SetSubject('Olá')
    .SetText('corpo');
end;

procedure TMockTests.Mock_KeepsWhatWasSent;
var
  LMock: TMockEmailSender;
  LSender: IEmailSender;
  R: TEmailSendResult;
begin
  LMock := TMockEmailSender.Create(TCountingIdSource.Create);
  LSender := LMock;
  R := LSender.Send(Msg('a@example.com'));
  LSender.Send(Msg('b@example.com'));
  TAssert.AssertEquals('id1@example.com', R.MessageId);
  TAssert.AssertEquals('mock-1', R.ProviderId);
  TAssert.AssertEquals(2, LMock.Count);
  TAssert.AssertEquals('a@example.com', LMock.Sent(0).Message.ToList[0].Address);
  TAssert.AssertEquals('b@example.com', LMock.Last.Message.ToList[0].Address);
  TAssert.AssertTrue('the MIME is kept', Pos('Subject: =?UTF-8?', LMock.Last.Mime.AsText) > 0);
  TAssert.AssertEquals('mock-2', LMock.Last.SendResult.ProviderId);
  TAssert.AssertEquals('mock', LSender.Name);
end;

procedure TMockTests.Mock_InvalidMessage_IsArgumentError_AndNotKept;
var
  LMock: TMockEmailSender;
  LSender: IEmailSender;
begin
  LMock := TMockEmailSender.Create;
  LSender := LMock;
  try
    LSender.Send(TEmailMessage.New.AddTo('a@example.com'));
    TAssert.Fail('a message without From was sent');
  except
    on E: EEmailArgumentError do
      ;
  end;
  TAssert.AssertEquals(0, LMock.Count);
  TAssert.AssertEquals(1, LMock.Attempts);
end;

procedure TMockTests.Mock_FailNext_RaisesTheClass_ThenRecovers;
var
  LMock: TMockEmailSender;
  LSender: IEmailSender;
  LRaised: Integer;
  I: Integer;
begin
  LMock := TMockEmailSender.Create;
  LSender := LMock;
  LMock.FailNext(EEmailTransient, 2, 'try later', 451);
  LRaised := 0;
  for I := 1 to 2 do
    try
      LSender.Send(Msg('a@example.com'));
    except
      on E: EEmailTransient do
      begin
        Inc(LRaised);
        TAssert.AssertEquals(451, E.Code);
        TAssert.AssertEquals('try later', E.Message);
      end;
    end;
  TAssert.AssertEquals(2, LRaised);
  LSender.Send(Msg('a@example.com'));
  TAssert.AssertEquals(1, LMock.Count);
  TAssert.AssertEquals(3, LMock.Attempts);
  LMock.FailNext(EEmailOutcomeUnknown);
  try
    LSender.Send(Msg('a@example.com'));
    TAssert.Fail('FailNext ignored');
  except
    on E: EEmailOutcomeUnknown do
      ;
  end;
end;

procedure TMockTests.Mock_Clear;
var
  LMock: TMockEmailSender;
  LSender: IEmailSender;
begin
  LMock := TMockEmailSender.Create;
  LSender := LMock;
  LSender.Send(Msg('a@example.com'));
  LMock.FailNext(EEmailRejected);
  LMock.Clear;
  LSender.Send(Msg('a@example.com'));
  TAssert.AssertEquals('Clear drops pending failures too', 1, LMock.Count);
  TAssert.AssertEquals(1, LMock.Attempts);
end;

procedure TMockTests.Mock_Last_WhenEmpty;
var
  LMock: TMockEmailSender;
  LSender: IEmailSender;
begin
  LMock := TMockEmailSender.Create;
  LSender := LMock;
  try
    LMock.Last;
    TAssert.Fail('Last with nothing sent');
  except
    on E: EEmailError do
      ;
  end;
end;

procedure TMockTests.SendMany_OutcomePerMessage;
var
  LMock: TMockEmailSender;
  LSender: IEmailSender;
  O: TEmailSendOutcomes;
begin
  LMock := TMockEmailSender.Create(TCountingIdSource.Create);
  LSender := LMock;
  O := LSender.SendMany([Msg('a@example.com'), TEmailMessage.New.AddTo('b@example.com'),
    Msg('c@example.com')]);
  TAssert.AssertEquals(3, Length(O));
  TAssert.AssertTrue(O[0].Sent);
  TAssert.AssertEquals('id1@example.com', O[0].SendResult.MessageId);
  TAssert.AssertFalse(O[1].Sent);
  TAssert.AssertTrue(O[1].ErrorClass = EEmailArgumentError);
  TAssert.AssertFalse(O[1].Retryable);
  TAssert.AssertTrue(O[2].Sent);
  TAssert.AssertEquals(2, LMock.Count);
end;

procedure TMockTests.Retryable_Classification;
var
  E: Exception;
begin
  E := EEmailTransient.Create('x');
  try TAssert.AssertTrue('transient', EmailIsRetryable(E)); finally E.Free; end;
  E := EEmailOutcomeUnknown.Create('x');
  try TAssert.AssertTrue('unknown outcome', EmailIsRetryable(E)); finally E.Free; end;
  E := EEmailAuthError.Create('x');
  try TAssert.AssertTrue('auth', EmailIsRetryable(E)); finally E.Free; end;
  E := EEmailRejected.Create('x');
  try TAssert.AssertFalse('rejected', EmailIsRetryable(E)); finally E.Free; end;
  E := EEmailArgumentError.Create('x');
  try TAssert.AssertFalse('argument', EmailIsRetryable(E)); finally E.Free; end;
  E := Exception.Create('x');
  try TAssert.AssertFalse('not ours', EmailIsRetryable(E)); finally E.Free; end;
end;

procedure TMockTests.File_WritesTheMime;
var
  LDir: string;
  LSender: IEmailSender;
  R: TEmailSendResult;
  LExpected: string;
begin
  LDir := NewTempDir('pascalemail-file');
  try
    LSender := TFileEmailSender.Create(LDir, TCountingIdSource.Create);
    R := LSender.Send(Msg('a@example.com').SetDate(EncodeDate(2026, 1, 2)));
    TAssert.AssertEquals('id1@example.com', R.MessageId);
    TAssert.AssertEquals(IncludeTrailingPathDelimiter(ExpandFileName(LDir)) +
      'id1_example.com.eml', R.ProviderId);
    LExpected := EmailBuildMime(Msg('a@example.com').SetDate(EncodeDate(2026, 1, 2)),
      TCountingIdSource.Create).AsText;
    TAssert.AssertEquals(LExpected, ReadFileText(R.ProviderId));
    TAssert.AssertEquals('file', LSender.Name);
  finally
    LSender := nil;
    RemoveTempDir(LDir);
  end;
end;

procedure TMockTests.File_CreatesTheFolder_AndLeavesNoTemp;
var
  LDir, LSub: string;
  LSender: IEmailSender;
  LInfo: TSearchRec;
  LFiles: Integer;
begin
  LDir := NewTempDir('pascalemail-file');
  LSub := IncludeTrailingPathDelimiter(LDir) + 'outbox';
  try
    LSender := TFileEmailSender.Create(LSub);
    LSender.Send(Msg('a@example.com'));
    LSender.Send(Msg('b@example.com'));
    LFiles := 0;
    if FindFirst(IncludeTrailingPathDelimiter(LSub) + '*', faAnyFile, LInfo) = 0 then
    try
      repeat
        if (LInfo.Name <> '.') and (LInfo.Name <> '..') then
        begin
          Inc(LFiles);
          TAssert.AssertEquals('.eml', ExtractFileExt(LInfo.Name));
        end;
      until FindNext(LInfo) <> 0;
    finally
      FindClose(LInfo);
    end;
    TAssert.AssertEquals(2, LFiles);
  finally
    LSender := nil;
    RemoveTempDir(LSub);
    RemoveTempDir(LDir);
  end;
end;

procedure TMockTests.File_EmptyDirectory_IsArgumentError;
begin
  try
    TFileEmailSender.Create('');
    TAssert.Fail('an empty directory accepted');
  except
    on E: EEmailArgumentError do
      ;
  end;
end;

initialization
  RegisterTest(TMockTests);

end.
