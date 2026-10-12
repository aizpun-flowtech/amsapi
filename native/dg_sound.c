/* ===========================================================================
   dg_sound.c - Sound-Backend fuer doomcore.dll (SFX + Musik) OHNE SDL

   doomgeneric selbst hat KEINE Tonausgabe: sein i_sound.c kennt nur zwei
   Sound-/Musik-Module (SDL_mixer bzw. Allegro), beide hinter FEATURE_SOUND,
   das im eingebetteten Build aus ist - deshalb war DOOM im AMS-Plugin stumm.
   Wir wollen aber keine SDL-/Allegro-Abhaengigkeit in die DLL ziehen.

   Diese Datei liefert stattdessen ein eigenes, self-contained Backend, das nur
   die Windows-Multimedia-API (winmm) benutzt - statisch verfuegbar, keine
   Fremd-DLL:

     * SFX  -> eigener Software-Mixer auf waveOut. Die DS*-Lumps (8-Bit-PCM
              mono, meist 11025 Hz) werden beim ersten Abspielen einmalig auf
              die Ausgabe-Rate (snd_samplerate, 16 Bit mono) resampled und
              gecached. Ein Feeder-Thread mischt bis zu DG_NUM_CHANNELS Kanaele
              (Lautstaerke + Panning) in doppelt gepufferte waveOut-Bloecke.

     * Musik -> die MUS-/MIDI-Lumps werden per mus2mid (doomgeneric-eigener
              Konverter) nach MIDI gewandelt, in eine Temp-Datei geschrieben und
              ueber den MCI-Sequencer (MIDI-Mapper) abgespielt. Looping laeuft
              ueber Poll(), das der Kern jeden Tic aufruft.

   Registriert wird das Ganze in i_sound.c als DG_sound_module / DG_music_module
   unter dem Build-Schalter DG_AMS_SOUND (siehe build_doomcore.bat). FEATURE_SOUND
   bleibt bewusst AUS, damit i_sound.c NICHT <SDL_mixer.h> einbindet.

   Robustheit: Jeder Init-/Geraetefehler fuehrt nur zu Stille, nie zu einem
   Absturz des Hosts (AMS). DG_ShutdownAudio() stoppt Thread und Geraete
   deterministisch und ist idempotent; dg_ams.c ruft es ueber den Export
   dg_shutdown() auf, BEVOR die Pascal-Seite die DLL entlaedt.
   =========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* DOOM-Header zuerst: hier ist boolean == unsigned int (doomtype.h via
   <stdbool.h>). Die Windows-Header definieren ihr eigenes boolean (unsigned
   char, in rpcndr.h) - das kollidiert. Deshalb Windows' boolean beim Einbinden
   umbenennen und danach wieder freigeben. */
#include "doomtype.h"
#include "i_sound.h"
#include "w_wad.h"
#include "z_zone.h"
#include "m_misc.h"
#include "memio.h"
#include "mus2mid.h"

#define boolean win_boolean
#include <windows.h>
#include <mmsystem.h>
#undef boolean

#define arrlen(x) ((int)(sizeof(x) / sizeof(*(x))))

/* --------------------------------------------------------------- Konfiguration */

#define DG_NUM_CHANNELS 16   /* obere Grenze; der Kern nutzt snd_channels (8) */
#define DG_WAVE_BUFFERS 6    /* waveOut-Bloecke (~70 ms Puffer bei 512/44100)  */
#define DG_WAVE_FRAMES  512  /* Frames (Stereo) je Block                        */

/* snd_samplerate lebt in i_sound.c (Default 44100) und ist in i_sound.h als
   extern deklariert. */

/* ------------------------------------------------------ SFX: gecachte Samples */

/* Einmalig auf die Ausgaberate resampeltes SFX (mono, 16 Bit). */
typedef struct dg_sfx_s
{
    struct dg_sfx_s *next;    /* Liste aller Allokationen, fuer Shutdown */
    sfxinfo_t       *owner;   /* zum Zuruecksetzen von owner->driver_data */
    unsigned int     numsamples;
    short            samples[1]; /* flexibel: [numsamples]                 */
} dg_sfx_t;

