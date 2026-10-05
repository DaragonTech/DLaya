unit LayaArchive;

(* A model in one file: reads the files of a Laya model out of an uncompressed .tar archive.

  LibLayaX 1.0.15 and later can load a model from such an archive instead of a folder (see the
  README). This unit lets Pascal code do the same for the small files it reads itself:
  LayaTokenizer uses it to take tokenizer.json and rl_agent_config.json from the archive.

    Archive := TLayaArchive.Create('C:\models\laya.tar');
    try
      Data := Archive.ReadFile('tokenizer/tokenizer.json');
    finally
      Archive.Free;
    end;

  Names are relative to where the model starts in the archive and use forward slashes. The
  model may sit at the top of the archive or inside one folder, as the library accepts it:
  when every entry lies below a single top folder, that folder is where the model starts.

  The archive must be a plain tar file (ustar, GNU or pax), not a compressed one. Entries named
  "._something", which the macOS tar adds, are ignored.

  Delphi and Free Pascal ({$MODE DELPHIUNICODE}), any platform, 32-bit targets included: this
  unit does not use the library. Needs LayaUnicode.pas. *)

{$IFDEF FPC}{$MODE DELPHIUNICODE}{$CODEPAGE UTF8}{$ENDIF}
{$IFNDEF FPC}{$IF CompilerVersion >= 24}{$ZEROBASEDSTRINGS OFF}{$IFEND}{$ENDIF}
{$Q-}{$R-}

interface

uses
  SysUtils, LayaUnicode;

type
  ELayaArchive = class(Exception);

  TLayaArchiveEntry = record
    Name: string;     (* as stored, cleaned: forward slashes, no leading "./" *)
    Offset: Int64;    (* of the first byte of the file, within the archive *)
    Size: Int64;
  end;
  TLayaArchiveEntries = array of TLayaArchiveEntry;

  TLayaArchive = class
  private
    FFileName: string;
    FEntries: TLayaArchiveEntries;
    FCount: Integer;
    FRoot: string;
    procedure AddEntry(const AName: string; AOffset, ASize: Int64);
    procedure ReadIndex;
    procedure FindRoot;
    function IndexOf(const AFullName: string): Integer;
    function GetEntry(Index: Integer): TLayaArchiveEntry;
  public
    (* Reads the table of contents. Raises ELayaArchive when the file is not a tar archive. *)
    constructor Create(const AFileName: string);

    (* AName is relative to the model: 'rl_agent_config.json', 'tokenizer/tokenizer.json'. *)
    function Exists(const AName: string): Boolean;
    function Find(const AName: string; out AOffset, ASize: Int64): Boolean;
    (* The whole file. Raises ELayaArchive when it is missing or cannot be read. *)
    function ReadFile(const AName: string): TBytes;

    property FileName: string read FFileName;
    (* '' when the model is at the top of the archive, else 'folder/'. *)
    property Root: string read FRoot;
    property Count: Integer read FCount;
    property Entries[Index: Integer]: TLayaArchiveEntry read GetEntry;
  end;

(* True when APath names a file (and so can only be an archive), False for a folder or for
  nothing at all. *)
function LayaIsArchiveFile(const APath: string): Boolean;

implementation

const
  BlockSize = 512;

function LayaIsArchiveFile(const APath: string): Boolean;
begin
  Result := (APath <> '') and FileExists(APath) and not DirectoryExists(APath);
end;

(* Forward slashes, no leading "./" or "/", no empty or "." parts. Empty when the name has a
  ".." part or names nothing. *)
function CleanName(const Raw: string): string;
var
  I: Integer;
  Part: string;
  Bad: Boolean;

  procedure Flush;
  begin
    if (Part = '') or (Part = '.') then
    begin
      Part := '';
      Exit;
    end;
    if Part = '..' then
    begin
      Bad := True;
      Exit;
    end;
    if Result <> '' then Result := Result + '/';
    Result := Result + Part;
    Part := '';
  end;

