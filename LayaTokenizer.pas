unit LayaTokenizer;

(* The Laya tokenizer in Pascal: turns text into the same token ids the engine inside LibLayaX
  produces, without loading the model and without calling the library.

  Use it to know how long a text is before sending it to the model. LayaContext.pas builds on
  it and tells whether a whole question fits.

    Tokenizer := TLayaTokenizer.Create;
    try
      Tokenizer.LoadFromModelDir('C:\models\laya');
      Writeln(Tokenizer.CountTokens('Please refund the duplicate charge.'));
    finally
      Tokenizer.Free;
    end;

  It reads tokenizer/tokenizer.json straight from the model folder; there is nothing to
  convert. Loading takes a fraction of a second and a few megabytes, against seconds and
  gigabytes for the model.

  The model may also be one .tar file, as LibLayaX 1.0.15 and later load it (see the README):
  give LoadFromModelDir the path of the archive and the same files are read from it.

  Both tokenizer kinds the engine accepts are supported: byte-level BPE (the English model)
  and metaspace BPE with byte fallback (the multilingual model). Anything else is refused with
  the engine's own message, "Unsupported tokenizer configuration".

  Thread safety: after loading, Encode and CountTokens only read. One tokenizer can be used
  from several threads at once. Do not load while another thread encodes.

  Long texts are no problem: a megabyte of text takes a fraction of a second, also in
  scripts that write without spaces.

  Delphi and Free Pascal ({$MODE DELPHIUNICODE}), any platform, 32-bit targets included: this
  unit does not use the library. Needs LayaUnicode.pas and LayaArchive.pas.

  The method is that of the tokenizer of laya.cpp (src/tokenizer.cpp), the engine inside
  LibLayaX: Copyright (c) 2026 Lars Karlslund, MIT License. See NOTICE. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}
{$IFNDEF FPC}{$IF CompilerVersion >= 24}{$ZEROBASEDSTRINGS OFF}{$IFEND}{$ENDIF}
{$Q-}{$R-}

interface

uses
  SysUtils, Classes, LayaUnicode, LayaArchive;

const
  (* What the engine uses when rl_agent_config.json does not say otherwise. *)
  LayaDefaultMaxLen = 512;
  LayaDefaultHeadMaxLen = 192;

type
  ELayaTokenizer = class(Exception);

  TLayaTokenIds = array of Integer;
  TLayaInt64Array = array of Int64;
  TLayaBytesArray = array of TBytes;

  TLayaAddedToken = record
    Content: TLayaCodePoints;
    ByteLength: Integer;     (* length of the content in UTF-8 *)
    Id: Integer;
    Normalized: Boolean;     (* looked for after normalization, not before *)
    LStrip: Boolean;         (* swallows the white space in front of it *)
  end;

  TLayaTokenizer = class
  private
    FLoaded: Boolean;
    FMetaspace: Boolean;
    FVocabSize: Integer;

    (* Symbols: every text the BPE can hold in one position. A vocabulary entry is a symbol
      with its token id; a merge result that is not in the vocabulary is a symbol with id -1. *)
    FSymKeys: TLayaBytesArray;
    FSymIds: TLayaTokenIds;
    FSymCount: Integer;
    FSlots: TLayaTokenIds;
    FSlotMask: Integer;

    (* Merges: (left symbol, right symbol) -> rank and resulting symbol. *)
    FPairKeys: TLayaInt64Array;
    FPairRanks: TLayaTokenIds;
    FPairSyms: TLayaTokenIds;
    FPairMask: Integer;
    FPairCount: Integer;

    FByteSyms: array[0..255] of Integer;       (* byte-level: the symbol of each byte *)
    FFallbackSyms: array[0..255] of Integer;   (* metaspace: the byte fallback symbols *)

    FAdded: array of TLayaAddedToken;
    FAddedFirst: array[Boolean, 0..127] of Boolean;
    FAddedOther: array[Boolean] of Boolean;

    FClsToken, FSepToken, FPadToken, FMaskToken: string;
    FClsId, FSepId, FPadId, FMaskId: Integer;
    FMaxLen, FHeadMaxLen: Integer;
    FModelName: string;

    procedure Clear;
    procedure CheckLoaded;

    procedure GrowSlots;
    function FindSymbol(const Key: TBytes; Len: Integer): Integer;
    function AddSymbol(const Key: TBytes): Integer;
    procedure GrowPairs(NewSize: Integer);
    procedure AddPair(Left, Right, Rank, Sym: Integer);
    function FindPair(Left, Right: Integer; out Sym: Integer): Integer;

    procedure ParseTokenizer(const Data: TBytes);
    procedure ParseTokenizerConfig(const Data: TBytes);
    procedure ParseAgentConfig(const Data: TBytes);
    procedure ResolveSpecialTokens;

    procedure Merge(var Syms: TLayaTokenIds; Count: Integer; var Output: TLayaTokenIds;
      var OutCount: Integer);
    procedure MergeLong(var Syms: TLayaTokenIds; Count: Integer; var Output: TLayaTokenIds;
      var OutCount: Integer);
    procedure EncodeWordBytes(const Text: TLayaCodePoints; AFrom, ATo: Integer;
      var Output: TLayaTokenIds; var OutCount: Integer);
    procedure EncodeWordMeta(const Text: TLayaCodePoints; AFrom, ATo: Integer;
      var Output: TLayaTokenIds; var OutCount: Integer);
    procedure Ordinary(const Text: TLayaCodePoints; AFrom, ATo: Integer;
      var Output: TLayaTokenIds; var OutCount: Integer);
    function FindAdded(const Text: TLayaCodePoints; AFrom, ATo: Integer; Normalized: Boolean;
      out Position: Integer): Integer;
    procedure Split(const Text: TLayaCodePoints; Normalized: Boolean;
      var Output: TLayaTokenIds; var OutCount: Integer);
    function GetAddedTokenCount: Integer;
    function GetAddedToken(Index: Integer): TLayaAddedToken;
  public
    constructor Create;
    destructor Destroy; override;

    (* The model folder: the one that contains rl_agent_config.json and the tokenizer folder.
      Reads tokenizer/tokenizer.json, tokenizer/tokenizer_config.json and the two limits in
      rl_agent_config.json. For another model of the same store, give its own folder, for
      example ...\laya\multilingual.
      When the path names a file instead of a folder, it is taken to be a .tar archive of the
      model and LoadFromArchive reads it. *)
    procedure LoadFromModelDir(const AModelDir: string);

    (* A model packed in an uncompressed .tar archive, as LibLayaX loads it. The same three
      files are read from the archive. AFolder selects a model inside an archive that holds
      several, for example 'multilingual'; leave it empty otherwise. *)
    procedure LoadFromArchive(const AFileName: string; const AFolder: string = '');

    (* Only a tokenizer.json. The special tokens are then taken to be [CLS], [SEP], [PAD] and
      [MASK], and the limits 512 and 192. *)
    procedure LoadFromFile(const AFileName: string);
    procedure LoadFromStream(AStream: TStream);

    (* The token ids of a text: exactly what the tokenizer makes of it, nothing added.
      [CLS], [SEP] and the other special tokens written in the text are recognized. *)
    function Encode(const AText: string): TLayaTokenIds;
    function EncodeCodePoints(const AText: TLayaCodePoints): TLayaTokenIds;
    function CountTokens(const AText: string): Integer;

    (* The id of one vocabulary entry, or -1. *)
    function TokenToId(const AToken: string): Integer;

    property Loaded: Boolean read FLoaded;
    property Metaspace: Boolean read FMetaspace;
    property VocabSize: Integer read FVocabSize;

    property ClsToken: string read FClsToken;
    property SepToken: string read FSepToken;
    property PadToken: string read FPadToken;
    property MaskToken: string read FMaskToken;
    property ClsId: Integer read FClsId;
    property SepId: Integer read FSepId;
    property PadId: Integer read FPadId;
    property MaskId: Integer read FMaskId;

    (* From rl_agent_config.json: the longest input in tokens, and the part of it the
      question with its options may take. *)
    property MaxLen: Integer read FMaxLen;
    property HeadMaxLen: Integer read FHeadMaxLen;
    property ModelName: string read FModelName;

    property AddedTokenCount: Integer read GetAddedTokenCount;
    property AddedTokens[Index: Integer]: TLayaAddedToken read GetAddedToken;
  end;

