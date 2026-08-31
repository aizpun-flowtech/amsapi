# Übergabe — Projekt „AmsApi“

**Ziel des neuen Projekts:** Den Host-Anbindungscode aus dem funktionierenden Prototyp
`AmsToolbox.lpr` (2171 Zeilen, ein Stück) herauslösen und zu einer **wiederverwendbaren,
dokumentierten API** machen, mit der sich weitere AMS.5-Plugins in ~50 Zeilen schreiben
lassen — ohne Delphi, ohne RAD Studio, ohne Hersteller-SDK.

Stand: 31.08.2026. Host: **ASSFINET AMS.5**, `C:\Program Files (x86)\assfinet ams.5\BIN`.

---

## 0. Zuerst: Quellen aus dem Temp-Ordner retten

Der gesamte bisherige Stand liegt in einem **sitzungsgebundenen Temp-Verzeichnis** und kann
jederzeit weggeräumt werden:

```
C:\Users\conno\AppData\Local\Temp\claude\C--Program-Files--x86--assfinet-ams-5-BIN\
  3643ca42-9ddb-48f5-af0a-4721109adb4d\scratchpad\
```

**Erster Schritt der neuen Session:**

```cmd
robocopy "C:\Users\conno\AppData\Local\Temp\claude\C--Program-Files--x86--assfinet-ams-5-BIN\3643ca42-9ddb-48f5-af0a-4721109adb4d\scratchpad" "C:\Users\conno\Projects\ams-api\_prototype" /E
```

Danach `git init` im Zielordner. Ab dann ist der Prototyp Referenz, nicht mehr Arbeitsstand.

### Was in `scratchpad\` liegt

| Pfad | Inhalt | Rolle im neuen Projekt |
|---|---|---|
| `AmsToolbox\AmsToolbox.lpr` | Das komplette Plugin, 2171 Z. | **Steinbruch** — hieraus wird die API extrahiert |
| `AmsToolbox\httpclient.inc` | WinHTTP-Client | fast unverändert übernehmbar |
| `AmsToolbox\iniread.inc` | INI-Parser | fast unverändert übernehmbar |
| `AmsToolbox\glyphconv.inc` | PNG → 32-bit-BMP (FPImage) | fast unverändert übernehmbar |
| `AmsToolbox\build.cmd` | Compile + Deploy | Vorlage (heute repariert, war korrupt) |
| `AmsToolbox\deploy\AmsToolbox\` | BPL + dokumentierte `plugin.ini` | Auslieferungsformat |
| `amsplug\hosttest.lpr` | Offscreen-Testhost, lädt das BPL echt | **Testinfrastruktur, unbedingt behalten** |
| `amsplug\harness.lpr` | Minimal-Loader (`rtl230!Initialize` → `LoadPackage`) | Testinfrastruktur |
| `amsplug\TestPlugin.lpr` | Kleinstes lauffähiges Plugin | Basis für `samples\HelloButton` |
| `*.py` (22 Stück) | Reverse-Engineering-Werkzeug | Für neue Symbole weiter gebraucht |

### Die Python-Werkzeuge (werden noch gebraucht)

| Datei | Zweck |
|---|---|
| `pe.py` | Export-Namen aus BPL/DLL. **Eigener Parser, weil `pefile` bei ~13916 Symbolen abschneidet** — `afnBu.bpl` hat 34803 |
| `disx.py`, `at.py`, `disva.py` | Capstone-Disassembler mit String-/Import-Annotation |
| `rtti.py`, `clsprops.py` | Delphi-RTTI: Typinfo, published properties (Klasse VMT−72) |
| `vmt.py`, `intf.py` | VMT-Slots, Interface-Tabellen (Adjustor-Thunks) |
| `imps.py`, `impxref.py`, `callers.py`, `callto.py`, `xref.py`, `vxref.py` | Import- und Aufrufstellensuche |
| `ctx.py`, `scan.py`, `near.py`, `strings.py`, `missing.py`, `noop.py`, `paths.py` | String-/Kontextsuche |

---

## 1. Was heute nachweislich funktioniert

Alles Folgende ist **im echten AMS des Anwenders** gelaufen, belegt durch `%TEMP%\AmsToolbox.log`:

- BPL wird von AMS' eigenem Plugin-Manager geladen, `PluginInit` liefert ein gültiges `IPlugin`
- Echter `TdxBarLargeButton` hängt in der Ribbon-Gruppe **„Benutzerdefiniert“**
- Eigenes Icon aus PNG per Pfad (relativ ab Plugin-Ordner)
- WinHTTP GET/POST gegen Live-Endpunkte (Status 200 verifiziert)
- Browser mit URL öffnen
- Benannte `TafnAction` ausführen / benanntes `TafnEvent` feuern
- **Automatismus im aktuellen Kontext ausführen** — Log zeigte `[11] "MessageBox anzeigen" -> ausgefuehrt`
  bei 17 gefundenen Kontext-Automatismen
- Fehlermeldungen als MessageBox, abschaltbar über `ShowErrors=0`

Belegausschnitt aus dem Log des Anwenders:

```
BuSession gemerkt: 0BC0A340 [TBuSession]
FindComponent("dxBarManager1")        -> 0BB5FDC0
FindComponent("bmbBenutzerdefiniert") -> 0E26ECD0
GetClass("TdxBarLargeButton")         -> 03D041D0
TdxBarManager.AddItem                 -> 181F3C80
ItemLinks.Add                         -> 18397840
Ribbon-Button in Gruppe "Benutzerdefiniert" eingehaengt
```

---

## 2. Der Host-Vertrag — die eigentliche Substanz

Dies ist das Wissen, das teuer war. **Nichts davon steht in irgendeiner Dokumentation**, alles
stammt aus Disassembly von `rtl230.bpl`, `vcl230.bpl`, `afnBu.bpl`, `afnUiCore.bpl`,
`afnComponentsRt.bpl`.

### 2.1 Delphi-Version

Alle Host-Packages tragen den Suffix `230` → **Delphi/RAD Studio 10 Seattle**.
Verifiziert über VersionInfo: `23.0.21418.4207`, Copyright 1997–2015.
Free Pascal 3.2.2 (i386-Win32) unter `C:\FPC\3.2.2` erzeugt kompatiblen Code.

### 2.2 Ladevorgang eines BPL

```
LoadPackage(Datei)
  ├─ InitializePackage
  │    ├─ CheckForDuplicateUnits   ← steigt aus, wenn keine PACKAGEINFO-RCDATA da ist
  │    └─ GetProcAddress(Modul, 'Initialize')   ← muss existieren
  └─ FinalizePackage → GetProcAddress(Modul, 'Finalize')
