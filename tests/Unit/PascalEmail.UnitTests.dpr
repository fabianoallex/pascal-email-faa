program PascalEmail.UnitTests;

{ DUnitX runner for the unit tests. No server needed: the SMTP tests talk to
  a scripted server (PascalEmail.TestSupport), the file sender writes into
  a temporary folder.

  The sibling FPCUnit suite lives in tests/Unit/fpc, with the same coverage
  and identical test bodies: the files there are GENERATED from these by
  tools/gen_fpc_mirror.py (PascalEmail.DUnitXCompat exists for that).
  Always edit the DUnitX masters here and regenerate the mirror. }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  PascalEmail.Version in '..\..\src\PascalEmail.Version.pas',
  PascalEmail.Errors in '..\..\src\PascalEmail.Errors.pas',
  PascalEmail.Address in '..\..\src\PascalEmail.Address.pas',
  PascalEmail.Message in '..\..\src\PascalEmail.Message.pas',
  PascalEmail.Mime in '..\..\src\PascalEmail.Mime.pas',
  PascalEmail.Interfaces in '..\..\src\PascalEmail.Interfaces.pas',
  PascalEmail.Mock in '..\..\src\PascalEmail.Mock.pas',
  PascalEmail.FileSender in '..\..\src\PascalEmail.FileSender.pas',
  PascalEmail.Decorators in '..\..\src\PascalEmail.Decorators.pas',
  PascalEmail.Smtp in '..\..\adapters\smtp\PascalEmail.Smtp.pas',
  PascalEmail.AwsSigV4 in '..\..\adapters\ses\PascalEmail.AwsSigV4.pas',
  PascalEmail.Ses in '..\..\adapters\ses\PascalEmail.Ses.pas',
  PascalEmail.DUnitXCompat in 'PascalEmail.DUnitXCompat.pas',
  PascalEmail.TestSupport in 'PascalEmail.TestSupport.pas',
  PascalEmail.AddressTests in 'PascalEmail.AddressTests.pas',
  PascalEmail.MimeTests in 'PascalEmail.MimeTests.pas',
  PascalEmail.MockTests in 'PascalEmail.MockTests.pas',
  PascalEmail.SmtpTests in 'PascalEmail.SmtpTests.pas',
  PascalEmail.DecoratorTests in 'PascalEmail.DecoratorTests.pas',
  PascalEmail.SesTests in 'PascalEmail.SesTests.pas';

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  // Acceptance criterion on both sides: 0 leaks (FastMM here, heaptrc on FPC).
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;

    if TDUnitX.Options.Include = '' then
      TDUnitX.Options.Include := '.';

    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    runner.FailsOnNoAsserts := False;

    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      logger := TDUnitXConsoleLogger.Create(
        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      runner.AddLogger(logger);
    end;

    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);

    results := runner.Execute;

    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;

    if (TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause) and IsConsole then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
