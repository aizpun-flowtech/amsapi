library Doom;

{ ============================================================================
  Doom - DOOM im laufenden AMS, eingebettet (kein eigenes Fenster)

  Ein Ribbon-Knopf "DOOM" haengt eine Spielflaeche IN das AMS-Fenster und
  laesst darin DOOM laufen. Zwei Betriebsarten, automatisch gewaehlt:

  1. ECHTES DOOM (bevorzugt): Liegt "doomcore.dll" neben dem Plugin UND ein
     IWAD (DOOM1.WAD Shareware, doom.wad oder freedoom1.wad), laeuft der echte
     DOOM-Kern (doomgeneric, GPLv2) mit echten Leveln - E1M1 und so weiter,
     samt Gegnern, Waffen und Spiellogik. Das Bild (640x400) kommt aus der DLL,
     wir blitten es nur.

  2. ERSATZ-ENGINE: Fehlt DLL oder WAD, laeuft die reine Pascal-Engine
     (AmsApi.DoomEngine) mit erzeugten Texturen - damit startet das Plugin in
     jedem Fall.

  Einbetten: Die Flaeche ist ein WS_CHILD-Fenster im AMS-Hauptfenster. Steht in
  der plugin.ini unter [Doom] Container=<Name> ein Bedienelement (z.B. eine
  Tab-Seite, deren Namen man mit dem UiTweaks-Suchfenster findet), wird die
  Flaeche in DESSEN Fenster gehaengt - so sitzt DOOM in einem Tab von AMS.
  Ohne Angabe fuellt sie das Hauptfenster.

  Steuerung: Pfeile/WASD laufen & drehen, Strg feuern, Leertaste benutzen/Tuer,
  Umschalt rennen, Zahlen Waffenwahl, Esc DOOM-Menue. Die Bibliothek
  (AmsApi.GameWindow / .DoomCore / .DoomEngine) macht die Arbeit - hier steht
  nur die Verdrahtung.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, Classes,
  AmsApi.Plugin, AmsApi.Ui, AmsApi.Factory, AmsApi.Rtti, AmsApi.Props,
  AmsApi.GameWindow, AmsApi.DoomCore, AmsApi.DoomEngine, AmsApi.Ini, AmsApi.Log;

const
  TAG_DOOM = 1;

type
  TDoomPlugin = class(TAmsPlugin)
  protected
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
    procedure BeforeUnload; override;
  private
    FWin: TAmsGameWindow;
    FCore: TAmsDoomCore;      { echtes DOOM (DLL) }
    FEngine: TAmsDoom;        { Ersatz-Engine (Pascal) }
    FReal: Boolean;           { laeuft der echte Kern? }
    FDead: Boolean;
    FTabSheet: Pointer;       { die angelegte TcxTabSheet, wenn als Tab }
    FUsingTab: Boolean;
    FWadPath: string;
    FExtra: string;
    FContainer: string;
    FMode: string;
    FSaveDir: string;
    FBgColor: COLORREF;
    FScale: Integer;
    FTop, FLeft, FRight, FBottom: Integer;
    FFramesLogged: Boolean;
    FKeyState: array[0..255] of Boolean;
    function ResolveWad: string;
    function ResolveSaveDir: string;
    function ResolveContainer: HWND;
    procedure OpenGame;
    procedure CloseGame;
    procedure PositionEmbed(AParent: HWND);
    procedure LogGeometry(AParent: HWND);
    procedure DiscoverContainers;
    function CreateDoomTab(out ASheetWnd: HWND): Boolean;
    procedure RemoveDoomTab;
    procedure OnFrame(ASender: TAmsGameWindow; AElapsedMs: Integer);
    procedure OnOverlay(ASender: TAmsGameWindow; ADC: HDC; ACW, ACH: Integer);
    procedure OnGameClosed(ASender: TAmsGameWindow; AElapsedMs: Integer);
  end;

{ ------------------------------------------------- Verzoegertes Schliessen ---
  Das Beenden per Y laeuft IN der Bildschleife von FWin; dort darf FWin nicht
  freigegeben werden (die Schleife wuerde danach in freigegebenen Speicher
  laufen). Also ueber einen Thread-Timer aus der Nachrichtenschleife von AMS
  heraus schliessen - dort ist es sicher, und dabei geht der Reiter mit weg. }
var
  gCloseTimer: UINT_PTR = 0;
  gClosePlugin: TDoomPlugin = nil;

procedure DeferredClose(AWnd: HWND; AMsg: UINT; AId: UINT_PTR; ATime: DWORD); stdcall;
begin
  if gCloseTimer <> 0 then
  begin
    KillTimer(0, gCloseTimer);
    gCloseTimer := 0;
  end;
  if gClosePlugin <> nil then
  try
    gClosePlugin.CloseGame;
  except
    on E: Exception do AmsLog('DOOM DeferredClose EXCEPTION: ' + E.Message);
  end;
end;

{ ------------------------------------------------------------------ Ribbon --- }

procedure TDoomPlugin.AfterMainWindow;
var
  Bg: string;
  C: Integer;
begin
  FWadPath := AmsIniStr('Wad', '', 'Doom');
  FExtra := AmsIniStr('Extra', '', 'Doom');
  FContainer := AmsIniStr('Container', '', 'Doom');
  { embed = Flaeche IN AMS (Standard). window = eigenes Fenster (Notloesung,
    falls das Einbetten in dieser AMS-Version nicht sichtbar wird). }
  FMode := LowerCase(AmsIniStr('Mode', 'embed', 'Doom'));
  FSaveDir := AmsIniStr('SaveDir', '', 'Doom');
  FScale := AmsIniInt('Scale', 2, 'Doom');
  if FScale < 1 then FScale := 1;
  if FScale > 8 then FScale := 8;
  { Raender der eingebetteten Flaeche im Elter-Client. Oben Platz fuer Ribbon
    und Tableiste, damit der DOOM-Knopf sichtbar/klickbar bleibt (Umschalten). }
  FTop := AmsIniInt('Top', 116, 'Doom');
  FLeft := AmsIniInt('Left', 0, 'Doom');
  FRight := AmsIniInt('Right', 0, 'Doom');
  FBottom := AmsIniInt('Bottom', 0, 'Doom');
  { Randfarbe um das Bild (Letterbox). Standard weiss - passt zur hellen
    AMS-Oberflaeche. "black"/"schwarz", "clRed", "#RRGGBB" gehen auch. }
  Bg := LowerCase(Trim(AmsIniStr('Background', 'white', 'Doom')));
  if (Bg = '') or (Bg = 'white') or (Bg = 'weiss') or (Bg = 'weiß') then
    FBgColor := RGB(255, 255, 255)
  else if (Bg = 'black') or (Bg = 'schwarz') then
    FBgColor := RGB(0, 0, 0)
  else if AmsColorFromText(Bg, C) then
    FBgColor := COLORREF(C)
  else
    FBgColor := RGB(255, 255, 255);

  gClosePlugin := Self;
  AddRibbonButton('DOOM', 'DOOM im AMS starten/schliessen', 'icon32.png', TAG_DOOM);
  Log('Doom-Plugin bereit. Mode=' + FMode);
end;

procedure TDoomPlugin.ButtonClick(ASender: Pointer; ATag: Integer);
begin
  case ATag of
    TAG_DOOM:
      { Umschalten: laeuft es schon, wieder schliessen. }
      if (FWin <> nil) and (FWin.Handle <> 0) and not FWin.Closed then
      begin
        Log('DOOM: Knopf erneut - schliessen');
        CloseGame;
      end
      else
        OpenGame;
  end;
end;

procedure TDoomPlugin.BeforeUnload;
begin
  CloseGame;
  gClosePlugin := nil;
end;

{ -------------------------------------------------------------- Fundstuecke -- }

function TDoomPlugin.ResolveWad: string;
const
  KNOWN: array[0..5] of string =
    ('DOOM1.WAD', 'doom1.wad', 'DOOM.WAD', 'doom.wad',
     'freedoom1.wad', 'freedoom2.wad');
var
  i: Integer;
  P: string;
begin
  Result := '';
  if FWadPath <> '' then
  begin
    P := AmsResolvePath(FWadPath);
    if FileExists(P) then Exit(P);
  end;
  for i := 0 to High(KNOWN) do
  begin
    P := AmsModuleDir + KNOWN[i];
    if FileExists(P) then Exit(P);
  end;
end;

{ Beschreibbares Verzeichnis fuer Spielstaende und Konfiguration. [Doom]
  SaveDir= hat Vorrang; sonst %APPDATA%\AmsDoom (immer pro-Benutzer beschreibbar,
  ohne Adminrechte). Ohne das schreibt DOOM ins Programmverzeichnis von AMS und
  Spielstaende gehen verloren. }
function TDoomPlugin.ResolveSaveDir: string;
begin
  if FSaveDir <> '' then
    Result := AmsResolvePath(FSaveDir)
  else
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA')) +
              'AmsDoom';
  Result := IncludeTrailingPathDelimiter(Result);
  if not DirectoryExists(Result) then
    if not ForceDirectories(Result) then
      LogFmt('DOOM: Speicherverzeichnis nicht anlegbar: %s', [Result]);
end;

{ Zielcontainer fuers Einbetten. [Doom] Container=<Name/Beschriftung> haengt die
  Flaeche in DESSEN Fenster (z.B. eine AMS-Tab-Seite). Sonst das Hauptfenster. }
function TDoomPlugin.ResolveContainer: HWND;
var
  E: TAmsElement;
  H: HWND;
begin
  Result := MainWindow;
  if FContainer = '' then Exit;
  if FindElement(FContainer, E) then
  begin
    H := AmsWindowOfElement(E.Obj);
    if H <> 0 then
    begin
      Result := H;
      LogFmt('DOOM: eingebettet in "%s" [%s] (HWND %p)',
             [E.Path, E.ClassName, Pointer(H)]);
    end
    else
      LogFmt('DOOM: "%s" hat kein Fenster - haenge ins Hauptfenster',
             [FContainer]);
  end
  else
    LogFmt('DOOM: Container "%s" nicht gefunden (%s) - Hauptfenster',
           [FContainer, LastError]);
end;

{ ------------------------------------------------------------------ Spiel ---- }

{ Eingebettete Flaeche im Elter platzieren: Client minus Raender. So bleibt
  oben die Ribbon-/Tableiste sichtbar und der DOOM-Knopf klickbar. }
procedure TDoomPlugin.PositionEmbed(AParent: HWND);
var
  R: TRect;
  x, y, w, h: Integer;
begin
  if (FWin = nil) or (AParent = 0) then Exit;
  if not GetClientRect(AParent, R) then Exit;
  x := FLeft;
  y := FTop;
  w := (R.Right - R.Left) - FLeft - FRight;
  h := (R.Bottom - R.Top) - FTop - FBottom;
  if w < 64 then w := 64;
  if h < 64 then h := 64;
  MoveWindow(FWin.Handle, x, y, w, h, True);
  FWin.ToForeground;   { im Z-Stapel nach oben }
end;

{ Diagnose: alle Tab-/Seiten-/Dock-artigen Elemente von AMS ins Log schreiben -
  damit laesst sich das Dokument-Tab-Steuerelement (das "Startseite" zeigt)
  eindeutig bestimmen, um DOOM als echten Reiter einzuhaengen. }
procedure TDoomPlugin.DiscoverContainers;
var
  F: TAmsElementFilter;
  All: TAmsElementArray;
  n, i: Integer;
  cn: string;
  h: HWND;
  R: TRect;

  function Looks(const AClass: string): Boolean;
  begin
    Result := (Pos('PAGECONTROL', UpperCase(AClass)) > 0) or
              (Pos('TABCONTROL', UpperCase(AClass)) > 0) or
              (Pos('TABSHEET', UpperCase(AClass)) > 0) or
              (Pos('PAGE', UpperCase(AClass)) > 0) or
              (Pos('TAB', UpperCase(AClass)) > 0) or
              (Pos('DOCK', UpperCase(AClass)) > 0) or
              (Pos('MDI', UpperCase(AClass)) > 0) or
              (Pos('DOCUMENT', UpperCase(AClass)) > 0) or
              (Pos('CONCENTER', UpperCase(AClass)) > 0);
  end;

begin
  F := AmsFilterAll;
  F.OnlyVisible := False;
  F.MaxResults := 12000;
  F.MaxNodes := 60000;
  n := AmsFindElements(F, All);
  LogFmt('=== DOOM Tab-Discovery: %d Elemente durchsucht ===', [n]);
  for i := 0 to n - 1 do
  begin
    cn := All[i].ClassName;
    if not Looks(cn) then Continue;
    h := All[i].Handle;
    if h = 0 then h := AmsWindowOfElement(All[i].Obj);
    FillChar(R, SizeOf(R), 0);
    if h <> 0 then GetWindowRect(h, R);
    LogFmt('  <%s> name="%s" caption="%s" hwnd=%p rect=%d,%d-%d,%d path=%s',
           [cn, All[i].Name, All[i].Caption, Pointer(h),
            R.Left, R.Top, R.Right, R.Bottom, All[i].Path]);
  end;
  Log('=== Ende Tab-Discovery ===');
end;

procedure TDoomPlugin.LogGeometry(AParent: HWND);
var
  PR, WR: TRect;
begin
  if FWin = nil then Exit;
  FillChar(PR, SizeOf(PR), 0);
  FillChar(WR, SizeOf(WR), 0);
  if AParent <> 0 then GetClientRect(AParent, PR);
  GetWindowRect(FWin.Handle, WR);
  LogFmt('DOOM-Geometrie: Parent=%p ClientW=%d ClientH=%d | Child=%p ' +
         'Rect=%d,%d-%d,%d sichtbar=%d',
         [Pointer(AParent), PR.Right - PR.Left, PR.Bottom - PR.Top,
          Pointer(FWin.Handle), WR.Left, WR.Top, WR.Right, WR.Bottom,
          Integer(IsWindowVisible(FWin.Handle))]);
end;

{ DOOM als echten Reiter anlegen: eine TcxTabSheet im Dokument-Page-Control
  von AMS (TafncxPageControl "SessionPageControl", per Discovery ermittelt).
  Angehaengt wird ueber die Eigenschaft PageControl - das erzeugt den Reiter
  und sein Fenster. Result False -> Aufrufer faellt aufs Einhaengen ins
  Hauptfenster zurueck. }
function TDoomPlugin.CreateDoomTab(out ASheetWnd: HWND): Boolean;
var
  F: TAmsElementFilter;
  PcEl: TAmsElement;
  Opt: TAmsNewOptions;
  PC: Pointer;
begin
  Result := False;
  ASheetWnd := 0;
  FTabSheet := nil;

  { WICHTIG: In AMS gibt es ZWEI "SessionPageControl" - eine TAdvPageControl
    (TMS, falsche Familie) und die richtige TafncxPageControl (DevExpress cx).
    Nur an eine cx-PageControl laesst sich eine TcxTabSheet haengen. Deshalb
    ueber die KLASSE einschraenken ("enthaelt cxPageControl"), nicht ueber den
    (mehrdeutigen) Namen. }
  F := AmsFilterAll;
  F.Name := 'SessionPageControl';
  F.ClassName := 'cxPageControl';
  if not AmsFindElement(F, PcEl) then
  begin
    { Notfalls nur ueber die Klasse. }
    F := AmsFilterAll;
    F.ClassName := 'cxPageControl';
    if not AmsFindElement(F, PcEl) then
    begin
      LogFmt('DOOM-Tab: cx-PageControl nicht gefunden (%s)', [LastError]);
      Exit;
    end;
  end;
  PC := PcEl.Obj;
  LogFmt('DOOM-Tab: Page-Control %s [%s]', [PcEl.Path, PcEl.ClassName]);

  Opt := AmsNewDefaults;
  Opt.ClassName := 'TcxTabSheet';
  Opt.Caption := 'DOOM';
  Opt.Owner := PC;      { Besitzer = Page-Control, als Aufraeum-Netz }
  { Anhaengen ueber den VIRTUELLEN SetParent: TcxTabSheet.SetParent leitet auf
    PageControl um und erzeugt so den Reiter. Die Eigenschaft PageControl ist
    NICHT published (kein RTTI) - SetOrdProp scheitert daran; SetParent nicht. }
  Opt.Target := PC;
  if not AmsNewElement(Opt, FTabSheet) then
  begin
    LogFmt('DOOM-Tab: TcxTabSheet anlegen/anhaengen fehlgeschlagen (%s)', [LastError]);
    FTabSheet := nil;
    Exit;
  end;

  { Beschriftung sicherstellen, dann - falls moeglich - aktiv schalten
    (ActivePage ggf. ebenfalls nicht setzbar; dann klickt man den Reiter). }
  AmsSetElementProp(FTabSheet, 'Caption', 'DOOM');
  AmsSetOrd(PC, 'ActivePage', Integer(PtrInt(FTabSheet)));

  ASheetWnd := AmsWindowOfElement(FTabSheet);
  Result := ASheetWnd <> 0;
  if Result then
    LogFmt('DOOM-Tab: Reiter "DOOM" angelegt, Fenster %p', [Pointer(ASheetWnd)])
  else
  begin
    Log('DOOM-Tab: Reiter angelegt, aber ohne Fenster - Fallback aufs Hauptfenster');
    RemoveDoomTab;
  end;
end;

procedure TDoomPlugin.RemoveDoomTab;
begin
  if FTabSheet <> nil then
  begin
    { Free der TcxTabSheet loest den Reiter im Destruktor selbst aus. }
    AmsRemoveElement(FTabSheet);
    FTabSheet := nil;
  end;
  FUsingTab := False;
end;

procedure TDoomPlugin.OpenGame;
var
  Wad, Dll: string;
  W, H: Integer;
  Parent, SheetWnd: HWND;
  Embed: Boolean;
begin
  CloseGame;

  FDead := False;
  FFramesLogged := False;
  FUsingTab := False;
  FillChar(FKeyState, SizeOf(FKeyState), 0);
  { Zur Fehlersuche: [Doom] Discover=1 schreibt alle Tab-/Seiten-Container
    ins Log (damit wurde das Page-Control von AMS bestimmt). }
  if AmsIniBool('Discover', False, 'Doom') then DiscoverContainers;
  Wad := ResolveWad;
  Embed := FMode <> 'window';

  { 1. Echtes DOOM versuchen. }
  FReal := False;
  Dll := AmsDoomCoreDefaultDll;
  if FileExists(Dll) and (Wad <> '') then
  begin
    FCore := TAmsDoomCore.Create(Dll);
    if FCore.Loaded then FCore.SetSaveDir(ResolveSaveDir);
    if FCore.Loaded and FCore.Start(Wad, FExtra) then
    begin
      FReal := True;
      W := 640; H := 400;
    end
    else
      FreeAndNil(FCore);
  end;

  { 2. Ersatz-Engine, falls kein echtes DOOM. }
  if not FReal then
  begin
    FEngine := TAmsDoom.Create;
    FEngine.LoadAssets(Wad);   { nimmt WAD-Assets, wenn vorhanden }
    FEngine.NewGame;
    W := 320; H := 200;
  end;

  if Embed then
  begin
    { Ohne ausdruecklichen Container: DOOM als echten Reiter anlegen. Klappt
      das nicht, oder ist ein Container in der INI gesetzt, ins genannte
      Element bzw. ins Hauptfenster einhaengen. }
    SheetWnd := 0;
    if (FContainer = '') and CreateDoomTab(SheetWnd) then
    begin
      Parent := SheetWnd;
      FUsingTab := True;
    end
    else
      Parent := ResolveContainer;
    FWin := TAmsGameWindow.Create('DOOM', W, H, Parent, FScale, {AChild=}True);
  end
  else
  begin
    Parent := 0;
    FWin := TAmsGameWindow.Create('DOOM - ' + AmsModuleName, W, H,
                                  MainWindow, FScale, {AChild=}False);
  end;

  if FWin.Handle = 0 then
  begin
    ShowError('Die Spielflaeche konnte nicht erzeugt werden.' + sLineBreak +
              LastError);
    CloseGame;
    Exit;
  end;

  FWin.BackColor := FBgColor;
  FWin.OnFrame := OnFrame;
  FWin.OnOverlay := OnOverlay;
  FWin.OnClose := OnGameClosed;
  FWin.Show;
  if Embed then
  begin
    if FUsingTab then
      FWin.FitToParent   { die Tab-Seite IST der Dokumentbereich - ganz fuellen }
    else
      PositionEmbed(Parent);
  end;
  FWin.Start(28);

  if FReal then
    Log('DOOM: echter Kern laeuft (WAD: ' + Wad + ')')
  else if Wad <> '' then
    Log('DOOM: Ersatz-Engine (doomcore.dll fehlt oder WAD unbrauchbar)')
  else
    Log('DOOM: Ersatz-Engine mit erzeugten Assets (kein WAD gefunden)');
  LogGeometry(Parent);
end;

procedure TDoomPlugin.CloseGame;
begin
  { Ein evtl. anstehendes verzoegertes Schliessen ist damit erledigt. }
  if gCloseTimer <> 0 then
  begin
    KillTimer(0, gCloseTimer);
    gCloseTimer := 0;
  end;
  if FWin <> nil then FWin.Stop;
  { Erst das DOOM-Kindfenster weg, dann den Reiter - sonst zerstoerte der
    Reiter das Kind unter uns. }
  FreeAndNil(FWin);
  FreeAndNil(FEngine);
  FreeAndNil(FCore);
  RemoveDoomTab;
  FReal := False;
end;

procedure TDoomPlugin.OnGameClosed(ASender: TAmsGameWindow; AElapsedMs: Integer);
begin
  if FWin <> nil then FWin.Stop;
end;

{ --------------------------------------------------------------- Bildschritt - }

procedure TDoomPlugin.OnFrame(ASender: TAmsGameWindow; AElapsedMs: Integer);
var
  vk: Integer;
  cur, foc: Boolean;
  fb: Pointer;
  fw, fh: Integer;
  In_: TAmsDoomInput;
begin
  if not FFramesLogged then
  begin
    FFramesLogged := True;
    Log('DOOM: Bildschleife laeuft (erster Frame).');
  end;

  { Der Host frisst die normalen Tastennachrichten (nur mit Alt gedrueckte
    Systemtasten kommen durch), also lesen wir den PHYSISCHEN Tastenzustand
    direkt - das kann kein Host abfangen. Nur wenn unsere Flaeche den Fokus
    hat, sonst wuerde DOOM auf Tippen anderswo reagieren. Aenderungen werden
    als Kante an den Kern gemeldet. }
  foc := (ASender.Handle <> 0) and (GetFocus = ASender.Handle);
  for vk := 1 to 255 do
  begin
    cur := foc and ((GetAsyncKeyState(vk) and $8000) <> 0);
    if cur <> FKeyState[vk] then
    begin
      FKeyState[vk] := cur;
      if FReal and (FCore <> nil) then
        case vk of
          { Maus wie in DOOM: links feuern, rechts benutzen. Unabhaengig von
            der Tastatur - falls der Host Strg global abfaengt, schiesst man so
            trotzdem. }
          VK_LBUTTON: FCore.Key(cur, VK_CONTROL);
          VK_RBUTTON: FCore.Key(cur, VK_SPACE);
          3, 4, 5, 6: ;   { andere Maus-/Sondertasten ignorieren }
        else
          FCore.Key(cur, vk);
        end;
    end;
  end;

  if FReal and (FCore <> nil) then
  begin
    if not FCore.Tick then
    begin
      FDead := True;
      Exit;
    end;
    { Hat der Spieler DOOM ueber das Menue beendet? Dann die Flaeche schliessen -
      NICHT hier freigeben (wir stecken in deren Timer), sondern WM_CLOSE
      posten; das raeumt sicher auf. }
    if FCore.WantsQuit then
    begin
      Log('DOOM: im Menue beendet - Reiter wird geschlossen');
      ASender.Stop;   { sofort keine weiteren Ticks mehr }
      { NICHT hier schliessen (wir stecken in der Schleife von FWin) - verzoegert
        aus der Host-Nachrichtenschleife heraus, das raeumt auch den Reiter ab. }
      if gCloseTimer = 0 then gCloseTimer := SetTimer(0, 0, 10, @DeferredClose);
      Exit;
    end;
    fb := FCore.Framebuffer(fw, fh);
    if (fb <> nil) and (fw = ASender.Width) and (fh = ASender.Height) then
      Move(fb^, ASender.Bits^, fw * fh * SizeOf(TAmsPixel));
    Exit;
  end;

  { Ersatz-Engine - liest denselben gepollten Zustand. }
  if FEngine = nil then Exit;
  FillChar(In_, SizeOf(In_), 0);
  In_.GoForward   := FKeyState[Ord('W')] or FKeyState[VK_UP];
  In_.GoBackward  := FKeyState[Ord('S')] or FKeyState[VK_DOWN];
  In_.StrafeLeft  := FKeyState[Ord('A')];
  In_.StrafeRight := FKeyState[Ord('D')];
  In_.TurnLeft    := FKeyState[VK_LEFT];
  In_.TurnRight   := FKeyState[VK_RIGHT];
  In_.Fire        := FKeyState[VK_CONTROL] or FKeyState[VK_SPACE] or
                     FKeyState[VK_LBUTTON];
  In_.Use         := FKeyState[Ord('E')] or FKeyState[VK_RETURN];
  In_.Run         := FKeyState[VK_SHIFT];
  FEngine.Tick(In_, AElapsedMs);
  FEngine.Render(ASender.Bits, ASender.Width, ASender.Height);
end;

{ ----------------------------------------------------------------- HUD ------- }

procedure DrawText(ADC: HDC; AX, AY: Integer; const AText: string; AColor: COLORREF);
var W: WideString;
begin
  W := WideString(AText);
  SetTextColor(ADC, AColor);
  TextOutW(ADC, AX, AY, PWideChar(W), Length(W));
end;

procedure TDoomPlugin.OnOverlay(ASender: TAmsGameWindow; ADC: HDC;
  ACW, ACH: Integer);
var
  Font, OldFont: HFONT;
  S: string;
begin
  { Der echte Kern hat seine eigene Statusleiste - nur bei Problemen etwas
    einblenden. Die Ersatz-Engine bekommt ihr HUD hier. }
  Font := CreateFontW(-15, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
    FIXED_PITCH or FF_MODERN, PWideChar(WideString('Consolas')));
  OldFont := SelectObject(ADC, Font);
  SetBkMode(ADC, TRANSPARENT);

  if FReal then
  begin
    if FDead then
    begin
      DrawText(ADC, 13, 11, 'DOOM-Kern gestoppt.', RGB(0, 0, 0));
      DrawText(ADC, 12, 10, 'DOOM-Kern gestoppt.', RGB(255, 80, 80));
    end;
  end
  else if FEngine <> nil then
  begin
    S := Format('HP %3d%%   MUN %3d   KILLS %d/%d',
                [FEngine.Health, FEngine.Ammo, FEngine.Kills, FEngine.Monsters]);
    DrawText(ADC, 13, ACH - 27, S, RGB(0, 0, 0));
    DrawText(ADC, 12, ACH - 28, S, RGB(255, 220, 60));
    if FEngine.StatusMessage <> '' then
    begin
      DrawText(ADC, 13, 11, FEngine.StatusMessage, RGB(0, 0, 0));
      DrawText(ADC, 12, 10, FEngine.StatusMessage, RGB(255, 255, 255));
    end;
    DrawText(ADC, 12, 30,
      'Ersatz-Engine. Fuer echtes DOOM: doomcore.dll + DOOM1.WAD neben das Plugin.',
      RGB(180, 180, 180));
  end;

  SelectObject(ADC, OldFont);
  DeleteObject(Font);
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(TDoomPlugin);
end.
