{-# LANGUAGE DeriveLift                 #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Database.PG.Query.Transaction
    ( TxIsolation(..)
    , TxAccess(..)
    , TxMode
    , PGTxErr(..)
    , getPGStmtErr
    , TxET(..)
    , TxE
    , TxT
    , Tx
    , withNotices
    , withQ
    , withQE
    , rawQ
    , rawQE
    , listQ
    , listQE
    , unitQ
    , unitQE
    , multiQE
    , multiQ
    , discardQ
    , discardQE
    , serverVersion
    , execTx
    , catchE
    , Query
    , fromText
    , fromBuilder
    , getQueryText
    ) where

import           Database.PG.Query.Class
import           Database.PG.Query.Connection

import           Control.Monad.Base
import           Control.Monad.Except
import           Control.Monad.Morph          (MFunctor, hoist)
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Data.Aeson
import           Data.Aeson.Text
import           Data.Hashable
import           GHC.Exts
import           Language.Haskell.TH.Syntax   (Lift)

import qualified Data.Text                    as T
import qualified Database.PostgreSQL.LibPQ    as PQ
import qualified Text.Builder                 as TB

data TxIsolation
  = ReadCommitted
  | RepeatableRead
  | Serializable
  deriving (Eq, Lift)

instance Show TxIsolation where
  {-# INLINE show #-}
  show ReadCommitted  = "ISOLATION LEVEL READ COMMITTED"
  show RepeatableRead = "ISOLATION LEVEL REPEATABLE READ"
  show Serializable   = "ISOLATION LEVEL SERIALIZABLE"

data TxAccess
  = ReadWrite
  | ReadOnly
  deriving (Eq, Lift)

instance Show TxAccess where
  {-# INLINE show #-}
  show ReadWrite = "READ WRITE"
  show ReadOnly  = "READ ONLY"

type TxMode = (TxIsolation, Maybe TxAccess)

newtype TxET e m a
  = TxET { txHandler :: ReaderT PGConn (ExceptT e m) a }
  deriving (Functor, Applicative, Monad, MonadError e, MonadIO, MonadReader PGConn, MonadFix)

instance MonadTrans (TxET e) where
  lift = TxET . lift . lift

instance MFunctor (TxET e) where
  hoist f = TxET . hoist (hoist f) . txHandler

instance (MonadBase IO m) => MonadBase IO (TxET e m) where
  liftBase = lift . liftBase

instance (MonadBaseControl IO m) => MonadBaseControl IO (TxET e m) where
  type StM (TxET e m) a = StM (ReaderT PGConn (ExceptT e m)) a
  liftBaseWith f = TxET $ liftBaseWith $ \run -> f (run . txHandler)
  restoreM = TxET . restoreM

type TxE e a = TxET e IO a
type TxT m a = TxET PGTxErr m a
type Tx a = TxE PGTxErr a


{-# INLINE catchE #-}
catchE :: (Functor m) => (e -> e') -> TxET e m a -> TxET e' m a
catchE f action = TxET $ mapReaderT (withExceptT f) $ txHandler action

data PGTxErr
  = PGTxErr !T.Text ![PrepArg] !Bool !PGErrInternal
  -- PGCustomErr !T.Text
  deriving (Eq)

{-# INLINE getPGStmtErr #-}
getPGStmtErr :: PGTxErr -> Maybe PGStmtErrDetail
getPGStmtErr (PGTxErr _ _ _ ei) = case ei of
  PGIStatement e  -> return e
  PGIUnexpected _ -> Nothing

instance ToJSON PGTxErr where
  toJSON (PGTxErr stmt args isPrep qe) =
    object [ "statement" .= stmt
           , "arguments" .= map show args
           , "prepared"  .= isPrep
           , "error"     .= qe
           ]

instance Show PGTxErr where
  show = show . encodeToLazyText

{-# INLINE execTx #-}
execTx :: PGConn -> TxET e m a -> ExceptT e m a
execTx conn tx = runReaderT (txHandler tx) conn

newtype Query
  = Query { getQueryText :: T.Text }
  deriving (Show, Eq, Hashable, IsString, ToJSON)

{-# INLINE fromText #-}
fromText :: T.Text -> Query
fromText = Query

{-# INLINE fromBuilder #-}
fromBuilder :: TB.Builder -> Query
fromBuilder = Query . TB.run

withQ :: (MonadIO m, FromRes a, ToPrepArgs r)
      => Query
      -> r
      -> Bool
      -> TxT m a
withQ = withQE id

withQE :: (MonadIO m, FromRes a, ToPrepArgs r)
       => (PGTxErr -> e)
       -> Query
       -> r
       -> Bool
       -> TxET e m a
withQE ef q r prep =
  rawQE ef q args prep
  where
    args = toPrepArgs r

rawQ :: (MonadIO m, FromRes a)
     => Query
     -> [PrepArg]
     -> Bool
     -> TxT m a
rawQ = rawQE id

rawQE :: (MonadIO m, FromRes a)
      => (PGTxErr -> e)
      -> Query
      -> [PrepArg]
      -> Bool
      -> TxET e m a
rawQE ef q args prep = TxET $ ReaderT $ \pgConn ->
  withExceptT (ef . txErrF) $ (hoist liftIO) $
  execQuery pgConn $ PGQuery (mkTemplate stmt) args prep fromRes
  where
    txErrF = PGTxErr stmt args prep
    stmt = getQueryText q

multiQE :: (MonadIO m, FromRes a)
        => (PGTxErr -> e)
        -> Query
        -> TxET e m a
multiQE ef q = TxET $ ReaderT $ \pgConn ->
  withExceptT (ef . txErrF) $ (hoist liftIO) $
  execMulti pgConn (mkTemplate stmt) fromRes
  where
    txErrF = PGTxErr stmt [] False
    stmt = getQueryText q

multiQ :: (MonadIO m, FromRes a)
       => Query
       -> TxT m a
multiQ = multiQE id

withNotices :: (MonadIO m) => TxT m a -> TxT m (a, [T.Text])
withNotices tx =  do
  conn <- asks pgPQConn
  setToNotice
  liftIO $ PQ.enableNoticeReporting conn
  a <- tx
  notices <- liftIO $ getNotices conn []
  liftIO $ PQ.disableNoticeReporting conn
  setToWarn
  return (a, map lenientDecodeUtf8 notices)
  where
    setToNotice = unitQE id "SET client_min_messages TO NOTICE;" () False
    setToWarn = unitQE id "SET client_min_messages TO WARNING;" () False
    getNotices conn xs = do
      notice <- PQ.getNotice conn
      case notice of
        Nothing -> return xs
        Just bs -> getNotices conn (bs:xs)

unitQ :: (MonadIO m, ToPrepArgs r)
      => Query
      -> r
      -> Bool
      -> TxT m ()
unitQ = withQ

unitQE :: (MonadIO m, ToPrepArgs r)
       => (PGTxErr -> e)
       -> Query
       -> r
       -> Bool
       -> TxET e m ()
unitQE = withQE

discardQ :: (MonadIO m, ToPrepArgs r)
         => Query
         -> r
         -> Bool
         -> TxT m ()
discardQ t r p= do
  Discard () <- withQ t r p
  return ()

discardQE :: (MonadIO m, ToPrepArgs r)
          => (PGTxErr -> e)
          -> Query
          -> r
          -> Bool
          -> TxET e m ()
discardQE ef t r p= do
  Discard () <- withQE ef t r p
  return ()

listQ :: (MonadIO m, FromRow a, ToPrepArgs r)
      => Query
      -> r
      -> Bool
      -> TxT m [a]
listQ = withQ

listQE :: (MonadIO m, FromRow a, ToPrepArgs r)
       => (PGTxErr -> e)
       -> Query
       -> r
       -> Bool
       -> TxET e m [a]
listQE = withQE

serverVersion
  :: MonadIO m => TxET e m Int
serverVersion = do
  conn <- asks pgPQConn
  liftIO $ PQ.serverVersion conn
