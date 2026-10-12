unit AmsApi.DoomEngine;

{ ============================================================================
  AmsApi.DoomEngine - eine DOOM-Engine, die in einen Bildpuffer rendert

  Ein First-Person-Softwarerenderer im Stil von DOOM: ein DDA-Raycaster fuer
  texturierte Waende, dazu Boden und Decke (Floor-Casting), Gegner und
  Aufsammelbares als Billboard-Sprites mit Z-Puffer, Waffe und HUD.

  ECHTE DOOM-DATEN: Liegt eine "DOOM1.WAD" (Shareware) o.ae. neben dem Plugin,
  benutzt die Engine deren echte Palette (PLAYPAL), Wandtexturen
  (TEXTURE1/PNAMES), Flats, Monster-Sprites und die Pistole. Fehlt das WAD -
  oder fehlt darin ein einzelnes Lump - werden gleichwertige Texturen erzeugt,
  damit das Plugin IMMER laeuft. Was benutzt wurde, steht im Log.

  Grenze der Ehrlichkeit: Das ist ein DOOM-*Stil*-Renderer mit echten
  DOOM-Assets, KEIN BSP-Port von E1M1. Die Karte ist ein kompaktes Gitter.
  Fuer echte Level (VERTEXES/LINEDEFS/SEGS/SSECTORS/NODES/SECTORS aus dem WAD)
  gibt AmsApi.Wad zwar den rohen Lump-Zugriff her, parst diese Map-Lumps aber
  noch nicht - ein fehlerhafter BSP-Renderer, den man ohne WAD und ohne AMS
  nicht gegenpruefen kann, waere das Gegenteil von "funktioniert".

  Die Engine kennt weder Fenster noch Host: Tick(Input) rechnet einen Schritt,
  Render(Puffer) zeichnet ihn. Damit ist sie ohne AMS testbar
  (tests\doomdemo.lpr) und im Plugin nur noch zu verdrahten.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Math, AmsApi.GameWindow, AmsApi.Wad;

const
  DOOM_MAP_W = 24;
  DOOM_MAP_H = 24;

type
  { Was der Spieler in diesem Schritt tut. Bewegung ist "gedrueckt/nicht",
    Fire ebenso - die Feuerrate macht die Engine selbst. }
  TAmsDoomInput = record
    GoForward, GoBackward, StrafeLeft, StrafeRight: Boolean;
    TurnLeft, TurnRight, Fire, Use, Run: Boolean;
    MouseDX: Integer;
  end;

  TAmsDoomTexture = record
    W, H: Integer;
    Pix: TAmsByteArray;    { Palettenindizes, W*H }
    Ok: Boolean;
  end;

  TAmsEnemyState = (esWalk, esPain, esDie, esDead, esAttack);

  TAmsEnemy = record
    X, Y: Double;
    Alive: Boolean;
    HP: Integer;
    State: TAmsEnemyState;
    Frame: Integer;
    AnimMs: Integer;
    AttackCoolMs: Integer;
    Active: Boolean;       { Slot benutzt }
  end;

  TAmsPickup = record
    X, Y: Double;
    Kind: Integer;         { 0 = Gesundheit, 1 = Munition }
    Taken: Boolean;
    Active: Boolean;
  end;

  TAmsDoom = class
  private
    FWad: TAmsWad;
    FUsingWad: Boolean;
    FPal: TAmsPalette;

    FWallTex: array of TAmsDoomTexture;
    FFloor: TAmsDoomTexture;
    FCeil: TAmsDoomTexture;

    FMonWalk: array of TAmsPic;
    FMonDie: array of TAmsPic;
    FItemPic: array[0..1] of TAmsPic;
    FGun: TAmsPic;
    FGunFire: TAmsPic;

    FMap: array[0..DOOM_MAP_W * DOOM_MAP_H - 1] of Byte;

    { Spieler }
    FPX, FPY, FAngle: Double;
    FHealth, FAmmo, FKills, FMonsters: Integer;
    FDead: Boolean;
    FFireCoolMs: Integer;
    FMuzzleMs: Integer;
    FBobMs: Integer;
    FMessage: string;
    FMessageMs: Integer;
    FHurtFlashMs: Integer;

    FEnemies: array of TAmsEnemy;
    FPickups: array of TAmsPickup;

    FZBuf: array of Double;   { pro Spalte die Wandentfernung, fuer Sprites }

    { --- Aufbau --- }
    procedure MakePalette;               { synthetische Palette (ohne WAD) }
    procedure LoadPaletteFromWad;
    function  MakeProcTexture(AKind: Integer): TAmsDoomTexture;
    function  MakeProcFlat(ACeiling: Boolean): TAmsDoomTexture;
    function  PicToTexture(const APic: TAmsPic): TAmsDoomTexture;
    function  FlatToTexture(const APix: TAmsByteArray): TAmsDoomTexture;
    function  MakeProcMonster(AFrame: Integer; ADying: Boolean): TAmsPic;
    function  MakeProcGun(AFiring: Boolean): TAmsPic;
    function  MakeProcItem(AKind: Integer): TAmsPic;
    procedure LoadWallTextures;
    procedure LoadFlats;
    procedure LoadSprites;
    procedure BuildMap;

    { --- Ablauf --- }
    function  MapAt(ACX, ACY: Integer): Byte;
    function  Blocked(AX, AY: Double): Boolean;
    function  LineClear(AX0, AY0, AX1, AY1: Double): Boolean;
    procedure MovePlayer(const AInput: TAmsDoomInput; ADtMs: Integer);
    procedure DoFire;
    procedure UpdateEnemies(ADtMs: Integer);
    procedure CheckPickups;
    procedure SetMessage(const AText: string);

    { --- Zeichnen --- }
    procedure RenderFloorCeil(ABuf: PAmsPixelBuf; AW, AH: Integer);
    procedure RenderWalls(ABuf: PAmsPixelBuf; AW, AH: Integer);
    procedure RenderSprites(ABuf: PAmsPixelBuf; AW, AH: Integer);
    procedure RenderWeapon(ABuf: PAmsPixelBuf; AW, AH: Integer);
    procedure DrawPicColumnScaled(ABuf: PAmsPixelBuf; AW, AH: Integer;
      const APic: TAmsPic; AScreenX, ADrawStartY, ADrawEndY, ATexX: Integer;
      AScaleH: Integer; AShade: Integer; AUseZ: Boolean; ADist: Double);
  public
    constructor Create;
    destructor Destroy; override;

    { Assets laden. AWadFile darf leer sein oder auf ein nicht vorhandenes WAD
      zeigen - dann werden Ersatztexturen erzeugt. Result = echtes WAD benutzt. }
    function LoadAssets(const AWadFile: string): Boolean;

    { Neues Spiel: Spieler und Gegner auf Start. }
    procedure NewGame;

    { Einen Schritt rechnen (ADtMs = vergangene Millisekunden). }
    procedure Tick(const AInput: TAmsDoomInput; ADtMs: Integer);

    { Den aktuellen Zustand in einen 32-Bit-Bildpuffer zeichnen. }
    procedure Render(ABuf: PAmsPixelBuf; AW, AH: Integer);

    property UsingWad: Boolean read FUsingWad;
    property Health: Integer read FHealth;
    property Ammo: Integer read FAmmo;
    property Kills: Integer read FKills;
    property Monsters: Integer read FMonsters;
    property PlayerDead: Boolean read FDead;
    property StatusMessage: string read FMessage;
  end;

implementation

uses
  AmsApi.Log;

const
  NUM_WALLTEX = 6;
  MOVE_SPEED  = 3.2;      { Zellen pro Sekunde }
  RUN_MULT    = 1.8;
  TURN_SPEED  = 2.6;      { Radiant pro Sekunde }
  FOV         = 0.66;
  FIRE_COOL   = 260;      { ms zwischen Schuessen }
  HIT_RANGE   = 16.0;
  HIT_ANGLE   = 0.16;     { ~9 Grad Trefferkegel }
  ENEMY_DMG   = 8;
  START_HEALTH = 100;
  START_AMMO   = 50;

  { Wandtexturnamen aus DOOM1.WAD (Shareware). Fehlt einer, wird erzeugt. }
  WALLTEX_NAMES: array[0..NUM_WALLTEX - 1] of string =
    ('STARTAN3', 'BROWN1', 'STONE2', 'TEKWALL4', 'COMPSPAN', 'SUPPORT2');

  { Die Karte. Ziffern 1..6 = Wandtextur, Punkt = Boden, P = Start,
    M = Monster, h = Gesundheit, a = Munition. }
  MAP_ROWS: array[0..DOOM_MAP_H - 1] of string = (
    '111111111111111111111111',
    '1......................1',
    '1..M......22222........1',
    '1.........2...2....h...1',
    '1.........2...2........1',
    '1....P....2...2....M...1',
    '1.........22.22........1',
    '1.....................1',
    '1...3333.......4444....1',
    '1...3..............4...1',
    '1...3....a....M.....4..1',
    '1...3..............4...1',
    '1...33333......4444....1',
    '1.....................1',
    '1..M..........55555....1',
    '1.............5...5....1',
    '1....6666.....5.M.5....1',
    '1....6..6.....5...5....1',
    '1....6..6.....55555....1',
    '1....6..6.............1',
    '1....6666.......h..M..1',
    '1.....................1',
    '1....................a1',
    '111111111111111111111111');

{ ---------------------------------------------------------------- Konstruktor }

constructor TAmsDoom.Create;
begin
  inherited Create;
  FWad := nil;
  FUsingWad := False;
  Randomize;
end;

destructor TAmsDoom.Destroy;
begin
  FWad.Free;
  inherited Destroy;
end;

{ ------------------------------------------------------------------- Palette - }

{ Ohne WAD: eine brauchbare 256-Farben-Palette in Rampen. Die
  Textur-Erzeuger picken sich daraus die Farben. }
procedure TAmsDoom.MakePalette;
var
  i, v: Integer;

  procedure Ramp(ABase, ACount, AR0, AG0, AB0, AR1, AG1, AB1: Integer);
  var
    k: Integer;
    t: Double;
  begin
    for k := 0 to ACount - 1 do
    begin
      if ACount > 1 then t := k / (ACount - 1) else t := 0;
      FPal[ABase + k] := AmsRGB(
        Round(AR0 + (AR1 - AR0) * t),
        Round(AG0 + (AG1 - AG0) * t),
        Round(AB0 + (AB1 - AB0) * t));
    end;
  end;

begin
  for i := 0 to 255 do FPal[i] := 0;
  Ramp(0,   32, 0, 0, 0, 255, 255, 255);        { Grau }
  Ramp(32,  32, 24, 0, 0, 255, 40, 40);         { Rot }
  Ramp(64,  32, 0, 16, 0, 60, 255, 60);         { Gruen }
  Ramp(96,  32, 0, 0, 24, 60, 60, 255);         { Blau }
  Ramp(128, 32, 24, 12, 0, 190, 120, 50);       { Braun/Orange }
  Ramp(160, 32, 32, 24, 0, 255, 230, 60);       { Gelb }
  Ramp(192, 32, 0, 24, 24, 60, 220, 220);       { Tuerkis }
  Ramp(224, 24, 40, 20, 12, 235, 180, 140);     { Haut }
  { Rest: Magenta-Toene }
  for i := 248 to 255 do
  begin
    v := (i - 248) * 32;
    FPal[i] := AmsRGB(120 + v, 0, 120 + v);
  end;
end;

procedure TAmsDoom.LoadPaletteFromWad;
begin
  if (FWad <> nil) and FWad.Valid and FWad.ReadPalette(FPal) then
    AmsLog('DOOM: echte Palette aus PLAYPAL')
  else
    MakePalette;
end;

{ ------------------------------------------------------- Textur-Erzeugung ---- }

{ Sucht einen Palettenindex, dessen Farbe einer Wunschfarbe am naechsten kommt.
  So funktionieren die erzeugten Texturen mit JEDER Palette - auch der echten
  aus dem WAD, falls ein einzelnes Textur-Lump fehlt. }
function TAmsDoom_NearestIndex(const APal: TAmsPalette; AR, AG, AB: Integer): Byte;
var
  i, Best, BestD, d, dr, dg, db: Integer;
begin
  Best := 0;
  BestD := MaxInt;
  for i := 0 to 255 do
  begin
    dr := ((APal[i] shr 16) and $FF) - AR;
    dg := ((APal[i] shr 8) and $FF) - AG;
    db := (APal[i] and $FF) - AB;
    d := dr * dr + dg * dg + db * db;
    if d < BestD then
    begin
      BestD := d;
      Best := i;
      if d = 0 then Break;
    end;
  end;
  Result := Byte(Best);
end;

function TAmsDoom.MakeProcTexture(AKind: Integer): TAmsDoomTexture;
var
  x, y, n: Integer;
  R, G, B: Integer;
  Idx, Dark, Light, Mortar: Byte;
begin
  Result.W := 64;
  Result.H := 64;
  Result.Ok := True;
  SetLength(Result.Pix, 64 * 64);

  { Grundfarbe je nach Wandtyp. }
  case AKind mod NUM_WALLTEX of
    0: begin R := 120; G := 120; B := 130; end;   { Stahlgrau }
    1: begin R := 150; G := 90;  B := 50;  end;    { Braun }
    2: begin R := 110; G := 110; B := 110; end;    { Stein }
    3: begin R := 60;  G := 120; B := 150; end;    { Technik/blau }
    4: begin R := 90;  G := 100; B := 90;  end;    { Computer }
    else begin R := 140; G := 130; B := 60; end;   { Stuetze/gelb }
  end;

  Light := TAmsDoom_NearestIndex(FPal, Min(255, R + 40), Min(255, G + 40), Min(255, B + 40));
  Dark := TAmsDoom_NearestIndex(FPal, R * 2 div 3, G * 2 div 3, B * 2 div 3);
  Mortar := TAmsDoom_NearestIndex(FPal, R div 3, G div 3, B div 3);

  for y := 0 to 63 do
    for x := 0 to 63 do
    begin
      { Ziegelmuster mit versetzten Reihen }
      Idx := TAmsDoom_NearestIndex(FPal, R, G, B);
      if (y mod 16 = 0) or (y mod 16 = 15) then
        Idx := Mortar
      else
      begin
        n := 0;
        if (y div 16) and 1 = 1 then n := 32;
        if ((x + n) mod 32 = 0) or ((x + n) mod 32 = 31) then
          Idx := Mortar
        else if ((x + y) and 7) = 0 then
          Idx := Light
        else if ((x * 3 + y) and 13) = 0 then
          Idx := Dark;
      end;
      { leichte vertikale Schattierung }
      if (AKind mod NUM_WALLTEX) = 3 then
        if (x mod 8) < 2 then Idx := Dark;
      Result.Pix[y * 64 + x] := Idx;
    end;
end;

function TAmsDoom.MakeProcFlat(ACeiling: Boolean): TAmsDoomTexture;
var
  x, y: Integer;
  R, G, B: Integer;
  A, Bk: Byte;
begin
  Result.W := 64;
  Result.H := 64;
  Result.Ok := True;
  SetLength(Result.Pix, 64 * 64);
  if ACeiling then begin R := 60; G := 60; B := 70; end
  else begin R := 80; G := 70; B := 55; end;
  A := TAmsDoom_NearestIndex(FPal, R, G, B);
  Bk := TAmsDoom_NearestIndex(FPal, R * 3 div 4, G * 3 div 4, B * 3 div 4);
  for y := 0 to 63 do
    for x := 0 to 63 do
      if ((x xor y) and 8) = 0 then
        Result.Pix[y * 64 + x] := A
      else
        Result.Pix[y * 64 + x] := Bk;
end;

function TAmsDoom.PicToTexture(const APic: TAmsPic): TAmsDoomTexture;
var
  i, n: Integer;
begin
  Result.W := APic.Width;
  Result.H := APic.Height;
  Result.Ok := (APic.Width > 0) and (APic.Height > 0);
  n := APic.Width * APic.Height;
  SetLength(Result.Pix, n);
  for i := 0 to n - 1 do
    if (i < Length(APic.Mask)) and (APic.Mask[i] = 0) then
      Result.Pix[i] := 0            { Loch -> Index 0 }
    else if i < Length(APic.Pixels) then
      Result.Pix[i] := APic.Pixels[i]
    else
      Result.Pix[i] := 0;
end;

function TAmsDoom.FlatToTexture(const APix: TAmsByteArray): TAmsDoomTexture;
var
  i: Integer;
begin
  Result.W := 64;
  Result.H := 64;
  Result.Ok := Length(APix) >= 4096;
  SetLength(Result.Pix, 4096);
  if Result.Ok then
    for i := 0 to 4095 do Result.Pix[i] := APix[i];
end;

{ Ein erzeugtes Monster (falls kein Sprite im WAD): ein kleiner Unhold. }
function TAmsDoom.MakeProcMonster(AFrame: Integer; ADying: Boolean): TAmsPic;
var
  W, H, x, y, cx, dy: Integer;
  Skin, Body, Eye, Dark: Byte;
  d2: Integer;
begin
  W := 40; H := 56;
  Result := AmsEmptyPic;
  Result.Width := W; Result.Height := H;
  Result.LeftOffset := W div 2; Result.TopOffset := H;
  SetLength(Result.Pixels, W * H);
  SetLength(Result.Mask, W * H);

  Skin := TAmsDoom_NearestIndex(FPal, 210, 160, 120);
  Body := TAmsDoom_NearestIndex(FPal, 120, 60, 40);
  Dark := TAmsDoom_NearestIndex(FPal, 70, 30, 20);
  Eye := TAmsDoom_NearestIndex(FPal, 255, 40, 20);
  cx := W div 2;

  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      if ADying then
      begin
        { im Sterben zusammensacken: nur unteres Drittel als Haufen }
        if y < H * 2 div 3 then Continue;
        d2 := (x - cx) * (x - cx) + (y - (H - 6)) * (y - (H - 6));
        if d2 < 220 then
        begin
          Result.Pixels[y * W + x] := Body;
          Result.Mask[y * W + x] := 1;
        end;
        Continue;
      end;

      { Kopf }
      d2 := (x - cx) * (x - cx) + (y - 12) * (y - 12);
      if d2 < 90 then
      begin
        Result.Pixels[y * W + x] := Skin;
        Result.Mask[y * W + x] := 1;
      end;
      { Rumpf }
      if (y >= 20) and (y < H - 8) and (Abs(x - cx) < 13 - (y - 20) div 8) then
      begin
        Result.Pixels[y * W + x] := Body;
        Result.Mask[y * W + x] := 1;
      end;
      { Beine, je nach Frame leicht versetzt (Gehanimation) }
      if (y >= H - 8) then
      begin
        dy := (AFrame and 1);
        if (Abs(x - (cx - 5 - dy)) < 3) or (Abs(x - (cx + 5 + dy)) < 3) then
        begin
          Result.Pixels[y * W + x] := Dark;
          Result.Mask[y * W + x] := 1;
        end;
      end;
    end;
  { Augen }
  if not ADying then
  begin
    Result.Pixels[10 * W + (cx - 3)] := Eye; Result.Mask[10 * W + (cx - 3)] := 1;
    Result.Pixels[10 * W + (cx + 3)] := Eye; Result.Mask[10 * W + (cx + 3)] := 1;
  end;
end;

function TAmsDoom.MakeProcGun(AFiring: Boolean): TAmsPic;
var
  W, H, x, y: Integer;
  Metal, Dark, Flash: Byte;
begin
  W := 64; H := 64;
  Result := AmsEmptyPic;
  Result.Width := W; Result.Height := H;
  Result.LeftOffset := W div 2; Result.TopOffset := 0;
  SetLength(Result.Pixels, W * H);
  SetLength(Result.Mask, W * H);
  Metal := TAmsDoom_NearestIndex(FPal, 150, 150, 160);
  Dark := TAmsDoom_NearestIndex(FPal, 60, 60, 70);
  Flash := TAmsDoom_NearestIndex(FPal, 255, 230, 120);

  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      { Griff + Lauf, grob mittig }
      if (x >= 26) and (x <= 38) and (y >= 20) then
      begin
        Result.Pixels[y * W + x] := Metal;
        Result.Mask[y * W + x] := 1;
        if (x = 26) or (x = 38) or (y = 20) then Result.Pixels[y * W + x] := Dark;
      end;
    end;
  if AFiring then
    for y := 10 to 20 do
      for x := 28 to 36 do
        if (Abs(x - 32) + Abs(y - 15)) < 6 then
        begin
          Result.Pixels[y * W + x] := Flash;
          Result.Mask[y * W + x] := 1;
        end;
end;

function TAmsDoom.MakeProcItem(AKind: Integer): TAmsPic;
var
  W, H, x, y, cx, cy, d2: Integer;
  C, Edge: Byte;
begin
  W := 20; H := 20;
  Result := AmsEmptyPic;
  Result.Width := W; Result.Height := H;
  Result.LeftOffset := W div 2; Result.TopOffset := H;
  SetLength(Result.Pixels, W * H);
  SetLength(Result.Mask, W * H);
  if AKind = 0 then
  begin
    C := TAmsDoom_NearestIndex(FPal, 40, 220, 60);      { Gesundheit gruen }
    Edge := TAmsDoom_NearestIndex(FPal, 255, 255, 255);
  end
  else
  begin
    C := TAmsDoom_NearestIndex(FPal, 230, 210, 60);     { Munition gelb }
    Edge := TAmsDoom_NearestIndex(FPal, 90, 70, 20);
  end;
  cx := W div 2; cy := H div 2;
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      d2 := (x - cx) * (x - cx) + (y - cy) * (y - cy);
      if d2 < 70 then
      begin
        Result.Pixels[y * W + x] := C;
        Result.Mask[y * W + x] := 1;
      end;
    end;
  { kleines Kreuz/Markierung }
  if AKind = 0 then
    for x := cx - 4 to cx + 4 do
    begin
      Result.Pixels[cy * W + x] := Edge; Result.Mask[cy * W + x] := 1;
      Result.Pixels[(cy) * W + x] := Edge;
    end;
end;

{ ---------------------------------------------------------------- Assets ----- }

procedure TAmsDoom.LoadWallTextures;
var
  i: Integer;
  Pic: TAmsPic;
  Ok: Boolean;
begin
  SetLength(FWallTex, NUM_WALLTEX);
  for i := 0 to NUM_WALLTEX - 1 do
  begin
    Ok := False;
    if FUsingWad then
      if FWad.BuildTexture(WALLTEX_NAMES[i], Pic) then
      begin
        FWallTex[i] := PicToTexture(Pic);
        Ok := FWallTex[i].Ok;
        if Ok then AmsLogFmt('DOOM: Wandtextur %s aus WAD', [WALLTEX_NAMES[i]]);
      end;
    if not Ok then
    begin
      FWallTex[i] := MakeProcTexture(i);
      if FUsingWad then
        AmsLogFmt('DOOM: Wandtextur %s fehlt im WAD - erzeugt', [WALLTEX_NAMES[i]]);
    end;
  end;
end;

procedure TAmsDoom.LoadFlats;
var
  Pix: TAmsByteArray;
begin
  FFloor.Ok := False;
  FCeil.Ok := False;
  if FUsingWad then
  begin
    if FWad.ReadFlat('FLOOR4_8', Pix) then FFloor := FlatToTexture(Pix);
    if FWad.ReadFlat('CEIL3_5', Pix) then FCeil := FlatToTexture(Pix);
  end;
  if not FFloor.Ok then FFloor := MakeProcFlat(False);
  if not FCeil.Ok then FCeil := MakeProcFlat(True);
end;

procedure TAmsDoom.LoadSprites;
var
  Pic: TAmsPic;
  i: Integer;
  WalkNames: array[0..3] of string;
  DieNames: array[0..4] of string;
  GotWalk, GotDie: Integer;
begin
  { Zombieman (POSS). Rotation 1 = Vorderansicht. }
  WalkNames[0] := 'POSSA1'; WalkNames[1] := 'POSSB1';
  WalkNames[2] := 'POSSC1'; WalkNames[3] := 'POSSD1';
  DieNames[0] := 'POSSH0'; DieNames[1] := 'POSSI0'; DieNames[2] := 'POSSJ0';
  DieNames[3] := 'POSSK0'; DieNames[4] := 'POSSL0';

  SetLength(FMonWalk, 4);
  SetLength(FMonDie, 5);
  GotWalk := 0;
  GotDie := 0;

  if FUsingWad then
  begin
    for i := 0 to 3 do
      if FWad.ReadPatch(WalkNames[i], Pic) and (Pic.Width > 0) then
      begin
        FMonWalk[i] := Pic;
        Inc(GotWalk);
      end;
    for i := 0 to 4 do
      if FWad.ReadPatch(DieNames[i], Pic) and (Pic.Width > 0) then
      begin
        FMonDie[i] := Pic;
        Inc(GotDie);
      end;
  end;

  if GotWalk < 4 then
  begin
    for i := 0 to 3 do FMonWalk[i] := MakeProcMonster(i, False);
    if FUsingWad then AmsLog('DOOM: Monster-Sprites unvollstaendig - erzeugt');
  end
  else
    AmsLog('DOOM: Monster-Sprites (POSS) aus WAD');

  if GotDie < 5 then
    for i := 0 to 4 do FMonDie[i] := MakeProcMonster(i, True);

  { Waffe: Pistole. }
  FGun := AmsEmptyPic;
  FGunFire := AmsEmptyPic;
  if FUsingWad then
  begin
    FWad.ReadPatch('PISGA0', FGun);
    if not FWad.ReadPatch('PISFA0', FGunFire) then FGunFire := FGun;
  end;
  if FGun.Width <= 0 then FGun := MakeProcGun(False);
  if FGunFire.Width <= 0 then FGunFire := MakeProcGun(True);

  { Aufsammelbares. Echte DOOM-Lumps: STIMA0 (Stimpack), CLIPA0 (Clip). }
  for i := 0 to 1 do FItemPic[i] := AmsEmptyPic;
  if FUsingWad then
  begin
    FWad.ReadPatch('STIMA0', FItemPic[0]);
    FWad.ReadPatch('CLIPA0', FItemPic[1]);
  end;
  if FItemPic[0].Width <= 0 then FItemPic[0] := MakeProcItem(0);
  if FItemPic[1].Width <= 0 then FItemPic[1] := MakeProcItem(1);
end;

procedure TAmsDoom.BuildMap;
var
  x, y, ne, np: Integer;
  Ch: Char;
begin
  FMonsters := 0;
  SetLength(FEnemies, 0);
  SetLength(FPickups, 0);
  ne := 0;
  np := 0;

  for y := 0 to DOOM_MAP_H - 1 do
    for x := 0 to DOOM_MAP_W - 1 do
    begin
      if x < Length(MAP_ROWS[y]) then Ch := MAP_ROWS[y][x + 1] else Ch := '1';
      case Ch of
        '1'..'6': FMap[y * DOOM_MAP_W + x] := Ord(Ch) - Ord('0');
        'P':
          begin
            FMap[y * DOOM_MAP_W + x] := 0;
            FPX := x + 0.5; FPY := y + 0.5; FAngle := 0;
          end;
        'M':
          begin
            FMap[y * DOOM_MAP_W + x] := 0;
            Inc(ne);
          end;
        'h', 'a':
          begin
            FMap[y * DOOM_MAP_W + x] := 0;
            Inc(np);
          end;
      else
        FMap[y * DOOM_MAP_W + x] := 0;
      end;
    end;

  SetLength(FEnemies, ne);
  SetLength(FPickups, np);
  ne := 0;
  np := 0;
  for y := 0 to DOOM_MAP_H - 1 do
    for x := 0 to DOOM_MAP_W - 1 do
    begin
      if x < Length(MAP_ROWS[y]) then Ch := MAP_ROWS[y][x + 1] else Ch := ' ';
      case Ch of
        'M':
          begin
            FEnemies[ne].X := x + 0.5; FEnemies[ne].Y := y + 0.5;
            FEnemies[ne].Alive := True; FEnemies[ne].HP := 20;
            FEnemies[ne].State := esWalk; FEnemies[ne].Frame := 0;
            FEnemies[ne].AnimMs := 0; FEnemies[ne].AttackCoolMs := 0;
            FEnemies[ne].Active := True;
            Inc(ne);
          end;
        'h':
          begin
            FPickups[np].X := x + 0.5; FPickups[np].Y := y + 0.5;
            FPickups[np].Kind := 0; FPickups[np].Taken := False;
            FPickups[np].Active := True;
            Inc(np);
          end;
        'a':
          begin
            FPickups[np].X := x + 0.5; FPickups[np].Y := y + 0.5;
            FPickups[np].Kind := 1; FPickups[np].Taken := False;
            FPickups[np].Active := True;
            Inc(np);
          end;
      end;
    end;
  FMonsters := ne;
end;

function TAmsDoom.LoadAssets(const AWadFile: string): Boolean;
begin
  FUsingWad := False;
  FWad.Free;
  FWad := nil;
  if (AWadFile <> '') and FileExists(AWadFile) then
  begin
    FWad := TAmsWad.Create(AWadFile);
    FUsingWad := FWad.Valid;
    if not FUsingWad then
    begin
      FWad.Free;
      FWad := nil;
    end;
  end;

  LoadPaletteFromWad;
  LoadWallTextures;
  LoadFlats;
  LoadSprites;
  BuildMap;

  if FUsingWad then
    AmsLogFmt('DOOM: echtes WAD in Betrieb (%s)', [ExtractFileName(AWadFile)])
  else
    AmsLog('DOOM: kein WAD - erzeugte Assets in Betrieb');
  Result := FUsingWad;
end;

procedure TAmsDoom.NewGame;
begin
  FHealth := START_HEALTH;
  FAmmo := START_AMMO;
  FKills := 0;
  FDead := False;
  FFireCoolMs := 0;
  FMuzzleMs := 0;
  FBobMs := 0;
  FMessage := '';
  FMessageMs := 0;
  FHurtFlashMs := 0;
  BuildMap;
  SetMessage('Los geht''s - viel Erfolg, Marine.');
end;

{ ------------------------------------------------------------------ Karte --- }

function TAmsDoom.MapAt(ACX, ACY: Integer): Byte;
begin
  if (ACX < 0) or (ACY < 0) or (ACX >= DOOM_MAP_W) or (ACY >= DOOM_MAP_H) then
    Exit(1);
  Result := FMap[ACY * DOOM_MAP_W + ACX];
end;

function TAmsDoom.Blocked(AX, AY: Double): Boolean;
begin
  Result := MapAt(Floor(AX), Floor(AY)) <> 0;
end;

{ Freie Sichtlinie zwischen zwei Punkten (fuer Treffer und Gegner-KI). }
function TAmsDoom.LineClear(AX0, AY0, AX1, AY1: Double): Boolean;
var
  Steps, i: Integer;
  dx, dy, x, y: Double;
begin
  dx := AX1 - AX0;
  dy := AY1 - AY0;
  Steps := Round(Sqrt(dx * dx + dy * dy) * 8) + 1;
  if Steps > 4096 then Steps := 4096;
  for i := 1 to Steps - 1 do
  begin
    x := AX0 + dx * i / Steps;
    y := AY0 + dy * i / Steps;
    if MapAt(Floor(x), Floor(y)) <> 0 then Exit(False);
  end;
  Result := True;
end;

{ ---------------------------------------------------------------- Bewegung -- }

procedure TAmsDoom.MovePlayer(const AInput: TAmsDoomInput; ADtMs: Integer);
var
  dt, spd, turn, mvx, mvy, nx, ny, dirX, dirY, sideX, sideY: Double;
begin
  dt := ADtMs / 1000.0;
  spd := MOVE_SPEED * dt;
  if AInput.Run then spd := spd * RUN_MULT;
  turn := TURN_SPEED * dt;

  if AInput.TurnLeft then FAngle := FAngle - turn;
  if AInput.TurnRight then FAngle := FAngle + turn;
  if AInput.MouseDX <> 0 then FAngle := FAngle + AInput.MouseDX * 0.003;

  dirX := Cos(FAngle);
  dirY := Sin(FAngle);
  sideX := Cos(FAngle + PI / 2);
  sideY := Sin(FAngle + PI / 2);

  mvx := 0; mvy := 0;
  if AInput.GoForward then begin mvx := mvx + dirX; mvy := mvy + dirY; end;
  if AInput.GoBackward then begin mvx := mvx - dirX; mvy := mvy - dirY; end;
  if AInput.StrafeLeft then begin mvx := mvx - sideX; mvy := mvy - sideY; end;
  if AInput.StrafeRight then begin mvx := mvx + sideX; mvy := mvy + sideY; end;

  { normieren, damit diagonal nicht schneller ist }
  if (mvx <> 0) or (mvy <> 0) then
  begin
    nx := Sqrt(mvx * mvx + mvy * mvy);
    mvx := mvx / nx * spd;
    mvy := mvy / nx * spd;
    FBobMs := FBobMs + ADtMs;

    nx := FPX + mvx;
    if not Blocked(nx + Sign(mvx) * 0.18, FPY) then FPX := nx;
    ny := FPY + mvy;
    if not Blocked(FPX, ny + Sign(mvy) * 0.18) then FPY := ny;
  end;
end;

procedure TAmsDoom.DoFire;
var
  i, BestI: Integer;
  dx, dy, dist, ang, diff, BestDist: Double;
begin
  if FAmmo <= 0 then
  begin
    SetMessage('Keine Munition! Munitionskisten aufsammeln.');
    Exit;
  end;
  Dec(FAmmo);
  FMuzzleMs := 90;
  FFireCoolMs := FIRE_COOL;

  BestI := -1;
  BestDist := HIT_RANGE;
  for i := 0 to High(FEnemies) do
  begin
    if not FEnemies[i].Active then Continue;
    if not FEnemies[i].Alive then Continue;
    dx := FEnemies[i].X - FPX;
    dy := FEnemies[i].Y - FPY;
    dist := Sqrt(dx * dx + dy * dy);
    if dist > HIT_RANGE then Continue;
    ang := ArcTan2(dy, dx);
    diff := ang - FAngle;
    while diff > PI do diff := diff - 2 * PI;
    while diff < -PI do diff := diff + 2 * PI;
    if Abs(diff) > HIT_ANGLE then Continue;
    if not LineClear(FPX, FPY, FEnemies[i].X, FEnemies[i].Y) then Continue;
    if dist < BestDist then
    begin
      BestDist := dist;
      BestI := i;
    end;
  end;

  if BestI >= 0 then
  begin
    Dec(FEnemies[BestI].HP, 10 + Random(6));
    if FEnemies[BestI].HP <= 0 then
    begin
      FEnemies[BestI].Alive := False;
      FEnemies[BestI].State := esDie;
      FEnemies[BestI].Frame := 0;
      FEnemies[BestI].AnimMs := 0;
      Inc(FKills);
      if FKills >= FMonsters then
        SetMessage('Alle Gegner erledigt! Sektor gesaeubert.')
      else
        SetMessage('Treffer!');
    end
    else
    begin
      FEnemies[BestI].State := esPain;
      FEnemies[BestI].AnimMs := 0;
    end;
  end;
end;

procedure TAmsDoom.UpdateEnemies(ADtMs: Integer);
var
  i: Integer;
  dx, dy, dist, ang, spd, nx, ny: Double;
  E: ^TAmsEnemy;
begin
  spd := (MOVE_SPEED * 0.45) * (ADtMs / 1000.0);
  for i := 0 to High(FEnemies) do
  begin
    E := @FEnemies[i];
    if not E^.Active then Continue;

    E^.AnimMs := E^.AnimMs + ADtMs;
    if E^.AttackCoolMs > 0 then Dec(E^.AttackCoolMs, ADtMs);

    case E^.State of
      esDie:
        begin
          if E^.AnimMs > 90 then
          begin
            E^.AnimMs := 0;
            Inc(E^.Frame);
            if E^.Frame >= High(FMonDie) then
            begin
              E^.Frame := High(FMonDie);
              E^.State := esDead;
            end;
          end;
          Continue;
        end;
      esDead:
        Continue;
      esPain:
        begin
          if E^.AnimMs > 120 then E^.State := esWalk;
        end;
    end;

    if not E^.Alive then Continue;

    { Gehanimation }
    if E^.AnimMs > 150 then
    begin
      E^.AnimMs := 0;
      E^.Frame := (E^.Frame + 1) and 3;
    end;

    dx := FPX - E^.X;
    dy := FPY - E^.Y;
    dist := Sqrt(dx * dx + dy * dy);

    { Sieht der Gegner den Spieler? Dann naeherkommen. }
    if (dist < 12) and LineClear(E^.X, E^.Y, FPX, FPY) then
    begin
      if dist > 1.2 then
      begin
        ang := ArcTan2(dy, dx);
        nx := E^.X + Cos(ang) * spd;
        ny := E^.Y + Sin(ang) * spd;
        if not Blocked(nx, E^.Y) then E^.X := nx;
        if not Blocked(E^.X, ny) then E^.Y := ny;
      end
      else if (E^.AttackCoolMs <= 0) and not FDead then
      begin
        { Nahangriff }
        E^.AttackCoolMs := 900;
        Dec(FHealth, ENEMY_DMG + Random(6));
        FHurtFlashMs := 120;
        if FHealth <= 0 then
        begin
          FHealth := 0;
          FDead := True;
          SetMessage('Du bist gefallen. Leertaste fuer neuen Versuch.');
        end;
      end;
    end;
  end;
end;

procedure TAmsDoom.CheckPickups;
var
  i: Integer;
  dx, dy: Double;
begin
  for i := 0 to High(FPickups) do
  begin
    if not FPickups[i].Active or FPickups[i].Taken then Continue;
    dx := FPickups[i].X - FPX;
    dy := FPickups[i].Y - FPY;
    if dx * dx + dy * dy < 0.20 then
    begin
      FPickups[i].Taken := True;
      if FPickups[i].Kind = 0 then
      begin
        Inc(FHealth, 25);
        if FHealth > 100 then FHealth := 100;
        SetMessage('Gesundheit +25');
      end
      else
      begin
        Inc(FAmmo, 20);
        SetMessage('Munition +20');
      end;
    end;
  end;
end;

procedure TAmsDoom.SetMessage(const AText: string);
begin
  FMessage := AText;
  FMessageMs := 2500;
end;

procedure TAmsDoom.Tick(const AInput: TAmsDoomInput; ADtMs: Integer);
begin
  if ADtMs <= 0 then ADtMs := 1;
  if FMessageMs > 0 then
  begin
    Dec(FMessageMs, ADtMs);
    if FMessageMs <= 0 then FMessage := '';
  end;
  if FMuzzleMs > 0 then Dec(FMuzzleMs, ADtMs);
  if FHurtFlashMs > 0 then Dec(FHurtFlashMs, ADtMs);
  if FFireCoolMs > 0 then Dec(FFireCoolMs, ADtMs);

  if FDead then
  begin
    { Nur Neustart erlauben. }
    if AInput.Use or AInput.Fire then NewGame;
    UpdateEnemies(ADtMs);   { Gegner laufen weiter, wirken aber nicht mehr }
    Exit;
  end;

  MovePlayer(AInput, ADtMs);
  if AInput.Fire and (FFireCoolMs <= 0) then DoFire;
  UpdateEnemies(ADtMs);
  CheckPickups;
end;

{ ---------------------------------------------------------------- Rendern --- }

procedure TAmsDoom.RenderFloorCeil(ABuf: PAmsPixelBuf; AW, AH: Integer);
var
  y, x, halfH, p: Integer;
  posZ, rowDist, stepX, stepY, fx, fy: Double;
  rdX0, rdY0, rdX1, rdY1, dirX, dirY, planeX, planeY: Double;
  cellX, cellY, tx, ty, fShade, cShade: Integer;
  fIdx, cIdx: Byte;
begin
  dirX := Cos(FAngle); dirY := Sin(FAngle);
  planeX := -Sin(FAngle) * FOV; planeY := Cos(FAngle) * FOV;
  rdX0 := dirX - planeX; rdY0 := dirY - planeY;
  rdX1 := dirX + planeX; rdY1 := dirY + planeY;
  halfH := AH div 2;
  posZ := 0.5 * AH;

  for y := halfH + 1 to AH - 1 do
  begin
    p := y - halfH;
    rowDist := posZ / p;
    stepX := rowDist * (rdX1 - rdX0) / AW;
    stepY := rowDist * (rdY1 - rdY0) / AW;
    fx := FPX + rowDist * rdX0;
    fy := FPY + rowDist * rdY0;

    { Tiefen-Schattierung: fern = dunkler. }
    fShade := 256 - Round(rowDist * 20);
    if fShade < 40 then fShade := 40;
    if fShade > 256 then fShade := 256;
    cShade := fShade;

    for x := 0 to AW - 1 do
    begin
      cellX := Floor(fx);
      cellY := Floor(fy);
      tx := (Floor(FFloor.W * (fx - cellX))) and (FFloor.W - 1);
      ty := (Floor(FFloor.H * (fy - cellY))) and (FFloor.H - 1);
      fIdx := FFloor.Pix[ty * FFloor.W + tx];
      cIdx := FCeil.Pix[((ty) and (FCeil.H - 1)) * FCeil.W + (tx and (FCeil.W - 1))];

      ABuf^[y * AW + x] := AmsShade(FPal[fIdx], fShade);
      ABuf^[(AH - y - 1) * AW + x] := AmsShade(FPal[cIdx], cShade);

      fx := fx + stepX;
      fy := fy + stepY;
    end;
  end;
end;

procedure TAmsDoom.RenderWalls(ABuf: PAmsPixelBuf; AW, AH: Integer);
var
  x, mapX, mapY, stepX, stepY, side, lineH, drawStart, drawEnd, y, texX, texY: Integer;
  cameraX, rayDirX, rayDirY, deltaX, deltaY, sideDistX, sideDistY: Double;
  perpDist, wallX, texStep, texPos: Double;
  dirX, dirY, planeX, planeY: Double;
  hit: Boolean;
  cell: Byte;
  Tex: ^TAmsDoomTexture;
  shade: Integer;
begin
  dirX := Cos(FAngle); dirY := Sin(FAngle);
  planeX := -Sin(FAngle) * FOV; planeY := Cos(FAngle) * FOV;

  for x := 0 to AW - 1 do
  begin
    cameraX := 2 * x / AW - 1;
    rayDirX := dirX + planeX * cameraX;
    rayDirY := dirY + planeY * cameraX;
    mapX := Floor(FPX);
    mapY := Floor(FPY);

    if rayDirX = 0 then deltaX := 1e30 else deltaX := Abs(1 / rayDirX);
    if rayDirY = 0 then deltaY := 1e30 else deltaY := Abs(1 / rayDirY);

    if rayDirX < 0 then
    begin
      stepX := -1;
      sideDistX := (FPX - mapX) * deltaX;
    end
    else
    begin
      stepX := 1;
      sideDistX := (mapX + 1.0 - FPX) * deltaX;
    end;
    if rayDirY < 0 then
    begin
      stepY := -1;
      sideDistY := (FPY - mapY) * deltaY;
    end
    else
    begin
      stepY := 1;
      sideDistY := (mapY + 1.0 - FPY) * deltaY;
    end;

    hit := False;
    side := 0;
    cell := 0;
    while not hit do
    begin
      if sideDistX < sideDistY then
      begin
        sideDistX := sideDistX + deltaX;
        mapX := mapX + stepX;
        side := 0;
      end
      else
      begin
        sideDistY := sideDistY + deltaY;
        mapY := mapY + stepY;
        side := 1;
      end;
      if (mapX < 0) or (mapY < 0) or (mapX >= DOOM_MAP_W) or (mapY >= DOOM_MAP_H) then
      begin
        cell := 1;
        hit := True;
      end
      else
      begin
        cell := FMap[mapY * DOOM_MAP_W + mapX];
        if cell <> 0 then hit := True;
      end;
    end;

    if side = 0 then perpDist := (sideDistX - deltaX)
    else perpDist := (sideDistY - deltaY);
    if perpDist < 0.0001 then perpDist := 0.0001;
    FZBuf[x] := perpDist;

    lineH := Round(AH / perpDist);
    drawStart := -lineH div 2 + AH div 2;
    drawEnd := lineH div 2 + AH div 2;
    if drawStart < 0 then drawStart := 0;
    if drawEnd >= AH then drawEnd := AH - 1;

    { Textur der getroffenen Zelle. }
    if (cell >= 1) and (cell <= Length(FWallTex)) then
      Tex := @FWallTex[cell - 1]
    else
      Tex := @FWallTex[0];

    if side = 0 then wallX := FPY + perpDist * rayDirY
    else wallX := FPX + perpDist * rayDirX;
    wallX := wallX - Floor(wallX);
    texX := Trunc(wallX * Tex^.W);
    if (side = 0) and (rayDirX > 0) then texX := Tex^.W - texX - 1;
    if (side = 1) and (rayDirY < 0) then texX := Tex^.W - texX - 1;
    if texX < 0 then texX := 0;
    if texX >= Tex^.W then texX := Tex^.W - 1;

    shade := 256 - Round(perpDist * 18);
    if side = 1 then shade := shade - 40;    { Y-Seiten dunkler (DOOM-Look) }
    if shade < 40 then shade := 40;
    if shade > 256 then shade := 256;

    texStep := Tex^.H / lineH;
    texPos := (drawStart - AH / 2 + lineH / 2) * texStep;
    for y := drawStart to drawEnd do
    begin
      texY := Trunc(texPos);
      if texY < 0 then texY := 0;
      if texY >= Tex^.H then texY := Tex^.H - 1;
      texPos := texPos + texStep;
      ABuf^[y * AW + x] := AmsShade(FPal[Tex^.Pix[texY * Tex^.W + texX]], shade);
    end;
  end;
end;

{ Ein Sprite spaltenweise zeichnen: vom Bildschirm-X in die Textur-Spalte,
  senkrecht skaliert, mit Maske und Z-Test. }
procedure TAmsDoom.DrawPicColumnScaled(ABuf: PAmsPixelBuf; AW, AH: Integer;
  const APic: TAmsPic; AScreenX, ADrawStartY, ADrawEndY, ATexX: Integer;
  AScaleH: Integer; AShade: Integer; AUseZ: Boolean; ADist: Double);
var
  y, texY, d: Integer;
  Src: Integer;
begin
  if (AScreenX < 0) or (AScreenX >= AW) then Exit;
  if AUseZ and (ADist >= FZBuf[AScreenX]) then Exit;
  if (ATexX < 0) or (ATexX >= APic.Width) then Exit;
  if AScaleH <= 0 then Exit;

  for y := ADrawStartY to ADrawEndY do
  begin
    if (y < 0) or (y >= AH) then Continue;
    d := y - (AH div 2 - AScaleH div 2);
    texY := (d * APic.Height) div AScaleH;
    if (texY < 0) or (texY >= APic.Height) then Continue;
    Src := texY * APic.Width + ATexX;
    if (Src < 0) or (Src >= Length(APic.Mask)) then Continue;
    if APic.Mask[Src] = 0 then Continue;
    ABuf^[y * AW + AScreenX] := AmsShade(FPal[APic.Pixels[Src]], AShade);
  end;
end;

procedure TAmsDoom.RenderSprites(ABuf: PAmsPixelBuf; AW, AH: Integer);
type
  TVis = record
    X, Y: Double;
    Dist: Double;
    IsEnemy: Boolean;
    Idx: Integer;
  end;
var
  Vis: array of TVis;
  n, i, j: Integer;
  tmp: TVis;
  dx, dy, invDet, transX, transY: Double;
  planeX, planeY, dirX, dirY: Double;
  spriteScreenX, spriteH, spriteW, drawStartX, drawEndX, drawStartY, drawEndY: Integer;
  stripe, texX, shade: Integer;
  Pic: ^TAmsPic;
  frameIdx: Integer;
begin
  dirX := Cos(FAngle); dirY := Sin(FAngle);
  planeX := -Sin(FAngle) * FOV; planeY := Cos(FAngle) * FOV;

  { Sichtbare Sprites sammeln (Gegner + Aufsammelbares). }
  n := 0;
  SetLength(Vis, Length(FEnemies) + Length(FPickups));
  for i := 0 to High(FEnemies) do
    if FEnemies[i].Active then
    begin
      Vis[n].X := FEnemies[i].X; Vis[n].Y := FEnemies[i].Y;
      Vis[n].IsEnemy := True; Vis[n].Idx := i;
      dx := FEnemies[i].X - FPX; dy := FEnemies[i].Y - FPY;
      Vis[n].Dist := dx * dx + dy * dy;
      Inc(n);
    end;
  for i := 0 to High(FPickups) do
    if FPickups[i].Active and not FPickups[i].Taken then
    begin
      Vis[n].X := FPickups[i].X; Vis[n].Y := FPickups[i].Y;
      Vis[n].IsEnemy := False; Vis[n].Idx := i;
      dx := FPickups[i].X - FPX; dy := FPickups[i].Y - FPY;
      Vis[n].Dist := dx * dx + dy * dy;
      Inc(n);
    end;
  SetLength(Vis, n);

  { fern -> nah sortieren (Insertion Sort, n ist klein). }
  for i := 1 to n - 1 do
  begin
    tmp := Vis[i];
    j := i - 1;
    while (j >= 0) and (Vis[j].Dist < tmp.Dist) do
    begin
      Vis[j + 1] := Vis[j];
      Dec(j);
    end;
    Vis[j + 1] := tmp;
  end;

  for i := 0 to n - 1 do
  begin
    dx := Vis[i].X - FPX;
    dy := Vis[i].Y - FPY;

    { in Kamerakoordinaten transformieren }
    invDet := 1.0 / (planeX * dirY - dirX * planeY);
    transX := invDet * (dirY * dx - dirX * dy);
    transY := invDet * (-planeY * dx + planeX * dy);
    if transY <= 0.05 then Continue;    { hinter der Kamera }

    spriteScreenX := Round((AW / 2) * (1 + transX / transY));

    { passendes Bild + Groesse waehlen }
    if Vis[i].IsEnemy then
    begin
      case FEnemies[Vis[i].Idx].State of
        esDie, esDead:
          begin
            frameIdx := FEnemies[Vis[i].Idx].Frame;
            if frameIdx > High(FMonDie) then frameIdx := High(FMonDie);
            Pic := @FMonDie[frameIdx];
          end;
      else
        begin
          frameIdx := FEnemies[Vis[i].Idx].Frame and 3;
          Pic := @FMonWalk[frameIdx];
        end;
      end;
    end
    else
      Pic := @FItemPic[FPickups[Vis[i].Idx].Kind];

    if (Pic^.Width <= 0) or (Pic^.Height <= 0) then Continue;

    spriteH := Round(Abs(AH / transY) * (Pic^.Height / 64.0));
    if spriteH <= 0 then Continue;
    spriteW := Round(spriteH * (Pic^.Width / Pic^.Height));
    if spriteW <= 0 then Continue;

    { senkrecht auf dem Boden aufsetzen: TopOffset/Boden beruecksichtigen -
      vereinfacht auf "steht auf dem Boden". }
    drawStartY := AH div 2 - spriteH div 2 + Round((AH / transY) * 0.20);
    drawEndY := drawStartY + spriteH;
    drawStartX := spriteScreenX - spriteW div 2;
    drawEndX := spriteScreenX + spriteW div 2;

    shade := 256 - Round(transY * 18);
    if shade < 60 then shade := 60;
    if shade > 256 then shade := 256;

    for stripe := drawStartX to drawEndX do
    begin
      if (stripe < 0) or (stripe >= AW) then Continue;
      texX := ((stripe - drawStartX) * Pic^.Width) div spriteW;
      DrawPicColumnScaled(ABuf, AW, AH, Pic^, stripe, drawStartY, drawEndY,
        texX, spriteH, shade, True, transY);
    end;
  end;
end;

procedure TAmsDoom.RenderWeapon(ABuf: PAmsPixelBuf; AW, AH: Integer);
var
  Pic: ^TAmsPic;
  scale, gw, gh, ox, oy, x, y, tx, ty, bob: Integer;
  Src: Integer;
begin
  if FMuzzleMs > 0 then Pic := @FGunFire else Pic := @FGun;
  if (Pic^.Width <= 0) or (Pic^.Height <= 0) then Exit;

  { Die Waffe fuellt etwa die halbe Bildhoehe. }
  scale := (AH div 2) div Max(1, Pic^.Height);
  if scale < 1 then scale := 1;
  gw := Pic^.Width * scale;
  gh := Pic^.Height * scale;
  bob := Round(Sin(FBobMs / 180.0) * 4);
  ox := (AW - gw) div 2;
  oy := AH - gh + Abs(bob);

  for y := 0 to gh - 1 do
  begin
    ty := y div scale;
    if (ty < 0) or (ty >= Pic^.Height) then Continue;
    for x := 0 to gw - 1 do
    begin
      tx := x div scale;
      if (tx < 0) or (tx >= Pic^.Width) then Continue;
      Src := ty * Pic^.Width + tx;
      if (Src >= Length(Pic^.Mask)) or (Pic^.Mask[Src] = 0) then Continue;
      if (ox + x < 0) or (ox + x >= AW) or (oy + y < 0) or (oy + y >= AH) then Continue;
      ABuf^[(oy + y) * AW + (ox + x)] := FPal[Pic^.Pixels[Src]];
    end;
  end;
end;

procedure TAmsDoom.Render(ABuf: PAmsPixelBuf; AW, AH: Integer);
var
  i, n: Integer;
  cx, cy: Integer;
  flash: TAmsPixel;
begin
  if ABuf = nil then Exit;
  if (AW <= 0) or (AH <= 0) then Exit;
  if Length(FZBuf) <> AW then SetLength(FZBuf, AW);

  RenderFloorCeil(ABuf, AW, AH);
  RenderWalls(ABuf, AW, AH);
  RenderSprites(ABuf, AW, AH);
  RenderWeapon(ABuf, AW, AH);

  { Fadenkreuz }
  cx := AW div 2; cy := AH div 2;
  for i := -3 to 3 do
  begin
    if (cx + i >= 0) and (cx + i < AW) then ABuf^[cy * AW + (cx + i)] := $00FFFFFF;
    if (cy + i >= 0) and (cy + i < AH) then ABuf^[(cy + i) * AW + cx] := $00FFFFFF;
  end;

  { Schmerz-/Tod-Rotstich }
  if (FHurtFlashMs > 0) or FDead then
  begin
    if FDead then flash := $00400000 else flash := $00300000;
    n := AW * AH;
    for i := 0 to n - 1 do
      ABuf^[i] := AmsRGB(
        Min(255, ((ABuf^[i] shr 16) and $FF) + ((flash shr 16) and $FF)),
        (ABuf^[i] shr 8) and $FF,
        ABuf^[i] and $FF);
  end;
end;

end.
