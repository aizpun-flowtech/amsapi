program AmsPluginApply;

{ Hilfsprogramm des Plugin Managers. Liegt neben PluginManager.bpl.

    AmsPluginApply.exe --apply   <warteschlange.ini>
        Plugins in BIN\plugins installieren, ersetzen, entfernen oder ihre
        plugin.ini schreiben. Der Plugin Manager startet es per UAC, wenn
        der Ordner fuer den Anwender schreibgeschuetzt ist.
    AmsPluginApply.exe --restart <neustart.ini>
        Auf das Ende von AMS warten und es dann neu starten - ohne erhoehte
        Rechte.

  Das Manifest (asInvoker) ist PFLICHT: ohne Manifest "virtualisiert"
  Windows ein 32-Bit-Programm, das Schreiben nach Program Files gelingt
  scheinbar und landet still in %LOCALAPPDATA%\VirtualStore.

  Alles Koennen steckt in AmsApi.PluginApply und AmsApi.Process. }

{$MODE DELPHI}
{$H+}
{$APPTYPE GUI}
{$R AmsPluginApply.rc}

uses
  SysUtils, AmsApi.Log, AmsApi.Files, AmsApi.Process, AmsApi.PluginApply;

begin
  AmsSetLogFile(IncludeTrailingPathDelimiter(GetTempDir) + 'AmsPluginApply.log');
  AmsDisableVirtualization;
  AmsLogFmt('AmsPluginApply %s %s (erhoeht: %s)',
            [ParamStr(1), ParamStr(2), BoolToStr(AmsIsElevated, True)]);
  if ParamStr(1) = '--apply' then Halt(AmsApplyHelperRun(ParamStr(2)));
  if ParamStr(1) = '--restart' then Halt(AmsRestartHelperRun(ParamStr(2)));
  Halt(64);
end.
