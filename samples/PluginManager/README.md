# Plugin Manager

Ein Knopf im Ribbon öffnet den Plugin-Browser von AMS: Plugins finden,
ansehen, installieren, aktualisieren, entfernen und einstellen.

![Symbol](icon32.png)

## Was er kann

| | |
|---|---|
| **Finden** | Suchfeld und Filter *Alle / Installiert / Updates / Nicht installiert* |
| **Ansehen** | Bild, Titel, Autor, Lizenz, installierte und verfügbare Version – und diese README, direkt aus dem Repo gerendert |
| **Installieren / Aktualisieren** | Paket laden, Prüfsumme, entpacken, eigene Einstellungen behalten, nach `BIN\plugins` kopieren |
| **Entfernen** | Ordner wird vorher gesichert |
| **Einstellungen** | jede `plugin.ini` bearbeiten – mit der Beschreibung aus den Kommentaren der Datei |
| **Neustart** | nach jeder Änderung: *Jetzt neu starten* oder *Später* |

## Woher die Plugins kommen

Aus einem **Katalog** – einer INI-Datei, eingetragen unter `[Katalog]` in der
`plugin.ini` dieses Plugins (Knopf *Quellen …*):

```ini
[HelloButton]
Repo=github:aizpun-flowtech/amsapi
Path=samples/HelloButton
```

Auf den Arbeitsplätzen gibt es weder `git` noch einen Compiler. Ausgeliefert
wird deshalb nicht der Quelltext, sondern das fertige Paket über
**GitHub-Releases**: je Plugin die Assets `<Name>.zip` und `<Name>.ini`.
`build.cmd` legt beide unter `build\release\` ab:

```cmd
build.cmd
gh release create v1.0.0 build\release\*
```

Ohne GitHub geht es genauso mit einem Webserver oder Netzlaufwerk:

```ini
[Intern]
Base=\\server\ams\plugins\Intern\
```

Private Repos: unter `[GitHub]` einen Token mit *Contents: Read-only*
hinterlegen, am besten über `TokenFile=` im eigenen Profil.

## Rechte

`BIN\plugins` liegt unter *Program Files* und ist für normale Benutzer
schreibgeschützt. Dann fragt Windows einmal nach Administratorrechten (UAC);
kopiert wird von `AmsPluginApply.exe`, das neben diesem Plugin liegt. Eine
Datei, die AMS gerade benutzt, wird beiseite geschoben statt überschrieben –
AMS arbeitet bis zum Neustart mit der alten Fassung weiter.
