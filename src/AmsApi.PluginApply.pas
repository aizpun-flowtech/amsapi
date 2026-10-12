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
    - Beim Entfernen geht die plugin.ini zuerst. Ohne sie ist der Ordner
      fuer AMS kein Plugin mehr, auch wenn eine gesperrte BPL bis zum
      Neustart als .old liegen bleibt.

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

function DoInstall(const ATarget, ABackupDir: string;
  var AOp: TAmsApplyOp): Boolean;
var
  Bak: string;
begin
  Result := False;
  if not DirectoryExists(AOp.Source) then
    Exit(AmsFailFmt('Bereitstellung fehlt: %s', [AOp.Source]));
  if not FileExists(IncludeTrailingPathDelimiter(AOp.Source) + 'plugin.ini') then
    Exit(AmsFailFmt('Bereitstellung ohne plugin.ini: %s', [AOp.Source]));
  AmsCleanupOld(ATarget);
  if not Backup(ATarget, ABackupDir, AOp.Name, Bak) then
    Exit(AmsFailFmt('Sicherung fehlgeschlagen: %s', [AmsLastError]));
  if not AmsCopyTree(AOp.Source, ATarget) then
  begin
    AOp.Message := AmsLastError;
    Restore(Bak, ATarget);
    Exit(AmsFail(AOp.Message));
  end;
  Result := True;
end;

function DoRemove(const ATarget, ABackupDir: string;
  var AOp: TAmsApplyOp): Boolean;
var
  Bak, Renamed: string;
  L: TStringList;
  i, Kept: Integer;
begin
  Result := False;
  if not DirectoryExists(ATarget) then Exit(True);   { schon weg }
  if not Backup(ATarget, ABackupDir, AOp.Name, Bak) then
    Exit(AmsFailFmt('Sicherung fehlgeschlagen: %s', [AmsLastError]));
  { plugin.ini zuerst: ohne sie ist der Ordner fuer AMS kein Plugin mehr }
  if not AmsRemoveFile(IncludeTrailingPathDelimiter(ATarget) + 'plugin.ini',
                       Renamed) then
    Exit(AmsFailFmt('plugin.ini nicht entfernbar: %s', [AmsLastError]));
  Kept := 0;
  L := TStringList.Create;
  try
    AmsListFiles(ATarget, L, True);
    for i := 0 to L.Count - 1 do
      if not AmsRemoveFile(IncludeTrailingPathDelimiter(ATarget) + L[i],
                           Renamed) then
        Inc(Kept)
      else if Renamed <> '' then
        Inc(Kept);
  finally
    L.Free;
  end;
  if Kept = 0 then
    AmsDeleteTree(ATarget)
  else
    AmsLogFmt('%s: %d gesperrte Dateien bleiben bis zum Neustart als .old',
              [AOp.Name, Kept]);
  Result := True;
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
