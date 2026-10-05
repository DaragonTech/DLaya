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

  Loading: with Delphi 2010 or later on Windows the imports are delay-loaded, so laya.dll is
  loaded on the first call into it and not when the program starts. If the DLL, one of the DLLs
  it depends on, or one of its exports is missing, that first call raises ELaya, which you can
  catch and report; the program still starts. Everywhere else the imports are bound at startup.

  Also compiles with Free Pascal ({$MODE DELPHI}) against liblaya.so on Linux.

  With LibLayaX 1.0.15 or later the model may be one .tar file instead of a folder, and a
  codec may decode the stored weights while they are read. See LayaCodecSupported and
  LayaSetCodec below, and the README. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}

(* "delayed" is a Delphi-for-Windows directive (Delphi 2010 = CompilerVersion 21 and later);
   Free Pascal does not have it. The compiler flags it as platform-specific, which is expected
   here, so that warning is switched off for this unit. *)
{$IFNDEF FPC}{$IFDEF MSWINDOWS}{$IF CompilerVersion >= 21}
  {$DEFINE LAYA_DELAYED}
  {$WARN SYMBOL_PLATFORM OFF}
{$IFEND}{$ENDIF}{$ENDIF}

interface

uses
  {$IFDEF FPC}dynlibs,{$ELSE}{$IFDEF MSWINDOWS}Windows,{$ENDIF}{$ENDIF}
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

  (* A codec for the weights (LibLayaX 1.0.15 or later). The library hands it a block of the stored weight
    file and it must replace the block, in place, with the same block of the plain file.
      Path      the file on disk the block was read from, as a full UTF-8 path: the weight
                file itself for a model folder, the .tar file for a model in an archive. A
                codec that keeps a file of its own beside the model finds the folder from it
                (UTF8ToString(Path), then ExtractFilePath).
      FileName  the weight file's name without folders, 'model.safetensors', as UTF-8
      Offset    position of the first byte of Data, counted from the start of the weight
                file (not of an archive around it)
      Data      the block; Size bytes. The decoded block has the same size.
    Return 0 on success; any other value makes the load fail with that number in the message.
    It is called on the thread that creates the agent, several times per load, with blocks in
    any order. Only the weight file is passed to it, whether the model is a folder or a .tar. *)
  TLayaCodecProc = function(User: Pointer; Path, FileName: PAnsiChar; Offset: UInt64;
    Data: Pointer; Size: UInt64): Integer; cdecl;

(* ---- Raw imports (see laya_c.h for the full contract) ----
   Delay-loaded where LAYA_DELAYED is defined (see the top of the unit): the first call to any
   of these loads the library, and raises ELaya if it or the called export cannot be found. *)
function laya_version: PAnsiChar; cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
function laya_api_version: Integer; cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
procedure laya_set_log_callback(Fn: TLayaLogProc; User: Pointer; MinLevel: Integer); cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
function laya_create(ModelDirUtf8, OptionsJson: PAnsiChar): PLayaAgent; cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
function laya_predict(Agent: PLayaAgent; RequestJson: PAnsiChar): PAnsiChar; cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
function laya_prepare(Agent: PLayaAgent; RequestJson: PAnsiChar): PAnsiChar; cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
function laya_info(Agent: PLayaAgent): PAnsiChar; cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
procedure laya_free_string(S: PAnsiChar); cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
procedure laya_destroy(Agent: PLayaAgent); cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};
function laya_last_error: PAnsiChar; cdecl;
  external LayaLib {$IFDEF LAYA_DELAYED}delayed{$ENDIF};

type
  ELaya = class(Exception);

  (* Optional hook invoked after the native Laya library has been physically loaded,
     but before the first Laya API call. Useful for code that must inspect/patch imports
     of laya.dll and its dependencies (for example a VFS IAT hook refresh). *)
  TLayaLibraryLoadedProc = procedure;

  TLayaAgent = class
  private
    FHandle: PLayaAgent;
    function TakeString(P: PAnsiChar): string;
  public
    (* ModelDir: checkpoint folder (contains rl_agent_config.json), or a model store root plus
      "variant" in Options. Options JSON keys: backend (cpu|cuda|vulkan), variant, precision
      (fp32|fp16|bf16), flash, tensor_core, allow_truncation, threads, device (GPU index or
      part of its name, e.g. "RTX"; default = first discrete GPU). Raises ELaya on failure.
      With LibLayaX 1.0.15 or later, ModelDir may also be the path of an uncompressed .tar
      file that holds the model. *)
    constructor Create(const ModelDir: string; const OptionsJson: string = ''); overload;
    (* The same, calling AOnLibraryLoaded first (see TLayaLibraryLoadedProc). nil is allowed. *)
    constructor Create(const ModelDir, OptionsJson: string;
      AOnLibraryLoaded: TLayaLibraryLoadedProc); overload;
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
    (* A choice between exactly two options, as a Boolean: True if the model picked Options[0],
      False if it picked Options[1]. If the response names neither, DefaultOption decides: it
      must be one of the two options. Raises ELaya if the arguments are wrong (not two different
      options, or DefaultOption is not one of them) or the library reports an error. *)
    function AskChoiceB(const State, Instructions, DefaultOption: string;
      const Options: array of string; const Id: string = 'q'): Boolean;

    property Handle: PLayaAgent read FHandle;
  end;

