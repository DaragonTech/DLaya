program LayaTestsEx;

(* Console test for two things LibLayaX can do from 1.0.15 on: load a model from one .tar file,
  and decode the stored weights through a codec. The everyday test and demo program is
  LayaTests; this one is for those who use either of the two.

    LayaTestsEx.exe [MODEL] [BACKEND]

  MODEL is a model folder or a .tar file of one. Without it only the checks that need no model
  run. With a library older than 1.0.15 the program says so and stops.
  Exit code 0 = all passed, 1 = a check failed, 2 = the library is too old.

  The codec used here is the one in LayaCodecExample.pas, which leaves the data as it is, so
  MODEL is an ordinary, plain model. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Laya, LayaArchive, LayaCodecExample;

var
  Checks, Failures: Integer;

procedure Check(Cond: Boolean; const What: string);
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failures);
    Writeln('FAIL: ', What);
  end;
end;

function Contains(const Text, Sub: string): Boolean;
begin
  Result := Pos(Sub, Text) > 0;
end;

procedure ExpectLoadFailure(const Model, Options, Needle: string);
var
  A: TLayaAgent;
begin
  try
    A := TLayaAgent.Create(Model, Options);
    A.Free;
    Check(False, 'expected load failure: ' + Needle);
  except
    on E: ELaya do Check(Contains(E.Message, Needle), 'load error "' + E.Message + '" lacks "' + Needle + '"');
  end;
end;

(* The answers of a response without the timing, which differs from run to run. *)
function ResultsOf(const Json: string): string;
var
  P: Integer;
begin
  P := Pos(',"elapsed_ms":', Json);
  if P > 0 then Result := Copy(Json, 1, P - 1) else Result := Json;
end;

function SizeOfFile(const FileName: string): Int64;
var
  Handle: THandle;
begin
  Result := -1;
  Handle := FileOpen(FileName, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then Exit;
  try
    Result := FileSeek(Handle, Int64(0), 2);
  finally
    FileClose(Handle);
  end;
end;

(* The size of the weight file of a model, in a folder or in an archive. *)
function WeightFileSize(const Model: string): Int64;
var
  Archive: TLayaArchive;
  Offset: Int64;
begin
  Result := -1;
  if LayaIsArchiveFile(Model) then
  begin
    Archive := TLayaArchive.Create(Model);
    try
      if not Archive.Find('model.safetensors', Offset, Result) then Result := -1;
    finally
      Archive.Free;
    end;
  end
  else
    Result := SizeOfFile(IncludeTrailingPathDelimiter(Model) + 'model.safetensors');
end;

(* Checks that need no model: what the library answers to wrong input. *)
procedure ModelFreeTests;
begin
  (* a file that is not an archive: this program itself *)
  ExpectLoadFailure(ParamStr(0), '', 'not a folder and not an uncompressed tar archive');
end;

procedure ModelTests(const Model, Backend: string);
var
  A: TLayaAgent;
  Options, Plain, Coded: string;
  Seen: TLayaExampleCodecState;
  Expected: Int64;
begin
  Options := '{"backend":"' + Backend + '"}';
  if LayaIsArchiveFile(Model) then
    Writeln('model: a .tar file, ', Model)
  else
    Writeln('model: a folder, ', Model);

  (* without a codec *)
  A := TLayaAgent.Create(Model, Options);
  try
    Writeln('info: ', A.Info);
    Plain := A.AskYesNo('Please refund the duplicate charge.', 'Does the customer ask for a refund?', 'refund');
    Writeln('yes/no: ', Plain);
    Check(Contains(Plain, '"noul":'), 'answer without a codec');
  finally
    A.Free;
  end;

  (* through the example codec, which leaves the data as it is: the answer must be the same *)
  LayaExampleCodecInstall;
  try
    A := TLayaAgent.Create(Model, Options);
    try
      Coded := A.AskYesNo('Please refund the duplicate charge.', 'Does the customer ask for a refund?', 'refund');
      Check(ResultsOf(Coded) = ResultsOf(Plain), 'the answer through a codec differs');
    finally
      A.Free;
    end;
    Seen := LayaExampleCodecState;
    Writeln('codec: ', Seen.Calls, ' calls, ', Seen.Bytes, ' bytes, read from ', Seen.Path);
    Check((Seen.Calls > 0) and Seen.Consistent and (Seen.FileName = 'model.safetensors'),
      'the codec was not called as documented');
    (* the path is the file on disk: the archive, or the weight file in the model folder *)
    Check(FileExists(Seen.Path) and DirectoryExists(Seen.ModelFolder) and
      (SameText(ExtractFileName(Seen.Path), 'model.safetensors') or SameText(Seen.Path, ExpandFileName(Model))),
      'the path given to the codec: ' + Seen.Path);
    (* every byte of the weight file went through the codec, and nothing else did *)
    Expected := WeightFileSize(Model);
    Check((Expected > 0) and (Seen.Bytes = UInt64(Expected)),
      'the codec saw ' + IntToStr(Seen.Bytes) + ' bytes, the weight file has ' + IntToStr(Expected));

    (* a codec that reports an error stops the load, with its number in the message *)
    LayaSetCodec(LayaExampleRefuse);
    ExpectLoadFailure(Model, Options, 'The codec reported error 5');
  finally
    LayaExampleCodecRemove;
  end;

  (* and without the codec the model loads again *)
  A := TLayaAgent.Create(Model, Options);
  try
    Check(ResultsOf(A.AskYesNo('Please refund the duplicate charge.', 'Does the customer ask for a refund?', 'refund')) =
      ResultsOf(Plain), 'the answer after the codec was removed differs');
  finally
    A.Free;
  end;
end;

begin
  Checks := 0;
  Failures := 0;
  try
    Writeln('library: ', LayaVersion);
    if not LayaCodecSupported then
    begin
      Writeln('This library is older than LibLayaX 1.0.15: it loads a model from a folder only and has');
      Writeln('no codecs. There is nothing to test here; LayaTests is the program for this library.');
      Halt(2);
    end;
    ModelFreeTests;
    if ParamCount >= 1 then
    begin
      if ParamCount >= 2 then ModelTests(ParamStr(1), ParamStr(2))
      else ModelTests(ParamStr(1), 'cpu');
    end
    else
      Writeln('(model tests skipped: pass a model folder or a .tar file)');
  except
    on E: Exception do
    begin
      Inc(Failures);
      Writeln('EXCEPTION ', E.ClassName, ': ', E.Message);
    end;
  end;
  Writeln(Checks, ' checks, ', Failures, ' failures');
  if Failures > 0 then Halt(1);
end.
