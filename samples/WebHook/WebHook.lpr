library WebHook;

{ Beispiel: Ribbon-Button schickt eine HTTP-Anfrage an eine konfigurierbare
  URL. Alles Wesentliche steht in der plugin.ini daneben, das Plugin selbst
  bleibt unveraendert.

  Die Anfrage laeuft im Hintergrundthread - der UI-Thread von AMS darf nicht
  auf ein Netzwerk warten. Das Ergebnis kommt ueber HttpDone zurueck; dort
  laeuft NICHT der Hauptthread, deshalb nur loggen bzw. PostMessage. }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, AmsApi.Plugin, AmsApi.Http, AmsApi.Ini;

const
  WM_HTTP_DONE = WM_APP + 41;

type
  TWebHookPlugin = class(TAmsPlugin)
  private
    FLastStatus: Integer;
    FLastOk: Boolean;
    procedure HttpDone(ASuccess: Boolean; AStatus: Integer;
      const AResponse: string; ATag: Integer);
  protected
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
    function WantsWindowHook: Boolean; override;
    function WindowMessage(AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM;
      var AHandled: Boolean): LRESULT; override;
  end;

procedure TWebHookPlugin.AfterMainWindow;
begin
  if AddRibbonButton(AmsIniStr('Caption', 'Webhook'),
                     AmsIniStr('Hint', 'Sendet eine HTTP-Anfrage'),
                     AmsIniStr('LargeGlyph', 'icon32.png')) = nil then
    Log('Kein Ribbon-Button: ' + LastError);
end;

procedure TWebHookPlugin.ButtonClick(ASender: Pointer; ATag: Integer);
begin
  if not AmsHttpRequestAsync(AmsIniStr('HttpMethod', 'GET'),
                             AmsIniStr('Url', ''),
                             AmsIniStr('HttpHeaders', ''),
                             AmsIniStr('HttpBody', ''),
                             HttpDone) then
    ShowError('Die Anfrage konnte nicht gestartet werden:' + sLineBreak +
              sLineBreak + LastError);
end;

{ Laeuft im Hintergrundthread: hier nichts anfassen, was der VCL gehoert.
  Ergebnis per PostMessage in den UI-Thread schaufeln. }
procedure TWebHookPlugin.HttpDone(ASuccess: Boolean; AStatus: Integer;
  const AResponse: string; ATag: Integer);
begin
  FLastOk := ASuccess;
  FLastStatus := AStatus;
  if MainWindow <> 0 then
    PostMessageW(MainWindow, WM_HTTP_DONE, WPARAM(Ord(ASuccess)), AStatus);
end;

function TWebHookPlugin.WantsWindowHook: Boolean;
begin
  Result := True;      { fuer WM_HTTP_DONE }
end;

function TWebHookPlugin.WindowMessage(AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM; var AHandled: Boolean): LRESULT;
begin
  Result := 0;
  AHandled := False;
  if AMsg <> WM_HTTP_DONE then Exit;
  AHandled := True;
  if AmsIniBool('ShowResult', True) then
  begin
    if FLastOk then
      ShowInfo(Format('Anfrage gesendet, Status %d.', [FLastStatus]))
    else
      ShowWarning('Die Anfrage ist fehlgeschlagen. Details im Log:' +
                  sLineBreak + sLineBreak + AmsIniStr('Url', ''));
  end;
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(TWebHookPlugin);
end.
