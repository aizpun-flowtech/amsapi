@echo off
rem ===========================================================================
rem  Holt den DOOM-Kern (doomgeneric, GPLv2) nach native\doomgeneric.
rem  Wird NICHT mit eingecheckt, wenn man es lieber frisch zieht - die hier
rem  eingecheckte Fassung enthaelt aber bereits die Patches (siehe README):
rem    * i_system.c  - Sicherheits-Patch (I_Error -> longjmp statt exit)
rem    * i_sound.c / i_sound.h - registriert unter DG_AMS_SOUND das eigene
rem      Sound-Backend (dg_sound.c) als DG_sound_module / DG_music_module.
rem  Ein frischer Clone braucht alle drei erneut.
rem ===========================================================================
cd /d "%~dp0"
if exist "doomgeneric\doomgeneric\doomgeneric.c" (
  echo doomgeneric ist bereits vorhanden.
  exit /b 0
)
git clone --depth 1 https://github.com/ozkl/doomgeneric doomgeneric
if errorlevel 1 (
  echo FEHLER: git clone fehlgeschlagen.
  exit /b 1
)
echo.
echo OK - doomgeneric geholt. ACHTUNG: bei einem frischen Clone muessen die
echo      Patches erneut angewandt werden (siehe README):
echo        - i_system.c            (I_Error -^> longjmp statt exit)
echo        - i_sound.c / i_sound.h (DG_AMS_SOUND: eigenes Sound-Backend)
exit /b 0
