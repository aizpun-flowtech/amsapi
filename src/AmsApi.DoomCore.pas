unit AmsApi.DoomCore;

{ ============================================================================
  AmsApi.DoomCore - der ECHTE DOOM-Kern als geladene DLL

  Braucht "doomcore.dll" neben dem Plugin: der echte DOOM (doomgeneric, auf
  Chocolate-Doom-/linuxdoom-Basis, GPLv2), mit MSVC als 32-Bit-DLL gebaut
  (native\build_doomcore.bat). So gibt es keine Objekt-/CRT-Vermischung mit FPC -
  die DLL ist ein normales Win32-Modul, das wir per LoadLibrary laden.

  Damit rendert das Plugin ECHTES DOOM mit ECHTEN Leveln (E1M1 ...), sobald
  ein IWAD vorliegt (DOOM1.WAD Shareware oder freedoom1.wad). Das Bild liefert
  der Kern in einem 640x400-Puffer (32 Bit, top-down BGRA); wir lesen ihn nur.

  Fehlt die DLL oder das WAD, meldet das (Loaded/Start = False) - das Plugin
  faellt dann auf die erzeugte Pascal-Engine (AmsApi.DoomEngine) zurueck.

  Sicherheit: Ein fataler Fehler im Kern (I_Error) beendet dank des Patches in
  native\...\i_system.c NICHT den Prozess, sondern springt in die DLL zurueck;
  Start/Tick liefern dann False. AMS laeuft weiter.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils;

type
  Tdg_start = function(wad, extra: PAnsiChar): Integer; cdecl;
  Tdg_tick  = function: Integer; cdecl;
  Tdg_fb    = function(var w, h: Integer): Pointer; cdecl;
  Tdg_key   = procedure(pressed, vk: Integer); cdecl;
  Tdg_alive = function: Integer; cdecl;
  Tdg_title = function: PAnsiChar; cdecl;
  Tdg_setsavedir = procedure(dir: PAnsiChar); cdecl;
  Tdg_wantsquit = function: Integer; cdecl;
  Tdg_shutdown = procedure; cdecl;

  TAmsDoomCore = class
  private
    FLib: HMODULE;
    FLoaded: Boolean;
    FStarted: Boolean;
    FDllPath: string;
    Fstart: Tdg_start;
    Ftick: Tdg_tick;
    Ffb: Tdg_fb;
    Fkey: Tdg_key;
    Falive: Tdg_alive;
    Ftitle: Tdg_title;
    Fsetsavedir: Tdg_setsavedir;
    Fwantsquit: Tdg_wantsquit;
    Fshutdown: Tdg_shutdown;
  public
    { Laedt die DLL (Standard: doomcore.dll neben dem Plugin). }
    constructor Create(const ADllPath: string = '');
    destructor Destroy; override;

    { Sind DLL und alle Exporte da? }
    property Loaded: Boolean read FLoaded;
    property Started: Boolean read FStarted;
    property DllPath: string read FDllPath;

    { Beschreibbares Verzeichnis fuer Konfiguration und Spielstaende setzen -
      VOR Start aufrufen. Ohne das speichert DOOM ins (schreibgeschuetzten)
      Programmverzeichnis von AMS und Spielstaende gehen verloren. }
    procedure SetSaveDir(const ADir: string);

    { DOOM starten. AWad = Pfad zu einem IWAD. AExtra = zusaetzliche
      Kommandozeile (z.B. '-warp 1 1'). Result False = DLL fehlt, WAD fehlt
      oder fataler Startfehler (Host bleibt am Leben). }
    function Start(const AWad: string; const AExtra: string = ''): Boolean;

    { Einen Bildschritt. False, wenn nicht gestartet oder der Kern gestorben ist. }
    function Tick: Boolean;

    { Zeiger auf das aktuelle Bild (nil, wenn nicht bereit). AW/AH = Groesse. }
    function Framebuffer(out AW, AH: Integer): Pointer;

    { Taste an DOOM: APressed = gedrueckt/losgelassen, AVk = Windows-VK-Code. }
    procedure Key(APressed: Boolean; AVk: Integer);

    { Laeuft der Kern noch (nicht gestorben)? }
    function Alive: Boolean;

    { Hat der Spieler DOOM ueber das Menue beendet ("press Y to quit")? Dann
      soll die eingebettete Flaeche geschlossen werden. }
    function WantsQuit: Boolean;
  end;

{ Standardpfad: doomcore.dll neben dem Plugin. }
function AmsDoomCoreDefaultDll: string;

implementation

uses
  AmsApi.Log;

function AmsDoomCoreDefaultDll: string;
begin
  Result := AmsModuleDir + 'doomcore.dll';
end;

constructor TAmsDoomCore.Create(const ADllPath: string);
begin
  inherited Create;
  FLoaded := False;
  FStarted := False;
  FDllPath := ADllPath;
  if FDllPath = '' then FDllPath := AmsDoomCoreDefaultDll;

  if not FileExists(FDllPath) then
  begin
    AmsLogFmt('DoomCore: doomcore.dll nicht gefunden: %s', [FDllPath]);
    Exit;
  end;

  FLib := LoadLibraryW(PWideChar(WideString(FDllPath)));
  if FLib = 0 then
  begin
    AmsLogFmt('DoomCore: LoadLibrary fehlgeschlagen (%d): %s',
              [GetLastError, FDllPath]);
    Exit;
  end;

  Fstart := Tdg_start(GetProcAddress(FLib, 'dg_start'));
  Ftick  := Tdg_tick(GetProcAddress(FLib, 'dg_tick'));
  Ffb    := Tdg_fb(GetProcAddress(FLib, 'dg_framebuffer'));
  Fkey   := Tdg_key(GetProcAddress(FLib, 'dg_key'));
  Falive := Tdg_alive(GetProcAddress(FLib, 'dg_alive'));
  Ftitle := Tdg_title(GetProcAddress(FLib, 'dg_title'));
  Fsetsavedir := Tdg_setsavedir(GetProcAddress(FLib, 'dg_set_savedir'));
  Fwantsquit := Tdg_wantsquit(GetProcAddress(FLib, 'dg_wants_quit'));
  Fshutdown := Tdg_shutdown(GetProcAddress(FLib, 'dg_shutdown'));

  FLoaded := Assigned(Fstart) and Assigned(Ftick) and Assigned(Ffb) and
             Assigned(Fkey) and Assigned(Falive);
  if FLoaded then
    AmsLogFmt('DoomCore: doomcore.dll geladen: %s', [FDllPath])
  else
    AmsLog('DoomCore: doomcore.dll geladen, aber Exporte fehlen');
end;

destructor TAmsDoomCore.Destroy;
begin
  { Die DLL VOLLSTAENDIG entladen. doomgeneric ist ein Singleton mit viel
    globalem Zustand und laesst sich nicht an Ort und Stelle neu starten -
    ein zweites dg_start liefe in den fertigen (beendeten) Zustand. Deshalb
    beim Schliessen die DLL freigeben; das naechste Oeffnen laedt eine frische
    Kopie (globale Variablen und CRT neu initialisiert) und startet ein neues
    Spiel. Dass das sauber geht - Laden, Spielen, Entladen, wieder Laden -,
    ist ohne AMS gegengeprueft (mehrere Runden, jede rendert). Voraussetzung:
    die Schleife ist gestoppt, wenn wir hierher kommen (CloseGame haelt sie an),
    es laeuft also kein Tick mehr im Kern. }

  { Sound zuerst herunterfahren: dg_shutdown stoppt den Mixer-Thread und
    schliesst waveOut/MCI. MUSS vor FreeLibrary laufen, sonst liefe der
    Feeder-Thread der DLL in bereits entladenen Code. Aeltere doomcore.dll
    ohne diesen Export: dann ist Fshutdown nil und wir ueberspringen es. }
  if (FLib <> 0) and Assigned(Fshutdown) then
  begin
    try
      Fshutdown;
    except
    end;
  end;

  if FLib <> 0 then
    FreeLibrary(FLib);
  FLib := 0;
  FStarted := False;
  inherited Destroy;
end;

procedure TAmsDoomCore.SetSaveDir(const ADir: string);
var
  D: AnsiString;
begin
  if not FLoaded then Exit;
  if not Assigned(Fsetsavedir) then
  begin
    AmsLog('DoomCore: dg_set_savedir fehlt in der DLL (alte doomcore.dll?)');
    Exit;
  end;
  D := AnsiString(ADir);
  try
    Fsetsavedir(PAnsiChar(D));
    AmsLogFmt('DoomCore: Speicherverzeichnis = %s', [ADir]);
  except
  end;
end;

function TAmsDoomCore.Start(const AWad, AExtra: string): Boolean;
var
  W, E: AnsiString;
begin
  Result := False;
  if not FLoaded then Exit;
  if not FileExists(AWad) then
  begin
    AmsLogFmt('DoomCore: WAD nicht gefunden: %s', [AWad]);
    Exit;
  end;
  W := AnsiString(AWad);
  E := AnsiString(AExtra);
  try
    Result := Fstart(PAnsiChar(W), PAnsiChar(E)) <> 0;
  except
    on Ex: Exception do
    begin
      AmsLog('DoomCore: Ausnahme in dg_start: ' + Ex.Message);
      Result := False;
    end;
  end;
  FStarted := Result;
  if Result then
    AmsLogFmt('DoomCore: DOOM gestartet mit %s %s', [AWad, AExtra])
  else
    AmsLog('DoomCore: dg_start meldete einen Fehler (WAD ungueltig?)');
end;

function TAmsDoomCore.Tick: Boolean;
begin
  Result := False;
  if not (FLoaded and FStarted) then Exit;
  try
    Result := Ftick() <> 0;
  except
    on Ex: Exception do
    begin
      AmsLog('DoomCore: Ausnahme in dg_tick: ' + Ex.Message);
      Result := False;
    end;
  end;
end;

function TAmsDoomCore.Framebuffer(out AW, AH: Integer): Pointer;
begin
  AW := 0; AH := 0;
  Result := nil;
  if not FLoaded then Exit;
  try
    Result := Ffb(AW, AH);
  except
    Result := nil;
  end;
end;

procedure TAmsDoomCore.Key(APressed: Boolean; AVk: Integer);
begin
  if not FLoaded then Exit;
  try
    Fkey(Ord(APressed), AVk);
  except
  end;
end;

function TAmsDoomCore.Alive: Boolean;
begin
  Result := FLoaded and FStarted and Assigned(Falive) and (Falive() <> 0);
end;

function TAmsDoomCore.WantsQuit: Boolean;
begin
  Result := FLoaded and FStarted and Assigned(Fwantsquit) and (Fwantsquit() <> 0);
end;

end.
