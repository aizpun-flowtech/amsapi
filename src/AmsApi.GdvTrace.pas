unit AmsApi.GdvTrace;

{ ============================================================================
  AmsApi.GdvTrace - den GDV-Import von AMS.5 bei Laufzeit mitschneiden.

  Haengt Code-Detours (AmsApi.Hook) an die Delphi-Methoden, die den GDV-Import
  tragen - alle per Reverse-Engineering lokalisiert (siehe amsreverse/amsgdv/
  Script-Engine-und-Aufrufstellen.md). Jeder Detour schreibt eine Zeile in die
  Zeitachse (AmsApi.Trace): Phase, Script-Aufruf oder Feldzugriff, verschachtelt
  und mit Dauer. Das Verlaufsfenster (AmsApi.TraceWindow) zeigt es live.

  ABI-REGEL (warum nur bestimmte Methoden gehookt werden):
  Delphi-register-Konvention - EAX=Self, EDX=1., ECX=2. Param, Rest auf dem
  Stack, der Aufgerufene raeumt ab. Ein Detour MUSS dieselbe Parameterzahl
  deklarieren, sonst stimmt das Stack-Cleanup nicht -> Absturz. Funktionen mit
  string-/Variant-RUECKGABE bekommen von Delphi einen VERSTECKTEN Result-Zeiger
  als zusaetzlichen letzten Parameter; der ist hier mitdeklariert. Boolean-/
  Integer-/Zeiger-Rueckgaben nutzen EAX und brauchen keinen Extraparameter.
  Alle Parameter sind als Pointer deklariert (4 Byte, wird nur durchgereicht).

  Gehookt wird in zwei Gruppen:
   * Phasen + Script-Aufrufe (immer): Einlesen, Zuordnen, Schreiben, die
     benannten Script-Einstiege und die Objekt-Registrierung.
   * Feldebene (Schalter): jeder Gdv.GetValue/GetWahl des Scripts und die
     haeufigen GetSatzNummer/GetVertragStatus. Sehr geschwaetzig.

  Kein Fetch*-Hook: deren Rueckgabetyp ist nicht sicher bestimmt; bevor die
  mit falscher Aritaet den Host abschiessen, bleiben sie draussen. ExportItem
  klammert die Schreibphase ohnehin ein.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils,
  AmsApi.Log, AmsApi.Hook, AmsApi.Trace, AmsApi.Strings;

{ Installiert die GDV-Hooks. AFieldLevel=True zusaetzlich die Feldebene.
  Liefert die Zahl der tatsaechlich gesetzten Hooks. Mehrfachaufruf ist
  idempotent. }
function  AmsGdvTraceStart(AFieldLevel: Boolean): Integer;

{ Schaltet das Mitschreiben der GDV-Zeilen ab (die Detours bleiben installiert,
  werden aber transparent). Das endgueltige Loesen macht AmsHookReleaseAll im
  BeforeUnload des Plugins. }
procedure AmsGdvTraceStop;

function  AmsGdvTraceRunning: Boolean;
function  AmsGdvTraceStatus: string;

implementation

const
  { Namen MIT '.bpl': AmsSym haengt sonst den Versionssuffix an (afnBu230.bpl),
    den afnBu/afnComponentsRt gar nicht tragen. }
  MBU = 'afnBu.bpl';
  MRT = 'afnComponentsRt.bpl';

type
  { Durchreich-Signaturen nach Parameterzahl. register = Delphi-ABI. }
  TFn2 = procedure(a1, a2: Pointer); register;
  TFn3 = procedure(a1, a2, a3: Pointer); register;
  TFn4 = procedure(a1, a2, a3, a4: Pointer); register;
  TFn6 = procedure(a1, a2, a3, a4, a5, a6: Pointer); register;

var
  gOn: Boolean = False;
  gFields: Boolean = False;
  gCount: Integer = 0;

  { Trampoline-Zeiger (Original weiterrufen). }
  oImportGDV, oLoadStream, oSplit, oIdentify, oFind, oExportItem: Pointer;
  oScIdentify, oScSparte, oScExpKunde, oScExpVertrag, oAddObject: Pointer;
  oGetValueMulti, oGetWahl, oGetSatzNr, oGetVStatus: Pointer;

{ --------------------------------------------------------------- Helfer --- }

function SafeStr(APtr: Pointer): string;
begin
  Result := '';
  if APtr = nil then Exit;
  try Result := AmsFromHostStr(APtr); except Result := ''; end;
end;

function YesNo(AValue: Boolean): string;
begin
  if AValue then Result := 'an' else Result := 'aus';
end;

{ ============================ Phasen (immer) ============================= }

procedure DetImportGDV(Self, ADict, AStream, AFlag: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'GDV Einlesen: ImportGDV',
    'Datei wird eingelesen'); except Id := 0; end;
  try TFn4(oImportGDV)(Self, ADict, AStream, AFlag);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

procedure DetLoadStream(Self, AStream: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'GDV Einlesen: LoadFromStream',
    'Kodierungserkennung'); except Id := 0; end;
  try TFn2(oLoadStream)(Self, AStream);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

procedure DetSplit(Self, AStream, AList, AIntf: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'GDV Einlesen: SplitDatei',
    'in Einzelvertraege zerlegen'); except Id := 0; end;
  try TFn4(oSplit)(Self, AStream, AList, AIntf);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

procedure DetIdentify(Self, AData, ACand, AFlag: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'GDV Zuordnen: IdentifyItem',
    'Kunde/Vertrag suchen'); except Id := 0; end;
  try TFn4(oIdentify)(Self, AData, ACand, AFlag);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

procedure DetFind(Self, ABuf, AIntf, ACand: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'GDV Zuordnen: FindCandidates',
    'Kandidatensuche'); except Id := 0; end;
  try TFn4(oFind)(Self, ABuf, AIntf, ACand);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

procedure DetExportItem(Self, AData, A1, A2: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'GDV Schreiben: ExportItem',
    'Vertrag in AMS schreiben'); except Id := 0; end;
  try TFn4(oExportItem)(Self, AData, A1, A2);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

{ ---------------------- benannte Script-Einstiege ----------------------- }

procedure DetScIdentify(Self, AInfo: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'JS Identify()',
    'Script korrigiert CandidateInfo'); except Id := 0; end;
  try TFn2(oScIdentify)(Self, AInfo);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

{ Sparte(): string -> versteckter Result-Zeiger in EDX (2. Slot). }
procedure DetScSparte(Self, AResult: Pointer); register;
var Id: Integer; S: string;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'JS Sparte()', ''); except Id := 0; end;
  try TFn2(oScSparte)(Self, AResult);
  finally
    if Id <> 0 then
    begin
      S := '';
      if AResult <> nil then try S := SafeStr(PPointer(AResult)^); except S := ''; end;
      AmsTraceLeave(Id, S);
    end;
  end;
