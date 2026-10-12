program browserdemo;

{ ============================================================================
  Rauchtest der eingebetteten HTML-Ansicht (AmsApi.Browser) - OHNE AMS.

  Ein Elternfenster ausserhalb des Bildes bekommt eine TAmsHtmlView. Ist der
  Browser von Windows (atl.dll / AtlAxWin) zu haben, wird er wirklich
  gefahren: zwei Dateien laden - eine davon in einem Ordner mit Leerzeichen
  und "#", eine mit Umlauten im Titel -, Fertigmeldung und Dokumenttitel
  lesen, eine Seite, die woanders hin will (Meta-Refresh), abfangen, die
  Hilfsseite von ShowText anzeigen. Danach dasselbe mit abgeschaltetem
  Browser: dann muss das Ersatz-Textfeld den Ersatztext zeigen.

  Am Ende darf weder ein Fenster noch eine Fensterklasse noch eine
  Hilfsdatei uebrig sein.

  Rueckgabewert 0 = alles gruen, sonst Anzahl der Fehlschlaege.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, Classes,
  AmsApi.Log, AmsApi.Browser;

const
  DEMO_CLASS = 'AmsApiBrowserDemo';
  ID_VIEW    = 300;
  ID_ERSATZ  = 301;
  WARTE_MS   = 10000;

type
  TLinkFang = class
    Url: string;
    Anzahl: Integer;
    procedure Link(ASender: TAmsHtmlView; const AUrl: string;
      var AHandled: Boolean);
  end;

var
  gRun: Integer = 0;
  gFail: Integer = 0;
  gParent: HWND = 0;
  gDir: string;

procedure TLinkFang.Link(ASender: TAmsHtmlView; const AUrl: string;
  var AHandled: Boolean);
begin
  Url := AUrl;
  Inc(Anzahl);
  AHandled := True;      { im Test nie den echten Browser starten }
end;

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

{ ----------------------------------------------------------------- Helfer - }

procedure Pump;
var
  M: TMsg;
begin
  while PeekMessageW(M, 0, 0, 0, PM_REMOVE) do
  begin
    TranslateMessage(M);
    DispatchMessageW(M);
  end;
end;

procedure PumpFor(AMs: DWORD);
var
  T0: QWord;
begin
  T0 := GetTickCount64;
  repeat
    Pump;
    Sleep(10);
  until GetTickCount64 - T0 >= AMs;
end;

{ Bis die Seite mit diesem Titel fertig ist. }
function WarteAuf(V: TAmsHtmlView; const ATitle: WideString): Boolean;
var
  T0: QWord;
begin
  T0 := GetTickCount64;
  repeat
    Pump;
    if (V.ReadyState = 4) and (V.DocumentTitle = ATitle) then Exit(True);
    Sleep(15);
  until GetTickCount64 - T0 > WARTE_MS;
  Result := False;
end;

procedure SchreibeUtf8(const AFile: string; const AText: WideString);
var
  U: UTF8String;
  F: TFileStream;
begin
  U := UTF8Encode(AText);
  F := TFileStream.Create(AFile, fmCreate);
  try
    F.WriteBuffer(Pointer(U)^, Length(U));
  finally
    F.Free;
  end;
end;

function Seite(const ATitle, AHead, ABody: WideString): WideString;
begin
  Result := '<!DOCTYPE html><html><head>' +
            '<meta http-equiv="X-UA-Compatible" content="IE=edge">' +
            '<meta charset="utf-8">' + AHead +
            '<title>' + ATitle + '</title></head><body>' + ABody +
            '</body></html>';
end;

function FensterText(AWnd: HWND): WideString;
var
  Len: Integer;
begin
  Result := '';
  Len := GetWindowTextLengthW(AWnd);
  if Len <= 0 then Exit;
  SetLength(Result, Len + 1);
  GetWindowTextW(AWnd, PWideChar(Result), Len + 1);
  SetLength(Result, Len);
end;

function KlassenName(AWnd: HWND): string;
var
  Buf: array[0..63] of WideChar;
begin
  Buf[0] := #0;
  GetClassNameW(AWnd, Buf, Length(Buf));
  Result := string(WideString(PWideChar(@Buf[0])));
end;

function HilfsdateienUebrig: Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(Format('%sAmsApi_htmlview_%d_*.html',
       [IncludeTrailingPathDelimiter(GetTempDir), GetCurrentProcessId]),
       faAnyFile, SR) = 0 then
  begin
    repeat
      Inc(Result);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

{ ------------------------------------------------------------ Elternfenster }

function MachEltern: Boolean;
var
  WC: WNDCLASSW;
begin
  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @DefWindowProcW;
  WC.hInstance := HInstance;
  WC.hbrBackground := HBRUSH(COLOR_BTNFACE + 1);
  WC.lpszClassName := DEMO_CLASS;
  RegisterClassW(WC);
  { Nicht gezeigt und ausserhalb des Bildes. }
  gParent := CreateWindowExW(WS_EX_TOOLWINDOW, DEMO_CLASS, 'browserdemo',
    WS_POPUP or WS_CLIPCHILDREN, -32000, -32000, 800, 600, 0, 0,
    HInstance, nil);
  Result := gParent <> 0;
end;

{ ---------------------------------------------------------------- Pruefungen }

procedure TestUrl;
begin
  Section('Pfad als URL');
  CheckEq('einfacher Pfad', 'file:///C:/Temp/a.html',
          AmsFileUrl('C:\Temp\a.html'));
  CheckEq('Leerzeichen, # und %', 'file:///C:/x%20y/a%23b%25c.html',
          AmsFileUrl('C:\x y\a#b%c.html'));
  CheckEq('UNC-Pfad', 'file://srv/share/r.html',
          AmsFileUrl('\\srv\share\r.html'));
  CheckEq('URL bleibt', 'https://example.invalid/x?a=1#b',
          AmsFileUrl('https://example.invalid/x?a=1#b'));
  CheckEq('about: bleibt', 'about:blank', AmsFileUrl('about:blank'));
end;

procedure TestBrowser;
var
  V: TAmsHtmlView;
  Fang: TLinkFang;
  Avail: Boolean;
  Eins, Zwei, Drei: string;
  H: HWND;
  R: TRect;
  T0: QWord;
  Gruesse: WideString;
begin
  Section('Eingebetteter Browser');
  Avail := AmsBrowserAvailable;
  WriteLn('  info  Browser auf diesem Rechner: ', BoolToStr(Avail, True));

  V := TAmsHtmlView.Create(gParent, ID_VIEW);
  Fang := TLinkFang.Create;
  try
    V.OnLink := Fang.Link;
    Check('Ansicht ist der Browser, wenn er verfuegbar ist',
          V.IsBrowser = Avail, AmsLastError);
    Check('Kindfenster vorhanden', IsWindow(V.Handle));
    Check('Kind des Elternfensters', GetParent(V.Handle) = gParent);
    CheckEq('Control-ID', IntToStr(ID_VIEW), IntToStr(GetDlgCtrlID(V.Handle)));

    if not V.IsBrowser then
    begin
      WriteLn('  info  kein Browser - Browserpruefungen entfallen');
      Exit;
    end;
    CheckEq('Fensterklasse', 'AtlAxWin', KlassenName(V.Handle));

    { Ordner mit Leerzeichen und "#" - genau die Zeichen, an denen eine
      file:-URL sonst bricht. }
    Eins := gDir + 'eins.html';
    SchreibeUtf8(Eins, Seite('Probe', '',
      '<h1>Probe</h1><p>Inhalt mit Umlauten: ' + WideChar($E4) +
      WideChar($F6) + WideChar($FC) + '</p>'));
    Check('ShowFile startet', V.ShowFile(Eins, 'Ersatz'), AmsLastError);
    Check('Seite 1 fertig mit Titel "Probe"', WarteAuf(V, 'Probe'),
          string(V.DocumentTitle));
    CheckEq('ReadyState fertig', '4', IntToStr(V.ReadyState));

    Gruesse := 'Gr' + WideChar($FC) + WideChar($DF) + 'e';
    Zwei := gDir + 'zwei.html';
    SchreibeUtf8(Zwei, Seite(Gruesse, '', '<p>zweite Seite</p>'));
    Check('zweite Datei', V.ShowFile(Zwei), AmsLastError);
    Check('Seite 2 fertig, Umlaut-Titel kommt heil an', WarteAuf(V, Gruesse),
          string(V.DocumentTitle));

    { Eine Seite, die von selbst woanders hin will: das ist keine eigene
      Navigation, sie muss abgebrochen und an OnLink gereicht werden. }
    Drei := gDir + 'drei.html';
    SchreibeUtf8(Drei, Seite('Drei',
      '<meta http-equiv="refresh" content="0;url=https://example.invalid/weiter">',
      '<p>gleich weg</p>'));
    Check('dritte Datei', V.ShowFile(Drei), AmsLastError);
    Check('Seite 3 fertig', WarteAuf(V, 'Drei'), string(V.DocumentTitle));
    T0 := GetTickCount64;
    while (Fang.Anzahl = 0) and (GetTickCount64 - T0 < WARTE_MS) do
    begin
      Pump;
      Sleep(15);
    end;
    CheckEq('fremde Navigation an OnLink', 'https://example.invalid/weiter',
            Fang.Url);
    CheckEq('genau einmal', '1', IntToStr(Fang.Anzahl));
    PumpFor(300);
    CheckEq('und abgebrochen - die Seite bleibt', 'Drei',
            string(V.DocumentTitle));

    V.ShowText('Lade README ...'#10'zweite Zeile <b>kein Fett</b>');
    Check('ShowText als Seite, Titel = erste Zeile',
          WarteAuf(V, 'Lade README ...'), string(V.DocumentTitle));
    CheckEq('eigene Navigationen nie an OnLink', '1', IntToStr(Fang.Anzahl));
    Check('Hilfsseite liegt im TEMP', HilfsdateienUebrig > 0);

    V.SetBounds(10, 20, 300, 200);
    GetWindowRect(V.Handle, R);
    MapWindowPoints(0, gParent, R, 2);
    CheckEq('SetBounds: Lage', '10,20', Format('%d,%d', [R.Left, R.Top]));
    CheckEq('SetBounds: Groesse', '300x200',
            Format('%dx%d', [R.Right - R.Left, R.Bottom - R.Top]));
    V.SetVisible(False);
    Check('SetVisible(False)',
          GetWindowLongW(V.Handle, GWL_STYLE) and WS_VISIBLE = 0);
    V.SetVisible(True);
    Check('SetVisible(True)',
          GetWindowLongW(V.Handle, GWL_STYLE) and WS_VISIBLE <> 0);
  finally
    H := V.Handle;
    V.Free;
    Fang.Free;
  end;
  PumpFor(100);
  Check('Kindfenster nach Free weg', not IsWindow(H));
  CheckEq('keine Hilfsdatei uebrig', '0', IntToStr(HilfsdateienUebrig));
end;

procedure TestErsatz;
var
  V: TAmsHtmlView;
  H: HWND;
  Klein: string;
begin
  Section('Ersatz ohne Browser');
  AmsBrowserDisabled := True;
  try
    Check('abgeschaltet heisst nicht verfuegbar', not AmsBrowserAvailable);
    V := TAmsHtmlView.Create(gParent, ID_ERSATZ);
    try
      Check('kein Browser', not V.IsBrowser);
      Check('Textfeld vorhanden', IsWindow(V.Handle));
      Klein := LowerCase(KlassenName(V.Handle));
      CheckEq('Fensterklasse', 'edit', Klein);
      CheckEq('Control-ID', IntToStr(ID_ERSATZ),
              IntToStr(GetDlgCtrlID(V.Handle)));
      Check('schreibgeschuetzt',
            GetWindowLongW(V.Handle, GWL_STYLE) and ES_READONLY <> 0);

      Check('ShowFile meldet: nicht im Browser',
            not V.ShowFile(gDir + 'eins.html',
                           'Ersatztext Zeile 1'#10'Zeile 2'));
      Check('mit Begruendung', AmsLastError <> '', AmsLastError);
      Check('Ersatztext steht im Feld, Zeilen als CRLF',
            FensterText(V.Handle) = 'Ersatztext Zeile 1'#13#10'Zeile 2',
            string(FensterText(V.Handle)));

      V.ShowText('Hallo');
      Check('ShowText im Feld', FensterText(V.Handle) = 'Hallo',
            string(FensterText(V.Handle)));
      Check('ShowUrl ohne Browser = False',
            not V.ShowUrl('https://example.invalid/'));
      Check('URL steht im Feld',
            Pos('https://example.invalid/', string(FensterText(V.Handle))) > 0,
            string(FensterText(V.Handle)));
      Check('fehlende Datei = False',
            not V.ShowFile(gDir + 'gibtsnicht.html', 'Ersatz'));
      Check('mit Begruendung "fehlt"', Pos('fehlt', AmsLastError) > 0,
            AmsLastError);
      CheckEq('ReadyState ohne Browser', '-1', IntToStr(V.ReadyState));
      Check('kein Titel ohne Browser', V.DocumentTitle = '');

      V.SetBounds(5, 6, 200, 100);
      V.SetVisible(False);
      Check('SetVisible(False) am Textfeld',
            GetWindowLongW(V.Handle, GWL_STYLE) and WS_VISIBLE = 0);
    finally
      H := V.Handle;
      V.Free;
    end;
    Check('Textfeld nach Free weg', not IsWindow(H));
  finally
    AmsBrowserDisabled := False;
  end;
end;

procedure Aufraeumen;
begin
  Section('Aufraeumen');
  Check('Elternfenster zerstoert', DestroyWindow(gParent));
  gParent := 0;
  Check('Fensterklasse abgemeldet', UnregisterClassW(DEMO_CLASS, HInstance));
  DeleteFile(gDir + 'eins.html');
  DeleteFile(gDir + 'zwei.html');
  DeleteFile(gDir + 'drei.html');
  Check('Testordner entfernt', RemoveDir(ExcludeTrailingPathDelimiter(gDir)));
end;

begin
  AmsSetLogFile(IncludeTrailingPathDelimiter(GetTempDir) +
                'amsapi_browserdemo.log');
  WriteLn('AmsApi.Browser - Rauchtest ohne AMS');
  WriteLn('===================================');

  gDir := IncludeTrailingPathDelimiter(GetTempDir) + 'amsapi browser #probe\';
  ForceDirectories(gDir);

  TestUrl;
  if MachEltern then
  begin
    TestBrowser;
    TestErsatz;
    Aufraeumen;
  end
  else
    Check('Elternfenster', False, IntToStr(GetLastError));

  WriteLn;
  WriteLn(Format('%d Pruefungen, %d Fehlschlaege.', [gRun, gFail]));
  if gFail = 0 then WriteLn('ALLES GRUEN.') else WriteLn('FEHLGESCHLAGEN.');
  Halt(gFail);
end.
