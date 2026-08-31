# AmsApi

Wiederverwendbare Free-Pascal-Bibliothek für Plugins zu **ASSFINET AMS.5**
(`C:\Program Files (x86)\assfinet ams.5\BIN`).

Ohne Delphi, ohne RAD Studio, ohne Hersteller-SDK. Ein Plugin mit eigenem
Ribbon-Button ist damit rund 30 Zeilen lang.

```pascal
library HelloButton;
{$MODE DELPHI}{$H+}
uses AmsApi.Plugin;

type
  THelloPlugin = class(TAmsPlugin)
  protected
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
  end;

procedure THelloPlugin.AfterMainWindow;
begin
  AddRibbonButton('Hallo', 'Zeigt eine Meldung', 'icon32.png');
end;

procedure THelloPlugin.ButtonClick(ASender: Pointer; ATag: Integer);
begin
  ShowInfo('Hallo aus dem Plugin.');
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(THelloPlugin);
end.
```

Die Basisklasse übernimmt IPlugin, das Warten auf das Hauptfenster, die
Auswertung von `DoCommand`, das Merken der `TBuSession` und ein sauberes
Entladen.

Nicht nur eigene Schaltflächen anlegen — auch die **vorhandenen** Elemente von
AMS lassen sich vollständig bearbeiten:

```pascal
var
  E: TAmsElement;
begin
  { Suchen: nach Name oder Beschriftung, mit Platzhaltern }
  if FindElement('bbLoeschen', E) then
  begin
    AmsEnableElement(E.Obj, False);                  // ausgrauen
    AmsSetElementCaption(E.Obj, 'Gesperrt');         // umbenennen
    AmsSetElementFont(E.Obj, '', 0, 'clRed', '[fsBold]');
    AmsSetElementSize(E.Obj, 220, AmsKeep);          // Breite, Höhe bleibt
    AmsSetElementProp(E.Obj, 'Hint', 'In diesem Mandanten gesperrt');
  end;

  { Was hat dieses Element überhaupt? Typ, Schreibbarkeit, erlaubte Werte }
  DumpElement('bbLoeschen', Liste);
end;
```

Den Namen dazu sucht man nicht im Quelltext, sondern im laufenden AMS: das
Beispiel `samples\UiTweaks` bringt ein Suchfenster mit — Begriff eingeben,
Treffer anklicken, Eigenschaft anklicken, fertige Patchzeile anwenden oder
kopieren. Im Code entsprechen dem `DumpElements` und `DumpElement`; wer lieber
mit der Pipette arbeitet, gibt das Fensterhandle aus AutoIt Window Info oder
Spy++ an `AmsElementOfWindow` — das liefert den Komponentennamen, den solche
Werkzeuge selbst nicht kennen.

Und die Frage, die man bei einem fremden Programm zuerst hat — **was
passiert eigentlich, wenn ich hier klicke?**

```pascal
AmsTraceWindowOpen(MainWindow);   { eine Zeile - mehr braucht es nicht }
```

Darin läuft mit, was der Host gerade tut — eingerückt nach Verschachtelung,
und damit sieht man, was wovon ausgelöst wird:

```
14:23:01.118  >  Ui      OnClick btnSpeichern   frmVertrag.pnFuss.btnSpeichern
14:23:01.119    >  Action acVertragSpeichern
14:23:01.121      .  SQL   UPDATE VERTRAG   3.100 ms   UPDATE VERTRAG SET ...
14:23:01.124      .  SQL   INSERT HISTORIE  0.800 ms   INSERT INTO HISTORIE ...
14:23:01.166    <  Action acVertragSpeichern   47.200 ms
14:23:01.169  <  Ui      OnClick btnSpeichern   51.000 ms   ok
```

**Zusehen braucht keine Datei.** Das Fenster liest aus einem Ringpuffer im
Speicher. Wer den Verlauf behalten will, drückt darin »Aufzeichnen« — dann
läuft zusätzlich `%TEMP%\<Plugin>.trace.tsv` mit, die sich unverändert in
Excel öffnen lässt. Abschalten geht jederzeit, das Zusehen läuft weiter.
Ohne Fenster geht es auch:

