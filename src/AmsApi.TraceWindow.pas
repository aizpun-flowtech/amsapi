unit AmsApi.TraceWindow;

{ ============================================================================
  AmsApi.TraceWindow - Verlaufsfenster, das mitlaeuft

  Ein Fenster im laufenden AMS, in dem Zeile fuer Zeile erscheint, was der
  Host gerade tut: welcher Klick, welche Action, welches SQL, wie lange.

  ZUSEHEN GEHT OHNE AUFZEICHNEN. Das Fenster braucht keine Datei; es holt
  sich die Zeilen aus dem Ringpuffer von AmsApi.Trace. Wer den Verlauf
  behalten will, schaltet im Fenster "Aufzeichnen" ein - dann laeuft
  zusaetzlich die TSV-Datei mit. Ausschalten geht jederzeit, das Zusehen
  laeuft weiter.

  Reines Win32 mit den Standardklassen BUTTON, LISTBOX und STATIC. Die VCL
  des Hosts steht einem FPC-Plugin nicht zur Verfuegung (getrennte Heaps,
  fremde RTL). Denselben Weg gehen schon der Notnagel-Button in
  AmsApi.Plugin und das Suchfenster in samples\UiTweaks.

  Das Fenster ist MODELESS - AMS pumpt die Nachrichten seiner eigenen
  Schleife. Ein modaler Dialog wuerde den Host anhalten, und dann gaebe es
  nichts mehr zuzusehen.

  Der Punkt, an dem so etwas sonst abstuerzt: geschrieben wird der Verlauf
  aus JEDEM Thread des Hosts, auch aus dem Datenbankthread. An einem Fenster
  darf aber nur dessen eigener Thread arbeiten. Deshalb ruft hier niemand von
  aussen herein - ein Timer im Fensterthread HOLT sich die neuen Zeilen
  (AmsTraceSince). Damit ist das Thema erledigt, ohne eine einzige Sperre.

  PFLICHT beim Entladen: AmsTraceWindowClose. Die Fensterprozedur liegt in
  diesem Modul; bliebe das Fenster stehen, waere die naechste Nachricht ein
  Sprung in freigegebenen Speicher.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

{ Fenster oeffnen. AOwner ist das AMS-Hauptfenster (0 geht auch).
  Faengt gleich an zu sammeln, wenn noch nichts laeuft, und startet die
  Quellen (Klicks, Actions, SQL), soweit sie zu haben sind.
  Ein zweiter Aufruf holt das vorhandene Fenster nach vorn. }
function  AmsTraceWindowOpen(AOwner: HWND = 0): Boolean;

{ Schliessen und aufraeumen. GEHOERT IN JEDES BeforeUnload. }
procedure AmsTraceWindowClose;

function  AmsTraceWindowHandle: HWND;
function  AmsTraceWindowOpenState: Boolean;

implementation

uses
  AmsApi.Log, AmsApi.Trace, AmsApi.Recorder;

const
  TRACEWIN_CLASS = 'AmsApiTraceWindow';

  IDC_LIST    = 200;
  IDC_REC     = 201;   { Aufzeichnen an/aus }
  IDC_PAUSE   = 202;   { Anhalten - Fenster friert ein, Sammeln laeuft weiter }
  IDC_CLEAR   = 203;
  IDC_REPORT  = 204;
  IDC_COPY    = 205;
  IDC_SQL     = 206;   { Kategorien }
  IDC_ACT     = 207;
  IDC_CLICK   = 208;
  IDC_STATUS  = 209;

  TIMER_ID    = 1;
  TIMER_MS    = 300;

  MARGIN  = 8;
  ROW_H   = 24;
  BTN_W   = 104;
  CHECK_W = 92;
  { So viele Zeilen haelt das Listenfeld hoechstens - darueber wird vorn
    geloescht. Ein Listenfeld mit 100000 Eintraegen malt sich zu Tode. }
  LIST_MAX = 3000;

var
  gWin: HWND = 0;
  gList: HWND = 0;
  gStatus: HWND = 0;
  gGuiFont: HFONT = 0;
  gFixedFont: HFONT = 0;
  gCursor: Integer = 0;
  gPaused: Boolean = False;
  gAutoScroll: Boolean = True;
  { Der Klassenname muss die Registrierung ueberleben: WNDCLASSW haelt nur
    einen Zeiger, ein temporaerer WideString waere schon wieder weg. }
  gClassNameW: WideString = '';
  gNeu: TStringList = nil;

{ --------------------------------------------------------------- Kleinkram }

procedure SetText(AWnd: HWND; const AText: string);
begin
  if AWnd <> 0 then SetWindowTextW(AWnd, PWideChar(WideString(AText)));
end;

function IsChecked(AId: Integer): Boolean;
begin
  Result := (gWin <> 0) and
            (SendMessageW(GetDlgItem(gWin, AId), BM_GETCHECK, 0, 0) =
             BST_CHECKED);
end;

procedure SetCheck(AId: Integer; AOn: Boolean);
var
  V: WPARAM;
begin
  if gWin = 0 then Exit;
  if AOn then V := BST_CHECKED else V := BST_UNCHECKED;
  SendMessageW(GetDlgItem(gWin, AId), BM_SETCHECK, V, 0);
end;

procedure Status;
var
  S: string;
begin
  if gWin = 0 then Exit;
  if AmsTraceRecording then
    S := 'Aufzeichnung: ' + AmsTraceFile
  else
    S := 'Aufzeichnung: aus (nur zusehen)';
  S := Format('%d Zeilen  -  %s  -  %s', [AmsTraceLineCount, S,
                                          AmsRecordStatus]);
  if gPaused then S := '[ANGEHALTEN]  ' + S;
  SetText(gStatus, S);
end;

{ Kategorien nach den Haken im Fenster setzen. }
procedure ApplyCategories;
var
  C: TAmsTraceCats;
begin
  C := AmsTraceCategories;
  if IsChecked(IDC_SQL) then C := C + [tcSql] else C := C - [tcSql];
  if IsChecked(IDC_ACT) then C := C + [tcAction, tcEvent]
                        else C := C - [tcAction, tcEvent];
  if IsChecked(IDC_CLICK) then C := C + [tcUi] else C := C - [tcUi];
  AmsTraceCategories := C;
end;

{ ------------------------------------------------------------ Nachziehen -- }

{ Neue Zeilen abholen und anhaengen. Laeuft NUR im Fensterthread, angestossen
  vom Timer - siehe Kopf der Unit. }
procedure Pump;
var
  i, Anz, Sicht, Ueber: Integer;
  W: WideString;
begin
  if (gWin = 0) or (gList = 0) or gPaused then Exit;
  if gNeu = nil then gNeu := TStringList.Create;
  gNeu.Clear;
  if AmsTraceSince(gCursor, gNeu, 400) = 0 then
  begin
    Status;
    Exit;
  end;

  { Zeichnen erst am Ende: sonst blinkt das Listenfeld bei jedem Eintrag. }
  SendMessageW(gList, WM_SETREDRAW, 0, 0);
  try
    for i := 0 to gNeu.Count - 1 do
    begin
      W := WideString(gNeu[i]);
      SendMessageW(gList, LB_ADDSTRING, 0, LPARAM(PWideChar(W)));
    end;
    Anz := SendMessageW(gList, LB_GETCOUNT, 0, 0);
    Ueber := Anz - LIST_MAX;
    for i := 1 to Ueber do
      SendMessageW(gList, LB_DELETESTRING, 0, 0);
    if Ueber > 0 then Anz := LIST_MAX;
  finally
    SendMessageW(gList, WM_SETREDRAW, 1, 0);
  end;
  InvalidateRect(gList, nil, True);

  { Mitlaufen: die letzte Zeile sichtbar halten. LB_SETTOPINDEX statt
    LB_SETCURSEL - eine Auswahl wuerde dem Anwender die seine wegnehmen. }
  if gAutoScroll and (Anz > 0) then
  begin
    Sicht := SendMessageW(gList, LB_GETCOUNT, 0, 0);
    SendMessageW(gList, LB_SETTOPINDEX, WPARAM(Sicht - 1), 0);
  end;
  Status;
end;

{ ----------------------------------------------------------------- Knoepfe }

procedure ToggleRecord;
begin
  if AmsTraceRecording then
  begin
    AmsTraceRecordStop;
    SetText(GetDlgItem(gWin, IDC_REC), 'Aufzeichnen');
  end
  else
  begin
    if AmsTraceRecordTo('') then
      SetText(GetDlgItem(gWin, IDC_REC), 'Aufz. beenden')
    else
      SetText(gStatus, 'Aufzeichnung nicht moeglich: ' + AmsLastError);
  end;
  Status;
end;

procedure TogglePause;
begin
  gPaused := not gPaused;
  if gPaused then
    SetText(GetDlgItem(gWin, IDC_PAUSE), 'Weiter')
  else
    SetText(GetDlgItem(gWin, IDC_PAUSE), 'Anhalten');
  { Beim Weiterlaufen sofort nachziehen, statt auf den Timer zu warten. }
  if not gPaused then Pump;
  Status;
end;

procedure ClearList;
begin
  SendMessageW(gList, LB_RESETCONTENT, 0, 0);
  AmsTraceClear;
  { Der Ringpuffer ist leer, die Zeilennummern laufen weiter - also dorthin
    aufschliessen, statt alles noch einmal anzuzeigen. }
  gCursor := AmsTraceLineCount;
  Status;
end;

{ Den sichtbaren Verlauf in die Zwischenablage legen. }
procedure CopyAll;
var
  i, Anz, Len: Integer;
  Buf: array[0..1023] of WideChar;
  Alles, Zeile: string;
  W: WideString;
  H: HGLOBAL;
  P: PWideChar;
begin
  Anz := SendMessageW(gList, LB_GETCOUNT, 0, 0);
  Alles := '';
  for i := 0 to Anz - 1 do
  begin
    Len := SendMessageW(gList, LB_GETTEXTLEN, WPARAM(i), 0);
    if (Len <= 0) or (Len >= Length(Buf)) then Continue;
    Buf[0] := #0;
    SendMessageW(gList, LB_GETTEXT, WPARAM(i), LPARAM(@Buf[0]));
    Zeile := string(WideString(Buf));
    Alles := Alles + Zeile + #13#10;
  end;
  if Alles = '' then Exit;

  W := WideString(Alles);
  if not OpenClipboard(gWin) then Exit;
  try
    EmptyClipboard;
    H := GlobalAlloc(GMEM_MOVEABLE, (Length(W) + 1) * SizeOf(WideChar));
    if H = 0 then Exit;
    P := GlobalLock(H);
    if P = nil then
    begin
      GlobalFree(H);
      Exit;
    end;
    Move(PWideChar(W)^, P^, (Length(W) + 1) * SizeOf(WideChar));
    GlobalUnlock(H);
    SetClipboardData(CF_UNICODETEXT, H);   { ab hier gehoert H Windows }
  finally
    CloseClipboard;
  end;
  SetText(gStatus, Format('%d Zeilen kopiert', [Anz]));
end;

{ Zusammenfassung ins Listenfeld - was wie oft, wie lange. }
procedure ShowReport;
var
  L: TStringList;
  i: Integer;
  W: WideString;
begin
  L := TStringList.Create;
  try
    L.Text := AmsTraceReport(40);
    SendMessageW(gList, WM_SETREDRAW, 0, 0);
    try
      SendMessageW(gList, LB_RESETCONTENT, 0, 0);
      W := WideString('--- Zusammenfassung, "Leeren" holt den Verlauf ' +
                      'zurueck ---');
      SendMessageW(gList, LB_ADDSTRING, 0, LPARAM(PWideChar(W)));
      for i := 0 to L.Count - 1 do
      begin
        W := WideString(L[i]);
        SendMessageW(gList, LB_ADDSTRING, 0, LPARAM(PWideChar(W)));
      end;
    finally
      SendMessageW(gList, WM_SETREDRAW, 1, 0);
    end;
    InvalidateRect(gList, nil, True);
    { Von hier an nicht weiter anhaengen, sonst mischt sich beides. }
    gPaused := True;
    SetText(GetDlgItem(gWin, IDC_PAUSE), 'Weiter');
    Status;
  finally
    L.Free;
  end;
end;

{ ----------------------------------------------------------------- Layout - }

procedure Layout(AWidth, AHeight: Integer);
var
  Top, X, ListH: Integer;
begin
  if gWin = 0 then Exit;

  { Kopfzeile: Kategorien links, Knoepfe rechts. Von rechts nach links
    gerechnet, jeder Schritt derselbe - eine ausgerechnete Position je Knopf
    hatte im Suchfenster genau einen Rechenfehler zu viel. }
  Top := MARGIN;
  X := AWidth - MARGIN - BTN_W;
  MoveWindow(GetDlgItem(gWin, IDC_REC), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gWin, IDC_PAUSE), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gWin, IDC_REPORT), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gWin, IDC_COPY), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gWin, IDC_CLEAR), X, Top, BTN_W, ROW_H, True);

  MoveWindow(GetDlgItem(gWin, IDC_CLICK), MARGIN, Top + 3, CHECK_W, ROW_H,
             True);
  MoveWindow(GetDlgItem(gWin, IDC_ACT), MARGIN + CHECK_W, Top + 3, CHECK_W,
             ROW_H, True);
  MoveWindow(GetDlgItem(gWin, IDC_SQL), MARGIN + 2 * CHECK_W, Top + 3,
             CHECK_W, ROW_H, True);

  { Liste dazwischen, Statuszeile unten. }
  Inc(Top, ROW_H + 6);
  ListH := AHeight - Top - MARGIN - 20;
  if ListH < 60 then ListH := 60;
  MoveWindow(gList, MARGIN, Top, AWidth - 2 * MARGIN, ListH, True);
  MoveWindow(gStatus, MARGIN, Top + ListH + 4, AWidth - 2 * MARGIN, 18,
             True);
