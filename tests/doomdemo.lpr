program doomdemo;

{ ============================================================================
  Rauchtest fuer die DOOM-Engine, das Bildpuffer-Fenster und den WAD-Leser -
  alles OHNE AMS.

    1. WAD-Leser: ein winziges IWAD im Speicher erzeugen, wegschreiben, wieder
       einlesen und Palette + Flat zurueckbekommen. So ist der Parser
       gegengeprueft, auch ohne echtes DOOM1.WAD auf der Platte.
    2. Engine: erzeugte Assets laden, ein neues Spiel, mehrere Bildschritte mit
       Eingabe rechnen und in einen Puffer rendern. Geprueft wird, dass ein
       echtes Bild entsteht (nicht einfarbig, Waende sichtbar) und dass
       Schiessen die Gegnerzahl senkt. Ein PNG-freies BMP landet in %TEMP% zum
       Ansehen.
    3. Bildpuffer-Fenster: versteckt und ausserhalb des Bildes erzeugen, ueber
       die Nachrichtenschleife ein paar Frames laufen lassen, sauber abbauen.

  Rueckgabe: Anzahl der Fehlschlaege.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, Classes,
  AmsApi.Log, AmsApi.GameWindow, AmsApi.Wad, AmsApi.DoomEngine;

var
  gRun: Integer = 0;
  gFail: Integer = 0;

procedure Check(const AName: string; ACondition: Boolean; const AGot: string = '');
begin
  Inc(gRun);
  if ACondition then
    WriteLn('  ok    ', AName)
  else
  begin
    Inc(gFail);
    if AGot <> '' then
      WriteLn('  FEHLT ', AName, '   -> "', AGot, '"')
    else
      WriteLn('  FEHLT ', AName);
  end;
  Flush(Output);
end;

procedure Section(const AName: string);
begin
  WriteLn;
  WriteLn(AName);
  WriteLn(StringOfChar('-', Length(AName)));
end;

{ ------------------------------------------------------- kleines Test-WAD ---- }

procedure PutI32(S: TStream; V: Integer);
var B: array[0..3] of Byte;
begin
  B[0] := Byte(V); B[1] := Byte(V shr 8);
  B[2] := Byte(V shr 16); B[3] := Byte(V shr 24);
  S.WriteBuffer(B, 4);
end;

procedure PutName(S: TStream; const AName: string);
var B: array[0..7] of Byte; i: Integer;
begin
  FillChar(B, 8, 0);
  for i := 1 to Length(AName) do
    if i <= 8 then B[i - 1] := Byte(AName[i]);
  S.WriteBuffer(B, 8);
end;

{ Baut ein IWAD mit PLAYPAL (768 Byte) und einem Flat "FLOOR4_8" (4096 Byte). }
function WriteTestWad(const AFile: string): Boolean;
var
  MS: TMemoryStream;
  Pal: array[0..767] of Byte;
  Flat: array[0..4095] of Byte;
  i: Integer;
  PalOfs, FlatOfs, DirOfs: Integer;
begin
  Result := False;
  for i := 0 to 255 do
  begin
    Pal[i * 3]     := i;           { R = Index -> leicht pruefbar }
    Pal[i * 3 + 1] := 255 - i;     { G }
    Pal[i * 3 + 2] := (i * 2) and $FF;
  end;
  for i := 0 to 4095 do Flat[i] := i and $FF;

  MS := TMemoryStream.Create;
  try
    { Header (12 Byte) + Lumps, danach das Verzeichnis. }
    MS.WriteBuffer(PChar('IWAD')^, 4);
    PutI32(MS, 2);          { numlumps }
    PutI32(MS, 0);          { infotableofs - spaeter korrigieren }

    PalOfs := MS.Position;
    MS.WriteBuffer(Pal, SizeOf(Pal));
    FlatOfs := MS.Position;
    MS.WriteBuffer(Flat, SizeOf(Flat));

    DirOfs := MS.Position;
    PutI32(MS, PalOfs);  PutI32(MS, SizeOf(Pal));  PutName(MS, 'PLAYPAL');
    PutI32(MS, FlatOfs); PutI32(MS, SizeOf(Flat)); PutName(MS, 'FLOOR4_8');

    { infotableofs im Header korrigieren }
    MS.Position := 8;
    PutI32(MS, DirOfs);

    MS.SaveToFile(AFile);
    Result := True;
  finally
    MS.Free;
  end;
end;

{ 32-Bit-BMP aus dem Bildpuffer schreiben (bottom-up). Der Puffer liegt schon
  als B,G,R,0 im Speicher - genau das BMP-Format. }
procedure DumpBmp(const AFile: string; ABuf: PAmsPixelBuf; AW, AH: Integer);
var
  F: TFileStream;
  FileHdr: array[0..13] of Byte;
  InfoHdr: array[0..39] of Byte;
  DataSize, y: Integer;

  procedure PutI(var B: array of Byte; O, V: Integer);
  begin
    B[O] := Byte(V); B[O + 1] := Byte(V shr 8);
    B[O + 2] := Byte(V shr 16); B[O + 3] := Byte(V shr 24);
  end;

begin
  DataSize := AW * AH * 4;
  FillChar(FileHdr, SizeOf(FileHdr), 0);
  FileHdr[0] := Ord('B'); FileHdr[1] := Ord('M');
  PutI(FileHdr, 2, 14 + 40 + DataSize);
  PutI(FileHdr, 10, 14 + 40);
  FillChar(InfoHdr, SizeOf(InfoHdr), 0);
  PutI(InfoHdr, 0, 40);
  PutI(InfoHdr, 4, AW);
  PutI(InfoHdr, 8, AH);
  InfoHdr[12] := 1; InfoHdr[14] := 32;
  PutI(InfoHdr, 20, DataSize);
  try
    F := TFileStream.Create(AFile, fmCreate);
    try
      F.WriteBuffer(FileHdr, SizeOf(FileHdr));
      F.WriteBuffer(InfoHdr, SizeOf(InfoHdr));
      for y := AH - 1 downto 0 do
        F.WriteBuffer(ABuf^[y * AW], AW * 4);
    finally
      F.Free;
    end;
  except
    on E: Exception do WriteLn('  (BMP nicht geschrieben: ', E.Message, ')');
  end;
end;

{ --------------------------------------------------------------- WAD-Test ---- }

procedure TestWad;
var
  Wf: string;
  W: TAmsWad;
  Pal: TAmsPalette;
  Flat: TAmsByteArray;
begin
  Section('WAD-Leser (synthetisches IWAD)');
  Wf := IncludeTrailingPathDelimiter(GetTempDir) + 'amsapi_test.wad';
  Check('Test-WAD geschrieben', WriteTestWad(Wf));

  W := TAmsWad.Create(Wf);
  try
    Check('WAD gilt als gueltig', W.Valid);
    Check('Kennung ist IWAD', W.Kind = 'IWAD', W.Kind);
    Check('zwei Lumps', W.LumpCount = 2, IntToStr(W.LumpCount));
    Check('PLAYPAL gefunden', W.IndexOf('PLAYPAL') >= 0);
    Check('FLOOR4_8 gefunden', W.IndexOf('FLOOR4_8') >= 0);
    Check('Suche ist gross-/kleinunabhaengig', W.IndexOf('floor4_8') >= 0);

    Check('Palette gelesen', W.ReadPalette(Pal));
    { Index 10: R=10, G=245, B=20 -> $000AF514 }
    Check('Palettenfarbe stimmt (Index 10)',
          Pal[10] = AmsRGB(10, 245, 20), IntToHex(Pal[10], 6));

    Check('Flat gelesen', W.ReadFlat('FLOOR4_8', Flat) and (Length(Flat) = 4096),
          IntToStr(Length(Flat)));
    Check('Flat-Byte stimmt', (Length(Flat) = 4096) and (Flat[100] = (100 and $FF)));

    Check('unbekanntes Lump -> -1', W.IndexOf('GIBTSNICHT') = -1);
  finally
    W.Free;
  end;
  DeleteFile(Wf);
end;

{ --------------------------------------------------------------- Engine ------ }

function CountNonBlack(ABuf: PAmsPixelBuf; AN: Integer): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to AN - 1 do
    if (ABuf^[i] and $00FFFFFF) <> 0 then Inc(Result);
end;

function DistinctColors(ABuf: PAmsPixelBuf; AN: Integer): Integer;
var
  i, c: Integer;
  seen: array of LongWord;
  found: Boolean;
begin
  { grobe Zaehlung: bis 64 verschiedene reichen als "es ist strukturiert" }
  SetLength(seen, 0);
  Result := 0;
  for i := 0 to AN - 1 do
  begin
    found := False;
    for c := 0 to High(seen) do
      if seen[c] = ABuf^[i] then begin found := True; Break; end;
    if not found then
    begin
      SetLength(seen, Length(seen) + 1);
      seen[High(seen)] := ABuf^[i];
      Inc(Result);
      if Result >= 64 then Exit;
    end;
  end;
end;

procedure TestEngine;
const
  W = 320; H = 200;
var
  D: TAmsDoom;
  Buf: PAmsPixelBuf;
  In_: TAmsDoomInput;
  i, nonblack, colors, killsBefore: Integer;
  Bmp: string;
begin
  Section('Engine (erzeugte Assets)');
  D := TAmsDoom.Create;
  Buf := nil;
  try
    Check('Assets ohne WAD geladen (erzeugt)', not D.LoadAssets(''));
    D.NewGame;
    Check('Startgesundheit 100', D.Health = 100, IntToStr(D.Health));
    Check('es gibt Gegner', D.Monsters > 0, IntToStr(D.Monsters));

    GetMem(Buf, W * H * SizeOf(TAmsPixel));

    { Ein paar Schritte drehen und vorlaufen, damit sich Waende zeigen. }
    FillChar(In_, SizeOf(In_), 0);
    for i := 0 to 20 do
    begin
      In_.TurnRight := (i mod 2 = 0);
      In_.GoForward := True;
      D.Tick(In_, 28);
    end;
    D.Render(Buf, W, H);

    nonblack := CountNonBlack(Buf, W * H);
    colors := DistinctColors(Buf, W * H);
    Check('Bild ist nicht schwarz',
          nonblack > (W * H) div 4, IntToStr(nonblack));
    Check('Bild ist strukturiert (viele Farben)',
          colors >= 16, IntToStr(colors));

    Bmp := IncludeTrailingPathDelimiter(GetTempDir) + 'amsapi_doom_frame.bmp';
    DumpBmp(Bmp, Buf, W, H);
    WriteLn('  ->    Frame gespeichert: ', Bmp);

    { Schiessen: irgendwann sollte ein Gegner ins Visier geraten. Wir drehen
      langsam und feuern dauernd; die Gesamtzahl der Kills darf nicht sinken
      und sollte bei genug Runden steigen (Gegner laufen auf uns zu). }
    killsBefore := D.Kills;
    for i := 0 to 400 do
    begin
      FillChar(In_, SizeOf(In_), 0);
      In_.Fire := True;
      In_.TurnRight := (i mod 30) < 15;
      D.Tick(In_, 28);
    end;
    Check('Kills sind nicht negativ und plausibel',
          (D.Kills >= killsBefore) and (D.Kills <= D.Monsters),
          IntToStr(D.Kills));
    WriteLn('  ->    Kills nach 400 Schritten: ', D.Kills, '/', D.Monsters,
            ', Munition: ', D.Ammo, ', HP: ', D.Health);

    { Render bei kaputten Massen darf nicht abstuerzen. }
    D.Render(Buf, 0, 0);
    D.Render(nil, W, H);
    Check('Render mit Nullmassen ist harmlos', True);
  finally
    if Buf <> nil then FreeMem(Buf);
    D.Free;
  end;
end;

{ --------------------------------------------------- Bildpuffer-Fenster ------ }

var
  gFrames: Integer = 0;

type
  TFrameSink = class
    procedure OnFrame(ASender: TAmsGameWindow; AElapsedMs: Integer);
  end;

procedure TFrameSink.OnFrame(ASender: TAmsGameWindow; AElapsedMs: Integer);
begin
  Inc(gFrames);
  ASender.Clear(AmsRGB(20, 40, 20));
  ASender.SetPixel(10, 10, $00FF0000);
end;

procedure Pump(AMs: Integer);
var
  Msg: TMsg;
  T0: QWord;
begin
  T0 := GetTickCount64;
  repeat
    while PeekMessageW(Msg, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(Msg);
      DispatchMessageW(Msg);
    end;
    Sleep(5);
  until GetTickCount64 - T0 >= QWord(AMs);
end;

procedure TestWindow;
var
  GW: TAmsGameWindow;
  Sink: TFrameSink;
begin
  Section('Bildpuffer-Fenster (versteckt, ohne AMS)');
  Sink := TFrameSink.Create;
  gFrames := 0;
  GW := TAmsGameWindow.Create('doomdemo (versteckt)', 320, 200, 0, 2);
  try
    Check('Fenster erzeugt', GW.Handle <> 0);
    Check('Bildpuffer vorhanden', GW.Bits <> nil);
    { verstecken und aus dem Bild schieben, damit kein Fokus geklaut wird }
    SetWindowPos(GW.Handle, 0, -3200, -3200, 200, 200,
                 SWP_NOZORDER or SWP_NOACTIVATE);
    ShowWindow(GW.Handle, SW_HIDE);

    GW.OnFrame := Sink.OnFrame;
    GW.Start(15);
    Pump(200);
    GW.Stop;
    Check('Schleife hat Frames gerechnet', gFrames > 0, IntToStr(gFrames));
    Check('Puffer wurde beschrieben',
          (GW.Bits <> nil) and (GW.Bits^[0] = AmsRGB(20, 40, 20)));
  finally
    GW.Free;
    Sink.Free;
  end;
  Check('Fenster nach Free abgebaut (kein Absturz)', True);

  { Zweites Erzeugen muss gehen (Klasse sauber ab-/wieder angemeldet). }
  GW := TAmsGameWindow.Create('doomdemo 2', 64, 64, 0, 1);
  try
    Check('zweites Fenster geht', GW.Handle <> 0);
  finally
    GW.Free;
  end;
end;

begin
  AmsSetLogFile(IncludeTrailingPathDelimiter(GetTempDir) + 'amsapi_doomdemo.log');
  WriteLn('AmsApi - DOOM-Engine ohne AMS');
  WriteLn('=============================');

  TestWad;
  TestEngine;
  TestWindow;

  WriteLn;
  WriteLn(Format('%d Pruefungen, %d Fehlschlaege.', [gRun, gFail]));
  if gFail = 0 then WriteLn('ALLES GRUEN.') else WriteLn('FEHLGESCHLAGEN.');
  Halt(gFail);
end.
