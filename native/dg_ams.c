/* ===========================================================================
   dg_ams.c - Plattform- und Export-Schicht fuer doomgeneric als doomcore.dll

   doomgeneric ist der echte DOOM-Kern (auf Chocolate Doom / linuxdoom-Basis,
   GPLv2). Er verlangt eine Handvoll Plattformfunktionen (DG_*) und wird ueber
   doomgeneric_Create() + wiederholtes doomgeneric_Tick() betrieben. Diese
   Datei liefert diese Funktionen ohne eigenes Fenster - das Bild bleibt in
   DG_ScreenBuffer (640x400, 32 Bit, top-down BGRA), das die Pascal-Seite
   (AmsApi.DoomCore) ausliest und in AMS praesentiert.

   Exportiert eine schlanke C-API (siehe doomcore.def), die das FPC-Plugin per
   LoadLibrary/GetProcAddress benutzt. So gibt es KEINE Objekt-/CRT-Vermischung
   zwischen MSVC und FPC - die DLL ist ein normales Win32-Modul mit statischer
   CRT (/MT).

   Sicherheit: doomgeneric beendet bei einem fatalen Fehler (I_Error) sonst den
   Prozess per exit(). Das wuerde AMS mitreissen. Deshalb ist i_system.c minimal
   gepatcht (siehe README): ein fataler Fehler springt per longjmp hierher
   zurueck, wir merken "tot" und lassen den Host weiterlaufen.
   =========================================================================== */

#include "doomkeys.h"
#include "doomgeneric.h"

#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include <setjmp.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* Vom i_system.c-Patch benutzt. */
jmp_buf dg_error_jmp;
int     dg_error_active = 0;

/* Sound-Backend (dg_sound.c): stoppt Feeder-Thread und schliesst die Audio-
   Geraete deterministisch. Muss laufen, BEVOR die Pascal-Seite die DLL per
   FreeLibrary entlaedt - sonst liefe der Mixer-Thread in entladenen Code. */
extern void DG_ShutdownAudio(void);

static int  s_started = 0;
static int  s_dead = 0;
static char s_title[256] = "DOOM";
static char s_savedir[512] = "";

/* Wird von I_Quit gesetzt (Patch in i_system.c), wenn der Spieler DOOM ueber
   das Menue beendet ("press Y to quit"). Da wir den Prozess nicht beenden
   duerfen (das ist AMS!), meldet die Shim das der Pascal-Seite, die dann die
   eingebettete Flaeche schliesst. */
int dg_quit_requested = 0;

__declspec(dllexport) int dg_wants_quit(void)
{
    return dg_quit_requested;
}

/* Beschreibbares Verzeichnis fuer Konfiguration und Spielstaende. Von der
   Pascal-Seite VOR dg_start gesetzt (dg_set_savedir), von m_config.c gelesen
   (dg_get_savedir). Ohne das schreibt DOOM ins Programmverzeichnis von AMS,
   wo es nicht speichern darf. */
__declspec(dllexport) void dg_set_savedir(const char* dir)
{
    if (dir)
    {
        strncpy(s_savedir, dir, sizeof(s_savedir) - 1);
        s_savedir[sizeof(s_savedir) - 1] = 0;
    }
    else
        s_savedir[0] = 0;
}

const char* dg_get_savedir(void)
{
    return s_savedir;
}

/* --------------------------------------------------- Tasten-Warteschlange ---
   Uebernommen aus doomgeneric_win.c (gleiches Projekt). Die Pascal-Seite
   schickt Windows-VK-Codes; hier werden sie in DOOM-Tasten uebersetzt. */

#define KEYQUEUE_SIZE 64
static unsigned short s_KeyQueue[KEYQUEUE_SIZE];
static unsigned int s_KeyQueueWriteIndex = 0;
static unsigned int s_KeyQueueReadIndex = 0;

static unsigned char convertToDoomKey(unsigned char key)
{
    switch (key)
    {
    case VK_RETURN:  key = KEY_ENTER;      break;
    case VK_ESCAPE:  key = KEY_ESCAPE;     break;
    case VK_LEFT:    key = KEY_LEFTARROW;  break;
    case VK_RIGHT:   key = KEY_RIGHTARROW; break;
    case VK_UP:      key = KEY_UPARROW;    break;
    case VK_DOWN:    key = KEY_DOWNARROW;  break;
    case VK_CONTROL: key = KEY_FIRE;       break;
    case VK_SPACE:   key = KEY_USE;        break;
    case VK_SHIFT:   key = KEY_RSHIFT;     break;
    case VK_TAB:     key = KEY_TAB;        break;
    case VK_MENU:    key = KEY_LALT;       break;
    default:         key = (unsigned char)tolower(key); break;
    }
    return key;
}

static void addKeyToQueue(int pressed, unsigned char keyCode)
{
    unsigned char key = convertToDoomKey(keyCode);
    unsigned short keyData = (unsigned short)((pressed << 8) | key);
    s_KeyQueue[s_KeyQueueWriteIndex] = keyData;
    s_KeyQueueWriteIndex = (s_KeyQueueWriteIndex + 1) % KEYQUEUE_SIZE;
}

