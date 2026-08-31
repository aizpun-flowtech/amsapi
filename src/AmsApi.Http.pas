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
