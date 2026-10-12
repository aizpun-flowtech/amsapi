unit AmsApi.IniEditor;

{ ============================================================================
  AmsApi.IniEditor - Einstellungsfenster fuer eine INI-Datei

  Jedes Plugin kann damit seine plugin.ini im laufenden AMS bearbeitbar
  machen - eine Zeile:

      AmsIniEditorOpen(MainWindow, AmsIniFile, 'Einstellungen');

  Oben die Liste aller Schluessel (Abschnitt, Schluessel, Wert), darunter
  die Beschreibung des gewaehlten Schluessels - das ist der Kommentarblock
  direkt darueber in der Datei, siehe AmsApi.IniDoc -, dann der Wert zum
  Aendern. "Als Text bearbeiten" zeigt die ganze Datei. Gespeichert wird
  mit AmsApi.IniDoc: Kommentare, Reihenfolge und Schreibweise bleiben.

  Zeichensatz: Ist die Datei UTF-8 (BOM oder gueltige Mehrbytezeichen),
  wird UTF-8 zurueckgeschrieben, sonst ANSI - das liest AmsIniValue im
  Plugin, und so bleibt es.

  OnSave ersetzt das Speichern. Standard: direkt schreiben. Der Plugin
  Manager haengt hier den Weg ueber Administratorrechte ein, denn
  BIN\plugins\*\plugin.ini ist fuer Benutzer schreibgeschuetzt. OnSaved
  kommt nach erfolgreichem Speichern (Neustart anbieten ...).

  Mehrere Fenster gleichzeitig gehen; dieselbe Datei ein zweites Mal holt
  das vorhandene nach vorn. PFLICHT beim Entladen: AmsIniEditorCloseAll -
  die Fensterprozedur liegt in diesem Modul.

  Kein Tab zwischen den Feldern: die Nachrichtenschleife gehoert AMS, und
  die ruft fuer fremde Fenster kein IsDialogMessage. Enter im Wertfeld
  uebernimmt den Wert.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{$codepage utf8}

interface

uses
  Windows, SysUtils, Classes, AmsApi.IniDoc;

type
  { AText = Bytes der ganzen Datei. True = gespeichert. Bei False steht die
    Ursache in AmsLastError. }
  TAmsIniSaveEvent = function(const AFile, AText: string): Boolean of object;
  TAmsIniSavedEvent = procedure(const AFile: string) of object;

  TAmsIniEditor = class
  private
    FWnd, FOwner: HWND;
    FFile: string;
    FTitle: WideString;
    FDoc: TAmsIniDoc;
    FUtf8: Boolean;
    FDirty: Boolean;
    FTextMode: Boolean;
    FCurrent: Integer;          { Eintragsindex im Wertfeld, -1 = keiner }
    FList, FDesc, FValue, FText, FStatus, FPath: HWND;
    FOldEditProc: Pointer;
    FLocked: array of string;
    FOnSave: TAmsIniSaveEvent;
    FOnSaved: TAmsIniSavedEvent;
    procedure BuildControls;
    procedure Layout;
    procedure FillList;
    procedure SelectEntry(AIndex: Integer);
    procedure ApplyValue;
    procedure ToggleText;
    function TextFromEdit: Boolean;
    function Encode(const AText: WideString): string;
    procedure SetStatus(const AText: WideString);
    procedure UpdateTitle;
    procedure Command(AId, ACode: Integer);
    procedure Notify(AHdr: Pointer);
  public
    constructor Create(AOwner: HWND; const AFile: string;
      const ATitle: WideString);
    destructor Destroy; override;
    function Open: Boolean;
    { Fragt bei ungespeicherten Aenderungen (ausser AForce). False =
      Anwender hat abgebrochen, Fenster bleibt. }
    function Close(AForce: Boolean = False): Boolean;
    function Save: Boolean;
    function Reload: Boolean;
    { Schluessel, die nur angezeigt, nicht geaendert werden (Muster wie bei
      AmsIniKeyMatches, z.B. AMS_PACKAGE_OWNED). Im Textmodus gilt das
      nicht - der ist fuer Fachleute. }
    procedure SetLocked(const APatterns: array of string);
    function IsLocked(AIndex: Integer): Boolean;
    function Handle: HWND;
    function Dirty: Boolean;
    property FileName: string read FFile;
    property Doc: TAmsIniDoc read FDoc;
    property OnSave: TAmsIniSaveEvent read FOnSave write FOnSave;
    property OnSaved: TAmsIniSavedEvent read FOnSaved write FOnSaved;
  end;

{ Fenster oeffnen (oder das vorhandene fuer diese Datei nach vorn holen). }
function AmsIniEditorOpen(AOwner: HWND; const AFile: string;
  const ATitle: WideString = ''; AOnSave: TAmsIniSaveEvent = nil;
  AOnSaved: TAmsIniSavedEvent = nil): TAmsIniEditor;
{ Alle schliessen, ohne zu fragen. GEHOERT IN JEDES BeforeUnload. }
procedure AmsIniEditorCloseAll;
function AmsIniEditorCount: Integer;
function AmsIniEditorFind(const AFile: string): TAmsIniEditor;

const
  { Steuerelemente - oeffentlich fuer Rauchtests }
  IDC_IE_LIST   = 300;
  IDC_IE_DESC   = 301;
  IDC_IE_VALUE  = 302;
  IDC_IE_APPLY  = 303;
  IDC_IE_TEXT   = 304;
  IDC_IE_TOGGLE = 305;
  IDC_IE_SAVE   = 306;
  IDC_IE_CLOSE  = 307;
  IDC_IE_STATUS = 308;
  IDC_IE_RELOAD = 309;
  IDC_IE_PATH   = 310;

implementation

uses
  AmsApi.Log, AmsApi.Files, AmsApi.WinCtl, AmsApi.Dialogs;

const
  CLASS_NAME = 'AmsApiIniEditor';
  M = 10;
  ROW = 26;
  BTN = 128;
  DESC_H = 78;
  SS_ENDELLIPSIS  = $4000;
  SS_PATHELLIPSIS = $8000;

var
  gEditors: TList = nil;
  gClassW: WideString = '';
  gRegistered: Boolean = False;

{ -------------------------------------------------------- Fensterprozedur - }

function EditorOf(AWnd: HWND): TAmsIniEditor;
begin
  Result := TAmsIniEditor(GetWindowLongPtrW(AWnd, GWLP_USERDATA));
end;

function EditorProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
var
  E: TAmsIniEditor;
  CS: PCreateStruct;   { lpCreateParams liegt bei A und W gleich }
begin
  if AMsg = WM_NCCREATE then
  begin
    CS := PCreateStruct(ALParam);
    SetWindowLongPtrW(AWnd, GWLP_USERDATA, LONG_PTR(CS^.lpCreateParams));
  end;
  E := EditorOf(AWnd);
  if E <> nil then
  try
    case AMsg of
      WM_SIZE:
        begin
          E.Layout;
          Exit(0);
        end;
      WM_GETMINMAXINFO:
        begin
          PMinMaxInfo(ALParam)^.ptMinTrackSize.x := 620;
          PMinMaxInfo(ALParam)^.ptMinTrackSize.y := 420;
          Exit(0);
        end;
      WM_COMMAND:
        begin
          E.Command(LOWORD(AWParam), HIWORD(AWParam));
          Exit(0);
        end;
      WM_NOTIFY:
        begin
          E.Notify(Pointer(ALParam));
          Exit(0);
        end;
      WM_CTLCOLORSTATIC:
        if HWND(ALParam) = E.FPath then
        begin
          SetTextColor(HDC(AWParam), GetSysColor(COLOR_GRAYTEXT));
          SetBkColor(HDC(AWParam), GetSysColor(COLOR_BTNFACE));
          Exit(LRESULT(GetSysColorBrush(COLOR_BTNFACE)));
        end;
      WM_CLOSE:
        begin
          E.Close(False);
          Exit(0);
        end;
      WM_DESTROY:
        begin
          E.FWnd := 0;
          Exit(0);
        end;
    end;
  except
    on Ex: Exception do AmsLog('IniEditor EXCEPTION: ' + Ex.Message);
  end;
  Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

{ Enter im Wertfeld = Uebernehmen }
function ValueEditProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
var
  E: TAmsIniEditor;
begin
  E := EditorOf(GetParent(AWnd));
  if (E <> nil) and (AMsg = WM_KEYDOWN) and (AWParam = VK_RETURN) then
  begin
    E.ApplyValue;
    Exit(0);
  end;
  if (E <> nil) and (AMsg = WM_CHAR) and (AWParam = 13) then Exit(0);
  if (E <> nil) and (E.FOldEditProc <> nil) then
    Result := CallWindowProcW(E.FOldEditProc, AWnd, AMsg, AWParam, ALParam)
  else
    Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

procedure EnsureClass;
var
  WC: TWndClassExW;
begin
  if gRegistered then Exit;
  FillChar(WC, SizeOf(WC), 0);
  WC.cbSize := SizeOf(WC);
  WC.lpfnWndProc := @EditorProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursorW(0, LPCWSTR(IDC_ARROW));
  WC.hbrBackground := HBRUSH(COLOR_BTNFACE + 1);
  gClassW := CLASS_NAME;
  WC.lpszClassName := PWideChar(gClassW);
  RegisterClassExW(WC);
  gRegistered := True;
end;

procedure DropClassIfUnused;
begin
  if gRegistered and ((gEditors = nil) or (gEditors.Count = 0)) then
  begin
    UnregisterClassW(PWideChar(gClassW), HInstance);
    gRegistered := False;
  end;
end;

{ ---------------------------------------------------------- TAmsIniEditor - }

constructor TAmsIniEditor.Create(AOwner: HWND; const AFile: string;
  const ATitle: WideString);
begin
  inherited Create;
  FOwner := AOwner;
  FFile := AFile;
  FTitle := ATitle;
  FDoc := TAmsIniDoc.Create;
  FCurrent := -1;
  if gEditors = nil then gEditors := TList.Create;
  gEditors.Add(Self);
end;

destructor TAmsIniEditor.Destroy;
begin
  if FWnd <> 0 then
  begin
    SetWindowLongPtrW(FWnd, GWLP_USERDATA, 0);
    DestroyWindow(FWnd);
    FWnd := 0;
  end;
  FDoc.Free;
  if gEditors <> nil then gEditors.Remove(Self);
  DropClassIfUnused;
  inherited Destroy;
end;

function TAmsIniEditor.Handle: HWND;
begin
  Result := FWnd;
end;

function TAmsIniEditor.Dirty: Boolean;
begin
  Result := FDirty;
end;

function TAmsIniEditor.Encode(const AText: WideString): string;
begin
  if FUtf8 then Result := AmsWideToUtf8(AText)
  else Result := string(AText);    { ANSI, Codepage des Systems }
end;

procedure TAmsIniEditor.SetStatus(const AText: WideString);
begin
  AmsSetWndText(FStatus, AText);
end;

procedure TAmsIniEditor.UpdateTitle;
var
  T: WideString;
begin
  T := FTitle;
  if T = '' then T := WideString(ExtractFileName(FFile));
  T := 'Einstellungen – ' + T;
  if FDirty then T := T + ' *';
  AmsSetWndText(FWnd, T);
end;

function TAmsIniEditor.Reload: Boolean;
var
  Raw: string;
begin
  Result := AmsReadFileRaw(FFile, Raw, 4 * 1024 * 1024);
  if not Result then Raw := '';
  FDoc.LoadFromText(Raw);
  FUtf8 := AmsHasUtf8Bom(Raw) or (AmsIsUtf8(Raw) and
           (AmsDecodeText(Raw) <> WideString(Raw)));
  FDirty := False;
  if FWnd <> 0 then
  begin
    FillList;
    if FTextMode then AmsSetWndText(FText, AmsDecodeText(FDoc.Text));
    UpdateTitle;
    if Result then SetStatus(WideString(Format('%d Einstellungen', [FDoc.Count])))
    else SetStatus('Datei nicht lesbar: ' + WideString(AmsLastError));
  end;
end;

procedure TAmsIniEditor.BuildControls;
begin
  FPath := AmsCreateChild(FWnd, 'STATIC', WideString(FFile),
                          SS_LEFTNOWORDWRAP or SS_PATHELLIPSIS, IDC_IE_PATH);
  FList := AmsListViewCreate(FWnd, IDC_IE_LIST, True);
  AmsListViewAddColumn(FList, 'Abschnitt', 130);
  AmsListViewAddColumn(FList, 'Schlüssel', 190);
  AmsListViewAddColumn(FList, 'Wert', 300);
  FDesc := AmsCreateChild(FWnd, 'EDIT', '', ES_MULTILINE or ES_READONLY or
                          WS_VSCROLL or ES_AUTOVSCROLL, IDC_IE_DESC, 0,
                          WS_EX_STATICEDGE);
  FValue := AmsCreateChild(FWnd, 'EDIT', '', WS_TABSTOP or ES_AUTOHSCROLL or
                           WS_BORDER, IDC_IE_VALUE);
  AmsSetCueBanner(FValue, 'Wert');
  FOldEditProc := Pointer(SetWindowLongPtrW(FValue, GWLP_WNDPROC,
                                            LONG_PTR(@ValueEditProc)));
  AmsCreateChild(FWnd, 'BUTTON', 'Übernehmen', WS_TABSTOP, IDC_IE_APPLY);
  FText := AmsCreateChild(FWnd, 'EDIT', '', ES_MULTILINE or WS_VSCROLL or
                          WS_HSCROLL or ES_AUTOVSCROLL or ES_AUTOHSCROLL or
                          ES_WANTRETURN or WS_BORDER, IDC_IE_TEXT, AmsMonoFont);
  SendMessageW(FText, EM_SETLIMITTEXT, 0, 0);
  ShowWindow(FText, SW_HIDE);
  AmsCreateChild(FWnd, 'BUTTON', 'Als Text bearbeiten', WS_TABSTOP,
                 IDC_IE_TOGGLE);
  AmsCreateChild(FWnd, 'BUTTON', 'Neu laden', WS_TABSTOP, IDC_IE_RELOAD);
  FStatus := AmsCreateChild(FWnd, 'STATIC', '', SS_LEFTNOWORDWRAP or
                            SS_ENDELLIPSIS, IDC_IE_STATUS);
  AmsCreateChild(FWnd, 'BUTTON', 'Speichern', WS_TABSTOP or BS_DEFPUSHBUTTON,
                 IDC_IE_SAVE, AmsBoldFont);
  AmsCreateChild(FWnd, 'BUTTON', 'Schließen', WS_TABSTOP, IDC_IE_CLOSE);
end;

procedure TAmsIniEditor.Layout;
var
  R: TRect;
  W, H, Y, ListH, X, BottomY: Integer;
begin
  if FWnd = 0 then Exit;
  GetClientRect(FWnd, R);
  W := R.Right;
  H := R.Bottom;
  Y := M;
  MoveWindow(FPath, M, Y, W - 2 * M, 18, True);
  Inc(Y, 22);
  BottomY := H - M - ROW;
  { untere Leiste: links Umschalter/Neu laden, Mitte Status, rechts Knoepfe }
  MoveWindow(GetDlgItem(FWnd, IDC_IE_TOGGLE), M, BottomY, BTN + 20, ROW, True);
  MoveWindow(GetDlgItem(FWnd, IDC_IE_RELOAD), M + BTN + 28, BottomY, 100, ROW, True);
  X := W - M - BTN;
  MoveWindow(GetDlgItem(FWnd, IDC_IE_CLOSE), X, BottomY, BTN, ROW, True);
  Dec(X, BTN + 8);
  MoveWindow(GetDlgItem(FWnd, IDC_IE_SAVE), X, BottomY, BTN, ROW, True);
  MoveWindow(FStatus, M + BTN + 28 + 108, BottomY + 5,
             X - (M + BTN + 28 + 108) - 8, 18, True);

  { Textmodus: das Textfeld fuellt alles }
  MoveWindow(FText, M, Y, W - 2 * M, BottomY - 8 - Y, True);

  ListH := BottomY - 8 - Y - DESC_H - 8 - ROW - 8;
  if ListH < 80 then ListH := 80;
  MoveWindow(FList, M, Y, W - 2 * M, ListH, True);
  AmsListViewSetColumnWidth(FList, 2, W - 2 * M - 130 - 190 - 24);
  Inc(Y, ListH + 8);
  MoveWindow(FDesc, M, Y, W - 2 * M, DESC_H, True);
  Inc(Y, DESC_H + 8);
  MoveWindow(FValue, M, Y, W - 2 * M - BTN - 8, ROW - 2, True);
  MoveWindow(GetDlgItem(FWnd, IDC_IE_APPLY), W - M - BTN, Y - 1, BTN, ROW, True);
end;

procedure TAmsIniEditor.FillList;
var
  i, Keep: Integer;
  E: TAmsIniEntry;
  Sec: WideString;
begin
  Keep := FCurrent;
  SendMessageW(FList, WM_SETREDRAW, 0, 0);
  try
    AmsListViewClear(FList);
    for i := 0 to FDoc.Count - 1 do
    begin
      E := FDoc.Entry(i);
      if E.Section = '' then Sec := '(Kopf)' else Sec := AmsDecodeText(E.Section);
      AmsListViewAdd(FList, [Sec, AmsDecodeText(E.Key), AmsDecodeText(E.Value)],
                     -1, i);
    end;
  finally
    SendMessageW(FList, WM_SETREDRAW, 1, 0);
  end;
  InvalidateRect(FList, nil, True);
  if (Keep >= 0) and (Keep < FDoc.Count) then
  begin
    AmsListViewSelect(FList, Keep);
    SelectEntry(Keep);
  end
  else
    SelectEntry(-1);
end;

procedure TAmsIniEditor.SetLocked(const APatterns: array of string);
var
  i: Integer;
begin
  SetLength(FLocked, Length(APatterns));
  for i := 0 to High(APatterns) do FLocked[i] := APatterns[i];
  if FWnd <> 0 then SelectEntry(FCurrent);
end;

function TAmsIniEditor.IsLocked(AIndex: Integer): Boolean;
var
  E: TAmsIniEntry;
begin
  Result := False;
  if (AIndex < 0) or (AIndex >= FDoc.Count) or (Length(FLocked) = 0) then Exit;
  E := FDoc.Entry(AIndex);
  Result := AmsIniKeyMatches(E.Section, E.Key, FLocked);
end;

procedure TAmsIniEditor.SelectEntry(AIndex: Integer);
var
  E: TAmsIniEntry;
  D: WideString;
  Lk: Boolean;
begin
  FCurrent := AIndex;
  if (AIndex < 0) or (AIndex >= FDoc.Count) then
  begin
    AmsSetWndText(FDesc, 'Einen Eintrag wählen. Die Beschreibung kommt aus ' +
                  'dem Kommentar über dem Schlüssel in der Datei.');
    AmsSetWndText(FValue, '');
    EnableWindow(FValue, False);
    AmsEnableChild(FWnd, IDC_IE_APPLY, False);
    Exit;
  end;
  E := FDoc.Entry(AIndex);
  D := AmsDecodeText(E.Comment);
  if D = '' then D := AmsDecodeText(FDoc.SectionComment(E.Section));
  if D = '' then D := '(keine Beschreibung in der Datei)';
  D := WideString(StringReplace(string(D), #10, #13#10, [rfReplaceAll]));
  Lk := IsLocked(AIndex);
  if Lk then
    D := 'Wird vom Plugin-Paket bestimmt und beim Aktualisieren ersetzt – ' +
         'hier nicht änderbar.'#13#10 + D;
  if E.Section <> '' then
    D := '[' + AmsDecodeText(E.Section) + '] ' + AmsDecodeText(E.Key) +
         #13#10 + D
  else
    D := AmsDecodeText(E.Key) + #13#10 + D;
  AmsSetWndText(FDesc, D);
  EnableWindow(FValue, not Lk);
  AmsEnableChild(FWnd, IDC_IE_APPLY, not Lk);
  AmsSetWndText(FValue, AmsDecodeText(E.Value));
end;

procedure TAmsIniEditor.ApplyValue;
var
  E: TAmsIniEntry;
  V: string;
begin
  if (FCurrent < 0) or (FCurrent >= FDoc.Count) or IsLocked(FCurrent) then Exit;
  E := FDoc.Entry(FCurrent);
  V := Encode(AmsGetWndText(FValue));
  if FDoc.SetValue(E.Section, E.Key, V) then
  begin
    FDirty := True;
    AmsListViewSetText(FList, FCurrent, 2, AmsDecodeText(V));
    UpdateTitle;
    SetStatus('Geändert: ' + AmsDecodeText(E.Key) + ' – noch nicht gespeichert');
  end;
end;

function TAmsIniEditor.TextFromEdit: Boolean;
var
  Before: string;
begin
  Before := FDoc.Text;
  FDoc.LoadFromText(Encode(AmsGetWndText(FText)));
  { BOM aus dem Original behalten }
  if AmsHasUtf8Bom(Before) then FDoc.HasBom := True;
  Result := FDoc.Text <> Before;
  if Result then FDirty := True;
end;

procedure TAmsIniEditor.ToggleText;
begin
  if FTextMode then
  begin
    TextFromEdit;
    FTextMode := False;
    ShowWindow(FText, SW_HIDE);
    ShowWindow(FList, SW_SHOW);
    ShowWindow(FDesc, SW_SHOW);
    ShowWindow(FValue, SW_SHOW);
    ShowWindow(GetDlgItem(FWnd, IDC_IE_APPLY), SW_SHOW);
    AmsSetWndText(GetDlgItem(FWnd, IDC_IE_TOGGLE), 'Als Text bearbeiten');
    FillList;
    UpdateTitle;
  end
  else
  begin
    ApplyValue;
    FTextMode := True;
    AmsSetWndText(FText, WideString(StringReplace(string(AmsDecodeText(FDoc.Text)),
                  #13#10, #10, [rfReplaceAll])));
    { EDIT braucht CRLF }
    AmsSetWndText(FText, AmsDecodeText(StringReplace(
      StringReplace(FDoc.Text, #13#10, #10, [rfReplaceAll]), #10, #13#10,
      [rfReplaceAll])));
    ShowWindow(FList, SW_HIDE);
    ShowWindow(FDesc, SW_HIDE);
    ShowWindow(FValue, SW_HIDE);
    ShowWindow(GetDlgItem(FWnd, IDC_IE_APPLY), SW_HIDE);
    ShowWindow(FText, SW_SHOW);
    AmsSetWndText(GetDlgItem(FWnd, IDC_IE_TOGGLE), 'Als Liste bearbeiten');
  end;
  Layout;
end;

function TAmsIniEditor.Save: Boolean;
var
  Data: string;
begin
  if FTextMode then TextFromEdit else ApplyValue;
  Data := FDoc.Text;
  AmsClearError;
  if Assigned(FOnSave) then Result := FOnSave(FFile, Data)
  else Result := AmsWriteFileRaw(FFile, Data);
  if Result then
  begin
    FDirty := False;
    UpdateTitle;
    SetStatus('Gespeichert.');
    if Assigned(FOnSaved) then FOnSaved(FFile);
  end
  else
  begin
    SetStatus('Nicht gespeichert: ' + WideString(AmsLastError));
    AmsTaskDialog(FWnd, 'Einstellungen', 'Speichern fehlgeschlagen',
                  WideString(AmsLastError), ['OK'], 0, diError);
  end;
end;

procedure TAmsIniEditor.Command(AId, ACode: Integer);
begin
  case AId of
    IDC_IE_APPLY:  ApplyValue;
    IDC_IE_TOGGLE: ToggleText;
    IDC_IE_SAVE:   Save;
    IDC_IE_CLOSE:  Close(False);
    IDC_IE_RELOAD:
      if not FDirty or (AmsTaskDialog(FWnd, 'Einstellungen',
           'Änderungen verwerfen?', 'Die Datei wird neu gelesen.',
           ['Verwerfen', 'Abbrechen'], 1, diWarning) = 0) then
      begin
        Reload;
        if FTextMode then
          AmsSetWndText(FText, AmsDecodeText(StringReplace(
            StringReplace(FDoc.Text, #13#10, #10, [rfReplaceAll]), #10,
            #13#10, [rfReplaceAll])));
      end;
    IDC_IE_TEXT:
      if (ACode = EN_CHANGE) and FTextMode and not FDirty then
      begin
        FDirty := True;
        UpdateTitle;
      end;
  end;
end;

procedure TAmsIniEditor.Notify(AHdr: Pointer);
var
  H: PAmsNmHdr;
  L: PAmsNmListView;
begin
  H := PAmsNmHdr(AHdr);
  if (H = nil) or (H^.hwndFrom <> FList) then Exit;
  if H^.code = AMS_LVN_ITEMCHANGED then
  begin
    L := PAmsNmListView(AHdr);
    if (L^.uNewState and 2 { LVIS_SELECTED }) <> 0 then
    begin
      if (FCurrent >= 0) and (FCurrent <> L^.iItem) then ApplyValue;
      SelectEntry(Integer(AmsListViewData(FList, L^.iItem)));
    end;
  end
  else if H^.code = AMS_NM_DBLCLK then
    SetFocus(FValue);
end;

function TAmsIniEditor.Open: Boolean;
begin
  if FWnd <> 0 then
  begin
    ShowWindow(FWnd, SW_RESTORE);
    SetForegroundWindow(FWnd);
    Exit(True);
  end;
  AmsInitCommonControls;
  EnsureClass;
  FWnd := CreateWindowExW(0, PWideChar(gClassW), '',
    WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT,
    820, 600, FOwner, 0, HInstance, Self);
  if FWnd = 0 then
    Exit(AmsFailFmt('Einstellungsfenster nicht erzeugbar (%d)', [GetLastError]));
  BuildControls;
  Reload;
  Layout;
  ShowWindow(FWnd, SW_SHOW);
  Result := True;
end;

function TAmsIniEditor.Close(AForce: Boolean): Boolean;
var
  R: Integer;
begin
  Result := True;
  if not AForce and FDirty and (FWnd <> 0) then
  begin
    R := AmsTaskDialog(FWnd, 'Einstellungen', 'Änderungen speichern?',
      WideString(FFile), ['Speichern', 'Nicht speichern', 'Abbrechen'], 0,
      diWarning);
    if (R = 2) or (R < 0) then Exit(False);
    if (R = 0) and not Save then Exit(False);
  end;
  Free;
end;

{ ------------------------------------------------------------- Verwaltung - }

function AmsIniEditorFind(const AFile: string): TAmsIniEditor;
var
  i: Integer;
begin
  Result := nil;
  if gEditors = nil then Exit;
  for i := 0 to gEditors.Count - 1 do
    if SameText(TAmsIniEditor(gEditors[i]).FFile, AFile) then
      Exit(TAmsIniEditor(gEditors[i]));
end;

function AmsIniEditorOpen(AOwner: HWND; const AFile: string;
  const ATitle: WideString; AOnSave: TAmsIniSaveEvent;
  AOnSaved: TAmsIniSavedEvent): TAmsIniEditor;
begin
  Result := AmsIniEditorFind(AFile);
  if Result = nil then
  begin
    Result := TAmsIniEditor.Create(AOwner, AFile, ATitle);
    Result.OnSave := AOnSave;
    Result.OnSaved := AOnSaved;
  end;
  if not Result.Open then
  begin
    Result.Free;
    Result := nil;
  end;
end;

procedure AmsIniEditorCloseAll;
begin
  if gEditors = nil then Exit;
  while gEditors.Count > 0 do
    TAmsIniEditor(gEditors[gEditors.Count - 1]).Free;
  DropClassIfUnused;
end;

function AmsIniEditorCount: Integer;
begin
  if gEditors = nil then Result := 0 else Result := gEditors.Count;
end;

finalization
  AmsIniEditorCloseAll;
  FreeAndNil(gEditors);

end.
