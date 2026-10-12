unit AmsApi.Process;

{ ============================================================================
  AmsApi.Process - Programme starten, Rechte heben, AMS neu starten

  Drei Dinge, die ein Plugin braucht, sobald es AMS selbst veraendert:

  1. MIT ADMINISTRATORRECHTEN etwas tun. BIN\plugins liegt unter Program
     Files; normale Benutzer duerfen dort nur lesen. AmsRunAndWait mit
     AElevated = True startet ein Hilfsprogramm ueber "runas" (UAC-Abfrage)
     und wartet darauf - auf Wunsch so, dass AMS waehrenddessen weiter
     zeichnet (APump).

  2. AMS NEU STARTEN. Ein Plugin kann den Prozess, in dem es laeuft, nicht
     selbst wieder hochfahren. AmsRestartHost legt deshalb einen kleinen
     Wartehelfer an, der auf das Ende von AMS wartet und es dann mit
     derselben Befehlszeile im selben Ordner wieder startet - und schickt
     dem Hauptfenster danach WM_CLOSE. AMS beendet sich also ganz normal,
     mit allen Rueckfragen. Bricht der Anwender das Beenden ab, gibt der
     Helfer nach AMS_RESTART_TIMEOUT_S Sekunden auf, statt AMS Stunden
     spaeter ueberraschend neu zu starten.

     Der Helfer ist entweder ein eigenes Programm (AmsRestartHelperRun,
     z.B. AmsPluginApply.exe --restart <ini>) oder, wenn keines angegeben
     ist, PowerShell mit -EncodedCommand (keine Anfuehrungszeichen-Hoelle,
     keine Ausfuehrungsrichtlinie). Der Neustart laeuft in jedem Fall OHNE
     erhoehte Rechte - ein per UAC gestartetes AMS waere falsch.

  3. Ein Kindprozess, der AMS UEBERLEBT: CREATE_BREAKAWAY_FROM_JOB, falls
     AMS in einem Job laeuft, der seine Kinder beim Beenden mitnimmt.

  Keine MessageBox hier (Designregel 1) - die Neustart-Frage steht in
  AmsApi.Dialogs.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

var
  { So lange wartet der Neustart-Helfer auf das Ende von AMS. }
  AmsRestartTimeoutS: Integer = 180;

{ Laeuft dieser Prozess mit erhoehten Rechten? }
function AmsIsElevated: Boolean;

{ Programmdatei, Argumente (ohne Programmpfad) und Arbeitsordner des
  laufenden Prozesses - im Plugin also die von AMS. }
function AmsHostExe: string;
function AmsHostArgs: string;
function AmsHostDir: string;

{ Programm starten und auf sein Ende warten.
  AElevated  ueber UAC ("runas"). Lehnt der Anwender ab: False, AmsLastError
             sagt es.
  APump      waehrenddessen Nachrichten verteilen - AMS bleibt bedienbar
             und zeichnet. Eigene Fenster vorher sperren (EnableWindow).
  Liefert True, wenn das Programm lief; AExitCode ist dann sein Exitcode. }
function AmsRunAndWait(const AExe, AParams: string; AElevated, APump: Boolean;
  out AExitCode: DWORD; ATimeoutMs: DWORD = INFINITE): Boolean;

{ Programm starten, nicht warten. Ueberlebt das Ende von AMS. }
function AmsStartDetached(const AExe, AParams, ADir: string;
  AHidden: Boolean = True): Boolean;

{ Auf das Ende eines Prozesses warten. True = beendet (oder gab es nicht). }
function AmsWaitProcessExit(APid: DWORD; ATimeoutMs: DWORD): Boolean;

{ AMS neu starten - siehe Kopf. AHelperExe = Programm, das
  "--restart <ini>" versteht (AmsRestartHelperRun); leer = PowerShell. }
function AmsRestartHost(AMainWnd: HWND; const AHelperExe: string = ''): Boolean;

{ Der Wartehelfer selbst. Gehoert in das Hauptprogramm eines Hilfs-exe:
    if ParamStr(1) = '--restart' then Halt(AmsRestartHelperRun(ParamStr(2)));
  0 = neu gestartet, 2 = AMS lief nach der Wartezeit noch, 3 = Start
  fehlgeschlagen, 1 = Parameterdatei fehlt. }
function AmsRestartHelperRun(const AParamFile: string): Integer;

{ Argument fuer eine Befehlszeile in Anfuehrungszeichen setzen, falls
  noetig (Regeln von CommandLineToArgvW). }
function AmsQuoteArg(const AArg: string): string;

implementation

uses
  AmsApi.Log, AmsApi.Ini, AmsApi.Files;

const
  SEE_MASK_NOCLOSEPROCESS = $00000040;
  SEE_MASK_FLAG_NO_UI     = $00000400;
  SEE_MASK_NOASYNC        = $00000100;
  TOKEN_ELEVATION_CLASS   = 20;
  CREATE_BREAKAWAY        = $01000000;   { CREATE_BREAKAWAY_FROM_JOB }

type
  TShellExecuteInfoW = record
    cbSize: DWORD;
    fMask: ULONG;
    Wnd: HWND;
    lpVerb: PWideChar;
    lpFile: PWideChar;
    lpParameters: PWideChar;
    lpDirectory: PWideChar;
    nShow: Integer;
    hInstApp: HINST;
    lpIDList: Pointer;
    lpClass: PWideChar;
    hkeyClass: HKEY;
    dwHotKey: DWORD;
    hIconOrMonitor: THandle;
    hProcess: THandle;
  end;

function ShellExecuteExW(var AInfo: TShellExecuteInfoW): BOOL; stdcall;
  external 'shell32.dll' name 'ShellExecuteExW';

function AmsIsElevated: Boolean;
var
  H: THandle;
  V, L: DWORD;
begin
  Result := False;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, H) then Exit;
  try
    V := 0;
    if GetTokenInformation(H, TTokenInformationClass(TOKEN_ELEVATION_CLASS),
                           @V, SizeOf(V), L) then
      Result := V <> 0;
  finally
    CloseHandle(H);
  end;
