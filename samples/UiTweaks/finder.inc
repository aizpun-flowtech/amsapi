{ ============================================================================
  finder.inc - Suchfenster fuer vorhandene AMS-Elemente

  Ein Fenster im laufenden AMS: oben ein Suchfeld, darunter die Treffer und
  ihre Eigenschaften, unten die fertige Patchzeile zum Kopieren oder gleich
  Ausprobieren.

  Die Zeile darueber baut: "Merken" nimmt den gewaehlten Treffer als
  Vorlage, "Klonen" setzt eine Kopie davon in den gerade gewaehlten
  Container (ohne Vorlage: eine Kopie neben das Original), "Neu" legt ein
  Element der eingetragenen Klasse an, "Entfernen" nimmt zurueck, was dieses
  Plugin angelegt hat. Alles davon verschwindet spaetestens beim Entladen -
  die Arbeit macht AmsApi.Factory, hier steht nur die Bedienung.

  Reines Win32. Die VCL des Hosts steht einem FPC-Plugin nicht zur Verfuegung
  (getrennte Heaps, fremde RTL) - CreateWindowExW mit den Standardklassen
  EDIT, BUTTON, LISTBOX und STATIC ist der Weg, der ohne Delphi funktioniert.
  Denselben Weg geht schon der Notnagel-Button in AmsApi.Plugin.

  Das Fenster ist MODELESS: AMS pumpt die Nachrichten seiner eigenen Schleife,
  unser Fenster haengt sich nur hinein. Ein modaler Dialog wuerde den Host
  anhalten - genau das will beim Stoebern niemand.

  PFLICHT beim Entladen: FinderClose und UnregisterClass. Die Fensterprozedur
  liegt in diesem Modul; bliebe das Fenster stehen, waere die naechste
  Nachricht ein Sprung in freigegebenen Speicher.
  ============================================================================ }

const
  FINDER_CLASS = 'AmsUiTweaksFinder';

  IDC_SEARCH  = 100;
  IDC_GO      = 101;
  IDC_ONLYVIS = 102;
  IDC_ELEMS   = 103;
  IDC_PROPS   = 104;
  IDC_PATCH   = 105;
  IDC_COPY    = 106;
  IDC_APPLY   = 107;
  IDC_UNDOBTN = 108;
  IDC_STATUS  = 109;
  IDC_SHOW    = 110;
  IDC_CLASS   = 111;
  IDC_TEXT    = 112;
  IDC_EVENTS  = 113;
  IDC_KEEP    = 114;
  IDC_CLONE   = 115;
  IDC_NEW     = 116;
  IDC_DELETE  = 117;

  MARGIN = 8;
  ROW_H = 24;
  BTN_W = 96;
  { "Zuruecknehmen" ist laenger als die anderen Beschriftungen. }
  UNDO_W = 124;
  CHECK_W = 150;
  EVENT_W = 140;
  { Breiteste Zeile ist die zum Bauen: vier Knoepfe, ein Haken und zwei
    Felder. Darunter faengt es an, sich zu ueberdecken. }
  MIN_W = 800;
  MIN_H = 460;

  { Beschriftung IM leeren Feld (Vista aufwaerts). Spart zwei
    Beschriftungsfelder und sagt trotzdem, was hineingehoert. }
  EM_SETCUEBANNER = $1501;

var
  gFinder: HWND = 0;
  gSearchBox: HWND = 0;
  gOnlyVisBox: HWND = 0;
  gElemList: HWND = 0;
  gPropList: HWND = 0;
  gPatchBox: HWND = 0;
  gStatusBar: HWND = 0;
  gClassBox: HWND = 0;
  gTextBox: HWND = 0;
  gEventsBox: HWND = 0;
  gGuiFont: HFONT = 0;
  gFixedFont: HFONT = 0;
  gOldEditProc: Pointer = nil;
  { Trefferliste und Eigenschaften des gewaehlten Treffers. Die Reihenfolge
    entspricht 1:1 den Zeilen in den beiden Listenfeldern. }
  gHits: TAmsElementArray;
  gHitCount: Integer = 0;
  gProps: TAmsPropArray;
  gPropCount: Integer = 0;
  gCurrent: Integer = -1;
  gMaxHits: Integer = 500;
  { Vorlage zum Klonen. Sie ueberlebt die naechste Suche - genau dafuer ist
    sie da: Vorlage merken, Ziel suchen, klonen. }
  gTemplate: TAmsElement;
  gHasTemplate: Boolean = False;
  { Der Klassenname muss die Registrierung ueberleben: WNDCLASSW haelt nur
    einen Zeiger, und ein temporaerer WideString waere am Ende der Zuweisung
    schon wieder weg. }
  gClassNameW: WideString = '';

