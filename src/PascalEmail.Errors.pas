unit PascalEmail.Errors;

{$I pascalemail.inc}

{ The library's exceptions, classified by what a caller should do next.

  Every engine maps its failures onto these classes (design, E8), so an
  application, or the outbox bridge, decides on a retry without knowing the
  engine:

  - EEmailArgumentError: the message itself is wrong (no sender, a bad
    address, CR or LF in a header). The caller's bug; never retry.
  - EEmailAuthError: the engine refused the credentials. Configuration; a
    retry alone won't fix it.
  - EEmailRejected: a permanent refusal (SMTP 5xx, a provider's validation
    error). Never retry the same message.
  - EEmailTransient: the engine said "later" (SMTP 4xx, HTTP 429/5xx), or the
    connection failed before the message was handed over. Retry with backoff.
  - EEmailOutcomeUnknown: the whole message was sent and the answer never
    came. The engine may have accepted it: a retry may deliver it twice
    (with the same Message-ID, so the copy is recognizable).

  The library never retries by itself. }

interface

uses
  SysUtils;

type
  /// Base of every exception of the library.
  EEmailError = class(Exception)
  private
    FCode: Integer;
    FEnhancedCode: string;
    FEngineText: string;
  public
    /// AText is the engine's own text (an SMTP reply, an HTTP body), kept
    /// apart from the message.
    constructor CreateReply(const AMessage: string; ACode: Integer;
      const AEnhancedCode, AText: string);
    /// The SMTP reply code (550) or the HTTP status (429); 0 when there was
    /// no answer.
    property Code: Integer read FCode;
    /// RFC 3463's enhanced status code ('5.1.1'), when the engine gave one.
    property EnhancedCode: string read FEnhancedCode;
    property EngineText: string read FEngineText;
  end;

  EEmailArgumentError = class(EEmailError);
  EEmailAuthError = class(EEmailError);
  EEmailRejected = class(EEmailError);
  EEmailTransient = class(EEmailError);
  EEmailOutcomeUnknown = class(EEmailError);

  /// One recipient the engine refused while it accepted others (SMTP).
  TEmailRejection = record
    Address: string;
    Code: Integer;
    EnhancedCode: string;
    Text: string;
  end;

  TEmailRejections = TArray<TEmailRejection>;

/// True for the classes a retry may fix: EEmailTransient,
/// EEmailOutcomeUnknown and EEmailAuthError (once the configuration is
/// fixed). False for EEmailArgumentError, EEmailRejected and anything that
/// isn't an EEmailError.
function EmailIsRetryable(E: Exception): Boolean;

implementation

constructor EEmailError.CreateReply(const AMessage: string; ACode: Integer;
  const AEnhancedCode, AText: string);
begin
  inherited Create(AMessage);
  FCode := ACode;
  FEnhancedCode := AEnhancedCode;
  FEngineText := AText;
end;

function EmailIsRetryable(E: Exception): Boolean;
begin
  Result := (E is EEmailTransient) or (E is EEmailOutcomeUnknown) or (E is EEmailAuthError);
end;

end.
