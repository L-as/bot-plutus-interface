{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes #-}

module BotPlutusInterface.Contract (runContract, handleContract) where

import BotPlutusInterface.Balance qualified as PreBalance
import BotPlutusInterface.CardanoCLI qualified as CardanoCLI
import BotPlutusInterface.Effects (
  PABEffect,
  createDirectoryIfMissing,
  handlePABEffect,
  logToContract,
  printLog,
  queryChainIndex,
  threadDelay,
  uploadDir,
 )
import BotPlutusInterface.Files (DummyPrivKey (FromSKey, FromVKey))
import BotPlutusInterface.Files qualified as Files
import BotPlutusInterface.Types (ContractEnvironment (..), LogLevel (Debug, Warn), Tip (slot))
import Control.Lens ((^.))
import Control.Monad (void)
import Control.Monad.Freer (Eff, Member, interpret, reinterpret, runM, subsume, type (~>))
import Control.Monad.Freer.Error (runError)
import Control.Monad.Freer.Extras.Log (handleLogIgnore)
import Control.Monad.Freer.Extras.Modify (raiseEnd)
import Control.Monad.Freer.Writer (Writer (Tell))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Either (eitherT, firstEitherT, newEitherT, secondEitherT)
import Data.Aeson (ToJSON, Value)
import Data.Aeson.Extras (encodeByteString)
import Data.Kind (Type)
import Data.Map qualified as Map
import Data.Row (Row)
import Data.Text (Text)
import Data.Text qualified as Text
import Ledger (POSIXTime)
import Ledger qualified
import Ledger.Address (PaymentPubKeyHash (PaymentPubKeyHash))
import Ledger.Constraints.OffChain (UnbalancedTx (..))
import Ledger.Slot (Slot (Slot))
import Ledger.TimeSlot (posixTimeRangeToContainedSlotRange, posixTimeToEnclosingSlot, slotToEndPOSIXTime)
import Ledger.Tx (CardanoTx)
import Ledger.Tx qualified as Tx
import Plutus.ChainIndex.Types (RollbackState (Committed), TxValidity (..))
import Plutus.Contract.Checkpoint (Checkpoint (..))
import Plutus.Contract.Effects (
  BalanceTxResponse (..),
  PABReq (..),
  PABResp (..),
  WriteBalancedTxResponse (..),
 )
import Plutus.Contract.Resumable (Resumable (..))
import Plutus.Contract.Types (Contract (..), ContractEffs)
import PlutusTx.Builtins (fromBuiltin)
import Wallet.Emulator.Error (WalletAPIError (..))
import Prelude

runContract ::
  forall (w :: Type) (s :: Row Type) (e :: Type) (a :: Type).
  (ToJSON w, Monoid w) =>
  ContractEnvironment w ->
  Contract w s e a ->
  IO (Either e a)
runContract contractEnv (Contract effs) = do
  runM $ handlePABEffect @w contractEnv $ raiseEnd $ handleContract contractEnv effs

handleContract ::
  forall (w :: Type) (e :: Type) (a :: Type).
  (ToJSON w, Monoid w) =>
  ContractEnvironment w ->
  Eff (ContractEffs w e) a ->
  Eff '[PABEffect w] (Either e a)
handleContract contractEnv =
  subsume @(PABEffect w)
    . handleResumable contractEnv
    . handleCheckpointIgnore
    . handleWriter
    . handleLogIgnore @Value
    . runError
    . raiseEnd

handleWriter ::
  forall (w :: Type) (effs :: [Type -> Type]).
  (ToJSON w, Monoid w) =>
  (Member (PABEffect w) effs) =>
  Eff (Writer w ': effs)
    ~> Eff effs
handleWriter =
  interpret
    (\case Tell msg -> logToContract msg)

handleResumable ::
  forall (w :: Type) (effs :: [Type -> Type]).
  ContractEnvironment w ->
  Eff (Resumable PABResp PABReq ': effs) ~> Eff (PABEffect w ': effs)
handleResumable contractEnv =
  reinterpret
    ( \case
        RRequest o -> handlePABReq @w contractEnv o
        RSelect -> pure True
        RZero -> undefined
    )

-- | Mocking checkpoint calls
handleCheckpointIgnore :: forall (effs :: [Type -> Type]). Eff (Checkpoint ': effs) ~> Eff effs
handleCheckpointIgnore =
  interpret
    ( \case
        DoCheckpoint -> pure ()
        AllocateKey -> pure 1
        Store {} -> pure ()
        Retrieve {} -> pure (Right Nothing)
    )

{- | Interpreting contract monad into CLI calls and chain index requests
 A few of these effects are not handled, these just return some dummy result to make the
 type system happy
-}
handlePABReq ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  PABReq ->
  Eff effs PABResp
handlePABReq contractEnv req = do
  printLog @w Debug $ show req
  resp <- case req of
    ----------------------
    -- Handled requests --
    ----------------------
    OwnPaymentPublicKeyHashReq ->
      pure $ OwnPaymentPublicKeyHashResp $ PaymentPubKeyHash contractEnv.cePABConfig.pcOwnPubKeyHash
    OwnContractInstanceIdReq ->
      pure $ OwnContractInstanceIdResp (ceContractInstanceId contractEnv)
    ChainIndexQueryReq query ->
      ChainIndexQueryResp <$> queryChainIndex @w query
    BalanceTxReq unbalancedTx ->
      BalanceTxResp <$> balanceTx @w contractEnv unbalancedTx
    WriteBalancedTxReq tx ->
      WriteBalancedTxResp <$> writeBalancedTx @w contractEnv tx
    AwaitSlotReq s -> AwaitSlotResp <$> awaitSlot @w contractEnv s
    AwaitTimeReq t -> AwaitTimeResp <$> awaitTime @w contractEnv t
    CurrentSlotReq -> CurrentSlotResp <$> currentSlot @w contractEnv
    CurrentTimeReq -> CurrentTimeResp <$> currentTime @w contractEnv
    PosixTimeRangeToContainedSlotRangeReq posixTimeRange ->
      pure $
        PosixTimeRangeToContainedSlotRangeResp $
          Right $
            posixTimeRangeToContainedSlotRange contractEnv.cePABConfig.pcSlotConfig posixTimeRange
    ------------------------
    -- Unhandled requests --
    ------------------------
    -- AwaitTimeReq t -> pure $ AwaitTimeResp t
    -- AwaitUtxoSpentReq txOutRef -> pure $ AwaitUtxoSpentResp ChainIndexTx
    -- AwaitUtxoProducedReq Address -> pure $ AwaitUtxoProducedResp (NonEmpty ChainIndexTx)
    AwaitTxStatusChangeReq txId -> pure $ AwaitTxStatusChangeResp txId (Committed TxValid ())
    -- AwaitTxOutStatusChangeReq TxOutRef
    -- ExposeEndpointReq ActiveEndpoint -> ExposeEndpointResp EndpointDescription (EndpointValue JSON.Value)
    -- YieldUnbalancedTxReq UnbalancedTx
    unsupported -> error ("Unsupported PAB effect: " ++ show unsupported)

  printLog @w Debug $ show resp
  pure resp

-- | This will FULLY balance a transaction
balanceTx ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  UnbalancedTx ->
  Eff effs BalanceTxResponse
balanceTx contractEnv unbalancedTx = do
  let pabConf = contractEnv.cePABConfig
  uploadDir @w pabConf.pcSigningKeyFileDir
  eitherPreBalancedTx <-
    PreBalance.balanceTxIO @w
      pabConf
      pabConf.pcOwnPubKeyHash
      unbalancedTx

  pure $ either (BalanceTxFailed . InsufficientFunds) (BalanceTxSuccess . Right) eitherPreBalancedTx

-- | This step would build tx files, write them to disk and submit them to the chain
writeBalancedTx ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  CardanoTx ->
  Eff effs WriteBalancedTxResponse
writeBalancedTx _ (Left _) = error "Cannot handle cardano api tx"
writeBalancedTx contractEnv (Right tx) = do
  let pabConf = contractEnv.cePABConfig
  uploadDir @w pabConf.pcSigningKeyFileDir
  createDirectoryIfMissing @w False (Text.unpack pabConf.pcScriptFileDir)

  eitherT (pure . WriteBalancedTxFailed . OtherError) (pure . WriteBalancedTxSuccess . Right) $ do
    void $ firstEitherT (Text.pack . show) $ newEitherT $ Files.writeAll @w pabConf tx
    lift $ uploadDir @w pabConf.pcScriptFileDir

    privKeys <- newEitherT $ Files.readPrivateKeys @w pabConf

    let requiredSigners = Map.keys $ tx ^. Tx.signatures
        skeys = Map.filter (\case FromSKey _ -> True; FromVKey _ -> False) privKeys
        signable = all ((`Map.member` skeys) . Ledger.pubKeyHash) requiredSigners

    newEitherT $ CardanoCLI.buildTx @w pabConf privKeys tx

    if signable
      then newEitherT $ CardanoCLI.signTx @w pabConf tx requiredSigners
      else
        lift . printLog @w Warn . Text.unpack . Text.unlines $
          [ "Not all required signatures have signing key files. Please sign and submit the tx manually:"
          , "Tx file: " <> Files.txFilePath pabConf "raw" tx
          , "Signatories (pkh): " <> Text.unwords (map pkhToText requiredSigners)
          ]

    if not pabConf.pcDryRun && signable
      then secondEitherT (const tx) $ newEitherT $ CardanoCLI.submitTx @w pabConf tx
      else pure tx

pkhToText :: Ledger.PubKey -> Text
pkhToText = encodeByteString . fromBuiltin . Ledger.getPubKeyHash . Ledger.pubKeyHash

{- | Wait at least until the given slot. The slot number only changes when a new block is appended
 to the chain so it waits for at least one block
-}
awaitSlot ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  Slot ->
  Eff effs Slot
awaitSlot contractEnv s@(Slot n) = do
  threadDelay @w (fromIntegral contractEnv.cePABConfig.pcTipPollingInterval)
  tip <- CardanoCLI.queryTip @w contractEnv.cePABConfig
  case tip of
    Right tip'
      | n < tip'.slot -> pure $ Slot tip'.slot
    _ -> awaitSlot contractEnv s

{- | Wait at least until the given time. Uses the awaitSlot under the hood, so the same constraints
 are applying here as well.
-}
awaitTime ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  POSIXTime ->
  Eff effs POSIXTime
awaitTime ce = fmap fromSlot . awaitSlot ce . toSlot
  where
    toSlot = posixTimeToEnclosingSlot ce.cePABConfig.pcSlotConfig
    fromSlot = slotToEndPOSIXTime ce.cePABConfig.pcSlotConfig

currentSlot ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  Eff effs Slot
currentSlot contractEnv =
  Slot . slot . either (error . Text.unpack) id <$> CardanoCLI.queryTip @w contractEnv.cePABConfig

currentTime ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  ContractEnvironment w ->
  Eff effs POSIXTime
currentTime contractEnv =
  slotToEndPOSIXTime contractEnv.cePABConfig.pcSlotConfig <$> currentSlot @w contractEnv
