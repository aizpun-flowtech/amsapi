program tracewindemo;

{ ============================================================================
  Rauchtest des Verlaufsfensters - OHNE AMS.

  Das Fenster wird erzeugt, mit erfundenen Verlaufszeilen gefuettert, ueber
  Nachrichten bedient (aufzeichnen, anhalten, Kategorien, leeren, Bericht,
  kopieren) und wieder geschlossen. Es bleibt dabei versteckt und ausserhalb
  des sichtbaren Bereichs.

  Geprueft wird vor allem, was im echten AMS niemand mehr gefahrlos
  ausprobieren kann: dass Zusehen OHNE Aufzeichnen geht, dass der Cursor
  keine Zeile doppelt zeigt und keine verschluckt, und dass sich nach dem
  Schliessen weder ein Fenster noch eine Fensterklasse haelt.

  Rueckgabewert 0 = alles gruen, sonst Anzahl der Fehlschlaege.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, Classes,
  AmsApi.Log, AmsApi.Trace, AmsApi.TraceWindow;

const
  IDC_LIST   = 200;
  IDC_REC    = 201;
  IDC_PAUSE  = 202;
  IDC_CLEAR  = 203;
  IDC_REPORT = 204;
  IDC_COPY   = 205;
  IDC_SQL    = 206;
  IDC_ACT    = 207;
  IDC_CLICK  = 208;
  IDC_STATUS = 209;

var
  gRun: Integer = 0;
  gFail: Integer = 0;
  gWin: HWND = 0;

procedure Check(const AName: string; ACondition: Boolean;
  const AGot: string = '');
begin
  Inc(gRun);
  if ACondition then
    WriteLn('  ok    ', AName)
  else
  begin
    Inc(gFail);
    if AGot <> '' then
      WriteLn('  FEHLT ', AName, '   -> "', AGot, '"')
    else
      WriteLn('  FEHLT ', AName);
  end;
  Flush(Output);
end;

procedure CheckEq(const AName, AExpected, AGot: string);
begin
  Inc(gRun);
  if AExpected = AGot then
    WriteLn('  ok    ', AName)
  else
  begin
    Inc(gFail);
    WriteLn('  FEHLT ', AName, '   erwartet "', AExpected, '", bekommen "',
            AGot, '"');
  end;
  Flush(Output);
end;

procedure Section(const AName: string);
begin
  WriteLn;
  WriteLn(AName);
  WriteLn(StringOfChar('-', Length(AName)));
end;

procedure Pump(AMilliseconds: Integer);
var
  Msg: TMsg;
  T0: QWord;
begin
  T0 := GetTickCount64;
  repeat
    while PeekMessageW(Msg, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(Msg);
      DispatchMessageW(Msg);
    end;
    Sleep(5);
  until GetTickCount64 - T0 >= QWord(AMilliseconds);
end;

procedure Klick(AId: Integer);
begin
  SendMessageW(gWin, WM_COMMAND, MAKEWPARAM(AId, BN_CLICKED),
               LPARAM(GetDlgItem(gWin, AId)));
end;

function ListCount: Integer;
begin
  Result := SendMessageW(GetDlgItem(gWin, IDC_LIST), LB_GETCOUNT, 0, 0);
end;

function ListText(AIndex: Integer): string;
var
  Buf: array[0..1023] of WideChar;
begin
  Buf[0] := #0;
  SendMessageW(GetDlgItem(gWin, IDC_LIST), LB_GETTEXT, WPARAM(AIndex),
               LPARAM(@Buf[0]));
  Result := string(WideString(Buf));
end;

function StatusText: string;
var
  Buf: array[0..1023] of WideChar;
begin
  Buf[0] := #0;
  GetWindowTextW(GetDlgItem(gWin, IDC_STATUS), Buf, Length(Buf));
  Result := string(WideString(Buf));
end;

function ButtonText(AId: Integer): string;
var
  Buf: array[0..255] of WideChar;
begin
  Buf[0] := #0;
  GetWindowTextW(GetDlgItem(gWin, AId), Buf, Length(Buf));
  Result := string(WideString(Buf));
end;

{ Ein paar Zeilen erzeugen, wie sie im echten Betrieb entstehen. }
procedure FuellVerlauf;
var
  Klickvorgang, Action: Integer;
begin
  Klickvorgang := AmsTraceEnter(tcUi, 'OnClick btnSpeichern',
                                'frmVertrag.pnFuss.btnSpeichern');
  Action := AmsTraceEnter(tcAction, 'acVertragSpeichern');
  AmsTraceNote(tcSql, 'UPDATE VERTRAG',
               'UPDATE VERTRAG'#13#10'   SET GEAENDERT = ?'#13#10' WHERE ID = ?');
  AmsTraceLeave(Action);
  AmsTraceLeave(Klickvorgang, 'ok');
end;

procedure TestOeffnen;
begin
  Section('Verlaufsfenster - oeffnen');
  Check('Fenster geoeffnet', AmsTraceWindowOpen(0), AmsLastError);
  gWin := AmsTraceWindowHandle;
  Check('Handle geliefert', gWin <> 0);
  Check('Zustand gemeldet', AmsTraceWindowOpenState);

  { REGRESSION. Hier lief einmal ein Detour schief, die Ausnahme trug den
    ganzen Aufruf davon, und zurueck blieb ein Fenster ohne Timer: sichtbar
    zu bekommen war es noch, aber die Liste blieb fuer immer leer.
    Ohne AMS scheitert JEDE Quelle - genau der Fall. Das Fenster muss
    trotzdem stehen, ticken und die Fehlschlaege selbst anzeigen. }
  Check('sichtbar, obwohl keine einzige Quelle laeuft',
        IsWindowVisible(gWin));
  Pump(500);
  Check('Timer laeuft (Zeilen kommen an)', ListCount > 0,
        IntToStr(ListCount));
  Check('gescheiterte Quelle steht IM FENSTER',
        Pos('SQL-Mitschnitt aus', ListText(0) + ListText(1) + ListText(2)) > 0,
        ListText(0) + ' | ' + ListText(1) + ' | ' + ListText(2));

  { Sofort aus dem Blick nehmen - der Test soll niemanden stoeren. }
  ShowWindow(gWin, SW_HIDE);
  SetWindowPos(gWin, 0, -3200, -3200, 1000, 560, SWP_NOZORDER or SWP_NOACTIVATE);
  Pump(60);

  Check('alle Bedienelemente da',
        (GetDlgItem(gWin, IDC_LIST) <> 0) and
        (GetDlgItem(gWin, IDC_REC) <> 0) and
        (GetDlgItem(gWin, IDC_PAUSE) <> 0) and
        (GetDlgItem(gWin, IDC_CLEAR) <> 0) and
        (GetDlgItem(gWin, IDC_REPORT) <> 0) and
        (GetDlgItem(gWin, IDC_COPY) <> 0) and
        (GetDlgItem(gWin, IDC_SQL) <> 0) and
        (GetDlgItem(gWin, IDC_ACT) <> 0) and
        (GetDlgItem(gWin, IDC_CLICK) <> 0) and
        (GetDlgItem(gWin, IDC_STATUS) <> 0));

  { DAS ist der Punkt: zusehen, ohne aufzuzeichnen. }
  Check('sammelt', AmsTraceCollecting);
  Check('zeichnet NICHT auf', not AmsTraceRecording);
  Check('Knopf heisst "Aufzeichnen"', ButtonText(IDC_REC) = 'Aufzeichnen',
        ButtonText(IDC_REC));

  Check('zweites Oeffnen liefert dasselbe Fenster',
        AmsTraceWindowOpen(0) and (AmsTraceWindowHandle = gWin));
  ShowWindow(gWin, SW_HIDE);
end;

procedure TestMitlaufen;
var
  Vorher, Nachher: Integer;
begin
  Section('Verlaufsfenster - Zeilen laufen mit');
  Vorher := ListCount;
  FuellVerlauf;
  Pump(500);                            { der Timer laeuft alle 300 ms }
  Nachher := ListCount;
  Check('Zeilen sind angekommen', Nachher >= Vorher + 5,
        Format('%d -> %d', [Vorher, Nachher]));
  Check('Klickzeile steht da', Pos('btnSpeichern', ListText(Nachher - 1)) > 0,
        ListText(Nachher - 1));
  Check('SQL einzeilig gemacht',
        Pos('UPDATE VERTRAG SET GEAENDERT', ListText(Nachher - 3)) > 0,
        ListText(Nachher - 3));
  Check('Verschachtelung eingerueckt',
        Pos('    ', ListText(Nachher - 3)) > 0, ListText(Nachher - 3));
  Check('Dauer bei der Endzeile', Pos(' ms', ListText(Nachher - 1)) > 0,
        ListText(Nachher - 1));
  Check('Statuszeile nennt "nur zusehen"',
        Pos('nur zusehen', StatusText) > 0, StatusText);

  { Zweiter Durchlauf: nichts darf doppelt erscheinen. }
  Vorher := ListCount;
  FuellVerlauf;
  Pump(500);
  CheckEq('genau 5 neue Zeilen', '5', IntToStr(ListCount - Vorher));

  { Ohne neue Ereignisse darf auch nichts dazukommen. }
  Vorher := ListCount;
  Pump(500);
  CheckEq('ohne Ereignis keine Zeile', '0', IntToStr(ListCount - Vorher));
end;

procedure TestAufzeichnen;
var
  Datei: string;
  Vorher: Integer;
begin
  Section('Verlaufsfenster - Aufzeichnen ist optional');
  Klick(IDC_REC);
  Pump(60);
  Check('zeichnet jetzt auf', AmsTraceRecording);
  Datei := AmsTraceFile;
  Check('Datei benannt', Datei <> '', Datei);
  Check('Datei angelegt', FileExists(Datei), Datei);
  Check('Knopf heisst jetzt "Aufz. beenden"',
        ButtonText(IDC_REC) = 'Aufz. beenden', ButtonText(IDC_REC));
  Check('Statuszeile nennt die Datei', Pos('.trace.tsv', StatusText) > 0,
        StatusText);

  Vorher := ListCount;
  FuellVerlauf;
  Pump(500);
  Check('Zusehen laeuft waehrend der Aufzeichnung weiter',
        ListCount > Vorher);

  Klick(IDC_REC);
  Pump(60);
  Check('Aufzeichnung wieder aus', not AmsTraceRecording);
  Check('gesammelt wird weiter', AmsTraceCollecting);
  Check('Knopf wieder "Aufzeichnen"', ButtonText(IDC_REC) = 'Aufzeichnen',
        ButtonText(IDC_REC));

  Vorher := ListCount;
  FuellVerlauf;
  Pump(500);
  Check('nach dem Abschalten laeuft das Fenster weiter',
        ListCount > Vorher);
  if Datei <> '' then DeleteFile(Datei);
end;

procedure TestAnhalten;
var
  Vorher: Integer;
begin
  Section('Verlaufsfenster - anhalten und weiter');
  Klick(IDC_PAUSE);
  Pump(60);
  Check('Knopf heisst "Weiter"', ButtonText(IDC_PAUSE) = 'Weiter',
        ButtonText(IDC_PAUSE));
  Check('Statuszeile meldet ANGEHALTEN', Pos('ANGEHALTEN', StatusText) > 0,
        StatusText);

  Vorher := ListCount;
  FuellVerlauf;
  Pump(500);
  CheckEq('angehalten kommt nichts dazu', '0', IntToStr(ListCount - Vorher));

  Klick(IDC_PAUSE);
  Pump(200);
  Check('nach "Weiter" ist alles nachgezogen', ListCount >= Vorher + 5,
        Format('%d -> %d', [Vorher, ListCount]));
  Check('Knopf wieder "Anhalten"', ButtonText(IDC_PAUSE) = 'Anhalten',
        ButtonText(IDC_PAUSE));
end;

procedure TestKategorien;
begin
  Section('Verlaufsfenster - Kategorien');
  Check('SQL ist an', tcSql in AmsTraceCategories);
  SendMessageW(GetDlgItem(gWin, IDC_SQL), BM_SETCHECK, BST_UNCHECKED, 0);
  Klick(IDC_SQL);
  Pump(60);
  Check('SQL abgewaehlt', not (tcSql in AmsTraceCategories));
  Check('Klicks unberuehrt', tcUi in AmsTraceCategories);

  SendMessageW(GetDlgItem(gWin, IDC_SQL), BM_SETCHECK, BST_CHECKED, 0);
  Klick(IDC_SQL);
  Pump(60);
  Check('SQL wieder an', tcSql in AmsTraceCategories);

  SendMessageW(GetDlgItem(gWin, IDC_ACT), BM_SETCHECK, BST_UNCHECKED, 0);
  Klick(IDC_ACT);
  Pump(60);
  Check('Actions abgewaehlt', not (tcAction in AmsTraceCategories));
  Check('Events gleich mit', not (tcEvent in AmsTraceCategories));
  SendMessageW(GetDlgItem(gWin, IDC_ACT), BM_SETCHECK, BST_CHECKED, 0);
  Klick(IDC_ACT);
  Pump(60);
  Check('Actions wieder an', tcAction in AmsTraceCategories);
end;

procedure TestLeerenUndBericht;
var
  Vorher: Integer;
begin
  Section('Verlaufsfenster - leeren, Bericht, kopieren');
  FuellVerlauf;
  Pump(400);
  Check('etwas zu kopieren da', ListCount > 0);
  Klick(IDC_COPY);
  Pump(60);
  Check('Kopieren meldet die Zeilenzahl', Pos('kopiert', StatusText) > 0,
        StatusText);

  Klick(IDC_REPORT);
  Pump(60);
  Check('Bericht steht in der Liste', ListCount > 1);
  Check('Bericht nennt die Action',
        Pos('acVertragSpeichern', ListText(2) + ListText(3) + ListText(4)) > 0,
        ListText(2) + ' | ' + ListText(3));
  Check('Bericht haelt an', Pos('ANGEHALTEN', StatusText) > 0, StatusText);

  Klick(IDC_CLEAR);
  Pump(60);
  CheckEq('Liste ist leer', '0', IntToStr(ListCount));

  { Nach dem Leeren darf der alte Puffer nicht noch einmal erscheinen. }
  Klick(IDC_PAUSE);      { aus dem Bericht zurueck ins Mitlaufen }
  Pump(400);
  CheckEq('nichts kommt zurueck', '0', IntToStr(ListCount));

  Vorher := ListCount;
  FuellVerlauf;
  Pump(500);
  CheckEq('danach laeuft es normal weiter', '5',
          IntToStr(ListCount - Vorher));
end;

procedure TestGroessen;
var
  i: Integer;
  Breiten: array[0..3] of Integer = (640, 820, 1200, 1600);
  R, RL, RS: TRect;
begin
  Section('Verlaufsfenster - Groessen');
  for i := 0 to High(Breiten) do
  begin
    SetWindowPos(gWin, 0, -3200, -3200, Breiten[i], 500,
                 SWP_NOZORDER or SWP_NOACTIVATE);
    Pump(60);
    Check(Format('Breite %d: umgebrochen', [Breiten[i]]),
          GetClientRect(gWin, R) and (R.Right > 0));
    GetWindowRect(GetDlgItem(gWin, IDC_LIST), RL);
    GetWindowRect(GetDlgItem(gWin, IDC_STATUS), RS);
    { Liste und Statuszeile duerfen sich nicht ueberdecken - genau das ist
      im Suchfenster schon einmal passiert. }
    Check(Format('Breite %d: Liste ueber der Statuszeile', [Breiten[i]]),
          RL.Bottom <= RS.Top);
  end;

  { Unter der Mindestgroesse: WM_GETMINMAXINFO muss halten. }
  SetWindowPos(gWin, 0, -3200, -3200, 200, 120,
               SWP_NOZORDER or SWP_NOACTIVATE);
  Pump(60);
  GetWindowRect(gWin, R);
  Check('Mindestbreite eingehalten', R.Right - R.Left >= 640,
        IntToStr(R.Right - R.Left));
  SetWindowPos(gWin, 0, -3200, -3200, 1000, 560,
               SWP_NOZORDER or SWP_NOACTIVATE);
  Pump(60);
end;

procedure TestSchliessen;
var
  WC: WNDCLASSW;
begin
  Section('Verlaufsfenster - schliessen');
  AmsTraceWindowClose;
  Pump(60);
  Check('Handle weg', AmsTraceWindowHandle = 0);
  Check('Zustand weg', not AmsTraceWindowOpenState);
  Check('Fenster wirklich zerstoert', not IsWindow(gWin));
  { Ist die Klasse abgemeldet, findet GetClassInfo sie nicht mehr. Bliebe
    sie stehen, zeigte sie nach dem Entladen auf toten Code. }
  FillChar(WC, SizeOf(WC), 0);
  Check('Fensterklasse abgemeldet',
        not GetClassInfoW(HInstance,
              PWideChar(WideString('AmsApiTraceWindow')), @WC));
  AmsTraceWindowClose;
  Check('zweites Schliessen ist harmlos', True);
  AmsTraceEnd;
end;

begin
  AmsSetLogFile(IncludeTrailingPathDelimiter(GetTempDir) +
                'amsapi_tracewindemo.log');
  WriteLn('AmsApi - Rauchtest des Verlaufsfensters (ohne AMS)');
  WriteLn('==================================================');

  TestOeffnen;
  if gWin <> 0 then
  begin
    TestMitlaufen;
    TestAufzeichnen;
    TestAnhalten;
    TestKategorien;
    TestLeerenUndBericht;
    TestGroessen;
    TestSchliessen;
  end;

  WriteLn;
  WriteLn(Format('%d Pruefungen, %d Fehlschlaege.', [gRun, gFail]));
  if gFail = 0 then WriteLn('ALLES GRUEN.') else WriteLn('FEHLGESCHLAGEN.');
  Halt(gFail);
end.