typedef struct
{
    int          active;
    dg_sfx_t    *snd;
    unsigned int pos;      /* Sample-Index in snd->samples */
    int          leftvol;  /* 0..255 */
    int          rightvol; /* 0..255 */
    sfxinfo_t   *sfxinfo;
} dg_chan_t;

static int              s_sfx_ready = 0;
static int              s_cs_init   = 0;
static int              s_use_prefix = 1;
static int              s_freq = 44100;

static HWAVEOUT         s_hwo = NULL;
static WAVEHDR          s_hdr[DG_WAVE_BUFFERS];
static short           *s_buf[DG_WAVE_BUFFERS];
static HANDLE           s_bufevent  = NULL;  /* waveOut CALLBACK_EVENT   */
static HANDLE           s_stopevent = NULL;  /* Feeder-Thread beenden    */
static HANDLE           s_thread    = NULL;
static CRITICAL_SECTION s_cs;                /* schuetzt s_chan[]        */
static dg_chan_t        s_chan[DG_NUM_CHANNELS];
static dg_sfx_t        *s_sfx_head = NULL;   /* Cache-Liste              */
static int              s_acc[DG_WAVE_FRAMES * 2]; /* Mix-Akkumulator (nur Feeder) */

/* --------------------------------------------------------------- SFX: Helfer */

static void DG_SfxName(sfxinfo_t *sfx, char *buf, size_t n)
{
    if (sfx->link != NULL)
        sfx = sfx->link;

    /* DOOM stellt den Lumps ein "ds" voran (use_sfx_prefix). DEHACKED ist im
       Build aus, deshalb der rohe Name ohne DEH_String. */
    if (s_use_prefix)
        M_snprintf(buf, n, "ds%s", sfx->name);
    else
        M_StringCopy(buf, sfx->name, n);
}

/* Laedt einen DS*-Lump, resampled ihn auf s_freq (16 Bit mono) und haengt das
   Ergebnis an die Cache-Liste. Result: gecachtes SFX oder NULL. */
static dg_sfx_t *DG_CacheSFX(sfxinfo_t *sfx)
{
    char          name[16];
    int           lumpnum, lumplen, srcrate, srclen;
    byte         *data, *src;
    dg_sfx_t     *snd;
    unsigned int  numout, i;

    if (sfx->driver_data != NULL)
        return (dg_sfx_t *)sfx->driver_data;

    DG_SfxName(sfx, name, sizeof(name));
    lumpnum = W_CheckNumForName(name);
    if (lumpnum < 0)
        return NULL;

    data = (byte *)W_CacheLumpNum(lumpnum, PU_STATIC);
    lumplen = W_LumpLength(lumpnum);
    if (data == NULL || lumplen < 8 || data[0] != 0x03 || data[1] != 0x00)
    {
        W_ReleaseLumpNum(lumpnum);
        return NULL;
    }

    /* Header: [0..1]=Format(0x0003), [2..3]=Samplerate LE, [4..7]=Laenge LE. */
    srcrate = (data[3] << 8) | data[2];
    srclen  = (data[7] << 24) | (data[6] << 16) | (data[5] << 8) | data[4];
    if (srclen > lumplen - 8 || srclen <= 48 || srcrate <= 0)
    {
        W_ReleaseLumpNum(lumpnum);
        return NULL;
    }

    /* Die DMX-Lib ueberspringt je 16 Bytes am Anfang und Ende der Samples. */
    src = data + 24;      /* 8 Header + 16 Pad */
    srclen -= 32;
    if (srclen <= 0)
    {
        W_ReleaseLumpNum(lumpnum);
        return NULL;
    }

    numout = (unsigned int)(((unsigned __int64)srclen * (unsigned int)s_freq)
                            / (unsigned int)srcrate);
    if (numout == 0)
        numout = 1;

    snd = (dg_sfx_t *)malloc(sizeof(dg_sfx_t) + (size_t)(numout - 1) * sizeof(short));
    if (snd == NULL)
    {
        W_ReleaseLumpNum(lumpnum);
        return NULL;
    }

    snd->numsamples = numout;
    for (i = 0; i < numout; ++i)
    {
        unsigned int si = (unsigned int)(((unsigned __int64)i * (unsigned int)srclen)
                                         / numout);
        int s8 = src[si];                  /* 0..255 (unsigned 8 Bit) */
        snd->samples[i] = (short)((s8 - 128) << 8);
    }

    W_ReleaseLumpNum(lumpnum);

    snd->owner = sfx;
    snd->next = s_sfx_head;
    s_sfx_head = snd;
    sfx->driver_data = snd;
    return snd;
}

