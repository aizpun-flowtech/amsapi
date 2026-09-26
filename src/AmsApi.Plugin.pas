unit AmsApi.Plugin;

(* ============================================================================
  AmsApi.Plugin - Basisklasse und Export-Boilerplate

  Damit reduziert sich ein AMS-Plugin auf das, was es fachlich tut. Die Klasse
  uebernimmt:
    - IPlugin vollstaendig (inkl. korrekter AddRef-Semantik in PluginInit)
    - das Warten auf das AMS-Hauptfenster (beim Laden existiert es noch nicht;
      Reihenfolge im Host: AmsApplication StartUp -> Plugins -> UiSession
      StartUp - deshalb wird per Timer im Message-Loop des Hosts gepollt)
    - Auswertung von DoCommand und das Merken der TBuSession
    - optionales Subclassing des Hauptfensters und einen Win32-Notnagel-Button
    - sauberes Entladen: Timer weg, Fensterhook zurueck, OnClick der eigenen
      Ribbon-Elemente abgeklemmt

  Ein vollstaendiges Plugin sieht damit so aus:

    library HelloButton;
    {$MODE DELPHI}{$H+}
    uses Windows, AmsApi.Plugin;

    type
      THello = class(TAmsPlugin)
      protected
        procedure AfterMainWindow; override;
        procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
      end;

    procedure THello.AfterMainWindow;
    begin
      AddRibbonButton('Hallo', 'Zeigt eine Meldung', 'icon32.png');
    end;

    procedure THello.ButtonClick(ASender: Pointer; ATag: Integer);
    begin
      ShowInfo('Hallo aus dem Plugin');
    end;

    exports
      AmsPkgInitialize name 'Initialize',
      AmsPkgFinalize   name 'Finalize',
      AmsPluginInit    name 'PluginInit';

    begin
      AmsRegisterPlugin(THello);
    end.
  ============================================================================ *)

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types, AmsApi.Ribbon, AmsApi.Menus,
  AmsApi.Props, AmsApi.Ui, AmsApi.Factory;

