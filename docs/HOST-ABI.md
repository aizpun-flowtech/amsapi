# Host-ABI: ASSFINET AMS.5

Dies ist das teuer erarbeitete Wissen hinter `AmsApi`. **Nichts davon steht in
irgendeiner Dokumentation** — alles stammt aus der Disassembly von `rtl230.bpl`,
`vcl230.bpl`, `afnBu.bpl`, `afnUiCore.bpl` und `afnComponentsRt.bpl`.

Wer die Bibliothek nur *benutzt*, braucht dieses Dokument nicht. Wer sie
erweitert oder auf eine neue AMS-Version hebt, braucht es vollständig.

Installation, auf die sich die Angaben beziehen:
`C:\Program Files (x86)\assfinet ams.5\BIN`

---

## 1. Delphi-Version und Bitbreite

Alle Host-Packages tragen den Suffix `230` → **Delphi/RAD Studio 10 Seattle**,
verifiziert über VersionInfo `23.0.21418.4207`, Copyright 1997–2015.

**32 Bit ist Pflicht** (`ppc386 -Pi386`). AMS ist eine x86-Anwendung; eine
64-Bit-BPL lädt der Host gar nicht erst.

Free Pascal 3.2.2 (i386-Win32) erzeugt kompatiblen Code.

| Suffix | Delphi |
|---|---|
| 190 | XE5 |
| 200 | XE6 |
| 210 | XE7 |
| 220 | XE8 |
| **230** | **10 Seattle — AMS.5 heute** |
| 240 | 10.1 Berlin |
| 250 | 10.2 Tokyo |
| 260 | 10.3 Rio |
| 270 | 10.4 Sydney |
| 280 | 11 Alexandria |
| 290 | 12 Athens |

`AmsApi.Bind` ermittelt den Suffix zur Laufzeit über ToolHelp (Modulliste nach
`rtl<Ziffern>.bpl` durchsuchen) und fällt auf das Durchprobieren der Tabelle
zurück. Deshalb steht `230` in der Bibliothek an genau **einer** Stelle: als
erster Kandidat der Fallback-Liste.

---

## 2. Ladevorgang eines BPL

```
LoadPackage(Datei)
  ├─ InitializePackage
  │    ├─ CheckForDuplicateUnits   ← steigt aus, wenn keine PACKAGEINFO-RCDATA da ist
  │    └─ GetProcAddress(Modul, 'Initialize')   ← muss existieren
  └─ FinalizePackage → GetProcAddress(Modul, 'Finalize')
```

**Konsequenz:** Ein FPC-Plugin braucht *keine* PACKAGEINFO-Ressource. Es braucht
genau drei Exporte:

```pascal
exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';
```

Die Quelldatei muss `library` sein, nicht `program`.

### `PluginInit`

```pascal
{ EAX = TPluginManager, EDX = @Result.
  Das Ergebnis muss AddRef'd zurückkommen — der Aufrufer macht IntfCopy
  und released seinen Temporären später. }
procedure PluginInit(AManager: Pointer; AResult: PPointer); register;
```

---

## 3. `IPlugin`

```pascal
IPlugin = interface
  ['{14DF4663-0C2D-4C29-A7EE-18BEA251C41D}']
  procedure SetPluginManager(AManager: Pointer);      // vtbl +0C
  procedure SetPluginItem(AItem: Pointer);            // vtbl +10
  procedure Loaded;                                   // vtbl +14
  function  UnloadQuery: Boolean;                     // vtbl +18
  procedure Unload;                                   // vtbl +1C
  procedure DoCommand(ACmd: Integer; AData: Pointer); // vtbl +20
end;
```

> **Falle:** `QueryInterface` (+00), `_AddRef` (+04) und `_Release` (+08) sind
> **stdcall** (COM-Konvention), alle übrigen Methoden **register**. Wer
> `_Release` als register aufruft, korrumpiert den Stack und stirbt irgendwo
> später mit einer Access Violation. Genau darüber ist der erste Lauf von
> `tests\hosttest.lpr` gestolpert.

### `DoCommand`-Codes

| Code | Name | `AData` |
|---|---|---|
| 0 | `pcBuSessionUpdate` | — |
| 1 | `pcInitConcenter` | — |
| 2 | `pcExitConcenter` | — |
| 3 | `pcInitBuSession` | **`TBuSession`** |
| 4 | `pcInitInternePlugins` | — |
| 5 | `pcPluginUpdate` | **`TBuSession`** |