(* The whole content of a file. Raises ELayaTokenizer if it cannot be read. *)
function LayaReadFile(const AFileName: string): TBytes;

implementation

const
  MetaspaceMark = $2581;   (* the "lower one eighth block" that stands for a space *)
  NoRank = MaxInt;
  (* Words of more symbols than this are merged with a heap, which stays fast for a word of
    any length: a long text in a script without spaces is one single word. *)
  LongWordSymbols = {$IFDEF LAYA_TEST_LONG_WORDS}1{$ELSE}64{$ENDIF};

(* ============================================================================ *)
(* Small helpers                                                                *)
(* ============================================================================ *)

function LayaReadFile(const AFileName: string): TBytes;
var
  Handle: THandle;
  Size: Int64;
  Done, Got: Integer;
begin
  Result := nil;
  Handle := FileOpen(AFileName, fmOpenRead or fmShareDenyWrite);
  if Handle = THandle(-1) then
    raise ELayaTokenizer.Create('Cannot open ' + AFileName);
  try
    Size := FileSeek(Handle, Int64(0), 2);
    if (Size < 0) or (Size > MaxInt) then
      raise ELayaTokenizer.Create('Cannot read ' + AFileName);
    FileSeek(Handle, Int64(0), 0);
    SetLength(Result, Integer(Size));
    Done := 0;
    while Done < Size do
    begin
      Got := FileRead(Handle, Result[Done], Integer(Size) - Done);
      if Got <= 0 then
        raise ELayaTokenizer.Create('Cannot read ' + AFileName);
      Inc(Done, Got);
    end;
  finally
    FileClose(Handle);
  end;
end;

function Utf8Bytes(const S: string): TBytes;
begin
  Result := LayaStringToUtf8(S);
end;

function SameBytes(const A: TBytes; ALen: Integer; const B: TBytes): Boolean;
var
  I: Integer;
begin
  Result := False;
  if ALen <> Length(B) then
    Exit;
  for I := 0 to ALen - 1 do
    if A[I] <> B[I] then
      Exit;
  Result := True;
end;

