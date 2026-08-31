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
