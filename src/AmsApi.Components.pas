unit AmsApi.Components;

{ ============================================================================
  AmsApi.Components - Fenster und VCL-Komponentenbaum des Hosts

  Zwei Wege in den Baum:
    Vcl.Controls.FindControl(HWND)  -> VCL-Objekt zu einem Fensterhandle
    TComponent.Components[]         -> Kinder einer Komponente

  Wichtig: viele AMS-Komponenten haengen NICHT am Hauptformular, sondern an
  Frames, die eigene Wurzeln sind. Wer nur ab dem Hauptformular sucht, findet
  sie nicht. AmsBuildRootList sammelt deshalb ueber alle Fenster des Prozesses
  die Owner-Ketten ein.

  Performance-Falle (echter Anwenderbefund): EnumChildWindows enumeriert
  bereits ALLE Nachfahren. Ein zusaetzlicher Aufruf je Kindfenster macht das
  Ganze quadratisch - 60 Sekunden statt Millisekunden. Deshalb genau ein
  EnumChildWindows pro Top-Level-Fenster.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{ Zeigerarithmetik ist hier die Aufgabe, nicht ein Versehen: VMT-Offsets und
  Delphi-Stringheader lassen sich nicht anders erreichen. Die beiden Hinweise
  dazu wuerden das Bauprotokoll nur zurauschen. }
{$WARN 4056 OFF}
{$WARN 4082 OFF}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types;

{ ---------------------------------------------------------------- Fenster - }

{ Groesstes sichtbares Top-Level-Fenster mit Titel im eigenen Prozess.
  So findet das Plugin das AMS-Hauptfenster, ohne den Host zu fragen. }
function AmsFindMainWindow: HWND;

function AmsWindowText(AHandle: HWND): string;
function AmsWindowClass(AHandle: HWND): string;

{ Fensterbaum protokollieren - VCL registriert seine Fensterklassen unter dem
  Delphi-Klassennamen, z.B. "TdxBarDockControl". }
procedure AmsDumpWindowTree(ARoot: HWND; ADest: TStrings; AMaxNodes: Integer = 400);

{ -------------------------------------------------------------- Komponenten }

{ VCL-Objekt zu einem Fensterhandle. nil, wenn das Fenster keiner VCL gehoert. }
function AmsControlOf(AHandle: HWND): Pointer;

{ Hauptformular von AMS (VCL-Objekt zum Hauptfenster). }
function AmsMainForm(AMainWnd: HWND): Pointer;

function AmsComponentCount(AComp: Pointer): Integer;
function AmsComponent(AComp: Pointer; AIndex: Integer): Pointer;

{ TComponent.FindComponent - sucht nur unter den DIREKTEN Kindern. }
function AmsFindComponent(ARoot: Pointer; const AName: string): Pointer;

{ Rekursiv unter ARoot nach Namen suchen, erster Treffer. }
function AmsFindComponentDeep(ARoot: Pointer; const AName: string;
  AMaxDepth: Integer = 8): Pointer;

{ Alle Komponenten mit diesem Namen unterhalb von ARoot einsammeln. }
procedure AmsCollectByName(ARoot: Pointer; const AName: string; AList: TList;
  AMaxDepth: Integer = 8);

{ Alle Wurzeln des Prozesses: fuer jedes Fenster das VCL-Objekt holen und
  dessen Owner-Kette hochlaufen. AList wird geleert und gefuellt. }
procedure AmsBuildRootList(AList: TList);

{ In allen Wurzeln nach einer Komponente mit diesem Namen suchen. }
function AmsFindAnywhere(const AName: string): Pointer;

{ Komponentenbaum protokollieren. AFilter leer = alles, sonst werden nur
  Eintraege ausgegeben, deren Name oder Klasse den Filter enthaelt. }
procedure AmsDumpComponents(ARoot: Pointer; ADest: TStrings;
  const AFilter: string = ''; AMaxDepth: Integer = 10;
  AMaxNodes: Integer = 20000);

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Log;

{ ---------------------------------------------------------------- Fenster - }

function AmsWindowText(AHandle: HWND): string;
var
  Buf: array[0..255] of WideChar;
begin
  Buf[0] := #0;
  if AHandle <> 0 then GetWindowTextW(AHandle, Buf, Length(Buf));
  Result := string(WideString(Buf));
end;

function AmsWindowClass(AHandle: HWND): string;
var
  Buf: array[0..255] of WideChar;
begin
  Buf[0] := #0;
  if AHandle <> 0 then GetClassNameW(AHandle, Buf, Length(Buf));
  Result := string(WideString(Buf));
end;

function EnumMainProc(AHandle: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Pid: DWORD;
  R, BR: TRect;
  Best: PHandle;
begin
  Result := True;
  Pid := 0;
  GetWindowThreadProcessId(AHandle, @Pid);
  if Pid <> GetCurrentProcessId then Exit;
  if not IsWindowVisible(AHandle) then Exit;
  if GetWindow(AHandle, GW_OWNER) <> 0 then Exit;
  if GetWindowTextLengthW(AHandle) = 0 then Exit;
  if not GetWindowRect(AHandle, R) then Exit;
  if (R.Right - R.Left < 400) or (R.Bottom - R.Top < 300) then Exit;
  Best := PHandle(AParam);
  if Best^ = 0 then
    Best^ := AHandle
  else if GetWindowRect(HWND(Best^), BR) then
    if Int64(R.Right - R.Left) * (R.Bottom - R.Top) >
       Int64(BR.Right - BR.Left) * (BR.Bottom - BR.Top) then
      Best^ := AHandle;
end;

function AmsFindMainWindow: HWND;
var
  Best: THandle;
begin
  Best := 0;
  EnumWindows(@EnumMainProc, LPARAM(@Best));
  Result := HWND(Best);
end;

procedure DumpWindows(AHandle: HWND; ADest: TStrings; ADepth: Integer;
  AMaxNodes: Integer; var ACount: Integer);
var
  C: HWND;
  R: TRect;
  Txt, Cls: string;
begin
  if (ADepth > 6) or (ACount > AMaxNodes) then Exit;
  C := GetWindow(AHandle, GW_CHILD);
  while (C <> 0) and (ACount <= AMaxNodes) do
  begin
    Inc(ACount);
    Cls := AmsWindowClass(C);
    Txt := AmsWindowText(C);
    if Length(Txt) > 40 then Txt := Copy(Txt, 1, 40) + '...';
    if GetWindowRect(C, R) then
      ADest.Add(Format('%s%-34s %5d x%4d  %s', [StringOfChar(' ', ADepth * 2),
        Cls, R.Right - R.Left, R.Bottom - R.Top, Txt]))
    else
      ADest.Add(StringOfChar(' ', ADepth * 2) + Cls);
    DumpWindows(C, ADest, ADepth + 1, AMaxNodes, ACount);
    C := GetWindow(C, GW_HWNDNEXT);
  end;
end;

procedure AmsDumpWindowTree(ARoot: HWND; ADest: TStrings; AMaxNodes: Integer);
var
  Cnt: Integer;
begin
  if ADest = nil then Exit;
  Cnt := 0;
  try
    DumpWindows(ARoot, ADest, 0, AMaxNodes, Cnt);
  except
  end;
end;

{ -------------------------------------------------------------- Komponenten }

function AmsControlOf(AHandle: HWND): Pointer;
begin
  Result := nil;
  if (AHandle = 0) or not AmsBindVcl then Exit;
  try
    Result := hcFindControl(AHandle);
  except
    Result := nil;
  end;
end;

function AmsMainForm(AMainWnd: HWND): Pointer;
begin
  Result := AmsControlOf(AMainWnd);
end;

function AmsComponentCount(AComp: Pointer): Integer;
begin
  Result := 0;
  if (AComp = nil) or not Assigned(hcGetComponentCount) then Exit;
  try
    Result := hcGetComponentCount(AComp);
  except
    Exit(0);
  end;
  { unplausible Werte heissen: der Zeiger war keine TComponent }
  if (Result < 0) or (Result > 4000) then Result := 0;
end;

function AmsComponent(AComp: Pointer; AIndex: Integer): Pointer;
begin
  Result := nil;
  if (AComp = nil) or not Assigned(hcGetComponent) then Exit;
  try
    Result := hcGetComponent(AComp, AIndex);
  except
    Result := nil;
  end;
end;

function AmsFindComponent(ARoot: Pointer; const AName: string): Pointer;
begin
  Result := nil;
  if (ARoot = nil) or (AName = '') or not AmsBindCore then Exit;
  try
    Result := hcFindComponent(ARoot, AmsStr(AName));
  except
    Result := nil;
  end;
end;

function FindDeep(ARoot: Pointer; const AName: string; ADepth,
  AMaxDepth: Integer): Pointer;
var
  i, n: Integer;
  C: Pointer;
begin
  Result := nil;
  if (ARoot = nil) or (ADepth > AMaxDepth) then Exit;
  n := AmsComponentCount(ARoot);
  for i := 0 to n - 1 do
  begin
    C := AmsComponent(ARoot, i);
    if C = nil then Continue;
    if SameText(AmsName(C), AName) then Exit(C);
    Result := FindDeep(C, AName, ADepth + 1, AMaxDepth);
    if Result <> nil then Exit;
  end;
end;

function AmsFindComponentDeep(ARoot: Pointer; const AName: string;
  AMaxDepth: Integer): Pointer;
begin
  Result := nil;
  if (AName = '') or not AmsBindCore then Exit;
  Result := AmsFindComponent(ARoot, AName);
  if Result = nil then
    Result := FindDeep(ARoot, AName, 0, AMaxDepth);
end;

procedure CollectNamed(ARoot: Pointer; const AName: string; AList: TList;
  ADepth, AMaxDepth: Integer);
var
  i, n: Integer;
  C: Pointer;
begin
  if (ARoot = nil) or (ADepth > AMaxDepth) or (AList.Count > 64) then Exit;
  n := AmsComponentCount(ARoot);
  for i := 0 to n - 1 do
  begin
    C := AmsComponent(ARoot, i);
    if C = nil then Continue;
    if SameText(AmsName(C), AName) then AList.Add(C);
    CollectNamed(C, AName, AList, ADepth + 1, AMaxDepth);
  end;
end;

procedure AmsCollectByName(ARoot: Pointer; const AName: string; AList: TList;
  AMaxDepth: Integer);
begin
  if (AList = nil) or (AName = '') or not AmsBindCore then Exit;
  CollectNamed(ARoot, AName, AList, 0, AMaxDepth);
end;

{ ------------------------------------------------------------- Wurzelliste - }

{ Die EnumWindows-Callbacks bekommen ihr Ziel nur ueber diese Globale.
  AmsBuildRootList ist damit NICHT reentrant und nicht threadsicher - es
  gehoert in den UI-Thread, so wie jeder andere Zugriff auf die VCL auch. }
var
  gRoots: TList = nil;          { nur waehrend AmsBuildRootList gesetzt }

procedure AddRoot(AComp: Pointer);
var
  i: Integer;
begin
  if (AComp = nil) or (gRoots = nil) or (gRoots.Count > 200) then Exit;
  for i := 0 to gRoots.Count - 1 do
    if gRoots[i] = AComp then Exit;
  gRoots.Add(AComp);
end;

{ Ein Fenster verarbeiten: VCL-Objekt holen, Owner-Kette merken.
  KEIN EnumChildWindows hier - siehe Unit-Kopf. }
function CollectWndProc(AHandle: HWND; AParam: LPARAM): BOOL; stdcall;
var
  C, Own: Pointer;
  Guard: Integer;
begin
  Result := True;
  if not Assigned(hcFindControl) then Exit;
  if (gRoots <> nil) and (gRoots.Count > 200) then Exit;
  try
    C := hcFindControl(AHandle);
  except
    Exit;
  end;
  if C = nil then Exit;
  Own := C;
  Guard := 0;
  while (Own <> nil) and (Guard < 12) do
  begin
    AddRoot(Own);
    try
      Own := PPointer(PtrUInt(Own) + ofsComponentOwner)^;
    except
      Break;
    end;
    Inc(Guard);
  end;
end;

function CollectTopProc(AHandle: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Pid: DWORD;
begin
  Result := True;
  Pid := 0;
  GetWindowThreadProcessId(AHandle, @Pid);
  if Pid <> GetCurrentProcessId then Exit;
  CollectWndProc(AHandle, 0);
  { genau einmal je Top-Level - erfasst rekursiv alle Nachfahren }
  EnumChildWindows(AHandle, @CollectWndProc, 0);
end;

procedure AmsBuildRootList(AList: TList);
begin
  if AList = nil then Exit;
  AList.Clear;
  if not AmsBindVcl then Exit;
  if gRoots <> nil then
  begin
    AmsLog('AmsBuildRootList: bereits aktiv - verschachtelter Aufruf ignoriert');
    Exit;
  end;
  gRoots := AList;
  try
    try
      EnumWindows(@CollectTopProc, 0);
    except
    end;
  finally
    gRoots := nil;
  end;
end;

function AmsFindAnywhere(const AName: string): Pointer;
var
  Roots: TList;
  i: Integer;
begin
  Result := nil;
  if (AName = '') or not AmsBindCore then Exit;
  Roots := TList.Create;
  try
    AmsBuildRootList(Roots);
    for i := 0 to Roots.Count - 1 do
    begin
      Result := AmsFindComponent(Roots[i], AName);
      if Result <> nil then Exit;
    end;
  finally
    Roots.Free;
  end;
end;

{ -------------------------------------------------------------- Diagnose -- }

procedure DumpComps(ARoot: Pointer; ADest: TStrings; const AFilter: string;
  ADepth, AMaxDepth, AMaxNodes: Integer; var ACount: Integer);
var
  i, n: Integer;
  C: Pointer;
  Nm, Cls: string;
begin
  if (ARoot = nil) or (ADepth > AMaxDepth) or (ACount > AMaxNodes) then Exit;
  n := AmsComponentCount(ARoot);
  for i := 0 to n - 1 do
  begin
    if ACount > AMaxNodes then Exit;
    C := AmsComponent(ARoot, i);
    if C = nil then Continue;
    Inc(ACount);
    Nm := AmsName(C);
    Cls := AmsClassName(C);
    if (AFilter = '') or (Pos(AFilter, Nm) > 0) or (Pos(AFilter, Cls) > 0) then
      ADest.Add(Format('%s%s [%s]',
        [StringOfChar(' ', ADepth * 2 + 4), Nm, Cls]));
    DumpComps(C, ADest, AFilter, ADepth + 1, AMaxDepth, AMaxNodes, ACount);
  end;
end;

procedure AmsDumpComponents(ARoot: Pointer; ADest: TStrings;
  const AFilter: string; AMaxDepth, AMaxNodes: Integer);
var
  Cnt: Integer;
begin
  if (ADest = nil) or not AmsBindCore then Exit;
  Cnt := 0;
  DumpComps(ARoot, ADest, AFilter, 0, AMaxDepth, AMaxNodes, Cnt);
  ADest.Add(Format('  besuchte Komponenten: %d', [Cnt]));
end;

end.
