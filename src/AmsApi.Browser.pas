unit AmsApi.Browser;

{ ============================================================================
  AmsApi.Browser - eingebettete HTML-Ansicht als Win32-Kindfenster

  Zeigt eine HTML-Datei (etwa eine gerenderte README) in einem Kindfenster
  eines eigenen Win32-Fensters. Die VCL des Hosts steht einem FPC-Plugin
  nicht zur Verfuegung (getrennte Heaps, fremde RTL) - also auch kein
  TWebBrowser. Eingehaengt wird deshalb der Browser von Windows selbst, ueber
  das Steuerelement-Hosting von atl.dll:

    AtlAxWinInit                     meldet die Fensterklasse "AtlAxWin" an
    CreateWindow("AtlAxWin",         erzeugt den WebBrowser (Shell.Explorer)
                 "about:blank")      als Kindfenster und haengt ihn ein
    AtlAxGetControl                  liefert dessen IUnknown -> IDispatch
    Navigate, ReadyState,            spaet gebunden ueber IDispatch.Invoke -
    Document.title                   ohne Typbibliothek, ohne ComObj

  atl.dll wird dynamisch geladen und bleibt geladen: die Fensterprozedur von
  "AtlAxWin" liegt dort, nicht in diesem Modul.

  ERSATZ: Fehlt atl.dll, scheitert das Anlegen oder das Navigieren, wird die
  Ansicht ein schreibgeschuetztes, mehrzeiliges EDIT mit dem Ersatztext. Eine
  Ansicht darf nie daran scheitern, WOMIT sie anzeigt.

  LINKS: Jede Navigation, die nicht von ShowFile/ShowUrl/ShowText kommt
  (Klick, Meta-Refresh, neues Fenster), wird abgebrochen und ueber einen
  Timer nachgereicht - an OnLink, sonst gehen http(s)/mailto an den
  Standardbrowser. Bewusst NICHT aus dem Browser-Ereignis heraus: darin
  erneut zu navigieren oder einen Dialog zu zeigen, ist beim IE ein bekannter
  Absturzweg. Der IE11 ist ausserdem fuer heutige Webseiten zu alt; eine
  fremde Seite gehoert in den richtigen Browser.

  GLEITKOMMA: Solange eine Ansicht mit Browser lebt, sind die FPU- und
  SSE-Ausnahmen des Threads maskiert. Delphi (und FPC) schalten sie ab Werk
  scharf; MSHTML rechnet mit maskierten Ausnahmen und stuerzt sonst in
  eigenem Code ab. Mit der letzten Ansicht wird der alte Zustand
  zurueckgestellt - sofern ihn inzwischen niemand anders geaendert hat.

  PFLICHT beim Entladen: jede TAmsHtmlView freigeben. Ereignissenke und
  Link-Timer liegen in diesem Modul; die finalization raeumt nur noch als
  Notbremse auf.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

type
  { Minimales IDispatch fuer das spaete Binden. Eigene Deklaration, damit die
    Aufrufkonvention feststeht: die IID kommt per constref, also als Zeiger -
    so wie COM sie erwartet. }
  IAmsDispatch = interface(IUnknown)
    ['{00020400-0000-0000-C000-000000000046}']
    function GetTypeInfoCount(out ACount: Integer): HRESULT; stdcall;
    function GetTypeInfo(AIndex, ALocale: Integer;
      out AInfo: Pointer): HRESULT; stdcall;
    function GetIDsOfNames(constref AIid: TGUID; ANames: Pointer;
      ACount, ALocale: Integer; ADispIds: Pointer): HRESULT; stdcall;
    function Invoke(ADispId: Integer; constref AIid: TGUID; ALocale: Integer;
      AFlags: Word; AParams: Pointer;
      AResult, AExcepInfo, AArgErr: Pointer): HRESULT; stdcall;
  end;

  TAmsHtmlView = class;

  { Ein Link wurde angeklickt bzw. die Seite will woanders hin. Kommt
    verzoegert ueber einen Timer, nicht aus dem Browser-Ereignis - hier darf
    also navigiert und ein Dialog gezeigt werden.
    AHandled = False: http(s)/mailto/ftp gehen an den Standardbrowser,
    file:-Links werden in der Ansicht geoeffnet, alles andere verworfen.
    Wer hier die Ansicht freigibt, MUSS AHandled := True setzen. }
  TAmsHtmlLinkEvent = procedure(ASender: TAmsHtmlView; const AUrl: string;
    var AHandled: Boolean) of object;

  TAmsHtmlView = class
  private
    FParent: HWND;
    FId: Integer;
    FWnd: HWND;
    FBrowser: IAmsDispatch;
    FSink: IUnknown;
    FSinkObj: TObject;
    FPoint: IUnknown;
    FCookie: LongInt;
    FOleInit: Boolean;
    FFpuHeld: Boolean;
    FX, FY, FW, FH: Integer;
    FVisible: Boolean;
    FOwnPending: Boolean;
    FTempFiles: TStringList;
    FLinks: TStringList;
    FOnLink: TAmsHtmlLinkEvent;
    function CreateBrowser: Boolean;
    function TryCreateBrowser: Boolean;
    procedure CreateFallback;
    procedure DropBrowser;
    procedure SwitchToFallback(const AReason: string);
    function Navigate(const AUrl: string): Boolean;
    function TempHtml(const AText: WideString): string;
    procedure SetFallbackText(const AText: WideString);
    function Intercept(const AUrl: WideString): Boolean;
    procedure QueueLink(const AUrl: WideString);
    procedure FireNextLink;
  public
    { Kindfenster in AParent mit Control-ID AId. Versucht den Browser, sonst
      Ersatz-Textfeld. Startgroesse ist die Client-Flaeche von AParent. }
    constructor Create(AParent: HWND; AId: Integer);
    { COM frei + Fenster weg. PFLICHT vor dem Entladen des Moduls. }
    destructor Destroy; override;
    procedure SetBounds(X, Y, W, H: Integer);
    procedure SetVisible(AVisible: Boolean);
    { HTML-Datei anzeigen. True = der Browser laedt sie. False = nur der
      Ersatztext steht im Textfeld (ohne Browser oder Datei fehlt), die
      Ursache steht in AmsLastError. }
    function ShowFile(const AHtmlFile: string;
      const AFallbackText: WideString = ''): Boolean;
    { Beliebige URL im eingebetteten Browser. Ohne Browser steht die URL im
      Textfeld, Ergebnis False. }
    function ShowUrl(const AUrl: string): Boolean;
    { Klartext (z.B. "Lade README ...") - mit Browser als einfache HTML-Seite,
      deren Titel die erste Zeile ist; sonst im Textfeld. }
    procedure ShowText(const AText: WideString);
    { False = Ersatz-Textfeld aktiv }
    function IsBrowser: Boolean;
    { 4 = fertig geladen, -1 ohne Browser oder bei Fehler }
    function ReadyState: Integer;
    { '' bei Fehler oder ohne Browser }
    function DocumentTitle: WideString;
    { das Kindfenster (AtlAxWin oder EDIT) }
    function Handle: HWND;
    property OnLink: TAmsHtmlLinkEvent read FOnLink write FOnLink;
  end;

var
  { True schaltet den eingebetteten Browser ab - jede NEUE Ansicht wird dann
    das Ersatz-Textfeld. Fuer Tests und als Notschalter. }
  AmsBrowserDisabled: Boolean = False;

{ Ist der eingebettete Browser auf diesem Rechner nutzbar? (atl.dll +
  AtlAxWinInit, und nicht per AmsBrowserDisabled abgeschaltet) }
function AmsBrowserAvailable: Boolean;

{ Pfad -> file:///-URL. "\" wird "/", Leerzeichen, "#" und "%" werden
  kodiert, \\Server\Freigabe wird file://Server/Freigabe. Eine URL (mit
  "://" oder about:) kommt unveraendert zurueck. }
