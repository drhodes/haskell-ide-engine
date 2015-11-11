{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
-- | Experimenting with a data structure to define a plugin.
--
-- The general idea is that a given plugin returns this structure during the
-- initial load/registration process, when- or however this eventually happens.
--
-- It should define the following things
--  1. What features the plugin should expose into the IDE
--  2. What resources it requires access to in order to do this
--       (this one may not be needed initially)
--
--       This may include a requirement to store private data of a particular
--       form.
--
--       It may be interesting to look at the Android model wrt Intents and
--       shared resource management, e.g. default Calendar app, default SMS app,
--       all making use of Contacts service.

module Haskell.Ide.Engine.PluginDescriptor where

import           Control.Applicative
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.Aeson.Types
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified GHC
import           GHC.Generics

-- ---------------------------------------------------------------------

data PluginDescriptor = PluginDescriptor
  { pdCommands        :: [Command]
  , pdExposedServices :: [Service]
  , pdUsedServices    :: [Service]
  } deriving (Show)


-- |Ideally a Command is defined in such a way that it can be exposed via the
-- native CLI for the tool being exposed as well. Perhaps use
-- Options.Applicative for this in some way.
data Command = Command
  { cmdDesc :: !CommandDescriptor
  , cmdFunc :: !CommandFunc
  }

instance Show Command where
  show (Command desc _func) = "(Command " ++ show desc ++ ")"

-- |Descriptor for a command. This is intended to be transferred to the IDE, so
-- the IDE can integrate it into it's UI, and then send requests through to HIE.
data CommandDescriptor = CommandDesc
  { cmdName :: !CommandName -- ^As returned in the 'IdeRequest'
  , cmdUiDescription :: !T.Text -- ^ Can be presented to the IDE user
  , cmdFileExtensions :: ![T.Text] -- ^ File extensions this command can be applied to
  , cmdContexts :: ![AcceptedContext] -- TODO: should this be a non empty list? or should empty list imply CtxNone.
  , cmdAdditionalParams :: ![ParamDecription]
  } deriving (Show,Generic)

type CommandName = T.Text

-- |Define what context will be accepted from the frontend for the specific
-- command. Matches up to corresponding values for CommandContext
data AcceptedContext = CtxNone        -- ^ No context required, global command
                     | CtxFile        -- ^ Works on a whole file
                     | CtxPoint       -- ^ A single (Line,Col) in a specific file
                     | CtxRegion      -- ^ A region within a specific file
                     | CtxCabalTarget -- ^ Works on a specific cabal target
                     | CtxProject     -- ^ Works on a the whole project
                     deriving (Eq,Show,Generic)

type Pos = (Int,Int)

-- |It will simplify things to always work with an absolute file path
type AbsFilePath = FilePath

data CabalSection = CabalSection T.Text deriving (Show,Eq,Generic)

-- |Initially all params will be returned as text. This can become a much
-- richer structure in time.
-- These should map down to the 'ParamVal' return types
data ParamDecription
  = RP
      { pName :: !ParamName
      , pHelp :: !ParamHelp
      , pType :: !ParamType
      } -- ^ Required parameter
  | OP
      { pName :: !ParamName
      , pHelp :: !ParamHelp
      , pType :: !ParamType
      } -- ^ Optional parameter
  deriving (Show,Generic)

type ParamHelp = T.Text
type ParamName = T.Text
data ParamType = PtText | PtFile | PtPos
               deriving (Eq,Show)

data Service = Service
  { svcName :: T.Text
  -- , svcXXX :: undefined
  } deriving (Show)

type PluginId = T.Text

type Plugins = Map.Map PluginId PluginDescriptor

-- ---------------------------------------------------------------------

-- |For a given 'AcceptedContext', define the parameters that are required in
-- the corresponding 'IdeRequest'
contextMapping :: AcceptedContext -> [ParamDecription]
contextMapping CtxNone        = []
contextMapping CtxFile        = [fileParam]
contextMapping CtxPoint       = [fileParam,startPosParam]
contextMapping CtxRegion      = [fileParam,startPosParam,endPosParam]
contextMapping CtxCabalTarget = [cabalParam]
contextMapping CtxProject     = []

fileParam :: ParamDecription
fileParam = RP "file" "a file name" PtFile

startPosParam :: ParamDecription
startPosParam = RP "start_pos" "start line and col" PtPos

endPosParam :: ParamDecription
endPosParam = RP "end_pos" "end line and col" PtPos

cabalParam :: ParamDecription
cabalParam = RP "cabal" "cabal target" PtText

-- ---------------------------------------------------------------------

-- |A request from the IDE to HIE. When a context is specified, the following
-- parameter names must be used.
--
--  cabal     - for the cabal target
--  file      - for the file name
--  start_pos - for the first position
--  end_pos   - for the second position
--
-- These will be checked by the dispatcher.
data IdeRequest = IdeRequest
  { ideCommand :: !CommandName
  , ideParams  :: !ParamMap
  } deriving (Show)

deriving instance Show (MyParamId t)
deriving instance Show (ParamVal t)
deriving instance Show ParamValP

deriving instance Eq (ParamVal t)
instance Eq ParamValP where
  (ParamValP (ParamText t)) == (ParamValP (ParamText t')) = t == t'
  (ParamValP (ParamFile f)) == (ParamValP (ParamFile f')) = f == f'
  (ParamValP (ParamPos p)) == (ParamValP (ParamPos p')) = p == p'
  _ == _ = False
                                 
type ParamMap = Map.Map ParamId ParamValP

type ParamId = T.Text

data MyParamId (t :: ParamType) where
  IdText :: T.Text -> MyParamId 'PtText
  IdFile :: T.Text -> MyParamId 'PtFile
  IdPos :: T.Text -> MyParamId 'PtPos

data ParamValP = forall t. ParamValP { unParamValP ::  ParamVal t }

data ParamVal (t :: ParamType) where
  ParamText :: T.Text -> ParamVal 'PtText
  ParamFile :: T.Text -> ParamVal 'PtFile
  ParamPos :: (Int,Int) -> ParamVal 'PtPos

data Rec :: (k -> *) -> [k] -> * where
  RNil :: Rec f '[]
  (:&) :: f t -> Rec f ts -> Rec f (t ': ts)

infixr 5 :&

-- TODO: should probably be able to return a plugin-specific type. Not sure how
-- to encode it. Perhaps as an instance of a class which says it can be encoded
-- on the wire.
data IdeResponse = IdeResponseOk    Value -- ^ Command Succeeded
                 | IdeResponseFail  Value -- ^ Command Failed
                 | IdeResponseError Value -- ^ some error in haskell-ide-engine
                                          -- driver. Equivalent to HTTP 500
                                          -- status
                 deriving (Show,Generic)

class (Monad m) => HasIdeState m where
  getPlugins :: m Plugins
  -- | Set up an underlying GHC session for the specific targets. Should map
  -- down to ghc-mod setTargets.
  setTargets :: [FilePath] -> m ()

-- |The 'CommandFunc' is called once the dispatcher has checked that it
-- satisfies at least one of the `AcceptedContext` values for the command
-- descriptor, and has all the required parameters. Where a command has only one
-- allowed context the supplied context list does not add much value, but allows
-- easy case checking when multiple contexts are supported.
type CommandFunc = forall m. (MonadIO m,GHC.GhcMonad m,HasIdeState m)
                => [AcceptedContext] -> IdeRequest -> m IdeResponse

-- ---------------------------------------------------------------------
-- JSON instances

instance ToJSON ParamValP  where
    toJSON (ParamValP (ParamText v)) = object [ "tag" .= String "text"
                                  , "contents" .= toJSON v ]
    toJSON (ParamValP (ParamFile v)) = object [ "tag" .= String "file"
                                  , "contents" .= toJSON v ]
    toJSON (ParamValP (ParamPos  v)) = object [ "tag" .= String "pos"
                                  , "contents" .= toJSON v ]

instance FromJSON ParamValP where
    parseJSON (Object v) = do
      tag <- v .: "tag" :: Parser T.Text
      case tag of
        "text" -> (ParamValP . ParamText) <$> v .: "contents"
        "file" -> (ParamValP . ParamFile) <$> v .: "contents"
        "pos"  -> (ParamValP . ParamPos) <$> v .: "contents"
        _ -> empty
    parseJSON _ = empty

-- -------------------------------------

instance ToJSON CabalSection where
    toJSON (CabalSection s) = toJSON s

instance FromJSON CabalSection where
    parseJSON (String s) = pure $ CabalSection s
    parseJSON _ = empty

-- -------------------------------------

instance ToJSON AcceptedContext where
    toJSON CtxNone = String "none"
    toJSON CtxPoint = String "point"
    toJSON CtxRegion = String "region"
    toJSON CtxFile = String "file"
    toJSON CtxCabalTarget = String "cabal_target"
    toJSON CtxProject = String "project"

instance FromJSON AcceptedContext where
    parseJSON (String "none") = pure CtxNone
    parseJSON (String "point") = pure CtxPoint
    parseJSON (String "region") = pure CtxRegion
    parseJSON (String "file") = pure CtxFile
    parseJSON (String "cabal_target") = pure CtxCabalTarget
    parseJSON (String "project") = pure CtxProject
    parseJSON _ = empty

-- -------------------------------------

instance ToJSON ParamType where
  toJSON PtText = String "text"
  toJSON PtFile = String "file"
  toJSON PtPos  = String "pos"

instance FromJSON ParamType where
  parseJSON (String "text") = pure PtText
  parseJSON (String "file") = pure PtFile
  parseJSON (String "pos")  = pure PtPos
  parseJSON _               = empty

-- -------------------------------------

instance ToJSON ParamDecription where
    toJSON (RP n h t) = object [ "tag" .= String "rp"
                               , "contents" .= toJSON (n,h,t) ]
    toJSON (OP n h t) = object [ "tag" .= String "op"
                               , "contents" .= toJSON (n,h,t) ]

instance FromJSON ParamDecription where
    parseJSON (Object v) = do
      tag <- v .: "tag" :: Parser T.Text
      (n,h,t) <- v .: "contents"
      case tag of
        "rp" -> return $ RP n h t
        "op" -> return $ OP n h t
        _ -> empty
    parseJSON _ = empty

-- -------------------------------------

instance ToJSON CommandDescriptor where
    toJSON cmdDescriptor = object [ "name" .= cmdName cmdDescriptor
                                  , "ui_description" .= cmdUiDescription cmdDescriptor
                                  , "file_extensions" .= cmdFileExtensions cmdDescriptor
                                  , "contexts" .= cmdContexts cmdDescriptor
                                  , "additional_params" .= cmdAdditionalParams cmdDescriptor ]

instance FromJSON CommandDescriptor where
    parseJSON (Object v) =
      CommandDesc <$> v .: "name"
                  <*> v .: "ui_description"
                  <*> v .: "file_extensions"
                  <*> v .: "contexts"
                  <*> v .: "additional_params"
    parseJSON _ = empty

-- -------------------------------------

instance ToJSON IdeRequest where
  toJSON (IdeRequest{ideCommand = command, ideParams = params}) =
    object [ "command" .= command
           , "params" .= params]

instance FromJSON IdeRequest where
    parseJSON (Object v) =
      IdeRequest <$> v .: "command"
                 <*> v .: "params"
    parseJSON _ = empty

-- -------------------------------------

instance ToJSON IdeResponse where
    toJSON (IdeResponseOk v) = object [ "tag" .= String "ok"
                                      , "contents" .= toJSON v ]
    toJSON (IdeResponseFail v) = object [ "tag" .= String "fail"
                                        , "contents" .= toJSON v ]
    toJSON (IdeResponseError v) = object [ "tag" .= String "error"
                                         , "contents" .= toJSON v ]

instance FromJSON IdeResponse where
    parseJSON (Object v) = do
      tag <- v .: "tag" :: Parser T.Text
      case tag of
        "ok" -> IdeResponseOk <$> v .: "contents"
        "fail" -> IdeResponseFail <$> v .: "contents"
        "error" -> IdeResponseError <$> v .: "contents"
        _ -> empty
    parseJSON _ = empty

-- EOF