Bei 3 und 5 **vor** dem Merken den Klassennamen prüfen
(`Pos('BuSession', ClassNameOf(AData)) > 0`) — nicht blind speichern.
`AmsApi.Plugin` tut das und ruft danach `SessionChanged`.

### Reihenfolge beim Start

```
AmsApplication StartUp  →  Plugins laden  →  UiSession StartUp
```

Beim Laden des Plugins existiert das Hauptfenster also **noch nicht**. Deshalb
pollt `AmsApi.Plugin` per `SetTimer` im Message-Loop des Hosts, bis
`AmsFindMainWindow` etwas liefert, und ruft dann `AfterMainWindow`.

---

## 4. ABI-Regeln

| Regel | Detail |
|---|---|
| Aufrufkonvention | Delphi `register`: EAX, EDX, ECX, dann Stack |
| Konstruktoren | EAX = Klassenreferenz, **DL = Alloc-Flag**, ECX = 1. Parameter, Stack = 2. |
| Interface-Rückgabe | über **verstecktes letztes Zeigerargument** — nicht über EAX! |
| String-Rückgabe | ebenso verstecktes `@Result` |
| VMT-Offsets | `vmtClassName` = **−56**, `vmtTypeInfo` = **−72**, `vmtIntfTable` = **−84** |
| `TComponent` | `FOwner` = **+4**, `FName` = **+8** |
| `TGraphic.LoadFromFile` | VMT-Slot 21 = Offset **$54** |
| `IInterface._Release` | Vtable-Offset **+08**, stdcall |
| Interface → Objekt | Adjustor-Thunks (`add eax,-IOffset`) verraten das Mapping; für `IWorkflowEngine` ist der Offset **$30** |

### `GetStrProp`

Die belegte Konvention ist:

```
EAX = Instance, EDX = PropName, ECX = @Result
```

**nicht** EAX = @Result. Falsch herum stürzt nichts ab — es liefert still Müll
und lässt *jeden* Namensvergleich fehlschlagen („er findet nix“).

---

### Delphi-RTTI: `TTypeInfo`, `TTypeData`, `TPropInfo`

Alle drei sind `packed` — es wird nirgends ausgerichtet, die Offsets stimmen
byteweise. Das ist die Grundlage von `AmsApi.Props`; `tests\rttiprobe.lpr`
prüft jeden dieser Offsets gegen `TComponent` und `TFont` aus den echten
Packages.

```
Klasse -> TypeInfo:   PPointer(PByte(ClassPtr) + vmtTypeInfo)^     (-72)

TTypeInfo
  +0  Kind: Byte                 tkClass = 7, tkEnumeration = 3, tkSet = 6,
  +1  Name: ShortString          tkMethod = 8, tkUString = 18, tkInteger = 1
  danach TTypeData, also bei 2 + Length(Name)

TTypeData bei tkClass
  +0  ClassType: TClass
  +4  ParentInfo: PPTypeInfo
  +8  PropCount: SmallInt        ALLE published properties, auch geerbte
 +10  UnitName: ShortString

TTypeData bei tkEnumeration
  +0  OrdType: Byte
  +1  MinValue: Integer
  +5  MaxValue: Integer
  +9  BaseType: PPTypeInfo
 +13  NameList: ShortString[]    MaxValue-MinValue+1 Stück, hintereinander

TTypeData bei tkSet
  +0  OrdType: Byte
  +1  CompType: PPTypeInfo       zeigt auf die Aufzählung der Elemente

TPropInfo
  +0  PropType: PPTypeInfo       ZWEIFACH dereferenzieren
  +4  GetProc      +8 SetProc    nil = nicht lesbar / nicht schreibbar
 +12  StoredProc  +16 Index  +20 Default
 +24  NameIndex: SmallInt        Index, unter dem GetPropInfos einträgt
 +26  Name: ShortString
```

Zwei Konsequenzen für die Praxis:

* `Boolean` ist in Delphi eine **Aufzählung**, keine eigene Typart. Deshalb
  liefert `GetEnumProp` dort `'True'`/`'False'` — und `Visible` eines
  `TdxBarItem` ist ebenfalls eine Aufzählung (`ivNever`/`ivAlways`), kein
  Boolean. Die Ordinalwerte 0/1 passen für beides.
* `SetProc = nil` ist die einzige verlässliche Auskunft darüber, ob eine
  Eigenschaft geschrieben werden darf. Ohne diese Prüfung wirft der Host bei
  jedem read-only-Zugriff eine Exception über die Modulgrenze.

---

