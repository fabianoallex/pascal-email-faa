program PascalEmailIntegrationTestsFpc;

{ FPCUnit runner for the integration tests (Mailpit: sh tools/mailpit.sh
  first; PascalEmail.IntegrationEnv says where the servers are). Same
  coverage as the DUnitX suite (tests/Integration/PascalEmail.IntegrationSuite.dpr):
  the fixtures in tests/Integration/fpc are generated from the DUnitX masters
  by tools/gen_fpc_mirror.py.

  Console (text output), when called with any parameter:
    .\PascalEmailIntegrationTestsFpc.exe --all --format=plain
  GUI (test tree + green/red bar), with no parameters:
    .\PascalEmailIntegrationTestsFpc.exe
  Outside Windows it always runs in console mode (no LCL/widgetset). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  PascalEmail.SmtpIntegrationTests;

var
  ConsoleApp: TTestRunner;
begin
  // The tests' accented literals are UTF-8: a plain FPC console's code page
  // isn't, by default.
  SetMultiByteConversionCodePage(CP_UTF8);

  {$IFDEF MSWINDOWS}
  if ParamCount = 0 then
  begin
    Application.Initialize;
    Application.CreateForm(TGUITestRunner, TestRunner);
    Application.Run;
  end
  else
  {$ENDIF}
  begin
    DefaultFormat := fPlain;
    DefaultRunAllTests := True;
    ConsoleApp := TTestRunner.Create(nil);
    try
      ConsoleApp.Initialize;
      ConsoleApp.Title := 'pascal-email-faa - integration tests (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
