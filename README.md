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

Und was der Host **nicht** mitbringt, kommt dazu — eine Schaltfläche auf ein
vorhandenes Panel, oder gleich eine Kopie einer vorhandenen:

```pascal
uses AmsApi.Factory;

{ Neu: Klasse, Beschriftung, Zielcontainer }
NewElement('TButton', 'Prüfen', 'pnUnten');

{ Kopie eines vorhandenen Elements, woanders eingehängt.
  True = der Klon ruft dieselbe Behandlung des Hosts wie das Original. }
CloneElement('bbSpeichern', 'bmbBenutzerdefiniert', True);
```

Die Klasse muss dafür nicht registriert sein: findet `Classes.GetClass` sie
nicht, wird ein Element derselben Klasse in der laufenden Oberfläche gesucht
und dessen Klassenzeiger genommen. Angelegtes und Geklontes verschwindet beim
Entladen wieder — wie jede Änderung.

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
über Nachrichten bedienen — auch Merken, Klonen, Neu und Entfernen —,
schließen, Fensterklasse abmelden. Geprüft wird dabei, dass sich in keiner
Breite zwei Bedienelemente überdecken und dass jeder Knopf ohne Host **sagt**,
was fehlt, statt still nichts zu tun. Das Fenster bleibt versteckt und
außerhalb des Bildes.

### DOOM-Engine ohne AMS

```cmd
build\doomdemo.exe
```

Prüft den kompletten Spiele-Zweig ohne Host: der WAD-Leser gegen ein im Test
erzeugtes IWAD (Palette und Flat kommen byteweise richtig zurück), die Engine
rendert nach ein paar Bildschritten ein **strukturiertes** Bild (nicht schwarz,
viele Farben — Wände, Boden, Decke, Sprites) und legt es als
`%TEMP%\amsapi_doom_frame.bmp` zum Ansehen ab, Schießen senkt die Gegnerzahl
plausibel, und das Bildpuffer-Fenster läuft versteckt ein paar Frames und baut
sich sauber wieder ab. Kein echtes `DOOM1.WAD` nötig.

### HTML-Ansicht ohne AMS

```cmd
build\browserdemo.exe
```

Fährt die eingebettete HTML-Ansicht aus `AmsApi.Browser` durch, in der der
Plugin Manager die README zeigt: IE-WebBrowser über `atl.dll`, Seiten laden
bis `ReadyState = 4`, Titel lesen, abgefangene Navigation, und den Ersatzweg
(schreibgeschütztes Textfeld), falls der Browser fehlt. Versteckt, ohne Reste.

### Plugin Manager ohne AMS

```cmd
build\pluginmgrdemo.exe
```

