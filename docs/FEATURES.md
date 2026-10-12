# AmsApi — Funktionsumfang

Was die Bibliothek kann, wozu man sie sonst Delphi, das Hersteller-SDK oder
Reverse Engineering bräuchte. Stand 12.10.2026, Version 1.1.0.

## Belegstufen

Jede Zeile trägt eine davon. Sie sagen ehrlich, wie weit etwas geprüft ist:

| | Bedeutung |
|---|---|
| **A** | Der Codepfad lief **im echten AMS des Anwenders**, belegt durch `%TEMP%\AmsToolbox.log` (Prototyp). In die API übernommen. |
| **T** | In dieser Sitzung geprüft — Unit-Tests, Symbolabgleich gegen die Installation oder `hosttest` über den echten `LoadPackage`-Pfad. |
| **N** | Neu in der API, noch nicht in einem laufenden AMS gegengeprüft. |

Die Regressionsprobe „AmsToolbox auf die neue API umstellen und alle A-Punkte
nachfahren“ steht noch aus — sie braucht ein laufendes AMS.

---

## 1. Plugin-Grundgerüst

Ein lauffähiges Plugin ist rund 30 Zeilen. Alles Folgende macht `TAmsPlugin`.

| Feature | Stufe | Detail |
|---|---|---|
| `IPlugin` vollständig implementiert | A · T | Korrekte Vtable-Reihenfolge, `register` für die Plugin-Methoden, `stdcall` für `_AddRef`/`_Release` |
| `PluginInit` mit richtiger AddRef-Semantik | A · T | Ergebnis über EDX, AddRef'd — der Host macht `IntfCopy` und released seinen Temporären |
| Export-Boilerplate | A · T | `AmsPkgInitialize` / `AmsPkgFinalize` / `AmsPluginInit`, per `exports` umbenannt auf `Initialize` / `Finalize` / `PluginInit` |
| Ohne PACKAGEINFO-Ressource | A · T | `CheckForDuplicateUnits` steigt bei nil aus — FPC-BPL braucht keine |
| Warten auf das Hauptfenster | A · T | Timer im Message-Loop des Hosts, weil Plugins **vor** der UiSession geladen werden. Danach genau einmal `AfterMainWindow` |
| `DoCommand` ausgewertet | A · T | Alle sechs Codes benannt im Log |
| `TBuSession` gemerkt | A | Bei `pcInitBuSession`/`pcPluginUpdate`, **nach Klassennamensprüfung** — nicht blind. Danach `SessionChanged` |
| Sauberes Entladen | T · N | Timer weg, Fensterhook zurück, `OnClick` abgeklemmt, Notnagel zerstört. `hosttest` fährt es durch |
| Klassenregistrierung | T | `AmsRegisterPlugin(TMeinPlugin)` im Hauptblock der `library` |
| Mehrere Plugins parallel | N | Jedes BPL linkt seine eigene Kopie; Log- und INI-Pfad leiten sich vom Modulnamen ab, kollidieren also nicht |

### Überschreibbare Haken

`Startup` · `AfterMainWindow` · `ButtonClick` · `SessionChanged` ·
`HostCommand` · `BeforeUnload` · `CanUnload` · `WantsWindowHook` ·
`WantsFallbackButton` · `WindowMessage`

### Zustand und Bequemlichkeit

`BuSession` · `MainWindow` · `Started` · `PluginManager` · `PluginItem` ·
`Log` · `LogFmt` · `LastError` · `ShowInfo` · `ShowWarning` · `ShowError` ·
`ShowLastError` · `BuildReport`

---

## 2. Ribbon und Bedienoberfläche

| Feature | Stufe | Detail |
|---|---|---|
| Echter `TdxBarLargeButton` im Ribbon | A | In der Gruppe „Benutzerdefiniert“ (`bmbBenutzerdefiniert` am `dxBarManager1`) |
| Eigenes Symbol aus PNG | A | PNG → 32-Bit-BMP (BGRA, bottom-up, unmultipliziert) + `AlphaFormat := afDefined`. `TdxBarButton.Glyph` ist ein schlichtes `TBitmap` und frisst sonst nur BMP |
| Symbol aus der Host-ImageList | A | `ImageIndex` / `LargeImageIndex` |
| Klick zurück in FPC-Code | A | Gefälschtes `TMethod` mit Thunk; pro Schaltfläche ein Slot mit Handler und Tag |
| Mehrere Schaltflächen je Plugin | N | Eigener Handler und Tag je Button über `TAmsRibbonOptions` |
| Freie Wahl von Manager, Gruppe, Buttonklasse | N | `ManagerName` / `BarName` / `ButtonClass`; verifiziert ist nur die Vorbelegung |
| Robuste Komponentensuche | A · N | Hauptformular → Manager → Tiefensuche → prozessweit über alle Wurzeln |
| Caption / Hint / Enabled nachträglich ändern | N | `AmsSetButtonCaption` · `AmsSetButtonHint` · `AmsSetButtonEnabled` |
| `OnClick` beim Entladen abklemmen | N | **Absturzschutz.** Bleibt ein `TdxBarItem` mit Zeiger ins entladene Modul stehen, ist der nächste Klick tödlich. `AmsReleaseButtons` klemmt ab und setzt `Visible := ivNever` |
| Win32-Notnagel-Button | A | Nur opt-in über `WantsFallbackButton`, nur wenn der Ribbon-Einbau nichts ergab |
| Subclassing des Hauptfensters | A | Opt-in über `WantsWindowHook`, Nachrichten kommen in `WindowMessage`, Hook wird beim Entladen zurückgenommen |

---

## 3. Vorhandene Elemente finden und bearbeiten

Nicht eigene Schaltflächen anlegen, sondern das anfassen, was AMS schon
mitbringt: deaktivieren, wieder einschalten, umbenennen, verschieben,
vergrößern, einfärben, verstecken. `AmsApi.Props` liefert die Typinformation,
`AmsApi.Ui` das Suchen und Ändern.

### Finden

| Feature | Stufe | Detail |
|---|---|---|
| Filter statt Namensraten | T · N | `TAmsElementFilter`: Name, Klasse, Beschriftung, Pfad, nur Sichtbares, nur Bedienelemente, nur Ribbon-Elemente. Alles UND-verknüpft, leere Felder zählen nicht |
| Platzhalter `*` und `?` | T | Eigener Vergleich mit Rückverfolgung, 14 Prüfungen im Unit-Test. Ohne Platzhalter: Name/Beschriftung exakt, Klasse/Pfad „enthält“ |
| Prozessweite Suche | A · N | Über alle Fensterwurzeln — sonst fehlen alle Komponenten, die auf Frames sitzen statt am Hauptformular |
| Jeder Knoten genau einmal | N | Zeigermenge mit offener Adressierung. Die Wurzelliste enthält bewusst auch Besitzer; ohne Menge wird derselbe Teilbaum vielfach durchlaufen |
| Kurzform `AmsElement` | N | Erst Name, dann Beschriftung — der Normalfall in einer Zeile |
| Mehrdeutigkeit wird gemeldet | N | Bei mehreren Treffern landen alle Pfade im Log. Dann ist der Filter zu grob, und man sieht sofort, wie er zu schärfen ist |
| Element unter dem Mauszeiger | N | `AmsElementAt` / `AmsElementAtCursor` über `WindowFromPoint` + `FindControl`, mit Aufstieg zum Elternfenster. Nur Elemente mit eigenem Fenster |
| **Element auf dem Bildschirm hervorheben** | T · N | `AmsHighlightElement` lässt einen Rahmen um das Element blinken — gezeichnet per `DSTINVERT` direkt auf den Bildschirm, zweimal gezeichnet hebt sich das wieder auf. Am Host wird dabei **nichts** verändert: keine Eigenschaft, kein Neuzeichnen, nichts zum Zurücknehmen |
| Rückweg Objekt → Fenster | T · N | `AmsWindowOfElement` — `FindControl` andersherum, über einen Durchlauf der Prozessfenster. Wieder genau ein `EnumChildWindows` je Top-Level. 0 bei Elementen ohne eigenes Fenster (Ribbon, `TGraphicControl`) |
| Element zu einem Fensterhandle | N | `AmsElementOfWindow` — die Zahl aus AutoIt Window Info, Spy++ oder WinSpy direkt einsetzen. Diese Werkzeuge zeigen die Win32-Fensterklasse (`TcxButton`), aber nie den Komponentennamen; genau den liefert der Aufruf. Prüft, dass das Fenster zum eigenen Prozess gehört |
| Pfad statt Zeiger | N | `frmMain.pnLeft.btnOk` aus der Besitzerkette — das ist die Angabe, die man in eine INI schreiben kann |
| Zeigerprobe | N | `AmsElementAlive` vergleicht Klasse und Name. Der Host kann seine Komponente längst freigegeben haben |
| Trefferliste als Tabelle | N | `AmsDumpElements` — Name, Klasse, Art, Beschriftung |