{ ------------------------------------------------------------ Kleinkram --- }

procedure SetText(AWnd: HWND; const AText: string);
begin
  if AWnd <> 0 then
    SetWindowTextW(AWnd, PWideChar(WideString(AText)));
end;

function GetText(AWnd: HWND): string;
var
  Buf: array[0..1023] of WideChar;
begin
  Buf[0] := #0;
  if AWnd <> 0 then GetWindowTextW(AWnd, Buf, Length(Buf));
  Result := string(WideString(Buf));
end;

procedure Status(const AText: string);
begin
  SetText(gStatusBar, AText);
end;

procedure ListClear(AWnd: HWND);
begin
  if AWnd <> 0 then SendMessageW(AWnd, LB_RESETCONTENT, 0, 0);
end;

procedure SetCue(AWnd: HWND; const AText: string);
var
  W: WideString;
begin
  if AWnd = 0 then Exit;
  W := WideString(AText);
  SendMessageW(AWnd, EM_SETCUEBANNER, 1, LPARAM(PWideChar(W)));
end;

procedure ListAdd(AWnd: HWND; const AText: string);
var
  W: WideString;
begin
  if AWnd = 0 then Exit;
  W := WideString(AText);
  SendMessageW(AWnd, LB_ADDSTRING, 0, LPARAM(PWideChar(W)));
end;

{ Womit sich das Element in einer Patchzeile ansprechen laesst: der
  Komponentenname, ersatzweise die Beschriftung. }
function Ident(const AElement: TAmsElement): string;
begin
  if AElement.Name <> '' then
    Result := AElement.Name
  else
    Result := AElement.Caption;
end;

function ArtOf(const AElement: TAmsElement): string;
begin
  if AElement.IsBarItem then Result := 'Ribbon'
  else if AElement.IsControl then Result := 'Control'
  else Result := '-';
end;

{ Eine Zeile der Trefferliste. An drei Stellen gebraucht - und drei Stellen
  mit demselben Format sind zwei zu viel. }
function HitLine(const AElement: TAmsElement): string;
begin
  Result := Format('%-28s %-26s %-7s %s',
                   [AElement.Name, AElement.ClassName, ArtOf(AElement),
                    AElement.Caption]);
end;

procedure CopyToClipboard(const AText: string);
var
  W: WideString;
  Mem: THandle;
  P: Pointer;
  Bytes: Integer;
begin
  if AText = '' then Exit;
  W := WideString(AText);
  Bytes := (Length(W) + 1) * SizeOf(WideChar);
  if not OpenClipboard(gFinder) then
  begin
    Status('Zwischenablage nicht verfuegbar.');
    Exit;
  end;
  try
    EmptyClipboard;
    Mem := GlobalAlloc(GMEM_MOVEABLE, Bytes);
    if Mem = 0 then Exit;
    P := GlobalLock(Mem);
    if P = nil then Exit;
    Move(PWideChar(W)^, P^, Bytes);
    GlobalUnlock(Mem);
    { Ab hier gehoert der Speicher der Zwischenablage - nicht freigeben. }
    SetClipboardData(CF_UNICODETEXT, Mem);
    Status('Kopiert: ' + AText);
  finally
    CloseClipboard;
  end;
end;

{ ---------------------------------------------------------------- Suchen -- }

procedure LoadProps(AIndex: Integer); forward;

procedure DoSearch;
var
  F: TAmsElementFilter;
  All: TAmsElementArray;
  Term: string;
  H: Integer;
  E: TAmsElement;
  i, n: Integer;
  Hit: Boolean;
  T0: QWord;