function AmsFileUrl(const APath: string): string;

implementation

uses
  AmsApi.Log, AmsApi.Http;

const
  VT_I2       = 2;
  VT_I4       = 3;
  VT_BSTR     = 8;
  VT_DISPATCH = 9;
  VT_BOOL     = 11;
  VT_VARIANT  = 12;
  VT_UI4      = 19;
  VT_INT      = 22;
  VT_BYREF    = $4000;

  DISPATCH_METHOD      = 1;
  DISPATCH_PROPERTYGET = 2;
  DISPATCH_PROPERTYPUT = 4;
  DISPID_PROPERTYPUT   = -3;

  DISPID_BEFORENAVIGATE2 = 250;
  DISPID_NEWWINDOW3      = 273;

  LOCALE_DEFAULT_USER = $0400;
  RPC_E_CHANGED_MODE  = HRESULT($80010106);
  E_NOTIMPL_          = HRESULT($80004001);

  DOCHOSTUIFLAG_NO3DBORDER      = $00000004;
  DOCHOSTUIFLAG_THEME           = $00040000;
  DOCHOSTUIFLAG_NO3DOUTERBORDER = $00200000;

  IID_NULL: TGUID = '{00000000-0000-0000-0000-000000000000}';
  DIID_DWebBrowserEvents2: TGUID = '{34A715A0-6587-11D0-924A-0020AFC7AC4D}';
  IID_IAxWinAmbientDispatch: TGUID = '{B6EA2051-048A-11D1-82B9-00C04FB9942E}';

  ATL_CLASS = 'AtlAxWin';
  TEMP_KEEP = 4;

type
  { VARIANT, 16 Byte: 8 Byte Kopf, 8 Byte Wert. }
  PAmsVar = ^TAmsVar;
  TAmsVar = packed record
    vt: Word;
    r1, r2, r3: Word;
    case Integer of
      0: (lVal: LongInt);
      1: (iVal: SmallInt);
      2: (bstrVal: PWideChar);
      3: (ptr: Pointer);
      4: (pad: Int64);
  end;
  TAmsVarArray = array[0..63] of TAmsVar;
  PAmsVarArray = ^TAmsVarArray;

  PAmsDispParams = ^TAmsDispParams;
  TAmsDispParams = record
    rgvarg: PAmsVarArray;
    rgdispidNamedArgs: Pointer;
    cArgs: LongWord;
    cNamedArgs: LongWord;
  end;

  IAmsConnectionPoint = interface(IUnknown)
    ['{B196B286-BAB4-101A-B69C-00AA00341D07}']
    function GetConnectionInterface(out AIid: TGUID): HRESULT; stdcall;
    function GetConnectionPointContainer(out ACpc: IUnknown): HRESULT; stdcall;
    function Advise(const ASink: IUnknown; out ACookie: LongInt): HRESULT; stdcall;
    function Unadvise(ACookie: LongInt): HRESULT; stdcall;
    function EnumConnections(out AEnum: IUnknown): HRESULT; stdcall;
  end;

  IAmsConnectionPointContainer = interface(IUnknown)
    ['{B196B284-BAB4-101A-B69C-00AA00341D07}']
    function EnumConnectionPoints(out AEnum: IUnknown): HRESULT; stdcall;
    function FindConnectionPoint(constref AIid: TGUID;
      out ACp: IAmsConnectionPoint): HRESULT; stdcall;
  end;

  { Die Ereignis-Schnittstelle des WebBrowsers ist eine reine dispinterface.
    Als Ableitung von IAmsDispatch mit eigener GUID findet GetInterface sie
    in der Schnittstellentabelle - QueryInterface muss nicht von Hand. }
  IAmsWebBrowserEvents2 = interface(IAmsDispatch)
    ['{34A715A0-6587-11D0-924A-0020AFC7AC4D}']
  end;

  TAmsBrowserSink = class(TInterfacedObject, IAmsDispatch, IAmsWebBrowserEvents2)
  private
    FView: TAmsHtmlView;
  public
    function GetTypeInfoCount(out ACount: Integer): HRESULT; stdcall;
    function GetTypeInfo(AIndex, ALocale: Integer;
      out AInfo: Pointer): HRESULT; stdcall;
    function GetIDsOfNames(constref AIid: TGUID; ANames: Pointer;
      ACount, ALocale: Integer; ADispIds: Pointer): HRESULT; stdcall;
    function Invoke(ADispId: Integer; constref AIid: TGUID; ALocale: Integer;
      AFlags: Word; AParams: Pointer;
      AResult, AExcepInfo, AArgErr: Pointer): HRESULT; stdcall;
  end;

  TAtlAxWinInit = function: BOOL; stdcall;
  TAtlAxGetUnk = function(AWnd: HWND; out AUnk: IUnknown): HRESULT; stdcall;