```

**Konsequenz:** Ein FPC-Plugin braucht *keine* PACKAGEINFO-Ressource. Es braucht genau drei
Exporte:

```pascal
exports
  PkgInitialize name 'Initialize',
  PkgFinalize   name 'Finalize',
  PluginInit    name 'PluginInit';
```

Die Unit muss `library` sein, nicht `program`.

### 2.3 `PluginInit`

```pascal
{ EAX = TPluginManager, EDX = @Result.
  Das Ergebnis muss AddRef'd zurückkommen — der Aufrufer macht IntfCopy
  und released seinen Temporären später. }
procedure PluginInit(AManager: Pointer; AResult: PPointer); register;
```

### 2.4 `IPlugin`

```pascal
IPlugin = interface
  ['{14DF4663-0C2D-4C29-A7EE-18BEA251C41D}']
  procedure SetPluginManager(AManager: Pointer);   // vtbl +0C
  procedure SetPluginItem(AItem: Pointer);         // vtbl +10
  procedure Loaded;                                // vtbl +14
  function  UnloadQuery: Boolean;                  // vtbl +18
  procedure Unload;                                // vtbl +1C
  procedure DoCommand(ACmd: Integer; AData: Pointer); // vtbl +20
end;
```

`DoCommand`-Codes (aus dem Host extrahiert):

| Code | Name | `AData` |
|---|---|---|
| 0 | `pcBuSessionUpdate` | — |
| 1 | `pcInitConcenter` | — |
| 2 | `pcExitConcenter` | — |
| 3 | `pcInitBuSession` | **`TBuSession`** |
| 4 | `pcInitInternePlugins` | — |
| 5 | `pcPluginUpdate` | **`TBuSession`** |

Bei 3 und 5 vor dem Merken den Klassennamen prüfen (`Pos('BuSession', ClassNameOf(AData)) > 0`) —
nicht blind speichern.

### 2.5 ABI-Regeln (die Fallstricke stecken hier)

| Regel | Detail |
|---|---|
| Aufrufkonvention | Delphi `register`: EAX, EDX, ECX, dann Stack |
| Konstruktoren | EAX = Klassenreferenz, **DL = Alloc-Flag**, ECX = 1. Parameter, Stack = 2. |
| Interface-Rückgabe | über **verstecktes letztes Zeigerargument** — nicht über EAX! |
| String-Rückgabe | ebenso verstecktes `@Result` |
| VMT-Offsets | `vmtClassName` = **−56**, `vmtTypeInfo` = **−72**, `vmtIntfTable` = **−84** |
| `TComponent` | `FOwner` = **+4**, `FName` = **+8** |
| `TGraphic.LoadFromFile` | VMT-Slot 21 = Offset **$54** |
| Interface → Objekt | Adjustor-Thunks (`add eax,-IOffset`) verraten das Mapping; für `IWorkflowEngine` ist der Offset **$30** |

`GetStrProp` hat mich zwei Runden gekostet — die belegte Konvention ist:

```
EAX = Instance, EDX = PropName, ECX = @Result
```

nicht EAX = @Result. Das ließ still und leise *jeden* Namensvergleich fehlschlagen
(„er findet nix“).

### 2.6 Die Heap-Falle — der wichtigste einzelne Punkt

FPC und die Delphi-RTL haben **getrennte Heaps**. Ein von FPC allozierter String, den Delphi
freigibt, ist ein Absturz. Lösung: `UnicodeString` mit **Refcount −1** fälschen, dann fasst die
Delphi-Seite ihn nie an:

```pascal
function CS(const S: UnicodeString): Pointer;
var P: PByte; N: Integer;
begin
  N := Length(S);
  P := GetMem(12 + (N + 1) * 2);
  PWord(P)^      := 1200;   { CodePage }
  PWord(P + 2)^  := 2;      { ElemSize }
  PInteger(P+4)^ := -1;     { RefCount — niemals freigeben }
  PInteger(P+8)^ := N;      { Length }
  if N > 0 then Move(S[1], (P + 12)^, N * 2);
  PWord(P + 12 + N * 2)^ := 0;
  Result := P + 12;