begin
  Term := Trim(GetText(gSearchBox));
  SetLength(gHits, 0);
  gHitCount := 0;
  gCurrent := -1;
  ListClear(gElemList);
  ListClear(gPropList);
  SetText(gPatchBox, '');

  { Sonderfall: ein Fensterhandle aus AutoIt Window Info oder Spy++.
    Dann ist nichts zu suchen - das Element ist bereits benannt. }
  if ((Copy(Term, 1, 2) = '0x') or (Copy(Term, 1, 1) = '$')) and
     AmsIntFromText(Term, H) then
  begin
    E := AmsElementOfWindow(HWND(H));
    if E.Obj = nil then
    begin
      Status(AmsLastError);
      Exit;
    end;
    SetLength(gHits, 1);
    gHits[0] := E;
    gHitCount := 1;
    ListAdd(gElemList, HitLine(E));
    SendMessageW(gElemList, LB_SETCURSEL, 0, 0);
    LoadProps(0);
    Exit;
  end;

  { Sonst EIN Durchlauf ueber den Komponentenbaum, danach im Speicher
    filtern. Drei getrennte Suchlaeufe fuer Name, Klasse und Beschriftung
    waeren dreimal derselbe Baum. }
  T0 := GetTickCount64;
  F := AmsFilterAll;
  F.OnlyVisible := SendMessageW(gOnlyVisBox, BM_GETCHECK, 0, 0) = BST_CHECKED;
  F.MaxResults := 4000;
  n := AmsFindElements(F, All);

  for i := 0 to n - 1 do
  begin
    if Term = '' then
      Hit := True
    else
      { "was auch immer": Name ODER Beschriftung ODER Klasse, als Teilstring.
        Mit "*" oder "?" im Suchtext wird daraus ein Mustervergleich. }
      Hit := AmsMatch(Term, All[i].Name, True) or
             AmsMatch(Term, All[i].Caption, True) or
             AmsMatch(Term, All[i].ClassName, True);
    if not Hit then Continue;
    if gHitCount >= gMaxHits then Break;
    SetLength(gHits, gHitCount + 1);
    gHits[gHitCount] := All[i];
    ListAdd(gElemList, HitLine(All[i]));
    Inc(gHitCount);
  end;

  if gHitCount = 0 then
    Status(Format('Nichts gefunden (%d Elemente durchsucht, %d ms). ' +
                  'Haken bei "nur Sichtbare" entfernen?',
                  [n, Int64(GetTickCount64 - T0)]))
  else
    Status(Format('%d Treffer von %d Elementen, %d ms. Treffer anklicken.',
                  [gHitCount, n, Int64(GetTickCount64 - T0)]));
end;

{ Eigenschaften des gewaehlten Treffers - das ist die rechte Seite einer
  Patchzeile. }
procedure LoadProps(AIndex: Integer);
var
  i: Integer;
  Flag, Val: string;
  E: TAmsElement;
begin
  ListClear(gPropList);
  gPropCount := 0;
  gCurrent := AIndex;
  if (AIndex < 0) or (AIndex >= gHitCount) then Exit;
  E := gHits[AIndex];

  if not AmsElementAlive(E) then
  begin
    Status('Dieses Element gibt es nicht mehr - neu suchen.');
    Exit;
  end;

  gPropCount := AmsPropList(E.Obj, gProps, True);
  for i := 0 to gPropCount - 1 do
  begin
    if gProps[i].Writable then Flag := ' ' else Flag := 'r';
    Val := gProps[i].Value;
    ListAdd(gPropList, Format('%s %-24s %-22s %s',
                              [Flag, gProps[i].Name, gProps[i].TypeName, Val]));
  end;

  if Ident(E) = '' then
    SetText(gPatchBox, '')
  else
    SetText(gPatchBox, Ident(E) + '.');
  Status(Format('%s  [%s]  %d Eigenschaften. Eigenschaft anklicken. ' +
                '(r = nur lesbar)', [E.Path, E.ClassName, gPropCount]));
end;

{ Eigenschaft gewaehlt -> fertige Patchzeile mit dem AKTUELLEN Wert bauen.
  Der aktuelle Wert ist die beste Vorlage: er hat garantiert das richtige
  Format, egal ob Zahl, Aufzaehlung oder Menge. }
procedure PropSelected(AIndex: Integer);
var
  E: TAmsElement;
  Line: string;