type
  TAmsPlugin = class;
  TAmsPluginClass = class of TAmsPlugin;

  TAmsPlugin = class(TInterfacedObject, IPlugin)
  private
    FManager: Pointer;
    FItem: Pointer;
    FBuSession: Pointer;
    FMainWnd: HWND;
    FStarted: Boolean;
    FUnloaded: Boolean;
    FFallbackBtn: HWND;
    procedure AttachMainWindow(AWnd: HWND);
  protected
    { --------------------------------------------------- Ueberschreibbares }

    { Direkt nach dem Erzeugen der Instanz, noch ohne Hauptfenster.
      Guter Ort fuer Logdatei, Konfiguration, eigene Initialisierung. }
    procedure Startup; virtual;

    { Das AMS-Hauptfenster steht und die Host-Symbole sind gebunden.
      HIER gehoert der Ribbon-Einbau hin. Wird genau einmal gerufen. }
    procedure AfterMainWindow; virtual;

    { Standard-Klickbehandlung fuer AddRibbonButton ohne eigenen Handler. }
    procedure ButtonClick(ASender: Pointer; ATag: Integer); virtual;

    { Die BuSession hat gewechselt (Anmeldung, Mandantenwechsel). }
    procedure SessionChanged; virtual;

    { Jedes DoCommand des Hosts, nach der Standardauswertung. }
    procedure HostCommand(ACmd: Integer; AData: Pointer); virtual;

    { Vor dem Entladen. Eigene Ressourcen hier freigeben. }
    procedure BeforeUnload; virtual;

    { False verhindert das Entladen (UnloadQuery). Standard: True. }
    function CanUnload: Boolean; virtual;

    { True subclasst das Hauptfenster und leitet Nachrichten an
      WindowMessage weiter. Standard: False. }
    function WantsWindowHook: Boolean; virtual;

    { True erzeugt einen Win32-Button unten rechts im Hauptfenster, falls der
      Ribbon-Einbau scheitert. Standard: False. }
    function WantsFallbackButton: Boolean; virtual;

    { Nachricht des Hauptfensters. AHandled := True unterdrueckt die
      Weitergabe an den urspruenglichen Fensterprozess. }
    function WindowMessage(AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM;
      var AHandled: Boolean): LRESULT; virtual;

    { ------------------------------------------------------- Bequemlichkeit }
    procedure Log(const AText: string);
    procedure LogFmt(const AFormat: string; const AArgs: array of const);

    { Ursache des letzten fehlgeschlagenen API-Aufrufs, im Klartext.
      Damit muss ein einfaches Plugin nur AmsApi.Plugin einbinden. }
    function LastError: string;

    { Meldungen an den Anwender. Die Bibliothek selbst zeigt NIE einen Dialog -
      das passiert nur, wenn ein Plugin diese Methoden aufruft. }
    procedure ShowInfo(const AText: string);
    procedure ShowWarning(const AText: string);
    procedure ShowError(const AText: string);
    { Zeigt AmsLastError mit vorangestelltem Text. }
    procedure ShowLastError(const APrefix: string);
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { ------------------------------------------------------ IPlugin (Host) }
    procedure SetPluginManager(AManager: Pointer);
    procedure SetPluginItem(AItem: Pointer);
    procedure Loaded;
    function  UnloadQuery: Boolean;
    procedure Unload;
    procedure DoCommand(ACmd: Integer; AData: Pointer);

    { ----------------------------------------------------------- Zustand -- }
    property PluginManager: Pointer read FManager;
    property PluginItem: Pointer read FItem;
    { TBuSession der aktuellen Anmeldung, nil vor dem Login. }
    property BuSession: Pointer read FBuSession;
    property MainWindow: HWND read FMainWnd;
    property Started: Boolean read FStarted;

    { --------------------------------------------------------- Aktionen --- }

    { Schaltflaeche in der Ribbon-Gruppe "Benutzerdefiniert". Ohne eigenen
      Handler landet der Klick in ButtonClick. Liefert das TdxBarItem oder
      nil; die Ursache steht dann in AmsLastError. }
    function AddRibbonButton(const ACaption: string; const AHint: string = '';
      const AGlyphFile: string = ''; ATag: Integer = 0): Pointer;
    function AddRibbonButtonEx(const AOptions: TAmsRibbonOptions): Pointer;

    { Automatismus im aktuellen Kontext starten bzw. auflisten. }
    function RunAutomatismus(const ACaption: string): Boolean;
    { Wie RunAutomatismus, liefert zusaetzlich die im Kontext angebotenen
      Automatismen - damit laesst sich eine brauchbare Meldung bauen, ohne
      die Suche zweimal zu fahren. }
    function RunAutomatismusEx(const ACaption: string;
      AAvailable: TStrings): Boolean;
    function ListAutomatismen(ACaptions: TStrings): Integer;

    { Benannte Action / Event aus der globalen Registry. }
    function RunAction(const AName: string): Boolean;
    function FireEvent(const AName: string): Boolean;

    { ------------------------------------------- Vorhandene Elemente ---
      Alles Weitere steht in AmsApi.Ui; das hier ist die Kurzschreibweise
      fuer den haeufigsten Fall. Jede Aenderung wird mitgeschrieben und
      beim Entladen automatisch zurueckgenommen. }

    { Element ueber Name ODER Beschriftung suchen. }
    function FindElement(const ANameOrCaption: string;
      out AElement: TAmsElement): Boolean;
    function FindElements(const AFilter: TAmsElementFilter;
      var AList: TAmsElementArray): Integer;

    { Beliebige Eigenschaft setzen: SetElement('bbNeu', 'Enabled', '0'),
      SetElement('Speichern', 'Font.Style', '[fsBold]'). }
    function SetElement(const ANameOrCaption, APropPath,
      AValue: string): Boolean;

    function EnableElement(const ANameOrCaption: string;
      AEnabled: Boolean): Boolean;
    function ShowElement(const ANameOrCaption: string;
      AVisible: Boolean): Boolean;
    { Beschriftung aendern - nicht der Komponentenname. }
    function RenameElement(const ANameOrCaption, ANewCaption: string): Boolean;

    { Abschnitt der plugin.ini als Patchliste anwenden:
        [Patch]
        bbLoeschen.Enabled=0
        Speichern.Caption=Sichern }
    function ApplyPatchesFromIni(const ASection: string = 'Patch'): Integer;

    { ------------------------------------------- Neue Elemente ---------
      Alles Weitere steht in AmsApi.Factory. Angelegtes und Geklontes wird
      beim Entladen wieder abgeraeumt, genau wie eine Aenderung. }

    { Neues Element in einen Container: NewElement('TButton', 'Test',
      'pnUnten'). Liefert das Element oder nil (Grund in LastError). }
    function NewElement(const AClass, ACaption,
      ATargetNameOrCaption: string): Pointer;

    { Vorhandenes Element kopieren und woanders einhaengen:
      CloneElement('bbSpeichern', 'bmbBenutzerdefiniert').
      Zielname leer = dorthin, wo das Original sitzt.
      ACopyEvents = True laesst den Klon dieselbe Behandlung des Hosts
      rufen wie das Original. }
    function CloneElement(const ASourceNameOrCaption,
      ATargetNameOrCaption: string; ACopyEvents: Boolean = False): Pointer;

    { Ein selbst angelegtes Element wieder entfernen. Auf ein Element des
      Hosts angewandt liefert es False. }
    function RemoveElement(AObj: Pointer): Boolean;

    { Alle eigenen Aenderungen sofort zuruecknehmen. }
    function UndoUiChanges: Integer;

    { Diagnose: Trefferliste bzw. ein Element mit allen Eigenschaften. }
    procedure DumpElements(const AFilter: TAmsElementFilter; ADest: TStrings);
    procedure DumpElement(const ANameOrCaption: string; ADest: TStrings);

    { Kurzbericht ueber Host-Anbindung und Zustand - fuer ein Diagnosefenster. }
    procedure BuildReport(ADest: TStrings);
  end;

