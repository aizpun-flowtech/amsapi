unit AmsApi.Recorder;

{ ============================================================================
  AmsApi.Recorder - die Quellen der Aufzeichnung

  AmsApi.Trace nimmt Ereignisse entgegen; diese Unit besorgt sie. Drei
  Quellen, einzeln ein- und ausschaltbar:

  1. SQL       jede Anweisung an die Datenbank, mit Dauer
  2. Actions   jede benannte TafnAction und jedes TafnEvent des Hosts
  3. Klicks    jedes OnClick der Oberflaeche

  Zusammen ergibt das die Zuordnung, um die es geht: der Klick oeffnet den
  Vorgang, die Action haengt darunter, das SQL darunter. AmsApi.Trace fuehrt
  je Thread den Stapel, hier wird nur Enter/Leave sauber geklammert.

  ---------------------------------------------------------------------------
  Warum SQL ueber fbclient.dll und nicht ueber UniDAC

  AMS spricht Firebird ueber UniDAC (ASSFINETWIN.ini: DbType=Firebird,
  VendorLib=fbclient.dll). Es gaebe drei Ansatzpunkte:

    TUniSQLMonitor      Devarts eigener Mitschnitt. Braucht einen Delphi-
                        Konstruktor und ein Ereignis mit drei Parametern -
                        und die Annahme, dass er ohne Debug-Flag an den
                        Komponenten ueberhaupt feuert. Zu viele Annahmen.
    TCustomDASQL.Execute  Gaebe den Komponentennamen dazu, aber der SQL-Text
                        haengt an nicht-published properties; ohne
                        Feldoffsets kommt man nicht heran.
    fbclient.dll        Der Flaschenhals ganz unten. Reine C-Funktionen,
                        stdcall (belegt: isc_dsql_execute_immediate endet
                        auf "ret 1Ch" = 7 Argumente), der SQL-Text ist ein
                        schlichter char*. Kein Delphi-Typ, kein Heap-Thema.

  Also fbclient. UniDAC laedt die DLL ueber VendorLib= dynamisch nach, es
  gibt daher KEINEN Eintrag in einer Importtabelle - der sichere IAT-Weg
  faellt aus, es bleibt der Detour auf die exportierte Funktion.

  Was dabei mitgeschrieben wird, ist der SQL-TEXT, nicht der Inhalt der
  Parameter. Das ist Absicht: Parameter sind Kundendaten.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes,
  AmsApi.Types, AmsApi.Log, AmsApi.Bind, AmsApi.Rtti, AmsApi.Props,
  AmsApi.Trace, AmsApi.Hook, AmsApi.Ui;

{ ------------------------------------------------------------------- SQL -- }

{ Datenbankverkehr aufzeichnen. Haengt sich an isc_dsql_prepare,
  isc_dsql_execute und isc_dsql_execute_immediate in fbclient.dll.
  False mit Klartext, wenn die DLL nicht geladen ist (dann ist noch kein
  Mandant offen - nach der Anmeldung nochmal versuchen). }
function  AmsRecordSqlStart: Boolean;
procedure AmsRecordSqlStop;
function  AmsRecordSqlRunning: Boolean;

{ ------------------------------------------------------- Actions / Events -- }

{ Benannte TafnAction und TafnEvent des Hosts mitschreiben. Das ist der Weg,
  ueber den sich auch ELO und DocuWare einklinken - hier laeuft praktisch
  alles vorbei, was AMS fachlich tut. }
function  AmsRecordActionsStart: Boolean;
procedure AmsRecordActionsStop;
function  AmsRecordActionsRunning: Boolean;

{ ----------------------------------------------------------------- Klicks -- }

{ Jedes belegte OnClick der Oberflaeche mitschreiben. Liefert die Anzahl der
  uebernommenen Elemente. Elemente ohne OnClick werden uebergangen - dort
  passiert ohnehin nichts.
  Nach dem Oeffnen eines neuen Formulars erneut aufrufen: was der Host spaeter
  aufbaut, kann beim ersten Durchlauf noch nicht dabei gewesen sein. }
function  AmsRecordClicksStart: Integer;
procedure AmsRecordClicksStop;
function  AmsRecordClicksCount: Integer;

{ ------------------------------------------------------------------ Alles -- }

{ Alles in einem Aufruf. Liefert True, wenn wenigstens eine Quelle steht.
  Was nicht geht, steht als Klartext im Log - ein fehlendes fbclient ist
  kein Grund, auch die Klicks nicht aufzuzeichnen. }
function  AmsRecordStartAll(const ATraceFile: string = ''): Boolean;

{ Sauber abbauen. GEHOERT IN JEDES BeforeUnload - ein stehengebliebener
  Detour ins entladene Modul ist ein sicherer Absturz. }
procedure AmsRecordStopAll;

{ Kurzstand fuer ein Diagnosefenster oder das Log. }
function  AmsRecordStatus: string;

{ Aus einem SQL-Text die Kurzform fuer die Spalte "Betreff" machen:
  "SELECT ... FROM KUNDE WHERE ..." wird zu "SELECT KUNDE". Damit zaehlt der
  Bericht gleichartige Anweisungen zusammen, statt jede Variante einzeln zu
  fuehren. Oeffentlich, weil ohne AMS testbar. }
function  AmsSqlSubject(const ASql: string): string;

implementation

{ ==========================================================================
  SQL
  ========================================================================== }

type
  { Firebird-API, alles stdcall. Handles sind void*, Status ein Array von
    ISC_STATUS - wir fassen davon nichts an ausser dem Rueckgabewert. }
  TFnDsqlPrepare = function(AStatus, ATrans, AStmt: Pointer; ALen: Word;
    AStr: PAnsiChar; ADialect: Word; ASqlda: Pointer): Integer; stdcall;
  TFnDsqlExecute = function(AStatus, ATrans, AStmt: Pointer; ADialect: Word;
    ASqlda: Pointer): Integer; stdcall;
  TFnDsqlExecImmediate = function(AStatus, ADb, ATrans: Pointer; ALen: Word;
    AStr: PAnsiChar; ADialect: Word; ASqlda: Pointer): Integer; stdcall;

const
  { Vorbereitete Anweisungen werden einmal uebersetzt und tausendfach
    ausgefuehrt. Ohne diese Zuordnung stuende bei jedem Execute nur eine
    Handle-Nummer - und die Aufzeichnung waere wertlos. }
  STMT_MAX = 256;

type
  TStmtEntry = record
    Handle: PtrUInt;
    Sql: string;
    Subject: string;
  end;

var
  gSqlOn: Boolean = False;
  gPrepareOrig: Pointer = nil;
  gExecuteOrig: Pointer = nil;
  gExecImmOrig: Pointer = nil;
  { Die gepatchten Adressen. AmsUnhookCode will das ZIEL, nicht den Detour. }
  gPrepareAt: Pointer = nil;
  gExecuteAt: Pointer = nil;
  gExecImmAt: Pointer = nil;
  gStmts: array[0..STMT_MAX - 1] of TStmtEntry;
  gStmtNext: Integer = 0;
  gStmtLock: TRTLCriticalSection;
  gStmtLockReady: Boolean = False;

function AmsSqlSubject(const ASql: string): string;
var
  S, Verb, Wort: string;
  i, n: Integer;

  { Trenner zwischen zwei Woertern. Das Komma gehoert unbedingt dazu:
    "select id, name from kunde" haette sonst nach "id," aufgehoert und
    die Tabelle nie gefunden. }
  function IstTrenner(C: Char): Boolean;
  begin
    Result := (C = ' ') or (C = ',') or (C = '(') or (C = ')') or (C = ';');
  end;

  { Naechstes Wort ab Position i, i steht danach hinter dem Wort. }
  function NextWord: string;
  var
    Start: Integer;
  begin
    while (i <= n) and IstTrenner(S[i]) do Inc(i);
    Start := i;
    while (i <= n) and (not IstTrenner(S[i])) do Inc(i);
    Result := Copy(S, Start, i - Start);
  end;

begin
  S := AmsTraceClean(ASql, 4000);
  n := Length(S);
  i := 1;
  Verb := UpperCase(NextWord);
  if Verb = '' then Exit('(leer)');
  Result := Verb;

  { Das interessante Wort steht je nach Anweisung woanders. }
  if (Verb = 'INSERT') or (Verb = 'SELECT') or (Verb = 'DELETE') then
  begin
    while i <= n do
    begin
      Wort := UpperCase(NextWord);
      if Wort = '' then Break;
      if (Wort = 'FROM') or (Wort = 'INTO') then
      begin
        Wort := NextWord;
        if Wort <> '' then Result := Verb + ' ' + UpperCase(Wort);
        Break;
      end;
    end;
  end
  else if (Verb = 'UPDATE') or (Verb = 'EXECUTE') then
  begin
    Wort := NextWord;
    if UpperCase(Wort) = 'PROCEDURE' then Wort := NextWord;
    if Wort <> '' then Result := Verb + ' ' + UpperCase(Wort);
  end;
end;

{ SQL-Text zu einem Anweisungshandle merken. }
procedure RememberStmt(AHandle: PtrUInt; const ASql, ASubject: string);
var
  i: Integer;
begin
  if (AHandle = 0) or (not gStmtLockReady) then Exit;
  EnterCriticalSection(gStmtLock);
  try
    for i := 0 to STMT_MAX - 1 do
      if gStmts[i].Handle = AHandle then
      begin
        gStmts[i].Sql := ASql;
        gStmts[i].Subject := ASubject;
        Exit;
      end;
    { Ringpuffer: der aelteste Eintrag faellt heraus. Bei 256 offenen
      Anweisungen ist das verkraftbar, und es waechst nichts. }
    gStmts[gStmtNext].Handle := AHandle;
    gStmts[gStmtNext].Sql := ASql;
    gStmts[gStmtNext].Subject := ASubject;
    gStmtNext := (gStmtNext + 1) mod STMT_MAX;
  finally
    LeaveCriticalSection(gStmtLock);
  end;
end;

function LookupStmt(AHandle: PtrUInt; out ASql, ASubject: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  ASql := '';
  ASubject := '';
  if (AHandle = 0) or (not gStmtLockReady) then Exit;
  EnterCriticalSection(gStmtLock);
  try
    for i := 0 to STMT_MAX - 1 do
      if gStmts[i].Handle = AHandle then
      begin
        ASql := gStmts[i].Sql;
        ASubject := gStmts[i].Subject;
        Exit(True);
      end;
  finally
    LeaveCriticalSection(gStmtLock);
  end;
end;

{ Text aus dem C-Aufruf holen. Laenge 0 heisst nullterminiert. }
function SqlTextOf(AStr: PAnsiChar; ALen: Word): string;
var
  A: AnsiString;
begin
  Result := '';
  if AStr = nil then Exit;
  try
    if ALen = 0 then
      { 0 heisst laut Firebird-API: nullterminiert. Nur dann darf gesucht
        werden. }
      A := AnsiString(AStr)
    else
      { SetString kopiert GENAU ALen Bytes. Der vorherige Weg ueber
        AnsiString(AStr) hat erst den ganzen C-String bis zur naechsten Null
        eingelesen und danach gekuerzt - bei einem Text mit Laengenangabe
        muss dort aber gar keine Null stehen. Das laeuft frueher oder spaeter
        aus der Seite heraus, und dann steht AMS. }
      SetString(A, AStr, ALen);
    Result := string(A);
  except
    Result := '(Text nicht lesbar)';
  end;
end;

function DsqlPrepareDetour(AStatus, ATrans, AStmt: Pointer; ALen: Word;
  AStr: PAnsiChar; ADialect: Word; ASqlda: Pointer): Integer; stdcall;
var
  Sql, Subj: string;
  Id: Integer;
  H: PtrUInt;
begin
  Sql := '';
  Id := 0;
  if gSqlOn then
  try
    Sql := SqlTextOf(AStr, ALen);
    Subj := AmsSqlSubject(Sql);
    Id := AmsTraceEnter(tcSql, 'PREPARE ' + Subj, Sql);
  except
    Id := 0;
  end;

  Result := TFnDsqlPrepare(gPrepareOrig)(AStatus, ATrans, AStmt, ALen, AStr,
                                         ADialect, ASqlda);

  if Id <> 0 then
  try
    { Das Handle steht erst NACH dem Aufruf sicher fest. }
    H := 0;
    if AStmt <> nil then H := PPtrUInt(AStmt)^;
    RememberStmt(H, Sql, Subj);
    AmsTraceLeave(Id, Format('Handle %x', [H]));
  except
  end;
end;

function DsqlExecuteDetour(AStatus, ATrans, AStmt: Pointer; ADialect: Word;
  ASqlda: Pointer): Integer; stdcall;
var
  Sql, Subj: string;
  Id: Integer;
  H: PtrUInt;
begin
  Id := 0;
  if gSqlOn then
  try
    H := 0;
    if AStmt <> nil then H := PPtrUInt(AStmt)^;
    if not LookupStmt(H, Sql, Subj) then
    begin
      Subj := Format('(Anweisung %x)', [H]);
      Sql := '';
    end;
    Id := AmsTraceEnter(tcSql, Subj, Sql);
  except
    Id := 0;
  end;

  Result := TFnDsqlExecute(gExecuteOrig)(AStatus, ATrans, AStmt, ADialect,
                                         ASqlda);
  if Id <> 0 then AmsTraceLeave(Id);
end;

function DsqlExecImmediateDetour(AStatus, ADb, ATrans: Pointer; ALen: Word;
  AStr: PAnsiChar; ADialect: Word; ASqlda: Pointer): Integer; stdcall;
var
  Sql: string;
  Id: Integer;
begin
  Id := 0;
  if gSqlOn then
  try
    Sql := SqlTextOf(AStr, ALen);
    Id := AmsTraceEnter(tcSql, AmsSqlSubject(Sql), Sql);
  except
    Id := 0;
  end;

  Result := TFnDsqlExecImmediate(gExecImmOrig)(AStatus, ADb, ATrans, ALen,
                                               AStr, ADialect, ASqlda);
  if Id <> 0 then AmsTraceLeave(Id);
end;

function AmsRecordSqlStart: Boolean;
var
  Fb: HMODULE;
  P: Pointer;
  Anzahl: Integer;

  function Haenge(const AName: string; ADetour: Pointer;
    var AOrig, AAt: Pointer): Boolean;
  begin
    Result := False;
    AAt := nil;
    P := GetProcAddress(Fb, PAnsiChar(AnsiString(AName)));
    if P = nil then
    begin
      AmsLogFmt('SQL-Mitschnitt: %s fehlt in fbclient.dll', [AName]);
      Exit;
    end;
    Result := AmsHookCode(P, ADetour, AOrig, AName);
    if Result then AAt := P
    else
      AmsLogFmt('SQL-Mitschnitt: %s nicht gehookt - %s',
                [AName, AmsLastError]);
  end;

begin
  if gSqlOn then Exit(True);
  { Was gar nicht aufgezeichnet werden soll, wird auch nicht gepatcht. Damit
    ist "SQL=0" in der plugin.ini der Notausgang, wenn ein Hook Aerger macht -
    ohne dass deswegen die anderen Quellen ausfallen. }
  if not (tcSql in AmsTraceCategories) then
    Exit(AmsFail('SQL-Mitschnitt: Kategorie SQL ist abgeschaltet'));

  { Nicht selbst laden: liegt fbclient nicht im Prozess, ist noch kein
    Mandant offen. Dann waere ein LoadLibrary hier eine zweite Instanz,
    die niemand benutzt. }
  Fb := GetModuleHandleW('fbclient.dll');
  if Fb = 0 then
    Exit(AmsFail('SQL-Mitschnitt: fbclient.dll ist nicht geladen - erst ' +
                 'nach der Anmeldung an einem Mandanten versuchen'));

  Anzahl := 0;
  if Haenge('isc_dsql_prepare', @DsqlPrepareDetour, gPrepareOrig,
            gPrepareAt) then Inc(Anzahl);
  if Haenge('isc_dsql_execute', @DsqlExecuteDetour, gExecuteOrig,
            gExecuteAt) then Inc(Anzahl);
  if Haenge('isc_dsql_execute_immediate', @DsqlExecImmediateDetour,
            gExecImmOrig, gExecImmAt) then Inc(Anzahl);

  if Anzahl = 0 then
    Exit(AmsFail('SQL-Mitschnitt: keine einzige Funktion gehookt'));

  gSqlOn := True;
  AmsLogFmt('SQL-Mitschnitt laeuft (%d von 3 Funktionen)', [Anzahl]);
  Result := True;
end;

procedure AmsRecordSqlStop;
begin
  if not gSqlOn then Exit;
  { ZUERST abschalten, dann erst die Detours loesen: was noch mitten im
    Aufruf steckt, faellt damit sofort auf den geraden Weg zurueck. }
  gSqlOn := False;
  if gPrepareAt <> nil then AmsUnhookCode(gPrepareAt);
  if gExecuteAt <> nil then AmsUnhookCode(gExecuteAt);
  if gExecImmAt <> nil then AmsUnhookCode(gExecImmAt);
  gPrepareOrig := nil;  gPrepareAt := nil;
  gExecuteOrig := nil;  gExecuteAt := nil;
  gExecImmOrig := nil;  gExecImmAt := nil;
  AmsLog('SQL-Mitschnitt beendet');
end;

function AmsRecordSqlRunning: Boolean;
begin
  Result := gSqlOn;
end;

{ ==========================================================================
  Actions und Events
  ========================================================================== }

var
  gActOn: Boolean = False;
  gActExecOrig: Pointer = nil;
  gEvtFireOrig: Pointer = nil;
  gActExecAt: Pointer = nil;
  gEvtFireAt: Pointer = nil;

{ Name eines Host-Objekts, so gut es geht. }
function NameOf(AObj: Pointer): string;
begin
  Result := '';
  if AObj = nil then Exit('(nil)');
  try
    Result := AmsName(AObj);
    if Result = '' then Result := AmsGetStr(AObj, 'Name');
    if Result = '' then Result := Format('%s@%p', [AmsClassName(AObj), AObj]);
  except
    Result := '(unlesbar)';
  end;
end;

procedure ActionExecuteDetour(Self, APacket, AUserData: Pointer); register;
var
  Id: Integer;
begin
  Id := 0;
  if gActOn then
  try
    Id := AmsTraceEnter(tcAction, NameOf(Self), AmsClassName(Self));
  except
    Id := 0;
  end;
  try
    TFnActExecute(gActExecOrig)(Self, APacket, AUserData);
  finally
    if Id <> 0 then AmsTraceLeave(Id);
  end;
end;

procedure EventFireDetour(Self, APacket, AUserData: Pointer;
  AOptions: Byte); register;
var
  Id: Integer;
begin
  Id := 0;
  if gActOn then
  try
    Id := AmsTraceEnter(tcEvent, NameOf(Self), AmsClassName(Self));
  except
    Id := 0;
  end;
  try
    TFnEvtFire(gEvtFireOrig)(Self, APacket, AUserData, AOptions);
  finally
    if Id <> 0 then AmsTraceLeave(Id);
  end;
end;

function AmsRecordActionsStart: Boolean;
var
  Anzahl: Integer;
  Ziel: Pointer;
begin
  if gActOn then Exit(True);
  if not (tcAction in AmsTraceCategories) then
    Exit(AmsFail('Action-Mitschnitt: Kategorie Action ist abgeschaltet'));
  if not AmsBindAfn then
    Exit(AmsFail('Action-Mitschnitt: afnComponentsRt.bpl nicht gebunden'));

  Anzahl := 0;
  { hcActionExecute ist eine VARIABLE mit dem Funktionszeiger. "@davor" waere
    die Adresse der Variablen (man patcht sonst den eigenen Datenbereich),
    und der blosse Name RUFT sie im Delphi-Modus auf. Deshalb der Umweg
    ueber PPointer: das liest den Inhalt, ohne etwas auszufuehren. }
  Ziel := PPointer(@hcActionExecute)^;
  if Ziel <> nil then
    if AmsHookCode(Ziel, @ActionExecuteDetour, gActExecOrig,
                   'TafnAction.Execute') then
    begin
      gActExecAt := Ziel;
      Inc(Anzahl);
    end;
  Ziel := PPointer(@hcEventFire)^;
  if Ziel <> nil then
    if AmsHookCode(Ziel, @EventFireDetour, gEvtFireOrig,
                   'TafnEvent.Fire') then
    begin
      gEvtFireAt := Ziel;
      Inc(Anzahl);
    end;

  if Anzahl = 0 then
    Exit(AmsFailFmt('Action-Mitschnitt: nichts gehookt - %s',
                    [AmsLastError]));
  gActOn := True;
  AmsLogFmt('Action-Mitschnitt laeuft (%d von 2)', [Anzahl]);
  Result := True;
end;

procedure AmsRecordActionsStop;
begin
  if not gActOn then Exit;
  gActOn := False;
  if gActExecAt <> nil then AmsUnhookCode(gActExecAt);
  if gEvtFireAt <> nil then AmsUnhookCode(gEvtFireAt);
  gActExecOrig := nil;  gActExecAt := nil;
  gEvtFireOrig := nil;  gEvtFireAt := nil;
  AmsLog('Action-Mitschnitt beendet');
end;

function AmsRecordActionsRunning: Boolean;
begin
  Result := gActOn;
end;

{ ==========================================================================
  Klicks

  Hier wird NICHT gepatcht: AmsApi.Ui setzt das published OnClick um und
  traegt es beim Entladen zurueck. Der Beobachter darunter klammert nur
  Enter/Leave um den Originalaufruf.
  ========================================================================== }

var
  gClickOn: Boolean = False;
  gClickCount: Integer = 0;

{ Wird von AmsApi.Ui vor und nach dem urspruenglichen Ereignis gerufen. }
procedure ClickWatcher(AObj: Pointer; const AProp: string; ASender: Pointer;
  var AToken: Integer; ABefore: Boolean);
var
  Betreff, Detail: string;
begin
  if not gClickOn then Exit;
  try
    if ABefore then
    begin
      Betreff := AmsName(AObj);
      if Betreff = '' then Betreff := AmsGetStr(AObj, 'Caption');
      if Betreff = '' then Betreff := AmsClassName(AObj);
      Detail := Format('%s [%s] %s', [AmsElementPath(AObj),
                                      AmsClassName(AObj), AProp]);
      AToken := AmsTraceEnter(tcUi, AProp + ' ' + Betreff, Detail);
    end
    else
    begin
      AmsTraceLeave(AToken);
      AToken := 0;
    end;
  except
    AToken := 0;
  end;
end;

function AmsRecordClicksStart: Integer;
var
  Filter: TAmsElementFilter;
  Liste: TAmsElementArray;
  i, n: Integer;
  M: TDelphiMethod;
begin
  Result := 0;
  if not (tcUi in AmsTraceCategories) then
  begin
    AmsFail('Klick-Mitschnitt: Kategorie Ui ist abgeschaltet');
    Exit;
  end;
  Filter := AmsFilterAll;
  n := AmsFindElements(Filter, Liste);
  if n = 0 then
  begin
    AmsFail('Klick-Mitschnitt: kein einziges Element gefunden');
    Exit;
  end;

  AmsEventWatcher := ClickWatcher;
  gClickOn := True;
  for i := 0 to n - 1 do
  begin
    { Nur belegte Ereignisse. Ein leeres OnClick zu uebernehmen hiesse,
      dem Element ein Verhalten zu geben, das es vorher nicht hatte. }
    if not AmsGetPropMethod(Liste[i].Obj, 'OnClick', M) then Continue;
    if M.Code = nil then Continue;
    if AmsHookEvent(Liste[i].Obj, 'OnClick', nil, 0, True) then Inc(Result);
  end;
  gClickCount := Result;
  AmsLogFmt('Klick-Mitschnitt: %d von %d Elementen uebernommen',
            [Result, n]);
end;

procedure AmsRecordClicksStop;
begin
  if not gClickOn then Exit;
  gClickOn := False;
  AmsEventWatcher := nil;
  AmsUnhookAll;
  gClickCount := 0;
  AmsLog('Klick-Mitschnitt beendet');
end;

function AmsRecordClicksCount: Integer;
begin
  Result := gClickCount;
end;

{ ==========================================================================
  Alles zusammen
  ========================================================================== }

function AmsRecordStartAll(const ATraceFile: string): Boolean;
var
  Quellen: Integer;
  WarSchonAn: Boolean;
begin
  { OHNE Dateinamen wird nur gesammelt - zum Zusehen im Fenster. Eine Datei
    entsteht erst, wenn eine verlangt wird. }
  WarSchonAn := AmsTraceCollecting;
  if not WarSchonAn then
    if not AmsTraceBegin then Exit(False);
  if (ATraceFile <> '') and (not AmsTraceRecording) then
    AmsTraceRecordTo(ATraceFile);

  Quellen := 0;
  if AmsRecordSqlStart then Inc(Quellen);
  if AmsRecordActionsStart then Inc(Quellen);
  if AmsRecordClicksStart > 0 then Inc(Quellen);

  Result := Quellen > 0;
  if Result then
    AmsTraceNote(tcPlugin, 'Aufzeichnung gestartet', AmsRecordStatus)
  else
  begin
    { Nichts anzuzeigen - dann auch nicht sammeln. Sonst bliebe ein
      Verlauf an, der bis in alle Ewigkeit leer ist. }
    if not WarSchonAn then AmsTraceEnd;
    AmsFail('Aufzeichnung: keine einzige Quelle verfuegbar');
  end;
end;

procedure AmsRecordStopAll;
begin
  { Reihenfolge zaehlt: erst die Quellen abklemmen, dann die Senke
    schliessen - sonst schreibt ein noch laufender Detour in eine
    geschlossene Datei. }
  AmsRecordClicksStop;
  AmsRecordActionsStop;
  AmsRecordSqlStop;
  if AmsTraceRunning then
  begin
    AmsTraceNote(tcPlugin, 'Aufzeichnung beendet');
    AmsTraceStop;
  end;
end;

function AmsRecordStatus: string;
begin
  Result := Format('SQL %s, Actions %s, Klicks %d, Zeilen %d',
    [BoolToStr(gSqlOn, 'an', 'aus'), BoolToStr(gActOn, 'an', 'aus'),
     gClickCount, AmsTraceCount]);
end;

initialization
  InitializeCriticalSection(gStmtLock);
  gStmtLockReady := True;

finalization
  AmsRecordStopAll;
  gStmtLockReady := False;
  DeleteCriticalSection(gStmtLock);

end.