/* Mischt frames Stereo-Frames aus allen aktiven Kanaelen nach dst. Laeuft nur
   im Feeder-Thread. */
static void DG_MixBuffer(short *dst, int frames)
{
    int c, f, i;
    int n2 = frames * 2;

    for (i = 0; i < n2; ++i)
        s_acc[i] = 0;

    EnterCriticalSection(&s_cs);
    for (c = 0; c < DG_NUM_CHANNELS; ++c)
    {
        dg_chan_t   *ch = &s_chan[c];
        dg_sfx_t    *snd;
        short       *sp;
        unsigned int pos, n;
        int          lv, rv;

        if (!ch->active || ch->snd == NULL)
            continue;

        snd = ch->snd;
        sp  = snd->samples;
        pos = ch->pos;
        n   = snd->numsamples;
        lv  = ch->leftvol;
        rv  = ch->rightvol;

        for (f = 0; f < frames; ++f)
        {
            int s;
            if (pos >= n)
            {
                ch->active = 0;
                break;
            }
            s = sp[pos++];
            s_acc[f * 2]     += (s * lv) >> 8;
            s_acc[f * 2 + 1] += (s * rv) >> 8;
        }
        ch->pos = pos;
    }
    LeaveCriticalSection(&s_cs);

    for (i = 0; i < n2; ++i)
    {
        int v = s_acc[i];
        if (v > 32767)       v = 32767;
        else if (v < -32768) v = -32768;
        dst[i] = (short)v;
    }
}

static DWORD WINAPI DG_SfxThread(LPVOID param)
{
    HANDLE evs[2];
    int b;

    (void)param;
    evs[0] = s_stopevent;
    evs[1] = s_bufevent;

    for (;;)
    {
        for (b = 0; b < DG_WAVE_BUFFERS; ++b)
        {
            if (s_hdr[b].dwFlags & WHDR_DONE)
            {
                s_hdr[b].dwFlags &= ~WHDR_DONE;
                DG_MixBuffer((short *)s_hdr[b].lpData, DG_WAVE_FRAMES);
                waveOutWrite(s_hwo, &s_hdr[b], sizeof(WAVEHDR));
            }
        }

        if (WaitForMultipleObjects(2, evs, FALSE, 5) == WAIT_OBJECT_0)
            break; /* stop */
    }
    return 0;
}

/* Stoppt SFX vollstaendig und gibt alle Ressourcen frei. Idempotent. */
static void DG_ShutdownSfx(void)
{
    int b;
    dg_sfx_t *p;

    if (s_stopevent != NULL)
        SetEvent(s_stopevent);

    if (s_thread != NULL)
    {
        WaitForSingleObject(s_thread, INFINITE);
        CloseHandle(s_thread);
        s_thread = NULL;
    }

    if (s_hwo != NULL)
    {
        waveOutReset(s_hwo);
        for (b = 0; b < DG_WAVE_BUFFERS; ++b)
        {
            if (s_hdr[b].dwFlags & WHDR_PREPARED)
                waveOutUnprepareHeader(s_hwo, &s_hdr[b], sizeof(WAVEHDR));
        }
        waveOutClose(s_hwo);
        s_hwo = NULL;
    }

    for (b = 0; b < DG_WAVE_BUFFERS; ++b)
    {
        if (s_buf[b] != NULL)
        {
            free(s_buf[b]);
            s_buf[b] = NULL;
        }
    }
    memset(s_hdr, 0, sizeof(s_hdr));

    if (s_bufevent != NULL)  { CloseHandle(s_bufevent);  s_bufevent = NULL; }
    if (s_stopevent != NULL) { CloseHandle(s_stopevent); s_stopevent = NULL; }

    /* Gecachte SFX freigeben und driver_data zuruecksetzen. Sicher, weil der
       Feeder-Thread hier bereits beendet ist. */
    p = s_sfx_head;
    while (p != NULL)
    {
        dg_sfx_t *nx = p->next;
        if (p->owner != NULL)
            p->owner->driver_data = NULL;
        free(p);
        p = nx;
    }
    s_sfx_head = NULL;

    if (s_cs_init)
    {
        DeleteCriticalSection(&s_cs);
        s_cs_init = 0;
    }
    s_sfx_ready = 0;
}

