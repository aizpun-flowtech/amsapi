unit AmsApi.Bind;

{ ============================================================================
  AmsApi.Bind - Anbindung an die geladenen Host-Packages

  AMS.5 laedt seine Delphi-Packages selbst; wir binden ausschliesslich per
  GetModuleHandleW + GetProcAddress an das, was bereits im Prozess liegt.
  Es wird nichts nachgeladen und nichts installiert.

  Zwei Punkte, die der Prototyp noch nicht konnte:

  1. VERSIONSUNABHAENGIG. Der Suffix "230" (Delphi 10 Seattle) war an ~30
     Stellen fest verdrahtet. Hier wird er zur Laufzeit aus den geladenen
     Modulen ermittelt (rtl<NNN>.bpl). Mit der naechsten AMS-Version bricht
     damit nichts.

  2. GRUPPENWEISE. Wer nur HTTP oder nur das Ribbon braucht, soll nicht an
     einem fehlenden afnBu.bpl scheitern. Jede Gruppe bindet fuer sich, lazy
     und idempotent.

  Fehlende Symbole sind KEIN Absturz, sondern ein False mit Klartext im Log -
  genau daran ist das ScriptScheduler-Plugin des Herstellers zerbrochen.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, AmsApi.Types;

{ ------------------------------------------------------------- Modulzugriff }

{ Versionssuffix der Delphi-Runtime-Packages, z.B. "230". Leer, wenn keine
  Delphi-RTL im Prozess liegt (dann laeuft das Plugin ausserhalb von AMS). }
function AmsHostSuffix: string;

{ Delphi/RAD-Studio-Produktname zum Suffix, z.B. "10 Seattle". }
function AmsHostDelphiName: string;

{ Modulhandle. ABase ohne Endung ("rtl", "vcl", "dbrtl") bekommt den
  Versionssuffix angehaengt; ein Name mit Punkt ("afnBu.bpl") wird
  unveraendert benutzt. }
function AmsHostModule(const ABase: string): HMODULE;

{ Exportiertes Symbol holen. Liefert nil und protokolliert, wenn es fehlt. }
function AmsSym(const AModule, AName: string): Pointer;

{ Laeuft dieser Code ueberhaupt in einem AMS-Prozess? }
function AmsHostPresent: Boolean;

{ ------------------------------------------------------ Gruppenweise binden }

function AmsBindCore: Boolean;      { rtl: Classes + TypInfo   }
function AmsBindProps: Boolean;     { rtl: RTTI der properties }
function AmsBindVcl: Boolean;       { vcl: FindControl, Bitmap }
function AmsBindBars: Boolean;      { afnUiCore: dxBar         }
function AmsBindFactory: Boolean;   { rtl+vcl: Elemente anlegen }
function AmsBindAfn: Boolean;       { afnComponentsRt: Actions }
function AmsBindWorkflow: Boolean;  { afnBu: WorkflowEngine    }

{ Alles binden, was da ist. Liefert True, wenn Core und Vcl stehen - das ist
  das Minimum fuer jede Komponentensuche. }
function AmsBindAll: Boolean;

{ Kurzbericht ueber den Bindezustand, fuer das Log eines Plugins. }
function AmsBindReport: string;

var
  { --------------------------------------------------------- rtl<NNN>.bpl }
  hcFindComponent: TFnFindComponent = nil;
  hcGetClass: TFnGetClass = nil;
  hcGetComponentCount: TFnGetCompCount = nil;
  hcGetComponent: TFnGetComp = nil;
  hcCollectionCount: TFnCollGetCount = nil;
  hcCollectionItem: TFnCollGetItem = nil;
  hcGetStrProp: TFnGetStrProp = nil;
  hcSetStrProp: TFnSetStrProp = nil;
  hcGetOrdProp: TFnGetOrdProp = nil;
  hcSetOrdProp: TFnSetOrdProp = nil;
  hcSetMethodProp: TFnSetMethodProp = nil;
  hcGetObjectProp: TFnGetObjectProp = nil;
  hcUStrClr: TFnUStrClr = nil;

  { ------------------------------- rtl<NNN>.bpl, RTTI (Gruppe "Props") --- }
  hcGetPropInfo: TFnGetPropInfo = nil;
  hcGetPropInfos: TFnGetPropInfos = nil;
  hcIsPublishedProp: TFnIsPublishedProp = nil;
  hcGetEnumProp: TFnGetEnumProp = nil;
  hcSetEnumProp: TFnSetEnumProp = nil;
  hcGetSetProp: TFnGetSetProp = nil;
  hcSetSetProp: TFnSetSetProp = nil;
  hcGetMethodProp: TFnGetMethodProp = nil;

  { --------------------------------------------------------- vcl<NNN>.bpl }
  hcFindControl: TFnFindControl = nil;
  hcSetAlphaFormat: TFnSetAlphaFormat = nil;

  { ------------------------- rtl + vcl, Gruppe "Factory" (Elemente anlegen)
    Die beiden Klassenzeiger werden nicht aufgerufen. Sie werden gebraucht,
    um im VMT den Slot der virtuellen Methode zu SUCHEN: Konstruktor und
    TControl.SetParent muessen virtuell gerufen werden, sonst entsteht ein
    halb gebautes Objekt bzw. ein Bedienelement ohne Fenster. Welcher Slot
    das ist, haengt an der Delphi-Version - deshalb gesucht statt geraten
    (AmsVmtIndexOf). }
  hcComponentClass: Pointer = nil;          { TComponent          }
  hcComponentCreate: Pointer = nil;         { TComponent.Create   }
  hcControlClass: Pointer = nil;            { TControl            }
  hcControlSetParent: Pointer = nil;        { TControl.SetParent  }
  hcObjectFree: TFnObjectFree = nil;        { TObject.Free        }

  { ------------------------------------------------------- afnUiCore.bpl }
  hcBarAddItem: TFnBarAddItem = nil;
  hcBarGetItemLinks: TFnBarGetItemLinks = nil;
  hcBarLinksAdd: TFnBarLinksAdd = nil;
  hcLinkGetItem: TFnLinkGetItem = nil;
  hcItemDirectClick: TFnItemDirectClick = nil;
  hcBarGetBarManager: TFnGetBarManager = nil;

  { -------------------------------------------------- afnComponentsRt.bpl }
  hcActionManagerClass: Pointer = nil;
  hcActionManagerInstance: TFnGetInstance = nil;
  hcActionManagerGetActions: TFnByName = nil;
  hcActionExecute: TFnActExecute = nil;
  hcEventManagerClass: Pointer = nil;
  hcEventManagerInstance: TFnGetInstance = nil;
  hcEventManagerGetEvents: TFnByName = nil;
  hcEventFire: TFnEvtFire = nil;

  { ------------------------------------------------------------ afnBu.bpl }
  hcWorkflowEngine: TFnWorkflowEngine = nil;
  hcEngineGetTaskList: TFnGetTaskList = nil;
  hcTaskListFindByName: TFnFindTaskByName = nil;
  hcTaskExecuteNoCheck: TFnTaskExecute = nil;

const
  { Modulnamen ohne Versionssuffix bzw. mit fester Endung }
  MOD_RTL = 'rtl';
  MOD_VCL = 'vcl';
  MOD_BARS = 'afnUiCore.bpl';
  MOD_AFN  = 'afnComponentsRt.bpl';
  MOD_BU   = 'afnBu.bpl';

implementation

uses
  AmsApi.Log;

{ ---------------------------------------------------- Modul-Enumeration ---
  ToolHelp direkt deklariert, damit die Unit nicht von der Verfuegbarkeit
  der FPC-Unit tlhelp32 abhaengt und keine Namen kollidieren. }

const
  TH32CS_SNAPMODULE = $00000008;

type
  TAmsModuleEntry32W = record
    dwSize: DWORD;
    th32ModuleID: DWORD;
    th32ProcessID: DWORD;
    GlblcntUsage: DWORD;
    ProccntUsage: DWORD;
    modBaseAddr: PByte;
    modBaseSize: DWORD;
    hModule: HMODULE;
    szModule: array[0..255] of WideChar;
    szExePath: array[0..MAX_PATH - 1] of WideChar;
  end;

function AmsCreateToolhelp32Snapshot(dwFlags, th32ProcessID: DWORD): THandle;
  stdcall; external 'kernel32' name 'CreateToolhelp32Snapshot';
function AmsModule32FirstW(hSnapshot: THandle; var lpme: TAmsModuleEntry32W): BOOL;
  stdcall; external 'kernel32' name 'Module32FirstW';
function AmsModule32NextW(hSnapshot: THandle; var lpme: TAmsModuleEntry32W): BOOL;
  stdcall; external 'kernel32' name 'Module32NextW';

var
  gSuffix: string = '';
  gSuffixDone: Boolean = False;
  gCore: Integer = 0;        { 0 = offen, 1 = ok, -1 = gescheitert }
  gProps: Integer = 0;
  gVcl: Integer = 0;
  gBars: Integer = 0;
  gAfn: Integer = 0;
  gWorkflow: Integer = 0;
  gFactory: Integer = 0;

{ "rtl230.bpl" -> "230". Liefert '' wenn der Name nicht passt. }
function SuffixOfRtl(const AName: string): string;
var
  Base: string;
  i: Integer;
begin
  Result := '';
  if not SameText(ExtractFileExt(AName), '.bpl') then Exit;
  Base := ChangeFileExt(AName, '');
  if Length(Base) <= 3 then Exit;
  if not SameText(Copy(Base, 1, 3), 'rtl') then Exit;
  for i := 4 to Length(Base) do
    if not (Base[i] in ['0'..'9']) then Exit;
  Result := Copy(Base, 4, MaxInt);
end;

{ Suffix aus den geladenen Modulen lesen. Fallback: bekannte Suffixe probieren,
  falls ToolHelp im Prozess nicht funktioniert. }
function DetectSuffix: string;
const
  KNOWN: array[0..11] of string = (
    '230',                                   { 10 Seattle - AMS.5 heute }
    '240', '250', '260', '270', '280', '290', '300',
    '220', '210', '200', '190');
var
  Snap: THandle;
  Ent: TAmsModuleEntry32W;
  Name, S: string;
  i: Integer;
begin
  Result := '';
  Snap := AmsCreateToolhelp32Snapshot(TH32CS_SNAPMODULE, 0);
  if Snap <> INVALID_HANDLE_VALUE then
  try
    FillChar(Ent, SizeOf(Ent), 0);
    Ent.dwSize := SizeOf(Ent);
    if AmsModule32FirstW(Snap, Ent) then
      repeat
        Name := string(WideString(PWideChar(@Ent.szModule[0])));
        S := SuffixOfRtl(Name);
        if S <> '' then Exit(S);
        FillChar(Ent, SizeOf(Ent), 0);
        Ent.dwSize := SizeOf(Ent);
      until not AmsModule32NextW(Snap, Ent);
  finally
    CloseHandle(Snap);
  end;

  for i := Low(KNOWN) to High(KNOWN) do
    if GetModuleHandleW(PWideChar(WideString('rtl' + KNOWN[i] + '.bpl'))) <> 0 then
      Exit(KNOWN[i]);
end;

function AmsHostSuffix: string;
begin
  if not gSuffixDone then
  begin
    gSuffix := DetectSuffix;
    gSuffixDone := True;
    if gSuffix = '' then
      AmsLog('Host: keine Delphi-RTL im Prozess gefunden (laeuft ausserhalb von AMS?)')
    else
      AmsLogFmt('Host: Package-Suffix "%s" erkannt (%s)',
                [gSuffix, AmsHostDelphiName]);
  end;
  Result := gSuffix;
end;

function AmsHostDelphiName: string;
begin
  if gSuffix = '190' then Result := 'XE5'
  else if gSuffix = '200' then Result := 'XE6'
  else if gSuffix = '210' then Result := 'XE7'
  else if gSuffix = '220' then Result := 'XE8'
  else if gSuffix = '230' then Result := '10 Seattle'
  else if gSuffix = '240' then Result := '10.1 Berlin'
  else if gSuffix = '250' then Result := '10.2 Tokyo'
  else if gSuffix = '260' then Result := '10.3 Rio'
  else if gSuffix = '270' then Result := '10.4 Sydney'
  else if gSuffix = '280' then Result := '11 Alexandria'
  else if gSuffix = '290' then Result := '12 Athens'
  else if gSuffix = '' then Result := 'unbekannt'
  else Result := 'unbekannt (' + gSuffix + ')';
end;

function AmsHostModule(const ABase: string): HMODULE;
var
  Name, Sfx: string;
begin
  Result := 0;
  if ABase = '' then Exit;
  if Pos('.', ABase) > 0 then
    Name := ABase
  else
  begin
    Sfx := AmsHostSuffix;
    if Sfx = '' then Exit;
    Name := ABase + Sfx + '.bpl';
  end;
  Result := GetModuleHandleW(PWideChar(WideString(Name)));
end;

function AmsHostPresent: Boolean;
begin
  Result := AmsHostModule(MOD_RTL) <> 0;
end;

function AmsSym(const AModule, AName: string): Pointer;
var
  H: HMODULE;
begin
  Result := nil;
  H := AmsHostModule(AModule);
  if H = 0 then
  begin
    AmsLog('Modul nicht geladen: ' + AModule);
    Exit;
  end;
  Result := GetProcAddress(H, PChar(AName));
  if Result = nil then
    AmsLog('Symbol fehlt in ' + AModule + ': ' + AName);
end;

{ --------------------------------------------------------------- Gruppen -- }

function AmsBindCore: Boolean;
begin
  if gCore <> 0 then Exit(gCore = 1);

  hcFindComponent := TFnFindComponent(AmsSym(MOD_RTL,
    '@System@Classes@TComponent@FindComponent$qqrx20System@UnicodeString'));
  hcGetClass := TFnGetClass(AmsSym(MOD_RTL,
    '@System@Classes@GetClass$qqrx20System@UnicodeString'));
  hcGetComponentCount := TFnGetCompCount(AmsSym(MOD_RTL,
    '@System@Classes@TComponent@GetComponentCount$qqrv'));
  hcGetComponent := TFnGetComp(AmsSym(MOD_RTL,
    '@System@Classes@TComponent@GetComponent$qqri'));
  hcCollectionCount := TFnCollGetCount(AmsSym(MOD_RTL,
    '@System@Classes@TCollection@GetCount$qqrv'));
  hcCollectionItem := TFnCollGetItem(AmsSym(MOD_RTL,
    '@System@Classes@TCollection@GetItem$qqri'));
  hcGetStrProp := TFnGetStrProp(AmsSym(MOD_RTL,
    '@System@Typinfo@GetStrProp$qqrp14System@TObjectx20System@UnicodeString'));
  hcSetStrProp := TFnSetStrProp(AmsSym(MOD_RTL,
    '@System@Typinfo@SetStrProp$qqrp14System@TObjectx20System@UnicodeStringt2'));
  hcGetOrdProp := TFnGetOrdProp(AmsSym(MOD_RTL,
    '@System@Typinfo@GetOrdProp$qqrp14System@TObjectx20System@UnicodeString'));
  hcSetOrdProp := TFnSetOrdProp(AmsSym(MOD_RTL,
    '@System@Typinfo@SetOrdProp$qqrp14System@TObjectx20System@UnicodeStringi'));
  hcSetMethodProp := TFnSetMethodProp(AmsSym(MOD_RTL,
    '@System@Typinfo@SetMethodProp$qqrp14System@TObjectx20System@UnicodeStringrx14System@TMethod'));
  hcGetObjectProp := TFnGetObjectProp(AmsSym(MOD_RTL,
    '@System@Typinfo@GetObjectProp$qqrp14System@TObjectx20System@UnicodeStringp17System@TMetaClass'));
  hcUStrClr := TFnUStrClr(AmsSym(MOD_RTL, '@System@@UStrClr$qqrpv'));

  { GetOrdProp und UStrClr sind Komfort - ihr Fehlen darf die Gruppe nicht
    scheitern lassen. }
  Result := Assigned(hcFindComponent) and Assigned(hcGetClass) and
            Assigned(hcGetComponentCount) and Assigned(hcGetComponent) and
            Assigned(hcCollectionCount) and Assigned(hcCollectionItem) and
            Assigned(hcGetStrProp) and Assigned(hcSetStrProp) and
            Assigned(hcSetOrdProp) and Assigned(hcSetMethodProp) and
            Assigned(hcGetObjectProp);
  if Result then gCore := 1 else gCore := -1;
  AmsLog('Bind Core (rtl): ' + BoolToStr(Result, True));
end;

function AmsBindProps: Boolean;
begin
  if gProps <> 0 then Exit(gProps = 1);
  if not AmsBindCore then
  begin
    gProps := -1;
    Exit(False);
  end;

  { GetPropInfo/GetPropInfos arbeiten auf dem PTypeInfo der Klasse, nicht auf
    der Instanz - deshalb die Ueberladungen OHNE TTypeKinds-Set. Ein 3 Byte
    grosses Set wuerde Delphi als Referenz uebergeben; diesen Sonderfall
    braucht hier niemand. }
  hcGetPropInfo := TFnGetPropInfo(AmsSym(MOD_RTL,
    '@System@Typinfo@GetPropInfo$qqrp24System@Typinfo@TTypeInfox20System@UnicodeString'));
  hcGetPropInfos := TFnGetPropInfos(AmsSym(MOD_RTL,
    '@System@Typinfo@GetPropInfos$qqrp24System@Typinfo@TTypeInfop57System@%StaticArray$p24System@Typinfo@TPropInfoi$i16380$%'));
  hcIsPublishedProp := TFnIsPublishedProp(AmsSym(MOD_RTL,
    '@System@Typinfo@IsPublishedProp$qqrp14System@TObjectx20System@UnicodeString'));
  hcGetEnumProp := TFnGetEnumProp(AmsSym(MOD_RTL,
    '@System@Typinfo@GetEnumProp$qqrp14System@TObjectx20System@UnicodeString'));
  hcSetEnumProp := TFnSetEnumProp(AmsSym(MOD_RTL,
    '@System@Typinfo@SetEnumProp$qqrp14System@TObjectx20System@UnicodeStringt2'));
  hcGetSetProp := TFnGetSetProp(AmsSym(MOD_RTL,
    '@System@Typinfo@GetSetProp$qqrp14System@TObjectx20System@UnicodeStringo'));
  hcSetSetProp := TFnSetSetProp(AmsSym(MOD_RTL,
    '@System@Typinfo@SetSetProp$qqrp14System@TObjectx20System@UnicodeStringt2'));
  hcGetMethodProp := TFnGetMethodProp(AmsSym(MOD_RTL,
    '@System@Typinfo@GetMethodProp$qqrp14System@TObjectx20System@UnicodeString'));

  { GetPropInfo und GetPropInfos tragen die Gruppe: ohne sie gibt es keine
    Auskunft ueber Typ und Schreibbarkeit. Der Rest ist Komfort und wird
    einzeln geprueft, bevor er benutzt wird. }
  Result := Assigned(hcGetPropInfo) and Assigned(hcGetPropInfos);
  if Result then gProps := 1 else gProps := -1;
  AmsLog('Bind Props (rtl RTTI): ' + BoolToStr(Result, True));
end;

function AmsBindVcl: Boolean;
begin
  if gVcl <> 0 then Exit(gVcl = 1);
  hcFindControl := TFnFindControl(AmsSym(MOD_VCL,
    '@Vcl@Controls@FindControl$qqrp6HWND__'));
  hcSetAlphaFormat := TFnSetAlphaFormat(AmsSym(MOD_VCL,
    '@Vcl@Graphics@TBitmap@SetAlphaFormat$qqr25Vcl@Graphics@TAlphaFormat'));
  Result := Assigned(hcFindControl);
  if Result then gVcl := 1 else gVcl := -1;
  AmsLog('Bind Vcl: ' + BoolToStr(Result, True));
end;

{ Elemente anlegen: der virtuelle Konstruktor aus rtl und TControl.SetParent
  aus vcl. Beide werden ueber ihren VMT-Slot gerufen; hier wird nur die
  ADRESSE geholt, mit der sich der Slot spaeter suchen laesst. }
function AmsBindFactory: Boolean;
begin
  if gFactory <> 0 then Exit(gFactory = 1);
  if not (AmsBindCore and AmsBindVcl) then
  begin
    gFactory := -1;
    Exit(False);
  end;

  hcComponentClass := AmsSym(MOD_RTL, '@System@Classes@TComponent@');
  { Konstruktoren tragen im Package den Namen "$bctr", nicht "Create". }
  hcComponentCreate := AmsSym(MOD_RTL,
    '@System@Classes@TComponent@$bctr$qqrp25System@Classes@TComponent');
  hcObjectFree := TFnObjectFree(AmsSym(MOD_RTL, '@System@TObject@Free$qqrv'));
  hcControlClass := AmsSym(MOD_VCL, '@Vcl@Controls@TControl@');
  hcControlSetParent := AmsSym(MOD_VCL,
    '@Vcl@Controls@TControl@SetParent$qqrp24Vcl@Controls@TWinControl');

  Result := (hcComponentClass <> nil) and (hcComponentCreate <> nil) and
            Assigned(hcObjectFree) and (hcControlClass <> nil) and
            (hcControlSetParent <> nil);
  if Result then gFactory := 1 else gFactory := -1;
  AmsLog('Bind Factory (rtl+vcl): ' + BoolToStr(Result, True));
end;

function AmsBindBars: Boolean;
begin
  if gBars <> 0 then Exit(gBars = 1);
  hcBarAddItem := TFnBarAddItem(AmsSym(MOD_BARS,
    '@Dxbar@TdxBarManager@AddItem$qqrp17System@TMetaClass'));
  hcBarGetItemLinks := TFnBarGetItemLinks(AmsSym(MOD_BARS,
    '@Dxbar@TdxBar@GetItemLinks$qqrv'));
  hcBarLinksAdd := TFnBarLinksAdd(AmsSym(MOD_BARS,
    '@Dxbar@TdxBarItemLinks@Add$qqrp16Dxbar@TdxBarItem'));
  hcLinkGetItem := TFnLinkGetItem(AmsSym(MOD_BARS,
    '@Dxbar@TdxBarItemLink@GetItem$qqrv'));
  hcItemDirectClick := TFnItemDirectClick(AmsSym(MOD_BARS,
    '@Dxbar@TdxBarItem@DirectClick$qqrv'));
  { Nur fuer das Anlegen eigener Ribbon-Elemente noetig; sein Fehlen darf die
    Gruppe nicht scheitern lassen. }
  hcBarGetBarManager := TFnGetBarManager(AmsSym(MOD_BARS,
    '@Dxbar@TdxBar@GetBarManager$qqrv'));
  Result := Assigned(hcBarAddItem) and Assigned(hcBarGetItemLinks) and
            Assigned(hcBarLinksAdd) and Assigned(hcLinkGetItem) and
            Assigned(hcItemDirectClick);
  if Result then gBars := 1 else gBars := -1;
  AmsLog('Bind Bars (afnUiCore): ' + BoolToStr(Result, True));
end;

function AmsBindAfn: Boolean;
begin
  if gAfn <> 0 then Exit(gAfn = 1);
  hcActionManagerClass := AmsSym(MOD_AFN,
    '@Afnglobalevents@TafnActionManager@');
  hcActionManagerInstance := TFnGetInstance(AmsSym(MOD_AFN,
    '@Afnglobalevents@TafnActionManager@GetInstance$qqrv'));
  hcActionManagerGetActions := TFnByName(AmsSym(MOD_AFN,
    '@Afnglobalevents@TafnActionManager@GetActions$qqr20System@UnicodeString'));
  hcActionExecute := TFnActExecute(AmsSym(MOD_AFN,
    '@Afnglobalevents@TafnAction@Execute$qqrp30Afnglobalevents@TafnDataPacketpv'));
  hcEventManagerClass := AmsSym(MOD_AFN,
    '@Afnglobalevents@TafnEventManager@');
  hcEventManagerInstance := TFnGetInstance(AmsSym(MOD_AFN,
    '@Afnglobalevents@TafnEventManager@GetInstance$qqrv'));
  hcEventManagerGetEvents := TFnByName(AmsSym(MOD_AFN,
    '@Afnglobalevents@TafnEventManager@GetEvents$qqr20System@UnicodeString'));
  hcEventFire := TFnEvtFire(AmsSym(MOD_AFN,
    '@Afnglobalevents@TafnEvent@Fire$qqrp30Afnglobalevents@TafnDataPacketpv62System@%Set$35Afnglobalevents@TafnEventFireOptiont1$i0$t1$i0$%'));
  Result := (hcActionManagerClass <> nil) and Assigned(hcActionManagerInstance) and
            Assigned(hcActionManagerGetActions) and Assigned(hcActionExecute) and
            (hcEventManagerClass <> nil) and Assigned(hcEventManagerInstance) and
            Assigned(hcEventManagerGetEvents) and Assigned(hcEventFire);
  if Result then gAfn := 1 else gAfn := -1;
  AmsLog('Bind Afn (afnComponentsRt): ' + BoolToStr(Result, True));
end;

function AmsBindWorkflow: Boolean;
begin
  if gWorkflow <> 0 then Exit(gWorkflow = 1);
  hcWorkflowEngine := TFnWorkflowEngine(AmsSym(MOD_BU,
    '@Uifworkflowengine@WorkflowEngine$qqrxp17Bubase@TBuSession'));
  hcEngineGetTaskList := TFnGetTaskList(AmsSym(MOD_BU,
    '@Uifworkflowengine@TWorkflowEngine@GetTaskList$qqrv'));
  hcTaskListFindByName := TFnFindTaskByName(AmsSym(MOD_BU,
    '@Uifworkflowengine@TWorkflowTaskList@FindTaskByName$qqrx20System@UnicodeString'));
  hcTaskExecuteNoCheck := TFnTaskExecute(AmsSym(MOD_BU,
    '@Uifworkflowengine@TWorkflowTask@ExecuteWithoutCheck$qqrx69System@%DelphiInterface$42Uifworkflowengine@Interfaces@IWorkflowItem%x65System@%DelphiInterface$38Uifworkflowengine@Interfaces@IWorkflow%'));
  Result := Assigned(hcWorkflowEngine) and Assigned(hcEngineGetTaskList) and
            Assigned(hcTaskListFindByName) and Assigned(hcTaskExecuteNoCheck);
  if Result then gWorkflow := 1 else gWorkflow := -1;
  AmsLog('Bind Workflow (afnBu): ' + BoolToStr(Result, True));
end;

function AmsBindAll: Boolean;
begin
  Result := AmsBindCore;
  Result := AmsBindVcl and Result;
  AmsBindProps;
  AmsBindFactory;
  AmsBindBars;
  AmsBindAfn;
  AmsBindWorkflow;
end;

function AmsBindReport: string;

  function State(V: Integer): string;
  begin
    case V of
      1: Result := 'gebunden';
     -1: Result := 'FEHLT';
    else Result := 'nicht versucht';
    end;
  end;

begin
  Result := Format('AmsApi %s, Host-Suffix "%s" (%s)' + sLineBreak +
                   '  Core (rtl) .......... %s' + sLineBreak +
                   '  Props (rtl RTTI) .... %s' + sLineBreak +
                   '  Vcl ................. %s' + sLineBreak +
                   '  Factory (rtl+vcl) ... %s' + sLineBreak +
                   '  Bars (afnUiCore) .... %s' + sLineBreak +
                   '  Afn (Actions) ....... %s' + sLineBreak +
                   '  Workflow (afnBu) .... %s',
                   [AMS_API_VERSION, AmsHostSuffix, AmsHostDelphiName,
                    State(gCore), State(gProps), State(gVcl), State(gFactory),
                    State(gBars), State(gAfn), State(gWorkflow)]);
end;

end.
