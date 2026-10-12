unit AmsApi.PluginApply;

{ ============================================================================
  AmsApi.PluginApply - Plugins in BIN\plugins installieren, ersetzen, entfernen

  Der Schritt, fuer den es meist Administratorrechte braucht. Deshalb steht
  er allein: eine Warteschlange (INI-Datei) beschreibt, was zu tun ist, und
  AmsApplyQueueFile arbeitet sie ab - im Plugin selbst, wenn der Ordner
  beschreibbar ist, sonst in einem Hilfsprogramm, das per UAC gestartet wird
  (AmsApplyWithRights). Beide Wege fuehren durch denselben Code.

      [Apply]
      PluginsDir=C:\Program Files (x86)\assfinet ams.5\BIN\plugins
      BackupDir=C:\Users\x\AppData\Local\AmsPluginManager\backup
      Count=2
      [Op1]
      Action=install          ; install | remove | config
      Name=HelloButton
      Source=C:\...\stage\HelloButton
      [Op2]
      Action=config
      Name=UiTweaks
      Source=C:\...\UiTweaks.plugin.ini

  Das Ergebnis wird in DIESELBE Datei zurueckgeschrieben ([OpN] Result=ok
  oder fail, Message=...; [Apply] Done=1) - so liest es der Aufrufer auch
  dann, wenn der Helfer mit anderen Rechten lief.

  Regeln, jede einzeln eine Lehre:
    - Name ist ein einzelner Ordnername (AmsIsSafeName). Nichts landet
      ausserhalb von PluginsDir.
    - Vorher wird der Plugin-Ordner nach BackupDir gesichert; scheitert ein
      Schritt, wird aus der Sicherung zurueckgespielt.
    - Geladene Dateien (AMS laeuft ja noch) werden beiseite umbenannt statt
      ueberschrieben, siehe AmsReplaceFile. AMS benutzt bis zum Neustart die
      alte BPL, danach die neue.
    - Beim Aktualisieren bleiben Dateien stehen, die es nur im Ziel gibt -
      dort liegt womoeglich etwas vom Anwender (eine WAD neben DOOM ...).
    - Ein Plugin-Ordner ist danach ENTWEDER vollstaendig (mit plugin.ini)
      ODER ganz weg. Ein Ordner ohne plugin.ini in BIN\plugins ist fuer AMS
      kein harmloser Rest, sondern ein Startabbruch: "Plugin descriptor
      file not found for <Name>" - so im echten AMS passiert, als die erste
      Fassung gesperrte BPLs als .old im Ordner liegen liess. Beim
      Entfernen wird deshalb alles in einen Papierkorb neben der Sicherung
      VERSCHOBEN (geht auf demselben Laufwerk auch mit geladener BPL); geht
      eine Datei nicht, wird alles zurueckgeschoben und abgelehnt.
      AmsRepairPluginsDir raeumt solche Reste vor jedem Lauf weg.

  Ohne Host, ohne AMS testbar.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

type
  TAmsApplyAction = (aaInstall, aaRemove, aaConfig);

  TAmsApplyOp = record
    Action: TAmsApplyAction;
    Name: string;
    Source: string;
    Ok: Boolean;
    Message: string;
  end;
  TAmsApplyOps = array of TAmsApplyOp;

{ Warteschlange schreiben bzw. lesen (mit Ergebnissen, falls schon da). }
function AmsQueueWrite(const AFile, APluginsDir, ABackupDir: string;
  const AOps: TAmsApplyOps): Boolean;
function AmsQueueRead(const AFile: string; out APluginsDir, ABackupDir: string;
  out AOps: TAmsApplyOps; out ADone: Boolean): Boolean;

{ Abarbeiten und Ergebnisse zurueckschreiben. True = alles ok. }
function AmsApplyQueueFile(const AFile: string): Boolean;

{ Eine Operation direkt, ohne Datei. }
function AmsApplyOp(const APluginsDir, ABackupDir: string;
  var AOp: TAmsApplyOp): Boolean;

{ Mit den noetigen Rechten abarbeiten: ist PluginsDir beschreibbar, hier im
  Prozess; sonst AHelperExe per UAC mit "--apply <Datei>" (APump: AMS
  zeichnet waehrenddessen weiter). Danach stehen die Ergebnisse in AOps.
  AElevated meldet, ob die UAC-Abfrage noetig war. }
function AmsApplyWithRights(const AFile, AHelperExe: string; APump: Boolean;
  out AOps: TAmsApplyOps; out AElevated: Boolean): Boolean;

{ Hauptprogramm des Helfers:
    if ParamStr(1) = '--apply' then Halt(AmsApplyHelperRun(ParamStr(2)));
  0 = alles ok, 1 = Teile fehlgeschlagen, 2 = Datei unlesbar. }
function AmsApplyHelperRun(const AFile: string): Integer;

{ Ordner ohne plugin.ini unter APluginsDir, die nur noch .old-Reste
  enthalten, ganz entfernen - ein solcher Ordner verhindert den Start von
  AMS. Ordner mit anderem Inhalt bleiben unangetastet (nur Warnung im
  Log). Laeuft vor jeder Warteschlange. Liefert die Anzahl. }
function AmsRepairPluginsDir(const APluginsDir, ABackupDir: string): Integer;

function AmsApplyActionName(AAction: TAmsApplyAction): string;

implementation

uses
  AmsApi.Log, AmsApi.Files, AmsApi.IniDoc, AmsApi.Process;

function AmsApplyActionName(AAction: TAmsApplyAction): string;
begin
  case AAction of
    aaInstall: Result := 'install';
    aaRemove:  Result := 'remove';
    aaConfig:  Result := 'config';
  else
    Result := '?';
  end;
end;

function ParseAction(const S: string; out A: TAmsApplyAction): Boolean;
begin
  Result := True;
  if SameText(S, 'install') then A := aaInstall
  else if SameText(S, 'remove') then A := aaRemove
  else if SameText(S, 'config') then A := aaConfig
  else Result := False;
end;

{ ------------------------------------------------------------ Warteschlange }

function AmsQueueWrite(const AFile, APluginsDir, ABackupDir: string;
  const AOps: TAmsApplyOps): Boolean;
var
  L: TStringList;
  i: Integer;
begin
  L := TStringList.Create;
  try
    L.Add('; Warteschlange des Plugin Managers - AmsApi.PluginApply');
    L.Add('[Apply]');
    L.Add('PluginsDir=' + ExcludeTrailingPathDelimiter(APluginsDir));
    L.Add('BackupDir=' + ExcludeTrailingPathDelimiter(ABackupDir));
    L.Add('Count=' + IntToStr(Length(AOps)));
    L.Add('Done=0');
    for i := 0 to High(AOps) do
    begin
      L.Add('');
      L.Add(Format('[Op%d]', [i + 1]));
      L.Add('Action=' + AmsApplyActionName(AOps[i].Action));
      L.Add('Name=' + AOps[i].Name);
      L.Add('Source=' + AOps[i].Source);
    end;
    Result := AmsWriteFileRaw(AFile, L.Text);
  finally
    L.Free;
  end;
end;

function AmsQueueRead(const AFile: string; out APluginsDir, ABackupDir: string;
  out AOps: TAmsApplyOps; out ADone: Boolean): Boolean;
var
  Doc: TAmsIniDoc;
  i, n: Integer;
  Sec: string;
begin
  Result := False;
  APluginsDir := '';
  ABackupDir := '';
  ADone := False;
  SetLength(AOps, 0);
  Doc := TAmsIniDoc.Create;
  try
    if not Doc.LoadFromFile(AFile) then Exit;
    APluginsDir := Doc.GetValue('Apply', 'PluginsDir');
    ABackupDir := Doc.GetValue('Apply', 'BackupDir');
    ADone := Doc.GetValue('Apply', 'Done') = '1';
    n := StrToIntDef(Doc.GetValue('Apply', 'Count'), 0);
    if (APluginsDir = '') or (n < 0) or (n > 100) then
      Exit(AmsFailFmt('Warteschlange unvollstaendig: %s', [AFile]));
    SetLength(AOps, n);
    for i := 0 to n - 1 do
    begin
      Sec := Format('Op%d', [i + 1]);
      if not ParseAction(Doc.GetValue(Sec, 'Action'), AOps[i].Action) then
        Exit(AmsFailFmt('Warteschlange: unbekannte Aktion in [%s]', [Sec]));
      AOps[i].Name := Doc.GetValue(Sec, 'Name');
      AOps[i].Source := Doc.GetValue(Sec, 'Source');
      AOps[i].Ok := Doc.GetValue(Sec, 'Result') = 'ok';
      AOps[i].Message := Doc.GetValue(Sec, 'Message');
    end;
    Result := True;
  finally
    Doc.Free;
  end;
end;

function WriteResults(const AFile: string; const AOps: TAmsApplyOps): Boolean;
var
  Doc: TAmsIniDoc;
  i: Integer;
  Sec, M: string;
begin
  Doc := TAmsIniDoc.Create;
  try
    Doc.LoadFromFile(AFile);
    for i := 0 to High(AOps) do
    begin
      Sec := Format('Op%d', [i + 1]);
      if AOps[i].Ok then Doc.SetValue(Sec, 'Result', 'ok')
      else Doc.SetValue(Sec, 'Result', 'fail');
      M := StringReplace(AOps[i].Message, #13, ' ', [rfReplaceAll]);
      M := StringReplace(M, #10, ' ', [rfReplaceAll]);
      Doc.SetValue(Sec, 'Message', M);
    end;
    Doc.SetValue('Apply', 'Done', '1');
    Result := Doc.SaveToFile(AFile);
  finally
    Doc.Free;
  end;
end;

{ ----------------------------------------------------------- Operationen - }

function Stamp: string;
var
  T: TSystemTime;
begin
  GetLocalTime(T);
  Result := Format('%.4d%.2d%.2d-%.2d%.2d%.2d', [T.wYear, T.wMonth, T.wDay,
                   T.wHour, T.wMinute, T.wSecond]);
end;

{ Ganzen Plugin-Ordner sichern. '' = nichts zu sichern. }
function Backup(const ATarget, ABackupDir, AName: string;
  out ABackup: string): Boolean;
begin
  ABackup := '';
  if not DirectoryExists(ATarget) then Exit(True);
  if ABackupDir = '' then Exit(True);
  ABackup := IncludeTrailingPathDelimiter(ABackupDir) + AName + '-' + Stamp;
  if DirectoryExists(ABackup) then ABackup := ABackup + '-' + IntToStr(GetTickCount64 mod 1000);
  Result := AmsCopyTree(ATarget, ABackup);
  if Result then AmsLogFmt('Gesichert: %s -> %s', [ATarget, ABackup])
  else ABackup := '';
end;

procedure Restore(const ABackup, ATarget: string);
begin
  if (ABackup = '') or not DirectoryExists(ABackup) then Exit;
  if AmsCopyTree(ABackup, ATarget) then
    AmsLogFmt('Zurueckgespielt: %s -> %s', [ABackup, ATarget])
  else
    AmsLogFmt('ZURUECKSPIELEN FEHLGESCHLAGEN: %s -> %s (%s)',
              [ABackup, ATarget, AmsLastError]);
end;

function MoveOut(const ATarget, ABackupDir, AName: string): Boolean; forward;

function DoInstall(const ATarget, ABackupDir: string;
  var AOp: TAmsApplyOp): Boolean;
var
  Bak: string;
  WasThere: Boolean;
begin
  Result := False;
  if not DirectoryExists(AOp.Source) then
    Exit(AmsFailFmt('Bereitstellung fehlt: %s', [AOp.Source]));
  if not FileExists(IncludeTrailingPathDelimiter(AOp.Source) + 'plugin.ini') then
    Exit(AmsFailFmt('Bereitstellung ohne plugin.ini: %s', [AOp.Source]));
  AmsCleanupOld(ATarget);
  WasThere := DirectoryExists(ATarget);
  if not Backup(ATarget, ABackupDir, AOp.Name, Bak) then
    Exit(AmsFailFmt('Sicherung fehlgeschlagen: %s', [AmsLastError]));
  if not AmsCopyTree(AOp.Source, ATarget) then
  begin
    AOp.Message := AmsLastError;
    if WasThere then
      Restore(Bak, ATarget)
    else
      { Neu und halb kopiert: ganz weg - ein Ordner ohne plugin.ini
        verhindert den Start von AMS }
      MoveOut(ATarget, ABackupDir, AOp.Name);
    Exit(AmsFail(AOp.Message));
  end;
  Result := True;
end;

{ ------------------------------------------------------------- Papierkorb -
  Was aus BIN\plugins hinaus muss, waehrend AMS es noch geladen hat, wird
  dorthin VERSCHOBEN. Verschieben ist auf demselben Laufwerk ein Umbenennen
  und geht auch bei einer geladenen BPL - Loeschen nicht. Der Papierkorb
  liegt neben der Sicherung und wird beim naechsten Lauf geleert, sobald
  nichts mehr geladen ist. }

function TrashRoot(const ABackupDir: string): string;
begin
  Result := '';
  if ABackupDir = '' then Exit;
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(
              ExcludeTrailingPathDelimiter(ABackupDir))) + 'trash';
end;

function SameVolume(const A, B: string): Boolean;
begin
  Result := (A <> '') and (B <> '') and
            SameText(ExtractFileDrive(ExpandFileName(A)),
                     ExtractFileDrive(ExpandFileName(B)));
end;

{ Leere Ordner von unten nach oben weg, ADir zuletzt. }
procedure RemoveEmptyDirs(const ADir: string);
var
  FD: TWin32FindDataW;
  H: THandle;
  Name, D: string;
begin
  D := ExcludeTrailingPathDelimiter(ADir);
  H := FindFirstFileW(PWideChar(WideString(D + '\*')), FD);
  if H <> INVALID_HANDLE_VALUE then
  try
    repeat
      Name := string(WideString(FD.cFileName));
      if (Name = '.') or (Name = '..') then Continue;
      if (FD.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        RemoveEmptyDirs(D + '\' + Name);
    until not FindNextFileW(H, FD);
  finally
    Windows.FindClose(H);
  end;
  RemoveDirectoryW(PWideChar(WideString(D)));
end;

{ Leise loeschen, was geht - gesperrte Reste bleiben bis zum naechsten Mal. }
procedure QuietDeleteTree(const ADir: string);
var
  L: TStringList;
  i: Integer;
  D: string;
begin
  D := IncludeTrailingPathDelimiter(ADir);
  if not DirectoryExists(D) then Exit;
  L := TStringList.Create;
  try
    AmsListFiles(D, L, True);
    for i := 0 to L.Count - 1 do
    begin
      SetFileAttributesW(PWideChar(WideString(D + L[i])), FILE_ATTRIBUTE_NORMAL);
      DeleteFileW(PWideChar(WideString(D + L[i])));
    end;
  finally
    L.Free;
  end;
  RemoveEmptyDirs(D);
end;

procedure EmptyTrash(const ABackupDir: string);
var
  FD: TWin32FindDataW;
  H: THandle;
  Root, Name: string;
begin
  Root := TrashRoot(ABackupDir);
  if (Root = '') or not DirectoryExists(Root) then Exit;
  H := FindFirstFileW(PWideChar(WideString(Root + '\*')), FD);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    repeat
      Name := string(WideString(FD.cFileName));
      if (Name <> '.') and (Name <> '..') and
         ((FD.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) then
        QuietDeleteTree(Root + '\' + Name);
    until not FindNextFileW(H, FD);
  finally
    Windows.FindClose(H);
  end;
end;

{ Den Plugin-Ordner ganz aus BIN\plugins hinaus schaffen - ALLES ODER
  NICHTS. Ein Ordner ohne plugin.ini in BIN\plugins verhindert den Start
  von AMS ("Plugin descriptor file not found for ..."). So im echten AMS
  passiert, als die erste Fassung gesperrte BPLs als .old im Ordner liess. }
function MoveOut(const ATarget, ABackupDir, AName: string): Boolean;
var
  L: TStringList;
  i, j, n: Integer;
  Trash, T: string;
  Err: DWORD;
  ViaTrash: Boolean;
begin
  Result := False;
  T := IncludeTrailingPathDelimiter(ATarget);
  Trash := TrashRoot(ABackupDir);
  ViaTrash := SameVolume(ATarget, Trash);
  if ViaTrash then
    Trash := Trash + '\' + AName + '-' + Stamp + '-' +
             IntToStr(GetTickCount64 mod 100000) + '\';
  L := TStringList.Create;
  try
    AmsListFiles(T, L, True);
    { plugin.ini zuletzt: bricht es unterwegs ab (ohne Papierkorb wird
      geloescht, nicht verschoben), bleibt ein gueltiges Plugin stehen }
    i := L.IndexOf('plugin.ini');
    if i >= 0 then L.Move(i, L.Count - 1);
    n := 0;
    for i := 0 to L.Count - 1 do
    begin
      SetFileAttributesW(PWideChar(WideString(T + L[i])), FILE_ATTRIBUTE_NORMAL);
      if ViaTrash then
      begin
        AmsForceDir(ExtractFilePath(Trash + L[i]));
        if MoveFileW(PWideChar(WideString(T + L[i])),
                     PWideChar(WideString(Trash + L[i]))) then
        begin
          Inc(n);
          Continue;
        end;
      end
      else if DeleteFileW(PWideChar(WideString(T + L[i]))) then
      begin
        Inc(n);
        Continue;
      end;
      { Geht nicht: alles zurueck, nichts veraendert lassen }
      Err := GetLastError;
      if ViaTrash then
        for j := n - 1 downto 0 do
          MoveFileW(PWideChar(WideString(Trash + L[j])),
                    PWideChar(WideString(T + L[j])));
      Exit(AmsFailFmt('%s laesst sich nicht entfernen (%d), solange es ' +
                      'benutzt wird. AMS beenden und erneut versuchen - ' +
                      'am Plugin wurde nichts veraendert.', [L[i], Err]));
    end;

    RemoveEmptyDirs(T);
    if DirectoryExists(ExcludeTrailingPathDelimiter(T)) then
    begin
      { z.B. im Explorer geoeffnet - zurueck, damit AMS startet }
      if ViaTrash then
        for j := n - 1 downto 0 do
        begin
          AmsForceDir(ExtractFilePath(T + L[j]));
          MoveFileW(PWideChar(WideString(Trash + L[j])),
                    PWideChar(WideString(T + L[j])));
        end;
      Exit(AmsFailFmt('Der Ordner %s laesst sich nicht entfernen (geoeffnet?). ' +
                      'Am Plugin wurde nichts veraendert.', [ATarget]));
    end;
    Result := True;
  finally
    L.Free;
  end;
  if ViaTrash then QuietDeleteTree(Trash);
end;

function DoRemove(const ATarget, ABackupDir: string;
  var AOp: TAmsApplyOp): Boolean;
var
  Bak: string;
begin
  Result := False;
  if not DirectoryExists(ATarget) then Exit(True);   { schon weg }
  if not Backup(ATarget, ABackupDir, AOp.Name, Bak) then
    Exit(AmsFailFmt('Sicherung fehlgeschlagen: %s', [AmsLastError]));
  if not MoveOut(ATarget, ABackupDir, AOp.Name) then
  begin
    { Ohne Papierkorb wurde geloescht - aus der Sicherung zurueck }
    if DirectoryExists(ATarget) and
       not FileExists(IncludeTrailingPathDelimiter(ATarget) + 'plugin.ini') then
      Restore(Bak, ATarget);
    Exit;
  end;
  Result := True;
end;

function AmsRepairPluginsDir(const APluginsDir, ABackupDir: string): Integer;
var
  FD: TWin32FindDataW;
  H: THandle;
  Name, D: string;
  L: TStringList;
  i: Integer;
  OnlyOld: Boolean;
begin
  Result := 0;
  D := IncludeTrailingPathDelimiter(APluginsDir);
  H := FindFirstFileW(PWideChar(WideString(D + '*')), FD);
  if H = INVALID_HANDLE_VALUE then Exit;
  L := TStringList.Create;
  try
    repeat
      Name := string(WideString(FD.cFileName));
      if (Name = '.') or (Name = '..') or
         ((FD.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0) then
        Continue;
      if FileExists(D + Name + '\plugin.ini') then Continue;
      L.Clear;
      AmsListFiles(D + Name, L, True);
      OnlyOld := True;
      for i := 0 to L.Count - 1 do
        if not SameText(ExtractFileExt(L[i]), '.old') then OnlyOld := False;
      if not OnlyOld then
      begin
        AmsLogFmt('WARNUNG: %s%s hat keine plugin.ini - AMS startet so nicht. ' +
                  'Nicht von hier, bleibt unangetastet.', [D, Name]);
        Continue;
      end;
      if MoveOut(D + Name, ABackupDir, 'Rest-' + Name) then
      begin
        AmsLogFmt('Repariert: Rest %s%s entfernt', [D, Name]);
        Inc(Result);
      end;
    until not FindNextFileW(H, FD);
  finally
    L.Free;
    Windows.FindClose(H);
  end;
end;

function DoConfig(const ATarget, ABackupDir: string;
  var AOp: TAmsApplyOp): Boolean;
var
  Bak, Renamed: string;
begin
  Result := False;
  if not DirectoryExists(ATarget) then
    Exit(AmsFailFmt('Plugin %s ist nicht installiert', [AOp.Name]));
  if not FileExists(AOp.Source) then
    Exit(AmsFailFmt('Neue Einstellungen fehlen: %s', [AOp.Source]));
  if ABackupDir <> '' then
  begin
    Bak := IncludeTrailingPathDelimiter(ABackupDir) + AOp.Name + '-' + Stamp +
           '-plugin.ini';
    AmsForceDir(ABackupDir);
    CopyFileW(PWideChar(WideString(IncludeTrailingPathDelimiter(ATarget) +
              'plugin.ini')), PWideChar(WideString(Bak)), False);
  end;
  Result := AmsReplaceFile(AOp.Source, IncludeTrailingPathDelimiter(ATarget) +
                           'plugin.ini', Renamed);
end;

function AmsApplyOp(const APluginsDir, ABackupDir: string;
  var AOp: TAmsApplyOp): Boolean;
var
  Target: string;
begin
  AOp.Ok := False;
  AOp.Message := '';
  AmsClearError;
  try
    if not AmsIsSafeName(AOp.Name) then
      AmsFailFmt('Ungueltiger Pluginname: "%s"', [AOp.Name])
    else if not DirectoryExists(ExcludeTrailingPathDelimiter(APluginsDir)) then
      AmsFailFmt('Plugin-Ordner fehlt: %s', [APluginsDir])
    else
    begin
      Target := IncludeTrailingPathDelimiter(APluginsDir) + AOp.Name;
      case AOp.Action of
        aaInstall: AOp.Ok := DoInstall(Target, ABackupDir, AOp);
        aaRemove:  AOp.Ok := DoRemove(Target, ABackupDir, AOp);
        aaConfig:  AOp.Ok := DoConfig(Target, ABackupDir, AOp);
      end;
    end;
  except
    on E: Exception do AmsFail('Ausnahme: ' + E.Message);
  end;
  if AOp.Ok then AOp.Message := 'ok'
  else if AOp.Message = '' then AOp.Message := AmsLastError;
  AmsLogFmt('Apply %s %s -> %s', [AmsApplyActionName(AOp.Action), AOp.Name,
                                  AOp.Message]);
  Result := AOp.Ok;
end;

function AmsApplyQueueFile(const AFile: string): Boolean;
var
  Dir, Bak: string;
  Ops: TAmsApplyOps;
  Done: Boolean;
  i: Integer;
begin
  Result := False;
  if not AmsQueueRead(AFile, Dir, Bak, Ops, Done) then Exit;
  if Done then Exit(AmsFailFmt('Warteschlange ist schon abgearbeitet: %s', [AFile]));
  { Aufraeumen vom letzten Mal: Papierkorb leeren, Reste reparieren }
  EmptyTrash(Bak);
  AmsRepairPluginsDir(Dir, Bak);
  Result := True;
  for i := 0 to High(Ops) do
    if not AmsApplyOp(Dir, Bak, Ops[i]) then Result := False;
  if not WriteResults(AFile, Ops) then
    Result := AmsFailFmt('Ergebnisse nicht schreibbar: %s', [AFile]);
end;

function AmsApplyWithRights(const AFile, AHelperExe: string; APump: Boolean;
  out AOps: TAmsApplyOps; out AElevated: Boolean): Boolean;
var
  Dir, Bak: string;
  Done: Boolean;
  Code: DWORD;
  i: Integer;
begin
  Result := False;
  AElevated := False;
  SetLength(AOps, 0);
  if not AmsQueueRead(AFile, Dir, Bak, AOps, Done) then Exit;
  if AmsCanWriteDir(Dir) then
    AmsApplyQueueFile(AFile)
  else
  begin
    AElevated := True;
    if (AHelperExe = '') or not FileExists(AHelperExe) then
      Exit(AmsFailFmt('Fuer %s braucht es Administratorrechte, das ' +
                      'Hilfsprogramm fehlt aber: %s', [Dir, AHelperExe]));
    if not AmsRunAndWait(AHelperExe, '--apply ' + AmsQuoteArg(AFile), True,
                         APump, Code) then
      Exit;
  end;
  if not AmsQueueRead(AFile, Dir, Bak, AOps, Done) then Exit;
  if not Done then
    Exit(AmsFail('Die Installation wurde nicht ausgefuehrt (Hilfsprogramm ' +
                 'ohne Ergebnis).'));
  Result := True;
  for i := 0 to High(AOps) do
    if not AOps[i].Ok then
    begin
      Result := False;
      AmsFail(AOps[i].Name + ': ' + AOps[i].Message);
    end;
end;

function AmsApplyHelperRun(const AFile: string): Integer;
begin
  AmsDisableVirtualization;
  if not FileExists(AFile) then Exit(2);
  try
    if AmsApplyQueueFile(AFile) then Result := 0 else Result := 1;
  except
    Result := 1;
  end;
end;

end.
