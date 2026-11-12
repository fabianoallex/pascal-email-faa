unit PascalEmail.Version;

{$I pascalemail.inc}

{ The library's version, as constants a consumer can test at compile time.

  Same format as pascal-common-faa's PascalCommon.Version: major * 10000 +
  minor * 100 + patch. Bump every constant here with each release, together
  with the version in the packages (packages/*.lpk), README.md and
  CHANGELOG.md. }

interface

const
  PASCALEMAIL_VERSION_MAJOR = 0;
  PASCALEMAIL_VERSION_MINOR = 1;
  PASCALEMAIL_VERSION_PATCH = 0;

  /// major * 10000 + minor * 100 + patch: 0.1.0 is 100.
  PASCALEMAIL_VERSION = 100;

  PASCALEMAIL_VERSION_STRING = '0.1.0';

implementation

end.