end;
```

**Regel für die gesamte API:** Über die Modulgrenze gehen nur Zeiger, Integer und Boolean.
Niemals managed Typen (string, dynamische Arrays, Interfaces als Wert).

### 2.7 Symboltabelle

Alle per `GetModuleHandleW` + `GetProcAddress` gebunden (`Sym(Modul, Name)`), lazy in
`BindHostSymbols`. Namen exakt so, mit `$`:

**`rtl230.bpl`**

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
| `@System@Typinfo@SetOrdProp$qqrp14System@TObjectx20System@UnicodeStringi` | `procedure(Obj, PropName: Pointer; V: Integer); register` |
| `@System@Typinfo@SetMethodProp$qqrp14System@TObjectx20System@UnicodeStringrx14System@TMethod` | `procedure(Obj, PropName, MethodPtr: Pointer); register` |
| `@System@Typinfo@GetObjectProp$qqrp14System@TObjectx20System@UnicodeStringp17System@TMetaClass` | `function(Obj, PropName, MinClass: Pointer): Pointer; register` |
| `@System@@UStrClr$qqrpv` | `procedure(AStr: Pointer); register` |

**`vcl230.bpl`**

| Mangled Name | Signatur |
|---|---|
| `@Vcl@Controls@FindControl$qqrp6HWND__` | `function(H: HWND): Pointer; register` |
| `@Vcl@Graphics@TBitmap@SetAlphaFormat$qqr25Vcl@Graphics@TAlphaFormat` | `procedure(Self: Pointer; V: Byte); register` |

**`afnUiCore.bpl`** (enthält DevExpress ExpressBars)

| Mangled Name | Signatur |
|---|---|
| `@Dxbar@TdxBarManager@AddItem$qqrp17System@TMetaClass` | `function(Self, AClass: Pointer): Pointer; register` |
| `@Dxbar@TdxBar@GetItemLinks$qqrv` | `function(Self: Pointer): Pointer; register` |
| `@Dxbar@TdxBarItemLinks@Add$qqrp16Dxbar@TdxBarItem` | `function(Self, AItem: Pointer): Pointer; register` |
| `@Dxbar@TdxBarItemLink@GetItem$qqrv` | `function(Self: Pointer): Pointer; register` |
| `@Dxbar@TdxBarItem@DirectClick$qqrv` | `procedure(Self: Pointer); register` |

**`afnComponentsRt.bpl`**

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

**`afnBu.bpl`**

| Mangled Name | Signatur |
|---|---|
| `@Uifworkflowengine@WorkflowEngine$qqrxp17Bubase@TBuSession` | **`procedure(ASession: Pointer; AResult: PPointer); register`** ← liefert Interface über EDX |
| `@Uifworkflowengine@TWorkflowEngine@GetTaskList$qqrv` | `function(Self: Pointer): Pointer; register` |
| `@Uifworkflowengine@TWorkflowTaskList@FindTaskByName$qqrx20System@UnicodeString` | `function(Self, AName: Pointer): Pointer; register` |
| `@Uifworkflowengine@TWorkflowTask@ExecuteWithoutCheck$qqrx69System@%DelphiInterface$42Uifworkflowengine@Interfaces@IWorkflowItem%x65System@%DelphiInterface$38Uifworkflowengine@Interfaces@IWorkflow%` | `procedure(Self, AItem, AWorkflow: Pointer); register` |

### 2.8 Wie Automatismen wirklich laufen

Wichtige Korrektur des Anwenders, die eine ganze Sackgasse beendet hat:
*„es sollen die automatismen aus der automatismustabelle gestartet werden können wie
Automatismus ausführen also nicht wirklich workflowengine/workflow“*

- AMS' eigener Menüpunkt „Automatismus ausführen“ ist `TuifAction acAutomatismen` — ein
  `TdxBarSubItem`, dessen `DropdownMenu` das `TdxRibbonPopupMenu` **`rpmAutomatismen`** ist.
- Dieses Menü wird **zur Laufzeit kontextabhängig** gefüllt. Was drinsteht, hängt davon ab, was
  gerade offen ist (Kunde / Vertrag / Vorgang).
- Der **funktionierende** Weg ist deshalb nicht die WorkflowEngine, sondern:
  Menü suchen → `ItemLinks` durchlaufen → `Caption` vergleichen → `TdxBarItem.DirectClick`.
  Damit läuft der Automatismus exakt im selben Kontext wie beim manuellen Klick.
- Der WorkflowEngine-Pfad (`RunAutomatismus`, Zeile 934) existiert noch als zweiter Modus
  `OnClick=RunAutomatismusEngine`, findet aber nur **AutoStart**-Automatismen — die werden beim
  Sessionstart vorgeladen. Für die neue API: als „Advanced“ mitnehmen, nicht als Standardweg.

---

## 3. Zielarchitektur der wiederverwendbaren API

### 3.1 Vorschlag Unit-Aufteilung

`AmsToolbox.lpr` ist heute eine einzige Datei mit `{$I ...}`-Includes. FPC kann echte Units
kompilieren — das ist der richtige Schnitt. Nur die `library`-Datei selbst bleibt beim Plugin.

```
ams-api/
  src/
    AmsApi.Types.pas         Typedefs aller Host-Funktionszeiger, TDelphiMethod, Konstanten
    AmsApi.Bind.pas          Sym(), Lazy-Binder, Suffix-Auflösung, IsBound
    AmsApi.Strings.pas       CS(), StrPropOf(), UStrClr-Wrapper
    AmsApi.Rtti.pas          ClassNameOf, NameOf, Get/Set-Prop-Familie
    AmsApi.Components.pas    FindControl, FindComponent, Baumdurchlauf, BuildRootList
    AmsApi.Ribbon.pas        Button in Ribbon-Gruppe einhängen
    AmsApi.Glyphs.pas        aus glyphconv.inc — PNG → BMP32 + SetAlphaFormat
    AmsApi.Menus.pas         dxBar-Popups einsammeln, ScanMenu, DirectClick
    AmsApi.Automatismus.pas  Kontext-Automatismen listen / ausführen
    AmsApi.Actions.pas       TafnActionManager / TafnEventManager
    AmsApi.Workflow.pas      WorkflowEngine (Advanced, Interface-Handling)
    AmsApi.Plugin.pas        TAmsPlugin-Basisklasse + Export-Boilerplate
    AmsApi.Log.pas           threadsicheres Logging
    AmsApi.Ini.pas           aus iniread.inc
    AmsApi.Http.pas          aus httpclient.inc
  tests/
    hosttest.lpr             Offscreen-Host (aus amsplug/ übernehmen)
    unittests.lpr            CS(), IniValue(), Glyph-Konvertierung ohne AMS prüfbar
  samples/
    HelloButton/             Ziel: unter 50 Zeilen bis zum Ribbon-Button
    WebHook/                 Button → HTTP-POST
    RunAutomatismus/         Button → Automatismus im Kontext
  docs/
    HOST-ABI.md              Abschnitt 2 dieses Dokuments, gepflegt
