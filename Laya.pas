unit Laya;

(* Delphi binding for laya.dll, the C ABI of laya.cpp (Laya typed-decision inference).

  Requirements: a Win64 target (laya.dll is 64-bit only). Put laya.dll next to your .exe.
  All text crosses the boundary as UTF-8 JSON; this unit converts to and from Delphi strings.

  Quick start:
    var Agent := TLayaAgent.Create('C:\models\laya', '{"backend":"cpu"}');
    try
      ShowMessage(Agent.Predict(
        '{"state":"Please refund the duplicate charge.",' +
        ' "questions":{"refund":{"type":"noul","instructions":"Does the customer ask for a refund?"}}}'));
    finally
      Agent.Free;
    end;

  Thread safety: one TLayaAgent may be used from several threads; the library serializes calls
  on the same agent. Loading a model takes seconds and gigabytes of memory, so create one agent
  per model and keep it alive.

  Also compiles with Free Pascal ({$MODE DELPHI}) against liblaya.so on Linux. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  SysUtils;

(* The library exists for 64-bit targets only. A new Delphi project starts with the 32-bit
   Windows platform selected, and a 32-bit program cannot load a 64-bit DLL: it would compile
   and then fail to start. Stop here instead, with a message that says what to do. *)
{$IF SizeOf(Pointer) <> 8}
  {$MESSAGE FATAL 'Laya.pas needs a 64-bit target: the LibLayaX library is 64-bit only. In Delphi, add the "64-bit Windows" target platform to the project and make it active.'}
{$IFEND}

const
{$IF Defined(MSWINDOWS)}
  LayaLib = 'laya.dll';
{$ELSEIF Defined(MACOS) or Defined(DARWIN)}
  LayaLib = 'liblaya.dylib';   (* deploy to Contents/MacOS; install name is @rpath/liblaya.dylib *)
{$ELSE}
  LayaLib = 'liblaya.so';
{$IFEND}
  LAYA_C_API_VERSION = 1;

  (* Log levels (ggml) *)
  LAYA_LOG_DEBUG = 1;
  LAYA_LOG_INFO  = 2;
  LAYA_LOG_WARN  = 3;
  LAYA_LOG_ERROR = 4;
  LAYA_LOG_CONT  = 5;

type
  PLayaAgent = Pointer;

  (* Called from library threads; must be thread-safe (e.g. use TThread.Queue for UI). *)
  TLayaLogProc = procedure(Level: Integer; Text: PAnsiChar; User: Pointer); cdecl;

(* ---- Raw imports (see laya_c.h for the full contract) ---- *)
function laya_version: PAnsiChar; cdecl; external LayaLib;
function laya_api_version: Integer; cdecl; external LayaLib;
procedure laya_set_log_callback(Fn: TLayaLogProc; User: Pointer; MinLevel: Integer); cdecl; external LayaLib;
function laya_create(ModelDirUtf8, OptionsJson: PAnsiChar): PLayaAgent; cdecl; external LayaLib;
function laya_predict(Agent: PLayaAgent; RequestJson: PAnsiChar): PAnsiChar; cdecl; external LayaLib;
function laya_prepare(Agent: PLayaAgent; RequestJson: PAnsiChar): PAnsiChar; cdecl; external LayaLib;
function laya_info(Agent: PLayaAgent): PAnsiChar; cdecl; external LayaLib;
procedure laya_free_string(S: PAnsiChar); cdecl; external LayaLib;
procedure laya_destroy(Agent: PLayaAgent); cdecl; external LayaLib;
function laya_last_error: PAnsiChar; cdecl; external LayaLib;

type
  ELaya = class(Exception);

  TLayaAgent = class
  private
    FHandle: PLayaAgent;
    function TakeString(P: PAnsiChar): string;
  public
    (* ModelDir: checkpoint folder (contains rl_agent_config.json), or a model store root plus
      "variant" in Options. Options JSON keys: backend (cpu|cuda|vulkan), variant, precision
      (fp32|fp16|bf16), flash, tensor_core, allow_truncation, threads, device (GPU index or
      part of its name, e.g. "RTX"; default = first discrete GPU). Raises ELaya on failure. *)
    constructor Create(const ModelDir: string; const OptionsJson: string = '');
    destructor Destroy; override;

    (* Request: one request object or an array of them. Returns the full response JSON:
      {"results":[...],"elapsed_ms":n,"backend":"...","device":"..."}. Raises ELaya on error. *)
    function Predict(const RequestJson: string): string;
    (* Same as Predict but returns {"error":"..."} instead of raising. *)
    function TryPredict(const RequestJson: string): string;
    (* Tokenized model inputs as JSON (debugging). *)
    function Prepare(const RequestJson: string): string;
    (* {"backend","device","model_dir","model_name","variant","max_len","head_max_len"} *)
    function Info: string;

    (* Convenience builders: one state, one question. Results are full response JSON. *)
    function AskYesNo(const State, Instructions: string; const Id: string = 'q'): string;
    function AskChoice(const State, Instructions: string; const Options: array of string;
      const Id: string = 'q'): string;
    function AskScore(const State, Instructions: string; const Levels: array of string;
      const Id: string = 'q'): string;

    property Handle: PLayaAgent read FHandle;
  end;

(* JSON string literal (with quotes) for S. *)
function LayaQuote(const S: string): string;
function LayaVersion: string;

implementation

function FromUtf8(P: PAnsiChar): string;
begin
  if P = nil then Result := '' else Result := UTF8ToString(P);
end;

function LayaVersion: string;
begin
  Result := FromUtf8(laya_version);
end;

function LayaQuote(const S: string): string;
var
  I: Integer;
  C: Char;
  SB: string;
begin
  SB := '"';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"': SB := SB + '\"';
      '\': SB := SB + '\\';
      #8:  SB := SB + '\b';
      #9:  SB := SB + '\t';
      #10: SB := SB + '\n';
      #12: SB := SB + '\f';
      #13: SB := SB + '\r';
    else
      if Ord(C) < 32 then SB := SB + '\u' + IntToHex(Ord(C), 4)
      else SB := SB + C;
    end;
  end;
  Result := SB + '"';
end;

function JsonArray(const Items: array of string): string;
var
  I: Integer;
begin
  Result := '[';
  for I := Low(Items) to High(Items) do
  begin
    if I > Low(Items) then Result := Result + ',';
    Result := Result + LayaQuote(Items[I]);
  end;
  Result := Result + ']';
end;

function Question(const State, Id, QType, Instructions, Criteria: string): string;
begin
  Result := '{"state":' + LayaQuote(State) + ',"questions":{' + LayaQuote(Id) +
    ':{"type":"' + QType + '","instructions":' + LayaQuote(Instructions);
  if Criteria <> '' then Result := Result + ',"criteria":' + Criteria;
  Result := Result + '}}}';
end;

(* TLayaAgent *)

constructor TLayaAgent.Create(const ModelDir, OptionsJson: string);
var
  Dir, Opts: UTF8String;
begin
  inherited Create;
  if laya_api_version <> LAYA_C_API_VERSION then
    raise ELaya.CreateFmt('laya.dll API version %d, expected %d', [laya_api_version, LAYA_C_API_VERSION]);
  Dir := UTF8Encode(ModelDir);
  Opts := UTF8Encode(OptionsJson);
  FHandle := laya_create(PAnsiChar(Dir), PAnsiChar(Opts));
  if FHandle = nil then
    raise ELaya.Create('Cannot load Laya model: ' + FromUtf8(laya_last_error));
end;

destructor TLayaAgent.Destroy;
begin
  laya_destroy(FHandle);
  FHandle := nil;
  inherited;
end;

function TLayaAgent.TakeString(P: PAnsiChar): string;
begin
  if P = nil then raise ELaya.Create('laya.dll: out of memory');
  try
    Result := FromUtf8(P);
  finally
    laya_free_string(P);
  end;
end;

function TLayaAgent.TryPredict(const RequestJson: string): string;
var
  Req: UTF8String;
begin
  Req := UTF8Encode(RequestJson);
  Result := TakeString(laya_predict(FHandle, PAnsiChar(Req)));
end;

function TLayaAgent.Predict(const RequestJson: string): string;
begin
  Result := TryPredict(RequestJson);
  if Copy(Result, 1, 9) = '{"error":' then
    raise ELaya.Create(FromUtf8(laya_last_error));
end;

function TLayaAgent.Prepare(const RequestJson: string): string;
var
  Req: UTF8String;
begin
  Req := UTF8Encode(RequestJson);
  Result := TakeString(laya_prepare(FHandle, PAnsiChar(Req)));
  if Copy(Result, 1, 9) = '{"error":' then
    raise ELaya.Create(FromUtf8(laya_last_error));
end;

function TLayaAgent.Info: string;
begin
  Result := TakeString(laya_info(FHandle));
end;

function TLayaAgent.AskYesNo(const State, Instructions, Id: string): string;
begin
  Result := Predict(Question(State, Id, 'noul', Instructions, ''));
end;

function TLayaAgent.AskChoice(const State, Instructions: string; const Options: array of string;
  const Id: string): string;
begin
  Result := Predict(Question(State, Id, 'choice', Instructions, JsonArray(Options)));
end;

function TLayaAgent.AskScore(const State, Instructions: string; const Levels: array of string;
  const Id: string): string;
begin
  Result := Predict(Question(State, Id, 'score', Instructions, JsonArray(Levels)));
end;

end.
