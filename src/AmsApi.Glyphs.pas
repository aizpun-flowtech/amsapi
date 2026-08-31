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
  Windows, SysUtils, Classes, FPImage, FPReadPNG, AmsApi.Types;

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
