unit AmsApi.Actions;

{ ============================================================================
  AmsApi.Actions - benannte Actions und Events des Hosts

  TafnActionManager und TafnEventManager sind die globale Registry, ueber die
  sich auch die internen Plugins des Herstellers (ELO, DocuWare) einklinken.
  Die Namen findet man im eingebauten Editor "Event/Action-Mappings".

  Beide Manager sind Singletons: GetInstance ist eine Klassenmethode, EAX ist
  also die Klassenreferenz (das exportierte VMT-Symbol), nicht eine Instanz.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, AmsApi.Types;

{ Instanz des Action- bzw. Event-Managers. nil, wenn afnComponentsRt fehlt. }
function AmsActionManager: Pointer;
function AmsEventManager: Pointer;

{ Benanntes Objekt aus der Registry holen. nil = nicht vorhanden. }
function AmsFindAction(const AName: string): Pointer;
function AmsFindEvent(const AName: string): Pointer;

{ Benannte Action ausfuehren. APacket/AUserData bleiben in aller Regel nil. }
function AmsRunAction(const AName: string; APacket: Pointer = nil;
  AUserData: Pointer = nil): Boolean;

{ Benanntes Event feuern. AOptions ist ein Delphi-Set als Byte, 0 = Standard. }
function AmsFireEvent(const AName: string; AOptions: Byte = 0;
  APacket: Pointer = nil; AUserData: Pointer = nil): Boolean;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Log;

function AmsActionManager: Pointer;
begin
  Result := nil;
  if not AmsBindAfn then Exit;
  try
    Result := hcActionManagerInstance(hcActionManagerClass);
  except
    on E: Exception do
    begin
      AmsFail('TafnActionManager.GetInstance: ' + E.Message);
      Result := nil;
    end;
  end;
end;

function AmsEventManager: Pointer;
begin
  Result := nil;
  if not AmsBindAfn then Exit;
  try
    Result := hcEventManagerInstance(hcEventManagerClass);
  except
    on E: Exception do
    begin
      AmsFail('TafnEventManager.GetInstance: ' + E.Message);
      Result := nil;
    end;
  end;
end;

function AmsFindAction(const AName: string): Pointer;
var
  Mgr: Pointer;
begin
  Result := nil;
  if AName = '' then Exit;
  Mgr := AmsActionManager;
  if Mgr = nil then Exit;
  try
    Result := hcActionManagerGetActions(Mgr, AmsStr(AName));
  except
    on E: Exception do
    begin
      AmsFailFmt('Actions["%s"]: %s', [AName, E.Message]);
      Result := nil;
    end;
  end;
end;

function AmsFindEvent(const AName: string): Pointer;
var
  Mgr: Pointer;
begin
  Result := nil;
  if AName = '' then Exit;
  Mgr := AmsEventManager;
  if Mgr = nil then Exit;
  try
    Result := hcEventManagerGetEvents(Mgr, AmsStr(AName));
  except
    on E: Exception do
    begin
      AmsFailFmt('Events["%s"]: %s', [AName, E.Message]);
      Result := nil;
    end;
  end;
end;

function AmsRunAction(const AName: string; APacket, AUserData: Pointer): Boolean;
var
  Act: Pointer;
begin
  Result := False;
  AmsClearError;
  if AName = '' then Exit(AmsFail('RunAction: kein Name angegeben'));
  if not AmsBindAfn then Exit(AmsFail('RunAction: afnComponentsRt fehlt'));

  Act := AmsFindAction(AName);
  if Act = nil then
    Exit(AmsFailFmt('RunAction: Action "%s" nicht gefunden', [AName]));

  try
    hcActionExecute(Act, APacket, AUserData);
    AmsLogFmt('Action "%s" [%s] ausgefuehrt', [AName, AmsClassName(Act)]);
    Result := True;
  except
    on E: Exception do
      Result := AmsFailFmt('RunAction "%s": %s', [AName, E.Message]);
  end;
end;

function AmsFireEvent(const AName: string; AOptions: Byte;
  APacket, AUserData: Pointer): Boolean;
var
  Ev: Pointer;
begin
  Result := False;
  AmsClearError;
  if AName = '' then Exit(AmsFail('FireEvent: kein Name angegeben'));
  if not AmsBindAfn then Exit(AmsFail('FireEvent: afnComponentsRt fehlt'));

  Ev := AmsFindEvent(AName);
  if Ev = nil then
    Exit(AmsFailFmt('FireEvent: Event "%s" nicht gefunden', [AName]));

  try
    hcEventFire(Ev, APacket, AUserData, AOptions);
    AmsLogFmt('Event "%s" [%s] gefeuert', [AName, AmsClassName(Ev)]);
    Result := True;
  except
    on E: Exception do
      Result := AmsFailFmt('FireEvent "%s": %s', [AName, E.Message]);
  end;
end;

end.