(* JSON string literal (with quotes) for S. *)
function LayaQuote(const S: string): string;
function LayaVersion: string;

(* True when the loaded library accepts a model in a .tar file and codecs for the weights:
  LibLayaX 1.0.15 or later. Older libraries have neither. *)
function LayaCodecSupported: Boolean;

(* Sets the codec for every agent created afterwards; nil removes it. Raises ELaya when the
  library has no codec support (check LayaCodecSupported first).
  Both functions need the library in the process and load it when it is not there yet. With a
  TLayaLibraryLoadedProc hook, note that LayaSetCodec is a call into the library that comes
  before the hook of the agent you create afterwards; it only stores the two pointers. *)
procedure LayaSetCodec(Fn: TLayaCodecProc; User: Pointer = nil);

implementation

{$IFDEF LAYA_DELAYED}
(* Delay-load failures. Left to itself the RTL reports these with a generic exception that
   does not say what is missing. This hook turns a failure to load laya.dll, or to find one of its exports, into ELaya with a
   message that names the cause. The hook is process-wide, so failures of other delay-loaded
   DLLs are passed on to whichever hook was installed before this one. *)
var
  PrevDelayHook: TDelayedLoadHook = nil;

function LayaDelayFailure(dliNotify: dliNotification; pdli: PDelayLoadInfo): Pointer; stdcall;
var
  ProcName: string;
begin
  if (pdli <> nil) and (pdli.szDll <> nil) and
    SameText(string(AnsiString(pdli.szDll)), LayaLib) then
    case dliNotify of
      dliFailLoadLibrary:
        raise ELaya.CreateFmt(
          'Cannot load %s (Windows error %d: %s). Put %s and the DLLs it depends on next to the program.',
          [LayaLib, pdli.dwLastError, Trim(SysErrorMessage(pdli.dwLastError)), LayaLib]);
      dliFailGetProcAddress:
        begin
          if pdli.dlp.fImportByName then
            ProcName := string(AnsiString(pdli.dlp.szProcName))
          else
            ProcName := '#' + IntToStr(pdli.dlp.dwOrdinal);
          raise ELaya.CreateFmt(
            '%s does not export %s. It is probably an older build than this unit expects.',
            [LayaLib, ProcName]);
        end;
    end;
  if Assigned(PrevDelayHook) then
    Result := PrevDelayHook(dliNotify, pdli)
  else
    Result := nil;   (* nil = let the RTL raise its default exception *)
end;

procedure RemoveDelayHook;
var
  Current: TDelayedLoadHook;
begin
  Current := SetDliFailureHook2(PrevDelayHook);
  (* Someone installed a hook after ours: put theirs back. *)
  if @Current <> @LayaDelayFailure then SetDliFailureHook2(Current);
end;
{$ENDIF}

function FromUtf8(P: PAnsiChar): string;
begin
  if P = nil then Result := '' else Result := UTF8ToString(P);
end;

function LayaVersion: string;
begin
  Result := FromUtf8(laya_version);
end;

(* laya_set_codec is looked up at run time and not imported: most libraries do not export it.
  The lookup needs the library in the process; where the imports are delay-loaded and nothing
  has called into the library yet, it is loaded here and stays loaded. *)
type
  TLayaSetCodec = procedure(Fn: TLayaCodecProc; User: Pointer); cdecl;

(* The address of laya_set_codec, or nil. A plain pointer on purpose: with a result of a
  procedural type, Delphi reads "FindSetCodec" as the function itself and not as a call. *)
function FindSetCodec: Pointer;
{$IFDEF FPC}
var
  Lib: TLibHandle;
begin
  Result := nil;
  Lib := LoadLibrary(LayaLib);
  if Lib <> NilHandle then
    Result := GetProcedureAddress(Lib, 'laya_set_codec');
end;
{$ELSE}
var
  Lib: HMODULE;
begin
  Result := nil;
{$IFDEF MSWINDOWS}
  Lib := GetModuleHandle(PChar(LayaLib));
  if Lib = 0 then
{$ENDIF}
    Lib := LoadLibrary(PChar(LayaLib));
  if Lib <> 0 then
    Result := GetProcAddress(Lib, PChar('laya_set_codec'));
end;
{$ENDIF}

function LayaCodecSupported: Boolean;
begin
  Result := FindSetCodec <> nil;
