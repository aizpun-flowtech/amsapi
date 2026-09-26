program finderdemo;

{ ============================================================================
  Rauchtest fuer das Suchfenster aus samples\UiTweaks\finder.inc.

  Das Fenster ist reines Win32 und laesst sich deshalb OHNE AMS pruefen: es
  wird erzeugt, in mehreren Groessen umgebrochen, ueber Nachrichten bedient
  (Suchen, Anwenden, Zuruecknehmen, Kopieren) und wieder abgebaut. Gesucht
  wird dabei nichts - ohne Host gibt es keine Elemente. Geprueft wird, dass
  jeder Weg durch die Fensterprozedur laeuft, ohne abzustuerzen, und dass das
  Fenster restlos verschwindet: seine Prozedur liegt im Plugin-Modul, ein
  stehengebliebenes Fenster waere nach dem Entladen toedlich.

  Das Fenster wird sofort nach dem Erzeugen versteckt und aus dem Bild
  geschoben, damit ein Baulauf nicht den Fokus klaut.

  Rueckgabe: Anzahl der Fehlschlaege.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, Classes,
  AmsApi.Types, AmsApi.Log, AmsApi.Props, AmsApi.Ui, AmsApi.Factory;

{$I ../samples/UiTweaks/finder.inc}

var
  gRun: Integer = 0;
  gFail: Integer = 0;

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

{ Gibt es im EIGENEN Prozess noch ein Fenster dieser Klasse?

  FindWindowW waere der kuerzere Weg, sucht aber den ganzen Desktop ab - und
  faellt damit ueber ein laufendes AMS, in dem dasselbe Plugin sein
  Suchfenster offen hat. Genau das ist hier passiert: der Test meldete ein
  "stehengebliebenes" Fenster, das einem voellig anderen Prozess gehoerte. }
var
  gSeenOwn: Boolean = False;

function EnumOwnProc(AHandle: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Pid: DWORD;
  Buf: array[0..63] of WideChar;
begin
  Result := True;
  Pid := 0;
  GetWindowThreadProcessId(AHandle, @Pid);
  if Pid <> GetCurrentProcessId then Exit;
  Buf[0] := #0;
  GetClassNameW(AHandle, Buf, Length(Buf));
  if string(WideString(Buf)) = FINDER_CLASS then
  begin
    gSeenOwn := True;
    Result := False;
  end;
end;

function OwnFinderExists: Boolean;
begin
  gSeenOwn := False;
  EnumWindows(@EnumOwnProc, 0);
  Result := gSeenOwn;
end;

procedure Section(const AName: string);
begin
  WriteLn;
  WriteLn(AName);
  WriteLn(StringOfChar('-', Length(AName)));
end;

{ Nachrichten abarbeiten - im echten Betrieb macht das die Schleife von AMS. }
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

procedure Push(AId: Integer; ANotify: Integer = BN_CLICKED);
begin
  if gFinder = 0 then Exit;
  SendMessageW(gFinder, WM_COMMAND,
               WPARAM(AId) or (WPARAM(ANotify) shl 16), 0);
end;

procedure Hide;
begin
  if gFinder = 0 then Exit;
  ShowWindow(gFinder, SW_HIDE);
  SetWindowPos(gFinder, 0, -3200, -3200, 1040, 680,
               SWP_NOZORDER or SWP_NOACTIVATE);
end;

procedure TestOpenClose;
begin
  Section('Fenster oeffnen und schliessen');
  FinderOpen(0, '');
  Hide;
  Check('Fenster erzeugt', gFinder <> 0);
  Check('Suchfeld da', gSearchBox <> 0);
  Check('Trefferliste da', gElemList <> 0);
  Check('Eigenschaftsliste da', gPropList <> 0);
  Check('Patchfeld da', gPatchBox <> 0);
  Check('Klassenfeld da', gClassBox <> 0);
  Check('Beschriftungsfeld da', gTextBox <> 0);
  Check('Haken fuer Ereignisse da', gEventsBox <> 0);
  Check('Statuszeile hat einen Text', GetText(gStatusBar) <> '');
  Check('Eingabetaste ist abgefangen', gOldEditProc <> nil);
  Pump(100);

  FinderClose;
  Check('Fenster wieder weg', gFinder = 0);
  Check('kein eigenes Fenster dieser Klasse mehr da', not OwnFinderExists);

  { Zweites Oeffnen muss gehen - die Fensterklasse wurde abgemeldet. }
  FinderOpen(0, '');
  Hide;
  Check('zweites Oeffnen geht', gFinder <> 0);
end;

{ Zwei Bedienelemente duerfen sich nie ueberdecken. Genau das ist beim
  ersten Wurf passiert - "Kopieren" und "Zuruecknehmen" lagen uebereinander,
  weil eine Knopfposition von Hand ausgerechnet war. Der alte Test hat nur
  gemessen, ob etwas Breite hat, nicht ob es woanders liegt. }
function Overlap(A, B: HWND; const AName: string): Boolean;
var
  RA, RB, RI: TRect;
begin
  Result := False;
  if (A = 0) or (B = 0) then Exit;
  if not GetWindowRect(A, RA) then Exit;
  if not GetWindowRect(B, RB) then Exit;
  Result := IntersectRect(RI, RA, RB);
  if Result then
    WriteLn(Format('        %s: %d,%d-%d,%d schneidet %d,%d-%d,%d',
                   [AName, RA.Left, RA.Top, RA.Right, RA.Bottom,
                    RB.Left, RB.Top, RB.Right, RB.Bottom]));
end;

procedure CheckNoOverlap(AWidth: Integer);
var
  Apply, Copy, Undo, Show, Go, Keep, Clone, Neu, Del: HWND;
  Bad: Boolean;
begin
  SetWindowPos(gFinder, 0, -3200, -3200, AWidth, 680,
               SWP_NOZORDER or SWP_NOACTIVATE);
  Pump(50);
  Apply := GetDlgItem(gFinder, IDC_APPLY);
  Copy := GetDlgItem(gFinder, IDC_COPY);
  Undo := GetDlgItem(gFinder, IDC_UNDOBTN);
  Show := GetDlgItem(gFinder, IDC_SHOW);
  Go := GetDlgItem(gFinder, IDC_GO);
  Keep := GetDlgItem(gFinder, IDC_KEEP);
  Clone := GetDlgItem(gFinder, IDC_CLONE);
  Neu := GetDlgItem(gFinder, IDC_NEW);
  Del := GetDlgItem(gFinder, IDC_DELETE);

  Bad := Overlap(Show, Apply, 'Zeigen/Anwenden') or
         Overlap(Apply, Copy, 'Anwenden/Kopieren') or
         Overlap(Copy, Undo, 'Kopieren/Zuruecknehmen') or
         Overlap(Show, Copy, 'Zeigen/Kopieren') or
         Overlap(Apply, Undo, 'Anwenden/Zuruecknehmen') or
         Overlap(Show, Undo, 'Zeigen/Zuruecknehmen');
  Check(Format('%d px breit: die vier Knoepfe der Patchzeile liegen ' +
               'nebeneinander', [AWidth]), not Bad);

  { Dieselbe Falle noch einmal, eine Zeile hoeher: die Bauzeile ist die
    engste im Fenster. }
  Bad := Overlap(Keep, Clone, 'Merken/Klonen') or
         Overlap(Clone, Neu, 'Klonen/Neu') or
         Overlap(Neu, Del, 'Neu/Entfernen') or
         Overlap(Keep, Neu, 'Merken/Neu') or
         Overlap(Keep, Del, 'Merken/Entfernen') or
         Overlap(Clone, Del, 'Klonen/Entfernen') or
         Overlap(gEventsBox, Keep, 'Haken/Merken') or
         Overlap(gClassBox, gTextBox, 'Klasse/Beschriftung') or
         Overlap(gTextBox, gEventsBox, 'Beschriftung/Haken');
  Check(Format('%d px breit: die Bauzeile liegt nebeneinander', [AWidth]),
        not Bad);

  Bad := Overlap(gSearchBox, Go, 'Suchfeld/Suchen') or
         Overlap(Go, gOnlyVisBox, 'Suchen/Haken') or
         Overlap(gPatchBox, Show, 'Patchfeld/Zeigen') or
         Overlap(gElemList, gPropList, 'Trefferliste/Eigenschaften') or
         { und die neue Zeile darf weder in die Liste darueber noch in die
           Patchzeile darunter ragen }
         Overlap(gPropList, gClassBox, 'Eigenschaften/Klasse') or
         Overlap(gPropList, Keep, 'Eigenschaften/Merken') or
         Overlap(gClassBox, gPatchBox, 'Klasse/Patchfeld') or
         Overlap(Keep, Show, 'Merken/Zeigen') or
         Overlap(Del, Undo, 'Entfernen/Zuruecknehmen');
  Check(Format('%d px breit: keine weitere Ueberdeckung', [AWidth]), not Bad);
end;

procedure TestLayout;
var
  R: TRect;
  Ok: Boolean;
begin
  Section('Umbruch bei verschiedenen Groessen');
  { Ab der Mindestgroesse aufwaerts darf sich nichts ueberdecken. }
  CheckNoOverlap(MIN_W);
  CheckNoOverlap(1040);
  CheckNoOverlap(1400);

  { Auch unter der Mindestgroesse darf nichts negativ werden - MoveWindow
    mit negativer Breite ist genau die Sorte Fehler, die man erst sieht,
    wenn jemand das Fenster klein zieht. }
  SetWindowPos(gFinder, 0, -3200, -3200, MIN_W, MIN_H,
               SWP_NOZORDER or SWP_NOACTIVATE);
  Pump(50);
  SetWindowPos(gFinder, 0, -3200, -3200, 1400, 900,
               SWP_NOZORDER or SWP_NOACTIVATE);
  Pump(50);
  SetWindowPos(gFinder, 0, -3200, -3200, 300, 200,
               SWP_NOZORDER or SWP_NOACTIVATE);
  Pump(50);
  Ok := GetWindowRect(gPatchBox, R);
  Check('Patchfeld hat nach dem Verkleinern noch Breite',
        Ok and (R.Right - R.Left >= 120),
        IntToStr(R.Right - R.Left));
  Ok := GetWindowRect(gElemList, R);
  Check('Trefferliste hat noch Hoehe', Ok and (R.Bottom - R.Top > 0),
        IntToStr(R.Bottom - R.Top));
  SetWindowPos(gFinder, 0, -3200, -3200, 1040, 680,
               SWP_NOZORDER or SWP_NOACTIVATE);
  Pump(50);
end;

procedure TestActions;
begin
  Section('Bedienung ohne Host (nichts darf abstuerzen)');
  { Ohne AMS findet die Suche nichts - genau das soll sie sagen, statt zu
    krachen oder still zu bleiben. }
  SetText(gSearchBox, 'Speichern');
  Push(IDC_GO);
  Pump(50);
  Check('Suche laeuft und meldet etwas', GetText(gStatusBar) <> '');
  Check('ohne Host keine Treffer', gHitCount = 0, IntToStr(gHitCount));

  SetText(gSearchBox, 'bb*');
  Push(IDC_GO);
  Pump(50);
  Check('Suche mit Platzhalter laeuft', GetText(gStatusBar) <> '');

  { Ein Handle, das es nicht gibt: der Sonderweg muss sauber ablehnen. }
  SetText(gSearchBox, '0x00000001');
  Push(IDC_GO);
  Pump(50);
  Check('ungueltiges Handle wird abgewiesen', gHitCount = 0);
  Check('mit Begruendung', GetText(gStatusBar) <> '');

  { Auswahl in leeren Listen. }
  Push(IDC_ELEMS, LBN_SELCHANGE);
  Push(IDC_PROPS, LBN_SELCHANGE);
  Push(IDC_ELEMS, LBN_DBLCLK);
  Check('Auswahl in leeren Listen ist harmlos', True);

  SetText(gPatchBox, 'GibtEsNicht.Enabled=0');
  Push(IDC_APPLY);
  Pump(50);
  Check('Patch auf ein unbekanntes Element meldet den Grund',
        Pos('Nicht angewandt', GetText(gStatusBar)) > 0,
        GetText(gStatusBar));

  SetText(gPatchBox, 'kaputte Zeile ohne Punkt');
  Push(IDC_APPLY);
  Pump(50);
  Check('unsinnige Patchzeile wird abgelehnt',
        Pos('Nicht angewandt', GetText(gStatusBar)) > 0,
        GetText(gStatusBar));

  Push(IDC_UNDOBTN);
  Pump(50);
  Check('Zuruecknehmen ohne Aenderungen',
        Pos('0 Aenderung', GetText(gStatusBar)) > 0, GetText(gStatusBar));

  SetText(gPatchBox, '');
  Push(IDC_COPY);
  Check('Kopieren mit leerem Feld ist harmlos', True);

  SetText(gPatchBox, 'bbTest.Enabled=0');
  Push(IDC_COPY);
  Pump(50);
  Check('Kopieren meldet Erfolg', Pos('Kopiert', GetText(gStatusBar)) > 0,
        GetText(gStatusBar));

  Push(IDC_SHOW);
  Pump(50);
  Check('Zeigen ohne Auswahl weist darauf hin',
        Pos('Treffer anklicken', GetText(gStatusBar)) > 0,
        GetText(gStatusBar));
end;

{ Bauen ohne Host. Es gibt nichts zu klonen und nichts anzulegen - jeder
  dieser Wege muss trotzdem durchlaufen und SAGEN, was fehlt. Ein Knopf, der
  still nichts tut, ist der Fehler, den man erst im Kundentermin sieht. }
procedure TestBuilding;
begin
  Section('Bauen ohne Host (nichts darf abstuerzen)');

  SetText(gClassBox, '');
  SetText(gTextBox, '');

  Push(IDC_KEEP);
  Pump(30);
  Check('Merken ohne Auswahl weist darauf hin',
        Pos('Treffer', GetText(gStatusBar)) > 0, GetText(gStatusBar));

  Push(IDC_CLONE);
  Pump(30);
  Check('Klonen ohne Auswahl weist darauf hin',
        Pos('Treffer', GetText(gStatusBar)) > 0, GetText(gStatusBar));

  { Ohne Klasse muss "Neu" sagen, was einzutragen ist - und zwar BEVOR es
    ueber das fehlende Ziel klagt. }
  Push(IDC_NEW);
  Pump(30);
  Check('Neu ohne Klasse nennt Beispiele',
        Pos('TButton', GetText(gStatusBar)) > 0, GetText(gStatusBar));

  SetText(gClassBox, 'TButton');
  Push(IDC_NEW);
  Pump(30);
  Check('Neu ohne Ziel weist auf den Treffer hin',
        Pos('Treffer', GetText(gStatusBar)) > 0, GetText(gStatusBar));

  Push(IDC_DELETE);
  Pump(30);
  Check('Entfernen ohne Auswahl weist darauf hin',
        Pos('Treffer', GetText(gStatusBar)) > 0, GetText(gStatusBar));

  { Der Haken darf gesetzt und wieder geloescht werden, ohne dass etwas
    passiert. }
  SendMessageW(gEventsBox, BM_SETCHECK, BST_CHECKED, 0);
  Push(IDC_CLONE);
  Pump(30);
  SendMessageW(gEventsBox, BM_SETCHECK, BST_UNCHECKED, 0);
  Check('Haken "mit Ereignissen" ist harmlos', True);

  { Und die API dahinter, unmittelbar: ohne AMS gibt es keinen
    Konstruktor - dann wird NICHTS angelegt, mit Begruendung. }
  Check('ohne Host ist die Factory nicht bereit', not AmsFactoryReady);
  Check('mit Begruendung', AmsLastError <> '', AmsLastError);
  Check('ohne Host kein Konstruktorslot', AmsCtorSlot < 0,
        IntToStr(AmsCtorSlot));
  Check('nichts angelegt', AmsSpawnCount = 0, IntToStr(AmsSpawnCount));
end;

procedure TestHighlight;
var
  R: TRect;
begin
  Section('Hervorheben');
  Check('kein Element -> kein Fenster', AmsWindowOfElement(nil) = 0);
  Check('kein Element -> kein Hervorheben', not AmsHighlightElement(nil));
  Check('mit Begruendung', AmsLastError <> '', AmsLastError);
  { Ohne Host gibt es kein VCL-Objekt zu einem Fenster - der Rueckweg muss
    das sauber verneinen, nicht in der Fensterschleife haengenbleiben. }
  Check('unbekanntes Objekt -> kein Fenster',
        AmsWindowOfElement(Pointer($DEADBEEF)) = 0);

  { Der Rahmen selbst laesst sich pruefen, ohne dass jemand hinsieht: weit
    ausserhalb des sichtbaren Bereichs zeichnen. Zweimal gezeichnet hebt
    XOR sich selbst auf, es bleibt also auch nichts stehen. }
  R.Left := -3000; R.Top := -3000; R.Right := -2900; R.Bottom := -2950;
  AmsFlashFrame(R, 1, 3);
  Check('Rahmen zeichnen stuerzt nicht ab', True);
  { Entartete Rechtecke sind der uebliche Absturzkandidat. }
  R.Right := R.Left;
  AmsFlashFrame(R, 1, 3);
  R.Left := 0; R.Top := 0; R.Right := 2; R.Bottom := 2;
  AmsFlashFrame(R, 1, 9);
  Check('leere und winzige Rechtecke sind harmlos', True);
end;

begin
  AmsSetLogFile(IncludeTrailingPathDelimiter(GetTempDir) +
                'amsapi_finderdemo.log');
  WriteLn('AmsApi ', AMS_API_VERSION, ' - Suchfenster ohne AMS');
  WriteLn('=========================================');

  TestOpenClose;
  TestLayout;
  TestActions;
  TestBuilding;
  TestHighlight;

  Section('Abbau');
  FinderClose;
  Check('Fenster geschlossen', gFinder = 0);
  Check('kein eigenes Fenster mehr uebrig', not OwnFinderExists);
  { Doppeltes Schliessen kommt vor: BeforeUnload und danach die finalization }
  FinderClose;
  Check('zweites Schliessen ist harmlos', True);

  WriteLn;
  WriteLn(Format('%d Pruefungen, %d Fehlschlaege.', [gRun, gFail]));
  if gFail = 0 then WriteLn('ALLES GRUEN.') else WriteLn('FEHLGESCHLAGEN.');
  Halt(gFail);
end.
