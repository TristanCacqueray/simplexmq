{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Server.Env.STM where

import Control.Concurrent (ThreadId)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.System (SystemTime)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (ServiceName)
import qualified Network.TLS as T
import Numeric.Natural
import Simplex.Messaging.Crypto (KeyHash (..))
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.QueueStore (NtfCreds (..), QueueRec (..))
import Simplex.Messaging.Server.QueueStore.STM
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport)
import Simplex.Messaging.Transport.Server (loadFingerprint, loadTLSServerParams)
import Simplex.Messaging.Version
import System.IO (IOMode (..))
import System.Mem.Weak (Weak)
import UnliftIO.STM

data ServerConfig = ServerConfig
  { transports :: [(ServiceName, ATransport)],
    tbqSize :: Natural,
    serverTbqSize :: Natural,
    msgQueueQuota :: Natural,
    queueIdBytes :: Int,
    msgIdBytes :: Int,
    storeLogFile :: Maybe FilePath,
    storeMsgsFile :: Maybe FilePath,
    -- | set to False to prohibit creating new queues
    allowNewQueues :: Bool,
    -- | time after which the messages can be removed from the queues and check interval, seconds
    messageExpiration :: Maybe ExpirationConfig,
    -- | time after which the socket with inactive client can be disconnected (without any messages or commands, incl. PING),
    -- and check interval, seconds
    inactiveClientExpiration :: Maybe ExpirationConfig,
    -- | log SMP server usage statistics, only aggregates are logged, seconds
    logStatsInterval :: Maybe Int,
    -- | time of the day when the stats are logged first, to log at consistent times,
    -- irrespective of when the server is started (seconds from 00:00 UTC)
    logStatsStartTime :: Int,
    -- | file to log stats
    serverStatsLogFile :: FilePath,
    -- | file to save and restore stats
    serverStatsBackupFile :: Maybe FilePath,
    -- | CA certificate private key is not needed for initialization
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    -- | SMP client-server protocol version range
    smpServerVRange :: VersionRange
  }

defaultMessageExpiration :: ExpirationConfig
defaultMessageExpiration =
  ExpirationConfig
    { ttl = 30 * 86400, -- seconds, 30 days
      checkInterval = 43200 -- seconds, 12 hours
    }

defaultInactiveClientExpiration :: ExpirationConfig
defaultInactiveClientExpiration =
  ExpirationConfig
    { ttl = 86400, -- seconds, 24 hours
      checkInterval = 43200 -- seconds, 12 hours
    }

data Env = Env
  { config :: ServerConfig,
    server :: Server,
    serverIdentity :: KeyHash,
    queueStore :: QueueStore,
    msgStore :: STMMsgStore,
    idsDrg :: TVar ChaChaDRG,
    storeLog :: Maybe (StoreLog 'WriteMode),
    tlsServerParams :: T.ServerParams,
    serverStats :: ServerStats
  }

data Server = Server
  { subscribedQ :: TBQueue (RecipientId, Client),
    subscribers :: TMap RecipientId Client,
    ntfSubscribedQ :: TBQueue (NotifierId, Client),
    notifiers :: TMap NotifierId Client
  }

data Client = Client
  { subscriptions :: TMap RecipientId (TVar Sub),
    ntfSubscriptions :: TMap NotifierId (),
    rcvQ :: TBQueue (NonEmpty (Maybe QueueRec, Transmission Cmd)),
    sndQ :: TBQueue (NonEmpty (Transmission BrokerMsg)),
    thVersion :: Version,
    sessionId :: ByteString,
    connected :: TVar Bool,
    activeAt :: TVar SystemTime
  }

data SubscriptionThread = NoSub | SubPending | SubThread (Weak ThreadId) | ProhibitSub

data Sub = Sub
  { subThread :: SubscriptionThread,
    delivered :: TMVar MsgId
  }

newServer :: Natural -> STM Server
newServer qSize = do
  subscribedQ <- newTBQueue qSize
  subscribers <- TM.empty
  ntfSubscribedQ <- newTBQueue qSize
  notifiers <- TM.empty
  return Server {subscribedQ, subscribers, ntfSubscribedQ, notifiers}

newClient :: Natural -> Version -> ByteString -> SystemTime -> STM Client
newClient qSize thVersion sessionId ts = do
  subscriptions <- TM.empty
  ntfSubscriptions <- TM.empty
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  connected <- newTVar True
  activeAt <- newTVar ts
  return Client {subscriptions, ntfSubscriptions, rcvQ, sndQ, thVersion, sessionId, connected, activeAt}

newSubscription :: SubscriptionThread -> STM Sub
newSubscription subThread = do
  delivered <- newEmptyTMVar
  return Sub {subThread, delivered}

newEnv :: forall m. (MonadUnliftIO m, MonadRandom m) => ServerConfig -> m Env
newEnv config@ServerConfig {caCertificateFile, certificateFile, privateKeyFile, storeLogFile} = do
  server <- atomically $ newServer (serverTbqSize config)
  queueStore <- atomically newQueueStore
  msgStore <- atomically newMsgStore
  idsDrg <- drgNew >>= newTVarIO
  storeLog <- liftIO $ openReadStoreLog `mapM` storeLogFile
  s' <- restoreQueues queueStore `mapM` storeLog
  tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
  Fingerprint fp <- liftIO $ loadFingerprint caCertificateFile
  let serverIdentity = KeyHash fp
  serverStats <- atomically . newServerStats =<< liftIO getCurrentTime
  return Env {config, server, serverIdentity, queueStore, msgStore, idsDrg, storeLog = s', tlsServerParams, serverStats}
  where
    restoreQueues :: QueueStore -> StoreLog 'ReadMode -> m (StoreLog 'WriteMode)
    restoreQueues QueueStore {queues, senders, notifiers} s = do
      (qs, s') <- liftIO $ readWriteStoreLog s
      atomically $ do
        writeTVar queues =<< mapM newTVar qs
        writeTVar senders $ M.foldr' addSender M.empty qs
        writeTVar notifiers $ M.foldr' addNotifier M.empty qs
      pure s'
    addSender :: QueueRec -> Map SenderId RecipientId -> Map SenderId RecipientId
    addSender q = M.insert (senderId q) (recipientId q)
    addNotifier :: QueueRec -> Map NotifierId RecipientId -> Map NotifierId RecipientId
    addNotifier q = case notifier q of
      Nothing -> id
      Just NtfCreds {notifierId} -> M.insert notifierId (recipientId q)