end;

procedure LayaSetCodec(Fn: TLayaCodecProc; User: Pointer);
var
  Address: Pointer;
begin
  Address := FindSetCodec;
  if Address = nil then
    raise ELaya.Create('This Laya library has no codec support (laya_set_codec is missing: it is older than 1.0.15).');
  TLayaSetCodec(Address)(Fn, User);
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
      (* lowercase hex, the same spelling the library writes, so quoted text can be compared *)
      if Ord(C) < 32 then SB := SB + '\u' + LowerCase(IntToHex(Ord(C), 4))
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
begin
  Create(ModelDir, OptionsJson, nil);
end;

constructor TLayaAgent.Create(const ModelDir, OptionsJson: string;
  AOnLibraryLoaded: TLayaLibraryLoadedProc);
var
  Dir, Opts: UTF8String;
{$IFDEF LAYA_DELAYED}
  LayaModule: HMODULE;
  LoadedHere: Boolean;
{$ENDIF}
begin
  inherited Create;
  FHandle := nil;

{$IFDEF LAYA_DELAYED}
  (* With delayed imports, merely entering this unit does not load laya.dll.
     Force it into the process first so AOnLibraryLoaded can refresh/patch the
     IATs of laya.dll and the dependencies Windows loaded with it. *)
  LayaModule := GetModuleHandle(PChar(LayaLib));
  LoadedHere := LayaModule = 0;
  if LoadedHere then
  begin
    LayaModule := LoadLibrary(PChar(LayaLib));
    if LayaModule = 0 then
      raise ELaya.CreateFmt(
        'Cannot load %s (Windows error %d: %s). Put %s and the DLLs it depends on next to the program.',
        [LayaLib, GetLastError, Trim(SysErrorMessage(GetLastError)), LayaLib]);
  end;

  try
    if Assigned(AOnLibraryLoaded) then
      AOnLibraryLoaded;

    (* This is intentionally the first delayed-import call. Delphi now binds
       its delayed import while our explicit LoadLibrary reference is alive. *)
    if laya_api_version <> LAYA_C_API_VERSION then
      raise ELaya.CreateFmt('laya.dll API version %d, expected %d',
        [laya_api_version, LAYA_C_API_VERSION]);
  finally
    (* Once laya_api_version has resolved, Delphi's delay loader owns its normal
       module reference. Drop only the extra reference acquired above. *)
    if LoadedHere and (LayaModule <> 0) then
      FreeLibrary(LayaModule);
  end;
{$ELSE}
  if Assigned(AOnLibraryLoaded) then
    AOnLibraryLoaded;

  if laya_api_version <> LAYA_C_API_VERSION then
    raise ELaya.CreateFmt('laya.dll API version %d, expected %d',
      [laya_api_version, LAYA_C_API_VERSION]);
{$ENDIF}

  Dir := UTF8Encode(ModelDir);
  Opts := UTF8Encode(OptionsJson);
  FHandle := laya_create(PAnsiChar(Dir), PAnsiChar(Opts));
  if FHandle = nil then
    raise ELaya.Create('Cannot load Laya model: ' + FromUtf8(laya_last_error));
end;

destructor TLayaAgent.Destroy;
begin
  (* Destroy also runs when Create raised. If that was because the library could not be loaded,
     calling into it here would raise a second time, so only call it with a real handle. *)
  if FHandle <> nil then laya_destroy(FHandle);
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

function TLayaAgent.AskChoiceB(const State, Instructions, DefaultOption: string;
  const Options: array of string; const Id: string): Boolean;
var
  Response: string;
begin
  if (Length(Options) <> 2) or (Options[0] = Options[1]) then
    raise ELaya.Create('AskChoiceB needs exactly two different options');
  if (DefaultOption <> Options[0]) and (DefaultOption <> Options[1]) then
    raise ELaya.Create('AskChoiceB: DefaultOption must be one of the two options');
  Response := AskChoice(State, Instructions, Options, Id);
  (* The answer names the selected option: ..."answers":{"q":{...,"choice":"<option>",...}}
     Match on the name and not on a position; the name is what the library reports. *)
  if Pos('"choice":' + LayaQuote(Options[0]), Response) > 0 then
    Result := True
  else if Pos('"choice":' + LayaQuote(Options[1]), Response) > 0 then
    Result := False
  else
    Result := DefaultOption = Options[0];   (* no match: fall back to the default option *)
end;

function TLayaAgent.AskScore(const State, Instructions: string; const Levels: array of string;
  const Id: string): string;
begin
  Result := Predict(Question(State, Id, 'score', Instructions, JsonArray(Levels)));
end;

{$IFDEF LAYA_DELAYED}
initialization
  PrevDelayHook := SetDliFailureHook2(LayaDelayFailure);

finalization
  RemoveDelayHook;
{$ENDIF}

end.
