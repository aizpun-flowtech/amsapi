unit AmsApi.Ui;

{ ============================================================================
  AmsApi.Ui - vorhandene Elemente des Hosts finden und bearbeiten

  Bis hierher konnte die Bibliothek EIGENE Schaltflaechen anlegen. Diese Unit
  greift auf das zu, was AMS schon mitbringt: Schaltflaechen, Eingabefelder,
  Registerkarten, Ribbon-Elemente, Menuepunkte - deaktivieren, wieder
  einschalten, umbenennen, verschieben, vergroessern, einfaerben, verstecken.

  ZWEI HAELFTEN.

  1. FINDEN. Ein Filter beschreibt, was gesucht ist - Name, Klasse,
     Beschriftung, Pfad, nur Sichtbares, nur Bedienelemente. Alle Angaben
     sind UND-verknuepft, leere Felder zaehlen nicht mit, "*" und "?" sind
     erlaubt. Gesucht wird prozessweit ueber alle Fensterwurzeln, weil viele
     AMS-Komponenten auf Frames sitzen und nicht am Hauptformular haengen.
     Jeder Knoten wird dabei genau einmal besucht (Zeigermenge), sonst wird
     die Suche quadratisch: die Wurzelliste enthaelt bewusst auch Besitzer.

  2. AENDERN. Alles laeuft ueber AmsApi.Props, also ueber die echte
     Delphi-RTTI: Typ und Schreibbarkeit werden geprueft, bevor etwas
     geschrieben wird, und JEDE Aenderung wird mit ihrem alten Wert
     mitgeschrieben. AmsUiRelease nimmt beim Entladen alles zurueck.

  DAS GEHOERT DAZU, WEIL ES SONST KNALLT: die Elemente gehoeren dem Host.
  Sie duerfen nicht freigegeben, nicht umgehaengt und nicht ueber das
  Entladen des Plugins hinaus veraendert zurueckgelassen werden. Ein Ereignis
  zu uebernehmen (AmsHookClick) ist erst recht nur so lange erlaubt, wie das
  Modul im Speicher liegt - deshalb klemmt AmsUnhookAll alles wieder ab.

  Alles gehoert in den UI-Thread des Hosts.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types, AmsApi.Props;

const
  { Fuer Groessen- und Positionsangaben: "diesen Wert nicht anfassen". }
  AmsKeep = Low(Integer);

type
  { Ein gefundenes Element. Obj ist der Objektzeiger des Hosts - nur
    innerhalb des UI-Threads und nur so lange gueltig, wie der Host das
    Element haelt. AmsElementAlive prueft das mit einer billigen Probe. }
  TAmsElement = record
    Obj: Pointer;
    Name: string;         { TComponent.Name, oft leer bei Frames }
    ClassName: string;    { Delphi-Klassenname, z.B. "TdxBarLargeButton" }
    Caption: string;      { Caption bzw. Text, ohne & }
    Path: string;         { Besitzerkette, z.B. "frmMain.pnLeft.btnOk" }
    Handle: HWND;         { nur gefuellt, wenn ueber ein Fenster gefunden }
    IsControl: Boolean;   { hat Left/Top/Width/Height }
    IsBarItem: Boolean;   { dxBar-Element (Ribbon, Menue, Symbolleiste) }
  end;
  TAmsElementArray = array of TAmsElement;

  { Suchbedingungen. Leere Felder werden nicht geprueft; alles Gesetzte muss
    zusammen zutreffen. In Name, ClassName, Caption und Path sind "*" und
    "?" erlaubt - ohne Platzhalter gilt bei Name und Caption Gleichheit
    (ohne Gross/Kleinschreibung), bei ClassName und Path "enthaelt". }
  TAmsElementFilter = record
    Name: string;
    ClassName: string;
    Caption: string;
    Path: string;
    { Wo gesucht wird. Beides leer = alle Fensterwurzeln des Prozesses. }
    Root: Pointer;
    Window: HWND;
    OnlyVisible: Boolean;
    OnlyControls: Boolean;
    OnlyBarItems: Boolean;
    { Schutz gegen Ausreisser. 0 = Standard (12 / 20000 / 200). }
    MaxDepth: Integer;
    MaxNodes: Integer;
    MaxResults: Integer;
  end;

var
  { Nimmt AmsUiRelease die Aenderungen zurueck? Nur abschalten, wenn sie
    ausdruecklich stehen bleiben sollen. }
  AmsAutoUndo: Boolean = True;

{ ---------------------------------------------------------- Filter bauen -- }

function AmsFilterAll: TAmsElementFilter;
function AmsByName(const AName: string): TAmsElementFilter;
function AmsByCaption(const ACaption: string): TAmsElementFilter;
function AmsByClass(const AClass: string): TAmsElementFilter;

{ Textvergleich der Suche, einzeln nutzbar. Leeres Muster passt immer;
  enthaelt es "*" oder "?", wird der ganze Text dagegen geprueft, sonst
  entscheidet ASubstring zwischen "enthaelt" und "ist gleich". }
function AmsMatch(const APattern, AText: string;
  ASubstring: Boolean = False): Boolean;

{ ---------------------------------------------------------------- Suchen -- }

{ Alle passenden Elemente. Liefert die Anzahl. }
function AmsFindElements(const AFilter: TAmsElementFilter;
  var AList: TAmsElementArray): Integer;

{ Erster Treffer. Bei mehreren Treffern wird der erste genommen und die
  Mehrdeutigkeit mit allen Pfaden protokolliert - dann ist der Filter zu
  ungenau. False heisst: nichts gefunden, Ursache in AmsLastError. }
function AmsFindElement(const AFilter: TAmsElementFilter;
  out AElement: TAmsElement): Boolean;

{ Kurzform: erst nach Name suchen, dann nach Beschriftung. Das ist der
  Normalfall - "bbSpeichern" oder "Speichern". }
function AmsElement(const ANameOrCaption: string;
  out AElement: TAmsElement): Boolean;

{ Objektzeiger -> Element (Name, Klasse, Beschriftung, Pfad). }
function AmsElementOf(AObj: Pointer): TAmsElement;

{ Element zu einem FENSTERHANDLE - genau die Zahl, die AutoIt Window Info,
  Spy++ oder WinSpy anzeigen. Damit wird jedes dieser Werkzeuge zur Pipette
  fuer diese API: Element dort aufnehmen, Handle hier einsetzen, und man
  bekommt den Komponentennamen, den Pfad und alle Eigenschaften.
  Gehoert das Fenster keinem VCL-Objekt, wird die Elternkette hochgegangen. }
function AmsElementOfWindow(AHandle: HWND): TAmsElement;

{ Element unter einem Bildschirmpunkt bzw. unter dem Mauszeiger. Findet
  Bedienelemente MIT eigenem Fenster; dxBar-Elemente und TGraphicControl
  haben keins und sind so nicht zu treffen - die findet man ueber Caption. }
function AmsElementAt(AX, AY: Integer): TAmsElement;
function AmsElementAtCursor: TAmsElement;

{ Der Rueckweg von FindControl: welches Fenster gehoert diesem VCL-Objekt?
  0, wenn das Element kein eigenes Fenster hat - TGraphicControl,
  TSpeedButton und alle dxBar-Elemente haben keins. Kostet einen Durchlauf
  ueber die Fenster des Prozesses. }
function AmsWindowOfElement(AObj: Pointer): HWND;

{ Element auf dem Bildschirm blinken lassen: ein Rahmen, der per XOR
  gezeichnet wird und sich beim zweiten Zeichnen selbst wieder aufhebt.
  Der Host wird dabei NICHT angefasst - keine Eigenschaft, kein Neuzeichnen,
  nichts, was zurueckgenommen werden muesste.
  False mit Klartext, wenn sich kein Rechteck ermitteln laesst. }
function AmsHighlightElement(AObj: Pointer; ABlinks: Integer = 3): Boolean;

{ Dasselbe fuer ein beliebiges Bildschirmrechteck. }
procedure AmsFlashFrame(const ARect: TRect; ABlinks: Integer = 3;
  AThickness: Integer = 3);

{ Besitzerkette als Pfad, z.B. "frmMain.pnLeft.btnOk". }
function AmsElementPath(AObj: Pointer): string;

{ Zeigt der Zeiger noch auf dasselbe Element? Billige Probe ueber Klasse und
  Name - erkennt den ueberwiegenden Teil der freigegebenen Zeiger. }
function AmsElementAlive(const AElement: TAmsElement): Boolean;

function AmsElementVisible(AObj: Pointer): Boolean;

{ ------------------------------------------------------------- Bearbeiten - }

{ Der allgemeine Weg: jede published property ueber ihren Pfad, aus Text.
  "Enabled"="0", "Caption"="Neu", "Font.Size"="12", "Color"="clRed",
  "Visible"="ivNever", "Font.Style"="[fsBold]". }
function AmsSetElementProp(AObj: Pointer; const APath, AValue: string): Boolean;

function AmsEnableElement(AObj: Pointer; AEnabled: Boolean): Boolean;
function AmsShowElement(AObj: Pointer; AVisible: Boolean): Boolean;

{ Beschriftung aendern. Faellt auf "Text" zurueck, wenn es keine "Caption"
  gibt (Eingabefelder). }
function AmsSetElementCaption(AObj: Pointer; const ACaption: string): Boolean;
function AmsSetElementHint(AObj: Pointer; const AHint: string): Boolean;

{ Groesse und Lage. AmsKeep laesst einen Wert unveraendert. Nur bei
  Bedienelementen mit Left/Top/Width/Height. }
function AmsSetElementBounds(AObj: Pointer;
  ALeft, ATop, AWidth, AHeight: Integer): Boolean;
function AmsSetElementSize(AObj: Pointer; AWidth, AHeight: Integer): Boolean;
function AmsSetElementPos(AObj: Pointer; ALeft, ATop: Integer): Boolean;
function AmsGetElementBounds(AObj: Pointer;
  out ALeft, ATop, AWidth, AHeight: Integer): Boolean;

{ Aussehen. Farbe als "clRed", "#FF8800" oder "$0088FF". Bei der Schrift
  bleibt jeder leere bzw. 0-Wert unveraendert; AStyle ist eine Menge wie
  "[fsBold,fsItalic]" oder "[]". }
function AmsSetElementColor(AObj: Pointer; const AColor: string): Boolean;
function AmsSetElementFont(AObj: Pointer; const AFontName: string;
  ASize: Integer; const AColor: string; const AStyle: string): Boolean;
function AmsSetElementImage(AObj: Pointer; AImageIndex: Integer): Boolean;

{ Element ausloesen: dxBar-Element ueber DirectClick (derselbe Codepfad wie
  ein Mausklick), sonst ueber das belegte OnClick. }
function AmsClickElement(AObj: Pointer): Boolean;

{ ------------------------------------------------------- Aus einer INI ---- }

{ Eine Zeile "Element.Eigenschaft=Wert" anwenden. "Element" wird gegen Name
  UND Beschriftung geprueft und darf Platzhalter enthalten; getrennt wird am
  ERSTEN Punkt, der Rest ist der Eigenschaftspfad:
      bbSpeichern.Enabled=0
      Speichern.Caption=Sichern
      bb*.Font.Style=[fsBold]
  Liefert die Zahl der geaenderten Elemente. }
function AmsApplyPatchLine(const ALine: string): Integer;

{ Mehrere Zeilen in EINEM Suchlauf - deutlich schneller als Zeile fuer
  Zeile. Genau das Format von AmsIniSection. }
function AmsApplyPatches(APatches: TStrings): Integer;

{ Eine Patchzeile zerlegen, ohne sie anzuwenden - getrennt wird am ersten
  "=" und davor am ersten Punkt. Fuer Pruefungen und Fehlermeldungen. }
function AmsSplitPatch(const ALine: string;
  out AElem, APath, AValue: string): Boolean;

{ ------------------------------------------------------ Ereignis fangen --- }

type
  { Beobachter fuer JEDES uebernommene Ereignis. Wird einmal vor und einmal
    nach der urspruenglichen Behandlung gerufen; AToken bleibt zwischen den
    beiden Aufrufen erhalten. Damit kann ein Rekorder eine Klammer mit Dauer
    um das Ereignis legen, ohne dass diese Unit etwas von ihm wissen muss
    (AmsApi.Recorder benutzt das). }
  TAmsEventWatch = procedure(AObj: Pointer; const AProp: string;
    ASender: Pointer; var AToken: Integer; ABefore: Boolean);

var
  AmsEventWatcher: TAmsEventWatch = nil;

{ OnClick eines vorhandenen Elements uebernehmen. ACallOriginal = True ruft
  zuerst die urspruengliche Behandlung des Hosts und danach den eigenen
  Handler; False ersetzt sie.
  Nur fuer Ereignisse vom Typ TNotifyEvent - alles andere hat mehr Parameter
  und wuerde den Stack zerlegen; das wird ueber die RTTI geprueft.
  Beim Entladen MUSS AmsUnhookAll laufen, sonst springt der naechste Klick
  in freigegebenen Speicher. AmsUiRelease erledigt das. }
function AmsHookClick(AObj: Pointer; AHandler: TAmsClickEvent;
  ATag: Integer = 0; ACallOriginal: Boolean = False): Boolean;
function AmsHookEvent(AObj: Pointer; const AEvent: string;
  AHandler: TAmsClickEvent; ATag: Integer; ACallOriginal: Boolean): Boolean;

function AmsUnhookElement(AObj: Pointer): Integer;
procedure AmsUnhookAll;
function AmsHookCount: Integer;

{ --------------------------------------------------------------- Ausgabe -- }

{ Trefferliste als Tabelle - der schnellste Weg zum richtigen Namen. }
procedure AmsDumpElements(const AFilter: TAmsElementFilter; ADest: TStrings);

{ Ein Element mit allen Eigenschaften, Typen und erlaubten Werten. }
procedure AmsDumpElement(AObj: Pointer; ADest: TStrings);

{ ------------------------------------------------------------- Aufraeumen - }

{ Ereignisse abklemmen und (sofern AmsAutoUndo) alle Aenderungen
  zuruecknehmen. Gehoert in das Entladen des Plugins; TAmsPlugin ruft es. }
procedure AmsUiRelease;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Components, AmsApi.Menus,
  AmsApi.Log;

const
  DEF_DEPTH = 12;
  DEF_NODES = 20000;
  DEF_RESULTS = 200;
  PATCH_RESULTS = 4000;      { fuer den Sammellauf von AmsApplyPatches }

{ ------------------------------------------------------------ Textmuster -- }

{ Platzhaltervergleich mit Rueckverfolgung. "*" steht fuer beliebig viele,
  "?" fuer genau ein Zeichen. }
function WildMatch(const AP, AT: string): Boolean;
var
  p, t, StarP, StarT: Integer;
begin
  p := 1;
  t := 1;
  StarP := 0;
  StarT := 0;
  while t <= Length(AT) do
  begin
    if (p <= Length(AP)) and ((AP[p] = '?') or (AP[p] = AT[t])) then
    begin
      Inc(p);
      Inc(t);
    end
    else if (p <= Length(AP)) and (AP[p] = '*') then
    begin
      StarP := p;
      Inc(p);
      StarT := t;
    end
    else if StarP > 0 then
    begin
      p := StarP + 1;
      Inc(StarT);
      t := StarT;
    end
    else
      Exit(False);
  end;
  while (p <= Length(AP)) and (AP[p] = '*') do Inc(p);
  Result := p > Length(AP);
end;

function AmsMatch(const APattern, AText: string; ASubstring: Boolean): Boolean;
var
  P: string;
begin
  P := Trim(APattern);
  if P = '' then Exit(True);
  if (Pos('*', P) > 0) or (Pos('?', P) > 0) then
    Result := WildMatch(LowerCase(P), LowerCase(AText))
  else if ASubstring then
    Result := Pos(LowerCase(P), LowerCase(AText)) > 0
  else
    Result := SameText(P, AText);
end;

{ ---------------------------------------------------------- Filter bauen -- }

function AmsFilterAll: TAmsElementFilter;
begin
  Result.Name := '';
  Result.ClassName := '';
  Result.Caption := '';
  Result.Path := '';
  Result.Root := nil;
  Result.Window := 0;
  Result.OnlyVisible := False;
  Result.OnlyControls := False;
  Result.OnlyBarItems := False;
  Result.MaxDepth := DEF_DEPTH;
  Result.MaxNodes := DEF_NODES;
  Result.MaxResults := DEF_RESULTS;
end;

function AmsByName(const AName: string): TAmsElementFilter;
begin
  Result := AmsFilterAll;
  Result.Name := AName;
end;

function AmsByCaption(const ACaption: string): TAmsElementFilter;
begin
  Result := AmsFilterAll;
  Result.Caption := ACaption;
end;

function AmsByClass(const AClass: string): TAmsElementFilter;
begin
  Result := AmsFilterAll;
  Result.ClassName := AClass;
end;

{ ---------------------------------------------------------- Elementdaten -- }

{ Leeres Element. NICHT ueber FillChar - der Record enthaelt Strings, und
  die sind referenzgezaehlt; "out" sorgt fuer die richtige Initialisierung. }
procedure ClearElement(out AElement: TAmsElement);
begin
  AElement.Obj := nil;
  AElement.Name := '';
  AElement.ClassName := '';
  AElement.Caption := '';
  AElement.Path := '';
  AElement.Handle := 0;
  AElement.IsControl := False;
  AElement.IsBarItem := False;
end;

function AmsElementPath(AObj: Pointer): string;
var
  O: Pointer;
  Guard: Integer;
  N: string;
begin
  Result := '';
  O := AObj;
  Guard := 0;
  while (O <> nil) and (Guard < 12) do
  begin
    N := AmsName(O);
    if N = '' then N := '[' + AmsClassName(O) + ']';
    if Result = '' then Result := N else Result := N + '.' + Result;
    try
      O := PPointer(PtrUInt(O) + ofsComponentOwner)^;
    except
      Break;
    end;
    Inc(Guard);
  end;
end;

function AmsElementVisible(AObj: Pointer): Boolean;
begin
  Result := True;
  if AObj = nil then Exit(False);
  if AmsHasProp(AObj, 'Visible') then
    Result := AmsGetPropInt(AObj, 'Visible', 1) <> 0;
end;

function CaptionOf(AObj: Pointer): string;
begin
  Result := '';
  if AmsHasProp(AObj, 'Caption') then
    Result := AmsGetStr(AObj, 'Caption')
  else if AmsHasProp(AObj, 'Text') then
    Result := AmsGetStr(AObj, 'Text');
  Result := AmsCleanCaption(Result);
end;

function AmsElementOf(AObj: Pointer): TAmsElement;
begin
  ClearElement(Result);
  Result.Obj := AObj;
  if AObj = nil then Exit;
  Result.Name := AmsName(AObj);
  Result.ClassName := AmsClassName(AObj);
  Result.Caption := CaptionOf(AObj);
  Result.Path := AmsElementPath(AObj);
  { Left und Height sind in TControl published - das trennt Bedienelemente
    zuverlaessig von Ribbon-Elementen, die beides nicht haben. }
  Result.IsControl := AmsHasProp(AObj, 'Left') and AmsHasProp(AObj, 'Height');
  Result.IsBarItem := (not Result.IsControl) and
                      AmsHasProp(AObj, 'Caption') and
                      (AmsHasProp(AObj, 'Category') or
                       (Pos('dxBar', Result.ClassName) > 0));
end;

function AmsElementAlive(const AElement: TAmsElement): Boolean;
begin
  Result := (AElement.Obj <> nil) and
            (AmsClassName(AElement.Obj) = AElement.ClassName) and
            (AmsName(AElement.Obj) = AElement.Name);
end;

{ ------------------------------------------------------------ Zeigermenge -
  Die Wurzelliste enthaelt absichtlich auch Besitzer; ohne diese Menge wuerde
  derselbe Teilbaum vielfach durchlaufen. Offene Adressierung, Zweierpotenz,
  keine Loeschung - mehr braucht ein Suchlauf nicht. }

type
  TSeen = record
    Slots: array of Pointer;
    Mask: PtrUInt;
    Count: Integer;
  end;

procedure SeenInit(var S: TSeen);
begin
  SetLength(S.Slots, 4096);
  FillChar(S.Slots[0], 4096 * SizeOf(Pointer), 0);
  S.Mask := 4095;
  S.Count := 0;
end;

function SeenSlot(const S: TSeen; AP: Pointer): PtrUInt;
begin
  Result := ((PtrUInt(AP) shr 4) xor (PtrUInt(AP) shr 12)) and S.Mask;
  while (S.Slots[Result] <> nil) and (S.Slots[Result] <> AP) do
    Result := (Result + 1) and S.Mask;
end;

procedure SeenGrow(var S: TSeen);
var
  Old: array of Pointer;
  i: Integer;
  Slot: PtrUInt;
begin
  Old := S.Slots;
  S.Slots := nil;
  SetLength(S.Slots, (S.Mask + 1) * 2);
  FillChar(S.Slots[0], Length(S.Slots) * SizeOf(Pointer), 0);
  S.Mask := PtrUInt(Length(S.Slots)) - 1;
  for i := 0 to Length(Old) - 1 do
    if Old[i] <> nil then
    begin
      Slot := SeenSlot(S, Old[i]);
      S.Slots[Slot] := Old[i];
    end;
end;

{ True, wenn der Zeiger neu war. }
function SeenAdd(var S: TSeen; AP: Pointer): Boolean;
var
  Slot: PtrUInt;
begin
  if AP = nil then Exit(False);
  Slot := SeenSlot(S, AP);
  if S.Slots[Slot] = AP then Exit(False);
  S.Slots[Slot] := AP;
  Inc(S.Count);
  Result := True;
  if S.Count * 2 > Integer(S.Mask) then SeenGrow(S);
end;

{ ---------------------------------------------------------------- Suchen -- }

function AmsFindElements(const AFilter: TAmsElementFilter;
  var AList: TAmsElementArray): Integer;
var
  F: TAmsElementFilter;
  Seen: TSeen;
  Nodes, Found: Integer;
  Roots: TList;
  i: Integer;
  T0: QWord;

  { Passt der Knoten? Erst die billigen Bedingungen. }
  function Matches(AObj: Pointer; const ANm, ACls: string): Boolean;
  var
    E: TAmsElement;
  begin
    Result := False;
    if not AmsMatch(F.Name, ANm, False) then Exit;
    if not AmsMatch(F.ClassName, ACls, True) then Exit;
    if (F.Caption <> '') and not AmsMatch(F.Caption, CaptionOf(AObj), False) then
      Exit;
    if (F.Path <> '') and not AmsMatch(F.Path, AmsElementPath(AObj), True) then
      Exit;
    if F.OnlyVisible and not AmsElementVisible(AObj) then Exit;
    if F.OnlyControls or F.OnlyBarItems then
    begin
      E := AmsElementOf(AObj);
      if F.OnlyControls and not E.IsControl then Exit;
      if F.OnlyBarItems and not E.IsBarItem then Exit;
    end;
    Result := True;
  end;

  procedure Take(AObj: Pointer);
  begin
    if Found >= F.MaxResults then Exit;
    if Length(AList) <= Found then
      SetLength(AList, Found + 32);
    AList[Found] := AmsElementOf(AObj);
    Inc(Found);
  end;

  procedure Visit(AObj: Pointer; ADepth: Integer);
  var
    n, k: Integer;
    C: Pointer;
  begin
    if (AObj = nil) or (ADepth > F.MaxDepth) then Exit;
    if Nodes > F.MaxNodes then Exit;
    if not SeenAdd(Seen, AObj) then Exit;
    Inc(Nodes);
    if (Found < F.MaxResults) and Matches(AObj, AmsName(AObj),
                                          AmsClassName(AObj)) then
      Take(AObj);
    n := AmsComponentCount(AObj);
    for k := 0 to n - 1 do
    begin
      if Nodes > F.MaxNodes then Exit;
      C := AmsComponent(AObj, k);
      if C <> nil then Visit(C, ADepth + 1);
    end;
  end;

begin
  SetLength(AList, 0);
  Result := 0;
  AmsClearError;
  F := AFilter;
  if F.MaxDepth <= 0 then F.MaxDepth := DEF_DEPTH;
  if F.MaxNodes <= 0 then F.MaxNodes := DEF_NODES;
  if F.MaxResults <= 0 then F.MaxResults := DEF_RESULTS;

  if not (AmsBindCore and AmsBindVcl) then
  begin
    AmsFail('Elementsuche: Host-Symbole fehlen (Core/Vcl)');
    Exit;
  end;

  Nodes := 0;
  Found := 0;
  T0 := GetTickCount64;
  SeenInit(Seen);
  try
    if F.Window <> 0 then
      Visit(AmsControlOf(F.Window), 0)
    else if F.Root <> nil then
      Visit(F.Root, 0)
    else
    begin
      Roots := TList.Create;
      try
        AmsBuildRootList(Roots);
        for i := 0 to Roots.Count - 1 do
          Visit(Roots[i], 0);
      finally
        Roots.Free;
      end;
    end;
  except
    on E: Exception do AmsLog('Elementsuche EXCEPTION: ' + E.Message);
  end;
  SetLength(AList, Found);
  Result := Found;
  AmsLogFmt('Elementsuche: %d Knoten, %d Treffer, %d ms',
            [Nodes, Found, Int64(GetTickCount64 - T0)]);
  if Nodes > F.MaxNodes then
    AmsLogFmt('Elementsuche abgebrochen - mehr als %d Knoten', [F.MaxNodes]);
end;

function AmsFindElement(const AFilter: TAmsElementFilter;
  out AElement: TAmsElement): Boolean;
var
  L: TAmsElementArray;
  n, i: Integer;
begin
  ClearElement(AElement);
  n := AmsFindElements(AFilter, L);
  if n = 0 then
    Exit(AmsFail('Kein Element gefunden, auf das der Filter passt'));
  AElement := L[0];
  { Mehrdeutigkeit ist kein Fehler, aber fast immer ein zu grober Filter -
    die Pfade ins Log, damit sich der Filter schaerfen laesst. }
  if n > 1 then
  begin
    AmsLogFmt('%d Elemente passen - genommen wird "%s"', [n, L[0].Path]);
    for i := 0 to n - 1 do
    begin
      if i >= 10 then
      begin
        AmsLog('  ...');
        Break;
      end;
      AmsLogFmt('  %s [%s] "%s"', [L[i].Path, L[i].ClassName, L[i].Caption]);
    end;
  end;
  Result := True;
end;

function AmsElement(const ANameOrCaption: string;
  out AElement: TAmsElement): Boolean;
var
  F: TAmsElementFilter;
begin
  ClearElement(AElement);
  if Trim(ANameOrCaption) = '' then
    Exit(AmsFail('Kein Name und keine Beschriftung angegeben'));
  F := AmsByName(ANameOrCaption);
  Result := AmsFindElement(F, AElement);
  if Result then Exit;
  F := AmsByCaption(ANameOrCaption);
  Result := AmsFindElement(F, AElement);
  if not Result then
    AmsFailFmt('"%s" gibt es hier weder als Name noch als Beschriftung',
               [ANameOrCaption]);
end;

{ ------------------------------------------------------- Objekt -> Fenster -
  Dieselbe Bauart wie AmsBuildRootList: die Enum-Callbacks bekommen ihr Ziel
  nur ueber Globale, also NICHT reentrant und nur im UI-Thread. Und wieder
  gilt: genau EIN EnumChildWindows je Top-Level-Fenster, sonst wird der
  Durchlauf quadratisch. }

var
  gWantObj: Pointer = nil;
  gWantWnd: HWND = 0;

function MatchWndProc(AHandle: HWND; AParam: LPARAM): BOOL; stdcall;
begin
  Result := True;
  if gWantWnd <> 0 then Exit(False);
  if not Assigned(hcFindControl) then Exit(False);
  try
    if hcFindControl(AHandle) = gWantObj then
    begin
      gWantWnd := AHandle;
      Result := False;
    end;
  except
  end;
end;

function MatchTopProc(AHandle: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Pid: DWORD;
begin
  Result := True;
  if gWantWnd <> 0 then Exit(False);
  Pid := 0;
  GetWindowThreadProcessId(AHandle, @Pid);
  if Pid <> GetCurrentProcessId then Exit;
  MatchWndProc(AHandle, 0);
  if gWantWnd = 0 then EnumChildWindows(AHandle, @MatchWndProc, 0);
  if gWantWnd <> 0 then Result := False;
end;

function AmsWindowOfElement(AObj: Pointer): HWND;
begin
  Result := 0;
  if (AObj = nil) or not AmsBindVcl then Exit;
  if gWantObj <> nil then
  begin
    AmsLog('AmsWindowOfElement: bereits aktiv - verschachtelter Aufruf');
    Exit;
  end;
  gWantObj := AObj;
  gWantWnd := 0;
  try
    try
      EnumWindows(@MatchTopProc, 0);
    except
    end;
    Result := gWantWnd;
  finally
    gWantObj := nil;
    gWantWnd := 0;
  end;
end;

{ Rahmen per DSTINVERT: gerade Anzahl Durchgaenge = der Bildschirm sieht
  danach aus wie vorher. Kein Neuzeichnen noetig, keine Spuren. }
procedure AmsFlashFrame(const ARect: TRect; ABlinks, AThickness: Integer);
var
  DC: HDC;
  i, W, H, T: Integer;
begin
  W := ARect.Right - ARect.Left;
  H := ARect.Bottom - ARect.Top;
  if (W <= 0) or (H <= 0) then Exit;
  T := AThickness;
  if T < 1 then T := 1;
  if T * 2 > W then T := W div 2;
  if T * 2 > H then T := H div 2;
  if T < 1 then T := 1;
  if ABlinks < 1 then ABlinks := 1;

  DC := GetDC(0);
  if DC = 0 then Exit;
  try
    for i := 1 to ABlinks * 2 do
    begin
      PatBlt(DC, ARect.Left, ARect.Top, W, T, DSTINVERT);
      PatBlt(DC, ARect.Left, ARect.Bottom - T, W, T, DSTINVERT);
      PatBlt(DC, ARect.Left, ARect.Top + T, T, H - 2 * T, DSTINVERT);
      PatBlt(DC, ARect.Right - T, ARect.Top + T, T, H - 2 * T, DSTINVERT);
      GdiFlush;
      { Blockiert den UI-Thread des Hosts - deshalb kurz und nur auf
        ausdruecklichen Wunsch des Anwenders. }
      Sleep(90);
    end;
  finally
    ReleaseDC(0, DC);
  end;
end;

function AmsHighlightElement(AObj: Pointer; ABlinks: Integer): Boolean;
var
  W: HWND;
  R: TRect;
begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  W := AmsWindowOfElement(AObj);
  if W = 0 then
    Exit(AmsFailFmt('[%s] hat kein eigenes Fenster - Ribbon-Elemente und ' +
                    'gezeichnete Bedienelemente lassen sich nicht ' +
                    'hervorheben', [AmsClassName(AObj)]));
  if not IsWindowVisible(W) then
    Exit(AmsFail('Das Element ist gerade nicht sichtbar (anderes ' +
                 'Register, zugeklappt oder verdeckt)'));
  if not GetWindowRect(W, R) then
    Exit(AmsFail('Bildschirmrechteck nicht lesbar'));
  if (R.Right - R.Left <= 0) or (R.Bottom - R.Top <= 0) then
    Exit(AmsFail('Das Element hat keine Ausdehnung'));
  AmsFlashFrame(R, ABlinks, 3);
  AmsLogFmt('Hervorgehoben: %s [%s] bei %d,%d-%d,%d',
            [AmsName(AObj), AmsClassName(AObj), R.Left, R.Top, R.Right,
             R.Bottom]);
  Result := True;
end;

function AmsElementOfWindow(AHandle: HWND): TAmsElement;
var
  W: HWND;
  O: Pointer;
  Pid: DWORD;
  Guard: Integer;
begin
  ClearElement(Result);
  W := AHandle;
  if (W = 0) or not IsWindow(W) then
  begin
    AmsFailFmt('%p ist kein gueltiges Fensterhandle (mehr)', [Pointer(W)]);
    Exit;
  end;
  { Ein Handle aus einem fremden Prozess koennen wir nicht aufloesen -
    FindControl kennt nur die VCL DIESES Prozesses. }
  Pid := 0;
  GetWindowThreadProcessId(W, @Pid);
  if Pid <> GetCurrentProcessId then
  begin
    AmsFail('Das Fenster gehoert einem anderen Prozess');
    Exit;
  end;
  { Nicht jedes Fenster gehoert einem VCL-Objekt - dann das Elternfenster
    nehmen, das tut es fast immer. }
  O := nil;
  Guard := 0;
  while (W <> 0) and (Guard < 8) do
  begin
    O := AmsControlOf(W);
    if O <> nil then Break;
    W := GetParent(W);
    Inc(Guard);
  end;
  if O = nil then
  begin
    AmsFail('Zu diesem Fenster gibt es kein VCL-Element');
    Exit;
  end;
  Result := AmsElementOf(O);
  Result.Handle := W;
end;

function AmsElementAt(AX, AY: Integer): TAmsElement;
var
  W: HWND;
  P: TPoint;
begin
  ClearElement(Result);
  P.X := AX;
  P.Y := AY;
  W := WindowFromPoint(P);
  if W = 0 then
  begin
    AmsFail('An dieser Stelle liegt kein Fenster');
    Exit;
  end;
  Result := AmsElementOfWindow(W);
end;

function AmsElementAtCursor: TAmsElement;
var
  P: TPoint;
begin
  ClearElement(Result);
  if not GetCursorPos(P) then
  begin
    AmsFail('Mausposition nicht lesbar');
    Exit;
  end;
  Result := AmsElementAt(P.X, P.Y);
end;

{ ------------------------------------------------------------- Bearbeiten - }

function AmsSetElementProp(AObj: Pointer; const APath, AValue: string): Boolean;
begin
  Result := AmsSetProp(AObj, APath, AValue);
  if Result then
    AmsLogFmt('%s "%s".%s := %s',
              [AmsClassName(AObj), AmsName(AObj), APath, AValue])
  else
    AmsLogFmt('%s "%s".%s := %s  FEHLGESCHLAGEN: %s',
              [AmsClassName(AObj), AmsName(AObj), APath, AValue, AmsLastError]);
end;

function AmsEnableElement(AObj: Pointer; AEnabled: Boolean): Boolean;
begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  if not AmsHasProp(AObj, 'Enabled') then
    Exit(AmsFailFmt('[%s] kennt kein "Enabled"', [AmsClassName(AObj)]));
  Result := AmsSetElementProp(AObj, 'Enabled', IntToStr(Ord(AEnabled)));
end;

function AmsShowElement(AObj: Pointer; AVisible: Boolean): Boolean;
var
  Kind: TAmsPropKind;
  Tn: string;
begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  Kind := AmsPropKindOf(AObj, 'Visible');
  if Kind = pkNone then
    Exit(AmsFailFmt('[%s] kennt kein "Visible"', [AmsClassName(AObj)]));
  { Bei dxBar-Elementen ist Visible eine Aufzaehlung (ivNever/ivAlways) und
    kein Boolean - die Ordinalwerte 0/1 passen aber fuer beides. }
  Tn := AmsPropTypeName(AObj, 'Visible');
  if (Kind = pkEnum) and not SameText(Tn, 'Boolean') then
    AmsLogFmt('"Visible" ist hier vom Typ %s - gesetzt wird %d', [Tn,
              Ord(AVisible)]);
  Result := AmsSetElementProp(AObj, 'Visible', IntToStr(Ord(AVisible)));
end;

function AmsSetElementCaption(AObj: Pointer; const ACaption: string): Boolean;
begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  if AmsHasProp(AObj, 'Caption') then
    Result := AmsSetElementProp(AObj, 'Caption', ACaption)
  else if AmsHasProp(AObj, 'Text') then
    Result := AmsSetElementProp(AObj, 'Text', ACaption)
  else
    Result := AmsFailFmt('[%s] hat weder "Caption" noch "Text"',
                         [AmsClassName(AObj)]);
end;

function AmsSetElementHint(AObj: Pointer; const AHint: string): Boolean;
begin
  Result := AmsSetElementProp(AObj, 'Hint', AHint);
end;

function AmsSetElementBounds(AObj: Pointer;
  ALeft, ATop, AWidth, AHeight: Integer): Boolean;

  function Apply(const AProp: string; AValue: Integer): Boolean;
  begin
    if AValue = AmsKeep then Exit(True);
    Result := AmsSetElementProp(AObj, AProp, IntToStr(AValue));
  end;

begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  if not AmsHasProp(AObj, 'Left') then
    Exit(AmsFailFmt('[%s] ist kein Bedienelement mit Groesse',
                    [AmsClassName(AObj)]));
  { Breite und Hoehe zuerst: bei verankerten Elementen aendert eine spaetere
    Positionierung sonst gleich wieder die Groesse. }
  Result := Apply('Width', AWidth);
  Result := Apply('Height', AHeight) and Result;
  Result := Apply('Left', ALeft) and Result;
  Result := Apply('Top', ATop) and Result;
end;

function AmsSetElementSize(AObj: Pointer; AWidth, AHeight: Integer): Boolean;
begin
  Result := AmsSetElementBounds(AObj, AmsKeep, AmsKeep, AWidth, AHeight);
end;

function AmsSetElementPos(AObj: Pointer; ALeft, ATop: Integer): Boolean;
begin
  Result := AmsSetElementBounds(AObj, ALeft, ATop, AmsKeep, AmsKeep);
end;

function AmsGetElementBounds(AObj: Pointer;
  out ALeft, ATop, AWidth, AHeight: Integer): Boolean;
begin
  ALeft := 0;
  ATop := 0;
  AWidth := 0;
  AHeight := 0;
  Result := (AObj <> nil) and AmsHasProp(AObj, 'Left');
  if not Result then Exit;
  ALeft := AmsGetPropInt(AObj, 'Left');
  ATop := AmsGetPropInt(AObj, 'Top');
  AWidth := AmsGetPropInt(AObj, 'Width');
  AHeight := AmsGetPropInt(AObj, 'Height');
end;

function AmsSetElementColor(AObj: Pointer; const AColor: string): Boolean;
begin
  Result := AmsSetElementProp(AObj, 'Color', AColor);
end;

function AmsSetElementFont(AObj: Pointer; const AFontName: string;
  ASize: Integer; const AColor: string; const AStyle: string): Boolean;
begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  if AmsGetPropObject(AObj, 'Font') = nil then
    Exit(AmsFailFmt('[%s] hat keine Schrift', [AmsClassName(AObj)]));
  Result := True;
  if AFontName <> '' then
    Result := AmsSetElementProp(AObj, 'Font.Name', AFontName) and Result;
  if ASize > 0 then
    Result := AmsSetElementProp(AObj, 'Font.Size', IntToStr(ASize)) and Result;
  if AColor <> '' then
    Result := AmsSetElementProp(AObj, 'Font.Color', AColor) and Result;
  if AStyle <> '' then
    Result := AmsSetElementProp(AObj, 'Font.Style', AStyle) and Result;
end;

function AmsSetElementImage(AObj: Pointer; AImageIndex: Integer): Boolean;
begin
  Result := AmsSetElementProp(AObj, 'ImageIndex', IntToStr(AImageIndex));
end;

function AmsClickElement(AObj: Pointer): Boolean;
var
  E: TAmsElement;
  M: TDelphiMethod;
  Notify: procedure(AData, ASender: Pointer); register;
begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  E := AmsElementOf(AObj);
  if E.IsBarItem then
    Exit(AmsClickItem(AObj));
  if not SameText(AmsPropTypeName(AObj, 'OnClick'), 'TNotifyEvent') then
    Exit(AmsFailFmt('[%s] hat kein OnClick vom Typ TNotifyEvent',
                    [E.ClassName]));
  if not AmsGetPropMethod(AObj, 'OnClick', M) or (M.Code = nil) then
    Exit(AmsFailFmt('OnClick von "%s" ist nicht belegt', [E.Name]));
  try
    Notify := M.Code;
    Notify(M.Data, AObj);
    Result := True;
  except
    on Ex: Exception do
      Result := AmsFail('OnClick fehlgeschlagen: ' + Ex.Message);
  end;
end;

{ ------------------------------------------------------- Aus einer INI ---- }

{ "bb*.Font.Style=[fsBold]" -> Element "bb*", Pfad "Font.Style", Wert "[fsBold]" }
function AmsSplitPatch(const ALine: string;
  out AElem, APath, AValue: string): Boolean;
var
  P: Integer;
  Left: string;
begin
  AElem := '';
  APath := '';
  AValue := '';
  Result := False;
  P := Pos('=', ALine);
  if P = 0 then Exit;
  Left := Trim(Copy(ALine, 1, P - 1));
  AValue := Trim(Copy(ALine, P + 1, MaxInt));
  P := Pos('.', Left);
  if P = 0 then Exit;
  AElem := Trim(Copy(Left, 1, P - 1));
  APath := Trim(Copy(Left, P + 1, MaxInt));
  Result := (AElem <> '') and (APath <> '');
end;

{ Passt das Element auf die linke Seite einer Patchzeile? }
function PatchHits(const AElement: TAmsElement; const AElem: string): Boolean;
begin
  Result := AmsMatch(AElem, AElement.Name, False) or
            ((AElement.Caption <> '') and
             AmsMatch(AElem, AElement.Caption, False));
end;

{ Leerzeile oder Kommentar? Erst trimmen - eine eingerueckte INI-Zeile ist
  genauso ein Kommentar wie eine buendige. }
function IsSkipLine(const ALine: string): Boolean;
var
  S: string;
begin
  S := Trim(ALine);
  Result := (S = '') or (S[1] = ';') or (S[1] = '#');
end;

function AmsApplyPatchLine(const ALine: string): Integer;
var
  Elem, Path, Value: string;
  F: TAmsElementFilter;
  L: TAmsElementArray;
  i, n: Integer;
begin
  Result := 0;
  if IsSkipLine(ALine) then Exit;
  if not AmsSplitPatch(ALine, Elem, Path, Value) then
  begin
    AmsFailFmt('"%s" ist keine Patchzeile (erwartet: ' +
               'Element.Eigenschaft=Wert)', [Trim(ALine)]);
    Exit;
  end;

  F := AmsByName(Elem);
  n := AmsFindElements(F, L);
  if n = 0 then
  begin
    F := AmsByCaption(Elem);
    n := AmsFindElements(F, L);
  end;
  if n = 0 then
  begin
    AmsFailFmt('"%s" gibt es hier nicht', [Elem]);
    Exit;
  end;
  for i := 0 to n - 1 do
    if AmsSetElementProp(L[i].Obj, Path, Value) then Inc(Result);
end;

function AmsApplyPatches(APatches: TStrings): Integer;
var
  All: TAmsElementArray;
  F: TAmsElementFilter;
  Elem, Path, Value: string;
  i, k, n, Hits: Integer;
begin
  Result := 0;
  if (APatches = nil) or (APatches.Count = 0) then Exit;

  { EIN Suchlauf fuer alle Zeilen - Zeile fuer Zeile zu suchen waere bei
    zwanzig Zeilen zwanzig Durchlaeufe ueber den ganzen Komponentenbaum. }
  F := AmsFilterAll;
  F.MaxResults := PATCH_RESULTS;
  n := AmsFindElements(F, All);
  if n = 0 then
  begin
    AmsFail('Kein einziges Element gefunden - laeuft das Plugin in AMS?');
    Exit;
  end;

  for i := 0 to APatches.Count - 1 do
  begin
    if IsSkipLine(APatches[i]) then Continue;
    if not AmsSplitPatch(APatches[i], Elem, Path, Value) then
    begin
      AmsLogFmt('Patch uebersprungen, keine gueltige Zeile: %s', [APatches[i]]);
      Continue;
    end;
    Hits := 0;
    for k := 0 to n - 1 do
      if PatchHits(All[k], Elem) then
      begin
        Inc(Hits);
        if AmsSetElementProp(All[k].Obj, Path, Value) then Inc(Result);
      end;
    if Hits = 0 then
      AmsLogFmt('Patch ohne Wirkung, "%s" gibt es hier nicht: %s',
                [Elem, APatches[i]]);
  end;
  AmsLogFmt('%d von %d Patchzeilen angewandt', [Result, APatches.Count]);
end;

{ ------------------------------------------------------ Ereignis fangen --- }

type
  TNotifyThunk = procedure(AData, ASender: Pointer); register;

  PHookSlot = ^THookSlot;
  THookSlot = record
    Method: TDelphiMethod;     { Code = @HookThunk, Data = @Slot }
    Original: TDelphiMethod;   { was vorher drinstand }
    Handler: TAmsClickEvent;
    Tag: Integer;
    Obj: Pointer;
    Prop: string;
    CallOriginal: Boolean;
    Token: Integer;            { Klammer des Beobachters, siehe HookThunk }
  end;

var
  gHooks: TList = nil;

{ Kommt vom Host als TNotifyEvent: EAX = Data (unser Slot), EDX = Sender. }
procedure HookThunk(ASlot: PHookSlot; ASender: Pointer); register;
var
  Orig: TNotifyThunk;
begin
  try
    if ASlot = nil then Exit;
    if Assigned(AmsEventWatcher) then
      AmsEventWatcher(ASlot^.Obj, ASlot^.Prop, ASender, ASlot^.Token, True);
    try
      if ASlot^.CallOriginal and (ASlot^.Original.Code <> nil) then
      begin
        Orig := TNotifyThunk(ASlot^.Original.Code);
        Orig(ASlot^.Original.Data, ASender);
      end;
      if Assigned(ASlot^.Handler) then ASlot^.Handler(ASender, ASlot^.Tag);
    finally
      { Auch bei einer Exception des Hosts muss die Klammer zugehen. }
      if Assigned(AmsEventWatcher) then
        AmsEventWatcher(ASlot^.Obj, ASlot^.Prop, ASender, ASlot^.Token, False);
    end;
  except
    on E: Exception do AmsLog('Uebernommenes Ereignis EXCEPTION: ' + E.Message);
  end;
end;

function FindHook(AObj: Pointer; const AProp: string): PHookSlot;
var
  i: Integer;
  S: PHookSlot;
begin
  Result := nil;
  if gHooks = nil then Exit;
  for i := 0 to gHooks.Count - 1 do
  begin
    S := PHookSlot(gHooks[i]);
    if (S^.Obj = AObj) and SameText(S^.Prop, AProp) then Exit(S);
  end;
end;

function AmsHookEvent(AObj: Pointer; const AEvent: string;
  AHandler: TAmsClickEvent; ATag: Integer; ACallOriginal: Boolean): Boolean;
var
  S: PHookSlot;
  Tn: string;
begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  { Ohne Handler ist ein Hook nur dann sinnvoll, wenn ein Beobachter
    mithoert - genau das macht der Klick-Mitschnitt. }
  if (not Assigned(AHandler)) and (not Assigned(AmsEventWatcher)) then
    Exit(AmsFail('Kein Handler angegeben'));
  if FindHook(AObj, AEvent) <> nil then
    Exit(AmsFailFmt('"%s" ist an diesem Element bereits uebernommen',
                    [AEvent]));

  { Nur TNotifyEvent. Ein Ereignis mit mehr Parametern wuerde unser Thunk
    nicht vom Stack raeumen - das ist kein Absturz "vielleicht", sondern
    einer mit Ansage. }
  Tn := AmsPropTypeName(AObj, AEvent);
  if Tn = '' then
    Exit(AmsFailFmt('[%s] kennt kein Ereignis "%s"',
                    [AmsClassName(AObj), AEvent]));
  if not SameText(Tn, 'TNotifyEvent') then
    Exit(AmsFailFmt('"%s" ist vom Typ %s - uebernommen werden nur ' +
                    'TNotifyEvent-Ereignisse', [AEvent, Tn]));

  New(S);
  S^.Handler := AHandler;
  S^.Tag := ATag;
  S^.Obj := AObj;
  S^.Prop := AEvent;
  S^.CallOriginal := ACallOriginal;
  S^.Token := 0;
  S^.Original.Code := nil;
  S^.Original.Data := nil;
  AmsGetPropMethod(AObj, AEvent, S^.Original);
  S^.Method.Code := @HookThunk;
  S^.Method.Data := S;

  if not AmsSetPropMethod(AObj, AEvent, S^.Method) then
  begin
    Dispose(S);
    Exit(False);
  end;

  if gHooks = nil then gHooks := TList.Create;
  gHooks.Add(S);
  AmsLogFmt('%s "%s".%s uebernommen (vorher %s)',
            [AmsClassName(AObj), AmsName(AObj), AEvent,
             BoolToStr(S^.Original.Code <> nil, 'belegt', 'leer')]);
  Result := True;
end;

function AmsHookClick(AObj: Pointer; AHandler: TAmsClickEvent;
  ATag: Integer; ACallOriginal: Boolean): Boolean;
begin
  Result := AmsHookEvent(AObj, 'OnClick', AHandler, ATag, ACallOriginal);
end;

{ Einen Slot abklemmen und freigeben. }
procedure ReleaseHook(ASlot: PHookSlot);
begin
  if ASlot = nil then Exit;
  try
    { Zuerst den Host abklemmen, dann erst freigeben - in dieser
      Reihenfolge, sonst zeigt das Ereignis kurzzeitig auf toten Speicher. }
    if ASlot^.Obj <> nil then
      AmsSetPropMethod(ASlot^.Obj, ASlot^.Prop, ASlot^.Original);
  except
    on E: Exception do AmsLog('Abklemmen fehlgeschlagen: ' + E.Message);
  end;
  ASlot^.Handler := nil;
  Dispose(ASlot);
end;

function AmsUnhookElement(AObj: Pointer): Integer;
var
  i: Integer;
  S: PHookSlot;
begin
  Result := 0;
  if (gHooks = nil) or (AObj = nil) then Exit;
  for i := gHooks.Count - 1 downto 0 do
  begin
    S := PHookSlot(gHooks[i]);
    if S^.Obj <> AObj then Continue;
    ReleaseHook(S);
    gHooks.Delete(i);
    Inc(Result);
  end;
end;

procedure AmsUnhookAll;
var
  i: Integer;
begin
  if gHooks = nil then Exit;
  for i := gHooks.Count - 1 downto 0 do
    ReleaseHook(PHookSlot(gHooks[i]));
  gHooks.Clear;
  AmsLog('Uebernommene Ereignisse abgeklemmt');
end;

function AmsHookCount: Integer;
begin
  if gHooks = nil then Result := 0 else Result := gHooks.Count;
end;

{ --------------------------------------------------------------- Ausgabe -- }

procedure AmsDumpElements(const AFilter: TAmsElementFilter; ADest: TStrings);
var
  L: TAmsElementArray;
  i, n: Integer;
  Art: string;
begin
  if ADest = nil then Exit;
  n := AmsFindElements(AFilter, L);
  ADest.Add(Format('%d Element(e) gefunden', [n]));
  if n = 0 then
  begin
    ADest.Add('  ' + AmsLastError);
    Exit;
  end;
  ADest.Add(Format('  %-28s %-26s %-8s %s',
                   ['Name', 'Klasse', 'Art', 'Beschriftung']));
  for i := 0 to n - 1 do
  begin
    if L[i].IsBarItem then Art := 'Ribbon'
    else if L[i].IsControl then Art := 'Control'
    else Art := '-';
    ADest.Add(Format('  %-28s %-26s %-8s %s',
                     [L[i].Name, L[i].ClassName, Art, L[i].Caption]));
  end;
end;

procedure AmsDumpElement(AObj: Pointer; ADest: TStrings);
var
  E: TAmsElement;
begin
  if ADest = nil then Exit;
  if AObj = nil then
  begin
    ADest.Add('Kein Element.');
    Exit;
  end;
  E := AmsElementOf(AObj);
  ADest.Add(StringOfChar('=', 78));
  ADest.Add(Format('Pfad ........ %s', [E.Path]));
  ADest.Add(Format('Klasse ...... %s', [E.ClassName]));
  ADest.Add(Format('Name ........ %s', [E.Name]));
  ADest.Add(Format('Beschriftung  %s', [E.Caption]));
  ADest.Add(Format('Art ......... Control=%s BarItem=%s Sichtbar=%s',
                   [BoolToStr(E.IsControl, True), BoolToStr(E.IsBarItem, True),
                    BoolToStr(AmsElementVisible(AObj), True)]));
  ADest.Add(Format('Zeiger ...... %p', [AObj]));
  ADest.Add('');
  ADest.Add('Eigenschaften (r = nur lesbar, {} = erlaubte Werte):');
  AmsDumpProps(AObj, ADest, True);
end;

{ ------------------------------------------------------------- Aufraeumen - }

procedure AmsUiRelease;
begin
  { Reihenfolge: erst die Ereignisse abklemmen (sonst kann ein Klick
    waehrend der Ruecknahme in unseren Code springen), dann zuruecknehmen. }
  AmsUnhookAll;
  if AmsAutoUndo then AmsUndoAll else AmsForgetChanges;
end;

initialization
  gHooks := nil;

finalization
  AmsUnhookAll;
  FreeAndNil(gHooks);

end.
