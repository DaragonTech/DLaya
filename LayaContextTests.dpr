program LayaContextTests;

(* Compares LayaContext.pas with the engine itself. Needs Laya.pas, the LibLayaX library and
  a model.

    LayaContextTests MODEL_DIR [COUNT] [BACKEND]

  COUNT questions (default 1000) of every kind and size are made up, some of them too long on
  purpose. For each one the unit's answer is compared with what the library prepares for the
  same request: the token ids must be identical, and where the library refuses the request,
  the unit must give the same message. The same is done with a model loaded with
  "allow_truncation":true. Three real questions are then asked, and the usage.input_tokens of
  each answer must be the unit's PromptTokens. Exit code 0 = all passed. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}
{$APPTYPE CONSOLE}
{$Q-}{$R-}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Laya, LayaUnicode, LayaTokenizer, LayaContext;

var
  Checks, Failures: Integer;
  Seed: UInt64 = 20261003;

procedure Check(Cond: Boolean; const What: string);
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failures);
    if Failures <= 10 then
      Writeln('FAIL: ', What);
  end;
end;

(* The same numbers with every compiler. *)
function Rnd(N: Integer): Integer;
begin
  Seed := (Seed * 6364136223846793005 + 1442695040888963407);
  Result := Integer((Seed shr 33) mod UInt64(N));
end;

