program PascalEmail.IntegrationSuite;

{ DUnitX runner for the integration tests: the SMTP sender against Mailpit
  (sh tools/mailpit.sh first; PascalEmail.IntegrationEnv says where the
  servers are). Named IntegrationSuite, not IntegrationTests: Delphi refuses
  a program named like a unit it uses.

  The sibling FPCUnit suite lives in tests/Integration/fpc, generated from
  these masters by tools/gen_fpc_mirror.py. }

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
  PascalEmail.Smtp in '..\..\adapters\smtp\PascalEmail.Smtp.pas',
  PascalEmail.DUnitXCompat in '..\Unit\PascalEmail.DUnitXCompat.pas',
  PascalEmail.TestSupport in '..\Unit\PascalEmail.TestSupport.pas',
  PascalEmail.IntegrationEnv in 'PascalEmail.IntegrationEnv.pas',
  PascalEmail.SmtpIntegrationTests in 'PascalEmail.SmtpIntegrationTests.pas';

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