end;

{ ------------------------------------------------------- Fensterprozedur -- }

function TraceProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
var
  Id, Anz, Oben, Hoehe: Integer;
begin
  case AMsg of
    WM_SIZE:
      begin
        Layout(LOWORD(ALParam), HIWORD(ALParam));
        Exit(0);
      end;
    WM_GETMINMAXINFO:
      begin
        PMinMaxInfo(ALParam)^.ptMinTrackSize.x := 640;
        PMinMaxInfo(ALParam)^.ptMinTrackSize.y := 260;
        Exit(0);
      end;
    WM_TIMER:
      begin
        if AWParam = TIMER_ID then Pump;
        Exit(0);
      end;
    WM_COMMAND:
      begin
        Id := LOWORD(AWParam);
        case Id of
          IDC_REC:    ToggleRecord;
          IDC_PAUSE:  TogglePause;
          IDC_CLEAR:  ClearList;
          IDC_REPORT: ShowReport;
          IDC_COPY:   CopyAll;
          IDC_SQL, IDC_ACT, IDC_CLICK:
            begin
              ApplyCategories;
              Status;
            end;
          IDC_LIST:
            { Blaettert der Anwender selbst zurueck, soll ihm das Mitlaufen
              nicht dauernd ans Ende springen. Am Ende gehts von selbst
              wieder mit. }
            if HIWORD(AWParam) = LBN_SELCHANGE then
            begin
              Anz := SendMessageW(gList, LB_GETCOUNT, 0, 0);
              Oben := SendMessageW(gList, LB_GETTOPINDEX, 0, 0);
              Hoehe := SendMessageW(gList, LB_GETCOUNT, 0, 0) - Oben;
              gAutoScroll := (Anz = 0) or (Hoehe <= 40);
            end;
        end;
        Exit(0);
      end;
    WM_CLOSE:
      begin
        AmsTraceWindowClose;
        Exit(0);
      end;
    WM_DESTROY:
      begin
        KillTimer(AWnd, TIMER_ID);
        gWin := 0;
        gList := 0;
        gStatus := 0;
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

