unit AmsApi.Strings;

{ ============================================================================
  AmsApi.Strings - Strings ueber die Modulgrenze

  DIE wichtigste Absturzursache bei FPC-Plugins in Delphi-Hosts: FPC und die
  Delphi-RTL haben getrennte Heaps. Gibt FPC einen String an Delphi und Delphi
  gibt ihn frei, ist das ein Absturz - oft erst viel spaeter und an ganz
  anderer Stelle.

  Loesung: wir bauen den Delphi-UnicodeString selbst und setzen den RefCount
  auf -1. Delphi behandelt das wie ein Konstantenliteral und fasst den Speicher
  nie an. Freigegeben wird ausschliesslich hier, beim Entladen des Plugins.

  Wiederholt benutzte Strings (Propertynamen wie "Caption") werden zwischen-
  gespeichert, damit ein Menuedurchlauf nicht bei jedem Eintrag neu alloziert.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{ Zeigerarithmetik ist hier die Aufgabe, nicht ein Versehen: VMT-Offsets und
  Delphi-Stringheader lassen sich nicht anders erreichen. Die beiden Hinweise
  dazu wuerden das Bauprotokoll nur zurauschen. }
{$WARN 4056 OFF}
{$WARN 4082 OFF}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types;

{ Delphi-UnicodeString-Zeiger fuer den Host. Der Zeiger bleibt bis zum
  Entladen des Plugins gueltig; er darf und muss nicht freigegeben werden. }
function AmsStr(const AValue: string): Pointer;
function AmsStrW(const AValue: UnicodeString): Pointer;

{ Einen vom Host gelieferten UnicodeString-Zeiger in einen FPC-String kopieren.
  Gibt den Host-String NICHT frei - dafuer ist AmsClearHostStr da. }
function AmsFromHostStr(APtr: Pointer): string;

{ Von Delphi allozierten String ueber die Delphi-RTL freigeben (UStrClr).
  AVar zeigt auf die Variable, die den Stringzeiger haelt. }
procedure AmsClearHostStr(AVar: PPointer);

{ Anzahl bisher angelegter Host-Strings - Diagnose. }
function AmsStrCount: Integer;

implementation

uses
  AmsApi.Bind;

const
  CACHE_MAX = 1024;

var
  gLock: TRTLCriticalSection;
  gReady: Boolean = False;
  gAll: TList = nil;            { alle Rohzeiger, fuer die Freigabe }
  gCache: TStringList = nil;    { sortiert: Text -> Zeiger als TObject }

function AllocHostStr(const AValue: UnicodeString): Pointer;
var
  P: PByte;
  N: Integer;
begin
  N := Length(AValue);
  P := GetMem(DelphiStrHeaderSize + (N + 1) * 2);
  PWord(P)^ := DelphiCodePageUtf16;         { CodePage }
  PWord(P + 2)^ := 2;                       { ElemSize }
  PInteger(P + 4)^ := -1;                   { RefCount: nie freigeben }
  PInteger(P + 8)^ := N;                    { Length   }
  if N > 0 then Move(AValue[1], (P + DelphiStrHeaderSize)^, N * 2);
  PWord(P + DelphiStrHeaderSize + N * 2)^ := 0;
  Result := P + DelphiStrHeaderSize;
end;

function AmsStrW(const AValue: UnicodeString): Pointer;
var
  Key: string;
  Idx: Integer;
  Raw: Pointer;
begin
  Result := nil;
  if not gReady then Exit(AllocHostStr(AValue));   { Notfall: ungecacht }
  Key := string(AValue);
  EnterCriticalSection(gLock);
  try
    if gCache.Find(Key, Idx) then
      Exit(Pointer(gCache.Objects[Idx]));
    Result := AllocHostStr(AValue);
    Raw := Pointer(PtrUInt(Result) - DelphiStrHeaderSize);
    gAll.Add(Raw);
    if gCache.Count < CACHE_MAX then
      gCache.AddObject(Key, TObject(Result));
  finally
    LeaveCriticalSection(gLock);
  end;
end;

function AmsStr(const AValue: string): Pointer;
begin
  Result := AmsStrW(UnicodeString(AValue));
end;

function AmsFromHostStr(APtr: Pointer): string;
var
  Len: Integer;
begin
  Result := '';
  if APtr = nil then Exit;
  try
    Len := PInteger(PtrUInt(APtr) - 4)^;   { StrRec.Length liegt 4 Byte davor }
    if (Len <= 0) or (Len > 1024 * 1024) then Exit;
    Result := string(WideCharLenToString(PWideChar(APtr), Len));
  except
    Result := '';
  end;
end;

procedure AmsClearHostStr(AVar: PPointer);
begin
  if (AVar = nil) or (AVar^ = nil) then Exit;
  if not Assigned(hcUStrClr) then
  begin
    AVar^ := nil;               { lieber lecken als in den falschen Heap fassen }
    Exit;
  end;
  try
    hcUStrClr(AVar);
  except
    AVar^ := nil;
  end;
end;

function AmsStrCount: Integer;
begin
  if not gReady then Exit(0);
  EnterCriticalSection(gLock);
  try
    Result := gAll.Count;
  finally
    LeaveCriticalSection(gLock);
  end;
end;

procedure FreeAllStrings;
var
  i: Integer;
  P: Pointer;
begin
  if gAll = nil then Exit;
  for i := 0 to gAll.Count - 1 do
  begin
    P := gAll[i];
    if P <> nil then FreeMem(P);
  end;
  gAll.Clear;
end;

initialization
  InitCriticalSection(gLock);
  gAll := TList.Create;
  gCache := TStringList.Create;
  gCache.CaseSensitive := True;
  gCache.Sorted := True;
  gCache.Duplicates := dupIgnore;
  gReady := True;

finalization
  gReady := False;
  { Der Host haelt diese Zeiger nur solange, wie er unsere Objekte haelt.
    Nach Finalize ist das Plugin ohnehin weg. }
  FreeAllStrings;
  FreeAndNil(gCache);
  FreeAndNil(gAll);
  DoneCriticalSection(gLock);

end.