{ Die Plugin-Klasse anmelden. Gehoert in den Hauptblock der library. }
procedure AmsRegisterPlugin(AClass: TAmsPluginClass);

{ Die laufende Instanz, oder nil. }
function AmsPluginInstance: TAmsPlugin;

{ ---------------------------------------------------- Exporte fuer die BPL
  Genau diese drei braucht AMS:
    Initialize / Finalize  von LoadPackage bzw. FinalizePackage
    PluginInit             vom TPluginManager
  Eine PACKAGEINFO-Ressource ist nicht noetig: CheckForDuplicateUnits steigt
  aus, wenn keine da ist. Die Quelldatei muss "library" sein, nicht "program". }

procedure AmsPkgInitialize; register;
procedure AmsPkgFinalize; register;

{ EAX = TPluginManager, EDX = @Result. Das Ergebnis muss AddRef'd zurueck-
  kommen - der Aufrufer macht IntfCopy und released seinen Temporaeren. }
procedure AmsPluginInit(AManager: Pointer; AResult: PPointer); register;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Components,
  AmsApi.Automatismus, AmsApi.Actions, AmsApi.Ini, AmsApi.Log;

const
  IDC_FALLBACK = $8A01;
  BTN_W = 132;
  BTN_H = 26;
  BTN_MARGIN = 14;
  POLL_MS = 750;

var
  gClass: TAmsPluginClass = nil;
  gInstance: TAmsPlugin = nil;
  gIntf: IPlugin = nil;
  gTimer: UINT_PTR = 0;
  gOldProc: Pointer = nil;
  gHooked: Boolean = False;

{ ------------------------------------------------------------ Fensterhook - }

procedure PositionFallback(AWnd: HWND; ABtn: HWND);
var
  R: TRect;
begin
  if (ABtn = 0) or (AWnd = 0) then Exit;
  if not GetClientRect(AWnd, R) then Exit;
  SetWindowPos(ABtn, HWND_TOP, R.Right - BTN_W - BTN_MARGIN,
    R.Bottom - BTN_H - BTN_MARGIN, BTN_W, BTN_H, SWP_NOACTIVATE);
end;

