unit AmsApi.WinCtl;

{ ============================================================================
  AmsApi.WinCtl - Bausteine fuer VCL-freie Win32-Fenster

  Ein FPC-Plugin kann die VCL des Hosts nicht benutzen (getrennte Heaps,
  fremde RTL). Fenster entstehen deshalb aus den Standardklassen von
  Windows - wie das Verlaufsfenster und das Suchfenster. Was dabei immer
  wieder gebraucht wird, steht hier: Schriften, Kindfenster, Texte als
  WideString, und die ListView (SysListView32) mit Spalten, Symbolen und
  Auswahl - die fuer eine Liste mit Bildern und mehreren Spalten noetig ist.

  Die Schriften sind die des Systems (Meldungsschrift, also Segoe UI 9),
  einmal erzeugt und beim Entladen der Unit freigegeben.

  Ohne Host, ohne AMS nutzbar.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils;

const
  { Benachrichtigungen der ListView (LVN_*, NM_*) als Integer }
  AMS_LVN_ITEMCHANGED = -101;
  AMS_NM_DBLCLK       = -3;
  AMS_NM_RETURN       = -4;

type
  PAmsNmHdr = ^TAmsNmHdr;
  TAmsNmHdr = record
    hwndFrom: HWND;
    idFrom: UINT_PTR;
    code: Integer;
  end;

  PAmsNmListView = ^TAmsNmListView;
  TAmsNmListView = record
    hdr: TAmsNmHdr;
    iItem: Integer;
    iSubItem: Integer;
    uNewState: UINT;
    uOldState: UINT;
    uChanged: UINT;
    ptAction: TPoint;
    lParam: LPARAM;
  end;

procedure AmsInitCommonControls;

{ Systemschriften. Nicht freigeben - das macht die Unit. }
function AmsGuiFont: HFONT;
function AmsBoldFont: HFONT;
function AmsTitleFont: HFONT;
function AmsMonoFont: HFONT;

{ Kindfenster mit Schrift. }
function AmsCreateChild(AParent: HWND; const AClass, AText: WideString;
  AStyle: DWORD; AId: Integer; AFont: HFONT = 0; AExStyle: DWORD = 0): HWND;
procedure AmsSetWndText(AWnd: HWND; const AText: WideString);
function AmsGetWndText(AWnd: HWND): WideString;
{ Grauer Hinweistext in einem leeren Eingabefeld. }
procedure AmsSetCueBanner(AEdit: HWND; const AText: WideString);
procedure AmsEnableChild(AParent: HWND; AId: Integer; AEnabled: Boolean);

{ ----------------------------------------------------------------- ListView }

{ Berichtsansicht, eine Zeile waehlbar, ganze Zeile markiert. }
function AmsListViewCreate(AParent: HWND; AId: Integer;
  AGridLines: Boolean = False): HWND;
procedure AmsListViewAddColumn(ALv: HWND; const ACaption: WideString;
  AWidth: Integer);
procedure AmsListViewSetColumnWidth(ALv: HWND; ACol, AWidth: Integer);
{ Zeile anhaengen; ATexts[0] ist die erste Spalte. Liefert den Index. }
function AmsListViewAdd(ALv: HWND; const ATexts: array of WideString;
  AImage: Integer = -1; AData: LPARAM = 0): Integer;
procedure AmsListViewSetText(ALv: HWND; AItem, ASub: Integer;
  const AText: WideString);
function AmsListViewGetText(ALv: HWND; AItem, ASub: Integer): WideString;
function AmsListViewCount(ALv: HWND): Integer;
function AmsListViewSelected(ALv: HWND): Integer;
procedure AmsListViewSelect(ALv: HWND; AIndex: Integer);
function AmsListViewData(ALv: HWND; AIndex: Integer): LPARAM;
procedure AmsListViewClear(ALv: HWND);
{ Bildliste fuer die kleinen Symbole (LVSIL_SMALL). Liefert die alte. }
function AmsListViewSetImages(ALv: HWND; AList: THandle): THandle;

{ ------------------------------------------------------------- ImageList - }
function AmsImageListCreate(ASize, AInitial: Integer): THandle;
{ 32-Bit-Bitmap mit Alpha anhaengen. Die Bitmap bleibt beim Aufrufer. }
function AmsImageListAdd(AList: THandle; ABitmap: HBITMAP): Integer;
procedure AmsImageListDestroy(AList: THandle);

implementation

const
  ICC_LISTVIEW_CLASSES = $0001;
  ICC_STANDARD_CLASSES = $4000;

  LVM_FIRST                    = $1000;
  LVM_SETIMAGELIST             = LVM_FIRST + 3;
  LVM_GETITEMCOUNT             = LVM_FIRST + 4;
  LVM_DELETEALLITEMS           = LVM_FIRST + 9;
  LVM_GETNEXTITEM              = LVM_FIRST + 12;
  LVM_ENSUREVISIBLE            = LVM_FIRST + 19;
  LVM_SETCOLUMNWIDTH           = LVM_FIRST + 30;
  LVM_SETITEMSTATE             = LVM_FIRST + 43;
  LVM_SETEXTENDEDLISTVIEWSTYLE = LVM_FIRST + 54;
  LVM_GETITEMW                 = LVM_FIRST + 75;
  LVM_INSERTITEMW              = LVM_FIRST + 77;
  LVM_INSERTCOLUMNW            = LVM_FIRST + 97;
  LVM_GETITEMTEXTW             = LVM_FIRST + 115;
  LVM_SETITEMTEXTW             = LVM_FIRST + 116;

  LVS_REPORT          = $0001;
  LVS_SINGLESEL       = $0004;
  LVS_SHOWSELALWAYS   = $0008;
  LVS_NOSORTHEADER    = $8000;
  LVS_EX_GRIDLINES    = $00000001;
  LVS_EX_FULLROWSELECT = $00000020;
  LVS_EX_DOUBLEBUFFER = $00010000;

  LVIF_TEXT   = $0001;
  LVIF_IMAGE  = $0002;
  LVIF_PARAM  = $0004;
  LVIF_STATE  = $0008;
  LVIS_FOCUSED  = $0001;
  LVIS_SELECTED = $0002;
  LVNI_SELECTED = $0002;
  LVCF_WIDTH  = $0002;
  LVCF_TEXT   = $0004;
  LVSIL_SMALL = 1;

  EM_SETCUEBANNER = $1501;

  ILC_COLOR32 = $0020;
  CLEARTYPE_QUALITY = 5;

type
  TInitCC = record
    dwSize: DWORD;
    dwICC: DWORD;
  end;

  TLvColumnW = record
    mask: UINT;
    fmt: Integer;
    cx: Integer;
    pszText: PWideChar;
    cchTextMax: Integer;
    iSubItem: Integer;
    iImage: Integer;
    iOrder: Integer;
  end;

  TLvItemW = record
    mask: UINT;
    iItem: Integer;
    iSubItem: Integer;
    state: UINT;
    stateMask: UINT;
    pszText: PWideChar;
    cchTextMax: Integer;
    iImage: Integer;
    lParam: LPARAM;
    iIndent: Integer;
    iGroupId: Integer;
    cColumns: UINT;
    puColumns: PUINT;
    piColFmt: PInteger;
    iGroup: Integer;
  end;

function InitCommonControlsEx(var AInit: TInitCC): BOOL; stdcall;
  external 'comctl32.dll' name 'InitCommonControlsEx';
function ImageList_Create(cx, cy: Integer; flags: UINT;
  cInitial, cGrow: Integer): THandle; stdcall;
  external 'comctl32.dll' name 'ImageList_Create';
function ImageList_Add(himl: THandle; hbmImage, hbmMask: HBITMAP): Integer;
  stdcall; external 'comctl32.dll' name 'ImageList_Add';
function ImageList_Destroy(himl: THandle): BOOL; stdcall;
  external 'comctl32.dll' name 'ImageList_Destroy';

var
  gInit: Boolean = False;
  gGui: HFONT = 0;
  gBold: HFONT = 0;
  gTitle: HFONT = 0;
  gMono: HFONT = 0;

procedure AmsInitCommonControls;
var
  I: TInitCC;
begin
  if gInit then Exit;
  I.dwSize := SizeOf(I);
  I.dwICC := ICC_LISTVIEW_CLASSES or ICC_STANDARD_CLASSES;
  InitCommonControlsEx(I);
  gInit := True;
end;

type
  TNonClientMetricsW = record
    cbSize: UINT;
    iBorderWidth, iScrollWidth, iScrollHeight, iCaptionWidth,
    iCaptionHeight: Integer;
    lfCaptionFont: TLogFontW;
    iSmCaptionWidth, iSmCaptionHeight: Integer;
    lfSmCaptionFont: TLogFontW;
    iMenuWidth, iMenuHeight: Integer;
    lfMenuFont: TLogFontW;
    lfStatusFont: TLogFontW;
    lfMessageFont: TLogFontW;
  end;

function MessageLogFont(out ALf: TLogFontW): Boolean;
var
  M: TNonClientMetricsW;
begin
  FillChar(M, SizeOf(M), 0);
  M.cbSize := SizeOf(M);
  Result := SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, SizeOf(M), @M, 0);
  if Result then ALf := M.lfMessageFont
  else FillChar(ALf, SizeOf(ALf), 0);
