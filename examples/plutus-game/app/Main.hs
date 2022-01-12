{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Cardano.Api (NetworkId (Testnet), NetworkMagic (..))
import Cardano.PlutusExample.Game (
  GameSchema,
  GuessParams,
  LockParams,
  guess,
  lock,
 )
import Data.Aeson qualified as JSON
import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.ByteString.Lazy qualified as LazyByteString
import MLabsPAB qualified
import MLabsPAB.Types (
  CLILocation (Local),
  HasDefinitions (..),
  LogLevel (Debug),
  PABConfig (..),
  SomeBuiltin (..),
  endpointsToSchemas,
 )
import Playground.Types (FunctionSchema)
import Schema (FormSchema)
import Servant.Client.Core (BaseUrl (BaseUrl), Scheme (Http))
import Prelude

instance HasDefinitions GameContracts where
  getDefinitions :: [GameContracts]
  getDefinitions = []

  getSchema :: GameContracts -> [FunctionSchema FormSchema]
  getSchema _ = endpointsToSchemas @GameSchema

  getContract :: (GameContracts -> SomeBuiltin)
  getContract = \case
    Lock params -> SomeBuiltin $ lock params
    Guess params -> SomeBuiltin $ guess params

data GameContracts = Lock LockParams | Guess GuessParams
  deriving stock (Show)

$(deriveJSON defaultOptions ''GameContracts)

main :: IO ()
main = do
  protocolParams <- JSON.decode <$> LazyByteString.readFile "protocol.json"
  let pabConf =
        PABConfig
          { pcCliLocation = Local
          , pcNetwork = Testnet (NetworkMagic 1097911063)
          , pcChainIndexUrl = BaseUrl Http "localhost" 9083 ""
          , pcPort = 9080
          , pcProtocolParams = protocolParams
          , pcOwnPubKeyHash = "0f45aaf1b2959db6e5ff94dbb1f823bf257680c3c723ac2d49f97546"
          , pcScriptFileDir = "./scripts"
          , pcSigningKeyFileDir = "./signing-keys"
          , pcTxFileDir = "./txs"
          , pcDryRun = True
          , pcLogLevel = Debug
          , pcProtocolParamsFile = "./protocol.json"
          }
  MLabsPAB.runPAB @GameContracts pabConf