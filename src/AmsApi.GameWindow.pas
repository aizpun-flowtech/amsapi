unit AmsApi.GameWindow;

{ ============================================================================
  AmsApi.GameWindow - eine Bildpuffer-Flaeche fuer Plugins im laufenden AMS

  Was der Host NICHT mitbringt: eine Flaeche, auf die ein Plugin Pixel malt.
  Kein VCL-TImage (fremder Heap, fremde RTL), sondern reines Win32 - genau der
  Weg, den schon das Suchfenster (samples\UiTweaks\finder.inc) und der
  Notnagel-Button in AmsApi.Plugin gehen.

  Der Kern ist eine DIBSection (32 Bit, BGRA, top-down): Windows gibt dafuer
  einen Zeiger auf die rohen Pixel heraus, in den das Plugin unmittelbar
  schreibt. Praesentiert wird mit StretchDIBits - ganzzahlig hochskaliert, mit
  schwarzem Rand, damit das Seitenverhaeltnis bleibt (320x200 ist 4:3 gemeint,
  nicht 8:5).

  Ein Bildpuffer allein ist noch kein Spiel. Deshalb bringt die Klasse mit:
    - eine Bildschleife ueber SetTimer (MODELESS - die Nachrichtenschleife
      gehoert AMS, wir haengen uns nur hinein; ein modaler Dialog wuerde den
      Host anhalten)
    - Tastaturzustand (gedrueckt/nicht) UND eine Kante-Warteschlange fuer
      "gerade gedrueckt", beides nur waehrend das Fenster den Fokus hat
    - eine Zeichenflaeche fuer Text ueber den Pixeln (HUD) nach dem Blit

  Das Fenster traegt seinen Besitzer in GWL_USERDATA - damit ist die Klasse
  wiederverwendbar und nicht auf eine einzige globale Instanz festgelegt.

  PFLICHT beim Entladen: Free ruft DestroyWindow, KillTimer, DeleteObject und
  UnregisterClass. Die Fensterprozedur liegt in diesem Modul; ein
  stehengebliebenes Fenster waere nach dem Entladen ein Sprung in
  freigegebenen Speicher.

  Ohne AMS testbar: das Fenster laesst sich versteckt und ausserhalb des
  Bildes erzeugen, Frames rechnen und den Puffer pruefen (tests\doomdemo.lpr).
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils;

type
  { Ein Pixel im Bildpuffer: gepackt als $00RRGGBB. So liegt es im Speicher
    als B,G,R,0 - genau, was eine BI_RGB-DIB mit 32 Bit erwartet. }
  TAmsPixel = LongWord;
  PAmsPixel = ^TAmsPixel;

  { Array-typisierter Zeiger, damit das Indizieren ohne Zeigerarithmetik
    sauber bleibt. Die Obergrenze ist nur ein Platzhalter fuers Typsystem. }
  TAmsPixelBuf = array[0..$3FFFFFF] of TAmsPixel;
  PAmsPixelBuf = ^TAmsPixelBuf;

  TAmsGameWindow = class;

  { Ein Bildschritt: hier rechnet und zeichnet das Plugin. AElapsedMs ist die
    Zeit seit dem letzten Schritt (fuer bildratenunabhaengige Bewegung). }
  TAmsFrameEvent = procedure(ASender: TAmsGameWindow; AElapsedMs: Integer) of object;

  { Nach dem Blit, auf dem Fenster-DC - fuer Text/HUD ueber den Pixeln. }
  TAmsOverlayEvent = procedure(ASender: TAmsGameWindow; ADC: HDC;
    AClientW, AClientH: Integer) of object;

  TAmsGameWindow = class
  private
    FWnd: HWND;
    FDC: HDC;                 { Speicher-DC mit der DIB }
    FBmp: HBITMAP;           { die DIBSection }
    FOldBmp: HBITMAP;
    FBits: PAmsPixelBuf;     { rohe Pixel, FWidth*FHeight, top-down }
    FWidth, FHeight: Integer;
    FTimer: UINT_PTR;
    FIntervalMs: Integer;
    FRunning: Boolean;
    FLastTick: QWord;
    FOnFrame: TAmsFrameEvent;
    FOnOverlay: TAmsOverlayEvent;
    FOnClose: TAmsFrameEvent;
    FClassAtom: ATOM;
    FClassNameW: WideString;
    FTitle: WideString;
    FKeys: array[0..255] of Boolean;
    FQueue: array[0..63] of Word;
    FQHead, FQTail: Integer;
    { Kanten-Warteschlange fuer VOLLE Ereignisse (auch Loslassen und Autorepeat) -
      das braucht ein Host wie DOOM, der seinen eigenen Tastenzustand fuehrt. }
    FEvtVk: array[0..127] of Word;
    FEvtDown: array[0..127] of Boolean;
    FEvtHead, FEvtTail: Integer;
    FHasFocus: Boolean;
    FMouseDX: Integer;
    FClosed: Boolean;
    FChild: Boolean;
    FBackColor: COLORREF;   { Rand um das skalierte Bild (Letterbox) }
    FBackBrush: HBRUSH;
    procedure SetBackColor(AColor: COLORREF);
    procedure BuildDib(AW, AH: Integer);
    procedure FreeDib;
    procedure PushKey(AVk: Word);
    procedure PushEvt(AVk: Word; ADown: Boolean);
    procedure InstallKbHook;
    procedure RemoveKbHook;
    procedure DoTick;
  protected
    function WndProc(AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM): LRESULT; virtual;
  public
    { Erzeugt das Fenster. AWidth/AHeight ist die Aufloesung des Bildpuffers
      (z.B. 320x200); AScale die anfaengliche Vergroesserung fuer die
      Fenstergroesse. AOwner darf das AMS-Hauptfenster sein.
      AChild = True erzeugt statt eines eigenen Fensters ein WS_CHILD-Fenster
      IN AOwner (die Flaeche sitzt dann im Host, kein separates Fenster) -
      genau das fuer "DOOM in einem Tab von AMS". FitToParent fuellt es aus. }
    constructor Create(const ATitle: string; AWidth, AHeight: Integer;
      AOwner: HWND = 0; AScale: Integer = 3; AChild: Boolean = False);
    destructor Destroy; override;

    { Nur im Child-Modus: das Fenster auf die Client-Flaeche seines Elters
      setzen (z.B. nach dem Einhaengen in einen Tab oder bei dessen WM_SIZE). }
    procedure FitToParent;
    { Elter zur Laufzeit wechseln (Einhaengen in einen gefundenen Container). }
    procedure Reparent(AParent: HWND);

    { Bildpuffer sofort auf das Fenster bringen (ganzzahlig skaliert,
      4:3-Rand). Wird von der Schleife nach jedem Frame selbst gerufen. }
    procedure Present;

    { Schleife starten/anhalten. AIntervalMs z.B. 28 (~35 fps, DOOM-Takt). }
    procedure Start(AIntervalMs: Integer = 28);
    procedure Stop;

    { Fenster anzeigen/verstecken/nach vorn. }
    procedure Show;
    procedure Hide;
    procedure ToForeground;

    { Ganze Flaeche mit einer Farbe fuellen. }
    procedure Clear(AColor: TAmsPixel);
    { Ein Pixel setzen, mit Bereichspruefung. }
    procedure SetPixel(AX, AY: Integer; AColor: TAmsPixel); inline;
    { Zeiger auf den Anfang einer Zeile (nil bei Bereichsfehler). }
    function ScanLine(AY: Integer): PAmsPixel;

    { Tastatur: ist eine Taste gerade gedrueckt (nur bei Fokus). AVk ist ein
      VK_-Code aus Windows. }
    function KeyDown(AVk: Word): Boolean;
    { Naechste "gerade gedrueckt"-Kante aus der Warteschlange (True = geliefert). }
    function PopKeyPress(out AVk: Word): Boolean;
    { Naechstes VOLLES Tastenereignis: ADown sagt gedrueckt/losgelassen. Autorepeat
      liefert weitere Down-Ereignisse. Fuer Hosts mit eigenem Tastenzustand. }
    function PopKeyEvent(out AVk: Word; out ADown: Boolean): Boolean;
    { Aufgelaufene Mausbewegung in X seit dem letzten Abruf (fuer Drehen). }
    function TakeMouseDeltaX: Integer;

    property Handle: HWND read FWnd;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Bits: PAmsPixelBuf read FBits;
    property Running: Boolean read FRunning;
    property HasFocus: Boolean read FHasFocus;
    property Closed: Boolean read FClosed;

    { Farbe des Randes um das (seitenverhaeltnisrichtig) skalierte Bild.
      Standard Schwarz. }
    property BackColor: COLORREF read FBackColor write SetBackColor;

    property OnFrame: TAmsFrameEvent read FOnFrame write FOnFrame;
    property OnOverlay: TAmsOverlayEvent read FOnOverlay write FOnOverlay;
    { Wird gerufen, wenn der Anwender das Fenster schliesst (WM_CLOSE). Das
      Plugin kann darin z.B. die Schleife anhalten. Das Fenster selbst wird
      danach zerstoert. }
    property OnClose: TAmsFrameEvent read FOnClose write FOnClose;
  end;

{ Bequeme Farbmischung, alles auf $00RRGGBB. }
function AmsRGB(AR, AG, AB: Byte): TAmsPixel; inline;
{ Farbe mit AFactor/256 abdunkeln (Tiefen-Schattierung wie in DOOM). }
function AmsShade(AColor: TAmsPixel; AFactor: Integer): TAmsPixel; inline;

implementation

uses
  AmsApi.Log;

const
  GAMEWIN_CLASS_PREFIX = 'AmsGameWindow_';

function AmsRGB(AR, AG, AB: Byte): TAmsPixel;
begin
  Result := (TAmsPixel(AR) shl 16) or (TAmsPixel(AG) shl 8) or TAmsPixel(AB);
end;

function AmsShade(AColor: TAmsPixel; AFactor: Integer): TAmsPixel;
var
  R, G, B: Integer;
begin
  if AFactor >= 256 then Exit(AColor);
  if AFactor < 0 then AFactor := 0;
  R := ((AColor shr 16) and $FF) * AFactor shr 8;
  G := ((AColor shr 8) and $FF) * AFactor shr 8;
  B := (AColor and $FF) * AFactor shr 8;
  Result := (TAmsPixel(R) shl 16) or (TAmsPixel(G) shl 8) or TAmsPixel(B);
end;

{ ------------------------------------------------------- Tastatur-Sperre ---
  Der Host (AMS) wertet Tastenanschlaege in seiner eigenen Nachrichtenschleife
  aus - Menue-Kuerzel, Ribbon-Beschleuniger usw. -, BEVOR sie unser Fenster
  erreichen. Solange die Spielflaeche den Fokus hat, wuerde also z.B. "Y" (DOOM:
  beenden) zusaetzlich eine AMS-Funktion ausloesen.

  Ein thread-lokaler WH_GETMESSAGE-Hook faengt die Tastennachrichten VOR der
  Schleife ab und macht sie zu WM_NULL. Damit sieht AMS sie nicht mehr; das
  Spiel liest die Tastatur ohnehin direkt (GetAsyncKeyState), nicht ueber diese
  Nachrichten. Der Hook wirkt nur, wenn unsere Flaeche den Fokus hat, und wird
  bei Fokusverlust und beim Zerstoeren wieder entfernt (ein stehengebliebener
  Hook in ein entladenes Modul waere toedlich). }
var
  gKbHook: HHOOK = 0;
  gKbHookWnd: HWND = 0;

function GameKbHook(ACode: Integer; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
var
  M: PMsg;
begin
  if (ACode = HC_ACTION) and (AWParam = PM_REMOVE) and
     (gKbHookWnd <> 0) and (GetFocus = gKbHookWnd) then
  begin
    M := PMsg(ALParam);
    if M <> nil then
      case M^.message of
        WM_KEYDOWN, WM_KEYUP, WM_CHAR, WM_DEADCHAR,
        WM_SYSKEYDOWN, WM_SYSKEYUP, WM_SYSCHAR:
          M^.message := WM_NULL;
      end;
  end;
  Result := CallNextHookEx(gKbHook, ACode, AWParam, ALParam);
end;

{ ------------------------------------------------------------ Fensterprozedur }

{ Alle Instanzen teilen sich eine Fensterprozedur; die Instanz haengt in
  GWL_USERDATA. Beim WM_CREATE kommt sie ueber lpCreateParams herein. }
function GameWndProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
var
  Inst: TAmsGameWindow;
begin
  if AMsg = WM_CREATE then
  begin
    { lpCreateParams ist das erste Feld von CREATESTRUCT (Offset 0) - so
      unabhaengig davon, wie die RTL den Record gerade benennt. }
    SetWindowLongW(AWnd, GWL_USERDATA, LONG(PPtrInt(ALParam)^));
    Exit(0);
  end;

  Inst := TAmsGameWindow(Pointer(PtrInt(GetWindowLongW(AWnd, GWL_USERDATA))));
  if Inst = nil then
    Exit(DefWindowProcW(AWnd, AMsg, AWParam, ALParam));

  try
    Result := Inst.WndProc(AMsg, AWParam, ALParam);
  except
    on E: Exception do
    begin
      AmsLog('GameWindow WndProc EXCEPTION: ' + E.Message);
      Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
    end;
  end;
end;

{ ---------------------------------------------------------------- TAmsGameWindow }

constructor TAmsGameWindow.Create(const ATitle: string; AWidth, AHeight: Integer;
  AOwner: HWND; AScale: Integer; AChild: Boolean);
var
  WC: WNDCLASSW;
  R: TRect;
  StyleEx, Style: DWORD;
begin
  inherited Create;
  FWnd := 0;
  FWidth := AWidth;
  FHeight := AHeight;
  FIntervalMs := 28;
  FQHead := 0;
  FQTail := 0;
  FEvtHead := 0;
  FEvtTail := 0;
  FClosed := False;
  FChild := AChild;
  FBackColor := RGB(0, 0, 0);
  FBackBrush := 0;
  if FWidth < 1 then FWidth := 1;
  if FHeight < 1 then FHeight := 1;
  if AScale < 1 then AScale := 1;
  FTitle := WideString(ATitle);

  { Klassenname eindeutig je Modul (HInstance) - zwei Plugins duerfen sich
    nicht in die Quere kommen. }
  FClassNameW := WideString(GAMEWIN_CLASS_PREFIX + IntToHex(PtrUInt(HInstance), 8));

  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @GameWndProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursorW(0, LPCWSTR(IDC_ARROW));
  WC.hbrBackground := HBRUSH(GetStockObject(BLACK_BRUSH));
  WC.lpszClassName := PWideChar(FClassNameW);
  { Doppelte Registrierung ist kein Fehler - beim zweiten Mal wird die
    vorhandene Klasse benutzt. }
  FClassAtom := RegisterClassW(WC);

  BuildDib(FWidth, FHeight);

  StyleEx := 0;
  if FChild then
  begin
    { WS_CHILD: sitzt IN AOwner, kein eigenes Fenster. Groesse setzt
      FitToParent. WS_TABSTOP, damit es den Fokus (und damit die Tastatur)
      annehmen darf. }
    Style := WS_CHILD or WS_VISIBLE or WS_CLIPSIBLINGS or WS_TABSTOP;
    FWnd := CreateWindowExW(StyleEx, PWideChar(FClassNameW), PWideChar(FTitle),
      Style, 0, 0, FWidth, FHeight, AOwner, 0, HInstance, Self);
  end
  else
  begin
    { Fenstergroesse so, dass der Client den skalierten Puffer aufnimmt. }
    R.Left := 0; R.Top := 0;
    R.Right := FWidth * AScale;
    R.Bottom := FHeight * AScale;
    Style := WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN;
    AdjustWindowRectEx(R, Style, False, StyleEx);
    FWnd := CreateWindowExW(StyleEx, PWideChar(FClassNameW), PWideChar(FTitle),
      Style, CW_USEDEFAULT, CW_USEDEFAULT, R.Right - R.Left, R.Bottom - R.Top,
      AOwner, 0, HInstance, Self);
  end;
  if FWnd = 0 then
  begin
    AmsLogFmt('GameWindow: CreateWindowExW fehlgeschlagen, Fehler %d',
              [GetLastError]);
    Exit;
  end;
  { Zur Sicherheit auch hier setzen - falls WM_CREATE das noch nicht tat. }
  SetWindowLongW(FWnd, GWL_USERDATA, LONG(PtrInt(Self)));
  if FChild then FitToParent;
end;

procedure TAmsGameWindow.FitToParent;
var
  Parent: HWND;
  R: TRect;
begin
  if (FWnd = 0) then Exit;
  Parent := GetParent(FWnd);
  if (Parent = 0) or not GetClientRect(Parent, R) then Exit;
  MoveWindow(FWnd, 0, 0, R.Right - R.Left, R.Bottom - R.Top, True);
end;

procedure TAmsGameWindow.Reparent(AParent: HWND);
begin
  if FWnd = 0 then Exit;
  Windows.SetParent(FWnd, AParent);
  FChild := AParent <> 0;
  if FChild then FitToParent;
end;

destructor TAmsGameWindow.Destroy;
begin
  Stop;
  RemoveKbHook;
  if FWnd <> 0 then
  begin
    { Besitzer loesen, damit eine spaete Nachricht nicht mehr hierher findet. }
    SetWindowLongW(FWnd, GWL_USERDATA, 0);
    DestroyWindow(FWnd);
    FWnd := 0;
  end;
  FreeDib;
  if FBackBrush <> 0 then
  begin
    DeleteObject(FBackBrush);
    FBackBrush := 0;
  end;
  if FClassAtom <> 0 then
    UnregisterClassW(PWideChar(FClassNameW), HInstance);
  inherited Destroy;
end;

procedure TAmsGameWindow.BuildDib(AW, AH: Integer);
var
  BI: BITMAPINFO;
  Bits: Pointer;
  ScreenDC: HDC;
begin
  FreeDib;
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  BI.bmiHeader.biWidth := AW;
  { negativ = top-down: Zeile 0 ist oben, so wie man denkt }
  BI.bmiHeader.biHeight := -AH;
  BI.bmiHeader.biPlanes := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;

  ScreenDC := GetDC(0);
  try
    FDC := CreateCompatibleDC(ScreenDC);
  finally
    ReleaseDC(0, ScreenDC);
  end;

  Bits := nil;
  FBmp := CreateDIBSection(FDC, BI, DIB_RGB_COLORS, Bits, 0, 0);
  if (FBmp = 0) or (Bits = nil) then
  begin
    AmsLog('GameWindow: CreateDIBSection fehlgeschlagen');
    FBits := nil;
    Exit;
  end;
  FBits := PAmsPixelBuf(Bits);
  FOldBmp := SelectObject(FDC, FBmp);
  Clear(0);
end;

procedure TAmsGameWindow.FreeDib;
begin
  if FDC <> 0 then
  begin
    if FOldBmp <> 0 then SelectObject(FDC, FOldBmp);
    FOldBmp := 0;
    if FBmp <> 0 then
    begin
      DeleteObject(FBmp);
      FBmp := 0;
    end;
    DeleteDC(FDC);
    FDC := 0;
  end;
  FBits := nil;
end;

procedure TAmsGameWindow.Clear(AColor: TAmsPixel);
var
  i, n: Integer;
begin
  if FBits = nil then Exit;
  n := FWidth * FHeight;
  for i := 0 to n - 1 do FBits^[i] := AColor;
end;

procedure TAmsGameWindow.SetPixel(AX, AY: Integer; AColor: TAmsPixel);
begin
  if FBits = nil then Exit;
  if (AX < 0) or (AY < 0) or (AX >= FWidth) or (AY >= FHeight) then Exit;
  FBits^[AY * FWidth + AX] := AColor;
end;

function TAmsGameWindow.ScanLine(AY: Integer): PAmsPixel;
begin
  if (FBits = nil) or (AY < 0) or (AY >= FHeight) then Exit(nil);
  Result := @FBits^[AY * FWidth];
end;

procedure TAmsGameWindow.SetBackColor(AColor: COLORREF);
begin
  if FBackColor = AColor then Exit;
  FBackColor := AColor;
  if FBackBrush <> 0 then
  begin
    DeleteObject(FBackBrush);
    FBackBrush := 0;
  end;
  if FWnd <> 0 then InvalidateRect(FWnd, nil, True);
end;

procedure TAmsGameWindow.Present;
var
  ClientR, BR: TRect;
  CW, CH, DW, DH, AspW, AspH, OX, OY: Integer;
  S: Double;
  WndDC: HDC;

  procedure FillBorder(AX, AY, AW, AH: Integer);
  begin
    if (AW <= 0) or (AH <= 0) then Exit;
    BR.Left := AX; BR.Top := AY; BR.Right := AX + AW; BR.Bottom := AY + AH;
    FillRect(WndDC, BR, FBackBrush);
  end;

begin
  if (FWnd = 0) or (FDC = 0) then Exit;
  if not GetClientRect(FWnd, ClientR) then Exit;
  CW := ClientR.Right - ClientR.Left;
  CH := ClientR.Bottom - ClientR.Top;
  if (CW <= 0) or (CH <= 0) then Exit;

  { Seitenverhaeltnisrichtig FUELLEN (nicht nur ganzzahlig): das Bild wird so
    gross wie moeglich gezogen, dass es hineinpasst. Der Puffer ist 320x200
    bzw. 640x400 (Pixel 8:5), gemeint aber 4:3 - deshalb die Hoehe wie *6/5
    behandeln, damit das Bild nicht flach wirkt. }
  AspW := FWidth;
  AspH := (FHeight * 6) div 5;             { 4:3 }
  S := CW / AspW;
  if (CH / AspH) < S then S := CH / AspH;
  if S <= 0 then S := 1;
  DW := Round(AspW * S);
  DH := Round(AspH * S);
  if DW > CW then DW := CW;
  if DH > CH then DH := CH;
  OX := (CW - DW) div 2;
  OY := (CH - DH) div 2;

  WndDC := GetDC(FWnd);
  if WndDC = 0 then Exit;
  try
    { Rand um das Bild in der eingestellten Farbe (Standard Schwarz). }
    if FBackBrush = 0 then FBackBrush := CreateSolidBrush(FBackColor);
    if OX > 0 then
    begin
      FillBorder(0, 0, OX, CH);
      FillBorder(OX + DW, 0, CW - OX - DW, CH);
    end;
    if OY > 0 then
    begin
      FillBorder(0, 0, CW, OY);
      FillBorder(0, OY + DH, CW, CH - OY - DH);
    end;

    SetStretchBltMode(WndDC, COLORONCOLOR);
    StretchBlt(WndDC, OX, OY, DW, DH, FDC, 0, 0, FWidth, FHeight, SRCCOPY);

    if Assigned(FOnOverlay) then
    try
      FOnOverlay(Self, WndDC, CW, CH);
    except
      on E: Exception do AmsLog('GameWindow Overlay EXCEPTION: ' + E.Message);
    end;
  finally
    ReleaseDC(FWnd, WndDC);
  end;
end;

procedure TAmsGameWindow.DoTick;
var
  Now: QWord;
  Elapsed: Integer;
begin
  Now := GetTickCount64;
  Elapsed := Integer(Now - FLastTick);
  FLastTick := Now;
  if Elapsed < 0 then Elapsed := FIntervalMs;
  if Elapsed > 250 then Elapsed := 250;   { nach einer Pause nicht springen }

  if Assigned(FOnFrame) then
  try
    FOnFrame(Self, Elapsed);
  except
    on E: Exception do AmsLog('GameWindow OnFrame EXCEPTION: ' + E.Message);
  end;
  Present;
end;

procedure TAmsGameWindow.Start(AIntervalMs: Integer);
begin
  if FWnd = 0 then Exit;
  if AIntervalMs < 5 then AIntervalMs := 5;
  FIntervalMs := AIntervalMs;
  FLastTick := GetTickCount64;
  if FTimer = 0 then
    FTimer := SetTimer(FWnd, 1, FIntervalMs, nil);
  FRunning := FTimer <> 0;
end;

procedure TAmsGameWindow.Stop;
begin
  if (FTimer <> 0) and (FWnd <> 0) then
    KillTimer(FWnd, FTimer);
  FTimer := 0;
  FRunning := False;
end;

procedure TAmsGameWindow.Show;
begin
  if FWnd = 0 then Exit;
  if FChild then FitToParent;
  ShowWindow(FWnd, SW_SHOW);
  UpdateWindow(FWnd);
  ToForeground;
end;

procedure TAmsGameWindow.Hide;
begin
  if FWnd <> 0 then ShowWindow(FWnd, SW_HIDE);
end;

procedure TAmsGameWindow.ToForeground;
begin
  if FWnd = 0 then Exit;
  if FChild then
  begin
    { Als Kind KEIN SetForegroundWindow (das gilt Top-Level-Fenstern). Statt
      dessen im Z-Stapel der Geschwister nach ganz oben - sonst liegt die
      Flaeche hinter den Bedienelementen des Hosts und man sieht nichts. }
    SetWindowPos(FWnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE or SWP_SHOWWINDOW);
    BringWindowToTop(FWnd);
    SetFocus(FWnd);
  end
  else
  begin
    SetForegroundWindow(FWnd);
    SetFocus(FWnd);
  end;
end;

procedure TAmsGameWindow.PushKey(AVk: Word);
var
  NextTail: Integer;
begin
  NextTail := (FQTail + 1) and 63;
  if NextTail = FQHead then Exit;    { voll - aelteste Kante fallenlassen }
  FQueue[FQTail] := AVk;
  FQTail := NextTail;
end;

procedure TAmsGameWindow.PushEvt(AVk: Word; ADown: Boolean);
var
  NextTail: Integer;
begin
  NextTail := (FEvtTail + 1) and 127;
  if NextTail = FEvtHead then Exit;
  FEvtVk[FEvtTail] := AVk;
  FEvtDown[FEvtTail] := ADown;
  FEvtTail := NextTail;
end;

function TAmsGameWindow.PopKeyEvent(out AVk: Word; out ADown: Boolean): Boolean;
begin
  AVk := 0; ADown := False;
  if FEvtHead = FEvtTail then Exit(False);
  AVk := FEvtVk[FEvtHead];
  ADown := FEvtDown[FEvtHead];
  FEvtHead := (FEvtHead + 1) and 127;
  Result := True;
end;

function TAmsGameWindow.KeyDown(AVk: Word): Boolean;
begin
  if AVk > 255 then Exit(False);
  Result := FHasFocus and FKeys[AVk];
end;

function TAmsGameWindow.PopKeyPress(out AVk: Word): Boolean;
begin
  AVk := 0;
  if FQHead = FQTail then Exit(False);
  AVk := FQueue[FQHead];
  FQHead := (FQHead + 1) and 63;
  Result := True;
end;

function TAmsGameWindow.TakeMouseDeltaX: Integer;
begin
  Result := FMouseDX;
  FMouseDX := 0;
end;

procedure TAmsGameWindow.InstallKbHook;
begin
  if FWnd = 0 then Exit;
  gKbHookWnd := FWnd;
  if gKbHook = 0 then
    gKbHook := SetWindowsHookExW(WH_GETMESSAGE, @GameKbHook, 0,
                                 GetCurrentThreadId);
end;

procedure TAmsGameWindow.RemoveKbHook;
begin
  { Nur abmelden, wenn WIR den Hook halten. }
  if gKbHookWnd = FWnd then gKbHookWnd := 0;
  if (gKbHook <> 0) and (gKbHookWnd = 0) then
  begin
    UnhookWindowsHookEx(gKbHook);
    gKbHook := 0;
  end;
end;

function TAmsGameWindow.WndProc(AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT;
var
  Vk: Word;
  i: Integer;
begin
  case AMsg of
    WM_TIMER:
      begin
        DoTick;
        Exit(0);
      end;
    WM_PAINT:
      begin
        { Nur den letzten Frame erneut aufziehen; Validieren nicht vergessen. }
        ValidateRect(FWnd, nil);
        Present;
        Exit(0);
      end;
    WM_ERASEBKGND:
      { Wir malen die ganze Flaeche selbst - kein Flackern durch Loeschen. }
      Exit(1);
    WM_KEYDOWN, WM_SYSKEYDOWN:
      begin
        Vk := Word(AWParam);
        if Vk <= 255 then
        begin
          { Nur die steigende Flanke in die einfache Warteschlange (Bit 30 = war
            schon gedrueckt = Autorepeat). }
          if (ALParam and (1 shl 30)) = 0 then PushKey(Vk);
          FKeys[Vk] := True;
        end;
        { Volles Ereignis inkl. Autorepeat - ein Host wie DOOM will das. }
        PushEvt(Vk, True);
        { Nur als eigenes Fenster schliesst Esc; eingebettet gehoert Esc dem
          Spiel (DOOM-Menue). }
        if (Vk = VK_ESCAPE) and not FChild then
        begin
          PostMessageW(FWnd, WM_CLOSE, 0, 0);
          Exit(0);
        end;
        { ALT nicht ins Systemmenue laufen lassen. }
        if AMsg = WM_SYSKEYDOWN then Exit(0);
        Exit(0);
      end;
    WM_KEYUP, WM_SYSKEYUP:
      begin
        Vk := Word(AWParam);
        if Vk <= 255 then FKeys[Vk] := False;
        PushEvt(Vk, False);
        if AMsg = WM_SYSKEYUP then Exit(0);
        Exit(0);
      end;
    WM_SIZE:
      begin
        { Als Child mitwachsen, wenn der Container (Tab) seine Groesse aendert. }
        Exit(0);
      end;
    WM_GETDLGCODE:
      { ENTSCHEIDEND im Host: sonst frisst dessen Dialog-Navigation die
        Pfeil-/Tabtasten, BEVOR sie hier ankommen - nur mit Alt gedrueckte
        Tasten (Systemtasten) rutschen durch. DLGC_WANTALLKEYS | WANTARROWS |
        WANTTAB | WANTCHARS ($0087) sagt Windows: alle Tasten gehoeren mir. }
      Exit(LRESULT($0087));
    WM_MOUSEACTIVATE:
      { Klick aktiviert die Flaeche (und holt so die Tastatur). }
      Exit(MA_ACTIVATE);
    WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN:
      begin
        { Ein rohes Kindfenster bekommt den Fokus NICHT von allein - ohne das
          hier kommen keine Tastenanschlaege an, das Spiel laesst sich nicht
          steuern. Deshalb bei jedem Klick den Fokus holen. }
        SetFocus(FWnd);
        Exit(0);
      end;
    WM_SETFOCUS:
      begin
        FHasFocus := True;
        { Tastatur fuer den Host sperren, solange wir den Fokus haben. }
        InstallKbHook;
        Exit(0);
      end;
    WM_KILLFOCUS:
      begin
        FHasFocus := False;
        RemoveKbHook;
        { Alle Tasten loslassen, sonst "klemmt" die Bewegung nach Fokusverlust. }
        for i := 0 to 255 do FKeys[i] := False;
        { Und alle offenen Tasten als "losgelassen" an einen Host melden. }
        for i := 0 to 255 do PushEvt(Word(i), False);
        Exit(0);
      end;
    WM_CLOSE:
      begin
        Stop;
        RemoveKbHook;
        if Assigned(FOnClose) then
        try
          FOnClose(Self, 0);
        except
          on E: Exception do AmsLog('GameWindow OnClose EXCEPTION: ' + E.Message);
        end;
        FClosed := True;
        SetWindowLongW(FWnd, GWL_USERDATA, 0);
        DestroyWindow(FWnd);
        FWnd := 0;
        Exit(0);
      end;
    WM_DESTROY:
      begin
        FWnd := 0;
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(FWnd, AMsg, AWParam, ALParam);
end;

end.