```

### 3.2 So soll ein Plugin danach aussehen (Zielbild)

```pascal
library HelloButton;
{$MODE DELPHI}{$H+}
uses AmsApi.Plugin, AmsApi.Ribbon, AmsApi.Log;

type
  THello = class(TAmsPlugin)
    procedure AfterMainWindow; override;
    procedure OnButton(Sender: Pointer); override;
  end;

procedure THello.AfterMainWindow;
begin
  AddRibbonButton('Hallo', 'Zeigt eine Meldung', './icon32.png');
end;

procedure THello.OnButton(Sender: Pointer);
begin
  Info('Hallo aus dem Plugin');
end;

exports AmsPluginExports;   { Initialize / Finalize / PluginInit }
begin
  RegisterPluginClass(THello);
end.
```

Die Basisklasse übernimmt: Timer-Warten aufs Hauptfenster, `DoCommand`-Auswertung,
BuSession-Merken, Subclassing, sauberes `Unload`.

### 3.3 Designregeln für die Bibliothek

1. **Keine MessageBox in der Bibliothek.** Der Prototyp mischt Diagnose und UI (`Notify`/`Warn`).
   In der API: Funktionen liefern `Boolean` + `LastError: string`; ob daraus ein Dialog wird,
   entscheidet das Plugin. `ShowErrors=` bleibt Sache der Beispiel-Plugins.
2. **Versionsunabhängig binden.** Heute ist `230` an ~30 Stellen fest verdrahtet. Der Binder
   soll den Suffix zur Laufzeit ermitteln (geladene Module nach `rtl*.bpl` durchsuchen) und
   `Sym('rtl', ...)` intern auflösen. Sonst bricht alles bei der nächsten AMS-Version.
3. **Lazy und einmalig binden**, `BindHostSymbols` ist idempotent (`if Assigned(...) then Exit(True)`).
   Beibehalten, aber pro Gruppe trennen: wer nur HTTP braucht, soll nicht an fehlendem
   `afnBu.bpl` scheitern.
4. **Jeder Host-Aufruf in `try/except`.** Delphi-Exceptions kommen als `EEDFADE`
   (External exception) über die Modulgrenze und sind nicht typisiert auswertbar.
5. **Fehlende Symbole sind kein Absturz**, sondern ein `False` mit Klartext im Log —
   genau das hat das ScriptScheduler-Plugin des Herstellers zerlegt.
6. **Keine managed Typen über die Grenze** (siehe 2.6).
7. **Alles, was ohne AMS testbar ist, muss ohne AMS testbar sein** — INI, Glyph, HTTP haben
   heute schon eigene Testprogramme. Das Muster fortführen.

### 3.4 Migrationstabelle

| Aus `AmsToolbox.lpr` | Zeilen | Ziel |
|---|---|---|
| `CS`, `Sym`, `BindHostSymbols` | 446–550 | `Bind` + `Strings` |
| `ClassNameOf`, `NameOf`, `StrPropOf` | 635, 1005, 1027 | `Rtti` |
| `CollectByName`, `AddRoot`, `CollectWnd`, `CollectTop`, `BuildRootList` | 1051–1153 | `Components` |
| `CollectPopups`, `CollectMenus`, `ScanMenu` | 1154–1300 | `Menus` |
| `DumpComponents`, `DumpComponentTree` | 1301–1380 | `Components` (Diagnose) |
| `RunAutomatismusContext` | 1381–1495 | `Automatismus` (ohne die `Warn`-Aufrufe) |
| `RunAutomatismus`, `ObjFromIntf`, `ReleaseIntf` | 890–1004 | `Workflow` (Advanced) |
| `TryAddRibbonButton`, `TrySetGlyph` | 1517, 657 | `Ribbon` + `Glyphs` |
| `RunNamedAction`, `FireNamedEvent` | 822, 857 | `Actions` |
| `HttpThread`, `StartHttpRequest`, `OpenUrlInBrowser` | 757–821 | `Http` |
| `MainSubclass`, `HookMainWindow`, `UnhookMainWindow`, `TimerProc` | 1588–1707 | `Plugin` (Basisklasse) |
| `TToolboxPlugin`, `PluginInit`, `PkgInitialize`, `PkgFinalize` | 1710–1830 | `Plugin` (Boilerplate) |
| `ShowToolWindow`, `CreateHostButton`, `BuildReport`, `RefreshEdit`, Toolfenster | 101–445 | **Sample „Diagnose“**, nicht in die API |

Die Zeilen 101–445 (eigenes Win32-Fenster, Systemmenü, Hotkey, Baum-Report) sind
Prototyp-Ballast bzw. Fallback. In die Bibliothek gehört davon nur der Fallback-Button, und
auch der nur optional.

---

## 4. Bauen, testen, ausliefern

### Bauen

```cmd
"C:\FPC\3.2.2\bin\i386-Win32\ppc386.exe" -Twin32 -Pi386 -O2 -Xs -oAmsToolbox.bpl AmsToolbox.lpr
```

`build.cmd` im Prototyp macht das plus Deploy-Kopie. **32-Bit ist Pflicht** (`-Pi386`), AMS ist
eine x86-Anwendung.

### Testen ohne AMS

`amsplug\hosttest.exe` erzeugt ein Offscreen-Fenster bei −3200,−3200, lädt das BPL über den
echten `LoadPackage`-Pfad, pumpt 4 s Nachrichten, sucht den Button, schickt `WM_COMMAND`,
pumpt weitere 6 s. Damit lassen sich Ladefehler, Exportfehler und Absturz beim Init finden,
**ohne** AMS zu starten.

Wichtig für den Harness: `rtl230.bpl!Initialize` muss aufgerufen werden, **bevor** die RTL
benutzt wird — sonst `EAccessViolation` in den FastMM-Bins.

### Ausliefern

Ordner unter `BIN\plugins\<Name>\` mit `<Name>.bpl` + `plugin.ini`.

```cmd
copy /Y "...\deploy\AmsToolbox\AmsToolbox.bpl" "C:\Program Files (x86)\assfinet ams.5\BIN\plugins\AmsToolbox\"
```

> **Regel aus dem bisherigen Projekt, bitte beibehalten:** Nie selbst nach
> `C:\Program Files (x86)\assfinet ams.5\` schreiben. Das ist die Installation des Anwenders und
> braucht Administratorrechte — immer den Kopierbefehl übergeben und ihn ausführen lassen.

Laufzeit-Log: `%TEMP%\AmsToolbox.log`.

---

## 5. Fallstricke — jeder einzelne hat Zeit gekostet

1. **`GetStrProp`-Konvention** — ECX ist `@Result`, nicht EAX. Falsch herum liefert es still
   Müll, nichts stürzt ab, alle Namensvergleiche schlagen fehl.
2. **`WorkflowEngine()` liefert ein Interface über EDX.** Als normale Funktion deklariert →
   Access Violation. Objektzeiger dann über Offset `$30` (validiert per Klassenname,
   nicht blind gerechnet).
3. **`EnumChildWindows` pro Fenster ist quadratisch.** Die API enumeriert bereits *alle*
   Nachfahren. Ein Aufruf pro Top-Level-Fenster — sonst 60 Sekunden statt Millisekunden.
   Das war ein echter Anwenderbefund.
4. **`GetObjectProp('ItemLinks')` auf einem VCL-`TPopupMenu`** wirft `EEDFADE` — das hat
   `Items`, nicht `ItemLinks`. Klassenfilter (`'PopupMenu'` **und** (`'dxBar'` oder `'dxRibbon'`))
   plus `try/except` sind Pflicht.
5. **`TdxBarButton.Glyph` / `LargeGlyph` sind schlichte `TBitmap`**, nicht `TdxSmartGlyph`.
   `LoadFromFile` ist die BMP-Basisimplementierung aus `vcl230` → PNG geht nur nach Konvertierung
   (`glyphconv.inc`) plus `SetAlphaFormat(afDefined)`.
6. **`TStrings.Values` als INI-Parser ist falsch** — vergleicht Schlüsselnamen buchstäblich,
   `  Url = x` liefert stillschweigend den Default. Eigener Parser in `iniread.inc`.
7. **HTTPS nicht am Port erkennen.** `Comp.nScheme = INTERNET_SCHEME_HTTPS` (2), sonst bricht
   `https://host:8443`.
