program unittests;

{ ============================================================================
  Tests, die OHNE AMS laufen.

  Designregel 7 der Bibliothek: was ohne AMS testbar ist, muss ohne AMS
  testbar sein. Das betrifft INI-Parser, Pfadaufloesung, den Aufbau der
  Delphi-Strings und die Bildkonvertierung - also genau die Stellen, an denen
  im Prototyp still falsche Werte entstanden sind.

  Rueckgabewert 0 = alles gruen, sonst Anzahl der Fehlschlaege.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{$WARN 4056 OFF}

uses
  Windows, SysUtils, Classes, FPImage, FPWritePNG,
  AmsApi.Types, AmsApi.Log, AmsApi.Ini, AmsApi.Strings, AmsApi.Glyphs,
  AmsApi.Bind, AmsApi.Props, AmsApi.Ui, AmsApi.Hook, AmsApi.Trace,
  AmsApi.Recorder, AmsApi.Rtti, AmsApi.Factory;

var
  gRun: Integer = 0;
  gFail: Integer = 0;
  gTmp: string;

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

procedure CheckEq(const AName, AExpected, AGot: string);
begin
  Inc(gRun);
  if AExpected = AGot then
    WriteLn('  ok    ', AName)
  else
  begin
    Inc(gFail);
    WriteLn('  FEHLT ', AName, '   erwartet "', AExpected, '", bekommen "',
            AGot, '"');
  end;
  Flush(Output);
end;

procedure Section(const AName: string);
begin
  WriteLn;
  WriteLn(AName);
  WriteLn(StringOfChar('-', Length(AName)));
end;

{ ------------------------------------------------------------- INI-Parser -- }

procedure TestIni;
var
  F: string;
  L: TStringList;
begin
  Section('INI-Parser');
  F := gTmp + 'amsapi_test.ini';
  L := TStringList.Create;
  try
    L.Add('; Kommentar mit = Zeichen');
    L.Add('# noch ein Kommentar');
    L.Add('Einfach=Wert');
    L.Add('  MitLeerzeichen  =   getrimmt   ');
    L.Add('Leer=');
    L.Add('Doppelt=erste');
    L.Add('Doppelt=zweite');
    L.Add('Zahl=42');
    L.Add('JaNein=ja');
    L.Add('[Extra]');
    L.Add('Einfach=aus Abschnitt');
    L.SaveToFile(F);
  finally
    L.Free;
  end;

  CheckEq('einfacher Wert', 'Wert', AmsIniValue(F, 'Einfach', '?'));
  { Genau hier lag der Fehler im Prototyp: TStrings.Values vergleicht den
    Schluessel buchstaeblich und liefert bei "  Key = x" still den Default. }
  CheckEq('Leerzeichen um Schluessel und Wert', 'getrimmt',
          AmsIniValue(F, 'MitLeerzeichen', '?'));
  CheckEq('Schluessel case-insensitiv', 'Wert', AmsIniValue(F, 'EINFACH', '?'));
  CheckEq('leerer Wert -> Default', 'Standard',
          AmsIniValue(F, 'Leer', 'Standard'));
  CheckEq('erste Fundstelle gewinnt', 'erste', AmsIniValue(F, 'Doppelt', '?'));
  CheckEq('fehlender Schluessel -> Default', 'Default',
          AmsIniValue(F, 'GibtsNicht', 'Default'));
  CheckEq('Kommentare uebersprungen', 'Default',
          AmsIniValue(F, 'Kommentar mit', 'Default'));
  CheckEq('Abschnitt gezielt', 'aus Abschnitt',
          AmsIniValue(F, 'Einfach', '?', 'Extra'));
  CheckEq('fehlende Datei -> Default', 'Default',
          AmsIniValue(gTmp + 'gibtsnicht.ini', 'Egal', 'Default'));

  DeleteFile(F);
end;

{ ------------------------------------------------------- Pfadaufloesung ---- }

procedure TestPaths;
var
  Dir: string;
begin
  Section('Pfadaufloesung');
  Dir := AmsModuleDir;
  Check('Modulverzeichnis endet auf Backslash',
        (Dir <> '') and (Dir[Length(Dir)] = '\'), Dir);
  Check('absolut mit Laufwerk', AmsIsAbsolutePath('C:\x\y.png'));
  Check('absolut als UNC', AmsIsAbsolutePath('\\server\share\y.png'));
  Check('relativ ist nicht absolut', not AmsIsAbsolutePath('icon32.png'));
  CheckEq('absoluter Pfad bleibt', 'C:\x\y.png', AmsResolvePath('C:\x\y.png'));
  CheckEq('relativ wird ab Modulordner aufgeloest', Dir + 'icon32.png',
          AmsResolvePath('icon32.png'));
  CheckEq('fuehrendes ./ faellt weg', Dir + 'icon32.png',
          AmsResolvePath('./icon32.png'));
  CheckEq('Schraegstriche werden normalisiert', Dir + 'bilder\icon32.png',
          AmsResolvePath('./bilder/icon32.png'));
  CheckEq('leer bleibt leer', '', AmsResolvePath('   '));
end;

{ --------------------------------------------------- Delphi-Stringaufbau --- }

procedure TestStrings;
var
  P: PByte;
  Raw: Pointer;
  A, B: Pointer;
begin
  Section('Delphi-Strings ueber die Modulgrenze');
  Raw := AmsStr('Caption');
  P := PByte(Raw);
  Check('Zeiger geliefert', Raw <> nil);
  CheckEq('CodePage 1200 (UTF-16)', '1200',
          IntToStr(PWord(P - 12)^));
  CheckEq('ElemSize 2', '2', IntToStr(PWord(P - 10)^));
  { Der Punkt, an dem sonst der Heap kracht: RefCount -1 heisst fuer Delphi
    "Literal, niemals freigeben". }
  CheckEq('RefCount -1', '-1', IntToStr(PInteger(P - 8)^));
  CheckEq('Length 7', '7', IntToStr(PInteger(P - 4)^));
  CheckEq('Inhalt', 'Caption', string(PWideChar(Raw)));
  CheckEq('nullterminiert', '0', IntToStr(PWord(P + 14)^));

  A := AmsStr('Caption');
  B := AmsStr('Hint');
  Check('gleicher Text -> selber Zeiger (Cache)', A = Raw);
  Check('anderer Text -> anderer Zeiger', B <> Raw);

  CheckEq('leerer String', '', string(PWideChar(AmsStr(''))));
  CheckEq('Umlaute bleiben erhalten', 'Größe',
          string(PWideChar(AmsStr('Größe'))));

  CheckEq('Rueckweg aus Host-String', 'Caption', AmsFromHostStr(Raw));
  CheckEq('Rueckweg von nil', '', AmsFromHostStr(nil));
end;

{ ------------------------------------------------------ Bildkonvertierung -- }

procedure TestGlyph;
var
  Src, Dst: string;
  Img: TFPMemoryImage;
  Wr: TFPWriterPNG;
  HasAlpha: Boolean;
  F: TFileStream;
  Hdr: array[0..57] of Byte;   { 14 Dateikopf + 40 Infokopf + 1 Pixel }
  W, H, Bits: Integer;
  C: TFPColor;
begin
  Section('Bildkonvertierung PNG -> BMP32');
  Src := gTmp + 'amsapi_test.png';

  { Testbild bauen: 4x2, halbtransparentes Rot. }
  Img := TFPMemoryImage.Create(4, 2);
  Wr := TFPWriterPNG.Create;
  try
    Wr.UseAlpha := True;
    C.Red := $FFFF; C.Green := 0; C.Blue := 0; C.Alpha := $8080;
    for W := 0 to 3 do
      for H := 0 to 1 do
        Img.Colors[W, H] := C;
    Img.SaveToFile(Src, Wr);
  finally
    Wr.Free;
    Img.Free;
  end;
  Check('Testbild geschrieben', FileExists(Src));

  Dst := AmsEnsureLoadableBitmap(Src, HasAlpha);
  Check('Konvertierung liefert Pfad', Dst <> '', AmsLastError);
  Check('Alphakanal gemeldet', HasAlpha);
  Check('BMP existiert', FileExists(Dst), Dst);

  if FileExists(Dst) then
  begin
    F := TFileStream.Create(Dst, fmOpenRead or fmShareDenyNone);
    try
      F.ReadBuffer(Hdr, SizeOf(Hdr));
    finally
      F.Free;
    end;
    CheckEq('BMP-Signatur', 'BM', Chr(Hdr[0]) + Chr(Hdr[1]));
    W := PInteger(@Hdr[18])^;
    H := PInteger(@Hdr[22])^;
    Bits := PWord(@Hdr[28])^;
    CheckEq('Breite', '4', IntToStr(W));
    CheckEq('Hoehe', '2', IntToStr(H));
    { 32 Bit ist Pflicht - sonst geht die Transparenz verloren. }
    CheckEq('32 Bit pro Pixel', '32', IntToStr(Bits));
    { erstes Pixel ab Offset 54, BGRA, bottom-up. Rot mit halbem Alpha:
      B=0, G=0, R=255, A=128. }
    CheckEq('Pixel Blau', '0', IntToStr(Hdr[54]));
    CheckEq('Pixel Gruen', '0', IntToStr(Hdr[55]));
    CheckEq('Pixel Rot', '255', IntToStr(Hdr[56]));
    CheckEq('Pixel Alpha unmultipliziert', '128', IntToStr(Hdr[57]));
  end;

  CheckEq('.bmp wird durchgereicht', Dst, AmsEnsureLoadableBitmap(Dst, HasAlpha));
  Check('unbekanntes Format wird abgelehnt',
        AmsEnsureLoadableBitmap(gTmp + 'nixda.tif', HasAlpha) = '');
  Check('fehlende Datei wird abgelehnt',
        AmsEnsureLoadableBitmap(gTmp + 'nixda.png', HasAlpha) = '');

  DeleteFile(Src);
  DeleteFile(Dst);
end;

{ ------------------------------------------------------------ Binder ------- }

procedure TestBind;
begin
  Section('Binder (ohne AMS erwartet: nichts gebunden, kein Absturz)');
  { Genau das ist die Anforderung aus dem Handover: fehlende Symbole sind
    kein Absturz, sondern ein False mit Klartext. }
  Check('AmsHostPresent stuerzt nicht ab', True);
  if AmsHostPresent then
  begin
    WriteLn('  (Delphi-RTL im Prozess - Suffix ', AmsHostSuffix, ')');
    Check('Suffix erkannt', AmsHostSuffix <> '');
  end
  else
  begin
    Check('kein Host -> Core bindet nicht', not AmsBindCore);
    Check('kein Host -> Bars binden nicht', not AmsBindBars);
    Check('wiederholter Aufruf ist idempotent', not AmsBindCore);
  end;
  WriteLn('  ', StringReplace(AmsBindReport, sLineBreak, sLineBreak + '  ',
                              [rfReplaceAll]));
end;

{ ------------------------------------------------ Elementsuche und Patches - }

procedure TestMatch;
begin
  Section('Textmuster der Elementsuche');
  Check('leeres Muster passt immer', AmsMatch('', 'irgendwas'));
  Check('Gleichheit ohne Platzhalter', AmsMatch('bbNeu', 'bbneu'));
  Check('ohne Platzhalter kein Teilstring', not AmsMatch('Neu', 'bbNeu'));
  Check('als Teilstring erlaubt', AmsMatch('Neu', 'bbNeu', True));
  Check('Stern am Ende', AmsMatch('bb*', 'bbSpeichern'));
  Check('Stern am Anfang', AmsMatch('*Speichern', 'bbSpeichern'));
  Check('Stern in der Mitte', AmsMatch('bb*ern', 'bbSpeichern'));
  Check('zwei Sterne', AmsMatch('*Spei*', 'bbSpeichern'));
  Check('Stern passt auch auf nichts', AmsMatch('bbNeu*', 'bbNeu'));
  Check('Fragezeichen ist genau ein Zeichen', AmsMatch('bbNe?', 'bbNeu'));
  Check('Fragezeichen nicht null Zeichen', not AmsMatch('bbNeu?', 'bbNeu'));
  Check('nicht passendes Muster', not AmsMatch('bb*', 'cbSpeichern'));
  { Der Fall, an dem naive Vergleiche scheitern: der Stern muss
    zuruecksetzen koennen. }
  Check('Rueckverfolgung noetig', AmsMatch('*ab*cd', 'xxabxxabxxcd'));
  Check('Rueckverfolgung erkennt auch das Nein',
        not AmsMatch('*ab*cd', 'xxabxxabxxce'));
end;

procedure TestColors;
var
  C: Integer;
begin
  Section('Farbwerte');
  Check('clRed', AmsColorFromText('clRed', C) and (C = $0000FF), IntToHex(C, 8));
  Check('Name ohne Ruecksicht auf Gross/Klein',
        AmsColorFromText('CLBLUE', C) and (C = $FF0000), IntToHex(C, 8));
  { TColor ist $00BBGGRR - HTML ist andersherum. Genau hier vertut man sich. }
  Check('#RRGGBB wird gedreht',
        AmsColorFromText('#FF8800', C) and (C = $0088FF), IntToHex(C, 8));
  Check('$-Schreibweise', AmsColorFromText('$0088FF', C) and (C = $0088FF),
        IntToHex(C, 8));
  Check('0x-Schreibweise', AmsColorFromText('0x0088FF', C) and (C = $0088FF),
        IntToHex(C, 8));
  Check('Dezimalzahl', AmsColorFromText('255', C) and (C = 255), IntToStr(C));
  Check('Unsinn wird abgelehnt', not AmsColorFromText('gruenlich', C));
  Check('leer wird abgelehnt', not AmsColorFromText('  ', C));
  { Dieselbe Zahlenerkennung liest auch Fensterhandles, wie sie AutoIt
    Window Info ausgibt. }
  Check('Handle in 0x-Schreibweise',
        AmsIntFromText('0x00650E98', C) and (C = $00650E98), IntToHex(C, 8));
  Check('Handle mit Leerzeichen', AmsIntFromText('  $650E98  ', C) and
        (C = $650E98), IntToHex(C, 8));
  Check('AmsIntFromText kennt keine Farbnamen',
        not AmsIntFromText('clRed', C));
  CheckEq('Rueckweg mit Namen', 'clRed', AmsColorToText($0000FF));
  CheckEq('Rueckweg ohne Namen', '$00123456', AmsColorToText($123456));
  CheckEq('Systemfarbe', 'clBtnFace', AmsColorToText(Integer($8000000F)));
end;

procedure TestPatchLine;
var
  E, P, V: string;
begin
  Section('Patchzeilen');
  Check('einfache Zeile', AmsSplitPatch('bbNeu.Enabled=0', E, P, V));
  CheckEq('  Element', 'bbNeu', E);
  CheckEq('  Eigenschaft', 'Enabled', P);
  CheckEq('  Wert', '0', V);

  { Getrennt wird am ERSTEN Punkt - der Rest ist ein Eigenschaftspfad. }
  Check('verschachtelte Eigenschaft',
        AmsSplitPatch('bb*.Font.Style=[fsBold,fsItalic]', E, P, V));
  CheckEq('  Element mit Platzhalter', 'bb*', E);
  CheckEq('  Pfad bleibt zusammen', 'Font.Style', P);
  CheckEq('  Menge als Wert', '[fsBold,fsItalic]', V);

  Check('Leerzeichen werden getrimmt',
        AmsSplitPatch('  bbNeu . Caption  =  Neuer Text  ', E, P, V));
  CheckEq('  getrimmtes Element', 'bbNeu', E);
  CheckEq('  getrimmter Wert', 'Neuer Text', V);

  Check('Gleichheitszeichen im Wert bleibt drin',
        AmsSplitPatch('bbNeu.Hint=a=b', E, P, V));
  CheckEq('  Wert mit =', 'a=b', V);

  Check('ohne Punkt ist keine Patchzeile',
        not AmsSplitPatch('bbNeu=0', E, P, V));
  Check('ohne Gleichheitszeichen ist keine Patchzeile',
        not AmsSplitPatch('bbNeu.Enabled', E, P, V));
  Check('leere Zeile ist keine Patchzeile', not AmsSplitPatch('', E, P, V));
end;

procedure TestUiWithoutHost;
var
  L: TAmsElementArray;
  E: TAmsElement;
  Props: TAmsPropArray;
  Dest: TStringList;
begin
  Section('Elementzugriff ohne AMS (darf nicht abstuerzen)');
  { Ohne Host ist nichts gebunden. Verlangt ist nicht "es geht", sondern
    "es liefert sauber nichts" - genau daran ist der Prototyp gescheitert. }
  Check('HasProp auf nil', not AmsHasProp(nil, 'Caption'));
  Check('Kind auf nil ist pkNone', AmsPropKindOf(nil, 'Caption') = pkNone);
  CheckEq('GetProp auf nil ist leer', '', AmsGetProp(nil, 'Caption'));
  Check('SetProp auf nil scheitert sauber',
        not AmsSetProp(nil, 'Caption', 'x'), AmsLastError);
  Check('PropList auf nil ist leer', AmsPropList(nil, Props) = 0);
  Check('Pfadaufloesung auf nil', AmsGetPropObject(nil, 'Font') = nil);

  Check('Suche ohne Host findet nichts', AmsFindElements(AmsByName('x'), L) = 0);
  Check('FindElement liefert False', not AmsFindElement(AmsByName('x'), E));
  Check('Element() liefert False', not AmsElement('x', E));
  Check('leerer Name wird abgelehnt', not AmsElement('   ', E));
  Check('Element unter nil-Zeiger', AmsElementOf(nil).Obj = nil);
  Check('ElementAlive auf leerem Element', not AmsElementAlive(E));
  Check('Enable ohne Element scheitert', not AmsEnableElement(nil, False));
  Check('Bounds ohne Element scheitert',
        not AmsSetElementBounds(nil, 1, 2, 3, 4));
  Check('Klick ohne Element scheitert', not AmsClickElement(nil));
  Check('Hook ohne Element scheitert', not AmsHookClick(nil, nil));

  Check('Journal ist leer', AmsChangeCount = 0);
  Check('Ruecknahme ohne Aenderungen', AmsUndoAll = 0);
  Check('keine uebernommenen Ereignisse', AmsHookCount = 0);
  { Muss auch ohne Host durchlaufen - es wird beim Entladen immer gerufen. }
  AmsUiRelease;
  Check('AmsUiRelease ohne Host', True);

  Dest := TStringList.Create;
  try
    AmsDumpElements(AmsFilterAll, Dest);
    Check('Dump schreibt eine Meldung statt zu krachen', Dest.Count > 0);
    Dest.Clear;
    AmsDumpElement(nil, Dest);
    Check('Elementdump auf nil', Dest.Count > 0);
    Dest.Clear;
    AmsDumpChanges(Dest);
    Check('Journaldump', Dest.Count > 0);
  finally
    Dest.Free;
  end;
end;

{ --------------------------------------------------------- Log/Fehler ------ }

procedure TestLog;
begin
  Section('Log und Fehlerspeicher');
  AmsClearError;
  CheckEq('nach ClearError leer', '', AmsLastError);
  Check('AmsFail liefert False', not AmsFail('Testfehler 1'));
  CheckEq('LastError gemerkt', 'Testfehler 1', AmsLastError);
  Check('AmsFailFmt liefert False', not AmsFailFmt('Fehler %d', [7]));
  CheckEq('LastError formatiert', 'Fehler 7', AmsLastError);
  AmsClearError;
  CheckEq('wieder leer', '', AmsLastError);
  Check('Logdatei benannt', AmsLogFile <> '', AmsLogFile);
end;

{ ------------------------------------------------------------ Aufzeichnung - }

procedure TestTrace;
var
  F: string;
  L: TStringList;
  Klick, Action: Integer;
  Sp: TStringList;
  Rep: string;
begin
  Section('Aufzeichnung - Textaufbereitung');
  CheckEq('Zeilenumbruch wird zu Leerzeichen', 'SELECT * FROM KUNDE',
          AmsTraceClean('SELECT *'#13#10'FROM KUNDE', 100));
  CheckEq('Tabulator wird zu Leerzeichen', 'A B',
          AmsTraceClean('A'#9'B', 100));
  CheckEq('Mehrfachleerzeichen zusammengefasst', 'A B',
          AmsTraceClean('A      B', 100));
  CheckEq('aussen getrimmt', 'A B', AmsTraceClean('   A  B   ', 100));
  CheckEq('gekuerzt mit Auslassung', 'ABCDEFG...',
          AmsTraceClean('ABCDEFGHIJKLMNOP', 10));
  CheckEq('leer bleibt leer', '', AmsTraceClean('   '#9#13#10'  ', 100));

  Section('Aufzeichnung - Verschachtelung');
  F := gTmp + 'amsapi_test.trace.tsv';
  Check('Start', AmsTraceStart(F), AmsLastError);
  Check('laeuft', AmsTraceRunning);
  CheckEq('Datei gemerkt', F, AmsTraceFile);

  Klick := AmsTraceEnter(tcUi, 'Klick "Speichern"', 'frmVertrag.btnSpeichern');
  Check('Enter liefert eine Nummer', Klick > 0);
  Action := AmsTraceEnter(tcAction, 'acVertragSpeichern');
  AmsTraceNote(tcSql, 'UPDATE VERTRAG', 'UPDATE VERTRAG'#13#10'SET X = 1');
  AmsTraceNote(tcSql, 'INSERT HISTORIE');
  AmsTraceLeave(Action);
  AmsTraceLeave(Klick, 'ok');

  { Abgeschaltete Kategorie darf gar nichts schreiben }
  AmsTraceCategories := AmsTraceAllCats - [tcSql];
  AmsTraceNote(tcSql, 'DARF NICHT ERSCHEINEN');
  AmsTraceCategories := AmsTraceAllCats;

  Rep := AmsTraceReport;
  AmsTraceStop;
  Check('gestoppt', not AmsTraceRunning);

  L := TStringList.Create;
  Sp := TStringList.Create;
  try
    L.LoadFromFile(F);
    Check('Datei geschrieben', L.Count >= 7, IntToStr(L.Count));
    Check('Kopfzeile', Pos('Dauer_ms', L[0]) > 0, L[0]);

    Sp.Delimiter := #9;
    Sp.StrictDelimiter := True;

    Sp.DelimitedText := L[1];
    CheckEq('1. Zeile ist ein Anfang', '>', Sp[2]);
    CheckEq('Tiefe 0', '0', Sp[3]);
    CheckEq('kein Elternvorgang', '0', Sp[4]);
    CheckEq('Kategorie Ui', 'Ui', Sp[7]);

    Sp.DelimitedText := L[2];
    CheckEq('2. Zeile Tiefe 1', '1', Sp[3]);
    CheckEq('Eltern ist der Klick', IntToStr(Klick), Sp[4]);
    CheckEq('Kategorie Action', 'Action', Sp[7]);

    Sp.DelimitedText := L[3];
    CheckEq('SQL steht unter der Action', IntToStr(Action), Sp[4]);
    CheckEq('SQL ist ein Einzelereignis', '.', Sp[2]);
    CheckEq('SQL einzeilig gemacht', 'UPDATE VERTRAG SET X = 1', Sp[9]);

    Sp.DelimitedText := L[5];
    CheckEq('Action wird geschlossen', '<', Sp[2]);
    Check('mit Dauer', Sp[5] <> '', Sp[5]);

    Sp.DelimitedText := L[6];
    CheckEq('Klick wird geschlossen', '<', Sp[2]);
    CheckEq('Ergebnis mitgeschrieben', 'ok', Sp[9]);

    Check('abgeschaltete Kategorie fehlt',
          Pos('DARF NICHT ERSCHEINEN', L.Text) = 0);
  finally
    Sp.Free;
    L.Free;
  end;

  Check('Bericht nennt die Action', Pos('acVertragSpeichern', Rep) > 0, Rep);
  Check('Bericht zaehlt das SQL', Pos('UPDATE VERTRAG', Rep) > 0);
  CheckEq('nach Stop kein Zaehlerzuwachs', IntToStr(AmsTraceCount),
          IntToStr(AmsTraceCount));

  AmsTraceClear;
  CheckEq('Bericht nach Clear leer', 'Nichts aufgezeichnet.', AmsTraceReport);
  DeleteFile(F);
end;

{ --------------------------------------------------------------- Rekorder - }

procedure TestRecorder;
begin
  Section('Rekorder - SQL-Kurzform');
  CheckEq('SELECT mit FROM', 'SELECT KUNDE',
          AmsSqlSubject('select id, name from kunde where id = ?'));
  CheckEq('SELECT mehrzeilig', 'SELECT VERTRAG',
          AmsSqlSubject('SELECT *'#13#10'  FROM VERTRAG v'#13#10' WHERE 1=1'));
  CheckEq('INSERT INTO', 'INSERT HISTORIE',
          AmsSqlSubject('insert into historie (a,b) values (?,?)'));
  CheckEq('INSERT ohne Leerzeichen vor Klammer', 'INSERT LOG',
          AmsSqlSubject('INSERT INTO LOG(A) VALUES(1)'));
  CheckEq('UPDATE', 'UPDATE VERTRAG',
          AmsSqlSubject('update vertrag set x = 1 where id = ?'));
  CheckEq('DELETE', 'DELETE POSTEN',
          AmsSqlSubject('DELETE FROM POSTEN WHERE ID = ?'));
  CheckEq('EXECUTE PROCEDURE', 'EXECUTE SP_NUMMER',
          AmsSqlSubject('execute procedure sp_nummer(?)'));
  CheckEq('COMMIT o.ae. bleibt das Verb', 'COMMIT',
          AmsSqlSubject('COMMIT'));
  CheckEq('leerer Text', '(leer)', AmsSqlSubject('   '));

  Section('Rekorder ohne AMS (erwartet: sauberes Nein, kein Absturz)');
  Check('SQL-Mitschnitt meldet fehlendes fbclient',
        not AmsRecordSqlStart, AmsLastError);
  Check('Meldung nennt fbclient', Pos('fbclient', AmsLastError) > 0,
        AmsLastError);
  Check('SQL laeuft nicht', not AmsRecordSqlRunning);
  Check('Action-Mitschnitt ohne Host', not AmsRecordActionsStart);
  Check('Actions laufen nicht', not AmsRecordActionsRunning);
  CheckEq('kein Klick uebernommen', '0', IntToStr(AmsRecordClicksStart));
  Check('StartAll scheitert sauber',
        not AmsRecordStartAll(gTmp + 'amsapi_test_rec.tsv'));
  AmsRecordStopAll;
  Check('Stop ohne Start ist harmlos', True);
  Check('Status ist lesbar', Pos('SQL', AmsRecordStatus) > 0,
        AmsRecordStatus);
  CheckEq('keine Hooks zurueckgeblieben', '0', IntToStr(AmsHookedCount));
  DeleteFile(gTmp + 'amsapi_test_rec.tsv');
end;

{ ------------------------------------------------------------------ Hooks -- }

{ Der Detour laesst sich vollstaendig ohne AMS pruefen: wir haengen uns an
  eine EIGENE Funktion. Genau das ist die Probe, die im echten Host niemand
  mehr machen kann, ohne etwas zu riskieren. }

type
  TFnCalc = function(A: Integer): Integer; register;
  TFnTick = function: DWORD; stdcall;

var
  gCalcTramp: Pointer = nil;
  gCalcHits: Integer = 0;
  gTickHits: Integer = 0;
  gFakeVmt: array[0..7] of Pointer;

{$OPTIMIZATION OFF}
{ Mit Stapelrahmen, damit der Prolog wie bei einer Delphi-Methode
  mindestens 5 Byte lang ist (push ebp / mov ebp,esp / sub esp,N). }
function Calc(A: Integer): Integer; register;
var
  L: array[0..3] of Integer;
  i: Integer;
begin
  for i := 0 to 3 do L[i] := A + i;
  Result := L[0] + L[3] - A - 3 + 2;
end;
{$OPTIMIZATION ON}

function CalcDetour(A: Integer): Integer; register;
begin
  Inc(gCalcHits);
  Result := TFnCalc(gCalcTramp)(A) + 100;
end;

function TickDetour: DWORD; stdcall;
begin
  Inc(gTickHits);
  Result := 4711;
end;

procedure DummyTarget;
begin
end;

procedure TestHookDecoder;
var
  B: array[0..15] of Byte;

  function Len(const ABytes: array of Byte): Integer;
  var
    i: Integer;
  begin
    for i := 0 to High(ABytes) do B[i] := ABytes[i];
    Result := AmsInsnLen(@B[0]);
  end;

begin
  Section('Hook - Laengendekoder');
  CheckEq('push ebp', '1', IntToStr(Len([$55])));
  CheckEq('mov ebp,esp', '2', IntToStr(Len([$8B, $EC])));
  CheckEq('sub esp,8', '3', IntToStr(Len([$83, $EC, $08])));
  CheckEq('sub esp,imm32', '6', IntToStr(Len([$81, $EC, $80, $00, $00, $00])));
  CheckEq('mov eax,imm32', '5', IntToStr(Len([$B8, $44, $33, $22, $11])));
  CheckEq('mov [ebp-8],eax', '3', IntToStr(Len([$89, $45, $F8])));
  CheckEq('mov eax,[ebp+8]', '3', IntToStr(Len([$8B, $45, $08])));
  CheckEq('xor eax,eax', '2', IntToStr(Len([$33, $C0])));
  CheckEq('test dl,dl', '2', IntToStr(Len([$84, $D2])));
  CheckEq('push imm8', '2', IntToStr(Len([$6A, $00])));
  CheckEq('push imm32', '5', IntToStr(Len([$68, $44, $33, $22, $11])));
  CheckEq('mov eax,[abs32]', '5', IntToStr(Len([$A1, $44, $33, $22, $11])));
  CheckEq('lea eax,[eax+2]', '3', IntToStr(Len([$8D, $40, $02])));
  CheckEq('ret', '1', IntToStr(Len([$C3])));
  CheckEq('ret imm16', '3', IntToStr(Len([$C2, $04, $00])));
  CheckEq('movzx eax,[ebx]', '3', IntToStr(Len([$0F, $B6, $03])));
  CheckEq('test eax,imm32 (F7 /0)', '6',
          IntToStr(Len([$F7, $C0, $01, $00, $00, $00])));
  CheckEq('not eax (F7 /2, ohne imm)', '2', IntToStr(Len([$F7, $D0])));
  CheckEq('mov [ebp-4],imm32', '7',
          IntToStr(Len([$C7, $45, $FC, $00, $00, $00, $00])));
  CheckEq('mit SIB', '3', IntToStr(Len([$8B, $04, $24])));

  { Was NICHT dekodiert werden darf - lieber kein Hook als ein Absturz }
  CheckEq('call rel32 = 0', '0', IntToStr(Len([$E8, $00, $00, $00, $00])));
  CheckEq('jmp rel32 = 0', '0', IntToStr(Len([$E9, $00, $00, $00, $00])));
  CheckEq('jz rel8 = 0', '0', IntToStr(Len([$74, $10])));
  CheckEq('jz rel32 = 0', '0', IntToStr(Len([$0F, $84, $00, $00, $00, $00])));
  CheckEq('unbekannt = 0', '0', IntToStr(Len([$D6])));
end;

procedure TestHookThunk;
var
  B: array[0..15] of Byte;
  Ziel: Pointer;
  Rel: Integer;
begin
  Section('Hook - Sprungthunk aufloesen');
  Ziel := @DummyTarget;
  FillChar(B, SizeOf(B), 0);
  B[0] := $E9;
  Rel := Integer(PtrUInt(Ziel)) - Integer(PtrUInt(@B[0]) + 5);
  PInteger(@B[1])^ := Rel;
  Check('E9-Thunk wird verfolgt', AmsResolveThunk(@B[0]) = Ziel);
  B[0] := $55;
  Check('kein Thunk bleibt unveraendert', AmsResolveThunk(@B[0]) = @B[0]);
end;

procedure TestHookCode;
var
  Vorher: Integer;
  Gesetzt, Zurueck: Boolean;
begin
  Section('Hook - Detour an einer eigenen Funktion');
  Vorher := Calc(5);
  CheckEq('ungehookt', '7', IntToStr(Vorher));

  gCalcHits := 0;
  Gesetzt := AmsHookCode(@Calc, @CalcDetour, gCalcTramp, 'Calc');
  Check('Hook gesetzt', Gesetzt, AmsLastError);
  if Gesetzt then
  begin
    CheckEq('Detour laeuft', '107', IntToStr(Calc(5)));
    CheckEq('Detour gezaehlt', '1', IntToStr(gCalcHits));
    CheckEq('Trampolin liefert das Original', '7',
            IntToStr(TFnCalc(gCalcTramp)(5)));
    CheckEq('Hook gelistet', '1', IntToStr(AmsHookedCount));
    Check('Bericht nennt den Namen', Pos('Calc', AmsHookReport) > 0);

    { Achtung: AmsResolveThunk wuerde hier UNSEREM Sprung folgen - die
      Funktion faengt jetzt mit E9 an. Deshalb die Adresse selbst. }
    Zurueck := AmsUnhookCode(@Calc);
    Check('Ruecknahme', Zurueck, AmsLastError);
    CheckEq('wieder original', '7', IntToStr(Calc(5)));
    CheckEq('Detour nicht mehr gezaehlt', '1', IntToStr(gCalcHits));
    CheckEq('Liste wieder leer', '0', IntToStr(AmsHookedCount));
  end;

  { Doppelt haengen muss abgelehnt werden, nicht zweimal patchen }
  if AmsHookCode(@Calc, @CalcDetour, gCalcTramp, 'Calc') then
  begin
    Zurueck := AmsHookCode(@Calc, @CalcDetour, gCalcTramp, 'Calc');
    Check('zweiter Hook abgelehnt', not Zurueck);
    CheckEq('trotzdem nur einer', '1', IntToStr(AmsHookedCount));
    AmsUnhookCode(@Calc);
  end;

  Check('nil wird abgewiesen', not AmsHookCode(nil, @CalcDetour, gCalcTramp));
  Check('nil-Detour wird abgewiesen', not AmsHookCode(@Calc, nil, gCalcTramp));
end;

procedure TestHookVmt;
var
  Alt: Pointer;
begin
  Section('Hook - VMT-Slot');
  FillChar(gFakeVmt, SizeOf(gFakeVmt), 0);
  gFakeVmt[2] := @DummyTarget;

  Check('Slot umgebogen',
        AmsHookVmt(@gFakeVmt[0], 8, @CalcDetour, Alt, 'FakeVmt'), AmsLastError);
  Check('alter Zeiger geliefert', Alt = @DummyTarget);
  Check('neuer Zeiger steht', gFakeVmt[2] = @CalcDetour);
  Check('schiefer Offset abgelehnt',
        not AmsHookVmt(@gFakeVmt[0], 7, @CalcDetour, Alt));
  Check('Ruecknahme', AmsUnhookVmt(@gFakeVmt[0], 8));
  Check('wieder original', gFakeVmt[2] = @DummyTarget);
  CheckEq('Liste leer', '0', IntToStr(AmsHookedCount));
end;

{$WARN SYMBOL_DEPRECATED OFF}
procedure TestHookImport;
var
  Alt: Pointer;
  N: Integer;
  T: DWORD;
begin
  Section('Hook - Importtabelle');
  T := GetTickCount;                 { erzwingt den Importeintrag }
  Check('GetTickCount liefert etwas', T > 0);

  gTickHits := 0;
  N := AmsHookImportEverywhere('kernel32.dll', 'GetTickCount', @TickDetour, Alt);
  if N > 0 then
  begin
    CheckEq('Detour wird gerufen', '4711', IntToStr(GetTickCount));
    Check('gezaehlt', gTickHits > 0);
    AmsHookReleaseAll;
    Check('nach Ruecknahme wieder echt', GetTickCount <> 4711);
    CheckEq('Liste leer', '0', IntToStr(AmsHookedCount));
  end
  else
    Check('kernel32!GetTickCount nicht importiert - uebersprungen', True);

  Check('unbekannte DLL wird abgewiesen',
        AmsHookImportEverywhere('gibtesnicht.dll', 'Foo', @TickDetour, Alt) = 0);
end;
{$WARN SYMBOL_DEPRECATED ON}

{ ------------------------------------------------- Klassenkette und VMT ---- }

procedure TestClassChain;
begin
  Section('Klassenkette und VMT-Slots');
  { Alles hier greift in fremden Speicher. Ohne Host gibt es keinen - und
    genau dann darf nichts abstuerzen, sondern es kommt ein leerer Wert. }
  Check('Klasse von nil', AmsClassOf(nil) = nil);
  CheckEq('Klassenname von nil', '', AmsClassNameOf(nil));
  Check('Elternklasse von nil', AmsClassParent(nil) = nil);
  CheckEq('Instanzgroesse von nil', '0', IntToStr(AmsInstanceSize(nil)));
  Check('Abstammung von nil', not AmsClassInheritsFrom(nil, 'TComponent'));
  Check('Abstammung eines Unsinnszeigers',
        not AmsInheritsFrom(Pointer($DEADBEEF), 'TComponent'));
  Check('leerer Klassenname passt auf nichts',
        not AmsClassInheritsFrom(Pointer($DEADBEEF), ''));

  CheckEq('Slotsuche ohne Klasse', '-1',
          IntToStr(AmsVmtIndexOf(nil, Pointer($1000))));
  CheckEq('Slotsuche ohne Methode', '-1',
          IntToStr(AmsVmtIndexOf(Pointer($1000), nil)));
  CheckEq('Slotsuche in fremdem Speicher', '-1',
          IntToStr(AmsVmtIndexOf(Pointer($DEADBEEF), Pointer($BAADF00D))));

  Check('Feldzugriff einer Eigenschaft auf nil',
        not AmsPropWritesField(nil, 'Font'));
end;

{ ------------------------------------------------- Elemente anlegen -------- }

procedure TestFactoryWithoutHost;
var
  Obj: Pointer;
  Opt: TAmsNewOptions;
  Dest: TStringList;
begin
  Section('Elemente anlegen ohne AMS (darf nicht abstuerzen)');

  { Ohne Host fehlen Symbole UND Konstruktorslot. Verlangt ist: nichts
    anlegen, und sagen warum. Ein geratener Slot waere ein Sprung in eine
    beliebige fremde Methode - deshalb gibt es hier keinen Notwert. }
  Check('nicht bereit ohne Host', not AmsFactoryReady);
  Check('mit Begruendung', AmsLastError <> '', AmsLastError);
  CheckEq('kein Konstruktorslot', '-1', IntToStr(AmsCtorSlot));
  CheckEq('kein SetParent-Slot', '-1', IntToStr(AmsSetParentSlot));

  Check('Klasse ohne Namen wird abgelehnt', AmsResolveClass('  ') = nil);
  Check('mit Begruendung', AmsLastError <> '', AmsLastError);
  Check('unbekannte Klasse wird abgelehnt', AmsResolveClass('TButton') = nil);

  Check('Konstruktor ohne Klasse', AmsCreateComponent(nil, nil) = nil);
  { Ein Zeiger, der keine Klasse ist, darf nicht durchrutschen: der
    Konstruktorslot gilt nur unterhalb von TComponent. }
  Check('Konstruktor auf einer Nichtklasse',
        AmsCreateComponent(Pointer($DEADBEEF), nil) = nil);

  Opt := AmsNewDefaults;
  CheckEq('Vorbelegung: keine Klasse', '', Opt.ClassName);
  Check('Vorbelegung: kein Ziel', Opt.Target = nil);
  Check('Vorbelegung: Lage unveraendert', Opt.Left = AmsKeep);
  Opt.ClassName := 'TButton';
  Check('Anlegen ohne Host scheitert', not AmsNewElement(Opt, Obj));
  Check('und liefert nichts', Obj = nil);
  Check('mit Begruendung', AmsLastError <> '', AmsLastError);

  Check('Einhaengen ohne Element', not AmsAttachElement(nil, nil));
  Check('Einhaengen ohne Ziel', not AmsAttachElement(Pointer($1000), nil));
  Check('Umhaengen ohne Element', not AmsMoveElement(nil, nil));

  Check('Klonen ohne Vorlage', not AmsCloneElement(nil, nil, Obj));
  Check('mit Begruendung', AmsLastError <> '', AmsLastError);
  CheckEq('Kopieren ohne Quelle', '0', IntToStr(AmsCopyProps(nil, nil, True)));

  { Fremde Elemente werden hier nicht zerstoert - das ist die wichtigste
    Zusage dieser Unit. }
  Check('Entfernen ohne Element', not AmsRemoveElement(nil));
  Check('fremdes Element wird nicht entfernt',
        not AmsRemoveElement(Pointer($DEADBEEF)));
  Check('mit Begruendung', Pos('nicht von diesem Plugin', AmsLastError) > 0,
        AmsLastError);
  Check('nichts angelegt', not AmsIsSpawned(Pointer($DEADBEEF)));
  CheckEq('Verzeichnis leer', '0', IntToStr(AmsSpawnCount));

  Dest := TStringList.Create;
  try
    AmsDumpSpawned(Dest);
    Check('Verzeichnisausgabe hat eine Ueberschrift', Dest.Count > 0);
  finally
    Dest.Free;
  end;

  { Laeuft beim Entladen IMMER - auch wenn nie etwas angelegt wurde. }
  CheckEq('Abraeumen ohne Angelegtes', '0', IntToStr(AmsFactoryRelease));
end;

begin
  gTmp := IncludeTrailingPathDelimiter(GetTempDir);
  AmsSetLogFile(gTmp + 'amsapi_unittests.log');

  WriteLn('AmsApi ', AMS_API_VERSION, ' - Tests ohne AMS');
  WriteLn('=================================');

  TestLog;
  TestIni;
  TestPaths;
  TestStrings;
  TestGlyph;
  TestMatch;
  TestColors;
  TestPatchLine;
  TestUiWithoutHost;
  TestClassChain;
  TestFactoryWithoutHost;
  TestTrace;
  TestHookDecoder;
  TestHookThunk;
  TestHookCode;
  TestHookVmt;
  TestHookImport;
  TestRecorder;
  TestBind;

  WriteLn;
  WriteLn(Format('%d Pruefungen, %d Fehlschlaege.', [gRun, gFail]));
  if gFail = 0 then WriteLn('ALLES GRUEN.') else WriteLn('FEHLGESCHLAGEN.');
  Halt(gFail);
end.
