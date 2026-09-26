unit AmsApi.Props;

{ ============================================================================
  AmsApi.Props - published properties: finden, lesen, schreiben, zuruecknehmen

  AmsApi.Rtti kann eine Eigenschaft lesen und schreiben, WENN man Name und Typ
  schon kennt. Diese Unit beantwortet die Frage davor: welche Eigenschaften hat
  dieses Element ueberhaupt, welchen Typ haben sie, sind sie schreibbar, und
  welche Werte sind erlaubt. Damit laesst sich ein fremdes Host-Element
  bearbeiten, ohne seinen Quelltext zu kennen.

  Drei Dinge machen die Unit aus:

  1. PFADE. "Font.Size" oder "Glyph.Transparent" wird ueber GetObjectProp
     aufgeloest. Ohne das kaeme man an eine Schriftgroesse gar nicht heran.

  2. KLARTEXT. Jede Eigenschaft laesst sich als Text lesen und setzen -
     Zahlen, Aufzaehlungen ("ivNever"), Mengen ("[fsBold,fsItalic]"), Farben
     ("clRed", "#FF8800", "$0088FF"). Erst das macht Konfiguration aus einer
     plugin.ini moeglich.

  3. RUECKNAHME. Jede Aenderung wird mit ihrem alten Wert mitgeschrieben.
     AmsUndoAll stellt den Ausgangszustand wieder her. Beim Entladen ist das
     PFLICHT: ein Plugin, das eine Schaltflaeche des Hosts deaktiviert und
     dann verschwindet, wuerde AMS beschaedigt zuruecklassen.

  Grundlage ist die Delphi-RTTI; die Offsets stehen in AmsApi.Types. Bewusst
  NICHT benutzt wird GetPropList: das alloziert im Delphi-Heap und der
  Aufrufer muesste dort freigeben. GetPropInfos fuellt ein Array, das wir
  selbst besitzen - kein fremder Heap, kein Absturz.

  Alles gehoert in den UI-Thread des Hosts, wie jeder Zugriff auf die VCL.
  ============================================================================ }

{$MODE DELPHI}
{$H+}
{ Zeigerarithmetik ist hier die Aufgabe, nicht ein Versehen: RTTI-Records sind
  packed und lassen sich nicht anders lesen. }
{$WARN 4056 OFF}
{$WARN 4082 OFF}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types;

type
  { Zusammengefasste Typart einer Eigenschaft. Die Delphi-TTypeKind-Werte sind
    feiner; fuer die Bearbeitung zaehlt nur, WIE ein Wert gesetzt werden muss. }
  TAmsPropKind = (pkNone, pkInteger, pkChar, pkEnum, pkFloat, pkString,
                  pkSet, pkClass, pkMethod, pkInt64, pkOther);

  TAmsProp = record
    Name: string;
    TypeName: string;      { Delphi-Typname, z.B. "TdxBarItemVisible" }
    Kind: TAmsPropKind;
    Writable: Boolean;     { False = nur lesbar (SetProc fehlt) }
    Value: string;         { nur gefuellt, wenn mit Werten angefordert }
  end;
  TAmsPropArray = array of TAmsProp;

var
  { Jede Aenderung ueber AmsSetProp wird mitgeschrieben, damit AmsUndoAll sie
    zuruecknehmen kann. Nur abschalten, wenn eine Aenderung ausdruecklich
    dauerhaft bleiben soll. }
  AmsRecordChanges: Boolean = True;

{ ------------------------------------------------------------- Auskunft ---- }

{ Hat das Element diese Eigenschaft? APath darf ein Pfad sein ("Font.Size"). }
function AmsHasProp(AObj: Pointer; const APath: string): Boolean;

function AmsPropKindOf(AObj: Pointer; const APath: string): TAmsPropKind;
function AmsPropTypeName(AObj: Pointer; const APath: string): string;
function AmsPropWritable(AObj: Pointer; const APath: string): Boolean;

{ Wird beim Schreiben unmittelbar ein Feld gefuellt, statt eine Methode zu
  rufen? Wichtig beim KOPIEREN von Objekteigenschaften: eine Setzmethode
  macht dort in aller Regel Assign und legt eine echte Kopie an, ein Feld
  wuerde nur den Zeiger uebernehmen. Wer eine solche Eigenschaft trotzdem
  kopiert, hat zwei Elemente mit derselben Schrift - und einen Absturz,
  sobald das erste sie freigibt. }
function AmsPropWritesField(AObj: Pointer; const APath: string): Boolean;

{ Erlaubte Werte einer Aufzaehlung oder Menge, mit "|" getrennt. Leer bei
  allen anderen Typen. Genau das gehoert in eine Fehlermeldung. }
function AmsPropOptions(AObj: Pointer; const APath: string): string;

{ Deutscher Name der Typart - fuer Ausgaben. }
function AmsKindName(AKind: TAmsPropKind): string;

{ Alle published properties des Elements, einschliesslich geerbter.
  AWithValues = False laesst das Lesen der Werte weg (deutlich schneller). }
function AmsPropList(AObj: Pointer; var AProps: TAmsPropArray;
  AWithValues: Boolean = True): Integer;