### Was ein Element kann

| Feature | Stufe | Detail |
|---|---|---|
| **Alle published properties auflisten** | T | Über die echte Delphi-RTTI: `GetPropInfos` füllt ein Array, das **wir** besitzen. `GetPropList` wäre der falsche Weg — das alloziert im Delphi-Heap |
| Typ und Schreibbarkeit je Eigenschaft | T | `SetProc = nil` heißt nur lesbar. Wird vor jedem Schreiben geprüft |
| Erlaubte Werte einer Auswahl | T | Namensliste aus dem `TTypeData` der Aufzählung: `ivNever\|ivAlways\|ivInCustomizing`. Steht in jeder Fehlermeldung |
| Eigenschaften mit Werten ausgeben | N | `AmsDumpElement` — die Antwort auf „was kann ich hier überhaupt ändern“ |
| RTTI-Offsets gegen den Host geprüft | T | `tests\rttiprobe.lpr` liest `TComponent` und `TFont` aus den echten Packages: 21 Prüfungen, ohne AMS zu starten |

### Ändern

| Feature | Stufe | Detail |
|---|---|---|
| Pfade in Eigenschaften | N | `Font.Size`, `Font.Color`, `Glyph.Transparent` — aufgelöst über `GetObjectProp`. Ohne das käme man an eine Schriftgröße nicht heran |
| Jede Eigenschaft aus Text | T · N | Die Umwandlung richtet sich nach dem RTTI-Typ, nicht nach Raten |
| Zahlen, Farben | T | `42`, `$FF`, `0x1F`, `#FF8800` (Web-RGB, wird auf `$00BBGGRR` gedreht), `clRed` und 29 weitere Namen |
| Aufzählungen im Klartext | N | `Visible=ivNever`; bei `Boolean` zusätzlich `ja`/`nein`/`an`/`aus` — damit eine INI lesbar bleibt |
| Mengen | N | `Font.Style=[fsBold,fsItalic]`, `[]` für leer |
| Fertige Kurzformen | N | `AmsEnableElement` · `AmsShowElement` · `AmsSetElementCaption` · `AmsSetElementHint` · `AmsSetElementBounds/Size/Pos` · `AmsSetElementColor` · `AmsSetElementFont` · `AmsSetElementImage` |
| `Visible` bei dxBar-Elementen | N | Dort eine Aufzählung (`ivNever`/`ivAlways`), kein Boolean — die Ordinalwerte 0/1 passen für beides, der Typ steht im Log |
| Größe vor Position setzen | N | Bei verankerten Elementen ändert eine spätere Positionierung sonst gleich wieder die Größe |
| Umbenennen nur ausdrücklich | N | `TComponent.Name` ist der Schlüssel, über den der Host seine Komponenten wiederfindet. `AmsSetProp` weist ihn ab und verweist auf `AmsRenameComponent` — ein Tippfehler in einer INI darf das nicht können |
| Element auslösen | N | `AmsClickElement`: dxBar-Element über `DirectClick`, sonst über das belegte `OnClick` |

### Zurücknehmen — der Teil, ohne den das Ganze fahrlässig wäre

| Feature | Stufe | Detail |
|---|---|---|
| **Änderungsjournal** | T · N | Jede Änderung wird mit ihrem alten Wert mitgeschrieben, der **erste** gemerkte Wert gewinnt |
| Rücknahme beim Entladen | N | `TAmsPlugin.Unload` ruft `AmsUiRelease`. Ein Plugin, das eine Schaltfläche deaktiviert und dann verschwindet, würde AMS sonst dauerhaft beschädigt zurücklassen |
| Rücknahme auf Knopfdruck | N | `AmsUndoAll` · `AmsUndoObject` · `AmsChangeCount` · `AmsDumpChanges` |
| Zeiger wird vor der Rücknahme geprüft | N | Klasse und Name müssen noch stimmen, sonst wird der Eintrag übersprungen und protokolliert |
| Nicht lesbare Werte werden gemeldet | N | Was sich nicht auslesen ließ, lässt sich nicht zurücknehmen — das steht dann im Log, statt still zu verschwinden |
| Dauerhaft ändern ist möglich | N | `AmsRecordChanges := False` bzw. `AmsAutoUndo := False` — aber ausdrücklich, nicht aus Versehen |

### Ereignis eines fremden Elements übernehmen

| Feature | Stufe | Detail |
|---|---|---|
| `OnClick` übernehmen | N | `AmsHookClick` / `AmsHookEvent`, wahlweise **zusätzlich** zur ursprünglichen Behandlung (`CallOriginal`) oder statt ihrer |
| Nur `TNotifyEvent` | N | Der Typ wird über die RTTI geprüft. Ein Ereignis mit mehr Parametern würde unser Thunk nicht vom Stack räumen — das wäre kein Absturz „vielleicht“, sondern einer mit Ansage |
| Original wird gemerkt | N | `AmsUnhookAll` trägt es beim Entladen zurück. Ohne das springt der nächste Klick in freigegebenen Speicher |

### Elemente anlegen, klonen und einhängen

`AmsApi.Factory`. Bis hierher konnte die Bibliothek ändern, was da ist. Hier
kommt Neues dazu — und zwar aus derselben Klasse wie das Vorhandene.

| Feature | Stufe | Detail |
|---|---|---|
| **Virtueller Konstruktor des Hosts** | T · N | Delphi-Konstruktoren sind virtuell; `TButton.Create` macht mehr als `TComponent.Create`. Aufgerufen wird deshalb der Slot aus dem VMT der **Zielklasse**, mit `EAX` = Klasse, `DL` = 1, `ECX` = Besitzer. `tests\rttiprobe.lpr` legt damit gegen die echte `rtl230.bpl` ein `TComponent` mit Besitzer an, benennt es und gibt es wieder frei |
| Slot wird gesucht, nicht verdrahtet | T | Die Adresse von `TComponent.Create` kommt aus dem Package (`…@$bctr$…`), ihr Platz im VMT von `TComponent` ist der Slot (`AmsVmtIndexOf`). Bei Delphi 10 Seattle ist das Offset 60, bei `TControl.SetParent` 140 — beides **gemessen**, nicht angenommen. Wird der Slot nicht gefunden, legt die Unit **nichts** an: ein falscher Slot wäre ein Sprung in eine beliebige andere Methode |
| Klasse auch ohne Registrierung | N | `AmsResolveClass`: erst `Classes.GetClass`, dann ein Element derselben Klasse in der laufenden Oberfläche — dessen Klassenzeiger tut es genauso. Was auf dem Bildschirm steht, lässt sich also immer nachbauen |
| Nur unterhalb von `TComponent` | T | Wird über die Klassenkette geprüft (`vmtParent`), bevor der Slot benutzt wird |
| Bedienelement einhängen | N | `TControl.SetParent`, ebenfalls **virtuell** — daran hängt bei `TWinControl` das Erzeugen des Fensters. Die Basisfassung würde ein Bedienelement ohne Fenster hinterlassen |
| Ribbon-Element einhängen | N | dxBar-Elemente haben keinen Parent: `TdxBarManager.AddItem`, dann `TdxBar.ItemLinks.Add`. Der Manager kommt aus der Leiste (`TdxBar.BarManager`), sonst aus der Besitzerkette, zuletzt `dxBarManager1` |
| **Klonen** | N | `AmsCloneElement` — alle schreibbaren published properties über die RTTI. Ohne Ziel landet die Kopie beim Original, um 16 Punkte versetzt (sonst läge sie unsichtbar darauf) |
| Objekteigenschaften nur über Setzmethode | N | `Font`, `Glyph`, `Images` werden **nur** kopiert, wenn dahinter eine Methode steht — die macht `Assign`, also eine echte Kopie. Steht dort unmittelbar ein Feld (`SetProc` mit `$FF……`), wird ausgelassen: zwei Elemente mit derselben Schrift sind ein Absturz auf Raten. `nil` wird nie geschrieben — `Font := nil` ist kein Löschen |
| Ereignisse auf Wunsch mitkopieren | N | `ACopyEvents` überträgt das `TMethod` unverändert: der Klon ruft dieselbe Behandlung des Hosts, mit sich selbst als `Sender` |
| Kein Journal beim Klonen | N | `AmsRecordChanges` ist währenddessen aus. Ein neues Element hat keinen Zustand, der sich zurücknehmen ließe — und das Journal (512 Plätze) wäre nach einem Klon voll |
| Umhängen mit Rückweg | N | `AmsMoveElement` für ein Element **des Hosts**: alter Container und alte Lage werden mitgeschrieben und beim Entladen wiederhergestellt. Ribbon-Elemente sind ausgenommen — die hängen an Verknüpfungen des Hosts |
| **Nur Eigenes wird entfernt** | T | `AmsRemoveElement` prüft das Verzeichnis. Ein Element des Hosts wird von hier aus nie zerstört; die Prüfung ist im Unit-Test festgenagelt |
| Abräumen beim Entladen | N | `AmsFactoryRelease` — erst Klickbehandlung abklemmen, dann `TObject.Free` (Delphi-Heap!). Zeigt der Zeiger nicht mehr auf dasselbe Element, wird nichts angefasst. `TAmsPlugin.Unload` ruft es **vor** `AmsUiRelease`, die `finalization` der Unit ebenfalls |
| Fällt das Freigeben aus, wird versteckt | N | Der Destruktor läuft in `try/except`; scheitert er, bleibt das Element unsichtbar zurück statt als toter Knopf |

