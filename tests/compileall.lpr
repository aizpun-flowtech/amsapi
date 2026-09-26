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
  AmsApi.Http, AmsApi.Plugin;
begin
  WriteLn('AmsApi ', AMS_API_VERSION, ' - alle Units uebersetzt.');
end.
