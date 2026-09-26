unit AmsApi.Factory;

{ ============================================================================
  AmsApi.Factory - Elemente ANLEGEN, KLONEN und EINHAENGEN

  AmsApi.Ui aendert, was der Host schon hat. Diese Unit legt Neues dazu: eine
  Schaltflaeche auf ein vorhandenes Panel, eine Kopie eines Eingabefeldes auf
  eine andere Registerkarte, ein zusaetzliches Ribbon-Element in einer
  bestehenden Gruppe.

  DREI DINGE, DIE MAN DAFUER BRAUCHT, UND WIE SIE HIER GELOEST SIND.

  1. EINE KLASSE. AmsResolveClass fragt zuerst Classes.GetClass - das kennt
     alles, was der Host fuer sein eigenes Streaming registriert hat. Findet
     es die Klasse nicht, wird ein Element DIESER Klasse in der laufenden
     Oberflaeche gesucht und dessen Klassenzeiger genommen. Was auf dem
     Bildschirm steht, laesst sich also immer nachbauen.

  2. EIN KONSTRUKTOR. Delphi-Konstruktoren sind virtuell; TButton.Create
     macht mehr als TComponent.Create. Aufgerufen wird deshalb der Slot aus
     dem VMT der ZIELKLASSE. Welcher Slot das ist, wird nicht geraten,
     sondern gesucht: die Adresse von TComponent.Create kommt aus dem
     Package, ihr Platz im VMT von TComponent ist der Slot (AmsVmtIndexOf).
     Wird er nicht gefunden, legt diese Unit NICHTS an - ein falscher Slot
     waere ein Sprung in eine beliebige andere Methode.

  3. EIN PLATZ. Bedienelemente kommen ueber TControl.SetParent an ihr Ziel -
     ebenfalls virtuell, weil daran das Erzeugen des Fensters haengt.
     dxBar-Elemente haben keinen Parent; sie werden am TdxBarManager
     angemeldet und mit einem ItemLink in eine Leiste gehaengt.

  WAS BEIM KLONEN KOPIERT WIRD. Alle published properties, die schreibbar
  sind, ueber die RTTI. Objekteigenschaften (Font, Glyph, Images) nur dann,
  wenn dahinter eine Setzmethode steht - die macht Assign, also eine echte
  Kopie. Steht dort unmittelbar ein Feld, wird die Eigenschaft ausgelassen:
  zwei Elemente mit derselben Schrift sind ein Absturz auf Raten. Auf Wunsch
  werden auch die Ereignisse uebernommen; dann ruft der Klon dieselbe
  Behandlung des Hosts wie das Original.

  AUFRAEUMEN IST PFLICHT, NICHT KUER. Jedes hier angelegte Element steht in
  einem Verzeichnis und wird beim Entladen wieder abgeraeumt - Ereignis
  abklemmen, dann freigeben. Ein Element, das dieses Modul ueberlebt, ist
  beim naechsten Klick ein Sprung in freigegebenen Speicher. Aus demselben
  Grund gibt AmsRemoveElement ausschliesslich EIGENE Elemente frei; ein
  Element des Hosts wird von hier aus nie zerstoert.

  Alles gehoert in den UI-Thread des Hosts.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{ Zeigerarithmetik ist hier die Aufgabe, nicht ein Versehen: VMT-Slots lassen
  sich nicht anders erreichen. }
{$WARN 4056 OFF}
{$WARN 4082 OFF}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types, AmsApi.Ui;

type
  { Bauplan fuer ein neues Element. AmsNewDefaults liefert die Vorbelegung;
    gesetzt werden muss nur, was von ihr abweicht. }
  TAmsNewOptions = record
    { Klassenname, z.B. 'TButton', 'TPanel', 'TdxBarLargeButton'. }
    ClassName: string;
    Caption: string;
    { Komponentenname. Leer = automatisch vergeben ("AmsNeu1"), damit sich
      das Element spaeter wiederfinden laesst. }
    Name: string;
    { Wohin: ein TWinControl (Formular, Panel, Registerkarte) oder eine
      dxBar-Leiste. Ohne Ziel bleibt das Element unsichtbar im Speicher. }
    Target: Pointer;
    { Besitzer im Sinne der VCL. nil heisst: dieses Plugin raeumt selbst auf -
      das ist der Normalfall und der einzige, der ohne den Host auskommt. }
    Owner: Pointer;
    { AmsKeep laesst den vom Konstruktor gesetzten Wert stehen. }
    Left, Top, Width, Height: Integer;
    { Klickbehandlung im Plugin. Wird beim Abraeumen abgeklemmt. }
    OnClick: TAmsClickEvent;
    Tag: Integer;
    { Nur fuer dxBar-Elemente und nur, wenn er sich nicht aus dem Ziel
      ergibt. }
    BarManager: Pointer;
  end;

{ ------------------------------------------------------------ Bereitschaft - }

{ Laesst sich hier ueberhaupt etwas anlegen? Prueft die Symbole UND die
  beiden gesuchten VMT-Slots. False mit Klartext in AmsLastError. }
function AmsFactoryReady: Boolean;

{ Byteoffset des virtuellen Konstruktors bzw. von TControl.SetParent im VMT,
  -1 wenn nicht gefunden. Nur fuer Diagnose interessant. }
function AmsCtorSlot: Integer;
function AmsSetParentSlot: Integer;

{ --------------------------------------------------------------- Klassen --- }

{ Klassenzeiger zu einem Namen: erst Classes.GetClass, dann die laufende
  Oberflaeche. nil mit Klartext, wenn es die Klasse nirgends gibt. }
function AmsResolveClass(const AClassName: string): Pointer;

{ Zu welchem TdxBarManager gehoert dieses Element? Fuer eine Leiste ueber
  BarManager, sonst ueber die Besitzerkette, zuletzt "dxBarManager1". }
function AmsBarManagerOf(AObj: Pointer): Pointer;

{ ---------------------------------------------------------- Anlegen -------- }

{ Nackter Aufruf des virtuellen Konstruktors. ACls MUSS von TComponent
  abstammen - das wird geprueft, denn der Slot gilt nur dort.
  Das Ergebnis gehoert dem Aufrufer und steht NICHT im Verzeichnis dieser
  Unit; wer es benutzt, raeumt es selbst ab. Der uebliche Weg ist
  AmsNewElement. }
function AmsCreateComponent(ACls, AOwner: Pointer): Pointer;

function AmsNewDefaults: TAmsNewOptions;

{ Element anlegen, benennen, beschriften, einhaengen - der ganze Weg.
  False mit Klartext; ein halb fertiges Element bleibt dabei nicht stehen. }
function AmsNewElement(const AOptions: TAmsNewOptions;
  out AObj: Pointer): Boolean;

{ ------------------------------------------------------------- Klonen ------ }

{ Kopie von ASource in ATarget. ATarget = nil bedeutet "dorthin, wo das
  Original sitzt"; die Kopie wird dann um 16 Punkte versetzt, sonst laege
  sie unsichtbar auf dem Original.
  Ereignisse werden dabei NICHT uebernommen - der Klon sieht aus wie das
  Original, tut aber nichts. Fuer das Gegenteil AmsCloneElementEx. }
function AmsCloneElement(ASource, ATarget: Pointer;
  out AClone: Pointer): Boolean;

{ Wie oben, mit allem, was man einzeln entscheiden will. ACopyEvents = True
  uebernimmt die Ereignisse des Originals: der Klon ruft dann dieselbe
  Behandlung des Hosts, mit sich selbst als Sender.
  ALeft/ATop = AmsKeep laesst die Lage des Originals stehen (bzw. versetzt
  sie, wenn Ziel und Quelle denselben Container haben). }
function AmsCloneElementEx(ASource, ATarget: Pointer; const AName: string;
  ACopyEvents: Boolean; ALeft, ATop: Integer; out AClone: Pointer): Boolean;

{ Nur die Eigenschaften kopieren, ohne etwas anzulegen. Liefert die Zahl der
  uebernommenen Eigenschaften. Aenderungen daran kommen NICHT ins
  Aenderungsjournal von AmsApi.Props - ein neues Element hat keinen
  Zustand, der sich zuruecknehmen liesse. }
function AmsCopyProps(ASource, ADest: Pointer; ACopyEvents: Boolean): Integer;

{ ------------------------------------------------------- Einhaengen -------- }

{ Element in einen Container haengen: Bedienelement -> SetParent,
  dxBar-Element -> ItemLinks der Leiste. }
function AmsAttachElement(AObj, ATarget: Pointer): Boolean;

{ Ein VORHANDENES Element des Hosts woanders hinhaengen. Die alte Lage wird
  mitgeschrieben und beim Entladen wiederhergestellt - anders als beim
  Anlegen gehoert dieses Element nicht uns.
  Nur fuer Bedienelemente: Ribbon-Elemente haengen an Verknuepfungen des
  Hosts, die hier niemand verschieben sollte. }
function AmsMoveElement(AObj, ATarget: Pointer): Boolean;

{ ------------------------------------------------------------ Verzeichnis -- }

{ Stammt dieses Element aus dieser Unit? }
function AmsIsSpawned(AObj: Pointer): Boolean;
function AmsSpawnCount: Integer;

{ Ein selbst angelegtes Element wieder entfernen. Auf ein Element des Hosts
  angewandt liefert es False - hier wird nichts Fremdes zerstoert. }
function AmsRemoveElement(AObj: Pointer): Boolean;

procedure AmsDumpSpawned(ADest: TStrings);

{ Alles Angelegte entfernen und alle Umhaengungen zuruecknehmen. Liefert die
  Zahl der abgeraeumten Elemente. Gehoert in das Entladen des Plugins;
  TAmsPlugin ruft es, die finalization dieser Unit ebenfalls. }
function AmsFactoryRelease: Integer;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Props, AmsApi.Components,
  AmsApi.Log;

type
  { Ein selbst angelegtes Element. ClassName und Name sind die Lebendprobe:
    zeigt der Zeiger spaeter auf etwas anderes, wird nichts freigegeben. }
  PSpawn = ^TSpawn;
  TSpawn = record
    Obj: Pointer;
    ClassName: string;
    Name: string;
    IsBarItem: Boolean;
    { Klickbehandlung: Method.Code = @ClickThunk, Method.Data = dieser Satz }
    Method: TDelphiMethod;
    Handler: TAmsClickEvent;
    Tag: Integer;
  end;

  { Ein umgehaengtes Element des Hosts - mit dem Rueckweg. }
  PMoved = ^TMoved;
  TMoved = record
    Obj: Pointer;
    ClassName: string;
    Name: string;
    OldParent: Pointer;
    OldLeft, OldTop: Integer;
  end;

var
  gSpawned: TList = nil;      { PSpawn }
  gMoved: TList = nil;        { PMoved }
  gCtorSlot: Integer = -2;    { -2 = noch nicht gesucht }
  gParentSlot: Integer = -2;
  gCounter: Integer = 0;

{ Wird vom Host als TNotifyEvent gerufen: EAX = Data (unser Satz),
  EDX = Sender. Ab hier sind wir wieder in FPC-Land. }
procedure ClickThunk(ASpawn: PSpawn; ASender: Pointer); register;
begin
  try
    if (ASpawn = nil) or not Assigned(ASpawn^.Handler) then Exit;
    ASpawn^.Handler(ASender, ASpawn^.Tag);
  except
    on E: Exception do
      AmsLog('Factory-Klick EXCEPTION: ' + E.Message);
  end;
end;

{ ------------------------------------------------------------ Bereitschaft - }

function AmsCtorSlot: Integer;
begin
  if gCtorSlot = -2 then
  begin
    gCtorSlot := -1;
    if AmsBindFactory then
    begin
      gCtorSlot := AmsVmtIndexOf(hcComponentClass, hcComponentCreate, 64);
      if gCtorSlot >= 0 then
        AmsLogFmt('Factory: virtueller Konstruktor auf VMT-Offset %d',
                  [gCtorSlot])
      else
        AmsLog('Factory: Konstruktorslot im VMT von TComponent NICHT ' +
               'gefunden - es wird nichts angelegt');
    end;
  end;
  Result := gCtorSlot;
end;

function AmsSetParentSlot: Integer;
begin
  if gParentSlot = -2 then
  begin
    gParentSlot := -1;
    if AmsBindFactory then
    begin
      gParentSlot := AmsVmtIndexOf(hcControlClass, hcControlSetParent, 200);
      if gParentSlot >= 0 then
        AmsLogFmt('Factory: TControl.SetParent auf VMT-Offset %d',
                  [gParentSlot])
      else
        AmsLog('Factory: Slot von TControl.SetParent NICHT gefunden - ' +
               'Bedienelemente lassen sich nicht einhaengen');
    end;
  end;
  Result := gParentSlot;
end;

function AmsFactoryReady: Boolean;
begin
  Result := False;
  if not AmsBindFactory then
    Exit(AmsFail('Elemente anlegen: rtl-/vcl-Symbole fehlen (laeuft das ' +
                 'hier ueberhaupt in AMS?)'));
  if AmsCtorSlot < 0 then
    Exit(AmsFail('Elemente anlegen: der virtuelle Konstruktor ist im VMT ' +
                 'nicht auffindbar - andere Delphi-Version?'));
  Result := True;
end;

{ --------------------------------------------------------------- Klassen --- }

function AmsResolveClass(const AClassName: string): Pointer;
var
  F: TAmsElementFilter;
  L: TAmsElementArray;
  i, n: Integer;
begin
  Result := nil;
  if Trim(AClassName) = '' then
  begin
    AmsFail('Keine Klasse angegeben');
    Exit;
  end;

  { Der kurze Weg: der Host registriert die Klassen, die er selbst streamt. }
  if AmsBindCore then
    try
      Result := hcGetClass(AmsStr(Trim(AClassName)));
    except
      Result := nil;
    end;
  if Result <> nil then Exit;

  { Der lange: was auf dem Bildschirm steht, hat einen Klassenzeiger. Damit
    laesst sich auch nachbauen, was nirgends registriert ist. }
  F := AmsFilterAll;
  F.ClassName := Trim(AClassName);
  F.MaxResults := 50;
  n := AmsFindElements(F, L);
  for i := 0 to n - 1 do
    if SameText(L[i].ClassName, Trim(AClassName)) then
    begin
      Result := AmsClassOf(L[i].Obj);
      if Result <> nil then
      begin
        AmsLogFmt('Klasse "%s" aus der laufenden Oberflaeche geholt (%s)',
                  [AClassName, L[i].Path]);
        Exit;
      end;
    end;

  AmsFailFmt('Klasse "%s" ist weder registriert noch in der Oberflaeche zu ' +
             'finden', [AClassName]);
end;

function AmsBarManagerOf(AObj: Pointer): Pointer;
var
  O: Pointer;
  Guard: Integer;
begin
  Result := nil;
  if AObj <> nil then
  begin
    if AmsInheritsFrom(AObj, 'TdxBarManager') then Exit(AObj);

    if AmsInheritsFrom(AObj, 'TdxBar') and AmsBindBars and
       Assigned(hcBarGetBarManager) then
      try
        Result := hcBarGetBarManager(AObj);
      except
        Result := nil;
      end;
    if Result <> nil then Exit;

    { Ribbon-Elemente kennen ihren Manager; ist die Eigenschaft nicht
      published, tut es die Besitzerkette. }
    Result := AmsGetObj(AObj, 'BarManager');
    if (Result <> nil) and AmsInheritsFrom(Result, 'TdxBarManager') then Exit;
    Result := nil;

    O := AObj;
    Guard := 0;
    while (O <> nil) and (Guard < 12) do
    begin
      if AmsInheritsFrom(O, 'TdxBarManager') then Exit(O);
      try
        O := PPointer(PtrUInt(O) + ofsComponentOwner)^;
      except
        Break;
      end;
      Inc(Guard);
    end;
  end;

  { Letzte Zuflucht: derselbe Name, den auch AmsApi.Ribbon voreinstellt. }
  Result := AmsFindAnywhere('dxBarManager1');
  if (Result <> nil) and not AmsInheritsFrom(Result, 'TdxBarManager') then
    Result := nil;
end;

{ ---------------------------------------------------------------- Anlegen -- }

function AmsCreateComponent(ACls, AOwner: Pointer): Pointer;
var
  Slot: Integer;
  Ctor: TFnComponentCreate;
begin
  Result := nil;
  if ACls = nil then
  begin
    AmsFail('Keine Klasse angegeben');
    Exit;
  end;
  { Der Slot gilt fuer TComponent und alles darunter. Auf einer anderen
    Klasse waere er ein Sprung in eine beliebige fremde Methode. }
  if not AmsClassInheritsFrom(ACls, 'TComponent') then
  begin
    if AmsClassNameOf(ACls) = '' then
      AmsFailFmt('%p ist kein Klassenzeiger', [ACls])
    else
      AmsFailFmt('"%s" stammt nicht von TComponent ab - so etwas legt diese ' +
                 'Unit nicht an', [AmsClassNameOf(ACls)]);
    Exit;
  end;
  if not AmsFactoryReady then Exit;
  Slot := AmsCtorSlot;

  try
    Ctor := TFnComponentCreate(PPointer(PByte(ACls) + Slot)^);
    if not Assigned(Ctor) then
    begin
      AmsFail('Konstruktorslot ist leer');
      Exit;
    end;
    { DL = 1: der Konstruktor fordert den Speicher selbst an (Delphi-Heap)
      und ruft am Ende AfterConstruction. }
    Result := Ctor(ACls, 1, AOwner);
  except
    on E: Exception do
    begin
      AmsFailFmt('Konstruktor von "%s" EXCEPTION: %s',
                 [AmsClassNameOf(ACls), E.Message]);
      Result := nil;
    end;
  end;

  if Result = nil then
    AmsFailFmt('Konstruktor von "%s" lieferte nichts', [AmsClassNameOf(ACls)])
  else
    AmsLogFmt('Angelegt: %s -> %p', [AmsClassNameOf(ACls), Result]);
end;

function AmsNewDefaults: TAmsNewOptions;
begin
  Result.ClassName := '';
  Result.Caption := '';
  Result.Name := '';
  Result.Target := nil;
  Result.Owner := nil;
  Result.Left := AmsKeep;
  Result.Top := AmsKeep;
  Result.Width := AmsKeep;
  Result.Height := AmsKeep;
  Result.OnClick := nil;
  Result.Tag := 0;
  Result.BarManager := nil;
end;

{ Freier Komponentenname. Vergeben wird er nur, wenn er wirklich frei ist -
  ein doppelter Name wirft im Host eine Exception. }
function FreshName(const AWish: string): string;
var
  Guard: Integer;
begin
  if AWish <> '' then
  begin
    if AmsFindAnywhere(AWish) = nil then Exit(AWish);
    AmsLogFmt('Name "%s" ist vergeben - es wird einer erzeugt', [AWish]);
  end;
  Guard := 0;
  repeat
    Inc(gCounter);
    Inc(Guard);
    Result := Format('AmsNeu%d', [gCounter]);
  until (AmsFindAnywhere(Result) = nil) or (Guard > 500);
end;

{ Satz im Verzeichnis anlegen. }
function Remember(AObj: Pointer; AIsBarItem: Boolean): PSpawn;
begin
  New(Result);
  Result^.Obj := AObj;
  Result^.ClassName := AmsClassName(AObj);
  Result^.Name := AmsName(AObj);
  Result^.IsBarItem := AIsBarItem;
  Result^.Handler := nil;
  Result^.Tag := 0;
  Result^.Method.Code := nil;
  Result^.Method.Data := nil;
  if gSpawned = nil then gSpawned := TList.Create;
  gSpawned.Add(Result);
end;

function FindSpawn(AObj: Pointer): PSpawn;
var
  i: Integer;
begin
  Result := nil;
  if (gSpawned = nil) or (AObj = nil) then Exit;
  for i := 0 to gSpawned.Count - 1 do
    if PSpawn(gSpawned[i])^.Obj = AObj then
      Exit(PSpawn(gSpawned[i]));
end;

{ Zeigt der Zeiger noch auf dasselbe Element? Dieselbe billige Probe wie
  AmsElementAlive - ohne sie wuerde beim Abraeumen in fremden Speicher
  gegriffen, wenn der Host das Element schon zerstoert hat. }
function StillAlive(ASpawn: PSpawn): Boolean;
begin
  Result := (ASpawn <> nil) and (ASpawn^.Obj <> nil) and
            (AmsClassName(ASpawn^.Obj) = ASpawn^.ClassName) and
            (AmsName(ASpawn^.Obj) = ASpawn^.Name);
end;

procedure SetClickHandler(ASpawn: PSpawn; AHandler: TAmsClickEvent;
  ATag: Integer);
begin
  if (ASpawn = nil) or not Assigned(AHandler) then Exit;
  if not AmsHasProp(ASpawn^.Obj, 'OnClick') then
  begin
    AmsLogFmt('%s hat kein OnClick - Klickbehandlung entfaellt',
              [ASpawn^.ClassName]);
    Exit;
  end;
  ASpawn^.Handler := AHandler;
  ASpawn^.Tag := ATag;
  ASpawn^.Method.Code := @ClickThunk;
  ASpawn^.Method.Data := ASpawn;
  AmsSetMethod(ASpawn^.Obj, 'OnClick', ASpawn^.Method);
end;

function AmsNewElement(const AOptions: TAmsNewOptions;
  out AObj: Pointer): Boolean;
var
  Cls, Mgr: Pointer;
  IsBar: Boolean;
  Spawn: PSpawn;
  Nm, Err: string;
begin
  Result := False;
  AObj := nil;
  AmsClearError;

  Cls := AmsResolveClass(AOptions.ClassName);
  if Cls = nil then Exit;

  IsBar := AmsClassInheritsFrom(Cls, 'TdxBarItem');
  if IsBar then
  begin
    { Ribbon-Elemente gehoeren an einen Manager, nicht an einen Konstruktor:
      AddItem meldet sie dort an. Ohne das kennt die Leiste sie nicht. }
    if not AmsBindBars then
      Exit(AmsFail('Ribbon-Element anlegen: afnUiCore-Symbole fehlen'));
    Mgr := AOptions.BarManager;
    if Mgr = nil then Mgr := AmsBarManagerOf(AOptions.Target);
    if Mgr = nil then
      Exit(AmsFail('Ribbon-Element anlegen: kein TdxBarManager gefunden'));
    try
      AObj := hcBarAddItem(Mgr, Cls);
    except
      on E: Exception do
        Exit(AmsFail('TdxBarManager.AddItem EXCEPTION: ' + E.Message));
    end;
    if AObj = nil then
      Exit(AmsFail('TdxBarManager.AddItem lieferte nichts'));
    AmsLogFmt('Ribbon-Element %s angelegt -> %p',
              [AmsClassNameOf(Cls), AObj]);
  end
  else
  begin
    AObj := AmsCreateComponent(Cls, AOptions.Owner);
    if AObj = nil then Exit;
  end;

  Spawn := Remember(AObj, IsBar);

  { Ab hier ist das Element im Verzeichnis: was jetzt noch schiefgeht, darf
    kein halb fertiges Element stehen lassen. }
  try
    Nm := FreshName(AOptions.Name);
    if Nm <> '' then
    begin
      AmsSetStr(AObj, 'Name', Nm);
      Spawn^.Name := AmsName(AObj);
    end;

    if AOptions.Caption <> '' then
      AmsSetElementCaption(AObj, AOptions.Caption);

    SetClickHandler(Spawn, AOptions.OnClick, AOptions.Tag);

    if AOptions.Target <> nil then
      if not AmsAttachElement(AObj, AOptions.Target) then
      begin
        { Grund festhalten: AmsRemoveElement raeumt auch AmsLastError ab. }
        Err := AmsLastError;
        AmsRemoveElement(AObj);
        AObj := nil;
        Exit(AmsFail(Err));
      end;

    if (AOptions.Left <> AmsKeep) or (AOptions.Top <> AmsKeep) or
       (AOptions.Width <> AmsKeep) or (AOptions.Height <> AmsKeep) then
      AmsSetElementBounds(AObj, AOptions.Left, AOptions.Top,
                          AOptions.Width, AOptions.Height);

    AmsClearError;
    AmsLogFmt('Neues Element %s "%s" angelegt',
              [AmsClassName(AObj), AmsName(AObj)]);
    Result := True;
  except
    on E: Exception do
    begin
      AmsRemoveElement(AObj);
      AObj := nil;
      Result := AmsFail('Anlegen EXCEPTION: ' + E.Message);
    end;
  end;
end;

{ ------------------------------------------------------------- Einhaengen -- }

function AmsAttachElement(AObj, ATarget: Pointer): Boolean;
var
  Links, Link: Pointer;
  Slot: Integer;
  SetParent: TFnSetParent;
begin
  Result := False;
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  if ATarget = nil then Exit(AmsFail('Kein Ziel angegeben'));

  { --- Ribbon-Element: ItemLink in einer Leiste --- }
  if AmsInheritsFrom(AObj, 'TdxBarItem') then
  begin
    if not AmsInheritsFrom(ATarget, 'TdxBar') then
      Exit(AmsFailFmt('Ein Ribbon-Element gehoert in eine Leiste (TdxBar), ' +
                      'nicht in [%s]', [AmsClassName(ATarget)]));
    if not AmsBindBars then Exit(AmsFail('afnUiCore-Symbole fehlen'));
    try
      Links := hcBarGetItemLinks(ATarget);
      if Links = nil then
        Exit(AmsFail('ItemLinks der Leiste nicht lesbar'));
      Link := hcBarLinksAdd(Links, AObj);
      if Link = nil then
        Exit(AmsFail('ItemLinks.Add lieferte nichts'));
    except
      on E: Exception do
        Exit(AmsFail('Einhaengen EXCEPTION: ' + E.Message));
    end;
    AmsLogFmt('%s in die Leiste "%s" gehaengt',
              [AmsClassName(AObj), AmsName(ATarget)]);
    Exit(True);
  end;

  { --- Bedienelement: Parent --- }
  if not AmsInheritsFrom(AObj, 'TControl') then
    Exit(AmsFailFmt('[%s] ist weder Bedienelement noch Ribbon-Element - ' +
                    'wohin sollte es?', [AmsClassName(AObj)]));
  if not AmsInheritsFrom(ATarget, 'TWinControl') then
    Exit(AmsFailFmt('[%s] kann nichts aufnehmen; gebraucht wird ein ' +
                    'TWinControl (Formular, Panel, Registerkarte)',
                    [AmsClassName(ATarget)]));

  Slot := AmsSetParentSlot;
  if Slot < 0 then
    Exit(AmsFail('Slot von TControl.SetParent nicht gefunden'));
  try
    { VIRTUELL: TWinControl haengt an SetParent das Erzeugen des Fensters.
      Die Basisfassung wuerde ein Bedienelement ohne Fenster hinterlassen. }
    SetParent := TFnSetParent(PPointer(PByte(AmsClassOf(AObj)) + Slot)^);
    if not Assigned(SetParent) then
      Exit(AmsFail('SetParent-Slot ist leer'));
    SetParent(AObj, ATarget);
  except
    on E: Exception do
      Exit(AmsFail('SetParent EXCEPTION: ' + E.Message));
  end;

  AmsLogFmt('%s "%s" haengt jetzt an %s "%s"',
            [AmsClassName(AObj), AmsName(AObj), AmsClassName(ATarget),
             AmsName(ATarget)]);
  Result := True;
end;

function AmsMoveElement(AObj, ATarget: Pointer): Boolean;
var
  M: PMoved;
  Old: Pointer;
  L, T, W, H: Integer;
begin
  Result := False;
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  if not AmsInheritsFrom(AObj, 'TControl') then
    Exit(AmsFail('Umhaengen geht nur bei Bedienelementen; ein ' +
                 'Ribbon-Element haengt an Verknuepfungen des Hosts'));

  { Der Rueckweg muss VOR dem Umhaengen abgelesen werden - danach ist der
    alte Container weg. Gemerkt wird nur, was uns nicht selbst gehoert:
    eigene Elemente verschwinden beim Abraeumen ohnehin. }
  Old := nil;
  L := AmsKeep;
  T := AmsKeep;
  if not AmsIsSpawned(AObj) then
  begin
    Old := AmsParentOf(AObj);
    if not AmsGetElementBounds(AObj, L, T, W, H) then
    begin
      L := AmsKeep;
      T := AmsKeep;
    end;
  end;

  Result := AmsAttachElement(AObj, ATarget);
  if not Result then Exit;

  if not AmsIsSpawned(AObj) then
  begin
    New(M);
    M^.Obj := AObj;
    M^.ClassName := AmsClassName(AObj);
    M^.Name := AmsName(AObj);
    M^.OldParent := Old;
    M^.OldLeft := L;
    M^.OldTop := T;
    if gMoved = nil then gMoved := TList.Create;
    gMoved.Add(M);
    if Old = nil then
      AmsLogFmt('Umhaengen: der bisherige Container von "%s" war nicht zu ' +
                'ermitteln - das laesst sich beim Entladen nicht ' +
                'zurueckhaengen', [AmsName(AObj)]);
  end;
end;

{ --------------------------------------------------------------- Klonen ---- }

function AmsCopyProps(ASource, ADest: Pointer; ACopyEvents: Boolean): Integer;
var
  Props: TAmsPropArray;
  i, n: Integer;
  Val: string;
  Obj: Pointer;
  M: TDelphiMethod;
  Journal: Boolean;
begin
  Result := 0;
  if (ASource = nil) or (ADest = nil) then
  begin
    AmsFail('Klonen: Quelle oder Ziel fehlt');
    Exit;
  end;

  { Ein frisch angelegtes Element hat keinen Zustand, der sich zuruecknehmen
    liesse. Ohne das Abschalten liefe das Journal (512 Plaetze) bei einem
    einzigen Klon voll und die echten Aenderungen fielen hinten heraus. }
  Journal := AmsRecordChanges;
  AmsRecordChanges := False;
  try
    n := AmsPropList(ASource, Props, False);
    for i := 0 to n - 1 do
    begin
      if not Props[i].Writable then Continue;
      { Der Name macht die Komponente auffindbar und muss eindeutig
        bleiben - er wird getrennt vergeben. }
      if SameText(Props[i].Name, 'Name') then Continue;

      try
        case Props[i].Kind of
          pkMethod:
            begin
              if not ACopyEvents then Continue;
              if not AmsGetPropMethod(ASource, Props[i].Name, M) then Continue;
              if (M.Code = nil) and (M.Data = nil) then Continue;
              if AmsSetPropMethod(ADest, Props[i].Name, M) then Inc(Result);
            end;
          pkClass:
            begin
              { Nur ueber eine Setzmethode - die macht Assign. Ein
                unmittelbares Feld wuerde den Zeiger teilen. }
              if AmsPropWritesField(ASource, Props[i].Name) then Continue;
              Obj := AmsGetPropObject(ASource, Props[i].Name);
              { nil nicht schreiben: Font := nil ist ein Absturz, kein
                Loeschen. }
              if Obj = nil then Continue;
              if AmsSetOrd(ADest, Props[i].Name, Integer(PtrUInt(Obj))) then
                Inc(Result);
            end;
          pkInteger, pkChar, pkEnum, pkString, pkSet:
            begin
              Val := AmsGetProp(ASource, Props[i].Name);
              if (Val = '') and (Props[i].Kind <> pkString) then Continue;
              if AmsSetProp(ADest, Props[i].Name, Val) then Inc(Result);
            end;
        else
          { Gleitkomma, Int64, Variant: nicht als Text lesbar. Sie stehen im
            Log, damit man sieht, was der Klon NICHT geerbt hat. }
          AmsLogFmt('Klon: "%s" (%s) nicht kopierbar',
                    [Props[i].Name, Props[i].TypeName]);
        end;
      except
        on E: Exception do
          AmsLogFmt('Klon: "%s" uebersprungen (%s)',
                    [Props[i].Name, E.Message]);
      end;
    end;
  finally
    AmsRecordChanges := Journal;
  end;
  AmsClearError;
end;

function AmsCloneElementEx(ASource, ATarget: Pointer; const AName: string;
  ACopyEvents: Boolean; ALeft, ATop: Integer; out AClone: Pointer): Boolean;
var
  Cls, Mgr, Parent, SrcParent: Pointer;
  IsBar, SameParent: Boolean;
  Spawn: PSpawn;
  Nm, Err: string;
  L, T, W, H, n: Integer;
begin
  Result := False;
  AClone := nil;
  SrcParent := nil;
  AmsClearError;

  if ASource = nil then Exit(AmsFail('Keine Vorlage angegeben'));
  Cls := AmsClassOf(ASource);
  if Cls = nil then Exit(AmsFail('Die Vorlage hat keine lesbare Klasse'));
  IsBar := AmsInheritsFrom(ASource, 'TdxBarItem');

  { --- Wohin? --- }
  Parent := ATarget;
  if IsBar then
  begin
    if (Parent <> nil) and not AmsInheritsFrom(Parent, 'TdxBar') then
      Exit(AmsFailFmt('Ein Ribbon-Element gehoert in eine Leiste (TdxBar); ' +
                      '[%s] ist keine', [AmsClassName(Parent)]));
    if Parent = nil then
      Exit(AmsFail('Fuer die Kopie eines Ribbon-Elements muss eine Leiste ' +
                   '(TdxBar) als Ziel gewaehlt werden'));
  end
  else
  begin
    { Jede dieser Fragen kostet einen Durchlauf ueber die Fenster des
      Prozesses - deshalb genau einmal. }
    SrcParent := AmsParentOf(ASource);
    { Ein Ziel, das selbst nichts aufnehmen kann, ist als "daneben" gemeint -
      dann in dessen Container. }
    if (Parent <> nil) and not AmsIsContainer(Parent) then
      Parent := AmsParentOf(Parent);
    if Parent = nil then Parent := SrcParent;
    if Parent = nil then
      Exit(AmsFailFmt('Kein Container fuer die Kopie: %s', [AmsLastError]));
  end;
  SameParent := (not IsBar) and (Parent <> nil) and (Parent = SrcParent);

  { --- Anlegen --- }
  if IsBar then
  begin
    if not AmsBindBars then
      Exit(AmsFail('Ribbon-Element klonen: afnUiCore-Symbole fehlen'));
    Mgr := AmsBarManagerOf(Parent);
    if Mgr = nil then Mgr := AmsBarManagerOf(ASource);
    if Mgr = nil then
      Exit(AmsFail('Ribbon-Element klonen: kein TdxBarManager gefunden'));
    try
      AClone := hcBarAddItem(Mgr, Cls);
    except
      on E: Exception do
        Exit(AmsFail('TdxBarManager.AddItem EXCEPTION: ' + E.Message));
    end;
    if AClone = nil then
      Exit(AmsFail('TdxBarManager.AddItem lieferte nichts'));
  end
  else
  begin
    AClone := AmsCreateComponent(Cls, nil);
    if AClone = nil then Exit;
  end;

  Spawn := Remember(AClone, IsBar);
  try
    { Erst einhaengen, dann kopieren: Eigenschaften wie Align, Anchors oder
      TabOrder tun ohne Container nichts bzw. gehen schief. }
    if not AmsAttachElement(AClone, Parent) then
    begin
      Err := AmsLastError;
      AmsRemoveElement(AClone);
      AClone := nil;
      Exit(AmsFail(Err));
    end;

    n := AmsCopyProps(ASource, AClone, ACopyEvents);

    Nm := FreshName(AName);
    if Nm <> '' then
    begin
      AmsSetStr(AClone, 'Name', Nm);
      Spawn^.Name := AmsName(AClone);
    end;

    { Lage: was gewuenscht ist, sonst die des Originals - und wenn beide im
      selben Container sitzen, versetzt, sonst laege die Kopie unsichtbar
      genau auf dem Original. }
    if not IsBar then
    begin
      if (ALeft = AmsKeep) and (ATop = AmsKeep) and SameParent then
      begin
        if AmsGetElementBounds(ASource, L, T, W, H) then
          AmsSetElementPos(AClone, L + 16, T + 16);
      end
      else if (ALeft <> AmsKeep) or (ATop <> AmsKeep) then
        AmsSetElementPos(AClone, ALeft, ATop);
    end;

    AmsClearError;
    AmsLogFmt('Klon von %s "%s" -> "%s" (%d Eigenschaften%s)',
              [AmsClassName(ASource), AmsName(ASource), AmsName(AClone), n,
               BoolToStr(ACopyEvents, ' mit Ereignissen', '')]);
    Result := True;
  except
    on E: Exception do
    begin
      AmsRemoveElement(AClone);
      AClone := nil;
      Result := AmsFail('Klonen EXCEPTION: ' + E.Message);
    end;
  end;
end;

function AmsCloneElement(ASource, ATarget: Pointer;
  out AClone: Pointer): Boolean;
begin
  Result := AmsCloneElementEx(ASource, ATarget, '', False, AmsKeep, AmsKeep,
                              AClone);
end;

{ ------------------------------------------------------------ Verzeichnis -- }

function AmsIsSpawned(AObj: Pointer): Boolean;
begin
  Result := FindSpawn(AObj) <> nil;
end;

function AmsSpawnCount: Integer;
begin
  if gSpawned = nil then Result := 0 else Result := gSpawned.Count;
end;

{ Ein Element wirklich abraeumen. Zuerst die Klickbehandlung abklemmen: sie
  zeigt in dieses Modul, und ein Klick nach dem Entladen waere toedlich. }
procedure Discard(ASpawn: PSpawn);
var
  Alive: Boolean;
begin
  if ASpawn = nil then Exit;
  Alive := StillAlive(ASpawn);
  if Alive then
  begin
    if Assigned(ASpawn^.Handler) then AmsClearMethod(ASpawn^.Obj, 'OnClick');
    try
      { Der Speicher stammt aus dem Delphi-Heap; nur TObject.Free gibt ihn
        dort richtig zurueck. Der Destruktor haengt das Element aus seinem
        Container und - beim Ribbon-Element - aus allen Leisten aus. }
      if Assigned(hcObjectFree) then
        hcObjectFree(ASpawn^.Obj)
      else
        AmsSetOrd(ASpawn^.Obj, 'Visible', 0);
    except
      on E: Exception do
      begin
        AmsLogFmt('Freigeben von "%s" EXCEPTION: %s - es wird nur ' +
                  'unsichtbar gemacht', [ASpawn^.Name, E.Message]);
        AmsSetOrd(ASpawn^.Obj, 'Visible', 0);
      end;
    end;
  end
  else
    AmsLogFmt('"%s" [%s] gibt es nicht mehr - nichts freizugeben',
              [ASpawn^.Name, ASpawn^.ClassName]);
  ASpawn^.Handler := nil;
  ASpawn^.Obj := nil;
  Dispose(ASpawn);
end;

function AmsRemoveElement(AObj: Pointer): Boolean;
var
  Spawn: PSpawn;
begin
  Result := False;
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  Spawn := FindSpawn(AObj);
  if Spawn = nil then
    Exit(AmsFailFmt('"%s" [%s] stammt nicht von diesem Plugin - fremde ' +
                    'Elemente werden hier nicht entfernt',
                    [AmsName(AObj), AmsClassName(AObj)]));
  gSpawned.Remove(Spawn);
  Discard(Spawn);
  AmsClearError;
  Result := True;
end;

procedure AmsDumpSpawned(ADest: TStrings);
var
  i: Integer;
  S: PSpawn;
  M: PMoved;
begin
  if ADest = nil then Exit;
  ADest.Add(Format('%-24s %-26s %s', ['Name', 'Klasse', 'Zustand']));
  ADest.Add(StringOfChar('-', 70));
  if gSpawned <> nil then
    for i := 0 to gSpawned.Count - 1 do
    begin
      S := PSpawn(gSpawned[i]);
      ADest.Add(Format('%-24s %-26s %s', [S^.Name, S^.ClassName,
        BoolToStr(StillAlive(S), 'lebt', 'weg')]));
    end;
  if (gMoved <> nil) and (gMoved.Count > 0) then
  begin
    ADest.Add('');
    ADest.Add('Umgehaengt (wird beim Entladen zurueckgehaengt):');
    for i := 0 to gMoved.Count - 1 do
    begin
      M := PMoved(gMoved[i]);
      ADest.Add(Format('  %-24s %-26s zurueck nach %s',
        [M^.Name, M^.ClassName, AmsName(M^.OldParent)]));
    end;
  end;
end;

function AmsFactoryRelease: Integer;
var
  i: Integer;
  M: PMoved;
begin
  Result := 0;

  { Erst die fremden Elemente zurueckhaengen: sie koennten an einem eigenen
    Element haengen, das gleich verschwindet. }
  if gMoved <> nil then
  begin
    for i := gMoved.Count - 1 downto 0 do
    begin
      M := PMoved(gMoved[i]);
      if (M^.Obj <> nil) and (M^.OldParent <> nil) and
         (AmsClassName(M^.Obj) = M^.ClassName) then
      begin
        if AmsAttachElement(M^.Obj, M^.OldParent) then
        begin
          if (M^.OldLeft <> AmsKeep) or (M^.OldTop <> AmsKeep) then
            AmsSetElementPos(M^.Obj, M^.OldLeft, M^.OldTop);
          Inc(Result);
        end;
      end;
      M^.Obj := nil;
      Dispose(M);
    end;
    gMoved.Clear;
  end;

  if gSpawned <> nil then
  begin
    { Rueckwaerts: das zuletzt Angelegte kann auf Frueherem sitzen. }
    for i := gSpawned.Count - 1 downto 0 do
    begin
      Discard(PSpawn(gSpawned[i]));
      Inc(Result);
    end;
    gSpawned.Clear;
  end;

  if Result > 0 then
    AmsLogFmt('Factory: %d Element(e) abgeraeumt', [Result]);
end;

initialization
  gSpawned := nil;
  gMoved := nil;

finalization
  AmsFactoryRelease;
  FreeAndNil(gSpawned);
  FreeAndNil(gMoved);

end.
