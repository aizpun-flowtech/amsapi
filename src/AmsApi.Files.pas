unit AmsApi.Files;

{ ============================================================================
  AmsApi.Files - Dateien, Ordner, Text, Pruefsummen

  Was ein Plugin braucht, sobald es selbst Dateien bewegt - etwa der Plugin
  Manager beim Installieren:

    - Dateien ROH lesen und schreiben. Inhalt ist ein gewoehnlicher string
      mit den Bytes der Datei, ohne jede Umwandlung. UTF-8 bleibt damit
      UTF-8, bis es ausdruecklich (AmsUtf8ToWide / AmsDecodeText) fuer ein
      W-API umgewandelt wird. Wichtig: so einen Byte-string nie mit einem
      Literal aus einer Unit mit "codepage utf8" verketten - FPC wuerde dann
      umkodieren. Vorher AmsWideToUtf8 nehmen.
    - Text erkennen: UTF-8 (mit und ohne BOM) oder ANSI.
    - Base64 und data:-URIs - Bilder lassen sich so in eine HTML-Seite legen,
      die keine fremden Dateien mehr nachladen muss.
    - SHA-256 ueber bcrypt.dll, dynamisch gebunden.
    - Ordnerbaeume kopieren, loeschen, auflisten; pruefen, ob ein Ordner
      beschreibbar ist (BIN\plugins ist es fuer normale Benutzer NICHT).
    - Dateien ersetzen, die gerade GELADEN sind. Eine BPL, die AMS benutzt,
      laesst sich weder loeschen noch ueberschreiben - umbenennen aber schon
      (der Lader oeffnet Images mit FILE_SHARE_DELETE). AmsReplaceFile
      schiebt das Original deshalb als <Datei>.<Zeit>.old beiseite und legt
      die neue Datei an seinen Platz. Der laufende Prozess benutzt weiter
      die alte, der naechste Start die neue. AmsCleanupOld raeumt die Reste
      weg, sobald sie niemand mehr haelt.

  Keine Beruehrung mit dem Host, ohne AMS testbar.
  ============================================================================ }

{$MODE DELPHI}
{$H+}

interface

uses
  Windows, SysUtils, Classes;

{ ------------------------------------------------------------- Roh lesen -- }

{ Datei als Bytes lesen. AMaxBytes > 0 lehnt groessere Dateien ab. }
function AmsReadFileRaw(const AFile: string; out AData: string;
  AMaxBytes: Int64 = 0): Boolean;

{ Bytes schreiben. Legt den Ordner an und schreibt ueber eine .tmp-Datei,
  damit ein Abbruch keine halbe Datei hinterlaesst. }
function AmsWriteFileRaw(const AFile, AData: string): Boolean;

{ ------------------------------------------------------------------ Text -- }

function AmsIsUtf8(const AData: string): Boolean;
function AmsHasUtf8Bom(const AData: string): Boolean;
function AmsStripBom(const AData: string): string;
function AmsUtf8ToWide(const AData: string): WideString;
function AmsWideToUtf8(const AText: WideString): string;
{ Fuer die Anzeige: gueltiges UTF-8 als UTF-8, sonst als ANSI lesen. }
function AmsDecodeText(const AData: string): WideString;
{ Umgekehrt: beliebigen Text der Datei als UTF-8-Bytes, egal wie sie
  kodiert ist. }
function AmsToUtf8(const AData: string): string;

{ ------------------------------------------------------- Base64 / data: -- }

