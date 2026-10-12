unit AmsApi.PluginStore;

{ ============================================================================
  AmsApi.PluginStore - woher Plugins kommen, was installiert ist, was neu ist

  Das Modell hinter dem Plugin Manager, ohne jedes Fenster. Alles hier ist
  ohne AMS testbar und darf im Hintergrundthread laufen.

  WOHER: ein KATALOG - eine INI-Datei, irgendwo erreichbar (GitHub, Webserver,
  Netzlaufwerk, lokaler Ordner). Jeder Abschnitt ist ein Plugin:

      [HelloButton]
      Repo=github:aizpun-flowtech/amsapi      ; oder https://github.com/o/r
      Path=samples/HelloButton                ; Unterordner im Repo (optional)

      [Intern]
      Base=\\server\ams\plugins\Intern\       ; Ordner oder URL, relativ zum
                                              ; Katalog erlaubt

  Ausgeliefert wird NICHT der Quelltext - auf den Arbeitsplaetzen gibt es
  weder git noch einen Compiler -, sondern das fertige Paket:

    github:  Release-Assets <Name>.zip (BPL, plugin.ini, Bild, README) und
             <Name>.ini (die plugin.ini, fuer Version und Beschreibung, ohne
             das ganze ZIP zu laden), gefunden ueber
             github.com/<o>/<r>/releases/latest/download/<Asset>.
             Kein API-Aufruf, also kein Limit von 60 Anfragen je Stunde -
             das traefe eine Firma hinter EINER Adresse sonst sofort.
             README und Bilder roh aus dem Repo (raw.githubusercontent.com).
             Mit Token (private Repos): Releases ueber die API, Rohdateien
             mit Authorization-Header. Der Token geht NUR an GitHub-Hosts.
    Base:    <Base><Name>.zip, <Base>plugin.ini, <Base>README.md. Liegt dort
             statt eines ZIP direkt der Plugin-Ordner, wird er kopiert.

  Jeder Schluessel laesst sich einzeln ueberschreiben: Package=, Meta=,
  Readme=, Icon=, Page=, Asset=, MetaAsset=, Branch=, Tag= (feste Version
  statt latest), Sha256= (Paket muss genau diese Pruefsumme haben).
  Title=, Description=, Version=, Author= im Katalog gelten, solange die
  plugin.ini der Quelle nicht zu holen ist.

  WAS INSTALLIERT IST: jeder Ordner unter BIN\plugins mit einer plugin.ini.
  Deren Kopf (Name, Module, Version, LargeGlyph) liest auch AMS; alles fuer
  den Manager steht im Abschnitt [Info] (Title, Description, Author,
  License, Homepage, Icon, Tags) - der Host stoert sich nicht daran.

  BEREITSTELLEN (AmsStagePlugin): Paket laden, Pruefsumme, entpacken (mit
  Zip-Slip-Schutz), plugin.ini pruefen, die Werte des Anwenders aus der
  installierten plugin.ini uebernehmen. Das Ergebnis ist ein fertiger
  Ordner; hineinkopiert wird er von AmsApi.PluginApply - dafuer braucht es
  meist Administratorrechte, dafuer hier nicht.

  Zeichensatz: Texte bleiben Bytes wie in der Quelle (UTF-8 oder ANSI);
  AmsDecodeText fuer die Anzeige, AmsToUtf8 fuer HTML.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, Contnrs;

type
  TAmsPluginState = (
    psAvailable,   { im Katalog, nicht installiert }
    psInstalled,   { installiert, aktuell }
    psUpdate,      { installiert, Katalog hat eine neuere Version }
    psNewer,       { installiert neuer als im Katalog }
    psLocal        { installiert, in keinem Katalog }
  );

  TAmsSourceKind = (skNone, skGitHub, skBase);

  TAmsStoreConfig = record
    PluginsDir: string;   { BIN\plugins\ }
    CacheDir: string;     { %LOCALAPPDATA%\AmsPluginManager\ }
    Catalogs: string;     { Quellen, mit | getrennt }
    Token: string;        { GitHub, optional }
  end;

  TAmsPluginInfo = class
  public
    Name: string;
    Title, Description, Author, License, Homepage, Tags: string;
    Module: string;
    { Bezugsquelle }
    InCatalog: Boolean;
    Catalog: string;
    Kind: TAmsSourceKind;
    GhOwner, GhRepo, GhPath, GhBranch, GhTag: string;
    Base: string;
    PackageAsset, MetaAsset: string;
    PackageUrl, MetaUrl, MetaFallbackUrl, ReadmeUrl, IconUrl, PageUrl: string;
    ApiPackageUrl, ApiMetaUrl: string;   { nur mit Token }
    ImageBase, LinkBase: string;
    Sha256: string;
    AvailableVersion: string;
    MetaError: string;
    { Installation }
    Installed: Boolean;
    InstalledVersion: string;
    InstalledDir: string;
    IconFile: string;      { lokale Bilddatei }
    ReadmeFile: string;    { lokale README.md (installiert) }
    function State: TAmsPluginState;
    function DisplayTitle: string;
    procedure Assign(ASource: TAmsPluginInfo);
  end;

  TAmsPluginList = class(TObjectList)
  private
    function GetInfo(AIndex: Integer): TAmsPluginInfo;
  public
    constructor Create;
    function Find(const AName: string): TAmsPluginInfo;
    procedure SortByTitle;
    property Infos[AIndex: Integer]: TAmsPluginInfo read GetInfo; default;
  end;

const
  AMS_STORE_SUBDIR = 'AmsPluginManager';
  { Was das Paket bestimmt und beim Aktualisieren NICHT vom Anwender
    uebernommen wird. }
  AMS_PACKAGE_OWNED: array[0..3] of string =
    ('.Name', '.Module', '.Version', 'Info.*');

{ Vergleich wie 1.2.10 > 1.2.9; fuehrendes v wird ignoriert, eine
  Vorabversion (1.0.0-beta) ist kleiner als die fertige. -1 / 0 / 1. }
function AmsCompareVersions(const A, B: string): Integer;

function AmsStateText(AState: TAmsPluginState): string;

{ BIN\plugins\ aus dem Ort des eigenen Moduls (BIN\plugins\<Plugin>\x.bpl). }
function AmsPluginsDirOfModule: string;

{ Holen - http(s) ueber AmsHttpGet, sonst als Datei (Pfad, \\UNC, file:///).
  Der Token geht nur an GitHub. False bei Fehler und bei Status <> 200. }
function AmsStoreFetch(const AConfig: TAmsStoreConfig; const AUrl: string;
  out AData: string; AMaxBytes: Int64 = 0; const AAccept: string = ''): Boolean;
function AmsStoreDownload(const AConfig: TAmsStoreConfig;
  const AUrl, ADestFile: string; const AAccept: string = ''): Boolean;

{ github:o/r, github:o/r/pfad, https://github.com/o/r(.git)(/tree/zweig/pfad) }
function AmsParseRepoSpec(const ASpec: string; out AOwner, ARepo,
  APath: string): Boolean;

{ Einen Katalogabschnitt (Name=Wert-Zeilen) in eine Bezugsquelle aufloesen.
  ACatalogUrl ist die Basis fuer relative Base=-Angaben. }
procedure AmsResolveSource(AInfo: TAmsPluginInfo; AKeys: TStrings;
  const ACatalogUrl: string);

{ Katalogtext lesen; jeder Abschnitt wird ein Eintrag. }
function AmsParseCatalog(const AText, ACatalogUrl: string;
  AList: TAmsPluginList): Integer;

{ plugin.ini-Text (Kopf + [Info]) uebernehmen. AInstalled = True setzt die
  installierte Version, sonst die verfuegbare. }
procedure AmsApplyMeta(AInfo: TAmsPluginInfo; const AIniText: string;
  AInstalled: Boolean);

{ Installierte Plugins unter APluginsDir. }
function AmsScanInstalled(const APluginsDir: string;
  AList: TAmsPluginList): Integer;

{ Katalog und Installiertes zusammenfuehren (nach Name). }
procedure AmsMergeInstalled(ACatalog, AInstalled, AResult: TAmsPluginList);

{ Alles in einem, fuer den Hintergrundthread: installierte lesen, Kataloge
  holen, je Plugin Metadaten und Bild. AOffline = nur der Zwischenspeicher
  der letzten Runde - schnell, fuer die erste Anzeige. ALog bekommt eine
  Zeile je Quelle und je Fehler. ACancel wird zwischendurch abgefragt. }
function AmsStoreRefresh(const AConfig: TAmsStoreConfig; AResult: TAmsPluginList;
  ALog: TStrings; AOffline: Boolean; ACancel: PBoolean = nil): Boolean;

{ README holen: aus der Quelle, sonst die installierte. Liefert die Bytes
  und die Basen fuer relative Bilder und Links. }
function AmsStoreFetchReadme(const AConfig: TAmsStoreConfig;
  AInfo: TAmsPluginInfo; out AMarkdown, AImageBase, ALinkBase: string): Boolean;

{ Paket bereitstellen - siehe Kopf. AStageDir = fertiger Plugin-Ordner. }
function AmsStagePlugin(const AConfig: TAmsStoreConfig; AInfo: TAmsPluginInfo;
  out AStageDir: string): Boolean;

implementation

uses
  fpjson, jsonparser, AmsApi.Log, AmsApi.Ini, AmsApi.IniDoc, AmsApi.Files,
  AmsApi.Http, AmsApi.Zip, AmsApi.Markdown;

const
  META_MAX    = 256 * 1024;
  ICON_MAX    = 1024 * 1024;
  README_MAX  = 2 * 1024 * 1024;
  CATALOG_MAX = 1024 * 1024;
  PACKAGE_MAX = 256 * 1024 * 1024;

{ ------------------------------------------------------------ TAmsPlugin - }

function TAmsPluginInfo.State: TAmsPluginState;
var
  C: Integer;
begin
  if not Installed then Exit(psAvailable);
  if not InCatalog then Exit(psLocal);
  if AvailableVersion = '' then Exit(psInstalled);
  C := AmsCompareVersions(AvailableVersion, InstalledVersion);
  if C > 0 then Result := psUpdate
  else if C < 0 then Result := psNewer
  else Result := psInstalled;
end;

function TAmsPluginInfo.DisplayTitle: string;
begin
  if Title <> '' then Result := Title else Result := Name;
end;

procedure TAmsPluginInfo.Assign(ASource: TAmsPluginInfo);
begin
  Name := ASource.Name;
  Title := ASource.Title;
  Description := ASource.Description;
  Author := ASource.Author;
  License := ASource.License;
  Homepage := ASource.Homepage;
  Tags := ASource.Tags;
  Module := ASource.Module;
  InCatalog := ASource.InCatalog;
  Catalog := ASource.Catalog;
  Kind := ASource.Kind;
  GhOwner := ASource.GhOwner;
  GhRepo := ASource.GhRepo;
  GhPath := ASource.GhPath;
  GhBranch := ASource.GhBranch;
  GhTag := ASource.GhTag;
  Base := ASource.Base;
  PackageAsset := ASource.PackageAsset;
  MetaAsset := ASource.MetaAsset;
  PackageUrl := ASource.PackageUrl;
  MetaUrl := ASource.MetaUrl;
  MetaFallbackUrl := ASource.MetaFallbackUrl;
  ReadmeUrl := ASource.ReadmeUrl;
  IconUrl := ASource.IconUrl;
  PageUrl := ASource.PageUrl;
  ApiPackageUrl := ASource.ApiPackageUrl;
  ApiMetaUrl := ASource.ApiMetaUrl;
  ImageBase := ASource.ImageBase;
  LinkBase := ASource.LinkBase;
  Sha256 := ASource.Sha256;
  AvailableVersion := ASource.AvailableVersion;
  MetaError := ASource.MetaError;
  Installed := ASource.Installed;
  InstalledVersion := ASource.InstalledVersion;
  InstalledDir := ASource.InstalledDir;
  IconFile := ASource.IconFile;
  ReadmeFile := ASource.ReadmeFile;
end;

constructor TAmsPluginList.Create;
begin
  inherited Create(True);
end;

function TAmsPluginList.GetInfo(AIndex: Integer): TAmsPluginInfo;
begin
  Result := TAmsPluginInfo(Items[AIndex]);
end;

function TAmsPluginList.Find(const AName: string): TAmsPluginInfo;
var
  i: Integer;
begin
  for i := 0 to Count - 1 do
    if SameText(Infos[i].Name, AName) then Exit(Infos[i]);
  Result := nil;
end;

function CompareTitles(A, B: Pointer): Integer;
begin
  Result := AnsiCompareText(TAmsPluginInfo(A).DisplayTitle,
                            TAmsPluginInfo(B).DisplayTitle);
end;

procedure TAmsPluginList.SortByTitle;
begin
  Sort(@CompareTitles);
end;

{ ------------------------------------------------------------- Versionen - }

function AmsCompareVersions(const A, B: string): Integer;

  procedure Split(const S: string; out ANum, APre: string);
  var
    p: Integer;
    T: string;
  begin
    T := Trim(S);
    if (T <> '') and (T[1] in ['v', 'V']) then Delete(T, 1, 1);
    p := Pos('-', T);
    if p = 0 then p := Pos('+', T);
    if p > 0 then
    begin
      ANum := Copy(T, 1, p - 1);
      APre := Copy(T, p + 1, MaxInt);
      p := Pos('+', APre);           { Build-Metadaten zaehlen nicht }
      if p > 0 then APre := Copy(APre, 1, p - 1);
    end
    else
    begin
      ANum := T;
      APre := '';
    end;
  end;

  function NextPart(var S: string): string;
  var
    p: Integer;
  begin
    p := Pos('.', S);
    if p = 0 then
    begin
      Result := S;
      S := '';
    end
    else
    begin
      Result := Copy(S, 1, p - 1);
      Delete(S, 1, p);
    end;
  end;

  function CmpPart(const X, Y: string): Integer;
  var
    NX, NY: Int64;
    OkX, OkY: Boolean;
  begin
    OkX := TryStrToInt64(X, NX);
    OkY := TryStrToInt64(Y, NY);
    if OkX and OkY then
    begin
      if NX < NY then Exit(-1);
      if NX > NY then Exit(1);
      Exit(0);
    end;
    if OkX then Exit(-1);            { Zahl < Text, wie SemVer }
    if OkY then Exit(1);
    Result := CompareText(X, Y);
    if Result < 0 then Result := -1 else if Result > 0 then Result := 1;
  end;

var
  NA, PA, NB, PB, X, Y: string;
begin
  Split(A, NA, PA);
  Split(B, NB, PB);
  while (NA <> '') or (NB <> '') do
  begin
    X := NextPart(NA);
    Y := NextPart(NB);
    if X = '' then X := '0';
    if Y = '' then Y := '0';
    Result := CmpPart(X, Y);
    if Result <> 0 then Exit;
  end;
  { Gleicher Kern: ohne Vorabkennung ist groesser }
  if (PA = '') and (PB = '') then Exit(0);
  if PA = '' then Exit(1);
  if PB = '' then Exit(-1);
  while (PA <> '') or (PB <> '') do
  begin
    if PA = '' then Exit(-1);
    if PB = '' then Exit(1);
    X := NextPart(PA);
    Y := NextPart(PB);
    Result := CmpPart(X, Y);
    if Result <> 0 then Exit;
  end;
  Result := 0;
end;

function AmsStateText(AState: TAmsPluginState): string;
begin
  case AState of
    psAvailable: Result := 'Nicht installiert';
    psInstalled: Result := 'Installiert';
    psUpdate:    Result := 'Update verfuegbar';
    psNewer:     Result := 'Neuer als Katalog';
    psLocal:     Result := 'Lokal installiert';
  else
    Result := '?';
  end;
end;

function AmsPluginsDirOfModule: string;
begin
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(AmsModuleDir));
end;

{ ----------------------------------------------------------------- Holen -- }

function IsHttp(const AUrl: string): Boolean;
var
  L: string;
begin
  L := LowerCase(AUrl);
  Result := (Pos('http://', L) = 1) or (Pos('https://', L) = 1);
end;

function HostOfUrl(const AUrl: string): string;
var
  p, q: Integer;
begin
  Result := '';
  p := Pos('://', AUrl);
  if p = 0 then Exit;
  q := p + 3;
  while (q <= Length(AUrl)) and not (AUrl[q] in ['/', '?', '#', ':']) do Inc(q);
  Result := LowerCase(Copy(AUrl, p + 3, q - p - 3));
end;

function IsGitHubHost(const AUrl: string): Boolean;
var
  H: string;
begin
  H := HostOfUrl(AUrl);
  Result := (H = 'github.com') or (H = 'api.github.com') or
            (H = 'raw.githubusercontent.com');
end;

{ file:///C:/x/y -> C:\x\y ; sonst unveraendert }
function PercentDecode(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '%') and (i + 2 <= Length(S)) and
       (S[i + 1] in ['0'..'9', 'A'..'F', 'a'..'f']) and
       (S[i + 2] in ['0'..'9', 'A'..'F', 'a'..'f']) then
    begin
      Result := Result + Chr(StrToInt('$' + Copy(S, i + 1, 2)));
      Inc(i, 3);
    end
    else
    begin
      Result := Result + S[i];
      Inc(i);
    end;
  end;
end;

function LocalPathOf(const AUrl: string): string;
var
  S: string;
  IsUrl: Boolean;
begin
  S := AUrl;
  IsUrl := Pos('file:', LowerCase(S)) = 1;
  if Pos('file:///', LowerCase(S)) = 1 then Delete(S, 1, 8)
  else if Pos('file://', LowerCase(S)) = 1 then
  begin
    Delete(S, 1, 7);
    S := '\\' + S;
  end;
  S := StringReplace(S, '/', '\', [rfReplaceAll]);
  { %20 nur in file:-URLs - in einem Pfad ist %APPDATA% gemeint }
  if IsUrl then S := PercentDecode(S)
  else S := AmsExpandEnv(S);
  Result := S;
end;

function Headers(const AConfig: TAmsStoreConfig; const AUrl, AAccept: string): string;
begin
  Result := '';
  if AAccept <> '' then Result := 'Accept: ' + AAccept;
  if (AConfig.Token <> '') and IsGitHubHost(AUrl) then
  begin
    if Result <> '' then Result := Result + AMS_HEADER_SEPARATOR;
    Result := Result + 'Authorization: token ' + AConfig.Token;
    if HostOfUrl(AUrl) = 'api.github.com' then
      Result := Result + AMS_HEADER_SEPARATOR + 'X-GitHub-Api-Version: 2022-11-28';
  end;
end;

function AmsStoreFetch(const AConfig: TAmsStoreConfig; const AUrl: string;
  out AData: string; AMaxBytes: Int64; const AAccept: string): Boolean;
var
  St: Integer;
begin
  AData := '';
  if Trim(AUrl) = '' then Exit(AmsFail('Keine Adresse'));
  if IsHttp(AUrl) then
  begin
    Result := AmsHttpGet(AUrl, Headers(AConfig, AUrl, AAccept), St, AData,
                         AMaxBytes);
    if not Result then Exit;
    if St <> 200 then
    begin
      AData := '';
      Exit(AmsFailFmt('HTTP %d: %s', [St, AUrl]));
    end;
  end
  else
    Result := AmsReadFileRaw(LocalPathOf(AUrl), AData, AMaxBytes);
end;

function AmsStoreDownload(const AConfig: TAmsStoreConfig;
  const AUrl, ADestFile: string; const AAccept: string): Boolean;
var
  St: Integer;
begin
  if IsHttp(AUrl) then
  begin
    Result := AmsHttpDownload(AUrl, Headers(AConfig, AUrl, AAccept), ADestFile,
                              St, PACKAGE_MAX);
    if Result and (St <> 200) then
      Result := AmsFailFmt('HTTP %d: %s', [St, AUrl]);
  end
  else
  begin
    AmsForceDir(ExtractFilePath(ADestFile));
    Result := CopyFileW(PWideChar(WideString(LocalPathOf(AUrl))),
                        PWideChar(WideString(ADestFile)), False);
    if not Result then
      AmsFailFmt('Datei nicht kopierbar (%d): %s', [GetLastError, AUrl]);
  end;
end;

{ ---------------------------------------------------------------- Quellen - }

function AmsParseRepoSpec(const ASpec: string; out AOwner, ARepo,
  APath: string): Boolean;
var
  S, L: string;
  Parts: TStringList;
  i: Integer;
begin
  Result := False;
  AOwner := '';
  ARepo := '';
  APath := '';
  S := Trim(ASpec);
  L := LowerCase(S);
  if Pos('github:', L) = 1 then Delete(S, 1, 7)
  else if Pos('https://github.com/', L) = 1 then Delete(S, 1, 19)
  else if Pos('http://github.com/', L) = 1 then Delete(S, 1, 18)
  else if Pos('github.com/', L) = 1 then Delete(S, 1, 11)
  else Exit;
  while (S <> '') and (S[Length(S)] = '/') do Delete(S, Length(S), 1);
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := S;
    if Parts.Count < 2 then Exit;
    AOwner := Parts[0];
    ARepo := Parts[1];
    if SameText(ExtractFileExt(ARepo), '.git') then
      ARepo := ChangeFileExt(ARepo, '');
    i := 2;
    { /tree/<zweig>/... oder /blob/<zweig>/... aus dem Browser kopiert }
    if (Parts.Count > 3) and (SameText(Parts[2], 'tree') or
                              SameText(Parts[2], 'blob')) then
      i := 4;
    while i < Parts.Count do
    begin
      if APath <> '' then APath := APath + '/';
      APath := APath + Parts[i];
      Inc(i);
    end;
    Result := AmsIsSafeName(AOwner) and AmsIsSafeName(ARepo);
  finally
    Parts.Free;
  end;
end;

function KeyOf(AKeys: TStrings; const AName: string): string;
var
  i, p: Integer;
begin
  Result := '';
  if AKeys = nil then Exit;
  for i := 0 to AKeys.Count - 1 do
  begin
    p := Pos('=', AKeys[i]);
    if (p > 1) and SameText(Copy(AKeys[i], 1, p - 1), AName) then
      Exit(Trim(Copy(AKeys[i], p + 1, MaxInt)));
  end;
end;

function WithSlash(const ABase: string): string;
begin
  Result := ABase;
  if Result = '' then Exit;
  if IsHttp(Result) or (Pos('file:', LowerCase(Result)) = 1) then
  begin
    if Result[Length(Result)] <> '/' then Result := Result + '/';
  end
  else
    Result := IncludeTrailingPathDelimiter(StringReplace(Result, '/', '\',
                                                         [rfReplaceAll]));
end;

procedure AmsResolveSource(AInfo: TAmsPluginInfo; AKeys: TStrings;
  const ACatalogUrl: string);
var
  Spec, Web, Rel, Raw, P, CatBase: string;
begin
  AInfo.Kind := skNone;
  AInfo.PackageAsset := KeyOf(AKeys, 'Asset');
  if AInfo.PackageAsset = '' then AInfo.PackageAsset := AInfo.Name + '.zip';
  AInfo.MetaAsset := KeyOf(AKeys, 'MetaAsset');
  if AInfo.MetaAsset = '' then AInfo.MetaAsset := AInfo.Name + '.ini';
  AInfo.Sha256 := LowerCase(KeyOf(AKeys, 'Sha256'));

  Spec := KeyOf(AKeys, 'Repo');
  if (Spec <> '') and AmsParseRepoSpec(Spec, AInfo.GhOwner, AInfo.GhRepo, P) then
  begin
    AInfo.Kind := skGitHub;
    AInfo.GhPath := KeyOf(AKeys, 'Path');
    if AInfo.GhPath = '' then AInfo.GhPath := P;
    AInfo.GhPath := StringReplace(AInfo.GhPath, '\', '/', [rfReplaceAll]);
    while (AInfo.GhPath <> '') and (AInfo.GhPath[1] = '/') do
      Delete(AInfo.GhPath, 1, 1);
    while (AInfo.GhPath <> '') and (AInfo.GhPath[Length(AInfo.GhPath)] = '/') do
      Delete(AInfo.GhPath, Length(AInfo.GhPath), 1);
    AInfo.GhBranch := KeyOf(AKeys, 'Branch');
    if AInfo.GhBranch = '' then AInfo.GhBranch := 'HEAD';
    AInfo.GhTag := KeyOf(AKeys, 'Tag');

    Web := 'https://github.com/' + AInfo.GhOwner + '/' + AInfo.GhRepo;
    if AInfo.GhTag <> '' then
      Rel := Web + '/releases/download/' + AInfo.GhTag + '/'
    else
      Rel := Web + '/releases/latest/download/';
    Raw := 'https://raw.githubusercontent.com/' + AInfo.GhOwner + '/' +
           AInfo.GhRepo + '/' + AInfo.GhBranch + '/';
    if AInfo.GhPath <> '' then Raw := Raw + AInfo.GhPath + '/';
    AInfo.PackageUrl := Rel + AInfo.PackageAsset;
    AInfo.MetaUrl := Rel + AInfo.MetaAsset;
    AInfo.MetaFallbackUrl := Raw + 'plugin.ini';
    AInfo.ReadmeUrl := Raw + 'README.md';
    AInfo.ImageBase := Raw;
    AInfo.LinkBase := Web + '/blob/' + AInfo.GhBranch + '/';
    if AInfo.GhPath <> '' then
      AInfo.LinkBase := AInfo.LinkBase + AInfo.GhPath + '/';
    AInfo.IconUrl := '';
    if AInfo.GhPath <> '' then
      AInfo.PageUrl := Web + '/tree/' + AInfo.GhBranch + '/' + AInfo.GhPath
    else
      AInfo.PageUrl := Web;
  end
  else
  begin
    AInfo.Base := KeyOf(AKeys, 'Base');
    if AInfo.Base <> '' then
    begin
      AInfo.Kind := skBase;
      { relativ zum Katalog. Eine URL-Basis verliert beim Aufloesen ihren
        Dateinamen von selbst, ein Pfad nicht - dort den Ordner nehmen. }
      CatBase := ACatalogUrl;
      if not IsHttp(CatBase) and (CatBase <> '') then
        CatBase := ExtractFilePath(LocalPathOf(CatBase));
      if (Pos('://', AInfo.Base) = 0) and not AmsIsAbsolutePath(AInfo.Base) and
         (CatBase <> '') then
        AInfo.Base := AmsResolveUrl(CatBase, AInfo.Base);
      AInfo.Base := WithSlash(AmsExpandEnv(AInfo.Base));
      AInfo.PackageUrl := AInfo.Base + AInfo.PackageAsset;
      { <Name>.ini zuerst: so kann build\release unveraendert auf ein
        Netzlaufwerk - alle Plugins flach in einem Ordner. Sonst ein
        Ordner je Plugin mit plugin.ini. }
      AInfo.MetaUrl := AInfo.Base + AInfo.MetaAsset;
      AInfo.MetaFallbackUrl := AInfo.Base + 'plugin.ini';
      AInfo.ReadmeUrl := AInfo.Base + 'README.md';
      AInfo.ImageBase := AInfo.Base;
      AInfo.LinkBase := AInfo.Base;
      AInfo.PageUrl := '';
    end;
  end;

  { Einzelne Angaben ueberschreiben alles Abgeleitete }
  if KeyOf(AKeys, 'Package') <> '' then AInfo.PackageUrl := KeyOf(AKeys, 'Package');
  if KeyOf(AKeys, 'Meta') <> '' then
  begin
    AInfo.MetaUrl := KeyOf(AKeys, 'Meta');
    AInfo.MetaFallbackUrl := '';
  end;
  if KeyOf(AKeys, 'Readme') <> '' then AInfo.ReadmeUrl := KeyOf(AKeys, 'Readme');
  if KeyOf(AKeys, 'Icon') <> '' then AInfo.IconUrl := KeyOf(AKeys, 'Icon');
  if KeyOf(AKeys, 'Page') <> '' then AInfo.PageUrl := KeyOf(AKeys, 'Page');
  if AInfo.Kind = skNone then
  begin
    if AInfo.PackageUrl <> '' then AInfo.Kind := skBase;
    if (AInfo.ImageBase = '') and (AInfo.ReadmeUrl <> '') then
    begin
      Rel := AInfo.ReadmeUrl;
      while (Rel <> '') and not (Rel[Length(Rel)] in ['/', '\']) do
        Delete(Rel, Length(Rel), 1);
      AInfo.ImageBase := Rel;
      AInfo.LinkBase := Rel;
    end;
  end;

  { Anzeige, solange die Quelle nichts Besseres liefert }
  if KeyOf(AKeys, 'Title') <> '' then AInfo.Title := KeyOf(AKeys, 'Title');
  if KeyOf(AKeys, 'Description') <> '' then
    AInfo.Description := KeyOf(AKeys, 'Description');
  if KeyOf(AKeys, 'Author') <> '' then AInfo.Author := KeyOf(AKeys, 'Author');
  if KeyOf(AKeys, 'Version') <> '' then
    AInfo.AvailableVersion := KeyOf(AKeys, 'Version');
  if (AInfo.Homepage = '') then AInfo.Homepage := AInfo.PageUrl;
end;

function AmsParseCatalog(const AText, ACatalogUrl: string;
  AList: TAmsPluginList): Integer;
var
  Doc: TAmsIniDoc;
  Secs, Keys: TStringList;
  i, j: Integer;
  Info: TAmsPluginInfo;
  E: TAmsIniEntry;
begin
  Result := 0;
  if AList = nil then Exit;
  Doc := TAmsIniDoc.Create;
  Secs := TStringList.Create;
  Keys := TStringList.Create;
  try
    Doc.LoadFromText(AText);
    Doc.Sections(Secs);
    for i := 0 to Secs.Count - 1 do
    begin
      if Secs[i] = '' then Continue;               { Kopf: Kommentar/Meta }
      if not AmsIsSafeName(Secs[i]) then
      begin
        AmsLogFmt('Katalog: Abschnitt "%s" ist kein gueltiger Ordnername',
                  [Secs[i]]);
        Continue;
      end;
      if AList.Find(Secs[i]) <> nil then Continue;  { erster Katalog gewinnt }
      Keys.Clear;
      for j := 0 to Doc.Count - 1 do
      begin
        E := Doc.Entry(j);
        if SameText(E.Section, Secs[i]) then Keys.Add(E.Key + '=' + E.Value);
      end;
      Info := TAmsPluginInfo.Create;
      Info.Name := Secs[i];
      Info.InCatalog := True;
      Info.Catalog := ACatalogUrl;
      AmsResolveSource(Info, Keys, ACatalogUrl);
      if Info.Kind = skNone then
      begin
        AmsLogFmt('Katalog: "%s" ohne Repo=/Base=/Package= - uebersprungen',
                  [Info.Name]);
        Info.Free;
        Continue;
      end;
      AList.Add(Info);
      Inc(Result);
    end;
  finally
    Keys.Free;
    Secs.Free;
    Doc.Free;
  end;
end;

{ Description darf \n fuer Zeilenumbrueche enthalten }
function Unescape(const S: string): string;
begin
  Result := StringReplace(S, '\n', #10, [rfReplaceAll]);
end;

procedure AmsApplyMeta(AInfo: TAmsPluginInfo; const AIniText: string;
  AInstalled: Boolean);
var
  Doc: TAmsIniDoc;
  V: string;
begin
  Doc := TAmsIniDoc.Create;
  try
    Doc.LoadFromText(AIniText);
    V := Doc.GetValue('', 'Version');
    if AInstalled then AInfo.InstalledVersion := V
    else if V <> '' then AInfo.AvailableVersion := V;
    if Doc.GetValue('', 'Module') <> '' then
      AInfo.Module := Doc.GetValue('', 'Module');
    if Doc.GetValue('Info', 'Title') <> '' then
      AInfo.Title := Doc.GetValue('Info', 'Title');
    if Doc.GetValue('Info', 'Description') <> '' then
      AInfo.Description := Unescape(Doc.GetValue('Info', 'Description'));
    if Doc.GetValue('Info', 'Author') <> '' then
      AInfo.Author := Doc.GetValue('Info', 'Author');
    if Doc.GetValue('Info', 'License') <> '' then
      AInfo.License := Doc.GetValue('Info', 'License');
    if Doc.GetValue('Info', 'Homepage') <> '' then
      AInfo.Homepage := Doc.GetValue('Info', 'Homepage');
    if Doc.GetValue('Info', 'Tags') <> '' then
      AInfo.Tags := Doc.GetValue('Info', 'Tags');
    { Bild: [Info] Icon= vor LargeGlyph= (das ist fuer den Ribbon gedacht) }
    V := Doc.GetValue('Info', 'Icon');
    if V = '' then V := Doc.GetValue('', 'LargeGlyph');
    V := StringReplace(V, '\', '/', [rfReplaceAll]);
    while (Length(V) >= 2) and (V[1] = '.') and (V[2] = '/') do Delete(V, 1, 2);
    if V <> '' then
    begin
      if AInstalled and (AInfo.InstalledDir <> '') then
      begin
        if AmsIsSafeRelPath(V) then
          AInfo.IconFile := IncludeTrailingPathDelimiter(AInfo.InstalledDir) +
                            StringReplace(V, '/', '\', [rfReplaceAll]);
      end
      else if (AInfo.IconUrl = '') and (AInfo.ImageBase <> '') then
        AInfo.IconUrl := AmsResolveUrl(AInfo.ImageBase, V);
    end;
  finally
    Doc.Free;
  end;
end;

function AmsScanInstalled(const APluginsDir: string;
  AList: TAmsPluginList): Integer;
var
  FD: TWin32FindDataW;
  H: THandle;
  Dir, Name, Ini, Data: string;
  Info: TAmsPluginInfo;
begin
  Result := 0;
  if AList = nil then Exit;
  Dir := IncludeTrailingPathDelimiter(APluginsDir);
  H := FindFirstFileW(PWideChar(WideString(Dir + '*')), FD);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    repeat
      if (FD.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then Continue;
      Name := string(WideString(FD.cFileName));
      if (Name = '.') or (Name = '..') or (Name[1] = '.') then Continue;
      Ini := Dir + Name + '\plugin.ini';
      if not FileExists(Ini) then Continue;
      if not AmsReadFileRaw(Ini, Data, META_MAX) then Continue;
      Info := TAmsPluginInfo.Create;
      Info.Name := Name;
      Info.Installed := True;
      Info.InstalledDir := Dir + Name;
      AmsApplyMeta(Info, Data, True);
      if FileExists(Dir + Name + '\README.md') then
        Info.ReadmeFile := Dir + Name + '\README.md';
      if (Info.IconFile <> '') and not FileExists(Info.IconFile) then
        Info.IconFile := '';
      if (Info.IconFile = '') and FileExists(Dir + Name + '\icon32.png') then
        Info.IconFile := Dir + Name + '\icon32.png';
      AList.Add(Info);
      Inc(Result);
    until not FindNextFileW(H, FD);
  finally
    Windows.FindClose(H);
  end;
end;

procedure AmsMergeInstalled(ACatalog, AInstalled, AResult: TAmsPluginList);
var
  i: Integer;
  C, Inst, N: TAmsPluginInfo;
begin
  if AResult = nil then Exit;
  if ACatalog <> nil then
    for i := 0 to ACatalog.Count - 1 do
    begin
      C := ACatalog[i];
      N := TAmsPluginInfo.Create;
      N.Assign(C);
      if AInstalled <> nil then
      begin
        Inst := AInstalled.Find(C.Name);
        if Inst <> nil then
        begin
          N.Installed := True;
          N.InstalledVersion := Inst.InstalledVersion;
          N.InstalledDir := Inst.InstalledDir;
          N.ReadmeFile := Inst.ReadmeFile;
          if Inst.IconFile <> '' then N.IconFile := Inst.IconFile;
          if N.Title = '' then N.Title := Inst.Title;
          if N.Description = '' then N.Description := Inst.Description;
          if N.Author = '' then N.Author := Inst.Author;
          if N.License = '' then N.License := Inst.License;
          if N.Module = '' then N.Module := Inst.Module;
          if N.Homepage = '' then N.Homepage := Inst.Homepage;
        end;
      end;
      AResult.Add(N);
    end;
  if AInstalled <> nil then
    for i := 0 to AInstalled.Count - 1 do
      if AResult.Find(AInstalled[i].Name) = nil then
      begin
        N := TAmsPluginInfo.Create;
        N.Assign(AInstalled[i]);
        AResult.Add(N);
      end;
  AResult.SortByTitle;
end;

{ ------------------------------------------------------- GitHub-API (Token) }

{ Release ueber die API holen und die Asset-Adressen eintragen. }
function ResolveApiAssets(const AConfig: TAmsStoreConfig;
  AInfo: TAmsPluginInfo): Boolean;
var
  Url, Data, AName: string;
  J: TJSONData;
  Assets: TJSONArray;
  A: TJSONObject;
  i: Integer;
begin
  Result := False;
  Url := 'https://api.github.com/repos/' + AInfo.GhOwner + '/' + AInfo.GhRepo +
         '/releases/';
  if AInfo.GhTag <> '' then Url := Url + 'tags/' + AInfo.GhTag
  else Url := Url + 'latest';
  if not AmsStoreFetch(AConfig, Url, Data, META_MAX * 4,
                       'application/vnd.github+json') then Exit;
  try
    J := GetJSON(Data);
  except
    on E: Exception do Exit(AmsFailFmt('GitHub-API: Antwort unlesbar (%s)',
                                       [E.Message]));
  end;
  try
    if not (J is TJSONObject) then Exit(AmsFail('GitHub-API: kein Objekt'));
    if AInfo.AvailableVersion = '' then
    begin
      AInfo.AvailableVersion := string(TJSONObject(J).Get('tag_name', ''));
      if (AInfo.AvailableVersion <> '') and
         (AInfo.AvailableVersion[1] in ['v', 'V']) then
        Delete(AInfo.AvailableVersion, 1, 1);
    end;
    Assets := TJSONObject(J).Get('assets', TJSONArray(nil));
    if Assets <> nil then
      for i := 0 to Assets.Count - 1 do
      begin
        if not (Assets.Items[i] is TJSONObject) then Continue;
        A := TJSONObject(Assets.Items[i]);
        AName := string(A.Get('name', ''));
        if SameText(AName, AInfo.PackageAsset) then
          AInfo.ApiPackageUrl := string(A.Get('url', ''));
        if SameText(AName, AInfo.MetaAsset) then
          AInfo.ApiMetaUrl := string(A.Get('url', ''));
      end;
    Result := True;
  finally
    J.Free;
  end;
end;

{ ------------------------------------------------------------ Aktualisieren }

function Cancelled(ACancel: PBoolean): Boolean;
begin
  Result := (ACancel <> nil) and ACancel^;
end;

procedure Note(ALog: TStrings; const AText: string);
begin
  AmsLog('PluginStore: ' + AText);
  if ALog <> nil then ALog.Add(AText);
end;

function CacheFile(const AConfig: TAmsStoreConfig; const ASub, AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(AConfig.CacheDir) + ASub + '\' + AName;
end;

{ Metadaten eines Katalogeintrags holen (Netz), im Zwischenspeicher ablegen }
procedure FetchMeta(const AConfig: TAmsStoreConfig; AInfo: TAmsPluginInfo;
  ALog: TStrings);
var
  Data, Ext, IconCache: string;
  Ok: Boolean;
begin
  Ok := False;
  Data := '';
  if (AInfo.Kind = skGitHub) and (AConfig.Token <> '') then
  begin
    if ResolveApiAssets(AConfig, AInfo) and (AInfo.ApiMetaUrl <> '') then
      Ok := AmsStoreFetch(AConfig, AInfo.ApiMetaUrl, Data, META_MAX,
                          'application/octet-stream');
  end;
  if not Ok and (AInfo.MetaUrl <> '') then
    Ok := AmsStoreFetch(AConfig, AInfo.MetaUrl, Data, META_MAX);
  if not Ok and (AInfo.MetaFallbackUrl <> '') then
    Ok := AmsStoreFetch(AConfig, AInfo.MetaFallbackUrl, Data, META_MAX);
  if Ok then
  begin
    AmsApplyMeta(AInfo, Data, False);
    AmsWriteFileRaw(CacheFile(AConfig, 'meta', AInfo.Name + '.ini'), Data);
    AInfo.MetaError := '';
  end
  else
  begin
    AInfo.MetaError := AmsLastError;
    { GitHub sagt bei privaten Repos ohne Token 404, nicht 401 }
    if (AInfo.Kind = skGitHub) and (AConfig.Token = '') and
       (Pos('HTTP 404', AInfo.MetaError) > 0) then
      AInfo.MetaError := AInfo.MetaError + ' - kein Release mit ' +
        AInfo.MetaAsset + ', oder privates Repo ohne Token ([GitHub] Token=)';
    Note(ALog, Format('%s: keine Metadaten - %s', [AInfo.Name, AInfo.MetaError]));
  end;

  { Bild in den Zwischenspeicher }
  if AInfo.IconUrl = '' then
    AInfo.IconUrl := AmsResolveUrl(AInfo.ImageBase, 'icon32.png');
  if (AInfo.IconUrl <> '') and (AInfo.ImageBase <> '') then
  begin
    Ext := LowerCase(ExtractFileExt(StringReplace(AInfo.IconUrl, '/', '\',
                                                  [rfReplaceAll])));
    if (Ext <> '.png') and (Ext <> '.bmp') then Ext := '.png';
    IconCache := CacheFile(AConfig, 'icons', AInfo.Name + Ext);
    if AmsStoreFetch(AConfig, AInfo.IconUrl, Data, ICON_MAX) then
    begin
      if AmsWriteFileRaw(IconCache, Data) and (AInfo.IconFile = '') then
        AInfo.IconFile := IconCache;
    end
    else if FileExists(IconCache) and (AInfo.IconFile = '') then
      AInfo.IconFile := IconCache;
  end;
end;

{ Dasselbe aus dem Zwischenspeicher }
procedure CachedMeta(const AConfig: TAmsStoreConfig; AInfo: TAmsPluginInfo);
var
  Data: string;
begin
  if AmsReadFileRaw(CacheFile(AConfig, 'meta', AInfo.Name + '.ini'), Data,
                    META_MAX) then
    AmsApplyMeta(AInfo, Data, False);
  if AInfo.IconFile = '' then
  begin
    if FileExists(CacheFile(AConfig, 'icons', AInfo.Name + '.png')) then
      AInfo.IconFile := CacheFile(AConfig, 'icons', AInfo.Name + '.png')
    else if FileExists(CacheFile(AConfig, 'icons', AInfo.Name + '.bmp')) then
      AInfo.IconFile := CacheFile(AConfig, 'icons', AInfo.Name + '.bmp');
  end;
end;

function AmsStoreRefresh(const AConfig: TAmsStoreConfig; AResult: TAmsPluginList;
  ALog: TStrings; AOffline: Boolean; ACancel: PBoolean): Boolean;
var
  Installed, Catalog: TAmsPluginList;
  Sources: TStringList;
  i, n: Integer;
  Src, Data, CacheName: string;
  Got: Boolean;
begin
  Result := False;
  if AResult = nil then Exit;
  Installed := TAmsPluginList.Create;
  Catalog := TAmsPluginList.Create;
  Sources := TStringList.Create;
  try
    n := AmsScanInstalled(AConfig.PluginsDir, Installed);
    Note(ALog, Format('%d Plugins installiert in %s', [n, AConfig.PluginsDir]));

    Sources.Delimiter := '|';
    Sources.StrictDelimiter := True;
    Sources.DelimitedText := AConfig.Catalogs;
    for i := 0 to Sources.Count - 1 do
    begin
      if Cancelled(ACancel) then Exit;
      Src := Trim(Sources[i]);
      if Src = '' then Continue;
      CacheName := CacheFile(AConfig, 'catalogs',
                             Copy(AmsSha256(Src), 1, 16) + '.ini');
      Got := False;
      if not AOffline then
      begin
        Got := AmsStoreFetch(AConfig, Src, Data, CATALOG_MAX);
        if Got then AmsWriteFileRaw(CacheName, Data)
        else Note(ALog, Format('Katalog nicht erreichbar: %s - %s',
                               [Src, AmsLastError]));
      end;
      if not Got then
        Got := AmsReadFileRaw(CacheName, Data, CATALOG_MAX) and (Data <> '');
      if not Got then Continue;
      n := AmsParseCatalog(AmsStripBom(Data), Src, Catalog);
      Note(ALog, Format('Katalog %s: %d Plugins', [Src, n]));
    end;

    for i := 0 to Catalog.Count - 1 do
    begin
      if Cancelled(ACancel) then Exit;
      if AOffline then CachedMeta(AConfig, Catalog[i])
      else FetchMeta(AConfig, Catalog[i], ALog);
    end;

    AmsMergeInstalled(Catalog, Installed, AResult);
    Result := True;
  finally
    Sources.Free;
    Catalog.Free;
    Installed.Free;
  end;
end;

function AmsStoreFetchReadme(const AConfig: TAmsStoreConfig;
  AInfo: TAmsPluginInfo; out AMarkdown, AImageBase, ALinkBase: string): Boolean;
begin
  Result := False;
  AMarkdown := '';
  AImageBase := '';
  ALinkBase := '';
  if (AInfo.ReadmeUrl <> '') and
     AmsStoreFetch(AConfig, AInfo.ReadmeUrl, AMarkdown, README_MAX) then
  begin
    AImageBase := AInfo.ImageBase;
    ALinkBase := AInfo.LinkBase;
    Exit(True);
  end;
  if (AInfo.ReadmeFile <> '') and
     AmsReadFileRaw(AInfo.ReadmeFile, AMarkdown, README_MAX) then
  begin
    AImageBase := IncludeTrailingPathDelimiter(ExtractFilePath(AInfo.ReadmeFile));
    ALinkBase := AImageBase;
    Exit(True);
  end;
end;

{ ------------------------------------------------------------ Bereitstellen }

{ Ordner mit plugin.ini finden: die Wurzel oder genau ein Unterordner. }
function FindPluginRoot(const ADir: string; out ARoot: string): Boolean;
var
  FD: TWin32FindDataW;
  H: THandle;
  Name, Found: string;
  n: Integer;
begin
  ARoot := IncludeTrailingPathDelimiter(ADir);
  if FileExists(ARoot + 'plugin.ini') then Exit(True);
  Found := '';
  n := 0;
  H := FindFirstFileW(PWideChar(WideString(ARoot + '*')), FD);
  if H <> INVALID_HANDLE_VALUE then
  try
    repeat
      Name := string(WideString(FD.cFileName));
      if (Name = '.') or (Name = '..') then Continue;
      if (FD.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        if FileExists(ARoot + Name + '\plugin.ini') then
        begin
          Found := ARoot + Name + '\';
          Inc(n);
        end;
    until not FindNextFileW(H, FD);
  finally
    Windows.FindClose(H);
  end;
  Result := n = 1;
  if Result then ARoot := Found;
end;

function AmsStagePlugin(const AConfig: TAmsStoreConfig; AInfo: TAmsPluginInfo;
  out AStageDir: string): Boolean;
var
  Zip, Stage, Root, Src, Hash, IniName, IniModule, Old: string;
  NewDoc, OldDoc: TAmsIniDoc;
  Merged: Integer;
  FromDir: Boolean;
begin
  Result := False;
  AStageDir := '';
  if not AmsIsSafeName(AInfo.Name) then
    Exit(AmsFailFmt('Ungueltiger Pluginname: "%s"', [AInfo.Name]));
  if (AInfo.PackageUrl = '') and (AInfo.ApiPackageUrl = '') then
    Exit(AmsFailFmt('%s: keine Paketquelle bekannt', [AInfo.Name]));

  Stage := IncludeTrailingPathDelimiter(AConfig.CacheDir) + 'stage\' + AInfo.Name;
  if not AmsDeleteTree(Stage) then Exit;
  if not AmsForceDir(Stage) then Exit;

  { Base= auf einen Ordner ohne ZIP: Ordner nehmen, wie er ist }
  Src := AInfo.PackageUrl;
  FromDir := False;
  if not IsHttp(Src) and not FileExists(LocalPathOf(Src)) and
     (AInfo.Kind = skBase) and FileExists(LocalPathOf(AInfo.Base) + 'plugin.ini') then
    FromDir := True;

  if FromDir then
  begin
    if not AmsCopyTree(LocalPathOf(AInfo.Base), Stage) then Exit;
    if AInfo.Sha256 <> '' then
      AmsLogFmt('%s: Sha256 gilt nur fuer Pakete, Ordnerquelle ungeprueft',
                [AInfo.Name]);
  end
  else
  begin
    Zip := IncludeTrailingPathDelimiter(AConfig.CacheDir) + 'packages\' +
           AInfo.Name + '.zip';
    DeleteFile(Zip);
    if (AConfig.Token <> '') and (AInfo.Kind = skGitHub) then
    begin
      if AInfo.ApiPackageUrl = '' then ResolveApiAssets(AConfig, AInfo);
      if AInfo.ApiPackageUrl <> '' then
      begin
        if not AmsStoreDownload(AConfig, AInfo.ApiPackageUrl, Zip,
                                'application/octet-stream') then Exit;
      end
      else if not AmsStoreDownload(AConfig, Src, Zip) then Exit;
    end
    else if not AmsStoreDownload(AConfig, Src, Zip) then Exit;

    if AInfo.Sha256 <> '' then
    begin
      if not AmsSha256File(Zip, Hash) then Exit;
      if not SameText(Hash, AInfo.Sha256) then
      begin
        DeleteFile(Zip);
        Exit(AmsFailFmt('%s: Pruefsumme stimmt nicht - erwartet %s, ' +
                        'bekommen %s. Paket verworfen.',
                        [AInfo.Name, AInfo.Sha256, Hash]));
      end;
    end;
    if not AmsZipExtract(Zip, Stage) then Exit;
  end;

  if not FindPluginRoot(Stage, Root) then
    Exit(AmsFailFmt('%s: das Paket enthaelt keine (eindeutige) plugin.ini',
                    [AInfo.Name]));

  NewDoc := TAmsIniDoc.Create;
  OldDoc := TAmsIniDoc.Create;
  try
    if not NewDoc.LoadFromFile(Root + 'plugin.ini') then Exit;
    IniName := NewDoc.GetValue('', 'Name');
    if (IniName <> '') and not SameText(IniName, AInfo.Name) then
      Exit(AmsFailFmt('%s: das Paket heisst "%s" - falsches Paket?',
                      [AInfo.Name, IniName]));
    IniModule := NewDoc.GetValue('', 'Module');
    if IniModule = '' then
      Exit(AmsFailFmt('%s: plugin.ini ohne Module=', [AInfo.Name]));
    if not AmsIsSafeRelPath(IniModule) or not FileExists(Root + IniModule) then
      Exit(AmsFailFmt('%s: Modul "%s" fehlt im Paket', [AInfo.Name, IniModule]));

    { Einstellungen des Anwenders behalten }
    Old := IncludeTrailingPathDelimiter(AConfig.PluginsDir) + AInfo.Name +
           '\plugin.ini';
    if FileExists(Old) and OldDoc.LoadFromFile(Old) then
    begin
      Merged := AmsIniMergeUserValues(NewDoc, OldDoc, AMS_PACKAGE_OWNED);
      if Merged > 0 then
      begin
        if not NewDoc.SaveToFile(Root + 'plugin.ini') then Exit;
        AmsLogFmt('%s: %d eigene Einstellungen uebernommen', [AInfo.Name, Merged]);
      end;
    end;
    AInfo.AvailableVersion := NewDoc.GetValue('', 'Version', AInfo.AvailableVersion);
  finally
    OldDoc.Free;
    NewDoc.Free;
  end;

  AStageDir := ExcludeTrailingPathDelimiter(Root);
  AmsLogFmt('%s bereitgestellt: %s', [AInfo.Name, AStageDir]);
  Result := True;
end;

end.
