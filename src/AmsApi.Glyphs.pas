unit AmsApi.Glyphs;

{ ============================================================================
  AmsApi.Glyphs - eigene Symbole in Host-Elemente laden

  TdxBarButton.Glyph / .LargeGlyph sind laut Laufzeitpruefung schlichte
  TBitmap. Deren LoadFromFile ist TGraphic.LoadFromFile aus vcl<NNN>.bpl und
  akzeptiert ausschliesslich BMP - ein PNG quittiert es mit EInvalidGraphic,
  bei uns sichtbar als "External exception EEDFADE".

  Deshalb wird das Bild mit den FPC-eigenen Units dekodiert und als 32-Bit-BMP
  (BGRA, bottom-up, unmultipliziertes Alpha) nach %TEMP% geschrieben.
  Anschliessend AlphaFormat := afDefined setzen; die VCL multipliziert dann
  selbst vor, und die Transparenz bleibt erhalten.

  Die Konvertierung ist ohne AMS testbar (siehe tests\unittests.lpr).
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, FPImage, FPReadPNG, FPReadBMP, AmsApi.Types;

{ 32-Bit-BMP schreiben. Oeffentlich, weil ohne Host testbar. }
function AmsWriteBmp32(AImage: TFPMemoryImage; const ADestFile: string): Boolean;

{ Liefert einen Pfad, den TBitmap.LoadFromFile frisst.
  .bmp wird unveraendert durchgereicht, .png nach %TEMP% konvertiert.
  AHasAlpha meldet, ob eine 32-Bit-BMP mit Alphakanal entstanden ist.
  Leeres Ergebnis = Format nicht unterstuetzt oder Fehler (siehe AmsLastError). }
function AmsEnsureLoadableBitmap(const ASourceFile: string;
  out AHasAlpha: Boolean): string;

{ Bilddatei in eine Grafik-Property eines Host-Objekts laden, z.B.
    AmsSetGlyph(Item, 'LargeGlyph', 'icon32.png')
  Relative Pfade gelten ab dem Plugin-Ordner. }
function AmsSetGlyph(AItem: Pointer; const APropName, AFile: string): Boolean;

{ ------------------------------------------------ Fuer eigene Win32-Fenster
  Ohne Host: PNG/BMP als quadratische 32-Bit-DIB-Section (ASize x ASize,
  seitenrichtig skaliert und zentriert, Alpha VORMULTIPLIZIERT - so wie es
  ImageList (comctl32 v6) und AlphaBlend erwarten). 0 bei Fehler.
  Freigeben mit DeleteObject. }
function AmsLoadImageBitmap(const AFile: string; ASize: Integer): HBITMAP;

{ Platzhalter: abgerundetes Quadrat in AColor mit dem Anfangsbuchstaben. }
function AmsPlaceholderBitmap(const AText: WideString; ASize: Integer;
  AColor: COLORREF): HBITMAP;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Ini, AmsApi.Log;

function AmsWriteBmp32(AImage: TFPMemoryImage; const ADestFile: string): Boolean;
var
  F: TFileStream;
  W, H, X, Y, RowBytes, DataSize: Integer;
  Row: array of Byte;
  C: TFPColor;
  FileHdr: array[0..13] of Byte;
  InfoHdr: array[0..39] of Byte;

  procedure PutI(var ABuf: array of Byte; AOfs, AValue: Integer);
  begin
    ABuf[AOfs]     := Byte(AValue);
    ABuf[AOfs + 1] := Byte(AValue shr 8);
    ABuf[AOfs + 2] := Byte(AValue shr 16);
    ABuf[AOfs + 3] := Byte(AValue shr 24);
  end;

begin
  Result := False;
  if AImage = nil then Exit;
  W := AImage.Width;
  H := AImage.Height;
  if (W <= 0) or (H <= 0) then Exit;
  RowBytes := W * 4;
  DataSize := RowBytes * H;

  FillChar(FileHdr, SizeOf(FileHdr), 0);
  FileHdr[0] := Ord('B');
  FileHdr[1] := Ord('M');
  PutI(FileHdr, 2, 14 + 40 + DataSize);
  PutI(FileHdr, 10, 14 + 40);

  FillChar(InfoHdr, SizeOf(InfoHdr), 0);
  PutI(InfoHdr, 0, 40);
  PutI(InfoHdr, 4, W);
  PutI(InfoHdr, 8, H);
  InfoHdr[12] := 1;                 { Planes   }
  InfoHdr[14] := 32;                { BitCount }
  PutI(InfoHdr, 20, DataSize);
  PutI(InfoHdr, 24, 2835);          { 72 dpi   }
  PutI(InfoHdr, 28, 2835);

  SetLength(Row, RowBytes);
  F := TFileStream.Create(ADestFile, fmCreate);
  try
    F.WriteBuffer(FileHdr, SizeOf(FileHdr));
    F.WriteBuffer(InfoHdr, SizeOf(InfoHdr));
    { BMP ist bottom-up: unterste Zeile zuerst }
    for Y := H - 1 downto 0 do
    begin
      for X := 0 to W - 1 do
      begin
        C := AImage.Colors[X, Y];
        Row[X * 4 + 0] := Byte(C.Blue shr 8);
        Row[X * 4 + 1] := Byte(C.Green shr 8);
        Row[X * 4 + 2] := Byte(C.Red shr 8);
        Row[X * 4 + 3] := Byte(C.Alpha shr 8);
      end;
      F.WriteBuffer(Row[0], RowBytes);
    end;
    Result := True;
  finally
    F.Free;
  end;
end;

function AmsEnsureLoadableBitmap(const ASourceFile: string;
  out AHasAlpha: Boolean): string;
var
  Ext, Dst: string;
  Img: TFPMemoryImage;
  Rd: TFPCustomImageReader;
begin
  Result := '';
  AHasAlpha := False;
  if not FileExists(ASourceFile) then
  begin
    AmsFail('Bilddatei nicht gefunden: ' + ASourceFile);
    Exit;
  end;

  Ext := LowerCase(ExtractFileExt(ASourceFile));
  if Ext = '.bmp' then Exit(ASourceFile);
  if Ext <> '.png' then
  begin
    AmsFail('Bildformat nicht unterstuetzt (nur PNG und BMP): ' + ASourceFile);
    Exit;
  end;

  Rd := nil;
  Img := nil;
  try
    try
      Rd := TFPReaderPNG.Create;
      Img := TFPMemoryImage.Create(0, 0);
      Img.LoadFromFile(ASourceFile, Rd);
      { Zielname enthaelt den Modulnamen, damit sich zwei Plugins mit
        gleichnamigen Symbolen nicht gegenseitig ueberschreiben. }
      Dst := IncludeTrailingPathDelimiter(GetTempDir) + AmsModuleName + '_' +
             ChangeFileExt(ExtractFileName(ASourceFile), '') + '.bmp';
      if AmsWriteBmp32(Img, Dst) then
      begin
        AHasAlpha := True;
        Result := Dst;
      end
      else
        AmsFail('BMP konnte nicht geschrieben werden: ' + Dst);
    except
      on E: Exception do
        AmsFail('Bildkonvertierung fehlgeschlagen: ' + E.Message);
    end;
  finally
    Img.Free;
    Rd.Free;
  end;
end;

{ ---------------------------------------------------- Win32-Bitmaps ------ }

function NewDib(ASize: Integer; out ABits: PCardinal): HBITMAP;
var
  BI: TBitmapInfo;
  P: Pointer;
begin
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
  BI.bmiHeader.biWidth := ASize;
  BI.bmiHeader.biHeight := -ASize;          { top-down }
  BI.bmiHeader.biPlanes := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;
  P := nil;
  Result := CreateDIBSection(0, BI, DIB_RGB_COLORS, P, 0, 0);
  ABits := P;
  if (Result <> 0) and (P <> nil) then
    FillChar(P^, ASize * ASize * 4, 0);
end;

function AmsLoadImageBitmap(const AFile: string; ASize: Integer): HBITMAP;
var
  Img: TFPMemoryImage;
  Rd: TFPCustomImageReader;
  Ext: string;
  Bits: PCardinal;
  W, H, DW, DH, OX, OY, X, Y, SX, SY, SX0, SX1, SY0, SY1, n: Integer;
  R, G, B, A: Cardinal;
  C: TFPColor;
  Ok: Boolean;
begin
  Result := 0;
  if (ASize <= 0) or not FileExists(AFile) then Exit;
  Ext := LowerCase(ExtractFileExt(AFile));
  Img := TFPMemoryImage.Create(0, 0);
  Rd := nil;
  Ok := False;
  try
    try
      if Ext = '.png' then Rd := TFPReaderPNG.Create
      else if Ext = '.bmp' then Rd := TFPReaderBMP.Create
      else Exit;
      Img.LoadFromFile(AFile, Rd);
      W := Img.Width;
      H := Img.Height;
      if (W <= 0) or (H <= 0) then Exit;
      { seitenrichtig in ASize x ASize }
      if W >= H then
      begin
        DW := ASize;
        DH := (H * ASize + W div 2) div W;
      end
      else
      begin
        DH := ASize;
        DW := (W * ASize + H div 2) div H;
      end;
      if DW < 1 then DW := 1;
      if DH < 1 then DH := 1;
      OX := (ASize - DW) div 2;
      OY := (ASize - DH) div 2;
      Result := NewDib(ASize, Bits);
      if Result = 0 then Exit;
      for Y := 0 to DH - 1 do
        for X := 0 to DW - 1 do
        begin
          { Flaechenmittel ueber die Quellpixel dieses Zielpixels }
          SX0 := X * W div DW;
          SX1 := ((X + 1) * W - 1) div DW;
          SY0 := Y * H div DH;
          SY1 := ((Y + 1) * H - 1) div DH;
          if SX1 < SX0 then SX1 := SX0;
          if SY1 < SY0 then SY1 := SY0;
          R := 0; G := 0; B := 0; A := 0; n := 0;
          for SY := SY0 to SY1 do
            for SX := SX0 to SX1 do
            begin
              C := Img.Colors[SX, SY];
              { vormultipliziert mitteln, sonst faerben durchsichtige
                Pixel die Kanten }
              Inc(A, C.Alpha shr 8);
              Inc(R, (Cardinal(C.Red shr 8) * (C.Alpha shr 8)) div 255);
              Inc(G, (Cardinal(C.Green shr 8) * (C.Alpha shr 8)) div 255);
              Inc(B, (Cardinal(C.Blue shr 8) * (C.Alpha shr 8)) div 255);
              Inc(n);
            end;
          PCardinal(PByte(Bits) + ((OY + Y) * ASize + OX + X) * 4)^ :=
            ((A div n) shl 24) or ((R div n) shl 16) or ((G div n) shl 8) or
            (B div n);
        end;
      Ok := True;
    except
      on E: Exception do
        AmsFailFmt('Bild nicht lesbar (%s): %s', [E.Message, AFile]);
    end;
  finally
    Rd.Free;
    Img.Free;
    if not Ok and (Result <> 0) then
    begin
      DeleteObject(Result);
      Result := 0;
    end;
  end;
end;

function AmsPlaceholderBitmap(const AText: WideString; ASize: Integer;
  AColor: COLORREF): HBITMAP;
var
  Bits, P: PCardinal;
  DC: HDC;
  Old: HGDIOBJ;
  F: HFONT;
  OldF: HGDIOBJ;
  R: TRect;
  X, Y, Rad, DX, DY: Integer;
  Inside: Boolean;
  Letter: WideString;
  Fill: Cardinal;
begin
  Result := NewDib(ASize, Bits);
  if Result = 0 then Exit;
  Rad := ASize div 5;
  Fill := $FF000000 or (Cardinal(GetRValue(AColor)) shl 16) or
          (Cardinal(GetGValue(AColor)) shl 8) or GetBValue(AColor);
  for Y := 0 to ASize - 1 do
    for X := 0 to ASize - 1 do
    begin
      DX := 0; DY := 0;
      if X < Rad then DX := Rad - X else if X >= ASize - Rad then DX := X - (ASize - Rad - 1);
      if Y < Rad then DY := Rad - Y else if Y >= ASize - Rad then DY := Y - (ASize - Rad - 1);
      Inside := DX * DX + DY * DY <= Rad * Rad;
      if Inside then
        PCardinal(PByte(Bits) + (Y * ASize + X) * 4)^ := Fill;
    end;
  Letter := '';
  if AText <> '' then Letter := WideUpperCase(Copy(AText, 1, 1));
  if Letter = '' then Exit;
  DC := CreateCompatibleDC(0);
  Old := SelectObject(DC, Result);
  F := CreateFontW(-(ASize * 5 div 8), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
    ANTIALIASED_QUALITY, DEFAULT_PITCH, 'Segoe UI');
  OldF := SelectObject(DC, F);
  SetBkMode(DC, TRANSPARENT);
  SetTextColor(DC, RGB(255, 255, 255));
  R := Rect(0, 0, ASize, ASize);
  DrawTextW(DC, PWideChar(Letter), 1, R, DT_CENTER or DT_VCENTER or DT_SINGLELINE);
  SelectObject(DC, OldF);
  DeleteObject(F);
  SelectObject(DC, Old);
  DeleteDC(DC);
  { GDI loescht beim Zeichnen den Alphakanal - innerhalb der Form wieder
    deckend machen }
  GdiFlush;
  for Y := 0 to ASize - 1 do
    for X := 0 to ASize - 1 do
    begin
      P := PCardinal(PByte(Bits) + (Y * ASize + X) * 4);
      if (P^ <> 0) then P^ := P^ or $FF000000;
    end;
end;

function AmsSetGlyph(AItem: Pointer; const APropName, AFile: string): Boolean;
var
  Glyph, Slot: Pointer;
  Proc: TFnLoadFromFile;
  Cls, Src, Bmp: string;
  HasAlpha: Boolean;
begin
  Result := False;
  if AItem = nil then Exit(AmsFail('SetGlyph: kein Zielobjekt'));
  if AFile = '' then Exit(AmsFail('SetGlyph: kein Dateiname fuer ' + APropName));
  if not AmsBindCore then Exit(AmsFail('SetGlyph: Core-Symbole fehlen'));

  Src := AmsResolvePath(AFile);
  if not FileExists(Src) then
    Exit(AmsFailFmt('%s: Datei nicht gefunden: %s', [APropName, Src]));

  Glyph := AmsGetObj(AItem, APropName);
  if Glyph = nil then
    Exit(AmsFailFmt('%s: Property nicht vorhanden oder nil', [APropName]));

  Cls := AmsClassName(Glyph);
  if (Pos('Glyph', Cls) = 0) and (Pos('Image', Cls) = 0) and
     (Pos('Bitmap', Cls) = 0) then
    Exit(AmsFailFmt('%s: unerwartete Klasse "%s" - lade nicht', [APropName, Cls]));

  Bmp := AmsEnsureLoadableBitmap(Src, HasAlpha);
  if Bmp = '' then Exit;    { AmsLastError ist bereits gesetzt }

  Slot := AmsVmtSlot(Glyph, vmtSlotLoadFromFile);
  if Slot = nil then
    Exit(AmsFailFmt('%s: LoadFromFile nicht im VMT', [APropName]));

  try
    Proc := TFnLoadFromFile(Slot);
    Proc(Glyph, AmsStr(Bmp));
    if HasAlpha and AmsBindVcl and Assigned(hcSetAlphaFormat) then
      hcSetAlphaFormat(Glyph, afDefined);
    AmsLogFmt('%s: geladen aus "%s" [%s] alpha=%s',
              [APropName, Bmp, Cls, BoolToStr(HasAlpha, True)]);
    Result := True;
  except
    on E: Exception do
      Result := AmsFailFmt('%s: LoadFromFile fehlgeschlagen: %s',
                           [APropName, E.Message]);
  end;
end;

end.
