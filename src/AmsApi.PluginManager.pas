unit AmsApi.PluginManager;

{ ============================================================================
  AmsApi.PluginManager - Plugin-Browser im laufenden AMS

  Ein Fenster, in dem der Anwender Plugins findet, installiert,
  aktualisiert, entfernt und einstellt:

    links   Suchfeld, Filter (Alle / Installiert / Updates / Nicht
            installiert) und die Liste mit Bild, Version und Zustand
    rechts  Installieren/Aktualisieren, Entfernen, Einstellungen, Webseite -
            darunter die Beschreibung: eine Kopfkarte (Bild, Titel, Autor,
            Lizenz, installierte und verfuegbare Version) und die README aus
            dem Repo, gerendert als HTML (AmsApi.Markdown + AmsApi.Browser).
            Bilder der README werden vorab geholt und als data:-URI in die
            Seite gelegt - so gehen auch private Repos und Netzlaufwerke.

  Wer es benutzt, braucht eine Zeile (samples\PluginManager):

      AmsPluginManagerOpen(MainWindow, AmsPluginManagerDefaults);

  ABLAUF
    Oeffnen     sofort die installierten und die zwischengespeicherten
                Katalogeintraege (kein Netz), dann im Hintergrund alle
                Kataloge frisch (AmsStoreRefresh).
    Auswaehlen  Kopfkarte sofort, README im Hintergrund.
    Installieren  Paket im Hintergrund bereitstellen (AmsStagePlugin), dann
                AmsApplyWithRights - im Prozess, wenn BIN\plugins
                beschreibbar ist, sonst ueber AmsPluginApply.exe mit UAC.
                Danach der Neustart-Dialog (AmsAskRestart).
    Einstellungen  AmsIniEditor auf die plugin.ini des Plugins. Gespeichert
                wird ebenfalls ueber AmsApplyWithRights.

  Hintergrundarbeit laeuft in eigenen Threads, die NIE ein Fenster
  anfassen: das Ergebnis kommt per PostMessage zurueck. AmsPluginManagerClose
  wartet auf die Threads - danach erst darf das Modul gehen.

  PFLICHT beim Entladen: AmsPluginManagerClose und AmsIniEditorCloseAll.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{$codepage utf8}

interface

uses
  Windows, SysUtils, Classes, AmsApi.PluginStore;

type
  TAmsPluginManagerOptions = record
    Store: TAmsStoreConfig;
    { AmsPluginApply.exe - UAC-Schritt und Neustart. }
    HelperExe: string;
    { Eigene plugin.ini ("Quellen" bearbeiten). }
    ConfigFile: string;
    { Eigener Ordnername - Entfernen fragt dann deutlicher. }
    SelfName: string;
    { AMS-Hauptfenster, fuer den Neustart. 0 = kein Neustart anbieten. }
    HostWindow: HWND;
    Title: WideString;
    { Fuer Rauchtests: ausserhalb des Bildes oeffnen, nicht aktivieren. }
    Offscreen: Boolean;
  end;

{ Vorbelegung aus der plugin.ini des eigenen Moduls - siehe
  AmsPluginManagerOptionsFromIni. }
function AmsPluginManagerDefaults: TAmsPluginManagerOptions;

{ Aus einer INI:
    [Katalog]
    Quelle1=https://.../katalog.ini      ; beliebig viele: Quelle, Quelle2 ...
    PluginsDir=                          ; leer = BIN\plugins dieses Moduls
    [GitHub]
    Token=                               ; fuer private Repos
    TokenFile=%APPDATA%\AmsPluginManager\github.token
  Ohne Token= und TokenFile= gilt die Umgebungsvariable AMS_GITHUB_TOKEN. }
function AmsPluginManagerOptionsFromIni(const AFile: string): TAmsPluginManagerOptions;

{ Fenster oeffnen bzw. nach vorn holen. }
function AmsPluginManagerOpen(AOwner: HWND;
  const AOptions: TAmsPluginManagerOptions): Boolean;
{ Schliessen, Threads abwarten, aufraeumen. GEHOERT IN JEDES BeforeUnload. }
procedure AmsPluginManagerClose;
function AmsPluginManagerHandle: HWND;

{ ---------------------------------------------------- fuer Rauchtests ---- }
function AmsPluginManagerBusy: Boolean;
function AmsPluginManagerCount: Integer;
function AmsPluginManagerItemText(AIndex, ASub: Integer): WideString;
function AmsPluginManagerSelect(const AName: string): Boolean;
function AmsPluginManagerSelected: string;
function AmsPluginManagerStatus: WideString;
{ Zuletzt angezeigte Beschreibungsseite und ob sie die README enthaelt. }
function AmsPluginManagerPage: string;
function AmsPluginManagerPageHasReadme: Boolean;
function AmsPluginManagerReadyState: Integer;

var
  { Wie oft ein Neustart angeboten wurde. }
  AmsPluginManagerRestartOffers: Integer = 0;

const
  IDC_PM_LIST     = 400;
  IDC_PM_SEARCH   = 401;
  IDC_PM_FILTER   = 402;
  IDC_PM_REFRESH  = 403;
  IDC_PM_SOURCES  = 404;
  IDC_PM_INSTALL  = 405;
  IDC_PM_REMOVE   = 406;
  IDC_PM_SETTINGS = 407;
  IDC_PM_WEB      = 408;
  IDC_PM_VIEW     = 409;
  IDC_PM_STATUS   = 410;

implementation

uses
  AmsApi.Log, AmsApi.Ini, AmsApi.IniDoc, AmsApi.Files, AmsApi.Http,
  AmsApi.Markdown, AmsApi.Browser, AmsApi.Glyphs, AmsApi.WinCtl,
  AmsApi.Dialogs, AmsApi.IniEditor, AmsApi.PluginApply, AmsApi.Process;

const
  CLASS_NAME = 'AmsApiPluginManager';
  WM_PM_JOB  = WM_APP + $340;
  M = 10;
  ROW = 26;
  ICON = 32;
  THREAD_WAIT_MS = 15000;

  { Filter }
  F_ALL = 0;
  F_INSTALLED = 1;
  F_UPDATES = 2;
  F_AVAILABLE = 3;

  PAGE_CSS =
    { Die README-Formatierung rahmt jede Tabelle - die Kopfkarte nicht }
    '.pm-head,.pm-head tr,.pm-head td{border:0;background:transparent}' +
    '.pm-head{border-collapse:collapse;margin:0 0 6px 0;width:auto}' +
    '.pm-head td{vertical-align:middle;padding:0}' +
    '.pm-iconcell{width:72px}' +
    '.pm-icon{width:56px;height:56px}' +
    '.pm-letter{width:56px;height:56px;line-height:56px;background:#2f6fb5;' +
      'color:#fff;font-size:30px;font-weight:600;text-align:center}' +
    'h1.pm-title{border:0;margin:0;padding:0;font-size:24px}' +
    '.pm-sub{color:#57606a;margin-top:2px}' +
    '.pm-badges{margin-top:6px}' +
    '.pm-badge{display:inline-block;padding:1px 8px;font-size:12px;' +
      'margin-right:6px;background:#eaeef2;color:#24292f}' +
    '.pm-inst{background:#dafbe1;color:#116329}' +
    '.pm-upd{background:#fff8c5;color:#7d4e00}' +
    '.pm-warn{background:#ffebe9;color:#a40e26}' +
    '.pm-desc{font-size:15px;margin:10px 0 4px 0}' +
    '.pm-src{color:#57606a;font-size:12px;margin-bottom:10px}' +
    '.pm-note{color:#57606a;font-style:italic}' +
    '.pm-err{color:#a40e26;margin-top:-6px}';

type
  TJobKind = (jkRefresh, jkReadme, jkStage);

  PJob = ^TJob;
  TJob = record
    Kind: TJobKind;
    Store: TAmsStoreConfig;
    Offline: Boolean;
    Gen: Integer;
    Info: TAmsPluginInfo;
    List: TAmsPluginList;
    Log: TStringList;
    PageFile: string;
    HasReadme: Boolean;
    StageDir: string;
    Ok: Boolean;
    Error: string;
    Target: HWND;
    Thread: TThreadID;
  end;

  { Bilder der README holen und als data:-URI einsetzen }
  TInliner = class
  public
    Store: TAmsStoreConfig;
    Count: Integer;
    Bytes: Int64;
    function Embed(const AUrl: string): string;
  end;

  { Methodenzeiger fuer den Einstellungseditor }
  THandlers = class
  public
    function SaveIni(const AFile, AText: string): Boolean;
    procedure IniSaved(const AFile: string);
  end;

var
  gWin: HWND = 0;
  gOwner: HWND = 0;
  gList, gSearch, gFilter, gStatus: HWND;
  gView: TAmsHtmlView = nil;
  gImages: THandle = 0;
  gOpts: TAmsPluginManagerOptions;
  gPlugins: TAmsPluginList = nil;
  gIconIndex: array of Integer;
  gChanged: TStringList = nil;
  gThreads: TList = nil;
  gHandlers: THandlers = nil;
  gRefreshing: Boolean = False;
  gStaging: Boolean = False;
  gApplying: Boolean = False;
  gReadmeGen: Integer = 0;
  gPage: string = '';
  gPageHasReadme: Boolean = False;
  gLastRefresh: string = '';
  gRefreshNote: WideString = '';
  gClassW: WideString = '';
  gRegistered: Boolean = False;

{ ------------------------------------------------------------ Kleinkram --- }

function U8(const AText: WideString): string;
begin
  Result := AmsWideToUtf8(AText);
end;

{ Bytes aus der Quelle -> UTF-8 -> HTML-escaped }
function H(const ARaw: string): string;
begin
  Result := AmsHtmlEscape(AmsToUtf8(ARaw));
end;

function W(const ARaw: string): WideString;
begin
  Result := AmsDecodeText(ARaw);
end;

procedure SetStatus(const AText: WideString);
begin
  AmsSetWndText(gStatus, AText);
end;

function StateText(AInfo: TAmsPluginInfo): WideString;
begin
  case AInfo.State of
    psAvailable: Result := 'Nicht installiert';
    psInstalled: Result := 'Installiert';
    psUpdate:    Result := 'Update verfügbar';
    psNewer:     Result := 'Neuer als Katalog';
    psLocal:     Result := 'Lokal';
  else
    Result := '';
  end;
  if (gChanged <> nil) and (gChanged.IndexOf(LowerCase(AInfo.Name)) >= 0) then
    Result := 'Neustart nötig';
end;

function VersionText(AInfo: TAmsPluginInfo): WideString;
begin
  case AInfo.State of
    psUpdate: Result := W(AInfo.InstalledVersion) + ' → ' + W(AInfo.AvailableVersion);
    psAvailable: Result := W(AInfo.AvailableVersion);
  else
    Result := W(AInfo.InstalledVersion);
  end;
end;

function SelectedInfo: TAmsPluginInfo;
var
  i, n: Integer;
begin
  Result := nil;
  if (gWin = 0) or (gPlugins = nil) then Exit;
  i := AmsListViewSelected(gList);
  if i < 0 then Exit;
  n := Integer(AmsListViewData(gList, i));
  if (n >= 0) and (n < gPlugins.Count) then Result := gPlugins[n];
end;

function ColorOf(const AName: string): COLORREF;
const
  Colors: array[0..7] of COLORREF = ($B56F2F, $2E8B57, $8A4FB0, $2F7FD0,
    $4060C0, $7A7A1F, $A0522D, $3C78B4);
var
  i, Hh: Integer;
begin
  Hh := 0;
  for i := 1 to Length(AName) do Hh := (Hh * 31 + Ord(UpCase(AName[i]))) and $FFFF;
  Result := Colors[Hh mod Length(Colors)];
end;

{ ------------------------------------------------------------- Optionen --- }

function AmsPluginManagerOptionsFromIni(const AFile: string): TAmsPluginManagerOptions;
var
  Doc: TAmsIniDoc;
  i: Integer;
  E: TAmsIniEntry;
  TokFile, Raw: string;
begin
  Result.Store.PluginsDir := AmsPluginsDirOfModule;
  Result.Store.CacheDir := AmsLocalDataDir(AMS_STORE_SUBDIR);
  Result.Store.Catalogs := '';
  Result.Store.Token := '';
  Result.HelperExe := AmsModuleDir + 'AmsPluginApply.exe';
  Result.ConfigFile := AFile;
  Result.SelfName := ExtractFileName(ExcludeTrailingPathDelimiter(AmsModuleDir));
  Result.HostWindow := 0;
  Result.Title := 'Plugin Manager';
  Result.Offscreen := False;
  Doc := TAmsIniDoc.Create;
  try
    if not Doc.LoadFromFile(AFile) then Exit;
    for i := 0 to Doc.Count - 1 do
    begin
      E := Doc.Entry(i);
      if SameText(E.Section, 'Katalog') and
         SameText(Copy(E.Key, 1, 6), 'Quelle') and (E.Value <> '') then
      begin
        if Result.Store.Catalogs <> '' then
          Result.Store.Catalogs := Result.Store.Catalogs + '|';
        Result.Store.Catalogs := Result.Store.Catalogs + E.Value;
      end;
    end;
    if Doc.GetValue('Katalog', 'PluginsDir') <> '' then
      Result.Store.PluginsDir := IncludeTrailingPathDelimiter(
        AmsExpandEnv(Doc.GetValue('Katalog', 'PluginsDir')));
    if Doc.GetValue('Katalog', 'CacheDir') <> '' then
      Result.Store.CacheDir := IncludeTrailingPathDelimiter(
        AmsExpandEnv(Doc.GetValue('Katalog', 'CacheDir')));
    Result.Store.Token := Doc.GetValue('GitHub', 'Token');
    TokFile := AmsExpandEnv(Doc.GetValue('GitHub', 'TokenFile'));
    if (Result.Store.Token = '') and (TokFile <> '') and FileExists(TokFile) and
       AmsReadFileRaw(TokFile, Raw, 4096) then
      Result.Store.Token := Trim(AmsStripBom(Raw));
  finally
    Doc.Free;
  end;
  if Result.Store.Token = '' then
    Result.Store.Token := Trim(GetEnvironmentVariable('AMS_GITHUB_TOKEN'));
end;

function AmsPluginManagerDefaults: TAmsPluginManagerOptions;
begin
  Result := AmsPluginManagerOptionsFromIni(AmsIniFile);
end;

{ ----------------------------------------------------------------- Seiten - }

function TInliner.Embed(const AUrl: string): string;
var
  D, Mime: string;
begin
  Result := '';
  if (Count >= 40) or (Bytes > 16 * 1024 * 1024) then Exit;
  if Pos('data:', LowerCase(AUrl)) = 1 then Exit;
  Inc(Count);
  if not AmsStoreFetch(Store, AUrl, D, 4 * 1024 * 1024) then Exit;
  Mime := AmsSniffImageMime(D);
  if Mime = '' then Exit;
  Inc(Bytes, Length(D));
  Result := AmsDataUri(Mime, D);
end;

function IconHtml(AInfo: TAmsPluginInfo): string;
var
  Data: string;
begin
  if (AInfo.IconFile <> '') and AmsReadFileRaw(AInfo.IconFile, Data, 1024 * 1024) and
     (AmsSniffImageMime(Data) <> '') then
    Result := '<img class="pm-icon" src="' +
              AmsDataUri(AmsSniffImageMime(Data), Data) + '" alt="">'
  else
    Result := '<div class="pm-letter">' +
              AmsHtmlEscape(U8(Copy(WideUpperCase(W(AInfo.DisplayTitle)), 1, 1))) +
              '</div>';
end;

function SourceText(AInfo: TAmsPluginInfo): string;
begin
  case AInfo.Kind of
    skGitHub:
      begin
        Result := 'github.com/' + AInfo.GhOwner + '/' + AInfo.GhRepo;
        if AInfo.GhPath <> '' then Result := Result + '/' + AInfo.GhPath;
      end;
    skBase: Result := AInfo.Base;
  else
    if AInfo.Installed then Result := AInfo.InstalledDir else Result := '';
  end;
end;

{ Kopfkarte: Bild, Titel, Autor, Versionen, Beschreibung, Quelle }
function HeaderHtml(AInfo: TAmsPluginInfo; AChanged: Boolean): string;
var
  Sub, Badges, Src, Link: string;
begin
  Sub := H(AInfo.Name);
  if AInfo.Author <> '' then Sub := Sub + ' &middot; ' + U8('von ') + H(AInfo.Author);
  if AInfo.License <> '' then Sub := Sub + ' &middot; ' + U8('Lizenz ') + H(AInfo.License);
  if AInfo.Tags <> '' then Sub := Sub + ' &middot; ' + H(AInfo.Tags);

  Badges := '';
  if AInfo.Installed then
    Badges := Badges + '<span class="pm-badge pm-inst">' + U8('Installiert ') +
              H(AInfo.InstalledVersion) + '</span>';
  if AInfo.AvailableVersion <> '' then
  begin
    if AInfo.State = psUpdate then
      Badges := Badges + '<span class="pm-badge pm-upd">' + U8('Neu: ') +
                H(AInfo.AvailableVersion) + '</span>'
    else if not AInfo.Installed then
      Badges := Badges + '<span class="pm-badge">' + U8('Version ') +
                H(AInfo.AvailableVersion) + '</span>';
  end;
  if AChanged then
    Badges := Badges + '<span class="pm-badge pm-upd">' +
              U8('Wirksam nach Neustart') + '</span>';
  if AInfo.State = psLocal then
    Badges := Badges + '<span class="pm-badge">' + U8('In keinem Katalog') +
              '</span>';
  if AInfo.MetaError <> '' then
    Badges := Badges + '<span class="pm-badge pm-warn">' +
              U8('Quelle nicht erreichbar') + '</span>';

  Result := '<table class="pm-head"><tr><td class="pm-iconcell">' +
            IconHtml(AInfo) + '</td><td><h1 class="pm-title">' +
            H(AInfo.DisplayTitle) + '</h1><div class="pm-sub">' + Sub +
            '</div><div class="pm-badges">' + Badges + '</div></td></tr></table>';
  if AInfo.Description <> '' then
    Result := Result + '<p class="pm-desc">' +
      StringReplace(H(AInfo.Description), #10, '<br>', [rfReplaceAll]) + '</p>';
  Src := SourceText(AInfo);
  Link := AInfo.Homepage;
  if Link = '' then Link := AInfo.PageUrl;
  if Src <> '' then
  begin
    Result := Result + '<div class="pm-src">' + U8('Quelle: ');
    if Link <> '' then
      Result := Result + '<a href="' + AmsHtmlEscape(Link) + '">' + H(Src) + '</a>'
    else
      Result := Result + H(Src);
    Result := Result + '</div>';
  end;
  if AInfo.MetaError <> '' then
    Result := Result + '<div class="pm-src pm-err">' + H(AInfo.MetaError) +
              '</div>';
end;

function NextPageFile(const ACacheDir: string; AGen: Integer): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheDir) + 'pages\' +
            Format('page%d.html', [AGen]);
  { die vorletzte wegraeumen - die letzte zeigt womoeglich noch jemand }
  DeleteFile(IncludeTrailingPathDelimiter(ACacheDir) + 'pages\' +
             Format('page%d.html', [AGen - 2]));
end;

function WritePage(const AFile: string; AInfo: TAmsPluginInfo;
  const ABody: string): Boolean;
begin
  Result := AmsWriteFileRaw(AFile, AmsHtmlPage(AmsToUtf8(AInfo.DisplayTitle),
                            ABody, PAGE_CSS));
end;

{ ------------------------------------------------------------ Hintergrund - }

procedure RunRefresh(J: PJob);
begin
  J^.List := TAmsPluginList.Create;
  J^.Log := TStringList.Create;
  J^.Ok := AmsStoreRefresh(J^.Store, J^.List, J^.Log, J^.Offline, nil);
  if not J^.Ok then J^.Error := AmsLastError;
end;

procedure RunReadme(J: PJob);
var
  Md, ImgBase, LinkBase, Body: string;
  Opt: TAmsMarkdownOptions;
  Inl: TInliner;
begin
  Body := HeaderHtml(J^.Info, False);
  Inl := TInliner.Create;
  try
    Inl.Store := J^.Store;
    if AmsStoreFetchReadme(J^.Store, J^.Info, Md, ImgBase, LinkBase) then
    begin
      Opt := AmsMarkdownDefaults;
      Opt.ImageBase := ImgBase;
      Opt.LinkBase := LinkBase;
      { Links faengt die Ansicht selbst ab (OnLink) und gibt sie an den
        Standardbrowser - kein target=_blank noetig }
      Opt.ExternalLinksNewWindow := False;
      Opt.OnImage := Inl.Embed;
      Body := Body + '<hr>' + AmsMarkdownToHtml(AmsToUtf8(Md), Opt);
      J^.HasReadme := True;
    end
    else
      Body := Body + '<hr><p class="pm-note">' +
              U8('Keine README gefunden.') + '</p>';
  finally
    Inl.Free;
  end;
  J^.Ok := WritePage(J^.PageFile, J^.Info, Body);
  if not J^.Ok then J^.Error := AmsLastError;
end;

procedure RunStage(J: PJob);
begin
  J^.Ok := AmsStagePlugin(J^.Store, J^.Info, J^.StageDir);
  if not J^.Ok then J^.Error := AmsLastError;
end;

procedure FreeJob(J: PJob);
begin
  if J = nil then Exit;
  J^.Info.Free;
  J^.List.Free;
  J^.Log.Free;
  Dispose(J);
end;

function JobThread(AParam: Pointer): PtrInt;
var
  J: PJob;
begin
  Result := 0;
  J := PJob(AParam);
  try
    case J^.Kind of
      jkRefresh: RunRefresh(J);
      jkReadme:  RunReadme(J);
      jkStage:   RunStage(J);
    end;
  except
    on E: Exception do
    begin
      J^.Ok := False;
      J^.Error := 'Ausnahme: ' + E.Message;
      AmsLog('PluginManager-Thread EXCEPTION: ' + E.Message);
    end;
  end;
  if not PostMessageW(J^.Target, WM_PM_JOB, 0, LPARAM(J)) then
    FreeJob(J);
end;

function StartJob(AKind: TJobKind; AInfo: TAmsPluginInfo; AGen: Integer;
  AOffline: Boolean): PJob;
begin
  New(Result);
  FillChar(Result^, SizeOf(Result^), 0);
  Result^.Kind := AKind;
  Result^.Store := gOpts.Store;
  Result^.Offline := AOffline;
  Result^.Gen := AGen;
  Result^.Target := gWin;
  if AInfo <> nil then
  begin
    Result^.Info := TAmsPluginInfo.Create;
    Result^.Info.Assign(AInfo);
  end;
  if AKind = jkReadme then
    Result^.PageFile := NextPageFile(gOpts.Store.CacheDir, AGen);
  Result^.Thread := BeginThread(@JobThread, Result);
  if Result^.Thread = 0 then
  begin
    AmsLog('PluginManager: Thread nicht startbar');
    FreeJob(Result);
    Exit(nil);
  end;
  gThreads.Add(Pointer(Result^.Thread));
end;

procedure ForgetThread(ATh: TThreadID);
begin
  if gThreads = nil then Exit;
  if gThreads.IndexOf(Pointer(ATh)) >= 0 then
  begin
    gThreads.Remove(Pointer(ATh));
    WaitForThreadTerminate(ATh, 2000);
    CloseThread(ATh);
  end;
end;

{ ---------------------------------------------------------------- Liste --- }

procedure RebuildImages;
var
  i: Integer;
  Bmp: HBITMAP;
  P: TAmsPluginInfo;
  Old: THandle;
begin
  SetLength(gIconIndex, gPlugins.Count);
  Old := gImages;
  gImages := AmsImageListCreate(ICON, gPlugins.Count + 1);
  for i := 0 to gPlugins.Count - 1 do
  begin
    P := gPlugins[i];
    Bmp := 0;
    if P.IconFile <> '' then Bmp := AmsLoadImageBitmap(P.IconFile, ICON);
    if Bmp = 0 then
      Bmp := AmsPlaceholderBitmap(W(P.DisplayTitle), ICON, ColorOf(P.Name));
    gIconIndex[i] := AmsImageListAdd(gImages, Bmp);
    if Bmp <> 0 then DeleteObject(Bmp);
  end;
  AmsListViewSetImages(gList, gImages);
  AmsImageListDestroy(Old);
end;

function Matches(P: TAmsPluginInfo; const ANeedle: WideString;
  AFilter: Integer): Boolean;
var
  S: WideString;
begin
  case AFilter of
    F_INSTALLED: if not P.Installed then Exit(False);
    F_UPDATES:   if P.State <> psUpdate then Exit(False);
    F_AVAILABLE: if P.Installed then Exit(False);
  end;
  if ANeedle = '' then Exit(True);
  S := WideUpperCase(W(P.DisplayTitle) + ' ' + W(P.Name) + ' ' +
                     W(P.Description) + ' ' + W(P.Author) + ' ' + W(P.Tags));
  Result := Pos(WideUpperCase(ANeedle), S) > 0;
end;

procedure FillList(const AKeepName: string);
var
  i, Row, Sel, Filter, Upd: Integer;
  Needle: WideString;
  P: TAmsPluginInfo;
begin
  if (gWin = 0) or (gPlugins = nil) then Exit;
  Needle := Trim(AmsGetWndText(gSearch));
  Filter := SendMessageW(gFilter, CB_GETCURSEL, 0, 0);
  Sel := -1;
  Upd := 0;
  SendMessageW(gList, WM_SETREDRAW, 0, 0);
  try
    AmsListViewClear(gList);
    for i := 0 to gPlugins.Count - 1 do
    begin
      P := gPlugins[i];
      if P.State = psUpdate then Inc(Upd);
      if not Matches(P, Needle, Filter) then Continue;
      Row := AmsListViewAdd(gList, [W(P.DisplayTitle), VersionText(P),
                                    StateText(P)], gIconIndex[i], i);
      if SameText(P.Name, AKeepName) then Sel := Row;
    end;
  finally
    SendMessageW(gList, WM_SETREDRAW, 1, 0);
  end;
  InvalidateRect(gList, nil, True);
  if Sel >= 0 then AmsListViewSelect(gList, Sel);
  if gRefreshing then
    SetStatus(WideString(Format('%d Plugins', [gPlugins.Count])) +
              ' · Kataloge werden geladen …')
  else
    SetStatus(WideString(Format('%d Plugins · %d Updates', [gPlugins.Count, Upd])) +
              gRefreshNote);
end;

procedure UpdateButtons;
var
  P: TAmsPluginInfo;
  Busy: Boolean;
  Cap: WideString;
begin
  if gWin = 0 then Exit;
  P := SelectedInfo;
  Busy := gStaging or gApplying;
  Cap := 'Installieren';
  if P <> nil then
    case P.State of
      psUpdate: Cap := 'Aktualisieren';
      psInstalled, psNewer: Cap := 'Neu installieren';
    end;
  AmsSetWndText(GetDlgItem(gWin, IDC_PM_INSTALL), Cap);
  AmsEnableChild(gWin, IDC_PM_INSTALL, (P <> nil) and not Busy and P.InCatalog);
  AmsEnableChild(gWin, IDC_PM_REMOVE, (P <> nil) and not Busy and P.Installed);
  AmsEnableChild(gWin, IDC_PM_SETTINGS, (P <> nil) and P.Installed and
                 FileExists(IncludeTrailingPathDelimiter(P.InstalledDir) + 'plugin.ini'));
  AmsEnableChild(gWin, IDC_PM_WEB, (P <> nil) and
                 ((P.Homepage <> '') or (P.PageUrl <> '')));
  AmsEnableChild(gWin, IDC_PM_REFRESH, not gRefreshing);
end;

{ Kopfkarte sofort, README im Hintergrund }
procedure ShowSelected;
var
  P: TAmsPluginInfo;
  F: string;
begin
  P := SelectedInfo;
  UpdateButtons;
  if gView = nil then Exit;
  Inc(gReadmeGen);
  if P = nil then
  begin
    gPage := '';
    gPageHasReadme := False;
    gView.ShowText('Plugin Manager'#10#10'Links ein Plugin wählen.');
    Exit;
  end;
  F := NextPageFile(gOpts.Store.CacheDir, gReadmeGen);
  if WritePage(F, P, HeaderHtml(P, gChanged.IndexOf(LowerCase(P.Name)) >= 0) +
               '<hr><p class="pm-note">' + U8('Beschreibung wird geladen …') +
               '</p>') then
  begin
    gPage := F;
    gPageHasReadme := False;
    gView.ShowFile(F, W(P.DisplayTitle) + #13#10#13#10 + W(P.Description));
  end;
  Inc(gReadmeGen);
  StartJob(jkReadme, P, gReadmeGen, False);
end;

function SelectedName: string;
var
  P: TAmsPluginInfo;
begin
  P := SelectedInfo;
  if P <> nil then Result := P.Name else Result := '';
end;

procedure ReplacePlugins(ANew: TAmsPluginList);
var
  Keep: string;
begin
  Keep := SelectedName;
  gPlugins.Free;
  gPlugins := ANew;
  RebuildImages;
  FillList(Keep);
  if SelectedName <> Keep then ShowSelected else UpdateButtons;
end;

{ Nach Installieren/Entfernen: Installiertes neu lesen, Katalog behalten }
procedure RescanInstalled;
var
  Cat, Inst, N: TAmsPluginList;
  i: Integer;
  C: TAmsPluginInfo;
  Cached: string;
begin
  Cat := TAmsPluginList.Create;
  Inst := TAmsPluginList.Create;
  N := TAmsPluginList.Create;
  try
    for i := 0 to gPlugins.Count - 1 do
      if gPlugins[i].InCatalog then
      begin
        C := TAmsPluginInfo.Create;
        C.Assign(gPlugins[i]);
        C.Installed := False;
        C.InstalledVersion := '';
        C.InstalledDir := '';
        C.ReadmeFile := '';
        if (C.IconFile <> '') and not FileExists(C.IconFile) then C.IconFile := '';
        Cached := IncludeTrailingPathDelimiter(gOpts.Store.CacheDir) +
                  'icons\' + C.Name + '.png';
        if (C.IconFile = '') and FileExists(Cached) then C.IconFile := Cached;
        Cat.Add(C);
      end;
    AmsScanInstalled(gOpts.Store.PluginsDir, Inst);
    AmsMergeInstalled(Cat, Inst, N);
  finally
    Inst.Free;
    Cat.Free;
  end;
  ReplacePlugins(N);
end;

procedure StartRefresh(AOffline: Boolean);
begin
  if gRefreshing and not AOffline then Exit;
  if not AOffline then gRefreshing := True;
  if StartJob(jkRefresh, nil, 0, AOffline) = nil then gRefreshing := False;
  UpdateButtons;
  FillList(SelectedName);
end;

{ ---------------------------------------------------- Aendern mit Rechten - }

procedure AskRestart(const AWhat: WideString);
begin
  Inc(AmsPluginManagerRestartOffers);
  if gOpts.HostWindow = 0 then Exit;
  if AmsAskRestart(gWin, AWhat) then
    if not AmsRestartHost(gOpts.HostWindow, gOpts.HelperExe) then
      AmsTaskDialog(gWin, 'Plugin Manager', 'Neustart nicht möglich',
                    WideString(AmsLastError) + #13#10#13#10 +
                    'Bitte AMS selbst beenden und wieder starten.', ['OK'], 0,
                    diWarning);
end;

{ Warteschlange ausfuehren - mit UAC, falls noetig. Fenster solange gesperrt. }
function ApplyOps(var AOps: TAmsApplyOps; out AError: WideString): Boolean;
var
  Queue: string;
  Elevated: Boolean;
  i: Integer;
begin
  Result := False;
  AError := '';
  Queue := IncludeTrailingPathDelimiter(gOpts.Store.CacheDir) +
           Format('queue-%d.ini', [GetTickCount64]);
  if not AmsQueueWrite(Queue, gOpts.Store.PluginsDir,
                       IncludeTrailingPathDelimiter(gOpts.Store.CacheDir) + 'backup',
                       AOps) then
  begin
    AError := WideString(AmsLastError);
    Exit;
  end;
  gApplying := True;
  UpdateButtons;
  if gWin <> 0 then EnableWindow(gWin, False);
  try
    SetStatus('Wird übernommen … (ggf. Bestätigung mit Administratorrechten)');
    Result := AmsApplyWithRights(Queue, gOpts.HelperExe, True, AOps, Elevated);
    if not Result then
    begin
      AError := WideString(AmsLastError);
      for i := 0 to High(AOps) do
        if not AOps[i].Ok and (AOps[i].Message <> '') then
          AError := W(AOps[i].Name) + ': ' + W(AOps[i].Message);
    end;
  finally
    if gWin <> 0 then
    begin
      EnableWindow(gWin, True);
      SetForegroundWindow(gWin);
    end;
    gApplying := False;
    DeleteFile(Queue);
  end;
end;

procedure MarkChanged(const AName: string);
begin
  if gChanged.IndexOf(LowerCase(AName)) < 0 then gChanged.Add(LowerCase(AName));
end;

procedure AfterStage(J: PJob);
var
  Ops: TAmsApplyOps;
  Err, What: WideString;
  WasInstalled: Boolean;
begin
  gStaging := False;
  if not J^.Ok then
  begin
    SetStatus('Installation fehlgeschlagen: ' + WideString(J^.Error));
    AmsTaskDialog(gWin, 'Plugin Manager', W(J^.Info.DisplayTitle) +
                  ' konnte nicht geladen werden', WideString(J^.Error), ['OK'],
                  0, diError);
    UpdateButtons;
    Exit;
  end;
  WasInstalled := DirectoryExists(IncludeTrailingPathDelimiter(
                    gOpts.Store.PluginsDir) + J^.Info.Name);
  SetLength(Ops, 1);
  Ops[0].Action := aaInstall;
  Ops[0].Name := J^.Info.Name;
  Ops[0].Source := J^.StageDir;
  if not ApplyOps(Ops, Err) then
  begin
    SetStatus('Installation fehlgeschlagen: ' + Err);
    AmsTaskDialog(gWin, 'Plugin Manager', W(J^.Info.DisplayTitle) +
                  ' wurde nicht installiert', Err, ['OK'], 0, diError);
    UpdateButtons;
    Exit;
  end;
  AmsDeleteTree(IncludeTrailingPathDelimiter(gOpts.Store.CacheDir) + 'stage\' +
                J^.Info.Name);
  MarkChanged(J^.Info.Name);
  RescanInstalled;
  if WasInstalled then What := ' wurde aktualisiert.' else What := ' wurde installiert.';
  What := W(J^.Info.DisplayTitle) + ' ' + W(J^.Info.AvailableVersion) + What;
  SetStatus(What + ' Wirksam nach dem Neustart von AMS.');
  AskRestart(What);
end;

procedure DoInstall;
var
  P: TAmsPluginInfo;
begin
  P := SelectedInfo;
  if (P = nil) or gStaging or gApplying then Exit;
  gStaging := True;
  UpdateButtons;
  SetStatus('Lade ' + W(P.DisplayTitle) + ' …');
  if StartJob(jkStage, P, 0, False) = nil then
  begin
    gStaging := False;
    UpdateButtons;
  end;
end;

procedure DoRemove;
var
  P: TAmsPluginInfo;
  Ops: TAmsApplyOps;
  Err, Extra, Title: WideString;
  Name: string;
begin
  P := SelectedInfo;
  if (P = nil) or not P.Installed or gStaging or gApplying then Exit;
  { ALLES jetzt kopieren: waehrend der Rueckfrage laufen Nachrichten weiter,
    ein fertiger Katalogabruf ersetzt gPlugins - danach zeigt P ins Leere
    (im echten AMS so passiert: Name kam leer beim Helfer an). }
  Name := P.Name;
  Title := W(P.DisplayTitle);
  P := nil;
  Extra := 'Der Ordner wird gesichert (' + WideString(gOpts.Store.CacheDir) +
           'backup) und beim nächsten Start von AMS nicht mehr geladen.';
  if SameText(Name, gOpts.SelfName) then
    Extra := 'Das ist der Plugin Manager selbst. Danach gibt es im Ribbon ' +
             'keinen Knopf mehr dafür – zurück nur durch manuelles Kopieren.' +
             #13#10#13#10 + Extra;
  if AmsTaskDialog(gWin, 'Plugin Manager', Title + ' entfernen?', Extra,
       ['Entfernen', 'Abbrechen'], 1, diWarning) <> 0 then Exit;
  if gStaging or gApplying or (gWin = 0) then Exit;
  SetLength(Ops, 1);
  Ops[0].Action := aaRemove;
  Ops[0].Name := Name;
  Ops[0].Source := '';
  if not ApplyOps(Ops, Err) then
  begin
    SetStatus('Entfernen fehlgeschlagen: ' + Err);
    AmsTaskDialog(gWin, 'Plugin Manager', Title + ' wurde nicht entfernt', Err,
                  ['OK'], 0, diError);
    UpdateButtons;
    Exit;
  end;
  MarkChanged(Name);
  RescanInstalled;
  SetStatus(Title + ' wurde entfernt. Wirksam nach dem Neustart von AMS.');
  AskRestart(Title + ' wurde entfernt.');
end;

function THandlers.SaveIni(const AFile, AText: string): Boolean;
var
  Dir, Name, Tmp: string;
  Ops: TAmsApplyOps;
  Err: WideString;
begin
  Dir := ExtractFilePath(AFile);
  if AmsCanWriteDir(Dir) then Exit(AmsWriteFileRaw(AFile, AText));
  { Nur Dateien in BIN\plugins\<Name>\plugin.ini gehen ueber den Helfer }
  Name := ExtractFileName(ExcludeTrailingPathDelimiter(Dir));
  if not SameText(ExtractFileName(AFile), 'plugin.ini') or
     not SameText(IncludeTrailingPathDelimiter(ExtractFilePath(
       ExcludeTrailingPathDelimiter(Dir))),
       IncludeTrailingPathDelimiter(gOpts.Store.PluginsDir)) then
    Exit(AmsFailFmt('Keine Schreibrechte: %s', [AFile]));
  Tmp := IncludeTrailingPathDelimiter(gOpts.Store.CacheDir) + 'config\' + Name +
         '.plugin.ini';
  if not AmsWriteFileRaw(Tmp, AText) then Exit(False);
  SetLength(Ops, 1);
  Ops[0].Action := aaConfig;
  Ops[0].Name := Name;
  Ops[0].Source := Tmp;
  Result := ApplyOps(Ops, Err);
  DeleteFile(Tmp);
  if not Result then AmsFail(string(Err));
end;

procedure THandlers.IniSaved(const AFile: string);
var
  Name: string;
  NewOpts: TAmsPluginManagerOptions;
begin
  if gWin = 0 then Exit;
  if SameText(AFile, gOpts.ConfigFile) then
  begin
    { Quellen geaendert: neu einlesen und Kataloge frisch holen }
    NewOpts := AmsPluginManagerOptionsFromIni(AFile);
    gOpts.Store.Catalogs := NewOpts.Store.Catalogs;
    gOpts.Store.Token := NewOpts.Store.Token;
    SetStatus('Quellen gespeichert – Kataloge werden neu geladen …');
    StartRefresh(False);
    Exit;
  end;
  Name := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(AFile)));
  MarkChanged(Name);
  FillList(SelectedName);
  AskRestart('Die Einstellungen von ' + WideString(Name) + ' wurden gespeichert.');
end;

procedure DoSettings;
var
  P: TAmsPluginInfo;
  E: TAmsIniEditor;
begin
  P := SelectedInfo;
  if (P = nil) or not P.Installed then Exit;
  E := AmsIniEditorOpen(gOwner, IncludeTrailingPathDelimiter(P.InstalledDir) +
                        'plugin.ini', W(P.DisplayTitle), gHandlers.SaveIni,
                        gHandlers.IniSaved);
  { Name, Module, Version, [Info] bestimmt das Paket }
  if E <> nil then E.SetLocked(AMS_PACKAGE_OWNED);
end;

procedure DoSources;
var
  E: TAmsIniEditor;
begin
  if gOpts.ConfigFile = '' then Exit;
  E := AmsIniEditorOpen(gOwner, gOpts.ConfigFile, 'Plugin Manager – Quellen',
                        gHandlers.SaveIni, gHandlers.IniSaved);
  if E <> nil then E.SetLocked(AMS_PACKAGE_OWNED);
end;

procedure DoWeb;
var
  P: TAmsPluginInfo;
begin
  P := SelectedInfo;
  if P = nil then Exit;
  if P.Homepage <> '' then AmsOpenUrl(P.Homepage)
  else if P.PageUrl <> '' then AmsOpenUrl(P.PageUrl);
end;

{ ------------------------------------------------------------ Ergebnisse -- }

procedure JobDone(J: PJob);
begin
  ForgetThread(J^.Thread);
  if gWin = 0 then Exit;
  case J^.Kind of
    jkRefresh:
      begin
        if not J^.Offline then gRefreshing := False;
        if J^.Ok then
        begin
          if not J^.Offline then
          begin
            gLastRefresh := FormatDateTime('hh:nn', Now);
            gRefreshNote := ' · Stand ' + WideString(gLastRefresh);
            if (J^.Log <> nil) and (Pos('nicht erreichbar', J^.Log.Text) > 0) then
              gRefreshNote := gRefreshNote + ' · Quelle nicht erreichbar';
            if gOpts.Store.Catalogs = '' then
              gRefreshNote := ' · Keine Katalogquelle eingetragen (Quellen …)';
          end;
          ReplacePlugins(J^.List);
          J^.List := nil;
        end
        else
          SetStatus('Aktualisieren fehlgeschlagen: ' + WideString(J^.Error));
        UpdateButtons;
      end;
    jkReadme:
      if (J^.Gen = gReadmeGen) and J^.Ok and (gView <> nil) then
      begin
        gPage := J^.PageFile;
        gPageHasReadme := J^.HasReadme;
        gView.ShowFile(J^.PageFile, W(J^.Info.DisplayTitle) + #13#10#13#10 +
                       W(J^.Info.Description));
      end;
    jkStage: AfterStage(J);
  end;
end;

{ ---------------------------------------------------------------- Layout -- }

procedure Layout;
var
  R: TRect;
  WW, HH, LW, X0, Y, X, ViewY, BottomY: Integer;
begin
  if gWin = 0 then Exit;
  GetClientRect(gWin, R);
  WW := R.Right;
  HH := R.Bottom;
  LW := WW * 36 div 100;
  if LW < 320 then LW := 320;
  BottomY := HH - M - 18;

  Y := M;
  MoveWindow(gSearch, M, Y, LW - 168, ROW - 2, True);
  MoveWindow(gFilter, M + LW - 160, Y, 160, 200, True);
  X := WW - M - 120;
  MoveWindow(GetDlgItem(gWin, IDC_PM_SOURCES), X, Y - 1, 120, ROW, True);
  Dec(X, 128);
  MoveWindow(GetDlgItem(gWin, IDC_PM_REFRESH), X, Y - 1, 120, ROW, True);

  Inc(Y, ROW + 8);
  MoveWindow(gList, M, Y, LW, BottomY - 8 - Y, True);
  AmsListViewSetColumnWidth(gList, 0, LW - 110 - 120 - 24);
  AmsListViewSetColumnWidth(gList, 1, 110);
  AmsListViewSetColumnWidth(gList, 2, 120);

  X0 := M + LW + 10;
  X := X0;
  MoveWindow(GetDlgItem(gWin, IDC_PM_INSTALL), X, Y, 140, ROW + 2, True);
  Inc(X, 148);
  MoveWindow(GetDlgItem(gWin, IDC_PM_REMOVE), X, Y, 110, ROW + 2, True);
  Inc(X, 118);
  MoveWindow(GetDlgItem(gWin, IDC_PM_SETTINGS), X, Y, 120, ROW + 2, True);
  Inc(X, 128);
  MoveWindow(GetDlgItem(gWin, IDC_PM_WEB), X, Y, 110, ROW + 2, True);
  ViewY := Y + ROW + 10;
  if gView <> nil then
    gView.SetBounds(X0, ViewY, WW - X0 - M, BottomY - 8 - ViewY);
  MoveWindow(gStatus, M, BottomY, WW - 2 * M, 18, True);
end;

{ ------------------------------------------------------- Fensterprozedur -- }

procedure Command(AId, ACode: Integer);
begin
  case AId of
    IDC_PM_SEARCH:  if ACode = EN_CHANGE then FillList(SelectedName);
    IDC_PM_FILTER:  if ACode = CBN_SELCHANGE then FillList(SelectedName);
    IDC_PM_REFRESH: StartRefresh(False);
    IDC_PM_SOURCES: DoSources;
    IDC_PM_INSTALL: DoInstall;
    IDC_PM_REMOVE:  DoRemove;
    IDC_PM_SETTINGS: DoSettings;
    IDC_PM_WEB:     DoWeb;
  end;
end;

procedure Notify(AHdr: Pointer);
var
  Hd: PAmsNmHdr;
  L: PAmsNmListView;
begin
  Hd := PAmsNmHdr(AHdr);
  if (Hd = nil) or (Hd^.hwndFrom <> gList) then Exit;
  if Hd^.code = AMS_LVN_ITEMCHANGED then
  begin
    L := PAmsNmListView(AHdr);
    if ((L^.uNewState xor L^.uOldState) and 2 { LVIS_SELECTED }) <> 0 then
      if (L^.uNewState and 2) <> 0 then ShowSelected
      else if AmsListViewSelected(gList) < 0 then ShowSelected;
  end;
end;

function ManagerProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
begin
  try
    case AMsg of
      WM_SIZE:
        begin
          Layout;
          Exit(0);
        end;
      WM_GETMINMAXINFO:
        begin
          PMinMaxInfo(ALParam)^.ptMinTrackSize.x := 900;
          PMinMaxInfo(ALParam)^.ptMinTrackSize.y := 520;
          Exit(0);
        end;
      WM_COMMAND:
        begin
          Command(LOWORD(AWParam), HIWORD(AWParam));
          Exit(0);
        end;
      WM_NOTIFY:
        begin
          Notify(Pointer(ALParam));
          Exit(0);
        end;
      WM_PM_JOB:
        begin
          try
            JobDone(PJob(ALParam));
          finally
            FreeJob(PJob(ALParam));
          end;
          Exit(0);
        end;
      WM_CLOSE:
        begin
          if gStaging or gApplying then
          begin
            SetStatus('Bitte warten – eine Installation läuft.');
            Exit(0);
          end;
          AmsPluginManagerClose;
          Exit(0);
        end;
    end;
  except
    on E: Exception do AmsLog('PluginManager EXCEPTION: ' + E.Message);
  end;
  Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

{ ----------------------------------------------------------- Oeffnen ----- }

procedure BuildControls;
begin
  gSearch := AmsCreateChild(gWin, 'EDIT', '', WS_TABSTOP or WS_BORDER or
                            ES_AUTOHSCROLL, IDC_PM_SEARCH);
  AmsSetCueBanner(gSearch, 'Suchen …');
  gFilter := AmsCreateChild(gWin, 'COMBOBOX', '', WS_TABSTOP or
                            CBS_DROPDOWNLIST or WS_VSCROLL, IDC_PM_FILTER);
  SendMessageW(gFilter, CB_ADDSTRING, 0, LPARAM(PWideChar(WideString('Alle'))));
  SendMessageW(gFilter, CB_ADDSTRING, 0, LPARAM(PWideChar(WideString('Installiert'))));
  SendMessageW(gFilter, CB_ADDSTRING, 0, LPARAM(PWideChar(WideString('Updates'))));
  SendMessageW(gFilter, CB_ADDSTRING, 0,
               LPARAM(PWideChar(WideString('Nicht installiert'))));
  SendMessageW(gFilter, CB_SETCURSEL, 0, 0);
  AmsCreateChild(gWin, 'BUTTON', 'Neu laden', WS_TABSTOP, IDC_PM_REFRESH);
  AmsCreateChild(gWin, 'BUTTON', 'Quellen …', WS_TABSTOP, IDC_PM_SOURCES);
  gList := AmsListViewCreate(gWin, IDC_PM_LIST);
  AmsListViewAddColumn(gList, 'Plugin', 200);
  AmsListViewAddColumn(gList, 'Version', 110);
  AmsListViewAddColumn(gList, 'Status', 120);
  AmsCreateChild(gWin, 'BUTTON', 'Installieren', WS_TABSTOP, IDC_PM_INSTALL,
                 AmsBoldFont);
  AmsCreateChild(gWin, 'BUTTON', 'Entfernen', WS_TABSTOP, IDC_PM_REMOVE);
  AmsCreateChild(gWin, 'BUTTON', 'Einstellungen', WS_TABSTOP, IDC_PM_SETTINGS);
  AmsCreateChild(gWin, 'BUTTON', 'Webseite', WS_TABSTOP, IDC_PM_WEB);
  gStatus := AmsCreateChild(gWin, 'STATIC', '', SS_LEFTNOWORDWRAP, IDC_PM_STATUS);
  { "Fenster vor Quellen": die Ansicht faellt selbst auf ein Textfeld
    zurueck, wenn der Browser fehlt }
  gView := TAmsHtmlView.Create(gWin, IDC_PM_VIEW);
end;

function AmsPluginManagerOpen(AOwner: HWND;
  const AOptions: TAmsPluginManagerOptions): Boolean;
var
  WC: TWndClassExW;
  First: TAmsPluginList;
  Title: WideString;
begin
  if gWin <> 0 then
  begin
    ShowWindow(gWin, SW_RESTORE);
    SetForegroundWindow(gWin);
    Exit(True);
  end;
  gOpts := AOptions;
  if gOpts.Store.CacheDir = '' then
    gOpts.Store.CacheDir := AmsLocalDataDir(AMS_STORE_SUBDIR);
  gOpts.Store.CacheDir := IncludeTrailingPathDelimiter(gOpts.Store.CacheDir);
  gOpts.Store.PluginsDir := IncludeTrailingPathDelimiter(gOpts.Store.PluginsDir);
  AmsForceDir(gOpts.Store.CacheDir + 'pages');
  gOwner := AOwner;
  if gOpts.HostWindow = 0 then gOpts.HostWindow := AOwner;

  AmsInitCommonControls;
  if not gRegistered then
  begin
    FillChar(WC, SizeOf(WC), 0);
    WC.cbSize := SizeOf(WC);
    WC.lpfnWndProc := @ManagerProc;
    WC.hInstance := HInstance;
    WC.hCursor := LoadCursorW(0, LPCWSTR(IDC_ARROW));
    WC.hbrBackground := HBRUSH(COLOR_BTNFACE + 1);
    gClassW := CLASS_NAME;
    WC.lpszClassName := PWideChar(gClassW);
    RegisterClassExW(WC);
    gRegistered := True;
  end;
  Title := gOpts.Title;
  if Title = '' then Title := 'Plugin Manager';
  if gOpts.Offscreen then
    gWin := CreateWindowExW(WS_EX_TOOLWINDOW, PWideChar(gClassW),
      PWideChar(Title), WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN, -32000, -32000,
      1120, 720, AOwner, 0, HInstance, nil)
  else
    gWin := CreateWindowExW(0, PWideChar(gClassW), PWideChar(Title),
      WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT,
      1120, 720, AOwner, 0, HInstance, nil);
  if gWin = 0 then
    Exit(AmsFailFmt('Plugin Manager: Fenster nicht erzeugbar (%d)', [GetLastError]));

  if gThreads = nil then gThreads := TList.Create;
  if gChanged = nil then gChanged := TStringList.Create;
  if gHandlers = nil then gHandlers := THandlers.Create;
  gPlugins := TAmsPluginList.Create;
  gRefreshNote := '';
  BuildControls;
  Layout;
  if gOpts.Offscreen then ShowWindow(gWin, SW_SHOWNOACTIVATE)
  else ShowWindow(gWin, SW_SHOW);

  { Sofort: was installiert und zwischengespeichert ist - ohne Netz }
  First := TAmsPluginList.Create;
  try
    AmsStoreRefresh(gOpts.Store, First, nil, True, nil);
  except
    on E: Exception do AmsLog('PluginManager: Erstanzeige: ' + E.Message);
  end;
  ReplacePlugins(First);
  ShowSelected;
  { Dann frisch aus den Quellen }
  StartRefresh(False);
  Result := True;
end;

procedure AmsPluginManagerClose;
var
  i: Integer;
  Msg: TMsg;
begin
  { Threads abwarten - sie laufen in diesem Modul }
  if gThreads <> nil then
  begin
    for i := gThreads.Count - 1 downto 0 do
    begin
      WaitForThreadTerminate(TThreadID(gThreads[i]), THREAD_WAIT_MS);
      CloseThread(TThreadID(gThreads[i]));
    end;
    gThreads.Clear;
  end;
  if gWin <> 0 then
  begin
    { liegengebliebene Ergebnisse freigeben }
    while PeekMessageW(Msg, gWin, WM_PM_JOB, WM_PM_JOB, PM_REMOVE) do
      FreeJob(PJob(Msg.lParam));
    FreeAndNil(gView);          { COM los, bevor das Elternfenster geht }
    DestroyWindow(gWin);
    gWin := 0;
  end
  else
    FreeAndNil(gView);
  AmsImageListDestroy(gImages);
  gImages := 0;
  FreeAndNil(gPlugins);
  SetLength(gIconIndex, 0);
  gRefreshing := False;
  gStaging := False;
  gApplying := False;
  if gRegistered then
  begin
    UnregisterClassW(PWideChar(gClassW), HInstance);
    gRegistered := False;
  end;
end;

function AmsPluginManagerHandle: HWND;
begin
  Result := gWin;
end;

{ ---------------------------------------------------- fuer Rauchtests ---- }

function AmsPluginManagerBusy: Boolean;
begin
  Result := gRefreshing or gStaging or gApplying or
            ((gThreads <> nil) and (gThreads.Count > 0));
end;

function AmsPluginManagerCount: Integer;
begin
  if gWin = 0 then Result := 0 else Result := AmsListViewCount(gList);
end;

function AmsPluginManagerItemText(AIndex, ASub: Integer): WideString;
begin
  if gWin = 0 then Result := '' else Result := AmsListViewGetText(gList, AIndex, ASub);
end;

function AmsPluginManagerSelect(const AName: string): Boolean;
var
  i, n: Integer;
begin
  Result := False;
  if (gWin = 0) or (gPlugins = nil) then Exit;
  for i := 0 to AmsListViewCount(gList) - 1 do
  begin
    n := Integer(AmsListViewData(gList, i));
    if (n >= 0) and (n < gPlugins.Count) and SameText(gPlugins[n].Name, AName) then
    begin
      AmsListViewSelect(gList, i);
      Exit(True);
    end;
  end;
end;

function AmsPluginManagerSelected: string;
begin
  Result := SelectedName;
end;

function AmsPluginManagerStatus: WideString;
begin
  Result := AmsGetWndText(gStatus);
end;

function AmsPluginManagerPage: string;
begin
  Result := gPage;
end;

function AmsPluginManagerPageHasReadme: Boolean;
begin
  Result := gPageHasReadme;
end;

function AmsPluginManagerReadyState: Integer;
begin
  if gView = nil then Result := -1 else Result := gView.ReadyState;
end;

finalization
  AmsPluginManagerClose;
  FreeAndNil(gThreads);
  FreeAndNil(gChanged);
  FreeAndNil(gHandlers);

end.