function MakeChild(const AClass, AText: string; AStyle: DWORD;
  AId: Integer; AFixed: Boolean): HWND;
begin
  Result := CreateWindowExW(0, PWideChar(WideString(AClass)),
    PWideChar(WideString(AText)), WS_CHILD or WS_VISIBLE or AStyle,
    0, 0, 10, 10, gWin, HMENU(AId), HInstance, nil);
  if Result = 0 then Exit;
  if AFixed and (gFixedFont <> 0) then
    SendMessageW(Result, WM_SETFONT, WPARAM(gFixedFont), 1)
  else if gGuiFont <> 0 then
    SendMessageW(Result, WM_SETFONT, WPARAM(gGuiFont), 1);
end;

function AmsTraceWindowOpen(AOwner: HWND): Boolean;
var
  WC: WNDCLASSW;
  R: TRect;
begin
  if gWin <> 0 then
  begin
    ShowWindow(gWin, SW_RESTORE);
    SetForegroundWindow(gWin);
    Exit(True);
  end;

  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @TraceProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursorW(0, LPCWSTR(IDC_ARROW));
  WC.hbrBackground := HBRUSH(COLOR_BTNFACE + 1);
  gClassNameW := WideString(TRACEWIN_CLASS);
  WC.lpszClassName := PWideChar(gClassNameW);
  { Doppelte Registrierung ist kein Fehler - beim zweiten Oeffnen scheitert
    RegisterClass und die vorhandene Klasse wird benutzt. }
  RegisterClassW(WC);

  if gGuiFont = 0 then gGuiFont := HFONT(GetStockObject(DEFAULT_GUI_FONT));
  if gFixedFont = 0 then
    { Feste Schrittweite: nur so stehen Zeit, Einrueckung und Dauer
      untereinander, und erst dadurch ist die Verschachtelung zu sehen. }
    gFixedFont := CreateFontW(-12, 0, 0, 0, FW_NORMAL, 0, 0, 0,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      DEFAULT_QUALITY, FIXED_PITCH or FF_MODERN,
      PWideChar(WideString('Consolas')));

  gWin := CreateWindowExW(WS_EX_TOOLWINDOW, PWideChar(WideString(TRACEWIN_CLASS)),
    'AMS-Verlauf - was der Host gerade tut',
    WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN,
    CW_USEDEFAULT, CW_USEDEFAULT, 1000, 560, AOwner, 0, HInstance, nil);
  if gWin = 0 then
    Exit(AmsFailFmt('Verlaufsfenster konnte nicht erzeugt werden, Fehler %d',
                    [GetLastError]));

  gList := MakeChild('LISTBOX', '',
    WS_BORDER or WS_VSCROLL or WS_HSCROLL or WS_TABSTOP or LBS_NOTIFY,
    IDC_LIST, True);
  gStatus := MakeChild('STATIC', '', SS_LEFTNOWORDWRAP, IDC_STATUS, False);
  MakeChild('BUTTON', 'Aufzeichnen', WS_TABSTOP, IDC_REC, False);
  MakeChild('BUTTON', 'Anhalten', WS_TABSTOP, IDC_PAUSE, False);
  MakeChild('BUTTON', 'Bericht', WS_TABSTOP, IDC_REPORT, False);
  MakeChild('BUTTON', 'Kopieren', WS_TABSTOP, IDC_COPY, False);
  MakeChild('BUTTON', 'Leeren', WS_TABSTOP, IDC_CLEAR, False);
  MakeChild('BUTTON', 'Klicks', WS_TABSTOP or BS_AUTOCHECKBOX, IDC_CLICK,
            False);
  MakeChild('BUTTON', 'Actions', WS_TABSTOP or BS_AUTOCHECKBOX, IDC_ACT,
            False);
  MakeChild('BUTTON', 'SQL', WS_TABSTOP or BS_AUTOCHECKBOX, IDC_SQL, False);

  SetCheck(IDC_CLICK, tcUi in AmsTraceCategories);
  SetCheck(IDC_ACT, tcAction in AmsTraceCategories);
  SetCheck(IDC_SQL, tcSql in AmsTraceCategories);

  { Zusehen heisst sammeln - aber keine Datei anlegen. Wer aufzeichnen will,
    drueckt den Knopf. }
  gPaused := False;
  gAutoScroll := True;
  gCursor := 0;
  AmsTraceBegin;

  { REIHENFOLGE: das Fenster wird ZUERST fertig - Layout, Timer, sichtbar.
    Erst danach werden die Quellen angeklemmt.

    Andersherum war es schon einmal falsch: die Quellen liefen vor SetTimer,
    ein Detour ging schief, die Ausnahme trug den ganzen Aufruf davon - und
    zurueck blieb ein Fenster ohne Timer. Es liess sich beim naechsten Klick
    sogar anzeigen (der "schon offen"-Zweig), nur blieb die Liste fuer immer
    leer. Ein Fenster, das nur zusieht, darf nie daran scheitern, WORAUF es
    zusieht. }
  if GetClientRect(gWin, R) then
    Layout(R.Right - R.Left, R.Bottom - R.Top);
  SetTimer(gWin, TIMER_ID, TIMER_MS, nil);
  ShowWindow(gWin, SW_SHOW);
  Status;

  { Jede Quelle einzeln und abgesichert. Was nicht geht, steht als Zeile IM
    FENSTER - dort wird es gelesen, nicht in einer Logdatei. }
  try
    if AmsRecordSqlStart then
      AmsTraceNote(tcPlugin, 'SQL-Mitschnitt laeuft')
    else
      AmsTraceNote(tcPlugin, 'SQL-Mitschnitt aus', AmsLastError);
  except
    on E: Exception do
      AmsTraceNote(tcPlugin, 'SQL-Mitschnitt abgestuerzt', E.Message);
  end;

  try
    if AmsRecordActionsStart then
      AmsTraceNote(tcPlugin, 'Action-Mitschnitt laeuft')
    else
      AmsTraceNote(tcPlugin, 'Action-Mitschnitt aus', AmsLastError);
  except
    on E: Exception do
      AmsTraceNote(tcPlugin, 'Action-Mitschnitt abgestuerzt', E.Message);
  end;

  try
    AmsTraceNote(tcPlugin, Format('Klick-Mitschnitt: %d Elemente',
                                  [AmsRecordClicksStart]));
  except
    on E: Exception do
      AmsTraceNote(tcPlugin, 'Klick-Mitschnitt abgestuerzt', E.Message);
  end;

  Pump;
  Result := True;
end;

procedure AmsTraceWindowClose;
begin
  if gWin <> 0 then
  begin
    KillTimer(gWin, TIMER_ID);
    DestroyWindow(gWin);
    gWin := 0;
    gList := 0;
    gStatus := 0;
  end;
  if gFixedFont <> 0 then
  begin
    DeleteObject(gFixedFont);
    gFixedFont := 0;
  end;
  UnregisterClassW(PWideChar(WideString(TRACEWIN_CLASS)), HInstance);
  if gNeu <> nil then FreeAndNil(gNeu);
  gCursor := 0;
end;

function AmsTraceWindowHandle: HWND;
begin
  Result := gWin;
end;

function AmsTraceWindowOpenState: Boolean;
begin
  Result := gWin <> 0;
end;

finalization
  { Notbremse: die Fensterprozedur liegt in diesem Modul. }
  if gWin <> 0 then AmsTraceWindowClose;

end.
