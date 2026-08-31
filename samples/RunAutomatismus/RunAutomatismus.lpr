library RunAutomatismus;

{ Beispiel: Ribbon-Button startet einen Automatismus IM AKTUELLEN KONTEXT -
  genau so, als haette der Anwender ihn unter "Automatismus ausfuehren"
  angeklickt.

  Der Name steht in der plugin.ini (AutomatismusName=). Ist er hier nicht
  verfuegbar, zeigt das Plugin die im Kontext angebotenen Automatismen an -
  das ist meistens die eigentliche Antwort auf "geht nicht": es ist kein
  Kunde / Vertrag / Vorgang geoeffnet. }

{$MODE DELPHI}
{$H+}

uses
  SysUtils, Classes, AmsApi.Plugin, AmsApi.Ini;

type
  TAutoPlugin = class(TAmsPlugin)
  protected
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
  end;

procedure TAutoPlugin.AfterMainWindow;
begin
  if AddRibbonButton(AmsIniStr('Caption', 'Automatismus'),
                     AmsIniStr('Hint', 'Startet den konfigurierten Automatismus'),
                     AmsIniStr('LargeGlyph', 'icon32.png')) = nil then
    Log('Kein Ribbon-Button: ' + LastError);
end;

procedure TAutoPlugin.ButtonClick(ASender: Pointer; ATag: Integer);
var
  Name, Msg: string;
  Verfuegbar: TStringList;
  i: Integer;
begin
  Name := AmsIniStr('AutomatismusName', '');
  if Name = '' then
  begin
    ShowWarning('Es ist kein Automatismus konfiguriert.' + sLineBreak +
                'Bitte AutomatismusName= in der plugin.ini eintragen.');
    Exit;
  end;

  Verfuegbar := TStringList.Create;
  try
    if RunAutomatismusEx(Name, Verfuegbar) then Exit;

    Msg := LastError;
    if Verfuegbar.Count > 0 then
    begin
      Msg := Msg + sLineBreak + sLineBreak + 'Verfuegbar sind:';
      for i := 0 to Verfuegbar.Count - 1 do
      begin
        if i >= 20 then
        begin
          Msg := Msg + sLineBreak + '... und weitere';
          Break;
        end;
        Msg := Msg + sLineBreak + '  - ' + Verfuegbar[i];
      end;
    end;
    ShowWarning(Msg);
  finally
    Verfuegbar.Free;
  end;
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(TAutoPlugin);
end.