function xOleInitialize(AReserved: Pointer): HRESULT; stdcall;
  external 'ole32.dll' name 'OleInitialize';
procedure xOleUninitialize; stdcall;
  external 'ole32.dll' name 'OleUninitialize';
function xSysAllocString(S: PWideChar): PWideChar; stdcall;
  external 'oleaut32.dll' name 'SysAllocString';
procedure xSysFreeString(S: PWideChar); stdcall;
  external 'oleaut32.dll' name 'SysFreeString';
function xVariantClear(var V: TAmsVar): HRESULT; stdcall;
  external 'oleaut32.dll' name 'VariantClear';

var
  gAtl: HMODULE = 0;
  gAtlTried: Boolean = False;
  gAtlOk: Boolean = False;
  gAtlGetControl: TAtlAxGetUnk = nil;
  gAtlGetHost: TAtlAxGetUnk = nil;

  gViews: TList = nil;
  gLinkTimer: UINT_PTR = 0;
  gTempNo: Integer = 0;

  gFpuRefs: Integer = 0;
  gOld8087, gSet8087: Word;
  gOldMxcsr, gSetMxcsr: LongWord;

{ ------------------------------------------------------------------ atl.dll }

function AtlReady: Boolean;
var
  Init: TAtlAxWinInit;
begin
  if not gAtlTried then
  begin
    gAtlTried := True;
    try
      gAtl := LoadLibraryW('atl.dll');
      if gAtl <> 0 then
      begin
        Init := TAtlAxWinInit(GetProcAddress(gAtl, 'AtlAxWinInit'));
        gAtlGetControl := TAtlAxGetUnk(GetProcAddress(gAtl, 'AtlAxGetControl'));
        gAtlGetHost := TAtlAxGetUnk(GetProcAddress(gAtl, 'AtlAxGetHost'));
        gAtlOk := Assigned(Init) and Assigned(gAtlGetControl) and Init();
      end;
    except
      gAtlOk := False;
    end;
    if gAtlOk then
      AmsLog('Browser: atl.dll geladen, AtlAxWin angemeldet')
    else
      AmsLogFmt('Browser: atl.dll/AtlAxWinInit nicht verfuegbar (Modul %p)',
                [Pointer(gAtl)]);
  end;
  Result := gAtlOk;
end;

function AmsBrowserAvailable: Boolean;
begin
  Result := (not AmsBrowserDisabled) and AtlReady;
end;

{ --------------------------------------------------------------- Gleitkomma }

procedure FpuHold;
begin
  if gFpuRefs = 0 then
  begin
    gOld8087 := Get8087CW;
    gOldMxcsr := GetMXCSR;
    gSet8087 := gOld8087 or $003F;       { alle x87-Ausnahmen maskiert }
    gSetMxcsr := gOldMxcsr or $1F80;     { alle SSE-Ausnahmen maskiert }
    Set8087CW(gSet8087);
    SetMXCSR(gSetMxcsr);
  end;
  Inc(gFpuRefs);
end;

procedure FpuRelease;
begin
  if gFpuRefs <= 0 then Exit;
  Dec(gFpuRefs);
  if gFpuRefs > 0 then Exit;
  { Nur zuruecknehmen, was noch unser Stand ist - hat jemand anders den
    Zustand inzwischen geaendert, gilt seiner. }
  if Get8087CW = gSet8087 then Set8087CW(gOld8087);
  if GetMXCSR = gSetMxcsr then SetMXCSR(gOldMxcsr);
end;

{ ------------------------------------------------------------- Spaet binden }

function DispIdOf(const ADisp: IAmsDispatch; const AName: WideString;
  out AId: Integer): Boolean;
var
  N: PWideChar;
begin
  Result := False;
  AId := 0;
  if ADisp = nil then Exit;
  N := PWideChar(AName);
  try
    Result := ADisp.GetIDsOfNames(IID_NULL, @N, 1, LOCALE_DEFAULT_USER,
                                  @AId) >= 0;
  except
    Result := False;
  end;
end;

function DispCall(const ADisp: IAmsDispatch; const AName: WideString;
  AFlags: Word; AArgs: PAmsVar; ACount: Integer; AResult: PAmsVar): Boolean;
var
  Id, PutId: Integer;
  P: TAmsDispParams;
