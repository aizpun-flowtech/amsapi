unit AmsApi.Menus;

{ ============================================================================
  AmsApi.Menus - dxBar-Popupmenues lesen und ausloesen

  AMS fuellt seine Popupmenues zur Laufzeit kontextabhaengig. Wer einen
  Menuepunkt "wie von Hand geklickt" ausloesen will, baut die Fuellogik NICHT
  nach, sondern liest das fertige Menue und ruft TdxBarItem.DirectClick auf -
  derselbe Codepfad wie beim Mausklick, mit demselben Kontext.

  Zwei Fallstricke:
  - Nicht jedes Popupmenue ist ein dxBar-Menue. Ein VCL-TPopupMenu hat "Items"
    statt "ItemLinks"; GetObjectProp('ItemLinks') wirft dort EEDFADE. Deshalb
    Klassenfilter ('PopupMenu' UND ('dxBar' ODER 'dxRibbon')) plus try/except.
  - Delphi-Captions enthalten & als Tastenkuerzel. Beim Vergleich entfernen.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types;

type
  { Ein gefundener Menueeintrag. }
  TAmsMenuEntry = record
    Item: Pointer;      { TdxBarItem }
    Caption: string;    { ohne & }
    Index: Integer;
    Menu: Pointer;      { das Popupmenue, in dem er steckt }
    MenuName: string;
  end;
  TAmsMenuEntryArray = array of TAmsMenuEntry;

{ Alle dxBar-Popupmenues des Prozesses einsammeln.
  APreferred bekommt die mit dem Namen AMenuName, AOther alle uebrigen -
  so funktioniert es auch dort, wo das Menue anders heisst.
  AMenuName = '' liefert alles in AOther. }
procedure AmsCollectPopupMenus(const AMenuName: string;
  APreferred, AOther: TList);

{ Eintraege eines Menues auslesen. Liefert die Anzahl. }
function AmsReadMenu(AMenu: Pointer; var AEntries: TAmsMenuEntryArray): Integer;

{ Einen einzelnen Eintrag ausloesen (TdxBarItem.DirectClick). }
function AmsClickItem(AItem: Pointer): Boolean;

{ Bequemer Gesamtweg: alle passenden Menues lesen und die Eintraege sammeln.
  AMenuName = bevorzugter Menuename, '' = alle Menues. }
function AmsCollectMenuEntries(const AMenuName: string;
  var AEntries: TAmsMenuEntryArray): Integer;

{ Eintrag mit dieser Beschriftung suchen und klicken.
  Vergleich case-insensitiv, & wird ignoriert. }
function AmsClickMenuEntry(const AMenuName, ACaption: string): Boolean;

{ Beschriftung ohne & und ohne Tastenkuerzel-Zusatz. }
function AmsCleanCaption(const ACaption: string): string;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Components, AmsApi.Log;

function AmsCleanCaption(const ACaption: string): string;
begin
  Result := Trim(StringReplace(ACaption, '&', '', [rfReplaceAll]));
end;

procedure AddOnce(AList: TList; AItem: Pointer; AMax: Integer);
var
  i: Integer;
begin
  if (AList = nil) or (AItem = nil) or (AList.Count >= AMax) then Exit;
  for i := 0 to AList.Count - 1 do
    if AList[i] = AItem then Exit;
  AList.Add(AItem);
end;

{ Popupmenues unter den DIREKTEN Komponenten einer Wurzel. Der Frame, dem ein
  Menue gehoert, hat selbst ein Fensterhandle und steht damit in der
  Wurzelliste - eine Tiefensuche ist nicht noetig. }
procedure CollectFromRoot(ARoot: Pointer; const AMenuName: string;
  APreferred, AOther: TList);
var
  i, n: Integer;
  C: Pointer;
  Cls: string;
begin
  n := AmsComponentCount(ARoot);
  for i := 0 to n - 1 do
  begin
    C := AmsComponent(ARoot, i);
    if C = nil then Continue;
    Cls := AmsClassName(C);
    if Pos('PopupMenu', Cls) = 0 then Continue;
    { nur dxBar-Menues haben ItemLinks }
    if (Pos('dxBar', Cls) = 0) and (Pos('dxRibbon', Cls) = 0) then Continue;
    if (AMenuName <> '') and SameText(AmsName(C), AMenuName) then
      AddOnce(APreferred, C, 40)
    else
      AddOnce(AOther, C, 40);
  end;
end;

procedure AmsCollectPopupMenus(const AMenuName: string;
  APreferred, AOther: TList);
var
  Roots: TList;
  i: Integer;
  T0: QWord;
begin
  if (APreferred = nil) or (AOther = nil) then Exit;
  if not (AmsBindCore and AmsBindVcl) then Exit;
  Roots := TList.Create;
  try
    T0 := GetTickCount64;
    AmsBuildRootList(Roots);
    for i := 0 to Roots.Count - 1 do
      CollectFromRoot(Roots[i], AMenuName, APreferred, AOther);
    AmsLogFmt('Menuesuche: %d Wurzeln, %d passend, %d weitere, %d ms',
              [Roots.Count, APreferred.Count, AOther.Count,
               Int64(GetTickCount64 - T0)]);
  finally
    Roots.Free;
  end;
end;

function AmsReadMenu(AMenu: Pointer; var AEntries: TAmsMenuEntryArray): Integer;
var
  Links, Link, Item: Pointer;
  i, n, Base: Integer;
  MenuName: string;
begin
  Result := 0;
  if AMenu = nil then Exit;
  if not (AmsBindCore and AmsBindBars) then Exit;

  { GetObjectProp auf einem Nicht-dxBar-Menue wirft; AmsGetObj faengt das ab. }
  Links := AmsGetObj(AMenu, 'ItemLinks');
  if Links = nil then Exit;

  try
    n := hcCollectionCount(Links);
  except
    Exit;
  end;
  if (n <= 0) or (n > 500) then Exit;

  MenuName := AmsName(AMenu);
  Base := Length(AEntries);
  SetLength(AEntries, Base + n);
  for i := 0 to n - 1 do
  begin
    AEntries[Base + i].Item := nil;
    AEntries[Base + i].Caption := '';
    AEntries[Base + i].Index := i;
    AEntries[Base + i].Menu := AMenu;
    AEntries[Base + i].MenuName := MenuName;
    try
      Link := hcCollectionItem(Links, i);
      if Link = nil then Continue;
      Item := hcLinkGetItem(Link);
      if Item = nil then Continue;
      AEntries[Base + i].Item := Item;
      AEntries[Base + i].Caption := AmsCleanCaption(AmsGetStr(Item, 'Caption'));
    except
      on E: Exception do
        AmsLogFmt('Menueeintrag %d in "%s": %s', [i, MenuName, E.Message]);
    end;
  end;
  Result := n;
end;

function AmsClickItem(AItem: Pointer): Boolean;
begin
  Result := False;
  if AItem = nil then Exit(AmsFail('DirectClick: kein Element'));
  if not AmsBindBars then Exit(AmsFail('DirectClick: dxBar-Symbole fehlen'));
  try
    hcItemDirectClick(AItem);
    Result := True;
  except
    on E: Exception do
      Result := AmsFail('DirectClick fehlgeschlagen: ' + E.Message);
  end;
end;

function AmsCollectMenuEntries(const AMenuName: string;
  var AEntries: TAmsMenuEntryArray): Integer;
var
  Preferred, Other: TList;
  i: Integer;
begin
  Result := 0;
  SetLength(AEntries, 0);
  Preferred := TList.Create;
  Other := TList.Create;
  try
    AmsCollectPopupMenus(AMenuName, Preferred, Other);
    { erst die Menues mit passendem Namen, dann alle uebrigen }
    for i := 0 to Preferred.Count - 1 do
      Inc(Result, AmsReadMenu(Preferred[i], AEntries));
    for i := 0 to Other.Count - 1 do
      Inc(Result, AmsReadMenu(Other[i], AEntries));
  finally
    Other.Free;
    Preferred.Free;
  end;
end;

function AmsClickMenuEntry(const AMenuName, ACaption: string): Boolean;
var
  Entries: TAmsMenuEntryArray;
  i, n: Integer;
  Wanted: string;
begin
  Result := False;
  Wanted := AmsCleanCaption(ACaption);
  if Wanted = '' then Exit(AmsFail('Kein Menueeintrag angegeben'));

  SetLength(Entries, 0);
  n := AmsCollectMenuEntries(AMenuName, Entries);
  if n = 0 then
    Exit(AmsFail('An dieser Stelle ist kein Menueeintrag verfuegbar'));

  for i := 0 to High(Entries) do
    if (Entries[i].Item <> nil) and SameText(Entries[i].Caption, Wanted) then
    begin
      AmsLogFmt('Menue "%s" [%d] "%s" -> DirectClick',
                [Entries[i].MenuName, Entries[i].Index, Entries[i].Caption]);
      Exit(AmsClickItem(Entries[i].Item));
    end;

  Result := AmsFailFmt('"%s" ist hier nicht verfuegbar (%d Eintraege geprueft)',
                       [Wanted, n]);
end;

end.