## 5. Die Heap-Falle

FPC und die Delphi-RTL haben **getrennte Heaps**. Ein von FPC allozierter
String, den Delphi freigibt, ist ein Absturz — oft erst viel später und an
ganz anderer Stelle.

Lösung: `UnicodeString` mit **RefCount −1** fälschen. Delphi behandelt das wie
ein Konstantenliteral und fasst den Speicher nie an.

```
StrRec, 12 Byte vor dem ersten Zeichen:
  +0  CodePage (Word)    = 1200
  +2  ElemSize (Word)    = 2
  +4  RefCount (LongInt) = -1     ← niemals freigeben
  +8  Length   (LongInt)
  +12 Zeichen, nullterminiert
```

Implementiert in `AmsApi.Strings.AmsStr`, inklusive Cache für wiederholt
benutzte Propertynamen. Freigegeben wird ausschließlich in der `finalization`
der Unit.

**Regel für die gesamte API:** Über die Modulgrenze gehen nur Zeiger, Integer
und Boolean. Niemals managed Typen (string, dynamische Arrays, Interfaces als
Wert).

---

## 6. Symboltabelle

Alle per `GetModuleHandleW` + `GetProcAddress` gebunden, gruppenweise und lazy
in `AmsApi.Bind`. Namen exakt so, mit `$`.
`tools\checksyms.py` prüft die Liste gegen die installierten BPLs.

### `rtl<NNN>.bpl`

| Mangled Name | Signatur (FPC-Typedef) |
|---|---|
| `@System@Classes@TComponent@FindComponent$qqrx20System@UnicodeString` | `function(Self, AName: Pointer): Pointer; register` |
| `@System@Classes@GetClass$qqrx20System@UnicodeString` | `function(AName: Pointer): Pointer; register` |
| `@System@Classes@TComponent@GetComponentCount$qqrv` | `function(Self: Pointer): Integer; register` |
| `@System@Classes@TComponent@GetComponent$qqri` | `function(Self: Pointer; I: Integer): Pointer; register` |
| `@System@Classes@TCollection@GetCount$qqrv` | `function(Self: Pointer): Integer; register` |
| `@System@Classes@TCollection@GetItem$qqri` | `function(Self: Pointer; I: Integer): Pointer; register` |
| `@System@Typinfo@GetStrProp$qqrp14System@TObjectx20System@UnicodeString` | `procedure(Obj, PropName, AResult: Pointer); register` |
| `@System@Typinfo@SetStrProp$qqrp14System@TObjectx20System@UnicodeStringt2` | `procedure(Obj, PropName, Value: Pointer); register` |
| `@System@Typinfo@GetOrdProp$qqrp14System@TObjectx20System@UnicodeString` | `function(Obj, PropName: Pointer): Integer; register` |
| `@System@Typinfo@SetOrdProp$qqrp14System@TObjectx20System@UnicodeStringi` | `procedure(Obj, PropName: Pointer; V: Integer); register` |
| `@System@Typinfo@SetMethodProp$qqrp14System@TObjectx20System@UnicodeStringrx14System@TMethod` | `procedure(Obj, PropName, MethodPtr: Pointer); register` |
| `@System@Typinfo@GetObjectProp$qqrp14System@TObjectx20System@UnicodeStringp17System@TMetaClass` | `function(Obj, PropName, MinClass: Pointer): Pointer; register` |
| `@System@@UStrClr$qqrpv` | `procedure(AStr: Pointer); register` |

Zweite Staffel — Typinformationen auslesen statt raten (Gruppe `Props`):

| Mangled Name | Signatur (FPC-Typedef) |
|---|---|
| `@System@Typinfo@GetPropInfo$qqrp24System@Typinfo@TTypeInfox20System@UnicodeString` | `function(ATypeInfo, APropName: Pointer): Pointer; register` |
| `@System@Typinfo@GetPropInfos$qqrp24System@Typinfo@TTypeInfop57System@%StaticArray$p24System@Typinfo@TPropInfoi$i16380$%` | `procedure(ATypeInfo, AList: Pointer); register` |
| `@System@Typinfo@IsPublishedProp$qqrp14System@TObjectx20System@UnicodeString` | `function(AObj, APropName: Pointer): Boolean; register` |
| `@System@Typinfo@GetEnumProp$qqrp14System@TObjectx20System@UnicodeString` | `procedure(AObj, APropName, AResult: Pointer); register` |
| `@System@Typinfo@SetEnumProp$qqrp14System@TObjectx20System@UnicodeStringt2` | `procedure(AObj, APropName, AValue: Pointer); register` |
| `@System@Typinfo@GetSetProp$qqrp14System@TObjectx20System@UnicodeStringo` | `procedure(AObj, APropName: Pointer; ABrackets: Boolean; AResult: Pointer); register` |
| `@System@Typinfo@SetSetProp$qqrp14System@TObjectx20System@UnicodeStringt2` | `procedure(AObj, APropName, AValue: Pointer); register` |
| `@System@Typinfo@GetMethodProp$qqrp14System@TObjectx20System@UnicodeString` | `procedure(AObj, APropName, AResult: Pointer); register` |

