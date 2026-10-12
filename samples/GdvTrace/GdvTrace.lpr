library GdvTrace;

{ ============================================================================
  GDV-Import bei Laufzeit mitschneiden.

  Ein Ribbon-Button oeffnet das Verlaufsfenster. Darin laeuft Zeile fuer Zeile
  mit, was AMS beim GDV-Import tut - verschachtelt und mit Dauer:

    Einlesen (ImportGDV, LoadFromStream, SplitDatei)
      -> Zuordnen (IdentifyItem, FindCandidates)
         -> JS Identify(), JS Sparte() = DIV
      -> Schreiben (ExportItem)
         -> JS ExportKunde(), JS ExportVertrag()
    JS Objekt: Gdv / Options / Context / CandidateInfo ...
    (Feldebene:) JS liest Feld 0200..1..004, JS liest Schluessel B003 ...

  Damit ist sichtbar, WANN welche JS-Funktion des Uebersetzungsscripts laeuft
  und - mit Feldebene - WELCHE GDV-Felder das Script liest.

  Alles Koennen steckt in AmsApi.GdvTrace / AmsApi.Trace / AmsApi.TraceWindow /
  AmsApi.Recorder. Hier wird nur verdrahtet. Schalter in plugin.ini.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  SysUtils, Classes,
  AmsApi.Plugin, AmsApi.Log, AmsApi.Ini, AmsApi.Trace, AmsApi.GdvTrace,
  AmsApi.Recorder, AmsApi.TraceWindow, AmsApi.Ribbon, AmsApi.Hook;

type
  TGdvTracePlugin = class(TAmsPlugin)
  private
    FButton: Pointer;
    FFields: Boolean;
    FWithSql: Boolean;
  protected
    procedure Startup; override;
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
    procedure SessionChanged; override;
    procedure BeforeUnload; override;
  end;

procedure TGdvTracePlugin.Startup;
begin
  FFields  := AmsIniBool('Feldebene', False, 'Aufzeichnung');
  FWithSql := AmsIniBool('MitSQL', True, 'Aufzeichnung');
  AmsTraceMaxDetail := AmsIniInt('MaxDetail', 300, 'Aufzeichnung');
  AmsTraceRingMax   := AmsIniInt('Zeilenpuffer', 4000, 'Aufzeichnung');
  AmsTraceToLog     := AmsIniBool('AuchInsLog', False, 'Aufzeichnung');
end;

procedure TGdvTracePlugin.AfterMainWindow;
var N: Integer;
begin
  FButton := AddRibbonButton('GDV-Trace',
    'Mitschneiden, was der GDV-Import tut: Phasen, JS-Aufrufe, Felder',
    'icon32.png');
  if FButton = nil then
    Log('Kein Ribbon-Button: ' + LastError);

  { Sammeln sofort anwerfen, damit auch ein frueher Import erfasst wird -
    das Zusehen (Fenster) ist davon unabhaengig. }
  AmsTraceBegin;

  { Die GDV-Hooks setzen. }
  N := AmsGdvTraceStart(FFields);
  LogFmt('GDV-Trace: %d Hooks gesetzt (Feldebene %s)',
         [N, BoolToStr(FFields, True)]);

  { Optional den Datenbankverkehr dazunehmen - zeigt die SQLs, die ExportItem
    ausloest. Bewusst nur SQL (keine Actions - zu geraeuschvoll und fuer GDV
    ohne Nutzen), idempotent und gekapselt, damit ein fehlender Mandant oder
    ein stoerrischer Hook AfterMainWindow nicht abbricht. Den Regelfall deckt
    ohnehin SessionChanged ab. }
  if FWithSql and (not AmsRecordSqlRunning) then
    try
      if not AmsRecordSqlStart then
        Log('SQL-Mitschnitt noch nicht moeglich (kein Mandant offen) - kommt mit der Anmeldung');
    except
      Log('SQL-Mitschnitt uebersprungen (nicht kritisch): ' + LastError);
    end;

  if AmsIniBool('FensterBeimStart', False, 'Aufzeichnung') then
    AmsTraceWindowOpen(MainWindow);
end;

procedure TGdvTracePlugin.ButtonClick(ASender: Pointer; ATag: Integer);
begin
  if not AmsTraceWindowOpen(MainWindow) then
    ShowLastError('GDV-Trace-Fenster');
end;

procedure TGdvTracePlugin.SessionChanged;
begin
  if FWithSql and (not AmsRecordSqlRunning) then
    if AmsRecordSqlStart then
      Log('SQL-Mitschnitt nach Mandantenwechsel nachgestartet');
end;

procedure TGdvTracePlugin.BeforeUnload;
begin
  { Reihenfolge wie beim Recorder: erst das Fenster (seine Fensterprozedur
    liegt in diesem Modul), dann die Detours loesen. }
  AmsTraceWindowClose;
  AmsGdvTraceStop;
  AmsRecordStopAll;
  AmsHookReleaseAll;
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(TGdvTracePlugin);
end.