function MainSubclass(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
var
  Handled: Boolean;
  P: TAmsPlugin;
begin
  Result := 0;
  P := gInstance;
  Handled := False;
  if P <> nil then
  try
    if (AMsg = WM_COMMAND) and (P.FFallbackBtn <> 0) and
       (HWND(ALParam) = P.FFallbackBtn) then
    begin
      P.ButtonClick(nil, 0);
      Exit(0);
    end;
    Result := P.WindowMessage(AMsg, AWParam, ALParam, Handled);
    if Handled then Exit;
  except
    on E: Exception do AmsLog('WindowMessage EXCEPTION: ' + E.Message);
  end;

  Result := CallWindowProcW(gOldProc, AWnd, AMsg, AWParam, ALParam);

  { Nach der VCL positionieren, damit der Notnagel oben bleibt. }
  if (P <> nil) and (P.FFallbackBtn <> 0) and
     ((AMsg = WM_SIZE) or (AMsg = WM_WINDOWPOSCHANGED)) then
    try
      PositionFallback(AWnd, P.FFallbackBtn);
    except
    end;
end;

procedure TimerProc(AWnd: HWND; AMsg: UINT; AId: UINT_PTR; ATime: DWORD); stdcall;
var
  W: HWND;
begin
  try
    if (gInstance = nil) or gInstance.FStarted then
    begin
      if gTimer <> 0 then
      begin
        KillTimer(0, gTimer);
        gTimer := 0;
      end;
      Exit;
    end;
    W := AmsFindMainWindow;
    if W <> 0 then
    begin
      if gTimer <> 0 then
      begin
        KillTimer(0, gTimer);
        gTimer := 0;
      end;
      gInstance.AttachMainWindow(W);
    end;
  except
    on E: Exception do AmsLog('TimerProc EXCEPTION: ' + E.Message);
  end;
end;

procedure StartPolling;
begin
  if gTimer = 0 then
    gTimer := SetTimer(0, 0, POLL_MS, @TimerProc);
end;

{ ---------------------------------------------------------------- TAmsPlugin }

constructor TAmsPlugin.Create;
begin
  inherited Create;
  FManager := nil;
  FItem := nil;
  FBuSession := nil;
  FMainWnd := 0;
  FStarted := False;
  FUnloaded := False;
  FFallbackBtn := 0;
end;

destructor TAmsPlugin.Destroy;
begin
  if gInstance = Self then gInstance := nil;
  inherited Destroy;
end;

procedure TAmsPlugin.Log(const AText: string);
begin
  AmsLog(AText);
end;

procedure TAmsPlugin.LogFmt(const AFormat: string; const AArgs: array of const);
begin
  AmsLogFmt(AFormat, AArgs);
end;

function TAmsPlugin.LastError: string;
begin
  Result := AmsLastError;
end;

procedure ShowBox(AWnd: HWND; const AText: string; AIcon: UINT);
var
  W, T: WideString;
begin
  try
    W := WideString(AText);
    T := WideString(AmsModuleName);
    MessageBoxW(AWnd, PWideChar(W), PWideChar(T), MB_OK or AIcon);
  except
  end;
end;

procedure TAmsPlugin.ShowInfo(const AText: string);
begin
  AmsLog('Meldung: ' + AText);
  ShowBox(FMainWnd, AText, MB_ICONINFORMATION);
end;

procedure TAmsPlugin.ShowWarning(const AText: string);
begin
  AmsLog('Warnung: ' + AText);
  ShowBox(FMainWnd, AText, MB_ICONWARNING);
end;

procedure TAmsPlugin.ShowError(const AText: string);
begin
  AmsLog('Fehlermeldung: ' + AText);
  ShowBox(FMainWnd, AText, MB_ICONERROR);
end;

procedure TAmsPlugin.ShowLastError(const APrefix: string);
var
  Msg: string;
begin
  Msg := AmsLastError;
  if Msg = '' then Msg := 'Unbekannte Ursache.';
  if APrefix <> '' then Msg := APrefix + sLineBreak + sLineBreak + Msg;
  ShowError(Msg);
end;

{ --------------------------------------------------------- Standardverhalten }

procedure TAmsPlugin.Startup;
begin
end;

procedure TAmsPlugin.AfterMainWindow;
begin
end;

procedure TAmsPlugin.ButtonClick(ASender: Pointer; ATag: Integer);
begin
  AmsLogFmt('ButtonClick(sender=%p, tag=%d) - nicht ueberschrieben',
            [ASender, ATag]);
end;

procedure TAmsPlugin.SessionChanged;
begin
end;

procedure TAmsPlugin.HostCommand(ACmd: Integer; AData: Pointer);
begin
end;

procedure TAmsPlugin.BeforeUnload;
begin
end;

function TAmsPlugin.CanUnload: Boolean;
begin
  Result := True;
end;

function TAmsPlugin.WantsWindowHook: Boolean;
begin
  Result := False;
end;

function TAmsPlugin.WantsFallbackButton: Boolean;
begin
  Result := False;
end;

function TAmsPlugin.WindowMessage(AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM; var AHandled: Boolean): LRESULT;
begin
  Result := 0;
  AHandled := False;
end;

{ ---------------------------------------------------------------- Anbinden - }

procedure TAmsPlugin.AttachMainWindow(AWnd: HWND);
var
  NeedHook: Boolean;
  F: HFONT;
begin
  if FStarted or (AWnd = 0) then Exit;
  FMainWnd := AWnd;
  FStarted := True;

  AmsLogFmt('Hauptfenster %p gefunden - Klasse "%s", Titel "%s"',
            [Pointer(AWnd), AmsWindowClass(AWnd), AmsWindowText(AWnd)]);
  AmsBindAll;
  AmsLog(AmsBindReport);

  NeedHook := WantsWindowHook;

  try
    AfterMainWindow;
  except
    on E: Exception do AmsLog('AfterMainWindow EXCEPTION: ' + E.Message);
  end;

  { Notnagel nur, wenn gewuenscht UND kein Ribbon-Element zustande kam. }
  if WantsFallbackButton and (AmsButtonCount = 0) then
  begin
    FFallbackBtn := CreateWindowExW(0, 'BUTTON',
      PWideChar(WideString(AmsModuleName)),
      WS_CHILD or WS_VISIBLE or WS_CLIPSIBLINGS or BS_PUSHBUTTON,
      0, 0, BTN_W, BTN_H, FMainWnd, HMENU(IDC_FALLBACK), HInstance, nil);
    if FFallbackBtn <> 0 then
    begin
      F := HFONT(GetStockObject(DEFAULT_GUI_FONT));
      SendMessageW(FFallbackBtn, WM_SETFONT, WPARAM(F), 1);
      PositionFallback(FMainWnd, FFallbackBtn);
      NeedHook := True;         { ohne Hook kaeme kein WM_COMMAND an }
      AmsLog('Ribbon-Einbau ohne Ergebnis - Win32-Notnagel erzeugt');
    end
    else
      AmsLogFmt('Notnagel-Button fehlgeschlagen, Fehler %d', [GetLastError]);
  end;

  if NeedHook and not gHooked then
  begin
    gOldProc := Pointer(SetWindowLongW(FMainWnd, GWL_WNDPROC, LONG(@MainSubclass)));
    gHooked := gOldProc <> nil;
    AmsLog('Hauptfenster gehookt: ' + BoolToStr(gHooked, True));
  end;
end;

{ ------------------------------------------------------------------ IPlugin }

procedure TAmsPlugin.SetPluginManager(AManager: Pointer);
begin
  FManager := AManager;
  AmsLogFmt('SetPluginManager(%p)', [AManager]);
end;

procedure TAmsPlugin.SetPluginItem(AItem: Pointer);
begin
  FItem := AItem;
  AmsLogFmt('SetPluginItem(%p)', [AItem]);
end;

procedure TAmsPlugin.Loaded;
begin
  AmsLog('Loaded - warte per Timer auf das AMS-Hauptfenster');
  StartPolling;
end;

function TAmsPlugin.UnloadQuery: Boolean;
begin
  Result := True;
  try
    Result := CanUnload;
  except
    on E: Exception do AmsLog('CanUnload EXCEPTION: ' + E.Message);
  end;
  AmsLog('UnloadQuery -> ' + BoolToStr(Result, True));
end;

procedure TAmsPlugin.Unload;
begin
  if FUnloaded then Exit;
  FUnloaded := True;
  AmsLog('Unload');
  try
    BeforeUnload;
  except
    on E: Exception do AmsLog('BeforeUnload EXCEPTION: ' + E.Message);
  end;

  try
    if gTimer <> 0 then
    begin
      KillTimer(0, gTimer);
      gTimer := 0;
    end;

    { Aenderungen an Host-Elementen zuruecknehmen und uebernommene
      Ereignisse abklemmen - BEIDES bevor das Modul verschwindet. Bliebe
      eine deaktivierte Schaltflaeche stehen, waere AMS dauerhaft
      beschaedigt; bliebe ein Ereignis stehen, waere der naechste Klick
      ein Sprung in freigegebenen Speicher. }
    { Selbst angelegte und geklonte Elemente zuerst: sie haengen an
      Elementen des Hosts, und ihre Klickbehandlung zeigt in dieses Modul. }
    AmsFactoryRelease;

    AmsUiRelease;

    { OnClick abklemmen, BEVOR das Modul verschwindet. }
    AmsReleaseButtons;

    if FFallbackBtn <> 0 then
    begin
      DestroyWindow(FFallbackBtn);
      FFallbackBtn := 0;
    end;

    if gHooked and (FMainWnd <> 0) and IsWindow(FMainWnd) then
      SetWindowLongW(FMainWnd, GWL_WNDPROC, LONG(gOldProc));
    gHooked := False;
    FMainWnd := 0;
    FStarted := False;
  except
    on E: Exception do AmsLog('Unload EXCEPTION: ' + E.Message);
  end;
end;

procedure TAmsPlugin.DoCommand(ACmd: Integer; AData: Pointer);
var
  Name: string;
begin
  try
    if (ACmd >= Low(AmsCommandNames)) and (ACmd <= High(AmsCommandNames)) then
      Name := AmsCommandNames[ACmd]
    else
      Name := '?';
    AmsLogFmt('DoCommand(%d = %s, data=%p)', [ACmd, Name, AData]);

    { Bei pcInitBuSession und pcPluginUpdate ist AData die TBuSession. Vor dem
      Merken den Klassennamen pruefen - nicht blind speichern. }
    if (AData <> nil) and ((ACmd = pcInitBuSession) or (ACmd = pcPluginUpdate)) then
    begin
      if AmsClassIs(AData, 'BuSession') then
      begin
        if FBuSession <> AData then
        begin
          FBuSession := AData;
          AmsLogFmt('BuSession gemerkt: %p [%s]', [AData, AmsClassName(AData)]);
          try
            SessionChanged;
          except
            on E: Exception do AmsLog('SessionChanged EXCEPTION: ' + E.Message);
          end;
        end;
      end
      else
        AmsLogFmt('DoCommand-Daten sind keine BuSession: [%s]',
                  [AmsClassName(AData)]);
    end;

    { Falls Loaded ausgeblieben ist oder das Fenster spaeter kommt.
      Nach Unload NICHT wieder anlaufen lassen - der Host schickt durchaus
      noch DoCommand, waehrend das Modul schon abgebaut wird. }
    if not (FStarted or FUnloaded) then StartPolling;

    try
      HostCommand(ACmd, AData);
    except
      on E: Exception do AmsLog('HostCommand EXCEPTION: ' + E.Message);
    end;
  except
    on E: Exception do AmsLog('DoCommand EXCEPTION: ' + E.Message);
  end;
end;

{ ----------------------------------------------------------------- Aktionen }

function TAmsPlugin.AddRibbonButtonEx(const AOptions: TAmsRibbonOptions): Pointer;
var
  Item: Pointer;
begin
  Result := nil;
  if AmsAddRibbonButton(FMainWnd, AOptions, Item) then
    Result := Item
  else
    AmsLog('AddRibbonButton fehlgeschlagen: ' + AmsLastError);
end;

function TAmsPlugin.AddRibbonButton(const ACaption, AHint, AGlyphFile: string;
  ATag: Integer): Pointer;
var
  Opt: TAmsRibbonOptions;
begin
  Opt := AmsRibbonDefaults;
  Opt.Caption := ACaption;
  Opt.Hint := AHint;
  Opt.LargeGlyphFile := AGlyphFile;
  Opt.GlyphFile := AGlyphFile;
  Opt.OnClick := ButtonClick;
  Opt.Tag := ATag;
  Result := AddRibbonButtonEx(Opt);
end;

function TAmsPlugin.RunAutomatismus(const ACaption: string): Boolean;
begin
  Result := AmsRunAutomatismus(ACaption);
end;

function TAmsPlugin.RunAutomatismusEx(const ACaption: string;
  AAvailable: TStrings): Boolean;
begin
  Result := AmsRunAutomatismusEx(ACaption, AAvailable);
end;

function TAmsPlugin.ListAutomatismen(ACaptions: TStrings): Integer;
begin
  Result := AmsListAutomatismen(ACaptions);
end;

function TAmsPlugin.RunAction(const AName: string): Boolean;
begin
  Result := AmsRunAction(AName);
end;

function TAmsPlugin.FireEvent(const AName: string): Boolean;
begin
  Result := AmsFireEvent(AName);
end;

{ ------------------------------------------------- Vorhandene Elemente --- }

function TAmsPlugin.FindElement(const ANameOrCaption: string;
  out AElement: TAmsElement): Boolean;
begin
  Result := AmsElement(ANameOrCaption, AElement);
end;

function TAmsPlugin.FindElements(const AFilter: TAmsElementFilter;
  var AList: TAmsElementArray): Integer;
begin
  Result := AmsFindElements(AFilter, AList);
end;

function TAmsPlugin.SetElement(const ANameOrCaption, APropPath,
  AValue: string): Boolean;
var
  E: TAmsElement;
begin
  Result := AmsElement(ANameOrCaption, E) and
            AmsSetElementProp(E.Obj, APropPath, AValue);
end;

function TAmsPlugin.EnableElement(const ANameOrCaption: string;
  AEnabled: Boolean): Boolean;
var
  E: TAmsElement;
begin
  Result := AmsElement(ANameOrCaption, E) and AmsEnableElement(E.Obj, AEnabled);
end;

function TAmsPlugin.ShowElement(const ANameOrCaption: string;
  AVisible: Boolean): Boolean;
var
  E: TAmsElement;
begin
  Result := AmsElement(ANameOrCaption, E) and AmsShowElement(E.Obj, AVisible);
end;

function TAmsPlugin.RenameElement(const ANameOrCaption,
  ANewCaption: string): Boolean;
var
  E: TAmsElement;
begin
  Result := AmsElement(ANameOrCaption, E) and
            AmsSetElementCaption(E.Obj, ANewCaption);
end;

function TAmsPlugin.ApplyPatchesFromIni(const ASection: string): Integer;
var
  L: TStringList;
begin
  Result := 0;
  L := TStringList.Create;
  try
    AmsIniSection(AmsIniFile, ASection, L);
    if L.Count = 0 then
    begin
      AmsLogFmt('plugin.ini: Abschnitt [%s] ist leer oder fehlt', [ASection]);
      Exit;
    end;
    Result := AmsApplyPatches(L);
  finally
    L.Free;
  end;
end;

function TAmsPlugin.NewElement(const AClass, ACaption,
  ATargetNameOrCaption: string): Pointer;
var
  Opt: TAmsNewOptions;
  Target: TAmsElement;
begin
  Result := nil;
  Opt := AmsNewDefaults;
  Opt.ClassName := AClass;
  Opt.Caption := ACaption;
  if ATargetNameOrCaption <> '' then
  begin
    if not AmsElement(ATargetNameOrCaption, Target) then Exit;
    Opt.Target := Target.Obj;
  end;
  if not AmsNewElement(Opt, Result) then Result := nil;
end;

function TAmsPlugin.CloneElement(const ASourceNameOrCaption,
  ATargetNameOrCaption: string; ACopyEvents: Boolean): Pointer;
var
  Src, Target: TAmsElement;
  Dest: Pointer;
begin
  Result := nil;
  if not AmsElement(ASourceNameOrCaption, Src) then Exit;
  Dest := nil;
  if ATargetNameOrCaption <> '' then
  begin
    if not AmsElement(ATargetNameOrCaption, Target) then Exit;
    Dest := Target.Obj;
  end;
  if AmsCloneElementEx(Src.Obj, Dest, '', ACopyEvents, AmsKeep, AmsKeep,
                       Result) then Exit;
  Result := nil;
end;

function TAmsPlugin.RemoveElement(AObj: Pointer): Boolean;
begin
  Result := AmsRemoveElement(AObj);
end;

function TAmsPlugin.UndoUiChanges: Integer;
begin
  Result := AmsUndoAll;
end;

procedure TAmsPlugin.DumpElements(const AFilter: TAmsElementFilter;
  ADest: TStrings);
begin
  AmsDumpElements(AFilter, ADest);
end;

procedure TAmsPlugin.DumpElement(const ANameOrCaption: string;
  ADest: TStrings);
var
  E: TAmsElement;
begin
  if ADest = nil then Exit;
  if AmsElement(ANameOrCaption, E) then
    AmsDumpElement(E.Obj, ADest)
  else
    ADest.Add(AmsLastError);
end;

procedure TAmsPlugin.BuildReport(ADest: TStrings);
begin
  if ADest = nil then Exit;
  ADest.Add(Format('%s - Plugin fuer ASSFINET AMS.5', [AmsModuleName]));
  ADest.Add(StringOfChar('=', 78));
  ADest.Add(Format('Modul ............... %s', [AmsModuleFile]));
  ADest.Add(Format('Prozess-ID .......... %d', [GetCurrentProcessId]));
  ADest.Add(Format('Hauptfenster ........ %p  Klasse "%s"',
                   [Pointer(FMainWnd), AmsWindowClass(FMainWnd)]));
  ADest.Add(Format('BuSession ........... %p  [%s]',
                   [FBuSession, AmsClassName(FBuSession)]));
  ADest.Add(Format('Ribbon-Elemente ..... %d', [AmsButtonCount]));
  ADest.Add(Format('Element-Aenderungen . %d (Ruecknahme beim Entladen: %s)',
                   [AmsChangeCount, BoolToStr(AmsAutoUndo, True)]));
  ADest.Add(Format('Uebernommene Events . %d', [AmsHookCount]));
  ADest.Add(Format('Fensterhook ......... %s', [BoolToStr(gHooked, True)]));
  ADest.Add(Format('plugin.ini .......... %s (%s)',
                   [AmsIniFile, BoolToStr(FileExists(AmsIniFile), True)]));
  ADest.Add(Format('Logdatei ............ %s', [AmsLogFile]));
  ADest.Add('');
  ADest.Add(AmsBindReport);
  ADest.Add('');
  ADest.Add('Letzte Ereignisse:');
  ADest.Add(StringOfChar('-', 78));
  AmsLogTail(ADest, 120);
end;

{ ------------------------------------------------------- Registrierung/Export }

procedure AmsRegisterPlugin(AClass: TAmsPluginClass);
begin
  gClass := AClass;
end;

function AmsPluginInstance: TAmsPlugin;
begin
  Result := gInstance;
end;

procedure AmsPkgInitialize; register;
begin
  try
    AmsLog('=== Initialize - Modul geladen ===');
    AmsLogFmt('AmsApi %s, Modul "%s", HInstance=%p',
              [AMS_API_VERSION, AmsModuleFile, Pointer(HInstance)]);
    AmsLogFmt('plugin.ini vorhanden: %s',
              [BoolToStr(FileExists(AmsIniFile), True)]);
  except
  end;
end;

procedure AmsPkgFinalize; register;
begin
  try
    AmsLog('=== Finalize - Modul wird entladen ===');
    if gInstance <> nil then gInstance.Unload;
    gIntf := nil;
    gInstance := nil;
  except
  end;
end;

procedure AmsPluginInit(AManager: Pointer; AResult: PPointer); register;
begin
  if AResult = nil then Exit;
  try
    if gIntf = nil then
    begin
      if gClass = nil then
      begin
        AmsLog('PluginInit: keine Plugin-Klasse angemeldet - ' +
               'AmsRegisterPlugin im Hauptblock der library aufrufen');
        AResult^ := nil;
        Exit;
      end;
      gInstance := gClass.Create;
      gIntf := gInstance;
      AmsLogFmt('PluginInit(manager=%p) - Instanz %s erzeugt',
                [AManager, gInstance.ClassName]);
      try
        gInstance.Startup;
      except
        on E: Exception do AmsLog('Startup EXCEPTION: ' + E.Message);
      end;
    end;
    { Der Aufrufer macht IntfCopy und released seinen Temporaeren spaeter -
      wir muessen also AddRef'd zurueckgeben. }
    gIntf._AddRef;
    AResult^ := Pointer(gIntf);
  except
    on E: Exception do
    begin
      AmsLog('PluginInit EXCEPTION: ' + E.Message);
      AResult^ := nil;
    end;
  end;
end;

end.
