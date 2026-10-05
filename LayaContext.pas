unit LayaContext;

(* Does a question fit? Counts the tokens of one Laya question the way the engine inside
  LibLayaX does, before the model is called.

    Tokenizer := TLayaTokenizer.Create;
    Tokenizer.LoadFromModelDir('C:\models\laya');

    Budget := LayaGetContextBudget(Tokenizer,
      LayaYesNoQuestion(CustomerMessage, 'Does the customer ask for a refund?'));

    if Budget.Fits then
      Answer := Agent.AskYesNo(CustomerMessage, 'Does the customer ask for a refund?')
    else
      Writeln(LayaBudgetStatusToString(Budget.Status), ': the text has ', Budget.StateTokens,
        ' tokens, there is room for ', Budget.AvailableStateTokens);

  What the model reads for one question is one sequence of at most MaxLen tokens:

    [CLS] <type> question: <instructions> [SEP]
          [MASK] <option> [MASK] <option> ... [SEP]
          <the text> [SEP]

  The part before the text, the "head", may take HeadMaxLen tokens, and one option 48. The
  text gets what is left. MaxLen and HeadMaxLen come from the model: 512 and 192 for the
  English one, 1024 and 256 for the multilingual one. A request with several questions makes
  one such sequence per question, each with the whole text, so check each question on its
  own.

  The numbers match the engine: PromptTokens is what the answer reports as
  usage.input_tokens, and Budget.Message is the error the library would return.

  Needs LayaTokenizer.pas and LayaUnicode.pas. Delphi and Free Pascal.

  The rules are those of the request preparation of laya.cpp (src/protocol.cpp), the engine
  inside LibLayaX: Copyright (c) 2026 Lars Karlslund, MIT License. See NOTICE. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}
{$IFNDEF FPC}{$IF CompilerVersion >= 24}{$ZEROBASEDSTRINGS OFF}{$IFEND}{$ENDIF}
{$Q-}{$R-}

interface

uses
  SysUtils, LayaUnicode, LayaTokenizer;

const
  LayaMaxOptionTokens = 48;   (* one option, not counting its [MASK] *)
  LayaMinOptions = 2;
  LayaMaxOptions = 255;

