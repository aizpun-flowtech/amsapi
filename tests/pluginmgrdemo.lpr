program pluginmgrdemo;

{ ============================================================================
  Rauchtest des Plugin Managers - OHNE AMS und OHNE Netz.

  Aufgebaut wird alles in %TEMP%\amsapi_pmdemo\:
    repo\      ein "Server" mit Katalog und drei Plugins (Alpha, Beta, Gamma)
               als ZIP, plugin.ini, README.md und Bild - Base=-Quellen
    plugins\   der Ersatz fuer BIN\plugins: Beta 1.0.0 (mit eigenen
               Einstellungen des Anwenders) und Alt (in keinem Katalog)
    cache\     Zwischenspeicher, Bereitstellung, Sicherungen

  Dann wird das Fenster ausserhalb des Bildes geoeffnet und ueber
  Nachrichten bedient wie von einem Anwender:
    - Liste: vier Plugins mit richtigem Zustand und Versionstext
    - Auswahl: Beschreibungsseite mit README, Tabelle, eingebettetem Bild
    - Alpha installieren, Beta aktualisieren - WAEHREND Beta.bpl geladen
      ist (wie im laufenden AMS) - und dabei die Werte des Anwenders
      behalten, Gamma mit falscher Pruefsumme ablehnen, Alt entfernen
      (mit Sicherung), plugin.ini im Einstellungsfenster aendern
    - Suche und Filter, Neu laden, Schliessen ohne Reste
  Zum Schluss das Hilfsprogramm AmsPluginApply.exe als eigener Prozess:
  Manifest vorhanden, --apply arbeitet eine Warteschlange ab, --restart
  wartet auf einen Prozess und startet danach ein Programm.

  Rueckgabewert 0 = alles gruen, sonst Anzahl der Fehlschlaege.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{$codepage utf8}

uses
  Windows, SysUtils, Classes, FPImage, FPWritePNG,
  AmsApi.Log, AmsApi.Files, AmsApi.Zip, AmsApi.IniDoc, AmsApi.Process,
  AmsApi.Dialogs, AmsApi.Browser, AmsApi.WinCtl, AmsApi.PluginStore,
  AmsApi.PluginApply, AmsApi.IniEditor, AmsApi.PluginManager;

var
  gRun: Integer = 0;
  gFail: Integer = 0;
  T: string;

procedure Check(const AName: string; ACondition: Boolean;
  const AGot: string = '');
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

{ --------------------------------------------------------------- Werkzeug - }

procedure Pump(AMs: Integer);
var
  M: TMsg;
  Start: QWord;
begin
  Start := GetTickCount64;
  repeat
    while PeekMessageW(M, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(M);
      DispatchMessageW(M);
    end;
    Sleep(10);
  until GetTickCount64 - Start >= QWord(AMs);
end;

{ Nachrichten verteilen, bis der Manager nichts mehr zu tun hat }
function WaitIdle(ATimeoutMs: Integer = 20000): Boolean;
var
  Start: QWord;
begin
  Start := GetTickCount64;
  repeat
    Pump(30);
    if not AmsPluginManagerBusy then
    begin
      Pump(60);
      if not AmsPluginManagerBusy then Exit(True);
    end;
  until GetTickCount64 - Start > QWord(ATimeoutMs);
  Result := False;
end;

procedure Cmd(AId: Integer);
begin
  SendMessageW(AmsPluginManagerHandle, WM_COMMAND, AId, 0);
end;

function Put(const AFile, AText: string): Boolean;
begin
  Result := AmsWriteFileRaw(AFile, AText);
end;

function Get(const AFile: string): string;
begin
  if not AmsReadFileRaw(AFile, Result) then Result := '';
end;

procedure MakePng(const AFile: string; R, G, B: Word);
var
  Img: TFPMemoryImage;
  Wr: TFPWriterPNG;
  X, Y: Integer;
  C: TFPColor;
begin
  Img := TFPMemoryImage.Create(32, 32);
  Wr := TFPWriterPNG.Create;
  try
    Wr.UseAlpha := True;
    C.Red := R; C.Green := G; C.Blue := B; C.Alpha := $FFFF;
    for Y := 0 to 31 do
      for X := 0 to 31 do
        Img.Colors[X, Y] := C;
    ForceDirectories(ExtractFilePath(AFile));
    Img.SaveToFile(AFile, Wr);
  finally
    Wr.Free;
    Img.Free;
  end;
end;

function Ini(const AName, AVersion, ATitle, AExtra: string): string;
begin
  Result :=
    '; Kopf' + #13#10 +
    'Name=' + AName + #13#10 +
    'Module=' + AName + '.bpl' + #13#10 +
    'Version=' + AVersion + #13#10 +
    'LargeGlyph=./icon32.png' + #13#10 +
    #13#10 +
    '[Info]' + #13#10 +
    'Title=' + ATitle + #13#10 +
    'Description=Beschreibung von ' + ATitle + #13#10 +
    'Author=Testautor' + #13#10 +
    'License=MIT' + #13#10 +
    AExtra;
end;

{ Paketordner + ZIP + Metadaten auf dem "Server" }
procedure Publish(const AName, AVersion, ATitle, AExtra, ABplContent: string);
var
  Pkg, Srv: string;
begin
  Pkg := T + 'build\' + AName + '\';
  Srv := T + 'repo\' + AName + '\';
  AmsDeleteTree(Pkg);
  Put(Pkg + 'plugin.ini', Ini(AName, AVersion, ATitle, AExtra));
  Put(Pkg + AName + '.bpl', ABplContent);
  MakePng(Pkg + 'icon32.png', $2000, $8000, $F000);
  Put(Pkg + 'README.md', '# ' + ATitle + #10#10 + 'Paketfassung.' + #10);
  AmsZipCreate(Pkg, Srv + AName + '.zip');
  Put(Srv + 'plugin.ini', Ini(AName, AVersion, ATitle, AExtra));
  CopyFileW(PWideChar(WideString(Pkg + 'icon32.png')),
            PWideChar(WideString(Srv + 'icon32.png')), False);
end;

function RowOf(const ATitle: WideString): Integer;
var
  i: Integer;
begin
  for i := 0 to AmsPluginManagerCount - 1 do
    if AmsPluginManagerItemText(i, 0) = ATitle then Exit(i);
  Result := -1;
end;

function FindOld(const ADir: string): Boolean;
var
  L: TStringList;
  i: Integer;
begin
  Result := False;
  L := TStringList.Create;
  try
    AmsListFiles(ADir, L, True);
    for i := 0 to L.Count - 1 do
      if SameText(ExtractFileExt(L[i]), '.old') then Exit(True);
  finally
    L.Free;
  end;
end;

{ ---------------------------------------------------------------- Aufbau - }

var
  BetaHash, Page, S: string;
  Opt: TAmsPluginManagerOptions;
  Lock: HMODULE;
  R: Integer;
  Ed: TAmsIniEditor;
  Doc: TAmsIniDoc;
  WC: TWndClassExW;

procedure Setup;
var
  BetaUser: string;
begin
  Section('Aufbau in ' + T);
  AmsDeleteTree(T);
  { Alpha 2.0.0 - nicht installiert, README mit Bild und Tabelle }
  Publish('Alpha', '2.0.0', 'Alpha-Plugin',
          '[Einstellungen]' + #13#10 + '; Ein Wert zum Aendern' + #13#10 +
          'Wert=1' + #13#10, 'ALPHA-BPL');
  Put(T + 'repo\Alpha\README.md',
      '# Alpha' + #10#10 + 'Ein **fettes** Plugin mit Bild:' + #10#10 +
      '![Bild](bild.png)' + #10#10 +
      '| Spalte | Wert |' + #10 + '|---|--:|' + #10 + '| a | 1 |' + #10#10 +
      '<script>alert(1)</script>' + #10);
  MakePng(T + 'repo\Alpha\bild.png', $F000, $2000, $2000);

  { Beta 1.1.0 auf dem Server, 1.0.0 installiert }
  Publish('Beta', '1.1.0', 'Beta-Plugin',
          '[Einstellungen]' + #13#10 + 'Farbe=blau' + #13#10 + 'Neu=1' + #13#10,
          'BETA-NEU');
  AmsSha256File(T + 'repo\Beta\Beta.zip', BetaHash);

  { Gamma - Pruefsumme im Katalog stimmt absichtlich nicht }
  Publish('Gamma', '0.9.0', 'Gamma-Plugin', '', 'GAMMA');

  Put(T + 'repo\katalog.ini',
      '; Testkatalog' + #13#10 +
      '[Alpha]' + #13#10 + 'Base=Alpha\' + #13#10 +
      '[Beta]' + #13#10 + 'Base=Beta\' + #13#10 + 'Sha256=' + BetaHash + #13#10 +
      '[Gamma]' + #13#10 + 'Base=Gamma\' + #13#10 +
      'Sha256=' + StringOfChar('0', 64) + #13#10);

  { installiert: Beta 1.0.0 mit Einstellungen des Anwenders }
  BetaUser := Ini('Beta', '1.0.0', 'Beta-Plugin (alt)',
    '[Einstellungen]' + #13#10 + 'Farbe=rot' + #13#10 + #13#10 +
    '[Patch]' + #13#10 + 'bbLoeschen.Enabled=0' + #13#10);
  Put(T + 'plugins\Beta\plugin.ini', BetaUser);
  { Beta.bpl ist eine echte DLL - sie wird gleich geladen wie von AMS }
  CopyFileW(PWideChar(WideString(AmsExpandEnv('%SystemRoot%\SysWOW64\atl.dll'))),
            PWideChar(WideString(T + 'plugins\Beta\Beta.bpl')), False);
  Put(T + 'plugins\Beta\Daten-vom-Anwender.wad', 'NICHT ANFASSEN');

  { installiert, in keinem Katalog }
  Put(T + 'plugins\Alt\plugin.ini', Ini('Alt', '0.1.0', 'Altes Plugin', ''));
  Put(T + 'plugins\Alt\Alt.bpl', 'ALT');

  Put(T + 'pm.ini',
      '[Katalog]' + #13#10 +
      'Quelle1=' + T + 'repo\katalog.ini' + #13#10 +
      'PluginsDir=' + T + 'plugins' + #13#10 +
      'CacheDir=' + T + 'cache' + #13#10);
  Check('Server und Plugin-Ordner angelegt',
        FileExists(T + 'repo\Alpha\Alpha.zip') and
        FileExists(T + 'plugins\Beta\Beta.bpl'));
end;

{ ------------------------------------------------------------------- Lauf - }

procedure TestList;
begin
  Section('Oeffnen und Liste');
  Opt := AmsPluginManagerOptionsFromIni(T + 'pm.ini');
  Opt.HelperExe := '';            { Ordner ist beschreibbar - im Prozess }
  Opt.HostWindow := 0;            { kein Neustart, nur zaehlen }
  Opt.Offscreen := True;
  Opt.SelfName := 'PluginManager';
  CheckEq('Katalogquelle aus der INI', T + 'repo\katalog.ini', Opt.Store.Catalogs);
  Check('Fenster offen', AmsPluginManagerOpen(0, Opt) and
        IsWindow(AmsPluginManagerHandle), AmsLastError);
  Check('Kataloge geladen', WaitIdle);
  CheckEq('vier Plugins', '4', IntToStr(AmsPluginManagerCount));
  R := RowOf('Alpha-Plugin');
  Check('Alpha in der Liste', R >= 0);
  if R >= 0 then
  begin
    CheckEq('Alpha: Version', '2.0.0', string(AmsPluginManagerItemText(R, 1)));
    CheckEq('Alpha: Zustand', 'Nicht installiert',
            AmsWideToUtf8(AmsPluginManagerItemText(R, 2)));
  end;
  R := RowOf('Beta-Plugin');
  Check('Beta in der Liste (Titel aus dem Katalog)', R >= 0);
  if R >= 0 then
  begin
    CheckEq('Beta: Versionen', AmsWideToUtf8('1.0.0 → 1.1.0'),
            AmsWideToUtf8(AmsPluginManagerItemText(R, 1)));
    CheckEq('Beta: Zustand', AmsWideToUtf8('Update verfügbar'),
            AmsWideToUtf8(AmsPluginManagerItemText(R, 2)));
  end;
  R := RowOf('Altes Plugin');
  Check('Alt: lokal', (R >= 0) and (AmsPluginManagerItemText(R, 2) = 'Lokal'));
  Check('Statuszeile zaehlt Updates',
        Pos('1 Updates', string(AmsPluginManagerStatus)) > 0,
        AmsWideToUtf8(AmsPluginManagerStatus));
end;

procedure TestPage;
var
  Start: QWord;
begin
  Section('Beschreibung');
  Check('Alpha waehlen', AmsPluginManagerSelect('Alpha'));
  WaitIdle;
  CheckEq('ausgewaehlt', 'Alpha', AmsPluginManagerSelected);
  Check('Seite mit README', AmsPluginManagerPageHasReadme);
  Page := Get(AmsPluginManagerPage);
  Check('Kopfkarte mit Titel', Pos('Alpha-Plugin', Page) > 0);
  Check('Autor und Lizenz', (Pos('Testautor', Page) > 0) and (Pos('MIT', Page) > 0));
  Check('README gerendert (fett)', Pos('<strong>fettes</strong>', Page) > 0);
  Check('Tabelle', Pos('<table', Page) > 0);
  Check('Bild als data:-URI eingebettet', Pos('data:image/png;base64,', Page) > 0);
  Check('<script> entfernt', Pos('alert(1)', Page) = 0);
  Check('Mark of the Web', Pos('saved from url=', Page) > 0);
  if AmsBrowserAvailable then
  begin
    Start := GetTickCount64;
    while (AmsPluginManagerReadyState <> 4) and (GetTickCount64 - Start < 10000) do
      Pump(50);
    CheckEq('Browser hat die Seite geladen', '4',
            IntToStr(AmsPluginManagerReadyState));
  end
  else
    WriteLn('  --    Browser auf diesem Rechner nicht verfuegbar, Ersatzfeld');
end;

procedure TestInstall;
var
  Before: Integer;
begin
  Section('Installieren');
  Before := AmsPluginManagerRestartOffers;
  AmsPluginManagerSelect('Alpha');
  WaitIdle;
  Cmd(IDC_PM_INSTALL);
  Check('fertig', WaitIdle);
  Check('Alpha\plugin.ini', FileExists(T + 'plugins\Alpha\plugin.ini'));
  CheckEq('Alpha.bpl aus dem Paket', 'ALPHA-BPL', Get(T + 'plugins\Alpha\Alpha.bpl'));
  Check('README mitinstalliert', FileExists(T + 'plugins\Alpha\README.md'));
  Check('Neustart angeboten', AmsPluginManagerRestartOffers = Before + 1);
  R := RowOf('Alpha-Plugin');
  Check('Zustand: Neustart noetig', (R >= 0) and
        (AmsWideToUtf8(AmsPluginManagerItemText(R, 2)) =
         AmsWideToUtf8('Neustart nötig')));
  Check('Bereitstellung aufgeraeumt', not DirectoryExists(T + 'cache\stage\Alpha'));
end;

procedure TestUpdateLocked;
begin
  Section('Aktualisieren, waehrend die BPL geladen ist');
  { genau wie AMS: als Image gemappt, also weder loesch- noch ueberschreibbar }
  Lock := LoadLibraryExW(PWideChar(WideString(T + 'plugins\Beta\Beta.bpl')), 0,
                         DONT_RESOLVE_DLL_REFERENCES);
  Check('Beta.bpl geladen', Lock <> 0);
  Check('und damit gesperrt', not DeleteFileW(PWideChar(WideString(
        T + 'plugins\Beta\Beta.bpl'))));
  AmsPluginManagerSelect('Beta');
  WaitIdle;
  Cmd(IDC_PM_INSTALL);
  Check('fertig', WaitIdle);
  Doc := TAmsIniDoc.Create;
  try
    Doc.LoadFromFile(T + 'plugins\Beta\plugin.ini');
    CheckEq('neue Version', '1.1.0', Doc.GetValue('', 'Version'));
    CheckEq('Wert des Anwenders behalten', 'rot', Doc.GetValue('Einstellungen', 'Farbe'));
    CheckEq('neuer Schluessel da', '1', Doc.GetValue('Einstellungen', 'Neu'));
    CheckEq('eigene [Patch]-Zeile behalten', '0',
            Doc.GetValue('Patch', 'bbLoeschen.Enabled'));
    CheckEq('[Info] aus dem Paket', 'Beta-Plugin', Doc.GetValue('Info', 'Title'));
  finally
    Doc.Free;
  end;
  CheckEq('neue Beta.bpl an ihrem Platz', 'BETA-NEU', Get(T + 'plugins\Beta\Beta.bpl'));
  Check('alte beiseite geschoben (.old)', FindOld(T + 'plugins\Beta'));
  CheckEq('Datei des Anwenders unberuehrt', 'NICHT ANFASSEN',
          Get(T + 'plugins\Beta\Daten-vom-Anwender.wad'));
  Check('Sicherung angelegt', DirectoryExists(T + 'cache\backup'));
  if Lock <> 0 then FreeLibrary(Lock);
  Check('.old nach dem Freigeben wegraeumbar', AmsCleanupOld(T + 'plugins\Beta') >= 1);
end;

procedure TestBadHash;
begin
  Section('Falsche Pruefsumme');
  AmsPluginManagerSelect('Gamma');
  WaitIdle;
  Cmd(IDC_PM_INSTALL);
  WaitIdle;
  Check('Gamma NICHT installiert', not DirectoryExists(T + 'plugins\Gamma'));
  Check('Statuszeile sagt es', Pos('fehlgeschlagen',
        string(AmsPluginManagerStatus)) > 0, AmsWideToUtf8(AmsPluginManagerStatus));
end;

procedure TestRemove;
var
  L: TStringList;
  i: Integer;
  Saved: Boolean;
begin
  Section('Entfernen');
  AmsPluginManagerSelect('Alt');
  WaitIdle;
  AmsDialogsSilentAnswer := 1;      { "Abbrechen" }
  Cmd(IDC_PM_REMOVE);
  WaitIdle;
  Check('Abbrechen laesst es stehen', DirectoryExists(T + 'plugins\Alt'));
  { Wie im echten AMS gesehen: waehrend die Rueckfrage offen steht, kommt der
    Katalogabruf zurueck und ersetzt die Liste. Der Name darf dabei nicht
    verloren gehen (frueher: "Ungueltiger Pluginname: """). }
  Cmd(IDC_PM_REFRESH);
  AmsDialogsSilentPumpMs := 1500;   { "Anwender liest" - Nachrichten laufen }
  AmsDialogsSilentAnswer := 0;      { "Entfernen" }
  Cmd(IDC_PM_REMOVE);
  WaitIdle;
  AmsDialogsSilentAnswer := -2;
  AmsDialogsSilentPumpMs := 0;
  Check('Katalog kam waehrend der Rueckfrage zurueck', not AmsPluginManagerBusy);
  Check('kein leerer Name beim Entfernen',
        Pos('Ungueltiger', string(AmsPluginManagerStatus)) = 0,
        AmsWideToUtf8(AmsPluginManagerStatus));
  Check('Alt entfernt', not DirectoryExists(T + 'plugins\Alt'));
  Saved := False;
  L := TStringList.Create;
  try
    AmsListFiles(T + 'cache\backup', L, True);
    for i := 0 to L.Count - 1 do
      if (Pos('Alt-', L[i]) = 1) and (ExtractFileName(L[i]) = 'Alt.bpl') then
        Saved := True;
  finally
    L.Free;
  end;
  Check('vorher gesichert', Saved);
  CheckEq('drei Plugins uebrig', '3', IntToStr(AmsPluginManagerCount));
end;

procedure TestSettings;
var
  Lv: HWND;
  i, Idx, Before: Integer;
  Txt: string;
begin
  Section('Einstellungen');
  Before := AmsPluginManagerRestartOffers;
  AmsPluginManagerSelect('Alpha');
  WaitIdle;
  Cmd(IDC_PM_SETTINGS);
  Pump(100);
  Ed := AmsIniEditorFind(T + 'plugins\Alpha\plugin.ini');
  Check('Editor offen', (Ed <> nil) and IsWindow(Ed.Handle));
  if Ed = nil then Exit;
  SetWindowPos(Ed.Handle, 0, -32000, -32000, 0, 0, SWP_NOSIZE or SWP_NOZORDER or
               SWP_NOACTIVATE);
  Idx := Ed.Doc.IndexOf('Einstellungen', 'Wert');
  Check('Schluessel gefunden', Idx >= 0);
  Lv := GetDlgItem(Ed.Handle, IDC_IE_LIST);
  CheckEq('alle Eintraege in der Liste', IntToStr(Ed.Doc.Count),
          IntToStr(AmsListViewCount(Lv)));
  { Was das Paket bestimmt, ist gesperrt }
  AmsListViewSelect(Lv, Ed.Doc.IndexOf('', 'Module'));
  Pump(50);
  Check('Module= gesperrt', not IsWindowEnabled(GetDlgItem(Ed.Handle, IDC_IE_VALUE)));
  Check('mit Begruendung', Pos('Plugin-Paket', AmsWideToUtf8(AmsGetWndText(
        GetDlgItem(Ed.Handle, IDC_IE_DESC)))) > 0);
  AmsListViewSelect(Lv, Idx);
  Pump(50);
  Txt := AmsWideToUtf8(AmsGetWndText(GetDlgItem(Ed.Handle, IDC_IE_DESC)));
  Check('Beschreibung aus dem Kommentar', Pos('Ein Wert zum Aendern', Txt) > 0, Txt);
  CheckEq('Wertfeld zeigt den Wert', '1',
          string(AmsGetWndText(GetDlgItem(Ed.Handle, IDC_IE_VALUE))));
  AmsSetWndText(GetDlgItem(Ed.Handle, IDC_IE_VALUE), '42');
  SendMessageW(Ed.Handle, WM_COMMAND, IDC_IE_SAVE, 0);
  Pump(100);
  Doc := TAmsIniDoc.Create;
  try
    Doc.LoadFromFile(T + 'plugins\Alpha\plugin.ini');
    CheckEq('gespeichert', '42', Doc.GetValue('Einstellungen', 'Wert'));
  finally
    Doc.Free;
  end;
  Check('Kommentar steht noch drin',
        Pos('; Ein Wert zum Aendern', Get(T + 'plugins\Alpha\plugin.ini')) > 0);
  Check('nicht mehr geaendert', not Ed.Dirty);
  Check('Neustart angeboten', AmsPluginManagerRestartOffers = Before + 1);

  SendMessageW(Ed.Handle, WM_COMMAND, IDC_IE_TOGGLE, 0);
  Txt := AmsWideToUtf8(AmsGetWndText(GetDlgItem(Ed.Handle, IDC_IE_TEXT)));
  Check('Textmodus zeigt die Datei', Pos('Wert=42', Txt) > 0);
  SendMessageW(Ed.Handle, WM_COMMAND, IDC_IE_TOGGLE, 0);
  CheckEq('zurueck zur Liste, nichts verloren', IntToStr(Ed.Doc.Count),
          IntToStr(AmsListViewCount(Lv)));
  AmsIniEditorCloseAll;
  CheckEq('Editor zu', '0', IntToStr(AmsIniEditorCount));
  { keine Fensterklasse uebrig }
  FillChar(WC, SizeOf(WC), 0);
  WC.cbSize := SizeOf(WC);
  Check('Editorklasse abgemeldet',
        not GetClassInfoExW(HInstance, 'AmsApiIniEditor', @WC));

end;

procedure TestFilter;
var
  E: HWND;
begin
  Section('Suche, Filter, Neu laden');
  E := GetDlgItem(AmsPluginManagerHandle, IDC_PM_SEARCH);
  AmsSetWndText(E, 'beta');
  Pump(50);
  CheckEq('Suche "beta"', '1', IntToStr(AmsPluginManagerCount));
  AmsSetWndText(E, 'Testautor');
  Pump(50);
  CheckEq('Suche nach Autor', '3', IntToStr(AmsPluginManagerCount));
  AmsSetWndText(E, '');
  SendMessageW(GetDlgItem(AmsPluginManagerHandle, IDC_PM_FILTER), CB_SETCURSEL, 1, 0);
  SendMessageW(AmsPluginManagerHandle, WM_COMMAND,
               MakeLong(IDC_PM_FILTER, CBN_SELCHANGE),
               LPARAM(GetDlgItem(AmsPluginManagerHandle, IDC_PM_FILTER)));
  CheckEq('Filter Installiert', '2', IntToStr(AmsPluginManagerCount));
  SendMessageW(GetDlgItem(AmsPluginManagerHandle, IDC_PM_FILTER), CB_SETCURSEL, 2, 0);
  SendMessageW(AmsPluginManagerHandle, WM_COMMAND,
               MakeLong(IDC_PM_FILTER, CBN_SELCHANGE),
               LPARAM(GetDlgItem(AmsPluginManagerHandle, IDC_PM_FILTER)));
  CheckEq('Filter Updates - Beta ist aktuell', '0', IntToStr(AmsPluginManagerCount));
  SendMessageW(GetDlgItem(AmsPluginManagerHandle, IDC_PM_FILTER), CB_SETCURSEL, 0, 0);
  SendMessageW(AmsPluginManagerHandle, WM_COMMAND,
               MakeLong(IDC_PM_FILTER, CBN_SELCHANGE),
               LPARAM(GetDlgItem(AmsPluginManagerHandle, IDC_PM_FILTER)));
  Cmd(IDC_PM_REFRESH);
  Check('Neu laden fertig', WaitIdle);
  CheckEq('weiter drei Plugins', '3', IntToStr(AmsPluginManagerCount));
end;

{ Wie im echten AMS: Entfernen, waehrend die Plugin-DLL geladen ist. Die
  erste Fassung liess einen Ordner ohne plugin.ini stehen - und AMS startete
  danach nicht mehr ("Plugin descriptor file not found"). }
procedure TestRemoveLocked;
var
  Lk: HMODULE;
begin
  Section('Entfernen, waehrend die BPL geladen ist');
  CopyFileW(PWideChar(WideString(AmsExpandEnv('%SystemRoot%\SysWOW64\atl.dll'))),
            PWideChar(WideString(T + 'plugins\Alpha\Hilfe.dll')), False);
  Lk := LoadLibraryExW(PWideChar(WideString(T + 'plugins\Alpha\Hilfe.dll')), 0,
                       DONT_RESOLVE_DLL_REFERENCES);
  Check('DLL des Plugins geladen', Lk <> 0);
  { Rest, wie ihn die erste Fassung hinterliess - wird mit repariert }
  Put(T + 'plugins\Rest\Rest.bpl.E3155C0.old', 'ALT');
  AmsPluginManagerSelect('Alpha');
  WaitIdle;
  AmsDialogsSilentAnswer := 0;
  Cmd(IDC_PM_REMOVE);
  WaitIdle;
  AmsDialogsSilentAnswer := -2;
  Check('Alpha-Ordner ganz weg', not DirectoryExists(T + 'plugins\Alpha'),
        AmsWideToUtf8(AmsPluginManagerStatus));
  Check('Rest der ersten Fassung repariert', not DirectoryExists(T + 'plugins\Rest'));
  Check('kein Ordner ohne plugin.ini mehr', not DirectoryExists(T + 'plugins\Alpha') and
        not DirectoryExists(T + 'plugins\Rest'));
  if Lk <> 0 then FreeLibrary(Lk);
end;

procedure TestClose;
begin
  Section('Schliessen');
  AmsPluginManagerClose;
  Check('Fenster weg', AmsPluginManagerHandle = 0);
  FillChar(WC, SizeOf(WC), 0);
  WC.cbSize := SizeOf(WC);
  Check('Fensterklasse abgemeldet',
        not GetClassInfoExW(HInstance, 'AmsApiPluginManager', @WC));
  Check('nichts laeuft mehr', not AmsPluginManagerBusy);
end;

{ ----------------------------------------------------------- Hilfsprogramm }

procedure TestHelper;
var
  Exe, Q, RIni, Mark: string;
  Ops: TAmsApplyOps;
  Dir, Bak: string;
  Done: Boolean;
  Code: DWORD;
  Mod_: HMODULE;
  SI: TStartupInfoW;
  PI: TProcessInformation;
  CmdW: WideString;
  Start: QWord;
  L: TStringList;
begin
  Section('Hilfsprogramm AmsPluginApply.exe');
  Exe := ExtractFilePath(ParamStr(0)) + 'AmsPluginApply.exe';
  if not FileExists(Exe) then
  begin
    Check('AmsPluginApply.exe neben dem Test', False, Exe);
    Exit;
  end;
  { Manifest drin? Ohne waere es virtualisiert - siehe AmsApi.Files }
  Mod_ := LoadLibraryExW(PWideChar(WideString(Exe)), 0, LOAD_LIBRARY_AS_DATAFILE);
  Check('Manifest eingebettet', (Mod_ <> 0) and
        (FindResourceW(Mod_, MAKEINTRESOURCEW(1), MAKEINTRESOURCEW(24)) <> 0));
  if Mod_ <> 0 then FreeLibrary(Mod_);

  { --apply }
  Put(T + 'helper\stage\Delta\plugin.ini', Ini('Delta', '1.0.0', 'Delta', ''));
  Put(T + 'helper\stage\Delta\Delta.bpl', 'DELTA');
  AmsForceDir(T + 'helper\plugins');
  SetLength(Ops, 1);
  Ops[0].Action := aaInstall;
  Ops[0].Name := 'Delta';
  Ops[0].Source := T + 'helper\stage\Delta';
  Q := T + 'helper\queue.ini';
  Check('Warteschlange geschrieben', AmsQueueWrite(Q, T + 'helper\plugins',
        T + 'helper\backup', Ops));
  Check('--apply lief', AmsRunAndWait(Exe, '--apply ' + AmsQuoteArg(Q), False,
        False, Code, 20000), AmsLastError);
  CheckEq('Exitcode 0', '0', IntToStr(Code));
  CheckEq('installiert', 'DELTA', Get(T + 'helper\plugins\Delta\Delta.bpl'));
  Check('Ergebnis in der Warteschlange', AmsQueueRead(Q, Dir, Bak, Ops, Done) and
        Done and (Length(Ops) = 1) and Ops[0].Ok);

  { --restart: wartet auf einen Prozess, startet dann ein Programm }
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  CmdW := WideString('"' + AmsExpandEnv('%SystemRoot%\System32\ping.exe') +
                     '" -n 2 127.0.0.1');
  if not CreateProcessW(nil, PWideChar(CmdW), nil, nil, False, CREATE_NO_WINDOW,
                        nil, nil, SI, PI) then
  begin
    Check('Wartepartner gestartet', False);
    Exit;
  end;
  CloseHandle(PI.hThread);
  Mark := T + 'helper\neu-gestartet.txt';
  RIni := T + 'helper\restart.ini';
  L := TStringList.Create;
  try
    L.Add('[Restart]');
    L.Add('Pid=' + IntToStr(PI.dwProcessId));
    L.Add('Exe=' + AmsExpandEnv('%SystemRoot%\System32\cmd.exe'));
    L.Add('Args=/c echo ok>"' + Mark + '"');
    L.Add('Dir=' + T + 'helper');
    L.Add('Timeout=20');
    L.SaveToFile(RIni);
  finally
    L.Free;
  end;
  Start := GetTickCount64;
  Check('--restart lief', AmsRunAndWait(Exe, '--restart ' + AmsQuoteArg(RIni),
        False, False, Code, 30000), AmsLastError);
  CheckEq('Exitcode 0', '0', IntToStr(Code));
  Check('hat auf den Prozess gewartet',
        WaitForSingleObject(PI.hProcess, 0) = WAIT_OBJECT_0);
  CloseHandle(PI.hProcess);
  while not FileExists(Mark) and (GetTickCount64 - Start < 10000) do Sleep(50);
  Check('danach neu gestartet', FileExists(Mark));
  Check('Parameterdatei aufgeraeumt', not FileExists(RIni));
end;

begin
  T := IncludeTrailingPathDelimiter(GetTempDir) + 'amsapi_pmdemo\';
  AmsSetLogFile(IncludeTrailingPathDelimiter(GetTempDir) + 'amsapi_pmdemo.log');
  AmsDisableVirtualization;
  AmsDialogsSilent := True;
  WriteLn('Plugin Manager - Rauchtest ohne AMS');
  WriteLn('===================================');
  Setup;
  TestList;
  TestPage;
  TestInstall;
  TestUpdateLocked;
  TestBadHash;
  TestRemove;
  TestSettings;
  TestFilter;
  TestRemoveLocked;
  TestClose;
  TestHelper;
  WriteLn;
  WriteLn(Format('%d Pruefungen, %d Fehlschlaege.', [gRun, gFail]));
  if gFail = 0 then
  begin
    WriteLn('ALLES GRUEN.');
    AmsDeleteTree(T);
  end
  else
    WriteLn('FEHLGESCHLAGEN. Stand liegt in ', T);
  Halt(gFail);
end.
