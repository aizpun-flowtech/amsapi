unit AmsApi.Rtti;

{ ============================================================================
  AmsApi.Rtti - Delphi-Laufzeitinformationen und published properties

  Alle Zugriffe sind in try/except gekapselt: Delphi-Exceptions kommen als
  EEDFADE (External exception) ueber die Modulgrenze und lassen sich nicht
  typisiert auswerten. Ein fehlgeschlagener Zugriff liefert hier immer einen
  neutralen Wert, nie eine Ausnahme an den Aufrufer.

  Merke zu GetStrProp: EAX = Instance, EDX = PropName, ECX = @Result.
  Nicht EAX = @Result. Falsch herum stuerzt nichts ab, es liefert still Muell
  und laesst jeden Namensvergleich fehlschlagen.
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
  Windows, SysUtils, AmsApi.Types;

{ Delphi-Klassenname aus dem VMT: PPointer(PPointer(Obj)^ + vmtClassName)^
  ist ein ShortString. Liefert '' bei nil, '?' bei kaputtem Zeiger. }
function AmsClassName(AObj: Pointer): string;

{ True, wenn der Klassenname ATeil enthaelt (case-sensitiv wie im Original). }
function AmsClassIs(AObj: Pointer; const APart: string): Boolean;

{ ------------------------------------------------------------ Klassenkette -
  Dieselben Angaben, aber ueber den KLASSENZEIGER statt ueber eine Instanz.
  Damit laesst sich ein Element einordnen, ohne seine Eigenschaften zu raten:
  "ist das ein TWinControl" ist eine Frage an die Klasse, nicht an das Objekt. }

{ Klasse eines Objekts (der VMT-Zeiger an Offset 0). }
function AmsClassOf(AObj: Pointer): Pointer;

{ Name einer KLASSE (nicht eines Objekts). }
function AmsClassNameOf(ACls: Pointer): string;

{ Elternklasse. vmtParent zeigt auf einen Zeiger auf die Klasse - hier ist
  beides dereferenziert. nil bei TObject und bei kaputten Zeigern. }
function AmsClassParent(ACls: Pointer): Pointer;

{ Groesse einer Instanz dieser Klasse in Byte. 0, wenn nicht lesbar. }
function AmsInstanceSize(ACls: Pointer): Integer;

{ Steht AName in der Klassenkette? Verglichen wird der Klassenname ohne
  Gross-/Kleinschreibung, also 'TWinControl', 'TControl', 'TdxBarItem'.
  Das ist die ehrliche Auskunft ueber die Herkunft eines fremden Elements -
  anders als die Frage, ob es zufaellig eine Eigenschaft "Left" hat. }
function AmsClassInheritsFrom(ACls: Pointer; const AName: string): Boolean;
function AmsInheritsFrom(AObj: Pointer; const AName: string): Boolean;

{ In welchem VMT-Slot steht diese Methode? Liefert den BYTEOFFSET (0, 4, 8
  ...) oder -1.

  Wozu: virtuelle Methoden des Hosts - der Konstruktor, TControl.SetParent -
  muessen ueber das VMT DES OBJEKTS gerufen werden, sonst greift bei einer
  abgeleiteten Klasse die falsche Fassung. Der Slot unterscheidet sich je
  Delphi-Version. Statt ihn zu verdrahten, wird die aus dem Package geholte
  Adresse der BASISFASSUNG im VMT der BASISKLASSE gesucht - der gefundene
  Slot gilt dann fuer jede abgeleitete Klasse.
  Gesucht wird nur, solange die Slots wie Codezeiger aussehen; hinter dem
  letzten Eintrag stehen andere Daten. }
function AmsVmtIndexOf(ACls, AMethod: Pointer;
  AMaxSlots: Integer = 200): Integer;

{ TComponent.FName direkt aus Offset 8 lesen - fuer den haeufigsten Fall ohne
  jede Allokation im Delphi-Heap. Liefert '' bei unplausiblem Inhalt. }
function AmsName(AComp: Pointer): string;

{ published properties }
function AmsGetStr(AObj: Pointer; const AProp: string): string;
function AmsSetStr(AObj: Pointer; const AProp, AValue: string): Boolean;
function AmsGetOrd(AObj: Pointer; const AProp: string; ADefault: Integer = 0): Integer;
function AmsSetOrd(AObj: Pointer; const AProp: string; AValue: Integer): Boolean;
function AmsGetObj(AObj: Pointer; const AProp: string): Pointer;
function AmsSetMethod(AObj: Pointer; const AProp: string;
  const AMethod: TDelphiMethod): Boolean;
{ Methodenproperty loeschen - Pflicht vor dem Entladen des Plugins, sonst
  springt ein spaeterer Klick in freigegebenen Code. }
function AmsClearMethod(AObj: Pointer; const AProp: string): Boolean;

{ Virtuelle Methode ueber das VMT des Objekts aufrufen (Slot als Byteoffset).
  Noetig z.B. fuer TGraphic.LoadFromFile, weil abgeleitete Klassen
  ueberschreiben. }
function AmsVmtSlot(AObj: Pointer; AOffset: Integer): Pointer;

{ Aus einem Interface-Zeiger den Objektzeiger gewinnen. Der Offset wird ueber
  den erwarteten Klassennamen validiert statt blind gerechnet. }
function AmsObjFromIntf(AIntf: Pointer; const AExpectClass: string;
  out AOffset: Integer): Pointer;

{ IInterface._Release aufrufen (Vtable-Slot 2). }
procedure AmsReleaseIntf(AIntf: Pointer);

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Log;

function AmsClassName(AObj: Pointer): string;
var
  P: PByte;
begin
  Result := '';
  if AObj = nil then Exit;
  try
    P := PPointer(PtrInt(PPointer(AObj)^) + vmtClassName)^;
    if P <> nil then SetString(Result, PAnsiChar(P + 1), P^);
  except
    Result := '?';
  end;
end;

function AmsClassIs(AObj: Pointer; const APart: string): Boolean;
begin
  Result := (APart <> '') and (Pos(APart, AmsClassName(AObj)) > 0);
end;

{ ------------------------------------------------------------ Klassenkette - }

function AmsClassOf(AObj: Pointer): Pointer;
begin
  Result := nil;
  if AObj = nil then Exit;
  try
    Result := PPointer(AObj)^;
  except
    Result := nil;
  end;
end;

function AmsClassNameOf(ACls: Pointer): string;
var
  P: PByte;
begin
  Result := '';
  if ACls = nil then Exit;
  try
    P := PPointer(PByte(ACls) + vmtClassName)^;
    if P <> nil then SetString(Result, PAnsiChar(P + 1), P^);
  except
    Result := '';
  end;
end;

function AmsClassParent(ACls: Pointer): Pointer;
var
  PP: PPointer;
begin
  Result := nil;
  if ACls = nil then Exit;
  try
    { Erst der Zeiger AUF den Klassenzeiger, dann die Klasse selbst. }
    PP := PPointer(PByte(ACls) + vmtParent)^;
    if PP <> nil then Result := PP^;
  except
    Result := nil;
  end;
end;

function AmsInstanceSize(ACls: Pointer): Integer;
begin
  Result := 0;
  if ACls = nil then Exit;
  try
    Result := PInteger(PByte(ACls) + vmtInstanceSize)^;
    if (Result < 0) or (Result > 1024 * 1024) then Result := 0;
  except
    Result := 0;
  end;
end;

function AmsClassInheritsFrom(ACls: Pointer; const AName: string): Boolean;
var
  C: Pointer;
  Guard: Integer;
begin
  Result := False;
  if (ACls = nil) or (AName = '') then Exit;
  C := ACls;
  Guard := 0;
  { 64 Stufen sind mehr als jede VCL-Kette; die Schranke faengt einen
    verbogenen vmtParent ab, der sonst ewig im Kreis liefe. }
  while (C <> nil) and (Guard < 64) do
  begin
    if SameText(AmsClassNameOf(C), AName) then Exit(True);
    C := AmsClassParent(C);
    Inc(Guard);
  end;
end;

function AmsInheritsFrom(AObj: Pointer; const AName: string): Boolean;
begin
  Result := AmsClassInheritsFrom(AmsClassOf(AObj), AName);
end;

function AmsVmtIndexOf(ACls, AMethod: Pointer; AMaxSlots: Integer): Integer;
var
  i: Integer;
  Slot: Pointer;
begin
  Result := -1;
  if (ACls = nil) or (AMethod = nil) then Exit;
  if AMaxSlots <= 0 then AMaxSlots := 200;
  try
    for i := 0 to AMaxSlots - 1 do
    begin
      Slot := PPointer(PByte(ACls) + i * SizeOf(Pointer))^;
      { Hinter dem letzten virtuellen Eintrag stehen andere Daten - eine
        Laenge, ein Zeichen, eine 0. Was kein Codezeiger sein kann, beendet
        die Suche, statt sie in fremden Speicher laufen zu lassen. }
      if PtrUInt(Slot) < $10000 then Break;
      if Slot = AMethod then Exit(i * SizeOf(Pointer));
    end;
  except
    Result := -1;
  end;
end;

function AmsName(AComp: Pointer): string;
var
  P: Pointer;
  i: Integer;
begin
  Result := '';
  if AComp = nil then Exit;
  try
    P := PPointer(PtrUInt(AComp) + ofsComponentName)^;
    if P = nil then Exit;
    Result := string(PWideChar(P));
    if Length(Result) > 64 then Exit('');
    { Ein Komponentenname ist ein Bezeichner. Alles andere heisst: der Zeiger
      war keiner - dann lieber leer liefern als Muell vergleichen. }
    for i := 1 to Length(Result) do
      if (Result[i] < #32) or (Result[i] > #126) then
        Exit('');
  except
    Result := '';
  end;
end;

function AmsGetStr(AObj: Pointer; const AProp: string): string;
var
  Res: Pointer;
begin
  Result := '';
  if (AObj = nil) or not Assigned(hcGetStrProp) then Exit;
  Res := nil;
  try
    hcGetStrProp(AObj, AmsStr(AProp), @Res);
    if Res <> nil then
    begin
      Result := string(PWideChar(Res));
      AmsClearHostStr(@Res);
    end;
  except
    Result := '';
  end;
end;

function AmsSetStr(AObj: Pointer; const AProp, AValue: string): Boolean;
begin
  Result := False;
  if (AObj = nil) or not Assigned(hcSetStrProp) then Exit;
  try
    hcSetStrProp(AObj, AmsStr(AProp), AmsStr(AValue));
    Result := True;
  except
    Result := AmsFailFmt('SetStrProp("%s") fehlgeschlagen', [AProp]);
  end;
end;

function AmsGetOrd(AObj: Pointer; const AProp: string; ADefault: Integer): Integer;
begin
  Result := ADefault;
  if (AObj = nil) or not Assigned(hcGetOrdProp) then Exit;
  try
    Result := hcGetOrdProp(AObj, AmsStr(AProp));
  except
    Result := ADefault;
  end;
end;

function AmsSetOrd(AObj: Pointer; const AProp: string; AValue: Integer): Boolean;
begin
  Result := False;
  if (AObj = nil) or not Assigned(hcSetOrdProp) then Exit;
  try
    hcSetOrdProp(AObj, AmsStr(AProp), AValue);
    Result := True;
  except
    Result := AmsFailFmt('SetOrdProp("%s") fehlgeschlagen', [AProp]);
  end;
end;

function AmsGetObj(AObj: Pointer; const AProp: string): Pointer;
begin
  Result := nil;
  if (AObj = nil) or not Assigned(hcGetObjectProp) then Exit;
  try
    Result := hcGetObjectProp(AObj, AmsStr(AProp), nil);
  except
    { z.B. GetObjectProp('ItemLinks') auf einem VCL-TPopupMenu: das hat
      "Items", nicht "ItemLinks", und wirft EEDFADE. }
    Result := nil;
  end;
end;

function AmsSetMethod(AObj: Pointer; const AProp: string;
  const AMethod: TDelphiMethod): Boolean;
begin
  Result := False;
  if (AObj = nil) or not Assigned(hcSetMethodProp) then Exit;
  try
    hcSetMethodProp(AObj, AmsStr(AProp), @AMethod);
    Result := True;
  except
    Result := AmsFailFmt('SetMethodProp("%s") fehlgeschlagen', [AProp]);
  end;
end;

function AmsClearMethod(AObj: Pointer; const AProp: string): Boolean;
var
  Empty: TDelphiMethod;
begin
  Empty.Code := nil;
  Empty.Data := nil;
  Result := AmsSetMethod(AObj, AProp, Empty);
end;

function AmsVmtSlot(AObj: Pointer; AOffset: Integer): Pointer;
begin
  Result := nil;
  if AObj = nil then Exit;
  try
    Result := PPointer(PtrInt(PPointer(AObj)^) + AOffset)^;
  except
    Result := nil;
  end;
end;

function AmsObjFromIntf(AIntf: Pointer; const AExpectClass: string;
  out AOffset: Integer): Pointer;
const
  { $30 stammt aus dem Konstruktoraufruf in WorkflowEngine(); die uebrigen
    sind Kandidaten fuer andere Interfaces derselben Bauart. }
  CANDIDATES: array[0..5] of Integer = ($30, $2C, $34, $28, $38, 0);
var
  i: Integer;
  Cand: Pointer;
begin
  Result := nil;
  AOffset := -1;
  if AIntf = nil then Exit;
  for i := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    Cand := Pointer(PtrInt(AIntf) - CANDIDATES[i]);
    if Pos(AExpectClass, AmsClassName(Cand)) > 0 then
    begin
      AOffset := CANDIDATES[i];
      Exit(Cand);
    end;
  end;
end;

procedure AmsReleaseIntf(AIntf: Pointer);
var
  Rel: TFnIntfRelease;
begin
  if AIntf = nil then Exit;
  try
    Rel := TFnIntfRelease(PPointer(PtrUInt(PPointer(AIntf)^) + vmtSlotRelease)^);
    if Assigned(Rel) then Rel(AIntf);
  except
  end;
end;

end.
