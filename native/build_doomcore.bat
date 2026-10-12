@echo off
rem ===========================================================================
rem  doomcore.dll bauen - der echte DOOM-Kern (doomgeneric, GPLv2) als 32-Bit-
rem  DLL fuer das AMS-Plugin. Braucht Visual Studio (cl.exe). 32 Bit ist
rem  Pflicht: AMS ist x86, laedt nur eine 32-Bit-DLL.
rem
rem  Ergebnis: native\doomcore.dll  (wird nach build\deploy\Doom\ kopiert)
rem ===========================================================================
setlocal enabledelayedexpansion

set VCVARS="C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars32.bat"
if not exist %VCVARS% set VCVARS="C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat"
if not exist %VCVARS% (
  echo FEHLER: vcvars32.bat nicht gefunden. Visual Studio mit C++ noetig.
  echo         Pfad oben in build_doomcore.bat anpassen.
  exit /b 1
)

call %VCVARS% >nul
cd /d "%~dp0"

set DG=doomgeneric\doomgeneric
if not exist "%DG%\doomgeneric.c" (
  echo FEHLER: doomgeneric-Quellen fehlen unter %DG%.
  echo         git clone --depth 1 https://github.com/ozkl/doomgeneric native\doomgeneric
  exit /b 1
)

rem Die Dateiliste stammt aus doomgeneric.vcxproj - OHNE doomgeneric_win.c
rem (dessen Rolle uebernimmt dg_ams.c).
set FILES=am_map d_event d_items d_iwad d_loop d_main d_mode d_net doomdef doomgeneric doomstat dstrings dummy f_finale f_wipe g_game gusconf hu_lib hu_stuff i_cdmus i_endoom i_input i_joystick i_scale i_sound i_system i_timer i_video icon info m_argv m_bbox m_cheat m_config m_controls m_fixed m_menu m_misc m_random memio mus2mid p_ceilng p_doors p_enemy p_floor p_inter p_lights p_map p_maputl p_mobj p_plats p_pspr p_saveg p_setup p_sight p_spec p_switch p_telept p_tick p_user r_bsp r_data r_draw r_main r_plane r_segs r_sky r_things s_sound sha1 sounds st_lib st_stuff statdump tables v_video w_checksum w_file w_file_stdc w_main w_wad wi_stuff z_zone

if not exist obj mkdir obj

set SRC=
for %%F in (%FILES%) do set SRC=!SRC! "%DG%\%%F.c"

rem  DG_AMS_SOUND schaltet in i_sound.c unser eigenes Sound-Backend frei
rem  (dg_sound.c: waveOut-SFX + MCI-Musik). FEATURE_SOUND bleibt AUS, damit
rem  i_sound.c NICHT <SDL_mixer.h> einbindet. winmm.lib fuer waveOut/MCI.
echo Uebersetze doomcore.dll (das kann einen Moment dauern) ...
cl /nologo /O2 /MT /D_CRT_SECURE_NO_WARNINGS /DWIN32 /DNDEBUG /D_CONSOLE ^
   /DDG_AMS_SOUND ^
   /I"%DG%" /Fo".\obj\\" dg_ams.c dg_sound.c !SRC! ^
   /link /DLL /OUT:doomcore.dll user32.lib winmm.lib
if errorlevel 1 (
  echo.
  echo doomcore.dll FEHLGESCHLAGEN.
  exit /b 1
)

echo.
echo OK - native\doomcore.dll gebaut.
exit /b 0