begin
  Result := False;
  if AResult <> nil then FillChar(AResult^, SizeOf(TAmsVar), 0);
  if not DispIdOf(ADisp, AName, Id) then Exit;
  FillChar(P, SizeOf(P), 0);
  P.rgvarg := PAmsVarArray(AArgs);
  P.cArgs := ACount;
  PutId := DISPID_PROPERTYPUT;
  if AFlags = DISPATCH_PROPERTYPUT then
  begin
    P.rgdispidNamedArgs := @PutId;
    P.cNamedArgs := 1;
  end;
  try
    Result := ADisp.Invoke(Id, IID_NULL, LOCALE_DEFAULT_USER, AFlags, @P,
                           AResult, nil, nil) >= 0;
  except
    Result := False;
  end;
end;

function DispGetInt(const ADisp: IAmsDispatch; const AName: WideString;
  out AValue: Integer): Boolean;
var
  R: TAmsVar;
begin
  AValue := 0;
  Result := DispCall(ADisp, AName, DISPATCH_PROPERTYGET, nil, 0, @R);
  if not Result then Exit;
  case R.vt of
    VT_I2, VT_BOOL:        AValue := R.iVal;
    VT_I4, VT_INT, VT_UI4: AValue := R.lVal;
  else
    Result := False;
  end;
  xVariantClear(R);
end;

function DispGetStr(const ADisp: IAmsDispatch; const AName: WideString;
  out AValue: WideString): Boolean;
var
  R: TAmsVar;
begin
  AValue := '';
  Result := DispCall(ADisp, AName, DISPATCH_PROPERTYGET, nil, 0, @R);
  if not Result then Exit;
  if R.vt = VT_BSTR then
    AValue := WideString(R.bstrVal)
  else
    Result := False;
  xVariantClear(R);
end;

function DispGetObj(const ADisp: IAmsDispatch; const AName: WideString;
  out AValue: IAmsDispatch): Boolean;
var
  R: TAmsVar;
begin
  AValue := nil;
  Result := DispCall(ADisp, AName, DISPATCH_PROPERTYGET, nil, 0, @R);
  if not Result then Exit;
  { Die Zuweisung zaehlt hoch, VariantClear gibt die Referenz des Ergebnisses
    wieder ab - unterm Strich genau eine, und die gehoert AValue. }
  if (R.vt = VT_DISPATCH) and (R.ptr <> nil) then
    AValue := IAmsDispatch(R.ptr)
  else
    Result := False;
  xVariantClear(R);
end;

function DispCallStr(const ADisp: IAmsDispatch;
  const AName, AArg: WideString): Boolean;
var
  A: TAmsVar;
begin
  FillChar(A, SizeOf(A), 0);
  A.vt := VT_BSTR;
  A.bstrVal := xSysAllocString(PWideChar(AArg));
  try
    Result := DispCall(ADisp, AName, DISPATCH_METHOD, @A, 1, nil);
  finally
    xSysFreeString(A.bstrVal);
  end;
end;

function DispPut(const ADisp: IAmsDispatch; const AName: WideString;
  AVt: Word; AValue: Integer): Boolean;
var
  A: TAmsVar;
begin
  FillChar(A, SizeOf(A), 0);
  A.vt := AVt;
  if AVt = VT_BOOL then A.iVal := SmallInt(AValue) else A.lVal := AValue;
  Result := DispCall(ADisp, AName, DISPATCH_PROPERTYPUT, @A, 1, nil);
end;

{ Text eines Ereignisarguments: BSTR direkt oder per Referenz, auch in
  einem VARIANT per Referenz (so kommt die URL in BeforeNavigate2). }
function VarText(const V: TAmsVar): WideString;
begin
  Result := '';
  case V.vt of
    VT_BSTR:
      Result := WideString(V.bstrVal);
    VT_BSTR or VT_BYREF:
      if V.ptr <> nil then Result := WideString(PPWideChar(V.ptr)^);
    VT_VARIANT or VT_BYREF:
      if V.ptr <> nil then Result := VarText(PAmsVar(V.ptr)^);
  end;
end;

{ VARIANT_BOOL per Referenz auf True - das "Cancel" der Ereignisse. }
procedure VarSetTrue(var V: TAmsVar);
begin
  if (V.vt = (VT_BOOL or VT_BYREF)) and (V.ptr <> nil) then
    PSmallInt(V.ptr)^ := -1;
end;

{ ----------------------------------------------------------- Ereignissenke - }

function TAmsBrowserSink.GetTypeInfoCount(out ACount: Integer): HRESULT; stdcall;
begin
  ACount := 0;
  Result := S_OK;
end;

function TAmsBrowserSink.GetTypeInfo(AIndex, ALocale: Integer;
  out AInfo: Pointer): HRESULT; stdcall;
begin
  AInfo := nil;
  Result := E_NOTIMPL_;
end;

function TAmsBrowserSink.GetIDsOfNames(constref AIid: TGUID; ANames: Pointer;
  ACount, ALocale: Integer; ADispIds: Pointer): HRESULT; stdcall;
begin
  Result := E_NOTIMPL_;
end;

function TAmsBrowserSink.Invoke(ADispId: Integer; constref AIid: TGUID;
  ALocale: Integer; AFlags: Word; AParams: Pointer;
  AResult, AExcepInfo, AArgErr: Pointer): HRESULT; stdcall;
var
  P: PAmsDispParams;