### Suchen im laufenden AMS

| Feature | Stufe | Detail |
|---|---|---|
| **Suchfenster im Host** | T · N | `samples\UiTweaks`, Schaltfläche „Elemente suchen": Suchbegriff eingeben, Treffer anklicken, Eigenschaft anklicken — unten steht die fertige Patchzeile. Damit entfällt das Raten von Namen vollständig |
| Ein Feld für alles | N | Der Suchbegriff wird gegen Name, Beschriftung **und** Klasse geprüft, als Teiltreffer; mit `*`/`?` als Muster. Ein Fensterhandle (`0x00650E98`) wird als solches erkannt und direkt aufgelöst |
| Patchzeile mit aktuellem Wert | N | Der bestehende Wert ist die beste Vorlage — er hat garantiert das richtige Format, ob Zahl, Aufzählung oder Menge |
| „Zeigen" | N | Blinkt das gewählte Element im AMS-Fenster an und schreibt gleichzeitig alle Einzelheiten ins Log — die Antwort auf „ist das überhaupt das richtige". Doppelklick auf den Treffer tut dasselbe. Das Suchfenster geht dafür kurz nach hinten |
| Sofort ausprobieren | N | „Anwenden" führt die Zeile aus und liest die Werte neu ein, „Zurücknehmen" macht alles rückgängig, „Kopieren" legt sie in die Zwischenablage |
| **Bauen im selben Fenster** | T · N | Eine Zeile darüber: „Merken" nimmt den Treffer als Vorlage, „Klonen" setzt eine Kopie in den gerade gewählten Container (ohne Vorlage: neben das Original), „Neu" legt ein Element der eingetragenen Klasse an, „Entfernen" nimmt Eigenes zurück. Der Haken „mit Ereignissen" entscheidet, ob der Klon auch tut, was das Original tut |
| Ziel ist die Auswahl | N | Ist der gewählte Treffer kein Container, ist er als „dorthin, wo der sitzt" gemeint — dann wird sein Container genommen (`AmsParentOf` über `GetParent` des Fensters). Geht das nicht (gezeichnete Elemente, Ribbon), sagt die Statuszeile, was auszuwählen ist |
| Ergebnis steht sofort in der Liste | N | Das neue Element wird hinten angehängt und ausgewählt — man steht danach auf seinen Eigenschaften und kann es über die Patchzeile weiterstellen |
| Reines Win32 | T | Kein VCL-Kontakt: `CreateWindowExW` mit `EDIT`/`BUTTON`/`LISTBOX`/`STATIC`, modeless in der Nachrichtenschleife des Hosts. Ein modaler Dialog würde AMS anhalten |
| Fenster verschwindet beim Entladen | T | `BeforeUnload` ruft `FinderClose` (`DestroyWindow` + `UnregisterClass`). Die Fensterprozedur liegt im Plugin-Modul — ein stehengebliebenes Fenster wäre nach dem Entladen tödlich |

---

### Ohne eine Zeile Pascal

| Feature | Stufe | Detail |
|---|---|---|
| Patchzeilen aus der `plugin.ini` | T · N | `[Patch]` mit `Element.Eigenschaft=Wert`. Getrennt wird am **ersten** Punkt, alles danach ist Eigenschaftspfad: `bbNeu.Font.Style=[fsBold]` |
| Element per Name **oder** Beschriftung | N | Mit Platzhaltern: `bb*.Enabled=0` |
| Alle Zeilen in einem Suchlauf | N | `AmsApplyPatches` sucht **einmal** und wendet dann alle Zeilen an — zwanzig Zeilen wären sonst zwanzig Durchläufe über den Komponentenbaum |
| Auf der Basisklasse | N | `ApplyPatchesFromIni('Patch')`, dazu `FindElement` · `SetElement` · `EnableElement` · `ShowElement` · `RenameElement` · `UndoUiChanges` · `DumpElement(s)` |

---

## 4. Automatismen, Actions und Events

| Feature | Stufe | Detail |
|---|---|---|
| **Automatismus im aktuellen Kontext starten** | A | Der Weg, der wirklich funktioniert: `rpmAutomatismen` suchen → `ItemLinks` durchlaufen → `Caption` vergleichen → `TdxBarItem.DirectClick`. Derselbe Codepfad wie beim Mausklick, derselbe Kontext |
| Verfügbare Automatismen auflisten | A | `AmsListAutomatismen` — beantwortet „geht nicht“ meist sofort: es ist kein Kunde/Vertrag/Vorgang offen |
| Beides in einem Durchgang | N | `RunAutomatismusEx(Name, Liste)` — startet und liefert bei Misserfolg die im Kontext angebotenen zurück, ohne zweimal zu suchen |
| Menüname frei wählbar | N | Falls eine Installation das Menü anders benennt |
| `&` in Beschriftungen ignoriert | A | Delphi-Menücaptions tragen Tastenkürzel |
| Benannte `TafnAction` ausführen | A | Über `TafnActionManager` — derselbe Weg, über den sich ELO und DocuWare einklinken |
| Benanntes `TafnEvent` feuern | A | Über `TafnEventManager`, mit Options-Set |
| Beliebige dxBar-Menüpunkte klicken | N | `AmsClickMenuEntry` — nicht auf Automatismen beschränkt |
| Menüs auslesen ohne zu klicken | N | `AmsCollectMenuEntries` liefert Item, Caption, Index, Menü und Menüname |
| WorkflowEngine (Zweitweg) | A | `AmsRunWorkflowTask`. Findet **nur AutoStart**-Automatismen — ausdrücklich nicht der Standardweg |

---

## 4a. Aufzeichnen, was AMS tut

Die Frage, mit der jede Arbeit an einem fremden Programm anfängt: *was
passiert, wenn ich hier klicke?* `AmsApi.Hook` fängt die Aufrufe ab,
`AmsApi.Trace` schreibt die Zeitachse, `AmsApi.Recorder` verbindet beides.

### Abfangen (`AmsApi.Hook`)

Drei Verfahren, absteigend nach Sicherheit - immer das oberste nehmen, das
für den Fall reicht.