Drei Punkte dazu, die jeweils eine Falle sind:

* **`GetPropInfo` nur in der Überladung ohne `TTypeKinds`.** Die andere nimmt
  ein Set über 22 Elemente = 3 Byte. Delphi übergibt Sets von 1, 2 oder 4 Byte
  im Register, alle anderen **als Referenz** — ein 3-Byte-Set ist genau der
  Sonderfall, den man nicht braucht.
* **`GetPropList` wird bewusst nicht benutzt.** Es alloziert die Liste im
  Delphi-Heap, und der Aufrufer müsste sie dort wieder freigeben. `GetPropInfos`
  füllt ein Array, das der Aufrufer selbst besitzt — kein fremder Heap.
* **`GetSetProp` hat drei echte Parameter.** Damit ist EAX/EDX/ECX belegt und
  das versteckte `@Result` liegt auf dem **Stack**. Bei `GetEnumProp` und
  `GetMethodProp` (zwei Parameter) liegt es dagegen in ECX.

Die Ergebnisstrings von `GetEnumProp` und `GetSetProp` kommen aus dem
Delphi-Heap und müssen mit `UStrClr` freigegeben werden — nicht mit `FreeMem`
von FPC. Siehe Abschnitt 5.

Zusätzlich vom Testhost benutzt:
`@System@Sysutils@LoadPackage$qqrx20System@UnicodeString`,
`@System@Sysutils@UnloadPackage$qqrui`.

### `vcl<NNN>.bpl`

| Mangled Name | Signatur |
|---|---|
| `@Vcl@Controls@FindControl$qqrp6HWND__` | `function(H: HWND): Pointer; register` |
| `@Vcl@Graphics@TBitmap@SetAlphaFormat$qqr25Vcl@Graphics@TAlphaFormat` | `procedure(Self: Pointer; V: Byte); register` |

### `afnUiCore.bpl` (enthält DevExpress ExpressBars)

| Mangled Name | Signatur |
|---|---|
| `@Dxbar@TdxBarManager@AddItem$qqrp17System@TMetaClass` | `function(Self, AClass: Pointer): Pointer; register` |
| `@Dxbar@TdxBar@GetItemLinks$qqrv` | `function(Self: Pointer): Pointer; register` |
| `@Dxbar@TdxBarItemLinks@Add$qqrp16Dxbar@TdxBarItem` | `function(Self, AItem: Pointer): Pointer; register` |
| `@Dxbar@TdxBarItemLink@GetItem$qqrv` | `function(Self: Pointer): Pointer; register` |
| `@Dxbar@TdxBarItem@DirectClick$qqrv` | `procedure(Self: Pointer); register` |

### `afnComponentsRt.bpl`

| Mangled Name | Signatur |
|---|---|
| `@Afnglobalevents@TafnActionManager@` | Klassen-VMT (kein Aufruf, Zeiger) |
| `@Afnglobalevents@TafnActionManager@GetInstance$qqrv` | `function(AClass: Pointer): Pointer; register` |
| `@Afnglobalevents@TafnActionManager@GetActions$qqr20System@UnicodeString` | `function(Self, AName: Pointer): Pointer; register` |
| `@Afnglobalevents@TafnAction@Execute$qqrp30Afnglobalevents@TafnDataPacketpv` | `procedure(Self, APacket, AUserData: Pointer); register` |
| `@Afnglobalevents@TafnEventManager@` | Klassen-VMT |
| `@Afnglobalevents@TafnEventManager@GetInstance$qqrv` | wie oben |
| `@Afnglobalevents@TafnEventManager@GetEvents$qqr20System@UnicodeString` | wie oben |
| `@Afnglobalevents@TafnEvent@Fire$qqrp30Afnglobalevents@TafnDataPacketpv62System@%Set$35Afnglobalevents@TafnEventFireOptiont1$i0$t1$i0$%` | `procedure(Self, APacket, AUserData: Pointer; AOpt: Byte); register` |