begin
  if (gCurrent < 0) or (gCurrent >= gHitCount) then Exit;
  if (AIndex < 0) or (AIndex >= gPropCount) then Exit;
  E := gHits[gCurrent];

  if Ident(E) = '' then
  begin
    Status('Dieses Element hat weder Namen noch Beschriftung - es laesst ' +
           'sich nicht ueber eine Patchzeile ansprechen.');
    Exit;
  end;

  Line := Ident(E) + '.' + gProps[AIndex].Name + '=' + gProps[AIndex].Value;
  SetText(gPatchBox, Line);

  if not gProps[AIndex].Writable then
    Status(Format('"%s" ist nur lesbar - das laesst sich nicht patchen.',
                  [gProps[AIndex].Name]))
  else if gProps[AIndex].Kind in [pkClass, pkMethod] then
    Status(Format('"%s" ist ein %s - nicht aus Text setzbar.',
                  [gProps[AIndex].Name, AmsKindName(gProps[AIndex].Kind)]))
  else if AmsPropOptions(E.Obj, gProps[AIndex].Name) <> '' then
    Status('Erlaubt: ' + AmsPropOptions(E.Obj, gProps[AIndex].Name))
  else
    Status('Wert im Feld unten anpassen, dann "Anwenden" oder "Kopieren".');
end;

{ Zeigen: das Element auf dem Bildschirm blinken lassen und alles ins Log.
  Beantwortet die Frage "ist das ueberhaupt das Richtige", bevor man es
  aendert. }
procedure ShowCurrent;
var
  L: TStringList;
  i: Integer;
  E: TAmsElement;