```pascal
AmsRecordStartAll;                       { nur sammeln }
AmsRecordStartAll('C:\temp\lauf.tsv');   { sammeln und mitschreiben }
{ ... im AMS arbeiten ... }
AmsRecordStopAll;
Log(AmsTraceReport);                     { was wie oft, wie lange }
```

Dasselbe geht ohne eine Zeile Pascal aus der `plugin.ini`:

```ini
[Patch]
bbLoeschen.Enabled=0
bbLoeschen.Hint=In diesem Mandanten gesperrt
Speichern.Caption=Sichern
bb*.Font.Style=[fsBold]
pnHinweis.Color=#FFF4C2
```

**Jede** Änderung wird mit ihrem alten Wert mitgeschrieben und beim Entladen
des Plugins wieder zurückgenommen — sonst bliebe AMS mit einer toten
Schaltfläche zurück.

---

## Voraussetzungen

* **Free Pascal 3.2.2, i386-Win32** unter `C:\FPC\3.2.2`
  (anderer Pfad → oben in `build.cmd` anpassen)
* AMS.5 auf dem Rechner, wenn `hosttest` benutzt werden soll
* Python 3 nur für die Hilfsskripte unter `tools\` (optional)

**32 Bit ist Pflicht.** AMS ist eine x86-Anwendung; eine 64-Bit-BPL lädt der
Host nicht.

---

## Bauen

```cmd
build.cmd                 :: Bibliothek + Tests + alle Beispiele
build.cmd HelloButton     :: nur ein Beispiel
```

Ergebnis: `build\deploy\<Name>\<Name>.bpl` samt `plugin.ini` und Symbolen.

Der Lauf macht drei Dinge:

1. jede Unit der Bibliothek übersetzen (`tests\compileall.lpr`)
2. `tests\unittests.exe` — Prüfungen, die **ohne AMS** laufen
3. die Beispiel-Plugins bauen und ausliefern

---

## Testen

### Ohne AMS

```cmd
build\unittests.exe
```

Prüft INI-Parser, Pfadauflösung, den Aufbau der Delphi-Strings (RefCount −1!),
die PNG→BMP32-Konvertierung, den Platzhaltervergleich der Elementsuche, die
Farbumrechnung und die Patchzeilen. Genau die Stellen, an denen im Prototyp
still falsche Werte entstanden sind.

### Verlaufsfenster ohne AMS

```cmd
build\tracewindemo.exe
```

Fährt das Verlaufsfenster aus `AmsApi.TraceWindow` durch: öffnen, mit
erfundenen Zeilen füttern, über Nachrichten bedienen — aufzeichnen an und
aus, anhalten und weiter, Kategorien, leeren, Bericht, kopieren —, in vier
Breiten umbrechen, schließen, Fensterklasse abmelden. Geprüft wird dabei
auch, dass der Cursor keine Zeile doppelt zeigt und keine verschluckt. Das
Fenster bleibt versteckt und außerhalb des Bildes.

### Suchfenster ohne AMS

```cmd
build\finderdemo.exe
```

Fährt das Win32-Suchfenster aus `samples\UiTweaks` durch: erzeugen, umbrechen,
über Nachrichten bedienen, schließen, Fensterklasse abmelden. Das Fenster
bleibt dabei versteckt und außerhalb des Bildes.

### RTTI gegen die installierten Packages

```cmd
build\rttiprobe.exe
```

Lädt `rtl230.bpl` und `vcl230.bpl` und liest die Typinformationen von
`TComponent` und `TFont`. Damit sind die Offsets in `TTypeInfo`, `TTypeData`
und `TPropInfo` belegt — die einzige Stelle, an der sich ein falscher Offset
sonst erst im laufenden AMS zeigen würde. AMS muss dafür **installiert**, aber
nicht gestartet sein; fehlt es, überspringt sich die Probe selbst.

### Ladepfad ohne AMS zu starten

```cmd
build\hosttest.exe build\deploy\HelloButton\HelloButton.bpl
```

Der Testhost geht denselben Weg wie AMS: `rtl230.bpl!Initialize`,
`System.SysUtils.LoadPackage`, `PluginInit`, dann `SetPluginManager` /
`Loaded` / `DoCommand` / `Unload` / `UnloadPackage`. Eine Offscreen-Senke
dient als Hauptfenster-Ersatz.

Damit finden sich Ladefehler, fehlende Exporte und Abstürze beim Init, **ohne**
AMS zu starten. Was hier *nicht* geht: Ribbon-Einbau und Automatismen — dafür
müsste das echte AMS-Hauptformular existieren. Die Bibliothek meldet das
sauber („Ribbon: vcl-Symbole fehlen“) statt abzustürzen; genau das ist die
erwartete Ausgabe.

### Symboltabelle gegen die Installation prüfen

```cmd
python tools\checksyms.py
```

Vergleicht jeden in `AmsApi.Bind` gebundenen mangled Namen mit den Exporten der
installierten BPLs. Der erste Schritt, wenn eine neue AMS-Version aufschlägt.

---

## Ausliefern

Ordner unter `BIN\plugins\<Name>\` mit `<Name>.bpl` und `plugin.ini`:

```cmd
copy /Y "build\deploy\HelloButton\*" ^
        "C:\Program Files (x86)\assfinet ams.5\BIN\plugins\HelloButton\"
