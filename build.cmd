@echo off
rem ===========================================================================
rem  AmsApi bauen: Bibliothek pruefen, Beispiel-Plugins uebersetzen, Tests.
rem
rem  32-Bit ist PFLICHT (-Pi386): AMS.5 ist eine x86-Anwendung. Eine
rem  64-Bit-BPL laesst sich vom Host gar nicht erst laden.
rem
rem    build.cmd            alles bauen
rem    build.cmd HelloButton   nur dieses Beispiel
rem
rem  Ergebnis: build\deploy\<Name>\ (zum Kopieren nach BIN\plugins) und
rem  build\release\<Name>.zip + .ini (Release-Assets fuer den Plugin Manager)
rem ===========================================================================
setlocal enabledelayedexpansion

set PPC=C:\FPC\3.2.2\bin\i386-Win32\ppc386.exe
if not exist "%PPC%" (
  echo FEHLER: Free Pascal nicht unter "%PPC%" gefunden.
  echo         Pfad in build.cmd anpassen oder FPC 3.2.2 i386 installieren.
  exit /b 1
)

set ROOT=%~dp0
set SRC=%ROOT%src
set OUT=%ROOT%build
rem -O2 optimieren, -Xs Symbole strippen, -gl fuer Zeilennummern weglassen
set OPT=-Twin32 -Pi386 -Mdelphi -O2 -Xs -vw -Fu"%SRC%" -FU"%OUT%"

if not exist "%OUT%" mkdir "%OUT%"

if not "%~1"=="" goto :one

rem ---------------------------------------------------------------- Bibliothek
echo [1/4] Bibliothek uebersetzen
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\compileall.lpr"
if errorlevel 1 goto :fail
rem  Werkzeug fuer die Release-Assets (siehe :build)
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tools\mkrelease.lpr"
if errorlevel 1 goto :fail

rem --------------------------------------------------------------------- Tests
echo [2/4] Tests uebersetzen und ausfuehren
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\unittests.lpr"
if errorlevel 1 goto :fail
"%OUT%\unittests.exe"
if errorlevel 1 goto :fail

"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\hosttest.lpr"
if errorlevel 1 goto :fail

rem  Rauchtest des Suchfensters aus samples\UiTweaks - reines Win32, laeuft
rem  ohne AMS. Das Fenster bleibt dabei versteckt und ausserhalb des Bildes.
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\finderdemo.lpr"
if errorlevel 1 goto :fail
"%OUT%\finderdemo.exe"
if errorlevel 1 goto :fail

rem  Rauchtest des Verlaufsfensters aus AmsApi.TraceWindow - ebenfalls
rem  reines Win32 und ohne AMS lauffaehig. Auch dieses Fenster bleibt
rem  versteckt und ausserhalb des Bildes.
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\tracewindemo.lpr"
if errorlevel 1 goto :fail
"%OUT%\tracewindemo.exe"
if errorlevel 1 goto :fail

rem  Rauchtest der DOOM-Engine, des Bildpuffer-Fensters und des WAD-Lesers
rem  aus samples\Doom - WAD-Parser gegen ein erzeugtes IWAD, ein gerendertes
rem  Bild nach %TEMP% und ein versteckt laufendes Spielfenster. Ohne AMS.
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\doomdemo.lpr"
if errorlevel 1 goto :fail
"%OUT%\doomdemo.exe"
if errorlevel 1 goto :fail

rem  Rauchtest der eingebetteten HTML-Ansicht (README im Plugin Manager):
rem  IE-Control ueber atl.dll, sonst Ersatz-Textfeld. Ohne AMS, versteckt.
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\browserdemo.lpr"
if errorlevel 1 goto :fail
"%OUT%\browserdemo.exe"
if errorlevel 1 goto :fail