begin
  if (gCurrent < 0) or (gCurrent >= gHitCount) then
  begin
    Status('Erst einen Treffer anklicken.');
    Exit;
  end;
  E := gHits[gCurrent];

  L := TStringList.Create;
  try
    AmsDumpElement(E.Obj, L);
    for i := 0 to L.Count - 1 do AmsLog(L[i]);
  finally
    L.Free;
  end;

  { Das eigene Fenster liegt womoeglich davor - kurz aus dem Weg. }
  if gFinder <> 0 then
    SetWindowPos(gFinder, HWND_BOTTOM, 0, 0, 0, 0,
                 SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  try
    if AmsHighlightElement(E.Obj) then
      Status(Format('%s blinkt im AMS-Fenster. Einzelheiten im Log: %s',
                    [E.Path, AmsLogFile]))
    else
      Status(AmsLastError + '  (Einzelheiten trotzdem im Log)');
  finally
    if gFinder <> 0 then
      SetWindowPos(gFinder, HWND_TOP, 0, 0, 0, 0,
                   SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  end;
end;

{ ----------------------------------------------------------------- Bauen -- }

{ Der gewaehlte Treffer, aber nur wenn es ihn noch gibt. }
function CurrentHit(out AElement: TAmsElement): Boolean;
begin
  Result := False;
  if (gCurrent < 0) or (gCurrent >= gHitCount) then
  begin
    Status('Erst einen Treffer in der oberen Liste anklicken.');
    Exit;
  end;
  AElement := gHits[gCurrent];
  if not AmsElementAlive(AElement) then
  begin
    Status('Dieses Element gibt es nicht mehr - neu suchen.');
    Exit;
  end;
  Result := True;
end;

{ Ein neu entstandenes Element hinten anhaengen und auswaehlen: so steht man
  danach auf dem Ergebnis und sieht sofort seine Eigenschaften. }
procedure AddHit(const AElement: TAmsElement);
begin
  SetLength(gHits, gHitCount + 1);
  gHits[gHitCount] := AElement;
  ListAdd(gElemList, HitLine(AElement));
  Inc(gHitCount);
  SendMessageW(gElemList, LB_SETCURSEL, gHitCount - 1, 0);
  LoadProps(gHitCount - 1);
end;

{ Merken: der gewaehlte Treffer wird zur Vorlage. Klasse und Beschriftung
  wandern in die Felder - damit ist auch "Neu" gleich sinnvoll gefuellt. }
procedure KeepTemplate;
var
  E: TAmsElement;
begin
  if not CurrentHit(E) then Exit;
  gTemplate := E;
  gHasTemplate := True;
  SetText(gClassBox, E.ClassName);
  SetText(gTextBox, E.Caption);
  Status(Format('Vorlage: %s [%s]. Jetzt das Ziel anklicken und "Klonen".',
                [E.Path, E.ClassName]));
end;

{ Klonen: die Vorlage in den gewaehlten Container. Ohne Vorlage ist der
  gewaehlte Treffer selbst gemeint - dann entsteht eine Kopie daneben. }
procedure CloneCurrent;
var
  Cur, Src, Made: TAmsElement;
  Dest, Clone: Pointer;
  Events: Boolean;
begin
  if not CurrentHit(Cur) then Exit;

  if gHasTemplate and AmsElementAlive(gTemplate) and
     (gTemplate.Obj <> Cur.Obj) then
  begin
    Src := gTemplate;
    Dest := Cur.Obj;
  end
  else
  begin
    Src := Cur;
    Dest := nil;          { nil heisst: dorthin, wo das Original sitzt }
  end;

  Events := SendMessageW(gEventsBox, BM_GETCHECK, 0, 0) = BST_CHECKED;
  if not AmsCloneElementEx(Src.Obj, Dest, '', Events, AmsKeep, AmsKeep,
                           Clone) then
  begin
    Status('Nicht geklont: ' + AmsLastError);
    Exit;
  end;

  Made := AmsElementOf(Clone);
  AddHit(Made);
  if Dest = nil then
    Status(Format('Kopie von "%s" daneben angelegt: %s. "Entfernen" nimmt ' +
                  'sie zurueck, das Entladen ebenfalls.',
                  [Ident(Src), Made.Path]))
  else
    Status(Format('"%s" nach %s kopiert: %s. "Entfernen" nimmt es zurueck, ' +
                  'das Entladen ebenfalls.',
                  [Ident(Src), Ident(Cur), Made.Path]));
end;

{ Neu: ein Element der eingetragenen Klasse in den gewaehlten Container. }
procedure NewFromFields;
var
  Opt: TAmsNewOptions;
  Target: TAmsElement;
  Obj: Pointer;
begin
  Opt := AmsNewDefaults;
  Opt.ClassName := Trim(GetText(gClassBox));
  if Opt.ClassName = '' then
  begin
    Status('Erst eine Klasse eintragen - TButton, TPanel, TEdit, ' +
           'TdxBarLargeButton. "Merken" traegt die des gewaehlten Elements ' +
           'ein.');
    Exit;
  end;
  if not CurrentHit(Target) then Exit;

  Opt.Caption := Trim(GetText(gTextBox));
  Opt.Target := Target.Obj;
  { Ein Ziel, das selbst nichts aufnehmen kann, ist als "dorthin, wo das
    hier sitzt" gemeint. }
  if not AmsIsContainer(Target.Obj) then
    Opt.Target := AmsParentOf(Target.Obj);
  if Opt.Target = nil then
  begin
    Status('Kein Container: ' + AmsLastError +
           '  Ein Formular, ein Panel, eine Registerkarte - oder fuer ein ' +
           'Ribbon-Element eine Leiste (Klasse TdxBar suchen).');
    Exit;
  end;

  if not AmsNewElement(Opt, Obj) then
  begin
    Status('Nicht angelegt: ' + AmsLastError);
    Exit;
  end;
  AddHit(AmsElementOf(Obj));
  Status(Format('%s angelegt in %s. Lage und Aussehen unten ueber die ' +
                'Patchzeile.',
                [Opt.ClassName, AmsElementOf(Opt.Target).Path]));
end;

{ Entfernen: nur, was dieses Plugin selbst angelegt hat. Ein Element des
  Hosts wird von hier aus nicht zerstoert - das sagt AmsApi.Factory ab. }
procedure RemoveCurrent;
var
  E: TAmsElement;
begin
  if not CurrentHit(E) then Exit;
  if AmsRemoveElement(E.Obj) then
  begin
    ListClear(gPropList);
    gPropCount := 0;
    if gHasTemplate and (gTemplate.Obj = E.Obj) then gHasTemplate := False;
    Status(Format('"%s" entfernt. Die Trefferliste ist an dieser Stelle ' +
                  'jetzt veraltet - neu suchen.', [Ident(E)]));
  end
  else
    Status('Nicht entfernt: ' + AmsLastError);
end;

procedure ApplyPatch;
var
  Line: string;
  n: Integer;
begin
  Line := Trim(GetText(gPatchBox));
  if Line = '' then Exit;
  n := AmsApplyPatchLine(Line);
  if n > 0 then
    Status(Format('%d Element(e) geaendert. Rueckgaengig mit ' +
                  '"Zuruecknehmen" oder spaetestens beim Entladen.', [n]))
  else
    Status('Nicht angewandt: ' + AmsLastError);
  { Werte neu einlesen, damit man sieht, was wirklich drinsteht. }
  if gCurrent >= 0 then LoadProps(gCurrent);
  SetText(gPatchBox, Line);
end;

procedure UndoAllChanges;
var
  n: Integer;
begin
  n := AmsUndoAll;
  Status(Format('%d Aenderung(en) zurueckgenommen.', [n]));
  if gCurrent >= 0 then LoadProps(gCurrent);
end;

{ ---------------------------------------------------------------- Fenster - }

procedure Layout(AWidth, AHeight: Integer);
var
  Top, ListTop, Avail, ElemH, PropH, Bottom, X, W, CW: Integer;
begin
  if gFinder = 0 then Exit;
  Top := MARGIN;

  { Zeile 1: Suchfeld, Knopf, Haken. Von RECHTS nach links gerechnet und
    jeder Schritt derselbe - eine ausgerechnete Position je Knopf hatte
    genau einen Rechenfehler zu viel. }
  X := AWidth - MARGIN - CHECK_W;
  MoveWindow(gOnlyVisBox, X, Top + 3, CHECK_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gFinder, IDC_GO), X, Top, BTN_W, ROW_H, True);
  W := X - 2 * MARGIN;
  if W < 120 then W := 120;
  MoveWindow(gSearchBox, MARGIN, Top, W, ROW_H, True);

  { Zeile 2: Statuszeile }
  Inc(Top, ROW_H + 4);
  MoveWindow(gStatusBar, MARGIN, Top, AWidth - 2 * MARGIN, 18, True);

  { Mitte: zwei Listen, oben Treffer, unten Eigenschaften. Darunter liegen
    jetzt ZWEI Zeilen - Bauen und Patchen. }
  ListTop := Top + 22;
  Bottom := AHeight - MARGIN - 2 * ROW_H - 12;
  Avail := Bottom - ListTop - 6;
  if Avail < 80 then Avail := 80;
  ElemH := Avail div 2;
  PropH := Avail - ElemH;
  MoveWindow(gElemList, MARGIN, ListTop, AWidth - 2 * MARGIN, ElemH, True);
  MoveWindow(gPropList, MARGIN, ListTop + ElemH + 6, AWidth - 2 * MARGIN,
             PropH, True);

  { Vorletzte Zeile: bauen. Vier Knoepfe und der Haken von rechts, den Rest
    teilen sich Klasse und Beschriftung. }
  Top := AHeight - MARGIN - 2 * ROW_H - 6;
  X := AWidth - MARGIN - BTN_W;
  MoveWindow(GetDlgItem(gFinder, IDC_DELETE), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gFinder, IDC_NEW), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gFinder, IDC_CLONE), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gFinder, IDC_KEEP), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + EVENT_W);
  MoveWindow(gEventsBox, X, Top + 3, EVENT_W, ROW_H, True);

  W := X - 2 * MARGIN;
  if W < 148 then W := 148;
  CW := W div 2;
  if CW > 200 then CW := 200;
  MoveWindow(gClassBox, MARGIN, Top, CW, ROW_H, True);
  MoveWindow(gTextBox, MARGIN + CW + MARGIN, Top, W - CW - MARGIN, ROW_H,
             True);

  { Unten: Patchzeile und vier Knoepfe, wieder von rechts. }
  Top := AHeight - MARGIN - ROW_H;
  X := AWidth - MARGIN - UNDO_W;
  MoveWindow(GetDlgItem(gFinder, IDC_UNDOBTN), X, Top, UNDO_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gFinder, IDC_COPY), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gFinder, IDC_APPLY), X, Top, BTN_W, ROW_H, True);
  Dec(X, MARGIN + BTN_W);
  MoveWindow(GetDlgItem(gFinder, IDC_SHOW), X, Top, BTN_W, ROW_H, True);
  W := X - 2 * MARGIN;
  if W < 120 then W := 120;
  MoveWindow(gPatchBox, MARGIN, Top, W, ROW_H, True);