const
  Words: array[0..47] of string = (
    'the', 'customer', 'refund', 'please', 'order', 'I''m', 'don''t', 'we''ve', 'invoice', 'twice',
    'charged', 'subscription', 'cancel', 'URGENT', 'thanks', '2024', '3.14', '#4711', 'e-mail',
    'user@example.com', 'https://example.com/a?b=c', '(see', 'below)', '...', '!!!', '?',
    'caf'#$00E9, 'na'#$00EF've', 'stra'#$00DF'e', #$00C5'ngstr'#$00F6'm', 'e'#$0301't'#$0065#$0301,
    #$65E5#$672C#$8A9E, #$4E2D#$6587, #$D55C#$AD6D#$C5B4, #$0440#$0443#$0441#$0441#$043A#$0438#$0439,
    #$0627#$0644#$0639#$0631#$0628#$064A#$0629, #$D83D#$DE00, #$20AC'100', #$00BD, #$2167,
    'antidisestablishmentarianism', 'x', 'a', 'Z', '[MASK]', '[SEP]', '[CLS]', '<|endoftext|>');
  Gaps: array[0..9] of string = (' ', ' ', ' ', ' ', ' ', ' ', '  ', #10, '    ', #9);

function MakeText(WordCount: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to WordCount do
  begin
    if I > 1 then
      Result := Result + Gaps[Rnd(Length(Gaps))];
    Result := Result + Words[Rnd(Length(Words))];
  end;
end;

(* The request the settings describe, as JSON. *)
function BuildRequest(const S: TLayaContextBudgetSettings): string;
var
  I: Integer;
  Described: Boolean;
begin
  Result := '{"state":' + LayaQuote(S.State) + ',"questions":{' + LayaQuote(S.QuestionId) + ':{"type":"';
  case S.QuestionType of
    lqtChoice: Result := Result + 'choice';
    lqtScore: Result := Result + 'score';
  else
    Result := Result + 'noul';
  end;
  Result := Result + '","instructions":' + LayaQuote(S.Instructions);
  case S.QuestionType of
    lqtChoice:
      begin
        Described := Length(S.Descriptions) > 0;
        if Described then Result := Result + ',"criteria":{' else Result := Result + ',"criteria":[';
        for I := 0 to High(S.Criteria) do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + LayaQuote(S.Criteria[I]);
          if Described then
          begin
            if (I <= High(S.Descriptions)) and (S.Descriptions[I] <> '') then
              Result := Result + ':' + LayaQuote(S.Descriptions[I])
            else
              Result := Result + ':null';
          end;
        end;
        if Described then Result := Result + '}' else Result := Result + ']';
      end;
    lqtScore:
      begin
        Result := Result + ',"criteria":[';
        for I := 0 to High(S.Criteria) do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + LayaQuote(S.Criteria[I]);
        end;
        Result := Result + ']';
      end;
  else
    if (S.TrueMeaning <> '') or (S.FalseMeaning <> '') then
    begin
      Result := Result + ',"criteria":{"true":' + LayaQuote(S.TrueMeaning) + ',"false":' +
        LayaQuote(S.FalseMeaning) + '}';
    end;
  end;
  Result := Result + '}}}';
end;

(* The numbers of the "ids" list in what Prepare returns. *)
function ParseIds(const Json: string): TLayaTokenIds;
var
  P, N, V: Integer;
  Have: Boolean;
begin
  Result := nil;
  P := Pos('"ids":[', Json);
  if P = 0 then Exit;
  Inc(P, 7);
  N := 0;
  V := 0;
  Have := False;
  while (P <= Length(Json)) do
  begin
    if (Json[P] >= '0') and (Json[P] <= '9') then
    begin
      V := V * 10 + Ord(Json[P]) - Ord('0');
      Have := True;
    end
    else
    begin
      if Have then
      begin
        if N = Length(Result) then SetLength(Result, N * 2 + 64);
        Result[N] := V;
        Inc(N);
        V := 0;
        Have := False;
      end;
      if Json[P] = ']' then Break;
    end;
    Inc(P);
  end;
  SetLength(Result, N);
end;

function SameIds(const A, B: TLayaTokenIds): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if Result then
    for I := 0 to High(A) do
      if A[I] <> B[I] then
      begin
        Result := False;
        Exit;
      end;
end;

var
  Fitting, Refused: Integer;
  ByStatus: array[TLayaContextBudgetStatus] of Integer;

procedure Compare(Agent: TLayaAgent; Tokenizer: TLayaTokenizer; const S: TLayaContextBudgetSettings;
  const Name: string);
var
  B: TLayaContextBudget;
  Request, Answer, Error: string;
  Ids: TLayaTokenIds;
begin
  B := LayaGetContextBudget(Tokenizer, S);
  Inc(ByStatus[B.Status]);
  Request := BuildRequest(S);
  Error := '';
  Ids := nil;
  try
    Answer := Agent.Prepare(Request);
    Ids := ParseIds(Answer);
  except
    on E: ELaya do Error := E.Message;
  end;
  if Error = '' then
  begin
    Inc(Fitting);
    Check(B.Fits, Name + ': the library accepts it, the unit says ' + B.Message);
    if B.Fits then
    begin
      Check(SameIds(B.Ids, Ids), Name + ': the token ids differ (' + IntToStr(Length(B.Ids)) + ' and ' +
        IntToStr(Length(Ids)) + ')');
      Check(B.PromptTokens = Length(Ids), Name + ': PromptTokens');
    end;
  end
  else
  begin
    Inc(Refused);
    Check(not B.Fits, Name + ': the library refuses it (' + Error + '), the unit says it fits');
    Check(B.Message = Error, Name + ': message "' + B.Message + '", library "' + Error + '"');
  end;
end;

function RandomQuestion: TLayaContextBudgetSettings;
var
  I, N, Kind: Integer;
  Options: array of string;
  Tiny: Boolean;
begin
  Options := nil;
  Kind := Rnd(3);
  Tiny := False;
  (* how many options: mostly a few, sometimes very many, now and then too few *)
  case Rnd(20) of
    0: N := 1;
    1: N := 20 + Rnd(60);
    2: N := 150 + Rnd(120);
    3: N := 0;
    4:
      begin
        (* very many options of one token each: the head overflows without any option being long *)
        N := 60 + Rnd(90);
        Tiny := True;
      end;
  else
    N := 2 + Rnd(6);
  end;
  SetLength(Options, N);
  for I := 0 to N - 1 do
  begin
    (* numbered, so that no two options of a question are the same text *)
    if Tiny then
    begin
      Options[I] := IntToStr(I);
      Continue;
    end;
    Options[I] := IntToStr(I) + ' ' + MakeText(1 + Rnd(3));
    if Rnd(25) = 0 then
      Options[I] := Options[I] + ' ' + MakeText(20 + Rnd(50));
  end;
  case Kind of
    0: Result := LayaYesNoQuestion('', '');
    1: Result := LayaChoiceQuestion('', '', Options);
  else
    Result := LayaScoreQuestion('', '', Options);
  end;
  if (Kind = 1) and (Rnd(3) = 0) and not Tiny then
  begin
    SetLength(Result.Descriptions, N);
    for I := 0 to N - 1 do
      if Rnd(4) > 0 then
        Result.Descriptions[I] := MakeText(1 + Rnd(8));
  end;
  if (Kind = 0) and (Rnd(3) = 0) then
  begin
    Result.TrueMeaning := MakeText(1 + Rnd(12));
    if Rnd(2) = 0 then
      Result.FalseMeaning := MakeText(1 + Rnd(12));
    if Rnd(15) = 0 then
      Result.TrueMeaning := MakeText(60 + Rnd(40));
  end;
  case Rnd(12) of
    0: Result.Instructions := MakeText(60 + Rnd(200));
    1: Result.Instructions := '';
  else
    Result.Instructions := MakeText(2 + Rnd(14));
  end;
  case Rnd(6) of
    0: Result.State := MakeText(200 + Rnd(500));
    1: Result.State := '';
  else
    Result.State := MakeText(1 + Rnd(120));
  end;
  Result.QuestionId := 'q' + IntToStr(Rnd(100));
end;

procedure RandomTests(Agent: TLayaAgent; Tokenizer: TLayaTokenizer; Count: Integer; Truncation: Boolean);
var
  I, K, Room: Integer;
  S: TLayaContextBudgetSettings;
  B: TLayaContextBudget;
  Status: TLayaContextBudgetStatus;
begin
  Fitting := 0;
  Refused := 0;
  for Status := Low(Status) to High(Status) do
    ByStatus[Status] := 0;
  for I := 1 to Count do
  begin
    S := RandomQuestion;
    S.AllowTruncation := Truncation;
    Compare(Agent, Tokenizer, S, 'question ' + IntToStr(I));
    (* now and then: a text of exactly the size that still fits, and one token more *)
    if I mod 10 = 0 then
    begin
      S.State := '';
      B := LayaGetContextBudget(Tokenizer, S);
      Room := B.AvailableStateTokens;
      if Room > 0 then
      begin
        S.State := 'a';
        for K := 2 to Room do
          S.State := S.State + ' a';
        Check(LayaCountTextTokens(Tokenizer, S.State) = Room, 'a text of ' + IntToStr(Room) + ' tokens');
        Compare(Agent, Tokenizer, S, 'question ' + IntToStr(I) + ', text that just fits');
        S.State := S.State + ' a';
        Compare(Agent, Tokenizer, S, 'question ' + IntToStr(I) + ', text one token too long');
      end;
    end;
  end;
  if Truncation then Write('with truncation: ') else Write('without truncation: ');
  Writeln(Fitting, ' accepted and ', Refused, ' refused by the library, all compared');
  for Status := Low(Status) to High(Status) do
    if ByStatus[Status] > 0 then
      Writeln('  ', ByStatus[Status], ' x ', LayaBudgetStatusToString(Status));
end;

function InputTokens(const Json: string): Integer;
var
  P: Integer;
begin
  Result := -1;
  P := Pos('"input_tokens":', Json);
  if P = 0 then Exit;
  Inc(P, 15);
  Result := 0;
  while (P <= Length(Json)) and (Json[P] >= '0') and (Json[P] <= '9') do
  begin
    Result := Result * 10 + Ord(Json[P]) - Ord('0');
    Inc(P);
  end;
end;

procedure Run(const Dir: string; Count: Integer; const Backend: string);
var
  Tokenizer: TLayaTokenizer;
  Agent: TLayaAgent;
  B: TLayaContextBudget;
  Info: string;
begin
  Tokenizer := TLayaTokenizer.Create;
  try
    Tokenizer.LoadFromModelDir(Dir);
    Writeln('tokenizer: ', Tokenizer.VocabSize, ' entries, limits ', Tokenizer.MaxLen, ' and ',
      Tokenizer.HeadMaxLen);

    Agent := TLayaAgent.Create(Dir, '{"backend":"' + Backend + '"}');
    try
      Info := Agent.Info;
      Check(Pos('"max_len":' + IntToStr(Tokenizer.MaxLen) + ',', Info) > 0, 'max_len: ' + Info);
      Check(Pos('"head_max_len":' + IntToStr(Tokenizer.HeadMaxLen) + '}', Info) > 0, 'head_max_len: ' + Info);
      RandomTests(Agent, Tokenizer, Count, False);

      (* real answers: usage.input_tokens is PromptTokens *)
      B := LayaGetContextBudget(Tokenizer, LayaYesNoQuestion('Please refund the duplicate charge.',
        'Does the customer ask for a refund?'));
      Check(InputTokens(Agent.AskYesNo('Please refund the duplicate charge.',
        'Does the customer ask for a refund?')) = B.PromptTokens, 'input_tokens of the yes/no answer');
      B := LayaGetContextBudget(Tokenizer, LayaChoiceQuestion('I want to cancel my subscription.',
        'What does the customer want?', ['cancel', 'upgrade', 'refund']));
      Check(InputTokens(Agent.AskChoice('I want to cancel my subscription.',
        'What does the customer want?', ['cancel', 'upgrade', 'refund'])) = B.PromptTokens,
        'input_tokens of the choice answer');
      B := LayaGetContextBudget(Tokenizer, LayaScoreQuestion('This is the third time I am writing!!!',
        'How angry is the customer?', ['calm', 'annoyed', 'furious']));
      Check(InputTokens(Agent.AskScore('This is the third time I am writing!!!',
        'How angry is the customer?', ['calm', 'annoyed', 'furious'])) = B.PromptTokens,
        'input_tokens of the score answer');
      Writeln('input_tokens of three real answers compared');
    finally
      Agent.Free;
    end;

    Agent := TLayaAgent.Create(Dir, '{"backend":"' + Backend + '","allow_truncation":true}');
    try
      RandomTests(Agent, Tokenizer, Count, True);
    finally
      Agent.Free;
    end;
  finally
    Tokenizer.Free;
  end;
end;

var
  Count: Integer;
  Backend: string;
begin
  Checks := 0;
  Failures := 0;
  try
    if ParamCount < 1 then
    begin
      Writeln('usage: LayaContextTests MODEL_DIR [COUNT] [BACKEND]');
      Halt(2);
    end;
    Writeln('library: ', LayaVersion);
    Count := 1000;
    if ParamCount >= 2 then Count := StrToIntDef(ParamStr(2), 1000);
    Backend := 'cpu';
    if ParamCount >= 3 then Backend := ParamStr(3);
    Run(ParamStr(1), Count, Backend);
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
