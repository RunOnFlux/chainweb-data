{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
-- |

module ChainwebDb.Queries (eventsQueryStmt, searchTxsQueryStmt, transferQueryStmt, escapeSearch) where

------------------------------------------------------------------------------
import           Data.Aeson hiding (Error)
import           Data.Int
import           Data.Function ((&))
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time
import           Data.String
import           Database.Beam hiding (insert)
import           Database.Beam.Postgres
------------------------------------------------------------------------------
import           ChainwebData.Api
import           ChainwebDb.Database
import           ChainwebData.Pagination
import           ChainwebDb.Types.Block
import           ChainwebDb.Types.DbHash
import           ChainwebDb.Types.Event
import           ChainwebDb.Types.Transaction
------------------------------------------------------------------------------

escapeSearch :: Text -> Text
escapeSearch str = str
  & T.replace " " "\\ "
  & T.replace "(" "\\("

searchTxsQueryStmt
  :: Maybe Limit
  -> Maybe Offset
  -> Text
  -> SqlSelect
        Postgres
        (QExprToIdentity
                (QGenExpr QValueContext Postgres QBaseScope Int64,
                QGenExpr QValueContext Postgres QBaseScope Int64,
                QGenExpr QValueContext Postgres QBaseScope (DbHash BlockHash),
                QGenExpr QValueContext Postgres QBaseScope UTCTime,
                QGenExpr QValueContext Postgres QBaseScope (DbHash TxHash),
                QGenExpr QValueContext Postgres QBaseScope Text,
                (QGenExpr QValueContext Postgres QBaseScope (Maybe Text),
                QGenExpr QValueContext Postgres QBaseScope (Maybe (PgJSONB Value)),
                QGenExpr
                QValueContext Postgres QBaseScope (Maybe (PgJSONB Value)))))
searchTxsQueryStmt limit offset search =
    select $ do
        limit_ lim $ offset_ off $ orderBy_ (desc_ . getHeight) $ do
                tx <- all_ (_cddb_transactions database)
                guard_ (toTsVector (Just $ fromString "simple") (fromMaybe_ (val_ "") $ _tx_code tx) @@ toTsQuery (Just $ fromString "simple") (val_ search))
                return
                        ( (_tx_chainId tx)
                        , (_tx_height tx)
                        , (unBlockId $ _tx_block tx)
                        , (_tx_creationTime tx)
                        , (_tx_requestKey tx)
                        , (_tx_sender tx)
                        , ((_tx_code tx)
                        , (_tx_continuation tx)
                        , (_tx_goodResult tx)
                        ))
  where
    lim = maybe 10 (min 100 . unLimit) limit
    off = maybe 0 unOffset offset
    getHeight (_,a,_,_,_,_,_) = a

eventsQueryStmt :: Maybe Limit -> Maybe Offset -> Maybe Text -> Maybe EventParam -> Maybe EventName
                -> SqlSelect
                   Postgres
                   (QExprToIdentity
                    (BlockT (QGenExpr QValueContext Postgres QBaseScope)
                    , EventT (QGenExpr QValueContext Postgres QBaseScope)))
eventsQueryStmt limit offset qSearch qParam qName =
  select $
    limit_ lim $ offset_ off $ orderBy_ getOrder $ do
      blk <- all_ (_cddb_blocks database)
      ev <- all_ (_cddb_events database)
      guard_ (_ev_block ev `references_` blk)
      whenArg qSearch $ \s -> guard_
        ((_ev_qualName ev `like_` val_ (searchString s)) ||.
         (_ev_paramText ev `like_` val_ (searchString s))
        )
      whenArg qName $ \(EventName n) -> guard_ (_ev_qualName ev `like_` val_ (searchString n))
      whenArg qParam $ \(EventParam p) -> guard_ (_ev_paramText ev `like_` val_ (searchString p))
      return (blk,ev)
  where
    whenArg p a = maybe (return ()) a p
    lim = maybe 10 (min 100 . unLimit) limit
    off = maybe 0 unOffset offset
    getOrder (_,ev) =
      (desc_ $ _ev_height ev
      ,asc_ $ _ev_chainid ev
      ,asc_ $ _ev_idx ev)
    searchString search = "%" <> search <> "%"

transferQueryStmt :: Maybe Limit -> Maybe Offset -> Maybe Text -> Maybe Text -> Maybe EventName
  -> SqlSelect
      Postgres
      (QExprToIdentity
       (BlockT (QGenExpr QValueContext Postgres QBaseScope)
       , EventT (QGenExpr QValueContext Postgres QBaseScope)))
transferQueryStmt limit offset fromAccount toAccount qName =
  select $
    limit_ lim $ offset_ off $ orderBy_ getOrder $ do
      blk <- all_ (_cddb_blocks database)
      ev <- all_ (_cddb_events database)
      guard_ (_ev_block ev `references_` blk)
      whenArg fromAccount $ \s -> guard_ ((_ev_params ev ->># val_ 0) ==. val_ s)
      whenArg toAccount $ \s -> guard_ ((_ev_params ev ->># val_ 1) ==. val_ s)
      guard_ (_ev_name ev ==. val_ "TRANSFER")
      whenArg qName $ \(EventName n) -> guard_ (_ev_qualName ev ==. val_ n)
      return (blk, ev)
  where
    whenArg p a = maybe (return ()) a p
    lim = maybe 10 (min 100 . unLimit) limit
    off = maybe 0 unOffset offset
    getOrder (_, ev) =
      (desc_ $ _ev_height ev
      ,asc_ $ _ev_chainid ev
      ,asc_ $ _ev_idx ev)
