# GdvTrace — GDV-Import bei Laufzeit mitschneiden

Hängt Code-Detours an die Delphi-Methoden, die den GDV-Import von AMS.5 tragen
(alle per Reverse-Engineering lokalisiert, siehe
`amsreverse/amsgdv/Script-Engine-und-Aufrufstellen.md`), und schreibt eine
verschachtelte Zeitachse mit Dauer. Ein Ribbon-Button **GDV-Trace** öffnet das
Verlaufsfenster; mitgeschnitten wird ab dem Start, auch ohne offenes Fenster.

## Was sichtbar wird

| Gruppe | gehookte Funktion | Zeile im Verlauf |
|---|---|---|
| Einlesen | `TGDVData.ImportGDV`, `TGdvDatei.LoadFromStream / SplitDatei` | `GDV Einlesen: …` |
| Zuordnen | `TSyncManagerGDV_AMS4.IdentifyItem / FindCandidates` | `GDV Zuordnen: …` |
| Schreiben | `TSyncManagerGDV_AMS4.ExportItem` | `GDV Schreiben: ExportItem` |
| JS-Aufrufe | `TGDVCustomTranslationScript.Identify / Sparte / ExportKunde / ExportVertrag` | `JS Sparte() … = KFZ` (mit Rückgabe + Dauer) |
| JS-Objekte | `TScriptHost.AddObject` | `JS Objekt: Gdv / Options / Context …` |
| **Feldebene** | `TGdvSatzBufferScriptLink.GetValueMulti / GetWahl`, `GetSatzNummer / GetVertragStatus` | `JS liest Feld 0200..1..004` |

Mit `MitSQL=1` laufen zusätzlich die vom Schreibvorgang ausgelösten SQLs und
Actions mit (über `AmsApi.Recorder`).

## Schalter (`plugin.ini`, Sektion `[Aufzeichnung]`)

- `Feldebene=0` — jeden Feldzugriff des Scripts mitschneiden. Zeigt **genau,
  welche GDV-Felder das JS liest**, erzeugt aber viele Zeilen pro Vertrag.
- `MitSQL=1` — Datenbankverkehr + Actions dazu.
- `FensterBeimStart=0`, `Zeilenpuffer=4000`, `MaxDetail=300`, `AuchInsLog=0`.

Aufzeichnen in `%TEMP%\GdvTrace.trace.tsv` ist ein Schalter im Fenster
(„Aufzeichnen"), kein Muss — Zusehen reicht.

## Bauen

```cmd
build.cmd GdvTrace
```
→ `build\deploy\GdvTrace\` mit `GdvTrace.bpl`, `plugin.ini`, `icon32.png`.

## Ausliefern (Admin-Rechte; selbst ausführen)

```cmd
copy /Y "build\deploy\GdvTrace\*" ^
        "C:\Program Files (x86)\assfinet ams.5\BIN\plugins\GdvTrace\"
```

## Grenzen / offen

- **Laufzeit noch nicht in echtem AMS getestet.** Kompiliert, gelinkt und alle
  15 Hook-Symbole sind gegen `afnBu.bpl`/`afnComponentsRt.bpl` als exakte
  Exporte verifiziert. Der erste echte GDV-Import ist der Funktionstest.
- **Kein `Fetch*`-Hook** (FetchKunde/FetchVertrag/FetchMitarbeiter): deren
  Rückgabetyp ist nicht sicher bestimmt, und eine falsche Parameter-Arität im
  Detour würde den Host abstürzen lassen. `ExportItem` + die JS-Export-Hooks
  klammern die Schreibphase ohnehin ein. Nachrüstbar, sobald der Rückgabetyp
  per Disassembly bestätigt ist.
- Kein `EvaluateCode`-Hook: die benannten Einstiege (`Sparte`, `Identify`,
  `ExportKunde`, `ExportVertrag`, `GetSatzNummer`, `GetVertragStatus`) zeigen
  dieselbe Information direkt und ohne das riskante `OleVariant`-Result.
