unit AmsApi.IniDoc;

{ ============================================================================
  AmsApi.IniDoc - INI-Dateien BEARBEITEN, ohne sie zu zerstoeren

  AmsApi.Ini liest. Diese Unit schreibt - und zwar so, dass die Datei danach
  noch dieselbe ist: Kommentare, Leerzeilen, Reihenfolge, Schreibweise der
  Schluessel und eine vorhandene UTF-8-BOM bleiben stehen. Geaendert wird
  nur der Wert hinter dem ersten "=" der betroffenen Zeile. TIniFile oder
  TMemIniFile wuerden die Kommentare wegwerfen - und in den plugin.ini-
  Dateien dieser Bibliothek STEHT die Bedienungsanleitung in den
  Kommentaren.

  Regeln wie in AmsApi.Ini: Zeilen werden getrimmt verglichen, ; und #
  leiten Kommentare ein, Schluessel sind case-insensitiv, die erste
  Fundstelle gewinnt. Kein Inline-Kommentar - alles hinter "=" ist Wert.

  Zu jedem Eintrag liefert das Dokument den Kommentarblock direkt darueber
  (ohne Leerzeile dazwischen) als Beschreibung. Trennlinien aus = - * #
  fallen dabei weg. Damit kann ein Einstellungsfenster zu jedem Schluessel
  erklaeren, was er tut, ohne dass das irgendwo zweimal steht.

  Zusaetzlich AmsIniMergeUserValues fuer Aktualisierungen: die neue
  plugin.ini einer Version bringt neue Schluessel und neue Kommentare mit,
  die Werte, die der Anwender geaendert hat, werden aus der alten
  uebernommen.

  Bytes werden nicht umkodiert (siehe AmsApi.Files). Ohne AMS testbar.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

type
  TAmsIniEntry = record
    Section: string;    { '' = vor dem ersten Abschnitt }
    Key: string;        { wie in der Datei geschrieben }
    Value: string;      { getrimmt }
    Comment: string;    { Kommentarblock direkt darueber, Zeilen mit #10 }
    Line: Integer;      { Index in Lines }
  end;

  TAmsIniDoc = class
  private
    FLines: TStringList;
    FEntries: array of TAmsIniEntry;
    FBom: Boolean;
    FLineBreak: string;
    procedure Parse;
    function FindSectionEnd(const ASection: string; out AFound: Boolean): Integer;
  public
    constructor Create;
    destructor Destroy; override;

    function LoadFromFile(const AFile: string): Boolean;
    procedure LoadFromText(const AText: string);
    function SaveToFile(const AFile: string): Boolean;
    { Gesamter Inhalt, wie er gespeichert wuerde (mit BOM, falls vorhanden). }
    function Text: string;

    function Count: Integer;
    function Entry(AIndex: Integer): TAmsIniEntry;
    { Index des ersten Eintrags oder -1. }
    function IndexOf(const ASection, AKey: string): Integer;
    function GetValue(const ASection, AKey: string;
      const ADefault: string = ''): string;
    { Wert setzen. Gibt es den Schluessel, wird nur dessen Wert ersetzt;
      sonst wird er am Ende seines Abschnitts angehaengt (Abschnitt wird bei
      Bedarf angelegt). Liefert True, wenn sich etwas geaendert hat. }
    function SetValue(const ASection, AKey, AValue: string): Boolean;
    { Abschnitte in Reihenfolge des Auftretens, '' fuer den Kopf, falls dort
      Schluessel stehen. }
    procedure Sections(ADest: TStrings);
    { Kommentarblock direkt ueber dem Abschnittskopf. }
    function SectionComment(const ASection: string): string;

    property Lines: TStringList read FLines;
    property HasBom: Boolean read FBom write FBom;
  end;

{ Benutzerwerte in eine neue Fassung uebernehmen. Fuer jeden Eintrag in
  ANew, den es (Abschnitt + Schluessel) auch in AOld gibt und dessen Wert
  dort anders ist, wird der alte Wert gesetzt. Eintraege, die NUR in AOld
  stehen (vom Anwender ergaenzt, etwa eigene [Patch]-Zeilen), werden in
  ihrem Abschnitt angehaengt. Ausgenommen ist AOwned - was das Paket
  bestimmt: 'Version' (Schluessel in jedem Abschnitt), 'Info.*' (ganzer
  Abschnitt) oder '.Version' (nur im Kopf).
  Liefert die Anzahl uebernommener Werte. }
function AmsIniMergeUserValues(ANew, AOld: TAmsIniDoc;
  const AOwned: array of string): Integer;

{ Passt Abschnitt/Schluessel auf eines der Muster? Schreibweise wie bei
  AOwned oben: 'Key' (jeder Abschnitt), '.Key' (Kopf), 'Sec.Key', 'Sec.*'. }
function AmsIniKeyMatches(const ASection, AKey: string;
  const APatterns: array of string): Boolean;

implementation

uses
  AmsApi.Log, AmsApi.Files;

function IsComment(const ALine: string): Boolean;
begin
  Result := (ALine <> '') and ((ALine[1] = ';') or (ALine[1] = '#'));
end;

function IsSectionHead(const ALine: string; out AName: string): Boolean;
begin
  Result := (Length(ALine) >= 2) and (ALine[1] = '[') and
            (ALine[Length(ALine)] = ']');
  if Result then AName := Trim(Copy(ALine, 2, Length(ALine) - 2))
  else AName := '';
end;

{ ";  Text" -> "Text"; reine Trennlinien -> '' }
function CommentText(const ALine: string): string;
var
  i: Integer;
  OnlyRule: Boolean;
begin
  Result := ALine;
  while (Result <> '') and ((Result[1] = ';') or (Result[1] = '#')) do
    Delete(Result, 1, 1);
  Result := TrimRight(Result);
  if (Result <> '') and (Result[1] = ' ') then Delete(Result, 1, 1);
  OnlyRule := Trim(Result) <> '';
  for i := 1 to Length(Result) do
    if not (Result[i] in ['=', '-', '*', '#', ' ', '_', '~']) then
    begin
      OnlyRule := False;
      Break;
    end;
  if OnlyRule then Result := '#RULE#';
end;

{ Kommentarblock oberhalb von Zeile AIndex einsammeln. }
function CommentAbove(ALines: TStrings; AIndex: Integer): string;
var
  i: Integer;
  L: TStringList;
  T: string;
begin
  Result := '';
  L := TStringList.Create;
  try
    i := AIndex - 1;
    while (i >= 0) and IsComment(Trim(ALines[i])) do
    begin
      T := CommentText(Trim(ALines[i]));
      if T <> '#RULE#' then L.Insert(0, T);
      Dec(i);
    end;
    { fuehrende und abschliessende Leerzeilen weg }
    while (L.Count > 0) and (Trim(L[0]) = '') do L.Delete(0);
    while (L.Count > 0) and (Trim(L[L.Count - 1]) = '') do L.Delete(L.Count - 1);
    for i := 0 to L.Count - 1 do
    begin
      if i > 0 then Result := Result + #10;
      Result := Result + L[i];
    end;
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------- TAmsIniDoc - }

constructor TAmsIniDoc.Create;
begin
  inherited Create;
  FLines := TStringList.Create;
  FLineBreak := #13#10;
end;

destructor TAmsIniDoc.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

procedure TAmsIniDoc.LoadFromText(const AText: string);
var
  S: string;
begin
  FBom := AmsHasUtf8Bom(AText);
  S := AmsStripBom(AText);
  if (Pos(#13#10, S) = 0) and (Pos(#10, S) > 0) then FLineBreak := #10
  else FLineBreak := #13#10;
  FLines.Text := S;
  Parse;
end;

function TAmsIniDoc.LoadFromFile(const AFile: string): Boolean;
var
  Data: string;
begin
  Result := AmsReadFileRaw(AFile, Data, 4 * 1024 * 1024);
  if Result then LoadFromText(Data)
  else LoadFromText('');
end;

function TAmsIniDoc.Text: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FLines.Count - 1 do
    Result := Result + FLines[i] + FLineBreak;
  if FBom then Result := #$EF#$BB#$BF + Result;
end;

function TAmsIniDoc.SaveToFile(const AFile: string): Boolean;
begin
  Result := AmsWriteFileRaw(AFile, Text);
end;

procedure TAmsIniDoc.Parse;
var
  i, n, p: Integer;
  Line, Sec, Name: string;
begin
  SetLength(FEntries, 0);
  n := 0;
  Sec := '';
  for i := 0 to FLines.Count - 1 do
  begin
    Line := Trim(FLines[i]);
    if (Line = '') or IsComment(Line) then Continue;
    if IsSectionHead(Line, Name) then
    begin
      Sec := Name;
      Continue;
    end;
    p := Pos('=', Line);
    if p < 2 then Continue;
    if n >= Length(FEntries) then SetLength(FEntries, n * 2 + 16);
    FEntries[n].Section := Sec;
    FEntries[n].Key := Trim(Copy(Line, 1, p - 1));
    FEntries[n].Value := Trim(Copy(Line, p + 1, MaxInt));
    FEntries[n].Comment := CommentAbove(FLines, i);
    FEntries[n].Line := i;
    Inc(n);
  end;
  SetLength(FEntries, n);
end;

function TAmsIniDoc.Count: Integer;
begin
  Result := Length(FEntries);
end;

function TAmsIniDoc.Entry(AIndex: Integer): TAmsIniEntry;
begin
  if (AIndex < 0) or (AIndex >= Length(FEntries)) then
  begin
    Result.Section := '';
    Result.Key := '';
    Result.Value := '';
    Result.Comment := '';
    Result.Line := -1;
  end
  else
    Result := FEntries[AIndex];
end;

function TAmsIniDoc.IndexOf(const ASection, AKey: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FEntries) do
    if SameText(FEntries[i].Section, ASection) and
       SameText(FEntries[i].Key, AKey) then
      Exit(i);
  Result := -1;
end;

function TAmsIniDoc.GetValue(const ASection, AKey, ADefault: string): string;
var
  i: Integer;
begin
  i := IndexOf(ASection, AKey);
  if (i >= 0) and (FEntries[i].Value <> '') then
    Result := FEntries[i].Value
  else
    Result := ADefault;
end;

{ Zeile hinter dem letzten Eintrag eines Abschnitts (vor nachfolgenden
  Leerzeilen/Kommentaren des naechsten Abschnitts). }
function TAmsIniDoc.FindSectionEnd(const ASection: string;
  out AFound: Boolean): Integer;
var
  i: Integer;
  Line, Name, Cur: string;
  InSec: Boolean;
  LastContent: Integer;
begin
  AFound := ASection = '';
  InSec := ASection = '';
  Cur := '';
  LastContent := -1;
  for i := 0 to FLines.Count - 1 do
  begin
    Line := Trim(FLines[i]);
    if IsSectionHead(Line, Name) then
    begin
      if InSec then Break;
      Cur := Name;
      if SameText(Cur, ASection) then
      begin
        InSec := True;
        AFound := True;
        LastContent := i;
      end;
      Continue;
    end;
    if InSec and (Line <> '') and not IsComment(Line) then LastContent := i;
  end;
  if not AFound then Exit(FLines.Count);
  { Kopf ohne Eintraege: direkt vor den ersten Abschnitt bzw. ans Ende }
  if (ASection = '') and (LastContent < 0) then
  begin
    for i := 0 to FLines.Count - 1 do
      if IsSectionHead(Trim(FLines[i]), Name) then Exit(i);
    Exit(FLines.Count);
  end;
  Result := LastContent + 1;
end;

function TAmsIniDoc.SetValue(const ASection, AKey, AValue: string): Boolean;
var
  i, p, At: Integer;
  Raw, Head: string;
  Found: Boolean;
begin
  i := IndexOf(ASection, AKey);
  if i >= 0 then
  begin
    if FEntries[i].Value = Trim(AValue) then Exit(False);
    { Nur den Wert tauschen, alles links vom "=" bleibt wie es war. }
    Raw := FLines[FEntries[i].Line];
    p := Pos('=', Raw);
    Head := Copy(Raw, 1, p);
    if (Length(Raw) > p) and (Raw[p + 1] = ' ') and (Trim(AValue) <> '') then
      Head := Head + ' ';
    FLines[FEntries[i].Line] := Head + Trim(AValue);
    Parse;
    Exit(True);
  end;

  At := FindSectionEnd(ASection, Found);
  if not Found then
  begin
    if (FLines.Count > 0) and (Trim(FLines[FLines.Count - 1]) <> '') then
      FLines.Add('');
    FLines.Add('[' + ASection + ']');
    At := FLines.Count;
  end;
  FLines.Insert(At, AKey + '=' + Trim(AValue));
  Parse;
  Result := True;
end;

procedure TAmsIniDoc.Sections(ADest: TStrings);
var
  i: Integer;
  Line, Name: string;
begin
  if ADest = nil then Exit;
  if (Length(FEntries) > 0) and (FEntries[0].Section = '') then ADest.Add('');
  for i := 0 to FLines.Count - 1 do
  begin
    Line := Trim(FLines[i]);
    if IsSectionHead(Line, Name) and (ADest.IndexOf(Name) < 0) then
      ADest.Add(Name);
  end;
end;

function TAmsIniDoc.SectionComment(const ASection: string): string;
var
  i: Integer;
  Name: string;
begin
  Result := '';
  for i := 0 to FLines.Count - 1 do
    if IsSectionHead(Trim(FLines[i]), Name) and SameText(Name, ASection) then
      Exit(CommentAbove(FLines, i));
end;

{ ------------------------------------------------------------- Uebernahme - }

function AmsIniKeyMatches(const ASection, AKey: string;
  const APatterns: array of string): Boolean;
var
  i, p: Integer;
  S, K: string;
begin
  for i := 0 to High(APatterns) do
  begin
    p := Pos('.', APatterns[i]);
    if p = 0 then
    begin
      if SameText(APatterns[i], AKey) then Exit(True);
      Continue;
    end;
    S := Copy(APatterns[i], 1, p - 1);
    K := Copy(APatterns[i], p + 1, MaxInt);
    if not SameText(S, ASection) then Continue;
    if (K = '*') or SameText(K, AKey) then Exit(True);
  end;
  Result := False;
end;

function AmsIniMergeUserValues(ANew, AOld: TAmsIniDoc;
  const AOwned: array of string): Integer;
var
  i, j: Integer;
  E: TAmsIniEntry;
  Pending: array of TAmsIniEntry;
begin
  Result := 0;
  if (ANew = nil) or (AOld = nil) then Exit;
  { Erst sammeln, dann setzen - SetValue baut die Eintragsliste neu. }
  SetLength(Pending, 0);
  for i := 0 to ANew.Count - 1 do
  begin
    E := ANew.Entry(i);
    if AmsIniKeyMatches(E.Section, E.Key, AOwned) then Continue;
    if ANew.IndexOf(E.Section, E.Key) <> i then Continue;   { Doppelte }
    j := AOld.IndexOf(E.Section, E.Key);
    if j < 0 then Continue;
    if AOld.Entry(j).Value = E.Value then Continue;
    SetLength(Pending, Length(Pending) + 1);
    Pending[High(Pending)] := E;
    Pending[High(Pending)].Value := AOld.Entry(j).Value;
  end;
  { Was der Anwender selbst ergaenzt hat }
  for j := 0 to AOld.Count - 1 do
  begin
    E := AOld.Entry(j);
    if AmsIniKeyMatches(E.Section, E.Key, AOwned) then Continue;
    if AOld.IndexOf(E.Section, E.Key) <> j then Continue;
    if ANew.IndexOf(E.Section, E.Key) >= 0 then Continue;
    SetLength(Pending, Length(Pending) + 1);
    Pending[High(Pending)] := E;
  end;
  for i := 0 to High(Pending) do
    if ANew.SetValue(Pending[i].Section, Pending[i].Key, Pending[i].Value) then
      Inc(Result);
  if Result > 0 then
    AmsLogFmt('INI: %d Benutzerwerte in die neue Fassung uebernommen', [Result]);
end;

end.
