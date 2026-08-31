unit AmsApi.Ini;

{ ============================================================================
  AmsApi.Ini - Konfiguration aus plugin.ini und Pfadaufloesung

  Bewusst NICHT TStrings.Values: das vergleicht den Schluesselnamen buchstaeb-
  lich, ein fuehrendes Leerzeichen ("  Url = x") wuerde den Wert stillschwei-
  gend verschlucken und den Default liefern. Hier wird jede Zeile getrimmt,
  Kommentare (; und #) werden uebersprungen, der Vergleich ist
  case-insensitiv, und die erste Fundstelle gewinnt.

  Abschnitte ([...]) werden erkannt: ohne Angabe wird die ganze Datei
  durchsucht, mit Angabe nur der genannte Abschnitt.

  Diese Unit hat keine Beruehrung mit dem Host und ist ohne AMS testbar.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

{ Pfad der plugin.ini neben dem Plugin-Modul. }
function AmsIniFile: string;

{ Lesen aus einer beliebigen INI-Datei. ASection = '' durchsucht alles. }
function AmsIniValue(const AFile, AKey, ADefault: string;
  const ASection: string = ''): string;

{ Lesen aus der plugin.ini des eigenen Moduls. }
function AmsIniStr(const AKey: string; const ADefault: string = '';
  const ASection: string = ''): string;
function AmsIniInt(const AKey: string; ADefault: Integer;
  const ASection: string = ''): Integer;
function AmsIniBool(const AKey: string; ADefault: Boolean;
  const ASection: string = ''): Boolean;

{ Alle Schluessel/Werte eines Abschnitts als Name=Wert-Zeilen. }
procedure AmsIniSection(const AFile, ASection: string; ADest: TStrings);

{ Absoluter Pfad? C:\... oder \\Server\... }
function AmsIsAbsolutePath(const APath: string): Boolean;

{ Pfad aus der Konfiguration aufloesen:
  - absolut wird unveraendert genommen
  - sonst relativ zum PLUGIN-Ordner, nicht zum Arbeitsverzeichnis von AMS
  - fuehrendes "./" bzw. ".\" wird entfernt, "/" zu "\" normalisiert }
function AmsResolvePath(const APath: string): string;

implementation

uses
  AmsApi.Log;

function AmsIniFile: string;
begin
  Result := AmsModuleDir + 'plugin.ini';
end;

function AmsIsAbsolutePath(const APath: string): Boolean;
begin
  Result := ((Length(APath) >= 3) and (APath[2] = ':')) or
            ((Length(APath) >= 2) and (APath[1] = '\') and (APath[2] = '\'));
end;

function AmsResolvePath(const APath: string): string;
var
  S: string;
begin
  S := Trim(APath);
  if S = '' then Exit('');
  S := StringReplace(S, '/', '\', [rfReplaceAll]);
  while (Length(S) >= 2) and (S[1] = '.') and (S[2] = '\') do
    Delete(S, 1, 2);
  if AmsIsAbsolutePath(S) then
    Result := S
  else
    Result := AmsModuleDir + S;
end;

{ Kern des Parsers. ADest <> nil sammelt einen ganzen Abschnitt ein,
  sonst wird nach AKey gesucht. }
function ScanIni(const AFile, ASection, AKey: string; ADest: TStrings;
  var AValue: string): Boolean;
var
  Lines: TStringList;
  Line, Key, Val, Cur: string;
  i, p: Integer;
  InSection: Boolean;
begin
  Result := False;
  if not FileExists(AFile) then Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(AFile);
    except
      Exit;
    end;
    Cur := '';
    InSection := ASection = '';
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if Line = '' then Continue;
      if (Line[1] = ';') or (Line[1] = '#') then Continue;
      if (Line[1] = '[') and (Line[Length(Line)] = ']') then
      begin
        Cur := Trim(Copy(Line, 2, Length(Line) - 2));
        InSection := (ASection = '') or SameText(Cur, ASection);
        Continue;
      end;
      if not InSection then Continue;
      p := Pos('=', Line);
      if p < 2 then Continue;
      Key := Trim(Copy(Line, 1, p - 1));
      Val := Trim(Copy(Line, p + 1, MaxInt));
      if ADest <> nil then
      begin
        ADest.Add(Key + '=' + Val);
        Result := True;
        Continue;
      end;
      if not SameText(Key, AKey) then Continue;
      AValue := Val;
      Exit(True);                    { erste Fundstelle gewinnt }
    end;
  finally
    Lines.Free;
  end;
end;

function AmsIniValue(const AFile, AKey, ADefault: string;
  const ASection: string): string;
var
  Val: string;
begin
  Val := '';
  if ScanIni(AFile, ASection, AKey, nil, Val) and (Val <> '') then
    Result := Val
  else
    Result := ADefault;
end;

procedure AmsIniSection(const AFile, ASection: string; ADest: TStrings);
var
  Dummy: string;
begin
  if ADest = nil then Exit;
  Dummy := '';
  ScanIni(AFile, ASection, '', ADest, Dummy);
end;

function AmsIniStr(const AKey, ADefault, ASection: string): string;
begin
  Result := AmsIniValue(AmsIniFile, AKey, ADefault, ASection);
end;

function AmsIniInt(const AKey: string; ADefault: Integer;
  const ASection: string): Integer;
begin
  Result := StrToIntDef(AmsIniStr(AKey, '', ASection), ADefault);
end;

function AmsIniBool(const AKey: string; ADefault: Boolean;
  const ASection: string): Boolean;
var
  S: string;
begin
  S := LowerCase(AmsIniStr(AKey, '', ASection));
  if (S = '1') or (S = 'ja') or (S = 'true') or (S = 'yes') or (S = 'ein') then
    Result := True
  else if (S = '0') or (S = 'nein') or (S = 'false') or (S = 'no') or (S = 'aus') then
    Result := False
  else
    Result := ADefault;
end;

end.