end;

procedure DetScExpKunde(Self, AObj, A2: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'JS ExportKunde()',
    'Kundenfelder schreiben'); except Id := 0; end;
  try TFn3(oScExpKunde)(Self, AObj, A2);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

procedure DetScExpVertrag(Self, A1, A2, A3, A4, A5: Pointer); register;
var Id: Integer;
begin
  Id := 0;
  if gOn then try Id := AmsTraceEnter(tcHost, 'JS ExportVertrag()',
    'Vertrags-/Spartenfelder schreiben'); except Id := 0; end;
  try TFn6(oScExpVertrag)(Self, A1, A2, A3, A4, A5);
  finally if Id <> 0 then AmsTraceLeave(Id); end;
end;

{ AddObject(name, obj) - zeigt, welche Host-Objekte dem Script gereicht werden.
  Engine-weit (afnComponentsRt), also auch fuer andere Scripte - waehrend eines
  GDV-Imports sind es die GDV-Objekte (Gdv, Options, Context, CandidateInfo ...). }
procedure DetAddObject(Self, AName, AObj: Pointer); register;
var S: string;
begin
  if gOn then
  begin
    S := SafeStr(AName);
    if S <> '' then AmsTraceNote(tcHost, 'JS Objekt: ' + S, '');
  end;
  TFn3(oAddObject)(Self, AName, AObj);
end;

{ ============================ Feldebene ================================= }

{ GetValueMulti(key, n): Variant -> versteckter Variant-Result als 4. Param.
  AKey (EDX) ist direkt der UnicodeString-Zeiger, AIdx (ECX) der Integer. }
procedure DetGetValueMulti(Self, AKey, AIdx, AResult: Pointer); register;
var S: string;
begin
  if gOn then
  begin
    S := SafeStr(AKey);
    if S <> '' then AmsTraceNote(tcHost, 'JS liest Feld ' + S,
      'n=' + IntToStr(PtrInt(AIdx)));
  end;
  TFn4(oGetValueMulti)(Self, AKey, AIdx, AResult);
end;

procedure DetGetWahl(Self, AKey, AUseAms, AResult: Pointer); register;
var S: string;
begin
  if gOn then
  begin
    S := SafeStr(AKey);
    if S <> '' then AmsTraceNote(tcHost, 'JS liest Schluessel ' + S, '');
  end;
  TFn4(oGetWahl)(Self, AKey, AUseAms, AResult);
end;

procedure DetGetSatzNr(Self, ALine, AVorsatz, AResult: Pointer); register;
var S: string;
begin
  if gOn then
  begin
    S := Copy(SafeStr(ALine), 1, 4);
    AmsTraceNote(tcHost, 'JS GetSatzNummer', 'Satzart ' + S);
  end;
  TFn4(oGetSatzNr)(Self, ALine, AVorsatz, AResult);
end;

procedure DetGetVStatus(Self, ALine, AVorsatz, AResult: Pointer); register;
var S: string;
begin
  if gOn then
  begin
    S := Copy(SafeStr(ALine), 1, 4);
    AmsTraceNote(tcHost, 'JS GetVertragStatus', 'Satzart ' + S);
  end;
  TFn4(oGetVStatus)(Self, ALine, AVorsatz, AResult);