rem  Rauchtest des Plugin Managers: Katalog auf einem lokalen "Server",
rem  installieren, aktualisieren (bei geladener BPL), entfernen, Einstellungen,
rem  dazu der UAC-/Neustart-Helfer als eigener Prozess. Ohne AMS, ohne Netz.
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%samples\PluginManager\AmsPluginApply.lpr"
if errorlevel 1 goto :fail
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\pluginmgrdemo.lpr"
if errorlevel 1 goto :fail
"%OUT%\pluginmgrdemo.exe"
if errorlevel 1 goto :fail

rem ------------------------------------------- RTTI gegen die Host-Packages
rem  Prueft die Offsets von TTypeInfo/TPropInfo an echten Typinformationen.
rem  Ohne installiertes AMS ueberspringt das Programm sich selbst (Code 0).
echo [3/4] RTTI-Probe
"%PPC%" %OPT% -FE"%OUT%" "%ROOT%tests\rttiprobe.lpr"
if errorlevel 1 goto :fail
"%OUT%\rttiprobe.exe"
if errorlevel 1 goto :fail

rem ------------------------------------------------------------------ Beispiele
echo [4/4] Beispiel-Plugins bauen
for /d %%D in ("%ROOT%samples\*") do (
  call :build "%%~nxD"
  if errorlevel 1 goto :fail
)
echo.
echo OK - alles gebaut. Ergebnisse in %OUT%\deploy\
goto :eof

:one
call :build "%~1"
if errorlevel 1 goto :fail
echo OK - %~1 gebaut.
goto :eof

rem --------------------------------------------------------------------------
:build
set NAME=%~1
set DIR=%ROOT%samples\%NAME%
if not exist "%DIR%\%NAME%.lpr" (
  echo FEHLER: %DIR%\%NAME%.lpr nicht gefunden.
  exit /b 1
)
set DEPLOY=%OUT%\deploy\%NAME%
if not exist "%DEPLOY%" mkdir "%DEPLOY%"
echo   - %NAME%
"%PPC%" %OPT% -FE"%DIR%" -o"%DEPLOY%\%NAME%.bpl" "%DIR%\%NAME%.lpr"
if errorlevel 1 exit /b 1
copy /Y "%DIR%\plugin.ini" "%DEPLOY%\plugin.ini" >nul
if exist "%DIR%\icon32.png" copy /Y "%DIR%\icon32.png" "%DEPLOY%\" >nul
if exist "%DIR%\icon16.png" copy /Y "%DIR%\icon16.png" "%DEPLOY%\" >nul
rem  Die README zeigt der Plugin Manager auch ohne Netz an
if exist "%DIR%\README.md" copy /Y "%DIR%\README.md" "%DEPLOY%\" >nul
rem  Der Plugin Manager bringt seinen UAC-/Neustart-Helfer mit
if /I "%NAME%"=="PluginManager" (
  "%PPC%" %OPT% -FE"%DEPLOY%" "%DIR%\AmsPluginApply.lpr"
  if errorlevel 1 exit /b 1
)
rem  Doom bringt zusaetzlich den echten DOOM-Kern mit, falls schon gebaut
rem  (native\build_doomcore.bat). Ohne DLL laeuft das Plugin mit der
rem  Ersatz-Engine, deshalb ist das kein Fehler.
if /I "%NAME%"=="Doom" if exist "%ROOT%native\doomcore.dll" copy /Y "%ROOT%native\doomcore.dll" "%DEPLOY%\" >nul
rem  Release-Assets fuer den Plugin Manager: <Name>.zip + <Name>.ini
rem  (hochladen: gh release create vX.Y.Z build\release\*)
if not exist "%OUT%\mkrelease.exe" "%PPC%" %OPT% -FE"%OUT%" "%ROOT%tools\mkrelease.lpr" >nul
if exist "%OUT%\mkrelease.exe" "%OUT%\mkrelease.exe" "%DEPLOY%" "%OUT%\release" "%NAME%"
exit /b 0

:fail
echo.
echo FEHLGESCHLAGEN.
exit /b 1