{ Eigenschaftsliste als lesbarer Block - die Antwort auf "was kann ich an
  diesem Element ueberhaupt aendern". }
procedure AmsDumpProps(AObj: Pointer; ADest: TStrings;
  AWithValues: Boolean = True);

{ ------------------------------------------------------------ Pfadzugriff -- }

{ "Font.Size" -> Objekt der Schrift, ALeaf = "Size". Liefert nil, wenn ein
  Glied des Pfades fehlt oder kein Objekt ist. }
function AmsPropOwner(AObj: Pointer; const APath: string;
  out ALeaf: string): Pointer;

{ ------------------------------------------------------- Lesen / Schreiben - }

{ Jede Eigenschaft als Text. Leer bei nicht lesbaren Typen (Gleitkomma,
  Int64, Variant); die Ursache steht dann in AmsLastError. }
function AmsGetProp(AObj: Pointer; const APath: string): string;

{ Jede Eigenschaft aus Text setzen. Die Umwandlung richtet sich nach dem
  RTTI-Typ:
    Zahl        "42", "$FF", "0x1F", "#FF8800", "clRed"
    Text        wie angegeben
    Aufzaehlung "ivNever" oder "0"; bei Boolean auch "ja"/"nein"/"an"/"aus"
    Menge       "[fsBold,fsItalic]" oder "fsBold,fsItalic", "[]" = leer
  Objekte und Ereignisse lassen sich nicht aus Text setzen. }
function AmsSetProp(AObj: Pointer; const APath, AValue: string): Boolean;

function AmsGetPropInt(AObj: Pointer; const APath: string;
  ADefault: Integer = 0): Integer;
function AmsSetPropInt(AObj: Pointer; const APath: string;
  AValue: Integer): Boolean;
function AmsGetPropBool(AObj: Pointer; const APath: string;
  ADefault: Boolean = False): Boolean;
function AmsSetPropBool(AObj: Pointer; const APath: string;
  AValue: Boolean): Boolean;
function AmsGetPropText(AObj: Pointer; const APath: string): string;
function AmsSetPropText(AObj: Pointer; const APath, AValue: string): Boolean;
function AmsGetPropObject(AObj: Pointer; const APath: string): Pointer;
function AmsGetPropMethod(AObj: Pointer; const APath: string;
  out AMethod: TDelphiMethod): Boolean;
function AmsSetPropMethod(AObj: Pointer; const APath: string;
  const AMethod: TDelphiMethod): Boolean;

{ Komponente wirklich umbenennen (TComponent.Name). Getrennt von AmsSetProp,
  weil der Host seine Komponenten ueber genau diesen Namen wiederfindet: ein
  Tippfehler in einer INI darf das nicht koennen. }
function AmsRenameComponent(AObj: Pointer; const ANewName: string): Boolean;

{ ---------------------------------------------------- Zahlen und Farben --- }

{ "42", "-1", "$0088FF", "0x00650E98". Auch fuer Fensterhandles brauchbar,
  wie sie AutoIt Window Info oder Spy++ anzeigen. }
function AmsIntFromText(const AText: string; out AValue: Integer): Boolean;

{ Wie AmsIntFromText, zusaetzlich "clRed" und 29 weitere Namen sowie
  "#FF8800" (Web-RGB). TColor ist $00BBGGRR - "#RRGGBB" wird gedreht. }
function AmsColorFromText(const AText: string; out AColor: Integer): Boolean;
function AmsColorToText(AColor: Integer): string;

{ ------------------------------------------------------ Aenderungsjournal -- }

function AmsChangeCount: Integer;
procedure AmsDumpChanges(ADest: TStrings);

{ Alles zuruecknehmen, in umgekehrter Reihenfolge. Liefert die Zahl der
  wiederhergestellten Eigenschaften. Gehoert in das Entladen des Plugins. }
function AmsUndoAll: Integer;

{ Nur die Aenderungen an einem Element zuruecknehmen. }
function AmsUndoObject(AObj: Pointer): Integer;

{ Journal verwerfen, ohne etwas zurueckzunehmen - die Aenderungen bleiben
  dann dauerhaft stehen. }
procedure AmsForgetChanges;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Log;

const
  MAX_PROPS = 2000;         { mehr hat keine VCL-Klasse }
  MAX_CHANGES = 512;

type
  TPtrArray = array[0..MAX_PROPS - 1] of Pointer;
  PPtrArray = ^TPtrArray;

{ ------------------------------------------------------------ RTTI-Leser --- }

function ShortStr(AP: PByte): string;
begin
  Result := '';
  if AP = nil then Exit;
  try
    SetString(Result, PAnsiChar(AP + 1), AP^);
  except
    Result := '';
  end;
end;

{ PTypeInfo der Klasse eines Objekts: VMT-72. }
function ClassTypeInfo(AObj: Pointer): Pointer;
begin
  Result := nil;
  if AObj = nil then Exit;
  try
    { ueber PByte rechnen: vmtTypeInfo ist negativ, und ein vorzeichen-
      behafteter Zeigerkast wuerde nur eine Warnung einbringen }
    Result := PPointer(PByte(PPointer(AObj)^) + vmtTypeInfo)^;
  except
    Result := nil;
  end;
end;

function TypeKindOf(ATi: Pointer): Integer;
begin
  Result := tkUnknown;
  if ATi = nil then Exit;
  try
    Result := PByte(PtrUInt(ATi) + ofsTypeKind)^;
  except
    Result := tkUnknown;
  end;
end;

function TypeNameOf(ATi: Pointer): string;
begin
  Result := '';
  if ATi = nil then Exit;
  Result := ShortStr(PByte(PtrUInt(ATi) + ofsTypeName));
end;

{ TTypeData beginnt hinter Kind und dem laengenpraefixierten Namen. }
function TypeDataOf(ATi: Pointer): PByte;
begin
  Result := nil;
  if ATi = nil then Exit;
  try
    Result := PByte(PtrUInt(ATi) + 2 + PByte(PtrUInt(ATi) + ofsTypeName)^);
  except
    Result := nil;
  end;
end;

function MapKind(ATypeKind: Integer): TAmsPropKind;
begin
  case ATypeKind of
    tkInteger: Result := pkInteger;
    tkChar, tkWChar: Result := pkChar;
    tkEnumeration: Result := pkEnum;
    tkFloat: Result := pkFloat;
    tkString, tkLString, tkWString, tkUString: Result := pkString;
    tkSet: Result := pkSet;
    tkClass: Result := pkClass;
    tkMethod: Result := pkMethod;
    tkInt64: Result := pkInt64;
    tkUnknown: Result := pkNone;
  else
    Result := pkOther;
  end;
end;

function AmsKindName(AKind: TAmsPropKind): string;
begin
  case AKind of
    pkInteger: Result := 'Zahl';
    pkChar: Result := 'Zeichen';
    pkEnum: Result := 'Auswahl';
    pkFloat: Result := 'Gleitkomma';
    pkString: Result := 'Text';
    pkSet: Result := 'Menge';
    pkClass: Result := 'Objekt';
    pkMethod: Result := 'Ereignis';
    pkInt64: Result := 'Int64';
    pkOther: Result := 'sonstiges';
  else
    Result := 'keine';
  end;
end;

{ PPropInfo einer EINZELNEN Eigenschaft (kein Pfad). GetPropInfo laeuft die
  Vorfahrenkette selbst hoch - geerbte Eigenschaften werden gefunden. }
function PropInfoOf(AObj: Pointer; const AProp: string): Pointer;
var
  Ti: Pointer;
begin
  Result := nil;
  if (AObj = nil) or (AProp = '') then Exit;
  if not AmsBindProps then Exit;
  Ti := ClassTypeInfo(AObj);
  if (Ti = nil) or (TypeKindOf(Ti) <> tkClass) then Exit;
  try
    Result := hcGetPropInfo(Ti, AmsStr(AProp));
  except
    Result := nil;
  end;
end;

function PropTypeInfo(APropInfo: Pointer): Pointer;
var
  PP: PPointer;
begin
  Result := nil;
  if APropInfo = nil then Exit;
  try
    PP := PPointer(PtrUInt(APropInfo) + ofsPropType)^;   { PPTypeInfo }
    if PP <> nil then Result := PP^;
  except
    Result := nil;
  end;
end;

function PropIsWritable(APropInfo: Pointer): Boolean;
begin
  Result := False;
  if APropInfo = nil then Exit;
  try
    Result := PPointer(PtrUInt(APropInfo) + ofsPropSetProc)^ <> nil;
  except
    Result := False;
  end;
end;

function PropNameOf(APropInfo: Pointer): string;
begin
  Result := '';
  if APropInfo = nil then Exit;
  Result := ShortStr(PByte(PtrUInt(APropInfo) + ofsPropName));
end;

{ Namen einer Aufzaehlung. Bei einer Menge wird der Elementtyp genommen. }
procedure EnumNames(ATi: Pointer; ADest: TStrings);
var
  TD: PByte;
  Mn, Mx, i: Integer;
  P: PByte;
  PP: PPointer;
begin
  if (ATi = nil) or (ADest = nil) then Exit;
  try
    if TypeKindOf(ATi) = tkSet then
    begin
      TD := TypeDataOf(ATi);
      if TD = nil then Exit;
      PP := PPointer(TD + ofsSetCompType)^;
      if PP = nil then Exit;
      ATi := PP^;
    end;
    if TypeKindOf(ATi) <> tkEnumeration then Exit;
    TD := TypeDataOf(ATi);
    if TD = nil then Exit;
    Mn := PInteger(TD + ofsEnumMinValue)^;
    Mx := PInteger(TD + ofsEnumMaxValue)^;
    if (Mx < Mn) or (Mx - Mn > 512) then Exit;
    P := TD + ofsEnumNameList;
    for i := Mn to Mx do
    begin
      ADest.Add(ShortStr(P));
      Inc(P, P^ + 1);
    end;
  except
  end;
end;

{ ------------------------------------------------------------ Pfadzugriff -- }

function AmsPropOwner(AObj: Pointer; const APath: string;
  out ALeaf: string): Pointer;
var
  Rest, Head: string;
  P, Guard: Integer;
begin
  ALeaf := '';
  Result := nil;
  if (AObj = nil) or (Trim(APath) = '') then Exit;
  Rest := Trim(APath);
  Result := AObj;
  Guard := 0;
  while Guard <= 8 do
  begin
    P := Pos('.', Rest);
    if P = 0 then Break;
    Head := Trim(Copy(Rest, 1, P - 1));
    Delete(Rest, 1, P);
    Rest := Trim(Rest);
    if Head = '' then Exit(nil);
    Result := AmsGetObj(Result, Head);
    if Result = nil then Exit(nil);
    Inc(Guard);
  end;
  if Rest = '' then Exit(nil);
  ALeaf := Rest;
end;

{ Ein Zug: Besitzer aufloesen, PropInfo holen, Typart bestimmen. }
function Resolve(AObj: Pointer; const APath: string; out AOwner: Pointer;
  out ALeaf: string; out AInfo: Pointer; out AKind: TAmsPropKind): Boolean;
begin
  AInfo := nil;
  AKind := pkNone;
  Result := False;
  AOwner := AmsPropOwner(AObj, APath, ALeaf);
  if AOwner = nil then Exit;
  AInfo := PropInfoOf(AOwner, ALeaf);
  if AInfo = nil then Exit;
  AKind := MapKind(TypeKindOf(PropTypeInfo(AInfo)));
  Result := True;
end;

{ ------------------------------------------------------------- Auskunft ---- }

function AmsHasProp(AObj: Pointer; const APath: string): Boolean;
var
  Owner, Info: Pointer;
  Leaf: string;
  Kind: TAmsPropKind;
begin
  Result := Resolve(AObj, APath, Owner, Leaf, Info, Kind);
end;

function AmsPropKindOf(AObj: Pointer; const APath: string): TAmsPropKind;
var
  Owner, Info: Pointer;
  Leaf: string;
begin
  if not Resolve(AObj, APath, Owner, Leaf, Info, Result) then Result := pkNone;
end;

function AmsPropTypeName(AObj: Pointer; const APath: string): string;
var
  Owner, Info: Pointer;
  Leaf: string;
  Kind: TAmsPropKind;
begin
  Result := '';
  if Resolve(AObj, APath, Owner, Leaf, Info, Kind) then
    Result := TypeNameOf(PropTypeInfo(Info));
end;

function AmsPropWritable(AObj: Pointer; const APath: string): Boolean;
var
  Owner, Info: Pointer;
  Leaf: string;
  Kind: TAmsPropKind;
begin
  Result := Resolve(AObj, APath, Owner, Leaf, Info, Kind) and
            PropIsWritable(Info);
end;

function AmsPropWritesField(AObj: Pointer; const APath: string): Boolean;
var
  Owner, Info, Setter: Pointer;
  Leaf: string;
  Kind: TAmsPropKind;
begin
  Result := False;
  if not Resolve(AObj, APath, Owner, Leaf, Info, Kind) then Exit;
  try
    Setter := PPointer(PtrUInt(Info) + ofsPropSetProc)^;
    Result := (Setter <> nil) and
              ((PtrUInt(Setter) and PropSlotMask) = PropSlotField);
  except
    Result := False;
  end;
end;

function AmsPropOptions(AObj: Pointer; const APath: string): string;
var
  Owner, Info: Pointer;
  Leaf: string;
  Kind: TAmsPropKind;
  L: TStringList;
  i: Integer;
begin
  Result := '';
  if not Resolve(AObj, APath, Owner, Leaf, Info, Kind) then Exit;
  if not (Kind in [pkEnum, pkSet]) then Exit;
  L := TStringList.Create;
  try
    EnumNames(PropTypeInfo(Info), L);
    for i := 0 to L.Count - 1 do
      if Result = '' then Result := L[i] else Result := Result + '|' + L[i];
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------ Wert lesen --- }

