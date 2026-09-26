library UiTweaks;

{ ============================================================================
  UiTweaks - vorhandene AMS-Elemente finden, bearbeiten und ergaenzen

  Vier Wege, dieselbe Sache:

  1. SUCHEN IM LAUFENDEN AMS. Die Schaltflaeche "Elemente suchen" oeffnet ein
     Fenster: Suchbegriff eingeben (Name, Beschriftung oder Klasse, "*" und
     "?" erlaubt), Treffer anklicken, Eigenschaft anklicken - unten steht die
     fertige Patchzeile. "Anwenden" probiert sie sofort aus, "Kopieren" legt
     sie in die Zwischenablage, "Zuruecknehmen" macht alles rueckgaengig.
     Ein Fensterhandle aus AutoIt Window Info ("0x00650E98") kann man direkt
     ins Suchfeld schreiben.

  2. BAUEN, im selben Fenster eine Zeile darueber. "Merken" nimmt den
     gewaehlten Treffer als Vorlage, "Klonen" setzt eine Kopie davon in den
     Container, der gerade gewaehlt ist - ohne Vorlage entsteht eine Kopie
     neben dem Original. "Neu" legt ein Element der eingetragenen Klasse an
     (TButton, TPanel, TEdit, TdxBarLargeButton), "Entfernen" nimmt zurueck,
     was dieses Plugin angelegt hat. Der Haken "mit Ereignissen" entscheidet,
     ob der Klon auch TUT, was das Original tut.

  3. AUS DER INI. Was unter [Patch] steht, wird beim Start angewandt - ohne
     eine Zeile Pascal. Genau die Zeilen, die das Suchfenster liefert.

  4. UEBERNEHMEN. Steht unter [Hook] ein Element, wird dessen OnClick
     mitgehoert.

  Alle Aenderungen werden mitgeschrieben und beim Entladen des Plugins
  zurueckgenommen; alles Angelegte und Geklonte wird dann wieder abgeraeumt.
  Die Arbeit macht die Bibliothek (AmsApi.Ui, AmsApi.Factory) - hier steht
  nur die Bedienung.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

uses
  Windows, SysUtils, Classes,
  AmsApi.Plugin, AmsApi.Ui, AmsApi.Factory, AmsApi.Props, AmsApi.Ini,
  AmsApi.Log;

const
  TAG_FINDER = 1;
  TAG_UNDO = 2;

{ Das Suchfenster ist reines Win32 und steht der Uebersicht halber in einer
  eigenen Datei. }
{$I finder.inc}

type
  TUiTweaks = class(TAmsPlugin)
  protected
    procedure AfterMainWindow; override;
    procedure ButtonClick(ASender: Pointer; ATag: Integer); override;
    procedure BeforeUnload; override;
  private
    procedure HookedClick(ASender: Pointer; ATag: Integer);
    procedure ApplyHook;
  end;

procedure TUiTweaks.AfterMainWindow;
var
  n: Integer;
begin
  AddRibbonButton('Elemente suchen',
                  'Elemente des Hosts durchsuchen und patchen',
                  'icon32.png', TAG_FINDER);
  AddRibbonButton('Zuruecknehmen',
                  'Nimmt alle Aenderungen dieses Plugins zurueck',
                  'icon32.png', TAG_UNDO);

  gMaxHits := AmsIniInt('MaxTreffer', 500, 'Suche');

  { Erst jetzt patchen: vorher steht die Oberflaeche noch nicht. }
  n := ApplyPatchesFromIni('Patch');
  if n > 0 then
    LogFmt('%d Eigenschaft(en) aus [Patch] gesetzt', [n]);

  ApplyHook;
end;

{ [Hook] Element=bbSpeichern
         CallOriginal=1        ; 1 = zusaetzlich, 0 = statt der Behandlung }
procedure TUiTweaks.ApplyHook;
var
  Name: string;
  E: TAmsElement;
begin
  Name := AmsIniStr('Element', '', 'Hook');
  if Name = '' then Exit;
  if not FindElement(Name, E) then
  begin
    LogFmt('[Hook] "%s": %s', [Name, LastError]);
    Exit;
  end;
  if AmsHookClick(E.Obj, HookedClick, 0,
                  AmsIniBool('CallOriginal', True, 'Hook')) then
    LogFmt('Klick auf "%s" wird mitgehoert', [E.Path])
  else
    LogFmt('[Hook] "%s": %s', [Name, LastError]);
end;

procedure TUiTweaks.HookedClick(ASender: Pointer; ATag: Integer);
begin
  { ASender ist das Element des Hosts, nicht unsere Schaltflaeche. }
  ShowInfo('Geklickt: ' + AmsElementOf(ASender).Caption);
end;

procedure TUiTweaks.ButtonClick(ASender: Pointer; ATag: Integer);
var
  n: Integer;
begin
  case ATag of
    TAG_FINDER:
      { Vorbelegung des Suchfelds aus der INI - praktisch, wenn man immer
        wieder an derselben Stelle sucht. }
      FinderOpen(MainWindow, AmsIniStr('Text', '', 'Suche'));
    TAG_UNDO:
      begin
        n := UndoUiChanges;
        ShowInfo(Format('%d Aenderung(en) zurueckgenommen.', [n]));
      end;
  end;
end;

{ Das Fenster MUSS weg, bevor das Modul verschwindet: seine Fensterprozedur
  liegt hier drin. }
procedure TUiTweaks.BeforeUnload;
begin
  FinderClose;
end;

exports
  AmsPkgInitialize name 'Initialize',
  AmsPkgFinalize   name 'Finalize',
  AmsPluginInit    name 'PluginInit';

begin
  AmsRegisterPlugin(TUiTweaks);
end.
