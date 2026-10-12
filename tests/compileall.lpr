program compileall;

{ Uebersetzt jede Unit der Bibliothek. Faengt Fehler, die sonst erst beim
  Bauen eines Plugins auffallen wuerden, das die Unit gerade nicht benutzt. }
{$MODE DELPHI}{$H+}
uses
  AmsApi.Types, AmsApi.Log, AmsApi.Ini, AmsApi.Bind, AmsApi.Strings,
  AmsApi.Hook, AmsApi.Trace, AmsApi.Recorder, AmsApi.TraceWindow,
  AmsApi.Rtti, AmsApi.Props, AmsApi.Components, AmsApi.Ui,
  AmsApi.Glyphs, AmsApi.Menus,
  AmsApi.Ribbon, AmsApi.Factory, AmsApi.Actions, AmsApi.Workflow,
  AmsApi.Automatismus,
  AmsApi.GameWindow, AmsApi.Wad, AmsApi.DoomEngine, AmsApi.DoomCore,
  AmsApi.Http, AmsApi.Plugin, AmsApi.GdvTrace,
  AmsApi.Files, AmsApi.Zip, AmsApi.IniDoc, AmsApi.Process, AmsApi.Dialogs,
  AmsApi.Markdown, AmsApi.Browser, AmsApi.WinCtl, AmsApi.IniEditor,
  AmsApi.PluginStore, AmsApi.PluginApply, AmsApi.PluginManager;
begin
  WriteLn('AmsApi ', AMS_API_VERSION, ' - alle Units uebersetzt.');
end.
