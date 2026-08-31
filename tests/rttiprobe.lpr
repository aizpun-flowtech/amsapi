program rttiprobe;

{ ============================================================================
  Prueft AmsApi.Props gegen die ECHTE Delphi-RTTI der Host-Packages.

  Die Offsets in TTypeInfo, TTypeData und TPropInfo sind aus der Delphi-Quelle
  abgeleitet. Ob sie stimmen, sieht man nicht am Uebersetzen und auch nicht an
  einem Unit-Test ohne Host - nur an echten Typinformationen. Genau dafuer ist
  dieses Programm da.

  Es braucht AMS NICHT laufend, nur installiert: rtl<NNN>.bpl und vcl<NNN>.bpl
  werden geladen und ausschliesslich GELESEN. Es wird kein Objekt erzeugt und
  keine Eigenschaft geschrieben - als "Instanz" dient ein Zeiger auf den
  Klassenzeiger, denn die RTTI haengt an der Klasse, nicht am Objekt. Alles,
  was hier geprueft wird, kommt ohne Instanz aus.

  Ohne AMS-Installation endet der Lauf mit "uebersprungen" und Rueckgabe 0.

  Rueckgabe: Anzahl der Fehlschlaege.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, Classes,
  AmsApi.Types, AmsApi.Bind, AmsApi.Props, AmsApi.Log;

const
  AMS_BIN = 'C:\Program Files (x86)\assfinet ams.5\BIN';

type
  TInitProc = procedure; register;

function SetDllDirectoryW(APath: PWideChar): BOOL; stdcall;
  external 'kernel32' name 'SetDllDirectoryW';

var
  gRun: Integer = 0;
  gFail: Integer = 0;
  { Haelt die Klassenzeiger. Die Adresse EINES Eintrags sieht fuer die RTTI
    aus wie eine Instanz: an Offset 0 steht der Klassenzeiger. }
  gFake: array[0..3] of Pointer;

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

function Fake(AIndex: Integer; AClass: Pointer): Pointer;
begin
  gFake[AIndex] := AClass;
  Result := @gFake[AIndex];
end;

{ rtl<NNN>.bpl laden und initialisieren - ohne das stirbt jeder weitere
  Aufruf in den FastMM-Bins. Derselbe Weg wie in hosttest.lpr. }
function LoadRtl: Boolean;
const
  KNOWN: array[0..3] of string = ('230', '240', '250', '260');
var
  i: Integer;
  H: HMODULE;
  Init: TInitProc;
begin
  Result := False;
  for i := Low(KNOWN) to High(KNOWN) do
  begin
    H := LoadLibraryW(PWideChar(WideString('rtl' + KNOWN[i] + '.bpl')));
    if H = 0 then Continue;
    Init := TInitProc(GetProcAddress(H, 'Initialize'));
    if not Assigned(Init) then Continue;
    Init;
    Exit(True);
  end;
end;

procedure TestComponentRtti;
var
  Cls, Obj: Pointer;
  Props: TAmsPropArray;
  i, n, Found: Integer;
begin
  Section('TComponent - Grundaufbau von TPropInfo');
  Cls := AmsSym(MOD_RTL, '@System@Classes@TComponent@');
  Check('Klassenzeiger TComponent aus dem Package', Cls <> nil);
  if Cls = nil then Exit;
  Obj := Fake(0, Cls);

  { Faende AmsHasProp hier nichts, waeren entweder vmtTypeInfo (-72) oder
    die Laenge des Typnamens vor TTypeData falsch. }
  Check('published property "Name" gefunden', AmsHasProp(Obj, 'Name'));
  Check('published property "Tag" gefunden', AmsHasProp(Obj, 'Tag'));
  Check('erfundene Eigenschaft wird nicht gefunden',
        not AmsHasProp(Obj, 'GibtEsNicht'));

  { Die Typart kommt aus PropType^^.Kind - stimmt ofsPropType nicht, ist sie
    Unsinn. }
  Check('"Name" ist ein Text', AmsPropKindOf(Obj, 'Name') = pkString,
        AmsKindName(AmsPropKindOf(Obj, 'Name')));
  Check('"Tag" ist eine Zahl', AmsPropKindOf(Obj, 'Tag') = pkInteger,
        AmsKindName(AmsPropKindOf(Obj, 'Tag')));
  Check('Typname von "Name" ist gefuellt', AmsPropTypeName(Obj, 'Name') <> '',
        AmsPropTypeName(Obj, 'Name'));

  { SetProc <> nil - beide sind schreibbar. }
  Check('"Name" ist schreibbar', AmsPropWritable(Obj, 'Name'));
  Check('"Tag" ist schreibbar', AmsPropWritable(Obj, 'Tag'));

  { GetPropInfos fuellt das vom Aufrufer gelieferte Array. Kommen hier die
    richtigen Namen heraus, stimmen PropCount-Offset UND ofsPropName. }
  n := AmsPropList(Obj, Props, False);
  Check('Eigenschaftsliste nicht leer', n >= 2, IntToStr(n));
  Found := 0;
  for i := 0 to n - 1 do
  begin
    if SameText(Props[i].Name, 'Name') then Inc(Found);
    if SameText(Props[i].Name, 'Tag') then Inc(Found);
    Check('  Name aus der Liste ist lesbar', Props[i].Name <> '');
  end;
  Check('Name und Tag stehen in der Liste', Found = 2, IntToStr(Found));
end;

procedure TestFontRtti;
var
  H: HMODULE;
  Cls, Obj: Pointer;
  Opt: string;
begin
  Section('TFont - Aufzaehlungen, Mengen und Farben');
  H := LoadLibraryW(PWideChar(WideString('vcl' + AmsHostSuffix + '.bpl')));
  if H = 0 then
  begin
    WriteLn('  (vcl', AmsHostSuffix, '.bpl nicht ladbar - uebersprungen)');
    Exit;
  end;
  Cls := AmsSym(MOD_VCL, '@Vcl@Graphics@TFont@');
  Check('Klassenzeiger TFont aus dem Package', Cls <> nil);
  if Cls = nil then Exit;
  Obj := Fake(1, Cls);

  Check('"Style" ist eine Menge', AmsPropKindOf(Obj, 'Style') = pkSet,
        AmsKindName(AmsPropKindOf(Obj, 'Style')));
  Check('"Pitch" ist eine Auswahl', AmsPropKindOf(Obj, 'Pitch') = pkEnum,
        AmsKindName(AmsPropKindOf(Obj, 'Pitch')));
  Check('"Size" ist eine Zahl', AmsPropKindOf(Obj, 'Size') = pkInteger);
  CheckEq('Typname von "Color"', 'TColor', AmsPropTypeName(Obj, 'Color'));

  { Die erlaubten Werte kommen aus der NameList im TTypeData der
    Aufzaehlung. Stimmt ofsEnumNameList nicht, steht hier Muell. }
  Opt := AmsPropOptions(Obj, 'Style');
  CheckEq('erlaubte Werte von "Style"',
          'fsBold|fsItalic|fsUnderline|fsStrikeOut', Opt);
  Opt := AmsPropOptions(Obj, 'Pitch');
  CheckEq('erlaubte Werte von "Pitch"', 'fpDefault|fpVariable|fpFixed', Opt);
  Check('eine Zahl hat keine Werteliste', AmsPropOptions(Obj, 'Size') = '');
end;

begin
  AmsSetLogFile(IncludeTrailingPathDelimiter(GetTempDir) + 'amsapi_rttiprobe.log');
  WriteLn('AmsApi ', AMS_API_VERSION, ' - RTTI gegen die Host-Packages');
  WriteLn('==============================================');

  if DirectoryExists(AMS_BIN) then
    SetDllDirectoryW(PWideChar(WideString(AMS_BIN)))
  else
    WriteLn('Hinweis: ', AMS_BIN, ' nicht vorhanden.');

  if not LoadRtl then
  begin
    WriteLn;
    WriteLn('Keine Delphi-RTL ladbar - Probe uebersprungen (kein Fehler).');
    Halt(0);
  end;
  WriteLn('RTL geladen, Suffix "', AmsHostSuffix, '" (', AmsHostDelphiName, ')');

  if not AmsBindProps then
  begin
    WriteLn;
    WriteLn('RTTI-Symbole nicht gebunden:');
    WriteLn(AmsBindReport);
    Halt(1);
  end;

  TestComponentRtti;
  TestFontRtti;

  WriteLn;
  WriteLn(Format('%d Pruefungen, %d Fehlschlaege.', [gRun, gFail]));
  if gFail = 0 then WriteLn('ALLES GRUEN.') else WriteLn('FEHLGESCHLAGEN.');
  Halt(gFail);
end.
