/// Main Process of the Command Line "mORMot GET" tool
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.tools.mget;


interface

{$I ..\..\mormot.defines.inc}

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.datetime,
  mormot.core.buffers,
  mormot.core.variants,
  mormot.core.rtti,
  mormot.core.json,
  mormot.core.log,
  mormot.core.data,
  mormot.crypt.secure,
  mormot.crypt.core,
  mormot.net.sock,
  mormot.net.client,
  mormot.net.server;


type
  TMGetProcessHash = (
    gphAutoDetect,
    gphMd5,
    gphSha1,
    gphSha256,
    gphSha384,
    gphSha512,
    gphSha3_256,
    gphSha3_512);

  /// state engine for mget processing
  // - just a wrapper around THttpClientSocket and THttpPeerCache
  // - published properties will be included as command line switches, using RTTI
  // - could be reused between the mget command line tool and an eventual GUI
  TMGetProcess = class(TPersistentAutoCreateFields)
  protected
    fPeerSettings: THttpPeerCacheSettings;
    fHashAlgo: TMGetProcessHash;
    fPeerRequest: TWGetAlternateOptions;
    fLimitBandwidthMB, fWholeRequestTimeoutSec: integer;
    fHeader, fHashValue: RawUtf8;
    fPeerSecret, fPeerSecretHexa: SpiUtf8;
    fClient: THttpClientSocket;
    fOnProgress: TOnStreamProgress;
    fOutSteps: TWGetSteps;
    fPeerCache: IWGetAlternate;
    function GetTcpTimeoutSec: integer;
    procedure SetTcpTimeoutSec(Seconds: integer);
  public
    // input parameters (e.g. from command line) for the MGet process
    Silent, NoResume, Cache, Peer, LogSteps, TrackNetwork: boolean;
    CacheFolder, DestFile: TFileName;
    Options: THttpRequestExtendedOptions;
    Log: TSynLogClass;
    ServerTls, ClientTls: TNetTlsContext;
    /// initialize this instance with the default values
    constructor Create; override;
    /// finalize this instance
    destructor Destroy; override;
    /// could be run once input parameters are set, before Execute() is called
    // - will launch THttpPeerCache background process, and re-create it if
    // the network layout did change (if TrackNetwork is true)
    // - do nothing if Peer is false, or if the THttpPeerCache instance is fine
    procedure StartPeerCache;
    /// this is the main processing method
    function Execute(const Url: RawUtf8): TFileName;
    /// write some message to the console, if Silent flag is false
    procedure ToConsole(const Fmt: RawUtf8; const Args: array of const);
    /// access to the associated THttpPeerCache instance
    // - a single peer-cache run in the background between Execute() calls
    property PeerCache: IWGetAlternate
      read fPeerCache;
    /// optional callback event called during download process
    property OnProgress: TOnStreamProgress
      read fOnProgress write fOnProgress;
    /// after Execute(), contains a set of all processed steps
    property OutSteps: TWGetSteps
      read fOutSteps;
  published
    /// the settings used if Peer is true
    property PeerSettings: THttpPeerCacheSettings
      read fPeerSettings write fPeerSettings;
    // following properties will be published as command line switches
    property customHttpHeader: RawUtf8
      read fHeader write fHeader;
    property proxyUri: RawUtf8
      read Options.Proxy write Options.Proxy;
    property redirectMax: integer
      read Options.RedirectMax write Options.RedirectMax;
    property hashAlgo: TMGetProcessHash
      read fHashAlgo write fHashAlgo;
    property hashValue: RawUtf8
      read fHashValue write fHashValue;
    property limitBandwidthMB: integer
      read fLimitBandwidthMB write fLimitBandwidthMB;
    property tcpTimeoutSec: integer
      read GetTcpTimeoutSec write SetTcpTimeoutSec;
    property wholeRequestTimeoutSec: integer
      read fWholeRequestTimeoutSec write fWholeRequestTimeoutSec;
    property peerSecret: SpiUtf8
      read fPeerSecret write fPeerSecret;
    property peerSecretHexa: SpiUtf8
      read fPeerSecretHexa write fPeerSecretHexa;
    property peerRequest: TWGetAlternateOptions
      read fPeerRequest write fPeerRequest;
  end;


implementation

const
  HASH_ALGO: array[gphMd5 .. high(TMGetProcessHash)] of THashAlgo = (
    hfMd5,
    hfSha1,
    hfSha256,
    hfSha384,
    hfSha512,
    hfSha3_256,
    hfSha3_512);

function GuessAlgo(const HashHexa: RawUtf8): TMGetProcessHash;
var
  l: integer;
begin
  l := length(HashHexa) shr 1; // from hexa to bytes
  for result := low(HASH_ALGO) to high(HASH_ALGO) do
    if HASH_SIZE[HASH_ALGO[result]] = l then
      exit; // detect first exact matching size (not SHA-3)
  result := gphAutoDetect;
end;


{ TMGetProcess }