type
  TLayaQuestionType = (
    lqtNoul,      (* yes or no *)
    lqtChoice,    (* one of several *)
    lqtScore      (* a level on a scale *)
  );

  TLayaStringArray = array of string;

  TLayaContextBudgetStatus = (
    lbsFits,
    lbsOptionCount,           (* fewer than 2 or more than 255 options *)
    lbsOptionTooLong,         (* one option is longer than 48 tokens *)
    lbsOptionBudgetExceeded,  (* the options together leave no room in the head *)
    lbsHeadingTooLong,        (* the instructions are too long for what the options leave *)
    lbsHeadBudgetExceeded,    (* instructions and options together exceed HeadMaxLen *)
    lbsStateExceedsContext,   (* the text is longer than the room left for it *)
    lbsSequenceLimit          (* the whole sequence exceeds MaxLen *)
  );

  TLayaContextBudgetSettings = record
    State: string;                  (* the text the question is about *)
    QuestionType: TLayaQuestionType;
    Instructions: string;           (* the question *)
    Criteria: TLayaStringArray;     (* choice: the options. score: the levels, lowest first. *)
    Descriptions: TLayaStringArray; (* choice only, optional: what each option means *)
    TrueMeaning: string;            (* noul only, optional: what yes means *)
    FalseMeaning: string;           (* noul only, optional: what no means *)
    QuestionId: string;             (* only used in Message; 'q' if empty *)
    MaxLen: Integer;                (* 0 = as the model says (Tokenizer.MaxLen) *)
    HeadMaxLen: Integer;            (* 0 = as the model says (Tokenizer.HeadMaxLen) *)
    AllowTruncation: Boolean;       (* the model was loaded with "allow_truncation":true *)
  end;

  TLayaContextBudget = record
    StateTokens: Integer;           (* the text *)
    HeadingTokens: Integer;         (* "<type> question: <instructions>" *)
    OptionCount: Integer;
    OptionTokens: Integer;          (* all options, each with its [MASK] *)
    HeadTokens: Integer;            (* heading + options: what HeadMaxLen limits *)
    HeadMaxLen: Integer;
    ContextSize: Integer;           (* MaxLen *)

    AvailableStateTokens: Integer;  (* room for the text *)
    RemainingTokens: Integer;       (* room left after the text; negative = too long by that much *)
    PromptTokens: Integer;          (* the whole sequence; usage.input_tokens of the answer *)

    Truncated: Boolean;             (* with AllowTruncation: something was cut to make it fit *)
    Fits: Boolean;
    Status: TLayaContextBudgetStatus;
    Message: string;                (* the library's error text; empty if it fits *)
    Ids: TLayaTokenIds;             (* the sequence itself, when it fits *)
  end;

(* Settings for the three kinds of question, with everything else at its default. They take
  the same arguments as AskYesNo, AskChoice and AskScore of TLayaAgent. *)
function LayaYesNoQuestion(const AState, AInstructions: string): TLayaContextBudgetSettings;
function LayaChoiceQuestion(const AState, AInstructions: string;
  const AOptions: array of string): TLayaContextBudgetSettings;
function LayaScoreQuestion(const AState, AInstructions: string;
  const ALevels: array of string): TLayaContextBudgetSettings;

function LayaGetContextBudget(ATokenizer: TLayaTokenizer;
  const ASettings: TLayaContextBudgetSettings): TLayaContextBudget;

function LayaBudgetStatusToString(const AStatus: TLayaContextBudgetStatus): string;

(* The tokens of a text as the engine counts request text. The same as
  Tokenizer.CountTokens, except that a mask token written in the text is read as a space. *)
function LayaCountTextTokens(ATokenizer: TLayaTokenizer; const AText: string): Integer;
function LayaEncodeText(ATokenizer: TLayaTokenizer; const AText: string): TLayaTokenIds;

implementation

const
  QuestionTypeNames: array[TLayaQuestionType] of string = ('noul', 'choice', 'score');
  DefaultTrueMeaning = 'yes, the statement holds';
  DefaultFalseMeaning = 'no, the statement does not hold';

function LayaBudgetStatusToString(const AStatus: TLayaContextBudgetStatus): string;
begin
  case AStatus of
    lbsFits: Result := 'FITS';
    lbsOptionCount: Result := 'WRONG NUMBER OF OPTIONS';
    lbsOptionTooLong: Result := 'OPTION TOO LONG';
    lbsOptionBudgetExceeded: Result := 'OPTIONS EXCEED HEAD BUDGET';
    lbsHeadingTooLong: Result := 'INSTRUCTIONS TOO LONG';
    lbsHeadBudgetExceeded: Result := 'QUESTION EXCEEDS HEAD BUDGET';
    lbsStateExceedsContext: Result := 'TEXT EXCEEDS CONTEXT';
    lbsSequenceLimit: Result := 'SEQUENCE EXCEEDS CONTEXT';
  else
    Result := '';
  end;
end;

procedure InitSettings(out S: TLayaContextBudgetSettings; const AState, AInstructions: string;
  AType: TLayaQuestionType);
begin
  S.State := AState;
  S.QuestionType := AType;
  S.Instructions := AInstructions;
  S.Criteria := nil;
  S.Descriptions := nil;
  S.TrueMeaning := '';
  S.FalseMeaning := '';
  S.QuestionId := 'q';
  S.MaxLen := 0;
  S.HeadMaxLen := 0;
  S.AllowTruncation := False;
end;

function LayaYesNoQuestion(const AState, AInstructions: string): TLayaContextBudgetSettings;
begin
  InitSettings(Result, AState, AInstructions, lqtNoul);
end;

function LayaChoiceQuestion(const AState, AInstructions: string;
  const AOptions: array of string): TLayaContextBudgetSettings;
var
  I: Integer;
begin
  InitSettings(Result, AState, AInstructions, lqtChoice);
  SetLength(Result.Criteria, Length(AOptions));
  for I := 0 to High(AOptions) do
    Result.Criteria[I] := AOptions[I];
end;

function LayaScoreQuestion(const AState, AInstructions: string;
  const ALevels: array of string): TLayaContextBudgetSettings;
var
  I: Integer;
begin
  InitSettings(Result, AState, AInstructions, lqtScore);
  SetLength(Result.Criteria, Length(ALevels));
  for I := 0 to High(ALevels) do
    Result.Criteria[I] := ALevels[I];
end;

(* The engine replaces the mask token's text by a space in everything a request says, so that
  nobody can write a second answer position into a question. *)
function Clean(const AText, AMask: string): string;
var
  P, Start, K, M, N: Integer;
  Same: Boolean;
begin
  M := Length(AMask);
  N := Length(AText);
  if (M = 0) or (Pos(AMask, AText) = 0) then
  begin
    Result := AText;
    Exit;
  end;
  Result := '';
  Start := 1;
  P := 1;
  while P + M - 1 <= N do
  begin
    Same := True;
    for K := 1 to M do
      if AText[P + K - 1] <> AMask[K] then
      begin
        Same := False;
        Break;
      end;
    if Same then
    begin
      Result := Result + Copy(AText, Start, P - Start) + ' ';
      P := P + M;
      Start := P;
    end
    else
      Inc(P);
  end;
  Result := Result + Copy(AText, Start, MaxInt);
end;

function LayaEncodeText(ATokenizer: TLayaTokenizer; const AText: string): TLayaTokenIds;
begin
  if ATokenizer = nil then
    raise ELayaTokenizer.Create('The tokenizer is nil.');
  Result := ATokenizer.Encode(Clean(AText, ATokenizer.MaskToken));
end;

function LayaCountTextTokens(ATokenizer: TLayaTokenizer; const AText: string): Integer;
begin
  Result := Length(LayaEncodeText(ATokenizer, AText));
end;

function LayaGetContextBudget(ATokenizer: TLayaTokenizer;
  const ASettings: TLayaContextBudgetSettings): TLayaContextBudget;
type
  TIdsArray = array of TLayaTokenIds;
var
  Limit, Budget, Used, Remaining, Per, HeadingLimit, Room, Total, LastMarker: Integer;
  I, J, K, N: Integer;
  Cut, Known: Boolean;
  Id: string;
  Options: TLayaStringArray;
  Names, Texts: TLayaStringArray;
  State, Heading: TLayaTokenIds;
  Encoded: TIdsArray;
  Ids: TLayaTokenIds;

  procedure Problem(AStatus: TLayaContextBudgetStatus; const AMessage: string);
  begin
    if Result.Status = lbsFits then
    begin
      Result.Status := AStatus;
      Result.Message := AMessage;
    end;
  end;

  function Prefix: string;
  begin
    Result := 'Question ''' + Id + ''' ';
  end;

begin
  if ATokenizer = nil then
    raise ELayaTokenizer.Create('The tokenizer is nil.');
  if not ATokenizer.Loaded then
    raise ELayaTokenizer.Create('Tokenizer has not been loaded.');
  if (ATokenizer.ClsId < 0) or (ATokenizer.SepId < 0) or (ATokenizer.MaskId < 0) then
    raise ELayaTokenizer.Create('The tokenizer lacks the special tokens the model needs. ' +
      'Load it with LoadFromModelDir.');

  Limit := ASettings.MaxLen;
  if Limit <= 0 then
    Limit := ATokenizer.MaxLen;
  Budget := ASettings.HeadMaxLen;
  if Budget <= 0 then
    Budget := ATokenizer.HeadMaxLen;
  Cut := ASettings.AllowTruncation;
  Id := ASettings.QuestionId;
  if Id = '' then
    Id := 'q';

  Result.Status := lbsFits;
  Result.Message := '';
  Result.Truncated := False;
  Result.Ids := nil;
  Result.ContextSize := Limit;
  Result.HeadMaxLen := Budget;

  (* The text. *)
  State := LayaEncodeText(ATokenizer, ASettings.State);
  Result.StateTokens := Length(State);

  (* The options, as the engine words them. *)
  Options := nil;
  case ASettings.QuestionType of
    lqtChoice:
      begin
        (* an option named twice counts once, at its first place *)
        Names := nil;
        Texts := nil;
        N := 0;
        SetLength(Names, Length(ASettings.Criteria));
        SetLength(Texts, Length(ASettings.Criteria));
        for I := 0 to High(ASettings.Criteria) do
        begin
          Known := False;
          for J := 0 to N - 1 do
            if Names[J] = ASettings.Criteria[I] then
            begin
              Known := True;
              K := J;
              Break;
            end;
          if not Known then
          begin
            K := N;
            Names[K] := ASettings.Criteria[I];
            Texts[K] := '';
            Inc(N);
          end;
          if (I <= High(ASettings.Descriptions)) and (ASettings.Descriptions[I] <> '') then
            Texts[K] := ASettings.Descriptions[I]
          else if Known then
            Texts[K] := '';
        end;
        SetLength(Options, N);
        for I := 0 to N - 1 do
          if Texts[I] = '' then
            Options[I] := Names[I]
          else
            Options[I] := Names[I] + ': ' + Texts[I];
      end;
    lqtScore:
      begin
        SetLength(Options, Length(ASettings.Criteria));
        for I := 0 to High(ASettings.Criteria) do
          Options[I] := 'level ' + IntToStr(I) + ': ' + ASettings.Criteria[I];
      end;
  else
    SetLength(Options, 2);
    if ASettings.FalseMeaning = '' then
      Options[0] := 'false: ' + DefaultFalseMeaning
    else
      Options[0] := 'false: ' + ASettings.FalseMeaning;
    if ASettings.TrueMeaning = '' then
      Options[1] := 'true: ' + DefaultTrueMeaning
    else
      Options[1] := 'true: ' + ASettings.TrueMeaning;
  end;
  Result.OptionCount := Length(Options);
  if (Length(Options) < LayaMinOptions) or (Length(Options) > LayaMaxOptions) then
    Problem(lbsOptionCount, 'Questions require 2 through 255 options');

  (* The heading. *)
  Heading := LayaEncodeText(ATokenizer,
    QuestionTypeNames[ASettings.QuestionType] + ' question: ' + ASettings.Instructions);

  (* Each option: a space, its text, and a [MASK] in front where the model answers. *)
  Encoded := nil;
  SetLength(Encoded, Length(Options));
  Used := 0;
  for I := 0 to High(Options) do
  begin
    Ids := LayaEncodeText(ATokenizer, ' ' + Options[I]);
    if Length(Ids) > LayaMaxOptionTokens then
    begin
      if Cut then
      begin
        SetLength(Ids, LayaMaxOptionTokens);
        Result.Truncated := True;
      end
      else
        Problem(lbsOptionTooLong, Prefix + 'exceeds option token limit (' +
          IntToStr(LayaMaxOptionTokens) + ')');
    end;
    SetLength(Encoded[I], Length(Ids) + 1);
    Encoded[I][0] := ATokenizer.MaskId;
    for J := 0 to High(Ids) do
      Encoded[I][J + 1] := Ids[J];
    Inc(Used, Length(Encoded[I]));
  end;

  (* Many or long options: the head keeps 16 tokens for the heading, the options share the
    rest equally. *)
  Remaining := Budget - Used;
  if (Remaining < 16) and (Length(Options) > 0) then
  begin
    Per := (Budget - 16) div Length(Options);
    if Per < 4 then
      Per := 4;
    for I := 0 to High(Encoded) do
      if Length(Encoded[I]) > Per then
      begin
        if Cut then
        begin
          SetLength(Encoded[I], Per);
          Result.Truncated := True;
        end
        else
          Problem(lbsOptionBudgetExceeded, Prefix + 'exceeds option token budget (' +
            IntToStr(Per) + ' tokens per option)');
      end;
    Used := 0;
    for I := 0 to High(Encoded) do
      Inc(Used, Length(Encoded[I]));
    Remaining := Budget - Used;
  end;

  HeadingLimit := Remaining;
  if HeadingLimit < 8 then
    HeadingLimit := 8;
  if Length(Heading) > HeadingLimit then
  begin
    if Cut then
    begin
      SetLength(Heading, HeadingLimit);
      Result.Truncated := True;
    end
    else
      Problem(lbsHeadingTooLong, Prefix + 'exceeds heading token budget (' +
        IntToStr(HeadingLimit) + ' tokens)');
  end;
  if (not Cut) and (Used + Length(Heading) > Budget) then
    Problem(lbsHeadBudgetExceeded, Prefix + 'exceeds question head token budget (' +
      IntToStr(Budget) + ' tokens)');

  Result.HeadingTokens := Length(Heading);
  Result.OptionTokens := Used;
  Result.HeadTokens := Used + Length(Heading);

  (* [CLS] heading [SEP] options [SEP] text [SEP] *)
  Total := 1 + Length(Heading) + 1 + Used + 1;
  LastMarker := -1;
  if Length(Encoded) > 0 then
    LastMarker := Total - 1 - Length(Encoded[High(Encoded)]);
  Room := Limit - Total - 1;
  if Room < 0 then
    Room := 0;
  Result.AvailableStateTokens := Room;
  Result.RemainingTokens := Room - Length(State);
  if Length(State) > Room then
  begin
    if Cut then
    begin
      SetLength(State, Room);
      Result.Truncated := True;
    end
    else
      Problem(lbsStateExceedsContext, Prefix + 'exceeds state context limit (' +
        IntToStr(Room) + ' tokens)');
  end;
  Total := Total + Length(State) + 1;
  if Total > Limit then
  begin
    if Cut then
      Result.Truncated := True
    else
      Problem(lbsSequenceLimit, Prefix + 'exceeds final sequence limit (' +
        IntToStr(Limit) + ' tokens)');
  end;
  (* the last answer position must lie inside the sequence, truncation or not *)
  if LastMarker >= Limit then
    Problem(lbsSequenceLimit, Prefix + 'exceeds final sequence limit (' +
      IntToStr(Limit) + ' tokens)');

  if Cut and (Total > Limit) then
    Result.PromptTokens := Limit
  else
    Result.PromptTokens := Total;
  Result.Fits := Result.Status = lbsFits;

  if Result.Fits then
  begin
    Ids := nil;
    SetLength(Ids, Total);
    N := 0;
    Ids[N] := ATokenizer.ClsId; Inc(N);
    for I := 0 to High(Heading) do
    begin
      Ids[N] := Heading[I]; Inc(N);
    end;
    Ids[N] := ATokenizer.SepId; Inc(N);
    for I := 0 to High(Encoded) do
      for J := 0 to High(Encoded[I]) do
      begin
        Ids[N] := Encoded[I][J]; Inc(N);
      end;
    Ids[N] := ATokenizer.SepId; Inc(N);
    for I := 0 to High(State) do
    begin
      Ids[N] := State[I]; Inc(N);
    end;
    Ids[N] := ATokenizer.SepId; Inc(N);
    if N > Limit then
      N := Limit;
    SetLength(Ids, N);
    Result.Ids := Ids;
  end;
end;

end.
