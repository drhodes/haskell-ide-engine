{-# LANGUAGE CPP #-}
module TestUtils
  (
    testOptions
  , cdAndDo
  , withTestLogging
  , withFileLogging
  , setupStackFiles
  ) where

import           Control.Exception
import           Control.Monad
import qualified GhcMod.Monad as GM
import qualified GhcMod.Types as GM
import qualified Language.Haskell.LSP.Core as Core
import           System.Directory
import qualified System.Log.Logger as L


-- ---------------------------------------------------------------------

testOptions :: GM.Options
testOptions = GM.defaultOptions {
    GM.optOutput     = GM.OutputOpts {
      GM.ooptLogLevel       = GM.GmError
      -- GM.ooptLogLevel       = GM.GmVomit
    , GM.ooptStyle          = GM.PlainStyle
    , GM.ooptLineSeparator  = GM.LineSeparator "\0"
    , GM.ooptLinePrefix     = Nothing
    }

    }

cdAndDo :: FilePath -> IO a -> IO a
cdAndDo path fn = do
  old <- getCurrentDirectory
  r <- bracket (setCurrentDirectory path) (\_ -> setCurrentDirectory old)
          $ \_ -> fn
  return r

withTestLogging :: IO a -> IO a
withTestLogging = withFileLogging "./test-main.log"


withFileLogging :: FilePath -> IO a -> IO a
withFileLogging filePath f = do
  Core.setupLogger (Just filePath) ["hie"] L.DEBUG
  f

-- ---------------------------------------------------------------------

setupStackFiles :: IO ()
setupStackFiles =
  forM_ files $ \f -> do
    writeFile (f ++ "stack.yaml") stackFileContents
    removePathForcibly (f ++ ".stack-work")

-- ---------------------------------------------------------------------

files :: [FilePath]
files =
  [  "./test/testdata/"
   , "./test/testdata/gototest/"
  ]

-- |Choose a resolver based on the current compiler, otherwise HaRe/ghc-mod will
-- not be able to load the files
resolver :: String
resolver =
#if __GLASGOW_HASKELL__ >= 802
  "resolver: nightly-2017-09-10"
#else
  "resolver: nightly-2017-06-16"
#endif

-- ---------------------------------------------------------------------

stackFileContents :: String
stackFileContents = unlines
  [ "# WARNING: THIS FILE IS AUTOGENERATED IN test/Main.hs. IT WILL BE OVERWRITTEN ON EVERY TEST RUN"
  , resolver
  , "packages:"
  , "- '.'"
  , "extra-deps: []"
  , "flags: {}"
  , "extra-package-dbs: []"
  ]
-- ---------------------------------------------------------------------
