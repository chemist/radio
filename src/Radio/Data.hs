{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module Radio.Data where

import           BasicPrelude                 hiding (concat, mapM)
import           Prelude                      ()
import qualified Prelude

import           Control.Concurrent           (Chan, MVar, newMVar, ThreadId)
import           Data.Aeson                   (FromJSON (..), ToJSON (..),
                                               Value (..), object, (.:), (.=))
import qualified Data.Map as Map
import           Data.Attoparsec.RFC2616      (Header (..))
import           Data.ByteString              (concat)
import           Data.ByteString.Char8        (pack)
import           Network.Socket               (HostName)

import           System.IO.Streams            as S
import           System.IO.Streams.Attoparsec as S
import           System.IO.Streams.Concurrent as S
import Control.Monad.Reader hiding (mapM)
import           Snap.Core           (Snap)
import qualified Data.Binary as B
import Data.Binary (Binary, Get)
import Data.IORef
import Data.Cycle
import qualified Data.Collections as Collections

newtype RadioId = RadioId ByteString deriving (Show, Ord, Eq)
newtype Url = Url ByteString deriving (Show, Ord, Eq)
newtype Meta = Meta (ByteString, Int) deriving (Show, Ord, Eq)
type Headers = [Header]
type HostPort = Maybe (HostName, Int)
type Channel = Maybe (Chan (Maybe ByteString))

instance ToJSON RadioId where
    toJSON (RadioId x) = toJSON x

instance ToJSON Url where
    toJSON (Url x) = toJSON x
    
instance Binary Url where
    put (Url x) = B.put x
    get = Url <$> B.get
    
instance Binary RadioId where
    put (RadioId x) = B.put x
    get = RadioId <$> B.get
    

port :: Int
port = 2000

data RadioInfo x = RI { rid      :: x
                      , url      :: Url
                      , pid      :: Maybe ThreadId
                      , headers  :: Headers
                      , meta     :: Maybe Meta
                      , channel  :: Channel
                      , hostPort :: HostPort
                      }
                  | ById { rid :: x } deriving (Eq)
                      
type Radio = RadioInfo RadioId

instance Binary Radio where
    put x = do
        B.put $ rid x
        B.put $ url x
    get = do
        r <- B.get :: Get RadioId
        u <- B.get :: Get Url
        return $ RI r u Nothing [] Nothing Nothing Nothing 

data Store a = Store (MVar (Map RadioId (MVar a))) HostPort

type RadioStore = Store Radio

type Application = ReaderT RadioStore IO

type Web = ReaderT RadioStore Snap 

data Buffer a = Buffer { active :: IORef (Cycle Int)
                       , buf    :: IORef (Cycle (IORef a))
                       }
                       
class Monoid a => RadioBuffer m a where
    -- ** создание буфера указанного размера
    new       :: Int -> IO (m a)
    -- ** циклический счетчик, номер блока для следующей записи
    current   :: m a -> IO Int
    -- ** последний записанный блок
    lastBlock :: m a -> IO a
    -- ** запись очередного блока
    update    :: a -> m a -> IO ()
    -- ** вернуть весь буфер в упорядоченном состоянии
    getAll    :: m a -> IO a
    
instance Monoid a => RadioBuffer Buffer a where
    new n = do
        l <-  sequence $ replicate n (newIORef empty :: Monoid a => IO (IORef a))
        l' <- newIORef $ Collections.fromList l
        p <- newIORef $ Collections.fromList [1 .. n]
        return $ Buffer p l'
    current x = readIORef (active x) >>= return . getValue
    lastBlock x = do
        position <- readIORef $ active x
        buf' <- readIORef $ buf x
        readIORef $ nthValue (getValue position) buf'
    update x y = do
        modifyIORef (active y) goRight
        position <- readIORef $ active y
        buf' <- readIORef $ buf y
        modifyIORef (nthValue (getValue position) buf') $ \_ -> x
    getAll x = do
        position <- readIORef $ active x
        buf' <- readIORef $ buf x
        let res = takeLR 5 $ goLR (1 + getValue position) buf'
        mconcat <$> Prelude.mapM (\y -> readIORef y) res
        
        
        

runWeb :: Web a -> RadioStore -> Snap a
runWeb m r = runReaderT m r

class (Monad m, MonadIO m, MonadReader RadioStore m) => Allowed m 

instance Allowed Application 
instance Allowed Web 

class Storable m a where
    member :: a -> m Bool
    create :: a -> m (Bool, a)
    remove :: a -> m Bool
    list   :: m [a]
    info   :: a -> m (MVar a)
--    save   :: Prelude.FilePath -> m ()
--    load   :: Prelude.FilePath -> m ()
    
    
    
class Detalization m a where
    get :: Radio -> m a
    set :: Radio -> a -> m ()

instance Show Radio where
    show x = Prelude.show (rid x) ++ Prelude.show (url x) ++ Prelude.show (hostPort x)

instance ToJSON Radio where
    toJSON x = object [ "id" .= (toJSON . rid) x
                      , "url" .= (toJSON . url) x
                      , "listenUrl" .= (toJSON . concat) ["http://", pack host', ":", toBs port', "/", (fromRid . rid) x]
                      ]
               where
                 (Just (host', port')) = hostPort x
                 toBs::Int -> ByteString
                 toBs  = pack . Prelude.show
                 fromRid :: RadioId -> ByteString
                 fromRid (RadioId y ) = y

instance FromJSON Radio where
    parseJSON (Object x) = do
        rid' <- x .: "id"
        url' <- x .: "url"
        return $ RI (addSlash $ RadioId rid') (Url url') Nothing [] Nothing Nothing Nothing

addSlash::RadioId -> RadioId
addSlash (RadioId x) = RadioId $ concat ["/", x]
   
