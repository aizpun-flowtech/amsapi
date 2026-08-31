program hosttest;

{ ============================================================================
  Testhost fuer AMS.5-Plugins - laedt ein BPL ohne AMS zu starten.

  Reproduziert den Ladeweg des Hosts:
      rtl<NNN>.bpl!Initialize     <- MUSS zuerst laufen, sonst
                                     EAccessViolation in den FastMM-Bins
      System.SysUtils.LoadPackage(<Plugin>.bpl)
      GetProcAddress(Modul, "PluginInit")  -> IPlugin
      IPlugin.SetPluginManager / Loaded / DoCommand / Unload

  Damit finden sich Ladefehler, fehlende Exporte und Abstuerze beim Init,
  OHNE AMS zu starten. Was hier NICHT geht: Ribbon-Einbau und Automatismen -
  dafuer muesste das AMS-Hauptformular existieren.

    hosttest build\deploy\HelloButton\HelloButton.bpl

  Ein Offscreen-Fenster bei -3200,-3200 dient als Nachrichtensenke, damit der
  Timer der Basisklasse laeuft und nichts auf dem Bildschirm aufblitzt.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils;

type
  TIntf = record Vtbl: PPointer; end;
  PIntf = ^TIntf;
  TPluginInit = procedure(AManager: Pointer; AResult: PPointer); register;
  TInitProc = procedure; register;
  TLoadPackage = function (AName: Pointer): HMODULE; register;
  TUnloadPackage = procedure(AModule: HMODULE); register;

const
  AMS_BIN = 'C:\Program Files (x86)\assfinet ams.5\BIN';
  DelphiHdr = 12;

{ In der FPC-Unit Windows nicht deklariert. }
function SetDllDirectoryW(APath: PWideChar): BOOL; stdcall;
  external 'kernel32' name 'SetDllDirectoryW';

var
  gRtl: HMODULE = 0;
  gErrors: Integer = 0;

function SizeOfFile(const AFile: string): Int64;
var
  R: TSearchRec;
begin
  Result := -1;
  if FindFirst(AFile, faAnyFile, R) = 0 then
  begin
    Result := R.Size;
    FindClose(R);
  end;
end;

procedure Say(const S: string);
begin
  WriteLn(S);
  Flush(Output);
end;

procedure Bad(const S: string);
begin
  Inc(gErrors);
  Say('  FEHLER: ' + S);
end;

{ Delphi-UnicodeString mit RefCount -1, wie in AmsApi.Strings. }
function CS(const S: UnicodeString): Pointer;
var
  P: PByte;
  N: Integer;
begin
  N := Length(S);
  P := GetMem(DelphiHdr + (N + 1) * 2);
  PWord(P)^ := 1200;
  PWord(P + 2)^ := 2;
  PInteger(P + 4)^ := -1;
  PInteger(P + 8)^ := N;
  if N > 0 then Move(S[1], (P + DelphiHdr)^, N * 2);
  PWord(P + DelphiHdr + N * 2)^ := 0;
  Result := P + DelphiHdr;
end;

function FindRtl(out AName: string): HMODULE;
const
  KNOWN: array[0..7] of string = ('230', '240', '250', '260', '270', '280',
                                  '290', '300');
var
  i: Integer;
begin
  Result := 0;
  for i := Low(KNOWN) to High(KNOWN) do
  begin
    AName := 'rtl' + KNOWN[i] + '.bpl';
    Result := LoadLibraryW(PWideChar(WideString(AName)));
    if Result <> 0 then Exit;
  end;
  AName := '';
end;

{ Vtable-Slot als Prozedur aufrufen. Die IPlugin-Reihenfolge:
    +00 QueryInterface +04 _AddRef +08 _Release
    +0C SetPluginManager +10 SetPluginItem +14 Loaded
    +18 UnloadQuery +1C Unload +20 DoCommand }
procedure CallSlot1(AIntf: Pointer; AOfs: Integer; AArg: Pointer);
type
  TProc1 = procedure(Self, A1: Pointer); register;
begin
  TProc1(PPointer(PtrUInt(PPointer(AIntf)^) + PtrUInt(AOfs))^)(AIntf, AArg);
end;

procedure CallSlot0(AIntf: Pointer; AOfs: Integer);
type
  TProc0 = procedure(Self: Pointer); register;
begin
  TProc0(PPointer(PtrUInt(PPointer(AIntf)^) + PtrUInt(AOfs))^)(AIntf);
end;

{ ACHTUNG: QueryInterface/_AddRef/_Release sind stdcall (COM-Konvention),
  die uebrigen IPlugin-Methoden register. Wer _Release als register aufruft,
  bekommt eine Stackkorruption und stirbt irgendwo spaeter. }
function CallRelease(AIntf: Pointer): Integer;
type
  TRel = function (Self: Pointer): Integer; stdcall;
begin
  Result := TRel(PPointer(PtrUInt(PPointer(AIntf)^) + 8)^)(AIntf);
end;

procedure CallDoCommand(AIntf: Pointer; ACmd: Integer; AData: Pointer);
type
  TProcC = procedure(Self: Pointer; ACmd: Integer; AData: Pointer); register;
begin
  TProcC(PPointer(PtrUInt(PPointer(AIntf)^) + $20)^)(AIntf, ACmd, AData);
end;

procedure Pump(AMilliseconds: Integer);
var
  Msg: TMsg;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(AMilliseconds);
  while GetTickCount64 < Deadline do
  begin
    while PeekMessageW(Msg, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(Msg);
      DispatchMessageW(Msg);
    end;
    Sleep(10);
  end;
end;

function SinkProc(H: HWND; Msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
begin
  Result := DefWindowProcW(H, Msg, wp, lp);
end;

function CreateSink: HWND;
var
  WC: WNDCLASSW;
begin
  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @SinkProc;
  WC.hInstance := HInstance;
  WC.lpszClassName := 'AmsHostTestSink';
  RegisterClassW(WC);
  { gross genug, damit AmsFindMainWindow es als "Hauptfenster" akzeptiert,
    aber weit ausserhalb des sichtbaren Bereichs }
  Result := CreateWindowExW(0, 'AmsHostTestSink', 'AmsApi Testhost',
    WS_OVERLAPPEDWINDOW or WS_VISIBLE, -3200, -3200, 900, 700,
    0, 0, HInstance, nil);
end;

var
  Bpl, Full, RtlName: string;
  LoadPkg: TLoadPackage;
  UnloadPkg: TUnloadPackage;
  InitProc: TInitProc;
  PluginInit: TPluginInit;
  Sink: HWND;
  Mod_: HMODULE;
  Intf: Pointer;

begin
  Say('AmsApi-Testhost');
  Say('===============');

  if ParamCount < 1 then
  begin
    Say('Aufruf: hosttest <pfad\zum\plugin.bpl>');
    Halt(2);
  end;
  Bpl := ParamStr(1);
  Full := ExpandFileName(Bpl);
  if not FileExists(Full) then
  begin
    Say('BPL nicht gefunden: ' + Full);
    Halt(2);
  end;
  Say('BPL: ' + Full);
  Say(Format('     %d Bytes, %s', [SizeOfFile(Full),
             DateTimeToStr(FileDateToDateTime(FileAge(Full)))]));

  { Host-Packages muessen auffindbar sein. }
  if not DirectoryExists(AMS_BIN) then
    Say('WARNUNG: ' + AMS_BIN + ' nicht vorhanden - ohne Host-Packages ' +
        'kann nur der Ladepfad geprueft werden.')
  else
    SetDllDirectoryW(PWideChar(WideString(AMS_BIN)));

  { 1. Delphi-RTL initialisieren. OHNE das stirbt alles Weitere im FastMM. }
  gRtl := FindRtl(RtlName);
  if gRtl = 0 then
  begin
    Bad('keine rtl<NNN>.bpl ladbar - AMS installiert?');
    Halt(1);
  end;
  Say('RTL: ' + RtlName);
  InitProc := TInitProc(GetProcAddress(gRtl, 'Initialize'));
  if not Assigned(InitProc) then
    Bad('rtl!Initialize fehlt')
  else
  begin
    InitProc;
    Say('  rtl!Initialize aufgerufen');
  end;

  LoadPkg := TLoadPackage(GetProcAddress(gRtl,
    '@System@Sysutils@LoadPackage$qqrx20System@UnicodeString'));
  UnloadPkg := TUnloadPackage(GetProcAddress(gRtl,
    '@System@Sysutils@UnloadPackage$qqrui'));
  if not Assigned(LoadPkg) then
  begin
    Bad('LoadPackage nicht in ' + RtlName);
    Halt(1);
  end;

  { 2. Nachrichtensenke, damit der Timer der Basisklasse feuern kann. }
  Sink := CreateSink;
  Say(Format('Nachrichtensenke: %p', [Pointer(Sink)]));

  { 3. Das Plugin ueber den echten LoadPackage-Pfad laden. }
  Mod_ := 0;
  try
    Mod_ := LoadPkg(CS(UnicodeString(Full)));
  except
    on E: Exception do Bad('LoadPackage EXCEPTION: ' + E.Message);
  end;
  if Mod_ = 0 then
  begin
    Bad('LoadPackage lieferte 0 - fehlt "Initialize" oder ein Import?');
    Halt(1);
  end;
  Say(Format('LoadPackage -> Modul %p', [Pointer(Mod_)]));

  { 4. PluginInit. EAX = Manager, EDX = @Result. }
  PluginInit := TPluginInit(GetProcAddress(Mod_, 'PluginInit'));
  if not Assigned(PluginInit) then
  begin
    Bad('Export "PluginInit" fehlt');
    Halt(1);
  end;
  Intf := nil;
  PluginInit(nil, @Intf);
  if Intf = nil then
  begin
    Bad('PluginInit lieferte nil');
    Halt(1);
  end;
  Say(Format('PluginInit -> IPlugin %p', [Intf]));

  { 5. Der Reihe nach wie der Host. }
  Say('SetPluginManager / SetPluginItem / Loaded');
  CallSlot1(Intf, $0C, nil);
  CallSlot1(Intf, $10, nil);
  CallSlot0(Intf, $14);

  Say('Nachrichten pumpen (4 s) - der Timer sucht das Hauptfenster');
  Pump(4000);

  Say('DoCommand(3 = pcInitBuSession, data=nil)');
  CallDoCommand(Intf, 3, nil);
  Pump(500);

  Say('Unload');
  CallSlot0(Intf, $1C);
  Say(Format('_Release -> Refcount %d', [CallRelease(Intf)]));
  Pump(300);

  if Assigned(UnloadPkg) then
  begin
    Say('UnloadPackage');
    try
      UnloadPkg(Mod_);
    except
      on E: Exception do Bad('UnloadPackage EXCEPTION: ' + E.Message);
    end;
  end;

  DestroyWindow(Sink);
  Say('');
  if gErrors = 0 then
  begin
    Say('ERGEBNIS: durchgelaufen, keine Fehler.');
    Say('Logdatei ansehen: %TEMP%\' +
        ChangeFileExt(ExtractFileName(Full), '.log'));
    Halt(0);
  end;
  Say(Format('ERGEBNIS: %d Fehler.', [gErrors]));
  Halt(1);
end.