/* --------------------------------------------------- SFX: Modul-Schnittstelle */

static boolean I_DG_InitSound(boolean use_sfx_prefix)
{
    WAVEFORMATEX wfx;
    int b;

    if (s_sfx_ready)
        return 1;

    s_use_prefix = use_sfx_prefix ? 1 : 0;
    s_freq = snd_samplerate;
    if (s_freq < 8000 || s_freq > 48000)
        s_freq = 44100;

    memset(s_chan, 0, sizeof(s_chan));
    memset(s_hdr, 0, sizeof(s_hdr));
    for (b = 0; b < DG_WAVE_BUFFERS; ++b)
        s_buf[b] = NULL;

    InitializeCriticalSection(&s_cs);
    s_cs_init = 1;

    s_bufevent  = CreateEvent(NULL, FALSE, FALSE, NULL); /* auto-reset */
    s_stopevent = CreateEvent(NULL, TRUE,  FALSE, NULL); /* manual-reset */
    if (s_bufevent == NULL || s_stopevent == NULL)
        goto fail;

    ZeroMemory(&wfx, sizeof(wfx));
    wfx.wFormatTag      = WAVE_FORMAT_PCM;
    wfx.nChannels       = 2;
    wfx.nSamplesPerSec  = (DWORD)s_freq;
    wfx.wBitsPerSample  = 16;
    wfx.nBlockAlign     = 4;
    wfx.nAvgBytesPerSec = (DWORD)s_freq * 4;
    wfx.cbSize          = 0;

    if (waveOutOpen(&s_hwo, WAVE_MAPPER, &wfx, (DWORD_PTR)s_bufevent, 0,
                    CALLBACK_EVENT) != MMSYSERR_NOERROR)
    {
        s_hwo = NULL;
        goto fail;
    }

    for (b = 0; b < DG_WAVE_BUFFERS; ++b)
    {
        s_buf[b] = (short *)malloc(DG_WAVE_FRAMES * 2 * sizeof(short));
        if (s_buf[b] == NULL)
            goto fail;
        memset(&s_hdr[b], 0, sizeof(WAVEHDR));
        s_hdr[b].lpData         = (LPSTR)s_buf[b];
        s_hdr[b].dwBufferLength = DG_WAVE_FRAMES * 2 * sizeof(short);
        if (waveOutPrepareHeader(s_hwo, &s_hdr[b], sizeof(WAVEHDR)) != MMSYSERR_NOERROR)
            goto fail;
    }

    /* Alle Bloecke einmal fuellen (anfangs Stille) und in die Queue geben. */
    for (b = 0; b < DG_WAVE_BUFFERS; ++b)
    {
        DG_MixBuffer(s_buf[b], DG_WAVE_FRAMES);
        waveOutWrite(s_hwo, &s_hdr[b], sizeof(WAVEHDR));
    }

    s_sfx_ready = 1;
    s_thread = CreateThread(NULL, 0, DG_SfxThread, NULL, 0, NULL);
    if (s_thread == NULL)
    {
        s_sfx_ready = 0;
        goto fail;
    }

    return 1;

fail:
    DG_ShutdownSfx();
    return 0;
}

