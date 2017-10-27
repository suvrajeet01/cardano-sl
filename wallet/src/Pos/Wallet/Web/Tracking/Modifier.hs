{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Wallet info modifier

module Pos.Wallet.Web.Tracking.Modifier
       ( WalletModifier (..)
       , CachedWalletModifier

       , VoidModifier
       , deleteAndInsertVM
       , deleteAndInsertMM

       , IndexedMapModifier (..)
       , sortedInsertions
       , indexedDeletions
       , insertIMM
       , deleteIMM
       , deleteAndInsertIMM
       ) where

import           Universum

import           Data.DList                   (DList)
import qualified Data.Text.Buildable
import           Formatting                   (bprint, build, (%))
import           Serokell.Util                (listJson, listJsonIndent)

import           Pos.Client.Txp.History       (TxHistoryEntry (..))
import           Pos.Core                     (HeaderHash)
import           Pos.Txp.Core                 (TxId)
import           Pos.Txp.Toil                 (UtxoModifier)
import           Pos.Util.Modifier            (MapModifier)
import qualified Pos.Util.Modifier            as MM

import           Pos.Wallet.Web.ClientTypes   (Addr, CId, CWAddressMeta)
import           Pos.Wallet.Web.Pending.Types (PtxBlockInfo)

-- VoidModifier describes a difference between two states.
-- It's (set of added k, set of deleted k) essentially.
type VoidModifier a = MapModifier a ()

data IndexedMapModifier a = IndexedMapModifier
    { immModifier :: MM.MapModifier a Int
    , immCounter  :: Int
    }

sortedInsertions :: IndexedMapModifier a -> [a]
sortedInsertions = map fst . sortWith snd . MM.insertions . immModifier

indexedDeletions :: IndexedMapModifier a -> [a]
indexedDeletions = MM.deletions . immModifier

instance (Eq a, Hashable a) => Monoid (IndexedMapModifier a) where
    mempty = IndexedMapModifier mempty 0
    IndexedMapModifier m1 c1 `mappend` IndexedMapModifier m2 c2 =
        IndexedMapModifier (m1 <> fmap (+ c1) m2) (c1 + c2)

data WalletModifier = WalletModifier
    { wmAddresses            :: !(IndexedMapModifier CWAddressMeta)
    , wmHistoryEntries       :: !(MapModifier TxId TxHistoryEntry)
    , wmUsed                 :: !(VoidModifier (CId Addr, HeaderHash))
    , wmChange               :: !(VoidModifier (CId Addr, HeaderHash))
    , wmUtxo                 :: !UtxoModifier
    , wmAddedPtxCandidates   :: !(DList (TxId, PtxBlockInfo))
    , wmDeletedPtxCandidates :: !(DList (TxId, TxHistoryEntry))
    }

instance Monoid WalletModifier where
    mempty = WalletModifier mempty mempty mempty mempty mempty mempty mempty
    (WalletModifier a b c d e f g) `mappend` (WalletModifier a1 b1 c1 d1 e1 f1 g1) =
        WalletModifier (a <> a1) (b <> b1) (c <> c1) (d <> d1) (e <> e1) (f <> f1) (g <> g1)

instance Buildable WalletModifier where
    build WalletModifier{..} =
        bprint
            ( "\n    added addresses: "%listJsonIndent 8
            %",\n    deleted addresses: "%listJsonIndent 8
            %",\n    used addresses: "%listJson
            %",\n    change addresses: "%listJson
            %",\n    local utxo (difference): "%build
            %",\n    added history entries: "%listJsonIndent 8
            %",\n    deleted history entries: "%listJsonIndent 8
            %",\n    added pending candidates: "%listJson
            %",\n    deleted pending candidates: "%listJson)
        (sortedInsertions wmAddresses)
        (indexedDeletions wmAddresses)
        (map (fst . fst) $ MM.insertions wmUsed)
        (map (fst . fst) $ MM.insertions wmChange)
        wmUtxo
        (map snd $ MM.insertions wmHistoryEntries)
        (MM.deletions wmHistoryEntries)
        (map fst wmAddedPtxCandidates)
        (map fst wmDeletedPtxCandidates)

-- | `txMempoolToModifier`, once evaluated, is passed around under this type in
-- scope of single request.
type CachedWalletModifier = WalletModifier

----------------------------------------------------------------------------
-- Funcs
----------------------------------------------------------------------------

-- | This function is alternative for MapModifier's @delete@.
-- It doesn't add removable element to delete set
-- if it was inserted before (in contrast with @delete@)
deleteNotDeep :: (Eq k, Hashable k) => k -> MapModifier k v -> MapModifier k v
deleteNotDeep = MM.alter alterDelF
  where
    alterDelF :: MM.KeyState v -> MM.KeyState v
    alterDelF MM.KeyNotFound     = MM.KeyDeleted
    alterDelF MM.KeyDeleted      = MM.KeyDeleted
    alterDelF (MM.KeyInserted _) = MM.KeyNotFound


insertIMM
    :: (Eq a, Hashable a)
    => a -> IndexedMapModifier a -> IndexedMapModifier a
insertIMM k IndexedMapModifier {..} =
    IndexedMapModifier
    { immModifier = MM.insert k immCounter immModifier
    , immCounter  = immCounter + 1
    }

deleteIMM
    :: (Eq a, Hashable a)
    => a -> IndexedMapModifier a -> IndexedMapModifier a
deleteIMM k IndexedMapModifier {..} =
    IndexedMapModifier
    { immModifier = deleteNotDeep k immModifier
    , ..
    }

deleteAndInsertIMM
    :: (Eq a, Hashable a)
    => [a] -> [a] -> IndexedMapModifier a -> IndexedMapModifier a
deleteAndInsertIMM dels ins mapModifier =
    -- Insert CWAddressMeta coressponding to outputs of tx.
    (\mm -> foldl' (flip insertIMM) mm ins) $
    -- Delete CWAddressMeta coressponding to inputs of tx.
    foldl' (flip deleteIMM) mapModifier dels

deleteAndInsertVM :: (Eq a, Hashable a) => [a] -> [a] -> VoidModifier a -> VoidModifier a
deleteAndInsertVM dels ins mapModifier = deleteAndInsertMM dels (zip ins $ repeat ()) mapModifier

deleteAndInsertMM :: (Eq k, Hashable k) => [k] -> [(k, v)] -> MM.MapModifier k v -> MM.MapModifier k v
deleteAndInsertMM dels ins mapModifier =
    -- Insert CWAddressMeta coressponding to outputs of tx (2)
    (\mm -> foldl' insertAcc mm ins) $
    -- Delete CWAddressMeta coressponding to inputs of tx (1)
    foldl' deleteAcc mapModifier dels
  where
    insertAcc :: (Hashable k, Eq k) => MapModifier k v -> (k, v) -> MapModifier k v
    insertAcc modifier (k, v) = MM.insert k v modifier

    deleteAcc :: (Hashable k, Eq k) => MapModifier k v -> k -> MapModifier k v
    deleteAcc = flip deleteNotDeep

