-- | A module that defines the different Utxo `Data.Map`s from transaction
-- | input to transaction output. Furthermore, a helper to get the utxos at
-- | a given `Address` is defined.
module Contract.Utxos
  ( utxosAt
  , module JsonWsp
  , module Transaction
  ) where

import Prelude
import Contract.Monad (Contract)
import Data.Maybe (Maybe)
import Data.Newtype (wrap)
import QueryM (utxosAt) as QueryM
import Serialization.Address (Address)
-- Can potentially remove, perhaps we move utxo related all to Contract.Address
-- and/or Contract.Transaction. Perhaps it's best to not expose JsonWsp.
import Types.JsonWsp (UtxoQueryResult, UtxoQR(UtxoQR)) as JsonWsp
import Types.Transaction (Utxo, UtxoM(UtxoM)) as Transaction

-- | This module defines query functionality via Ogmios to get utxos.

-- | Gets utxos at an (internal) `Address` in terms of (internal) `Transaction.Types`.
-- | Results may vary depending on `Wallet` type. See `QueryM` for more details
-- | on wallet variance.
utxosAt :: Address -> Contract (Maybe Transaction.UtxoM)
utxosAt = wrap <<< QueryM.utxosAt
