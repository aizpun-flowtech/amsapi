program mkrelease;

{ ============================================================================
  Release-Assets fuer den Plugin Manager bauen.

    mkrelease.exe <deploy-ordner> <release-ordner> <Name>

  Legt an:
    <release>\<Name>.zip   der ganze Plugin-Ordner (BPL, plugin.ini, Bild,
                           README) - das installiert der Plugin Manager
    <release>\<Name>.ini   die plugin.ini allein - daraus liest er Version
                           und Beschreibung, ohne das ZIP zu laden
  und schreibt die SHA-256 des ZIP nach <release>\SHA256SUMS.txt - fuer
  Sha256= im Katalog, wer die Version festnageln will.

  Gepackt wird mit AmsApi.Zip, also genau dem Format, das der Plugin
  Manager selbst entpackt. Hochladen: gh release create v1.0.0 build\release\*

  NICHT ins Paket kommt, was im Deploy-Ordner nur zufaellig liegt: eine
  dort abgelegte WAD (Doom), Logs, .old-Reste, Quelltext. Siehe SKIP.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, Classes, AmsApi.Log, AmsApi.Files, AmsApi.Zip;

const
  SKIP: array[0..8] of string =
    ('.wad', '.log', '.old', '.tmp', '.part', '.lpr', '.pas', '.o', '.ppu');

function Skipped(const AFile: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(SKIP) do
    if SameText(ExtractFileExt(AFile), SKIP[i]) then Exit(True);
  Result := False;
end;

var
  Src, Dst, Name, Zip, Hash, Stage: string;
  Sums, Files: TStringList;
  i: Integer;
begin
  if ParamCount < 3 then
  begin
    WriteLn('Aufruf: mkrelease <deploy-ordner> <release-ordner> <Name>');
    Halt(2);
  end;
  AmsLogEnabled := False;
  Src := IncludeTrailingPathDelimiter(ParamStr(1));
  Dst := IncludeTrailingPathDelimiter(ParamStr(2));
  Name := ParamStr(3);
  if not FileExists(Src + 'plugin.ini') then
  begin
    WriteLn('FEHLER: ', Src, 'plugin.ini fehlt');
    Halt(1);
  end;
  AmsForceDir(Dst);
  { Nur, was zum Plugin gehoert, in einen Zwischenordner }
  Stage := IncludeTrailingPathDelimiter(GetTempDir) + 'amsapi_mkrelease\' + Name + '\';
  AmsDeleteTree(Stage);
  Files := TStringList.Create;
  try
    AmsListFiles(Src, Files, True);
    for i := 0 to Files.Count - 1 do
      if Skipped(Files[i]) then
        WriteLn('      ausgelassen: ', Files[i])
      else
      begin
        AmsForceDir(ExtractFilePath(Stage + Files[i]));
        CopyFileW(PWideChar(WideString(Src + Files[i])),
                  PWideChar(WideString(Stage + Files[i])), False);
      end;
  finally
    Files.Free;
  end;
  Zip := Dst + Name + '.zip';
  DeleteFile(Zip);
  if not AmsZipCreate(Stage, Zip) then
  begin
    WriteLn('FEHLER: ', AmsLastError);
    Halt(1);
  end;
  if not CopyFileW(PWideChar(WideString(Src + 'plugin.ini')),
                   PWideChar(WideString(Dst + Name + '.ini')), False) then
  begin
    WriteLn('FEHLER: ', Name, '.ini nicht kopierbar');
    Halt(1);
  end;
  if not AmsSha256File(Zip, Hash) then
  begin
    WriteLn('FEHLER: ', AmsLastError);
    Halt(1);
  end;
  Sums := TStringList.Create;
  try
    if FileExists(Dst + 'SHA256SUMS.txt') then
      Sums.LoadFromFile(Dst + 'SHA256SUMS.txt');
    for i := Sums.Count - 1 downto 0 do
      if Pos(' ' + Name + '.zip', Sums[i]) > 0 then Sums.Delete(i);
    Sums.Add(Hash + '  ' + Name + '.zip');
    Sums.SaveToFile(Dst + 'SHA256SUMS.txt');
  finally
    Sums.Free;
  end;
  AmsDeleteTree(Stage);
  WriteLn('      release: ', Name, '.zip + ', Name, '.ini  sha256 ', Hash);
end.
