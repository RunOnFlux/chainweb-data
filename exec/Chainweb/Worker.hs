{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NumericUnderscores #-}

module Chainweb.Worker
  ( writes
  , writeBlock
  , writeBlocks
  ) where

import           BasePrelude hiding (delete, insert)
import           Chainweb.Api.BlockHeader
import           Chainweb.Api.BlockPayloadWithOutputs
import           Chainweb.Api.ChainId (ChainId(..))
import           Chainweb.Api.Hash
import           Chainweb.Database
import           Chainweb.Env
import           Chainweb.Lookups
import           ChainwebData.Types
import           ChainwebDb.Types.Block
import           ChainwebDb.Types.DbHash
import           ChainwebDb.Types.MinerKey
import           ChainwebDb.Types.Transaction
import           ChainwebDb.Types.Event
import           Control.Lens (iforM_)
import           Control.Retry
import           Control.StopWatch
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import qualified Data.Map as M
import qualified Data.Pool as P
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Tuple.Strict (T2(..))
import           Database.Beam hiding (insert)
import           Database.Beam.Backend.SQL.BeamExtensions
import           Database.Beam.Postgres
import           Database.Beam.Postgres.Full (insert, onConflict)
import           Database.PostgreSQL.Simple.Transaction (withTransaction,withSavepoint)
import           System.Logger hiding (logg)
---

-- | Write a Block and its Transactions to the database. Also writes the Miner
-- if it hasn't already been via some other block.
writes :: P.Pool Connection -> Block -> [T.Text] -> [Transaction] -> [Event] -> IO ()
writes pool b ks ts es = P.withResource pool $ \c -> withTransaction c $ do
     runBeamPostgres c $ do
        -- Write Pub Key many-to-many relationships if unique --
        runInsert
          $ insert (_cddb_minerkeys database) (insertValues $ map (MinerKey (pk b)) ks)
          $ onConflict (conflictingFields primaryKey) onConflictDoNothing
        -- Write the Block if unique --
        runInsert
          $ insert (_cddb_blocks database) (insertValues [b])
          $ onConflict (conflictingFields primaryKey) onConflictDoNothing
     {- We should still be able to write the block & miner keys data if writing
     either the transaction or event data somehow fails. -}
     withSavepoint c $ runBeamPostgres c $ do
        -- Write the TXs if unique --
        runInsert
          $ insert (_cddb_transactions database) (insertValues ts)
          $ onConflict (conflictingFields primaryKey) onConflictDoNothing
        -- Write the events if unique --
        runInsert
          $ insert (_cddb_events database) (insertValues es)
          $ onConflict (conflictingFields primaryKey) onConflictDoNothing
        -- liftIO $ printf "[OKAY] Chain %d: %d: %s %s\n"
        --   (_block_chainId b)
        --   (_block_height b)
        --   (unDbHash $ _block_hash b)
        --   (map (const '.') ts)

batchWrites :: P.Pool Connection -> [Block] -> [[T.Text]] -> [[Transaction]] -> [[Event]] -> IO ()
batchWrites pool bs kss tss ess = P.withResource pool $ \c -> withTransaction c $ do
  runBeamPostgres c $ do
    -- Write Pub Key many-to-many relationships if unique --
    runInsert
      $ insert (_cddb_minerkeys database) (insertValues $ concat $ zipWith (\b ks -> map (MinerKey (pk b)) ks) bs kss)
      $ onConflict (conflictingFields primaryKey) onConflictDoNothing
    -- Write the Blocks if unique
    runInsert
      $ insert (_cddb_blocks database) (insertValues bs)
      $ onConflict (conflictingFields primaryKey) onConflictDoNothing

  withSavepoint c $ runBeamPostgres c $ do
    -- Write the TXs if unique
    runInsert
      $ insert (_cddb_transactions database) (insertValues $ concat tss)
      $ onConflict (conflictingFields primaryKey) onConflictDoNothing

    runInsert
      $ insert (_cddb_events database) (insertValues $ concat ess)
      $ onConflict (conflictingFields primaryKey) onConflictDoNothing

asPow :: BlockHeader -> PowHeader
asPow bh = PowHeader bh (T.decodeUtf8 . B16.encode . B.reverse . unHash $ powHash bh)

-- | Given a single `BlockHeader`, look up its payload and write everything to
-- the database.
writeBlock :: Env -> P.Pool Connection -> IORef Int -> BlockHeader -> IO ()
writeBlock env pool count bh = do
  let !pair = T2 (_blockHeader_chainId bh) (hashToDbHash $ _blockHeader_payloadHash bh)
      logg = _env_logger env
  retrying policy check (const $ payloadWithOutputs env pair) >>= \case
    Left e -> do
      logg Error $ fromString $ printf "Couldn't fetch parent for: %s\n"
        (hashB64U $ _blockHeader_hash bh)
      logg Info $ fromString $ show e
    Right pl -> do
      let !m = _blockPayloadWithOutputs_minerData pl
          !b = asBlock (asPow bh) m
          !t = mkBlockTransactions b pl
          !es = mkBlockEvents (fromIntegral $ _blockHeader_height bh) (_blockHeader_chainId bh) (DbHash $ hashB64U $ _blockHeader_parent bh) pl
          !k = bpwoMinerKeys pl
      atomicModifyIORef' count (\n -> (n+1, ()))
      writes pool b k t es
  where
    policy :: RetryPolicyM IO
    policy = exponentialBackoff 250_000 <> limitRetries 3

check :: RetryStatus -> Either ApiError a -> IO Bool
check _ ev = pure $
  case ev of
    Left e -> apiError_type e == RateLimiting
    _ -> False

writeBlocks :: Env -> P.Pool Connection -> IORef Int -> IORef Int -> [BlockHeader] -> IO ()
writeBlocks env pool count sampler bhs = do
    iforM_ blocksByChainId $ \chain (Sum numWrites, bhs') -> do
      let ff bh = (hashToDbHash $ _blockHeader_payloadHash bh, _blockHeader_hash bh)
      retrying policy check (const $ payloadWithOutputsBatch env chain (M.fromList (ff <$> bhs'))) >>= \case
        Left e -> do
          logger Error $ fromString $ printf "Couldn't fetch payload batch for chain: %d" (unChainId chain)
          print e
        Right pls' -> do
          let !pls = M.fromList pls'
              !ms = _blockPayloadWithOutputs_minerData <$> pls
              !bs = M.intersectionWith (\m bh -> asBlock (asPow bh) m) ms (makeBlockMap bhs')
              !tss = M.intersectionWith (flip mkBlockTransactions) pls bs
              !ess = M.intersectionWith
                  (\pl bh -> mkBlockEvents (fromIntegral $ _blockHeader_height bh) (_blockHeader_chainId bh) (DbHash $ hashB64U $ _blockHeader_parent bh) pl)
                  pls
                  (makeBlockMap bhs')
              !kss = M.intersectionWith (\p _ -> bpwoMinerKeys p) pls (makeBlockMap bhs')
          deltaT <- fmap snd $ stopWatch $ batchWrites pool (M.elems bs) (M.elems kss) (M.elems tss) (M.elems ess)
          logger Info $ fromString $ printf "Took %s to write batch of roughly size %d." (show deltaT) (M.size bs)
          sample <- readIORef sampler
          when (mod sample 100 == 0) $ do
            logger Debug $ fromString $ printf "Took %s to write btach of roughly size %d." (show deltaT) (M.size bs)
            atomicModifyIORef' sampler (const (0,()))
          atomicModifyIORef' sampler (\n -> (n + 1, ()))
          atomicModifyIORef' count (\n -> (n + numWrites, ()))
  where

    makeBlockMap = M.fromList . fmap (\bh -> (_blockHeader_hash bh, bh))

    logger = _env_logger env

    blocksByChainId =
      M.fromListWith mappend
        $ bhs
        <&> \bh -> (_blockHeader_chainId bh, (Sum (1 :: Int), [bh]))

    policy :: RetryPolicyM IO
    policy = exponentialBackoff 250_000 <> limitRetries 3