end;

function MakeFont(AScale100, AWeight: Integer): HFONT;
var
  Lf: TLogFontW;
begin
  if not MessageLogFont(Lf) then
  begin
    Lf.lfHeight := -12;
    Lf.lfCharSet := DEFAULT_CHARSET;
    Move(PWideChar(WideString('Segoe UI'))^, Lf.lfFaceName[0], 9 * 2);
  end;
  Lf.lfHeight := (Lf.lfHeight * AScale100) div 100;
  if AWeight <> 0 then Lf.lfWeight := AWeight;
  Lf.lfQuality := CLEARTYPE_QUALITY;
  Result := CreateFontIndirectW(Lf);
  if Result = 0 then Result := HFONT(GetStockObject(DEFAULT_GUI_FONT));
end;

function AmsGuiFont: HFONT;
begin
  if gGui = 0 then gGui := MakeFont(100, 0);
  Result := gGui;
end;

function AmsBoldFont: HFONT;
begin
  if gBold = 0 then gBold := MakeFont(100, FW_SEMIBOLD);
  Result := gBold;
end;

function AmsTitleFont: HFONT;
begin
  if gTitle = 0 then gTitle := MakeFont(150, FW_SEMIBOLD);
  Result := gTitle;
end;

function AmsMonoFont: HFONT;
begin
  if gMono = 0 then
    gMono := CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
      FIXED_PITCH or FF_MODERN, 'Consolas');
  Result := gMono;