end;

{ ============================ Installation ============================== }

procedure Hook(const AModule, AName: string; ADetour: Pointer;
  var AOrig: Pointer);
begin
  if AmsHookSymbol(AModule, AName, ADetour, AOrig) then
    Inc(gCount)
  else
    AmsLogFmt('GdvTrace: Hook fehlgeschlagen: %s!%s - %s',
              [AModule, AName, AmsLastError]);
end;

function AmsGdvTraceStart(AFieldLevel: Boolean): Integer;
begin
  if gOn then
  begin
    gOn := True;
    Exit(gCount);
  end;
  gCount := 0;
  gFields := AFieldLevel;

  { --- Phasen (afnBu) --- }
  Hook(MBU, '@Bugdvlist@TGDVData@ImportGDV$qqrp25Bugdv@TGdvDictionaryStorep22System@Classes@TStreamo',
       @DetImportGDV, oImportGDV);
  Hook(MBU, '@Bugdv@TGdvDatei@LoadFromStream$qqrp22System@Classes@TStream',
       @DetLoadStream, oLoadStream);
  Hook(MBU, '@Bugdv@TGdvDatei@SplitDatei$qqrp22System@Classes@TStreamp20System@Classes@TList69System@%DelphiInterface$42Bugdvtranslationintf@IGDVCustomTranslation%',
       @DetSplit, oSplit);
  Hook(MBU, '@Bugdvlist@TSyncManagerGDV_AMS4@IdentifyItem$qqrp18Bugdvlist@TGDVDatap31Bucandidates@TCandidateListAMS4o',
       @DetIdentify, oIdentify);
  Hook(MBU, '@Bugdvlist@TSyncManagerGDV_AMS4@FindCandidates$qqrp20Bugdv@TGdvSatzBuffer65System@%DelphiInterface$38Bugdvtranslationintf@IGDVCandidateInfo%p31Bucandidates@TCandidateListAMS4',
       @DetFind, oFind);
  Hook(MBU, '@Bugdvlist@TSyncManagerGDV_AMS4@ExportItem$qqrp18Bugdvlist@TGDVDataoo',
       @DetExportItem, oExportItem);

  { --- benannte Script-Einstiege (afnBu) --- }
  Hook(MBU, '@Bugdvtranslationimpl@TGDVCustomTranslationScript@Identify$qqr65System@%DelphiInterface$38Bugdvtranslationintf@IGDVCandidateInfo%',
       @DetScIdentify, oScIdentify);
  Hook(MBU, '@Bugdvtranslationimpl@TGDVCustomTranslationScript@Sparte$qqrv',
       @DetScSparte, oScSparte);
  Hook(MBU, '@Bugdvtranslationimpl@TGDVCustomTranslationScript@ExportKunde$qqrp17Bubase@TAmsObjektt1',
       @DetScExpKunde, oScExpKunde);
  Hook(MBU, '@Bugdvtranslationimpl@TGDVCustomTranslationScript@ExportVertrag$qqrp17Bubase@TAmsObjektt1t1t1t1',
       @DetScExpVertrag, oScExpVertrag);

  { --- Script-Engine: Objekt-Registrierung (afnComponentsRt) --- }
  Hook(MRT, '@Afnscript@TScriptHost@AddObject$qqr20System@UnicodeStringp14System@TObject',
       @DetAddObject, oAddObject);

  { --- Feldebene (optional, afnBu) --- }
  if gFields then
  begin
    Hook(MBU, '@Bugdvlist@TGdvSatzBufferScriptLink@GetValueMulti$qqr20System@UnicodeStringi',
         @DetGetValueMulti, oGetValueMulti);
    Hook(MBU, '@Bugdvlist@TGdvSatzBufferScriptLink@GetWahl$qqr20System@UnicodeStringo',
         @DetGetWahl, oGetWahl);
    Hook(MBU, '@Bugdvtranslationimpl@TGDVCustomTranslationScript@GetSatzNummer$qqr20System@UnicodeStringt1',
         @DetGetSatzNr, oGetSatzNr);
    Hook(MBU, '@Bugdvtranslationimpl@TGDVCustomTranslationScript@GetVertragStatus$qqr20System@UnicodeStringt1',
         @DetGetVStatus, oGetVStatus);
  end;

  gOn := gCount > 0;
  if gOn then
    AmsLogFmt('GdvTrace: %d Hooks gesetzt (Feldebene: %s)',
              [gCount, YesNo(gFields)])
  else
    AmsLog('GdvTrace: kein Hook gesetzt - Symbole nicht gefunden?');
  Result := gCount;
end;

procedure AmsGdvTraceStop;
begin
  gOn := False;
end;

function AmsGdvTraceRunning: Boolean;
begin
  Result := gOn;
end;

function AmsGdvTraceStatus: string;
var Lauf: string;
begin
  if gOn then Lauf := 'laeuft' else Lauf := 'aus';
  Result := Format('GdvTrace: %d Hooks, %s, Feldebene %s',
    [gCount, Lauf, YesNo(gFields)]);
end;

end.
