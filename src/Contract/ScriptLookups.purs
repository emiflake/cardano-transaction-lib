-- | A module for creating off-chain script lookups, and an unbalanced
-- | transaction.
module Contract.ScriptLookups
  ( mkUnbalancedTx
  , mkUnbalancedTxM
  , module X
  ) where

import Prelude

import Contract.Monad (Contract)
import Ctl.Internal.IsData (class IsData)
import Ctl.Internal.ProcessConstraints (mkUnbalancedTxImpl) as PC
import Ctl.Internal.ProcessConstraints.Error
  ( MkUnbalancedTxError
  )
import Ctl.Internal.ProcessConstraints.Error
  ( MkUnbalancedTxError
      ( CannotConvertPaymentPubKeyHash
      , CannotFindDatum
      , CannotQueryDatum
      , CannotConvertPOSIXTimeRange
      , CannotSolveTimeConstraints
      , CannotGetMintingPolicyScriptIndex
      , CannotGetValidatorHashFromAddress
      , CannotHashDatum
      , CannotHashMintingPolicy
      , CannotHashValidator
      , CannotMakeValue
      , CannotWithdrawRewardsPubKey
      , CannotWithdrawRewardsPlutusScript
      , CannotWithdrawRewardsNativeScript
      , DatumNotFound
      , DatumWrongHash
      , MintingPolicyHashNotCurrencySymbol
      , MintingPolicyNotFound
      , ModifyTx
      , OwnPubKeyAndStakeKeyMissing
      , TxOutRefNotFound
      , TxOutRefWrongType
      , TypeCheckFailed
      , TypedTxOutHasNoDatumHash
      , TypedValidatorMissing
      , ValidatorHashNotFound
      , WrongRefScriptHash
      , CannotSatisfyAny
      , ExpectedPlutusScriptGotNativeScript
      , CannotMintZero
      )
  ) as X
import Ctl.Internal.ProcessConstraints.UnbalancedTx (UnbalancedTx)
import Ctl.Internal.ProcessConstraints.UnbalancedTx (UnbalancedTx(UnbalancedTx)) as X
import Ctl.Internal.Types.ScriptLookups
  ( ScriptLookups
  )
import Ctl.Internal.Types.ScriptLookups
  ( ScriptLookups(ScriptLookups)
  , datum
  , generalise
  , mintingPolicy
  , mintingPolicyM
  , ownPaymentPubKeyHash
  , ownPaymentPubKeyHashM
  , ownStakePubKeyHash
  , ownStakePubKeyHashM
  , typedValidatorLookups
  , typedValidatorLookupsM
  -- , paymentPubKeyM
  , unspentOutputs
  , unspentOutputsM
  -- , unsafePaymentPubKey
  , validator
  , validatorM
  ) as X
import Ctl.Internal.Types.TxConstraints (TxConstraints)
import Ctl.Internal.Types.TypedValidator (class ValidatorTypes)
import Data.Either (Either, hush)
import Data.Maybe (Maybe)

-- | Create an `UnbalancedTx` given `ScriptLookups` and
-- | `TxConstraints`. You will probably want to use this version as it returns
-- | datums and redeemers that require attaching (and maybe reindexing) in
-- | a separate call. In particular, this should be called in conjuction with
-- | `balanceTx` and  `signTransaction`.
mkUnbalancedTx
  :: forall (validator :: Type) (datum :: Type)
       (redeemer :: Type)
   . ValidatorTypes validator datum redeemer
  => IsData datum
  => IsData redeemer
  => ScriptLookups validator
  -> TxConstraints redeemer datum
  -> Contract
       ( Either
           MkUnbalancedTxError
           UnbalancedTx
       )
mkUnbalancedTx = PC.mkUnbalancedTxImpl

-- | Same as `mkUnbalancedTx` but hushes the error.
mkUnbalancedTxM
  :: forall (validator :: Type) (datum :: Type)
       (redeemer :: Type)
   . ValidatorTypes validator datum redeemer
  => IsData datum
  => IsData redeemer
  => ScriptLookups validator
  -> TxConstraints redeemer datum
  -> Contract (Maybe UnbalancedTx)
mkUnbalancedTxM lookups = map hush <<< mkUnbalancedTx lookups
