@echo off
rem ===========================================================================
rem  AmsApi bauen: Bibliothek pruefen, Beispiel-Plugins uebersetzen, Tests.
rem
rem  32-Bit ist PFLICHT (-Pi386): AMS.5 ist eine x86-Anwendung. Eine
rem  64-Bit-BPL laesst sich vom Host gar nicht erst laden.
rem
rem    build.cmd            alles bauen
rem    build.cmd HelloButton   nur dieses Beispiel
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
exit /b 0

:fail
echo.
echo FEHLGESCHLAGEN.
exit /b 1
