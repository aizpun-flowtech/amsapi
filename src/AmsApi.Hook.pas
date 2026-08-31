unit AmsApi.Hook;

{ ============================================================================
  AmsApi.Hook - Aufrufe des Hosts abfangen

  Bisher konnte die API nur an EIGENEN Elementen mithoeren (AmsHookEvent in
  AmsApi.Ui setzt ein published Ereignis um). Fuer eine Aufzeichnung dessen,
  was AMS von sich aus tut - welche Action laeuft, welches SQL geht raus -
  reicht das nicht: diese Aufrufe gehen an keinem Ereignis vorbei.

  Drei Verfahren, absteigend nach Sicherheit. IMMER das oberste nehmen, das
  fuer den Fall funktioniert:

  1. IAT   - AmsHookImport. Ein Zeiger in der Importtabelle wird umgebogen.
             EIN ausgerichteter 4-Byte-Schreibvorgang, also atomar; es wird
             kein Code veraendert. Damit werden DLL-Funktionen gefangen,
             z.B. isc_dsql_prepare aus fbclient.dll.
  2. VMT   - AmsHookVmt. Ein Slot in der Klassentabelle wird umgebogen.
             Ebenfalls ein einzelner Zeiger, kein Code. Geht nur bei
             VIRTUELLEN Methoden und wirkt auf die Klasse samt Erben, die
             nicht selbst ueberschreiben.
  3. Detour- AmsHookCode. Die ersten Bytes der Zielfunktion werden durch
             einen Sprung ersetzt, das Original wandert in ein Trampolin.
             Der einzige Weg zu statischen Methoden wie
             TCustomDASQL.Execute - aber der riskanteste.

  Sicherheitsnetze beim Detour, jedes einzelne aus gutem Grund:

  * Der Laengendekoder RAET NICHT. Findet er eine Anweisung, die er nicht
    kennt, bricht er ab und schreibt die Bytes ins Log, statt eine halbe
    Anweisung ins Trampolin zu kopieren. Lieber kein Hook als ein Absturz.
  * Relative Sprunge (E8/E9/Jcc) werden nicht kopiert. Sie zeigen nach dem
    Umkopieren woanders hin. Steht am Anfang der Funktion ein Sprung, ist
    das ein Thunk - dem folgen wir und haengen uns ans echte Ziel.
  * Waehrend gepatcht wird, werden alle anderen Threads des Prozesses
    angehalten und ihr EIP geprueft. Steht einer mitten im Patchbereich,
    wird der Hook abgelehnt. AMS ist mehrthreadig; ohne das ist ein
    5-Byte-Patch ein Wuerfelspiel.
  * Beim Entladen MUSS AmsHookReleaseAll laufen. Ein stehengebliebener
    Detour ins entladene Modul ist ein sicherer Absturz - nicht
    "vielleicht", sondern beim naechsten Aufruf.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

const
  { E9 rel32 - der Sprung, den wir einbauen }
  AmsJmpSize = 5;
  { So viel Platz bekommt ein Trampolin: kopierte Bytes + Ruecksprung }
  AmsTrampolineSize = 32;

type
  TAmsHookKind = (hkCode, hkVmt, hkImport);

  { Ein Eintrag der Hookliste - fuer AmsHookReport und die Ruecknahme. }
  TAmsHookInfo = record
    Kind: TAmsHookKind;
    Target: Pointer;      { gepatchte Stelle bzw. Slot-Adresse }
    Detour: Pointer;      { wohin es jetzt geht }
    Original: Pointer;    { Trampolin (Code) bzw. alter Zeiger (Vmt/Import) }
    Name: string;         { Klartext fuers Log }
  end;

{ --------------------------------------------------------------- Detour --- }

{ Zielfunktion umbiegen. ATrampoline liefert die Adresse, ueber die das
  ORIGINAL weiter aufrufbar bleibt - der Detour muss sie benutzen, sonst
  faellt die Funktion des Hosts ersatzlos aus.
  False mit Klartext in AmsLastError, wenn nicht sicher patchbar. }
function AmsHookCode(ATarget, ADetour: Pointer; out ATrampoline: Pointer;
  const AName: string = ''): Boolean;

{ Dasselbe ueber ein exportiertes Symbol (AmsSym). Bequemer Normalfall:
    AmsHookSymbol('dac', '@Dbaccess@TCustomDASQL@Execute$qqrv', @MeinDetour, T) }
function AmsHookSymbol(const AModule, AName: string; ADetour: Pointer;
  out ATrampoline: Pointer): Boolean;

{ Einen einzelnen Detour zuruecknehmen. }
function AmsUnhookCode(ATarget: Pointer): Boolean;

{ ------------------------------------------------------------------ VMT --- }

{ Virtuelle Methode einer Delphi-Klasse umbiegen. ASlot ist der Byteoffset
  ab dem Klassenzeiger, wie ihn AmsVmtSlot benutzt (LoadFromFile = $54).
  AOld liefert die Originaladresse zum Weiterrufen. }
function AmsHookVmt(AClass: Pointer; ASlot: Integer; ANew: Pointer;
  out AOld: Pointer; const AName: string = ''): Boolean;

function AmsUnhookVmt(AClass: Pointer; ASlot: Integer): Boolean;

{ --------------------------------------------------------------- Import --- }

{ Importtabelle eines Moduls umbiegen: jeder Aufruf von ADll!AFunc aus
  AModule heraus landet ab jetzt bei ANew. AOld ist die Originaladresse. }
function AmsHookImport(AModule: HMODULE; const ADll, AFunc: string;
  ANew: Pointer; out AOld: Pointer): Boolean;

{ Dasselbe in ALLEN geladenen Modulen des Prozesses. Liefert die Anzahl der
  umgebogenen Eintraege. Das ist der Weg zu fbclient.dll: AMS ruft es aus
  mehreren Packages heraus auf, ein einzelnes Modul reicht nicht. }
function AmsHookImportEverywhere(const ADll, AFunc: string; ANew: Pointer;
  out AOld: Pointer): Integer;

{ ---------------------------------------------------------------- Sonst --- }

{ ALLES zuruecknehmen. Gehoert in jedes BeforeUnload - siehe Kopf. }
procedure AmsHookReleaseAll;

function AmsHookedCount: Integer;
function AmsHookInfo(AIndex: Integer; out AInfo: TAmsHookInfo): Boolean;
function AmsHookReport: string;

{ Laenge der Anweisung an ACode in Bytes, 0 wenn unbekannt oder relativ.
  Oeffentlich, weil die Unit-Tests den Dekoder ohne AMS pruefen. }
function AmsInsnLen(ACode: Pointer): Integer;

{ Folgt einem Sprungthunk (E9 rel32 / FF 25 [addr]) bis zur echten Funktion.
  Liefert ACode unveraendert, wenn dort kein Thunk steht. }
function AmsResolveThunk(ACode: Pointer): Pointer;

implementation

uses
  AmsApi.Log, AmsApi.Bind;

{ ------------------------------------------------------------- ToolHelp ----
  Die Windows-Unit von FPC kennt ToolHelp nicht, und der Umweg ueber
  jwatlhelp32 zoege das ganze JEDI-Paket herein. Fuenf Funktionen und zwei
  Records - die deklarieren wir selbst, wie den Rest des Host-ABIs auch. }

const
  TH32CS_SNAPTHREAD = $00000004;
  TH32CS_SNAPMODULE = $00000008;
  MAX_MODULE_NAME32 = 255;

type
  TThreadEntry32 = record
    dwSize: DWORD;
    cntUsage: DWORD;
    th32ThreadID: DWORD;
    th32OwnerProcessID: DWORD;
    tpBasePri: Longint;
    tpDeltaPri: Longint;
    dwFlags: DWORD;
  end;

  TModuleEntry32W = record
    dwSize: DWORD;
    th32ModuleID: DWORD;
    th32ProcessID: DWORD;
    GlblcntUsage: DWORD;
    ProccntUsage: DWORD;
    modBaseAddr: PByte;
    modBaseSize: DWORD;
    hModule: HMODULE;
    szModule: array[0..MAX_MODULE_NAME32] of WideChar;
    szExePath: array[0..MAX_PATH - 1] of WideChar;
  end;

function CreateToolhelp32Snapshot(dwFlags, th32ProcessID: DWORD): THandle;
  stdcall; external 'kernel32' name 'CreateToolhelp32Snapshot';
function Thread32First(hSnapshot: THandle; var lpte: TThreadEntry32): BOOL;
  stdcall; external 'kernel32' name 'Thread32First';
function Thread32Next(hSnapshot: THandle; var lpte: TThreadEntry32): BOOL;
  stdcall; external 'kernel32' name 'Thread32Next';
function Module32FirstW(hSnapshot: THandle; var lpme: TModuleEntry32W): BOOL;
  stdcall; external 'kernel32' name 'Module32FirstW';
function Module32NextW(hSnapshot: THandle; var lpme: TModuleEntry32W): BOOL;
  stdcall; external 'kernel32' name 'Module32NextW';

var
  gHooks: array of TAmsHookInfo;

{ ==========================================================================
  Laengendekoder

  Nur so viel x86, wie am Anfang einer Delphi-Funktion wirklich vorkommt.
  Alles andere liefert 0 - und 0 heisst "Finger weg", nicht "1 Byte".
  ========================================================================== }

{ Laenge des ModRM-Teils inklusive SIB und Displacement. }
function ModRmLen(P: PByte; AAddr16: Boolean): Integer;
var
  Md, Rm: Byte;
begin
  Md := (P^ shr 6) and 3;
  Rm := P^ and 7;
  Result := 1;
  if AAddr16 then
  begin
    { 16-Bit-Adressierung kommt in Delphi-Code nicht vor. Nicht raten. }
    if (Md = 0) and (Rm = 6) then Result := 3
    else if Md = 1 then Result := 2
    else if Md = 2 then Result := 3;
    Exit;
  end;
  if (Md <> 3) and (Rm = 4) then Inc(Result);        { SIB }
  case Md of
    0: if Rm = 5 then Inc(Result, 4)                 { disp32 absolut }
       else if (Rm = 4) and ((PByte(P + 1)^ and 7) = 5) then Inc(Result, 4);
    1: Inc(Result, 1);
    2: Inc(Result, 4);
  end;
end;

function AmsInsnLen(ACode: Pointer): Integer;
var
  P: PByte;
  Op: Byte;
  OpSize16, Addr16: Boolean;
  Len, ImmSize, Digit: Integer;
begin
  Result := 0;
  if ACode = nil then Exit;
  P := PByte(ACode);
  Len := 0;
  OpSize16 := False;
  Addr16 := False;

  { Praefixe - hoechstens vier, sonst stimmt etwas nicht }
  while Len < 4 do
  begin
    case P^ of
      $66: begin OpSize16 := True; Inc(P); Inc(Len); end;
      $67: begin Addr16 := True; Inc(P); Inc(Len); end;
      $F0, $F2, $F3, $2E, $36, $3E, $26, $64, $65:
           begin Inc(P); Inc(Len); end;
    else
      Break;
    end;
  end;

  Op := P^;
  ImmSize := 4;
  if OpSize16 then ImmSize := 2;

  case Op of
    { --- ohne Operanden --------------------------------------------------- }
    $40..$5F,             { inc/dec reg, push/pop reg }
    $90,                  { nop }
    $98, $99,             { cwde, cdq }
    $C3, $C9, $CC, $F8..$FD:
      Exit(Len + 1);

    { --- ModRM ohne Immediate --------------------------------------------- }
    $00..$03, $08..$0B, $10..$13, $18..$1B, $20..$23, $28..$2B,
    $30..$33, $38..$3B,
    $62, $63, $84..$8B, $8D, $8F,
    $D0..$D3,
    $FE, $FF:
      Exit(Len + 1 + ModRmLen(P + 1, Addr16));

    { --- ModRM + Immediate ------------------------------------------------ }
    $80, $6B, $C0, $C1, $C6:
      Exit(Len + 1 + ModRmLen(P + 1, Addr16) + 1);
    $81, $69, $C7:
      Exit(Len + 1 + ModRmLen(P + 1, Addr16) + ImmSize);
    $83:
      Exit(Len + 1 + ModRmLen(P + 1, Addr16) + 1);

    { --- F6/F7: nur /0 und /1 (test) haben ein Immediate ------------------ }
    $F6, $F7:
      begin
        Digit := (PByte(P + 1)^ shr 3) and 7;
        Result := Len + 1 + ModRmLen(P + 1, Addr16);
        if Digit <= 1 then
          if Op = $F6 then Inc(Result) else Inc(Result, ImmSize);
        Exit;
      end;

    { --- Immediate ohne ModRM --------------------------------------------- }
    $04, $0C, $14, $1C, $24, $2C, $34, $3C,      { op al, imm8 }
    $6A,                                          { push imm8 }
    $A8,                                          { test al, imm8 }
    $B0..$B7:                                     { mov r8, imm8 }
      Exit(Len + 2);

    $05, $0D, $15, $1D, $25, $2D, $35, $3D,      { op eax, imm32 }
    $68,                                          { push imm32 }
    $A9,                                          { test eax, imm32 }
    $B8..$BF:                                     { mov r32, imm32 }
      Exit(Len + 1 + ImmSize);

    $A0..$A3:                                     { mov al/eax, [moffs] }
      Exit(Len + 5);

    $C2:                                          { ret imm16 }
      Exit(Len + 3);

    { --- Zwei-Byte-Opcodes ------------------------------------------------ }
    $0F:
      begin
        case PByte(P + 1)^ of
          $1F,                                    { multibyte nop }
          $40..$4F,                               { cmovcc }
          $90..$9F,                               { setcc }
          $A3, $AB, $AF, $B0, $B1, $B6, $B7, $BE, $BF, $C0, $C1:
            Exit(Len + 2 + ModRmLen(P + 2, Addr16));
          $A4, $AC, $BA:                          { shld/shrd/bt imm8 }
            Exit(Len + 2 + ModRmLen(P + 2, Addr16) + 1);
          { 0F 80..8F ist ein relativer Sprung - siehe unten, 0 }
        end;
        Exit(0);
      end;
  end;

  { E8/E9/EB/Jcc/loop landen hier: relativ, also bewusst 0. }
  Result := 0;
end;

function AmsResolveThunk(ACode: Pointer): Pointer;
var
  P: PByte;
  Hops: Integer;
begin
  Result := ACode;
  Hops := 0;
  while (Result <> nil) and (Hops < 8) do
  begin
    P := PByte(Result);
    if P^ = $E9 then                       { jmp rel32 }
      Result := Pointer(PtrUInt(Result) + 5 + PtrUInt(PInteger(P + 1)^))
    else if (P^ = $FF) and (PByte(P + 1)^ = $25) then
    begin                                  { jmp [abs32] - Importthunk }
      if PPointer(PPointer(P + 2)^) = nil then Exit;
      Result := PPointer(PPointer(P + 2)^)^;
    end
    else
      Exit;
    Inc(Hops);
  end;
end;

{ ==========================================================================
  Threads anhalten

  Ein 5-Byte-Patch ist nicht atomar. Steht ein anderer Thread genau dort,
  fuehrt er nach dem Fortsetzen die zweite Haelfte einer Anweisung aus, die
  es nicht mehr gibt. Deshalb: anhalten, EIP pruefen, patchen, fortsetzen.
  ========================================================================== }

type
  TThreadList = record
    Handles: array of THandle;
    Count: Integer;
  end;

{ ZWEI DURCHGAENGE, und das ist kein Schoenheitsfehler:

  Zuerst werden alle Threads geoeffnet und die Handles eingesammelt - dabei
  waechst ein dynamisches Array, es wird also der Heap angefasst. ERST DANACH
  wird angehalten. Andersherum (anhalten und dabei das Array wachsen lassen)
  greift man in den Heap, waehrend moeglicherweise genau der Thread eingefroren
  ist, der dessen Sperre haelt. Solange nur die eigenen Hooks liefen, ist das
  gutgegangen; sobald die SQL-Detours haengen, laeuft staendig ein fremder
  Thread durch unseren Code - und dann ist es eine Frage von Sekunden.

  Zwischen SuspendOthers und ResumeOthers wird deshalb NICHTS alloziert,
  NICHTS formatiert und NICHTS protokolliert. }

function CollectOthers(var AList: TThreadList): Boolean;
var
  Snap: THandle;
  Te: TThreadEntry32;
  H: THandle;
  Pid, Me: DWORD;
begin
  AList.Count := 0;
  SetLength(AList.Handles, 0);
  Result := False;
  Pid := GetCurrentProcessId;
  Me := GetCurrentThreadId;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if Snap = INVALID_HANDLE_VALUE then Exit;
  try
    Te.dwSize := SizeOf(Te);
    if not Thread32First(Snap, Te) then Exit;
    repeat
      if (Te.th32OwnerProcessID <> Pid) or (Te.th32ThreadID = Me) then
        Continue;
      H := OpenThread(THREAD_SUSPEND_RESUME or THREAD_GET_CONTEXT, False,
                      Te.th32ThreadID);
      if H = 0 then Continue;
      SetLength(AList.Handles, AList.Count + 1);   { Heap - noch erlaubt }
      AList.Handles[AList.Count] := H;
      Inc(AList.Count);
    until not Thread32Next(Snap, Te);
    Result := True;
  finally
    CloseHandle(Snap);
  end;
end;

{ Ab hier kein Heap mehr. Nicht anhaltbare Threads bekommen das Handle 0. }
procedure SuspendCollected(var AList: TThreadList);
var
  i: Integer;
begin
  for i := 0 to AList.Count - 1 do
    if AList.Handles[i] <> 0 then
      if SuspendThread(AList.Handles[i]) = DWORD(-1) then
      begin
        CloseHandle(AList.Handles[i]);
        AList.Handles[i] := 0;
      end;
end;

procedure ResumeOthers(var AList: TThreadList);
var
  i: Integer;
begin
  { Erst alle fortsetzen ... }
  for i := 0 to AList.Count - 1 do
    if AList.Handles[i] <> 0 then ResumeThread(AList.Handles[i]);
  { ... dann aufraeumen. Das Freigeben des Arrays fasst den Heap an und
    gehoert deshalb hinter das letzte ResumeThread. }
  for i := 0 to AList.Count - 1 do
    if AList.Handles[i] <> 0 then CloseHandle(AList.Handles[i]);
  AList.Count := 0;
  SetLength(AList.Handles, 0);
end;

{ Steht einer der angehaltenen Threads im Bereich [AFrom, AFrom+ALen)? }
function AnyThreadInside(const AList: TThreadList; AFrom: Pointer;
  ALen: Integer): Boolean;
var
  i: Integer;
  Ctx: CONTEXT;
  Ip: PtrUInt;
begin
  Result := False;
  for i := 0 to AList.Count - 1 do
  begin
    if AList.Handles[i] = 0 then Continue;   { liess sich nicht anhalten }
    FillChar(Ctx, SizeOf(Ctx), 0);
    Ctx.ContextFlags := CONTEXT_CONTROL;
    if not GetThreadContext(AList.Handles[i], Ctx) then
    begin
      { Kein Kontext lesbar heisst: wir wissen es nicht. Im Zweifel Nein. }
      Exit(True);
    end;
    Ip := PtrUInt(Ctx.Eip);
    if (Ip >= PtrUInt(AFrom)) and (Ip < PtrUInt(AFrom) + PtrUInt(ALen)) then
      Exit(True);
  end;
end;

{ ==========================================================================
  Hookliste
  ========================================================================== }

function AddHook(AKind: TAmsHookKind; ATarget, ADetour, AOriginal: Pointer;
  const AName: string): Integer;
begin
  Result := Length(gHooks);
  SetLength(gHooks, Result + 1);
  gHooks[Result].Kind := AKind;
  gHooks[Result].Target := ATarget;
  gHooks[Result].Detour := ADetour;
  gHooks[Result].Original := AOriginal;
  gHooks[Result].Name := AName;
end;

function IndexOfHook(AKind: TAmsHookKind; ATarget: Pointer): Integer;
var
  i: Integer;
begin
  for i := 0 to High(gHooks) do
    if (gHooks[i].Kind = AKind) and (gHooks[i].Target = ATarget) then
      Exit(i);
  Result := -1;
end;

{ Ist AP einer UNSERER Detours? Wird gebraucht, weil AmsResolveThunk nach dem
  Patchen dem eigenen Sprung folgt: die Zielfunktion faengt dann mit E9 an,
  und "aufloesen" landet beim Detour statt beim Original. Ohne diese Probe
  wuerde ein zweiter Hook den eigenen Detour patchen statt abzulehnen. }
function IsOurDetour(AP: Pointer): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(gHooks) do
    if (gHooks[i].Kind = hkCode) and (gHooks[i].Detour = AP) then Exit(True);
  Result := False;
end;

procedure DeleteHook(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(gHooks)) then Exit;
  for i := AIndex to High(gHooks) - 1 do
    gHooks[i] := gHooks[i + 1];
  SetLength(gHooks, Length(gHooks) - 1);
end;

{ ==========================================================================
  Detour
  ========================================================================== }

{ Bytes schreiben, egal wie die Seite geschuetzt ist. }
function WriteCode(ADest: Pointer; const ASrc; ALen: Integer): Boolean;
var
  Old, Tmp: DWORD;
begin
  Result := False;
  if not VirtualProtect(ADest, ALen, PAGE_EXECUTE_READWRITE, @Old) then Exit;
  Move(ASrc, ADest^, ALen);
  VirtualProtect(ADest, ALen, Old, @Tmp);
  FlushInstructionCache(GetCurrentProcess, ADest, ALen);
  Result := True;
end;

function AmsHookCode(ATarget, ADetour: Pointer; out ATrampoline: Pointer;
  const AName: string): Boolean;
var
  Copied, L: Integer;
  Tramp: PByte;
  Jmp: array[0..4] of Byte;
  Threads: TThreadList;
  Bytes: string;
  i: Integer;
  Ok, Besetzt: Boolean;
begin
  ATrampoline := nil;
  Result := False;
  if (ATarget = nil) or (ADetour = nil) then
    Exit(AmsFail('Hook: Ziel oder Detour ist nil'));

  if IndexOfHook(hkCode, ATarget) >= 0 then
    Exit(AmsFailFmt('Hook: %s haengt bereits', [AName]));
  ATarget := AmsResolveThunk(ATarget);
  if IsOurDetour(ATarget) then
    Exit(AmsFailFmt('Hook: %s haengt bereits (der Sprung ist unserer)',
                    [AName]));
  if IndexOfHook(hkCode, ATarget) >= 0 then
    Exit(AmsFailFmt('Hook: %s haengt bereits', [AName]));

  { 1. Wie viele ganze Anweisungen brauchen wir fuer 5 Byte? }
  Copied := 0;
  while Copied < AmsJmpSize do
  begin
    L := AmsInsnLen(Pointer(PtrUInt(ATarget) + PtrUInt(Copied)));
    if L = 0 then
    begin
      Bytes := '';
      for i := 0 to 7 do
        Bytes := Bytes + IntToHex(PByte(PtrUInt(ATarget) + PtrUInt(i))^, 2) + ' ';
      Exit(AmsFailFmt('Hook %s: Anweisung bei +%d nicht dekodierbar (%s)- ' +
                      'nicht gepatcht', [AName, Copied, Bytes]));
    end;
    Inc(Copied, L);
    if Copied > AmsTrampolineSize - AmsJmpSize then
      Exit(AmsFailFmt('Hook %s: Prolog zu lang (%d Byte)', [AName, Copied]));
  end;

  { 2. Trampolin: Originalbytes + Ruecksprung hinter den Patch }
  Tramp := VirtualAlloc(nil, AmsTrampolineSize, MEM_COMMIT or MEM_RESERVE,
                        PAGE_EXECUTE_READWRITE);
  if Tramp = nil then
    Exit(AmsFailFmt('Hook %s: kein Speicher fuers Trampolin', [AName]));
  Move(ATarget^, Tramp^, Copied);
  PByte(Tramp + Copied)^ := $E9;
  PInteger(Tramp + Copied + 1)^ :=
    Integer(PtrUInt(ATarget) + PtrUInt(Copied)) -
    Integer(PtrUInt(Tramp) + PtrUInt(Copied) + 5);

  { 3. Patchen, waehrend niemand sonst laeuft }
  Jmp[0] := $E9;
  PInteger(@Jmp[1])^ :=
    Integer(PtrUInt(ADetour)) - Integer(PtrUInt(ATarget) + AmsJmpSize);

  { --- ab hier eingefroren: nichts allozieren, nichts loggen --- }
  Besetzt := False;
  Ok := False;
  CollectOthers(Threads);
  try
    SuspendCollected(Threads);
    Besetzt := AnyThreadInside(Threads, ATarget, Copied);
    if not Besetzt then Ok := WriteCode(ATarget, Jmp, AmsJmpSize);
  finally
    ResumeOthers(Threads);
  end;
  { --- aufgetaut, jetzt darf wieder geredet werden --- }

  if Besetzt then
  begin
    VirtualFree(Tramp, 0, MEM_RELEASE);
    Exit(AmsFailFmt('Hook %s: ein anderer Thread steht genau in der ' +
                    'Funktion - nicht gepatcht', [AName]));
  end;
  if not Ok then
  begin
    VirtualFree(Tramp, 0, MEM_RELEASE);
    Exit(AmsFailFmt('Hook %s: Speicher nicht beschreibbar', [AName]));
  end;

  ATrampoline := Tramp;
  AddHook(hkCode, ATarget, ADetour, Tramp, AName);
  AmsLogFmt('Hook (Code) %s: %p -> %p, %d Byte gerettet',
            [AName, ATarget, ADetour, Copied]);
  Result := True;
end;

function AmsHookSymbol(const AModule, AName: string; ADetour: Pointer;
  out ATrampoline: Pointer): Boolean;
var
  P: Pointer;
begin
  ATrampoline := nil;
  P := AmsSym(AModule, AName);
  if P = nil then
    Exit(AmsFailFmt('Hook: Symbol %s!%s nicht gefunden', [AModule, AName]));
  Result := AmsHookCode(P, ADetour, ATrampoline, AName);
end;

function AmsUnhookCode(ATarget: Pointer): Boolean;
var
  Idx, Copied, L: Integer;
  Tramp: PByte;
  Threads: TThreadList;
  Besetzt: Boolean;
begin
  { Es darf beides uebergeben werden: die Adresse, die gepatcht wurde, oder
    das Symbol, das noch auf einen Thunk davor zeigt. Nur nicht ueber den
    eigenen Sprung hinweg aufloesen - siehe IsOurDetour. }
  Idx := IndexOfHook(hkCode, ATarget);
  if Idx < 0 then
  begin
    Tramp := PByte(AmsResolveThunk(ATarget));
    if not IsOurDetour(Tramp) then Idx := IndexOfHook(hkCode, Tramp);
  end;
  if Idx < 0 then Exit(AmsFail('Hook: dieser Detour haengt nicht'));
  ATarget := gHooks[Idx].Target;
  Tramp := PByte(gHooks[Idx].Original);

  { Wie viel wurde gerettet? Steht im Trampolin bis zum Ruecksprung. }
  Copied := 0;
  while Copied < AmsTrampolineSize - 5 do
  begin
    if (PByte(Tramp + Copied)^ = $E9) and (Copied >= AmsJmpSize) then Break;
    L := AmsInsnLen(Pointer(PtrUInt(Tramp) + PtrUInt(Copied)));
    if L = 0 then Break;
    Inc(Copied, L);
  end;

  { Steht unser Sprung ueberhaupt noch? Hat jemand darueber gepatcht,
    waere Zurueckschreiben schlimmer als Stehenlassen. }
  if PByte(ATarget)^ <> $E9 then
  begin
    AmsLogFmt('Hook %s: fremder Patch an %p - Detour bleibt haengen',
              [gHooks[Idx].Name, ATarget]);
    DeleteHook(Idx);
    Exit(False);
  end;

  Besetzt := False;
  Result := False;
  CollectOthers(Threads);
  try
    SuspendCollected(Threads);
    Besetzt := AnyThreadInside(Threads, ATarget, Copied) or
               AnyThreadInside(Threads, Tramp, AmsTrampolineSize);
    if not Besetzt then Result := WriteCode(ATarget, Tramp^, Copied);
  finally
    ResumeOthers(Threads);
  end;

  if Besetzt then
  begin
    AmsLogFmt('Hook %s: Thread noch im Aufruf - Ruecknahme verschoben',
              [gHooks[Idx].Name]);
    Exit(False);
  end;
  if Result then
  begin
    { Das Trampolin wird BEWUSST nicht freigegeben: ein Thread, der gerade
      hineinspringt, waere sonst tot. Ein paar Seiten sind der Preis. }
    AmsLogFmt('Hook (Code) %s zurueckgenommen', [gHooks[Idx].Name]);
    DeleteHook(Idx);
  end;
end;

{ ==========================================================================
  VMT
  ========================================================================== }

function AmsHookVmt(AClass: Pointer; ASlot: Integer; ANew: Pointer;
  out AOld: Pointer; const AName: string): Boolean;
var
  Slot: PPointer;
  Old, Tmp: DWORD;
begin
  AOld := nil;
  if (AClass = nil) or (ANew = nil) then
    Exit(AmsFail('VMT-Hook: Klasse oder Ziel ist nil'));
  if (ASlot < 0) or (ASlot > 4096) or ((ASlot and 3) <> 0) then
    Exit(AmsFailFmt('VMT-Hook: Slot %d ist kein gueltiger Offset', [ASlot]));

  Slot := PPointer(PtrUInt(AClass) + PtrUInt(ASlot));
  if IndexOfHook(hkVmt, Slot) >= 0 then
    Exit(AmsFailFmt('VMT-Hook: Slot $%x haengt bereits', [ASlot]));

  if not VirtualProtect(Slot, SizeOf(Pointer), PAGE_READWRITE, @Old) then
    Exit(AmsFailFmt('VMT-Hook: Slot $%x nicht beschreibbar', [ASlot]));
  AOld := Slot^;
  { Ein ausgerichteter Zeigerschreibvorgang - atomar, keine Threadpause noetig. }
  Slot^ := ANew;
  VirtualProtect(Slot, SizeOf(Pointer), Old, @Tmp);

  AddHook(hkVmt, Slot, ANew, AOld, AName);
  AmsLogFmt('Hook (VMT) %s: Slot $%x %p -> %p', [AName, ASlot, AOld, ANew]);
  Result := True;
end;

function AmsUnhookVmt(AClass: Pointer; ASlot: Integer): Boolean;
var
  Slot: PPointer;
  Idx: Integer;
  Old, Tmp: DWORD;
begin
  if AClass = nil then Exit(False);
  Slot := PPointer(PtrUInt(AClass) + PtrUInt(ASlot));
  Idx := IndexOfHook(hkVmt, Slot);
  if Idx < 0 then Exit(AmsFail('VMT-Hook: dieser Slot haengt nicht'));
  Result := False;
  if not VirtualProtect(Slot, SizeOf(Pointer), PAGE_READWRITE, @Old) then Exit;
  { Nur zurueckschreiben, wenn noch UNSER Zeiger drinsteht. }
  if Slot^ = gHooks[Idx].Detour then
  begin
    Slot^ := gHooks[Idx].Original;
    Result := True;
  end
  else
    AmsLogFmt('Hook %s: fremder VMT-Eintrag - bleibt stehen',
              [gHooks[Idx].Name]);
  VirtualProtect(Slot, SizeOf(Pointer), Old, @Tmp);
  DeleteHook(Idx);
end;

{ ==========================================================================
  Importtabelle
  ========================================================================== }

type
  PImageImportDescriptor = ^TImageImportDescriptor;
  TImageImportDescriptor = record
    OriginalFirstThunk: DWORD;
    TimeDateStamp: DWORD;
    ForwarderChain: DWORD;
    Name: DWORD;
    FirstThunk: DWORD;
  end;

{ Adresse des IAT-Eintrags fuer ADll!AFunc in AModule, nil wenn nicht da. }
function FindImportSlot(AModule: HMODULE; const ADll, AFunc: string): PPointer;
var
  Dos: PImageDosHeader;
  Nt: PImageNtHeaders;
  Imp: PImageImportDescriptor;
  Base: PtrUInt;
  DllName: PAnsiChar;
  Thunk, OrigThunk: PPtrUInt;
  ByName: PAnsiChar;
  Rva: DWORD;
begin
  Result := nil;
  if AModule = 0 then Exit;
  Base := PtrUInt(AModule);
  Dos := PImageDosHeader(Base);
  if Dos^.e_magic <> IMAGE_DOS_SIGNATURE then Exit;
  Nt := PImageNtHeaders(Base + PtrUInt(Dos^._lfanew));
  if Nt^.Signature <> IMAGE_NT_SIGNATURE then Exit;
  Rva := Nt^.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
           .VirtualAddress;
  if Rva = 0 then Exit;

  Imp := PImageImportDescriptor(Base + Rva);
  while Imp^.Name <> 0 do
  begin
    DllName := PAnsiChar(Base + PtrUInt(Imp^.Name));
    if SameText(string(DllName), ADll) then
    begin
      Thunk := PPtrUInt(Base + PtrUInt(Imp^.FirstThunk));
      if Imp^.OriginalFirstThunk <> 0 then
        OrigThunk := PPtrUInt(Base + PtrUInt(Imp^.OriginalFirstThunk))
      else
        OrigThunk := Thunk;
      while OrigThunk^ <> 0 do
      begin
        { Nur nach Namen importierte Eintraege, keine Ordinalimporte }
        if (OrigThunk^ and $80000000) = 0 then
        begin
          ByName := PAnsiChar(Base + OrigThunk^ + 2);   { +2 = Hint ueberspringen }
          if SameText(string(ByName), AFunc) then
            Exit(PPointer(Thunk));
        end;
        Inc(OrigThunk);
        Inc(Thunk);
      end;
    end;
    Inc(Imp);
  end;
end;

function AmsHookImport(AModule: HMODULE; const ADll, AFunc: string;
  ANew: Pointer; out AOld: Pointer): Boolean;
var
  Slot: PPointer;
  Old, Tmp: DWORD;
begin
  AOld := nil;
  Slot := FindImportSlot(AModule, ADll, AFunc);
  if Slot = nil then
    Exit(AmsFailFmt('Import-Hook: %s!%s wird von diesem Modul nicht ' +
                    'importiert', [ADll, AFunc]));
  if IndexOfHook(hkImport, Slot) >= 0 then Exit(False);
  if not VirtualProtect(Slot, SizeOf(Pointer), PAGE_READWRITE, @Old) then
    Exit(AmsFailFmt('Import-Hook: %s!%s nicht beschreibbar', [ADll, AFunc]));
  AOld := Slot^;
  Slot^ := ANew;
  VirtualProtect(Slot, SizeOf(Pointer), Old, @Tmp);
  AddHook(hkImport, Slot, ANew, AOld, ADll + '!' + AFunc);
  Result := True;
end;

function AmsHookImportEverywhere(const ADll, AFunc: string; ANew: Pointer;
  out AOld: Pointer): Integer;
var
  Snap: THandle;
  Me: TModuleEntry32W;
  Old: Pointer;
begin
  Result := 0;
  AOld := nil;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId);
  if Snap = INVALID_HANDLE_VALUE then
  begin
    AmsFail('Import-Hook: Modulliste nicht lesbar');
    Exit;
  end;
  try
    Me.dwSize := SizeOf(Me);
    if not Module32FirstW(Snap, Me) then Exit;
    repeat
      if AmsHookImport(HMODULE(Me.modBaseAddr), ADll, AFunc, ANew, Old) then
      begin
        Inc(Result);
        { Alle Eintraege zeigen auf dieselbe Funktion; einer reicht als
          Rueckweg. Falls doch nicht: der erste gewinnt. }
        if AOld = nil then AOld := Old;
      end;
    until not Module32NextW(Snap, Me);
  finally
    CloseHandle(Snap);
  end;
  AmsClearError;
  if Result = 0 then
    AmsFailFmt('Import-Hook: %s!%s wird von keinem geladenen Modul ' +
               'importiert', [ADll, AFunc])
  else
    AmsLogFmt('Hook (Import) %s!%s in %d Modulen', [ADll, AFunc, Result]);
