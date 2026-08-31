unit AmsApi.Trace;

{ ============================================================================
  AmsApi.Trace - Aufzeichnung dessen, was AMS tut

  Das normale Log (AmsApi.Log) beantwortet "was hat mein Plugin gemacht".
  Diese Unit beantwortet die andere Frage: "was macht AMS eigentlich, wenn ich
  hier klicke" - welche Action laeuft an, welches Ereignis feuert, welches SQL
  geht zur Datenbank, und wie lange dauert das alles.

  Der Punkt, auf den es ankommt, ist die VERSCHACHTELUNG. Eine flache Liste
  von SQL-Anweisungen sagt wenig; die Zuordnung sagt alles:

    > Ui       Klick "Speichern" (frmVertrag.btnSpeichern)
      > Action acVertragSpeichern
        . SQL  UPDATE VERTRAG SET ... WHERE ID = ?      3.1 ms
        . SQL  INSERT INTO HISTORIE ...                 0.8 ms
      < Action acVertragSpeichern                      47.2 ms
    < Ui       Klick "Speichern"                       51.0 ms

  Dafuer gibt es AmsTraceEnter/AmsTraceLeave (Paar mit Dauer) neben
  AmsTraceNote (Einzelzeile). Jede Zeile merkt sich, in welchem offenen
  Vorgang sie steht - je Thread getrennt, denn AMS arbeitet mehrthreadig.

  Geschrieben wird als TSV: eine Zeile je Ereignis, sofort, ohne Zwischen-
  puffer im Prozess. Wenn AMS abstuerzt, ist genau die letzte Zeile die
  interessante - die darf nicht in einem Puffer verloren gehen. Die Datei
  laesst sich unveraendert in Excel oder Calc oeffnen.

  Diese Unit hat KEINE Beruehrung mit dem Host: sie nimmt Text entgegen und
  schreibt ihn weg. Wer die Ereignisse einsammelt, steht in AmsApi.Recorder.
  Deshalb ist hier alles ohne AMS testbar.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

type
  TAmsTraceCat = (tcPlugin, tcUi, tcAction, tcEvent, tcSql, tcAuto, tcHost);
  TAmsTraceCats = set of TAmsTraceCat;

  { Art der Zeile: Anfang eines Vorgangs, sein Ende, oder ein Einzelereignis }
  TAmsTraceKind = (tkEnter, tkLeave, tkNote);

const
  AmsTraceCatName: array[TAmsTraceCat] of string =
    ('Plugin', 'Ui', 'Action', 'Event', 'SQL', 'Automat', 'Host');
  AmsTraceKindMark: array[TAmsTraceKind] of string = ('>', '<', '.');
  AmsTraceAllCats = [tcPlugin, tcUi, tcAction, tcEvent, tcSql, tcAuto, tcHost];

var
  { Hauptschalter. Solange False, kostet jeder Aufruf nur einen Vergleich -
    ein Rekorder darf im Betrieb nicht spuerbar sein. }
  AmsTraceEnabled: Boolean = False;
  { Was aufgezeichnet wird. SQL abschalten, wenn nur die Bedienung interessiert. }
  AmsTraceCategories: TAmsTraceCats = AmsTraceAllCats;
  { Laenge, ab der Detailtexte gekuerzt werden. SQL wird sonst unlesbar. }
  AmsTraceMaxDetail: Integer = 500;
  { Zeilen im Speicher fuer AmsTraceTail und den Bericht. }
  AmsTraceRingMax: Integer = 2000;
  { Zusaetzlich ins normale Log schreiben - zum Mitlesen in einer Datei. }
  AmsTraceToLog: Boolean = False;

{ ------------------------------------------------------------ Ein und aus - }

{ ZUSEHEN und AUFZEICHNEN sind zwei verschiedene Dinge, und der Normalfall
  ist Zusehen. Wer wissen will, was ein Klick ausloest, will das im Fenster
  mitlaufen sehen - eine Datei braucht er dafuer nicht, und eine ungefragt
  angelegte Datei waere nur Muell im Temp-Ordner.

  Sammeln fuellt den Ringpuffer im Speicher; ein Betrachter holt sich die
  Zeilen mit AmsTraceSince ab. Kostet keine Datei und kein Schreiben. }
function  AmsTraceBegin: Boolean;
procedure AmsTraceEnd;
function  AmsTraceCollecting: Boolean;

{ Zusaetzlich in eine Datei schreiben. Laesst sich jederzeit an- und
  abschalten, ohne das Sammeln zu unterbrechen - der Ringpuffer laeuft
  weiter. Leerer Dateiname = %TEMP%\<Modulname>.trace.tsv. Eine bestehende
  Datei wird ueberschrieben: eine Aufzeichnung ist ein Versuch, kein
  Sammelband. }
function  AmsTraceRecordTo(const AFile: string = ''): Boolean;
procedure AmsTraceRecordStop;
function  AmsTraceRecording: Boolean;
function  AmsTraceFile: string;

{ Beides zusammen - sammeln und gleich mitschreiben. }
function  AmsTraceStart(const AFile: string = ''): Boolean;
procedure AmsTraceStop;
{ Laeuft ueberhaupt etwas? Gleichbedeutend mit AmsTraceCollecting. }
function  AmsTraceRunning: Boolean;

{ ------------------------------------------------------------- Schreiben -- }

{ Vorgang oeffnen. Der Rueckgabewert gehoert in das passende AmsTraceLeave -
  am besten in einem try/finally, sonst bleibt die Verschachtelung offen. }
function  AmsTraceEnter(ACat: TAmsTraceCat;
  const ASubject: string; const ADetail: string = ''): Integer;

{ Vorgang schliessen. Schreibt die Dauer mit. }
procedure AmsTraceLeave(AId: Integer; const AResult: string = '');

{ Einzelnes Ereignis ohne Dauer. }
procedure AmsTraceNote(ACat: TAmsTraceCat;
  const ASubject: string; const ADetail: string = '');

{ ---------------------------------------------------------------- Lesen --- }

function  AmsTraceCount: Integer;
procedure AmsTraceTail(ADest: TStrings; AMaxLines: Integer = 200);
procedure AmsTraceClear;

{ Alles, was seit dem letzten Abruf dazugekommen ist - fuer ein Fenster, das
  den Verlauf mitlaufen laesst. ACursor ist die Merkstelle des Betrachters
  und wird fortgeschrieben; 0 heisst "von vorn".

  Der Betrachter HOLT die Zeilen ab, sie werden ihm nicht zugerufen. Das ist
  Absicht: geschrieben wird aus jedem beliebigen Thread des Hosts - auch aus
  dem Datenbankthread -, und an einem Fenster darf nur sein eigener Thread
  arbeiten. Ein Timer, der hier nachfragt, umgeht das Thema vollstaendig.

  Sind mehr Zeilen aufgelaufen, als der Ringpuffer haelt, ruecken die
  aeltesten heraus; der Cursor wird dann stillschweigend nachgezogen. }
function  AmsTraceSince(var ACursor: Integer; ADest: TStrings;
  AMaxLines: Integer = 500): Integer;

{ Gesamtzahl je ausgegebener Zeilen - Obergrenze fuer einen Cursor. }
function  AmsTraceLineCount: Integer;

{ Zusammenfassung: je Kategorie und Betreff wie oft und wie lange. Das ist
  die Antwort auf "was kostet dieser Klick eigentlich". }
function  AmsTraceReport(AMaxRows: Integer = 40): string;

{ ---------------------------------------------------------------- Helfer -- }

{ Mehrzeiliges SQL auf eine Zeile bringen, Mehrfachleerzeichen weg, kuerzen.
  Ohne das ist eine TSV-Datei nach dem ersten SQL-Statement kaputt. }
function  AmsTraceClean(const AText: string; AMaxLen: Integer = 0): string;

implementation

uses
  AmsApi.Log;

const
  MAX_THREADS = 64;
  MAX_DEPTH   = 32;

type
  { Offene Vorgaenge je Thread. Feste Groesse mit Absage bei Ueberlauf -
    lieber eine Zeile ohne Zuordnung als eine wachsende Struktur in einem
    Rekorder, der bei jedem SQL laeuft. }
  TThreadStack = record
    Tid: DWORD;
    Depth: Integer;
    Ids: array[0..MAX_DEPTH - 1] of Integer;
    Ticks: array[0..MAX_DEPTH - 1] of Int64;
    Cats: array[0..MAX_DEPTH - 1] of TAmsTraceCat;
    Subjects: array[0..MAX_DEPTH - 1] of string;
  end;

  { Zaehler fuer den Bericht }
  TAgg = record
    Cat: TAmsTraceCat;
    Subject: string;
    Count: Integer;
    TotalMs: Double;
    MaxMs: Double;
  end;

var
  gLock: TRTLCriticalSection;
  gReady: Boolean = False;
  gRunning: Boolean = False;
  gFile: string = '';
  gStream: TFileStream = nil;
  gRing: TStringList = nil;
  gSeq: Integer = 0;
  { Fortlaufende Nummer JEDER ausgegebenen Zeile. Der Ringpuffer wirft vorn
    heraus; erst diese Zahl macht daraus eine Merkstelle, die ein Betrachter
    ueber mehrere Abrufe hinweg behalten kann. }
  gLineNo: Integer = 0;
  gStacks: array[0..MAX_THREADS - 1] of TThreadStack;
  gAgg: array of TAgg;
  gFreq: Int64 = 0;
  gStart: Int64 = 0;
  gLost: Integer = 0;      { Zeilen, die keinen Platz im Stapel hatten }

{ --------------------------------------------------------------- Helfer -- }

function AmsTraceClean(const AText: string; AMaxLen: Integer): string;
var
  i, n: Integer;
  Space: Boolean;
  C: Char;
begin
  if AMaxLen <= 0 then AMaxLen := AmsTraceMaxDetail;
  SetLength(Result, Length(AText));
  n := 0;
  Space := False;
  for i := 1 to Length(AText) do
  begin
    C := AText[i];
    { Tabulator und Zeilenumbruch wuerden die Spalten zerlegen. }
    if (C = #9) or (C = #10) or (C = #13) or (C = ' ') then
    begin
      if n = 0 then Continue;      { fuehrende Leerzeichen weg }
      if Space then Continue;      { mehrfache zusammenfassen }
      Space := True;
      Inc(n);
      Result[n] := ' ';
    end
    else
    begin
      Space := False;
      Inc(n);
      Result[n] := C;
    end;
  end;
  while (n > 0) and (Result[n] = ' ') do Dec(n);
  SetLength(Result, n);
  if (AMaxLen > 3) and (Length(Result) > AMaxLen) then
    Result := Copy(Result, 1, AMaxLen - 3) + '...';
end;

function NowTicks: Int64;
begin
  if gFreq = 0 then Exit(0);
  QueryPerformanceCounter(Result);
end;

function MsBetween(AFrom, ATo: Int64): Double;
begin
  if gFreq = 0 then Exit(0);
  Result := (ATo - AFrom) * 1000.0 / gFreq;
end;

{ Stapel des aufrufenden Threads, bei Bedarf angelegt. Nur unter gLock. }
function StackOf(ACreate: Boolean): Integer;
var
  i, Free: Integer;
  Tid: DWORD;
begin
  Tid := GetCurrentThreadId;
  Free := -1;
  for i := 0 to MAX_THREADS - 1 do
  begin
    if gStacks[i].Tid = Tid then Exit(i);
    if (Free < 0) and (gStacks[i].Tid = 0) then Free := i;
  end;
  if not ACreate then Exit(-1);
  if Free < 0 then Exit(-1);
  gStacks[Free].Tid := Tid;
  gStacks[Free].Depth := 0;
  Result := Free;
end;

{ ------------------------------------------------------------- Schreiben -- }

{ Eine fertige Zeile ausgeben. Immer unter gLock.

  Zwei Formen, absichtlich: die Datei bekommt TSV mit allen Spalten (damit
  sich in Excel filtern und sortieren laesst), das Fenster bekommt eine
  eingerueckte Zeile zum Lesen. Die TSV-Zeile wird nur gebaut, wenn auch
  wirklich eine Datei offen ist. }
procedure Emit(AKind: TAmsTraceKind; ACat: TAmsTraceCat; AId, AParent,
  ADepth: Integer; AMs: Double; const ASubject, ADetail: string);
var
  Line, Disp, Dauer, Zeit, Betreff, Detail, Cat: string;
  Raw: AnsiString;
begin
  if AMs < 0 then Dauer := '' else Dauer := FormatFloat('0.000', AMs);
  Zeit := FormatDateTime('hh:nn:ss.zzz', Now);
  Betreff := AmsTraceClean(ASubject, 200);
  Detail := AmsTraceClean(ADetail, AmsTraceMaxDetail);

  { --- lesbare Form fuer den Betrachter --- }
  Cat := AmsTraceCatName[ACat];
  while Length(Cat) < 7 do Cat := Cat + ' ';
  Disp := Zeit + '  ' + StringOfChar(' ', ADepth * 2) +
          AmsTraceKindMark[AKind] + ' ' + Cat + ' ' + Betreff;
  if Dauer <> '' then Disp := Disp + '   ' + Dauer + ' ms';
  { Beim Anfang und bei Einzelereignissen steht im Detail das Interessante -
    der SQL-Text. Beim Ende steht dort hoechstens ein Ergebnis. }
  if (Detail <> '') and (AKind <> tkLeave) then
    Disp := Disp + '   ' + Copy(Detail, 1, 200);

  if gRing <> nil then
  begin
    gRing.Add(Disp);
    Inc(gLineNo);
    while gRing.Count > AmsTraceRingMax do gRing.Delete(0);
  end;

  { --- TSV fuer die Datei, nur wenn aufgezeichnet wird --- }
  if gStream <> nil then
  try
    Line := Format('%d'#9'%s'#9'%s'#9'%d'#9'%d'#9'%s'#9'%d'#9'%s'#9'%s'#9'%s',
      [AId, Zeit, AmsTraceKindMark[AKind], ADepth, AParent, Dauer,
       GetCurrentThreadId, AmsTraceCatName[ACat], Betreff, Detail]);
    Raw := AnsiString(UTF8Encode(Line)) + #13#10;
    gStream.WriteBuffer(Raw[1], Length(Raw));
  except
    { Eine kaputte Aufzeichnung darf niemals AMS stoeren. }
  end;

  if AmsTraceToLog then AmsLog(Disp);
end;

procedure AddAgg(ACat: TAmsTraceCat; const ASubject: string; AMs: Double);
var
  i: Integer;
begin
  for i := 0 to High(gAgg) do
    if (gAgg[i].Cat = ACat) and (gAgg[i].Subject = ASubject) then
    begin
      Inc(gAgg[i].Count);
      gAgg[i].TotalMs := gAgg[i].TotalMs + AMs;
      if AMs > gAgg[i].MaxMs then gAgg[i].MaxMs := AMs;
      Exit;
    end;
  { Obergrenze, sonst waechst die Tabelle bei parametrisiertem SQL endlos }
  if Length(gAgg) >= 500 then Exit;
  i := Length(gAgg);
  SetLength(gAgg, i + 1);
  gAgg[i].Cat := ACat;
  gAgg[i].Subject := ASubject;
  gAgg[i].Count := 1;
  gAgg[i].TotalMs := AMs;
  gAgg[i].MaxMs := AMs;
end;

function AmsTraceEnter(ACat: TAmsTraceCat;
  const ASubject, ADetail: string): Integer;
var
  S, D: Integer;
  Parent: Integer;
begin
  Result := 0;
  if not AmsTraceEnabled then Exit;
  if not (ACat in AmsTraceCategories) then Exit;
  if not gReady then Exit;

  EnterCriticalSection(gLock);
  try
    S := StackOf(True);
    if S < 0 then
    begin
      Inc(gLost);
      Exit;
    end;
    D := gStacks[S].Depth;
    if D >= MAX_DEPTH then
    begin
      Inc(gLost);
      Exit;
    end;
    Inc(gSeq);
    Result := gSeq;
    if D > 0 then Parent := gStacks[S].Ids[D - 1] else Parent := 0;
    gStacks[S].Ids[D] := Result;
    gStacks[S].Ticks[D] := NowTicks;
    gStacks[S].Cats[D] := ACat;
    gStacks[S].Subjects[D] := ASubject;
    gStacks[S].Depth := D + 1;
    Emit(tkEnter, ACat, Result, Parent, D, -1, ASubject, ADetail);
  finally
    LeaveCriticalSection(gLock);
  end;
end;

procedure AmsTraceLeave(AId: Integer; const AResult: string);
var
  S, D, Parent: Integer;
  Ms: Double;
begin
  if AId = 0 then Exit;
  if not gReady then Exit;

  EnterCriticalSection(gLock);
  try
    S := StackOf(False);
    if S < 0 then Exit;
    D := gStacks[S].Depth - 1;
    { Nicht blind den obersten nehmen: ein vergessenes Leave wuerde sonst
      alles Folgende falsch zuordnen. Passenden Eintrag suchen und alles
      darueber verwerfen. }
    while (D >= 0) and (gStacks[S].Ids[D] <> AId) do Dec(D);
    if D < 0 then Exit;
    Ms := MsBetween(gStacks[S].Ticks[D], NowTicks);
    if D > 0 then Parent := gStacks[S].Ids[D - 1] else Parent := 0;
    Emit(tkLeave, gStacks[S].Cats[D], AId, Parent, D, Ms,
         gStacks[S].Subjects[D], AResult);
    AddAgg(gStacks[S].Cats[D], gStacks[S].Subjects[D], Ms);
    gStacks[S].Depth := D;
    if gStacks[S].Depth = 0 then gStacks[S].Tid := 0;   { Platz freigeben }
  finally
    LeaveCriticalSection(gLock);
  end;
end;

procedure AmsTraceNote(ACat: TAmsTraceCat; const ASubject, ADetail: string);
var
  S, D, Parent, Id: Integer;
begin
  if not AmsTraceEnabled then Exit;
  if not (ACat in AmsTraceCategories) then Exit;
  if not gReady then Exit;

  EnterCriticalSection(gLock);
  try
    S := StackOf(False);
    Parent := 0;
    D := 0;
    if S >= 0 then
    begin
      D := gStacks[S].Depth;
      if D > 0 then Parent := gStacks[S].Ids[D - 1];
    end;
    Inc(gSeq);
    Id := gSeq;
    Emit(tkNote, ACat, Id, Parent, D, -1, ASubject, ADetail);
    AddAgg(ACat, ASubject, 0);
  finally
    LeaveCriticalSection(gLock);
  end;
end;

{ ------------------------------------------------------------ Ein und aus - }

function AmsTraceBegin: Boolean;
var
  i: Integer;
begin
  if not gReady then Exit(AmsFail('Trace: Unit nicht bereit'));
  if gRunning then Exit(True);

  EnterCriticalSection(gLock);
  try
    gSeq := 0;
    gLost := 0;
    SetLength(gAgg, 0);
    if gRing <> nil then gRing.Clear;
    gLineNo := 0;
    for i := 0 to MAX_THREADS - 1 do
    begin
      gStacks[i].Tid := 0;
      gStacks[i].Depth := 0;
    end;
    QueryPerformanceCounter(gStart);
    gRunning := True;
    AmsTraceEnabled := True;
  finally
    LeaveCriticalSection(gLock);
  end;
  AmsLog('Verlauf wird gesammelt');
  Result := True;
end;

procedure AmsTraceEnd;
begin
  if not gReady then Exit;
  { Erst die Datei schliessen, dann das Sammeln abstellen - anders herum
    koennte eine Zeile aus einem anderen Thread noch in einen gerade
    freigegebenen Stream laufen. }
  AmsTraceRecordStop;
  AmsTraceEnabled := False;
  EnterCriticalSection(gLock);
  try
    gRunning := False;
  finally
    LeaveCriticalSection(gLock);
  end;
  if gLost > 0 then
    AmsLogFmt('Verlauf beendet, %d Zeile(n) ohne Zuordnung (Stapel voll)',
              [gLost])
  else
    AmsLog('Verlauf beendet');
end;

function AmsTraceCollecting: Boolean;
begin
  Result := gRunning;
end;

function AmsTraceRecordTo(const AFile: string): Boolean;
var
  Target: string;
  Head: AnsiString;
begin
  if not gReady then Exit(AmsFail('Trace: Unit nicht bereit'));
  Target := AFile;
  if Target = '' then
    Target := IncludeTrailingPathDelimiter(GetTempDir) + AmsModuleName +
              '.trace.tsv';

  EnterCriticalSection(gLock);
  try
    if gStream <> nil then FreeAndNil(gStream);
    try
      gStream := TFileStream.Create(Target, fmCreate or fmShareDenyNone);
    except
      on E: Exception do
      begin
        gStream := nil;
        Exit(AmsFailFmt('Aufzeichnung: %s nicht schreibbar (%s)',
                        [Target, E.Message]));
      end;
    end;
    gFile := Target;
    Head := AnsiString('Nr'#9'Zeit'#9'Art'#9'Tiefe'#9'Eltern'#9'Dauer_ms'#9 +
                       'Thread'#9'Kategorie'#9'Betreff'#9'Detail'#13#10);
    gStream.WriteBuffer(Head[1], Length(Head));
  finally
    LeaveCriticalSection(gLock);
  end;
  AmsLogFmt('Aufzeichnung laeuft: %s', [Target]);
  Result := True;
end;

procedure AmsTraceRecordStop;
begin
  if not gReady then Exit;
  EnterCriticalSection(gLock);
  try
    if gStream <> nil then
    begin
      FreeAndNil(gStream);
      AmsLog('Aufzeichnung beendet');
    end;
  finally
    LeaveCriticalSection(gLock);
  end;
end;

function AmsTraceRecording: Boolean;
begin
  Result := gStream <> nil;
end;

function AmsTraceStart(const AFile: string): Boolean;
begin
  Result := AmsTraceBegin and AmsTraceRecordTo(AFile);
end;

procedure AmsTraceStop;
begin
  AmsTraceEnd;
end;

function AmsTraceRunning: Boolean;
begin
  Result := gRunning;
end;

function AmsTraceFile: string;
begin
  Result := gFile;
end;

{ ---------------------------------------------------------------- Lesen --- }

function AmsTraceCount: Integer;
begin
  if not gReady then Exit(0);
  EnterCriticalSection(gLock);
  try
    Result := gSeq;
  finally
    LeaveCriticalSection(gLock);
  end;
end;

procedure AmsTraceTail(ADest: TStrings; AMaxLines: Integer);
var
  i, First: Integer;
begin
  if (ADest = nil) or (not gReady) then Exit;
  EnterCriticalSection(gLock);
  try
    if gRing = nil then Exit;
    First := gRing.Count - AMaxLines;
    if First < 0 then First := 0;
    for i := First to gRing.Count - 1 do ADest.Add(gRing[i]);
  finally
    LeaveCriticalSection(gLock);
  end;
end;

function AmsTraceSince(var ACursor: Integer; ADest: TStrings;
  AMaxLines: Integer): Integer;
var
  Base, i: Integer;
begin
  Result := 0;
  if (ADest = nil) or (not gReady) then Exit;
  if AMaxLines <= 0 then AMaxLines := MaxInt;
  EnterCriticalSection(gLock);
  try
    if gRing = nil then Exit;
    Base := gLineNo - gRing.Count;      { absolute Nummer von gRing[0] }
    if ACursor < Base then ACursor := Base;   { zu langsam abgeholt }
    if ACursor > gLineNo then ACursor := gLineNo;
    i := ACursor - Base;
    while (i < gRing.Count) and (Result < AMaxLines) do
    begin
      ADest.Add(gRing[i]);
      Inc(i);
      Inc(Result);
    end;
    ACursor := Base + i;
  finally
    LeaveCriticalSection(gLock);
  end;
end;

function AmsTraceLineCount: Integer;
begin
  if not gReady then Exit(0);
  EnterCriticalSection(gLock);
  try
    Result := gLineNo;
  finally
    LeaveCriticalSection(gLock);
  end;
end;

procedure AmsTraceClear;
var
  i: Integer;
begin
  if not gReady then Exit;
  EnterCriticalSection(gLock);
  try
    if gRing <> nil then gRing.Clear;
    { gLineNo NICHT zuruecksetzen: ein Betrachter mit altem Cursor wuerde
      sonst denken, es sei alles neu, und den Puffer doppelt anzeigen. }
    SetLength(gAgg, 0);
    for i := 0 to MAX_THREADS - 1 do
    begin
      gStacks[i].Tid := 0;
      gStacks[i].Depth := 0;
    end;
  finally
    LeaveCriticalSection(gLock);
  end;
end;

function AmsTraceReport(AMaxRows: Integer): string;
var
  i, j, n: Integer;
  Tmp: TAgg;
  Sorted: array of TAgg;
begin
  Result := '';
  if not gReady then Exit;
  EnterCriticalSection(gLock);
  try
    n := Length(gAgg);
    SetLength(Sorted, n);
    for i := 0 to n - 1 do Sorted[i] := gAgg[i];
  finally
    LeaveCriticalSection(gLock);
  end;

  if n = 0 then Exit('Nichts aufgezeichnet.');

  { Einfache Auswahlsortierung nach Gesamtdauer - bei hoechstens 500
    Zeilen ist das schnell genug und braucht keine Hilfsstrukturen. }
  for i := 0 to n - 2 do
    for j := i + 1 to n - 1 do
      if Sorted[j].TotalMs > Sorted[i].TotalMs then
      begin
        Tmp := Sorted[i]; Sorted[i] := Sorted[j]; Sorted[j] := Tmp;
      end;

  Result := Format('%-8s %6s %10s %10s  %s'#13#10,
                   ['Art', 'Anzahl', 'Summe_ms', 'Max_ms', 'Betreff']);
  if AMaxRows <= 0 then AMaxRows := n;
  for i := 0 to n - 1 do
  begin
    if i >= AMaxRows then
    begin
      Result := Result + Format('... und %d weitere'#13#10, [n - i]);
      Break;
    end;
    Result := Result + Format('%-8s %6d %10.1f %10.1f  %s'#13#10,
      [AmsTraceCatName[Sorted[i].Cat], Sorted[i].Count,
       Sorted[i].TotalMs, Sorted[i].MaxMs, Sorted[i].Subject]);
  end;
end;

initialization
  InitializeCriticalSection(gLock);
  gRing := TStringList.Create;
  if not QueryPerformanceFrequency(gFreq) then gFreq := 0;
  gReady := True;

finalization
  gReady := False;
  AmsTraceEnabled := False;
  gRunning := False;
  if gStream <> nil then FreeAndNil(gStream);
  if gRing <> nil then FreeAndNil(gRing);
  DeleteCriticalSection(gLock);

end.