`GetInstance` ist eine **Klassenmethode**: EAX ist die Klassenreferenz (das
exportierte VMT-Symbol), keine Instanz.

### `afnBu.bpl`

| Mangled Name | Signatur |
|---|---|
| `@Uifworkflowengine@WorkflowEngine$qqrxp17Bubase@TBuSession` | **`procedure(ASession: Pointer; AResult: PPointer); register`** ← liefert Interface über EDX |
| `@Uifworkflowengine@TWorkflowEngine@GetTaskList$qqrv` | `function(Self: Pointer): Pointer; register` |
| `@Uifworkflowengine@TWorkflowTaskList@FindTaskByName$qqrx20System@UnicodeString` | `function(Self, AName: Pointer): Pointer; register` |
| `@Uifworkflowengine@TWorkflowTask@ExecuteWithoutCheck$qqrx69System@%DelphiInterface$42Uifworkflowengine@Interfaces@IWorkflowItem%x65System@%DelphiInterface$38Uifworkflowengine@Interfaces@IWorkflow%` | `procedure(Self, AItem, AWorkflow: Pointer); register` |

---

## 7. Wo die Komponenten wirklich hängen

Viele AMS-Komponenten hängen **nicht** am Hauptformular, sondern an Frames, die
eigene Wurzeln sind. Eine Suche allein ab dem Hauptformular findet sie nicht.

Der Weg von `AmsApi.Components.AmsBuildRootList`:

1. `EnumWindows` über alle Top-Level-Fenster des eigenen Prozesses
2. je Fenster **genau einmal** `EnumChildWindows`
3. je Fensterhandle `Vcl.Controls.FindControl` → VCL-Objekt
4. dessen Owner-Kette (`TComponent.FOwner`, Offset +4) hochlaufen

> **Performance-Falle (echter Anwenderbefund):** `EnumChildWindows` enumeriert
> bereits *alle* Nachfahren. Ein zusätzlicher Aufruf je Kindfenster macht das
> Ganze quadratisch — 60 Sekunden statt Millisekunden.

---

## 8. Wie Automatismen wirklich laufen

Wichtige Korrektur des Anwenders, die eine ganze Sackgasse beendet hat:

> „es sollen die automatismen aus der automatismustabelle gestartet werden
> können wie Automatismus ausführen also nicht wirklich workflowengine/workflow“

- AMS' eigener Menüpunkt „Automatismus ausführen“ ist `TuifAction acAutomatismen`
  — ein `TdxBarSubItem`, dessen `DropdownMenu` das `TdxRibbonPopupMenu`
  **`rpmAutomatismen`** ist.
- Dieses Menü wird **zur Laufzeit kontextabhängig** gefüllt. Was drinsteht,
  hängt davon ab, was gerade offen ist (Kunde / Vertrag / Vorgang).
- Der **funktionierende** Weg ist deshalb nicht die WorkflowEngine, sondern:
  Menü suchen → `ItemLinks` durchlaufen → `Caption` vergleichen →
  `TdxBarItem.DirectClick`. Damit läuft der Automatismus exakt im selben
  Kontext wie beim manuellen Klick. → `AmsApi.Automatismus`
- Der WorkflowEngine-Pfad findet nur **AutoStart**-Automatismen, die beim
  Sessionstart vorgeladen werden. → `AmsApi.Workflow`, ausdrücklich als
  Zweitweg, nicht als Standardweg.

**Grenze der Fehlerbehandlung:** Fehler *innerhalb* eines Automatismus-Skripts
laufen in AMS' Skript-Engine. Nach `DirectClick` sieht das Plugin davon nichts
mehr — die Prüfung gehört ins Skript (`if (WItem == null) ...`).

---

## 9. Fallstricke — jeder einzelne hat Zeit gekostet

1. **`GetStrProp`-Konvention** — ECX ist `@Result`, nicht EAX. Falsch herum
   liefert es still Müll, nichts stürzt ab, alle Namensvergleiche schlagen fehl.
2. **`WorkflowEngine()` liefert ein Interface über EDX.** Als normale Funktion
   deklariert → Access Violation. Objektzeiger dann über Offset `$30`
   (validiert per Klassenname, nicht blind gerechnet).
3. **`EnumChildWindows` pro Fenster ist quadratisch** — siehe Abschnitt 7.
4. **`GetObjectProp('ItemLinks')` auf einem VCL-`TPopupMenu`** wirft `EEDFADE` —
   das hat `Items`, nicht `ItemLinks`. Klassenfilter (`'PopupMenu'` **und**
   (`'dxBar'` oder `'dxRibbon'`)) plus `try/except` sind Pflicht.
