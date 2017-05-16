{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

module Pos.Communication.Limits
       (
         module Pos.Communication.Limits.Types

       , updateVoteNumLimit
       , commitmentsNumLimit
       ) where

import           Universum

import           Control.Lens                       (each)
import           Crypto.Hash                        (Blake2b_224, Blake2b_256)
import qualified Crypto.PVSS                        as PVSS
import           GHC.Exts                           (IsList (..))

import           Pos.Binary.Class                   (AsBinary (..))
import           Pos.Block.Network.Types            (MsgBlock (..), MsgGetHeaders (..),
                                                     MsgHeaders (..))
import           Pos.Communication.Types.Relay      (DataMsg (..))
import qualified Pos.Constants                      as Const
import           Pos.Core                           (BlockVersionData (..),
                                                     coinPortionToDouble)
import           Pos.Crypto                         (AbstractHash, EncShare, PublicKey,
                                                     SecretProof, SecretSharingExtra (..),
                                                     Share, Signature, VssPublicKey)
import qualified Pos.DB.Class                       as DB
import           Pos.Ssc.GodTossing.Arbitrary       ()
import           Pos.Ssc.GodTossing.Core.Types      (Commitment (..), InnerSharesMap,
                                                     Opening, SignedCommitment,
                                                     VssCertificate)
import           Pos.Ssc.GodTossing.Types.Message   (GtMsgContents (..))
import           Pos.Txp.Core                       (TxAux)
import           Pos.Txp.Network.Types              (TxMsgContents (..))
import           Pos.Types                          (Block, BlockHeader)
import           Pos.Update.Core.Types              (UpdateProposal (..), UpdateVote (..))

-- Reexports
import           Pos.Communication.Limits.Instances ()
import           Pos.Communication.Limits.Types

----------------------------------------------------------------------------
-- Instances (MessageLimited[Pure])
----------------------------------------------------------------------------

----------------------------------------------------------------------------
---- Core and lower
----------------------------------------------------------------------------

instance MessageLimitedPure (Signature a) where
    msgLenLimit = 64

instance MessageLimitedPure PublicKey where
    msgLenLimit = 64

instance MessageLimitedPure a => MessageLimitedPure (AsBinary a) where
    msgLenLimit = coerce (msgLenLimit :: Limit a) + 20

instance MessageLimitedPure SecretProof where
    msgLenLimit = 64

instance MessageLimitedPure VssPublicKey where
    msgLenLimit = 33

instance MessageLimitedPure EncShare where
    msgLenLimit = 101

instance MessageLimitedPure Share where
    msgLenLimit = 101 --4+33+64

instance MessageLimitedPure PVSS.Commitment where
    msgLenLimit = 33

instance MessageLimitedPure PVSS.ExtraGen where
    msgLenLimit = 33

instance MessageLimitedPure (AbstractHash Blake2b_224 a) where
    msgLenLimit = 28

instance MessageLimitedPure (AbstractHash Blake2b_256 a) where
    msgLenLimit = 32

----------------------------------------------------------------------------
---- GodTossing
----------------------------------------------------------------------------

-- | Upper bound on number of `PVSS.Commitment`s in single
-- `Commitment`.  Actually it's a maximum number of participants in
-- GodTossing. So it also limits number of shares, for instance.
commitmentsNumLimit :: DB.MonadGStateCore m => m Int
commitmentsNumLimit =
    -- succ is just in case
    succ . ceiling . recip . coinPortionToDouble . bvdMpcThd <$>
    DB.gsAdoptedBVData

instance MessageLimited SecretSharingExtra where
    getMsgLenLimit _ = do
        numLimit <- commitmentsNumLimit
        return $ SecretSharingExtra <$> msgLenLimit <+> vector numLimit

instance MessageLimited (AsBinary SecretSharingExtra) where
    -- 20 is a magic constant copy-pasted from 'MessageLimitedPure' instance
    getMsgLenLimit _ =
        coerce . (20 +) <$> getMsgLenLimit (Proxy @SecretSharingExtra)

instance MessageLimited Commitment where
    getMsgLenLimit _ = do
        extraLimit <- getMsgLenLimit (Proxy @(AsBinary SecretSharingExtra))
        numLimit <- commitmentsNumLimit
        return $
            Commitment <$> extraLimit <+> msgLenLimit <+> multiMap numLimit

instance MessageLimited SignedCommitment where
    getMsgLenLimit _ = do
        commLimit <- getMsgLenLimit (Proxy @Commitment)
        return $ (,,) <$> msgLenLimit <+> commLimit <+> msgLenLimit

instance MessageLimitedPure Opening where
    msgLenLimit = 33

instance MessageLimited InnerSharesMap where
    getMsgLenLimit _ = do
        numLimit <- commitmentsNumLimit
        return $ multiMap numLimit

-- There is some precaution in this limit. 171 means that epoch is
-- extremely large. It shouldn't happen in practice, but adding few
-- bytes to the limit is harmless.
instance MessageLimitedPure VssCertificate where
    msgLenLimit = 171

instance MessageLimited (DataMsg GtMsgContents) where
    type LimitType (DataMsg GtMsgContents) = ( Limit (DataMsg GtMsgContents)
                                             , Limit (DataMsg GtMsgContents)
                                             , Limit (DataMsg GtMsgContents)
                                             , Limit (DataMsg GtMsgContents))
    getMsgLenLimit _ = do
        commLimit <-
            fmap MCCommitment <$> getMsgLenLimit (Proxy @SignedCommitment)
        sharesLimit <-
            (MCShares <$> msgLenLimit <+>) <$>
            getMsgLenLimit (Proxy @InnerSharesMap)
        -- 'succ' is used here, because 1 byte is spent on tag.
        -- See 'instance Bi GtMsgContents'.
        return $
            each %~ succ . fmap DataMsg $
            ( commLimit
            , MCOpening <$> msgLenLimit <+> msgLenLimit
            , sharesLimit
            , MCVssCertificate <$> msgLenLimit
            )

----------------------------------------------------------------------------
---- Txp
----------------------------------------------------------------------------

instance MessageLimited TxAux where
    getMsgLenLimit _ = Limit <$> DB.gsMaxTxSize

instance MessageLimited (DataMsg TxMsgContents) where
    getMsgLenLimit _ = do
        txLimit <- getMsgLenLimit (Proxy @TxAux)
        return $ DataMsg . TxMsgContents <$> txLimit

----------------------------------------------------------------------------
---- Update System
----------------------------------------------------------------------------

-- | Upper bound on number of votes carried with single `UpdateProposal`.
updateVoteNumLimit :: DB.MonadGStateCore m => m Int
updateVoteNumLimit =
    -- succ is just in case
    succ . ceiling . recip . coinPortionToDouble . bvdUpdateVoteThd <$>
    DB.gsAdoptedBVData

instance MessageLimitedPure UpdateVote where
    msgLenLimit =
        UpdateVote <$> msgLenLimit <+> msgLenLimit <+> msgLenLimit
                   <+> msgLenLimit

instance MessageLimitedPure (DataMsg UpdateVote) where
    msgLenLimit = DataMsg <$> msgLenLimit

instance MessageLimited (DataMsg UpdateVote)

instance MessageLimited UpdateProposal where
    getMsgLenLimit _ = Limit <$> DB.gsMaxProposalSize

instance MessageLimited (DataMsg (UpdateProposal, [UpdateVote])) where
    getMsgLenLimit _ = do
        proposalLimit <- getMsgLenLimit (Proxy @UpdateProposal)
        voteNumLimit <- updateVoteNumLimit
        return $
            DataMsg <$> ((,) <$> proposalLimit <+> vector voteNumLimit)

----------------------------------------------------------------------------
---- Blocks/headers
----------------------------------------------------------------------------

instance MessageLimited (BlockHeader ssc) where
    getMsgLenLimit _ = Limit <$> DB.gsMaxHeaderSize

instance MessageLimited (Block ssc) where
    getMsgLenLimit _ = Limit <$> DB.gsMaxBlockSize

instance MessageLimited (MsgBlock ssc) where
    getMsgLenLimit _ = do
        blkLimit <- getMsgLenLimit (Proxy @(Block ssc))
        return $ MsgBlock <$> blkLimit

instance MessageLimitedPure MsgGetHeaders where
    msgLenLimit = MsgGetHeaders <$> vector maxGetHeadersNum <+> msgLenLimit
      where
        maxGetHeadersNum =
            ceiling $
            log ((fromIntegral :: Int -> Double) Const.blkSecurityParam) + 5

instance MessageLimited MsgGetHeaders

instance MessageLimited (MsgHeaders ssc) where
    getMsgLenLimit _ = do
        headerLimit <- getMsgLenLimit (Proxy @(BlockHeader ssc))
        return $
            MsgHeaders <$> vectorOf Const.recoveryHeadersMessage headerLimit

----------------------------------------------------------------------------
-- Arbitrary
----------------------------------------------------------------------------

-- TODO [CSL-859]
-- These instances were assuming that commitment limit is constant, but
-- it's not, because threshold can change.
-- P. S. Also it would be good to move them somewhere (and clean-up
-- this module), because currently it's quite messy (I think). @gromak
-- By messy I mean at least that it contains some 'Arbitrary' stuff, which we
-- usually put somewhere outside. Also I don't like that it knows about
-- GodTossing (I think instances for GodTossing should be in GodTossing),
-- but it can wait.

-- instance T.Arbitrary (MaxSize Commitment) where
--     arbitrary = MaxSize <$>
--         (Commitment <$> T.arbitrary <*> T.arbitrary
--                     <*> aMultimap commitmentsNumLimit)

-- instance T.Arbitrary (MaxSize SecretSharingExtra) where
--     arbitrary = do
--         SecretSharingExtra gen commitments <- T.arbitrary
--         let commitments' = alignLength commitmentsNumLimit commitments
--         return $ MaxSize $ SecretSharingExtra gen commitments'
--       where
--         alignLength n = take n . cycle

-- instance T.Arbitrary (MaxSize GtMsgContents) where
--     arbitrary = MaxSize <$>
--         T.oneof [aCommitment, aOpening, aShares, aVssCert]
--       where
--         aCommitment = MCCommitment <$>
--             ((,,) <$> T.arbitrary
--                   <*> (getOfMaxSize <$> T.arbitrary)
--                   <*> T.arbitrary)
--         aOpening = MCOpening <$> T.arbitrary <*> T.arbitrary
--         aShares =
--             MCShares <$> T.arbitrary
--                      <*> aMultimap commitmentsNumLimit
--         aVssCert = MCVssCertificate <$> T.arbitrary

-- instance T.Arbitrary (MaxSize (DataMsg GtMsgContents)) where
--     arbitrary = fmap DataMsg <$> T.arbitrary

----------------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------------

-- -- | Generates multimap which has given number of keys, each associated
-- -- with a single value
-- aMultimap
--     :: (Eq k, Hashable k, T.Arbitrary k, T.Arbitrary v)
--     => Int -> T.Gen (HashMap k (NonEmpty v))
-- aMultimap k =
--     let pairs = (,) <$> T.arbitrary <*> ((:|) <$> T.arbitrary <*> pure [])
--     in  fromList <$> T.vectorOf k pairs

-- | Given a limit for a list item, generate limit for a list with N elements
vectorOf :: IsList l => Int -> Limit (Item l) -> Limit l
vectorOf k (Limit x) =
    Limit $ encodedListLength + x * (fromIntegral k)
  where
    -- should be enough for most reasonable cases
    encodedListLength = 20

-- | Generate limit for a list of messages with N elements
vector :: (IsList l, MessageLimitedPure (Item l)) => Int -> Limit l
vector k = vectorOf k msgLenLimit

multiMap
    :: (IsList l, Item l ~ (k, l0), IsList l0,
        MessageLimitedPure k, MessageLimitedPure (Item l0))
    => Int -> Limit l
multiMap k =
    -- max message length is reached when each key has single value
    vectorOf k $ (,) <$> msgLenLimit <+> vector 1

coerce :: Limit a -> Limit b
coerce (Limit x) = Limit x
