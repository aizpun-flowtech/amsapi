library PluginManager;

{ Beispiel: Plugin Manager im Ribbon.

  Ein Knopf oeffnet den Plugin-Browser: Plugins aus Katalogen (GitHub-Repos,
  Webserver, Netzlaufwerk) suchen, mit Bild, Beschreibung, Version und
  gerenderter README ansehen, installieren, aktualisieren, entfernen und
  ihre plugin.ini bearbeiten. Nach jeder Aenderung fragt er, ob AMS gleich
  neu starten soll.

  Alles Koennen steckt in den Units der Bibliothek (AmsApi.PluginManager,
  .PluginStore, .PluginApply, .IniEditor ...). Hier wird nur verdrahtet.
  Woher die Plugins kommen, steht in der plugin.ini daneben ([Katalog]).

  Daneben liegt AmsPluginApply.exe: BIN\plugins ist fuer normale Benutzer
  schreibgeschuetzt, das Kopieren laeuft dann dort mit UAC-Abfrage. }

{$MODE DELPHI}
{$H+}
{$codepage utf8}

uses
  Windows, SysUtils, AmsApi.Plugin, AmsApi.Ini, AmsApi.PluginManager,
  AmsApi.IniEditor;

type
  TPluginManagerPlugin = class(TAmsPlugin)
  protected
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
    procedure BeforeUnload; override;
  end;

procedure TPluginManagerPlugin.AfterMainWindow;
begin
  if AddRibbonButton(AmsIniStr('Caption', 'Plugin Manager'),
       AmsIniStr('Hint', 'Plugins suchen, installieren, aktualisieren und einstellen'),
       AmsIniStr('LargeGlyph', 'icon32.png')) = nil then
    Log('Kein Ribbon-Button: ' + LastError);
end;

procedure TPluginManagerPlugin.ButtonClick(ASender: Pointer; ATag: Integer);
var
  O: TAmsPluginManagerOptions;
begin
  O := AmsPluginManagerDefaults;
  O.HostWindow := MainWindow;     { fuer "Jetzt neu starten" }
  if not AmsPluginManagerOpen(MainWindow, O) then
    ShowLastError('Der Plugin Manager konnte nicht geöffnet werden.');
end;

procedure TPluginManagerPlugin.BeforeUnload;
begin
  { Fensterprozeduren und Threads liegen in diesem Modul }
  AmsPluginManagerClose;
  AmsIniEditorCloseAll;
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(TPluginManagerPlugin);
end.
