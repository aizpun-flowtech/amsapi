unit AmsApi.Wad;

{ ============================================================================
  AmsApi.Wad - das echte DOOM-WAD-Format lesen

  Ein WAD ("Where's All the Data") ist das Archivformat von DOOM. Aufbau:

    Header    : 4 Byte Kennung ("IWAD"/"PWAD"), int32 Anzahl Lumps,
                int32 Offset des Verzeichnisses
    Verzeichnis: je Lump 12 Byte - int32 Dateiposition, int32 Groesse,
                8 Byte Name (ASCII, gross, ggf. ohne Nullabschluss)
    Lumps     : die rohen Daten, an den genannten Positionen

  Daraus liest diese Unit genau das, was die Engine braucht:
    - PLAYPAL   die 256-Farben-Palette (echte DOOM-Farben)
    - Flats     64x64 Boden-/Deckentexturen, roh indiziert
    - patch_t   das DOOM-Bildformat (Sprites, Waffe, Wandflicken) mit
                Transparenz, spaltenweise kodiert
    - TEXTURE1/PNAMES  zusammengesetzte Wandtexturen aus mehreren Flicken

  Das ganze WAD wird einmal in den Speicher gelesen (Shareware ~4 MB); alle
  Lumps sind danach Zeiger hinein. JEDER Zugriff ist bereichsgeprueft: ein
  beschaedigtes oder unerwartetes WAD darf NIE abstuerzen, sondern liefert
  False. Die Engine faellt dann auf erzeugte Ersatztexturen zurueck - so
  laeuft das Plugin auch voellig ohne WAD.

  Ohne AMS testbar: reines Byte-Handling, keine Host-Symbole.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, AmsApi.GameWindow;

type
  { 256 Farben, jede als $00RRGGBB (siehe AmsApi.GameWindow.TAmsPixel). }
  TAmsPalette = array[0..255] of TAmsPixel;

  TAmsByteArray = array of Byte;

  { Ein dekodiertes DOOM-Bild. Pixel sind Palettenindizes; Mask sagt je Pixel,
    ob er sichtbar ist (Sprites sind nicht rechteckig). Left/TopOffset sind die
    Aufhaengepunkte aus dem patch_t (fuer Sprites und die Waffe wichtig). }
  TAmsPic = record
    Width, Height: Integer;
    LeftOffset, TopOffset: Integer;
    Pixels: TAmsByteArray;   { Width*Height Indizes }
    Mask: TAmsByteArray;     { Width*Height: 1 sichtbar, 0 durchsichtig }
  end;

  TAmsWad = class
  private
    FData: TAmsByteArray;
    FSize: Integer;
    FValid: Boolean;
    FKind: string;
    FNames: array of string;     { je Lump der (normalisierte) Name }
    FOfs: array of Integer;
    FLen: array of Integer;
    FPNames: array of string;    { aus PNAMES, fuer TEXTURE1 }
    FPNamesLoaded: Boolean;
    function RdI32(AOfs: Integer): Integer;
    function RdI16(AOfs: Integer): SmallInt;
    function RdU16(AOfs: Integer): Word;
    function LumpNameAt(AOfs: Integer): string;
    procedure LoadDirectory;
    procedure EnsurePNames;
    function DecodePatchAt(ADataOfs, ASize: Integer; out APic: TAmsPic): Boolean;
  public
    constructor Create(const AFile: string);
    destructor Destroy; override;

    property Valid: Boolean read FValid;
    property Kind: string read FKind;         { 'IWAD' / 'PWAD' }
    function LumpCount: Integer;

    { Index eines Lumps ueber den Namen (gross-/kleinunabhaengig), ab AStart.
      -1 = nicht gefunden. }
    function IndexOf(const AName: string; AStart: Integer = 0): Integer;
    function LumpName(AIndex: Integer): string;
    function LumpSize(AIndex: Integer): Integer;
    { Zeiger auf die Rohdaten eines Lumps (nil bei ungueltigem Index). }
    function LumpPtr(AIndex: Integer): PByte;

    { PLAYPAL, Palette 0. }
    function ReadPalette(out APal: TAmsPalette): Boolean;

    { Ein Flat (64x64) als rohe Indizes. Result False, wenn nicht vorhanden
      oder die Groesse nicht passt. }
    function ReadFlat(const AName: string; out APix: TAmsByteArray): Boolean;

    { Ein patch_t ueber Name bzw. Lump-Index dekodieren (Sprite/Waffe). }
    function ReadPatch(const AName: string; out APic: TAmsPic): Boolean;
    function ReadPatchByIndex(AIndex: Integer; out APic: TAmsPic): Boolean;

    { Eine zusammengesetzte Wandtextur aus TEXTURE1/TEXTURE2 bauen. Ergebnis
      ist voll deckend (Mask ueberall 1); Loecher bleiben Index 0. }
    function BuildTexture(const AName: string; out APic: TAmsPic): Boolean;
  end;

{ Ein leeres Bild - fuer sauberes Initialisieren. }
function AmsEmptyPic: TAmsPic;

implementation

uses
  AmsApi.Log;

function AmsEmptyPic: TAmsPic;
begin
  Result.Width := 0;
  Result.Height := 0;
  Result.LeftOffset := 0;
  Result.TopOffset := 0;
  SetLength(Result.Pixels, 0);
  SetLength(Result.Mask, 0);
end;

{ ------------------------------------------------------------- kleine Leser -- }

function TAmsWad.RdI32(AOfs: Integer): Integer;
begin
  if (AOfs < 0) or (AOfs + 4 > FSize) then Exit(0);
  Result := FData[AOfs] or (FData[AOfs + 1] shl 8) or
            (FData[AOfs + 2] shl 16) or (FData[AOfs + 3] shl 24);
end;

function TAmsWad.RdI16(AOfs: Integer): SmallInt;
begin
  if (AOfs < 0) or (AOfs + 2 > FSize) then Exit(0);
  Result := SmallInt(Word(FData[AOfs] or (FData[AOfs + 1] shl 8)));
end;

function TAmsWad.RdU16(AOfs: Integer): Word;
begin
  if (AOfs < 0) or (AOfs + 2 > FSize) then Exit(0);
  Result := FData[AOfs] or (FData[AOfs + 1] shl 8);
end;

function TAmsWad.LumpNameAt(AOfs: Integer): string;
var
  i: Integer;
  C: Byte;
begin
  Result := '';
  if (AOfs < 0) or (AOfs + 8 > FSize) then Exit;
  for i := 0 to 7 do
  begin
    C := FData[AOfs + i];
    if C = 0 then Break;
    Result := Result + UpCase(Chr(C));
  end;
end;

{ --------------------------------------------------------------- Laden ------- }

constructor TAmsWad.Create(const AFile: string);
var
  FS: TFileStream;
begin
  inherited Create;
  FValid := False;
  FSize := 0;
  FKind := '';
  FPNamesLoaded := False;
  if not FileExists(AFile) then
  begin
    AmsLogFmt('WAD: Datei nicht gefunden: %s', [AFile]);
    Exit;
  end;
  try
    FS := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try
      FSize := FS.Size;
      if FSize < 12 then
      begin
        AmsLogFmt('WAD: zu klein (%d Byte): %s', [FSize, AFile]);
        FSize := 0;
        Exit;
      end;
      SetLength(FData, FSize);
      FS.ReadBuffer(FData[0], FSize);
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      AmsLogFmt('WAD: Lesefehler: %s (%s)', [AFile, E.Message]);
      FSize := 0;
      SetLength(FData, 0);
      Exit;
    end;
  end;

  FKind := Chr(FData[0]) + Chr(FData[1]) + Chr(FData[2]) + Chr(FData[3]);
  if (FKind <> 'IWAD') and (FKind <> 'PWAD') then
  begin
    AmsLogFmt('WAD: keine IWAD/PWAD-Kennung ("%s"): %s', [FKind, AFile]);
    Exit;
  end;

  try
    LoadDirectory;
    FValid := LumpCount > 0;
    if FValid then
      AmsLogFmt('WAD: %s geladen - %s, %d Lumps, %d Byte',
                [ExtractFileName(AFile), FKind, LumpCount, FSize]);
  except
    on E: Exception do
    begin
      AmsLogFmt('WAD: Verzeichnisfehler: %s', [E.Message]);
      FValid := False;
    end;
  end;
end;

destructor TAmsWad.Destroy;
begin
  SetLength(FData, 0);
  inherited Destroy;
end;

procedure TAmsWad.LoadDirectory;
var
  NumLumps, DirOfs, i, Entry: Integer;
begin
  NumLumps := RdI32(4);
  DirOfs := RdI32(8);
  if (NumLumps <= 0) or (NumLumps > 1024 * 1024) then Exit;
  if (DirOfs < 0) or (DirOfs + NumLumps * 16 > FSize) then
  begin
    AmsLog('WAD: Verzeichnis liegt ausserhalb der Datei');
    Exit;
  end;
  SetLength(FNames, NumLumps);
  SetLength(FOfs, NumLumps);
  SetLength(FLen, NumLumps);
  for i := 0 to NumLumps - 1 do
  begin
    Entry := DirOfs + i * 16;
    FOfs[i] := RdI32(Entry);
    FLen[i] := RdI32(Entry + 4);
    FNames[i] := LumpNameAt(Entry + 8);
    { Fehlerhafte Eintraege neutralisieren, statt sie spaeter auszuwerten. }
    if (FOfs[i] < 0) or (FLen[i] < 0) or (FOfs[i] + FLen[i] > FSize) then
    begin
      FOfs[i] := 0;
      FLen[i] := 0;
    end;
  end;
end;

{ ------------------------------------------------------------- Lump-Zugriff -- }

function TAmsWad.LumpCount: Integer;
begin
  Result := Length(FNames);
end;

function TAmsWad.IndexOf(const AName: string; AStart: Integer): Integer;
var
  i: Integer;
  N: string;
begin
  Result := -1;
  N := UpperCase(Trim(AName));
  if AStart < 0 then AStart := 0;
  for i := AStart to High(FNames) do
    if FNames[i] = N then Exit(i);
end;

function TAmsWad.LumpName(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex > High(FNames)) then Exit('');
  Result := FNames[AIndex];
end;

function TAmsWad.LumpSize(AIndex: Integer): Integer;
begin
  if (AIndex < 0) or (AIndex > High(FLen)) then Exit(0);
  Result := FLen[AIndex];
end;

function TAmsWad.LumpPtr(AIndex: Integer): PByte;
begin
  Result := nil;
  if (AIndex < 0) or (AIndex > High(FOfs)) then Exit;
  if FLen[AIndex] <= 0 then Exit;
  Result := @FData[FOfs[AIndex]];
end;

{ ----------------------------------------------------------------- Palette --- }

function TAmsWad.ReadPalette(out APal: TAmsPalette): Boolean;
var
  Idx, Base, i: Integer;
begin
  Result := False;
  for i := 0 to 255 do APal[i] := 0;
  Idx := IndexOf('PLAYPAL');
  if Idx < 0 then Exit;
  Base := FOfs[Idx];
  if FLen[Idx] < 768 then Exit;
  for i := 0 to 255 do
    APal[i] := AmsRGB(FData[Base + i * 3], FData[Base + i * 3 + 1],
                      FData[Base + i * 3 + 2]);
  Result := True;
end;

{ -------------------------------------------------------------------- Flat --- }

function TAmsWad.ReadFlat(const AName: string; out APix: TAmsByteArray): Boolean;
var
  Idx, i: Integer;
begin
  Result := False;
  SetLength(APix, 0);
  Idx := IndexOf(AName);
  if Idx < 0 then Exit;
  if FLen[Idx] < 4096 then Exit;      { 64x64 }
  SetLength(APix, 4096);
  for i := 0 to 4095 do APix[i] := FData[FOfs[Idx] + i];
  Result := True;
end;

{ ------------------------------------------------------------------ patch_t -- }

{ patch_t:
    WORD  width, height
    int16 leftoffset, topoffset
    DWORD columnofs[width]        (relativ zum Lump-Anfang)
  Jede Spalte: Folge von Posts
    BYTE topdelta   (255 = Ende der Spalte)
    BYTE length
    BYTE unused     (Fuellbyte vor den Pixeln)
    length * BYTE   Pixel
    BYTE unused     (Fuellbyte danach) }
function TAmsWad.DecodePatchAt(ADataOfs, ASize: Integer;
  out APic: TAmsPic): Boolean;
var
  W, H, x, y, ColPtr, Post, PostLen, TopDelta, i, Dst: Integer;
  LumpEnd: Integer;
begin
  APic := AmsEmptyPic;
  Result := False;
  if (ADataOfs < 0) or (ASize < 8) or (ADataOfs + ASize > FSize) then Exit;
  LumpEnd := ADataOfs + ASize;

  W := RdU16(ADataOfs);
  H := RdU16(ADataOfs + 2);
  if (W <= 0) or (H <= 0) or (W > 4096) or (H > 4096) then Exit;
  APic.Width := W;
  APic.Height := H;
  APic.LeftOffset := RdI16(ADataOfs + 4);
  APic.TopOffset := RdI16(ADataOfs + 6);
  SetLength(APic.Pixels, W * H);
  SetLength(APic.Mask, W * H);
  { Mask ist durch SetLength schon 0 (durchsichtig). }

  for x := 0 to W - 1 do
  begin
    ColPtr := ADataOfs + RdI32(ADataOfs + 8 + x * 4);
    if (ColPtr < ADataOfs) or (ColPtr >= LumpEnd) then Continue;
    { Posts der Spalte abarbeiten. }
    while ColPtr < LumpEnd do
    begin
      TopDelta := FData[ColPtr];
      if TopDelta = 255 then Break;
      if ColPtr + 2 > LumpEnd then Break;
      PostLen := FData[ColPtr + 1];
      Post := ColPtr + 3;                 { +1 topdelta +1 len +1 fuellbyte }
      for i := 0 to PostLen - 1 do
      begin
        y := TopDelta + i;
        if (Post + i >= LumpEnd) then Break;
        if (y >= 0) and (y < H) then
        begin
          Dst := y * W + x;
          APic.Pixels[Dst] := FData[Post + i];
          APic.Mask[Dst] := 1;
        end;
      end;
      { naechster Post: topdelta + len + fuellbyte + pixel + fuellbyte }
      ColPtr := Post + PostLen + 1;
    end;
  end;
  Result := True;
end;

function TAmsWad.ReadPatchByIndex(AIndex: Integer; out APic: TAmsPic): Boolean;
begin
  APic := AmsEmptyPic;
  if (AIndex < 0) or (AIndex > High(FOfs)) then Exit(False);
  Result := DecodePatchAt(FOfs[AIndex], FLen[AIndex], APic);
end;

function TAmsWad.ReadPatch(const AName: string; out APic: TAmsPic): Boolean;
begin
  Result := ReadPatchByIndex(IndexOf(AName), APic);
end;

{ ------------------------------------------------------ zusammengesetzte Textur }

procedure TAmsWad.EnsurePNames;
var
  Idx, Count, i, Base: Integer;
begin
  if FPNamesLoaded then Exit;
  FPNamesLoaded := True;
  SetLength(FPNames, 0);
  Idx := IndexOf('PNAMES');
  if Idx < 0 then Exit;
  Base := FOfs[Idx];
  Count := RdI32(Base);
  if (Count <= 0) or (Count > 65535) then Exit;
  if Base + 4 + Count * 8 > FSize then Exit;
  SetLength(FPNames, Count);
  for i := 0 to Count - 1 do
    FPNames[i] := LumpNameAt(Base + 4 + i * 8);
end;

{ Sucht in TEXTURE1 (und, falls vorhanden, TEXTURE2) den maptexture-Eintrag
  mit passendem Namen und setzt ihn aus seinen Flicken zusammen. }
function TAmsWad.BuildTexture(const AName: string; out APic: TAmsPic): Boolean;

  function TryLump(const ATexLump: string): Boolean;
  var
    Base, NumTex, t, TexOfs, W, H, PatchCount, p, PatchBase: Integer;
    OX, OY, PatchIdx, PLumpIdx, px, py, Sx, Sy, Dst, Src: Integer;
    Name: string;
    Patch: TAmsPic;
  begin
    Result := False;
    t := IndexOf(ATexLump);
    if t < 0 then Exit;
    Base := FOfs[t];
    NumTex := RdI32(Base);
    if (NumTex <= 0) or (NumTex > 65535) then Exit;

    for t := 0 to NumTex - 1 do
    begin
      TexOfs := Base + RdI32(Base + 4 + t * 4);
      if (TexOfs < Base) or (TexOfs + 22 > FSize) then Continue;
      Name := LumpNameAt(TexOfs);
      if Name <> UpperCase(Trim(AName)) then Continue;

      W := RdU16(TexOfs + 12);
      H := RdU16(TexOfs + 14);
      if (W <= 0) or (H <= 0) or (W > 4096) or (H > 4096) then Exit;
      PatchCount := RdU16(TexOfs + 20);
      if (PatchCount < 0) or (PatchCount > 4096) then Exit;

      APic := AmsEmptyPic;
      APic.Width := W;
      APic.Height := H;
      SetLength(APic.Pixels, W * H);
      SetLength(APic.Mask, W * H);

      PatchBase := TexOfs + 22;
      for p := 0 to PatchCount - 1 do
      begin
        if PatchBase + p * 10 + 10 > FSize then Break;
        OX := RdI16(PatchBase + p * 10);
        OY := RdI16(PatchBase + p * 10 + 2);
        PatchIdx := RdU16(PatchBase + p * 10 + 4);
        if (PatchIdx < 0) or (PatchIdx > High(FPNames)) then Continue;
        PLumpIdx := IndexOf(FPNames[PatchIdx]);
        if PLumpIdx < 0 then Continue;
        if not DecodePatchAt(FOfs[PLumpIdx], FLen[PLumpIdx], Patch) then Continue;

        for py := 0 to Patch.Height - 1 do
        begin
          Sy := OY + py;
          if (Sy < 0) or (Sy >= H) then Continue;
          for px := 0 to Patch.Width - 1 do
          begin
            Sx := OX + px;
            if (Sx < 0) or (Sx >= W) then Continue;
            Src := py * Patch.Width + px;
            if Patch.Mask[Src] = 0 then Continue;
            Dst := Sy * W + Sx;
            APic.Pixels[Dst] := Patch.Pixels[Src];
            APic.Mask[Dst] := 1;
          end;
        end;
      end;
      Result := True;
      Exit;
    end;
  end;

begin
  APic := AmsEmptyPic;
  EnsurePNames;
  if Length(FPNames) = 0 then Exit(False);
  Result := TryLump('TEXTURE1');
  if not Result then Result := TryLump('TEXTURE2');
end;

end.