| Feature | Stufe | Detail |
|---|---|---|
| Importtabelle umbiegen | T | `AmsHookImport` / `AmsHookImportEverywhere`. EIN ausgerichteter Zeigerschreibvorgang, also atomar, und es wird kein Code verändert. Im Unit-Test an `kernel32!GetTickCount` durchgefahren: hooken, Aufruf fängt sich, zurücknehmen |
| VMT-Slot umbiegen | T | `AmsHookVmt`. Ebenfalls ein einzelner Zeiger. Nur virtuelle Methoden, wirkt auf die Klasse samt Erben |
| **Code-Detour mit Trampolin** | T | `AmsHookCode`. Die ersten Bytes werden durch `E9 rel32` ersetzt, das Original wandert in ein Trampolin, über das der Detour weiterrufen kann. Der einzige Weg zu statischen Funktionen - im Unit-Test an einer eigenen Funktion belegt: Detour läuft, Trampolin liefert das Original, Rücknahme stellt her |
| Längendekoder, der **nicht rät** | T | 25 Prüfungen. Was er nicht kennt, liefert 0, und dann wird nicht gepatcht, sondern die Bytes landen im Log. Eine halb kopierte Anweisung wäre ein Absturz mit Ansage |
| Relative Sprünge werden nie kopiert | T | `E8`/`E9`/`Jcc` zeigen nach dem Umkopieren woanders hin. Steht am Anfang ein Sprung, ist es ein Thunk - `AmsResolveThunk` folgt ihm bis zur echten Funktion |
| Threads anhalten während des Patchens | N | Ein 5-Byte-Patch ist nicht atomar. Alle anderen Threads werden angehalten und ihr EIP geprüft; steht einer im Patchbereich, wird der Hook abgelehnt statt gewürfelt |
| Eigener Sprung wird erkannt | T | Nach dem Patchen fängt die Zielfunktion mit `E9` an - "auflösen" landete sonst beim eigenen Detour, und ein zweiter Hook würde den Detour patchen statt abzulehnen |
| Fremde Patches bleiben stehen | N | Steht an der Stelle nicht mehr unser Sprung, wird nicht zurückgeschrieben. Zurückschreiben wäre schlimmer als Stehenlassen |
| Trampolin wird nie freigegeben | N | Ein Thread, der beim Lösen gerade hineinspringt, wäre sonst tot. Ein paar Seiten sind der Preis |
| Rücknahme beim Entladen | T | `AmsHookReleaseAll`, zusätzlich als Notbremse in der `finalization`. Ein Detour ins entladene Modul ist ein **sicherer** Absturz, nicht nur ein möglicher |
| ToolHelp selbst deklariert | T | FPCs Windows-Unit kennt es nicht, und `jwatlhelp32` zöge das ganze JEDI-Paket herein. Fünf Funktionen, zwei Records |

### Zeitachse (`AmsApi.Trace`)

| Feature | Stufe | Detail |
|---|---|---|
| **Verschachtelung statt flacher Liste** | T | `AmsTraceEnter`/`AmsTraceLeave` klammern einen Vorgang, alles dazwischen hängt darunter. Genau das beantwortet "welcher Klick löst dieses SQL aus" |
| Je Thread ein eigener Stapel | N | AMS arbeitet mehrthreadig; ein gemeinsamer Stapel würde die Zuordnung vertauschen |
| Vergessenes `Leave` verdirbt nichts | T | Es wird der passende Eintrag gesucht, nicht blind der oberste genommen |
| Dauer in Millisekunden mit Nachkomma | T | Über `QueryPerformanceCounter`; bei SQL stände sonst ueberall 0 |
| TSV, sofort geschrieben | T | Eine Zeile je Ereignis, ohne Zwischenpuffer im Prozess: stürzt AMS ab, ist die letzte Zeile die interessante. Öffnet sich unverändert in Excel |
| **Sammeln und Aufzeichnen getrennt** | T | `AmsTraceBegin` füllt nur den Ringpuffer — das reicht zum Zusehen und kostet keine Datei. `AmsTraceRecordTo` schaltet die Datei jederzeit zu und wieder ab, ohne das Sammeln zu unterbrechen |
| Zwei Formen derselben Zeile | T | Die Datei bekommt TSV mit allen Spalten (in Excel filter- und sortierbar), das Fenster eine eingerückte Zeile zum Lesen. Die TSV-Zeile wird nur gebaut, wenn wirklich eine Datei offen ist |
| Kategorien einzeln abschaltbar | T | `Plugin` / `Ui` / `Action` / `Event` / `SQL` / `Automat` / `Host` |
| Mehrzeiliges SQL wird einzeilig | T | Tabulator und Umbruch würden die Spalten zerlegen; `AmsTraceClean` fasst zusammen und kürzt |
| Zusammenfassung | T | `AmsTraceReport` - je Betreff Anzahl, Summe und Maximum, nach Gesamtdauer sortiert. Die Antwort auf "was kostet dieser Klick" |
| Ringpuffer im Speicher | N | `AmsTraceTail` für ein Diagnosefenster, ohne die Datei zu lesen |

### Verlaufsfenster (`AmsApi.TraceWindow`)

Zusehen ist der Normalfall, Aufzeichnen die Ausnahme — wer wissen will, was
ein Klick auslöst, will das mitlaufen sehen und braucht dafür keine Datei.

| Feature | Stufe | Detail |
|---|---|---|
| **Zusehen ohne Aufzeichnen** | T | Das Fenster liest aus dem Ringpuffer im Speicher. Es entsteht keine Datei, solange niemand eine verlangt — eine ungefragt angelegte Datei wäre nur Müll im Temp-Ordner |
| Aufzeichnen als Schalter | T | »Aufzeichnen« schaltet die TSV-Datei zu und wieder ab, ohne das Zusehen zu unterbrechen. Der Ringpuffer läuft durch |
| **Der Betrachter holt ab, niemand ruft herein** | T | Geschrieben wird aus jedem Thread des Hosts, auch aus dem Datenbankthread; an einem Fenster darf nur dessen eigener Thread arbeiten. Ein Timer im Fensterthread fragt `AmsTraceSince` — damit ist das Thema erledigt, ohne eine einzige Sperre und ohne `PostMessage` |
| Cursor statt Zeitstempel | T | Jede Zeile trägt eine fortlaufende Nummer; der Betrachter merkt sich, wo er war. Läuft der Ringpuffer über, wird der Cursor nachgezogen statt Zeilen doppelt zu zeigen. Über mehrere Durchläufe geprüft: keine doppelt, keine verschluckt |
| Feste Schrittweite | T | Consolas; nur so stehen Zeit, Einrückung und Dauer untereinander, und erst dadurch ist die Verschachtelung überhaupt zu sehen |
| Mitlaufen, ohne zu bevormunden | N | Die letzte Zeile bleibt sichtbar (`LB_SETTOPINDEX`, keine Auswahl — die gehört dem Anwender). Wer selbst zurückblättert, wird nicht ans Ende gerissen |
| Anhalten | T | Friert die Anzeige ein, das Sammeln läuft weiter. »Weiter« zieht alles nach — beim Lesen einer Zeile soll nicht alles weiterrutschen |
| Kategorien im Fenster | T | Klicks / Actions / SQL einzeln an und aus, während es läuft |
| Bericht auf Knopfdruck | T | `AmsTraceReport` in dieselbe Liste: was wie oft, wie lange, Maximum |
| Kopieren | T | Der sichtbare Verlauf als `CF_UNICODETEXT` in die Zwischenablage |
| Listenfeld gedeckelt | N | Höchstens 3000 Zeilen, davor wird vorn gelöscht. Ein Listenfeld mit 100000 Einträgen malt sich zu Tode |
| Kein Flimmern | N | `WM_SETREDRAW` um den ganzen Block, nicht je Zeile |
| Modeless | T | Ein modaler Dialog würde AMS anhalten — und dann gäbe es nichts mehr zuzusehen |
| Fenster und Klasse verschwinden | T | `AmsTraceWindowClose` zerstört das Fenster, gibt die Schrift frei und meldet die Fensterklasse ab; zusätzlich als Notbremse in der `finalization`. Die Fensterprozedur liegt im Plugin-Modul — ein stehengebliebenes Fenster wäre nach dem Entladen tödlich. Im Rauchtest wird mit `GetClassInfo` nachgesehen |
| Mindestgröße | T | `WM_GETMINMAXINFO`; darunter überdecken sich Liste und Statuszeile |

### Quellen (`AmsApi.Recorder`)

