unit AmsApi.Markdown;

{ ============================================================================
  AmsApi.Markdown - Markdown (GitHub-Teilmenge) nach HTML

  Fuer die README-Anzeige im Plugin Manager: das README.md eines Plugins wird
  hier in HTML uebersetzt und im WebBrowser-Control (IE11-Engine) gezeigt.
  Deshalb ist das CSS von AmsHtmlPage bewusst IE11-tauglich - keine
  CSS-Variablen, kein Flex-gap, kein max-content.

  ZEICHENSATZ: Der Text kommt als UTF-8-Bytes in einem gewoehnlichen string
  und wird NIE umgewandelt. Alle Steuerzeichen von Markdown sind ASCII, also
  wird byteweise gearbeitet; Umlaute laufen unveraendert durch, und die Seite
  sagt dem Browser per meta charset, dass es UTF-8 ist.

  Unterstuetzt (GFM-Teilmenge):
    Ueberschriften (ATX und Setext) mit Ankern wie bei GitHub, Absaetze,
    harte Umbrueche, fett/kursiv/durchgestrichen, Code inline und als Block
    (eingerueckt und ``` bzw. ~~~ mit Sprache), Zitate (verschachtelt, dazu
    die GitHub-Hinweise [!NOTE] usw.), Listen (verschachtelt, geordnet mit
    Startnummer, Aufgabenlisten), Trennlinien, Links (inline, Referenz,
    Autolinks, nackte URLs), Bilder (auch verlinkt), Tabellen mit
    Ausrichtung, Roh-HTML (Bloecke und inline).

  Bewusst NICHT: Fussnoten (bleiben Text), Definitionslisten, Emojis
  (:smile:), Mathe, Mermaid (bleibt Codeblock) und die EINFACHE Tilde als
  Durchstreichung - "ca. ~5 min bis ~10 min" soll lesbar bleiben.

  SICHERHEIT: Ein README kommt aus einem fremden Repo und darf nichts
  ausfuehren. Roh-HTML wird nur bereinigt durchgereicht (AmsSanitizeHtml):
  script/style/iframe/object/embed/svg samt Inhalt weg, Formularelemente
  weg, on*-Attribute weg, javascript:/vbscript:/data:-Adressen weg (data:
  nur fuer Bilder erlaubt). Fuer Markdown-Links gilt dieselbe Pruefung.

  ROBUSTHEIT: Beliebiger Muell liefert HTML, nie eine Exception und nie eine
  Endlosschleife. Verschachtelung ist auf MAX_DEPTH begrenzt; geht trotzdem
  etwas schief, kommt der Text escaped als <pre> zurueck.

  Keine Beruehrung mit dem Host, ohne AMS testbar (tests\unittests.lpr).
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes;

type
  { Wird fuer jedes Bild gerufen - Markdown ![..](..) UND <img src> in
    Roh-HTML, nicht fuer data:-Adressen. AUrl ist schon gegen ImageBase
    aufgeloest. Die Rueckgabe landet in src=; leer = AUrl unveraendert.
    Darf blockieren (die Umwandlung laeuft im Hintergrundthread). Eine
    Exception darin wird geschluckt, das Bild behaelt dann AUrl. }
  TAmsMdImageEvent = function(const AUrl: string): string of object;

  TAmsMarkdownOptions = record
    { Basis fuer relative Bildpfade: URL mit "/" am Ende oder Ordner mit "\". }
    ImageBase: string;
    { Basis fuer relative Links. Anker (#abschnitt) bleiben immer relativ. }
    LinkBase: string;
    { target="_blank" rel="noopener" an absolute http(s)-Links. }
    ExternalLinksNewWindow: Boolean;
    { Roh-HTML bereinigt durchreichen. False = als Text zeigen. }
    AllowHtml: Boolean;
    OnImage: TAmsMdImageEvent;
  end;

{ ExternalLinksNewWindow und AllowHtml an, alles andere leer. }
function AmsMarkdownDefaults: TAmsMarkdownOptions;

{ Markdown nach HTML. Liefert ein Fragment (ohne <html>/<body>). }
function AmsMarkdownToHtml(const AMarkdown: string;
  const AOptions: TAmsMarkdownOptions): string;

{ Ganze Seite um ein Fragment: Doctype, Mark of the Web, IE=edge, UTF-8,
  GitHub-aehnliches CSS (dahinter AExtraCss) und <div class="markdown-body">. }
function AmsHtmlPage(const ATitle, ABodyHtml: string;
  const AExtraCss: string = ''): string;

{ & < > " ' als Entities - fuer Text und Attributwerte. }
function AmsHtmlEscape(const AText: string): string;

{ ARef relativ gegen ABase aufloesen.
  - absolut bleibt unveraendert: Schema (https:, mailto:, data:, file:),
    Anker (#x), Laufwerk (C:\), UNC (\\server); leeres ARef ebenso
  - Basis-URL: "./" und "../" werden aufgeloest, "/" am Anfang von ARef
    heisst ab Wurzel des Hosts, "//host" uebernimmt das Schema der Basis
  - Basis-Ordner (Laufwerk, UNC oder mit "\"): mit "\" zusammengesetzt,
    "/" wird zu "\", ?query und #anker fallen weg, ".." nie ueber die Wurzel }
function AmsResolveUrl(const ABase, ARef: string): string;

{ Roh-HTML entschaerfen: script, style, iframe, frame(set), object, embed,
  applet, template, textarea, svg, math samt Inhalt weg; meta, link, base,
  form, input, button, select, option ohne Inhalt weg; Kommentare weg;
  on*-Attribute und srcset weg; href/src/... mit javascript:, vbscript: oder
  data: weg (data:image/ an <img src> bleibt). }
function AmsSanitizeHtml(const AHtml: string): string;

implementation

const
  MAX_DEPTH = 16;
  { Laenger darf ein Linktext nicht sein - sonst wird jede "[" in einem
    langen Text zu einer Suche bis ans Ende. }
  MAX_LINK_TEXT = 4096;

  { Aufgabenlisten: [ ] / [x] werden vor dem Inline-Lauf durch diese
    Zeichen ersetzt. Steuerzeichen werden vorher aus der Eingabe entfernt,
    ein Zusammenstoss mit dem Text ist also ausgeschlossen. }
  TASK_OPEN = #2;
  TASK_DONE = #3;

  BLOCK_TAGS: array[0..61] of string = (
    'address', 'article', 'aside', 'base', 'basefont', 'blockquote', 'body',
    'caption', 'center', 'col', 'colgroup', 'dd', 'details', 'dialog', 'dir',
    'div', 'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form',
    'frame', 'frameset', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header',
    'hr', 'html', 'iframe', 'legend', 'li', 'link', 'main', 'menu',
    'menuitem', 'nav', 'noframes', 'ol', 'optgroup', 'option', 'p', 'param',
    'section', 'source', 'summary', 'table', 'tbody', 'td', 'tfoot', 'th',
    'thead', 'title', 'tr', 'track', 'ul');

  { Diese Elemente fliegen mit allem raus, was zwischen Anfang und Ende
    steht. }
  DROP_WITH_CONTENT: array[0..13] of string = (
    'script', 'style', 'iframe', 'frame', 'frameset', 'object', 'embed',
    'applet', 'template', 'textarea', 'svg', 'math', 'xml', 'noembed');

  { Diese nur als Tag - der Inhalt (etwa der Text eines <button>) bleibt. }
  DROP_TAG: array[0..15] of string = (
    'meta', 'link', 'base', 'form', 'input', 'button', 'select', 'option',
    'optgroup', 'html', 'head', 'body', 'basefont', 'bgsound', 'isindex',
    'keygen');

  URL_ATTRS: array[0..12] of string = (
    'href', 'src', 'action', 'formaction', 'background', 'dynsrc', 'lowsrc',
    'poster', 'cite', 'longdesc', 'xlink:href', 'data', 'codebase');

type
  TLines = array of string;
  TLinesArr = array of TLines;

  { Wachsender Ausgabepuffer - Zeichen fuer Zeichen an einen string zu
    haengen waere bei grossen READMEs quadratisch. }
  TBuf = record
    S: string;
    Len: Integer;
  end;

  TTagAttr = record
    Name: string;      { klein geschrieben }
    Value: string;     { roh, ohne Anfuehrungszeichen }
    HasValue: Boolean;
  end;

  TTagInfo = record
    Name: string;      { klein geschrieben }
    Closing: Boolean;
    SelfClosing: Boolean;
    Attrs: array of TTagAttr;
  end;

  TListMark = record
    Ordered: Boolean;
    Ch: Char;          { - * + bzw. . ) }
    Start: Integer;
    MIndent: Integer;  { Einrueckung der Marke }
    CIndent: Integer;  { Spalte, ab der der Inhalt steht }
    Text: string;
    Empty: Boolean;
  end;

  TNodeKind = (nkText, nkDelim);

  { Inline-Lauf: fertiger Text oder eine Folge von * _ ~, die erst am Ende
    zu <em>/<strong>/<del> wird (CommonMark-Begrenzerliste, vereinfacht). }
  TNode = record
    Kind: TNodeKind;
    Text: string;
    Ch: Char;
    Count, Orig: Integer;
    CanOpen, CanClose, Active: Boolean;
    OpenTags, CloseTags: string;
  end;
  TNodes = array of TNode;

  TMdConverter = class
  private
    FOpt: TAmsMarkdownOptions;
    FRefKeys, FRefUrls, FRefTitles: TStringList;
    FIds: TStringList;
    procedure CollectRefs(var A: TLines);
    function LookupRef(const ALabel: string; out AUrl, ATitle: string): Boolean;
    function UniqueId(const AId: string): string;
    function TargetAttr(const AHref: string): string;
    function Blocks(const A: TLines; ATight: Boolean; ADepth: Integer): string;
    function DoParagraph(const A: TLines; I: Integer; ATight: Boolean;
      var B: TBuf): Integer;
    procedure DoHeading(ALevel: Integer; const AText: string; var B: TBuf);
    function DoIndentedCode(const A: TLines; I: Integer; var B: TBuf): Integer;
    function DoFence(const A: TLines; I, AIndent: Integer; AFch: Char;
      AFlen: Integer; const AInfo: string; var B: TBuf): Integer;
    function DoQuote(const A: TLines; I, ADepth: Integer; var B: TBuf): Integer;
    function DoList(const A: TLines; I, ADepth: Integer; var B: TBuf): Integer;
    function DoHtml(const A: TLines; I, AKind: Integer; var B: TBuf): Integer;
    function DoTable(const A: TLines; I: Integer; var B: TBuf): Integer;
    function Inlines(const S: string; ANoLinks: Boolean;
      ADepth: Integer): string;
    function TryLink(const S: string; AStart: Integer; AImage: Boolean;
      ADepth: Integer; out AEnd: Integer; out AHtml: string): Boolean;
    function TryAutolink(const S: string; AStart: Integer; ANoLinks: Boolean;
      out AHtml: string): Integer;
    function TryBareUrl(const S: string; AStart: Integer;
      out AHtml: string): Integer;
  public
    constructor Create(const AOpt: TAmsMarkdownOptions);
    destructor Destroy; override;
    function ResolveImage(const AUrl: string): string;
    function ResolveLink(const AUrl: string): string;
    function Convert(const AMarkdown: string): string;
  end;

{ ------------------------------------------------------------- Puffer --- }

procedure BufInit(out B: TBuf);
begin
  B.S := '';
  B.Len := 0;
end;

procedure BufAdd(var B: TBuf; const T: string);
var
  L: Integer;
begin
  L := Length(T);
  if L = 0 then Exit;
  if B.Len + L > Length(B.S) then
    SetLength(B.S, (B.Len + L) * 2 + 64);
  Move(T[1], B.S[B.Len + 1], L);
  Inc(B.Len, L);
end;

procedure BufAddC(var B: TBuf; C: Char);
begin
  if B.Len + 1 > Length(B.S) then
    SetLength(B.S, B.Len * 2 + 64);
  Inc(B.Len);
  B.S[B.Len] := C;
end;

function BufText(const B: TBuf): string;
begin
  Result := Copy(B.S, 1, B.Len);
end;

{ ---------------------------------------------------------- Kleinkram --- }

function IsWs(C: Char): Boolean; inline;
begin
  Result := C in [' ', #9, #10, #11, #12, #13];
end;

function IsPunct(C: Char): Boolean; inline;
begin
  Result := C in ['!'..'/', ':'..'@', '['..'`', '{'..'~'];
end;

function InList(const AName: string; const AList: array of string): Boolean;
var
  i: Integer;
begin
  for i := Low(AList) to High(AList) do
    if AList[i] = AName then Exit(True);
  Result := False;
end;

function StartsText(const APrefix, S: string): Boolean;
begin
  Result := (Length(S) >= Length(APrefix)) and
            SameText(Copy(S, 1, Length(APrefix)), APrefix);
end;

{ Position von ASub ab AFrom, ohne Gross/Klein. 0 = nicht gefunden. }
function PosCI(const ASub, S: string; AFrom: Integer): Integer;
var
  P: Integer;
begin
  Result := 0;
  if AFrom < 1 then AFrom := 1;
  if AFrom > Length(S) then Exit;
  P := Pos(LowerCase(ASub), LowerCase(Copy(S, AFrom, MaxInt)));
  if P > 0 then Result := P + AFrom - 1;
end;

function RunLen(const S: string; P: Integer; C: Char): Integer;
var
  j: Integer;
begin
  j := P;
  while (j <= Length(S)) and (S[j] = C) do Inc(j);
  Result := j - P;
end;

function CountChar(const S: string; C: Char): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do
    if S[i] = C then Inc(Result);
end;

function Indent(const S: string): Integer;
begin
  Result := 0;
  while (Result < Length(S)) and (S[Result + 1] = ' ') do Inc(Result);
end;

{ Nur Leerzeichen zaehlen als leer - die Aufgabenmarken #2/#3 nicht. }
function IsBlankLine(const S: string): Boolean;
begin
  Result := Indent(S) = Length(S);
end;

function StripLead(const S: string; N: Integer): string;
var
  k: Integer;
begin
  k := 0;
  while (k < N) and (k < Length(S)) and (S[k + 1] = ' ') do Inc(k);
  Result := Copy(S, k + 1, MaxInt);
end;

function TrimLeftSpaces(const S: string): string;
begin
  Result := Copy(S, Indent(S) + 1, MaxInt);
end;

function TrimRightSpaces(const S: string): string;
var
  L: Integer;
begin
  L := Length(S);
  while (L > 0) and (S[L] = ' ') do Dec(L);
  Result := Copy(S, 1, L);
end;

procedure Append(var L: TLines; const S: string);
begin
  SetLength(L, Length(L) + 1);
  L[High(L)] := S;
end;

function SplitStr(const S: string; ASep: Char): TLines;
var
  i, k, Cnt: Integer;
begin
  Result := nil;
  SetLength(Result, CountChar(S, ASep) + 1);
  Cnt := 0;
  k := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] = ASep) then
    begin
      Result[Cnt] := Copy(S, k, i - k);
      Inc(Cnt);
      k := i + 1;
    end;
  SetLength(Result, Cnt);
end;

function JoinLines(const A: TLines): string;
var
  B: TBuf;
  i: Integer;
begin
  BufInit(B);
  for i := 0 to High(A) do
  begin
    if i > 0 then BufAddC(B, #10);
    BufAdd(B, A[i]);
  end;
  Result := BufText(B);
end;

{ Tabulatoren auf die naechste Viererspalte. }
function ExpandTabs(const S: string): string;
var
  i, Col: Integer;
  B: TBuf;
begin
  if Pos(#9, S) = 0 then Exit(S);
  BufInit(B);
  Col := 0;
  for i := 1 to Length(S) do
    if S[i] = #9 then
    begin
      repeat
        BufAddC(B, ' ');
        Inc(Col);
      until Col mod 4 = 0;
    end
    else
    begin
      BufAddC(B, S[i]);
      Inc(Col);
    end;
  Result := BufText(B);
end;

{ ---------------------------------------------------------- Escaping --- }

function AmsHtmlEscape(const AText: string): string;
var
  B: TBuf;
  i: Integer;
begin
  BufInit(B);
  for i := 1 to Length(AText) do
    case AText[i] of
      '&': BufAdd(B, '&amp;');
      '<': BufAdd(B, '&lt;');
      '>': BufAdd(B, '&gt;');
      '"': BufAdd(B, '&quot;');
      '''': BufAdd(B, '&#39;');
    else
      BufAddC(B, AText[i]);
    end;
  Result := BufText(B);
end;

{ Ein Zeichen aus einem Backslash-Escape - nur die HTML-kritischen. }
function EscChar(C: Char): string;
begin
  case C of
    '&': Result := '&amp;';
    '<': Result := '&lt;';
    '>': Result := '&gt;';
    '"': Result := '&quot;';
  else
    Result := C;
  end;
end;

{ Adresse fuer ein Attribut. & wird zu &amp;, Anfuehrungszeichen und
  spitze Klammern zu Entities - mehr nicht, die Adresse bleibt lesbar. }
function UrlAttr(const AUrl: string): string;
var
  B: TBuf;
  i: Integer;
begin
  BufInit(B);
  for i := 1 to Length(AUrl) do
    case AUrl[i] of
      '&': BufAdd(B, '&amp;');
      '"': BufAdd(B, '&quot;');
      '<': BufAdd(B, '&lt;');
      '>': BufAdd(B, '&gt;');
    else
      BufAddC(B, AUrl[i]);
    end;
  Result := BufText(B);
end;

{ Laenge einer gueltigen Entity ab P (&amp; &#123; &#x1F;), sonst 0. }
function EntityLen(const S: string; P: Integer): Integer;
var
  j, k, n: Integer;
begin
  Result := 0;
  n := Length(S);
  if (P > n) or (S[P] <> '&') then Exit;
  j := P + 1;
  if (j <= n) and (S[j] = '#') then
  begin
    Inc(j);
    if (j <= n) and (S[j] in ['x', 'X']) then
    begin
      Inc(j);
      k := j;
      while (j <= n) and (j - k < 6) and
            (S[j] in ['0'..'9', 'a'..'f', 'A'..'F']) do Inc(j);
    end
    else
    begin
      k := j;
      while (j <= n) and (j - k < 7) and (S[j] in ['0'..'9']) do Inc(j);
    end;
    if j = k then Exit;
  end
  else
  begin
    k := j;
    if (j > n) or not (S[j] in ['A'..'Z', 'a'..'z']) then Exit;
    while (j <= n) and (j - k < 32) and
          (S[j] in ['A'..'Z', 'a'..'z', '0'..'9']) do Inc(j);
    if j - k < 2 then Exit;
  end;
  if (j <= n) and (S[j] = ';') then Result := j - P + 1;
end;

{ Die Entities, auf die es bei Adressen und Ankern ankommt, zurueck in
  Zeichen: &amp; &lt; &gt; &quot; &apos; &colon; &tab; &newline; und
  numerische unter 128. Alles andere bleibt stehen. }
function DecodeBasicEntities(const S: string): string;
var
  B: TBuf;
  i, L, Code: Integer;
  Name, Rep: string;
begin
  if Pos('&', S) = 0 then Exit(S);
  BufInit(B);
  i := 1;
  while i <= Length(S) do
  begin
    L := 0;
    if S[i] = '&' then L := EntityLen(S, i);
    if L = 0 then
    begin
      BufAddC(B, S[i]);
      Inc(i);
      Continue;
    end;
    Name := Copy(S, i + 1, L - 2);
    Rep := #0;
    if Name[1] = '#' then
    begin
      if (Length(Name) > 1) and (Name[2] in ['x', 'X']) then
        Code := StrToIntDef('$' + Copy(Name, 3, MaxInt), -1)
      else
        Code := StrToIntDef(Copy(Name, 2, MaxInt), -1);
      if (Code > 0) and (Code < 128) then Rep := Chr(Code);
    end
    else
    begin
      Name := LowerCase(Name);
      if Name = 'amp' then Rep := '&'
      else if Name = 'lt' then Rep := '<'
      else if Name = 'gt' then Rep := '>'
      else if Name = 'quot' then Rep := '"'
      else if Name = 'apos' then Rep := ''''
      else if Name = 'colon' then Rep := ':'
      else if Name = 'tab' then Rep := #9
      else if Name = 'newline' then Rep := #10;
    end;
    if Rep = #0 then
      BufAdd(B, Copy(S, i, L))
    else
      BufAdd(B, Rep);
    Inc(i, L);
  end;
  Result := BufText(B);
end;

{ Backslash vor Satzzeichen weg, dann die Entities - fuer Linkziel und
  Titel aus dem Markdown. }
function Unescape(const S: string): string;
var
  B: TBuf;
  i: Integer;
begin
  BufInit(B);
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '\') and (i < Length(S)) and IsPunct(S[i + 1]) then
      Inc(i);
    BufAddC(B, S[i]);
    Inc(i);
  end;
  Result := DecodeBasicEntities(BufText(B));
end;

function StripTags(const S: string): string;
var
  B: TBuf;
  i: Integer;
  InTag: Boolean;
begin
  BufInit(B);
  InTag := False;
  for i := 1 to Length(S) do
    if InTag then
    begin
      if S[i] = '>' then InTag := False;
    end
    else if S[i] = '<' then
      InTag := True
    else
      BufAddC(B, S[i]);
  Result := BufText(B);
end;

{ Anker wie bei GitHub: klein, Leerzeichen zu "-", Satzzeichen weg,
  UTF-8-Bytes bleiben. }
function Slug(const AHtml: string): string;
var
  P: string;
  B: TBuf;
  i: Integer;
  C: Char;
begin
  P := DecodeBasicEntities(StripTags(AHtml));
  BufInit(B);
  for i := 1 to Length(P) do
  begin
    C := P[i];
    { UTF-8 hat kein Gross/Klein, das hier ginge - ausser im Latin-1-Block
      (C3 80..9E, also auch Ae/Oe/Ue): dort ist "klein" das Folgebyte + $20,
      wie GitHub es auch macht. Das Malzeichen (C3 97) bleibt. }
    if (Ord(C) in [$80..$9E]) and (Ord(C) <> $97) and (i > 1) and
       (P[i - 1] = #$C3) then
      BufAddC(B, Chr(Ord(C) + $20))
    else if C in ['A'..'Z'] then
      BufAddC(B, Chr(Ord(C) + 32))
    else if (C in ['a'..'z', '0'..'9', '-', '_']) or (Ord(C) >= 128) then
      BufAddC(B, C)
    else if C = ' ' then
      BufAddC(B, '-');
  end;
  Result := BufText(B);
end;

{ --------------------------------------------------------- Adressen --- }

{ Laenge bis einschliesslich ":" eines Schemas, sonst 0. "C:" liefert 2. }
function SchemeLen(const S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  if (S = '') or not (S[1] in ['A'..'Z', 'a'..'z']) then Exit;
  i := 2;
  while (i <= Length(S)) and (i <= 33) and
        (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '.', '-']) do Inc(i);
  if (i <= Length(S)) and (S[i] = ':') then Result := i;
end;

function IsAbsoluteRef(const S: string): Boolean;
begin
  Result := (S <> '') and ((S[1] = '#') or (SchemeLen(S) > 0) or
            ((Length(S) >= 2) and (S[1] = '\') and (S[2] = '\')));
end;

function IsHttpUrl(const S: string): Boolean;
begin
  Result := StartsText('http://', S) or StartsText('https://', S);
end;

{ "." und ".." aus einem Pfad. Ein fuehrender Trenner (absoluter Pfad)
  bleibt, ".." ueber die Wurzel wird ignoriert; ein relativer Pfad behaelt
  seine fuehrenden "..". }
function RemoveDotSegments(const APath: string; ASep: Char): string;
var
  Parts, Outp: TLines;
  k, Cnt: Integer;
  Seg: string;
  Last: Boolean;
begin
  Parts := SplitStr(APath, ASep);
  { Ein Teil mehr: ein abschliessendes "." oder ".." legt zusaetzlich ein
    leeres Segment fuer den Trenner am Ende an. }
  SetLength(Outp, Length(Parts) + 1);
  Cnt := 0;
  for k := 0 to High(Parts) do
  begin
    Seg := Parts[k];
    Last := k = High(Parts);
    if Seg = '.' then
    begin
      if Last then
      begin
        Outp[Cnt] := '';
        Inc(Cnt);
      end;
      Continue;
    end;
    if Seg = '..' then
    begin
      if (Cnt > 0) and (Outp[Cnt - 1] <> '..') and
         not ((Cnt = 1) and (Outp[0] = '')) then
        Dec(Cnt)
      else if (Cnt = 0) or (Outp[Cnt - 1] = '..') then
      begin
        Outp[Cnt] := '..';
        Inc(Cnt);
      end;
      if Last then
      begin
        Outp[Cnt] := '';
        Inc(Cnt);
      end;
      Continue;
    end;
    Outp[Cnt] := Seg;
    Inc(Cnt);
  end;
  SetLength(Outp, Cnt);
  Result := '';
  for k := 0 to Cnt - 1 do
  begin
    if k > 0 then Result := Result + ASep;
    Result := Result + Outp[k];
  end;
  { Absoluter Pfad, der zu "" zusammengefallen ist: Wurzel. }
  if (Result = '') and (APath <> '') and (APath[1] = ASep) then
    Result := ASep;
end;

function ResolveFolder(const ABase, ARef: string): string;
var
  Base, Ref, Root, Rest: string;
  p, k, sl: Integer;
begin
  Ref := StringReplace(ARef, '/', '\', [rfReplaceAll]);
  p := Pos('?', Ref);
  if p > 0 then Ref := Copy(Ref, 1, p - 1);
  p := Pos('#', Ref);
  if p > 0 then Ref := Copy(Ref, 1, p - 1);
  Base := ABase;
  if Base[Length(Base)] <> '\' then Base := Base + '\';

  { Wurzel abtrennen: "C:" bzw. "\\server\freigabe" }
  sl := SchemeLen(Base);
  if sl = 2 then
  begin
    Root := Copy(Base, 1, 2);
    Rest := Copy(Base, 3, MaxInt);
  end
  else if (Length(Base) >= 2) and (Base[1] = '\') and (Base[2] = '\') then
  begin
    p := 3;
    for k := 1 to 2 do
    begin
      while (p <= Length(Base)) and (Base[p] <> '\') do Inc(p);
      if k = 1 then Inc(p);
    end;
    Root := Copy(Base, 1, p - 1);
    Rest := Copy(Base, p, MaxInt);
  end
  else
  begin
    Root := '';
    Rest := Base;
  end;
  if (Rest = '') or (Rest[1] <> '\') then Rest := '\' + Rest;

  if (Ref <> '') and (Ref[1] = '\') then
    Rest := Ref
  else
    Rest := Rest + Ref;
  Rest := RemoveDotSegments(Rest, '\');
  if Root = '' then
    Result := Copy(Rest, 2, MaxInt)     { relativer Ordner bleibt relativ }
  else
    Result := Root + Rest;
end;

function AmsResolveUrl(const ABase, ARef: string): string;
var
  Base, Ref, Prefix, Path, RefPath, Suffix: string;
  p, sl: Integer;
  HasAuthority: Boolean;
begin
  Ref := Trim(ARef);
  Base := Trim(ABase);
  if (Ref = '') or (Base = '') or IsAbsoluteRef(Ref) then Exit(Ref);

  sl := SchemeLen(Base);
  { //host/pfad - Schema der Basis uebernehmen }
  if (Length(Ref) >= 2) and (Ref[1] = '/') and (Ref[2] = '/') then
  begin
    if sl > 2 then Exit(Copy(Base, 1, sl) + Ref);
    Exit(Ref);
  end;

  if (sl = 2) or ((Length(Base) >= 2) and (Base[1] = '\') and
     (Base[2] = '\')) or ((sl = 0) and (Pos('\', Base) > 0)) then
    Exit(ResolveFolder(Base, Ref));

  HasAuthority := False;
  if sl > 0 then
  begin
    if Copy(Base, sl + 1, 2) = '//' then
    begin
      HasAuthority := True;
      p := sl + 3;
      while (p <= Length(Base)) and not (Base[p] in ['/', '?', '#']) do Inc(p);
      Prefix := Copy(Base, 1, p - 1);
      Path := Copy(Base, p, MaxInt);
    end
    else
    begin
      Prefix := Copy(Base, 1, sl);
      Path := Copy(Base, sl + 1, MaxInt);
    end;
  end
  else
  begin
    Prefix := '';
    Path := Base;
  end;

  p := Pos('#', Path);
  if p > 0 then Path := Copy(Path, 1, p - 1);
  p := Pos('?', Path);
  if p > 0 then Path := Copy(Path, 1, p - 1);
  if Ref[1] = '?' then Exit(Prefix + Path + Ref);

  p := 1;
  while (p <= Length(Ref)) and not (Ref[p] in ['?', '#']) do Inc(p);
  RefPath := Copy(Ref, 1, p - 1);
  Suffix := Copy(Ref, p, MaxInt);

  if (RefPath <> '') and (RefPath[1] = '/') then
    Path := RefPath
  else
  begin
    { Verzeichnis der Basis: alles bis einschliesslich zum letzten "/". }
    p := Length(Path);
    while (p > 0) and (Path[p] <> '/') do Dec(p);
    if p > 0 then
      Path := Copy(Path, 1, p)
    else if HasAuthority then
      Path := '/'
    else
      Path := '';
    Path := Path + RefPath;
  end;
  Result := Prefix + RemoveDotSegments(Path, '/') + Suffix;
end;

{ javascript:, vbscript: & Co. - und data:, ausser fuer Bilder. Vor dem
  Vergleich werden Entities aufgeloest und alles bis einschliesslich
  Leerzeichen entfernt: "jav&#x61;script:" und "java script:" sind
  dieselbe Falle. }
function IsUnsafeUrl(const AUrl: string; AImage: Boolean): Boolean;
var
  S, T: string;
  i: Integer;
begin
  S := LowerCase(DecodeBasicEntities(Copy(AUrl, 1, 256)));
  T := '';
  for i := 1 to Length(S) do
  begin
    if S[i] > ' ' then T := T + S[i];
    if Length(T) >= 16 then Break;
  end;
  Result := StartsText('javascript:', T) or StartsText('vbscript:', T) or
            StartsText('livescript:', T) or StartsText('mocha:', T) or
            (StartsText('data:', T) and
             not (AImage and StartsText('data:image/', T)));
end;

{ -------------------------------------------------------------- Tags --- }

{ Tag ab P parsen (S[P] = '<'). Liefert die Laenge oder 0, wenn dort kein
  vollstaendiges Tag steht. }
function ParseTag(const S: string; P: Integer; out T: TTagInfo): Integer;
var
  n, j, k, q: Integer;
  HadWs: Boolean;
  A: TTagAttr;
  Quote: Char;
begin
  Result := 0;
  T.Name := '';
  T.Closing := False;
  T.SelfClosing := False;
  SetLength(T.Attrs, 0);
  n := Length(S);
  if (P < 1) or (P > n) or (S[P] <> '<') then Exit;
  j := P + 1;
  if (j <= n) and (S[j] = '/') then
  begin
    T.Closing := True;
    Inc(j);
  end;
  if (j > n) or not (S[j] in ['A'..'Z', 'a'..'z']) then Exit;
  k := j;
  while (j <= n) and (S[j] in ['A'..'Z', 'a'..'z', '0'..'9', '-', ':']) do
    Inc(j);
  T.Name := LowerCase(Copy(S, k, j - k));
  if T.Closing then
  begin
    while (j <= n) and IsWs(S[j]) do Inc(j);
    if (j <= n) and (S[j] = '>') then Result := j - P + 1;
    Exit;
  end;

  while True do
  begin
    HadWs := False;
    while (j <= n) and IsWs(S[j]) do
    begin
      Inc(j);
      HadWs := True;
    end;
    if j > n then Exit;
    if S[j] = '>' then Break;
    if (S[j] = '/') and (j < n) and (S[j + 1] = '>') then
    begin
      T.SelfClosing := True;
      Inc(j);
      Break;
    end;
    if not HadWs then Exit;
    if not (S[j] in ['A'..'Z', 'a'..'z', '_', ':']) then Exit;
    k := j;
    while (j <= n) and
          (S[j] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', ':', '-']) do
      Inc(j);
    A.Name := LowerCase(Copy(S, k, j - k));
    A.Value := '';
    A.HasValue := False;
    q := j;
    while (q <= n) and IsWs(S[q]) do Inc(q);
    if (q <= n) and (S[q] = '=') then
    begin
      j := q + 1;
      while (j <= n) and IsWs(S[j]) do Inc(j);
      if j > n then Exit;
      if S[j] in ['"', ''''] then
      begin
        Quote := S[j];
        Inc(j);
        k := j;
        while (j <= n) and (S[j] <> Quote) do Inc(j);
        if j > n then Exit;
        A.Value := Copy(S, k, j - k);
        Inc(j);
      end
      else
      begin
        k := j;
        while (j <= n) and not IsWs(S[j]) and
              not (S[j] in ['"', '''', '=', '<', '>', '`']) do Inc(j);
        if j = k then Exit;
        A.Value := Copy(S, k, j - k);
      end;
      A.HasValue := True;
    end;
    { Muellschutz: kein echtes Tag hat so viele Attribute. }
    if Length(T.Attrs) >= 256 then Exit;
    SetLength(T.Attrs, Length(T.Attrs) + 1);
    T.Attrs[High(T.Attrs)] := A;
  end;
  Result := j - P + 1;
end;

{ Attributwert ohne Adresse: Anfuehrungszeichen und spitze Klammern als
  Entities, & bleibt (kann schon eine Entity sein). }
function AttrValue(const S: string): string;
begin
  Result := StringReplace(S, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

function DangerousStyle(const S: string): Boolean;
var
  L: string;
begin
  L := LowerCase(S);
  Result := (Pos('expression', L) > 0) or (Pos('behavior', L) > 0) or
            (Pos('javascript', L) > 0) or (Pos('vbscript', L) > 0) or
            (Pos('-moz-binding', L) > 0);
end;

{ Tag sauber neu aufbauen. AConv <> nil loest dabei <img src> und <a href>
  ueber die Optionen des Umwandlers auf. }
function RebuildTag(const T: TTagInfo; AConv: TMdConverter): string;
var
  i: Integer;
  An, V, D: string;
  External, HasTarget: Boolean;
begin
  if T.Closing then Exit('</' + T.Name + '>');
  Result := '<' + T.Name;
  External := False;
  HasTarget := False;
  for i := 0 to High(T.Attrs) do
  begin
    An := T.Attrs[i].Name;
    if StartsText('on', An) or (An = 'srcset') or (An = 'formaction') then
      Continue;
    if not T.Attrs[i].HasValue then
    begin
      Result := Result + ' ' + An;
      Continue;
    end;
    V := T.Attrs[i].Value;
    if (An = 'style') and DangerousStyle(DecodeBasicEntities(V)) then
      Continue;
    if InList(An, URL_ATTRS) then
    begin
      D := DecodeBasicEntities(V);
      if IsUnsafeUrl(D, (T.Name = 'img') and (An = 'src')) then Continue;
      if AConv <> nil then
      begin
        if (T.Name = 'img') and (An = 'src') then
          D := AConv.ResolveImage(D)
        else if (T.Name = 'a') and (An = 'href') then
        begin
          D := AConv.ResolveLink(D);
          External := IsHttpUrl(D);
        end;
      end;
      Result := Result + ' ' + An + '="' + UrlAttr(D) + '"';
      Continue;
    end;
    if An = 'target' then HasTarget := True;
    Result := Result + ' ' + An + '="' + AttrValue(V) + '"';
  end;
  if (AConv <> nil) and External and not HasTarget and
     AConv.FOpt.ExternalLinksNewWindow then
    Result := Result + ' target="_blank" rel="noopener"';
  if T.SelfClosing then Result := Result + ' /';
  Result := Result + '>';
end;

{ Ende eines verbotenen Elements samt Inhalt ab P suchen. Liefert die
  Position hinter dessen ">" bzw. hinter das Textende. }
function SkipElement(const S, AName: string; P: Integer): Integer;
var
  k, e: Integer;
begin
  k := PosCI('</' + AName, S, P);
  if k = 0 then Exit(Length(S) + 1);
  e := k;
  while (e <= Length(S)) and (S[e] <> '>') do Inc(e);
  Result := e + 1;
end;

function SanitizeCore(const H: string; AConv: TMdConverter): string;
var
  B: TBuf;
  i, n, k, L: Integer;
  T: TTagInfo;
begin
  BufInit(B);
  n := Length(H);
  i := 1;
  while i <= n do
  begin
    if H[i] <> '<' then
    begin
      BufAddC(B, H[i]);
      Inc(i);
      Continue;
    end;
    { Kommentare fliegen raus - auch weil alte IE-Fassungen in bedingten
      Kommentaren Code ausfuehren. }
    if Copy(H, i, 4) = '<!--' then
    begin
      k := Pos('-->', Copy(H, i + 4, MaxInt));
      if k = 0 then Break;
      i := i + 4 + k - 1 + 3;
      Continue;
    end;
    if (i < n) and (H[i + 1] in ['!', '?']) then
    begin
      k := i;
      while (k <= n) and (H[k] <> '>') do Inc(k);
      i := k + 1;
      Continue;
    end;
    L := ParseTag(H, i, T);
    if L = 0 then
    begin
      BufAdd(B, '&lt;');
      Inc(i);
      Continue;
    end;
    if InList(T.Name, DROP_WITH_CONTENT) then
    begin
      if T.Closing or T.SelfClosing then
        i := i + L
      else
        i := SkipElement(H, T.Name, i + L);
      Continue;
    end;
    if InList(T.Name, DROP_TAG) then
    begin
      i := i + L;
      Continue;
    end;
    BufAdd(B, RebuildTag(T, AConv));
    i := i + L;
  end;
  Result := BufText(B);
end;

function AmsSanitizeHtml(const AHtml: string): string;
begin
  try
    Result := SanitizeCore(AHtml, nil);
  except
    Result := AmsHtmlEscape(AHtml);
  end;
end;

{ ------------------------------------------------------ Blockerkennung - }

function IsFence(const T: string; out AFch: Char; out AFlen: Integer;
  out AInfo: string): Boolean;
begin
  Result := False;
  AFch := #0;
  AFlen := 0;
  AInfo := '';
  if (T = '') or not (T[1] in ['`', '~']) then Exit;
  AFch := T[1];
  AFlen := RunLen(T, 1, AFch);
  if AFlen < 3 then Exit;
  AInfo := Trim(Copy(T, AFlen + 1, MaxInt));
  if (AFch = '`') and (Pos('`', AInfo) > 0) then Exit;
  Result := True;
end;

function IsFenceClose(const ALine: string; AFch: Char; AFlen: Integer): Boolean;
var
  ind, run: Integer;
  T: string;
begin
  Result := False;
  ind := Indent(ALine);
  if ind >= 4 then Exit;
  T := Copy(ALine, ind + 1, MaxInt);
  run := RunLen(T, 1, AFch);
  if run < AFlen then Exit;
  Result := IsBlankLine(Copy(T, run + 1, MaxInt));
end;

function IsAtx(const T: string; out ALevel: Integer; out AText: string): Boolean;
var
  L, j: Integer;
begin
  Result := False;
  ALevel := 0;
  AText := '';
  L := RunLen(T, 1, '#');
  if (L = 0) or (L > 6) then Exit;
  if (Length(T) > L) and (T[L + 1] <> ' ') then Exit;
  AText := Trim(Copy(T, L + 1, MaxInt));
  { schliessende Folge "## Titel ##" }
  j := Length(AText);
  while (j > 0) and (AText[j] = '#') do Dec(j);
  if j = 0 then
    AText := ''
  else if (j < Length(AText)) and (AText[j] = ' ') then
    AText := TrimRightSpaces(Copy(AText, 1, j));
  ALevel := L;
  Result := True;
end;

function IsHr(const T: string): Boolean;
var
  i, j, Cnt: Integer;
  C: Char;
begin
  Result := False;
  j := Indent(T) + 1;
  if (j > Length(T)) or not (T[j] in ['-', '*', '_']) then Exit;
  C := T[j];
  Cnt := 0;
  for i := j to Length(T) do
    if T[i] = C then
      Inc(Cnt)
    else if T[i] <> ' ' then
      Exit;
  Result := Cnt >= 3;
end;

function IsSetext(const T: string; out ALevel: Integer): Boolean;
var
  S: string;
begin
  Result := False;
  ALevel := 0;
  S := TrimRightSpaces(T);
  if S = '' then Exit;
  if RunLen(S, 1, '=') = Length(S) then ALevel := 1
  else if RunLen(S, 1, '-') = Length(S) then ALevel := 2
  else Exit;
  Result := True;
end;

function ParseMark(const ALine: string; out M: TListMark): Boolean;
var
  ind, p, q, n, mlen, e, sp: Integer;
begin
  Result := False;
  M.Ordered := False;
  M.Ch := #0;
  M.Start := 1;
  M.MIndent := 0;
  M.CIndent := 0;
  M.Text := '';
  M.Empty := False;
  n := Length(ALine);
  ind := Indent(ALine);
  p := ind + 1;
  if p > n then Exit;
  if ALine[p] in ['-', '*', '+'] then
  begin
    if IsHr(Copy(ALine, p, MaxInt)) then Exit;
    M.Ch := ALine[p];
    mlen := 1;
  end
  else if ALine[p] in ['0'..'9'] then
  begin
    q := p;
    while (q <= n) and (q - p < 9) and (ALine[q] in ['0'..'9']) do Inc(q);
    if (q > n) or not (ALine[q] in ['.', ')']) then Exit;
    M.Ordered := True;
    M.Start := StrToIntDef(Copy(ALine, p, q - p), 1);
    M.Ch := ALine[q];
    mlen := q - p + 1;
  end
  else
    Exit;
  e := p + mlen;
  if (e <= n) and (ALine[e] <> ' ') then Exit;
  sp := 0;
  while (e + sp <= n) and (ALine[e + sp] = ' ') do Inc(sp);
  if e + sp > n then
  begin
    M.Empty := True;
    M.CIndent := ind + mlen + 1;
  end
  else if sp >= 5 then
  begin
    { Inhalt ist eingerueckter Code: Inhalt beginnt eine Spalte nach der Marke. }
    M.CIndent := ind + mlen + 1;
    M.Text := Copy(ALine, e + 1, MaxInt);
  end
  else
  begin
    M.CIndent := ind + mlen + sp;
    M.Text := Copy(ALine, e + sp, MaxInt);
  end;
  M.MIndent := ind;
  Result := True;
end;

function SameKind(const A, B: TListMark): Boolean;
begin
  Result := (A.Ordered = B.Ordered) and (A.Ch = B.Ch);
end;

{ 1 script/pre/style/textarea, 2 Kommentar, 3 <?, 4 <!X, 5 CDATA,
  6 Blockelement, 7 einzelnes vollstaendiges Tag allein auf der Zeile
  (darf keinen Absatz unterbrechen), 0 = kein HTML-Block. }
function HtmlKind(const T: string; AInPara: Boolean): Integer;
const
  RAW_TAGS: array[0..3] of string = ('script', 'pre', 'style', 'textarea');
var
  Lt, Name: string;
  i, p, k: Integer;
  Info: TTagInfo;
begin
  Result := 0;
  if (T = '') or (T[1] <> '<') then Exit;
  Lt := LowerCase(Copy(T, 1, 64));
  if Copy(Lt, 1, 4) = '<!--' then Exit(2);
  for i := Low(RAW_TAGS) to High(RAW_TAGS) do
    if (Copy(Lt, 1, Length(RAW_TAGS[i]) + 1) = '<' + RAW_TAGS[i]) then
    begin
      p := Length(RAW_TAGS[i]) + 2;
      if (p > Length(Lt)) or (Lt[p] in [' ', '>']) then Exit(1);
    end;
  if Copy(Lt, 1, 2) = '<?' then Exit(3);
  if Copy(Lt, 1, 9) = '<![cdata[' then Exit(5);
  if (Length(Lt) >= 3) and (Lt[2] = '!') and (Lt[3] in ['a'..'z']) then
    Exit(4);

  p := 2;
  if (p <= Length(Lt)) and (Lt[p] = '/') then Inc(p);
  if (p > Length(Lt)) or not (Lt[p] in ['a'..'z']) then Exit;
  k := p;
  while (k <= Length(Lt)) and (Lt[k] in ['a'..'z', '0'..'9', '-']) do Inc(k);
  Name := Copy(Lt, p, k - p);
  if InList(Name, BLOCK_TAGS) and
     ((k > Length(Lt)) or (Lt[k] in [' ', '>']) or
      (Copy(Lt, k, 2) = '/>')) then
    Exit(6);
  if AInPara then Exit;
  k := ParseTag(T, 1, Info);
  if (k > 0) and IsBlankLine(Copy(T, k + 1, MaxInt)) then Result := 7;
end;

function HtmlEnd(AKind: Integer; const ALine: string): Boolean;
var
  L: string;
begin
  L := LowerCase(ALine);
  case AKind of
    1: Result := (Pos('</script>', L) > 0) or (Pos('</pre>', L) > 0) or
                 (Pos('</style>', L) > 0) or (Pos('</textarea>', L) > 0);
    2: Result := Pos('-->', L) > 0;
    3: Result := Pos('?>', L) > 0;
    4: Result := Pos('>', L) > 0;
    5: Result := Pos(']]>', L) > 0;
  else
    Result := True;
  end;
end;

{ Beginnt die Zeile einen eigenen Block? Dann ist sie keine faule
  Fortsetzung eines Absatzes in Zitat oder Liste. }
function StartsBlock(const ALine: string): Boolean;
var
  ind, lvl, flen: Integer;
  T, Info: string;
  Fch: Char;
  M: TListMark;
begin
  Result := False;
  if IsBlankLine(ALine) then Exit;
  ind := Indent(ALine);
  if ind >= 4 then Exit;
  T := Copy(ALine, ind + 1, MaxInt);
  Result := IsFence(T, Fch, flen, Info) or IsAtx(T, lvl, Info) or IsHr(T) or
            (T[1] = '>') or ParseMark(ALine, M) or (HtmlKind(T, True) > 0);
end;

function HasUnescapedPipe(const S: string): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if (S[i] = '|') and ((i = 1) or (S[i - 1] <> '\')) then Exit(True);
  Result := False;
end;

function SplitRow(const ALine: string): TLines;
var
  S: string;
  i, k: Integer;
begin
  Result := nil;
  S := Trim(ALine);
  if (S <> '') and (S[1] = '|') then Delete(S, 1, 1);
  if (S <> '') and (S[Length(S)] = '|') and
     not ((Length(S) >= 2) and (S[Length(S) - 1] = '\')) then
    Delete(S, Length(S), 1);
  k := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or ((S[i] = '|') and ((i = 1) or (S[i - 1] <> '\'))) then
    begin
      Append(Result, Copy(S, k, i - k));
      k := i + 1;
    end;
end;

function IsDelimCell(const S: string): Boolean;
var
  T: string;
  a, z: Integer;
begin
  T := Trim(S);
  Result := False;
  if T = '' then Exit;
  a := 1;
  z := Length(T);
  if T[a] = ':' then Inc(a);
  if (z >= a) and (T[z] = ':') then Dec(z);
  if z < a then Exit;
  Result := RunLen(T, a, '-') = z - a + 1;
end;

function IsTableStart(const L1, L2: string): Boolean;
var
  D, H: TLines;
  i: Integer;
begin
  Result := False;
  if (Indent(L1) >= 4) or (Indent(L2) >= 4) then Exit;
  if not HasUnescapedPipe(L1) or (Pos('|', L2) = 0) then Exit;
  D := SplitRow(L2);
  if Length(D) = 0 then Exit;
  for i := 0 to High(D) do
    if not IsDelimCell(D[i]) then Exit;
  H := SplitRow(L1);
  Result := Length(H) = Length(D);
end;

function NormLabel(const S: string): string;
var
  B: TBuf;
  i: Integer;
  Sp: Boolean;
  T: string;
begin
  T := LowerCase(Trim(S));
  BufInit(B);
  Sp := False;
  for i := 1 to Length(T) do
    if IsWs(T[i]) then
      Sp := True
    else
    begin
      if Sp then BufAddC(B, ' ');
      Sp := False;
      BufAddC(B, T[i]);
    end;
  Result := BufText(B);
end;

{ "[label]: ziel "titel"" auf einer Zeile. Fussnoten ([^1]:) nicht. }
function ParseRefDef(const T: string; out ALabel, AUrl, ATitle: string): Boolean;
var
  n, j, k: Integer;
  Close: Char;
  HadWs: Boolean;
  Dest: string;
begin
  Result := False;
  ALabel := '';
  AUrl := '';
  ATitle := '';
  n := Length(T);
  if (n < 4) or (T[1] <> '[') then Exit;
  j := 2;
  while (j <= n) and (T[j] <> ']') do
  begin
    if T[j] = '[' then Exit;
    if T[j] = '\' then Inc(j);
    Inc(j);
  end;
  if j > n then Exit;
  ALabel := Copy(T, 2, j - 2);
  if (Trim(ALabel) = '') or (ALabel[1] = '^') or (Length(ALabel) > 999) then
    Exit;
  Inc(j);
  if (j > n) or (T[j] <> ':') then Exit;
  Inc(j);
  while (j <= n) and (T[j] = ' ') do Inc(j);
  if j > n then Exit;
  if T[j] = '<' then
  begin
    k := j + 1;
    while (k <= n) and (T[k] <> '>') do Inc(k);
    if k > n then Exit;
    Dest := Copy(T, j + 1, k - j - 1);
    j := k + 1;
  end
  else
  begin
    k := j;
    while (k <= n) and (T[k] <> ' ') do Inc(k);
    Dest := Copy(T, j, k - j);
    j := k;
    if Dest = '' then Exit;
  end;
  HadWs := (j <= n) and (T[j] = ' ');
  while (j <= n) and (T[j] = ' ') do Inc(j);
  if j <= n then
  begin
    if not HadWs or not (T[j] in ['"', '''', '(']) then Exit;
    if T[j] = '(' then Close := ')' else Close := T[j];
    k := j + 1;
    while (k <= n) and (T[k] <> Close) do
    begin
      if T[k] = '\' then Inc(k);
      Inc(k);
    end;
    if k > n then Exit;
    ATitle := Unescape(Copy(T, j + 1, k - j - 1));
    if not IsBlankLine(Copy(T, k + 1, MaxInt)) then Exit;
  end;
  AUrl := Unescape(Dest);
  Result := True;
end;

{ -------------------------------------------------------- Umwandler --- }

constructor TMdConverter.Create(const AOpt: TAmsMarkdownOptions);
begin
  inherited Create;
  FOpt := AOpt;
  FRefKeys := TStringList.Create;
  FRefUrls := TStringList.Create;
  FRefTitles := TStringList.Create;
  FIds := TStringList.Create;
end;

destructor TMdConverter.Destroy;
begin
  FRefKeys.Free;
  FRefUrls.Free;
  FRefTitles.Free;
  FIds.Free;
  inherited Destroy;
end;

function TMdConverter.ResolveImage(const AUrl: string): string;
var
  R: string;
begin
  Result := AUrl;
  if FOpt.ImageBase <> '' then Result := AmsResolveUrl(FOpt.ImageBase, AUrl);
  if Assigned(FOpt.OnImage) and not StartsText('data:', Result) then
  try
    R := FOpt.OnImage(Result);
    if R <> '' then Result := R;
  except
    { Ein kaputter Bildlader darf die Seite nicht kosten. }
  end;
end;

function TMdConverter.ResolveLink(const AUrl: string): string;
begin
  if (AUrl <> '') and (AUrl[1] <> '#') and (FOpt.LinkBase <> '') then
    Result := AmsResolveUrl(FOpt.LinkBase, AUrl)
  else
    Result := AUrl;
end;

function TMdConverter.TargetAttr(const AHref: string): string;
begin
  if FOpt.ExternalLinksNewWindow and IsHttpUrl(AHref) then
    Result := ' target="_blank" rel="noopener"'
  else
    Result := '';
end;

function TMdConverter.UniqueId(const AId: string): string;
var
  k: Integer;
  Base: string;
begin
  Base := AId;
  if Base = '' then Base := 'abschnitt';
  Result := Base;
  k := 0;
  while FIds.IndexOf(Result) >= 0 do
  begin
    Inc(k);
    Result := Base + '-' + IntToStr(k);
  end;
  FIds.Add(Result);
end;

procedure TMdConverter.CollectRefs(var A: TLines);
var
  i, ind, Flen, Clen: Integer;
  T, Info, Lbl, Url, Title, Key: string;
  Fch, Cch: Char;
  InFence: Boolean;
begin
  InFence := False;
  Cch := #0;
  Clen := 0;
  for i := 0 to High(A) do
  begin
    if InFence then
    begin
      if IsFenceClose(A[i], Cch, Clen) then InFence := False;
      Continue;
    end;
    ind := Indent(A[i]);
    if ind >= 4 then Continue;
    T := Copy(A[i], ind + 1, MaxInt);
    if IsFence(T, Fch, Flen, Info) then
    begin
      InFence := True;
      Cch := Fch;
      Clen := Flen;
      Continue;
    end;
    if (T <> '') and (T[1] = '[') and ParseRefDef(T, Lbl, Url, Title) then
    begin
      Key := NormLabel(Lbl);
      if (Key <> '') and (FRefKeys.IndexOf(Key) < 0) then
      begin
        FRefKeys.Add(Key);
        FRefUrls.Add(Url);
        FRefTitles.Add(Title);
      end;
      { Leerzeile statt Loeschen: die Absaetze davor und danach bleiben
        getrennt. }
      A[i] := '';
    end;
  end;
end;

function TMdConverter.LookupRef(const ALabel: string;
  out AUrl, ATitle: string): Boolean;
var
  k: Integer;
begin
  AUrl := '';
  ATitle := '';
  k := FRefKeys.IndexOf(NormLabel(ALabel));
  Result := k >= 0;
  if Result then
  begin
    AUrl := FRefUrls[k];
    ATitle := FRefTitles[k];
  end;
end;

function TMdConverter.Convert(const AMarkdown: string): string;
var
  B: TBuf;
  i, Start: Integer;
  C: Char;
  Lines: TLines;
begin
  { Steuerzeichen raus (die Aufgabenmarken brauchen #2/#3 fuer sich),
    BOM weg, Zeilenenden vereinheitlichen. }
  BufInit(B);
  Start := 1;
  if Copy(AMarkdown, 1, 3) = #$EF#$BB#$BF then Start := 4;
  i := Start;
  while i <= Length(AMarkdown) do
  begin
    C := AMarkdown[i];
    if C = #13 then
    begin
      BufAddC(B, #10);
      if (i < Length(AMarkdown)) and (AMarkdown[i + 1] = #10) then Inc(i);
    end
    else if (C >= ' ') or (C = #9) or (C = #10) then
      BufAddC(B, C);
    Inc(i);
  end;
  Lines := SplitStr(BufText(B), #10);
  for i := 0 to High(Lines) do Lines[i] := ExpandTabs(Lines[i]);
  CollectRefs(Lines);
  Result := Blocks(Lines, False, 0);
end;

{ -------------------------------------------------------------- Bloecke - }

function TMdConverter.Blocks(const A: TLines; ATight: Boolean;
  ADepth: Integer): string;
var
  B: TBuf;
  i, n, ind, lvl, Flen, Kind: Integer;
  Line, T, Info, Txt: string;
  Fch: Char;
  M: TListMark;
begin
  BufInit(B);
  n := Length(A);
  if ADepth > MAX_DEPTH then
    Exit('<p>' + AmsHtmlEscape(JoinLines(A)) + '</p>'#10);
  i := 0;
  while i < n do
  begin
    Line := A[i];
    if IsBlankLine(Line) then
    begin
      Inc(i);
      Continue;
    end;
    ind := Indent(Line);
    if ind >= 4 then
    begin
      i := DoIndentedCode(A, i, B);
      Continue;
    end;
    T := Copy(Line, ind + 1, MaxInt);
    Kind := 0;
    if IsFence(T, Fch, Flen, Info) then
      i := DoFence(A, i, ind, Fch, Flen, Info, B)
    else if IsAtx(T, lvl, Txt) then
    begin
      DoHeading(lvl, Txt, B);
      Inc(i);
    end
    else if IsHr(T) then
    begin
      BufAdd(B, '<hr>'#10);
      Inc(i);
    end
    else if T[1] = '>' then
      i := DoQuote(A, i, ADepth, B)
    else if ParseMark(Line, M) then
      i := DoList(A, i, ADepth, B)
    else
    begin
      Kind := HtmlKind(T, False);
      if Kind > 0 then
        i := DoHtml(A, i, Kind, B)
      else if (i + 1 < n) and IsTableStart(Line, A[i + 1]) then
        i := DoTable(A, i, B)
      else
        i := DoParagraph(A, i, ATight, B);
    end;
  end;
  Result := BufText(B);
end;

function TMdConverter.DoParagraph(const A: TLines; I: Integer;
  ATight: Boolean; var B: TBuf): Integer;
var
  n, ind, lvl, Flen: Integer;
  Line, T, Txt, Info: string;
  Fch: Char;
  M: TListMark;
begin
  n := Length(A);
  Txt := TrimLeftSpaces(A[I]);
  Inc(I);
  while I < n do
  begin
    Line := A[I];
    if IsBlankLine(Line) then Break;
    ind := Indent(Line);
    if ind < 4 then
    begin
      T := Copy(Line, ind + 1, MaxInt);
      if IsSetext(T, lvl) then
      begin
        DoHeading(lvl, Txt, B);
        Exit(I + 1);
      end;
      if IsFence(T, Fch, Flen, Info) or IsAtx(T, lvl, Info) or IsHr(T) or
         (T[1] = '>') or (HtmlKind(T, True) > 0) then Break;
      { Eine Liste unterbricht einen Absatz nur mit Inhalt, eine geordnete
        nur ab 1 - sonst waere "2020. war ein Jahr" eine Liste. }
      if ParseMark(Line, M) and not M.Empty and
         (not M.Ordered or (M.Start = 1)) then Break;
      if (I + 1 < n) and IsTableStart(Line, A[I + 1]) then Break;
    end;
    Txt := Txt + #10 + TrimLeftSpaces(Line);
    Inc(I);
  end;
  Txt := TrimRightSpaces(Txt);
  if ATight then
    BufAdd(B, Inlines(Txt, False, 0) + #10)
  else
    BufAdd(B, '<p>' + Inlines(Txt, False, 0) + '</p>'#10);
  Result := I;
end;

procedure TMdConverter.DoHeading(ALevel: Integer; const AText: string;
  var B: TBuf);
var
  H, L: string;
begin
  H := Inlines(Trim(AText), False, 0);
  L := IntToStr(ALevel);
  BufAdd(B, '<h' + L + ' id="' + UrlAttr(UniqueId(Slug(H))) + '">' + H +
            '</h' + L + '>'#10);
end;

function TMdConverter.DoIndentedCode(const A: TLines; I: Integer;
  var B: TBuf): Integer;
var
  n, Last, k: Integer;
  L: TLines;
  S: string;
begin
  n := Length(A);
  SetLength(L, 0);
  while (I < n) and (IsBlankLine(A[I]) or (Indent(A[I]) >= 4)) do
  begin
    Append(L, StripLead(A[I], 4));
    Inc(I);
  end;
  Last := High(L);
  while (Last >= 0) and IsBlankLine(L[Last]) do Dec(Last);
  S := '';
  for k := 0 to Last do S := S + L[k] + #10;
  BufAdd(B, '<pre><code>' + AmsHtmlEscape(S) + '</code></pre>'#10);
  Result := I;
end;

function TMdConverter.DoFence(const A: TLines; I, AIndent: Integer;
  AFch: Char; AFlen: Integer; const AInfo: string; var B: TBuf): Integer;
var
  n, p: Integer;
  S, Lang: string;
begin
  n := Length(A);
  Inc(I);
  S := '';
  while I < n do
  begin
    if IsFenceClose(A[I], AFch, AFlen) then
    begin
      Inc(I);
      Break;
    end;
    S := S + StripLead(A[I], AIndent) + #10;
    Inc(I);
  end;
  Lang := Unescape(AInfo);
  p := Pos(' ', Lang);
  if p > 0 then Lang := Copy(Lang, 1, p - 1);
  if Lang <> '' then
    BufAdd(B, '<pre><code class="language-' + AmsHtmlEscape(Lang) + '">')
  else
    BufAdd(B, '<pre><code>');
  BufAdd(B, AmsHtmlEscape(S) + '</code></pre>'#10);
  Result := I;
end;

function TMdConverter.DoQuote(const A: TLines; I, ADepth: Integer;
  var B: TBuf): Integer;
const
  KINDS: array[0..4] of string = ('note', 'tip', 'important', 'warning',
                                  'caution');
  TITLES: array[0..4] of string = ('Hinweis', 'Tipp', 'Wichtig', 'Warnung',
                                   'Vorsicht');
var
  n, ind, k, Alert: Integer;
  Q: TLines;
  Line, S: string;
begin
  n := Length(A);
  SetLength(Q, 0);
  while I < n do
  begin
    Line := A[I];
    ind := Indent(Line);
    if (ind < 4) and (ind < Length(Line)) and (Line[ind + 1] = '>') then
    begin
      S := Copy(Line, ind + 2, MaxInt);
      if (S <> '') and (S[1] = ' ') then Delete(S, 1, 1);
      Append(Q, S);
    end
    else if IsBlankLine(Line) then
      Break
    else if (Length(Q) > 0) and not IsBlankLine(Q[High(Q)]) and
            not StartsBlock(Line) then
      Append(Q, Line)              { faule Fortsetzung des Absatzes }
    else
      Break;
    Inc(I);
  end;

  { GitHub-Hinweise: "> [!NOTE]" allein auf der ersten Zeile. }
  Alert := -1;
  if Length(Q) > 0 then
    for k := Low(KINDS) to High(KINDS) do
      if SameText(Trim(Q[0]), '[!' + KINDS[k] + ']') then
      begin
        Alert := k;
        Q[0] := '';
        Break;
      end;
  if Alert >= 0 then
    BufAdd(B, '<div class="markdown-alert markdown-alert-' + KINDS[Alert] +
              '">'#10'<p class="markdown-alert-title">' + TITLES[Alert] +
              '</p>'#10 + Blocks(Q, False, ADepth + 1) + '</div>'#10)
  else
    BufAdd(B, '<blockquote>'#10 + Blocks(Q, False, ADepth + 1) +
              '</blockquote>'#10);
  Result := I;
end;

function TMdConverter.DoList(const A: TLines; I, ADepth: Integer;
  var B: TBuf): Integer;
var
  n, ind, ci, mind, k: Integer;
  First, M: TListMark;
  Items: TLinesArr;
  Cur, Item: TLines;
  Loose, SawBlank, AnyTask: Boolean;
  Line, S, Body, Open, Close, LiOpen: string;
  Task: array of Char;

  procedure AddItem;
  begin
    SetLength(Items, Length(Items) + 1);
    Items[High(Items)] := Cur;
  end;

begin
  n := Length(A);
  ParseMark(A[I], First);
  SetLength(Items, 0);
  SetLength(Cur, 0);
  Append(Cur, First.Text);
  ci := First.CIndent;
  mind := First.MIndent;
  Loose := False;
  SawBlank := False;
  Inc(I);
  while I < n do
  begin
    Line := A[I];
    if IsBlankLine(Line) then
    begin
      Append(Cur, '');
      SawBlank := True;
      Inc(I);
      Continue;
    end;
    ind := Indent(Line);
    { Gehoert zum laufenden Punkt: genug eingerueckt - oder eine Marke,
      die tiefer steht als die eigene (verzeiht 2er-Einrueckung unter
      "1." und Listen anderer Art darunter). }
    if (ind >= ci) or
       ((ind > mind) and ParseMark(Line, M) and
        (not SameKind(M, First) or (ind >= mind + 2))) then
    begin
      if SawBlank then Loose := True;
      Append(Cur, StripLead(Line, ci));
      SawBlank := False;
      Inc(I);
      Continue;
    end;
    if ParseMark(Line, M) and SameKind(M, First) then
    begin
      AddItem;
      if SawBlank then Loose := True;
      SetLength(Cur, 0);
      Append(Cur, M.Text);
      ci := M.CIndent;
      mind := M.MIndent;
      SawBlank := False;
      Inc(I);
      Continue;
    end;
    if not SawBlank and not StartsBlock(Line) then
    begin
      Append(Cur, TrimLeftSpaces(Line));     { faule Fortsetzung }
      Inc(I);
      Continue;
    end;
    Break;
  end;
  AddItem;

  { Aufgabenlisten: [ ] und [x] am Anfang eines Punkts. }
  SetLength(Task, Length(Items));
  AnyTask := False;
  for k := 0 to High(Items) do
  begin
    Task[k] := #0;
    if Length(Items[k]) = 0 then Continue;
    S := Items[k][0];
    if (Length(S) >= 3) and (S[1] = '[') and (S[3] = ']') and
       (S[2] in [' ', 'x', 'X']) and ((Length(S) = 3) or (S[4] = ' ')) then
    begin
      if S[2] = ' ' then Task[k] := TASK_OPEN else Task[k] := TASK_DONE;
      Items[k][0] := Task[k] + Copy(S, 5, MaxInt);
      AnyTask := True;
    end;
  end;

  if First.Ordered then
  begin
    if First.Start <> 1 then
      Open := '<ol start="' + IntToStr(First.Start) + '">'
    else
      Open := '<ol>';
    Close := '</ol>';
  end
  else
  begin
    if AnyTask then Open := '<ul class="contains-task-list">' else Open := '<ul>';
    Close := '</ul>';
  end;
  BufAdd(B, Open + #10);
  for k := 0 to High(Items) do
  begin
    Item := Items[k];
    Body := Blocks(Item, not Loose, ADepth + 1);
    while (Body <> '') and (Body[Length(Body)] = #10) do
      Delete(Body, Length(Body), 1);
    if Task[k] <> #0 then
      LiOpen := '<li class="task-list-item">'
    else
      LiOpen := '<li>';
    BufAdd(B, LiOpen + Body + '</li>'#10);
  end;
  BufAdd(B, Close + #10);
  Result := I;
end;

function TMdConverter.DoHtml(const A: TLines; I, AKind: Integer;
  var B: TBuf): Integer;
var
  n: Integer;
  S: string;
begin
  n := Length(A);
  S := '';
  if AKind <= 5 then
  begin
    while I < n do
    begin
      S := S + A[I] + #10;
      Inc(I);
      if HtmlEnd(AKind, A[I - 1]) then Break;
    end;
  end
  else
    while (I < n) and not IsBlankLine(A[I]) do
    begin
      S := S + A[I] + #10;
      Inc(I);
    end;
  if FOpt.AllowHtml then
    BufAdd(B, SanitizeCore(S, Self))
  else
    BufAdd(B, '<p>' + AmsHtmlEscape(TrimRightSpaces(S)) + '</p>'#10);
  Result := I;
end;

function TMdConverter.DoTable(const A: TLines; I: Integer;
  var B: TBuf): Integer;
var
  Head, Delim, Row: TLines;
  Align: array of string;
  n, Cols, k: Integer;
  D, Cell: string;
  Body: Boolean;
begin
  n := Length(A);
  Head := SplitRow(A[I]);
  Delim := SplitRow(A[I + 1]);
  Cols := Length(Head);
  SetLength(Align, Cols);
  for k := 0 to Cols - 1 do
  begin
    D := Trim(Delim[k]);
    if (D[1] = ':') and (D[Length(D)] = ':') and (Length(D) > 1) then
      Align[k] := ' style="text-align:center"'
    else if D[Length(D)] = ':' then
      Align[k] := ' style="text-align:right"'
    else if D[1] = ':' then
      Align[k] := ' style="text-align:left"'
    else
      Align[k] := '';
  end;

  BufAdd(B, '<table>'#10'<thead>'#10'<tr>'#10);
  for k := 0 to Cols - 1 do
  begin
    Cell := StringReplace(Trim(Head[k]), '\|', '|', [rfReplaceAll]);
    BufAdd(B, '<th' + Align[k] + '>' + Inlines(Cell, False, 0) + '</th>'#10);
  end;
  BufAdd(B, '</tr>'#10'</thead>'#10);
  Inc(I, 2);
  Body := False;
  while (I < n) and not IsBlankLine(A[I]) do
  begin
    if StartsBlock(A[I]) and not HasUnescapedPipe(A[I]) then Break;
    Row := SplitRow(A[I]);
    if not Body then BufAdd(B, '<tbody>'#10);
    Body := True;
    BufAdd(B, '<tr>'#10);
    for k := 0 to Cols - 1 do
    begin
      if k <= High(Row) then
        Cell := StringReplace(Trim(Row[k]), '\|', '|', [rfReplaceAll])
      else
        Cell := '';
      BufAdd(B, '<td' + Align[k] + '>' + Inlines(Cell, False, 0) +
                '</td>'#10);
    end;
    BufAdd(B, '</tr>'#10);
    Inc(I);
  end;
  if Body then BufAdd(B, '</tbody>'#10);
  BufAdd(B, '</table>'#10);
  Result := I;
end;

{ ------------------------------------------------------------- Inline --- }

{ Schliessende Backtick-Folge genau der Laenge ARun ab P, 0 = keine. }
function FindBacktickClose(const S: string; P, ARun: Integer): Integer;
var
  j, r: Integer;
begin
  j := P;
  while j <= Length(S) do
    if S[j] = '`' then
    begin
      r := RunLen(S, j, '`');
      if r = ARun then Exit(j);
      Inc(j, r);
    end
    else
      Inc(j);
  Result := 0;
end;

function NormCode(const S: string): string;
var
  i: Integer;
  AllSp: Boolean;
begin
  Result := StringReplace(S, #10, ' ', [rfReplaceAll]);
  if (Length(Result) >= 2) and (Result[1] = ' ') and
     (Result[Length(Result)] = ' ') then
  begin
    AllSp := True;
    for i := 1 to Length(Result) do
      if Result[i] <> ' ' then
      begin
        AllSp := False;
        Break;
      end;
    if not AllSp then Result := Copy(Result, 2, Length(Result) - 2);
  end;
end;

{ Passende "]" zur "[" bei AStart; Escapes und Codespans werden
  uebersprungen. 0 = keine. }
function FindCloseBracket(const S: string; AStart: Integer): Integer;
var
  j, Depth, r, e: Integer;
begin
  Result := 0;
  Depth := 0;
  j := AStart;
  while (j <= Length(S)) and (j - AStart <= MAX_LINK_TEXT) do
  begin
    case S[j] of
      '\':
        begin
          Inc(j, 2);
          Continue;
        end;
      '`':
        begin
          r := RunLen(S, j, '`');
          e := FindBacktickClose(S, j + r, r);
          if e > 0 then j := e + r else j := j + r;
          Continue;
        end;
      '[': Inc(Depth);
      ']':
        begin
          Dec(Depth);
          if Depth = 0 then Exit(j);
        end;
    end;
    Inc(j);
  end;
end;

{ "(ziel "titel")" ab P (S[P] = '('). }
function ParseInlineDest(const S: string; P: Integer;
  out ADest, ATitle: string; out AEnd: Integer): Boolean;
var
  n, j, k, Depth: Integer;
  Close: Char;
  HadWs: Boolean;
begin
  Result := False;
  ADest := '';
  ATitle := '';
  AEnd := 0;
  n := Length(S);
  j := P + 1;
  while (j <= n) and IsWs(S[j]) do Inc(j);
  if j > n then Exit;
  if S[j] = '<' then
  begin
    k := j + 1;
    while (k <= n) and not (S[k] in ['>', '<', #10]) do
    begin
      if (S[k] = '\') and (k < n) then Inc(k);
      Inc(k);
    end;
    if (k > n) or (S[k] <> '>') then Exit;
    ADest := Copy(S, j + 1, k - j - 1);
    j := k + 1;
  end
  else
  begin
    k := j;
    Depth := 0;
    while k <= n do
    begin
      if (S[k] = '\') and (k < n) and IsPunct(S[k + 1]) then
      begin
        Inc(k, 2);
        Continue;
      end;
      if IsWs(S[k]) or (S[k] < ' ') then Break;
      if S[k] = '(' then
      begin
        Inc(Depth);
        if Depth > 32 then Exit;
      end
      else if S[k] = ')' then
      begin
        if Depth = 0 then Break;
        Dec(Depth);
      end;
      Inc(k);
    end;
    ADest := Copy(S, j, k - j);
    j := k;
  end;
  HadWs := False;
  while (j <= n) and IsWs(S[j]) do
  begin
    Inc(j);
    HadWs := True;
  end;
  if (j <= n) and (S[j] in ['"', '''', '(']) and (HadWs or (ADest = '')) then
  begin
    if S[j] = '(' then Close := ')' else Close := S[j];
    k := j + 1;
    while (k <= n) and (S[k] <> Close) do
    begin
      if (S[k] = '\') and (k < n) then Inc(k);
      Inc(k);
    end;
    if k > n then Exit;
    ATitle := Copy(S, j + 1, k - j - 1);
    j := k + 1;
    while (j <= n) and IsWs(S[j]) do Inc(j);
  end;
  if (j > n) or (S[j] <> ')') then Exit;
  AEnd := j + 1;
  ADest := Unescape(ADest);
  ATitle := Unescape(ATitle);
  Result := True;
end;

function TMdConverter.TryLink(const S: string; AStart: Integer;
  AImage: Boolean; ADepth: Integer; out AEnd: Integer;
  out AHtml: string): Boolean;
var
  n, Close, p, q: Integer;
  Inner, Dest, Title, Lbl, Src, Alt, Href, TitleAttr, InnerHtml: string;
  Ok: Boolean;
begin
  Result := False;
  AEnd := 0;
  AHtml := '';
  n := Length(S);
  Close := FindCloseBracket(S, AStart);
  if Close = 0 then Exit;
  Inner := Copy(S, AStart + 1, Close - AStart - 1);
  p := Close + 1;
  Ok := False;
  if (p <= n) and (S[p] = '(') then
    Ok := ParseInlineDest(S, p, Dest, Title, AEnd);
  if not Ok and (p <= n) and (S[p] = '[') then
  begin
    q := p + 1;
    while (q <= n) and (S[q] <> ']') and (S[q] <> '[') and (q - p < 1000) do
      Inc(q);
    if (q <= n) and (S[q] = ']') then
    begin
      Lbl := Copy(S, p + 1, q - p - 1);
      if Trim(Lbl) = '' then Lbl := Inner;
      if LookupRef(Lbl, Dest, Title) then
      begin
        Ok := True;
        AEnd := q + 1;
      end;
    end;
  end;
  if not Ok and LookupRef(Inner, Dest, Title) then
  begin
    Ok := True;
    AEnd := Close + 1;
  end;
  if not Ok then Exit;

  if Title <> '' then
    TitleAttr := ' title="' + AmsHtmlEscape(Title) + '"'
  else
    TitleAttr := '';
  if AImage then
  begin
    Alt := StripTags(Inlines(Inner, True, ADepth + 1));
    if IsUnsafeUrl(Dest, True) then
      AHtml := Alt
    else
    begin
      Src := ResolveImage(Dest);
      AHtml := '<img src="' + UrlAttr(Src) + '" alt="' + Alt + '"' +
               TitleAttr + '>';
    end;
  end
  else
  begin
    InnerHtml := Inlines(Inner, True, ADepth + 1);
    if IsUnsafeUrl(Dest, False) then
      AHtml := InnerHtml
    else
    begin
      Href := ResolveLink(Dest);
      AHtml := '<a href="' + UrlAttr(Href) + '"' + TitleAttr +
               TargetAttr(Href) + '>' + InnerHtml + '</a>';
    end;
  end;
  Result := True;
end;

function IsEmail(const S: string): Boolean;
var
  At, i: Integer;
begin
  Result := False;
  At := Pos('@', S);
  if (At < 2) or (At = Length(S)) or (CountChar(S, '@') <> 1) then Exit;
  for i := 1 to At - 1 do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '!', '#', '$', '%',
                     '&', '''', '*', '+', '/', '=', '?', '^', '_', '`', '{',
                     '|', '}', '~', '-']) then Exit;
  for i := At + 1 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '-']) then Exit;
  Result := Pos('.', Copy(S, At + 1, MaxInt)) > 1;
end;

{ <https://...> bzw. <name@host.de>. Liefert die Position hinter ">"
  oder 0. }
function TMdConverter.TryAutolink(const S: string; AStart: Integer;
  ANoLinks: Boolean; out AHtml: string): Integer;
var
  j: Integer;
  C, Href: string;
begin
  Result := 0;
  AHtml := '';
  j := AStart + 1;
  while (j <= Length(S)) and (S[j] > ' ') and not (S[j] in ['<', '>']) do
    Inc(j);
  if (j > Length(S)) or (S[j] <> '>') then Exit;
  C := Copy(S, AStart + 1, j - AStart - 1);
  if SchemeLen(C) >= 3 then
  begin
    if IsUnsafeUrl(C, False) then Exit;
    Href := C;
  end
  else if IsEmail(C) then
    Href := 'mailto:' + C
  else
    Exit;
  if ANoLinks then
    AHtml := AmsHtmlEscape(C)
  else
    AHtml := '<a href="' + UrlAttr(Href) + '"' + TargetAttr(Href) + '>' +
             AmsHtmlEscape(C) + '</a>';
  Result := j + 1;
end;

{ Nackte Adresse wie bei GitHub (http://, https://, www.). Satzzeichen am
  Ende gehoeren nicht dazu, eine ")" nur, wenn sie eine "(" schliesst. }
function TMdConverter.TryBareUrl(const S: string; AStart: Integer;
  out AHtml: string): Integer;
var
  Prev: Char;
  Plen, e, L, k, d: Integer;
  Url, Low, Domain, Href: string;
  Changed: Boolean;
begin
  Result := 0;
  AHtml := '';
  if AStart > 1 then Prev := S[AStart - 1] else Prev := ' ';
  if not (IsWs(Prev) or (Prev in ['(', '*', '_', '~', '"', ''''])) then Exit;
  Low := LowerCase(Copy(S, AStart, 8));
  if Copy(Low, 1, 8) = 'https://' then Plen := 8
  else if Copy(Low, 1, 7) = 'http://' then Plen := 7
  else if Copy(Low, 1, 4) = 'www.' then Plen := 4
  else Exit;
  e := AStart;
  while (e <= Length(S)) and (S[e] > ' ') and (S[e] <> '<') do Inc(e);
  Url := Copy(S, AStart, e - AStart);
  repeat
    Changed := False;
    L := Length(Url);
    if L = 0 then Break;
    if Url[L] in ['?', '!', '.', ',', ':', '*', '_', '~', '''', '"'] then
    begin
      Delete(Url, L, 1);
      Changed := True;
    end
    else if (Url[L] = ')') and (CountChar(Url, ')') > CountChar(Url, '(')) then
    begin
      Delete(Url, L, 1);
      Changed := True;
    end
    else if Url[L] = ';' then
    begin
      k := L;
      while (k > 0) and (Url[k] <> '&') do Dec(k);
      if (k > 0) and (EntityLen(Url, k) = L - k + 1) then
      begin
        Url := Copy(Url, 1, k - 1);
        Changed := True;
      end;
    end;
  until not Changed;
  if Length(Url) <= Plen then Exit;
  Domain := Copy(Url, Plen + 1, MaxInt);
  d := 1;
  while (d <= Length(Domain)) and not (Domain[d] in ['/', '?', '#', ':']) do
    Inc(d);
  Domain := Copy(Domain, 1, d - 1);
  if Domain = '' then Exit;
  if (Plen <> 4) and (Pos('.', Domain) = 0) then Exit;
  if Plen = 4 then Href := 'http://' + Url else Href := Url;
  AHtml := '<a href="' + UrlAttr(Href) + '"' + TargetAttr(Href) + '>' +
           AmsHtmlEscape(Url) + '</a>';
  Result := AStart + Length(Url);
end;

{ Laenge von Roh-HTML ab P: Kommentar, <?..>, <!..> oder ein Tag. }
function HtmlInlineLen(const S: string; P: Integer; out T: TTagInfo): Integer;
var
  k: Integer;
begin
  T.Name := '';
  T.Closing := False;
  T.SelfClosing := False;
  SetLength(T.Attrs, 0);
  if Copy(S, P, 4) = '<!--' then
  begin
    k := Pos('-->', Copy(S, P + 4, MaxInt));
    if k = 0 then Exit(0);
    Exit(4 + k - 1 + 3);
  end;
  if (P < Length(S)) and (S[P + 1] in ['!', '?']) then
  begin
    k := P;
    while (k <= Length(S)) and (S[k] <> '>') do Inc(k);
    if k > Length(S) then Exit(0);
    Exit(k - P + 1);
  end;
  Result := ParseTag(S, P, T);
end;

function TMdConverter.Inlines(const S: string; ANoLinks: Boolean;
  ADepth: Integer): string;
var
  Nodes: TNodes;
  Cnt: Integer;
  Buf, R: TBuf;
  i, n, Run, e, k, o, c, Use: Integer;
  Ch, Prev, Next: Char;
  LeftF, RightF: Boolean;
  Tmp, Tag: string;
  T: TTagInfo;

  procedure Grow;
  begin
    if Cnt >= Length(Nodes) then SetLength(Nodes, Cnt * 2 + 8);
  end;

  procedure Flush;
  begin
    if Buf.Len = 0 then Exit;
    Grow;
    Nodes[Cnt].Kind := nkText;
    Nodes[Cnt].Text := BufText(Buf);
    Inc(Cnt);
    Buf.Len := 0;
  end;

  procedure PushDelim(ACh: Char; ACount: Integer; AOpen, AClose: Boolean);
  begin
    Flush;
    Grow;
    Nodes[Cnt].Kind := nkDelim;
    Nodes[Cnt].Text := '';
    Nodes[Cnt].Ch := ACh;
    Nodes[Cnt].Count := ACount;
    Nodes[Cnt].Orig := ACount;
    Nodes[Cnt].CanOpen := AOpen;
    Nodes[Cnt].CanClose := AClose;
    Nodes[Cnt].Active := True;
    Nodes[Cnt].OpenTags := '';
    Nodes[Cnt].CloseTags := '';
    Inc(Cnt);
  end;

begin
  if ADepth > MAX_DEPTH then Exit(AmsHtmlEscape(S));
  n := Length(S);
  SetLength(Nodes, 0);
  Cnt := 0;
  BufInit(Buf);
  i := 1;
  while i <= n do
  begin
    Ch := S[i];
    case Ch of
      '\':
        if (i < n) and (S[i + 1] = #10) then
        begin
          BufAdd(Buf, '<br>'#10);
          Inc(i, 2);
        end
        else if (i < n) and IsPunct(S[i + 1]) then
        begin
          BufAdd(Buf, EscChar(S[i + 1]));
          Inc(i, 2);
        end
        else
        begin
          BufAddC(Buf, '\');
          Inc(i);
        end;
      '`':
        begin
          Run := RunLen(S, i, '`');
          e := FindBacktickClose(S, i + Run, Run);
          if e > 0 then
          begin
            BufAdd(Buf, '<code>' +
                        AmsHtmlEscape(NormCode(Copy(S, i + Run, e - i - Run))) +
                        '</code>');
            i := e + Run;
          end
          else
          begin
            BufAdd(Buf, StringOfChar('`', Run));
            Inc(i, Run);
          end;
        end;
      '*', '_', '~':
        begin
          Run := RunLen(S, i, Ch);
          if i > 1 then Prev := S[i - 1] else Prev := ' ';
          if i + Run <= n then Next := S[i + Run] else Next := ' ';
          LeftF := not IsWs(Next) and
                   (not IsPunct(Next) or IsWs(Prev) or IsPunct(Prev));
          RightF := not IsWs(Prev) and
                    (not IsPunct(Prev) or IsWs(Next) or IsPunct(Next));
          if Ch = '_' then
            { snake_case bleibt: "_" oeffnet/schliesst nicht mitten im Wort. }
            PushDelim(Ch, Run, LeftF and (not RightF or IsPunct(Prev)),
                      RightF and (not LeftF or IsPunct(Next)))
          else if Ch = '~' then
          begin
            if Run = 2 then
              PushDelim(Ch, Run, LeftF, RightF)
            else
              BufAdd(Buf, StringOfChar('~', Run));
          end
          else
            PushDelim(Ch, Run, LeftF, RightF);
          Inc(i, Run);
        end;
      '!':
        if (i < n) and (S[i + 1] = '[') and
           TryLink(S, i + 1, True, ADepth, e, Tmp) then
        begin
          BufAdd(Buf, Tmp);
          i := e;
        end
        else
        begin
          BufAddC(Buf, '!');
          Inc(i);
        end;
      '[':
        if not ANoLinks and TryLink(S, i, False, ADepth, e, Tmp) then
        begin
          BufAdd(Buf, Tmp);
          i := e;
        end
        else
        begin
          BufAddC(Buf, '[');
          Inc(i);
        end;
      '<':
        begin
          e := TryAutolink(S, i, ANoLinks, Tmp);
          if e > 0 then
          begin
            BufAdd(Buf, Tmp);
            i := e;
          end
          else
          begin
            k := HtmlInlineLen(S, i, T);
            if (k > 0) and FOpt.AllowHtml then
            begin
              if (T.Name <> '') and not T.Closing and not T.SelfClosing and
                 InList(T.Name, DROP_WITH_CONTENT) then
                i := SkipElement(S, T.Name, i + k)
              else
              begin
                BufAdd(Buf, SanitizeCore(Copy(S, i, k), Self));
                i := i + k;
              end;
            end
            else
            begin
              BufAdd(Buf, '&lt;');
              Inc(i);
            end;
          end;
        end;
      '&':
        begin
          k := EntityLen(S, i);
          if k > 0 then
          begin
            BufAdd(Buf, Copy(S, i, k));
            Inc(i, k);
          end
          else
          begin
            BufAdd(Buf, '&amp;');
            Inc(i);
          end;
        end;
      '>':
        begin
          BufAdd(Buf, '&gt;');
          Inc(i);
        end;
      '"':
        begin
          BufAdd(Buf, '&quot;');
          Inc(i);
        end;
      #10:
        begin
          { Harter Umbruch: zwei Leerzeichen vor dem Zeilenende. }
          k := 0;
          while (Buf.Len > 0) and (Buf.S[Buf.Len] = ' ') do
          begin
            Dec(Buf.Len);
            Inc(k);
          end;
          if k >= 2 then BufAdd(Buf, '<br>'#10) else BufAddC(Buf, #10);
          Inc(i);
          while (i <= n) and (S[i] = ' ') do Inc(i);
        end;
      TASK_OPEN:
        begin
          BufAdd(Buf, '<input type="checkbox" disabled> ');
          Inc(i);
        end;
      TASK_DONE:
        begin
          BufAdd(Buf, '<input type="checkbox" disabled checked> ');
          Inc(i);
        end;
    else
      if not ANoLinks and (Ch in ['h', 'H', 'w', 'W']) then
      begin
        e := TryBareUrl(S, i, Tmp);
        if e > 0 then
        begin
          BufAdd(Buf, Tmp);
          i := e;
          Continue;
        end;
      end;
      BufAddC(Buf, Ch);
      Inc(i);
    end;
  end;
  Flush;

  { Begrenzer paaren: fuer jeden moeglichen Schliesser den naechsten
    passenden Oeffner links davon suchen (CommonMark, ohne
    openers_bottom - die Eingaben sind klein). }
  for c := 0 to Cnt - 1 do
  begin
    if (Nodes[c].Kind <> nkDelim) or not Nodes[c].CanClose then Continue;
    while Nodes[c].Count > 0 do
    begin
      o := c - 1;
      while o >= 0 do
      begin
        if (Nodes[o].Kind = nkDelim) and Nodes[o].Active and
           Nodes[o].CanOpen and (Nodes[o].Ch = Nodes[c].Ch) and
           (Nodes[o].Count > 0) then
        begin
          { Dreierregel: "*a**b*" soll nicht "a" fett machen. }
          if (Nodes[o].Ch <> '~') and
             (Nodes[o].CanClose or Nodes[c].CanOpen) and
             ((Nodes[o].Orig + Nodes[c].Orig) mod 3 = 0) and
             not ((Nodes[o].Orig mod 3 = 0) and (Nodes[c].Orig mod 3 = 0)) then
          begin
            Dec(o);
            Continue;
          end;
          Break;
        end;
        Dec(o);
      end;
      if o < 0 then Break;
      if Nodes[c].Ch = '~' then
      begin
        Use := 2;
        Tag := 'del';
      end
      else if (Nodes[o].Count >= 2) and (Nodes[c].Count >= 2) then
      begin
        Use := 2;
        Tag := 'strong';
      end
      else
      begin
        Use := 1;
        Tag := 'em';
      end;
      Nodes[o].OpenTags := '<' + Tag + '>' + Nodes[o].OpenTags;
      Nodes[c].CloseTags := Nodes[c].CloseTags + '</' + Tag + '>';
      Dec(Nodes[o].Count, Use);
      Dec(Nodes[c].Count, Use);
      for k := o + 1 to c - 1 do
        if Nodes[k].Kind = nkDelim then Nodes[k].Active := False;
    end;
  end;

  BufInit(R);
  for k := 0 to Cnt - 1 do
    if Nodes[k].Kind = nkText then
      BufAdd(R, Nodes[k].Text)
    else
    begin
      BufAdd(R, Nodes[k].CloseTags);
      BufAdd(R, StringOfChar(Nodes[k].Ch, Nodes[k].Count));
      BufAdd(R, Nodes[k].OpenTags);
    end;
  Result := BufText(R);
end;

{ --------------------------------------------------------- Oeffentlich - }

function AmsMarkdownDefaults: TAmsMarkdownOptions;
begin
  Result.ImageBase := '';
  Result.LinkBase := '';
  Result.ExternalLinksNewWindow := True;
  Result.AllowHtml := True;
  Result.OnImage := nil;
end;

function AmsMarkdownToHtml(const AMarkdown: string;
  const AOptions: TAmsMarkdownOptions): string;
var
  C: TMdConverter;
begin
  try
    C := TMdConverter.Create(AOptions);
    try
      Result := C.Convert(AMarkdown);
    finally
      C.Free;
    end;
  except
    { Letzte Rueckfallebene: lieber unformatiert als gar nicht. }
    Result := '<pre>' + AmsHtmlEscape(AMarkdown) + '</pre>'#10;
  end;
end;

const
  PAGE_CSS =
    'body{margin:0;padding:0;background:#ffffff;color:#1f2328;' +
      'font-family:"Segoe UI",Tahoma,Arial,sans-serif;font-size:14px;' +
      'line-height:1.5;}'#13#10 +
    '.markdown-body{padding:16px 24px;word-wrap:break-word;}'#13#10 +
    '.markdown-body>*:first-child{margin-top:0 !important;}'#13#10 +
    'h1,h2,h3,h4,h5,h6{margin-top:24px;margin-bottom:16px;font-weight:600;' +
      'line-height:1.25;}'#13#10 +
    'h1{font-size:2em;padding-bottom:.3em;border-bottom:1px solid #d1d9e0;}'#13#10 +
    'h2{font-size:1.5em;padding-bottom:.3em;border-bottom:1px solid #d1d9e0;}'#13#10 +
    'h3{font-size:1.25em;}h4{font-size:1em;}h5{font-size:.875em;}' +
      'h6{font-size:.85em;color:#59636e;}'#13#10 +
    'p,blockquote,ul,ol,dl,table,pre,details,.markdown-alert{margin-top:0;' +
      'margin-bottom:16px;}'#13#10 +
    'a{color:#0969da;text-decoration:none;}a:hover{text-decoration:underline;}'#13#10 +
    'strong{font-weight:600;}'#13#10 +
    'code,kbd,pre{font-family:Consolas,"Courier New",monospace;}'#13#10 +
    'code{font-size:85%;padding:.2em .4em;margin:0;background:#eff1f3;' +
      'border-radius:6px;}'#13#10 +
    'pre{font-size:85%;line-height:1.45;padding:16px;overflow:auto;' +
      'background:#f6f8fa;border-radius:6px;word-wrap:normal;}'#13#10 +
    'pre code{padding:0;margin:0;font-size:100%;background:transparent;' +
      'border:0;border-radius:0;white-space:pre;word-wrap:normal;}'#13#10 +
    'kbd{display:inline-block;padding:3px 5px;font-size:11px;line-height:10px;' +
      'color:#1f2328;background:#f6f8fa;border:1px solid #d1d9e0;' +
      'border-radius:6px;}'#13#10 +
    'blockquote{margin-left:0;margin-right:0;padding:0 1em;color:#59636e;' +
      'border-left:.25em solid #d1d9e0;}'#13#10 +
    'blockquote>:first-child{margin-top:0;}blockquote>:last-child{margin-bottom:0;}'#13#10 +
    'hr{height:.25em;padding:0;margin:24px 0;background-color:#d1d9e0;' +
      'border:0;}'#13#10 +
    'table{border-collapse:collapse;border-spacing:0;}'#13#10 +
    'th,td{padding:6px 13px;border:1px solid #d1d9e0;}'#13#10 +
    'th{font-weight:600;}'#13#10 +
    'tr{background:#ffffff;border-top:1px solid #d1d9e0;}'#13#10 +
    'tr:nth-child(2n){background:#f6f8fa;}'#13#10 +
    'img{max-width:100%;border-style:none;}'#13#10 +
    'ul,ol{padding-left:2em;}'#13#10 +
    'ul ul,ul ol,ol ol,ol ul{margin-top:0;margin-bottom:0;}'#13#10 +
    'li+li{margin-top:.25em;}'#13#10 +
    '.task-list-item{list-style-type:none;}'#13#10 +
    '.task-list-item input{margin:0 .2em .25em -1.4em;vertical-align:middle;}'#13#10 +
    'details summary{cursor:pointer;}'#13#10 +
    '.markdown-alert{padding:8px 16px;border-left:.25em solid #d1d9e0;}'#13#10 +
    '.markdown-alert>:last-child{margin-bottom:0;}'#13#10 +
    '.markdown-alert-title{font-weight:600;margin-bottom:4px;}'#13#10 +
    '.markdown-alert-note{border-left-color:#0969da;}' +
      '.markdown-alert-note .markdown-alert-title{color:#0969da;}'#13#10 +
    '.markdown-alert-tip{border-left-color:#1a7f37;}' +
      '.markdown-alert-tip .markdown-alert-title{color:#1a7f37;}'#13#10 +
    '.markdown-alert-important{border-left-color:#8250df;}' +
      '.markdown-alert-important .markdown-alert-title{color:#8250df;}'#13#10 +
    '.markdown-alert-warning{border-left-color:#9a6700;}' +
      '.markdown-alert-warning .markdown-alert-title{color:#9a6700;}'#13#10 +
    '.markdown-alert-caution{border-left-color:#d1242f;}' +
      '.markdown-alert-caution .markdown-alert-title{color:#d1242f;}'#13#10;

function AmsHtmlPage(const ATitle, ABodyHtml: string;
  const AExtraCss: string): string;
begin
  { Mark of the Web direkt hinter dem Doctype: ohne sie fragt der IE bei
    einer lokalen Datei nach (Local Machine Zone Lockdown). Die 0014 ist
    die Laenge von "about:internet". X-UA-Compatible muss vor allem
    anderen im head stehen, sonst rendert das Control im IE7-Modus. }
  Result :=
    '<!DOCTYPE html>'#13#10 +
    '<!-- saved from url=(0014)about:internet -->'#13#10 +
    '<html>'#13#10 +
    '<head>'#13#10 +
    '<meta http-equiv="X-UA-Compatible" content="IE=edge">'#13#10 +
    '<meta charset="utf-8">'#13#10 +
    '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">'#13#10 +
    '<title>' + AmsHtmlEscape(ATitle) + '</title>'#13#10 +
    '<style>'#13#10 + PAGE_CSS + AExtraCss + #13#10'</style>'#13#10 +
    '</head>'#13#10 +
    '<body>'#13#10 +
    '<div class="markdown-body">'#13#10 +
    ABodyHtml + #13#10 +
    '</div>'#13#10 +
    '</body>'#13#10 +
    '</html>'#13#10;
end;

end.