{ Host-String-Ergebnis abholen und im Delphi-Heap freigeben. }
function TakeHostStr(var APtr: Pointer): string;
begin
  Result := '';
  if APtr = nil then Exit;
  Result := string(PWideChar(APtr));
  AmsClearHostStr(@APtr);
end;

function GetEnumText(AObj: Pointer; const AProp: string): string;
var
  Res: Pointer;
begin
  Result := '';
  if not Assigned(hcGetEnumProp) then Exit;
  Res := nil;
  try
    hcGetEnumProp(AObj, AmsStr(AProp), @Res);
    Result := TakeHostStr(Res);
  except
    Result := '';
  end;
end;

function GetSetText(AObj: Pointer; const AProp: string): string;
var
  Res: Pointer;
begin
  Result := '';
  if not Assigned(hcGetSetProp) then Exit;
  Res := nil;
  try
    hcGetSetProp(AObj, AmsStr(AProp), True, @Res);
    Result := TakeHostStr(Res);
  except
    Result := '';
  end;
end;

function ValueOf(AOwner: Pointer; const ALeaf: string; AInfo: Pointer;
  AKind: TAmsPropKind): string;
var
  O: Pointer;
  M: TDelphiMethod;
  Tn: string;
begin
  Result := '';
  Tn := TypeNameOf(PropTypeInfo(AInfo));
  case AKind of
    pkString:
      Result := AmsGetStr(AOwner, ALeaf);
    pkEnum:
      begin
        Result := GetEnumText(AOwner, ALeaf);
        if Result = '' then Result := IntToStr(AmsGetOrd(AOwner, ALeaf));
      end;
    pkSet:
      Result := GetSetText(AOwner, ALeaf);
    pkInteger, pkChar:
      if Pos('Color', Tn) > 0 then
        Result := AmsColorToText(AmsGetOrd(AOwner, ALeaf))
      else
        Result := IntToStr(AmsGetOrd(AOwner, ALeaf));
    pkClass:
      begin
        O := AmsGetObj(AOwner, ALeaf);
        if O = nil then
          Result := '(leer)'
        else if AmsName(O) <> '' then
          Result := AmsClassName(O) + ' "' + AmsName(O) + '"'
        else
          Result := AmsClassName(O);
      end;
    pkMethod:
      if AmsGetPropMethod(AOwner, ALeaf, M) and (M.Code <> nil) then
        Result := '(belegt)'
      else
        Result := '(leer)';
  end;
