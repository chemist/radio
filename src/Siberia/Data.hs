{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TypeSynonymInstances   #-}

module Siberia.Data where

import           BasicPrelude            hiding (FilePath, Map, appendFile,
                                          concat, mapM)
import           Prelude                 (FilePath)
import qualified Prelude

import           Control.Concurrent      (Chan, MVar, ThreadId)
import           Data.Aeson              (FromJSON (..), ToJSON (..),
                                          Value (..), object, (.:), (.=))
import           Data.Attoparsec.RFC2616 (Header (..))
import           Data.ByteString         (concat)
import qualified Data.ByteString         as BS
import           Data.ByteString.Char8   (pack)
import           Data.Map                (Map)
import qualified Data.Map                as Map
import           Data.Text.IO            (appendFile)
import           Network.Socket          (HostName)

import           Control.Monad.Reader
import           Data.Binary             (Binary, Get)
import qualified Data.Binary             as B
import qualified Data.Collections        as Collections
import           Data.Cycle
import           Data.IORef
import           Paths_siberia
import           Snap.Core               (Snap)
import           Data.Attoparsec.RFC2616      (Request (..), request)
import System.IO.Streams (InputStream)
import           Blaze.ByteString.Builder                 (Builder)

-- | const paths
tempDir, musicDirectory, logFile :: FilePath
tempDir = "/.music/"
musicDirectory = "/music/"
logFile = "/log/siberia.log"

-- | const max size for uploaded files
limitSizeForUpload :: Int64
limitSizeForUpload = 10000000

newtype RadioId = RadioId ByteString deriving (Show, Ord, Eq)
newtype Url = Url ByteString deriving (Show, Ord, Eq)
newtype Meta = Meta (ByteString, Int) deriving (Show, Ord, Eq)

type Headers = [Header]
type HostPort = Maybe (HostName, Int)
type Channel = Maybe (Chan (Maybe ByteString))
     
data SRequest = SRequest 
  { headers' :: Headers
  , request' :: Request
  , radio   :: Radio
  }           | BadRequest Int ByteString
  deriving (Show, Eq) 
  
type SResponse = InputStream Builder 

type ShoutCast = SRequest -> Application SResponse


port :: Int
port = 2000

type MProcess = Maybe ThreadId

data Status = Status { connections          :: !Int
                     , connectProcess       :: !MProcess
                     , bufferProcess        :: !MProcess
                     , chanProcess          :: !MProcess
                     , connectionsProcesses :: ![ThreadId]
                     } deriving (Eq, Show)

defStatus :: Status
defStatus = Status 0 Nothing Nothing Nothing []


data Radio = Proxy
  { rid      :: !RadioId
  , url      :: !Url
  , pid      :: !Status
  , headers  :: !Headers
  , meta     :: !(Maybe Meta)
  , channel  :: !Channel
  , hostPort :: !HostPort
  , buff     :: !(Maybe (Buffer ByteString))
  , countIO  :: IO Int64
  }
                 | Local
  { rid      :: !RadioId
  , pid      :: !Status
  , headers  :: !Headers
  , meta     :: !(Maybe Meta)
  , channel  :: !Channel
  , hostPort :: !HostPort
  , buff     :: !(Maybe (Buffer ByteString))
  , playlist :: !(Maybe Playlist)
  , countIO  :: IO Int64
  }
                 | ById
  { rid :: !RadioId } 
  
instance Eq Radio where
    x == y = rid x == rid y
    

data Song = Song { sidi  :: !Int
                 , spath :: !String
                 } deriving (Eq, Show)

type Playlist = Cycle Song

instance Ord Song where
    compare x y = compare (sidi x) (sidi y)

data Store = Store (MVar (Map RadioId (MVar Radio))) !HostPort


type Application = ReaderT Store IO

type Web = ReaderT Store Snap

data Buffer a = Buffer { active :: IORef (Cycle Int)
                       , buf    :: IORef (Cycle (IORef a))
                       , size   :: IORef Int
                       } deriving (Eq)

class Monoid a => RadioBuffer m a where
    -- ** создание буфера указанного размера
    new       :: Int -> IO (m a)
    bufSize   :: m a -> IO Int
    -- ** циклический счетчик, номер блока для следующей записи
    current   :: m a -> IO Int
    nextC     :: m a -> IO Int
    -- ** последний записанный блок
    lastBlock :: m a -> IO a
    -- ** запись очередного блока
    update    :: a -> m a -> IO ()
    -- ** вернуть весь буфер в упорядоченном состоянии
    getAll    :: m a -> IO a

runWeb :: Web a -> Store -> Snap a
runWeb mw r = runReaderT mw r


class (Monad m, MonadIO m, MonadReader Store m) => Allowed m

instance Allowed Application
instance Allowed Web

class Storable m a where
    -- ** проверка наличия радиостанции
    member :: a -> m Bool
    -- ** создание радиостанции
    create :: a -> m (Bool, a)
    -- ** удаление радиостанции
    remove :: a -> m Bool
    -- ** список радиостанций
    list   :: m [a]
    -- ** возвращает MVar с RadioInfo по ById RadioId
    info   :: a -> m (MVar a)

class Detalization m a where
    getD :: Radio -> m a
    setD :: Radio -> a -> m ()

instance Show Radio where
    show (ById x) = Prelude.show x
    show x@Proxy{} = Prelude.show (rid x) ++ Prelude.show (url x) ++ Prelude.show (hostPort x)
    show x@Local{} = Prelude.show (rid x) ++ Prelude.show (hostPort x)


tproxy, tlocal :: Text
tproxy = "proxy"
tlocal = "local"

instance ToJSON Radio where
    toJSON x@Proxy{} = object [ "id" .= (toJSON . rid) x
                              , "url" .= (toJSON . url) x
                              , "listenUrl" .= (toJSON . concat) ["http://", pack host', ":", toBs port', "/", (fromRid . rid) x]
                              , "type" .= toJSON tproxy
                              ]
                       where
                         (Just (host', port')) = hostPort x
                         toBs::Int -> ByteString
                         toBs  = pack . Prelude.show
                         fromRid :: RadioId -> ByteString
                         fromRid (RadioId y ) = y
    toJSON x@Local{} = object
      [ "id" .= (toJSON . rid) x
      , "playlist" .= (toJSON . playlist) x
      , "listenUrl" .= (toJSON . concat) ["http://", pack host', ":", toBs port', "/", (fromRid . rid) x]
      , "type" .= toJSON tlocal
      ]
                       where
                         (Just (host', port')) = hostPort x
                         toBs::Int -> ByteString
                         toBs  = pack . Prelude.show
                         fromRid :: RadioId -> ByteString
                         fromRid (RadioId y ) = y
    toJSON _ = undefined

instance FromJSON Radio where
    parseJSON (Object x) =  Proxy <$> toRid (x .: "id") <*> (Url <$> x .: "url") <*> pD <*> pL <*> pN <*> pN <*> pN <*> pN <*> (pure $ return 0)
                        <|> Local <$> toRid (x .: "id") <*> pD <*> pL <*> pN <*> pN <*> pN <*> pN <*> pN <*> (pure $ return 0)
        where toRid y = addSlash . RadioId <$> y
              pN = pure Nothing
              pD = pure defStatus
              pL = pure []
    parseJSON _ = mzero

instance ToJSON (Maybe Meta) where
    toJSON (Just (Meta (bs,_))) = object [ "meta" .=  (toJSON $ BS.takeWhile (/= toEnum 0) bs) ]
    toJSON Nothing = object [ "meta" .=  toJSON BS.empty ]


instance ToJSON Song where
    toJSON x = object [ "position" .= (toJSON . sidi) x
                      , "file"     .= (toJSON . spath) x
                      ]

instance FromJSON Song where
    parseJSON (Object x) = Song <$> x .: "position" <*> x .: "file"
    parseJSON _ = mzero


instance ToJSON Playlist where
    toJSON x = toJSON . Collections.toList $ x

instance ToJSON Status where
    toJSON (Status i (Just _) _ _ _) = object [ "connections" .= toJSON i
                                            , "status" .= toJSON True
                                            ]
    toJSON (Status i Nothing _ _ _) = object [ "connections" .= toJSON i
                                           , "status" .= toJSON False
                                           ]

addSlash::RadioId -> RadioId
addSlash (RadioId x) = RadioId $ concat ["/", x]



instance ToJSON RadioId where
    toJSON (RadioId x) = toJSON $ BS.tail x

instance ToJSON Url where
    toJSON (Url x) = toJSON x

instance Binary Url where
    put (Url x) = B.put x
    get = Url <$> B.get

instance Binary RadioId where
    put (RadioId x) = B.put x
    get = RadioId <$> B.get

instance Binary Song where
    put (Song x y) = B.put x >> B.put y
    get = Song <$> B.get <*> B.get

instance Binary Playlist where
    put  = B.put . Collections.toList
    get = Collections.fromList <$> B.get

instance Binary Radio where
    put x@Proxy{} = do
        B.put (0 :: Word8)
        B.put $ rid x
        B.put $ url x
    put x@Local{} = do
        B.put (1 :: Word8)
        B.put $ rid x
        B.put $ playlist x
    put _ = undefined
    get = do t <- B.get :: Get Word8
             case t of
                  0 -> do
                      r <- B.get :: Get RadioId
                      u <- B.get :: Get Url
                      return $ Proxy r u defStatus [] Nothing Nothing Nothing Nothing (return 0)
                  1 -> do
                      r <- B.get
                      p <- B.get
                      return $ Local r defStatus [] Nothing Nothing Nothing Nothing p (return 0)
                  _ -> undefined