static void I_DG_ShutdownSound(void)
{
    DG_ShutdownSfx();
}

static int I_DG_GetSfxLumpNum(sfxinfo_t *sfx)
{
    char name[16];
    DG_SfxName(sfx, name, sizeof(name));
    return W_CheckNumForName(name); /* -1 wenn fehlt: Kern spielt dann nichts */
}

static void I_DG_Update(void)
{
    /* Nichts: das Mischen erledigt der Feeder-Thread. */
}

static void DG_VolSep(int vol, int sep, int *left, int *right)
{
    int l = ((254 - sep) * vol) / 127;
    int r = ((sep) * vol) / 127;
    if (l < 0) l = 0; else if (l > 255) l = 255;
    if (r < 0) r = 0; else if (r > 255) r = 255;
    *left = l;
    *right = r;
}

static void I_DG_UpdateSoundParams(int channel, int vol, int sep)
{
    int left, right;
    if (!s_sfx_ready || channel < 0 || channel >= DG_NUM_CHANNELS)
        return;
    DG_VolSep(vol, sep, &left, &right);
    EnterCriticalSection(&s_cs);
    s_chan[channel].leftvol  = left;
    s_chan[channel].rightvol = right;
    LeaveCriticalSection(&s_cs);
}

static int I_DG_StartSound(sfxinfo_t *sfx, int channel, int vol, int sep)
{
    dg_sfx_t *snd;
    int left, right;

    if (!s_sfx_ready || channel < 0 || channel >= DG_NUM_CHANNELS)
        return -1;

    snd = DG_CacheSFX(sfx);
    if (snd == NULL)
        return -1;

    DG_VolSep(vol, sep, &left, &right);

    EnterCriticalSection(&s_cs);
    s_chan[channel].snd      = snd;
    s_chan[channel].pos      = 0;
    s_chan[channel].leftvol  = left;
    s_chan[channel].rightvol = right;
    s_chan[channel].sfxinfo  = sfx;
    s_chan[channel].active   = 1;
    LeaveCriticalSection(&s_cs);

    return channel;
}

static void I_DG_StopSound(int channel)
{
    if (!s_sfx_ready || channel < 0 || channel >= DG_NUM_CHANNELS)
        return;
    EnterCriticalSection(&s_cs);
    s_chan[channel].active = 0;
    LeaveCriticalSection(&s_cs);
}

static boolean I_DG_SoundIsPlaying(int channel)
{
    if (!s_sfx_ready || channel < 0 || channel >= DG_NUM_CHANNELS)
        return 0;
    return s_chan[channel].active ? 1 : 0;
}

/* ========================================================================== */
/*  Musik ueber den MCI-Sequencer (MUS/MIDI -> Temp-.mid -> MIDI-Mapper)      */
/* ========================================================================== */

typedef struct
{
    char path[MAX_PATH];
} dg_song_t;

static int      s_music_ready   = 0;
static char     s_alias[32]     = "";   /* offener MCI-Alias, "" = keiner  */
static int      s_music_loop    = 0;
static int      s_music_playing = 0;
static int      s_music_vol     = 127;  /* 0..127 */
static char     s_cur_path[MAX_PATH] = "";
static unsigned s_counter = 0;

static void DG_MciClose(void)
{
    if (s_alias[0] != 0)
    {
        char cmd[64];
        M_snprintf(cmd, sizeof(cmd), "close %s", s_alias);
        mciSendStringA(cmd, NULL, 0, NULL);
        s_alias[0] = 0;
    }
    s_music_playing = 0;
}

static void DG_ShutdownMusic(void)
{
    DG_MciClose();
    if (s_cur_path[0] != 0)
    {
        remove(s_cur_path);
        s_cur_path[0] = 0;
    }
    s_music_ready = 0;
}

static boolean I_DG_InitMusic(void)
{
    s_music_ready = 1;
    return 1;
}

static void I_DG_ShutdownMusic(void)
{
    DG_ShutdownMusic();
}

