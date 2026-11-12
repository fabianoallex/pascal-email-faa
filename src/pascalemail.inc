{ Shared compiler directives (dual Delphi / Free Pascal).

  Every unit of the library includes this file right after 'unit ...;'. On
  Delphi it doesn't change the mode; on FPC it enables Delphi mode (long
  strings, Delphi-style generics, advanced records).

  PASCALEMAIL_WINDOWS: defined when the target is Windows, on either compiler
  (Delphi defines MSWINDOWS; FPC defines WINDOWS). }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{$IFDEF MSWINDOWS}
  {$DEFINE PASCALEMAIL_WINDOWS}
{$ENDIF}
{$IFDEF WINDOWS}
  {$IFNDEF PASCALEMAIL_WINDOWS}
    {$DEFINE PASCALEMAIL_WINDOWS}
  {$ENDIF}
{$ENDIF}

{ PASCALEMAIL_FUNCREFS: the library's public callbacks are "reference to" -
  they accept a closure OR a method. Always on in Delphi. FPC 3.2.2 (stable)
  has no "reference to", so the same types become "of object" there: the
  portable subset is "pass a method". With an FPC that has function
  references (trunk/3.3+), define PASCALEMAIL_FPC_FUNCREFS in the project to
  get the Delphi API. Same rule as pascal-db-faa's PASCALDB_FUNCREFS. }
{$IFNDEF FPC}
  {$DEFINE PASCALEMAIL_FUNCREFS}
{$ELSE}
  {$IFDEF PASCALEMAIL_FPC_FUNCREFS}
    {$MODESWITCH FUNCTIONREFERENCES}
    {$MODESWITCH ANONYMOUSFUNCTIONS}
    {$DEFINE PASCALEMAIL_FUNCREFS}
  {$ENDIF}
{$ENDIF}
