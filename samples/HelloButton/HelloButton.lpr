library HelloButton;

{ Kleinstes vollstaendiges AMS.5-Plugin auf Basis von AmsApi.
  Baut einen Ribbon-Button in die Gruppe "Benutzerdefiniert" und zeigt beim
  Klick eine Meldung. Ohne Delphi, ohne RAD Studio, ohne Hersteller-SDK. }

{$MODE DELPHI}
{$H+}

uses
  AmsApi.Plugin;

type
  THelloPlugin = class(TAmsPlugin)
  protected
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
  end;

procedure THelloPlugin.AfterMainWindow;
begin
  if AddRibbonButton('Hallo', 'Zeigt eine Meldung', 'icon32.png') = nil then
    Log('Kein Ribbon-Button: ' + LastError);
end;

procedure THelloPlugin.ButtonClick(ASender: Pointer; ATag: Integer);
begin
  ShowInfo('Hallo aus dem Plugin.');
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(THelloPlugin);
end.