end;

function AmsGetProp(AObj: Pointer; const APath: string): string;
var
  Owner, Info: Pointer;
  Leaf: string;
  Kind: TAmsPropKind;
begin
  Result := '';
  if not Resolve(AObj, APath, Owner, Leaf, Info, Kind) then
  begin
    AmsFailFmt('Eigenschaft "%s" gibt es an [%s] nicht',
               [APath, AmsClassName(AObj)]);
    Exit;
  end;
  if Kind in [pkFloat, pkInt64, pkOther, pkNone] then
  begin
    AmsFailFmt('Eigenschaft "%s" (%s) wird als Text nicht unterstuetzt',
               [APath, AmsKindName(Kind)]);
    Exit;
  end;
  Result := ValueOf(Owner, Leaf, Info, Kind);
end;

{ ------------------------------------------------------------ Wert setzen -- }

type
  TColorName = record
    N: string;
    V: Integer;
  end;

const
  { Die gebraeuchlichen TColor-Konstanten aus Vcl.Graphics. TColor ist
    $00BBGGRR - die Byte-Reihenfolge ist gegenueber HTML gedreht. }
  COLOR_NAMES: array[0..29] of TColorName = (
    (N: 'clBlack';         V: $000000),
    (N: 'clMaroon';        V: $000080),
    (N: 'clGreen';         V: $008000),
    (N: 'clOlive';         V: $008080),
    (N: 'clNavy';          V: $800000),
    (N: 'clPurple';        V: $800080),
    (N: 'clTeal';          V: $808000),
    (N: 'clGray';          V: $808080),
    (N: 'clSilver';        V: $C0C0C0),
    (N: 'clRed';           V: $0000FF),
    (N: 'clLime';          V: $00FF00),
    (N: 'clYellow';        V: $00FFFF),
    (N: 'clBlue';          V: $FF0000),
    (N: 'clFuchsia';       V: $FF00FF),
    (N: 'clAqua';          V: $FFFF00),
    (N: 'clWhite';         V: $FFFFFF),
    (N: 'clMoneyGreen';    V: $C0DCC0),
    (N: 'clSkyBlue';       V: $F0CAA6),
    (N: 'clCream';         V: $F0FBFF),
    (N: 'clMedGray';       V: $A4A0A0),
    (N: 'clNone';          V: $1FFFFFFF),
    (N: 'clDefault';       V: $20000000),
    (N: 'clScrollBar';     V: Integer($80000000)),
    (N: 'clMenu';          V: Integer($80000004)),
    (N: 'clWindow';        V: Integer($80000005)),
    (N: 'clWindowText';    V: Integer($80000008)),
    (N: 'clHighlight';     V: Integer($8000000D)),
    (N: 'clHighlightText'; V: Integer($8000000E)),
    (N: 'clBtnFace';       V: Integer($8000000F)),
    (N: 'clBtnText';       V: Integer($80000012)));