begin
  Result := S_OK;
  { Aus diesem Aufruf darf NIE eine Ausnahme heraus - er kommt aus dem IE. }
  try
    P := AParams;
    if (FView = nil) or (P = nil) or (P^.rgvarg = nil) then Exit;
    case ADispId of
      DISPID_BEFORENAVIGATE2:
        { (pDisp, URL, Flags, TargetFrameName, PostData, Headers, Cancel) -
          in rgvarg rueckwaerts: [5] = URL, [0] = Cancel. }
        if P^.cArgs >= 7 then
          if FView.Intercept(VarText(P^.rgvarg^[5])) then
            VarSetTrue(P^.rgvarg^[0]);
      DISPID_NEWWINDOW3:
        { (ppDisp, Cancel, dwFlags, bstrUrlContext, bstrUrl) -
          rueckwaerts: [3] = Cancel, [0] = URL. Nie ein eigenes IE-Fenster. }
        if P^.cArgs >= 5 then
        begin
          VarSetTrue(P^.rgvarg^[3]);
          FView.QueueLink(VarText(P^.rgvarg^[0]));
        end;
    end;
  except
    on E: Exception do AmsLog('Browser-Ereignis EXCEPTION: ' + E.Message);
  end;
end;

{ ----------------------------------------------------------- Link-Timer ---- }

procedure LinkTimerProc(AWnd: HWND; AMsg: UINT; AId: UINT_PTR;
  ATime: DWORD); stdcall;
var
  i: Integer;
  V: TAmsHtmlView;
begin
  if gLinkTimer <> 0 then
  begin
    KillTimer(0, gLinkTimer);
    gLinkTimer := 0;
  end;
  try
    i := 0;
    while (gViews <> nil) and (i < gViews.Count) do
    begin
      V := TAmsHtmlView(gViews[i]);
      if (V.FLinks <> nil) and (V.FLinks.Count > 0) then
      begin
        { Genau einer, danach neu schauen: OnLink darf Ansichten anlegen und
          freigeben, die Liste kann sich also unter uns aendern. }
        V.FireNextLink;
        Continue;
      end;
      Inc(i);
    end;
  except
    on E: Exception do AmsLog('Browser-Link EXCEPTION: ' + E.Message);
  end;
end;

procedure StartLinkTimer;
begin
  if gLinkTimer = 0 then
    gLinkTimer := SetTimer(0, 0, 10, @LinkTimerProc);
end;

{ ------------------------------------------------------------- Kleinkram -- }

function AmsFileUrl(const APath: string): string;
var
  S: string;
  i: Integer;
begin
  S := Trim(APath);
  if (Pos('://', S) > 0) or SameText(Copy(S, 1, 6), 'about:') then
    Exit(S);
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '\': Result := Result + '/';
      ' ': Result := Result + '%20';
      '#': Result := Result + '%23';
      '%': Result := Result + '%25';
    else
      Result := Result + S[i];
    end;
  if Copy(Result, 1, 2) = '//' then
    Result := 'file:' + Result               { \\Server\Freigabe }
  else
    Result := 'file:///' + Result;
end;

{ LF, CR und CRLF -> CRLF, wie ein EDIT es braucht. }
function ToCrlf(const AText: WideString): WideString;
var
  S, R: UnicodeString;
  i, n, k: Integer;