begin
  Result := '';
  Part := '';
  Bad := False;
  for I := 1 to Length(Raw) do
    if (Raw[I] = '/') or (Raw[I] = '\') then
    begin
      Flush;
      if Bad then Break;
    end
    else
      Part := Part + Raw[I];
  if not Bad then Flush;
  if Bad then Result := '';
end;

function BaseName(const Name: string): string;
var
  I: Integer;
begin
  Result := Name;
  for I := Length(Name) downto 1 do
    if Name[I] = '/' then
    begin
      Result := Copy(Name, I + 1, MaxInt);
      Exit;
    end;
end;

(* A number field of a tar header: octal text, or base 256 when the first bit is set. *)
function TarNumber(const Header: TBytes; Start, Width: Integer): Int64;
var
  I: Integer;
begin
  Result := 0;
  if (Header[Start] and $80) <> 0 then
  begin
    Result := Header[Start] and $7F;
    for I := Start + 1 to Start + Width - 1 do
      Result := (Result shl 8) or Header[I];
    Exit;
  end;
  I := Start;
  while (I < Start + Width) and (Header[I] = Ord(' ')) do Inc(I);
  while (I < Start + Width) and (Header[I] >= Ord('0')) and (Header[I] <= Ord('7')) do
  begin
    Result := Result * 8 + (Header[I] - Ord('0'));
    Inc(I);
  end;
end;

(* A text field of a tar header: up to the first zero byte, as UTF-8. *)
function TarText(const Data: TBytes; Start, Width: Integer): string;
var
  Len: Integer;
  Part: TBytes;
begin
  Len := 0;
  while (Len < Width) and (Start + Len < Length(Data)) and (Data[Start + Len] <> 0) do Inc(Len);
  Part := nil;
  SetLength(Part, Len);
  if Len > 0 then Move(Data[Start], Part[0], Len);
  Result := LayaUtf8ToString(Part);
end;

function ChecksumOk(const Header: TBytes): Boolean;
var
  I: Integer;
  Sum: Int64;
begin
  Sum := 0;
  for I := 0 to BlockSize - 1 do
    if (I >= 148) and (I < 156) then Inc(Sum, Ord(' ')) else Inc(Sum, Header[I]);
  Result := Sum = TarNumber(Header, 148, 8);
end;

function AllZero(const Header: TBytes): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to BlockSize - 1 do
    if Header[I] <> 0 then
    begin
      Result := False;
      Exit;
    end;
end;

function IsPosixHeader(const Header: TBytes): Boolean;
begin
  (* "ustar" followed by a zero byte; GNU tar writes "ustar  " and uses the prefix field
    for other things *)
  Result := (Header[257] = Ord('u')) and (Header[258] = Ord('s')) and (Header[259] = Ord('t')) and
    (Header[260] = Ord('a')) and (Header[261] = Ord('r')) and (Header[262] = 0);
end;

(* The "path" and "size" records of a pax extended header: "<length> <key>=<value>" + LF. *)
procedure ReadPax(const Data: TBytes; var Path: string; var HasSize: Boolean; var Size: Int64);
var
  At, Space, Len, Equals, I, ValueStart, ValueLen: Integer;
  Key: string;
  Value: TBytes;
begin
  At := 0;
  while At < Length(Data) do
  begin
    Space := At;
    while (Space < Length(Data)) and (Data[Space] <> Ord(' ')) do Inc(Space);
    if Space >= Length(Data) then Break;
    Len := 0;
    for I := At to Space - 1 do
    begin
      if (Data[I] < Ord('0')) or (Data[I] > Ord('9')) or (Len > 100000000) then
      begin
        Len := 0;
        Break;
      end;
      Len := Len * 10 + (Data[I] - Ord('0'));
    end;
    if (Len = 0) or (At + Len > Length(Data)) then Break;
    Equals := Space + 1;
    while (Equals < At + Len) and (Data[Equals] <> Ord('=')) do Inc(Equals);
    if Equals < At + Len then
    begin
      Key := '';
      for I := Space + 1 to Equals - 1 do Key := Key + Char(Data[I]);
      ValueStart := Equals + 1;
      ValueLen := At + Len - ValueStart;
      if (ValueLen > 0) and (Data[ValueStart + ValueLen - 1] = 10) then Dec(ValueLen);
      Value := nil;
      SetLength(Value, ValueLen);
      if ValueLen > 0 then Move(Data[ValueStart], Value[0], ValueLen);
      if Key = 'path' then
        Path := LayaUtf8ToString(Value)
      else if Key = 'size' then
      begin
        Size := StrToInt64Def(LayaUtf8ToString(Value), -1);
        HasSize := Size >= 0;
      end;
    end;
    Inc(At, Len);
  end;
end;

(* Reads Count bytes at Position. False when the file ends before that. *)
function ReadAt(Handle: THandle; Position: Int64; var Buffer; Count: Integer): Boolean;
var
  Done, Got: Integer;
  P: PByte;
begin
  Result := False;
  if FileSeek(Handle, Position, 0) <> Position then Exit;
  Done := 0;
  P := PByte(@Buffer);
  while Done < Count do
  begin
    Got := FileRead(Handle, P^, Count - Done);
    if Got <= 0 then Exit;
    Inc(P, Got);
    Inc(Done, Got);
  end;
  Result := True;
end;

(* TLayaArchive *)

constructor TLayaArchive.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FEntries := nil;
  FCount := 0;
  FRoot := '';
  ReadIndex;
  FindRoot;
end;

procedure TLayaArchive.AddEntry(const AName: string; AOffset, ASize: Int64);
var
  I: Integer;
begin
  (* a later entry of the same name replaces the earlier one, as tar itself does *)
  for I := 0 to FCount - 1 do
    if FEntries[I].Name = AName then
    begin
      FEntries[I].Offset := AOffset;
      FEntries[I].Size := ASize;
      Exit;
    end;
  if FCount = Length(FEntries) then SetLength(FEntries, FCount * 2 + 16);
  FEntries[FCount].Name := AName;
  FEntries[FCount].Offset := AOffset;
  FEntries[FCount].Size := ASize;
  Inc(FCount);
end;

procedure TLayaArchive.ReadIndex;
var
  Handle: THandle;
  Total, At, Size, DataAt, PaxSize: Int64;
  Header, Extra: TBytes;
  Kind: Byte;
  Name, LongName, PaxPath, Prefix, NotTar: string;
  PaxHasSize, First: Boolean;
begin
  NotTar := FFileName + ' is not a folder and not an uncompressed tar archive';
  Handle := FileOpen(FFileName, fmOpenRead or fmShareDenyWrite);
  if Handle = THandle(-1) then
    raise ELayaArchive.Create('Cannot open ' + FFileName);
  try
    Total := FileSeek(Handle, Int64(0), 2);
    if Total < BlockSize then raise ELayaArchive.Create(NotTar);
    Header := nil;
    SetLength(Header, BlockSize);
    LongName := '';
    PaxPath := '';
    PaxHasSize := False;
    PaxSize := 0;
    First := True;
    At := 0;
    while At + BlockSize <= Total do
    begin
      if not ReadAt(Handle, At, Header[0], BlockSize) then
        raise ELayaArchive.Create('Cannot read ' + FFileName);
      if AllZero(Header) then Break;   (* the end marker *)
      if not ChecksumOk(Header) then
      begin
        if First then raise ELayaArchive.Create(NotTar);
        raise ELayaArchive.Create('Damaged tar archive (bad header at byte ' + IntToStr(At) + '): ' + FFileName);
      end;
      First := False;
      Size := TarNumber(Header, 124, 12);
      Kind := Header[156];
      DataAt := At + BlockSize;
      if (Kind = Ord('L')) or (Kind = Ord('x')) or (Kind = Ord('g')) or (Kind = Ord('K')) then
      begin
        (* a record about the entry that follows: a GNU long name or a pax extended header *)
        if (Size < 0) or (Size > 1024 * 1024) or (DataAt + Size > Total) then
          raise ELayaArchive.Create('Damaged tar archive: ' + FFileName);
        Extra := nil;
        SetLength(Extra, Integer(Size));
        if (Size > 0) and not ReadAt(Handle, DataAt, Extra[0], Integer(Size)) then
          raise ELayaArchive.Create('Cannot read ' + FFileName);
        if Kind = Ord('L') then
          LongName := TarText(Extra, 0, Length(Extra))
        else if Kind = Ord('x') then
          ReadPax(Extra, PaxPath, PaxHasSize, PaxSize);
      end
      else
      begin
        if PaxHasSize then Size := PaxSize;
        if PaxPath <> '' then Name := PaxPath
        else if LongName <> '' then Name := LongName
        else
        begin
          Name := TarText(Header, 0, 100);
          if IsPosixHeader(Header) then
          begin
            Prefix := TarText(Header, 345, 155);
            if Prefix <> '' then Name := Prefix + '/' + Name;
          end;
        end;
        LongName := '';
        PaxPath := '';
        PaxHasSize := False;
        if (Size < 0) or (DataAt + Size > Total) then
          raise ELayaArchive.Create('Truncated tar archive: ' + FFileName);
        if (Kind = Ord('0')) or (Kind = 0) or (Kind = Ord('7')) then
        begin
          Name := CleanName(Name);
          (* "._name" entries are resource forks added by the macOS tar *)
          if (Name <> '') and (Copy(BaseName(Name), 1, 2) <> '._') then
            AddEntry(Name, DataAt, Size);
        end;
      end;
      At := DataAt + ((Size + BlockSize - 1) div BlockSize) * BlockSize;
    end;
    if First then raise ELayaArchive.Create(NotTar);
  finally
    FileClose(Handle);
  end;
end;

procedure TLayaArchive.FindRoot;
var
  I, Slash: Integer;
  Top, Folder: string;
begin
  FRoot := '';
  Top := '';
  for I := 0 to FCount - 1 do
  begin
    Slash := Pos('/', FEntries[I].Name);
    if Slash = 0 then Exit;            (* a file at the top: the model starts there *)
    Folder := Copy(FEntries[I].Name, 1, Slash);
    if Top = '' then Top := Folder
    else if Top <> Folder then Exit;   (* more than one top folder *)
  end;
  FRoot := Top;
end;

function TLayaArchive.IndexOf(const AFullName: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to FCount - 1 do
    if FEntries[I].Name = AFullName then
    begin
      Result := I;
      Exit;
    end;
end;

function TLayaArchive.GetEntry(Index: Integer): TLayaArchiveEntry;
begin
  if (Index < 0) or (Index >= FCount) then
    raise ELayaArchive.Create('No such entry.');
  Result := FEntries[Index];
end;

function TLayaArchive.Find(const AName: string; out AOffset, ASize: Int64): Boolean;
var
  Index: Integer;
  Clean: string;
begin
  AOffset := 0;
  ASize := 0;
  Result := False;
  Clean := CleanName(AName);
  if Clean = '' then Exit;
  Index := IndexOf(FRoot + Clean);
  if Index < 0 then Exit;
  AOffset := FEntries[Index].Offset;
  ASize := FEntries[Index].Size;
  Result := True;
end;

function TLayaArchive.Exists(const AName: string): Boolean;
var
  Offset, Size: Int64;
begin
  Result := Find(AName, Offset, Size);
end;

function TLayaArchive.ReadFile(const AName: string): TBytes;
var
  Offset, Size: Int64;
  Handle: THandle;
begin
  Result := nil;
  if not Find(AName, Offset, Size) then
    raise ELayaArchive.Create('Cannot open ' + AName + ' (no such file in ' + FFileName + ')');
  if Size > MaxInt then
    raise ELayaArchive.Create('Cannot read ' + AName + ' (too large to read at once)');
  SetLength(Result, Integer(Size));
  if Size = 0 then Exit;
  Handle := FileOpen(FFileName, fmOpenRead or fmShareDenyWrite);
  if Handle = THandle(-1) then
    raise ELayaArchive.Create('Cannot open ' + FFileName);
  try
    if not ReadAt(Handle, Offset, Result[0], Integer(Size)) then
      raise ELayaArchive.Create('Cannot read ' + AName + ' from ' + FFileName);
  finally
    FileClose(Handle);
  end;
end;

end.