function AmsColorToText(AColor: Integer): string;
var
  i: Integer;
begin
  for i := Low(COLOR_NAMES) to High(COLOR_NAMES) do
    if COLOR_NAMES[i].V = AColor then Exit(COLOR_NAMES[i].N);
  Result := '$' + IntToHex(AColor, 8);
end;

function AmsIntFromText(const AText: string; out AValue: Integer): Boolean;
var
  S: string;
  Code: Integer;
begin
  AValue := 0;
  S := Trim(AText);
  if S = '' then Exit(False);
  { Val kennt "$" fuer hexadezimal, "0x" nicht - das ist aber die Form, in
    der Werkzeuge wie AutoIt Window Info Handles ausgeben. }
  if (Length(S) > 2) and (S[1] = '0') and (UpCase(S[2]) = 'X') then
    S := '$' + Copy(S, 3, MaxInt);
  Val(S, AValue, Code);
  Result := Code = 0;
end;

function AmsColorFromText(const AText: string; out AColor: Integer): Boolean;
var
  S: string;
  i, Code, R, G, B: Integer;
begin
  AColor := 0;
  S := Trim(AText);
  if S = '' then Exit(False);

  for i := Low(COLOR_NAMES) to High(COLOR_NAMES) do
    if SameText(S, COLOR_NAMES[i].N) then
    begin
      AColor := COLOR_NAMES[i].V;
      Exit(True);
    end;

  { Web-Notation #RRGGBB -> TColor $00BBGGRR }
  if (S[1] = '#') and (Length(S) = 7) then
  begin
    Val('$' + Copy(S, 2, 2), R, Code); if Code <> 0 then Exit(False);
    Val('$' + Copy(S, 4, 2), G, Code); if Code <> 0 then Exit(False);
    Val('$' + Copy(S, 6, 2), B, Code); if Code <> 0 then Exit(False);
    AColor := (B shl 16) or (G shl 8) or R;
    Exit(True);
  end;

  Result := AmsIntFromText(S, AColor);
end;

function TextToBool(const AText: string; out AValue: Boolean): Boolean;
var
  S: string;
begin
  S := LowerCase(Trim(AText));
  Result := True;
  AValue := False;
  if (S = '1') or (S = '-1') or (S = 'ja') or (S = 'j') or (S = 'true') or
     (S = 'wahr') or (S = 'an') or (S = 'ein') or (S = 'on') or (S = 'yes') then
    AValue := True
  else if not ((S = '0') or (S = 'nein') or (S = 'n') or (S = 'false') or
               (S = 'falsch') or (S = 'aus') or (S = 'off') or (S = 'no')) then
    Result := False;
end;

{ "fsBold, fsItalic" -> "[fsBold,fsItalic]". SetSetProp will die Klammern. }
function NormalizeSet(const AText: string): string;
var
  S: string;
begin
  S := Trim(AText);
  if S = '' then Exit('[]');
  if S[1] <> '[' then S := '[' + S;
  if S[Length(S)] <> ']' then S := S + ']';
  Result := StringReplace(S, ' ', '', [rfReplaceAll]);
end;

function SetEnumText(AObj: Pointer; const AProp, AValue: string): Boolean;
begin
  Result := False;
  if not Assigned(hcSetEnumProp) then Exit;
  try
    hcSetEnumProp(AObj, AmsStr(AProp), AmsStr(AValue));
    Result := True;
  except
    { EPropertyConvertError kommt als EEDFADE herueber - der Name war falsch }
    Result := False;
  end;
end;

function SetSetText(AObj: Pointer; const AProp, AValue: string): Boolean;
begin
  Result := False;
  if not Assigned(hcSetSetProp) then Exit;
  try
    hcSetSetProp(AObj, AmsStr(AProp), AmsStr(AValue));
    Result := True;
  except
    Result := False;
  end;
end;

{ Das Journal braucht ValueOf, das Setzen braucht das Journal. }
procedure Remember(ARoot: Pointer; const APath, AOldValue: string;
  AHasOld: Boolean); forward;

function SetValue(AOwner: Pointer; const ALeaf: string; AInfo: Pointer;
  AKind: TAmsPropKind; const AValue, APath: string): Boolean;
var
  Num: Integer;
  B: Boolean;
  Tn, Opt: string;

  function BadValue: Boolean;
  begin
    Opt := '';
    if AInfo <> nil then
    begin
      { die erlaubten Namen gehoeren in die Meldung - sonst raet der
        Anwender an einer INI-Zeile herum }
      Opt := AmsPropOptions(AOwner, ALeaf);
      if Opt <> '' then Opt := '  Erlaubt: ' + Opt;
    end;
    Result := AmsFailFmt('"%s" ist kein gueltiger Wert fuer "%s" (%s).%s',
                         [AValue, APath, Tn, Opt]);
  end;

begin
  Tn := TypeNameOf(PropTypeInfo(AInfo));
  case AKind of
    pkString:
      Result := AmsSetStr(AOwner, ALeaf, AValue);
    pkInteger, pkChar:
      begin
        if not AmsColorFromText(AValue, Num) then
          Exit(AmsFailFmt('"%s" ist keine Zahl fuer "%s"', [AValue, APath]));
        Result := AmsSetOrd(AOwner, ALeaf, Num);
      end;
    pkEnum:
      begin
        { Boolean ist in Delphi eine Aufzaehlung - "ja"/"aus" soll trotzdem
          gehen, damit eine INI-Zeile lesbar bleibt. }
        if SameText(Tn, 'Boolean') or SameText(Tn, 'ByteBool') or
           SameText(Tn, 'WordBool') or SameText(Tn, 'LongBool') then
        begin
          if not TextToBool(AValue, B) then Exit(BadValue);
          Exit(AmsSetOrd(AOwner, ALeaf, Ord(B)));
        end;
        if TryStrToInt(Trim(AValue), Num) then
          Exit(AmsSetOrd(AOwner, ALeaf, Num));
        if SetEnumText(AOwner, ALeaf, Trim(AValue)) then Exit(True);
        Result := BadValue;
      end;
    pkSet:
      begin
        if SetSetText(AOwner, ALeaf, NormalizeSet(AValue)) then Exit(True);
        Result := BadValue;
      end;
    pkClass, pkMethod:
      Result := AmsFailFmt('"%s" ist ein %s und laesst sich nicht aus Text ' +
                           'setzen', [APath, AmsKindName(AKind)]);
  else
    Result := AmsFailFmt('Eigenschaft "%s" (%s) kann nicht gesetzt werden',
                         [APath, AmsKindName(AKind)]);
  end;
end;

var
  gAllowRename: Boolean = False;

function AmsSetProp(AObj: Pointer; const APath, AValue: string): Boolean;
var
  Owner, Info: Pointer;
  Leaf, Old: string;
  Kind: TAmsPropKind;
  HasOld: Boolean;
begin
  AmsClearError;
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  if not Resolve(AObj, APath, Owner, Leaf, Info, Kind) then
    Exit(AmsFailFmt('Eigenschaft "%s" gibt es an [%s] nicht',
                    [APath, AmsClassName(AObj)]));
  if not PropIsWritable(Info) then
    Exit(AmsFailFmt('Eigenschaft "%s" ist nur lesbar', [APath]));
  { Der Host findet seine Komponenten ueber TComponent.Name wieder. Eine
    Umbenennung ist deshalb kein gewoehnliches Setzen - dafuer gibt es
    AmsRenameComponent, das ausdruecklich danach verlangt. }
  if SameText(Leaf, 'Name') and not gAllowRename then
    Exit(AmsFail('"Name" wird nicht ueber AmsSetProp gesetzt - dafuer gibt ' +
                 'es AmsRenameComponent'));

  { Den alten Wert VOR dem Schreiben lesen, ins Journal aber erst NACH einem
    erfolgreichen Schreiben eintragen - ein gescheiterter Versuch hat nichts
    veraendert und gehoert deshalb auch nicht zurueckgenommen. }
  HasOld := AmsRecordChanges and
            not (Kind in [pkFloat, pkInt64, pkOther, pkNone, pkClass, pkMethod]);
  if HasOld then Old := ValueOf(Owner, Leaf, Info, Kind);

  Result := SetValue(Owner, Leaf, Info, Kind, AValue, APath);
  if Result then Remember(AObj, APath, Old, HasOld);
end;

function AmsGetPropInt(AObj: Pointer; const APath: string;
  ADefault: Integer): Integer;
var
  Owner: Pointer;
  Leaf: string;
begin
  Result := ADefault;
  Owner := AmsPropOwner(AObj, APath, Leaf);
  if Owner = nil then Exit;
  Result := AmsGetOrd(Owner, Leaf, ADefault);
end;

function AmsSetPropInt(AObj: Pointer; const APath: string;
  AValue: Integer): Boolean;
begin
  Result := AmsSetProp(AObj, APath, IntToStr(AValue));
end;

function AmsGetPropBool(AObj: Pointer; const APath: string;
  ADefault: Boolean): Boolean;
begin
  Result := AmsGetPropInt(AObj, APath, Ord(ADefault)) <> 0;
end;

function AmsSetPropBool(AObj: Pointer; const APath: string;
  AValue: Boolean): Boolean;
begin
  Result := AmsSetProp(AObj, APath, IntToStr(Ord(AValue)));
end;

function AmsGetPropText(AObj: Pointer; const APath: string): string;
var
  Owner: Pointer;
  Leaf: string;
begin
  Result := '';
  Owner := AmsPropOwner(AObj, APath, Leaf);
  if Owner = nil then Exit;
  Result := AmsGetStr(Owner, Leaf);
end;

function AmsSetPropText(AObj: Pointer; const APath, AValue: string): Boolean;
begin
  Result := AmsSetProp(AObj, APath, AValue);
end;

function AmsGetPropObject(AObj: Pointer; const APath: string): Pointer;
var
  Owner: Pointer;
  Leaf: string;
begin
  Result := nil;
  Owner := AmsPropOwner(AObj, APath, Leaf);
  if Owner = nil then Exit;
  Result := AmsGetObj(Owner, Leaf);
end;

function AmsGetPropMethod(AObj: Pointer; const APath: string;
  out AMethod: TDelphiMethod): Boolean;
var
  Owner: Pointer;
  Leaf: string;
begin
  AMethod.Code := nil;
  AMethod.Data := nil;
  Result := False;
  if not AmsBindProps then Exit;
  if not Assigned(hcGetMethodProp) then Exit;
  Owner := AmsPropOwner(AObj, APath, Leaf);
  if Owner = nil then Exit;
  try
    hcGetMethodProp(Owner, AmsStr(Leaf), @AMethod);
    Result := True;
  except
    AMethod.Code := nil;
    AMethod.Data := nil;
    Result := False;
  end;
end;

function AmsSetPropMethod(AObj: Pointer; const APath: string;
  const AMethod: TDelphiMethod): Boolean;
var
  Owner: Pointer;
  Leaf: string;
begin
  Owner := AmsPropOwner(AObj, APath, Leaf);
  if Owner = nil then
    Exit(AmsFailFmt('Ereignis "%s" gibt es an [%s] nicht',
                    [APath, AmsClassName(AObj)]));
  Result := AmsSetMethod(Owner, Leaf, AMethod);
end;

function AmsRenameComponent(AObj: Pointer; const ANewName: string): Boolean;
var
  Old: string;
begin
  if AObj = nil then Exit(AmsFail('Kein Element angegeben'));
  if Trim(ANewName) = '' then Exit(AmsFail('Leerer Name'));
  Old := AmsName(AObj);
  gAllowRename := True;
  try
    Result := AmsSetProp(AObj, 'Name', Trim(ANewName));
  finally
    gAllowRename := False;
  end;
  if Result then
    AmsLogFmt('Komponente "%s" [%s] heisst jetzt "%s" - unter dem alten ' +
              'Namen findet der Host sie nicht mehr',
              [Old, AmsClassName(AObj), Trim(ANewName)]);
end;

{ ---------------------------------------------------------------- Liste ---- }

function AmsPropList(AObj: Pointer; var AProps: TAmsPropArray;
  AWithValues: Boolean): Integer;
var
  Ti: Pointer;
  TD: PByte;
  Cnt, i, n: Integer;
  List: PPtrArray;
  Info: Pointer;
  Kind: TAmsPropKind;
begin
  SetLength(AProps, 0);
  Result := 0;
  if not AmsBindProps then
  begin
    AmsFail('RTTI-Symbole des Hosts fehlen (Gruppe Props)');
    Exit;
  end;
  Ti := ClassTypeInfo(AObj);
  if (Ti = nil) or (TypeKindOf(Ti) <> tkClass) then
  begin
    AmsFail('Kein Delphi-Objekt mit RTTI');
    Exit;
  end;

  TD := TypeDataOf(Ti);
  if TD = nil then Exit;
  Cnt := 0;
  try
    Cnt := PSmallInt(TD + ofsClassPropCount)^;
  except
    Cnt := 0;
  end;
  if (Cnt <= 0) or (Cnt > MAX_PROPS) then Exit;

  List := GetMem(Cnt * SizeOf(Pointer));
  try
    FillChar(List^, Cnt * SizeOf(Pointer), 0);
    try
      hcGetPropInfos(Ti, List);
    except
      Exit;
    end;

    SetLength(AProps, Cnt);
    n := 0;
    for i := 0 to Cnt - 1 do
    begin
      Info := List^[i];
      if Info = nil then Continue;
      AProps[n].Name := PropNameOf(Info);
      if AProps[n].Name = '' then Continue;
      Kind := MapKind(TypeKindOf(PropTypeInfo(Info)));
      AProps[n].TypeName := TypeNameOf(PropTypeInfo(Info));
      AProps[n].Kind := Kind;
      AProps[n].Writable := PropIsWritable(Info);
      if AWithValues then
        AProps[n].Value := ValueOf(AObj, AProps[n].Name, Info, Kind)
      else
        AProps[n].Value := '';
      Inc(n);
    end;
    SetLength(AProps, n);
    Result := n;
  finally
    FreeMem(List);
  end;
end;

procedure AmsDumpProps(AObj: Pointer; ADest: TStrings; AWithValues: Boolean);
var
  Props: TAmsPropArray;
  i, n: Integer;
  Flag, Val, Opt: string;
begin
  if ADest = nil then Exit;
  n := AmsPropList(AObj, Props, AWithValues);
  ADest.Add(Format('%s "%s" - %d Eigenschaften',
                   [AmsClassName(AObj), AmsName(AObj), n]));
  if n = 0 then
  begin
    ADest.Add('  ' + AmsLastError);
    Exit;
  end;
  for i := 0 to n - 1 do
  begin
    if Props[i].Writable then Flag := ' ' else Flag := 'r';
    Val := Props[i].Value;
    if (Val = '') and (Props[i].Kind in [pkFloat, pkInt64, pkOther]) then
      Val := '(' + AmsKindName(Props[i].Kind) + ')';
    Opt := '';
    if Props[i].Kind in [pkEnum, pkSet] then
    begin
      Opt := AmsPropOptions(AObj, Props[i].Name);
      if Opt <> '' then Opt := '   {' + Opt + '}';
    end;
    ADest.Add(Format('  %s %-24s %-22s %s%s',
                     [Flag, Props[i].Name, Props[i].TypeName, Val, Opt]));
  end;
end;

{ ------------------------------------------------------ Aenderungsjournal -- }

type
  PChange = ^TChange;
  TChange = record
    Obj: Pointer;
    ObjClass: string;      { zur Wiedererkennung des Zeigers }
    ObjName: string;
    Path: string;
    OldValue: string;
    HasOld: Boolean;
  end;

var
  gChanges: TList = nil;

function FindChange(AObj: Pointer; const APath: string): PChange;
var
  i: Integer;
  C: PChange;
begin
  Result := nil;
  if gChanges = nil then Exit;
  for i := 0 to gChanges.Count - 1 do
  begin
    C := PChange(gChanges[i]);
    if (C^.Obj = AObj) and SameText(C^.Path, APath) then Exit(C);
  end;
end;

procedure Remember(ARoot: Pointer; const APath, AOldValue: string;
  AHasOld: Boolean);
var
  C: PChange;
begin
  if not AmsRecordChanges then Exit;
  if ARoot = nil then Exit;
  if gChanges = nil then gChanges := TList.Create;
  { Der ERSTE gemerkte Wert ist der Ausgangszustand - spaetere Aenderungen
    derselben Eigenschaft duerfen ihn nicht ueberschreiben. }
  if FindChange(ARoot, APath) <> nil then Exit;
  if gChanges.Count >= MAX_CHANGES then
  begin
    AmsLog('Aenderungsjournal voll - weitere Aenderungen sind nicht mehr ' +
           'zuruecknehmbar');
    Exit;
  end;
  if not AHasOld then
    AmsLogFmt('Alter Wert von "%s" nicht lesbar - keine Ruecknahme moeglich',
              [APath]);

  New(C);
  C^.Obj := ARoot;
  C^.ObjClass := AmsClassName(ARoot);
  C^.ObjName := AmsName(ARoot);
  C^.Path := APath;
  C^.OldValue := AOldValue;
  C^.HasOld := AHasOld;
  gChanges.Add(C);
end;

function AmsChangeCount: Integer;
begin
  if gChanges = nil then Result := 0 else Result := gChanges.Count;
end;

procedure AmsDumpChanges(ADest: TStrings);
var
  i: Integer;
  C: PChange;
begin
  if ADest = nil then Exit;
  ADest.Add(Format('Aenderungen an Host-Elementen: %d', [AmsChangeCount]));
  if gChanges = nil then Exit;
  for i := 0 to gChanges.Count - 1 do
  begin
    C := PChange(gChanges[i]);
    if C^.HasOld then
      ADest.Add(Format('  %s "%s".%s   vorher: %s',
                       [C^.ObjClass, C^.ObjName, C^.Path, C^.OldValue]))
    else
      ADest.Add(Format('  %s "%s".%s   vorher: unbekannt',
                       [C^.ObjClass, C^.ObjName, C^.Path]));
  end;
end;

{ Zeigt der gemerkte Zeiger noch auf dasselbe Objekt? Der Host kann seine
  Komponente laengst freigegeben haben; dann steht an der Adresse etwas
  anderes - oder gar nichts. Klasse und Name sind eine billige Probe, die
  den ueberwiegenden Teil dieser Faelle erkennt. }
function StillThere(AC: PChange): Boolean;
begin
  Result := (AC^.Obj <> nil) and
            (AmsClassName(AC^.Obj) = AC^.ObjClass) and
            (AmsName(AC^.Obj) = AC^.ObjName);
end;

function UndoOne(AC: PChange): Boolean;
var
  Owner, Info: Pointer;
  Leaf: string;
  Kind: TAmsPropKind;
  Saved: Boolean;
begin
  Result := False;
  if not AC^.HasOld then Exit;
  if not StillThere(AC) then
  begin
    AmsLogFmt('Ruecknahme uebersprungen: %s "%s" gibt es nicht mehr',
              [AC^.ObjClass, AC^.ObjName]);
    Exit;
  end;
  if not Resolve(AC^.Obj, AC^.Path, Owner, Leaf, Info, Kind) then Exit;
  Saved := AmsRecordChanges;
  AmsRecordChanges := False;
  try
    Result := SetValue(Owner, Leaf, Info, Kind, AC^.OldValue, AC^.Path);
  finally
    AmsRecordChanges := Saved;
  end;
end;

function AmsUndoAll: Integer;
var
  i: Integer;
  C: PChange;
begin
  Result := 0;
  if gChanges = nil then Exit;
  { rueckwaerts: die zuletzt gesetzte Eigenschaft zuerst }
  for i := gChanges.Count - 1 downto 0 do
  begin
    C := PChange(gChanges[i]);
    try
      if UndoOne(C) then Inc(Result);
    except
      on E: Exception do
        AmsLogFmt('Ruecknahme von "%s" gescheitert: %s', [C^.Path, E.Message]);
    end;
    Dispose(C);
  end;
  gChanges.Clear;
  if Result > 0 then
    AmsLogFmt('%d Aenderung(en) an Host-Elementen zurueckgenommen', [Result]);
end;

function AmsUndoObject(AObj: Pointer): Integer;
var
  i: Integer;
  C: PChange;
begin
  Result := 0;
  if (gChanges = nil) or (AObj = nil) then Exit;
  for i := gChanges.Count - 1 downto 0 do
  begin
    C := PChange(gChanges[i]);
    if C^.Obj <> AObj then Continue;
    try
      if UndoOne(C) then Inc(Result);
    except
      on E: Exception do
        AmsLogFmt('Ruecknahme von "%s" gescheitert: %s', [C^.Path, E.Message]);
    end;
    Dispose(C);
    gChanges.Delete(i);
  end;
end;

procedure AmsForgetChanges;
var
  i: Integer;
begin
  if gChanges = nil then Exit;
  for i := 0 to gChanges.Count - 1 do
    Dispose(PChange(gChanges[i]));
  gChanges.Clear;
end;

initialization
  gChanges := nil;

finalization
  { Hier NICHT mehr zuruecknehmen: beim Finalize ist der Host womoeglich
    schon abgebaut. Die Ruecknahme gehoert in Unload, siehe AmsApi.Plugin. }
  AmsForgetChanges;
  FreeAndNil(gChanges);

end.