end;

{ ==========================================================================
  Ruecknahme und Bericht
  ========================================================================== }

procedure AmsHookReleaseAll;
var
  i: Integer;
  Slot: PPointer;
  Old, Tmp: DWORD;
begin
  { Von hinten nach vorn - DeleteHook schiebt die Liste zusammen. }
  for i := High(gHooks) downto 0 do
  begin
    case gHooks[i].Kind of
      hkCode:
        AmsUnhookCode(gHooks[i].Target);
      hkVmt, hkImport:
        begin
          Slot := PPointer(gHooks[i].Target);
          if VirtualProtect(Slot, SizeOf(Pointer), PAGE_READWRITE, @Old) then
          begin
            if Slot^ = gHooks[i].Detour then Slot^ := gHooks[i].Original
            else AmsLogFmt('Hook %s: fremder Eintrag - bleibt stehen',
                           [gHooks[i].Name]);
            VirtualProtect(Slot, SizeOf(Pointer), Old, @Tmp);
          end;
          if i <= High(gHooks) then DeleteHook(i);
        end;
    end;
  end;
  SetLength(gHooks, 0);
  AmsLog('Alle Hooks zurueckgenommen');
end;

function AmsHookedCount: Integer;
begin
  Result := Length(gHooks);
end;

function AmsHookInfo(AIndex: Integer; out AInfo: TAmsHookInfo): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex <= High(gHooks));
  if Result then AInfo := gHooks[AIndex];
end;

function AmsHookReport: string;
const
  KindName: array[TAmsHookKind] of string = ('Code', 'VMT ', 'IAT ');
var
  i: Integer;
begin
  if Length(gHooks) = 0 then Exit('Keine Hooks aktiv.');
  Result := Format('%d Hook(s):'#13#10, [Length(gHooks)]);
  for i := 0 to High(gHooks) do
    Result := Result + Format('  [%s] %-40s %p -> %p'#13#10,
      [KindName[gHooks[i].Kind], gHooks[i].Name,
       gHooks[i].Target, gHooks[i].Detour]);
end;

initialization
  SetLength(gHooks, 0);

finalization
  { Notbremse. Ein Detour ins entladene Modul ist ein sicherer Absturz -
    lieber hier noch aufraeumen, auch wenn das Plugin es vergessen hat. }
  if Length(gHooks) > 0 then AmsHookReleaseAll;

end.