| Feature | Stufe | Detail |
|---|---|---|
| **SQL mitschreiben** | A | Detours auf `isc_dsql_prepare`, `isc_dsql_execute` und `isc_dsql_execute_immediate` in `fbclient.dll`. **Im echten AMS des Anwenders gelaufen** (31.08.2026): 3 von 3 Funktionen gehookt, 395 Zeilen echtes Firebird-SQL mit Dauer und Anweisungshandle |
| Warum dort und nicht bei UniDAC | - | AMS spricht Firebird über UniDAC (`ASSFINETWIN.ini`: `DbType=Firebird`, `VendorLib=fbclient.dll`). `TUniSQLMonitor` bräuchte einen Delphi-Konstruktor, ein Ereignis mit drei Parametern und die Annahme, dass er ohne Debug-Flag überhaupt feuert; `TCustomDASQL.Execute` gäbe den Komponentennamen, aber der SQL-Text hängt an nicht-published properties. `fbclient` ist der Flaschenhals ganz unten: reine C-Funktionen, der Text ein schlichter `char*` |
| Aufrufkonvention belegt, nicht geraten | T | `isc_dsql_execute_immediate` endet auf `ret 1Ch` = 28 Byte = 7 Argumente, `isc_dsql_execute` auf `ret 14h` = 5. Beides passt genau zur dokumentierten Signatur, also **stdcall** |
| Kein IAT-Weg für fbclient | T | UniDAC lädt die DLL über `VendorLib=` nach; es gibt daher keinen Importeintrag, der sich umbiegen ließe. Es bleibt der Detour |
| Vorbereitete Anweisungen zugeordnet | N | Ein `prepare` wird einmal übersetzt und tausendfach ausgeführt. Ohne die Zuordnung Handle zu SQL stünde bei jedem `execute` nur eine Nummer. Ringpuffer mit 256 Plätzen |
| Lesbarer Betreff je Anweisung | T | `AmsSqlSubject`: aus `select id, name from kunde where ...` wird `SELECT KUNDE`. Damit zählt der Bericht Gleichartiges zusammen. 9 Prüfungen |
| **Keine Parameterwerte** | - | Aufgezeichnet wird der SQL-TEXT, nicht der Inhalt der Parameter. Das ist Absicht: Parameter sind Kundendaten |
| Nachstart nach der Anmeldung | N | `fbclient.dll` liegt erst im Prozess, wenn ein Mandant offen ist. Vorher meldet der Start das im Klartext, statt zu scheitern; das Beispiel zieht in `SessionChanged` nach |
| **Actions und Events mitschreiben** | N | Detours auf `TafnAction.Execute` und `TafnEvent.Fire` - dieselben Symbole, die die API ohnehin bindet. Hier läuft praktisch alles vorbei, was AMS fachlich tut. **Im echten AMS mit einer Access violation abgebrochen**, Ursache noch offen - siehe Abschnitt 9. Escape: `Actions=0` in der `plugin.ini`, dann wird gar nicht erst gepatcht |
| **Jeden Klick mitschreiben** | A | Über `AmsHookEvent`, also ohne jeden Codepatch: das published `OnClick` wird umgesetzt und beim Entladen zurückgetragen. Nur belegte Ereignisse - ein leeres zu übernehmen hieße, dem Element ein Verhalten zu geben, das es vorher nicht hatte |
| Beobachter in `AmsApi.Ui` | T | `AmsEventWatcher` wird vor und nach der ursprünglichen Behandlung gerufen und trägt ein Token zwischen beiden Aufrufen. Damit legt der Rekorder eine Klammer mit Dauer um fremde Ereignisse, ohne dass `AmsApi.Ui` etwas von ihm wissen muss. Das `finally` sorgt dafür, dass die Klammer auch bei einer Exception des Hosts zugeht |
| Alles in einem Aufruf | N | `AmsRecordStartAll` / `AmsRecordStopAll`. Eine fehlende Quelle ist kein Grund, die anderen nicht aufzuzeichnen |
| Abbau in der richtigen Reihenfolge | T | Erst die Quellen abklemmen, dann die Senke schließen - sonst schreibt ein noch laufender Detour in eine geschlossene Datei |
| Ohne AMS: sauberes Nein | T | 10 Prüfungen. Kein `fbclient` gibt eine Klartextmeldung, fehlende Host-Symbole geben False, `StopAll` ohne `Start` ist harmlos - und danach ist kein einziger Hook zurückgeblieben |

---

## 5. Zugriff auf den Host

| Feature | Stufe | Detail |
|---|---|---|
| **Versionsunabhängiges Binden** | T · N | Package-Suffix wird zur Laufzeit über ToolHelp aus `rtl<NNN>.bpl` gelesen; Fallback-Tabelle XE5 … 12 Athens. Im Testlauf: `Suffix "230" erkannt (10 Seattle)` |
| Gruppenweise, lazy, idempotent | T | Core · Vcl · Bars · Afn · Workflow einzeln. Wer nur HTTP will, scheitert nicht an fehlendem `afnBu.bpl` |
| Bindebericht | T | `AmsBindReport` — eine Tabelle fürs Log oder ein Diagnosefenster |
| 40 Host-Symbole gebunden | T | `tools\checksyms.py` prüft jeden mangled Namen gegen die installierten BPLs: **40/40** |
| Klassenname aus dem VMT | A | `AmsClassName`, Offset −56 |
| Komponentenname ohne Allokation | A | `AmsName` liest `TComponent.FName` direkt bei +8, mit Plausibilitätsprüfung |
| published properties lesen/schreiben | A | String, Ordinal, Objekt, Methode — inklusive der `GetStrProp`-Konvention (ECX = `@Result`), die zwei Runden gekostet hat |
| Methodenproperty löschen | N | `AmsClearMethod` — die Voraussetzung für sicheres Entladen |
| Virtuelle Methode über VMT-Slot | A | `AmsVmtSlot`, nötig für `TGraphic.LoadFromFile` ($54) |
| Interface → Objektzeiger | A | `AmsObjFromIntf` probiert Kandidaten und **validiert über den Klassennamen**, statt blind $30 zu rechnen |
| Fensterbaum und Komponentenbaum | A | `AmsFindMainWindow` · `AmsControlOf` · `AmsDumpWindowTree` · `AmsDumpComponents` |
| Wurzelliste über alle Fenster | A | Findet Komponenten auf Frames, die nicht dem Hauptformular gehören. **Ein** `EnumChildWindows` je Top-Level — der quadratische Fall kostete 60 Sekunden |
| Suche nach Namen | A · N | `AmsFindComponent` (direkt) · `AmsFindComponentDeep` (rekursiv) · `AmsFindAnywhere` (prozessweit) · `AmsCollectByName` |
| **Delphi-Strings ohne Heap-Absturz** | A · T | `UnicodeString` mit RefCount −1 — Delphi fasst ihn nie an. Cache für wiederholte Propertynamen, Freigabe beim Entladen. Aufbau im Unit-Test byteweise geprüft |
| Host-Strings zurücklesen und freigeben | A | `AmsFromHostStr` · `AmsClearHostStr` (über `UStrClr` des Hosts, nicht über FPC) |

---

## 6. Ohne AMS nutzbar

Diese vier Units haben keine Berührung mit der Delphi-Seite — kein ABI, kein
Heap-Thema, vollständig ohne AMS testbar.

| Feature | Stufe | Detail |
|---|---|---|
| HTTP/HTTPS über WinHTTP | A · T | Teil von Windows: keine zusätzliche DLL, kein OpenSSL, TLS inklusive |
| Synchron und im Hintergrund | A · N | `AmsHttpRequest` blockiert; `AmsHttpRequestAsync` läuft im Thread und meldet über Callback zurück |
| Beliebige Methode, Header, Body | A | Header mit `\|` getrennt, weil eine INI kein CRLF kann. Body als UTF-8 |
| HTTPS am Schema erkannt | A | `nScheme`, nicht am Port — sonst bricht `https://host:8443` |
| User-Agent und Timeout einstellbar | N | `AmsHttpUserAgent` · `AmsHttpTimeoutMs` |
| Browser öffnen | A | `AmsOpenUrl` |
| INI-Parser, der Leerzeichen verträgt | A · T | Nicht `TStrings.Values`: das vergleicht Schlüssel buchstäblich, `  Url = x` liefert still den Default |
| Abschnitte, Kommentare, Typen | T | `[Abschnitt]`, `;` und `#`, case-insensitiv, erste Fundstelle gewinnt, `AmsIniInt` / `AmsIniBool` / `AmsIniSection` |
| Pfade ab dem Plugin-Ordner | A · T | Absolut bleibt absolut, `./` fällt weg, `/` wird normalisiert — **nicht** relativ zum Arbeitsverzeichnis von AMS |
| Threadsicheres Logging | A · T | Kritischer Abschnitt, Ringpuffer im Speicher, Datei unter `%TEMP%\<Modulname>.log` |
| Log pro Plugin getrennt, rollend | N | Name aus dem Modul, Wegrollen ab 2 MB, abschaltbar |
| PNG → 32-Bit-BMP | A · T | Mit Alphakanal. Pixelwerte im Unit-Test geprüft |

---

## 7. Robustheit

Die Sicherheitsnetze sind kein Beiwerk — an genau diesen Stellen ist der
Prototyp bzw. das `ScriptScheduler`-Plugin des Herstellers gescheitert.

