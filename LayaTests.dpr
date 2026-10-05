program LayaTests;

(* Console test/demo for Laya.pas. Usage:  LayaTests.exe [MODEL_DIR] [BACKEND]
  Without MODEL_DIR only the model-free checks run. Exit code 0 = all passed.
  Models in a .tar file and codecs for the weights have a test program of their own,
  LayaTestsEx. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes, Laya;

var
  Checks, Failures: Integer;
  MxcsrBefore: UInt32;

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

procedure ExpectLoadFailure(const Dir, Options, Needle: string);
var
  A: TLayaAgent;
begin
  try
    A := TLayaAgent.Create(Dir, Options);
    A.Free;
    Check(False, 'expected load failure for ' + Options);
  except
    on E: ELaya do Check(Contains(E.Message, Needle), 'load error "' + E.Message + '" lacks "' + Needle + '"');
  end;
end;

type
  TWorker = class(TThread)
  public
    Agent: TLayaAgent;
    Expected: string;
    Mismatches: Integer;
    procedure Execute; override;
  end;

function ResultsOf(const Json: string): string;
var
  P: Integer;
begin
  P := Pos(',"elapsed_ms":', Json);
  if P > 0 then Result := Copy(Json, 1, P - 1) else Result := Json;
end;

procedure TWorker.Execute;
var
  I: Integer;
begin
  for I := 1 to 2 do
    if ResultsOf(Agent.AskYesNo('Café — I want my money back', 'Does the customer ask for a refund?')) <> Expected then
      Inc(Mismatches);
end;

var
  LoadedHookCalls: Integer;

procedure LoadedHook;
begin
  Inc(LoadedHookCalls);
end;

procedure ExpectChoiceBError(A: TLayaAgent; const DefaultOption: string; const Options: array of string;
  const Needle: string);
begin
  try
    A.AskChoiceB('x', 'Which?', DefaultOption, Options);
    Check(False, 'AskChoiceB should raise: ' + Needle);
  except
    on E: ELaya do Check(Contains(E.Message, Needle), 'AskChoiceB error "' + E.Message + '" lacks "' + Needle + '"');
  end;
end;

procedure ModelTests(const Dir, Backend: string);
var
  A: TLayaAgent;
  S, Ref: string;
  W: array[0..2] of TWorker;
  I, Bad: Integer;
begin
  LoadedHookCalls := 0;
  A := TLayaAgent.Create(Dir, '{"backend":"' + Backend + '"}', LoadedHook);
  try
    Check(LoadedHookCalls = 1, 'the library-loaded hook runs once per Create');
    S := A.Info;
    Writeln('info: ', S);
    Check(Contains(S, '"max_len":'), 'info');

    S := A.AskYesNo('Please refund the duplicate charge.', 'Does the customer ask for a refund?', 'refund');
    Writeln('yes/no: ', S);
    Check(Contains(S, '"noul":'), 'yes/no answer');

    S := A.AskChoice('I want to cancel my subscription.', 'What does the customer want?',
      ['cancel', 'upgrade', 'refund'], 'intent');
    Writeln('choice: ', S);
    Check(Contains(S, '"choice":') and Contains(S, '"cancel":'), 'choice answer');

    (* AskChoiceB is AskChoice with two options, read as a Boolean *)
    S := A.AskChoice('I want to cancel my subscription.', 'What does the customer want?', ['cancel', 'refund']);
    Check(A.AskChoiceB('I want to cancel my subscription.', 'What does the customer want?', 'refund',
      ['cancel', 'refund']) = Contains(S, '"choice":"cancel"'), 'AskChoiceB, first option');
    S := A.AskChoice('I want to cancel my subscription.', 'What does the customer want?', ['a "quoted" one', 'tab'#9'and'#1'more']);
    Check(A.AskChoiceB('I want to cancel my subscription.', 'What does the customer want?', 'a "quoted" one',
      ['a "quoted" one', 'tab'#9'and'#1'more']) = Contains(S, '"choice":"a \"quoted\" one"'), 'AskChoiceB, options that need escaping');
    Check(Contains(S, '"choice":' + LayaQuote('a "quoted" one')) or Contains(S, '"choice":' + LayaQuote('tab'#9'and'#1'more')),
      'the library writes an option the way LayaQuote does: ' + S);
    ExpectChoiceBError(A, 'a', ['a', 'b', 'c'], 'exactly two different options');
    ExpectChoiceBError(A, 'a', ['a', 'a'], 'exactly two different options');
    ExpectChoiceBError(A, 'c', ['a', 'b'], 'DefaultOption must be one of the two options');

    S := A.AskScore('This is the third time I am writing!!!', 'How angry is the customer?',
      ['calm', 'annoyed', 'furious'], 'anger');
    Writeln('score: ', S);
    Check(Contains(S, '"score":') and Contains(S, '"legend":'), 'score answer');

    S := A.AskYesNo('Quotes " backslash \ tab'#9'newline'#10'and ünïcödé 日本語', 'Is it odd "text"?');
    Check(Contains(S, '"noul":'), 'escaping and UTF-8: ' + S);

    S := A.TryPredict('{"state":"x","questions":{"a":{"type":"essay","instructions":"x"}}}');
    Check(Contains(S, 'Unsupported question type'), 'TryPredict error JSON: ' + S);
    try
      A.Predict('{broken');
      Check(False, 'Predict should raise');
    except
      on E: ELaya do Check(E.Message <> '', 'Predict raised ELaya');
    end;

    Check(Contains(A.Prepare('{"state":"x","questions":{"a":{"type":"noul","instructions":"y"}}}'), '"ids":'), 'prepare');

    (* three Delphi threads share the agent *)
    Ref := ResultsOf(A.AskYesNo('Café — I want my money back', 'Does the customer ask for a refund?'));
    for I := 0 to High(W) do
    begin
      W[I] := TWorker.Create(True);
      W[I].Agent := A;
      W[I].Expected := Ref;
      W[I].Start;
    end;
    Bad := 0;
    for I := 0 to High(W) do
    begin
      W[I].WaitFor;
      Inc(Bad, W[I].Mismatches);
      W[I].Free;
    end;
    Check(Bad = 0, IntToStr(Bad) + ' threaded results differed');
  finally
    A.Free;
  end;
end;

begin
  Checks := 0;
  Failures := 0;
  try
    Writeln('library: ', LayaVersion);
    Check(laya_api_version = LAYA_C_API_VERSION, 'api version');
    ExpectLoadFailure('C:\no\such\model', '', 'rl_agent_config.json');
    ExpectLoadFailure('C:\no\such\model', '{"backend":"tpu"}', 'Unknown backend');
    ExpectLoadFailure('C:\no\such\model', '{"nope":1}', 'Unknown option');
    Check(LayaQuote('a"b\c'#10) = '"a\"b\\c\n"', 'LayaQuote');
    Check(LayaQuote(#1#31) = '"\u0001\u001f"', 'LayaQuote writes control characters in lowercase hex');
    if ParamCount >= 1 then
    begin
{$IF Defined(CPUX64) or Defined(CPUX86_64)}
      MxcsrBefore := GetMXCSR;
{$IFEND}
      if ParamCount >= 2 then ModelTests(ParamStr(1), ParamStr(2))
      else ModelTests(ParamStr(1), 'cpu');
      (* The DLL masks FP exceptions while it works and must hand back the host's settings. *)
{$IF Defined(CPUX64) or Defined(CPUX86_64)}
      Writeln('MXCSR: $', IntToHex(MxcsrBefore, 4), ' -> $', IntToHex(GetMXCSR, 4));
      Check((GetMXCSR and not $3F) = (MxcsrBefore and not $3F), 'host MXCSR (FP exception masks) changed');
{$IFEND}
    end
    else
      Writeln('(model tests skipped: pass MODEL_DIR)');
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
