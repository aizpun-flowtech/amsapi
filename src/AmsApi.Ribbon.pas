unit AmsApi.Ribbon;

{ ============================================================================
  AmsApi.Ribbon - eigene Schaltflaechen im AMS-Ribbon

  Der Weg, der im echten AMS nachweislich funktioniert:
    FindControl(Hauptfenster)        -> Hauptformular
    FindComponent("dxBarManager1")   -> TdxBarManager
    FindComponent("bmbBenutzerdefiniert") -> die Ribbon-Gruppe (TdxBar)
    GetClass("TdxBarLargeButton")    -> Klassenreferenz
    TdxBarManager.AddItem(Klasse)    -> neues TdxBarItem
    Caption/Hint/Glyph/OnClick setzen
    TdxBar.ItemLinks.Add(Item)       -> sichtbar machen

  OnClick ist ein TNotifyEvent, also ein Delphi-TMethod: EAX = Data,
  EDX = Sender. Wir legen pro Schaltflaeche einen Slot an, tragen dort den
  FPC-Handler ein und geben dem Host Code = @ClickThunk, Data = @Slot.

  WICHTIG beim Entladen: AmsReleaseButtons ruft AmsClearMethod fuer jede
  Schaltflaeche auf. Ohne das springt ein Klick nach dem Entladen des BPL in
  freigegebenen Speicher.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types;

type
  TAmsRibbonOptions = record
    Caption: string;
    Hint: string;
    { Bilddateien, relativ zum Plugin-Ordner oder absolut. }
    LargeGlyphFile: string;
    GlyphFile: string;
    { Alternativ ein vorhandenes Symbol aus der ImageList, -1 = aus. }
    ImageIndex: Integer;
    LargeImageIndex: Integer;
    { Namen im Host. Leer = Standard (siehe AmsRibbonDefaults). }
    ManagerName: string;
    BarName: string;
    ButtonClass: string;
    { Klickbehandlung }
    OnClick: TAmsClickEvent;
    Tag: Integer;
  end;

{ Vorbelegte Optionen: dxBarManager1 / bmbBenutzerdefiniert /
  TdxBarLargeButton, ImageIndex -1. }
function AmsRibbonDefaults: TAmsRibbonOptions;

{ Schaltflaeche anlegen und einhaengen. AItem erhaelt das TdxBarItem.
  Liefert False mit Klartext in AmsLastError, wenn etwas fehlt. }
function AmsAddRibbonButton(AMainWnd: HWND; const AOptions: TAmsRibbonOptions;
  out AItem: Pointer): Boolean;

{ Beschriftung / Hinweis / Aktivierung einer angelegten Schaltflaeche aendern. }
function AmsSetButtonCaption(AItem: Pointer; const ACaption: string): Boolean;
function AmsSetButtonHint(AItem: Pointer; const AHint: string): Boolean;
function AmsSetButtonEnabled(AItem: Pointer; AEnabled: Boolean): Boolean;

{ Alle von diesem Modul angelegten Schaltflaechen abklemmen. Beim Entladen
  Pflicht - siehe Unit-Kopf. }
procedure AmsReleaseButtons;

{ Anzahl der von diesem Modul angelegten Schaltflaechen. }
function AmsButtonCount: Integer;

implementation

uses
  AmsApi.Bind, AmsApi.Strings, AmsApi.Rtti, AmsApi.Components,
  AmsApi.Glyphs, AmsApi.Log;

type
  PClickSlot = ^TClickSlot;
  TClickSlot = record
    Method: TDelphiMethod;    { Code = @ClickThunk, Data = @Self }
    Handler: TAmsClickEvent;
    Tag: Integer;
    Item: Pointer;
  end;

var
  gSlots: TList = nil;         { PClickSlot }

{ Wird vom Host als TNotifyEvent gerufen: EAX = Data (= unser Slot),
  EDX = Sender. Ab hier sind wir wieder in FPC-Land. }
procedure ClickThunk(ASlot: PClickSlot; ASender: Pointer); register;
begin
  try
    if (ASlot = nil) or not Assigned(ASlot^.Handler) then Exit;
    ASlot^.Handler(ASender, ASlot^.Tag);
  except
    on E: Exception do
      AmsLog('Klickbehandlung EXCEPTION: ' + E.Message);
  end;
end;

function AmsRibbonDefaults: TAmsRibbonOptions;
begin
  Result.Caption := '';
  Result.Hint := '';
  Result.LargeGlyphFile := '';
  Result.GlyphFile := '';
  Result.ImageIndex := -1;
  Result.LargeImageIndex := -1;
  Result.ManagerName := 'dxBarManager1';
  Result.BarName := 'bmbBenutzerdefiniert';
  Result.ButtonClass := 'TdxBarLargeButton';
  Result.OnClick := nil;
  Result.Tag := 0;
end;

{ Komponente erst am Hauptformular suchen, dann am Manager, dann prozessweit.
  Der letzte Schritt macht den Einbau robust, wenn AMS die Leiste woanders
  aufhaengt. }
function LocateComponent(AForm, AManager: Pointer; const AName: string): Pointer;
begin
  Result := AmsFindComponent(AForm, AName);
  if (Result = nil) and (AManager <> nil) then
    Result := AmsFindComponent(AManager, AName);
  if Result = nil then
    Result := AmsFindComponentDeep(AForm, AName);
  if Result = nil then
    Result := AmsFindAnywhere(AName);
end;

function AmsAddRibbonButton(AMainWnd: HWND; const AOptions: TAmsRibbonOptions;
  out AItem: Pointer): Boolean;
var
  Opt: TAmsRibbonOptions;
  Form, Mgr, Bar, Cls, Links, Link: Pointer;
  Slot: PClickSlot;
begin
  Result := False;
  AItem := nil;
  AmsClearError;

  Opt := AOptions;
  if Opt.ManagerName = '' then Opt.ManagerName := 'dxBarManager1';
  if Opt.BarName = '' then Opt.BarName := 'bmbBenutzerdefiniert';
  if Opt.ButtonClass = '' then Opt.ButtonClass := 'TdxBarLargeButton';
  if Opt.Caption = '' then Opt.Caption := 'Plugin';

  if not AmsBindCore then Exit(AmsFail('Ribbon: rtl-Symbole fehlen'));
  if not AmsBindVcl then Exit(AmsFail('Ribbon: vcl-Symbole fehlen'));
  if not AmsBindBars then Exit(AmsFail('Ribbon: afnUiCore-Symbole fehlen'));

  try
    Form := AmsMainForm(AMainWnd);
    if Form = nil then
      Exit(AmsFail('Ribbon: Hauptformular nicht gefunden'));
    AmsLogFmt('FindControl(%p) -> %p [%s]',
              [Pointer(AMainWnd), Form, AmsClassName(Form)]);

    Mgr := LocateComponent(Form, nil, Opt.ManagerName);
    if Mgr = nil then
      Exit(AmsFailFmt('Ribbon: "%s" nicht gefunden', [Opt.ManagerName]));
    AmsLogFmt('FindComponent("%s") -> %p', [Opt.ManagerName, Mgr]);

    Bar := LocateComponent(Form, Mgr, Opt.BarName);
    if Bar = nil then
      Exit(AmsFailFmt('Ribbon: Gruppe "%s" nicht gefunden', [Opt.BarName]));
    AmsLogFmt('FindComponent("%s") -> %p', [Opt.BarName, Bar]);

    Cls := hcGetClass(AmsStr(Opt.ButtonClass));
    if Cls = nil then
      Exit(AmsFailFmt('Ribbon: Klasse "%s" nicht registriert', [Opt.ButtonClass]));

    AItem := hcBarAddItem(Mgr, Cls);
    if AItem = nil then
      Exit(AmsFail('Ribbon: AddItem lieferte nil'));
    AmsLogFmt('TdxBarManager.AddItem -> %p', [AItem]);

    AmsSetStr(AItem, 'Caption', Opt.Caption);
    if Opt.Hint <> '' then AmsSetStr(AItem, 'Hint', Opt.Hint);
    if Opt.ImageIndex >= 0 then AmsSetOrd(AItem, 'ImageIndex', Opt.ImageIndex);
    if Opt.LargeImageIndex >= 0 then
      AmsSetOrd(AItem, 'LargeImageIndex', Opt.LargeImageIndex);

    { Symbole sind optional - ihr Fehlen darf den Einbau nicht verhindern. }
    if Opt.LargeGlyphFile <> '' then
      if not AmsSetGlyph(AItem, 'LargeGlyph', Opt.LargeGlyphFile) then
        AmsLog('LargeGlyph nicht gesetzt: ' + AmsLastError);
    if Opt.GlyphFile <> '' then
      if not AmsSetGlyph(AItem, 'Glyph', Opt.GlyphFile) then
        AmsLog('Glyph nicht gesetzt: ' + AmsLastError);

    if Assigned(Opt.OnClick) then
    begin
      New(Slot);
      Slot^.Handler := Opt.OnClick;
      Slot^.Tag := Opt.Tag;
      Slot^.Item := AItem;
      Slot^.Method.Code := @ClickThunk;
      Slot^.Method.Data := Slot;
      if gSlots = nil then gSlots := TList.Create;
      gSlots.Add(Slot);
      AmsSetMethod(AItem, 'OnClick', Slot^.Method);
    end;

    Links := hcBarGetItemLinks(Bar);
    if Links = nil then
      Exit(AmsFail('Ribbon: ItemLinks der Gruppe nicht lesbar'));

    Link := hcBarLinksAdd(Links, AItem);
    if Link = nil then
      Exit(AmsFail('Ribbon: ItemLinks.Add lieferte nil'));

    AmsClearError;
    AmsLogFmt('Ribbon-Button "%s" in Gruppe "%s" eingehaengt',
              [Opt.Caption, Opt.BarName]);
    Result := True;
  except
    on E: Exception do
      Result := AmsFail('Ribbon EXCEPTION: ' + E.Message);
  end;
end;

function AmsSetButtonCaption(AItem: Pointer; const ACaption: string): Boolean;
begin
  Result := AmsSetStr(AItem, 'Caption', ACaption);
end;

function AmsSetButtonHint(AItem: Pointer; const AHint: string): Boolean;
begin
  Result := AmsSetStr(AItem, 'Hint', AHint);
end;

function AmsSetButtonEnabled(AItem: Pointer; AEnabled: Boolean): Boolean;
begin
  Result := AmsSetOrd(AItem, 'Enabled', Ord(AEnabled));
end;

function AmsButtonCount: Integer;
begin
  if gSlots = nil then Result := 0 else Result := gSlots.Count;
end;

procedure AmsReleaseButtons;
var
  i: Integer;
  Slot: PClickSlot;
begin
  if gSlots = nil then Exit;
  for i := 0 to gSlots.Count - 1 do
  begin
    Slot := PClickSlot(gSlots[i]);
    if Slot = nil then Continue;
    { Zuerst den Host abklemmen, dann erst freigeben. }
    if Slot^.Item <> nil then
    begin
      AmsClearMethod(Slot^.Item, 'OnClick');
      { Nicht loeschen - das Element gehoert dem Host. Nur unsichtbar machen,
        damit keine tote Schaltflaeche stehen bleibt. ivNever = 0. }
      AmsSetOrd(Slot^.Item, 'Visible', 0);
    end;
    Slot^.Handler := nil;
    Dispose(Slot);
  end;
  gSlots.Clear;
  AmsLog('Ribbon-Schaltflaechen abgeklemmt');
end;

initialization
  gSlots := nil;

finalization
  AmsReleaseButtons;
  FreeAndNil(gSlots);

end.
