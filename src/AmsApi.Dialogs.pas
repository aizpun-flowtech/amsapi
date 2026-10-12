unit AmsApi.Dialogs;

{ ============================================================================
  AmsApi.Dialogs - Rueckfragen an den Anwender

  Die Bibliothek zeigt von sich aus NIE einen Dialog (Designregel 1). Diese
  Unit ist fuer den Fall, dass ein PLUGIN fragen will - mit eigenen
  Knopftexten statt "Ja/Nein", also mit dem TaskDialog von Windows.

  TaskDialogIndirect gibt es nur in comctl32 Version 6. AMS laedt die (sein
  Manifest verlangt sie), ein Testprogramm ohne Manifest nicht. Fehlt die
  Funktion, faellt AmsTaskDialog auf MessageBoxW zurueck: ein Knopf = OK,
  zwei = Ja/Nein, drei = Ja/Nein/Abbrechen - in dieser Reihenfolge den
  Knoepfen zugeordnet. Die Knopftexte stehen dann im Text darueber, damit
  klar ist, welcher was tut.

  AmsDialogsSilent = True beantwortet jede Frage sofort mit ADefault - fuer
  Rauchtests ohne Bediener.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{$codepage utf8}

interface

uses
  Windows, SysUtils;

type
  TAmsDialogIcon = (diNone, diInfo, diWarning, diError, diShield);

var
  { Keine Fenster, jede Frage liefert ihren Standard. Fuer Tests. }
  AmsDialogsSilent: Boolean = False;
  { Antwort der stillen Fragen: -2 = jeweils ADefault, sonst dieser Index
    (-1 = Abbruch). Fuer Tests. }
  AmsDialogsSilentAnswer: Integer = -2;
  { So lange verteilt eine stille Frage Nachrichten, bevor sie antwortet -
    wie ein echter Dialog, der offen steht, waehrend der Anwender liest.
    Ohne das findet kein Test, was waehrend einer Rueckfrage passieren
    kann (im echten AMS: Liste ersetzt, Zeiger ins Leere). Fuer Tests. }
  AmsDialogsSilentPumpMs: Integer = 0;
  { Zaehlt die Fragen - auch die stillen. Fuer Tests. }
  AmsDialogCount: Integer = 0;

{ Frage mit eigenen Knoepfen. Liefert den Index des gewaehlten Knopfs
  (0-basiert) oder -1 bei Abbruch (Esc / Schliessen). }
function AmsTaskDialog(AOwner: HWND; const ATitle, AMain, AContent: WideString;
  const AButtons: array of WideString; ADefault: Integer = 0;
  AIcon: TAmsDialogIcon = diInfo): Integer;

{ "AMS jetzt neu starten?" - True = jetzt, False = spaeter. }
function AmsAskRestart(AOwner: HWND; const AWhat: WideString): Boolean;

implementation

const
  TDF_ALLOW_DIALOG_CANCELLATION = $0008;
  TDF_USE_COMMAND_LINKS         = $0010;
  TDF_POSITION_RELATIVE_TO_WINDOW = $1000;
  ID_BASE = 1000;

type
  TTaskDialogButton = packed record
    nButtonID: Integer;
    pszButtonText: PWideChar;
  end;

  TTaskDialogConfig = packed record
    cbSize: UINT;
    hwndParent: HWND;
    hInstance: HINST;
    dwFlags: DWORD;
    dwCommonButtons: DWORD;
    pszWindowTitle: PWideChar;
    pszMainIcon: PWideChar;
    pszMainInstruction: PWideChar;
    pszContent: PWideChar;
    cButtons: UINT;
    pButtons: Pointer;
    nDefaultButton: Integer;
    cRadioButtons: UINT;
    pRadioButtons: Pointer;
    nDefaultRadioButton: Integer;
    pszVerificationText: PWideChar;
    pszExpandedInformation: PWideChar;
    pszExpandedControlText: PWideChar;
    pszCollapsedControlText: PWideChar;
    pszFooterIcon: PWideChar;
    pszFooter: PWideChar;
    pfCallback: Pointer;
    lpCallbackData: LONG_PTR;
    cxWidth: UINT;
  end;

  TTaskDialogIndirect = function(const AConfig: TTaskDialogConfig;
    APressed, ARadio: PInteger; AVerify: PBOOL): HRESULT; stdcall;

function IconRes(AIcon: TAmsDialogIcon): PWideChar;
begin
  case AIcon of
    diWarning: Result := PWideChar(PtrUInt($FFFF));   { TD_WARNING_ICON }
    diError:   Result := PWideChar(PtrUInt($FFFE));   { TD_ERROR_ICON }
    diInfo:    Result := PWideChar(PtrUInt($FFFD));   { TD_INFORMATION_ICON }
    diShield:  Result := PWideChar(PtrUInt($FFFC));   { TD_SHIELD_ICON }
  else
    Result := nil;
  end;
end;

function BoxIcon(AIcon: TAmsDialogIcon): UINT;
begin
  case AIcon of
    diWarning, diShield: Result := MB_ICONWARNING;
    diError: Result := MB_ICONERROR;
    diInfo: Result := MB_ICONINFORMATION;
  else
    Result := 0;
  end;
end;

{ Befehlslink "Titel"#10"Erklaerung" fuer die MessageBox in eine Zeile }
function OneLine(const S: WideString): WideString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if S[i] = #10 then Result := Result + ' – '
    else Result := Result + S[i];
end;

function AmsTaskDialog(AOwner: HWND; const ATitle, AMain, AContent: WideString;
  const AButtons: array of WideString; ADefault: Integer;
  AIcon: TAmsDialogIcon): Integer;
var
  Fn: TTaskDialogIndirect;
  Cfg: TTaskDialogConfig;
  Btn: array of TTaskDialogButton;
  i, Pressed, n: Integer;
  Text: WideString;
  Style: UINT;
  R: Integer;
  Start: QWord;
  Msg: TMsg;
begin
  Inc(AmsDialogCount);
  n := Length(AButtons);
  if AmsDialogsSilent then
  begin
    if AmsDialogsSilentPumpMs > 0 then
    begin
      Start := GetTickCount64;
      repeat
        while PeekMessageW(Msg, 0, 0, 0, PM_REMOVE) do
        begin
          TranslateMessage(Msg);
          DispatchMessageW(Msg);
        end;
        Sleep(10);
      until GetTickCount64 - Start >= QWord(AmsDialogsSilentPumpMs);
    end;
    if AmsDialogsSilentAnswer >= -1 then Exit(AmsDialogsSilentAnswer);
    Exit(ADefault);
  end;

  Fn := nil;
  if GetModuleHandleW('comctl32.dll') <> 0 then
    Fn := TTaskDialogIndirect(GetProcAddress(GetModuleHandleW('comctl32.dll'),
                                             'TaskDialogIndirect'));
  if Assigned(Fn) and (n > 0) then
  begin
    SetLength(Btn, n);
    for i := 0 to n - 1 do
    begin
      Btn[i].nButtonID := ID_BASE + i;
      Btn[i].pszButtonText := PWideChar(AButtons[i]);
    end;
    FillChar(Cfg, SizeOf(Cfg), 0);
    Cfg.cbSize := SizeOf(Cfg);
    Cfg.hwndParent := AOwner;
    Cfg.dwFlags := TDF_ALLOW_DIALOG_CANCELLATION or TDF_POSITION_RELATIVE_TO_WINDOW;
    { Knopftexte mit Zeilenumbruch werden als Befehlslinks gezeigt }
    for i := 0 to n - 1 do
      if Pos(#10, AButtons[i]) > 0 then
        Cfg.dwFlags := Cfg.dwFlags or TDF_USE_COMMAND_LINKS;
    Cfg.pszWindowTitle := PWideChar(ATitle);
    Cfg.pszMainIcon := IconRes(AIcon);
    Cfg.pszMainInstruction := PWideChar(AMain);
    Cfg.pszContent := PWideChar(AContent);
    Cfg.cButtons := n;
    Cfg.pButtons := @Btn[0];
    Cfg.nDefaultButton := ID_BASE + ADefault;
    Pressed := 0;
    try
      if Fn(Cfg, @Pressed, nil, nil) = S_OK then
      begin
        if (Pressed >= ID_BASE) and (Pressed < ID_BASE + n) then
          Exit(Pressed - ID_BASE);
        Exit(-1);       { IDCANCEL }
      end;
    except
    end;
  end;

  { Ersatz ohne comctl32 v6 }
  Text := AMain;
  if AContent <> '' then Text := Text + #13#10#13#10 + AContent;
  if n > 1 then
  begin
    Text := Text + #13#10;
    for i := 0 to n - 1 do
    begin
      case i of
        0: Text := Text + #13#10'Ja = ';
        1: Text := Text + #13#10'Nein = ';
      else
        Text := Text + #13#10'Abbrechen = ';
      end;
      Text := Text + OneLine(AButtons[i]);
    end;
  end;
  case n of
    0, 1: Style := MB_OK;
    2: Style := MB_YESNO;
  else
    Style := MB_YESNOCANCEL;
  end;
  if ADefault = 1 then Style := Style or MB_DEFBUTTON2
  else if ADefault = 2 then Style := Style or MB_DEFBUTTON3;
  R := MessageBoxW(AOwner, PWideChar(Text), PWideChar(ATitle),
                   Style or BoxIcon(AIcon));
  case R of
    IDOK, IDYES: Result := 0;
    IDNO: Result := 1;
    IDCANCEL: if n >= 3 then Result := 2 else Result := -1;
  else
    Result := -1;
  end;
end;

function AmsAskRestart(AOwner: HWND; const AWhat: WideString): Boolean;
begin
  Result := AmsTaskDialog(AOwner, 'AMS neu starten',
    AWhat,
    'Die Änderung wird erst nach einem Neustart von AMS wirksam. ' +
    'Beim Beenden fragt AMS wie gewohnt nach ungespeicherten Daten.',
    ['Jetzt neu starten'#10'AMS wird beendet und gleich wieder geöffnet.',
     'Später'#10'Die Änderung greift beim nächsten Start von AMS.'],
    1, diInfo) = 0;
end;

end.
