unit AmsApi.Types;

{ ============================================================================
  AmsApi.Types - Typen, Konstanten und Host-Signaturen

  Diese Unit enthaelt ausschliesslich Deklarationen, keinen ausfuehrbaren Code.
  Sie ist die einzige Stelle, an der der ABI-Vertrag mit ASSFINET AMS.5
  festgeschrieben ist; alles Weitere baut darauf auf.

  Grundregel fuer die gesamte API:
    Ueber die Modulgrenze zum Host gehen nur Zeiger, Integer und Boolean.
    Niemals managed Typen (string, dynamische Arrays, Interfaces als Wert) -
    FPC und die Delphi-RTL haben getrennte Heaps.

  Aufrufkonvention durchgaengig Delphi-"register": EAX, EDX, ECX, dann Stack.
  Interface- und String-Rueckgaben laufen ueber ein verstecktes letztes
  Zeigerargument, NICHT ueber EAX.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows;

const
  { Version dieser Bibliothek }
  AMS_API_VERSION = '1.0.0';

  { ------------------------------------------------ DoCommand-Codes des Hosts
    Ermittelt aus dem TPluginManager. Bei pcInitBuSession und pcPluginUpdate
    ist AData die aktuelle TBuSession - vor dem Merken den Klassennamen
    pruefen, nicht blind speichern. }
  pcBuSessionUpdate    = 0;
  pcInitConcenter      = 1;
  pcExitConcenter      = 2;
  pcInitBuSession      = 3;
  pcInitInternePlugins = 4;
  pcPluginUpdate       = 5;

  AmsCommandNames: array[0..5] of string = (
    'pcBuSessionUpdate', 'pcInitConcenter', 'pcExitConcenter',
    'pcInitBuSession', 'pcInitInternePlugins', 'pcPluginUpdate');

  { ------------------------------------------------------ Delphi-VMT-Offsets }
  vmtClassName = -56;
  vmtTypeInfo  = -72;
  vmtIntfTable = -84;

  { TComponent-Felder: FOwner und FName liegen unmittelbar hinter dem VMT-Zeiger }
  ofsComponentOwner = 4;
  ofsComponentName  = 8;

  { TGraphic.LoadFromFile ist VMT-Slot 21. Ueber das VMT aufrufen, sonst
    greift bei abgeleiteten Klassen nur die BMP-Basisimplementierung. }
  vmtSlotLoadFromFile = $54;

  { IInterface._Release liegt auf Slot 2 der Interface-Vtable }
  vmtSlotRelease = 8;

  { Vcl.Graphics.TAlphaFormat }
  afIgnored       = 0;
  afDefined       = 1;
  afPremultiplied = 2;

  { Delphi-UnicodeString-Header (StrRec), Laenge 12 Byte vor den Zeichen:
      +0 CodePage (Word)   +2 ElemSize (Word)
      +4 RefCount (LongInt) +8 Length (LongInt) }
  DelphiStrHeaderSize = 12;
  DelphiCodePageUtf16 = 1200;

  { ------------------------------------------------------- Delphi-RTTI ----
    Aufbau von TTypeInfo, TTypeData und TPropInfo in 32-Bit-Delphi. Alle
    Records sind PACKED - es wird nirgends ausgerichtet, deshalb stimmen die
    Offsets byteweise. Hier steht nur, was AmsApi.Props wirklich anfasst. }

  { TTypeKind, Reihenfolge aus System.TypInfo (Delphi 10 Seattle).
    Der mangled Name von GetPropInfo nennt den Bereich 0..21 - passt. }
  tkUnknown = 0;  tkInteger = 1;  tkChar = 2;    tkEnumeration = 3;
  tkFloat = 4;    tkString = 5;   tkSet = 6;     tkClass = 7;
  tkMethod = 8;   tkWChar = 9;    tkLString = 10; tkWString = 11;
  tkVariant = 12; tkArray = 13;   tkRecord = 14; tkInterface = 15;
  tkInt64 = 16;   tkDynArray = 17; tkUString = 18; tkClassRef = 19;
  tkPointer = 20; tkProcedure = 21;

  { TTypeInfo:  Kind: Byte;  Name: ShortString;  danach TTypeData.
    TTypeData beginnt also bei 2 + Length(Name). }
  ofsTypeKind = 0;
  ofsTypeName = 1;

  { TTypeData bei tkClass:
      +0 ClassType: TClass   +4 ParentInfo: PPTypeInfo
      +8 PropCount: SmallInt (ALLE published properties, auch geerbte)
     +10 UnitName: ShortString }
  ofsClassPropCount = 8;

  { TTypeData bei tkEnumeration:
      +0 OrdType: Byte  +1 MinValue: Integer  +5 MaxValue: Integer
      +9 BaseType: PPTypeInfo  +13 NameList: ShortString[] }
  ofsEnumMinValue = 1;
  ofsEnumMaxValue = 5;
  ofsEnumNameList = 13;

  { TTypeData bei tkSet:  +0 OrdType: Byte  +1 CompType: PPTypeInfo }
  ofsSetCompType = 1;

  { TPropInfo:
      +0 PropType: PPTypeInfo    +4 GetProc     +8 SetProc
     +12 StoredProc  +16 Index   +20 Default   +24 NameIndex: SmallInt
     +26 Name: ShortString
    SetProc = nil heisst: nur lesbar. }
  ofsPropType    = 0;
  ofsPropGetProc = 4;
  ofsPropSetProc = 8;
  ofsPropName    = 26;

type
  { -------------------------------------------------------------- IPlugin
    GUID und Vtable-Reihenfolge sind aus dem Host disassembliert:
      +00 QueryInterface  +04 _AddRef          +08 _Release
      +0C SetPluginManager +10 SetPluginItem   +14 Loaded
      +18 UnloadQuery      +1C Unload          +20 DoCommand }
  IPlugin = interface
    ['{14DF4663-0C2D-4C29-A7EE-18BEA251C41D}']
    procedure SetPluginManager(AManager: Pointer);
    procedure SetPluginItem(AItem: Pointer);
    procedure Loaded;
    function  UnloadQuery: Boolean;
    procedure Unload;
    procedure DoCommand(ACmd: Integer; AData: Pointer);
  end;

  { Delphi-Methodenzeiger (TMethod). Wird an SetMethodProp uebergeben, um
    z.B. OnClick eines TdxBarItem zu belegen. }
  PDelphiMethod = ^TDelphiMethod;
  TDelphiMethod = record
    Code: Pointer;
    Data: Pointer;
  end;

  { --------------------------------------------- Signaturen der Host-Symbole
    Namen bewusst nah an der Delphi-Quelle gehalten. }

  { rtl - System.Classes }
  TFnFindComponent   = function (Self, AName: Pointer): Pointer; register;
  TFnGetClass        = function (AName: Pointer): Pointer; register;
  TFnGetCompCount    = function (Self: Pointer): Integer; register;
  TFnGetComp         = function (Self: Pointer; AIndex: Integer): Pointer; register;
  TFnCollGetCount    = function (Self: Pointer): Integer; register;
  TFnCollGetItem     = function (Self: Pointer; AIndex: Integer): Pointer; register;

  { rtl - System.TypInfo.
    ACHTUNG GetStrProp: EAX=Instance, EDX=PropName, ECX=@Result.
    Nicht EAX=@Result - falsch herum liefert es still Muell. }
  TFnGetStrProp      = procedure(AObj, APropName, AResult: Pointer); register;
  TFnSetStrProp      = procedure(AObj, APropName, AValue: Pointer); register;
  TFnGetOrdProp      = function (AObj, APropName: Pointer): Integer; register;
  TFnSetOrdProp      = procedure(AObj, APropName: Pointer; AValue: Integer); register;
  TFnSetMethodProp   = procedure(AObj, APropName, AMethod: Pointer); register;
  TFnGetObjectProp   = function (AObj, APropName, AMinClass: Pointer): Pointer; register;
  TFnUStrClr         = procedure(AStr: Pointer); register;

  { rtl - System.TypInfo, zweite Staffel: RTTI auslesen statt raten.
    GetPropInfo/GetPropInfos arbeiten auf dem PTypeInfo der KLASSE (VMT-72).
    GetPropInfos fuellt ein vom Aufrufer geliefertes Array - deshalb wird
    hier nichts im Delphi-Heap alloziert und nichts muss dort freigegeben
    werden. Das ist der Grund, warum GetPropList NICHT benutzt wird. }
  TFnGetPropInfo     = function (ATypeInfo, APropName: Pointer): Pointer; register;
  TFnGetPropInfos    = procedure(ATypeInfo, AList: Pointer); register;
  TFnIsPublishedProp = function (AObj, APropName: Pointer): Boolean; register;
  { Enum und Set als KLARTEXT - damit laesst sich "Visible := ivNever" oder
    "Font.Style := [fsBold]" aus einer INI-Zeile setzen.
    Ergebnisstrings kommen aus dem Delphi-Heap und muessen mit UStrClr
    freigegeben werden (AmsClearHostStr). }
  TFnGetEnumProp     = procedure(AObj, APropName, AResult: Pointer); register;
  TFnSetEnumProp     = procedure(AObj, APropName, AValue: Pointer); register;
  { GetSetProp hat drei echte Parameter, das versteckte @Result liegt daher
    auf dem Stack - EAX, EDX, CL, dann Stack. }
  TFnGetSetProp      = procedure(AObj, APropName: Pointer; ABrackets: Boolean;
                                 AResult: Pointer); register;
  TFnSetSetProp      = procedure(AObj, APropName, AValue: Pointer); register;
  { Ergebnis ist ein TMethod (8 Byte) -> ueber verstecktes @Result in ECX. }
  TFnGetMethodProp   = procedure(AObj, APropName, AResult: Pointer); register;

  { vcl }
  TFnFindControl     = function (AHandle: HWND): Pointer; register;
  TFnSetAlphaFormat  = procedure(Self: Pointer; AValue: Byte); register;
  TFnLoadFromFile    = procedure(Self, AFileName: Pointer); register;

  { afnUiCore - DevExpress ExpressBars }
  TFnBarAddItem      = function (Self, AClass: Pointer): Pointer; register;
  TFnBarGetItemLinks = function (Self: Pointer): Pointer; register;
  TFnBarLinksAdd     = function (Self, AItem: Pointer): Pointer; register;
  TFnLinkGetItem     = function (Self: Pointer): Pointer; register;
  TFnItemDirectClick = procedure(Self: Pointer); register;

  { afnComponentsRt - globale Action-/Event-Registry }
  TFnGetInstance     = function (AClass: Pointer): Pointer; register;
  TFnByName          = function (Self, AName: Pointer): Pointer; register;
  TFnActExecute      = procedure(Self, APacket, AUserData: Pointer); register;
  TFnEvtFire         = procedure(Self, APacket, AUserData: Pointer; AOptions: Byte); register;

  { afnBu - WorkflowEngine.
    WorkflowEngine() liefert ein Interface ueber das versteckte Ergebnis-
    argument in EDX. Als normale Funktion deklariert -> Access Violation. }
  TFnWorkflowEngine  = procedure(ASession: Pointer; AResult: PPointer); register;
  TFnGetTaskList     = function (Self: Pointer): Pointer; register;
  TFnFindTaskByName  = function (Self, AName: Pointer): Pointer; register;
  TFnTaskExecute     = procedure(Self, AItem, AWorkflow: Pointer); register;

  { IInterface._Release, stdcall wie bei COM }
  TFnIntfRelease     = function (Self: Pointer): Integer; stdcall;

  { --------------------------------------------------------- Callback-Typen }

  { Klick auf ein Ribbon-/Menue-Element. ASender ist der TdxBarItem-Zeiger des
    Hosts, ATag der beim Anlegen mitgegebene Wert. }
  TAmsClickEvent = procedure(ASender: Pointer; ATag: Integer) of object;

  { Ergebnis einer HTTP-Anfrage im Hintergrund. }
  TAmsHttpDoneEvent = procedure(ASuccess: Boolean; AStatus: Integer;
    const AResponse: string; ATag: Integer) of object;

implementation

end.
