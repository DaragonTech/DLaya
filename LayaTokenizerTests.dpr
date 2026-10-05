program LayaTokenizerTests;

(* Console test for LayaTokenizer.pas, LayaContext.pas, LayaArchive.pas and LayaUnicode.pas. It
  does not need the LibLayaX library.

    LayaTokenizerTests [MODEL_DIR] [CASES_FILE]

  Without MODEL_DIR only the checks that need no model run. With it, the tokenizer is loaded
  from the model folder and compared with the fixtures in CASES_FILE: texts with the token
  ids the model's own tokenizer gives them. The default is testdata/tokenizer-cases.txt for
  the English model and testdata/tokenizer-multilingual.txt for the multilingual one, looked
  for next to the program and in the current folder. Exit code 0 = all passed.

  MODEL_DIR may also be a .tar archive of the model. When it is a folder, the program also
  packs the tokenizer files into archives of its own and checks that they load the same. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, LayaUnicode, LayaArchive, LayaTokenizer, LayaContext;

var
  Checks, Failures: Integer;

procedure Check(Cond: Boolean; const What: string);
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failures);
    if Failures <= 20 then
      Writeln('FAIL: ', What);
  end;
end;

function IdsToText(const Ids: TLayaTokenIds): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Ids) do
  begin
    if I > 0 then Result := Result + ' ';
    Result := Result + IntToStr(Ids[I]);
  end;
end;

function HexToText(const Points: TLayaCodePoints): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Points) do
  begin
    if I > 0 then Result := Result + ' ';
    Result := Result + IntToHex(Points[I], 4);
  end;
end;

function Points(const Values: array of Integer): TLayaCodePoints;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Values));
  for I := 0 to High(Values) do
    Result[I] := Values[I];
end;

function SamePoints(const A, B: TLayaCodePoints): Boolean;
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

(* ---- checks that need no model ---- *)