end;

function AmsCreateChild(AParent: HWND; const AClass, AText: WideString;
  AStyle: DWORD; AId: Integer; AFont: HFONT; AExStyle: DWORD): HWND;
begin
  Result := CreateWindowExW(AExStyle, PWideChar(AClass), PWideChar(AText),
    WS_CHILD or WS_VISIBLE or AStyle, 0, 0, 10, 10, AParent, HMENU(AId),
    HInstance, nil);
  if Result = 0 then Exit;
  if AFont = 0 then AFont := AmsGuiFont;
  SendMessageW(Result, WM_SETFONT, WPARAM(AFont), 1);
end;

procedure AmsSetWndText(AWnd: HWND; const AText: WideString);
begin
  if AWnd <> 0 then SetWindowTextW(AWnd, PWideChar(AText));
end;

function AmsGetWndText(AWnd: HWND): WideString;
var
  n: Integer;
begin
  Result := '';
  if AWnd = 0 then Exit;
  n := GetWindowTextLengthW(AWnd);
  if n <= 0 then Exit;
  SetLength(Result, n + 1);
  n := GetWindowTextW(AWnd, PWideChar(Result), n + 1);
  SetLength(Result, n);
end;

procedure AmsSetCueBanner(AEdit: HWND; const AText: WideString);
begin
  SendMessageW(AEdit, EM_SETCUEBANNER, 1, LPARAM(PWideChar(AText)));
end;

procedure AmsEnableChild(AParent: HWND; AId: Integer; AEnabled: Boolean);
begin
  EnableWindow(GetDlgItem(AParent, AId), AEnabled);
end;

{ ----------------------------------------------------------------- ListView }

function AmsListViewCreate(AParent: HWND; AId: Integer;
  AGridLines: Boolean): HWND;
var
  Ex: DWORD;
begin
  AmsInitCommonControls;
  Result := AmsCreateChild(AParent, 'SysListView32', '',
    WS_TABSTOP or WS_BORDER or LVS_REPORT or LVS_SINGLESEL or
    LVS_SHOWSELALWAYS or LVS_NOSORTHEADER, AId);
  if Result = 0 then Exit;
  Ex := LVS_EX_FULLROWSELECT or LVS_EX_DOUBLEBUFFER;
  if AGridLines then Ex := Ex or LVS_EX_GRIDLINES;
  SendMessageW(Result, LVM_SETEXTENDEDLISTVIEWSTYLE, Ex, Ex);
end;

procedure AmsListViewAddColumn(ALv: HWND; const ACaption: WideString;
  AWidth: Integer);
var
  C: TLvColumnW;
  n: Integer;
begin
  FillChar(C, SizeOf(C), 0);
  C.mask := LVCF_TEXT or LVCF_WIDTH;
  C.cx := AWidth;
  C.pszText := PWideChar(ACaption);
  { Anzahl der Spalten = Anzahl der Header-Elemente }
  n := SendMessageW(SendMessageW(ALv, LVM_FIRST + 31 { LVM_GETHEADER }, 0, 0),
                    $1200 { HDM_GETITEMCOUNT }, 0, 0);
  if n < 0 then n := 0;
  SendMessageW(ALv, LVM_INSERTCOLUMNW, n, LPARAM(@C));
end;

procedure AmsListViewSetColumnWidth(ALv: HWND; ACol, AWidth: Integer);
begin
  SendMessageW(ALv, LVM_SETCOLUMNWIDTH, ACol, AWidth);