function AmsBase64Encode(const AData: string): string;
function AmsBase64Decode(const AText: string; out AData: string): Boolean;
{ MIME-Typ nach Endung: png jpg jpeg gif svg bmp ico webp; sonst
  application/octet-stream. Query (?...) und Anker (#...) werden ignoriert. }
function AmsMimeOf(const AFileOrUrl: string): string;
function AmsDataUri(const AMime, AData: string): string;
{ Bildformat am INHALT erkennen (PNG, GIF, JPEG, BMP, WEBP, ICO, SVG).
  '' = kein Bild - etwa eine HTML-Fehlerseite statt des Bildes.
  Steht absichtlich hier und nicht in einer Unit mit "codepage utf8": dort
  waere #$89 ein Unicode-Zeichen und der Bytevergleich ginge daneben. }
function AmsSniffImageMime(const AData: string): string;

{ ------------------------------------------------------------ Pruefsumme -- }

{ SHA-256 als Hex in Kleinbuchstaben. Leer bei Fehler (AmsLastError). }
function AmsSha256(const AData: string): string;
function AmsSha256File(const AFile: string; out AHex: string): Boolean;

{ ---------------------------------------------------------------- Ordner -- }

function AmsForceDir(const ADir: string): Boolean;
{ Ganzen Baum loeschen. True auch, wenn es ihn nicht gab. }
function AmsDeleteTree(const ADir: string): Boolean;
{ Relative Dateipfade unterhalb ADir (mit \ getrennt), sortiert. }
procedure AmsListFiles(const ADir: string; ADest: TStrings;
  ARecursive: Boolean = True);
{ Baum kopieren. Vorhandene Dateien werden per AmsReplaceFile ersetzt,
  geladene also beiseite geschoben. Zusaetzliche Dateien im Ziel bleiben
  stehen - dort liegt womoeglich etwas vom Anwender. }
function AmsCopyTree(const ASrc, ADest: string): Boolean;
{ Darf dieser Prozess hier anlegen? Probe: Datei anlegen und loeschen.
  Fuer Program Files ohne Administratorrechte: False.

  FALLE: Ein 32-Bit-Programm OHNE Manifest wird von Windows "virtualisiert"
  - Schreiben nach Program Files gelingt scheinbar und landet still in
  %LOCALAPPDATA%\VirtualStore. Die Probe wuerde dann luegen. Deshalb
  schaltet AmsCanWriteDir die Virtualisierung vorher ab und liefert False,
  wenn das nicht geht. AMS selbst hat ein asInvoker-Manifest, ist also
  nicht betroffen - eigene Hilfsprogramme schon (Manifest einbinden!). }
function AmsCanWriteDir(const ADir: string): Boolean;
{ Leitet Windows Schreibzugriffe dieses Prozesses nach VirtualStore um? }
function AmsIsVirtualized: Boolean;
{ Umleitung fuer diesen Prozess abschalten. True = jetzt aus. }
function AmsDisableVirtualization: Boolean;
{ %LOCALAPPDATA%\<ASub>\, angelegt. Ohne LOCALAPPDATA: %TEMP%\<ASub>\. }
function AmsLocalDataDir(const ASub: string): string;
{ Umgebungsvariablen in einem Pfad aufloesen (%APPDATA% ...). }
function AmsExpandEnv(const APath: string): string;

{ -------------------------------------------------- Geladene Dateien ---- }

{ ASrc nach ADest kopieren, auch wenn ADest gerade geladen ist. ARenamedTo
  meldet, wohin das Original geschoben wurde ('' = nicht noetig). }
function AmsReplaceFile(const ASrc, ADest: string;
  out ARenamedTo: string): Boolean;
{ Datei loeschen; geht das nicht, beiseite umbenennen. }
function AmsRemoveFile(const AFile: string; out ARenamedTo: string): Boolean;
{ *.old-Reste unterhalb ADir loeschen, soweit sie niemand mehr haelt.
  Liefert die Anzahl der geloeschten. }
function AmsCleanupOld(const ADir: string): Integer;

{ ------------------------------------------------------------- Namen ---- }

{ Ein einzelner Ordner- oder Dateiname aus fremder Quelle: nicht leer,
  kein \ / : * ? " < > |, nicht . oder .., keine Steuerzeichen. }
function AmsIsSafeName(const AName: string): Boolean;
{ Relativer Pfad, der nicht aus seinem Ordner herausfuehrt: kein Laufwerk,
  kein fuehrender Trenner, kein ".." als Bestandteil. / und \ gehen beide. }
function AmsIsSafeRelPath(const APath: string): Boolean;

implementation

uses
  AmsApi.Log;

{ ------------------------------------------------------------- Roh lesen -- }

function AmsReadFileRaw(const AFile: string; out AData: string;
  AMaxBytes: Int64): Boolean;
var
  H: THandle;
  Size, Hi: DWORD;
  Read: DWORD;
begin
  Result := False;
  AData := '';
  H := CreateFileW(PWideChar(WideString(AFile)), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
    Exit(AmsFailFmt('Datei nicht lesbar (%d): %s', [GetLastError, AFile]));
  try
    Hi := 0;
    Size := GetFileSize(H, @Hi);
    if (Size = INVALID_FILE_SIZE) and (GetLastError <> NO_ERROR) then
      Exit(AmsFailFmt('Dateigroesse unbekannt: %s', [AFile]));
    if (Hi <> 0) or (Size > $40000000) then
      Exit(AmsFailFmt('Datei zu gross: %s', [AFile]));
    if (AMaxBytes > 0) and (Int64(Size) > AMaxBytes) then
      Exit(AmsFailFmt('Datei groesser als %d Bytes: %s', [AMaxBytes, AFile]));
    SetLength(AData, Size);
    if Size > 0 then
    begin
      Read := 0;
      if not ReadFile(H, AData[1], Size, Read, nil) or (Read <> Size) then
      begin
        AData := '';
        Exit(AmsFailFmt('Lesen fehlgeschlagen (%d): %s', [GetLastError, AFile]));
      end;
    end;
    Result := True;
  finally
    CloseHandle(H);
  end;
end;

function AmsWriteFileRaw(const AFile, AData: string): Boolean;
var
  H: THandle;
  Tmp: string;
  Written: DWORD;
  Ok: Boolean;
begin
  Result := False;
  if not AmsForceDir(ExtractFilePath(AFile)) then Exit;
  Tmp := AFile + '.tmp';
  H := CreateFileW(PWideChar(WideString(Tmp)), GENERIC_WRITE, 0, nil,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
    Exit(AmsFailFmt('Datei nicht schreibbar (%d): %s', [GetLastError, AFile]));
  Ok := True;
  try
    if AData <> '' then
    begin
      Written := 0;
      Ok := WriteFile(H, AData[1], Length(AData), Written, nil) and
            (Integer(Written) = Length(AData));
    end;
  finally
    CloseHandle(H);
  end;
  if not Ok then
  begin
    DeleteFileW(PWideChar(WideString(Tmp)));
    Exit(AmsFailFmt('Schreiben fehlgeschlagen: %s', [AFile]));
  end;
  if not MoveFileExW(PWideChar(WideString(Tmp)), PWideChar(WideString(AFile)),
                     MOVEFILE_REPLACE_EXISTING) then
  begin
    DeleteFileW(PWideChar(WideString(Tmp)));
    Exit(AmsFailFmt('Ersetzen fehlgeschlagen (%d): %s', [GetLastError, AFile]));
  end;
  Result := True;
end;

{ ------------------------------------------------------------------ Text -- }

function AmsHasUtf8Bom(const AData: string): Boolean;
begin
  Result := (Length(AData) >= 3) and (AData[1] = #$EF) and
            (AData[2] = #$BB) and (AData[3] = #$BF);
end;

function AmsStripBom(const AData: string): string;
begin
  if AmsHasUtf8Bom(AData) then
    Result := Copy(AData, 4, MaxInt)
  else
    Result := AData;
end;

function AmsIsUtf8(const AData: string): Boolean;
var
  i, n, Need: Integer;
  B: Byte;
begin
  Result := True;
  i := 1;
  n := Length(AData);
  while i <= n do
  begin
    B := Byte(AData[i]);
    if B < $80 then
    begin
      Inc(i);
      Continue;
    end;
    if (B and $E0) = $C0 then Need := 1
    else if (B and $F0) = $E0 then Need := 2
    else if (B and $F8) = $F0 then Need := 3
    else Exit(False);
    { Ueberlange Formen von ASCII ($C0/$C1) sind kein gueltiges UTF-8 }
    if (B = $C0) or (B = $C1) then Exit(False);
    if i + Need > n then Exit(False);
    Inc(i);
    while Need > 0 do
    begin
      if (Byte(AData[i]) and $C0) <> $80 then Exit(False);
      Inc(i);
      Dec(Need);
    end;
  end;
end;

function AmsUtf8ToWide(const AData: string): WideString;
var
  S: string;
  n: Integer;
begin
  Result := '';
  S := AmsStripBom(AData);
  if S = '' then Exit;
  n := MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(S), Length(S), nil, 0);
  if n <= 0 then Exit;
  SetLength(Result, n);
  MultiByteToWideChar(CP_UTF8, 0, PAnsiChar(S), Length(S), PWideChar(Result), n);
end;

function AmsWideToUtf8(const AText: WideString): string;
var
  n: Integer;
begin
  Result := '';
  if AText = '' then Exit;
  n := WideCharToMultiByte(CP_UTF8, 0, PWideChar(AText), Length(AText),
                           nil, 0, nil, nil);
  if n <= 0 then Exit;
  SetLength(Result, n);
  WideCharToMultiByte(CP_UTF8, 0, PWideChar(AText), Length(AText),
                      PAnsiChar(Result), n, nil, nil);
end;

function AnsiBytesToWide(const AData: string): WideString;
var
  n: Integer;
begin
  Result := '';
  if AData = '' then Exit;
  n := MultiByteToWideChar(CP_ACP, 0, PAnsiChar(AData), Length(AData), nil, 0);
  if n <= 0 then Exit;
  SetLength(Result, n);
  MultiByteToWideChar(CP_ACP, 0, PAnsiChar(AData), Length(AData),
                      PWideChar(Result), n);
end;

function AmsDecodeText(const AData: string): WideString;
begin
  if AmsHasUtf8Bom(AData) or AmsIsUtf8(AData) then
    Result := AmsUtf8ToWide(AData)
  else
    Result := AnsiBytesToWide(AData);
end;

function AmsToUtf8(const AData: string): string;
begin
  if AmsHasUtf8Bom(AData) then
    Result := Copy(AData, 4, MaxInt)
  else if AmsIsUtf8(AData) then
    Result := AData
  else
    Result := AmsWideToUtf8(AnsiBytesToWide(AData));
end;

{ ------------------------------------------------------- Base64 / data: -- }

const
  B64: array[0..63] of AnsiChar =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function AmsBase64Encode(const AData: string): string;
var
  i, o, n: Integer;
  V: Cardinal;
begin
  n := Length(AData);
  SetLength(Result, ((n + 2) div 3) * 4);
  i := 1;
  o := 1;
  while i <= n do
  begin
    V := Cardinal(Byte(AData[i])) shl 16;
    if i + 1 <= n then V := V or (Cardinal(Byte(AData[i + 1])) shl 8);
    if i + 2 <= n then V := V or Cardinal(Byte(AData[i + 2]));
    Result[o]     := B64[(V shr 18) and 63];
    Result[o + 1] := B64[(V shr 12) and 63];
    if i + 1 <= n then Result[o + 2] := B64[(V shr 6) and 63]
                  else Result[o + 2] := '=';
    if i + 2 <= n then Result[o + 3] := B64[V and 63]
                  else Result[o + 3] := '=';
    Inc(i, 3);
    Inc(o, 4);
  end;
end;

function AmsBase64Decode(const AText: string; out AData: string): Boolean;
var
  i, Bits, Acc, v, o: Integer;
  C: AnsiChar;
begin
  Result := False;
  AData := '';
  SetLength(AData, (Length(AText) div 4) * 3 + 3);
  o := 0;
  Acc := 0;
  Bits := 0;
  for i := 1 to Length(AText) do
  begin
    C := AText[i];
    case C of
      'A'..'Z': v := Ord(C) - Ord('A');
      'a'..'z': v := Ord(C) - Ord('a') + 26;
      '0'..'9': v := Ord(C) - Ord('0') + 52;
      '+', '-': v := 62;
      '/', '_': v := 63;
      '=': Break;
      #9, #10, #13, ' ': Continue;
    else
      Exit;
    end;
    Acc := (Acc shl 6) or v;
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Inc(o);
      AData[o] := AnsiChar((Acc shr Bits) and $FF);
    end;
  end;
  SetLength(AData, o);
  Result := True;
end;

function AmsMimeOf(const AFileOrUrl: string): string;
var
  S, Ext: string;
  p: Integer;
begin
  S := AFileOrUrl;
  p := Pos('?', S);
  if p > 0 then S := Copy(S, 1, p - 1);
  p := Pos('#', S);
  if p > 0 then S := Copy(S, 1, p - 1);
  Ext := LowerCase(ExtractFileExt(StringReplace(S, '/', '\', [rfReplaceAll])));
  if Ext = '.png' then Result := 'image/png'
  else if (Ext = '.jpg') or (Ext = '.jpeg') then Result := 'image/jpeg'
  else if Ext = '.gif' then Result := 'image/gif'
  else if Ext = '.svg' then Result := 'image/svg+xml'
  else if Ext = '.bmp' then Result := 'image/bmp'
  else if Ext = '.ico' then Result := 'image/x-icon'
  else if Ext = '.webp' then Result := 'image/webp'
  else Result := 'application/octet-stream';
end;

function AmsDataUri(const AMime, AData: string): string;
begin
  Result := 'data:' + AMime + ';base64,' + AmsBase64Encode(AData);
end;

function AmsSniffImageMime(const AData: string): string;
var
  Head: string;
begin
  Result := '';
  if Length(AData) < 4 then Exit;
  if Copy(AData, 1, 4) = #$89'PNG' then Exit('image/png');
  if Copy(AData, 1, 4) = 'GIF8' then Exit('image/gif');
  if Copy(AData, 1, 2) = #$FF#$D8 then Exit('image/jpeg');
  if Copy(AData, 1, 2) = 'BM' then Exit('image/bmp');
  if (Copy(AData, 1, 4) = 'RIFF') and (Copy(AData, 9, 4) = 'WEBP') then
    Exit('image/webp');
  if Copy(AData, 1, 4) = #0#0#1#0 then Exit('image/x-icon');
  Head := LowerCase(Copy(AData, 1, 2048));
  if Pos('<svg', Head) > 0 then Exit('image/svg+xml');
end;

{ ------------------------------------------------------------ Pruefsumme -- }

type
  TBCryptOpen = function(var AAlg: Pointer; AAlgId, AImpl: PWideChar;
    AFlags: ULONG): LongInt; stdcall;
  TBCryptCreateHash = function(AAlg: Pointer; var AHash: Pointer;
    AObj: PByte; AObjLen: ULONG; ASecret: PByte; ASecretLen: ULONG;
    AFlags: ULONG): LongInt; stdcall;
  TBCryptHashData = function(AHash: Pointer; AInput: PByte; ALen: ULONG;
    AFlags: ULONG): LongInt; stdcall;
  TBCryptFinish = function(AHash: Pointer; AOut: PByte; ALen: ULONG;
    AFlags: ULONG): LongInt; stdcall;
  TBCryptDestroy = function(AHash: Pointer): LongInt; stdcall;
  TBCryptClose = function(AAlg: Pointer; AFlags: ULONG): LongInt; stdcall;

var
  gBcrypt: HMODULE = 0;
  gBcOpen: TBCryptOpen = nil;
  gBcCreate: TBCryptCreateHash = nil;
  gBcData: TBCryptHashData = nil;
  gBcFinish: TBCryptFinish = nil;
  gBcDestroy: TBCryptDestroy = nil;
  gBcClose: TBCryptClose = nil;

function BindBcrypt: Boolean;
begin
  if Assigned(gBcClose) then Exit(True);
  if gBcrypt = 0 then gBcrypt := LoadLibraryW('bcrypt.dll');
  if gBcrypt = 0 then Exit(AmsFail('SHA-256: bcrypt.dll nicht ladbar'));
  gBcOpen := TBCryptOpen(GetProcAddress(gBcrypt, 'BCryptOpenAlgorithmProvider'));
  gBcCreate := TBCryptCreateHash(GetProcAddress(gBcrypt, 'BCryptCreateHash'));
  gBcData := TBCryptHashData(GetProcAddress(gBcrypt, 'BCryptHashData'));
  gBcFinish := TBCryptFinish(GetProcAddress(gBcrypt, 'BCryptFinishHash'));
  gBcDestroy := TBCryptDestroy(GetProcAddress(gBcrypt, 'BCryptDestroyHash'));
  gBcClose := TBCryptClose(GetProcAddress(gBcrypt, 'BCryptCloseAlgorithmProvider'));
  Result := Assigned(gBcOpen) and Assigned(gBcCreate) and Assigned(gBcData) and
            Assigned(gBcFinish) and Assigned(gBcDestroy) and Assigned(gBcClose);
  if not Result then
  begin
    gBcClose := nil;
    AmsFail('SHA-256: bcrypt.dll ohne die erwarteten Funktionen');
  end;
end;

type
  { Einmal oeffnen, stueckweise fuettern - fuer Dateien wie fuer Strings. }
  TSha = record
    Alg, Hash: Pointer;
  end;

function ShaBegin(out AHs: TSha): Boolean;
begin
  AHs.Alg := nil;
  AHs.Hash := nil;
  Result := False;
  if not BindBcrypt then Exit;
  if gBcOpen(AHs.Alg, 'SHA256', nil, 0) <> 0 then
  begin
    AHs.Alg := nil;
    Exit(AmsFail('SHA-256: Algorithmus nicht verfuegbar'));
  end;
  if gBcCreate(AHs.Alg, AHs.Hash, nil, 0, nil, 0, 0) <> 0 then
  begin
    gBcClose(AHs.Alg, 0);
    AHs.Alg := nil;
    AHs.Hash := nil;
    Exit(AmsFail('SHA-256: BCryptCreateHash fehlgeschlagen'));
  end;
  Result := True;
end;

function ShaEnd(var AHs: TSha): string;
var
  D: array[0..31] of Byte;
  i: Integer;
begin
  Result := '';
  if gBcFinish(AHs.Hash, @D[0], 32, 0) = 0 then
    for i := 0 to 31 do Result := Result + LowerCase(IntToHex(D[i], 2));
  gBcDestroy(AHs.Hash);
  gBcClose(AHs.Alg, 0);
  AHs.Hash := nil;
  AHs.Alg := nil;
end;

function AmsSha256(const AData: string): string;
var
  S: TSha;
begin
  Result := '';
  if not ShaBegin(S) then Exit;
  if AData <> '' then
    gBcData(S.Hash, PByte(PAnsiChar(AData)), Length(AData), 0);
  Result := ShaEnd(S);
end;

function AmsSha256File(const AFile: string; out AHex: string): Boolean;
var
  S: TSha;
  H: THandle;
  Buf: array[0..65535] of Byte;
  Read: DWORD;
begin
  Result := False;
  AHex := '';
  H := CreateFileW(PWideChar(WideString(AFile)), GENERIC_READ,
    FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, 0);
  if H = INVALID_HANDLE_VALUE then
    Exit(AmsFailFmt('SHA-256: Datei nicht lesbar (%d): %s',
                    [GetLastError, AFile]));
  try
    if not ShaBegin(S) then Exit;
    repeat
      Read := 0;
      if not ReadFile(H, Buf[0], SizeOf(Buf), Read, nil) then
      begin
        ShaEnd(S);
        Exit(AmsFailFmt('SHA-256: Lesefehler in %s', [AFile]));
      end;
      if Read > 0 then gBcData(S.Hash, @Buf[0], Read, 0);
    until Read = 0;
    AHex := ShaEnd(S);
    Result := AHex <> '';
  finally
    CloseHandle(H);
  end;
end;

{ ---------------------------------------------------------------- Ordner -- }

function AmsForceDir(const ADir: string): Boolean;
var
  D: string;
begin
  D := ExcludeTrailingPathDelimiter(ADir);
  if (D = '') or DirectoryExists(D) then Exit(True);
  Result := ForceDirectories(D);
  if not Result then
    AmsFailFmt('Ordner nicht anlegbar (%d): %s', [GetLastError, D]);
end;

function AmsDeleteTree(const ADir: string): Boolean;
var
  D: string;
  FD: TWin32FindDataW;
  H: THandle;
  Name, Full: string;
begin
  D := ExcludeTrailingPathDelimiter(ADir);
  if (D = '') or not DirectoryExists(D) then Exit(True);
  Result := True;
  H := FindFirstFileW(PWideChar(WideString(D + '\*')), FD);
  if H <> INVALID_HANDLE_VALUE then
  try
    repeat
      Name := string(WideString(FD.cFileName));
      if (Name = '.') or (Name = '..') then Continue;
      Full := D + '\' + Name;
      if (FD.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
      begin
        { Verbindungspunkte nicht verfolgen, nur den Link entfernen }
        if (FD.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
        begin
          if not RemoveDirectoryW(PWideChar(WideString(Full))) then
            Result := False;
        end
        else if not AmsDeleteTree(Full) then
          Result := False;
      end
      else
      begin
        if (FD.dwFileAttributes and FILE_ATTRIBUTE_READONLY) <> 0 then
          SetFileAttributesW(PWideChar(WideString(Full)), FILE_ATTRIBUTE_NORMAL);
        if not DeleteFileW(PWideChar(WideString(Full))) then
          Result := False;
      end;
    until not FindNextFileW(H, FD);
  finally
    Windows.FindClose(H);
  end;
  if not RemoveDirectoryW(PWideChar(WideString(D))) then Result := False;
  if not Result then
    AmsFailFmt('Ordner nicht vollstaendig loeschbar: %s', [D]);
end;

procedure ListInto(const ARoot, ARel: string; ADest: TStrings;
  ARecursive: Boolean);
var
  FD: TWin32FindDataW;
  H: THandle;
  Name, Rel: string;
begin
  H := FindFirstFileW(PWideChar(WideString(ARoot + ARel + '*')), FD);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    repeat
      Name := string(WideString(FD.cFileName));
      if (Name = '.') or (Name = '..') then Continue;
      Rel := ARel + Name;
      if (FD.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
      begin
        if ARecursive and
           ((FD.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) = 0) then
          ListInto(ARoot, Rel + '\', ADest, True);
      end
      else
        ADest.Add(Rel);
    until not FindNextFileW(H, FD);
  finally
    Windows.FindClose(H);
  end;
end;

procedure AmsListFiles(const ADir: string; ADest: TStrings; ARecursive: Boolean);
var
  L: TStringList;
begin
  if ADest = nil then Exit;
  L := TStringList.Create;
  try
    ListInto(IncludeTrailingPathDelimiter(ADir), '', L, ARecursive);
    L.Sort;
    ADest.AddStrings(L);
  finally
    L.Free;
  end;
end;

function AmsCopyTree(const ASrc, ADest: string): Boolean;
var
  L: TStringList;
  i: Integer;
  S, D, Renamed: string;
begin
  Result := False;
  S := IncludeTrailingPathDelimiter(ASrc);
  D := IncludeTrailingPathDelimiter(ADest);
  if not DirectoryExists(S) then
    Exit(AmsFailFmt('Quellordner fehlt: %s', [ASrc]));
  if not AmsForceDir(D) then Exit;
  L := TStringList.Create;
  try
    AmsListFiles(S, L, True);
    for i := 0 to L.Count - 1 do
    begin
      if not AmsForceDir(ExtractFilePath(D + L[i])) then Exit;
      if not AmsReplaceFile(S + L[i], D + L[i], Renamed) then Exit;
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

const
  TOKEN_VIRTUALIZATION_ENABLED = 24;   { TokenVirtualizationEnabled }

function AmsIsVirtualized: Boolean;
var
  H: THandle;
  V, L: DWORD;
begin
  Result := False;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, H) then Exit;
  try
    V := 0;
    L := 0;
    if GetTokenInformation(H, TTokenInformationClass(TOKEN_VIRTUALIZATION_ENABLED),
                           @V, SizeOf(V), L) then
      Result := V <> 0;
  finally
    CloseHandle(H);
  end;
end;

function AmsDisableVirtualization: Boolean;
var
  H: THandle;
  V: DWORD;
begin
  if not AmsIsVirtualized then Exit(True);
  if OpenProcessToken(GetCurrentProcess, TOKEN_QUERY or TOKEN_ADJUST_DEFAULT, H) then
  try
    V := 0;
    SetTokenInformation(H, TTokenInformationClass(TOKEN_VIRTUALIZATION_ENABLED),
                        @V, SizeOf(V));
  finally
    CloseHandle(H);
  end;
  Result := not AmsIsVirtualized;
end;

function AmsCanWriteDir(const ADir: string): Boolean;
var
  F: string;
  H: THandle;
begin
  Result := False;
  if not DirectoryExists(ExcludeTrailingPathDelimiter(ADir)) then Exit;
  { Siehe Schnittstelle: eine virtualisierte Probe gelingt immer. }
  if not AmsDisableVirtualization then Exit;
  F := IncludeTrailingPathDelimiter(ADir) +
       Format('.amsapi_probe_%d_%d.tmp', [GetCurrentProcessId, GetTickCount64]);
  H := CreateFileW(PWideChar(WideString(F)), GENERIC_WRITE, 0, nil,
    CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE, 0);
  if H = INVALID_HANDLE_VALUE then Exit;
  CloseHandle(H);
  DeleteFileW(PWideChar(WideString(F)));
  Result := True;
end;

function AmsExpandEnv(const APath: string): string;
var
  Buf: array[0..2047] of WideChar;
  n: DWORD;
begin
  Result := APath;
  if Pos('%', APath) = 0 then Exit;
  n := ExpandEnvironmentStringsW(PWideChar(WideString(APath)), Buf, Length(Buf));
  if (n > 0) and (n <= Length(Buf)) then Result := string(WideString(Buf));
end;

function AmsLocalDataDir(const ASub: string): string;
var
  Base: string;
begin
  Base := AmsExpandEnv('%LOCALAPPDATA%');
  if (Base = '') or (Base[1] = '%') or not DirectoryExists(Base) then
    Base := ExcludeTrailingPathDelimiter(GetTempDir);
  Result := IncludeTrailingPathDelimiter(Base);
  if ASub <> '' then Result := IncludeTrailingPathDelimiter(Result + ASub);
  AmsForceDir(Result);
end;

{ -------------------------------------------------- Geladene Dateien ---- }

function AsideName(const AFile: string): string;
var
  n: Integer;
begin
  n := 0;
  repeat
    Result := Format('%s.%x%d.old', [AFile, GetTickCount64, n]);
    Inc(n);
  until not FileExists(Result) or (n > 50);
end;

function AmsReplaceFile(const ASrc, ADest: string;
  out ARenamedTo: string): Boolean;
var
  Err: DWORD;
  Aside: string;
begin
  ARenamedTo := '';
  if CopyFileW(PWideChar(WideString(ASrc)), PWideChar(WideString(ADest)),
               False) then
    Exit(True);
  Err := GetLastError;
  if not FileExists(ADest) then
    Exit(AmsFailFmt('Kopieren fehlgeschlagen (%d): %s', [Err, ADest]));

  { Schreibschutz ist der harmlose Fall }
  SetFileAttributesW(PWideChar(WideString(ADest)), FILE_ATTRIBUTE_NORMAL);
  if CopyFileW(PWideChar(WideString(ASrc)), PWideChar(WideString(ADest)),
               False) then
    Exit(True);

  { Geladen: beiseite schieben. Umbenennen geht bei einem gemappten Image,
    Loeschen und Ueberschreiben nicht. }
  Aside := AsideName(ADest);
  if not MoveFileW(PWideChar(WideString(ADest)), PWideChar(WideString(Aside))) then
    Exit(AmsFailFmt('Datei gesperrt und nicht umbenennbar (%d/%d): %s',
                    [Err, GetLastError, ADest]));
  if not CopyFileW(PWideChar(WideString(ASrc)), PWideChar(WideString(ADest)),
                   False) then
  begin
    Err := GetLastError;
    MoveFileW(PWideChar(WideString(Aside)), PWideChar(WideString(ADest)));
    Exit(AmsFailFmt('Kopieren nach dem Umbenennen fehlgeschlagen (%d): %s',
                    [Err, ADest]));
  end;
  ARenamedTo := Aside;
  AmsLogFmt('Geladene Datei beiseite geschoben: %s -> %s', [ADest, Aside]);
  Result := True;
end;

function AmsRemoveFile(const AFile: string; out ARenamedTo: string): Boolean;
var
  Aside: string;
begin
  ARenamedTo := '';
  if not FileExists(AFile) then Exit(True);
  SetFileAttributesW(PWideChar(WideString(AFile)), FILE_ATTRIBUTE_NORMAL);
  if DeleteFileW(PWideChar(WideString(AFile))) then Exit(True);
  Aside := AsideName(AFile);
  if not MoveFileW(PWideChar(WideString(AFile)), PWideChar(WideString(Aside))) then
    Exit(AmsFailFmt('Datei weder loeschbar noch umbenennbar (%d): %s',
                    [GetLastError, AFile]));
  { Beim naechsten Neustart von Windows endgueltig weg - klappt nur mit
    Administratorrechten, schadet sonst nicht. }
  MoveFileExW(PWideChar(WideString(Aside)), nil, MOVEFILE_DELAY_UNTIL_REBOOT);
  ARenamedTo := Aside;
  Result := True;
end;

function AmsCleanupOld(const ADir: string): Integer;
var
  L: TStringList;
  i: Integer;
  D: string;
begin
  Result := 0;
  D := IncludeTrailingPathDelimiter(ADir);
  if not DirectoryExists(D) then Exit;
  L := TStringList.Create;
  try
    AmsListFiles(D, L, True);
    for i := 0 to L.Count - 1 do
      if SameText(ExtractFileExt(L[i]), '.old') then
        if DeleteFileW(PWideChar(WideString(D + L[i]))) then Inc(Result);
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------- Namen ---- }

function AmsIsSafeName(const AName: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (AName = '') or (AName = '.') or (AName = '..') then Exit;
  if Length(AName) > 120 then Exit;
  for i := 1 to Length(AName) do
    if (AName[i] < ' ') or (Pos(AName[i], '\/:*?"<>|') > 0) then Exit;
  { "NAME." und " NAME" legt Windows anders an, als es heisst }
  if (AName[Length(AName)] = '.') or (AName[Length(AName)] = ' ') or
     (AName[1] = ' ') then Exit;
  Result := True;
end;

function AmsIsSafeRelPath(const APath: string): Boolean;
var
  S, Part: string;
  p: Integer;
begin
  Result := False;
  S := StringReplace(APath, '/', '\', [rfReplaceAll]);
  if S = '' then Exit;
  if (S[1] = '\') or (Pos(':', S) > 0) then Exit;
  while S <> '' do
  begin
    p := Pos('\', S);
    if p = 0 then
    begin
      Part := S;
      S := '';
    end
    else
    begin
      Part := Copy(S, 1, p - 1);
      Delete(S, 1, p);
    end;
    if Part = '..' then Exit;
  end;
  Result := True;
end;

finalization
  if gBcrypt <> 0 then FreeLibrary(gBcrypt);

end.