end;

{ Das Suchfeld selbst kennt weder Eingabe- noch Abbruchtaste - in einem
  gewoehnlichen Fenster gibt es keine Dialogtastatur. Also abfangen. }
function SearchEditProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
begin
  if AMsg = WM_KEYDOWN then
  begin
    if AWParam = VK_RETURN then
    begin
      DoSearch;
      Exit(0);
    end;
    if AWParam = VK_ESCAPE then
    begin
      if gFinder <> 0 then PostMessageW(gFinder, WM_CLOSE, 0, 0);
      Exit(0);
    end;
  end;
  { Ohne das piept EDIT bei jeder Eingabetaste. }
  if (AMsg = WM_CHAR) and ((AWParam = VK_RETURN) or (AWParam = VK_ESCAPE)) then
    Exit(0);
  Result := CallWindowProcW(gOldEditProc, AWnd, AMsg, AWParam, ALParam);
end;

function FinderProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
var
  R: TRect;
begin
  case AMsg of
    WM_COMMAND:
      begin
        try
          case LOWORD(AWParam) of
            IDC_GO: DoSearch;
            IDC_APPLY: ApplyPatch;
            IDC_COPY: CopyToClipboard(Trim(GetText(gPatchBox)));
            IDC_UNDOBTN: UndoAllChanges;
            IDC_SHOW: ShowCurrent;
            IDC_KEEP: KeepTemplate;
            IDC_CLONE: CloneCurrent;
            IDC_NEW: NewFromFields;
            IDC_DELETE: RemoveCurrent;
            IDC_ELEMS:
              case HIWORD(AWParam) of
                LBN_SELCHANGE:
                  LoadProps(SendMessageW(gElemList, LB_GETCURSEL, 0, 0));
                { Doppelklick auf einen Treffer ist dasselbe wie "Zeigen" -
                  der schnellste Weg zu "welches ist das denn nun". }
                LBN_DBLCLK:
                  ShowCurrent;
              end;
            IDC_PROPS:
              if HIWORD(AWParam) = LBN_SELCHANGE then
                PropSelected(SendMessageW(gPropList, LB_GETCURSEL, 0, 0));
          end;
        except
          on E: Exception do
          begin
            AmsLog('Suchfenster EXCEPTION: ' + E.Message);
            Status('Fehler: ' + E.Message);
          end;
        end;
        Exit(0);
      end;
    WM_SIZE:
      begin
        if GetClientRect(AWnd, R) then
          Layout(R.Right - R.Left, R.Bottom - R.Top);
        Exit(0);
      end;
    WM_GETMINMAXINFO:
      begin
        PMinMaxInfo(ALParam)^.ptMinTrackSize.X := MIN_W;
        PMinMaxInfo(ALParam)^.ptMinTrackSize.Y := MIN_H;
        Exit(0);
      end;
    WM_CLOSE:
      begin
        DestroyWindow(AWnd);
        Exit(0);
      end;
    WM_DESTROY:
      begin
        gFinder := 0;
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
    0, 0, 10, 10, gFinder, HMENU(AId), HInstance, nil);
  if Result = 0 then Exit;
  if AFixed and (gFixedFont <> 0) then
    SendMessageW(Result, WM_SETFONT, WPARAM(gFixedFont), 1)
  else if gGuiFont <> 0 then
    SendMessageW(Result, WM_SETFONT, WPARAM(gGuiFont), 1);
