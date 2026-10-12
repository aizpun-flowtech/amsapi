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
  AmsApi.Recorder, AmsApi.Rtti, AmsApi.Factory, Zipper, AmsApi.Files,
  AmsApi.Zip, AmsApi.IniDoc, AmsApi.Markdown, AmsApi.PluginStore,
  AmsApi.PluginApply, AmsApi.Process, AmsApi.Dialogs;

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

{ --------------------------------------------------------- Markdown ------
  Gehoert in tests\unittests.lpr; braucht AmsApi.Markdown in der uses-Liste
  und einen Aufruf TestMarkdown im Hauptblock. }

procedure TestMarkdown;
var
  O: TAmsMarkdownOptions;
  R: string;

  function Md(const S: string): string;
  begin
    Result := Trim(AmsMarkdownToHtml(S, AmsMarkdownDefaults));
  end;

begin
  Section('Markdown nach HTML (README-Anzeige)');

  CheckEq('Ueberschrift mit GitHub-Anker',
          '<h2 id="die-units--teil-2">Die Units &amp; Teil 2!</h2>',
          Md('## Die Units & Teil 2!'));
  CheckEq('Setext-Ueberschrift', '<h2 id="titel">Titel</h2>',
          Md('Titel'#10'---'));
  CheckEq('fett und kursiv', '<p><strong>x</strong> und <em>y</em></p>',
          Md('**x** und _y_'));
  { Die beiden Fallen schlechthin: snake_case darf nicht kursiv werden,
    und in Code bleibt Markdown Markdown. }
  CheckEq('snake_case bleibt', '<p>mein_schoener_name</p>',
          Md('mein_schoener_name'));
  CheckEq('** in Code bleibt', '<p><code>**x**</code></p>', Md('`**x**`'));
  CheckEq('einfache Tilde bleibt', '<p>ca. ~5 min</p>', Md('ca. ~5 min'));
  CheckEq('Codeblock escaped < und &',
          '<pre><code class="language-pascal">if a &lt; b then s := &#39;&amp;&#39;;'#10 +
          '</code></pre>',
          Md('```pascal'#10'if a < b then s := ''&'';'#10'```'));
  CheckEq('verschachtelte Liste',
          '<ul>'#10'<li>a'#10'<ul>'#10'<li>b</li>'#10'</ul></li>'#10 +
          '<li>c</li>'#10'</ul>',
          Md('- a'#10'  - b'#10'- c'));
  R := Md('- [ ] offen'#10'- [x] fertig');
  Check('Aufgabenliste', (Pos('<input type="checkbox" disabled> offen', R) > 0) and
        (Pos('disabled checked> fertig', R) > 0), R);
  R := Md('| L | M | R |'#10'|:--|:-:|--:|'#10'| a | `b\|c` | 1 |');
  Check('Tabelle mit Ausrichtung',
        (Pos('<th style="text-align:center">M</th>', R) > 0) and
        (Pos('<td style="text-align:right">1</td>', R) > 0), R);
  Check('Tabelle: \| bleibt in der Zelle', Pos('<code>b|c</code>', R) > 0, R);
  CheckEq('externer Link im neuen Fenster',
          '<p><a href="https://github.com" target="_blank" rel="noopener">G</a></p>',
          Md('[G](https://github.com)'));
  CheckEq('Referenzlink, & im Ziel escaped',
          '<p><a href="/x?a=1&amp;b=2">x</a></p>',
          Md('[x][r]'#10#10'[r]: /x?a=1&b=2'));
  R := Md('Siehe https://github.com/aizpun-flowtech/amsapi.');
  Check('nackte URL ohne Satzpunkt',
        Pos('>https://github.com/aizpun-flowtech/amsapi</a>.', R) > 0, R);

  O := AmsMarkdownDefaults;
  O.ImageBase := 'https://raw.githubusercontent.com/o/r/HEAD/docs/';
  R := Trim(AmsMarkdownToHtml('![x](../img/a.png)', O));
  Check('relatives Bild mit ../',
        Pos('src="https://raw.githubusercontent.com/o/r/HEAD/img/a.png"', R) > 0, R);
  R := Trim(AmsMarkdownToHtml(
         '<p align="center"><img src="./logo.png" onerror="alert(1)"></p>', O));
  Check('Roh-HTML-<img> relativ aufgeloest',
        Pos('src="https://raw.githubusercontent.com/o/r/HEAD/docs/logo.png"', R) > 0, R);
  Check('onerror entfernt', Pos('onerror', R) = 0, R);

  CheckEq('<script> samt Inhalt weg', '<p>Text  weiter</p>',
          Md('Text <script>alert(1)</script> weiter'));
  CheckEq('javascript:-Link wird Text', '<p>x</p>', Md('[x](javascript:alert(1))'));
  R := Md('<a href="jav&#x61;script:alert(1)">x</a>');
  Check('verschleiertes javascript: entfernt', Pos('script', R) = 0, R);
  CheckEq('nacktes & escaped, Entities bleiben',
          '<p>A &amp; B &amp; C &copy;</p>', Md('A & B &amp; C &copy;'));
  CheckEq('UTF-8 laeuft unveraendert durch',
          '<p>'#$C3#$9C'bersicht</p>', Md(#$EF#$BB#$BF + #$C3#$9C'bersicht'));

  CheckEq('URL ../', 'https://h/a/c.png', AmsResolveUrl('https://h/a/b/', '../c.png'));
  CheckEq('URL ab Wurzel', 'https://h/x.png', AmsResolveUrl('https://h/a/b/', '/x.png'));
  CheckEq('Ordner, / wird \, Query weg', 'C:\p\a.png',
          AmsResolveUrl('C:\p\X\', '../a.png?raw=true'));
  CheckEq('Sanitize: Formular weg, Text bleibt', 'Text',
          AmsSanitizeHtml('<form action="x"><input name="p">Text</form>'));

  { Muell darf nie zu einer Exception oder Endlosschleife fuehren. }
  AmsMarkdownToHtml(StringOfChar('[', 20000), AmsMarkdownDefaults);
  AmsMarkdownToHtml(StringOfChar('>', 5000) + ' x', AmsMarkdownDefaults);
  AmsMarkdownToHtml(#0#1#2#3'<a href="'#10'```'#10'| - |'#10'[x](',
                    AmsMarkdownDefaults);
  Check('Muell ohne Absturz', True);

  R := AmsHtmlPage('A & B', '<p>x</p>');
  Check('Seite: Mark of the Web direkt hinter dem Doctype',
        Copy(R, 1, 61) = '<!DOCTYPE html>'#13#10 +
                         '<!-- saved from url=(0014)about:internet -->', R);
  Check('Seite: IE=edge, UTF-8, escapter Titel',
        (Pos('content="IE=edge"', R) > 0) and (Pos('<meta charset="utf-8">', R) > 0) and
        (Pos('<title>A &amp; B</title>', R) > 0), '');
end;

{ ---------------------------------------------- Dateien, Text, Pruefsummen }

procedure TestFiles;
var
  D, S, Ren, Dir: string;
  W: WideString;
  Lock: HMODULE;
begin
  Section('Dateien, Text, Pruefsummen (Plugin Manager)');
  CheckEq('SHA-256 "abc"',
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    AmsSha256('abc'));
  CheckEq('SHA-256 leer',
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    AmsSha256(''));
  CheckEq('Base64', 'SGVsbG8hPw==', AmsBase64Encode('Hello!?'));
  Check('Base64 hin und zurueck', AmsBase64Decode(AmsBase64Encode(#0#1#255'xy'), D) and
        (D = #0#1#255'xy'));
  Check('UTF-8 erkannt', AmsIsUtf8('Gr'#$C3#$BC#$C3#$9F'e'));
  Check('ANSI ist kein UTF-8', not AmsIsUtf8('Gr'#$FC#$DF));
  W := AmsDecodeText('Gr'#$C3#$BC#$C3#$9F'e');
  Check('UTF-8 dekodiert', (Length(W) = 5) and (Ord(W[3]) = $FC));
  W := AmsDecodeText('Gr'#$FC'n');
  Check('ANSI dekodiert', (Length(W) = 4) and (Ord(W[3]) = $FC));
  CheckEq('nach UTF-8 umkodiert', 'Gr'#$C3#$BC'n', AmsToUtf8('Gr'#$FC'n'));
  Check('BOM weg', AmsStripBom(#$EF#$BB#$BF'x') = 'x');
  CheckEq('PNG am Inhalt', 'image/png', AmsSniffImageMime(#$89'PNG'#13#10#26#10));
  CheckEq('SVG am Inhalt', 'image/svg+xml',
          AmsSniffImageMime('<?xml version="1.0"?><svg xmlns="x"/>'));
  CheckEq('HTML ist kein Bild', '', AmsSniffImageMime('<!DOCTYPE html><html>'));
  CheckEq('MIME nach Endung', 'image/jpeg', AmsMimeOf('https://x/y/bild.JPG?raw=1'));

  Check('Name ok', AmsIsSafeName('HelloButton'));
  Check('Name .. abgelehnt', not AmsIsSafeName('..'));
  Check('Name mit \ abgelehnt', not AmsIsSafeName('a\b'));
  Check('Name mit / abgelehnt', not AmsIsSafeName('a/b'));
  Check('Name mit : abgelehnt', not AmsIsSafeName('C:'));
  Check('Name mit Punkt am Ende abgelehnt', not AmsIsSafeName('x.'));
  Check('relativer Pfad ok', AmsIsSafeRelPath('sub\datei.txt'));
  Check('.. abgelehnt', not AmsIsSafeRelPath('..\boese.dll'));
  Check('versteckt .. abgelehnt', not AmsIsSafeRelPath('a/../../boese.dll'));
  Check('absolut abgelehnt', not AmsIsSafeRelPath('C:\Windows\x.dll'));
  Check('fuehrender Trenner abgelehnt', not AmsIsSafeRelPath('\x.dll'));

  Dir := gTmp + 'amsapi_files\';
  AmsDeleteTree(Dir);
  Check('schreiben legt Ordner an', AmsWriteFileRaw(Dir + 'a\b\c.txt', 'x'));
  Check('beschreibbar', AmsCanWriteDir(Dir));
  Check('fehlender Ordner nicht beschreibbar', not AmsCanWriteDir(Dir + 'nix'));
  Check('nicht virtualisiert', not AmsIsVirtualized);

  { Eine geladene DLL laesst sich nicht ueberschreiben - aber beiseite
    schieben. Genau so liegt eine BPL im laufenden AMS. }
  CopyFileW(PWideChar(WideString(AmsExpandEnv('%SystemRoot%\SysWOW64\atl.dll'))),
            PWideChar(WideString(Dir + 'geladen.bpl')), False);
  AmsWriteFileRaw(Dir + 'neu.bpl', 'NEU');
  Lock := LoadLibraryExW(PWideChar(WideString(Dir + 'geladen.bpl')), 0,
                         DONT_RESOLVE_DLL_REFERENCES);
  Check('Testdatei geladen', Lock <> 0);
  Check('ersetzt trotz Sperre', AmsReplaceFile(Dir + 'neu.bpl',
        Dir + 'geladen.bpl', Ren));
  Check('Original beiseite', (Ren <> '') and FileExists(Ren), Ren);
  Check('neuer Inhalt an seinem Platz', AmsReadFileRaw(Dir + 'geladen.bpl', S) and
        (S = 'NEU'));
  Check('.old noch gesperrt', AmsCleanupOld(Dir) = 0);
  if Lock <> 0 then FreeLibrary(Lock);
  CheckEq('.old nach dem Freigeben weg', '1', IntToStr(AmsCleanupOld(Dir)));
  Check('Baum loeschen', AmsDeleteTree(Dir) and not DirectoryExists(Dir));
end;

{ ------------------------------------------------------------------- ZIP -- }

procedure TestZip;
var
  Dir: string;
  L: TStringList;
  Z: TZipper;
  S: string;
begin
  Section('ZIP');
  Dir := gTmp + 'amsapi_zip\';
  AmsDeleteTree(Dir);
  AmsWriteFileRaw(Dir + 'src\plugin.ini', 'Name=X');
  AmsWriteFileRaw(Dir + 'src\sub\a.txt', 'A');
  Check('packen', AmsZipCreate(Dir + 'src', Dir + 'x.zip'));
  L := TStringList.Create;
  try
    Check('auflisten', AmsZipList(Dir + 'x.zip', L));
    CheckEq('Eintraege', 'plugin.ini,sub\a.txt', L.CommaText);
    L.Clear;
    Check('entpacken', AmsZipExtract(Dir + 'x.zip', Dir + 'out', L));
    Check('Inhalt da', AmsReadFileRaw(Dir + 'out\sub\a.txt', S) and (S = 'A'));
  finally
    L.Free;
  end;

  { Zip Slip: ein Eintrag zeigt aus dem Zielordner heraus }
  AmsWriteFileRaw(Dir + 'boese.txt', 'BOESE');
  Z := TZipper.Create;
  try
    Z.FileName := Dir + 'slip.zip';
    Z.Entries.AddFileEntry(Dir + 'boese.txt', 'harmlos.txt');
    Z.Entries.AddFileEntry(Dir + 'boese.txt', '../../boese-draussen.txt');
    Z.ZipAllFiles;
  finally
    Z.Free;
  end;
  Check('Zip Slip abgelehnt', not AmsZipExtract(Dir + 'slip.zip', Dir + 'slip\ziel'));
  Check('mit Begruendung', Pos('heraus', AmsLastError) > 0, AmsLastError);
  Check('nichts entpackt - auch nicht das Harmlose',
        not FileExists(Dir + 'slip\ziel\harmlos.txt'));
  Check('nichts draussen', not FileExists(Dir + 'boese-draussen.txt'));
  AmsDeleteTree(Dir);
end;

{ ----------------------------------------------------------- INI bearbeiten }

procedure TestIniDoc;
var
  Doc, Old: TAmsIniDoc;
  E: TAmsIniEntry;
  T: string;
  i: Integer;
begin
  Section('INI bearbeiten (Kommentare bleiben)');
  Doc := TAmsIniDoc.Create;
  Old := TAmsIniDoc.Create;
  try
    Doc.LoadFromText(
      'Name=X'#13#10 +
      'Version=1.0.0'#13#10 +
      #13#10 +
      '; ======================'#13#10 +
      ';  Abschnitt fuer Farben'#13#10 +
      '; ======================'#13#10 +
      '[Farben]'#13#10 +
      '; Hintergrund des Fensters'#13#10 +
      ';   als #RRGGBB'#13#10 +
      'Hinten = #FFFFFF'#13#10 +
      #13#10 +
      'Vorn=#000000'#13#10 +
      '[Leer]'#13#10);
    CheckEq('Eintraege', '4', IntToStr(Doc.Count));
    i := Doc.IndexOf('farben', 'HINTEN');
    Check('Suche case-insensitiv', i >= 0);
    E := Doc.Entry(i);
    CheckEq('Wert getrimmt', '#FFFFFF', E.Value);
    CheckEq('Beschreibung aus dem Kommentar',
            'Hintergrund des Fensters'#10'  als #RRGGBB', E.Comment);
    CheckEq('Leerzeile trennt die Beschreibung', '',
            Doc.Entry(Doc.IndexOf('Farben', 'Vorn')).Comment);
    CheckEq('Abschnittskommentar ohne Trennlinien', ' Abschnitt fuer Farben',
            Doc.SectionComment('Farben'));
    Check('Wert setzen', Doc.SetValue('Farben', 'Hinten', '#FFF4C2'));
    Check('gleicher Wert ist keine Aenderung',
          not Doc.SetValue('Farben', 'Hinten', '#FFF4C2'));
    T := Doc.Text;
    Check('Schreibweise "Hinten = " bleibt', Pos('Hinten = #FFF4C2', T) > 0);
    Check('Kommentare bleiben', Pos(';   als #RRGGBB', T) > 0);
    Doc.SetValue('Farben', 'Rahmen', '#CCCCCC');
    Check('neuer Schluessel im Abschnitt, nicht am Dateiende',
          Pos('Vorn=#000000'#13#10'Rahmen=#CCCCCC'#13#10'[Leer]', Doc.Text) > 0,
          Doc.Text);
    Doc.SetValue('Neu', 'A', '1');
    CheckEq('neuer Abschnitt', '1', Doc.GetValue('Neu', 'A'));
    Doc.SetValue('', 'Module', 'X.bpl');
    Check('Kopf-Schluessel vor dem ersten Abschnitt',
          Pos('Version=1.0.0'#13#10'Module=X.bpl', Doc.Text) > 0, Doc.Text);

    Doc.LoadFromText(#$EF#$BB#$BF'A=1'#10'B=2'#10);
    Doc.SetValue('', 'A', '3');
    CheckEq('BOM und LF bleiben', #$EF#$BB#$BF'A=3'#10'B=2'#10, Doc.Text);

    { Benutzerwerte in die neue Fassung uebernehmen }
    Doc.LoadFromText('Name=X'#13#10'Version=2.0.0'#13#10'[Info]'#13#10 +
                     'Title=Neu'#13#10'[Opt]'#13#10'; Farbe'#13#10 +
                     'Farbe=blau'#13#10'Neu=1'#13#10);
    Old.LoadFromText('Name=X'#13#10'Version=1.0.0'#13#10'[Info]'#13#10 +
                     'Title=Alt'#13#10'[Opt]'#13#10'Farbe=rot'#13#10 +
                     '[Patch]'#13#10'bb.Enabled=0'#13#10);
    CheckEq('zwei Werte uebernommen', '2',
            IntToStr(AmsIniMergeUserValues(Doc, Old, AMS_PACKAGE_OWNED)));
    CheckEq('Wert des Anwenders', 'rot', Doc.GetValue('Opt', 'Farbe'));
    CheckEq('neuer Schluessel bleibt', '1', Doc.GetValue('Opt', 'Neu'));
    CheckEq('Version vom Paket', '2.0.0', Doc.GetValue('', 'Version'));
    CheckEq('[Info] vom Paket', 'Neu', Doc.GetValue('Info', 'Title'));
    CheckEq('eigene Zeile uebernommen', '0', Doc.GetValue('Patch', 'bb.Enabled'));
    Check('Kommentar der neuen Fassung bleibt', Pos('; Farbe', Doc.Text) > 0);
    Check('Muster .Version', AmsIniKeyMatches('', 'Version', ['.Version']));
    Check('Muster .Version nicht im Abschnitt',
          not AmsIniKeyMatches('Opt', 'Version', ['.Version']));
    Check('Muster Info.*', AmsIniKeyMatches('info', 'Irgendwas', ['Info.*']));
  finally
    Old.Free;
    Doc.Free;
  end;
end;

{ ---------------------------------------------------- Katalog, Versionen -- }

procedure TestStore;
var
  L: TAmsPluginList;
  P: TAmsPluginInfo;
  O, R, Pa: string;
begin
  Section('Plugin-Katalog und Versionen');
  Check('1.2.10 > 1.2.9', AmsCompareVersions('1.2.10', '1.2.9') > 0);
  Check('v1.0 = 1.0.0', AmsCompareVersions('v1.0', '1.0.0') = 0);
  Check('Vorabversion kleiner', AmsCompareVersions('1.0.0-beta', '1.0.0') < 0);
  Check('beta.2 > beta.1', AmsCompareVersions('1.0.0-beta.2', '1.0.0-beta.1') > 0);
  Check('2 > 1.9.9', AmsCompareVersions('2', '1.9.9') > 0);
  Check('leer < 0.1', AmsCompareVersions('', '0.1') < 0);

  Check('github:o/r', AmsParseRepoSpec('github:aizpun-flowtech/amsapi', O, R, Pa) and
        (O = 'aizpun-flowtech') and (R = 'amsapi') and (Pa = ''));
  Check('URL mit .git', AmsParseRepoSpec('https://github.com/o/r.git', O, R, Pa) and
        (R = 'r'));
  Check('URL aus dem Browser mit Pfad',
        AmsParseRepoSpec('https://github.com/o/r/tree/main/samples/X', O, R, Pa) and
        (Pa = 'samples/X'), Pa);
  Check('anderes Schema abgelehnt', not AmsParseRepoSpec('gitlab:o/r', O, R, Pa));

  L := TAmsPluginList.Create;
  try
    CheckEq('Katalog: drei gueltige Eintraege', '3', IntToStr(AmsParseCatalog(
      '; Kopf'#13#10 +
      '[Hello]'#13#10'Repo=github:o/r'#13#10'Path=/samples/Hello/'#13#10 +
      '[Fest]'#13#10'Repo=github:o/r'#13#10'Tag=v1.2.0'#13#10 +
      'Sha256=ABCDEF'#13#10 +
      '[Server]'#13#10'Base=plugins/Server/'#13#10'Title=Vom Server'#13#10 +
      '[..]'#13#10'Base=x'#13#10 +
      '[OhneQuelle]'#13#10'Title=nix'#13#10,
      'https://intranet/ams/katalog.ini', L)));
    P := L.Find('Hello');
    Check('Hello gefunden', P <> nil);
    if P <> nil then
    begin
      CheckEq('Paket aus dem neuesten Release',
        'https://github.com/o/r/releases/latest/download/Hello.zip', P.PackageUrl);
      CheckEq('Metadaten aus dem Release',
        'https://github.com/o/r/releases/latest/download/Hello.ini', P.MetaUrl);
      CheckEq('README roh aus dem Repo',
        'https://raw.githubusercontent.com/o/r/HEAD/samples/Hello/README.md',
        P.ReadmeUrl);
      CheckEq('Links in die Repo-Ansicht',
        'https://github.com/o/r/blob/HEAD/samples/Hello/', P.LinkBase);
      Check('nicht installiert', P.State = psAvailable);
    end;
    P := L.Find('Fest');
    if P <> nil then
    begin
      CheckEq('feste Version',
        'https://github.com/o/r/releases/download/v1.2.0/Fest.zip', P.PackageUrl);
      CheckEq('Pruefsumme klein', 'abcdef', P.Sha256);
    end;
    P := L.Find('Server');
    if P <> nil then
    begin
      CheckEq('Base relativ zum Katalog',
        'https://intranet/ams/plugins/Server/Server.zip', P.PackageUrl);
      CheckEq('Titel aus dem Katalog', 'Vom Server', P.Title);
      AmsApplyMeta(P, 'Version=1.5.0'#13#10'[Info]'#13#10'Title=Server-Plugin'#13#10 +
                   'Description=Zeile 1\nZeile 2'#13#10'Icon=img/logo.png'#13#10, False);
      CheckEq('Version aus der plugin.ini', '1.5.0', P.AvailableVersion);
      CheckEq('Titel aus [Info] gewinnt', 'Server-Plugin', P.Title);
      CheckEq('\n wird Zeilenumbruch', 'Zeile 1'#10'Zeile 2', P.Description);
      CheckEq('Bild relativ zur Quelle',
        'https://intranet/ams/plugins/Server/img/logo.png', P.IconUrl);
      P.Installed := True;
      P.InstalledVersion := '1.4.0';
      Check('Update erkannt', P.State = psUpdate);
      P.InstalledVersion := '1.5.0';
      Check('aktuell', P.State = psInstalled);
    end;
    Check('ungueltiger Ordnername uebersprungen', L.Find('..') = nil);
  finally
    L.Free;
  end;

  L := TAmsPluginList.Create;
  try
    AmsParseCatalog('[Lokal]'#13#10'Base=Lokal\'#13#10,
                    'C:\Server\Katalog\katalog.ini', L);
    P := L.Find('Lokal');
    if P <> nil then
      CheckEq('Base relativ zu einem Katalog auf Platte',
              'C:\Server\Katalog\Lokal\Lokal.zip', P.PackageUrl)
    else
      Check('Base relativ zu einem Katalog auf Platte', False);
  finally
    L.Free;
  end;
end;

{ -------------------------------------------- Installieren / Entfernen --- }

procedure TestApply;
var
  Dir, Q, PDir, BDir: string;
  Op: TAmsApplyOp;
  Ops: TAmsApplyOps;
  Done: Boolean;
  S: string;
  Lock, Lock2: HMODULE;
  L: TStringList;
begin
  Section('Installieren und Entfernen (Warteschlange)');
  Dir := gTmp + 'amsapi_apply\';
  AmsDeleteTree(Dir);
  AmsForceDir(Dir + 'plugins');
  AmsWriteFileRaw(Dir + 'stage\P\plugin.ini', 'Name=P'#13#10'Module=P.bpl'#13#10);
  AmsWriteFileRaw(Dir + 'stage\P\P.bpl', 'V1');

  Op.Action := aaInstall;
  Op.Name := 'P';
  Op.Source := Dir + 'stage\P';
  Check('installieren', AmsApplyOp(Dir + 'plugins', Dir + 'backup', Op), Op.Message);
  Check('Datei da', AmsReadFileRaw(Dir + 'plugins\P\P.bpl', S) and (S = 'V1'));

  AmsWriteFileRaw(Dir + 'plugins\P\anwender.dat', 'MEINS');
  AmsWriteFileRaw(Dir + 'stage\P\P.bpl', 'V2');
  Check('aktualisieren', AmsApplyOp(Dir + 'plugins', Dir + 'backup', Op), Op.Message);
  Check('neue Fassung', AmsReadFileRaw(Dir + 'plugins\P\P.bpl', S) and (S = 'V2'));
  Check('Datei des Anwenders bleibt', FileExists(Dir + 'plugins\P\anwender.dat'));
  Check('Sicherung angelegt', DirectoryExists(Dir + 'backup'));

  AmsWriteFileRaw(Dir + 'neu.ini', 'Name=P'#13#10'Module=P.bpl'#13#10'X=1'#13#10);
  Op.Action := aaConfig;
  Op.Source := Dir + 'neu.ini';
  Check('Einstellungen schreiben', AmsApplyOp(Dir + 'plugins', Dir + 'backup', Op));
  CheckEq('plugin.ini ersetzt', '1', AmsIniValue(Dir + 'plugins\P\plugin.ini', 'X', ''));

  Op.Name := '..\..\Windows';
  Op.Action := aaInstall;
  Check('fremder Pfad abgelehnt', not AmsApplyOp(Dir + 'plugins', '', Op));
  Check('mit Begruendung', Pos('Ungueltiger', Op.Message) > 0, Op.Message);

  Op.Name := 'Fehlt';
  Op.Source := Dir + 'gibtsnicht';
  Check('fehlende Bereitstellung abgelehnt',
        not AmsApplyOp(Dir + 'plugins', '', Op));
  Check('nichts angelegt', not DirectoryExists(Dir + 'plugins\Fehlt'));

  Op.Action := aaRemove;
  Op.Name := 'P';
  Op.Source := '';
  Check('entfernen', AmsApplyOp(Dir + 'plugins', Dir + 'backup', Op));
  Check('Ordner weg', not DirectoryExists(Dir + 'plugins\P'));

  { Entfernen, waehrend die BPL geladen ist - im echten AMS liess die erste
    Fassung dabei einen Ordner ohne plugin.ini stehen, und AMS startete
    nicht mehr ("Plugin descriptor file not found"). }
  AmsWriteFileRaw(Dir + 'stage\Q\plugin.ini', 'Name=Q'#13#10'Module=Q.bpl'#13#10);
  CopyFileW(PWideChar(WideString(AmsExpandEnv('%SystemRoot%\SysWOW64\atl.dll'))),
            PWideChar(WideString(Dir + 'stage\Q\Q.bpl')), False);
  Op.Action := aaInstall;
  Op.Name := 'Q';
  Op.Source := Dir + 'stage\Q';
  Check('Q installiert', AmsApplyOp(Dir + 'plugins', Dir + 'backup', Op), Op.Message);
  Lock := LoadLibraryExW(PWideChar(WideString(Dir + 'plugins\Q\Q.bpl')), 0,
                         DONT_RESOLVE_DLL_REFERENCES);
  Check('Q.bpl geladen', Lock <> 0);
  Op.Action := aaRemove;
  Check('entfernen trotz geladener BPL', AmsApplyOp(Dir + 'plugins',
        Dir + 'backup', Op), Op.Message);
  Check('Ordner GANZ weg - kein Rest ohne plugin.ini',
        not DirectoryExists(Dir + 'plugins\Q'));
  { freigeben - sonst gaebe der Lader beim naechsten LoadLibraryEx am selben
    Pfad nur dieses Modul zurueck, statt die neue Datei zu mappen }
  if Lock <> 0 then FreeLibrary(Lock);
  Lock := 0;

  { Ohne Papierkorb (wie auf einem anderen Laufwerk) wird geloescht - die
    geladene BPL geht nicht, dann bleibt das Plugin gueltig stehen }
  Op.Action := aaInstall;
  Check('Q wieder installiert', AmsApplyOp(Dir + 'plugins', Dir + 'backup', Op),
        Op.Message);
  Lock2 := LoadLibraryExW(PWideChar(WideString(Dir + 'plugins\Q\Q.bpl')), 0,
                          DONT_RESOLVE_DLL_REFERENCES);
  Op.Action := aaRemove;
  Check('ohne Papierkorb abgelehnt', not AmsApplyOp(Dir + 'plugins', '', Op));
  Check('mit Begruendung', Pos('AMS beenden', Op.Message) > 0, Op.Message);
  Check('plugin.ini steht noch', FileExists(Dir + 'plugins\Q\plugin.ini'));
  if Lock2 <> 0 then FreeLibrary(Lock2);
  if Lock <> 0 then FreeLibrary(Lock);
  Check('jetzt geht es', AmsApplyOp(Dir + 'plugins', Dir + 'backup', Op) and
        not DirectoryExists(Dir + 'plugins\Q'), Op.Message);

  { Reste der ersten Fassung: Ordner nur mit .old - und einer, der nicht
    von uns ist }
  AmsWriteFileRaw(Dir + 'plugins\Kaputt\Kaputt.bpl.ABC.old', 'x');
  AmsWriteFileRaw(Dir + 'plugins\Fremd\irgendwas.txt', 'x');
  CheckEq('ein Rest repariert', '1',
          IntToStr(AmsRepairPluginsDir(Dir + 'plugins', Dir + 'backup')));
  Check('Rest weg', not DirectoryExists(Dir + 'plugins\Kaputt'));
  Check('Fremdes bleibt', FileExists(Dir + 'plugins\Fremd\irgendwas.txt'));
  AmsDeleteTree(Dir + 'plugins\Fremd');

  { als Warteschlange, wie fuer den Helfer }
  Q := Dir + 'q.ini';
  SetLength(Ops, 2);
  Ops[0].Action := aaInstall;
  Ops[0].Name := 'P';
  Ops[0].Source := Dir + 'stage\P';
  Ops[1].Action := aaRemove;
  Ops[1].Name := 'GibtsNicht';
  Ops[1].Source := '';
  Check('Warteschlange schreiben', AmsQueueWrite(Q, Dir + 'plugins', Dir + 'backup', Ops));
  Check('abarbeiten', AmsApplyQueueFile(Q), AmsLastError);
  L := TStringList.Create;
  try
    AmsListFiles(Dir + 'trash', L, True);
    CheckEq('Papierkorb geleert, sobald nichts mehr geladen ist', '0',
            IntToStr(L.Count));
  finally
    L.Free;
  end;
  Check('Ergebnisse gelesen', AmsQueueRead(Q, PDir, BDir, Ops, Done) and Done and
        Ops[0].Ok and Ops[1].Ok);
  Check('zweimal geht nicht', not AmsApplyQueueFile(Q));
  CheckEq('Helfer-Exitcode bei unlesbarer Datei', '2',
          IntToStr(AmsApplyHelperRun(Dir + 'gibtsnicht.ini')));
  AmsDeleteTree(Dir);
end;

{ ---------------------------------------------------------- Prozesse ----- }

procedure TestProcess;
var
  Code: DWORD;
begin
  Section('Prozesse und Rueckfragen');
  CheckEq('Argument ohne Leerzeichen', 'abc', AmsQuoteArg('abc'));
  CheckEq('mit Leerzeichen', '"a b"', AmsQuoteArg('a b'));
  CheckEq('Backslash am Ende', '"C:\x y\\"', AmsQuoteArg('C:\x y\'));
  CheckEq('Anfuehrungszeichen', '"say \"hi\""', AmsQuoteArg('say "hi"'));
  CheckEq('eigenes Programm', LowerCase(ExtractFileName(ParamStr(0))),
          LowerCase(ExtractFileName(AmsHostExe)));
  Check('Programm laufen lassen und warten',
        AmsRunAndWait(AmsExpandEnv('%SystemRoot%\System32\cmd.exe'), '/c exit 3',
                      False, False, Code, 10000), AmsLastError);
  CheckEq('Exitcode', '3', IntToStr(Code));
  Check('fehlendes Programm', not AmsRunAndWait(gTmp + 'gibtsnicht.exe', '',
        False, False, Code));
  CheckEq('Neustart-Helfer ohne Datei', '1',
          IntToStr(AmsRestartHelperRun(gTmp + 'gibtsnicht.ini')));

  AmsDialogsSilent := True;
  AmsDialogCount := 0;
  CheckEq('stille Frage liefert den Standard', '1',
          IntToStr(AmsTaskDialog(0, 'T', 'M', '', ['a', 'b'], 1)));
  AmsDialogsSilentAnswer := 0;
  CheckEq('stille Frage mit Vorgabe', '0',
          IntToStr(AmsTaskDialog(0, 'T', 'M', '', ['a', 'b'], 1)));
  AmsDialogsSilentAnswer := -2;
  CheckEq('Fragen gezaehlt', '2', IntToStr(AmsDialogCount));
  AmsDialogsSilent := False;
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
  TestMarkdown;
  TestFiles;
  TestZip;
  TestIniDoc;
  TestStore;
  TestApply;
  TestProcess;

  WriteLn;
  WriteLn(Format('%d Pruefungen, %d Fehlschlaege.', [gRun, gFail]));
  if gFail = 0 then WriteLn('ALLES GRUEN.') else WriteLn('FEHLGESCHLAGEN.');
  Halt(gFail);
end.