| Feature | Stufe | Detail |
|---|---|---|
| Keine MessageBox aus der Bibliothek | N | Funktionen liefern `Boolean`, Ursache in `AmsLastError` und im Log. Ob daraus ein Dialog wird, entscheidet das Plugin |
| Fehlende Symbole sind kein Absturz | T | `False` mit Klartext. Im `hosttest` ohne die afn-Packages nachgestellt: „Ribbon: vcl-Symbole fehlen“ statt Crash |
| Jeder Host-Aufruf in `try/except` | A | Delphi-Exceptions kommen als `EEDFADE` über die Grenze und sind nicht typisiert auswertbar |
| Klassenfilter vor `ItemLinks` | A | `GetObjectProp('ItemLinks')` auf einem VCL-`TPopupMenu` wirft — das hat `Items` |
| Plausibilitätsgrenzen | A | Komponentenzahlen, Namenslängen, Rekursionstiefen, Listenobergrenzen — ein falsch gedeuteter Zeiger führt nicht in eine Endlosschleife |
| Keine managed Typen über die Grenze | A | Nur Zeiger, Integer, Boolean |
| Kein Timer-Neustart nach `Unload` | N | Der Host schickt durchaus noch `DoCommand`, während das Modul abgebaut wird |
| Verschachtelte Wurzelsuche abgefangen | N | Die Enum-Callbacks arbeiten über eine Globale; ein Zweitaufruf wird abgewiesen statt zu korrumpieren |

---

## 8. Entwicklung und Test

| Werkzeug | Stufe | Zweck |
|---|---|---|
| `build.cmd` | T | Bibliothek übersetzen, Tests laufen lassen, alle Beispiele bauen und ausliefern. `build.cmd <Name>` für eines |
| `tests\compileall.lpr` | T | Übersetzt jede Unit — auch die, die gerade kein Plugin benutzt |
| `tests\unittests.lpr` | T | **230 Prüfungen ohne AMS**: INI, Pfade, Delphi-StrRec, PNG→BMP32, Platzhaltervergleich, Farbwerte, Patchzeilen, Binder-Verhalten ohne Host — und dass der ganze Elementzugriff ohne Host sauber nichts liefert statt abzustürzen. Dazu der komplette Hook-Mechanismus - Laengendekoder, Detour an einer eigenen Funktion, VMT-Slot, Importtabelle - und die Zeitachse samt Verschachtelung |
| `tests\hosttest.lpr` | T | Lädt ein BPL über den echten Weg: `rtl!Initialize` → `LoadPackage` → `PluginInit` → Lifecycle → `Unload` → `UnloadPackage`. Offscreen-Senke als Hauptfenster-Ersatz. Findet Lade-, Export- und Init-Fehler **ohne AMS zu starten** |
| `tests\tracewindemo.lpr` | T | **60 Prüfungen des Verlaufsfensters ohne AMS**: öffnen, mit erfundenen Zeilen füttern, über Nachrichten bedienen (aufzeichnen an/aus, anhalten/weiter, Kategorien, leeren, Bericht, kopieren), in vier Breiten umbrechen, schließen, Fensterklasse abmelden. Geprüft wird dabei vor allem, dass **Zusehen ohne Aufzeichnen** geht und der Cursor keine Zeile doppelt zeigt und keine verschluckt |
| `tests\finderdemo.lpr` | T | **39 Prüfungen des Suchfensters ohne AMS**: erzeugen, in fünf Größen umbrechen (auch unter der Mindestgröße), über Nachrichten bedienen — suchen, ungültiges Handle, Auswahl in leeren Listen, kaputte Patchzeile, zurücknehmen, kopieren, zeigen —, den XOR-Rahmen außerhalb des sichtbaren Bereichs zeichnen (auch mit leerem und winzigem Rechteck), schließen, Fensterklasse abmelden, doppelt schließen. Geprüft wird dabei auch, dass sich **keine zwei Bedienelemente überdecken** — bei 700, 980 und 1400 px. Das Fenster bleibt versteckt und außerhalb des Bildes |
| `tests\rttiprobe.lpr` | T | **21 Prüfungen der RTTI-Offsets** gegen `rtl230.bpl`/`vcl230.bpl`: `TComponent` und `TFont` werden aus den echten Packages gelesen. Braucht AMS nur installiert, nicht laufend; ohne Installation überspringt sich das Programm selbst |
| `tools\checksyms.py` | T | Jeden gebundenen mangled Namen gegen die Installation prüfen — erster Schritt bei einer neuen AMS-Version. Stand: **40/40** |
| `tools\exports.py` | T | Exportnamen aus BPL/DLL. Eigener PE-Parser, weil `pefile` bei großen Tabellen abschneidet (`afnBu.bpl`: ~34800 Symbole) |
| `tools\mkicon.py` | T | Platzhalter-PNG erzeugen, nur Standardbibliothek |
| `docs\HOST-ABI.md` | — | Der komplette Host-Vertrag: Ladevorgang, `IPlugin`, Konventionen, Symboltabelle, 12 Fallstricke |
| Acht Beispiel-Plugins | T | `HelloButton` (Minimalfall) · `WebHook` (Hintergrundthread → UI-Thread) · `RunAutomatismus` (Kontext-Automatismus mit brauchbarer Fehlermeldung) · `UiTweaks` (**Suchfenster im laufenden AMS**: suchen, patchen und **bauen** — merken, klonen, neu anlegen, wieder entfernen; dazu Patches aus der INI und `OnClick` übernehmen) · `Recorder` (**Verlaufsfenster im laufenden AMS**: zusehen, was der Host tut — Klicks, Actions, SQL mit Dauer und Verschachtelung; Aufzeichnen ist ein Schalter darin) · `Doom` (**DOOM im laufenden AMS**) · `GdvTrace` (GDV-Import mitschneiden) · `PluginManager` (**Plugins aus Katalogen installieren, aktualisieren, einstellen**) |

---

## 9. Bildpuffer-Fenster, WAD und DOOM-Engine

Was der Host für ein eigenes Bild nicht mitbringt, kommt dazu — als
wiederverwendbare Units, nicht als Einzweck-Code im Beispiel. Der ganze Zweig
braucht **keinen** Host und ist deshalb ohne AMS geprüft (`build\doomdemo.exe`);
das fertige BPL lädt zusätzlich sauber über den echten `LoadPackage`-Pfad
(`hosttest`).

