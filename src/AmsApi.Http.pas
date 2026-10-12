unit AmsApi.Http;

{ ============================================================================
  AmsApi.Http - HTTP/HTTPS auf WinHTTP, plus Browser oeffnen

  winhttp.dll gehoert zu Windows: keine zusaetzliche DLL, kein OpenSSL, TLS
  inklusive. Diese Unit hat keinerlei Beruehrung mit der Delphi-Seite des
  Hosts - also weder Heap- noch ABI-Themen - und ist ohne AMS testbar.

  Fallstrick: HTTPS NICHT am Port erkennen, sondern an Comp.nScheme. Sonst
  bricht https://host:8443.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes, AmsApi.Types;

const
  { In einer INI laesst sich kein CRLF unterbringen - dieses Zeichen trennt
    mehrere Header voneinander. }
  AMS_HEADER_SEPARATOR = '|';

{ Synchrone Anfrage. Blockiert - im UI-Thread von AMS nur fuer schnelle
  Endpunkte benutzen, sonst AmsHttpRequestAsync.
  AMethod z.B. GET oder POST, ABody wird als UTF-8 gesendet.
  Ergebnis False = Transportfehler, AResponse enthaelt dann die Ursache. }
function AmsHttpRequest(const AMethod, AUrl, AHeaders, ABody: string;
  out AStatus: Integer; out AResponse: string): Boolean;

{ Anfrage im Hintergrundthread. Das Ergebnis landet im Log; ist ein Callback
  angegeben, wird er IM HINTERGRUNDTHREAD gerufen - dort nichts anfassen, was
  dem VCL-Hauptthread gehoert. }
function AmsHttpRequestAsync(const AMethod, AUrl, AHeaders, ABody: string;
  AOnDone: TAmsHttpDoneEvent = nil; ATag: Integer = 0): Boolean;

{ Binaersicher holen - fuer Dateien, Bilder, UTF-8-Text. AData enthaelt die
  Bytes unveraendert (siehe AmsApi.Files), nichts wird umkodiert.

  Weiterleitungen folgt die Funktion SELBST (hoechstens 10) und laesst dabei
  "Authorization" weg, sobald der Host wechselt: GitHub leitet Release-
  Downloads auf einen CDN-Host um, und ein Token hat dort nichts verloren.

  Proxy: die Einstellung des Systems (wie im Browser, auch PAC), nicht nur
  die von netsh winhttp - in Firmennetzen ist das der Unterschied zwischen
  "geht" und "Zeitueberschreitung".

  False = Transportfehler, Ursache in AmsLastError. Ein Status wie 404 ist
  KEIN Transportfehler - AStatus pruefen. AMaxBytes > 0 bricht groessere
  Antworten ab. Blockiert: gehoert in einen Hintergrundthread. }
function AmsHttpGet(const AUrl, AHeaders: string; out AStatus: Integer;
  out AData: string; AMaxBytes: Int64 = 0): Boolean;

{ Wie AmsHttpGet, schreibt aber direkt in eine Datei (ueber .part, erst bei
  Status 200 umbenannt). Bei anderem Status bleibt keine Datei zurueck. }
function AmsHttpDownload(const AUrl, AHeaders, ADestFile: string;
  out AStatus: Integer; AMaxBytes: Int64 = 0): Boolean;

{ Kopfzeilen (mit | getrennt) ohne den genannten Header. }
function AmsHeaderRemove(const AHeaders, AName: string): string;

{ URL im Standardbrowser oeffnen. }
function AmsOpenUrl(const AUrl: string): Boolean;

{ User-Agent der Bibliothek. Darf vom Plugin gesetzt werden. }
var
  AmsHttpUserAgent: string = 'AmsApi/1.0';
  AmsHttpTimeoutMs: Integer = 20000;

implementation

uses
  AmsApi.Log;

const
  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0;
  WINHTTP_FLAG_SECURE               = $00800000;
  WINHTTP_QUERY_STATUS_CODE         = 19;
  WINHTTP_QUERY_FLAG_NUMBER         = $20000000;
  INTERNET_SCHEME_HTTPS             = 2;

type
  TUrlComponents = record
    dwStructSize: DWORD;
    lpszScheme: PWideChar;      dwSchemeLength: DWORD;
    nScheme: DWORD;
    lpszHostName: PWideChar;    dwHostNameLength: DWORD;
    nPort: Word;
    lpszUserName: PWideChar;    dwUserNameLength: DWORD;
    lpszPassword: PWideChar;    dwPasswordLength: DWORD;
    lpszUrlPath: PWideChar;     dwUrlPathLength: DWORD;
    lpszExtraInfo: PWideChar;   dwExtraInfoLength: DWORD;
  end;

function WinHttpOpen(pszAgentW: PWideChar; dwAccessType: DWORD;
  pszProxyW, pszProxyBypassW: PWideChar; dwFlags: DWORD): Pointer; stdcall;
  external 'winhttp.dll' name 'WinHttpOpen';
function WinHttpConnect(hSession: Pointer; pswzServerName: PWideChar;
  nServerPort: Word; dwReserved: DWORD): Pointer; stdcall;
  external 'winhttp.dll' name 'WinHttpConnect';
function WinHttpOpenRequest(hConnect: Pointer; pwszVerb, pwszObjectName,
  pwszVersion, pwszReferrer: PWideChar; ppwszAcceptTypes: Pointer;
  dwFlags: DWORD): Pointer; stdcall;
  external 'winhttp.dll' name 'WinHttpOpenRequest';
function WinHttpSendRequest(hRequest: Pointer; pwszHeaders: PWideChar;
  dwHeadersLength: DWORD; lpOptional: Pointer;
  dwOptionalLength, dwTotalLength, dwContext: DWORD): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpSendRequest';
function WinHttpReceiveResponse(hRequest, lpReserved: Pointer): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpReceiveResponse';
function WinHttpQueryHeaders(hRequest: Pointer; dwInfoLevel: DWORD;
  pwszName: PWideChar; lpBuffer: Pointer; var lpdwBufferLength: DWORD;
  lpdwIndex: Pointer): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpQueryHeaders';
function WinHttpReadData(hRequest: Pointer; lpBuffer: Pointer;
  dwNumberOfBytesToRead: DWORD; var lpdwNumberOfBytesRead: DWORD): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpReadData';
function WinHttpCloseHandle(hInternet: Pointer): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpCloseHandle';
function WinHttpCrackUrl(pwszUrl: PWideChar; dwUrlLength, dwFlags: DWORD;
  var lpUrlComponents: TUrlComponents): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpCrackUrl';
function WinHttpSetTimeouts(hInternet: Pointer;
  nResolveTimeout, nConnectTimeout, nSendTimeout, nReceiveTimeout: Integer): BOOL;
  stdcall; external 'winhttp.dll' name 'WinHttpSetTimeouts';
function WinHttpSetOption(hInternet: Pointer; dwOption: DWORD;
  lpBuffer: Pointer; dwBufferLength: DWORD): BOOL; stdcall;
  external 'winhttp.dll' name 'WinHttpSetOption';

const
  WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4;   { ab Windows 8.1 }
  WINHTTP_OPTION_DISABLE_FEATURE      = 63;
  WINHTTP_DISABLE_REDIRECTS           = 2;
  WINHTTP_QUERY_LOCATION              = 33;
  MAX_REDIRECTS                       = 10;

function AmsHttpRequest(const AMethod, AUrl, AHeaders, ABody: string;
  out AStatus: Integer; out AResponse: string): Boolean;
var
  UrlW, HostW, PathW, VerbW, HdrW, AgentW: UnicodeString;
  Comp: TUrlComponents;
  Sess, Conn, Req: Pointer;
  Secure: Boolean;
  Flags, Read, Len, Code: DWORD;
  BodyU, Raw: UTF8String;
  Buf: array[0..4095] of Byte;
  HdrPtr: PWideChar;

  procedure Fail(const AWhere: string);
  begin
    AResponse := AWhere + ' fehlgeschlagen, Windows-Fehler ' +
                 IntToStr(GetLastError);
  end;

begin
  Result := False;
  AStatus := 0;
  AResponse := '';
  Sess := nil; Conn := nil; Req := nil;

  UrlW := UnicodeString(AUrl);
  if UrlW = '' then
  begin
    AResponse := 'Keine URL angegeben';
    Exit;
  end;

  FillChar(Comp, SizeOf(Comp), 0);
  Comp.dwStructSize := SizeOf(Comp);
  Comp.dwSchemeLength := DWORD(-1);
  Comp.dwHostNameLength := DWORD(-1);
  Comp.dwUrlPathLength := DWORD(-1);
  Comp.dwExtraInfoLength := DWORD(-1);
  if not WinHttpCrackUrl(PWideChar(UrlW), Length(UrlW), 0, Comp) then
  begin
    Fail('URL zerlegen');
    Exit;
  end;

  SetString(HostW, Comp.lpszHostName, Comp.dwHostNameLength);
  SetString(PathW, Comp.lpszUrlPath, Comp.dwUrlPathLength + Comp.dwExtraInfoLength);
  if PathW = '' then PathW := '/';
  { HTTPS am Schema erkennen, nicht am Port - sonst bricht https://host:8443 }
  Secure := Comp.nScheme = INTERNET_SCHEME_HTTPS;
  VerbW := UnicodeString(UpperCase(AMethod));
  if VerbW = '' then VerbW := 'GET';
  AgentW := UnicodeString(AmsHttpUserAgent);

  try
    Sess := WinHttpOpen(PWideChar(AgentW), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                        nil, nil, 0);
    if Sess = nil then begin Fail('WinHttpOpen'); Exit; end;
    WinHttpSetTimeouts(Sess, AmsHttpTimeoutMs div 2, AmsHttpTimeoutMs div 2,
                       AmsHttpTimeoutMs, AmsHttpTimeoutMs);

    Conn := WinHttpConnect(Sess, PWideChar(HostW), Comp.nPort, 0);
    if Conn = nil then begin Fail('WinHttpConnect'); Exit; end;

    Flags := 0;
    if Secure then Flags := WINHTTP_FLAG_SECURE;
    Req := WinHttpOpenRequest(Conn, PWideChar(VerbW), PWideChar(PathW),
                              nil, nil, nil, Flags);
    if Req = nil then begin Fail('WinHttpOpenRequest'); Exit; end;

    BodyU := UTF8String(ABody);
    HdrW := UnicodeString(StringReplace(AHeaders, AMS_HEADER_SEPARATOR,
                                        #13#10, [rfReplaceAll]));
    if HdrW <> '' then HdrPtr := PWideChar(HdrW) else HdrPtr := nil;

    if not WinHttpSendRequest(Req, HdrPtr, DWORD(-1),
             Pointer(PAnsiChar(BodyU)), Length(BodyU), Length(BodyU), 0) then
    begin
      Fail('WinHttpSendRequest');
      Exit;
    end;
    if not WinHttpReceiveResponse(Req, nil) then
    begin
      Fail('WinHttpReceiveResponse');
      Exit;
    end;

    Code := 0;
    Len := SizeOf(Code);
    if WinHttpQueryHeaders(Req,
         WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER,
         nil, @Code, Len, nil) then
      AStatus := Integer(Code);

    Raw := '';
    repeat
      Read := 0;
      if not WinHttpReadData(Req, @Buf[0], SizeOf(Buf), Read) then Break;
      if Read = 0 then Break;
      SetLength(Raw, Length(Raw) + Integer(Read));
      Move(Buf[0], Raw[Length(Raw) - Integer(Read) + 1], Read);
    until False;

    AResponse := string(Raw);
    Result := True;
  finally
    if Req <> nil then WinHttpCloseHandle(Req);
    if Conn <> nil then WinHttpCloseHandle(Conn);
    if Sess <> nil then WinHttpCloseHandle(Sess);
  end;
end;

type
  PHttpJob = ^THttpJob;
  THttpJob = record
    Method, Url, Headers, Body: string;
    OnDone: TAmsHttpDoneEvent;
    Tag: Integer;
  end;

function HttpThread(AParam: Pointer): PtrInt;
var
  Job: PHttpJob;
  Status: Integer;
  Resp, Short: string;
  Ok: Boolean;
begin
  Result := 0;
  Job := PHttpJob(AParam);
  Status := 0;
  Resp := '';
  Ok := False;
  try
    Ok := AmsHttpRequest(Job^.Method, Job^.Url, Job^.Headers, Job^.Body,
                         Status, Resp);
    if Ok then
    begin
      AmsLogFmt('HTTP %s %s -> Status %d, %d Zeichen',
                [Job^.Method, Job^.Url, Status, Length(Resp)]);
      Short := Resp;
      if Length(Short) > 400 then Short := Copy(Short, 1, 400) + ' ...';
      AmsLog('HTTP Antwort: ' +
             StringReplace(Short, sLineBreak, ' ', [rfReplaceAll]));
    end
    else
      AmsLogFmt('HTTP %s %s FEHLER: %s', [Job^.Method, Job^.Url, Resp]);
  except
    on E: Exception do AmsLog('HTTP EXCEPTION: ' + E.Message);
  end;
  try
    if Assigned(Job^.OnDone) then Job^.OnDone(Ok, Status, Resp, Job^.Tag);
  except
    on E: Exception do AmsLog('HTTP-Callback EXCEPTION: ' + E.Message);
  end;
  Dispose(Job);
end;

function AmsHttpRequestAsync(const AMethod, AUrl, AHeaders, ABody: string;
  AOnDone: TAmsHttpDoneEvent; ATag: Integer): Boolean;
var
  Job: PHttpJob;
begin
  Result := False;
  if Trim(AUrl) = '' then Exit(AmsFail('HTTP: keine URL angegeben'));
  New(Job);
  Job^.Method := AMethod;
  if Job^.Method = '' then Job^.Method := 'GET';
  Job^.Url := AUrl;
  Job^.Headers := AHeaders;
  Job^.Body := ABody;
  Job^.OnDone := AOnDone;
  Job^.Tag := ATag;
  AmsLogFmt('HTTP %s %s - starte im Hintergrund', [Job^.Method, Job^.Url]);
  BeginThread(@HttpThread, Job);
  Result := True;
end;

{ ------------------------------------------------- Binaer + Weiterleitung -- }

function AmsHeaderRemove(const AHeaders, AName: string): string;
var
  L: TStringList;
  i: Integer;
  Line: string;
begin
  Result := '';
  if AHeaders = '' then Exit;
  L := TStringList.Create;
  try
    L.Text := StringReplace(AHeaders, AMS_HEADER_SEPARATOR, #13#10,
                            [rfReplaceAll]);
    for i := 0 to L.Count - 1 do
    begin
      Line := Trim(L[i]);
      if Line = '' then Continue;
      if SameText(Trim(Copy(Line, 1, Pos(':', Line) - 1)), AName) then Continue;
      if Result <> '' then Result := Result + AMS_HEADER_SEPARATOR;
      Result := Result + Line;
    end;
  finally
    L.Free;
  end;
end;

{ Ziel einer Weiterleitung gegen die bisherige URL aufloesen. }
function ResolveLocation(const ABase, ALoc: string): string;
var
  p, q: Integer;
  Origin: string;
begin
  if (Pos('://', ALoc) > 0) and (Pos('://', ALoc) < 10) then Exit(ALoc);
  p := Pos('://', ABase);
  if p = 0 then Exit(ALoc);
  q := p + 3;
  while (q <= Length(ABase)) and (ABase[q] <> '/') do Inc(q);
  Origin := Copy(ABase, 1, q - 1);
  if (ALoc <> '') and (ALoc[1] = '/') then
  begin
    if (Length(ALoc) >= 2) and (ALoc[2] = '/') then
      Exit(Copy(ABase, 1, p) + ALoc);      { //host/pfad }
    Exit(Origin + ALoc);
  end;
  { relativ zum Ordner der bisherigen URL }
  Result := ABase;
  q := Pos('?', Result);
  if q > 0 then Result := Copy(Result, 1, q - 1);
  q := Length(Result);
  while (q > Length(Origin)) and (Result[q] <> '/') do Dec(q);
  if q <= Length(Origin) then Result := Origin + '/' + ALoc
  else Result := Copy(Result, 1, q) + ALoc;
end;

function HostOf(const AUrl: string): string;
var
  p, q: Integer;
begin
  Result := '';
  p := Pos('://', AUrl);
  if p = 0 then Exit;
  q := p + 3;
  while (q <= Length(AUrl)) and not (AUrl[q] in ['/', '?', '#']) do Inc(q);
  Result := LowerCase(Copy(AUrl, p + 3, q - p - 3));
end;

function OpenSession: Pointer;
var
  AgentW: UnicodeString;
begin
  AgentW := UnicodeString(AmsHttpUserAgent);
  Result := WinHttpOpen(PWideChar(AgentW), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                        nil, nil, 0);
  if Result = nil then   { vor Windows 8.1 }
    Result := WinHttpOpen(PWideChar(AgentW), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                          nil, nil, 0);
  if Result <> nil then
    WinHttpSetTimeouts(Result, AmsHttpTimeoutMs div 2, AmsHttpTimeoutMs div 2,
                       AmsHttpTimeoutMs, AmsHttpTimeoutMs);
end;

{ Ein einzelner Schritt: eine URL, keine Weiterleitung. ALocation wird bei
  3xx gefuellt, sonst landet der Rumpf in AStream. }
function FetchOnce(ASess: Pointer; const AUrl, AHeaders: string;
  AStream: TStream; AMaxBytes: Int64; out AStatus: Integer;
  out ALocation: string): Boolean;
var
  UrlW, HostW, PathW, HdrW: UnicodeString;
  Comp: TUrlComponents;
  Conn, Req: Pointer;
  Flags, Opt, Code, Len, Read: DWORD;
  HdrPtr: PWideChar;
  Buf: array[0..16383] of Byte;
  LocBuf: array of WideChar;
  Total: Int64;
begin
  Result := False;
  AStatus := 0;
  ALocation := '';
  Conn := nil;
  Req := nil;
  UrlW := UnicodeString(AUrl);
  FillChar(Comp, SizeOf(Comp), 0);
  Comp.dwStructSize := SizeOf(Comp);
  Comp.dwSchemeLength := DWORD(-1);
  Comp.dwHostNameLength := DWORD(-1);
  Comp.dwUrlPathLength := DWORD(-1);
  Comp.dwExtraInfoLength := DWORD(-1);
  if not WinHttpCrackUrl(PWideChar(UrlW), Length(UrlW), 0, Comp) then
    Exit(AmsFailFmt('HTTP: URL nicht zerlegbar (%d): %s', [GetLastError, AUrl]));
  SetString(HostW, Comp.lpszHostName, Comp.dwHostNameLength);
  SetString(PathW, Comp.lpszUrlPath, Comp.dwUrlPathLength + Comp.dwExtraInfoLength);
  if PathW = '' then PathW := '/';
  try
    Conn := WinHttpConnect(ASess, PWideChar(HostW), Comp.nPort, 0);
    if Conn = nil then
      Exit(AmsFailFmt('HTTP: keine Verbindung zu %s (%d)',
                      [string(HostW), GetLastError]));
    Flags := 0;
    if Comp.nScheme = INTERNET_SCHEME_HTTPS then Flags := WINHTTP_FLAG_SECURE;
    Req := WinHttpOpenRequest(Conn, 'GET', PWideChar(PathW), nil, nil, nil, Flags);
    if Req = nil then
      Exit(AmsFailFmt('HTTP: Anfrage nicht anlegbar (%d)', [GetLastError]));
    Opt := WINHTTP_DISABLE_REDIRECTS;
    WinHttpSetOption(Req, WINHTTP_OPTION_DISABLE_FEATURE, @Opt, SizeOf(Opt));

    HdrW := UnicodeString(StringReplace(AHeaders, AMS_HEADER_SEPARATOR, #13#10,
                                        [rfReplaceAll]));
    if HdrW <> '' then HdrPtr := PWideChar(HdrW) else HdrPtr := nil;
    if not WinHttpSendRequest(Req, HdrPtr, DWORD(-1), nil, 0, 0, 0) then
      Exit(AmsFailFmt('HTTP: Senden an %s fehlgeschlagen (%d)',
                      [string(HostW), GetLastError]));
    if not WinHttpReceiveResponse(Req, nil) then
      Exit(AmsFailFmt('HTTP: keine Antwort von %s (%d)',
                      [string(HostW), GetLastError]));

    Code := 0;
    Len := SizeOf(Code);
    if WinHttpQueryHeaders(Req, WINHTTP_QUERY_STATUS_CODE or
         WINHTTP_QUERY_FLAG_NUMBER, nil, @Code, Len, nil) then
      AStatus := Integer(Code);

    if (AStatus >= 300) and (AStatus < 400) and (AStatus <> 304) then
    begin
      Len := 0;
      WinHttpQueryHeaders(Req, WINHTTP_QUERY_LOCATION, nil, nil, Len, nil);
      if Len > 0 then
      begin
        SetLength(LocBuf, Len div 2 + 1);
        if WinHttpQueryHeaders(Req, WINHTTP_QUERY_LOCATION, nil, @LocBuf[0],
                               Len, nil) then
          ALocation := string(WideString(PWideChar(@LocBuf[0])));
      end;
      Exit(True);
    end;

    Total := 0;
    repeat
      Read := 0;
      if not WinHttpReadData(Req, @Buf[0], SizeOf(Buf), Read) then
        Exit(AmsFailFmt('HTTP: Lesefehler von %s (%d)',
                        [string(HostW), GetLastError]));
      if Read = 0 then Break;
      Inc(Total, Read);
      { Eine Fehlerseite (GitHub: 300 KB HTML fuer ein fehlendes Asset)
        braucht niemand ganz - sonst verdeckt die Groessengrenze den
        eigentlichen Status. }
      if (AStatus >= 400) and (Total > 65536) then Break;
      if (AMaxBytes > 0) and (Total > AMaxBytes) then
        Exit(AmsFailFmt('HTTP: Antwort groesser als %d Bytes: %s',
                        [AMaxBytes, AUrl]));
      AStream.WriteBuffer(Buf[0], Read);
    until False;
    Result := True;
  finally
    if Req <> nil then WinHttpCloseHandle(Req);
    if Conn <> nil then WinHttpCloseHandle(Conn);
  end;
end;

function FetchTo(const AUrl, AHeaders: string; AStream: TStream;
  AMaxBytes: Int64; out AStatus: Integer): Boolean;
var
  Sess: Pointer;
  Url, Hdr, Loc, Host: string;
  Hops: Integer;
begin
  Result := False;
  AStatus := 0;
  if Trim(AUrl) = '' then Exit(AmsFail('HTTP: keine URL angegeben'));
  Sess := OpenSession;
  if Sess = nil then
    Exit(AmsFailFmt('HTTP: WinHttpOpen fehlgeschlagen (%d)', [GetLastError]));
  try
    Url := Trim(AUrl);
    Hdr := AHeaders;
    Host := HostOf(Url);
    for Hops := 0 to MAX_REDIRECTS do
    begin
      AStream.Size := 0;
      if not FetchOnce(Sess, Url, Hdr, AStream, AMaxBytes, AStatus, Loc) then
        Exit;
      if Loc = '' then
      begin
        if (AStatus >= 300) and (AStatus < 400) and (AStatus <> 304) then
          Exit(AmsFailFmt('HTTP %d ohne Ziel: %s', [AStatus, Url]));
        Exit(True);
      end;
      Url := ResolveLocation(Url, Loc);
      if (Pos('https://', LowerCase(AUrl)) = 1) and
         (Pos('https://', LowerCase(Url)) <> 1) then
        Exit(AmsFailFmt('HTTP: Weiterleitung von https auf unsicher ' +
                        'abgelehnt: %s', [Url]));
      if HostOf(Url) <> Host then
      begin
        Hdr := AmsHeaderRemove(Hdr, 'Authorization');
        Host := HostOf(Url);
      end;
    end;
    Result := AmsFailFmt('HTTP: mehr als %d Weiterleitungen: %s',
                         [MAX_REDIRECTS, AUrl]);
  finally
    WinHttpCloseHandle(Sess);
  end;
end;

function AmsHttpGet(const AUrl, AHeaders: string; out AStatus: Integer;
  out AData: string; AMaxBytes: Int64): Boolean;
var
  M: TMemoryStream;
begin
  AData := '';
  M := TMemoryStream.Create;
  try
    Result := FetchTo(AUrl, AHeaders, M, AMaxBytes, AStatus);
    if Result and (M.Size > 0) then
    begin
      SetLength(AData, M.Size);
      Move(M.Memory^, AData[1], M.Size);
    end;
  finally
    M.Free;
  end;
end;

function AmsHttpDownload(const AUrl, AHeaders, ADestFile: string;
  out AStatus: Integer; AMaxBytes: Int64): Boolean;
var
  F: TFileStream;
  Part: string;
begin
  Result := False;
  AStatus := 0;
  Part := ADestFile + '.part';
  ForceDirectories(ExtractFilePath(ADestFile));
  try
    F := TFileStream.Create(Part, fmCreate);
  except
    on E: Exception do
      Exit(AmsFailFmt('Download: %s nicht anlegbar (%s)', [Part, E.Message]));
  end;
  try
    Result := FetchTo(AUrl, AHeaders, F, AMaxBytes, AStatus);
  finally
    F.Free;
  end;
  if Result and (AStatus = 200) then
  begin
    DeleteFile(ADestFile);
    if not RenameFile(Part, ADestFile) then
    begin
      DeleteFile(Part);
      Exit(AmsFailFmt('Download: %s nicht umbenennbar', [Part]));
    end;
  end
  else
    DeleteFile(Part);
end;

function AmsOpenUrl(const AUrl: string): Boolean;
var
  UrlW: UnicodeString;
  R: HINST;
begin
  Result := False;
  UrlW := UnicodeString(Trim(AUrl));
  if UrlW = '' then Exit(AmsFail('OpenUrl: keine URL angegeben'));
  R := ShellExecuteW(0, 'open', PWideChar(UrlW), nil, nil, SW_SHOWNORMAL);
  if R > 32 then
  begin
    AmsLog('Browser geoeffnet: ' + string(UrlW));
    Result := True;
  end
  else
    Result := AmsFailFmt('ShellExecute fehlgeschlagen (%d) fuer %s',
                         [R, string(UrlW)]);
end;

end.