begin
  S := UnicodeString(AText);
  n := 0;
  for i := 1 to Length(S) do
    if (S[i] = #10) and not ((i > 1) and (S[i - 1] = #13)) then Inc(n)
    else if (S[i] = #13) and not ((i < Length(S)) and (S[i + 1] = #10)) then
      Inc(n);
  SetLength(R, Length(S) + n);
  k := 0;
  for i := 1 to Length(S) do
  begin
    if (S[i] = #10) and not ((i > 1) and (S[i - 1] = #13)) then
    begin
      Inc(k); R[k] := #13;
      Inc(k); R[k] := #10;
    end
    else if (S[i] = #13) and not ((i < Length(S)) and (S[i + 1] = #10)) then
    begin
      Inc(k); R[k] := #13;
      Inc(k); R[k] := #10;
    end
    else
    begin
      Inc(k); R[k] := S[i];
    end;
  end;
  Result := WideString(R);
end;

function HtmlEscape(const AText: UnicodeString): UnicodeString;
var
  i, n, k: Integer;

  procedure Put(const AWhat: UnicodeString);
  var
    j: Integer;
  begin
    for j := 1 to Length(AWhat) do
    begin
      Inc(k);
      Result[k] := AWhat[j];
    end;
  end;

begin
  n := 0;
  for i := 1 to Length(AText) do
    case AText[i] of
      '&': Inc(n, 5);
      '<', '>': Inc(n, 4);
      '"': Inc(n, 6);
    else
      Inc(n);
    end;
  SetLength(Result, n);
  k := 0;
  for i := 1 to Length(AText) do
    case AText[i] of
      '&': Put('&amp;');
      '<': Put('&lt;');
      '>': Put('&gt;');
      '"': Put('&quot;');
    else
      Inc(k);
      Result[k] := AText[i];
    end;
end;

function FirstLine(const AText: UnicodeString): UnicodeString;
var
  i: Integer;
begin
  Result := AText;
  for i := 1 to Length(AText) do
    if (AText[i] = #13) or (AText[i] = #10) then
    begin
      Result := Copy(AText, 1, i - 1);
      Break;
    end;
  if Length(Result) > 120 then Result := Copy(Result, 1, 120);
end;

{ ---------------------------------------------------------- TAmsHtmlView -- }

constructor TAmsHtmlView.Create(AParent: HWND; AId: Integer);
var
  R: TRect;
  Grund: string;
begin
  inherited Create;
  FParent := AParent;
  FId := AId;
  FVisible := True;
  FX := 0;
  FY := 0;
  FW := 100;
  FH := 100;
  if (AParent <> 0) and GetClientRect(AParent, R) and (R.Right > 0) and
     (R.Bottom > 0) then
  begin
    FW := R.Right;
    FH := R.Bottom;
  end;
  FTempFiles := TStringList.Create;
  FLinks := TStringList.Create;
  if gViews = nil then gViews := TList.Create;
  gViews.Add(Self);

  if CreateBrowser then
    AmsLog('Browser: Ansicht eingebettet (AtlAxWin)')
  else
  begin
    Grund := AmsLastError;
    CreateFallback;
    AmsLog('Browser: Ersatz-Textfeld - ' + Grund);
  end;
end;

destructor TAmsHtmlView.Destroy;
var
  i: Integer;
begin
  if gViews <> nil then gViews.Remove(Self);
  DropBrowser;
  if FTempFiles <> nil then
  begin
    for i := 0 to FTempFiles.Count - 1 do
      DeleteFile(FTempFiles[i]);
    FreeAndNil(FTempFiles);
  end;
  FreeAndNil(FLinks);
  if (gViews <> nil) and (gViews.Count = 0) then
  begin
    FreeAndNil(gViews);
    if gLinkTimer <> 0 then
    begin
      KillTimer(0, gLinkTimer);
      gLinkTimer := 0;
    end;
  end;
  inherited Destroy;
end;

function TAmsHtmlView.CreateBrowser: Boolean;
begin
  Result := False;
  try
    Result := TryCreateBrowser;
  except
    on E: Exception do AmsFail('Browser anlegen: ' + E.Message);
  end;
  if not Result then DropBrowser;
end;

function TAmsHtmlView.TryCreateBrowser: Boolean;
var
  Unk, HostUnk: IUnknown;
  Host: IAmsDispatch;
  Cpc: IAmsConnectionPointContainer;
  Cp: IAmsConnectionPoint;
  Sink: TAmsBrowserSink;
  Hr: HRESULT;
  Style: DWORD;
begin
  Result := False;
  if AmsBrowserDisabled then
    Exit(AmsFail('Browser abgeschaltet (AmsBrowserDisabled)'));
  if not AtlReady then
    Exit(AmsFail('atl.dll bzw. AtlAxWinInit nicht verfuegbar'));

  { Der IE braucht ein STA. Im Host ist OLE meist schon an (S_FALSE) - auch
    das zaehlt und wird im Destroy wieder abgegeben. }
  Hr := xOleInitialize(nil);
  if Hr = RPC_E_CHANGED_MODE then
    Exit(AmsFail('Thread ist MTA - eingebetteter Browser nicht moeglich'));
  if Hr < 0 then
    Exit(AmsFailFmt('OleInitialize fehlgeschlagen, HRESULT %.8x', [Hr]));
  FOleInit := True;

  FpuHold;
  FFpuHeld := True;

  Style := WS_CHILD or WS_CLIPCHILDREN or WS_CLIPSIBLINGS or WS_TABSTOP;
  if FVisible then Style := Style or WS_VISIBLE;
  FWnd := CreateWindowExW(0, ATL_CLASS, 'about:blank', Style, FX, FY, FW, FH,
    FParent, HMENU(FId), HInstance, nil);
  if FWnd = 0 then
    Exit(AmsFailFmt('AtlAxWin konnte nicht erzeugt werden, Fehler %d',
                    [GetLastError]));

  Unk := nil;
  if (gAtlGetControl(FWnd, Unk) < 0) or (Unk = nil) then
    Exit(AmsFail('AtlAxGetControl ohne Ergebnis - kein WebBrowser im Fenster'));
  if (Unk.QueryInterface(IAmsDispatch, FBrowser) < 0) or (FBrowser = nil) then
    Exit(AmsFail('WebBrowser liefert kein IDispatch'));

  { Kein 3D-Rand, Systemdarstellung, kein IE-Kontextmenue. Das muss vor der
    ersten eigenen Navigation stehen - der IE fragt es je Dokument ab.
    Geht es nicht, sieht es nur altmodischer aus. }
  HostUnk := nil;
  if Assigned(gAtlGetHost) and (gAtlGetHost(FWnd, HostUnk) >= 0) and
     (HostUnk <> nil) and
     (HostUnk.QueryInterface(IID_IAxWinAmbientDispatch, Host) >= 0) and
     (Host <> nil) then
  begin
    if not DispPut(Host, 'DocHostFlags', VT_I4, DOCHOSTUIFLAG_NO3DBORDER or
                   DOCHOSTUIFLAG_THEME or DOCHOSTUIFLAG_NO3DOUTERBORDER) then
      AmsLog('Browser: DocHostFlags nicht gesetzt');
    if not DispPut(Host, 'AllowContextMenu', VT_BOOL, 0) then
      AmsLog('Browser: AllowContextMenu nicht gesetzt');
  end
  else
    AmsLog('Browser: kein IAxWinAmbientDispatch - Standarddarstellung');

  { Ereignisse: ohne sie gibt es keine Linkbehandlung, angezeigt wird
    trotzdem. Deshalb kein Abbruch, nur ein Logeintrag. }
  if (Unk.QueryInterface(IAmsConnectionPointContainer, Cpc) >= 0) and
     (Cpc <> nil) and
     (Cpc.FindConnectionPoint(DIID_DWebBrowserEvents2, Cp) >= 0) and
     (Cp <> nil) then
  begin
    Sink := TAmsBrowserSink.Create;
    Sink.FView := Self;
    FSinkObj := Sink;
    FSink := Sink;
    if Cp.Advise(FSink, FCookie) >= 0 then
      FPoint := Cp
    else
    begin
      Sink.FView := nil;
      FSinkObj := nil;
      FSink := nil;
      AmsLog('Browser: Advise fehlgeschlagen - Links ohne Behandlung');
    end;
  end
  else
    AmsLog('Browser: keine DWebBrowserEvents2 - Links ohne Behandlung');

  Result := True;
end;

procedure TAmsHtmlView.DropBrowser;
var
  Cp: IAmsConnectionPoint;
begin
  try
    if FSinkObj <> nil then TAmsBrowserSink(FSinkObj).FView := nil;
    if (FPoint <> nil) and
       (FPoint.QueryInterface(IAmsConnectionPoint, Cp) >= 0) and
       (Cp <> nil) then
      Cp.Unadvise(FCookie);
  except
    on E: Exception do AmsLog('Browser Unadvise EXCEPTION: ' + E.Message);
  end;
  try
    Cp := nil;
    FPoint := nil;
    FSink := nil;
    FSinkObj := nil;
    { COM-Referenzen zuerst, dann das Fenster: der Host im AtlAxWin gibt
      beim WM_DESTROY seine eigene ab und baut den Browser ab. }
    FBrowser := nil;
  except
    on E: Exception do AmsLog('Browser Release EXCEPTION: ' + E.Message);
  end;
  if FWnd <> 0 then
  begin
    DestroyWindow(FWnd);
    FWnd := 0;
  end;
  if FOleInit then
  begin
    xOleUninitialize;
    FOleInit := False;
  end;
  if FFpuHeld then
  begin
    FpuRelease;
    FFpuHeld := False;
  end;
end;

procedure TAmsHtmlView.CreateFallback;
var
  Style: DWORD;
begin
  Style := WS_CHILD or WS_VSCROLL or WS_TABSTOP or ES_MULTILINE or
           ES_READONLY or ES_AUTOVSCROLL;
  if FVisible then Style := Style or WS_VISIBLE;
  FWnd := CreateWindowExW(WS_EX_CLIENTEDGE, 'EDIT', '', Style, FX, FY, FW, FH,
    FParent, HMENU(FId), HInstance, nil);
  if FWnd = 0 then
  begin
    AmsFailFmt('Ersatz-Textfeld konnte nicht erzeugt werden, Fehler %d',
               [GetLastError]);
    Exit;
  end;
  SendMessageW(FWnd, WM_SETFONT, WPARAM(GetStockObject(DEFAULT_GUI_FONT)), 1);
  { Ohne das schneidet ein EDIT bei 32K Zeichen ab - eine README ist laenger. }
  SendMessageW(FWnd, EM_SETLIMITTEXT, 0, 0);
end;

procedure TAmsHtmlView.SwitchToFallback(const AReason: string);
begin
  AmsLog('Browser: wechsle auf Ersatz-Textfeld - ' + AReason);
  DropBrowser;
  CreateFallback;
  AmsFail(AReason);
end;

procedure TAmsHtmlView.SetFallbackText(const AText: WideString);
var
  W: WideString;
begin
  if FWnd = 0 then Exit;
  W := ToCrlf(AText);
  SetWindowTextW(FWnd, PWideChar(W));
end;

function TAmsHtmlView.Navigate(const AUrl: string): Boolean;
begin
  Result := False;
  if FBrowser = nil then Exit;
  { Die naechste Navigation ist unsere - die Ereignissenke laesst sie durch. }
  FOwnPending := True;
  Result := DispCallStr(FBrowser, 'Navigate', WideString(AUrl));
  if not Result then
  begin
    FOwnPending := False;
    AmsFail('Browser: Navigate fehlgeschlagen fuer ' + AUrl);
  end;
end;

function TAmsHtmlView.TempHtml(const AText: WideString): string;
var
  S: UnicodeString;
  U: UTF8String;
  F: TFileStream;
  Name: string;
begin
  Result := '';
  Inc(gTempNo);
  Name := Format('%sAmsApi_htmlview_%d_%d.html',
    [IncludeTrailingPathDelimiter(GetTempDir), GetCurrentProcessId, gTempNo]);
  S := '<!DOCTYPE html>'#13#10'<html><head>' +
       '<meta http-equiv="X-UA-Compatible" content="IE=edge">' +
       '<meta charset="utf-8">' +
       '<title>' + HtmlEscape(FirstLine(UnicodeString(AText))) + '</title>' +
       '<style>body{font-family:"Segoe UI",Tahoma,sans-serif;font-size:10pt;' +
       'color:#555;margin:16px;white-space:pre-wrap}</style>' +
       '</head><body>' + HtmlEscape(UnicodeString(AText)) +
       '</body></html>'#13#10;
  U := UTF8Encode(S);
  try
    F := TFileStream.Create(Name, fmCreate);
    try
      if Length(U) > 0 then F.WriteBuffer(Pointer(U)^, Length(U));
    finally
      F.Free;
    end;
  except
    on E: Exception do
    begin
      AmsFail('Browser: Hilfsseite nicht schreibbar: ' + E.Message);
      Exit;
    end;
  end;
  FTempFiles.Add(Name);
  { Aeltere Hilfsseiten sind laengst gelesen - nur die letzten behalten. }
  while FTempFiles.Count > TEMP_KEEP do
  begin
    DeleteFile(FTempFiles[0]);
    FTempFiles.Delete(0);
  end;
  Result := Name;
end;

procedure TAmsHtmlView.SetBounds(X, Y, W, H: Integer);
begin
  FX := X;
  FY := Y;
  FW := W;
  FH := H;
  if FWnd <> 0 then MoveWindow(FWnd, X, Y, W, H, True);
end;

procedure TAmsHtmlView.SetVisible(AVisible: Boolean);
begin
  FVisible := AVisible;
  if FWnd = 0 then Exit;
  if AVisible then ShowWindow(FWnd, SW_SHOWNA) else ShowWindow(FWnd, SW_HIDE);
end;

function TAmsHtmlView.ShowFile(const AHtmlFile: string;
  const AFallbackText: WideString): Boolean;
var
  Grund: string;
begin
  Result := False;
  if not FileExists(AHtmlFile) then
  begin
    Grund := 'HTML-Datei fehlt: ' + AHtmlFile;
    if AFallbackText <> '' then ShowText(AFallbackText)
                           else ShowText(WideString(Grund));
    AmsFail(Grund);
    Exit;
  end;
  if FBrowser <> nil then
  begin
    if Navigate(AmsFileUrl(AHtmlFile)) then Exit(True);
    SwitchToFallback(AmsLastError);
  end
  else
    AmsFail('Kein eingebetteter Browser - Ersatztext angezeigt');
  if AFallbackText <> '' then
    SetFallbackText(AFallbackText)
  else
    SetFallbackText(WideString('HTML-Ansicht nicht verfuegbar.'#13#10 +
                               AHtmlFile));
end;

function TAmsHtmlView.ShowUrl(const AUrl: string): Boolean;
begin
  Result := False;
  if FBrowser <> nil then
  begin
    if Navigate(AUrl) then Exit(True);
    SwitchToFallback(AmsLastError);
  end
  else
    AmsFail('Kein eingebetteter Browser fuer ' + AUrl);
  SetFallbackText(WideString('Ohne eingebetteten Browser nicht darstellbar:'#13#10 +
                             AUrl));
end;

procedure TAmsHtmlView.ShowText(const AText: WideString);
var
  F: string;
begin
  if FBrowser <> nil then
  begin
    F := TempHtml(AText);
    if (F <> '') and Navigate(AmsFileUrl(F)) then Exit;
    SwitchToFallback(AmsLastError);
  end;
  SetFallbackText(AText);
end;

function TAmsHtmlView.IsBrowser: Boolean;
begin
  Result := FBrowser <> nil;
end;

function TAmsHtmlView.ReadyState: Integer;
var
  V: Integer;
begin
  Result := -1;
  if (FBrowser <> nil) and DispGetInt(FBrowser, 'ReadyState', V) then
    Result := V;
end;

function TAmsHtmlView.DocumentTitle: WideString;
var
  Doc: IAmsDispatch;
  T: WideString;
begin
  Result := '';
  if FBrowser = nil then Exit;
  if DispGetObj(FBrowser, 'Document', Doc) and (Doc <> nil) and
     DispGetStr(Doc, 'title', T) then
    Result := T;
end;

function TAmsHtmlView.Handle: HWND;
begin
  Result := FWnd;
end;

{ Aus BeforeNavigate2: True = abbrechen, die URL geht spaeter an OnLink. }
function TAmsHtmlView.Intercept(const AUrl: WideString): Boolean;
var
  U, Here: string;
  W: WideString;
  p, q: Integer;
begin
  Result := False;
  U := string(AUrl);
  { about:blank vom Anlegen und die Fehlerseiten des IE (res://) duerfen
    immer - auch ohne die Marke der eigenen Navigation zu verbrauchen. }
  if (U = '') or SameText(Copy(U, 1, 6), 'about:') or
     SameText(Copy(U, 1, 4), 'res:') then
    Exit;
  if FOwnPending then
  begin
    FOwnPending := False;
    Exit;
  end;
  { Sprungmarke innerhalb der angezeigten Seite. }
  p := Pos('#', U);
  if (p > 1) and DispGetStr(FBrowser, 'LocationURL', W) then
  begin
    Here := string(W);
    q := Pos('#', Here);
    if q > 0 then Here := Copy(Here, 1, q - 1);
    if SameText(Copy(U, 1, p - 1), Here) then Exit;
  end;
  QueueLink(AUrl);
  Result := True;
end;

procedure TAmsHtmlView.QueueLink(const AUrl: WideString);
begin
  if (AUrl = '') or (FLinks = nil) then Exit;
  FLinks.Add(string(AUrl));
  StartLinkTimer;
end;

procedure TAmsHtmlView.FireNextLink;
var
  U, L: string;
  Handled: Boolean;
begin
  U := FLinks[0];
  FLinks.Delete(0);
  AmsLog('Browser: Link ' + U);
  Handled := False;
  if Assigned(FOnLink) then
  try
    FOnLink(Self, U, Handled);
  except
    on E: Exception do
    begin
      AmsLog('OnLink EXCEPTION: ' + E.Message);
      Handled := True;
    end;
  end;
  { Die Ansicht kann im OnLink freigegeben worden sein - dann keinen Zugriff
    mehr auf Felder. Verglichen wird nur der Zeigerwert. }
  if Handled or (gViews = nil) or (gViews.IndexOf(Self) < 0) then Exit;
  L := LowerCase(U);
  if (Pos('http://', L) = 1) or (Pos('https://', L) = 1) or
     (Pos('mailto:', L) = 1) or (Pos('ftp://', L) = 1) then
    AmsOpenUrl(U)
  else if Pos('file:', L) = 1 then
    ShowUrl(U)
  else
    AmsLog('Browser: Link ohne Behandlung verworfen: ' + U);
end;

finalization
  { Notbremse: Ereignissenke und Timer liegen in diesem Modul. Ordentlich
    ist das Freigeben im BeforeUnload des Plugins. }
  try
    while (gViews <> nil) and (gViews.Count > 0) do
      TAmsHtmlView(gViews[gViews.Count - 1]).Free;
  except
  end;
  if gLinkTimer <> 0 then
  begin
    KillTimer(0, gLinkTimer);
    gLinkTimer := 0;
  end;
  FreeAndNil(gViews);

end.