static void I_DG_SetMusicVolume(int volume)
{
    s_music_vol = volume;
    if (s_alias[0] != 0)
    {
        char cmd[64];
        int n = (volume * 1000) / 127;
        if (n < 0) n = 0; else if (n > 1000) n = 1000;
        /* Nicht jedes Sequencer-Geraet unterstuetzt das - Fehler ignorieren. */
        M_snprintf(cmd, sizeof(cmd), "setaudio %s volume to %d", s_alias, n);
        mciSendStringA(cmd, NULL, 0, NULL);
    }
}

static void I_DG_PauseMusic(void)
{
    if (s_alias[0] != 0)
    {
        char cmd[64];
        M_snprintf(cmd, sizeof(cmd), "pause %s", s_alias);
        mciSendStringA(cmd, NULL, 0, NULL);
    }
}

static void I_DG_ResumeMusic(void)
{
    if (s_alias[0] != 0)
    {
        char cmd[64];
        M_snprintf(cmd, sizeof(cmd), "resume %s", s_alias);
        if (mciSendStringA(cmd, NULL, 0, NULL) != 0)
        {
            M_snprintf(cmd, sizeof(cmd), "play %s", s_alias);
            mciSendStringA(cmd, NULL, 0, NULL);
        }
    }
}

/* Wandelt MUS nach MIDI (bzw. uebernimmt vorhandenes MIDI) in eine Temp-Datei
   und liefert ein Handle. */
static void *I_DG_RegisterSong(void *data, int len)
{
    dg_song_t *song;
    char       tmpdir[MAX_PATH];
    FILE      *f;

    if (!s_music_ready || data == NULL || len <= 4)
        return NULL;

    song = (dg_song_t *)malloc(sizeof(dg_song_t));
    if (song == NULL)
        return NULL;
    song->path[0] = 0;

    if (GetTempPathA(sizeof(tmpdir), tmpdir) == 0)
    {
        free(song);
        return NULL;
    }
    M_snprintf(song->path, sizeof(song->path), "%sdgmus_%lu_%lu.mid",
               tmpdir, (unsigned long)GetCurrentProcessId(),
               (unsigned long)(++s_counter));

    if (memcmp(data, "MUS\x1a", 4) == 0)
    {
        MEMFILE *in  = mem_fopen_read(data, (size_t)len);
        MEMFILE *out = mem_fopen_write();
        boolean  failed = mus2mid(in, out); /* 0 == Erfolg */

        if (!failed)
        {
            void  *buf;
            size_t buflen;
            mem_get_buf(out, &buf, &buflen);
            f = fopen(song->path, "wb");
            if (f != NULL)
            {
                fwrite(buf, 1, buflen, f);
                fclose(f);
            }
            else
                failed = 1;
        }

        mem_fclose(in);
        mem_fclose(out);

        if (failed)
        {
            free(song);
            return NULL;
        }
    }
    else if (memcmp(data, "MThd", 4) == 0)
    {
        f = fopen(song->path, "wb");
        if (f == NULL)
        {
            free(song);
            return NULL;
        }
        fwrite(data, 1, (size_t)len, f);
        fclose(f);
    }
    else
    {
        free(song);
        return NULL; /* weder MUS noch MIDI */
    }

    return song;
}

static void I_DG_UnRegisterSong(void *handle)
{
    dg_song_t *song = (dg_song_t *)handle;
    if (song == NULL)
        return;

    /* Der Kern hebt immer den gerade gestoppten Song auf - Geraet schliessen. */
    DG_MciClose();
    if (s_cur_path[0] != 0 && strcmp(s_cur_path, song->path) == 0)
        s_cur_path[0] = 0;
    remove(song->path);
    free(song);
}