5. **`TdxBarButton.Glyph` / `LargeGlyph` sind schlichte `TBitmap`**, nicht
   `TdxSmartGlyph`. `LoadFromFile` ist die BMP-Basisimplementierung aus `vcl230`
   → PNG geht nur nach Konvertierung plus `SetAlphaFormat(afDefined)`.
6. **`TStrings.Values` als INI-Parser ist falsch** — vergleicht Schlüsselnamen
   buchstäblich, `  Url = x` liefert stillschweigend den Default.
7. **HTTPS nicht am Port erkennen.** `Comp.nScheme = INTERNET_SCHEME_HTTPS` (2),
   sonst bricht `https://host:8443`.
8. **Cross-Heap** — siehe Abschnitt 5. Die häufigste Absturzursache bei
   FPC-Plugins in Delphi-Hosts.
9. **`_Release` ist stdcall**, die IPlugin-Methoden sind register — siehe
   Abschnitt 3.
10. **`OnClick` vor dem Entladen abklemmen.** Bleibt ein `TdxBarItem` mit einem
    Methodenzeiger in ein entladenes Modul stehen, ist der nächste Klick ein
    Absturz. `AmsApi.Ribbon.AmsReleaseButtons` tut das; `TAmsPlugin.Unload`
    ruft es.
11. **Veraltete BPL im Plugin-Ordner.** Bei „geht nicht“ zuerst Dateigröße und
    Zeitstempel der installierten Datei mit dem Build vergleichen —
    `hosttest.exe` gibt beides aus.
12. **Fehlende Symbole dürfen kein Absturz sein**, sondern ein `False` mit
    Klartext im Log — genau daran ist das `ScriptScheduler`-Plugin des
    Herstellers zerbrochen (4 fehlende Unit-Init/Finalize-Symbole von ~375
    Importen, Build-Mismatch).
13. **Ein Thunk räumt nur den Stack, den er kennt.** In der register-Konvention
    räumt der **Aufgerufene** die Stackparameter. Ein `TNotifyEvent`-Thunk
    (zwei Register, nichts auf dem Stack) an ein `OnMouseDown` gehängt lässt
    die dort übergebenen Stackparameter stehen — der Stack ist danach kaputt.
    Deshalb prüft `AmsHookEvent` über die RTTI, dass der Ereignistyp wirklich
    `TNotifyEvent` heißt, und lehnt alles andere ab.
14. **Geänderte Host-Eigenschaften vor dem Entladen zurücknehmen.** Dasselbe
    Argument wie bei Punkt 10, nur ohne Absturz und deshalb tückischer: eine
    vom Plugin deaktivierte Schaltfläche bleibt deaktiviert, auch wenn das
    Plugin längst weg ist. Der Anwender sieht ein kaputtes AMS und hat keinen
    Anhaltspunkt, woher es kommt. `AmsApi.Props` schreibt jede Änderung mit
    ihrem alten Wert mit, `AmsUiRelease` nimmt sie in `Unload` zurück.
15. **`TComponent.Name` ist kein gewöhnliches Textfeld.** Der Host findet seine
    Komponenten über `FindComponent(Name)` wieder. Eine Umbenennung macht sie
    für ihn unauffindbar — `AmsSetProp` lehnt `Name` deshalb ab und verlangt
    ausdrücklich `AmsRenameComponent`.

---

## 10. Offene Punkte

| Punkt | Stand |
|---|---|
| Kontextfreier Automatismus-Start | Bräuchte `TAutomatismus` per Delphi-Konstruktor (EAX=Klasse, DL=1, ECX=Owner, Session auf Stack) + `SelektionByIdent` + `LoadTaskIntoEngine`. Inline-Assembler, Absturzrisiko. **Nur gegen die Test-DB und nur bei echtem Bedarf.** |
| Ribbon-Elemente beim Entladen entfernen | `AmsReleaseButtons` klemmt `OnClick` ab und setzt `Visible := ivNever`. Das `TdxBarItem` selbst gehört dem Host und wird nicht freigegeben — dafür wäre der Delphi-Destruktor nötig. |
| Andere Ribbon-Gruppen als „Benutzerdefiniert“ | Über `TAmsRibbonOptions.BarName` einstellbar, aber nur `bmbBenutzerdefiniert` ist im echten AMS verifiziert. |