/* ------------------------------------------------ Plattform fuer doomgeneric */

void DG_Init(void)
{
    memset(s_KeyQueue, 0, sizeof(s_KeyQueue));
    s_KeyQueueReadIndex = 0;
    s_KeyQueueWriteIndex = 0;
}

void DG_DrawFrame(void)
{
    /* Nichts. Nach doomgeneric_Tick() steht das Bild in DG_ScreenBuffer;
       die Pascal-Seite blittet es. */
}

void DG_SleepMs(uint32_t ms)
{
    /* Im eingebetteten Betrieb NICHT schlafen - der Takt kommt vom Timer der
       Pascal-Seite. Ein Sleep hier wuerde den AMS-UI-Thread blockieren. */
    (void)ms;
}

uint32_t DG_GetTicksMs(void)
{
    return (uint32_t)GetTickCount();
}

int DG_GetKey(int* pressed, unsigned char* doomKey)
{
    if (s_KeyQueueReadIndex == s_KeyQueueWriteIndex)
        return 0;
    {
        unsigned short keyData = s_KeyQueue[s_KeyQueueReadIndex];
        s_KeyQueueReadIndex = (s_KeyQueueReadIndex + 1) % KEYQUEUE_SIZE;
        *pressed = keyData >> 8;
        *doomKey = keyData & 0xFF;
    }
    return 1;
}

void DG_SetWindowTitle(const char* title)
{
    if (title)
    {
        strncpy(s_title, title, sizeof(s_title) - 1);
        s_title[sizeof(s_title) - 1] = 0;
    }
}

/* --------------------------------------------------------------- Export-API */

static char  s_wad[1024];
static char  s_extra[512];
static char* s_argv[16];

/* Startet DOOM mit dem angegebenen WAD (IWAD). AExtra sind optionale, per
   Leerzeichen getrennte zusaetzliche Kommandozeilen-Parameter (z.B. "-warp 1").
   Result 1 = laeuft, 0 = fataler Fehler beim Start (Host bleibt am Leben). */
__declspec(dllexport) int dg_start(const char* wad, const char* extra)
{
    int argc = 0;
    char* p;

    if (s_started && !s_dead)
        return 1;

    strncpy(s_wad, wad ? wad : "", sizeof(s_wad) - 1);
    s_wad[sizeof(s_wad) - 1] = 0;

    s_argv[argc++] = "doomcore";
    s_argv[argc++] = "-iwad";
    s_argv[argc++] = s_wad;
    s_argv[argc++] = "-nogui";      /* keine modale Fehler-Dialogbox in AMS */

    /* zusaetzliche Parameter zerlegen */
    if (extra && *extra)
    {
        strncpy(s_extra, extra, sizeof(s_extra) - 1);
        s_extra[sizeof(s_extra) - 1] = 0;
        p = strtok(s_extra, " ");
        while (p && argc < 15)
        {
            s_argv[argc++] = p;
            p = strtok(NULL, " ");
        }
    }

    dg_quit_requested = 0;
    dg_error_active = 1;
    if (setjmp(dg_error_jmp))
    {
        s_dead = 1;
        dg_error_active = 0;
        return 0;
    }
    doomgeneric_Create(argc, s_argv);
    dg_error_active = 0;
    s_started = 1;
    s_dead = 0;
    return 1;
}

/* Ein Bildschritt. Result 0, wenn (noch) nicht gestartet oder tot. */
__declspec(dllexport) int dg_tick(void)
{
    if (!s_started || s_dead)
        return 0;
    dg_error_active = 1;
    if (setjmp(dg_error_jmp))
    {
        s_dead = 1;
        dg_error_active = 0;
        return 0;
    }
    doomgeneric_Tick();
    dg_error_active = 0;
    return 1;
}

/* Zeiger auf das aktuelle Bild (640x400, 32 Bit, top-down BGRA). */
__declspec(dllexport) void* dg_framebuffer(int* w, int* h)
{
    if (w) *w = DOOMGENERIC_RESX;
    if (h) *h = DOOMGENERIC_RESY;
    return (void*)DG_ScreenBuffer;
}

/* Tastendruck (pressed=1) / -loslassen (pressed=0), vk = Windows-VK-Code. */
__declspec(dllexport) void dg_key(int pressed, int vk)
{
    addKeyToQueue(pressed, (unsigned char)vk);
}

__declspec(dllexport) int dg_alive(void)
{
    return s_started && !s_dead;
}

/* Audio herunterfahren (Thread stoppen, waveOut/MCI schliessen). Von der
   Pascal-Seite VOR FreeLibrary aufgerufen. Idempotent - mehrfach aufrufbar,
   auch wenn Sound nie initialisiert wurde. */
__declspec(dllexport) void dg_shutdown(void)
{
    DG_ShutdownAudio();
}

__declspec(dllexport) const char* dg_title(void)
{
    return s_title;
}