| Feature | Stufe | Detail |
|---|---|---|
| Bildpuffer-Fenster (`AmsApi.GameWindow`) | T · N | Rohes Win32-Fenster mit 32-Bit-DIBSection (top-down BGRA), Ausgabe per `StretchDIBits`, ganzzahlig skaliert mit 4:3-Rand. Derselbe VCL-freie Weg wie `finder.inc` |
| Bildschleife im Host-Message-Loop | T · N | `SetTimer` treibt Rechnen + Ausgeben, modeless — die Nachrichtenschleife bleibt die von AMS. Bildratenunabhängig über gemessene ms |
| Tastatur ohne Fokusklau | T · N | Zustandstabelle **und** Kanten-Warteschlange, nur bei Fokus; bei Fokusverlust werden alle Tasten losgelassen |
| Sauberes Entladen | T · N | `Free` ruft `KillTimer`, `DestroyWindow`, `DeleteObject`, `UnregisterClass`. Instanz hängt in `GWL_USERDATA`, nicht an einer globalen — mehrere Fenster möglich |
| DOOM-WAD lesen (`AmsApi.Wad`) | T | Header, Lump-Verzeichnis, Namenssuche, `PLAYPAL`, Flats (64×64), `patch_t`-Bilder mit Transparenz, `TEXTURE1`/`PNAMES`-Komposit. **Jeder** Zugriff bereichsgeprüft — ein kaputtes WAD liefert `False`, nie einen Absturz. Gegen ein erzeugtes IWAD geprüft |
| **Echter DOOM-Kern** (`AmsApi.DoomCore` + `doomcore.dll`) | T · N | Der echte DOOM (doomgeneric, GPLv2) als 32-Bit-DLL, per `LoadLibrary` geladen und über `dg_start`/`dg_tick`/`dg_framebuffer`/`dg_key` getrieben. **Echte Level** (E1M1 …), Gegner, Waffen, volle Spiellogik, echte BSP-Grafik. Offscreen gegen `freedoom1.wad` gerendert (256000/256000 Pixel), außerdem über die echten Plugin-Units (`AmsApi.DoomCore`+`AmsApi.GameWindow`) end-to-end |
| Sicher eingebettet | T · N | Ein fataler `I_Error` würde sonst per `exit()` **AMS mitreißen**. Minimaler Patch in `i_system.c`: `longjmp` zurück in die Shim, `dg_start`/`dg_tick` liefern dann `False`, der Host lebt weiter |
| **Sound** (`native/dg_sound.c`) | N | doomgeneric ist ab Werk stumm (Sound nur hinter `FEATURE_SOUND` → SDL/Allegro). Eigenes Backend **ohne Fremd-DLL, nur über Windows-`winmm`**: **SFX** als Software-Mixer auf `waveOut` (DS*-Lumps werden auf `snd_samplerate` resampled + gecached, Feeder-Thread mischt 16 Kanäle mit Lautstärke/Panning), **Musik** per `mus2mid` → Temp-MIDI → MCI-Sequencer, Looping über `Poll()`. Registriert unter `DG_AMS_SOUND` als `DG_sound_module`/`DG_music_module` (nicht `FEATURE_SOUND`, das zieht SDL). Geräteausfall = Stille, nie Absturz. `dg_shutdown` stoppt Thread + Geräte **vor** `FreeLibrary` — Laden/Spielen/Entladen/Neuladen crashfrei geprüft |
| Ersatz-Engine (`AmsApi.DoomEngine`) | T | Wenn DLL oder WAD fehlen: DDA-Raycaster in purem Pascal — texturierter Boden/Decke, Sprite-Gegner mit Z-Puffer, Waffe, HUD, Nahkampf-KI, Schießen. Das Plugin startet **in jedem Fall** |
| Echte DOOM-Assets (Ersatz-Engine) | N | Mit einem WAD auch hier echte Palette/Texturen/Flats/Sprites; fehlt ein Lump, wird es über den nächsten Palettenindex erzeugt |
| Als echter AMS-Tab | A · T | DOOM öffnet als **eigener Reiter „DOOM"** neben „Startseite" — im laufenden AMS bestätigt. Eine `TcxTabSheet` wird per virtuellem `SetParent` an das Dokument-Page-Control `TafncxPageControl` (`SessionPageControl`) gehängt; Schließen/`Y` entfernt den Reiter. `[Doom] Container=<Name>` bzw. `Mode=window` sind die Alternativen |
| Tastatur bleibt beim Spiel | A · T | Der Host frisst Tastennachrichten (nur Alt-Kombis rutschen durch) und feuert eigene Kürzel (z.B. „Y" → Synchronisieren). Lösung: physisch pollen (`GetAsyncKeyState`) **und** solange die Fläche Fokus hat die Tastennachrichten per thread-lokalem `WH_GETMESSAGE`-Hook zu `WM_NULL` machen. Maus: links feuern, rechts benutzen |
| Spielstände & Beenden | A · T | Saves/Config nach `%APPDATA%\AmsDoom` (Programmordner ist schreibgeschützt). „Quit" darf den Host **nicht** per `exit(0)` mitreißen: `D_Endoom`/`I_Quit` entschärft, `M_QuitResponse` meldet nur „schließen". Reopen lädt die DLL frisch (Singleton) → neues Spiel |

---

## 10. Plugin Manager — Plugins verteilen, installieren, einstellen

Ein Ribbon-Knopf öffnet einen Plugin-Browser (`samples\PluginManager`). Alles
Können steckt in Units, die einzeln wiederverwendbar sind — ein anderes
Plugin kann etwa nur das Einstellungsfenster (`AmsApi.IniEditor`) oder nur den
Neustart (`AmsApi.Process`) benutzen. Geprüft ohne AMS
(`build\pluginmgrdemo.exe`, `build\browserdemo.exe`, `unittests`), dazu der
Ladepfad der fertigen BPL über `hosttest`. **Im laufenden AMS noch nicht
gegengeprüft** — daher überall höchstens T · N.

### Woher die Plugins kommen (`AmsApi.PluginStore`)

| Feature | Stufe | Detail |
|---|---|---|
| Katalog als INI | T | Ein Abschnitt je Plugin, Quelle als URL oder Pfad (auch `\\Server`), mehrere Kataloge, der erste gewinnt. Ordnername wird geprüft (`AmsIsSafeName`) |
| GitHub ohne API | T | `Repo=github:o/r` (auch `https://github.com/o/r`, `.git`, `/tree/<zweig>/<pfad>` aus dem Browser). Paket und Metadaten aus `releases/latest/download/<Name>.zip` bzw. `.ini`, README und Bilder roh aus dem Repo. **Kein API-Aufruf**, also kein Limit von 60/h je Adresse. Gegen echte öffentliche Repos geprüft (Weiterleitung auf den CDN-Host, README mit Bildern) |
| Private Repos | N | Mit Token: Release über die GitHub-API, Assets mit `Accept: application/octet-stream`, Rohdateien mit `Authorization`. Der Token geht **nur** an `github.com`, `api.github.com`, `raw.githubusercontent.com`; bei einer Weiterleitung auf einen anderen Host wird der Header entfernt. Token aus `[GitHub] Token=`, `TokenFile=` oder `AMS_GITHUB_TOKEN`. Ohne eigenes privates Repo noch nicht gegen GitHub gefahren |
| Monorepo | T | `Path=` für Repos mit mehreren Plugins (wie dieses); Asset-Namen je Plugin eindeutig |
| Ohne GitHub | T | `Base=` auf Webserver oder Ordner, relativ zum Katalog erlaubt. Flach (`build\release` unverändert kopiert) oder ein Ordner je Plugin; statt ZIP darf dort auch gleich der Plugin-Ordner liegen. End-to-End mit den echten Release-Assets aller acht Beispiele geprüft |
| Festnageln und prüfen | T | `Tag=` statt neuestem Release, `Sha256=` — falsche Prüfsumme verwirft das Paket |
| Metadaten | T | Kopf der `plugin.ini` (Name, Module, Version) plus Abschnitt `[Info]`: Title, Description (`\n` = Umbruch), Author, License, Homepage, Icon, Tags. AMS stört sich nicht an dem Abschnitt |
| Versionen | T | `1.2.10 > 1.2.9`, führendes `v`, Vorabversionen (`-beta.2`) wie SemVer |
| Zwischenspeicher | T | Kataloge, Metadaten und Bilder unter `%LOCALAPPDATA%\AmsPluginManager`; das Fenster zeigt sofort den letzten Stand und lädt im Hintergrund nach |

### Installieren (`AmsApi.PluginStore` + `AmsApi.PluginApply`)

| Feature | Stufe | Detail |
|---|---|---|
| Bereitstellen | T | Laden, SHA-256, entpacken mit **Zip-Slip-Schutz** (ganzes Archiv abgelehnt, bevor eine Datei geschrieben ist) und Größengrenze, `plugin.ini` prüfen (Name passt, Modul vorhanden) |
| **Einstellungen des Anwenders bleiben** | T | Beim Aktualisieren werden geänderte Werte und selbst ergänzte Schlüssel (eigene `[Patch]`-Zeilen) in die neue `plugin.ini` übernommen; Name, Module, Version und `[Info]` bestimmt das Paket |
| **Ersetzen, während AMS läuft** | T | Eine geladene BPL lässt sich nicht überschreiben, aber umbenennen. Sie wird als `.old` beiseite geschoben, die neue liegt sofort an ihrem Platz, AMS arbeitet bis zum Neustart mit der alten. Geprüft mit einer echt per `LoadLibraryEx` gemappten DLL. Reste räumt der nächste Lauf weg |
| Sicherung und Rücknahme | T | Vorher wird der Plugin-Ordner gesichert; scheitert ein Schritt, wird zurückgespielt. Dateien, die nur im Ziel liegen (eine WAD neben DOOM), bleiben stehen |
| Entfernen | A · T | **Ganz oder gar nicht.** Ein Ordner ohne `plugin.ini` in `BIN\plugins` bricht den Start von AMS ab („Plugin descriptor file not found for …“) — im echten AMS passiert, als die erste Fassung gesperrte BPLs als `.old` im Ordner liegen ließ. Jetzt wird alles in einen Papierkorb neben der Sicherung **verschoben** (geht auf demselben Laufwerk auch mit geladener BPL), der Ordner verschwindet. Geht eine Datei nicht, wird alles zurückgeschoben und abgelehnt („AMS beenden und erneut versuchen“). Solche Reste repariert jeder Lauf vorab (`AmsRepairPluginsDir`, von Hand: `AmsPluginApply.exe --repair <BIN\plugins>`) |
| **Rechte** | T · N | `BIN\plugins` ist für Benutzer schreibgeschützt. Ist der Ordner beschreibbar, läuft alles im Prozess; sonst startet `AmsPluginApply.exe` per UAC (`runas`) und arbeitet eine Warteschlange ab, AMS zeichnet währenddessen weiter. Helfer als Prozess geprüft, die UAC-Abfrage selbst nur im Code |
| **Falle: UAC-Virtualisierung** | T | Ein 32-Bit-Programm **ohne Manifest** schreibt scheinbar erfolgreich nach Program Files — in Wahrheit nach `%LOCALAPPDATA%\VirtualStore`. Der Helfer bringt deshalb ein `asInvoker`-Manifest mit (der Test prüft es), und `AmsCanWriteDir` schaltet die Virtualisierung vor der Probe ab. AMS selbst hat ein Manifest |

### Anzeigen und einstellen

| Feature | Stufe | Detail |
|---|---|---|
| Plugin-Liste | T | 32-px-Bilder (PNG skaliert, sonst Buchstabe auf Farbe), Version (`1.0.0 → 1.1.0`), Zustand: nicht installiert / installiert / Update / lokal / neuer als Katalog / Neustart nötig. Suche über Titel, Name, Beschreibung, Autor, Tags; Filter |
| **README aus dem Repo** | T | `AmsApi.Markdown` (GFM: Tabellen, Code, Listen, Aufgaben, Bilder, Roh-HTML) mit Kopfkarte (Bild, Titel, Autor, Lizenz, Versionen, Fehler der Quelle). Bilder werden vorab geholt und als `data:`-URI eingebettet — so gehen auch private Repos und Netzlaufwerke. `<script>`, `on*=`, `javascript:` werden entfernt, die Seite liegt per *Mark of the Web* in der Internetzone |
| Eingebetteter Browser | T | IE-WebBrowser über `atl.dll`, ohne VCL und ohne ComObj (eigenes IDispatch). Links gehen an den Standardbrowser. Fehlt der Browser, ein Textfeld. Solange er lebt, sind FPU-Ausnahmen des UI-Threads maskiert (MSHTML verträgt sie nicht) — danach wiederhergestellt |
| **Einstellungsfenster** | T | Jede `plugin.ini`: Liste aller Schlüssel, Beschreibung aus dem Kommentar über dem Schlüssel, Wert ändern (Enter), Textmodus, neu laden. Gespeichert wird nur der Wert — Kommentare, Reihenfolge, Schreibweise und BOM bleiben; ANSI bleibt ANSI. Was das Paket bestimmt, ist gesperrt. Speichern unter Program Files über denselben UAC-Helfer |
| **Neustart-Dialog** | T · N | Nach Installieren, Aktualisieren, Entfernen und Speichern: „Jetzt neu starten“ / „Später“ (TaskDialog, sonst MessageBox). „Jetzt“ startet einen Wartehelfer (ohne erhöhte Rechte), schickt AMS `WM_CLOSE` — AMS fragt wie gewohnt nach — und startet es mit derselben Befehlszeile neu. Bricht der Anwender das Beenden ab, gibt der Helfer nach 3 Minuten auf. Wartehelfer als Prozess geprüft, das Beenden von AMS selbst nicht |
| Release-Assets | T | `build.cmd` legt je Beispiel `build\release\<Name>.zip` + `.ini` und `SHA256SUMS.txt` an (`tools\mkrelease.lpr`, mit `AmsApi.Zip` gepackt). Was im Deploy-Ordner nur zufällig liegt (WAD, Logs, `.old`), kommt nicht hinein |

> **Falle für alle UI-Units mit Umlauten:** In einer Unit mit `{$codepage
> utf8}` ist `#$89` ein *Unicode-Zeichen* und wird als zwei UTF-8-Bytes
> abgelegt. Ein Bytevergleich wie `Copy(Daten, 1, 4) = #$89'PNG'` geht dann
> still daneben. Byte-Logik gehört deshalb in Units ohne diese Direktive
> (`AmsSniffImageMime` in `AmsApi.Files`).

---

## 11. Was (noch) nicht drin ist

| Punkt | Warum |
|---|---|
| **Action-Detour stürzt im echten AMS ab** | Der Hook auf `TafnAction.Execute` warf beim ersten Lauf eine Access violation - und zwar bevor `AmsHookCode` überhaupt zu seiner ersten Logzeile kam. Der Prolog ist unverdächtig (`55 8b ec 83 c4 f4`, sauber dekodierbar), der Verdacht liegt auf dem Zusammenspiel mit den kurz zuvor gesetzten SQL-Detours: ab da läuft ständig ein fremder AMS-Thread durch unseren Code, und das Einfrieren aller Threads traf ihn mitten darin. Zwei Ursachen sind deshalb schon beseitigt (kein Heap und kein Log mehr im eingefrorenen Zustand), der Beweis steht aber aus. Bis dahin ist SQL+Klicks der belegte Umfang |
| Plugin Manager im echten AMS | Alles ohne AMS geprüft; der erste Lauf im laufenden AMS steht aus — insbesondere UAC-Abfrage aus AMS heraus, `WM_CLOSE` an das Hauptfenster beim Neustart und das Laden einer beiseite geschobenen BPL |
| GitLab/Gitea als Kurzform | Nur `github:` hat Vorlagen. Andere Hosts gehen über `Base=` oder einzelne `Package=`/`Meta=`/`Readme=`-Adressen |
| Proxy mit Anmeldung | WinHTTP nimmt den Proxy des Systems (auch PAC), meldet sich aber nicht selbst an. Verlangt der Proxy NTLM (`407`), scheitert der Abruf mit Klartext |
| Code-Signatur der Pakete | Geprüft wird nur, was der Katalog verlangt (`Sha256=`). Wer den Katalog schreiben kann, bestimmt, was installiert wird — ihn also dort ablegen, wo nur Admins schreiben |
| Terminalserver | Läuft AMS in anderen Sitzungen, sind dort die BPLs geladen; sie werden ebenfalls beiseite geschoben und greifen dort erst beim nächsten Start |
| Tab-Taste in eigenen Fenstern | Die Nachrichtenschleife gehört AMS und ruft für fremde Fenster kein `IsDialogMessage`. Maus und Enter gehen |
| Regressionsprobe im echten AMS | Steht aus. `AmsToolbox` auf die neue API umstellen und die A-Punkte nachfahren |
| Kontextfreier Automatismus-Start | Bräuchte `TAutomatismus` per Delphi-Konstruktor (EAX=Klasse, DL=1, ECX=Owner, Session auf Stack) plus `SelektionByIdent` und `LoadTaskIntoEngine`. Inline-Assembler, Absturzrisiko. Nur gegen die Test-DB und nur bei echtem Bedarf |
| Ribbon-Element wirklich entfernen | Wird nur abgeklemmt und unsichtbar gesetzt. Freigeben bräuchte den Delphi-Destruktor; das `TdxBarItem` gehört dem Host |
| Andere Bildformate als PNG und BMP | JPG/GIF/ICO müssten über weitere FPImage-Reader; bisher kein Bedarf |
| Menüs und Untermenüs tiefer als eine Ebene | `AmsReadMenu` liest eine Menüebene. Für Automatismen reicht das |
| Eigene Dialoge / Toolfenster | Bewusst draußen. Das Diagnosefenster des Prototyps war Ballast; `BuildReport` liefert den Inhalt, das Fenster baut das Plugin |
| Datenbankzugriff, Vorgänge anlegen | Nicht angefasst. Der Weg dahin führt über Actions/Events oder Automatismen |
| Gleitkomma- und Int64-Eigenschaften | Werden erkannt und benannt, aber nicht aus Text gesetzt. `SetFloatProp` nimmt ein `Extended` über den Stack — 10 Byte, bei denen ein Fehler den Stack zerlegt. In einer Oberfläche kommen sie praktisch nicht vor |
| Ereignisse mit mehr als zwei Parametern | Nur `TNotifyEvent` wird übernommen. Für `OnMouseDown` & Co. bräuchte jeder Ereignistyp einen eigenen Thunk, der den Stack richtig räumt |
| Elemente ohne eigenes Fenster unter dem Mauszeiger | `AmsElementAt` findet nur Fenster. Ein `TdxBarLargeButton` oder `TSpeedButton` hat keins; dafür bräuchte es das Hit-Testing von DevExpress |
| Änderungen überleben einen Neuaufbau der Oberfläche nicht | Baut AMS ein Formular neu auf, sind die Zeiger weg und die Patches gelten nicht mehr. Ein erneutes `ApplyPatchesFromIni` hilft; ein Automatismus dafür ist bewusst nicht drin |