procedure UnicodeTests;
begin
  Check(LayaIsLetter(Ord('a')) and LayaIsLetter($E9) and LayaIsLetter($4E2D) and LayaIsLetter($1E900),
    'letters');
  Check(not LayaIsLetter(Ord('1')) and not LayaIsLetter(Ord(' ')) and not LayaIsLetter($1F600),
    'not letters');
  Check(LayaIsNumber(Ord('7')) and LayaIsNumber($B2) and LayaIsNumber($BD) and LayaIsNumber($2167) and
    LayaIsNumber($663), 'numbers');
  Check(LayaIsWhiteSpace($20) and LayaIsWhiteSpace($0B) and LayaIsWhiteSpace($85) and
    LayaIsWhiteSpace($A0) and LayaIsWhiteSpace($3000), 'white space');
  Check(not LayaIsWhiteSpace($200B) and not LayaIsWhiteSpace($FEFF) and not LayaIsWhiteSpace($1F),
    'not white space');
  Check(LayaCombiningClass($301) = 230, 'combining class');

  (* e + acute -> e-acute; Angstrom sign -> A-ring; marks put in order, then composed *)
  Check(SamePoints(LayaNFC(Points([$65, $301])), Points([$E9])), 'NFC: compose');
  Check(SamePoints(LayaNFC(Points([$212B])), Points([$C5])), 'NFC: singleton');
  Check(SamePoints(LayaNFC(Points([$71, $307, $323])), Points([$71, $323, $307])), 'NFC: reorder');
  Check(SamePoints(LayaNFC(Points([$1100, $1161, $11A8])), Points([$AC01])), 'NFC: Hangul');
  Check(SamePoints(LayaNFC(Points([$41, $20, $42])), Points([$41, $20, $42])), 'NFC: plain text');
  Check(SamePoints(LayaNFC(Points([$344])), Points([$308, $301])), 'NFC: excluded from composition');

  Check(SamePoints(LayaStringToCodePoints('a' + #$D83D + #$DE00 + 'b'), Points([$61, $1F600, $62])),
    'surrogate pair');
  Check(SamePoints(LayaStringToCodePoints(#$D83D + 'b'), Points([$FFFD, $62])), 'lone surrogate');
  Check(LayaCodePointsToString(Points([$61, $1F600, $62])) = 'a' + #$D83D + #$DE00 + 'b', 'to string');
  Check(LayaUtf8ToString(LayaStringToUtf8('caf' + #$00E9 + ' ' + #$D83D + #$DE00)) =
    'caf' + #$00E9 + ' ' + #$D83D + #$DE00, 'UTF-8 round trip');
  Check(LayaNormalizeNFC('e' + #$0301) = #$00E9, 'LayaNormalizeNFC');
end;

procedure NotLoadedTests;
var
  T: TLayaTokenizer;
begin
  T := TLayaTokenizer.Create;
  try
    try
      T.CountTokens('x');
      Check(False, 'an unloaded tokenizer must raise');
    except
      on E: ELayaTokenizer do Check(True, '');
    end;
    try
      T.LoadFromModelDir('no-such-folder-for-laya');
      Check(False, 'a missing folder must raise');
    except
      on E: ELayaTokenizer do Check(Pos('Cannot open', E.Message) = 1, 'missing folder: ' + E.Message);
    end;
    Check(not T.Loaded, 'not loaded after a failure');
  finally
    T.Free;
  end;
end;

(* ---- fixtures ---- *)

function FindCasesFile(const Name: string): string;
var
  Dir: string;
begin
  Dir := ExtractFilePath(ParamStr(0));
  Result := Dir + 'testdata' + PathDelim + Name;
  if FileExists(Result) then Exit;
  Result := Dir + Name;
  if FileExists(Result) then Exit;
  Result := 'testdata' + PathDelim + Name;
  if FileExists(Result) then Exit;
  Result := Name;
  if FileExists(Result) then Exit;
  Result := '';
end;

procedure FixtureTests(Tokenizer: TLayaTokenizer; const FileName: string);
var
  Data: TBytes;
  P, N, Value, Count, Bad, LineNo: Integer;
  Text: TLayaCodePoints;
  Expected, Actual: TLayaTokenIds;
  TextCount, IdCount: Integer;
  InIds, HaveNumber, Comment, Same: Boolean;
  C, I: Integer;

  procedure EndNumber;
  begin
    if not HaveNumber then Exit;
    if InIds then
    begin
      if IdCount = Length(Expected) then SetLength(Expected, IdCount * 2 + 16);
      Expected[IdCount] := Value;
      Inc(IdCount);
    end
    else
    begin
      if TextCount = Length(Text) then SetLength(Text, TextCount * 2 + 16);
      Text[TextCount] := Value;
      Inc(TextCount);
    end;
    Value := 0;
    HaveNumber := False;
  end;

begin
  Data := LayaReadFile(FileName);
  N := Length(Data);
  P := 0;
  Count := 0;
  Bad := 0;
  LineNo := 0;
  Text := nil;
  Expected := nil;
  while P < N do
  begin
    Inc(LineNo);
    TextCount := 0;
    IdCount := 0;
    InIds := False;
    HaveNumber := False;
    Value := 0;
    Comment := Data[P] = Ord('#');
    while (P < N) and (Data[P] <> 10) do
    begin
      C := Data[P];
      Inc(P);
      if Comment or (C = 13) then Continue;
      if C = Ord('|') then
      begin
        EndNumber;
        InIds := True;
      end
      else if C = Ord(' ') then
        EndNumber
      else
      begin
        HaveNumber := True;
        if InIds then
          Value := Value * 10 + (C - Ord('0'))
        else if C <= Ord('9') then
          Value := Value * 16 + (C - Ord('0'))
        else
          Value := Value * 16 + (C - Ord('A') + 10);
      end;
    end;
    EndNumber;
    Inc(P);
    if Comment or not InIds then Continue;

    Actual := Tokenizer.EncodeCodePoints(Copy(Text, 0, TextCount));
    Same := Length(Actual) = IdCount;
    if Same then
      for I := 0 to IdCount - 1 do
        if Actual[I] <> Expected[I] then
        begin
          Same := False;
          Break;
        end;
    Inc(Count);
    if not Same then
    begin
      Inc(Bad);
      if Bad <= 5 then
      begin
        Writeln('  line ', LineNo, ': text ', HexToText(Copy(Text, 0, TextCount)));
        Writeln('    expected ', IdsToText(Copy(Expected, 0, IdCount)));
        Writeln('    actual   ', IdsToText(Actual));
      end;
    end;
  end;
  Writeln('fixtures: ', Count - Bad, ' of ', Count, ' passed (', ExtractFileName(FileName), ')');
  Check(Count > 0, 'the fixture file has no cases');
  Check(Bad = 0, IntToStr(Bad) + ' fixtures differ');
end;

(* ---- checks with a model's tokenizer ---- *)

(* ---- models in a .tar archive ------------------------------------------------ *)

(* A minimal tar writer for the tests: enough to produce the kinds of header the reader has
  to understand. *)
type
  TTarBuilder = class
  public
    Data: TBytes;
    procedure Add(const Name: string; const Content: TBytes; Kind: AnsiChar = '0';
      Posix: Boolean = True; const Prefix: string = '');
    procedure Finish;
    procedure Save(const FileName: string);
  end;

procedure PutText(var Block: TBytes; Start, Width: Integer; const Text: TBytes);
var
  I: Integer;
begin
  for I := 0 to Length(Text) - 1 do
    if I < Width then Block[Start + I] := Text[I];
end;

procedure PutOctal(var Block: TBytes; Start, Width: Integer; Value: Int64);
var
  I: Integer;
begin
  (* Width - 1 octal digits and a zero byte *)
  Block[Start + Width - 1] := 0;
  for I := Start + Width - 2 downto Start do
  begin
    Block[I] := Ord('0') + (Value and 7);
    Value := Value shr 3;
  end;
end;

procedure TTarBuilder.Add(const Name: string; const Content: TBytes; Kind: AnsiChar;
  Posix: Boolean; const Prefix: string);
var
  Header: TBytes;
  At, I, Sum, Padded: Integer;
begin
  Header := nil;
  SetLength(Header, 512);
  PutText(Header, 0, 100, LayaStringToUtf8(Name));
  PutOctal(Header, 100, 8, 420);
  PutOctal(Header, 108, 8, 0);
  PutOctal(Header, 116, 8, 0);
  PutOctal(Header, 124, 12, Length(Content));
  PutOctal(Header, 136, 12, 0);
  Header[156] := Ord(Kind);
  if Posix then
  begin
    PutText(Header, 257, 6, LayaStringToUtf8('ustar'));
    Header[263] := Ord('0');
    Header[264] := Ord('0');
    PutText(Header, 345, 155, LayaStringToUtf8(Prefix));
  end
  else
    PutText(Header, 257, 8, LayaStringToUtf8('ustar  '));
  Sum := 0;
  for I := 0 to 511 do
    if (I >= 148) and (I < 156) then Inc(Sum, 32) else Inc(Sum, Header[I]);
  PutOctal(Header, 148, 7, Sum);
  Header[155] := 32;
  Padded := (Length(Content) + 511) div 512 * 512;
  At := Length(Data);
  SetLength(Data, At + 512 + Padded);
  Move(Header[0], Data[At], 512);
  if Length(Content) > 0 then Move(Content[0], Data[At + 512], Length(Content));
end;

procedure TTarBuilder.Finish;
begin
  SetLength(Data, Length(Data) + 1024);   (* SetLength fills the new part with zeros *)
end;

procedure TTarBuilder.Save(const FileName: string);
var
  Handle: THandle;
begin
  Handle := FileCreate(FileName);
  if Handle = THandle(-1) then raise Exception.Create('Cannot write ' + FileName);
  try
    if (Length(Data) > 0) and (FileWrite(Handle, Data[0], Length(Data)) <> Length(Data)) then
      raise Exception.Create('Cannot write ' + FileName);
  finally
    FileClose(Handle);
  end;
end;

function TempFile(const Name: string): string;
var
  Dir: string;
begin
  Dir := GetEnvironmentVariable('TEMP');
  if (Dir = '') or not DirectoryExists(Dir) then Dir := GetEnvironmentVariable('TMPDIR');
  if (Dir = '') or not DirectoryExists(Dir) then Dir := ExtractFilePath(ParamStr(0));
  if (Dir = '') or not DirectoryExists(Dir) then Dir := GetCurrentDir;
  Result := IncludeTrailingPathDelimiter(Dir) + Name;
end;

function Text8(const S: string): TBytes;
begin
  Result := LayaStringToUtf8(S);
end;

function SameData(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if Result then
    for I := 0 to Length(A) - 1 do
      if A[I] <> B[I] then
      begin
        Result := False;
        Exit;
      end;
end;

(* One record of a pax header: its own length in decimal, a space, key=value and a line feed.
  The length counts the digits too. The keys and values used here are plain ASCII. *)
function PaxRecord(const Key, Value: string): string;
var
  Rest: string;
  Len: Integer;
begin
  Rest := ' ' + Key + '=' + Value + #10;
  Len := Length(Rest) + 1;
  while Length(IntToStr(Len)) + Length(Rest) <> Len do Inc(Len);
  Result := IntToStr(Len) + Rest;
end;

function ArchiveFails(const FileName, Needle: string): Boolean;
var
  A: TLayaArchive;
begin
  Result := False;
  try
    A := TLayaArchive.Create(FileName);
    A.Free;
  except
    on E: ELayaArchive do Result := Pos(Needle, E.Message) > 0;
  end;
end;

procedure ArchiveTests;
var
  Tar: TTarBuilder;
  A: TLayaArchive;
  FileName, LongFolder: string;
  Config, Vocab: TBytes;
  Offset, Size: Int64;
  I: Integer;
begin
  FileName := TempFile('laya-archive-test.tar');
  Config := Text8('{"max_len": 300}');
  Vocab := nil;
  SetLength(Vocab, 1500);   (* longer than one block, and not a multiple of one *)
  for I := 0 to High(Vocab) do Vocab[I] := Byte(I * 7 + 1);
  LongFolder := '';
  for I := 1 to 15 do LongFolder := LongFolder + 'a-long-folder-name-' + IntToStr(I) + '-';
  Tar := TTarBuilder.Create;
  try
    (* the model at the top *)
    Tar.Add('rl_agent_config.json', Config);
    Tar.Add('tokenizer/', nil, '5');
    Tar.Add('tokenizer/tokenizer.json', Vocab);
    Tar.Finish;
    Tar.Save(FileName);
    A := TLayaArchive.Create(FileName);
    try
      Check(A.Root = '', 'archive: model at the top');
      Check(A.Count = 2, 'archive: two files, the folder entry is not one');
      Check(A.Exists('rl_agent_config.json') and A.Exists('tokenizer/tokenizer.json'), 'archive: files found');
      Check(A.Exists('./tokenizer\tokenizer.json'), 'archive: other ways to write a name');
      Check(not A.Exists('tokenizer/other.json') and not A.Exists('../x') and not A.Exists(''), 'archive: files not there');
      Check(SameData(A.ReadFile('rl_agent_config.json'), Config), 'archive: small file');
      Check(SameData(A.ReadFile('tokenizer/tokenizer.json'), Vocab), 'archive: file of several blocks');
      Check(A.Find('tokenizer/tokenizer.json', Offset, Size) and (Size = 1500) and (Offset = 2048), 'archive: place of a file');
      try
        A.ReadFile('missing.json');
        Check(False, 'archive: reading a missing file must fail');
      except
        on E: ELayaArchive do Check(Pos('no such file', E.Message) > 0, 'archive: message for a missing file');
      end;
    finally
      A.Free;
    end;
    Check(LayaIsArchiveFile(FileName), 'archive: a file is taken for an archive');
    Check(not LayaIsArchiveFile(ExtractFilePath(FileName)) and not LayaIsArchiveFile(FileName + '.none'),
      'archive: a folder and a missing path are not');

    (* inside one folder; with an entry the macOS tar would add *)
    Tar.Data := nil;
    Tar.Add('._pack', Text8('junk'));
    Tar.Add('pack/rl_agent_config.json', Config);
    Tar.Add('pack/tokenizer/._tokenizer.json', Text8('junk'));
    Tar.Add('pack/tokenizer/tokenizer.json', Vocab);
    Tar.Finish;
    Tar.Save(FileName);
    A := TLayaArchive.Create(FileName);
    try
      Check(A.Root = 'pack/', 'archive: model inside one folder');
      Check(A.Count = 2, 'archive: resource-fork entries are ignored');
      Check(SameData(A.ReadFile('tokenizer/tokenizer.json'), Vocab), 'archive: file inside the folder');
    finally
      A.Free;
    end;

    (* two folders at the top: the model does not start in either *)
    Tar.Data := nil;
    Tar.Add('english/rl_agent_config.json', Config);
    Tar.Add('multilingual/rl_agent_config.json', Config);
    Tar.Finish;
    Tar.Save(FileName);
    A := TLayaArchive.Create(FileName);
    try
      Check((A.Root = '') and A.Exists('multilingual/rl_agent_config.json'), 'archive: several models');
    finally
      A.Free;
    end;

    (* long names: the GNU way, the pax way, and the ustar prefix field *)
    Tar.Data := nil;
    Tar.Add('././@LongLink', Text8(LongFolder + '/rl_agent_config.json'#0), 'L', False);
    Tar.Add(Copy(LongFolder, 1, 99), Config, '0', False);
    Tar.Finish;
    Tar.Save(FileName);
    A := TLayaArchive.Create(FileName);
    try
      Check((A.Root = LongFolder + '/') and SameData(A.ReadFile('rl_agent_config.json'), Config), 'archive: GNU long name');
    finally
      A.Free;
    end;
    Tar.Data := nil;
    Tar.Add('PaxHeader/x', Text8(PaxRecord('mtime', '1700000000.123456789') +
      PaxRecord('path', LongFolder + '/rl_agent_config.json')), 'x');
    Tar.Add('truncated-name', Config);
    Tar.Add('second.json', Config);
    Tar.Finish;
    Tar.Save(FileName);
    A := TLayaArchive.Create(FileName);
    try
      Check(A.Exists(LongFolder + '/rl_agent_config.json') and A.Exists('second.json') and
        not A.Exists('truncated-name'), 'archive: pax long name, and only for the next entry');
    finally
      A.Free;
    end;
    Tar.Data := nil;
    Tar.Add('tokenizer.json', Vocab, '0', True, 'deep/tokenizer');
    Tar.Add('rl_agent_config.json', Config, '0', True, 'deep');
    Tar.Finish;
    Tar.Save(FileName);
    A := TLayaArchive.Create(FileName);
    try
      Check((A.Root = 'deep/') and SameData(A.ReadFile('tokenizer/tokenizer.json'), Vocab), 'archive: ustar prefix');
    finally
      A.Free;
    end;

    (* files that are not archives, and a damaged one *)
    Tar.Data := Text8('{"this": "is JSON, not a tar file", "padding": "' + StringOfChar('x', 600) + '"}');
    Tar.Save(FileName);
    Check(ArchiveFails(FileName, 'not a folder and not an uncompressed tar archive'), 'archive: a file that is not a tar');
    Tar.Data := Text8('short');
    Tar.Save(FileName);
    Check(ArchiveFails(FileName, 'not a folder and not an uncompressed tar archive'), 'archive: a very short file');
    Tar.Data := nil;
    Tar.Add('rl_agent_config.json', Config);
    Tar.Add('tokenizer/tokenizer.json', Vocab);
    SetLength(Tar.Data, Length(Tar.Data) - 1024);
    Tar.Save(FileName);
    Check(ArchiveFails(FileName, 'Truncated tar archive'), 'archive: a file cut short');
    Check(ArchiveFails(FileName + '.none', 'Cannot open'), 'archive: a missing file');
  finally
    Tar.Free;
    DeleteFile(FileName);
  end;
end;

(* The tokenizer loaded from an archive of the model must be the tokenizer loaded from the
  folder. The archive is made here from the three small files; the weights are not needed. *)
procedure ArchiveModelTests(const Dir: string; Reference: TLayaTokenizer);
const
  Texts: array[0..3] of string = ('Please refund the duplicate charge.', 'naïve café — 日本語 ünïcödé',
    'a   b'#9'c'#10'd', '[CLS] x [SEP] 1234567890');
var
  Tar: TTarBuilder;
  T: TLayaTokenizer;
  FileName, Base, Folder: string;
  Layout, I: Integer;
  Same: Boolean;
begin
  FileName := TempFile('laya-archive-model-test.tar');
  Base := IncludeTrailingPathDelimiter(Dir);
  Tar := TTarBuilder.Create;
  T := TLayaTokenizer.Create;
  try
    for Layout := 0 to 2 do
    begin
      case Layout of
        0: Folder := '';
        1: Folder := 'model/';
      else
        Folder := 'store/multilingual/';
      end;
      Tar.Data := nil;
      Tar.Add(Folder + 'rl_agent_config.json', LayaReadFile(Base + 'rl_agent_config.json'));
      Tar.Add(Folder + 'tokenizer/tokenizer_config.json',
        LayaReadFile(Base + 'tokenizer' + PathDelim + 'tokenizer_config.json'));
      Tar.Add(Folder + 'tokenizer/tokenizer.json', LayaReadFile(Base + 'tokenizer' + PathDelim + 'tokenizer.json'));
      Tar.Finish;
      Tar.Save(FileName);
      if Layout = 2 then T.LoadFromArchive(FileName, 'multilingual')
      else T.LoadFromModelDir(FileName);
      Same := T.Loaded and (T.VocabSize = Reference.VocabSize) and (T.MaxLen = Reference.MaxLen) and
        (T.HeadMaxLen = Reference.HeadMaxLen) and (T.MaskId = Reference.MaskId) and
        (T.ModelName = Reference.ModelName) and (T.AddedTokenCount = Reference.AddedTokenCount);
      for I := Low(Texts) to High(Texts) do
        if IdsToText(T.Encode(Texts[I])) <> IdsToText(Reference.Encode(Texts[I])) then Same := False;
      Check(Same, 'tokenizer from an archive, layout ' + IntToStr(Layout));
    end;
    try
      T.LoadFromArchive(FileName, 'english');
      Check(False, 'a folder that is not in the archive must fail');
    except
      on E: ELayaTokenizer do Check(not T.Loaded and (Pos('no such file', E.Message) > 0), 'archive: wrong folder');
    end;
  finally
    T.Free;
    Tar.Free;
    DeleteFile(FileName);
  end;
end;

procedure ModelTests(const Dir, CasesFile: string);
var
  T: TLayaTokenizer;
  B, B2: TLayaContextBudget;
  S: TLayaContextBudgetSettings;
  Name, Long: string;
  Started: TDateTime;
  I, Room: Integer;
begin
  T := TLayaTokenizer.Create;
  try
    Started := Now;
    T.LoadFromModelDir(Dir);
    Writeln('tokenizer: ', T.VocabSize, ' entries, ', T.AddedTokenCount, ' added tokens, metaspace ',
      T.Metaspace, ', loaded in ', Round((Now - Started) * 86400000), ' ms');
    Writeln('special tokens: ', T.ClsToken, '=', T.ClsId, ' ', T.SepToken, '=', T.SepId, ' ',
      T.PadToken, '=', T.PadId, ' ', T.MaskToken, '=', T.MaskId);
    Writeln('limits: max_len ', T.MaxLen, ', head_max_len ', T.HeadMaxLen);
    Check(T.Loaded, 'loaded');
    Check((T.ClsId >= 0) and (T.SepId >= 0) and (T.PadId >= 0) and (T.MaskId >= 0), 'special tokens');
    Check(T.TokenToId(T.MaskToken) = T.MaskId, 'TokenToId');
    Check(T.TokenToId('no such token in any vocabulary') = -1, 'TokenToId of an unknown text');
    Check(T.CountTokens('') = 0, 'empty text');
    Check(Length(T.Encode(T.ClsToken)) = 1, 'a special token is one token');
    Check(T.Encode(T.ClsToken)[0] = T.ClsId, 'a special token keeps its id');

    Name := CasesFile;
    if Name = '' then
    begin
      if T.Metaspace then Name := FindCasesFile('tokenizer-multilingual.txt')
      else Name := FindCasesFile('tokenizer-cases.txt');
    end;
    if Name <> '' then
      FixtureTests(T, Name)
    else
      Writeln('(fixtures skipped: testdata folder not found)');

    (* the budget of the three examples of the documentation *)
    B := LayaGetContextBudget(T, LayaYesNoQuestion('Please refund the duplicate charge.',
      'Does the customer ask for a refund?'));
    Writeln('yes/no: ', LayaBudgetStatusToString(B.Status), ', ', B.PromptTokens, ' tokens (text ',
      B.StateTokens, ', heading ', B.HeadingTokens, ', options ', B.OptionTokens, '), room for the text ',
      B.AvailableStateTokens);
    Check(B.Fits and (B.Status = lbsFits) and (B.Message = ''), 'yes/no fits');
    Check(B.PromptTokens = Length(B.Ids), 'PromptTokens is the length of Ids');
    Check(B.PromptTokens = 1 + B.HeadingTokens + 1 + B.OptionTokens + 1 + B.StateTokens + 1, 'the parts add up');
    Check(B.AvailableStateTokens = B.ContextSize - B.HeadTokens - 4, 'room for the text');
    Check(B.RemainingTokens = B.AvailableStateTokens - B.StateTokens, 'RemainingTokens');
    Check(B.OptionCount = 2, 'yes/no has two options');
    Check((B.Ids[0] = T.ClsId) and (B.Ids[High(B.Ids)] = T.SepId), 'starts with CLS, ends with SEP');
    if (not T.Metaspace) and (T.VocabSize = 50368) then
      (* the English model reports "input_tokens":40 for this question *)
      Check(B.PromptTokens = 40, 'the refund example is 40 tokens, got ' + IntToStr(B.PromptTokens));

    B := LayaGetContextBudget(T, LayaChoiceQuestion('I want to cancel my subscription.',
      'What does the customer want?', ['cancel', 'upgrade', 'refund']));
    Writeln('choice: ', LayaBudgetStatusToString(B.Status), ', ', B.PromptTokens, ' tokens');
    Check(B.Fits and (B.OptionCount = 3), 'choice fits');

    B := LayaGetContextBudget(T, LayaScoreQuestion('This is the third time I am writing!!!',
      'How angry is the customer?', ['calm', 'annoyed', 'furious']));
    Writeln('score: ', LayaBudgetStatusToString(B.Status), ', ', B.PromptTokens, ' tokens');
    Check(B.Fits and (B.OptionCount = 3), 'score fits');

    (* a text that is too long, then cut to what fits *)
    Long := '';
    for I := 1 to 3000 do
      Long := Long + 'word ';
    S := LayaYesNoQuestion(Long, 'Is it long?');
    B := LayaGetContextBudget(T, S);
    Writeln('long text: ', LayaBudgetStatusToString(B.Status), ' - ', B.Message);
    Check((not B.Fits) and (B.Status = lbsStateExceedsContext), 'a long text does not fit');
    Check(B.Message = 'Question ''q'' exceeds state context limit (' + IntToStr(B.AvailableStateTokens) +
      ' tokens)', 'the message of the library: ' + B.Message);
    Check(B.RemainingTokens < 0, 'RemainingTokens is negative');
    Check(B.Ids = nil, 'no sequence when it does not fit');
    Room := B.AvailableStateTokens;
    S.AllowTruncation := True;
    B2 := LayaGetContextBudget(T, S);
    Check(B2.Fits and B2.Truncated and (B2.PromptTokens = B2.ContextSize), 'with truncation it fits');
    Check(B2.StateTokens = B.StateTokens, 'StateTokens is the whole text');
    Check(Room = B2.AvailableStateTokens, 'same room');

    (* one option, and an option that is too long *)
    B := LayaGetContextBudget(T, LayaChoiceQuestion('x', 'Which?', ['only']));
    Check((B.Status = lbsOptionCount) and (B.Message = 'Questions require 2 through 255 options'),
      'one option: ' + B.Message);
    B := LayaGetContextBudget(T, LayaChoiceQuestion('x', 'Which?', ['short', Copy(Long, 1, 600)]));
    Check((B.Status = lbsOptionTooLong) and (B.Message = 'Question ''q'' exceeds option token limit (48)'),
      'long option: ' + B.Message);

    (* the mask token written in a text is read as a space *)
    Check(LayaCountTextTokens(T, 'a ' + T.MaskToken + ' b') = T.CountTokens('a   b'), 'mask in the text');
    Check(LayaCountTextTokens(T, 'plain text') = T.CountTokens('plain text'), 'text without a mask');

    if not LayaIsArchiveFile(Dir) then ArchiveModelTests(Dir, T);
  finally
    T.Free;
  end;
end;

begin
  Checks := 0;
  Failures := 0;
  try
    Writeln('Unicode ', LayaUnicodeVersion);
    UnicodeTests;
    NotLoadedTests;
    ArchiveTests;
    if ParamCount >= 1 then
    begin
      if ParamCount >= 2 then ModelTests(ParamStr(1), ParamStr(2))
      else ModelTests(ParamStr(1), '');
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
