unit AmsApi.Workflow;

{ ============================================================================
  AmsApi.Workflow - WorkflowEngine der aktuellen BuSession  (ADVANCED)

  ACHTUNG - Anwendungsbereich:
  Dieser Weg findet nur AutoStart-Automatismen; die werden beim Sessionstart
  aus der Datenbank in die Engine geladen. Fuer "Automatismus ausfuehren wie
  im Menue" ist AmsApi.Automatismus der richtige Weg, weil AMS sein Menue
  kontextabhaengig fuellt. Diese Unit ist der Zweitweg, nicht der Standardweg.

  Der eine gefaehrliche Punkt:
    WorkflowEngine(Session) liefert ein INTERFACE ueber ein verstecktes
    Ergebnisargument in EDX. Als normale Funktion deklariert -> Access
    Violation. Der Objektzeiger liegt danach bei Offset $30 vor dem
    Interface-Zeiger; wir validieren das ueber den Klassennamen, statt blind
    zu rechnen.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, AmsApi.Types;

{ Engine-Objekt zur Session holen. AIntf muss der Aufrufer spaeter mit
  AmsReleaseWorkflowEngine freigeben. }
function AmsWorkflowEngine(ABuSession: Pointer; out AIntf: Pointer): Pointer;
procedure AmsReleaseWorkflowEngine(AIntf: Pointer);

{ Aufgabenliste der Engine. }
function AmsWorkflowTaskList(AEngine: Pointer): Pointer;

{ Aufgabe nach Namen suchen. }
function AmsFindWorkflowTask(ATaskList: Pointer; const AName: string): Pointer;

{ Kompletter Weg: benannte Aufgabe der Session ohne Vorpruefung ausfuehren. }
function AmsRunWorkflowTask(ABuSession: Pointer; const AName: string): Boolean;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Log;

function AmsWorkflowEngine(ABuSession: Pointer; out AIntf: Pointer): Pointer;
var
  Ofs: Integer;
begin
  Result := nil;
  AIntf := nil;
  if ABuSession = nil then
  begin
    AmsFail('WorkflowEngine: keine BuSession - erst nach der Anmeldung moeglich');
    Exit;
  end;
  if not AmsBindWorkflow then
  begin
    AmsFail('WorkflowEngine: afnBu-Symbole fehlen');
    Exit;
  end;

  try
    { Interface kommt ueber das versteckte Ergebnisargument, nicht ueber EAX. }
    hcWorkflowEngine(ABuSession, @AIntf);
  except
    on E: Exception do
    begin
      AmsFail('WorkflowEngine() EXCEPTION: ' + E.Message);
      AIntf := nil;
      Exit;
    end;
  end;
  if AIntf = nil then
  begin
    AmsFail('WorkflowEngine: Interface ist nil');
    Exit;
  end;

  Result := AmsObjFromIntf(AIntf, 'WorkflowEngine', Ofs);
  if Result = nil then
  begin
    AmsFail('WorkflowEngine: Objektzeiger nicht ermittelbar');
    AmsReleaseWorkflowEngine(AIntf);
    AIntf := nil;
    Exit;
  end;
  AmsLogFmt('WorkflowEngine: Interface %p -> Objekt %p bei Offset $%x [%s]',
            [AIntf, Result, Ofs, AmsClassName(Result)]);
end;

procedure AmsReleaseWorkflowEngine(AIntf: Pointer);
begin
  AmsReleaseIntf(AIntf);
end;

function AmsWorkflowTaskList(AEngine: Pointer): Pointer;
begin
  Result := nil;
  if (AEngine = nil) or not AmsBindWorkflow then Exit;
  try
    Result := hcEngineGetTaskList(AEngine);
  except
    on E: Exception do
    begin
      AmsFail('GetTaskList: ' + E.Message);
      Result := nil;
    end;
  end;
end;

function AmsFindWorkflowTask(ATaskList: Pointer; const AName: string): Pointer;
begin
  Result := nil;
  if (ATaskList = nil) or (AName = '') or not AmsBindWorkflow then Exit;
  try
    Result := hcTaskListFindByName(ATaskList, AmsStr(AName));
  except
    on E: Exception do
    begin
      AmsFailFmt('FindTaskByName("%s"): %s', [AName, E.Message]);
      Result := nil;
    end;
  end;
end;

function AmsRunWorkflowTask(ABuSession: Pointer; const AName: string): Boolean;
var
  Intf, Engine, List, Task: Pointer;
begin
  Result := False;
  AmsClearError;
  if AName = '' then Exit(AmsFail('RunWorkflowTask: kein Name angegeben'));

  Intf := nil;
  Engine := AmsWorkflowEngine(ABuSession, Intf);
  if Engine = nil then Exit;
  try
    List := AmsWorkflowTaskList(Engine);
    if List = nil then Exit(AmsFail('RunWorkflowTask: TaskList ist nil'));
    AmsLogFmt('  TaskList -> %p [%s]', [List, AmsClassName(List)]);

    Task := AmsFindWorkflowTask(List, AName);
    if Task = nil then
      Exit(AmsFailFmt('RunWorkflowTask: "%s" nicht gefunden - nur AutoStart-' +
                      'Automatismen liegen in der Engine', [AName]));
    AmsLogFmt('  FindTaskByName("%s") -> %p [%s]',
              [AName, Task, AmsClassName(Task)]);

    try
      hcTaskExecuteNoCheck(Task, nil, nil);
      AmsLogFmt('RunWorkflowTask "%s": ausgefuehrt', [AName]);
      Result := True;
    except
      on E: Exception do
        Result := AmsFailFmt('RunWorkflowTask "%s": %s', [AName, E.Message]);
    end;
  finally
    AmsReleaseWorkflowEngine(Intf);
  end;
end;

end.