end;

function AmsListViewAdd(ALv: HWND; const ATexts: array of WideString;
  AImage: Integer; AData: LPARAM): Integer;
var
  It: TLvItemW;
  i: Integer;
  T: WideString;
begin
  FillChar(It, SizeOf(It), 0);
  It.mask := LVIF_TEXT or LVIF_PARAM;
  if AImage >= 0 then It.mask := It.mask or LVIF_IMAGE;
  It.iItem := MaxInt;
  if Length(ATexts) > 0 then T := ATexts[0] else T := '';
  It.pszText := PWideChar(T);
  It.iImage := AImage;
  It.lParam := AData;
  Result := SendMessageW(ALv, LVM_INSERTITEMW, 0, LPARAM(@It));
  if Result < 0 then Exit;
  for i := 1 to High(ATexts) do
    AmsListViewSetText(ALv, Result, i, ATexts[i]);
end;

procedure AmsListViewSetText(ALv: HWND; AItem, ASub: Integer;
  const AText: WideString);
var
  It: TLvItemW;
begin
  FillChar(It, SizeOf(It), 0);
  It.iSubItem := ASub;
  It.pszText := PWideChar(AText);
  SendMessageW(ALv, LVM_SETITEMTEXTW, AItem, LPARAM(@It));
end;

function AmsListViewGetText(ALv: HWND; AItem, ASub: Integer): WideString;
var
  It: TLvItemW;
  Buf: array[0..1023] of WideChar;
  n: Integer;
begin
  FillChar(It, SizeOf(It), 0);
  Buf[0] := #0;
  It.iSubItem := ASub;
  It.pszText := @Buf[0];
  It.cchTextMax := Length(Buf);
  n := SendMessageW(ALv, LVM_GETITEMTEXTW, AItem, LPARAM(@It));
  SetString(Result, PWideChar(@Buf[0]), n);
end;

function AmsListViewCount(ALv: HWND): Integer;
begin
  Result := SendMessageW(ALv, LVM_GETITEMCOUNT, 0, 0);
end;

function AmsListViewSelected(ALv: HWND): Integer;
begin
  Result := SendMessageW(ALv, LVM_GETNEXTITEM, WPARAM(-1), LVNI_SELECTED);
end;

procedure AmsListViewSelect(ALv: HWND; AIndex: Integer);
var
  It: TLvItemW;
begin
  FillChar(It, SizeOf(It), 0);
  It.stateMask := LVIS_SELECTED or LVIS_FOCUSED;
  if AIndex >= 0 then
  begin
    It.state := LVIS_SELECTED or LVIS_FOCUSED;
    SendMessageW(ALv, LVM_SETITEMSTATE, AIndex, LPARAM(@It));
    SendMessageW(ALv, LVM_ENSUREVISIBLE, AIndex, 0);
  end
  else
    SendMessageW(ALv, LVM_SETITEMSTATE, WPARAM(-1), LPARAM(@It));
end;

function AmsListViewData(ALv: HWND; AIndex: Integer): LPARAM;
var
  It: TLvItemW;
begin
  Result := 0;
  if AIndex < 0 then Exit;
  FillChar(It, SizeOf(It), 0);
  It.mask := LVIF_PARAM;
  It.iItem := AIndex;
  if SendMessageW(ALv, LVM_GETITEMW, 0, LPARAM(@It)) <> 0 then
    Result := It.lParam;
end;

procedure AmsListViewClear(ALv: HWND);
begin
  SendMessageW(ALv, LVM_DELETEALLITEMS, 0, 0);
end;

function AmsListViewSetImages(ALv: HWND; AList: THandle): THandle;
begin
  Result := THandle(SendMessageW(ALv, LVM_SETIMAGELIST, LVSIL_SMALL,
                                 LPARAM(AList)));
end;

{ ------------------------------------------------------------- ImageList - }

function AmsImageListCreate(ASize, AInitial: Integer): THandle;
begin
  AmsInitCommonControls;
  Result := ImageList_Create(ASize, ASize, ILC_COLOR32, AInitial, 8);
end;

function AmsImageListAdd(AList: THandle; ABitmap: HBITMAP): Integer;
begin
  Result := -1;
  if (AList = 0) or (ABitmap = 0) then Exit;
  Result := ImageList_Add(AList, ABitmap, 0);
end;

procedure AmsImageListDestroy(AList: THandle);
begin
  if AList <> 0 then ImageList_Destroy(AList);
end;

finalization
  if gGui <> 0 then DeleteObject(gGui);
  if gBold <> 0 then DeleteObject(gBold);
  if gTitle <> 0 then DeleteObject(gTitle);
  if gMono <> 0 then DeleteObject(gMono);

end.