end;

procedure FinderOpen(AOwner: HWND; const APreset: string);
var
  WC: WNDCLASSW;
  R: TRect;
begin
  { Schon offen -> nach vorn holen statt ein zweites Fenster aufzumachen. }
  if gFinder <> 0 then
  begin
    ShowWindow(gFinder, SW_RESTORE);
    SetForegroundWindow(gFinder);
    Exit;
  end;

  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @FinderProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursorW(0, LPCWSTR(IDC_ARROW));
  WC.hbrBackground := HBRUSH(COLOR_BTNFACE + 1);
  gClassNameW := WideString(FINDER_CLASS);
  WC.lpszClassName := PWideChar(gClassNameW);
  { Doppelte Registrierung ist kein Fehler - beim zweiten Oeffnen scheitert
    RegisterClass und die vorhandene Klasse wird benutzt. }
  RegisterClassW(WC);

  if gGuiFont = 0 then gGuiFont := HFONT(GetStockObject(DEFAULT_GUI_FONT));
  if gFixedFont = 0 then
    { Feste Schrittweite, sonst stehen die Spalten nicht untereinander. }
    gFixedFont := CreateFontW(-12, 0, 0, 0, FW_NORMAL, 0, 0, 0,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      DEFAULT_QUALITY, FIXED_PITCH or FF_MODERN,
      PWideChar(WideString('Consolas')));

  gFinder := CreateWindowExW(WS_EX_TOOLWINDOW, PWideChar(WideString(FINDER_CLASS)),
    'AMS-Elemente suchen, patchen und bauen',
    WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN,
    CW_USEDEFAULT, CW_USEDEFAULT, 1040, 680, AOwner, 0, HInstance, nil);
  if gFinder = 0 then
  begin
    AmsLogFmt('Suchfenster konnte nicht erzeugt werden, Fehler %d',
              [GetLastError]);
    Exit;
  end;

  gSearchBox := MakeChild('EDIT', APreset,
    WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, IDC_SEARCH, False);
  MakeChild('BUTTON', 'Suchen', WS_TABSTOP or BS_DEFPUSHBUTTON, IDC_GO, False);
  gOnlyVisBox := MakeChild('BUTTON', 'nur Sichtbare',
    WS_TABSTOP or BS_AUTOCHECKBOX, IDC_ONLYVIS, False);
  gStatusBar := MakeChild('STATIC', 'Suchbegriff eingeben - Name, ' +
    'Beschriftung oder Klasse. Leer = alles. Treffer anklicken, dann ' +
    'patchen (unten) oder bauen (Merken/Klonen/Neu).', SS_LEFTNOWORDWRAP,
    IDC_STATUS, False);
  gElemList := MakeChild('LISTBOX', '',
    WS_BORDER or WS_VSCROLL or WS_HSCROLL or WS_TABSTOP or LBS_NOTIFY,
    IDC_ELEMS, True);
  gPropList := MakeChild('LISTBOX', '',
    WS_BORDER or WS_VSCROLL or WS_HSCROLL or WS_TABSTOP or LBS_NOTIFY,
    IDC_PROPS, True);
  gClassBox := MakeChild('EDIT', '',
    WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, IDC_CLASS, True);
  gTextBox := MakeChild('EDIT', '',
    WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, IDC_TEXT, False);
  gEventsBox := MakeChild('BUTTON', 'mit Ereignissen',
    WS_TABSTOP or BS_AUTOCHECKBOX, IDC_EVENTS, False);
  MakeChild('BUTTON', 'Merken', WS_TABSTOP, IDC_KEEP, False);
  MakeChild('BUTTON', 'Klonen', WS_TABSTOP, IDC_CLONE, False);
  MakeChild('BUTTON', 'Neu', WS_TABSTOP, IDC_NEW, False);
  MakeChild('BUTTON', 'Entfernen', WS_TABSTOP, IDC_DELETE, False);

  gPatchBox := MakeChild('EDIT', '',
    WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, IDC_PATCH, True);
  MakeChild('BUTTON', 'Zeigen', WS_TABSTOP, IDC_SHOW, False);
  MakeChild('BUTTON', 'Anwenden', WS_TABSTOP, IDC_APPLY, False);
  MakeChild('BUTTON', 'Kopieren', WS_TABSTOP, IDC_COPY, False);
  MakeChild('BUTTON', 'Zuruecknehmen', WS_TABSTOP, IDC_UNDOBTN, False);

  SetCue(gClassBox, 'Klasse, z.B. TButton');
  SetCue(gTextBox, 'Beschriftung des neuen Elements');
  SetCue(gPatchBox, 'Element.Eigenschaft=Wert');
  SendMessageW(gOnlyVisBox, BM_SETCHECK, BST_CHECKED, 0);

  { Eingabetaste im Suchfeld abfangen. }
  gOldEditProc := Pointer(SetWindowLongW(gSearchBox, GWL_WNDPROC,
                                         LONG(@SearchEditProc)));

  if GetClientRect(gFinder, R) then
    Layout(R.Right - R.Left, R.Bottom - R.Top);
  ShowWindow(gFinder, SW_SHOW);
  SetFocus(gSearchBox);
  if APreset <> '' then DoSearch;
end;

{ Beim Entladen PFLICHT: die Fensterprozedur liegt in diesem Modul. }
procedure FinderClose;
begin
  if gFinder <> 0 then
  begin
    DestroyWindow(gFinder);
    gFinder := 0;
  end;
  if gFixedFont <> 0 then
  begin
    DeleteObject(gFixedFont);
    gFixedFont := 0;
  end;
  UnregisterClassW(PWideChar(WideString(FINDER_CLASS)), HInstance);
  SetLength(gHits, 0);
  SetLength(gProps, 0);
  gHitCount := 0;
  gPropCount := 0;
  gCurrent := -1;
  { Die Vorlage zeigt auf ein Element des Hosts - beim naechsten Oeffnen
    muss es das nicht mehr geben. }
  gHasTemplate := False;
  gTemplate.Obj := nil;
end;
