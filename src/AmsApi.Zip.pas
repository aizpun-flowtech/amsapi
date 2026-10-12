unit AmsApi.Zip;

{ ============================================================================
  AmsApi.Zip - ZIP-Archive pruefen, entpacken, packen

  Auf der FPC-eigenen Unit zipper (paszlib) - keine fremde DLL, kein
  Shell-COM, kein tar.exe.

  Entpackt wird nur, was vorher geprueft ist. Ein Archiv aus dem Netz kann
  Eintraege wie "..\..\Windows\x.dll" oder "C:\x" enthalten ("Zip Slip").
  AmsZipExtract lehnt dann das GANZE Archiv ab, bevor eine einzige Datei
  geschrieben ist - halb entpackt waere schlimmer als gar nicht. Ebenso
  abgelehnt: mehr als AMS_ZIP_MAX_BYTES ausgepackt (Zip-Bombe).

  Eintragsnamen mit "\" statt "/" (so schreibt Compress-Archive aus
  PowerShell 5.1) und fuehrendes "./" (tar.exe) werden beide verstanden.

  Ohne Host, ohne AMS testbar.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

var
  { Obergrenze fuer die ausgepackte Gesamtgroesse. }
  AmsZipMaxBytes: Int64 = 512 * 1024 * 1024;

{ Eintraege auflisten (normalisiert: \ als Trenner, ohne fuehrendes .\).
  Ordnereintraege enden auf \. }
function AmsZipList(const AZipFile: string; ADest: TStrings): Boolean;

{ Pruefen und entpacken. ADestDir wird angelegt. AFiles (optional) bekommt
  die entpackten Dateien relativ zu ADestDir. }
function AmsZipExtract(const AZipFile, ADestDir: string;
  AFiles: TStrings = nil): Boolean;

{ Ordnerinhalt (rekursiv) als Archiv. Namen relativ zu ASourceDir, mit /. }
function AmsZipCreate(const ASourceDir, AZipFile: string): Boolean;

implementation

uses
  Zipper, AmsApi.Log, AmsApi.Files;

function NormName(const AName: string): string;
begin
  Result := StringReplace(AName, '/', '\', [rfReplaceAll]);
  while (Length(Result) >= 2) and (Result[1] = '.') and (Result[2] = '\') do
    Delete(Result, 1, 2);
end;

function AmsZipList(const AZipFile: string; ADest: TStrings): Boolean;
var
  U: TUnZipper;
  i: Integer;
  N: string;
begin
  Result := False;
  if ADest = nil then Exit;
  if not FileExists(AZipFile) then
    Exit(AmsFailFmt('ZIP fehlt: %s', [AZipFile]));
  U := TUnZipper.Create;
  try
    try
      U.FileName := AZipFile;
      U.Examine;
      for i := 0 to U.Entries.Count - 1 do
      begin
        N := NormName(U.Entries[i].ArchiveFileName);
        if N = '' then Continue;
        if U.Entries[i].IsDirectory and (N[Length(N)] <> '\') then N := N + '\';
        ADest.Add(N);
      end;
      Result := True;
    except
      on E: Exception do
        Result := AmsFailFmt('ZIP nicht lesbar (%s): %s', [E.Message, AZipFile]);
    end;
  finally
    U.Free;
  end;
end;

function AmsZipExtract(const AZipFile, ADestDir: string;
  AFiles: TStrings): Boolean;
var
  U: TUnZipper;
  i: Integer;
  N, D: string;
  Total: Int64;
begin
  Result := False;
  if not FileExists(AZipFile) then
    Exit(AmsFailFmt('ZIP fehlt: %s', [AZipFile]));
  D := IncludeTrailingPathDelimiter(ADestDir);
  U := TUnZipper.Create;
  try
    try
      U.FileName := AZipFile;
      U.Examine;
      if U.Entries.Count = 0 then
        Exit(AmsFailFmt('ZIP ist leer: %s', [AZipFile]));

      { ERST pruefen, DANN schreiben - siehe Kopf der Unit. }
      Total := 0;
      for i := 0 to U.Entries.Count - 1 do
      begin
        N := NormName(U.Entries[i].ArchiveFileName);
        if N = '' then Continue;
        if not AmsIsSafeRelPath(N) then
          Exit(AmsFailFmt('ZIP abgelehnt - Eintrag zeigt aus dem Zielordner ' +
                          'heraus: "%s"', [U.Entries[i].ArchiveFileName]));
        if U.Entries[i].IsLink then
          Exit(AmsFailFmt('ZIP abgelehnt - enthaelt einen Link: "%s"',
                          [U.Entries[i].ArchiveFileName]));
        Inc(Total, U.Entries[i].Size);
        if Total > AmsZipMaxBytes then
          Exit(AmsFailFmt('ZIP abgelehnt - ausgepackt groesser als %d Bytes',
                          [AmsZipMaxBytes]));
      end;

      if not AmsForceDir(D) then Exit;
      U.OutputPath := ExcludeTrailingPathDelimiter(D);
      U.UnZipAllFiles;

      if AFiles <> nil then
        for i := 0 to U.Entries.Count - 1 do
        begin
          N := NormName(U.Entries[i].ArchiveFileName);
          if (N <> '') and not U.Entries[i].IsDirectory and
             (N[Length(N)] <> '\') then
            AFiles.Add(N);
        end;
      AmsLogFmt('ZIP entpackt: %s -> %s (%d Eintraege, %d Bytes)',
                [AZipFile, D, U.Entries.Count, Total]);
      Result := True;
    except
      on E: Exception do
        Result := AmsFailFmt('ZIP nicht entpackbar (%s): %s',
                             [E.Message, AZipFile]);
    end;
  finally
    U.Free;
  end;
end;

function AmsZipCreate(const ASourceDir, AZipFile: string): Boolean;
var
  Z: TZipper;
  L: TStringList;
  i: Integer;
  S: string;
begin
  Result := False;
  S := IncludeTrailingPathDelimiter(ASourceDir);
  if not DirectoryExists(S) then
    Exit(AmsFailFmt('Ordner fehlt: %s', [ASourceDir]));
  if not AmsForceDir(ExtractFilePath(AZipFile)) then Exit;
  L := TStringList.Create;
  Z := TZipper.Create;
  try
    try
      AmsListFiles(S, L, True);
      if L.Count = 0 then Exit(AmsFailFmt('Ordner ist leer: %s', [ASourceDir]));
      Z.FileName := AZipFile;
      for i := 0 to L.Count - 1 do
        Z.Entries.AddFileEntry(S + L[i],
                               StringReplace(L[i], '\', '/', [rfReplaceAll]));
      Z.ZipAllFiles;
      Result := True;
    except
      on E: Exception do
        Result := AmsFailFmt('ZIP nicht erzeugbar (%s): %s', [E.Message, AZipFile]);
    end;
  finally
    Z.Free;
    L.Free;
  end;
end;

end.