8. **Cross-Heap** — siehe 2.6. Die häufigste Absturzursache bei FPC-Plugins in Delphi-Hosts.
9. **Veraltete BPL im Plugin-Ordner.** Bei „geht nicht“ zuerst Dateigröße und Zeitstempel der
   installierten Datei mit dem Build vergleichen.
10. **Heredocs im Bash-Tool zerlegen Backslashes und `$`.** Genau so wurde `build.cmd` korrupt
    (Steuerbytes 0x03/0x08/0x0C statt `\3`, `\b`, `\p`). Pascal-Quelltext und Pfade mit dem
    Write-Tool schreiben, in Python-Patchskripten `chr(92)` verwenden.
11. **`dis.py` kollidiert mit dem Stdlib-Modul `dis`** — deshalb heißt es `disx.py`.

---

## 6. Offene Punkte

| Punkt | Stand |
|---|---|
| Build vom 31.08., 12:55 (Fehler-MessageBox) | vom Anwender **noch nicht in AMS verifiziert** |
| Wirkung der Performance-Korrektur | Log gibt jetzt `Wurzeln: N (Aufbau X ms), Menues: M, Suche Y ms` aus — Zahlen stehen noch aus |
| Kontextfreier Automatismus-Start | Bräuchte `TAutomatismus` per Delphi-Konstruktor (EAX=Klasse, DL=1, ECX=Owner, Session auf Stack) + `SelektionByIdent` + `LoadTaskIntoEngine`. Inline-Assembler, Absturzrisiko. **Nur gegen die Test-DB und nur bei echtem Bedarf.** |
| Versionsunabhängiger Binder | Konzept steht (3.3.2), nicht implementiert |
| Grenze der Fehlerbehandlung | Fehler *innerhalb* eines Automatismus-Skripts laufen in AMS' Skript-Engine, nach `DirectClick` sieht das Plugin davon nichts mehr. Prüfung gehört ins Skript (`if (WItem == null) ...`) |
| `ScriptScheduler.bpl` des Herstellers | Diagnose abgeschlossen: 4 fehlende Unit-Init/Finalize-Symbole von ~375 Importen aus `afnBu`/`afnCollectionRt`, Build-Mismatch. Auf Wunsch des Anwenders **nicht** repariert |