function TMGetProcess.GetTcpTimeoutSec: integer;
begin
  result := Options.CreateTimeoutMS * 1000;
end;

procedure TMGetProcess.SetTcpTimeoutSec(Seconds: integer);
begin
  Options.CreateTimeoutMS := Seconds div 1000;
end;

constructor TMGetProcess.Create;
begin
  inherited Create;
  Options.RedirectMax := 5;
end;

procedure TMGetProcess.StartPeerCache;
var
  l: ISynLog;
begin
  if not Peer then
    exit;
  // first check if the network interface changed
  if fPeerCache <> nil then
    if TrackNetwork and
       fPeerCache.NetworkInterfaceChanged then
    begin
      l := Log.Enter(self, 'StartPeerCache: NetworkInterfaceChanged');
      fPeerCache := nil; // force re-create just below
    end;
  // (re)create the peer-cache background process if necessary
  if fPeerCache = nil then
  begin
    l := Log.Enter(self, 'StartPeerCache: THttpPeerCache.Create');
    if (fPeerSecret = '') and
       (fPeerSecretHexa <> '') then
      fPeerSecret := HexToBin(fPeerSecretHexa);
    try
      fPeerCache := THttpPeerCache.Create(fPeerSettings, fPeerSecret,
        nil, 2, self.Log, @ServerTls, @ClientTls);
      // THttpAsyncServer could also be tried with rfProgressiveStatic
    except
      // don't disable Peer: we would try on next Execute()
      on E: Exception do
        if Assigned(l) then
          l.Log(sllTrace,
            'StartPeerCache raised %: will retry next time', [E.ClassType]);
    end;
  end;
end;

function TMGetProcess.Execute(const Url: RawUtf8): TFileName;
var
  wget: THttpClientSocketWGet;
  u, h: RawUtf8;
  algo: TMGetProcessHash; // may change with next Url
  uri: TUri;
  l: ISynLog;
begin
  // prepare the process
  l := Log.Enter('Execute %', [Url], self);
  // (re)start background THttpPeerCache process if needed
  StartPeerCache;
  // identify e.g. 'xxxxxxxxxxxxxxxxxxxx@http://toto.com/res'
  if not Split(Url, '@', h, u) or
     (GuessAlgo(h) = gphAutoDetect) or
     (HexToBin(h) = '') then // ignore https://user:password@server:port/addr
  begin
    u := Url;
    h := hashValue;
  end;
  // guess the hash algorithm from its hexadecimal value size
  algo := hashAlgo;
  if algo = gphAutoDetect then
    if h <> '' then
      algo := GuessAlgo(h)
    else if Peer then
      algo := gphSha256;
  // set the WGet additional parameters
  fOutSteps := [];
  wget.Clear;
  wget.KeepAlive := 30000;
  wget.Resume := not NoResume;
  wget.Header := fHeader;
  wget.HashFromServer := (h = '') and
                         (algo <> gphAutoDetect);
  if Assigned(fOnProgress) then
    wget.OnProgress := fOnProgress;
  if LogSteps and
     (Log <> nil) then
    wget.LogSteps := Log.DoLog;
  if algo <> gphAutoDetect then
  begin
    wget.Hasher := HASH_STREAMREDIRECT[HASH_ALGO[algo]];
    wget.Hash := h;
    if not Silent then
      if not Assigned(wget.OnProgress) then
        wget.OnProgress := TStreamRedirect.ProgressStreamToConsole;
  end;
  wget.LimitBandwidth := fLimitBandwidthMB shl 20;
  wget.TimeOutSec := fWholeRequestTimeoutSec;
  // (peer) cache support
  if Cache then
    wget.HashCacheDir := EnsureDirectoryExists(CacheFolder);
  if Peer then
  begin
    wget.Alternate := fPeerCache; // reuse THttpPeerCache on background
    wget.AlternateOptions := fPeerRequest;
  end;
  // make the actual request
  result := '';
  if not uri.From(u) then
    exit;
  if fClient <> nil then
    if not fClient.SameOpenOptions(uri, Options) then // need a new connection
      FreeAndNil(fClient);
  if fClient = nil then  // if we can't reuse the existing connection
  begin
    fClient := THttpClientSocket.OpenOptions(uri, Options);
    if Log <> nil then
      fClient.OnLog := Log.DoLog;
  end;
  result := fClient.WGet(uri.Address, DestFile, wget);
  fOutSteps := wget.OutSteps;
  if Assigned(l) then
    l.Log(sllTrace, 'Execute: WGet=% [%]',
      [result, GetSetName(TypeInfo(TWGetSteps), fOutSteps, {trim=}true)], self);
end;

destructor TMGetProcess.Destroy;
begin
  inherited Destroy;
  fClient.Free;
  FillZero(fPeerSecret);
  FillZero(fPeerSecretHexa);
end;

procedure TMGetProcess.ToConsole(const Fmt: RawUtf8;
  const Args: array of const);
begin
  if not Silent then
    ConsoleWrite(Fmt, Args);
end;


initialization

end.
