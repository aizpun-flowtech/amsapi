# native — der echte DOOM-Kern als `doomcore.dll`

Damit das `Doom`-Plugin **echtes DOOM mit echten Leveln** rendert (E1M1 und so
weiter, samt Gegnern, Waffen und Spiellogik), lädt es zur Laufzeit eine
`doomcore.dll`. Diese DLL ist der echte DOOM-Kern **[doomgeneric](https://github.com/ozkl/doomgeneric)**
(auf Chocolate-Doom-/linuxdoom-Basis), gebaut mit Visual Studio als 32-Bit-DLL.

Warum eine separate DLL und nicht in die BPL gelinkt? Weil FPC (der die BPL
baut) und MSVC (der DOOM baut) getrennte Objekt-/CRT-Welten sind. Eine normale
Win32-DLL, per `LoadLibrary` geladen, vermeidet jede Vermischung. Das FPC-Plugin
spricht sie über eine schmale C-API an (`AmsApi.DoomCore`).

## Bauen

Voraussetzung: **Visual Studio mit C++** (hier getestet mit VS 2022/„18").
**32 Bit ist Pflicht** — AMS ist x86 und lädt nur eine 32-Bit-DLL.

```cmd
:: 1. Quellen holen (einmalig; ~30k Zeilen, wird NICHT mit eingecheckt)
native\get_doomgeneric.cmd

:: 2. DLL bauen
native\build_doomcore.bat
```

Ergebnis: `native\doomcore.dll`. `build.cmd` kopiert sie dann automatisch neben
`Doom.bpl` nach `build\deploy\Doom\`.

## Was hier von Hand dazukam

* **`dg_ams.c`** — die Plattform- und Export-Schicht: implementiert die
  `DG_*`-Funktionen, die doomgeneric verlangt (ohne eigenes Fenster — das Bild
  bleibt im Puffer), und exportiert die schlanke API
  `dg_start` / `dg_tick` / `dg_framebuffer` / `dg_key` / `dg_alive` / `dg_title`
  / `dg_shutdown`.
* **`dg_sound.c`** — das Sound-Backend (SFX + Musik) **ohne SDL/Allegro**, nur
  über Windows-`winmm`. doomgeneric selbst ist stumm: sein `i_sound.c` kennt nur
  SDL-/Allegro-Module hinter `FEATURE_SOUND`, das im eingebetteten Build aus ist.
  Diese Datei liefert stattdessen:
    * **SFX** — ein eigener Software-Mixer auf `waveOut`. Die `DS*`-Lumps werden
      beim ersten Abspielen auf `snd_samplerate` (16 Bit mono) resampled und
      gecached; ein Feeder-Thread mischt bis zu 16 Kanäle (Lautstärke + Panning)
      in doppelt gepufferte `waveOut`-Blöcke.
    * **Musik** — die `MUS`/`MIDI`-Lumps werden per `mus2mid` (doomgeneric-eigen)
      nach MIDI gewandelt, in eine Temp-Datei geschrieben und über den
      **MCI-Sequencer** (MIDI-Mapper) gespielt; Looping läuft über `Poll()`.
  Registriert wird das Backend in `i_sound.c` als `DG_sound_module` /
  `DG_music_module` unter dem Build-Schalter **`DG_AMS_SOUND`** (NICHT über
  `FEATURE_SOUND`, das sonst `<SDL_mixer.h>` einbinden würde). Jeder Geräte-
  fehler führt nur zu Stille, nie zu einem Absturz des Hosts.
* **`build_doomcore.bat`** — ruft `vcvars32`, übersetzt die Dateiliste aus
  `doomgeneric.vcxproj` (ohne `doomgeneric_win.c`, dessen Rolle `dg_ams.c`
  übernimmt) plus `dg_ams.c`, `dg_sound.c` und `mus2mid.c` zu `doomcore.dll`
  (`/MT`, statische CRT — keine Laufzeit-Abhängigkeit; `/DDG_AMS_SOUND`,
  gelinkt gegen `winmm.lib`).
* **Ein Sicherheits-Patch in `doomgeneric\doomgeneric\i_system.c`**: DOOM beendet
  bei einem fatalen Fehler (`I_Error`) sonst den ganzen Prozess per `exit()` —
  das würde **AMS mitreißen**. Der Patch lässt einen fatalen Fehler stattdessen
  per `longjmp` in `dg_ams.c` zurückspringen; `dg_start`/`dg_tick` liefern dann
  `0`, und der Host läuft weiter. (`git clone` holt die Originaldatei; die hier
  eingecheckte Fassung enthält den Patch.)
* **Zwei kleine Patches in `i_sound.c` / `i_sound.h`**: sie registrieren unter
  `DG_AMS_SOUND` das Backend aus `dg_sound.c` als `DG_sound_module` /
  `DG_music_module` (Sound-Modul-Tabelle und `InitMusicModule`), ohne
  `FEATURE_SOUND` und damit ohne SDL. (`git clone` holt die Originaldateien;
  die hier eingecheckten Fassungen enthalten die Patches.)

## WAD

Der Kern braucht ein IWAD. **Keins ist hier eingecheckt** (id-Assets sind
urheberrechtlich geschützt). Legale Quellen:

* **DOOM1.WAD** — die frei weitergebbare DOOM-Shareware (echte id-Level E1).
* **freedoom1.wad** — freie Inhalte, <https://freedoom.github.io/> (eigene Level
  im DOOM-Format).

WAD neben `Doom.bpl` legen oder in `plugin.ini` unter `[Doom] Wad=` eintragen.

## Lizenz

doomgeneric / der DOOM-Quellcode steht unter der **GPLv2**. Er wird zu einer
eigenständigen DLL gebaut, die das Plugin zur Laufzeit lädt — der FPC-Code der
Bibliothek bleibt davon getrennt. Wer die DLL weitergibt, gibt den GPL-Kern
weiter und muss dessen Bedingungen einhalten.
