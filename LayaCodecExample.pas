unit LayaCodecExample;

(* A codec for the weights, in a unit of its own: the frame of one, without a transform.

  A codec is a function the library calls for every block of the weight file it reads
  (see the README). This unit shows everything around that function: its
  signature, how it is given to the library, what it is told about the model, and where the
  work of a real codec goes. The example leaves the data as it is, so it works with any plain
  model, and it records what the library passed to it. LayaTestsEx.dpr uses it.

  To make a codec of your own, copy this unit and put your transform at the place marked in
  LayaExampleDecode.

    LayaExampleCodecInstall;
    try
      Agent := TLayaAgent.Create('C:\models\laya.tar');
    finally
      LayaExampleCodecRemove;   // the codec is only used while a model loads
    end;

  Delphi and Free Pascal ({$MODE DELPHIUNICODE}). Needs Laya.pas and LibLayaX 1.0.15 or later
  (LayaCodecSupported tells). *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  SysUtils, Laya;

type
  (* What the example codec saw during the last load. *)
  TLayaExampleCodecState = record
    Calls: Integer;         (* how many blocks the library passed *)
    Bytes: UInt64;          (* their sizes added up: the size of the weight file *)
    Path: string;           (* the file on disk the blocks came from: the weight file, or the .tar *)
    ModelFolder: string;    (* the folder of that file, with the trailing delimiter *)
    FileName: string;       (* the weight file's name without folders *)
    Consistent: Boolean;    (* every call had the same user pointer, path and file name *)
  end;
  PLayaExampleCodecState = ^TLayaExampleCodecState;

(* The codec function. Its signature is TLayaCodecProc of Laya.pas. *)
function LayaExampleDecode(User: Pointer; Path, FileName: PAnsiChar; Offset: UInt64;
  Data: Pointer; Size: UInt64): Integer; cdecl;

(* A codec that reports error 5 for every block: loading a model then fails with
  "The codec reported error 5 for model.safetensors". For tests. *)
function LayaExampleRefuse(User: Pointer; Path, FileName: PAnsiChar; Offset: UInt64;
  Data: Pointer; Size: UInt64): Integer; cdecl;

(* Gives LayaExampleDecode to the library for the agents created afterwards and clears the
  record of the last load. Raises ELaya when the library has no codec support. *)
procedure LayaExampleCodecInstall;
(* Takes the codec away again. *)
procedure LayaExampleCodecRemove;

(* What LayaExampleDecode saw since the last LayaExampleCodecInstall. *)
function LayaExampleCodecState: TLayaExampleCodecState;

implementation

var
  State: TLayaExampleCodecState;

(* Runs once per load, on the first block. Path is the same for every block of a load, so
  anything a codec needs from the model's folder is found here and kept for the calls that
  follow: a codec that has a file of its own beside the model would open it at this point. *)
procedure FirstBlock(Target: PLayaExampleCodecState; Path, FileName: PAnsiChar);
begin
  Target^.Path := UTF8ToString(Path);
  Target^.ModelFolder := ExtractFilePath(Target^.Path);
  Target^.FileName := UTF8ToString(FileName);
end;

function LayaExampleDecode(User: Pointer; Path, FileName: PAnsiChar; Offset: UInt64;
  Data: Pointer; Size: UInt64): Integer; cdecl;
var
  Target: PLayaExampleCodecState;
begin
  (* The library is not written in Pascal: no exception may leave this function. Report a
    failure with a number instead; the load then stops and names that number. *)
  try
    Target := PLayaExampleCodecState(User);
    if (Target = nil) or (Data = nil) then
    begin
      Result := 1;
      Exit;
    end;
    if Target^.Calls = 0 then
      FirstBlock(Target, Path, FileName)
    else if (UTF8ToString(Path) <> Target^.Path) or (UTF8ToString(FileName) <> Target^.FileName) then
      Target^.Consistent := False;
    Inc(Target^.Calls);
    Inc(Target^.Bytes, Size);

    (* ---- the transform goes here ----
      Data points to Size bytes of the stored weight file, beginning at position Offset of that
      file. Replace them, in place, with the same bytes of the plain file. The plain data has
      the same length, and each block must be decodable from Offset alone: the library asks
      for blocks in any order.
      This example does nothing here, so the stored file is the plain file. *)

    Result := 0;
  except
    Result := 2;
  end;
end;

function LayaExampleRefuse(User: Pointer; Path, FileName: PAnsiChar; Offset: UInt64;
  Data: Pointer; Size: UInt64): Integer; cdecl;
begin
  Result := 5;
end;

procedure LayaExampleCodecInstall;
begin
  State.Calls := 0;
  State.Bytes := 0;
  State.Path := '';
  State.ModelFolder := '';
  State.FileName := '';
  State.Consistent := True;
  (* the second argument comes back as User in every call *)
  LayaSetCodec(LayaExampleDecode, @State);
end;

procedure LayaExampleCodecRemove;
begin
  LayaSetCodec(nil);
end;

function LayaExampleCodecState: TLayaExampleCodecState;
begin
  Result := State;
end;

end.