Baut in `%TEMP%\amsapi_pmdemo\` einen Katalog auf einem lokalen „Server“ mit
drei Plugins und einen Ersatz für `BIN\plugins` und bedient das Fenster wie
ein Anwender: Liste mit Zuständen, Beschreibungsseite mit gerenderter README
und eingebettetem Bild, **Installieren**, **Aktualisieren, während die BPL
geladen ist** (genau wie im laufenden AMS) mitsamt Übernahme der Werte des
Anwenders, Ablehnung bei falscher Prüfsumme, **Entfernen** mit Sicherung, die
`plugin.ini` im Einstellungsfenster ändern, Suche und Filter. Danach den
Helfer `AmsPluginApply.exe` als eigenen Prozess: Manifest vorhanden,
`--apply` und `--restart`. Kein Netz nötig.

### RTTI gegen die installierten Packages

```cmd
build\rttiprobe.exe
```

Lädt `rtl230.bpl` und `vcl230.bpl` und liest die Typinformationen von
`TComponent` und `TFont`. Damit sind die Offsets in `TTypeInfo`, `TTypeData`
und `TPropInfo` belegt — die einzige Stelle, an der sich ein falscher Offset
sonst erst im laufenden AMS zeigen würde.

Dazu die Klassenkette (`vmtClassName`, `vmtParent`, `vmtInstanceSize`) und der
**virtuelle Konstruktor aus `AmsApi.Factory`**: er wird gegen die echte
Delphi-RTL aufgerufen, ein `TComponent` mit Besitzer angelegt, benannt und
wieder freigegeben. Damit sind die Registerbelegung (`EAX`/`DL`/`ECX`) und der
zur Laufzeit gesuchte VMT-Slot belegt, ohne dass AMS laufen muss. AMS muss
dafür **installiert**, aber nicht gestartet sein; fehlt es, überspringt sich
die Probe selbst.

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

### Über den Plugin Manager

Einmal `PluginManager` von Hand kopieren — danach geht alles Weitere aus AMS
heraus (Ribbon-Knopf **Plugin Manager**). `build.cmd` legt dafür je Plugin
die Release-Assets ab:

```
build\release\<Name>.zip     ganzer Plugin-Ordner (BPL, plugin.ini, Bild, README)
build\release\<Name>.ini     nur die plugin.ini - Version und Beschreibung
build\release\SHA256SUMS.txt Prüfsummen, für Sha256= im Katalog
```

Veröffentlichen auf GitHub:

```cmd
gh release create v1.1.0 build\release\*.zip build\release\*.ini
```

Der Katalog (`samples\PluginManager\katalog.ini`) nennt je Plugin nur das Repo
und den Unterordner; der Manager holt das neueste Release, die README und das
Bild selbst. Ohne GitHub: `build\release` unverändert auf ein Netzlaufwerk
kopieren und im Katalog `Base=\\server\ams\plugins\` eintragen.

**Warum nicht `git clone`?** Auf den Arbeitsplätzen gibt es weder `git` noch
einen Compiler, und ein Repo enthält Quelltext, keine BPL. Das Repo bleibt die
Quelle der Wahrheit (README, Bilder, `plugin.ini` mit `[Info]`), ausgeliefert
wird das fertige Release-Paket — ohne GitHub-API, also ohne deren Limit von 60
Anfragen je Stunde und Adresse, das eine Firma hinter einer gemeinsamen
Adresse sofort träfe. Private Repos gehen mit Token (dann über die API).

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
| `AmsApi.Factory` | **Elemente anlegen, klonen und einhängen** — virtueller Konstruktor über den zur Laufzeit gesuchten VMT-Slot, Eigenschaften und auf Wunsch Ereignisse kopieren; alles Angelegte wird beim Entladen abgeräumt | ja |
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
| `AmsApi.GameWindow` | **Bildpuffer-Fenster** — rohe Win32-Fläche mit 32-Bit-DIB, `StretchDIBits`-Ausgabe, Tastatur und Bildschleife. Was der Host für ein Spiel nicht mitbringt | – |
| `AmsApi.Wad` | **DOOM-WAD lesen** — Header, Lump-Verzeichnis, `PLAYPAL`, Flats, `patch_t`-Bilder, `TEXTURE1`/`PNAMES`; alles bereichsgeprüft | – |
| `AmsApi.DoomEngine` | **Ersatz-DOOM-Engine (pures Pascal)** — Raycaster mit texturiertem Boden/Decke, Sprite-Gegnern, Waffe und HUD; läuft ohne alles, benutzt WAD-Assets wenn vorhanden | – |
| `AmsApi.DoomCore` | **Der echte DOOM-Kern** — lädt `doomcore.dll` (doomgeneric, GPLv2) und treibt ihn: echtes DOOM mit echten Leveln aus einem IWAD. Bild kommt aus der DLL, wir blitten es | – |
| `AmsApi.Files` | Dateien roh lesen/schreiben, UTF-8/ANSI erkennen, Base64 und `data:`-URIs, SHA-256 (bcrypt), Ordnerbäume, **geladene BPL ersetzen** (beiseite umbenennen), Schreibrechte prüfen ohne UAC-Virtualisierung | – |
| `AmsApi.Zip` | ZIP prüfen, entpacken (Zip-Slip- und Zip-Bomben-Schutz), packen | – |
| `AmsApi.IniDoc` | INI **bearbeiten**, ohne Kommentare und Layout zu verlieren; Beschreibung je Schlüssel aus dem Kommentar darüber; Benutzerwerte in eine neue Fassung übernehmen | – |
| `AmsApi.Process` | Programm mit UAC starten und warten (AMS zeichnet weiter), **AMS neu starten** über einen Wartehelfer, Prozess überlebt AMS | – |
| `AmsApi.Dialogs` | Rückfragen mit eigenen Knöpfen (TaskDialog, sonst MessageBox), Neustart-Frage | – |
| `AmsApi.Markdown` | **Markdown → HTML** (GFM: Tabellen, Code, Listen, Bilder, Roh-HTML bereinigt) und eine fertige Seite im GitHub-Stil | – |
| `AmsApi.Browser` | **Eingebettete HTML-Ansicht** (IE-WebBrowser über `atl.dll`), Links gehen in den Standardbrowser; ohne Browser ein Textfeld | – |
| `AmsApi.WinCtl` | Bausteine für VCL-freie Fenster: Systemschriften, ListView mit Symbolen, ImageList | – |
| `AmsApi.IniEditor` | **Einstellungsfenster** für eine INI: Liste, Beschreibung aus den Kommentaren, Textmodus, gesperrte Schlüssel, eigener Speicherweg | – |
| `AmsApi.PluginStore` | **Woher Plugins kommen**: Katalog, GitHub-Releases/Base=-Quellen, installierte Plugins, Versionen, Paket bereitstellen | – |
| `AmsApi.PluginApply` | Installieren/Ersetzen/Entfernen in `BIN\plugins` mit Sicherung und Rücknahme — im Prozess oder im UAC-Helfer | – |
| `AmsApi.PluginManager` | **Plugin-Browser**: Liste mit Bild und Zustand, README, Installieren, Einstellungen, Neustart-Dialog | – |
| `AmsApi.Plugin` | `TAmsPlugin`-Basisklasse und Export-Boilerplate | ja |

Abhängigkeiten laufen nur nach unten: `TraceWindow` → `Recorder` →
`Ui`/`Hook`/`Trace` · `Plugin` → `Ribbon`/`Automatismus`/`Ui` →
`Menus`/`Components`/`Props` → `Rtti` → `Strings` → `Bind` → `Log`/`Types`.
Der Spiele-Zweig steht daneben und braucht den Host nicht:
`DoomEngine` → `Wad`/`GameWindow` → `Log`, dazu `DoomCore` → `Log` (lädt den
echten DOOM-Kern `doomcore.dll`, siehe `native\`).
Ebenso der Plugin-Manager-Zweig, ganz ohne Host-Symbole:
`PluginManager` → `PluginStore`/`PluginApply`/`IniEditor`/`Browser`/`Markdown`
→ `IniDoc`/`Zip`/`Http`/`Process`/`Dialogs`/`WinCtl` → `Files` → `Log`.

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
| `samples\GdvTrace` | **GDV-Import mitschneiden**: ein Ribbon-Knopf öffnet das Verlaufsfenster, darin läuft der GDV-Import verschachtelt mit — Einlesen/Zuordnen/Schreiben, welche JS-Funktion des Übersetzungsscripts wann läuft (`Sparte()`, `Identify()`, `ExportKunde/Vertrag()`), welche Host-Objekte das Script bekommt, und mit `Feldebene=1` jeder einzelne GDV-Feldzugriff (`Gdv.GetValue`). Zeigt, wie das `contecto_gdvams`-Script zur Laufzeit benutzt wird. Hooks per Reverse-Engineering (siehe `amsreverse/amsgdv`) |
| `samples\UiTweaks` | **Suchfenster im laufenden AMS** (Win32, ohne VCL): Element suchen, Eigenschaft anklicken, fertige Patchzeile anwenden oder kopieren. Dazu **bauen** — Vorlage merken, Kopie in einen anderen Container setzen, neues Element anlegen, eigene wieder entfernen. Und Patches aus der `plugin.ini`, `OnClick` mithören, Rücknahme per Knopfdruck |
| `samples\PluginManager` | **Plugin Manager im Ribbon**: Plugins aus Katalogen (GitHub-Repos, Webserver, Netzlaufwerk) suchen und filtern, mit Bild, Autor, Version und der **README aus dem Repo** ansehen, installieren, aktualisieren (eigene Einstellungen bleiben), entfernen, jede `plugin.ini` im **Einstellungsfenster** bearbeiten; danach **„Jetzt neu starten / Später“**. Weil `BIN\plugins` für Benutzer schreibgeschützt ist, kopiert `AmsPluginApply.exe` (liegt daneben) per UAC. Woher die Plugins kommen, steht in `plugin.ini` unter `[Katalog]`, das Format in `katalog.ini` |
| `samples\Doom` | **DOOM im laufenden AMS**, eingebettet (kein eigenes Fenster). Ein Ribbon-Knopf hängt eine Spielfläche in AMS. Mit `doomcore.dll` (siehe `native\`) und einem IWAD läuft der **echte DOOM-Kern mit echten Leveln** (E1M1 …, Gegner, Waffen, Spiellogik); fehlt DLL oder WAD, springt die pure-Pascal-Ersatz-Engine ein. Zeigt: Bildpuffer-Fläche als `WS_CHILD` in den Host hängen (`AmsApi.GameWindow`), einen nativen Fremdkern laden und treiben (`AmsApi.DoomCore`), Bildschleife im Message-Loop von AMS |

Die Symbole (`icon32.png`) sind Platzhalter aus `tools\mkicon.py` — durch
eigene ersetzen. Für **echtes** DOOM: einmal `native\get_doomgeneric.cmd` und
`native\build_doomcore.bat` (braucht Visual Studio), dann eine `DOOM1.WAD`
(Shareware genügt) oder `freedoom1.wad` neben die BPL oder in `plugin.ini` unter
`Wad=`. Einbetten in einen bestimmten AMS-Tab: dessen Elementnamen mit
`samples\UiTweaks` suchen und in `plugin.ini` unter `Container=` eintragen.

---

## Weiterführend

* `docs\HOST-ABI.md` — der komplette Host-Vertrag: Ladevorgang, `IPlugin`,
  Aufrufkonventionen, Symboltabelle, Fallstricke. **Das ist das Wissen, das nie
  wieder erarbeitet werden soll.**
* `analyse\` — der ursprüngliche Prototyp `AmsToolbox.lpr` (1841 Zeilen, ein
  Stück) als Referenz. Alles Wiederverwendbare daraus steckt jetzt in `src\`.
* `tools\exports.py` — Exportnamen aus BPL/DLL listen. Eigener PE-Parser, weil
  `pefile` bei großen Tabellen abschneidet (`afnBu.bpl` hat ~34800 Symbole).
