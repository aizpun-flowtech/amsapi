library Recorder;

{ ============================================================================
  Zusehen, was AMS tut.

  Ein Ribbon-Button oeffnet das Verlaufsfenster. Darin laeuft Zeile fuer Zeile
  mit, was der Host gerade macht: welcher Klick, welche Action, welches SQL,
  und wie lange es dauert - eingerueckt nach Verschachtelung, damit man sieht,
  was wovon ausgeloest wird.

  ZUSEHEN BRAUCHT KEINE DATEI. Wer den Verlauf behalten will, drueckt im
  Fenster "Aufzeichnen"; dann laeuft zusaetzlich

    %TEMP%\Recorder.trace.tsv

  mit, die sich unveraendert in Excel oeffnen laesst. Ausschalten geht
  jederzeit, das Zusehen laeuft weiter.

  Das Plugin selbst kann nichts - alles Koennen steckt in AmsApi.Recorder,
  AmsApi.Trace und AmsApi.TraceWindow. Hier wird nur verdrahtet.

  Einstellungen stehen in plugin.ini.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  SysUtils, Classes,
  AmsApi.Plugin, AmsApi.Log, AmsApi.Ini, AmsApi.Trace, AmsApi.Recorder,
  AmsApi.TraceWindow, AmsApi.Ribbon, AmsApi.Hook;

type
  TRecorderPlugin = class(TAmsPlugin)
  private
    FButton: Pointer;
  protected
    procedure Startup; override;
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
    procedure SessionChanged; override;
    procedure BeforeUnload; override;
  end;

procedure TRecorderPlugin.Startup;
begin
  { Kategorien aus der INI vorbelegen - im Fenster laesst sich das jederzeit
    umschalten. Wer nur die Bedienung sehen will, schaltet SQL ab. }
  if not AmsIniBool('SQL', True, 'Aufzeichnung') then
    AmsTraceCategories := AmsTraceCategories - [tcSql];
  if not AmsIniBool('Actions', True, 'Aufzeichnung') then
    AmsTraceCategories := AmsTraceCategories - [tcAction, tcEvent];
  if not AmsIniBool('Klicks', True, 'Aufzeichnung') then
    AmsTraceCategories := AmsTraceCategories - [tcUi];

  AmsTraceMaxDetail := AmsIniInt('MaxDetail', 500, 'Aufzeichnung');
  AmsTraceRingMax := AmsIniInt('Zeilenpuffer', 2000, 'Aufzeichnung');
  AmsTraceToLog := AmsIniBool('AuchInsLog', False, 'Aufzeichnung');
end;

procedure TRecorderPlugin.AfterMainWindow;
begin
  FButton := AddRibbonButton('Verlauf',
    'Zusehen, was AMS tut: Klicks, Actions, SQL', 'icon32.png');
  if FButton = nil then
    Log('Kein Ribbon-Button: ' + LastError);

  { Fenster gleich aufmachen, wenn die INI das sagt - dafuer gedacht, das
    Hochfahren von AMS selbst zu beobachten. }
  if AmsIniBool('FensterBeimStart', False, 'Aufzeichnung') then
    AmsTraceWindowOpen(MainWindow);
end;

procedure TRecorderPlugin.ButtonClick(ASender: Pointer; ATag: Integer);
begin
  if not AmsTraceWindowOpen(MainWindow) then
    ShowLastError('Verlaufsfenster');
end;

procedure TRecorderPlugin.SessionChanged;
begin
  { fbclient.dll wird erst mit der Anmeldung an einem Mandanten geladen.
    Sieht gerade jemand zu, wird der SQL-Teil jetzt nachgezogen - beim
    Oeffnen des Fensters war er noch nicht zu haben. }
  if AmsTraceCollecting and (not AmsRecordSqlRunning) then
    if AmsRecordSqlStart then
      Log('SQL-Mitschnitt nach dem Mandantenwechsel nachgestartet');

  { Ein Mandantenwechsel baut Formulare neu auf. Was danach entsteht, war
    beim ersten Durchlauf noch nicht da. }
  if AmsTraceCollecting then
    LogFmt('Klick-Mitschnitt erneuert: %d Elemente',
           [AmsRecordClicksStart]);
end;

procedure TRecorderPlugin.BeforeUnload;
begin
  { Pflicht, und zwar in dieser Reihenfolge. Das Fenster zuerst: seine
    Fensterprozedur liegt in diesem Modul, und eine Nachricht nach dem
    Entladen waere ein Sprung ins Nichts. Danach die Detours - dasselbe
    Problem eine Ebene tiefer. }
  AmsTraceWindowClose;
  AmsRecordStopAll;
  AmsHookReleaseAll;
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(TRecorderPlugin);
end.