end;

function AmsHostExe: string;
var
  Buf: array[0..MAX_PATH * 2] of WideChar;
begin
  Buf[0] := #0;
  GetModuleFileNameW(0, Buf, Length(Buf));
  Result := string(WideString(Buf));
end;

function AmsHostArgs: string;
var
  C: WideString;
  i: Integer;
  InQ: Boolean;
begin
  C := WideString(GetCommandLineW);
  { Erstes Token ueberspringen - Programmpfad, ggf. in Anfuehrungszeichen }
  i := 1;
  InQ := False;
  while i <= Length(C) do
  begin
    if C[i] = '"' then InQ := not InQ
    else if (C[i] = ' ') and not InQ then Break;
    Inc(i);
  end;
  Result := Trim(string(Copy(C, i, MaxInt)));
end;

function AmsHostDir: string;
var
  Buf: array[0..MAX_PATH * 2] of WideChar;
begin
  Buf[0] := #0;
  GetCurrentDirectoryW(Length(Buf), Buf);
  Result := string(WideString(Buf));
end;

function AmsQuoteArg(const AArg: string): string;
var
  i, Bs: Integer;
begin
  if (AArg <> '') and (Pos(' ', AArg) = 0) and (Pos(#9, AArg) = 0) and
     (Pos('"', AArg) = 0) then
    Exit(AArg);
  Result := '"';
  Bs := 0;
  for i := 1 to Length(AArg) do
  begin
    if AArg[i] = '\' then
    begin
      Inc(Bs);
      Continue;
    end;
    if AArg[i] = '"' then
      Result := Result + StringOfChar('\', Bs * 2 + 1) + '"'
    else
      Result := Result + StringOfChar('\', Bs) + AArg[i];
    Bs := 0;
  end;
  Result := Result + StringOfChar('\', Bs * 2) + '"';
end;

procedure PumpOnce;
var
  M: TMsg;
begin
  while PeekMessageW(M, 0, 0, 0, PM_REMOVE) do
  begin
    if M.message = WM_QUIT then
    begin
      { WM_QUIT gehoert der Schleife des Hosts - wieder einstellen }
      PostQuitMessage(M.wParam);
      Exit;
    end;
    TranslateMessage(M);
    DispatchMessageW(M);
  end;
end;

function AmsRunAndWait(const AExe, AParams: string; AElevated, APump: Boolean;
  out AExitCode: DWORD; ATimeoutMs: DWORD): Boolean;
var
  Info: TShellExecuteInfoW;
  ExeW, ParW, VerbW, DirW: WideString;
  Start: QWord;
  Left, R, Err: DWORD;
begin
  Result := False;
  AExitCode := DWORD(-1);
  if not FileExists(AExe) then
    Exit(AmsFailFmt('Programm fehlt: %s', [AExe]));
  ExeW := WideString(AExe);
  ParW := WideString(AParams);
  DirW := WideString(ExtractFilePath(AExe));
  if AElevated then VerbW := 'runas' else VerbW := 'open';
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  Info.fMask := SEE_MASK_NOCLOSEPROCESS or SEE_MASK_NOASYNC or SEE_MASK_FLAG_NO_UI;
  Info.Wnd := GetActiveWindow;
  Info.lpVerb := PWideChar(VerbW);
  Info.lpFile := PWideChar(ExeW);
  Info.lpParameters := PWideChar(ParW);
  Info.lpDirectory := PWideChar(DirW);
  Info.nShow := SW_HIDE;
  AmsLogFmt('Starte%s: %s %s', [BoolToStr(AElevated, ' mit UAC', ''), AExe, AParams]);
  if not ShellExecuteExW(Info) then
  begin
    Err := GetLastError;
    if Err = ERROR_CANCELLED then
      Exit(AmsFail('Die Bestaetigung mit Administratorrechten wurde abgelehnt.'));
    Exit(AmsFailFmt('Start fehlgeschlagen (%d): %s', [Err, AExe]));
  end;
  if Info.hProcess = 0 then
    Exit(AmsFailFmt('Kein Prozess-Handle fuer %s', [AExe]));
  try
    Start := GetTickCount64;
    repeat
      if ATimeoutMs = INFINITE then Left := INFINITE
      else
      begin
        if GetTickCount64 - Start >= ATimeoutMs then
          Exit(AmsFailFmt('Zeitueberschreitung beim Warten auf %s', [AExe]));
        Left := ATimeoutMs - DWORD(GetTickCount64 - Start);
      end;
      if APump then
      begin
        R := MsgWaitForMultipleObjects(1, Info.hProcess, False, Left, QS_ALLINPUT);
        if R = WAIT_OBJECT_0 + 1 then
        begin
          PumpOnce;
          Continue;
        end;
      end
      else
        R := WaitForSingleObject(Info.hProcess, Left);
      if R = WAIT_OBJECT_0 then Break;
      if R = WAIT_TIMEOUT then
        Exit(AmsFailFmt('Zeitueberschreitung beim Warten auf %s', [AExe]));
      if R = WAIT_FAILED then
        Exit(AmsFailFmt('Warten fehlgeschlagen (%d)', [GetLastError]));
    until False;
    GetExitCodeProcess(Info.hProcess, AExitCode);
    AmsLogFmt('%s beendet, Exitcode %d', [ExtractFileName(AExe), AExitCode]);
    Result := True;
  finally
    CloseHandle(Info.hProcess);
  end;
end;

function AmsStartDetached(const AExe, AParams, ADir: string;
  AHidden: Boolean): Boolean;
var
  SI: TStartupInfoW;
  PI: TProcessInformation;
  Cmd, DirW: WideString;
  Flags: DWORD;
  DirP: PWideChar;
begin
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  if AHidden then
  begin
    SI.dwFlags := STARTF_USESHOWWINDOW;
    SI.wShowWindow := SW_HIDE;
  end;
  FillChar(PI, SizeOf(PI), 0);
  Cmd := WideString(AmsQuoteArg(AExe));
  if AParams <> '' then Cmd := Cmd + ' ' + WideString(AParams);
  UniqueString(Cmd);
  DirW := WideString(ADir);
  if DirW <> '' then DirP := PWideChar(DirW) else DirP := nil;
  Flags := CREATE_BREAKAWAY;
  if AHidden then Flags := Flags or CREATE_NO_WINDOW;
  Result := CreateProcessW(nil, PWideChar(Cmd), nil, nil, False, Flags, nil,
                           DirP, SI, PI);
  if not Result then
  begin
    { Job ohne Erlaubnis zum Ausbrechen - dann eben ohne }
    Flags := Flags and not CREATE_BREAKAWAY;
    Result := CreateProcessW(nil, PWideChar(Cmd), nil, nil, False, Flags, nil,
                             DirP, SI, PI);
  end;
  if not Result then
    Exit(AmsFailFmt('Start fehlgeschlagen (%d): %s', [GetLastError, AExe]));
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
  AmsLogFmt('Gestartet (pid %d): %s', [PI.dwProcessId, string(Cmd)]);
end;

function AmsWaitProcessExit(APid: DWORD; ATimeoutMs: DWORD): Boolean;
var
  H: THandle;
begin
  H := OpenProcess(SYNCHRONIZE, False, APid);
  if H = 0 then Exit(True);      { gibt es nicht (mehr) }
  try
    Result := WaitForSingleObject(H, ATimeoutMs) = WAIT_OBJECT_0;
  finally
    CloseHandle(H);
  end;
end;

{ ---------------------------------------------------------------- Neustart - }

function PsQuote(const AText: string): string;
begin
  Result := '''' + StringReplace(AText, '''', '''''', [rfReplaceAll]) + '''';
end;

function Utf16Base64(const AText: WideString): string;
var
  Raw: string;
begin
  SetLength(Raw, Length(AText) * 2);
  if AText <> '' then Move(PWideChar(AText)^, Raw[1], Length(Raw));
  Result := AmsBase64Encode(Raw);
end;

function AmsRestartHost(AMainWnd: HWND; const AHelperExe: string): Boolean;
var
  Ini, Script, PsExe: string;
  L: TStringList;
begin
  Result := False;
  if AMainWnd = 0 then Exit(AmsFail('Neustart: kein Hauptfenster bekannt'));

  if (AHelperExe <> '') and FileExists(AHelperExe) then
  begin
    Ini := IncludeTrailingPathDelimiter(GetTempDir) +
           Format('AmsRestart_%d.ini', [GetCurrentProcessId]);
    L := TStringList.Create;
    try
      L.Add('[Restart]');
      L.Add('Pid=' + IntToStr(GetCurrentProcessId));
      L.Add('Exe=' + AmsHostExe);
      L.Add('Args=' + AmsHostArgs);
      L.Add('Dir=' + AmsHostDir);
      L.Add('Timeout=' + IntToStr(AmsRestartTimeoutS));
      try
        L.SaveToFile(Ini);
      except
        on E: Exception do
          Exit(AmsFailFmt('Neustart: %s nicht schreibbar (%s)', [Ini, E.Message]));
      end;
    finally
      L.Free;
    end;
    if not AmsStartDetached(AHelperExe, '--restart ' + AmsQuoteArg(Ini),
                            ExtractFilePath(AHelperExe)) then
      Exit;
  end
  else
  begin
    Script :=
      '$ErrorActionPreference=''SilentlyContinue'';' +
      '$p=Get-Process -Id ' + IntToStr(GetCurrentProcessId) + ';' +
      'if($p){if(-not $p.WaitForExit(' + IntToStr(AmsRestartTimeoutS * 1000) +
      ')){exit 2}};Start-Sleep -Milliseconds 700;' +
      'Start-Process -FilePath ' + PsQuote(AmsHostExe);
    if AmsHostArgs <> '' then
      Script := Script + ' -ArgumentList ' + PsQuote(AmsHostArgs);
    Script := Script + ' -WorkingDirectory ' + PsQuote(AmsHostDir);
    PsExe := AmsExpandEnv('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe');
    if not FileExists(PsExe) then PsExe := 'powershell.exe';
    if not AmsStartDetached(PsExe, '-NoProfile -NonInteractive ' +
         '-WindowStyle Hidden -EncodedCommand ' +
         Utf16Base64(WideString(Script)), AmsHostDir) then
      Exit;
  end;

  AmsLog('Neustart angefordert - Hauptfenster bekommt WM_CLOSE');
  PostMessageW(AMainWnd, WM_CLOSE, 0, 0);
  Result := True;
end;

function AmsRestartHelperRun(const AParamFile: string): Integer;
var
  Pid: DWORD;
  Exe, Args, Dir: string;
  Timeout: Integer;
begin
  if not FileExists(AParamFile) then Exit(1);
  Pid := DWORD(StrToIntDef(AmsIniValue(AParamFile, 'Pid', '0', 'Restart'), 0));
  Exe := AmsIniValue(AParamFile, 'Exe', '', 'Restart');
  Args := AmsIniValue(AParamFile, 'Args', '', 'Restart');
  Dir := AmsIniValue(AParamFile, 'Dir', '', 'Restart');
  Timeout := StrToIntDef(AmsIniValue(AParamFile, 'Timeout', '180', 'Restart'), 180);
  DeleteFile(AParamFile);
  if (Exe = '') or not FileExists(Exe) then Exit(3);
  if (Pid <> 0) and not AmsWaitProcessExit(Pid, DWORD(Timeout) * 1000) then
  begin
    AmsLogFmt('Neustart abgebrochen: Prozess %d lief nach %d s noch', [Pid, Timeout]);
    Exit(2);
  end;
  Sleep(700);
  if AmsStartDetached(Exe, Args, Dir, False) then Result := 0 else Result := 3;
end;

end.