```

> **Regel:** Nie automatisiert nach `C:\Program Files (x86)\assfinet ams.5\`
> schreiben. Das ist die Installation des Anwenders und braucht
> Administratorrechte — den Kopierbefehl übergeben und ihn ausführen lassen.

Laufzeit-Log: `%TEMP%\<Name>.log` (pro Plugin eine eigene Datei, rollt bei 2 MB).

---

## Die Units

| Unit | Inhalt | Braucht AMS |
|---|---|---|
| `AmsApi.Types` | ABI-Vertrag: `IPlugin`, Signaturen, VMT-Offsets, Konstanten | – |
| `AmsApi.Log` | Threadsicheres Log, `AmsLastError`, `AmsFail` | – |
| `AmsApi.Ini` | `plugin.ini` lesen, Pfade auflösen | – |
| `AmsApi.Http` | WinHTTP GET/POST, synchron und im Hintergrund, Browser öffnen | – |
| `AmsApi.Bind` | Versionsunabhängiges Binden der Host-Symbole, gruppenweise | ja |
| `AmsApi.Strings` | Delphi-`UnicodeString` mit RefCount −1 (Heap-Falle) | ja |
| `AmsApi.Rtti` | Klassennamen, published properties, VMT-Slots, Interface→Objekt | ja |
| `AmsApi.Components` | Fenster- und Komponentenbaum, Wurzelliste, Suche | ja |
| `AmsApi.Props` | Delphi-RTTI: welche Eigenschaften ein Element hat, welchen Typ, welche Werte erlaubt sind. Pfade (`Font.Size`), alles als Text, Änderungsjournal mit Rücknahme | ja |
| `AmsApi.Ui` | **Vorhandene Elemente des Hosts finden und bearbeiten** — deaktivieren, umbenennen, Größe, Aussehen, `OnClick` übernehmen | ja |
| `AmsApi.Glyphs` | PNG→BMP32 + `AlphaFormat`, Symbol in ein Host-Element laden | teilweise |
| `AmsApi.Menus` | dxBar-Popupmenüs lesen, `DirectClick` | ja |
| `AmsApi.Ribbon` | Schaltflächen im Ribbon, Klick-Dispatch, sauberes Abklemmen | ja |
| `AmsApi.Actions` | Benannte `TafnAction` / `TafnEvent` | ja |
| `AmsApi.Automatismus` | Automatismen **im aktuellen Kontext** starten/auflisten | ja |
| `AmsApi.Workflow` | WorkflowEngine — Zweitweg, nur AutoStart-Automatismen | ja |
| `AmsApi.Hook` | Aufrufe des Hosts abfangen: Importtabelle, VMT-Slot, Code-Detour mit Trampolin und Laengendekoder | teilweise |
| `AmsApi.Trace` | Zeitachse mit Verschachtelung und Dauer, als TSV. Beantwortet "was loest was aus" | – |
| `AmsApi.Recorder` | **Mitschreiben, was AMS tut** — SQL, `TafnAction`/`TafnEvent`, jeder Klick | ja |
| `AmsApi.TraceWindow` | **Verlaufsfenster, das mitläuft** — zusehen ohne Aufzeichnen, Aufzeichnen auf Knopfdruck | ja |
| `AmsApi.Plugin` | `TAmsPlugin`-Basisklasse und Export-Boilerplate | ja |

Abhängigkeiten laufen nur nach unten: `TraceWindow` → `Recorder` →
`Ui`/`Hook`/`Trace` · `Plugin` → `Ribbon`/`Automatismus`/`Ui` →
`Menus`/`Components`/`Props` → `Rtti` → `Strings` → `Bind` → `Log`/`Types`.

---

## Designregeln

1. **Keine MessageBox aus der Bibliothek.** Funktionen liefern `Boolean`, die
   Ursache steht in `AmsLastError` und im Log. Ob daraus ein Dialog wird,
   entscheidet das Plugin (`ShowInfo` / `ShowWarning` / `ShowError` /
   `ShowLastError` auf der Basisklasse).
2. **Versionsunabhängig binden.** Der Package-Suffix (`230` = Delphi 10
   Seattle) wird zur Laufzeit ermittelt, nicht verdrahtet.
3. **Lazy und gruppenweise binden.** Wer nur HTTP braucht, scheitert nicht an
   einem fehlenden `afnBu.bpl`. Jeder Binder ist idempotent.
4. **Jeder Host-Aufruf in `try/except`.** Delphi-Exceptions kommen als
   `EEDFADE` über die Modulgrenze und sind nicht typisiert auswertbar.
5. **Fehlende Symbole sind kein Absturz**, sondern ein `False` mit Klartext.
6. **Keine managed Typen über die Modulgrenze** — nur Zeiger, Integer, Boolean.
7. **Was ohne AMS testbar ist, ist ohne AMS getestet.**

---

## Beispiele

| Beispiel | Zeigt |
|---|---|
| `samples\HelloButton` | Minimalfall: Ribbon-Button mit eigenem Symbol und Meldung |
| `samples\WebHook` | HTTP-Anfrage im Hintergrundthread, Ergebnis per `PostMessage` zurück in den UI-Thread |
| `samples\RunAutomatismus` | Automatismus im aktuellen Kontext starten, mit brauchbarer Meldung, wenn er hier nicht angeboten wird |
| `samples\Recorder` | **Verlaufsfenster im laufenden AMS**: ein Knopf öffnet es, darin läuft mit, was der Host tut — Klicks, Actions und SQL mit Dauer und Verschachtelung. Aufzeichnen in eine TSV-Datei ist ein Schalter darin, kein Muss |
| `samples\UiTweaks` | **Suchfenster im laufenden AMS** (Win32, ohne VCL): Element suchen, Eigenschaft anklicken, fertige Patchzeile anwenden oder kopieren. Dazu Patches aus der `plugin.ini`, `OnClick` mithören und Rücknahme per Knopfdruck |

Die Symbole (`icon32.png`) sind Platzhalter aus `tools\mkicon.py` — durch
eigene ersetzen.

---

## Weiterführend

* `docs\HOST-ABI.md` — der komplette Host-Vertrag: Ladevorgang, `IPlugin`,
  Aufrufkonventionen, Symboltabelle, Fallstricke. **Das ist das Wissen, das nie
  wieder erarbeitet werden soll.**
* `analyse\` — der ursprüngliche Prototyp `AmsToolbox.lpr` (1841 Zeilen, ein
  Stück) als Referenz. Alles Wiederverwendbare daraus steckt jetzt in `src\`.
* `tools\exports.py` — Exportnamen aus BPL/DLL listen. Eigener PE-Parser, weil
  `pefile` bei großen Tabellen abschneidet (`afnBu.bpl` hat ~34800 Symbole).