function IsText(const A: TBytes; const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(A) <> Length(S) then
    Exit;
  for I := 0 to High(A) do
    if A[I] <> Ord(S[I + 1]) then
      Exit;
  Result := True;
end;

function Concat2(const A, B: TBytes): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

(* UTF-8 of one code point into Buffer (at least 4 bytes); returns the length. *)
function PutUtf8(C: Integer; var Buffer: TBytes; At: Integer): Integer;
begin
  if C < $80 then
  begin
    Buffer[At] := C;
    Result := 1;
  end
  else if C < $800 then
  begin
    Buffer[At] := $C0 or (C shr 6);
    Buffer[At + 1] := $80 or (C and $3F);
    Result := 2;
  end
  else if C < $10000 then
  begin
    Buffer[At] := $E0 or (C shr 12);
    Buffer[At + 1] := $80 or ((C shr 6) and $3F);
    Buffer[At + 2] := $80 or (C and $3F);
    Result := 3;
  end
  else
  begin
    Buffer[At] := $F0 or (C shr 18);
    Buffer[At + 1] := $80 or ((C shr 12) and $3F);
    Buffer[At + 2] := $80 or ((C shr 6) and $3F);
    Buffer[At + 3] := $80 or (C and $3F);
    Result := 4;
  end;
end;

function Utf8Of(C: Integer): TBytes;
begin
  Result := nil;
  SetLength(Result, 4);
  SetLength(Result, PutUtf8(C, Result, 0));
end;

function HashBytes(const Key: TBytes; Len: Integer): Cardinal;
var
  I: Integer;
  H: UInt64;
begin
  H := 2166136261;
  for I := 0 to Len - 1 do
    H := ((H xor Key[I]) * 16777619) and $FFFFFFFF;
  Result := Cardinal(H);
end;

function HashPair(Left, Right: Integer): Cardinal;
var
  H: UInt64;
begin
  H := (UInt64(Cardinal(Left)) * 2654435761) and $FFFFFFFF;
  H := H xor ((UInt64(Cardinal(Right)) * 2246822519) and $FFFFFFFF);
  H := H xor (H shr 15);
  Result := Cardinal(H and $FFFFFFFF);
end;

procedure Push(var Output: TLayaTokenIds; var Count: Integer; Value: Integer);
begin
  if Count = Length(Output) then
    SetLength(Output, Count * 2 + 64);
  Output[Count] := Value;
  Inc(Count);
end;

(* ============================================================================ *)
(* A small JSON reader                                                          *)
(*                                                                              *)
(* tokenizer.json is a few megabytes with tens of thousands of entries. This    *)
(* reader walks it once and hands out the pieces; it builds no document tree.   *)
(* ============================================================================ *)

type
  TJsonReader = class
  private
    FData: TBytes;
    FPos, FLen: Integer;
    procedure SkipSpace;
    procedure Fail(const What: string);
    function Hex4: Integer;
  public
    constructor Create(const AData: TBytes);
    function Peek: Integer;                         (* next significant byte, -1 at the end *)
    procedure Expect(C: Integer);
    (* After Expect('{'): the next key, or False at the closing brace. *)
    function NextKey(out Key: TBytes): Boolean;
    (* After Expect('['): True if another element follows, False at the closing bracket. *)
    function NextElement: Boolean;
    function ReadString: TBytes;
    function ReadLiteral: TBytes;                   (* a number, true, false or null, as written *)
    function ReadInteger: Integer;
    procedure Skip;                                 (* any value *)
  end;

  (* A small JSON value read whole: only for the short settings objects. *)
  TFlatKind = (fkString, fkOther);
  TFlatEntry = record
    Path: string;       (* "pattern.String" for nested objects *)
    Kind: TFlatKind;
    Value: TBytes;      (* string content, or the literal as written *)
  end;
  TFlat = record
    Present: Boolean;
    IsObject: Boolean;
    Entries: array of TFlatEntry;
  end;

constructor TJsonReader.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
  FLen := Length(AData);
  FPos := 0;
  (* a byte order mark is not JSON, but files carry it *)
  if (FLen >= 3) and (FData[0] = $EF) and (FData[1] = $BB) and (FData[2] = $BF) then
    FPos := 3;
end;

procedure TJsonReader.Fail(const What: string);
begin
  raise ELayaTokenizer.CreateFmt('Invalid JSON at byte %d: %s', [FPos, What]);
end;

procedure TJsonReader.SkipSpace;
begin
  while (FPos < FLen) and ((FData[FPos] = $20) or (FData[FPos] = $0A) or (FData[FPos] = $0D) or
    (FData[FPos] = $09)) do
    Inc(FPos);
end;

function TJsonReader.Peek: Integer;
begin
  SkipSpace;
  if FPos < FLen then Result := FData[FPos] else Result := -1;
end;

procedure TJsonReader.Expect(C: Integer);
begin
  if Peek <> C then
    Fail('expected "' + Char(C) + '"');
  Inc(FPos);
end;

function TJsonReader.NextKey(out Key: TBytes): Boolean;
begin
  Key := nil;
  if Peek = Ord(',') then
    Inc(FPos);
  if Peek = Ord('}') then
  begin
    Inc(FPos);
    Result := False;
    Exit;
  end;
  Key := ReadString;
  Expect(Ord(':'));
  Result := True;
end;

function TJsonReader.NextElement: Boolean;
begin
  if Peek = Ord(',') then
    Inc(FPos);
  if Peek = Ord(']') then
  begin
    Inc(FPos);
    Result := False;
  end
  else
    Result := True;
end;

function TJsonReader.Hex4: Integer;
var
  I, C: Integer;
begin
  Result := 0;
  if FPos + 4 > FLen then
    Fail('unfinished \u escape');
  for I := 0 to 3 do
  begin
    C := FData[FPos + I];
    if (C >= Ord('0')) and (C <= Ord('9')) then C := C - Ord('0')
    else if (C >= Ord('a')) and (C <= Ord('f')) then C := C - Ord('a') + 10
    else if (C >= Ord('A')) and (C <= Ord('F')) then C := C - Ord('A') + 10
    else Fail('bad \u escape');
    Result := Result * 16 + C;
  end;
  Inc(FPos, 4);
end;

function TJsonReader.ReadString: TBytes;
var
  Start, N, C, D: Integer;
  Simple: Boolean;
begin
  Result := nil;
  Expect(Ord('"'));
  (* first pass: find the end, and see whether there is anything to unescape *)
  Start := FPos;
  Simple := True;
  while True do
  begin
    if FPos >= FLen then
      Fail('unfinished string');
    C := FData[FPos];
    if C = Ord('"') then
      Break;
    if C = Ord('\') then
    begin
      Simple := False;
      Inc(FPos);
    end;
    Inc(FPos);
  end;
  if Simple then
  begin
    N := FPos - Start;
    SetLength(Result, N);
    if N > 0 then
      Move(FData[Start], Result[0], N);
    Inc(FPos);
    Exit;
  end;
  (* second pass with unescaping; the result is never longer than the source *)
  SetLength(Result, FPos - Start);
  FPos := Start;
  N := 0;
  while True do
  begin
    C := FData[FPos];
    Inc(FPos);
    if C = Ord('"') then
      Break;
    if C <> Ord('\') then
    begin
      Result[N] := C;
      Inc(N);
      Continue;
    end;
    C := FData[FPos];
    Inc(FPos);
    case C of
      Ord('b'): C := 8;
      Ord('f'): C := 12;
      Ord('n'): C := 10;
      Ord('r'): C := 13;
      Ord('t'): C := 9;
      Ord('u'):
        begin
          C := Hex4;
          if (C >= $D800) and (C <= $DBFF) then
          begin
            (* a surrogate pair written as two escapes *)
            if (FPos + 1 < FLen) and (FData[FPos] = Ord('\')) and (FData[FPos + 1] = Ord('u')) then
            begin
              Inc(FPos, 2);
              D := Hex4;
              if (D >= $DC00) and (D <= $DFFF) then
                C := $10000 + ((C - $D800) shl 10) + (D - $DC00)
              else
                Fail('bad surrogate pair');
            end
            else
              Fail('bad surrogate pair');
          end
          else if (C >= $DC00) and (C <= $DFFF) then
            Fail('bad surrogate pair');
          Inc(N, PutUtf8(C, Result, N));
          Continue;
        end;
    else
      (* quote, backslash and slash stand for themselves *)
      if (C <> Ord('"')) and (C <> Ord('\')) and (C <> Ord('/')) then
        Fail('bad escape');
    end;
    Result[N] := C;
    Inc(N);
  end;
  SetLength(Result, N);
end;

function TJsonReader.ReadLiteral: TBytes;
var
  Start, C: Integer;
begin
  Result := nil;
  SkipSpace;
  Start := FPos;
  while FPos < FLen do
  begin
    C := FData[FPos];
    if (C = Ord(',')) or (C = Ord('}')) or (C = Ord(']')) or (C = $20) or (C = $0A) or
       (C = $0D) or (C = $09) then
      Break;
    Inc(FPos);
  end;
  if FPos = Start then
    Fail('a value is missing');
  SetLength(Result, FPos - Start);
  Move(FData[Start], Result[0], FPos - Start);
end;

function TJsonReader.ReadInteger: Integer;
var
  Text: TBytes;
  I: Integer;
  Negative: Boolean;
  Value: Int64;
begin
  Text := ReadLiteral;
  Negative := Text[0] = Ord('-');
  if Negative then I := 1 else I := 0;
  if I > High(Text) then
    Fail('a whole number was expected');
  Value := 0;
  while I <= High(Text) do
  begin
    if (Text[I] < Ord('0')) or (Text[I] > Ord('9')) or (Value > MaxInt) then
      Fail('a whole number was expected');
    Value := Value * 10 + (Text[I] - Ord('0'));
    Inc(I);
  end;
  if Value > MaxInt then
    Fail('a whole number was expected');
  if Negative then Result := -Integer(Value) else Result := Integer(Value);
end;

procedure TJsonReader.Skip;
var
  Key: TBytes;
begin
  case Peek of
    Ord('{'):
      begin
        Inc(FPos);
        while NextKey(Key) do
          Skip;
      end;
    Ord('['):
      begin
        Inc(FPos);
        while NextElement do
          Skip;
      end;
    Ord('"'):
      ReadString;
    -1:
      Fail('unexpected end');
  else
    ReadLiteral;
  end;
end;

procedure ReadFlatInto(Reader: TJsonReader; const Prefix: string; var Flat: TFlat);
var
  Key: TBytes;
  N: Integer;
  Path: string;
begin
  Reader.Expect(Ord('{'));
  while Reader.NextKey(Key) do
  begin
    Path := Prefix + LayaUtf8ToString(Key);
    case Reader.Peek of
      Ord('{'):
        ReadFlatInto(Reader, Path + '.', Flat);
      Ord('['):
        begin
          (* no setting the engine looks at is a list; remember that it was there *)
          Reader.Skip;
          N := Length(Flat.Entries);
          SetLength(Flat.Entries, N + 1);
          Flat.Entries[N].Path := Path;
          Flat.Entries[N].Kind := fkOther;
          Flat.Entries[N].Value := Utf8Bytes('[]');
        end;
    else
      N := Length(Flat.Entries);
      SetLength(Flat.Entries, N + 1);
      Flat.Entries[N].Path := Path;
      if Reader.Peek = Ord('"') then
      begin
        Flat.Entries[N].Kind := fkString;
        Flat.Entries[N].Value := Reader.ReadString;
      end
      else
      begin
        Flat.Entries[N].Kind := fkOther;
        Flat.Entries[N].Value := Reader.ReadLiteral;
      end;
    end;
  end;
end;

function ReadFlat(Reader: TJsonReader): TFlat;
begin
  Result.Present := True;
  Result.Entries := nil;
  Result.IsObject := Reader.Peek = Ord('{');
  if Result.IsObject then
    ReadFlatInto(Reader, '', Result)
  else
    Reader.Skip;
end;

function FlatFind(const Flat: TFlat; const Path: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(Flat.Entries) do
    if Flat.Entries[I].Path = Path then
    begin
      Result := I;
      Exit;
    end;
end;

function FlatIsString(const Flat: TFlat; const Path: string; const Value: TBytes): Boolean;
var
  I: Integer;
begin
  I := FlatFind(Flat, Path);
  Result := (I >= 0) and (Flat.Entries[I].Kind = fkString) and
    SameBytes(Flat.Entries[I].Value, Length(Flat.Entries[I].Value), Value);
end;

function FlatIsLiteral(const Flat: TFlat; const Path, Literal: string): Boolean;
var
  I: Integer;
begin
  I := FlatFind(Flat, Path);
  Result := (I >= 0) and (Flat.Entries[I].Kind = fkOther) and IsText(Flat.Entries[I].Value, Literal);
end;

(* ============================================================================ *)
(* TLayaTokenizer: construction                                                 *)
(* ============================================================================ *)

constructor TLayaTokenizer.Create;
begin
  inherited Create;
  Clear;
end;

destructor TLayaTokenizer.Destroy;
begin
  Clear;
  inherited;
end;

procedure TLayaTokenizer.Clear;
var
  I: Integer;
  B: Boolean;
begin
  FLoaded := False;
  FMetaspace := False;
  FVocabSize := 0;
  FSymKeys := nil;
  FSymIds := nil;
  FSymCount := 0;
  FSlots := nil;
  FSlotMask := 0;
  FPairKeys := nil;
  FPairRanks := nil;
  FPairSyms := nil;
  FPairMask := 0;
  FPairCount := 0;
  FAdded := nil;
  for I := 0 to 255 do
  begin
    FByteSyms[I] := -1;
    FFallbackSyms[I] := -1;
  end;
  for B := False to True do
  begin
    for I := 0 to 127 do
      FAddedFirst[B, I] := False;
    FAddedOther[B] := False;
  end;
  FClsToken := '[CLS]';
  FSepToken := '[SEP]';
  FPadToken := '[PAD]';
  FMaskToken := '[MASK]';
  FClsId := -1;
  FSepId := -1;
  FPadId := -1;
  FMaskId := -1;
  FMaxLen := LayaDefaultMaxLen;
  FHeadMaxLen := LayaDefaultHeadMaxLen;
  FModelName := '';
end;

procedure TLayaTokenizer.CheckLoaded;
begin
  if not FLoaded then
    raise ELayaTokenizer.Create('Tokenizer has not been loaded.');
end;

function TLayaTokenizer.GetAddedTokenCount: Integer;
begin
  Result := Length(FAdded);
end;

function TLayaTokenizer.GetAddedToken(Index: Integer): TLayaAddedToken;
begin
  if (Index < 0) or (Index > High(FAdded)) then
    raise ELayaTokenizer.CreateFmt('Added token index %d is out of range', [Index]);
  Result := FAdded[Index];
end;

(* ============================================================================ *)
(* Symbol table and merge table                                                 *)
(* ============================================================================ *)

procedure TLayaTokenizer.GrowSlots;
var
  I, Size: Integer;
  H: Cardinal;
begin
  Size := Length(FSlots) * 2;
  if Size < 1024 then
    Size := 1024;
  FSlots := nil;
  SetLength(FSlots, Size);
  FSlotMask := Size - 1;
  for I := 0 to Size - 1 do
    FSlots[I] := -1;
  for I := 0 to FSymCount - 1 do
  begin
    H := HashBytes(FSymKeys[I], Length(FSymKeys[I])) and Cardinal(FSlotMask);
    while FSlots[H] >= 0 do
      H := (H + 1) and Cardinal(FSlotMask);
    FSlots[H] := I;
  end;
end;

function TLayaTokenizer.FindSymbol(const Key: TBytes; Len: Integer): Integer;
var
  H: Cardinal;
begin
  Result := -1;
  if FSlotMask = 0 then
    Exit;
  H := HashBytes(Key, Len) and Cardinal(FSlotMask);
  while FSlots[H] >= 0 do
  begin
    if SameBytes(Key, Len, FSymKeys[FSlots[H]]) then
    begin
      Result := FSlots[H];
      Exit;
    end;
    H := (H + 1) and Cardinal(FSlotMask);
  end;
end;

function TLayaTokenizer.AddSymbol(const Key: TBytes): Integer;
var
  H: Cardinal;
begin
  Result := FindSymbol(Key, Length(Key));
  if Result >= 0 then
    Exit;
  if (FSymCount + 1) * 2 > Length(FSlots) then
    GrowSlots;
  if FSymCount = Length(FSymKeys) then
  begin
    SetLength(FSymKeys, FSymCount * 2 + 1024);
    SetLength(FSymIds, Length(FSymKeys));
  end;
  Result := FSymCount;
  FSymKeys[Result] := Key;
  FSymIds[Result] := -1;
  Inc(FSymCount);
  H := HashBytes(Key, Length(Key)) and Cardinal(FSlotMask);
  while FSlots[H] >= 0 do
    H := (H + 1) and Cardinal(FSlotMask);
  FSlots[H] := Result;
end;

procedure TLayaTokenizer.GrowPairs(NewSize: Integer);
var
  OldKeys: TLayaInt64Array;
  OldRanks, OldSyms: TLayaTokenIds;
  I: Integer;
begin
  OldKeys := FPairKeys;
  OldRanks := FPairRanks;
  OldSyms := FPairSyms;
  FPairKeys := nil;
  FPairRanks := nil;
  FPairSyms := nil;
  SetLength(FPairKeys, NewSize);
  SetLength(FPairRanks, NewSize);
  SetLength(FPairSyms, NewSize);
  FPairMask := NewSize - 1;
  FPairCount := 0;
  for I := 0 to NewSize - 1 do
    FPairKeys[I] := -1;
  for I := 0 to High(OldKeys) do
    if OldKeys[I] >= 0 then
      AddPair(Integer(OldKeys[I] shr 32), Integer(OldKeys[I] and $FFFFFFFF), OldRanks[I], OldSyms[I]);
end;

procedure TLayaTokenizer.AddPair(Left, Right, Rank, Sym: Integer);
var
  Key: Int64;
  H: Cardinal;
begin
  if (FPairCount + 1) * 2 > Length(FPairKeys) then
  begin
    if Length(FPairKeys) = 0 then GrowPairs(1024) else GrowPairs(Length(FPairKeys) * 2);
  end;
  Key := (Int64(Left) shl 32) or Int64(Right);
  H := HashPair(Left, Right) and Cardinal(FPairMask);
  while FPairKeys[H] >= 0 do
  begin
    if FPairKeys[H] = Key then
      Exit;                      (* the same pair twice: the first one counts, as in the engine *)
    H := (H + 1) and Cardinal(FPairMask);
  end;
  FPairKeys[H] := Key;
  FPairRanks[H] := Rank;
  FPairSyms[H] := Sym;
  Inc(FPairCount);
end;

function TLayaTokenizer.FindPair(Left, Right: Integer; out Sym: Integer): Integer;
var
  Key: Int64;
  H: Cardinal;
begin
  Result := NoRank;
  Sym := -1;
  if FPairCount = 0 then
    Exit;
  Key := (Int64(Left) shl 32) or Int64(Right);
  H := HashPair(Left, Right) and Cardinal(FPairMask);
  while FPairKeys[H] >= 0 do
  begin
    if FPairKeys[H] = Key then
    begin
      Result := FPairRanks[H];
      Sym := FPairSyms[H];
      Exit;
    end;
    H := (H + 1) and Cardinal(FPairMask);
  end;
end;

(* ============================================================================ *)
(* Loading                                                                      *)
(* ============================================================================ *)

procedure TLayaTokenizer.LoadFromArchive(const AFileName, AFolder: string);
var
  Archive: TLayaArchive;
  Folder: string;
begin
  Clear;
  try
    Folder := AFolder;
    while (Folder <> '') and ((Folder[Length(Folder)] = '/') or (Folder[Length(Folder)] = '\')) do
      SetLength(Folder, Length(Folder) - 1);
    if Folder <> '' then Folder := Folder + '/';
    try
      Archive := TLayaArchive.Create(AFileName);
      try
        ParseTokenizer(Archive.ReadFile(Folder + 'tokenizer/tokenizer.json'));
        if Archive.Exists(Folder + 'tokenizer/tokenizer_config.json') then
          ParseTokenizerConfig(Archive.ReadFile(Folder + 'tokenizer/tokenizer_config.json'));
        if Archive.Exists(Folder + 'rl_agent_config.json') then
          ParseAgentConfig(Archive.ReadFile(Folder + 'rl_agent_config.json'));
      finally
        Archive.Free;
      end;
    except
      on E: ELayaArchive do
        raise ELayaTokenizer.Create(E.Message);
    end;
    ResolveSpecialTokens;
    FLoaded := True;
  except
    Clear;
    raise;
  end;
end;

procedure TLayaTokenizer.LoadFromModelDir(const AModelDir: string);
var
  Dir, Name: string;
begin
  if LayaIsArchiveFile(AModelDir) then
  begin
    LoadFromArchive(AModelDir);
    Exit;
  end;
  Clear;
  try
    Dir := IncludeTrailingPathDelimiter(AModelDir);
    ParseTokenizer(LayaReadFile(Dir + 'tokenizer' + PathDelim + 'tokenizer.json'));
    Name := Dir + 'tokenizer' + PathDelim + 'tokenizer_config.json';
    if FileExists(Name) then
      ParseTokenizerConfig(LayaReadFile(Name));
    Name := Dir + 'rl_agent_config.json';
    if FileExists(Name) then
      ParseAgentConfig(LayaReadFile(Name));
    ResolveSpecialTokens;
    FLoaded := True;
  except
    Clear;
    raise;
  end;
end;

procedure TLayaTokenizer.LoadFromFile(const AFileName: string);
begin
  Clear;
  try
    ParseTokenizer(LayaReadFile(AFileName));
    ResolveSpecialTokens;
    FLoaded := True;
  except
    Clear;
    raise;
  end;
end;

procedure TLayaTokenizer.LoadFromStream(AStream: TStream);
var
  Data: TBytes;
  Size: Int64;
begin
  if AStream = nil then
    raise ELayaTokenizer.Create('The stream is nil.');
  Clear;
  try
    Size := AStream.Size - AStream.Position;
    if (Size < 0) or (Size > MaxInt) then
      raise ELayaTokenizer.Create('The stream cannot be read.');
    Data := nil;
    SetLength(Data, Integer(Size));
    if Size > 0 then
      AStream.ReadBuffer(Data[0], Integer(Size));
    ParseTokenizer(Data);
    ResolveSpecialTokens;
    FLoaded := True;
  except
    Clear;
    raise;
  end;
end;

procedure TLayaTokenizer.ParseTokenizer(const Data: TBytes);
type
  TPendingAdded = record
    Content: TBytes;
    Id: Integer;
    Normalized, LStrip: Boolean;
  end;
var
  Reader: TJsonReader;
  Key, Sub, Left, Right, Text, Mark, FallbackName: TBytes;
  Normalizer, PreTokenizer: TFlat;
  ModelType: TBytes;
  ByteFallback, IgnoreMerges, HaveModel, DropoutIsNull, ByteLevel, MetaOk, Flag: Boolean;
  MergeLeft, MergeRight: TLayaBytesArray;
  MergeCount: Integer;
  Pending: array of TPendingAdded;
  PendingCount: Integer;
  Item: TPendingAdded;
  SingleWord, RStrip, HasContent, HasId, HasNormalized, HasLStrip, HasSingle, HasRStrip: Boolean;
  I, J, K, Sym, Id, Next, A, B, C: Integer;
  Token: TLayaAddedToken;
  Points: TLayaCodePoints;
const
  Hex: string = '0123456789ABCDEF';

  procedure Unsupported;
  begin
    raise ELayaTokenizer.Create('Unsupported tokenizer configuration');
  end;

  function ReadBool: Boolean;
  var
    L: TBytes;
  begin
    L := Reader.ReadLiteral;
    if IsText(L, 'true') then Result := True
    else if IsText(L, 'false') then Result := False
    else
    begin
      Result := False;
      Unsupported;
    end;
  end;

begin
  Pending := nil;
  MergeLeft := nil;
  MergeRight := nil;
  Normalizer.Present := False;
  PreTokenizer.Present := False;
  DropoutIsNull := False;
  ModelType := nil;
  ByteFallback := False;
  IgnoreMerges := False;
  HaveModel := False;
  MergeCount := 0;
  PendingCount := 0;

  Reader := TJsonReader.Create(Data);
  try
    Reader.Expect(Ord('{'));
    while Reader.NextKey(Key) do
    begin
      if IsText(Key, 'normalizer') then
        Normalizer := ReadFlat(Reader)
      else if IsText(Key, 'pre_tokenizer') then
        PreTokenizer := ReadFlat(Reader)
      else if IsText(Key, 'added_tokens') then
      begin
        Reader.Expect(Ord('['));
        while Reader.NextElement do
        begin
          Item.Content := nil;
          Item.Id := 0;
          Item.Normalized := False;
          Item.LStrip := False;
          SingleWord := False;
          RStrip := False;
          HasContent := False; HasId := False; HasNormalized := False;
          HasLStrip := False; HasSingle := False; HasRStrip := False;
          Reader.Expect(Ord('{'));
          while Reader.NextKey(Sub) do
          begin
            if IsText(Sub, 'content') then begin Item.Content := Reader.ReadString; HasContent := True; end
            else if IsText(Sub, 'id') then begin Item.Id := Reader.ReadInteger; HasId := True; end
            else if IsText(Sub, 'normalized') then begin Item.Normalized := ReadBool; HasNormalized := True; end
            else if IsText(Sub, 'lstrip') then begin Item.LStrip := ReadBool; HasLStrip := True; end
            else if IsText(Sub, 'single_word') then begin SingleWord := ReadBool; HasSingle := True; end
            else if IsText(Sub, 'rstrip') then begin RStrip := ReadBool; HasRStrip := True; end
            else Reader.Skip;
          end;
          if not (HasContent and HasId and HasNormalized and HasLStrip and HasSingle and HasRStrip) then
            raise ELayaTokenizer.Create('An added token lacks one of its fields');
          if SingleWord or RStrip then
            raise ELayaTokenizer.Create('Unsupported added-token boundary flags');
          if PendingCount = Length(Pending) then
            SetLength(Pending, PendingCount * 2 + 64);
          Pending[PendingCount] := Item;
          Inc(PendingCount);
        end;
      end
      else if IsText(Key, 'model') then
      begin
        HaveModel := True;
        Reader.Expect(Ord('{'));
        while Reader.NextKey(Sub) do
        begin
          if IsText(Sub, 'type') then
            ModelType := Reader.ReadString
          else if IsText(Sub, 'dropout') then
          begin
            if Reader.Peek = Ord('n') then
              DropoutIsNull := IsText(Reader.ReadLiteral, 'null')
            else
              Reader.Skip;
          end
          else if IsText(Sub, 'byte_fallback') then
            ByteFallback := ReadBool
          else if IsText(Sub, 'ignore_merges') then
            IgnoreMerges := ReadBool
          else if IsText(Sub, 'vocab') then
          begin
            Reader.Expect(Ord('{'));
            while Reader.NextKey(Text) do
            begin
              Id := Reader.ReadInteger;
              Sym := AddSymbol(Text);
              if FSymIds[Sym] < 0 then
                FSymIds[Sym] := Id;
            end;
          end
          else if IsText(Sub, 'merges') then
          begin
            Reader.Expect(Ord('['));
            while Reader.NextElement do
            begin
              Left := nil;
              Right := nil;
              if Reader.Peek <> Ord('[') then
                raise ELayaTokenizer.Create('Unsupported BPE merge format');
              Reader.Expect(Ord('['));
              I := 0;
              while Reader.NextElement do
              begin
                if (I > 1) or (Reader.Peek <> Ord('"')) then
                  raise ELayaTokenizer.Create('Unsupported BPE merge format');
                if I = 0 then Left := Reader.ReadString else Right := Reader.ReadString;
                Inc(I);
              end;
              if I <> 2 then
                raise ELayaTokenizer.Create('Unsupported BPE merge format');
              if MergeCount = Length(MergeLeft) then
              begin
                SetLength(MergeLeft, MergeCount * 2 + 4096);
                SetLength(MergeRight, Length(MergeLeft));
              end;
              MergeLeft[MergeCount] := Left;
              MergeRight[MergeCount] := Right;
              Inc(MergeCount);
            end;
          end
          else
            Reader.Skip;
        end;
      end
      else
        Reader.Skip;
    end;
  finally
    Reader.Free;
  end;

  (* The same checks as the engine: only the two tokenizer kinds it was written for. *)
  if not (HaveModel and Normalizer.Present and PreTokenizer.Present and DropoutIsNull) then
    Unsupported;
  Mark := Utf8Of(MetaspaceMark);
  FMetaspace := FlatIsString(PreTokenizer, 'type', Utf8Bytes('Metaspace'));
  ByteLevel := FlatIsString(Normalizer, 'type', Utf8Bytes('NFC')) and
    FlatIsString(PreTokenizer, 'type', Utf8Bytes('ByteLevel')) and
    FlatIsLiteral(PreTokenizer, 'add_prefix_space', 'false') and
    FlatIsLiteral(PreTokenizer, 'use_regex', 'true') and not ByteFallback;
  MetaOk := FMetaspace and (Length(Normalizer.Entries) = 3) and
    FlatIsString(Normalizer, 'type', Utf8Bytes('Replace')) and
    FlatIsString(Normalizer, 'pattern.String', Utf8Bytes(' ')) and
    FlatIsString(Normalizer, 'content', Mark) and
    FlatIsString(PreTokenizer, 'replacement', Mark) and
    FlatIsString(PreTokenizer, 'prepend_scheme', Utf8Bytes('always')) and
    FlatIsLiteral(PreTokenizer, 'split', 'true') and ByteFallback;
  if not IsText(ModelType, 'BPE') or not (ByteLevel or MetaOk) or IgnoreMerges then
    Unsupported;

  (* Added tokens enter the vocabulary too, and replace an entry of the same text. *)
  for I := 0 to PendingCount - 1 do
  begin
    Sym := AddSymbol(Pending[I].Content);
    FSymIds[Sym] := Pending[I].Id;
  end;
  FVocabSize := FSymCount;

  (* Byte symbols. *)
  if FMetaspace then
  begin
    SetLength(FallbackName, 6);
    for I := 0 to 255 do
    begin
      FallbackName[0] := Ord('<');
      FallbackName[1] := Ord('0');
      FallbackName[2] := Ord('x');
      FallbackName[3] := Ord(Hex[I div 16 + 1]);
      FallbackName[4] := Ord(Hex[I mod 16 + 1]);
      FallbackName[5] := Ord('>');
      Sym := FindSymbol(FallbackName, 6);
      if Sym < 0 then
      begin
        Text := nil;
        SetLength(Text, 1);
        Text[0] := I;
        if I < 128 then Sym := FindSymbol(Text, 1) else Sym := -1;
        if Sym < 0 then
          raise ELayaTokenizer.Create('Missing byte fallback token');
      end;
      FFallbackSyms[I] := Sym;
    end;
  end
  else
  begin
    Next := 256;
    for I := 0 to 255 do
    begin
      if ((I >= 33) and (I <= 126)) or ((I >= 161) and (I <= 172)) or (I >= 174) then
        FByteSyms[I] := AddSymbol(Utf8Of(I))
      else
      begin
        FByteSyms[I] := AddSymbol(Utf8Of(Next));
        Inc(Next);
      end;
    end;
  end;

  (* Merges, in the order of the file: the position is the rank. *)
  for I := 0 to MergeCount - 1 do
  begin
    A := AddSymbol(MergeLeft[I]);
    B := AddSymbol(MergeRight[I]);
    C := AddSymbol(Concat2(MergeLeft[I], MergeRight[I]));
    AddPair(A, B, I, C);
  end;

  (* Added tokens: longest first (in bytes, as the engine sorts them), otherwise in file order. *)
  SetLength(FAdded, PendingCount);
  K := 0;
  for I := 0 to PendingCount - 1 do
  begin
    if Length(Pending[I].Content) = 0 then
      Continue;   (* an empty token would match everywhere *)
    Token.Content := LayaUtf8ToCodePoints(Pending[I].Content);
    Token.ByteLength := Length(Pending[I].Content);
    Token.Id := Pending[I].Id;
    Token.Normalized := Pending[I].Normalized;
    Token.LStrip := Pending[I].LStrip;
    J := K;
    while (J > 0) and (FAdded[J - 1].ByteLength < Token.ByteLength) do
    begin
      FAdded[J] := FAdded[J - 1];
      Dec(J);
    end;
    FAdded[J] := Token;
    Inc(K);
  end;
  SetLength(FAdded, K);
  for I := 0 to High(FAdded) do
  begin
    Points := FAdded[I].Content;
    Flag := FAdded[I].Normalized;
    if Points[0] < 128 then
      FAddedFirst[Flag, Points[0]] := True
    else
      FAddedOther[Flag] := True;
  end;
end;

procedure TLayaTokenizer.ParseTokenizerConfig(const Data: TBytes);
var
  Reader: TJsonReader;
  Key, Sub, Value: TBytes;
  Found: Boolean;
begin
  Reader := TJsonReader.Create(Data);
  try
    Reader.Expect(Ord('{'));
    while Reader.NextKey(Key) do
    begin
      if IsText(Key, 'cls_token') or IsText(Key, 'sep_token') or IsText(Key, 'pad_token') or
         IsText(Key, 'mask_token') then
      begin
        (* either the text itself or an object with the text in "content" *)
        Value := nil;
        Found := False;
        if Reader.Peek = Ord('"') then
        begin
          Value := Reader.ReadString;
          Found := True;
        end
        else if Reader.Peek = Ord('{') then
        begin
          Reader.Expect(Ord('{'));
          while Reader.NextKey(Sub) do
            if IsText(Sub, 'content') and (Reader.Peek = Ord('"')) then
            begin
              Value := Reader.ReadString;
              Found := True;
            end
            else
              Reader.Skip;
        end
        else
          Reader.Skip;
        if Found then
        begin
          if IsText(Key, 'cls_token') then FClsToken := LayaUtf8ToString(Value)
          else if IsText(Key, 'sep_token') then FSepToken := LayaUtf8ToString(Value)
          else if IsText(Key, 'pad_token') then FPadToken := LayaUtf8ToString(Value)
          else FMaskToken := LayaUtf8ToString(Value);
        end;
      end
      else
        Reader.Skip;
    end;
  finally
    Reader.Free;
  end;
end;

procedure TLayaTokenizer.ParseAgentConfig(const Data: TBytes);
var
  Reader: TJsonReader;
  Key: TBytes;
begin
  Reader := TJsonReader.Create(Data);
  try
    Reader.Expect(Ord('{'));
    while Reader.NextKey(Key) do
    begin
      if IsText(Key, 'max_len') then
        FMaxLen := Reader.ReadInteger
      else if IsText(Key, 'head_max_len') then
        FHeadMaxLen := Reader.ReadInteger
      else if IsText(Key, 'model_name') and (Reader.Peek = Ord('"')) then
        FModelName := LayaUtf8ToString(Reader.ReadString)
      else
        Reader.Skip;
    end;
  finally
    Reader.Free;
  end;
end;

procedure TLayaTokenizer.ResolveSpecialTokens;

  function IdOf(const Token: string): Integer;
  var
    Key: TBytes;
    Sym: Integer;
  begin
    Key := Utf8Bytes(Token);
    Sym := FindSymbol(Key, Length(Key));
    if (Sym >= 0) and (Sym < FVocabSize) then Result := FSymIds[Sym] else Result := -1;
  end;

begin
  FClsId := IdOf(FClsToken);
  FSepId := IdOf(FSepToken);
  FPadId := IdOf(FPadToken);
  FMaskId := IdOf(FMaskToken);
end;

function TLayaTokenizer.TokenToId(const AToken: string): Integer;
var
  Key: TBytes;
  Sym: Integer;
begin
  CheckLoaded;
  Key := Utf8Bytes(AToken);
  Sym := FindSymbol(Key, Length(Key));
  if (Sym >= 0) and (Sym < FVocabSize) then Result := FSymIds[Sym] else Result := -1;
end;

(* ============================================================================ *)
(* BPE                                                                          *)
(* ============================================================================ *)

(* Joins the symbols of one word by the merge table and appends the token ids. In every round
  the pair with the lowest rank is joined, the leftmost one if there are several. *)
procedure TLayaTokenizer.Merge(var Syms: TLayaTokenIds; Count: Integer; var Output: TLayaTokenIds;
  var OutCount: Integer);
var
  Ranks, Joined: TLayaTokenIds;
  I, Best, At: Integer;
begin
  if Count > LongWordSymbols then
  begin
    MergeLong(Syms, Count, Output, OutCount);
    Exit;
  end;
  if Count > 1 then
  begin
    Ranks := nil;
    Joined := nil;
    SetLength(Ranks, Count);
    SetLength(Joined, Count);
    for I := 0 to Count - 2 do
      Ranks[I] := FindPair(Syms[I], Syms[I + 1], Joined[I]);
    while Count > 1 do
    begin
      Best := NoRank;
      At := -1;
      for I := 0 to Count - 2 do
        if Ranks[I] < Best then
        begin
          Best := Ranks[I];
          At := I;
        end;
      if At < 0 then
        Break;
      Syms[At] := Joined[At];
      for I := At + 1 to Count - 2 do
      begin
        Syms[I] := Syms[I + 1];
        Ranks[I] := Ranks[I + 1];
        Joined[I] := Joined[I + 1];
      end;
      Dec(Count);
      if At > 0 then
        Ranks[At - 1] := FindPair(Syms[At - 1], Syms[At], Joined[At - 1]);
      if At < Count - 1 then
        Ranks[At] := FindPair(Syms[At], Syms[At + 1], Joined[At])
      else
        Ranks[At] := NoRank;
    end;
  end;
  for I := 0 to Count - 1 do
  begin
    if (Syms[I] < 0) or (FSymIds[Syms[I]] < 0) then
      raise ELayaTokenizer.Create('The tokenizer has no token for a piece of this text');
    Push(Output, OutCount, FSymIds[Syms[I]]);
  end;
end;

(* The same result as Merge, for long words. The symbols form a linked list, and a heap holds
  every pair that can be joined, ordered by rank and then by position. An entry of the heap is
  out of date when the symbols at its position are no longer the ones it was made for; such
  entries are skipped when they come up. *)
procedure TLayaTokenizer.MergeLong(var Syms: TLayaTokenIds; Count: Integer; var Output: TLayaTokenIds;
  var OutCount: Integer);
var
  Next, Prev: TLayaTokenIds;
  HeapRank, HeapPos, HeapLeft, HeapRight, HeapJoined: TLayaTokenIds;
  HeapCount: Integer;
  I, P, Q, Sym, Joined, Left, Right: Integer;

  function Before(A, B: Integer): Boolean;
  begin
    Result := (HeapRank[A] < HeapRank[B]) or
      ((HeapRank[A] = HeapRank[B]) and (HeapPos[A] < HeapPos[B]));
  end;

  procedure Swap(A, B: Integer);
  var
    T: Integer;
  begin
    T := HeapRank[A]; HeapRank[A] := HeapRank[B]; HeapRank[B] := T;
    T := HeapPos[A]; HeapPos[A] := HeapPos[B]; HeapPos[B] := T;
    T := HeapLeft[A]; HeapLeft[A] := HeapLeft[B]; HeapLeft[B] := T;
    T := HeapRight[A]; HeapRight[A] := HeapRight[B]; HeapRight[B] := T;
    T := HeapJoined[A]; HeapJoined[A] := HeapJoined[B]; HeapJoined[B] := T;
  end;

  procedure Add(APos: Integer);
  var
    ARank, AJoined, Child, Parent: Integer;
  begin
    ARank := FindPair(Syms[APos], Syms[Next[APos]], AJoined);
    if ARank = NoRank then
      Exit;
    Child := HeapCount;
    Inc(HeapCount);
    HeapRank[Child] := ARank;
    HeapPos[Child] := APos;
    HeapLeft[Child] := Syms[APos];
    HeapRight[Child] := Syms[Next[APos]];
    HeapJoined[Child] := AJoined;
    while Child > 0 do
    begin
      Parent := (Child - 1) shr 1;
      if not Before(Child, Parent) then
        Break;
      Swap(Child, Parent);
      Child := Parent;
    end;
  end;

  procedure RemoveTop;
  var
    Parent, Child: Integer;
  begin
    Dec(HeapCount);
    if HeapCount = 0 then
      Exit;
    Swap(0, HeapCount);
    Parent := 0;
    while True do
    begin
      Child := Parent * 2 + 1;
      if Child >= HeapCount then
        Break;
      if (Child + 1 < HeapCount) and Before(Child + 1, Child) then
        Inc(Child);
      if not Before(Child, Parent) then
        Break;
      Swap(Child, Parent);
      Parent := Child;
    end;
  end;

begin
  Next := nil;
  Prev := nil;
  HeapRank := nil;
  HeapPos := nil;
  HeapLeft := nil;
  HeapRight := nil;
  HeapJoined := nil;
  SetLength(Next, Count);
  SetLength(Prev, Count);
  for I := 0 to Count - 1 do
  begin
    Prev[I] := I - 1;
    Next[I] := I + 1;
  end;
  Next[Count - 1] := -1;
  (* at most one entry per starting pair and two per join *)
  SetLength(HeapRank, Count * 3);
  SetLength(HeapPos, Count * 3);
  SetLength(HeapLeft, Count * 3);
  SetLength(HeapRight, Count * 3);
  SetLength(HeapJoined, Count * 3);
  HeapCount := 0;
  for I := 0 to Count - 2 do
    Add(I);

  while HeapCount > 0 do
  begin
    P := HeapPos[0];
    Left := HeapLeft[0];
    Right := HeapRight[0];
    Joined := HeapJoined[0];
    RemoveTop;
    Q := Next[P];
    if (Syms[P] <> Left) or (Q < 0) or (Syms[Q] <> Right) then
      Continue;
    Syms[P] := Joined;
    Syms[Q] := -1;
    Next[P] := Next[Q];
    if Next[Q] >= 0 then
      Prev[Next[Q]] := P;
    if Prev[P] >= 0 then
      Add(Prev[P]);
    if Next[P] >= 0 then
      Add(P);
  end;

  P := 0;
  while P >= 0 do
  begin
    Sym := Syms[P];
    if (Sym < 0) or (FSymIds[Sym] < 0) then
      raise ELayaTokenizer.Create('The tokenizer has no token for a piece of this text');
    Push(Output, OutCount, FSymIds[Sym]);
    P := Next[P];
  end;
end;

(* Byte-level: every byte of the word's UTF-8 form is a symbol to start with. *)
procedure TLayaTokenizer.EncodeWordBytes(const Text: TLayaCodePoints; AFrom, ATo: Integer;
  var Output: TLayaTokenIds; var OutCount: Integer);
var
  Syms: TLayaTokenIds;
  Buffer: TBytes;
  I, K, N, Count: Integer;
begin
  Syms := nil;
  Buffer := nil;
  SetLength(Syms, (ATo - AFrom) * 4);
  SetLength(Buffer, 4);
  Count := 0;
  for I := AFrom to ATo - 1 do
  begin
    N := PutUtf8(Text[I], Buffer, 0);
    for K := 0 to N - 1 do
    begin
      Syms[Count] := FByteSyms[Buffer[K]];
      Inc(Count);
    end;
  end;
  Merge(Syms, Count, Output, OutCount);
end;

(* Metaspace: every character that is in the vocabulary is a symbol; any other character is
  spelled with one fallback symbol per byte. *)
procedure TLayaTokenizer.EncodeWordMeta(const Text: TLayaCodePoints; AFrom, ATo: Integer;
  var Output: TLayaTokenIds; var OutCount: Integer);
var
  Syms: TLayaTokenIds;
  Buffer: TBytes;
  I, K, N, Count, Sym: Integer;
begin
  Syms := nil;
  Buffer := nil;
  SetLength(Syms, (ATo - AFrom) * 4);
  SetLength(Buffer, 4);
  Count := 0;
  for I := AFrom to ATo - 1 do
  begin
    N := PutUtf8(Text[I], Buffer, 0);
    Sym := FindSymbol(Buffer, N);
    if (Sym >= 0) and (Sym < FVocabSize) then
    begin
      Syms[Count] := Sym;
      Inc(Count);
    end
    else
      for K := 0 to N - 1 do
      begin
        Syms[Count] := FFallbackSyms[Buffer[K]];
        Inc(Count);
      end;
  end;
  Merge(Syms, Count, Output, OutCount);
end;

(* ============================================================================ *)
(* Splitting a text into words                                                  *)
(* ============================================================================ *)

(* Text without added tokens, already normalized.

  Byte-level tokenizers cut the text with this expression, tried from left to right:

    's|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+

  The code below takes the same pieces without a regular expression engine. Every character
  is a letter, a number, white space or something else, so every position starts a piece. *)
procedure TLayaTokenizer.Ordinary(const Text: TLayaCodePoints; AFrom, ATo: Integer;
  var Output: TLayaTokenIds; var OutCount: Integer);
type
  TKind = (ckLetter, ckNumber, ckSpace, ckOther);

  function KindOf(C: Integer): TKind;
  begin
    if LayaIsLetter(C) then Result := ckLetter
    else if LayaIsNumber(C) then Result := ckNumber
    else if LayaIsWhiteSpace(C) then Result := ckSpace
    else Result := ckOther;
  end;

var
  I, J, C, D, E: Integer;
  Kind: TKind;
  Marked: TLayaCodePoints;
begin
  if ATo <= AFrom then
    Exit;

  if FMetaspace then
  begin
    (* A marker in front, then one word per marker; the marker stays with its word. *)
    Marked := nil;
    if Text[AFrom] <> MetaspaceMark then
    begin
      SetLength(Marked, ATo - AFrom + 1);
      Marked[0] := MetaspaceMark;
      for I := AFrom to ATo - 1 do
        Marked[I - AFrom + 1] := Text[I];
    end
    else
    begin
      SetLength(Marked, ATo - AFrom);
      for I := AFrom to ATo - 1 do
        Marked[I - AFrom] := Text[I];
    end;
    I := 0;
    while I < Length(Marked) do
    begin
      J := I + 1;
      while (J < Length(Marked)) and (Marked[J] <> MetaspaceMark) do
        Inc(J);
      EncodeWordMeta(Marked, I, J, Output, OutCount);
      I := J;
    end;
    Exit;
  end;

  I := AFrom;
  while I < ATo do
  begin
    C := Text[I];
    if I + 1 < ATo then D := Text[I + 1] else D := -1;
    if I + 2 < ATo then E := Text[I + 2] else E := -1;
    J := -1;

    (* 's 't 're 've 'm 'll 'd *)
    if C = $27 then
    begin
      if (D = Ord('s')) or (D = Ord('t')) or (D = Ord('m')) or (D = Ord('d')) then
        J := I + 2
      else if ((D = Ord('r')) or (D = Ord('v'))) and (E = Ord('e')) then
        J := I + 3
      else if (D = Ord('l')) and (E = Ord('l')) then
        J := I + 3;
    end;

    if J < 0 then
    begin
      Kind := KindOf(C);
      if (C = $20) and (D >= 0) and (KindOf(D) <> ckSpace) then
      begin
        (* one space in front belongs to the word that follows *)
        Kind := KindOf(D);
        J := I + 2;
        while (J < ATo) and (KindOf(Text[J]) = Kind) do
          Inc(J);
      end
      else if Kind <> ckSpace then
      begin
        J := I + 1;
        while (J < ATo) and (KindOf(Text[J]) = Kind) do
          Inc(J);
      end
      else
      begin
        (* white space: all of it at the end of the text; otherwise all but the last
          character, which is left for the next piece *)
        J := I + 1;
        while (J < ATo) and LayaIsWhiteSpace(Text[J]) do
          Inc(J);
        if (J < ATo) and (J - I >= 2) then
          Dec(J);
      end;
    end;

    EncodeWordBytes(Text, I, J, Output, OutCount);
    I := J;
  end;
end;

(* The first added token at or after AFrom, among those with the given flag. At one position
  the longest wins. Returns its index, or -1. *)
function TLayaTokenizer.FindAdded(const Text: TLayaCodePoints; AFrom, ATo: Integer;
  Normalized: Boolean; out Position: Integer): Integer;
var
  P, I, K, N, C: Integer;
  Match: Boolean;
begin
  Result := -1;
  Position := ATo;
  for P := AFrom to ATo - 1 do
  begin
    C := Text[P];
    if C < 128 then
    begin
      if not FAddedFirst[Normalized, C] then
        Continue;
    end
    else if not FAddedOther[Normalized] then
      Continue;
    for I := 0 to High(FAdded) do
    begin
      if (FAdded[I].Normalized <> Normalized) or (FAdded[I].Content[0] <> C) then
        Continue;
      N := Length(FAdded[I].Content);
      if P + N > ATo then
        Continue;
      Match := True;
      for K := 1 to N - 1 do
        if Text[P + K] <> FAdded[I].Content[K] then
        begin
          Match := False;
          Break;
        end;
      if Match then
      begin
        Result := I;
        Position := P;
        Exit;
      end;
    end;
  end;
end;

(* First pass (Normalized = False): cut out the added tokens that are looked for in the text
  as written, normalize what lies between them and hand it to the second pass. Second pass:
  cut out the added tokens that are looked for in normalized text, and tokenize the rest. *)
procedure TLayaTokenizer.Split(const Text: TLayaCodePoints; Normalized: Boolean;
  var Output: TLayaTokenIds; var OutCount: Integer);
var
  Start, Stop, Position, Found, I, N: Integer;
  Part: TLayaCodePoints;
begin
  Start := 0;
  N := Length(Text);
  while Start < N do
  begin
    Found := FindAdded(Text, Start, N, Normalized, Position);
    if Found >= 0 then Stop := Position else Stop := N;
    if (Found >= 0) and FAdded[Found].LStrip then
      while (Stop > Start) and LayaIsWhiteSpace(Text[Stop - 1]) do
        Dec(Stop);
    if Normalized then
      Ordinary(Text, Start, Stop, Output, OutCount)
    else if Stop > Start then
    begin
      Part := nil;
      SetLength(Part, Stop - Start);
      for I := Start to Stop - 1 do
        Part[I - Start] := Text[I];
      if FMetaspace then
      begin
        for I := 0 to High(Part) do
          if Part[I] = $20 then
            Part[I] := MetaspaceMark;
      end
      else
        Part := LayaNFC(Part);
      Split(Part, True, Output, OutCount);
    end;
    if Found < 0 then
      Break;
    Push(Output, OutCount, FAdded[Found].Id);
    Start := Position + Length(FAdded[Found].Content);
  end;
end;

(* ============================================================================ *)
(* Encoding                                                                     *)
(* ============================================================================ *)

function TLayaTokenizer.EncodeCodePoints(const AText: TLayaCodePoints): TLayaTokenIds;
var
  Count: Integer;
begin
  CheckLoaded;
  Result := nil;
  Count := 0;
  Split(AText, False, Result, Count);
  SetLength(Result, Count);
end;

function TLayaTokenizer.Encode(const AText: string): TLayaTokenIds;
begin
  Result := EncodeCodePoints(LayaStringToCodePoints(AText));
end;

function TLayaTokenizer.CountTokens(const AText: string): Integer;
begin
  Result := Length(Encode(AText));
end;

end.