static void I_DG_PlaySong(void *handle, boolean looping)
{
    dg_song_t *song = (dg_song_t *)handle;
    char       cmd[MAX_PATH + 64];

    if (!s_music_ready || song == NULL)
        return;

    DG_MciClose();

    M_snprintf(s_alias, sizeof(s_alias), "dgm%lu", (unsigned long)(++s_counter));
    M_snprintf(cmd, sizeof(cmd), "open \"%s\" type sequencer alias %s",
               song->path, s_alias);
    if (mciSendStringA(cmd, NULL, 0, NULL) != 0)
    {
        s_alias[0] = 0;
        return; /* kein MIDI-Geraet -> stumm, aber Host laeuft weiter */
    }

    M_StringCopy(s_cur_path, song->path, sizeof(s_cur_path));
    s_music_loop = looping ? 1 : 0;

    M_snprintf(cmd, sizeof(cmd), "play %s from 0", s_alias);
    if (mciSendStringA(cmd, NULL, 0, NULL) != 0)
    {
        DG_MciClose();
        return;
    }

    I_DG_SetMusicVolume(s_music_vol);
    s_music_playing = 1;
}

static void I_DG_StopSong(void)
{
    if (s_alias[0] != 0)
    {
        char cmd[64];
        M_snprintf(cmd, sizeof(cmd), "stop %s", s_alias);
        mciSendStringA(cmd, NULL, 0, NULL);
    }
    s_music_playing = 0;
}

static boolean I_DG_MusicIsPlaying(void)
{
    return s_music_playing ? 1 : 0;
}

/* Der Kern ruft das jeden Tic. Nur hierfuer brauchen wir keinen eigenen Thread:
   Endlos-Loop durch erneutes Abspielen, wenn das Stueck zu Ende ist. */
static void I_DG_PollMusic(void)
{
    char st[32];
    char cmd[64];

    if (!s_music_ready || !s_music_playing || !s_music_loop || s_alias[0] == 0)
        return;

    M_snprintf(cmd, sizeof(cmd), "status %s mode", s_alias);
    if (mciSendStringA(cmd, st, sizeof(st), NULL) == 0)
    {
        if (strcmp(st, "stopped") == 0)
        {
            M_snprintf(cmd, sizeof(cmd), "play %s from 0", s_alias);
            mciSendStringA(cmd, NULL, 0, NULL);
        }
    }
}

/* ------------------------------------------------------------------ Module + */

static snddevice_t s_sfx_devices[] =
{
    SNDDEVICE_SB, SNDDEVICE_PAS, SNDDEVICE_GUS,
    SNDDEVICE_WAVEBLASTER, SNDDEVICE_SOUNDCANVAS, SNDDEVICE_AWE32,
};

sound_module_t DG_sound_module =
{
    s_sfx_devices,
    arrlen(s_sfx_devices),
    I_DG_InitSound,
    I_DG_ShutdownSound,
    I_DG_GetSfxLumpNum,
    I_DG_Update,
    I_DG_UpdateSoundParams,
    I_DG_StartSound,
    I_DG_StopSound,
    I_DG_SoundIsPlaying,
    NULL, /* CacheSounds: nicht noetig (wird lazy in StartSound geladen) */
};

static snddevice_t s_mus_devices[] =
{
    SNDDEVICE_PAS, SNDDEVICE_GUS, SNDDEVICE_WAVEBLASTER,
    SNDDEVICE_SOUNDCANVAS, SNDDEVICE_GENMIDI, SNDDEVICE_AWE32,
};

music_module_t DG_music_module =
{
    s_mus_devices,
    arrlen(s_mus_devices),
    I_DG_InitMusic,
    I_DG_ShutdownMusic,
    I_DG_SetMusicVolume,
    I_DG_PauseMusic,
    I_DG_ResumeMusic,
    I_DG_RegisterSong,
    I_DG_UnRegisterSong,
    I_DG_PlaySong,
    I_DG_StopSong,
    I_DG_MusicIsPlaying,
    I_DG_PollMusic,
};

/* Von dg_ams.c (Export dg_shutdown) aufgerufen, BEVOR die DLL entladen wird.
   Idempotent - stoppt Thread und Geraete deterministisch. */
void DG_ShutdownAudio(void)
{
    DG_ShutdownSfx();
    DG_ShutdownMusic();
}
