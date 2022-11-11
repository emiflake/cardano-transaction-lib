-- | This module contains everything needed to run E2E tests.
module Ctl.Internal.Test.E2E.Runner
  ( runE2ECommand
  , runE2ETests
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Monad.Error.Class (liftMaybe)
import Control.Promise (Promise, toAffE)
import Ctl.Internal.Deserialization.Keys (privateKeyFromBytes)
import Ctl.Internal.Helpers (liftedM)
import Ctl.Internal.Plutip.Server (withPlutipContractEnv)
import Ctl.Internal.Plutip.Types (PlutipConfig)
import Ctl.Internal.Plutip.UtxoDistribution (withStakeKey)
import Ctl.Internal.QueryM (ClusterSetup, emptyHooks)
import Ctl.Internal.Test.E2E.Browser (withBrowser)
import Ctl.Internal.Test.E2E.Feedback
  ( BrowserEvent(ConfirmAccess, Sign, Success, Failure)
  )
import Ctl.Internal.Test.E2E.Feedback.Node
  ( setClusterSetup
  , subscribeToBrowserEvents
  )
import Ctl.Internal.Test.E2E.Options
  ( BrowserOptions
  , ClusterPortsOptions
  , E2ECommand(UnpackSettings, PackSettings, RunBrowser, RunE2ETests)
  , ExtensionOptions
  , SettingsOptions
  , TestOptions
  , defaultPorts
  )
import Ctl.Internal.Test.E2E.Types
  ( Browser
  , ChromeUserDataDir
  , E2ETest
  , E2ETestRuntime
  , E2EWallet(NoWallet, PlutipCluster, WalletExtension)
  , ExtensionParams
  , Extensions
  , RunningE2ETest
  , SettingsArchive
  , SettingsRuntime
  , TmpDir
  , WalletExt(FlintExt, NamiExt, GeroExt, LodeExt, EternlExt)
  , getE2EWalletExtension
  , mkE2ETest
  , mkExtensionId
  , unExtensionId
  )
import Ctl.Internal.Test.E2E.Wallets
  ( eternlConfirmAccess
  , eternlSign
  , flintConfirmAccess
  , flintSign
  , geroConfirmAccess
  , geroSign
  , lodeConfirmAccess
  , lodeSign
  , namiConfirmAccess
  , namiSign
  )
import Ctl.Internal.Test.TestPlanM (TestPlanM, interpretWithConfig)
import Ctl.Internal.Types.RawBytes (hexToRawBytes)
import Ctl.Internal.Wallet.Key
  ( PrivateStakeKey
  , keyWalletPrivatePaymentKey
  , keyWalletPrivateStakeKey
  )
import Data.Array (catMaybes, mapMaybe, nub)
import Data.Array as Array
import Data.BigInt as BigInt
import Data.Either (Either(Left, Right))
import Data.Foldable (fold)
import Data.Int as Int
import Data.List (intercalate)
import Data.Log.Level (LogLevel(Trace))
import Data.Map as Map
import Data.Maybe (Maybe(Just, Nothing), fromJust, fromMaybe, maybe)
import Data.Newtype (unwrap, wrap)
import Data.Posix.Signal (Signal(SIGINT))
import Data.String (Pattern(Pattern))
import Data.String (contains, null, split, toUpper, trim) as String
import Data.String.Utils (startsWith) as String
import Data.Time.Duration (Milliseconds(Milliseconds), Seconds(Seconds))
import Data.Traversable (for, for_)
import Data.Tuple (Tuple(Tuple))
import Data.UInt as UInt
import Effect (Effect)
import Effect.Aff (Aff, Canceler(Canceler), launchAff_, makeAff)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Exception (Error, error, throw)
import Effect.Ref as Ref
import Mote (group, test)
import Node.ChildProcess
  ( Exit(Normally, BySignal)
  , SpawnOptions
  , defaultExecOptions
  , defaultSpawnOptions
  , exec
  , kill
  , spawn
  , stdout
  )
import Node.ChildProcess as ChildProcess
import Node.Encoding as Encoding
import Node.FS.Aff (exists, stat)
import Node.FS.Stats (isDirectory)
import Node.Path (FilePath, concat, relative)
import Node.Process (lookupEnv)
import Node.Stream (onDataString)
import Partial.Unsafe (unsafePartial)
import Record.Builder (build, delete, merge)
import Test.Spec.Runner as SpecRunner
import Toppokki as Toppokki
import Type.Proxy (Proxy(Proxy))

-- | The entry point to the implementation of E2E tests.
runE2ECommand :: E2ECommand -> Aff Unit
runE2ECommand = case _ of
  RunE2ETests testOptions -> do
    runtime <- readTestRuntime testOptions
    tests <- liftEffect $ readTests testOptions.tests
    noHeadless <- liftEffect $ readNoHeadless testOptions.noHeadless
    testTimeout <- liftEffect $ readTestTimeout testOptions.testTimeout
    portOptions <- liftEffect $ readPorts testOptions
    let
      testOptions' = build (merge portOptions) $ testOptions
        { noHeadless = noHeadless, testTimeout = testTimeout, tests = tests }
    runE2ETests testOptions' runtime
  RunBrowser browserOptions -> do
    runtime <- readBrowserRuntime Nothing browserOptions
    runBrowser runtime.tmpDir runtime.chromeUserDataDir runtime.browser
      runtime.wallets
  PackSettings opts -> do
    rt <- readSettingsRuntime opts
    packSettings rt.settingsArchive rt.chromeUserDataDir
  UnpackSettings opts -> do
    rt <- readSettingsRuntime opts
    unpackSettings rt.settingsArchive rt.chromeUserDataDir

-- | Implements `run` command
runE2ETests :: TestOptions -> E2ETestRuntime -> Aff Unit
runE2ETests opts rt = do
  interpretWithConfig
    ( SpecRunner.defaultConfig
        { timeout = Milliseconds <<< mul 1000.0 <<< Int.toNumber <$>
            opts.testTimeout
        }
    )
    (testPlan opts rt)

buildPlutipConfig :: TestOptions -> PlutipConfig
buildPlutipConfig options =
  { host: "127.0.0.1"
  , port: fromMaybe (UInt.fromInt defaultPorts.plutip) options.plutipPort
  , logLevel: Trace
  , ogmiosConfig:
      { port: fromMaybe (UInt.fromInt defaultPorts.ogmios) options.ogmiosPort
      , host: "127.0.0.1"
      , secure: false
      , path: Nothing
      }
  , ogmiosDatumCacheConfig:
      { port: fromMaybe (UInt.fromInt defaultPorts.ogmiosDatumCache)
          options.ogmiosDatumCachePort
      , host: "127.0.0.1"
      , secure: false
      , path: Nothing
      }
  , ctlServerConfig: Just
      { port: fromMaybe (UInt.fromInt defaultPorts.ctlServer)
          options.ctlServerPort
      , host: "127.0.0.1"
      , secure: false
      , path: Nothing
      }
  , postgresConfig:
      { host: "127.0.0.1"
      , port: fromMaybe (UInt.fromInt 5438) options.postgresPort
      , user: "ctxlib"
      , password: "ctxlib"
      , dbname: "ctxlib"
      }
  , suppressLogs: true
  , customLogger: Just \_ _ -> pure unit
  , hooks: emptyHooks
  }

-- | Plutip does not generate private stake keys for us, so we make one and
-- | fund it manually to get a usable base address.
privateStakeKey :: PrivateStakeKey
privateStakeKey = wrap $ unsafePartial $ fromJust
  $ privateKeyFromBytes =<< hexToRawBytes
      "633b1c4c4a075a538d37e062c1ed0706d3f0a94b013708e8f5ab0a0ca1df163d"

-- | Constructs a test plan given an array of tests.
testPlan
  :: TestOptions
  -> E2ETestRuntime
  -> TestPlanM (Aff Unit) Unit
testPlan opts@{ tests } rt@{ wallets } =
  group "E2E tests" do
    for_ tests \testEntry@{ specString } -> test specString $ case testEntry of
      { url, wallet: NoWallet } -> do
        withBrowser opts.noHeadless rt Nothing \browser -> do
          withE2ETest (wrap url) browser \{ page } -> do
            subscribeToTestStatusUpdates page
      { url, wallet: PlutipCluster } -> do
        let
          distr = withStakeKey privateStakeKey
            [ BigInt.fromInt 2_000_000_000 * BigInt.fromInt 100
            , BigInt.fromInt 2_000_000_000 * BigInt.fromInt 100
            , BigInt.fromInt 2_000_000_000 * BigInt.fromInt 100
            , BigInt.fromInt 2_000_000_000 * BigInt.fromInt 100
            , BigInt.fromInt 2_000_000_000 * BigInt.fromInt 100
            ]
        -- TODO: don't connect to services in ContractEnv, just start them
        -- https://github.com/Plutonomicon/cardano-transaction-lib/issues/1197
        liftAff $ withPlutipContractEnv (buildPlutipConfig opts) distr
          \env wallet -> do
            let
              (clusterSetup :: ClusterSetup) =
                { ctlServerConfig: (unwrap env).config.ctlServerConfig
                , ogmiosConfig: (unwrap env).config.ogmiosConfig
                , datumCacheConfig: (unwrap env).config.datumCacheConfig
                , keys:
                    { payment: keyWalletPrivatePaymentKey wallet
                    , stake: keyWalletPrivateStakeKey wallet
                    }
                }
            withBrowser opts.noHeadless rt Nothing \browser -> do
              withE2ETest (wrap url) browser \{ page } -> do
                setClusterSetup page clusterSetup
                subscribeToTestStatusUpdates page
      { url, wallet: WalletExtension wallet } -> do
        { password, extensionId } <- liftEffect
          $ liftMaybe
              (error $ "Wallet was not provided: " <> walletName wallet)
          $ Map.lookup wallet wallets
        withBrowser opts.noHeadless rt (Just extensionId) \browser -> do
          withE2ETest (wrap url) browser \re@{ page } -> do
            let
              confirmAccess =
                case wallet of
                  EternlExt -> eternlConfirmAccess
                  FlintExt -> flintConfirmAccess
                  GeroExt -> geroConfirmAccess
                  LodeExt -> lodeConfirmAccess
                  NamiExt -> namiConfirmAccess
              sign =
                case wallet of
                  EternlExt -> eternlSign
                  FlintExt -> flintSign
                  GeroExt -> geroSign
                  LodeExt -> lodeSign
                  NamiExt -> namiSign
              someWallet =
                { wallet
                , name: walletName wallet
                , extensionId
                , confirmAccess: confirmAccess extensionId re
                , sign: sign extensionId password re
                }
            subscribeToBrowserEvents (Just $ Seconds 10.0) page
              case _ of
                ConfirmAccess -> launchAff_ someWallet.confirmAccess
                Sign -> launchAff_ someWallet.sign
                Success -> pure unit
                Failure err -> throw err
  where
  subscribeToTestStatusUpdates :: Toppokki.Page -> Aff Unit
  subscribeToTestStatusUpdates page =
    subscribeToBrowserEvents (Just $ Seconds 10.0) page
      case _ of
        Success -> pure unit
        Failure err -> throw err
        _ -> pure unit

-- | Implements `browser` command.
runBrowser
  :: TmpDir
  -> ChromeUserDataDir
  -> Browser
  -> Extensions
  -> Aff Unit
runBrowser tmpDir chromeUserDataDir browser extensions = do
  let
    extPath ext = tmpDir <> "/" <> unExtensionId ext.extensionId

    extensionsList :: String
    extensionsList = intercalate "," $ map extPath $ Map.values extensions
  void $ spawnAndCollectOutput browser
    [ "--load-extension=" <> extensionsList
    , "--user-data-dir=" <> chromeUserDataDir
    ]
    defaultSpawnOptions
    defaultErrorReader

readTestRuntime :: TestOptions -> Aff E2ETestRuntime
readTestRuntime testOptions = do
  let
    removeUnneeded =
      build
        ( delete (Proxy :: Proxy "noHeadless")
            <<< delete (Proxy :: Proxy "tests")
            <<< delete (Proxy :: Proxy "testTimeout")
            <<< delete (Proxy :: Proxy "plutipPort")
            <<< delete (Proxy :: Proxy "ogmiosPort")
            <<< delete (Proxy :: Proxy "ogmiosDatumCachePort")
            <<< delete (Proxy :: Proxy "ctlServerPort")
            <<< delete (Proxy :: Proxy "postgresPort")
        )
  readBrowserRuntime Nothing $ removeUnneeded testOptions

readPorts :: TestOptions -> Effect ClusterPortsOptions
readPorts testOptions = do
  plutipPort <-
    readPortNumber "PLUTIP" testOptions.plutipPort
  ogmiosPort <-
    readPortNumber "OGMIOS" testOptions.ogmiosPort
  ogmiosDatumCachePort <-
    readPortNumber "OGMIOS_DATUM_CACHE" testOptions.ogmiosDatumCachePort
  ctlServerPort <-
    readPortNumber "CTL_SERVER" testOptions.ctlServerPort
  postgresPort <-
    readPortNumber "POSTGRES" testOptions.postgresPort
  pure
    { plutipPort
    , ogmiosPort
    , ogmiosDatumCachePort
    , ctlServerPort
    , postgresPort
    }
  where
  readPortNumber varName Nothing = do
    str <- lookupEnv $ varName <> "_PORT"
    case UInt.fromString <$> str of
      Nothing -> pure Nothing
      Just Nothing -> throw $ varName <> "_PORT: must be a port number"
      Just (Just res)
        | res <= UInt.fromInt 65535 -> pure $ Just res
        | otherwise -> do
            throw $ varName
              <> "_PORT: port number must be in range 0-65535, got: "
              <> show (UInt.toInt res)
  readPortNumber _ res@(Just _) = pure res

-- | Read E2E test suite parameters from environment variables and CLI
-- | options. CLI options have higher priority.
readBrowserRuntime
  :: Maybe (Array E2ETest) -> BrowserOptions -> Aff E2ETestRuntime
readBrowserRuntime mbTests testOptions = do
  browser <- maybe findBrowser pure testOptions.browser
  tmpDir <- createTmpDir testOptions.tmpDir browser
  chromeUserDataDir <- maybe findChromeProfile pure
    testOptions.chromeUserDataDir
  ensureChromeUserDataDir chromeUserDataDir
  settingsArchive <- maybe (liftEffect findSettingsArchive) pure
    testOptions.settingsArchive
  nami <- liftEffect $ readExtensionParams "NAMI"
    (Map.lookup NamiExt testOptions.wallets)
  flint <- liftEffect $ readExtensionParams "FLINT"
    (Map.lookup FlintExt testOptions.wallets)
  gero <- liftEffect $ readExtensionParams "GERO"
    (Map.lookup GeroExt testOptions.wallets)
  lode <- liftEffect $ readExtensionParams "LODE"
    (Map.lookup LodeExt testOptions.wallets)
  eternl <- liftEffect $ readExtensionParams "ETERNL"
    (Map.lookup EternlExt testOptions.wallets)
  unpackSettings settingsArchive chromeUserDataDir
  let
    wallets = Map.fromFoldable $ catMaybes
      [ Tuple NamiExt <$> nami
      , Tuple FlintExt <$> flint
      , Tuple GeroExt <$> gero
      , Tuple LodeExt <$> lode
      , Tuple EternlExt <$> eternl
      ]
    runtime =
      { browser
      , wallets
      , chromeUserDataDir
      , tmpDir
      , settingsArchive
      }
  -- Must be executed before extractExtension call
  for_ (sanityCheck mbTests runtime) (throw >>> liftEffect)
  for_ wallets $ extractExtension tmpDir
  pure runtime

-- | Check that the provided set of options is valid in a given runtime.
sanityCheck :: Maybe (Array E2ETest) -> E2ETestRuntime -> Maybe String
sanityCheck mbTests { wallets } =
  case errors of
    [] -> Nothing
    _ -> Just $ Array.intercalate "\n" $ nub errors
  where
  errors = walletErrors <> testErrors <> walletIdDuplicateErrors
  testErrors
    | Just tests <- mbTests
    , Array.length tests == 0 =
        [ "No tests to run! Use E2E_TESTS or --test to specify some." ]
    | otherwise = []
  -- Check that all extension IDs are different
  walletIdDuplicateErrors =
    let
      allIds = Array.fromFoldable $ Map.values wallets <#> _.extensionId
      uniqIds = nub allIds
      diff = Array.difference allIds uniqIds
    in
      if Array.length allIds /= Array.length uniqIds then
        [ "Some of the provided extension IDs are duplicate: " <>
            (intercalate ", " $ diff <#> unExtensionId)
        ]
      else []
  -- check that all required wallet extensions are provided
  walletErrors
    | Just tests <- mbTests =
        tests `flip mapMaybe` \test ->
          getE2EWalletExtension test.wallet >>= \wallet ->
            case Map.lookup wallet wallets of
              Just _ -> Nothing
              Nothing ->
                let
                  name = walletName wallet
                  capName = String.toUpper name
                in
                  Just $ "Wallet " <> name
                    <> " was not provided! Please specify "
                    <> capName
                    <> "_CRX, "
                    <> capName
                    <> "_PASSWORD, "
                    <> capName
                    <> "_EXTID "
                    <> "or "
                    <> "--"
                    <> name
                    <> "-crx, "
                    <> "--"
                    <> name
                    <> "-password, "
                    <> "--"
                    <> name
                    <> "-extid"
    | otherwise = []

-- | Create ChromeUserDataDir if it does not exist
ensureChromeUserDataDir :: ChromeUserDataDir -> Aff Unit
ensureChromeUserDataDir chromeUserDataDir = do
  void $ spawnAndCollectOutput "mkdir" [ "-p", chromeUserDataDir ]
    defaultSpawnOptions
    defaultErrorReader
  void $ spawnAndCollectOutput "rm"
    [ "-f", chromeUserDataDir <> "/" <> "SingletonLock" ]
    defaultSpawnOptions
    defaultErrorReader

readTests :: Array E2ETest -> Effect (Array E2ETest)
readTests optUrls = do
  testSpecs <- lookupEnv "E2E_TESTS" <#> fold
    >>> String.split (Pattern "\n")
    >>> Array.filter \string ->
      not (eq "" $ String.trim string) &&
        not (String.startsWith "#") string
  tests <- for testSpecs \testSpec -> do
    liftMaybe (mkError testSpec) $ mkE2ETest testSpec
  pure $ nub $ optUrls <> tests
  where
  mkError testSpec =
    error $ "Failed to parse test data from: " <> testSpec <>
      "\nTest spec must be of form \"wallet:url\", where allowed wallets are: \
      \eternl, flint, gero, lode, nami."

-- | Run an example in a new browser page.
-- |
-- | Example usage:
-- |
-- | ```purescript
-- |   withBrowser options NamiExt \browser -> do
-- |     withE2ETest
-- |        (wrap "http://myserver:1234/docontract")
-- |        browser do
-- |          namiSign $ wrap "mypassword"
-- | ```
withE2ETest
  :: forall (a :: Type)
   . Toppokki.URL
  -> Toppokki.Browser
  -> (RunningE2ETest -> Aff a)
  -> Aff a
withE2ETest url browser action = do
  startExample url browser >>= action

-- | Navigate to an example's page, inject jQuery and set up error handlers
startExample :: Toppokki.URL -> Toppokki.Browser -> Aff RunningE2ETest
startExample url browser = do
  page <- Toppokki.newPage browser
  jQuery <- retrieveJQuery page
  Toppokki.goto url page
  pure { browser, jQuery, page }

-- | Download jQuery
retrieveJQuery :: Toppokki.Page -> Aff String
retrieveJQuery = toAffE <<< _retrieveJQuery

foreign import _retrieveJQuery :: Toppokki.Page -> Effect (Promise String)

readNoHeadless :: Boolean -> Effect Boolean
readNoHeadless true = pure true
readNoHeadless false = do
  mbStr <- lookupEnv "E2E_NO_HEADLESS"
  case mbStr of
    Nothing -> pure false
    Just str -> do
      liftMaybe (error $ "Failed to read E2E_NO_HEADLESS: " <> str) $
        readBoolean str
  where
  readBoolean = case _ of
    "true" -> Just true
    "false" -> Just false
    _ -> Nothing

readTestTimeout :: Maybe Int -> Effect (Maybe Int)
readTestTimeout r@(Just _) = pure r
readTestTimeout Nothing = do
  mbTimeoutStr <- lookupEnv "E2E_TEST_TIMEOUT"
  for mbTimeoutStr \timeoutStr -> do
    case Int.fromString timeoutStr of
      Nothing -> throw $ "Unable to decode E2E_TEST_TIMEOUT: " <> timeoutStr
      Just timeout -> pure timeout

readSettingsRuntime :: SettingsOptions -> Aff SettingsRuntime
readSettingsRuntime { chromeUserDataDir, settingsArchive } = do
  d <- maybe findChromeProfile pure chromeUserDataDir
  a <- maybe (liftEffect findSettingsArchive) pure settingsArchive
  pure { settingsArchive: a, chromeUserDataDir: d }

extractExtension :: TmpDir -> ExtensionParams -> Aff Unit
extractExtension tmpDir extension = do
  void $ spawnAndCollectOutput "unzip"
    [ extension.crx
    , "-d"
    , tmpDir <> "/" <> unExtensionId extension.extensionId
    ]
    defaultSpawnOptions
    errorReader
  where
  errorReader = case _ of
    Normally 0 -> Nothing
    Normally 1 -> Nothing
    Normally code -> Just $ "(code: " <> show code <> ")"
    BySignal signal -> Just $ show signal

findSettingsArchive :: Effect SettingsArchive
findSettingsArchive =
  liftedM
    ( error
        "Unable to find settings archive (specify E2E_SETTINGS_ARCHIVE or --settings-archive)"
    ) $ lookupEnv "E2E_SETTINGS_ARCHIVE"

findChromeProfile :: Aff ChromeUserDataDir
findChromeProfile = do
  chromeUserDataDir <- liftedM (error "Unable to get E2E_CHROME_USER_DATA")
    $ liftEffect
    $ lookupEnv "E2E_CHROME_USER_DATA"
  doesExist <- exists chromeUserDataDir
  unless doesExist do
    ensureChromeUserDataDir chromeUserDataDir
  isDir <- isDirectory <$> stat chromeUserDataDir
  unless isDir do
    liftEffect $ throw $ chromeUserDataDir <>
      " is not a directory (E2E_CHROME_USER_DATA)"
  pure chromeUserDataDir

findBrowser :: Aff Browser
findBrowser =
  liftEffect (lookupEnv "E2E_BROWSER") >>=
    maybe tryBrowserBinaries pure
  where
  tryBrowserBinaries = do
    res <- execAndCollectOutput "which chromium google-chrome | head -n1"
    when (res == "") do
      liftEffect $ throw $
        "Unable to find chromium or google-chrome binaries. Set E2E_BROWSER environment variable manually"
    pure res

readExtensionParams
  :: String -> Maybe ExtensionOptions -> Effect (Maybe ExtensionParams)
readExtensionParams extensionName mbCliOptions = do
  crxFile <- lookupEnv $ extensionName <> "_CRX"
  password <- lookupEnv (extensionName <> "_PASSWORD")
  mbExtensionIdStr <- lookupEnv (extensionName <> "_EXTID")
  extensionId <- for mbExtensionIdStr \str ->
    liftMaybe (error $ mkExtIdError str) $ mkExtensionId str
  let
    envOptions :: ExtensionOptions
    envOptions = { crxFile, password, extensionId }

    mergedOptions :: ExtensionOptions
    mergedOptions = case mbCliOptions of
      Nothing -> envOptions
      Just cliOptions -> mergeExtensionOptions cliOptions envOptions
  toExtensionParams mergedOptions
  where
  mergeExtensionOptions
    :: ExtensionOptions -> ExtensionOptions -> ExtensionOptions
  mergeExtensionOptions a b =
    { crxFile: a.crxFile <|> b.crxFile
    , password: a.password <|> b.password
    , extensionId: a.extensionId <|> b.extensionId
    }

  toExtensionParams :: ExtensionOptions -> Effect (Maybe ExtensionParams)
  toExtensionParams { crxFile, password, extensionId } =
    case crxFile, password, extensionId of
      Nothing, Nothing, Nothing -> pure Nothing
      Just crx, Just pwd, Just extId -> pure $ Just
        { crx, password: pwd, extensionId: extId }
      _, _, _ -> throw $ "Please ensure that either none or all of"
        <> extensionName
        <> "_CRX, "
        <> extensionName
        <> "_PASSWORD and "
        <> extensionName
        <> "_EXTID are provided"
  mkExtIdError str =
    "Unable to parse extension ID. must be a string consisting of 32 characters\
    \, got: " <> str

-- | Pack user data directory to an archive
packSettings :: SettingsArchive -> ChromeUserDataDir -> Aff Unit
packSettings settingsArchive userDataDir = do
  -- Passing a non-existent directory to tar will error,
  -- but we can't rely on the existence of these directories.
  paths <- filterExistingPaths userDataDir
    [ "./Default/IndexedDB/"
    , "./Default/Local Storage/"
    , "./Default/Extension State"
    , "./Default/Local Extension Settings"
    ]
  case paths of
    [] -> do
      -- Create an empty tar.gz
      void $ spawnAndCollectOutput "tar"
        [ "czf"
        , relative userDataDir settingsArchive
        , "-T"
        , "/dev/null"
        ]
        defaultSpawnOptions { cwd = Just userDataDir }
        defaultErrorReader
    _ -> do
      void $ spawnAndCollectOutput "tar"
        ( [ "czf"
          , relative userDataDir settingsArchive
          ] <> paths
        )
        defaultSpawnOptions { cwd = Just userDataDir }
        defaultErrorReader

-- | Filter out non-existing paths, relative to the given directory
filterExistingPaths :: FilePath -> Array FilePath -> Aff (Array FilePath)
filterExistingPaths base paths = do
  catMaybes <$> for paths \path -> do
    exists (concat [ base, path ]) >>= case _ of
      false -> pure Nothing
      true -> pure $ Just path

-- | Unpack settings archive to user data directory
unpackSettings :: SettingsArchive -> ChromeUserDataDir -> Aff Unit
unpackSettings settingsArchive userDataDir = do
  void $ spawnAndCollectOutput "tar"
    [ "xzf"
    , relative userDataDir settingsArchive
    ]
    defaultSpawnOptions { cwd = Just userDataDir }
    defaultErrorReader

-- | Find a suitable temp directory for E2E tests. Apps installed with `snap`
-- | don't work in $E2E_TMPDIR, because of lacking read access.
createTmpDir :: Maybe TmpDir -> Browser -> Aff TmpDir
createTmpDir mbOptionsTmpDir browser = do
  mbTmpDir <- maybe (liftEffect $ lookupEnv "E2E_TMPDIR") (pure <<< Just)
    mbOptionsTmpDir
  for_ mbTmpDir ensureExists
  maybe createNew createNewSubdir mbTmpDir
  where
  ensureExists dir =
    dir <$ spawnAndCollectOutput "mkdir" [ "-p", dir ] defaultSpawnOptions
      defaultErrorReader
  createNewSubdir prefix = do
    uniqPart <- execAndCollectOutput "mktemp -du e2e.XXXXXXX"
    void $ spawnAndCollectOutput "mkdir" [ "-p", prefix <> "/" <> uniqPart ]
      defaultSpawnOptions
      defaultErrorReader
    pure $ prefix <> "/" <> uniqPart
  createNew = do
    realPath <- spawnAndCollectOutput "which" [ browser ]
      defaultSpawnOptions
      defaultErrorReader
    let
      isBrowserFromSnap = String.contains (Pattern "/snap") realPath
    uniqPart <- execAndCollectOutput "mktemp -du e2e.XXXXXXX"
    if isBrowserFromSnap then do
      liftEffect $ throw $
        "Your browser is installed from Snap store: " <> realPath
          <> ". Because of that it can't access the temporary directory. Please"
          <> " provide E2E_TMPDIR variable or use --tmp-dir CLI argument"
    else do
      prefix <- execAndCollectOutput "mktemp -d"
      void $ execAndCollectOutput $ "mkdir -p " <> prefix <> "/" <> uniqPart
      pure $ prefix <> "/" <> uniqPart

execAndCollectOutput_
  :: String
  -> (Either Error String -> Effect Unit)
  -> Effect Canceler
execAndCollectOutput_ shellCmd cont = do
  child <- exec shellCmd defaultExecOptions (const $ pure unit)
  ref <- Ref.new ""
  ChildProcess.onExit child case _ of
    Normally 0 -> Ref.read ref >>= String.trim >>> Right >>> cont
    exitStatus -> do
      output <- Ref.read ref
      cont $ Left
        ( error $ "Command failed: " <> shellCmd <> " (" <> show exitStatus
            <> ")."
            <>
              if String.null output then ""
              else " Output collected so far: " <> output
        )
  onDataString (stdout child) Encoding.UTF8
    \str -> do
      void $ Ref.modify (_ <> str) ref
  pure $ Canceler $ const $ liftEffect $ kill SIGINT child

-- | Run a shell command and collect the output.
execAndCollectOutput :: String -> Aff String
execAndCollectOutput cmd = makeAff (execAndCollectOutput_ cmd)

spawnAndCollectOutput_
  :: String
  -> Array String
  -> SpawnOptions
  -> (Exit -> Maybe String)
  -> (Either Error String -> Effect Unit)
  -> Effect Canceler
spawnAndCollectOutput_ cmd args opts errorReader cont = do
  child <- spawn cmd args opts
  ref <- Ref.new ""
  ChildProcess.onExit child $ errorReader >>> case _ of
    Nothing -> do
      cont <<< Right <<< String.trim =<< Ref.read ref
    Just errorStr -> do
      output <- Ref.read ref
      cont $ Left $ error $
        "Process `" <> cmd <> " " <> intercalate " " args
          <> "` exited with non-zero status ("
          <> errorStr
          <> ")."
          <>
            if String.null output then ""
            else " Output collected so far: " <> output
  onDataString (stdout child) Encoding.UTF8
    \str -> do
      void $ Ref.modify (_ <> str) ref
  pure $ Canceler $ const $ liftEffect $ kill SIGINT child

-- | Spawn a command with CLI parameters. The last arguments allows to treat
-- | various non-zero exit-codes as a norm (and avoid throwing an error).
spawnAndCollectOutput
  :: String
  -> Array String
  -> SpawnOptions
  -> (Exit -> Maybe String)
  -> Aff String
spawnAndCollectOutput cmd args opts errorReader = makeAff
  (spawnAndCollectOutput_ cmd args opts errorReader)

defaultErrorReader :: Exit -> Maybe String
defaultErrorReader =
  case _ of
    Normally 0 -> Nothing
    exitStatus -> Just $ show exitStatus

walletName :: WalletExt -> String
walletName = case _ of
  EternlExt -> "eternl"
  FlintExt -> "flint"
  GeroExt -> "gero"
  LodeExt -> "lode"
  NamiExt -> "nami"
