unit AmsApi.Log;

{ ============================================================================
  AmsApi.Log - threadsicheres Logging und Fehlerspeicher

  Designregel der Bibliothek: KEINE MessageBox aus der API heraus. Funktionen
  liefern Boolean, die Ursache steht in AmsLastError und im Log. Ob daraus ein
  Dialog wird, entscheidet allein das Plugin.

  Das Logziel ist standardmaessig %TEMP%\<Modulname>.log - dadurch schreiben
  mehrere Plugins, die diese API benutzen, nicht in dieselbe Datei.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

var
  { Schalter fuer das Dateilog. Fehler landen unabhaengig davon in AmsLastError. }
  AmsLogEnabled: Boolean = True;
  { Ab dieser Groesse wird die Logdatei nach *.log.old weggerollt. 0 = nie. }
  AmsLogMaxBytes: Int64 = 2 * 1024 * 1024;

{ Vollstaendiger Pfad des Moduls, in dem diese Unit laeuft (also des Plugins). }
function AmsModuleFile: string;
{ Verzeichnis dieses Moduls, mit abschliessendem Backslash. }
function AmsModuleDir: string;
{ Dateiname ohne Pfad und Endung, z.B. "AmsToolbox". }
function AmsModuleName: string;

{ Aktuelles Logziel. Leer = nur Ringpuffer, keine Datei. }
function  AmsLogFile: string;
procedure AmsSetLogFile(const AFile: string);

procedure AmsLog(const AText: string);
procedure AmsLogFmt(const AFormat: string; const AArgs: array of const);

{ Letzter Fehlertext. Wird von AmsFail gesetzt, von AmsClearError geleert. }
function  AmsLastError: string;
procedure AmsClearError;

{ Fehler protokollieren, in AmsLastError merken und False liefern. Damit
  laesst sich in einer Zeile abbrechen:  if X = nil then Exit(AmsFail('...')); }
function AmsFail(const AText: string): Boolean;
function AmsFailFmt(const AFormat: string; const AArgs: array of const): Boolean;

{ Die letzten Zeilen aus dem Ringpuffer - fuer Diagnosefenster eines Plugins. }
procedure AmsLogTail(ADest: TStrings; AMaxLines: Integer = 200);

implementation

var
  gLock: TRTLCriticalSection;
  gLockReady: Boolean = False;
  gRing: TStringList = nil;
  gFile: string = '';
  gFileSet: Boolean = False;
  gLastError: string = '';

const
  RING_MAX = 400;

function AmsModuleFile: string;
var
  Buf: array[0..MAX_PATH] of WideChar;
begin
  Buf[0] := #0;
  GetModuleFileNameW(HInstance, Buf, Length(Buf));
  Result := string(WideString(Buf));
end;

function AmsModuleDir: string;
begin
  Result := ExtractFilePath(AmsModuleFile);
end;

function AmsModuleName: string;
begin
  Result := ChangeFileExt(ExtractFileName(AmsModuleFile), '');
  if Result = '' then Result := 'AmsPlugin';
end;

function AmsLogFile: string;
begin
  if not gFileSet then
  begin
    gFile := IncludeTrailingPathDelimiter(GetTempDir) + AmsModuleName + '.log';
    gFileSet := True;
  end;
  Result := gFile;
end;

procedure AmsSetLogFile(const AFile: string);
begin
  gFile := AFile;
  gFileSet := True;
end;

{ Logdatei wegrollen, damit ein dauerlaufendes AMS die Platte nicht fuellt. }
procedure RollIfLarge(const AFile: string);
var
  H: THandle;
  Size: Int64;
  Old: string;
begin
  if AmsLogMaxBytes <= 0 then Exit;
  H := CreateFileW(PWideChar(WideString(AFile)), GENERIC_READ,
         FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if H = INVALID_HANDLE_VALUE then Exit;
  Size := 0;
  Int64Rec(Size).Lo := GetFileSize(H, @Int64Rec(Size).Hi);
  CloseHandle(H);
  if Size < AmsLogMaxBytes then Exit;
  Old := AFile + '.old';
  DeleteFileW(PWideChar(WideString(Old)));
  MoveFileW(PWideChar(WideString(AFile)), PWideChar(WideString(Old)));
end;

procedure WriteLine(const ALine: string);
var
  F: TextFile;
  Target: string;
begin
  Target := AmsLogFile;
  if Target = '' then Exit;
  try
    if FileExists(Target) then
    begin
      RollIfLarge(Target);
      if FileExists(Target) then
      begin
        AssignFile(F, Target);
        Append(F);
      end
      else
      begin
        AssignFile(F, Target);
        Rewrite(F);
      end;
    end
    else
    begin
      AssignFile(F, Target);
      Rewrite(F);
    end;
    try
      WriteLn(F, ALine);
    finally
      CloseFile(F);
    end;
  except
    { Ein fehlgeschlagener Logschreibvorgang darf niemals das Plugin stoeren. }
  end;
end;

procedure AmsLog(const AText: string);
var
  Line: string;
begin
  if not gLockReady then Exit;
  try
    Line := FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AText;
  except
    Line := AText;
  end;
  EnterCriticalSection(gLock);
  try
    if gRing <> nil then
    begin
      gRing.Add(Line);
      while gRing.Count > RING_MAX do gRing.Delete(0);
    end;
    if AmsLogEnabled then WriteLine(Line);
  finally
    LeaveCriticalSection(gLock);
  end;
end;

procedure AmsLogFmt(const AFormat: string; const AArgs: array of const);
begin
  try
    AmsLog(Format(AFormat, AArgs));
  except
    AmsLog(AFormat);
  end;
end;

function AmsLastError: string;
begin
  if not gLockReady then Exit(gLastError);
  EnterCriticalSection(gLock);
  try
    Result := gLastError;
  finally
    LeaveCriticalSection(gLock);
  end;
end;

procedure AmsClearError;
begin
  if not gLockReady then
  begin
    gLastError := '';
    Exit;
  end;
  EnterCriticalSection(gLock);
  try
    gLastError := '';
  finally
    LeaveCriticalSection(gLock);
  end;
end;

function AmsFail(const AText: string): Boolean;
begin
  Result := False;
  if gLockReady then
  begin
    EnterCriticalSection(gLock);
    try
      gLastError := AText;
    finally
      LeaveCriticalSection(gLock);
    end;
  end
  else
    gLastError := AText;
  AmsLog('FEHLER: ' + AText);
end;

function AmsFailFmt(const AFormat: string; const AArgs: array of const): Boolean;
begin
  try
    Result := AmsFail(Format(AFormat, AArgs));
  except
    Result := AmsFail(AFormat);
  end;
end;

procedure AmsLogTail(ADest: TStrings; AMaxLines: Integer);
var
  i, First: Integer;
begin
  if (ADest = nil) or not gLockReady then Exit;
  EnterCriticalSection(gLock);
  try
    if gRing = nil then Exit;
    First := gRing.Count - AMaxLines;
    if First < 0 then First := 0;
    for i := First to gRing.Count - 1 do
      ADest.Add(gRing[i]);
  finally
    LeaveCriticalSection(gLock);
  end;
end;

initialization
  InitCriticalSection(gLock);
  gRing := TStringList.Create;
  gLockReady := True;

finalization
  gLockReady := False;
  FreeAndNil(gRing);
  DoneCriticalSection(gLock);

end.