---

## 7. Erste Schritte der neuen Session

1. Prototyp aus dem Temp-Ordner nach `C:\Users\conno\Projects\ams-api\` sichern, `git init`.
2. `docs\HOST-ABI.md` aus Abschnitt 2 dieses Dokuments anlegen — das ist das Wissen, das nie
   wieder erarbeitet werden soll.
3. `AmsApi.Types.pas` + `AmsApi.Bind.pas` zuerst, mit **laufzeitaufgelöstem Versionssuffix**.
   Gegen `hosttest.exe` grün bekommen.
4. Dann von unten nach oben: `Strings` → `Rtti` → `Components` → `Menus` → `Ribbon`.
   Nach jeder Unit einmal bauen und mit `hosttest.exe` laden.
5. `AmsApi.Plugin.pas` mit der Basisklasse, dann `samples\HelloButton` — Erfolgskriterium ist
   das Zielbild aus 3.2 in unter 50 Zeilen.
6. Erst danach `Automatismus`, `Actions`, `Workflow` portieren.
7. `AmsToolbox` zuletzt auf die neue API umstellen und gegenprüfen, dass die verifizierten
   Funktionen aus Abschnitt 1 alle noch laufen — das ist die Regressionsprobe.

**Sprache:** Kommentare und Anwendermeldungen auf Deutsch, ohne Umlaute in MessageBox-Texten
(der Prototyp schreibt konsequent `ausgefuehrt`, `verfuegbar`) — bei der Codepage-Lage über die
Modulgrenze ist das die sichere Variante.
