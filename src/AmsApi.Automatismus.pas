unit AmsApi.Automatismus;

{ ============================================================================
  AmsApi.Automatismus - Automatismen im aktuellen Kontext starten

  Der entscheidende Befund aus dem Prototyp:

    "Es sollen die Automatismen aus der Automatismustabelle gestartet werden
     koennen wie 'Automatismus ausfuehren' - also nicht wirklich
     WorkflowEngine/Workflow."

  AMS zeigt "Automatismus ausfuehren" als TdxBarSubItem, dessen DropdownMenu
  das TdxRibbonPopupMenu "rpmAutomatismen" ist. Dieses Menue wird zur Laufzeit
  KONTEXTABHAENGIG gefuellt: was drinsteht, haengt davon ab, was gerade offen
  ist (Kunde / Vertrag / Vorgang).

  Wir bauen die Filterkette deshalb nicht nach, sondern lesen das fertige
  Menue und loesen den passenden Eintrag mit TdxBarItem.DirectClick aus.
  Damit laeuft der Automatismus exakt im selben Kontext wie beim Mausklick.

  Grenze der Fehlerbehandlung: Fehler INNERHALB eines Automatismus-Skripts
  laufen in der Skript-Engine von AMS. Nach DirectClick sieht das Plugin davon
  nichts mehr - die Pruefung gehoert ins Skript.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types, AmsApi.Menus;

const
  { Der Menuename in AMS.5. Ueber die Parameter ueberschreibbar, falls eine
    Installation ihn anders benennt. }
  AMS_AUTOMATISMUS_MENU = 'rpmAutomatismen';

{ Die im aktuellen Kontext verfuegbaren Automatismen auflisten.
  ACaptions wird gefuellt (Duplikate werden uebersprungen), Rueckgabe ist die
  Anzahl. 0 heisst: an dieser Stelle bietet AMS keinen an - typischerweise,
  weil kein Kunde / Vertrag / Vorgang geoeffnet ist. }
function AmsListAutomatismen(ACaptions: TStrings;
  const AMenuName: string = AMS_AUTOMATISMUS_MENU): Integer;

{ Automatismus mit dieser Beschriftung im aktuellen Kontext starten.
  False mit Klartext in AmsLastError, wenn er hier nicht angeboten wird. }
function AmsRunAutomatismus(const ACaption: string;
  const AMenuName: string = AMS_AUTOMATISMUS_MENU): Boolean;

{ Wie AmsRunAutomatismus, liefert zusaetzlich die im Kontext verfuegbaren
  Beschriftungen zurueck - damit kann das Plugin eine sinnvolle Meldung
  bauen, ohne die Suche zweimal zu fahren. }
function AmsRunAutomatismusEx(const ACaption: string; AAvailable: TStrings;
  const AMenuName: string = AMS_AUTOMATISMUS_MENU): Boolean;

implementation

uses
  AmsApi.Bind, AmsApi.Log;

function CollectCaptions(const AMenuName: string; ADest: TStrings;
  var AEntries: TAmsMenuEntryArray): Integer;
var
  i: Integer;
begin
  SetLength(AEntries, 0);
  Result := AmsCollectMenuEntries(AMenuName, AEntries);
  if ADest = nil then Exit;
  for i := 0 to High(AEntries) do
    if (AEntries[i].Item <> nil) and (AEntries[i].Caption <> '') then
      if ADest.IndexOf(AEntries[i].Caption) < 0 then
        ADest.Add(AEntries[i].Caption);
end;

function AmsListAutomatismen(ACaptions: TStrings;
  const AMenuName: string): Integer;
var
  Entries: TAmsMenuEntryArray;
begin
  AmsClearError;
  if not (AmsBindCore and AmsBindVcl and AmsBindBars) then
  begin
    AmsFail('Automatismen: Host-Symbole nicht gebunden');
    Exit(0);
  end;
  Result := CollectCaptions(AMenuName, ACaptions, Entries);
  AmsLogFmt('Automatismen im Kontext: %d Eintraege', [Result]);
end;

function AmsRunAutomatismusEx(const ACaption: string; AAvailable: TStrings;
  const AMenuName: string): Boolean;
var
  Entries: TAmsMenuEntryArray;
  Wanted: string;
  i, n: Integer;
begin
  Result := False;
  AmsClearError;
  Wanted := AmsCleanCaption(ACaption);
  if Wanted = '' then
    Exit(AmsFail('Es ist kein Automatismus angegeben'));
  if not (AmsBindCore and AmsBindVcl and AmsBindBars) then
    Exit(AmsFail('Automatismen: Host-Symbole nicht gebunden'));

  n := CollectCaptions(AMenuName, AAvailable, Entries);
  if n = 0 then
    Exit(AmsFail('An dieser Stelle ist kein Automatismus verfuegbar. ' +
                 'AMS bietet Automatismen nur passend zum geoeffneten Objekt an - ' +
                 'bitte zuerst einen Kunden, Vertrag oder Vorgang oeffnen.'));

  for i := 0 to High(Entries) do
    if (Entries[i].Item <> nil) and SameText(Entries[i].Caption, Wanted) then
    begin
      AmsLogFmt('Automatismus "%s" aus Menue "%s" [%d] -> DirectClick',
                [Entries[i].Caption, Entries[i].MenuName, Entries[i].Index]);
      if AmsClickItem(Entries[i].Item) then
      begin
        AmsLogFmt('Automatismus "%s" ausgefuehrt', [Wanted]);
        Exit(True);
      end;
      Exit(False);
    end;

  Result := AmsFailFmt('Der Automatismus "%s" ist hier nicht verfuegbar ' +
                       '(%d Eintraege im Kontext)', [Wanted, n]);
end;

function AmsRunAutomatismus(const ACaption, AMenuName: string): Boolean;
begin
  Result := AmsRunAutomatismusEx(ACaption, nil, AMenuName);
end;

end.
