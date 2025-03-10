{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}

module AgentTests.SQLiteTests (storeTests) where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM
import Control.Monad (replicateM_)
import Crypto.Random (drgNew)
import Data.ByteString.Char8 (ByteString)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time
import Data.Word (Word32)
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import SMPClient (testKeyHash)
import Simplex.Messaging.Agent.Client ()
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Protocol as SMP
import System.Random
import Test.Hspec
import UnliftIO.Directory (removeFile)

testDB :: String
testDB = "tests/tmp/smp-agent.test.db"

withStore :: SpecWith SQLiteStore -> Spec
withStore = before createStore . after removeStore

withStore2 :: SpecWith (SQLiteStore, SQLiteStore) -> Spec
withStore2 = before connect2 . after (removeStore . fst)
  where
    connect2 :: IO (SQLiteStore, SQLiteStore)
    connect2 = do
      s1 <- createStore
      s2 <- connectSQLiteStore (dbFilePath s1)
      pure (s1, s2)

createStore :: IO SQLiteStore
createStore = do
  -- Randomize DB file name to avoid SQLite IO errors supposedly caused by asynchronous
  -- IO operations on multiple similarly named files; error seems to be environment specific
  r <- randomIO :: IO Word32
  createSQLiteStore (testDB <> show r) Migrations.app True

removeStore :: SQLiteStore -> IO ()
removeStore db = do
  close db
  removeFile $ dbFilePath db
  where
    close :: SQLiteStore -> IO ()
    close st = mapM_ DB.close =<< atomically (tryTakeTMVar $ dbConnection st)

-- TODO add null port tests
storeTests :: Spec
storeTests = do
  withStore2 $ do
    describe "stress test" testConcurrentWrites
  withStore $ do
    describe "db setup" $ do
      testCompiledThreadsafe
      testForeignKeysEnabled
    describe "db methods" $ do
      describe "Queue and Connection management" $ do
        describe "createRcvConn" $ do
          testCreateRcvConn
          testCreateRcvConnRandomId
          testCreateRcvConnDuplicate
        describe "createSndConn" $ do
          testCreateSndConn
          testCreateSndConnRandomID
          testCreateSndConnDuplicate
        describe "getRcvConn" testGetRcvConn
        describe "deleteConn" $ do
          testDeleteRcvConn
          testDeleteSndConn
          testDeleteDuplexConn
        describe "upgradeRcvConnToDuplex" $ do
          testUpgradeRcvConnToDuplex
        describe "upgradeSndConnToDuplex" $ do
          testUpgradeSndConnToDuplex
        describe "set Queue status" $ do
          describe "setRcvQueueStatus" $ do
            testSetRcvQueueStatus
          describe "setSndQueueStatus" $ do
            testSetSndQueueStatus
          testSetQueueStatusDuplex
      describe "Msg management" $ do
        describe "create Msg" $ do
          testCreateRcvMsg
          testCreateSndMsg
          testCreateRcvAndSndMsgs

testConcurrentWrites :: SpecWith (SQLiteStore, SQLiteStore)
testConcurrentWrites =
  it "should complete multiple concurrent write transactions w/t sqlite busy errors" $ \(s1, s2) -> do
    g <- newTVarIO =<< drgNew
    _ <- withTransaction s1 $ \db ->
      createRcvConn db g cData1 rcvQueue1 SCMInvitation
    let ConnData {connId} = cData1
    concurrently_ (runTest s1 connId) (runTest s2 connId)
  where
    runTest :: SQLiteStore -> ConnId -> IO ()
    runTest st connId = replicateM_ 100 . withTransaction st $ \db -> do
      (internalId, internalRcvId, _, _) <- updateRcvIds db connId
      let rcvMsgData = mkRcvMsgData internalId internalRcvId 0 "0" "hash_dummy"
      createRcvMsg db connId rcvMsgData

testCompiledThreadsafe :: SpecWith SQLiteStore
testCompiledThreadsafe =
  it "compiled sqlite library should be threadsafe" . withStoreTransaction $ \db -> do
    compileOptions <- DB.query_ db "pragma COMPILE_OPTIONS;" :: IO [[T.Text]]
    compileOptions `shouldNotContain` [["THREADSAFE=0"]]

withStoreTransaction :: (DB.Connection -> IO a) -> SQLiteStore -> IO a
withStoreTransaction = flip withTransaction

testForeignKeysEnabled :: SpecWith SQLiteStore
testForeignKeysEnabled =
  it "foreign keys should be enabled" . withStoreTransaction $ \db -> do
    let inconsistentQuery =
          [sql|
            INSERT INTO snd_queues
              ( host, port, snd_id, conn_id, snd_private_key, e2e_dh_secret, status)
            VALUES
              ('smp.simplex.im', '5223', '1234', '2345', x'', x'', 'new');
          |]
    DB.execute_ db inconsistentQuery
      `shouldThrow` (\e -> DB.sqlError e == DB.ErrorConstraint)

cData1 :: ConnData
cData1 = ConnData {connId = "conn1", connAgentVersion = 1, duplexHandshake = Nothing}

testPrivateSignKey :: C.APrivateSignKey
testPrivateSignKey = C.APrivateSignKey C.SEd25519 "MC4CAQAwBQYDK2VwBCIEIDfEfevydXXfKajz3sRkcQ7RPvfWUPoq6pu1TYHV1DEe"

testPrivDhKey :: C.PrivateKeyX25519
testPrivDhKey = "MC4CAQAwBQYDK2VuBCIEINCzbVFaCiYHoYncxNY8tSIfn0pXcIAhLBfFc0m+gOpk"

testDhSecret :: C.DhSecretX25519
testDhSecret = "01234567890123456789012345678901"

rcvQueue1 :: RcvQueue
rcvQueue1 =
  RcvQueue
    { server = SMPServer "smp.simplex.im" "5223" testKeyHash,
      rcvId = "1234",
      rcvPrivateKey = testPrivateSignKey,
      rcvDhSecret = testDhSecret,
      e2ePrivKey = testPrivDhKey,
      e2eDhSecret = Nothing,
      sndId = Just "2345",
      status = New,
      clientNtfCreds = Nothing
    }

sndQueue1 :: SndQueue
sndQueue1 =
  SndQueue
    { server = SMPServer "smp.simplex.im" "5223" testKeyHash,
      sndId = "3456",
      sndPublicKey = Nothing,
      sndPrivateKey = testPrivateSignKey,
      e2ePubKey = Nothing,
      e2eDhSecret = testDhSecret,
      status = New
    }

testCreateRcvConn :: SpecWith SQLiteStore
testCreateRcvConn =
  it "should create RcvConnection and add SndQueue" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    createRcvConn db g cData1 rcvQueue1 SCMInvitation
      `shouldReturn` Right "conn1"
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rcvQueue1))
    upgradeRcvConnToDuplex db "conn1" sndQueue1
      `shouldReturn` Right ()
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1))

testCreateRcvConnRandomId :: SpecWith SQLiteStore
testCreateRcvConnRandomId =
  it "should create RcvConnection and add SndQueue with random ID" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    Right connId <- createRcvConn db g cData1 {connId = ""} rcvQueue1 SCMInvitation
    getConn db connId
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 {connId} rcvQueue1))
    upgradeRcvConnToDuplex db connId sndQueue1
      `shouldReturn` Right ()
    getConn db connId
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 {connId} rcvQueue1 sndQueue1))

testCreateRcvConnDuplicate :: SpecWith SQLiteStore
testCreateRcvConnDuplicate =
  it "should throw error on attempt to create duplicate RcvConnection" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    createRcvConn db g cData1 rcvQueue1 SCMInvitation
      `shouldReturn` Left (SEConnDuplicate)

testCreateSndConn :: SpecWith SQLiteStore
testCreateSndConn =
  it "should create SndConnection and add RcvQueue" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    createSndConn db g cData1 sndQueue1
      `shouldReturn` Right "conn1"
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 sndQueue1))
    upgradeSndConnToDuplex db "conn1" rcvQueue1
      `shouldReturn` Right ()
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1))

testCreateSndConnRandomID :: SpecWith SQLiteStore
testCreateSndConnRandomID =
  it "should create SndConnection and add RcvQueue with random ID" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    Right connId <- createSndConn db g cData1 {connId = ""} sndQueue1
    getConn db connId
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 {connId} sndQueue1))
    upgradeSndConnToDuplex db connId rcvQueue1
      `shouldReturn` Right ()
    getConn db connId
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 {connId} rcvQueue1 sndQueue1))

testCreateSndConnDuplicate :: SpecWith SQLiteStore
testCreateSndConnDuplicate =
  it "should throw error on attempt to create duplicate SndConnection" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createSndConn db g cData1 sndQueue1
    createSndConn db g cData1 sndQueue1
      `shouldReturn` Left (SEConnDuplicate)

testGetRcvConn :: SpecWith SQLiteStore
testGetRcvConn =
  it "should get connection using rcv queue id and server" . withStoreTransaction $ \db -> do
    let smpServer = SMPServer "smp.simplex.im" "5223" testKeyHash
    let recipientId = "1234"
    g <- newTVarIO =<< drgNew
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    getRcvConn db smpServer recipientId
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rcvQueue1))

testDeleteRcvConn :: SpecWith SQLiteStore
testDeleteRcvConn =
  it "should create RcvConnection and delete it" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rcvQueue1))
    deleteConn db "conn1"
      `shouldReturn` ()
    -- TODO check queues are deleted as well
    getConn db "conn1"
      `shouldReturn` Left (SEConnNotFound)

testDeleteSndConn :: SpecWith SQLiteStore
testDeleteSndConn =
  it "should create SndConnection and delete it" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createSndConn db g cData1 sndQueue1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 sndQueue1))
    deleteConn db "conn1"
      `shouldReturn` ()
    -- TODO check queues are deleted as well
    getConn db "conn1"
      `shouldReturn` Left (SEConnNotFound)

testDeleteDuplexConn :: SpecWith SQLiteStore
testDeleteDuplexConn =
  it "should create DuplexConnection and delete it" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    _ <- upgradeRcvConnToDuplex db "conn1" sndQueue1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1))
    deleteConn db "conn1"
      `shouldReturn` ()
    -- TODO check queues are deleted as well
    getConn db "conn1"
      `shouldReturn` Left (SEConnNotFound)

testUpgradeRcvConnToDuplex :: SpecWith SQLiteStore
testUpgradeRcvConnToDuplex =
  it "should throw error on attempt to add SndQueue to SndConnection or DuplexConnection" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createSndConn db g cData1 sndQueue1
    let anotherSndQueue =
          SndQueue
            { server = SMPServer "smp.simplex.im" "5223" testKeyHash,
              sndId = "2345",
              sndPublicKey = Nothing,
              sndPrivateKey = testPrivateSignKey,
              e2ePubKey = Nothing,
              e2eDhSecret = testDhSecret,
              status = New
            }
    upgradeRcvConnToDuplex db "conn1" anotherSndQueue
      `shouldReturn` Left (SEBadConnType CSnd)
    _ <- upgradeSndConnToDuplex db "conn1" rcvQueue1
    upgradeRcvConnToDuplex db "conn1" anotherSndQueue
      `shouldReturn` Left (SEBadConnType CDuplex)

testUpgradeSndConnToDuplex :: SpecWith SQLiteStore
testUpgradeSndConnToDuplex =
  it "should throw error on attempt to add RcvQueue to RcvConnection or DuplexConnection" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    let anotherRcvQueue =
          RcvQueue
            { server = SMPServer "smp.simplex.im" "5223" testKeyHash,
              rcvId = "3456",
              rcvPrivateKey = testPrivateSignKey,
              rcvDhSecret = testDhSecret,
              e2ePrivKey = testPrivDhKey,
              e2eDhSecret = Nothing,
              sndId = Just "4567",
              status = New,
              clientNtfCreds = Nothing
            }
    upgradeSndConnToDuplex db "conn1" anotherRcvQueue
      `shouldReturn` Left (SEBadConnType CRcv)
    _ <- upgradeRcvConnToDuplex db "conn1" sndQueue1
    upgradeSndConnToDuplex db "conn1" anotherRcvQueue
      `shouldReturn` Left (SEBadConnType CDuplex)

testSetRcvQueueStatus :: SpecWith SQLiteStore
testSetRcvQueueStatus =
  it "should update status of RcvQueue" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rcvQueue1))
    setRcvQueueStatus db rcvQueue1 Confirmed
      `shouldReturn` ()
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCRcv (RcvConnection cData1 rcvQueue1 {status = Confirmed}))

testSetSndQueueStatus :: SpecWith SQLiteStore
testSetSndQueueStatus =
  it "should update status of SndQueue" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createSndConn db g cData1 sndQueue1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 sndQueue1))
    setSndQueueStatus db sndQueue1 Confirmed
      `shouldReturn` ()
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCSnd (SndConnection cData1 sndQueue1 {status = Confirmed}))

testSetQueueStatusDuplex :: SpecWith SQLiteStore
testSetQueueStatusDuplex =
  it "should update statuses of RcvQueue and SndQueue in DuplexConnection" . withStoreTransaction $ \db -> do
    g <- newTVarIO =<< drgNew
    _ <- createRcvConn db g cData1 rcvQueue1 SCMInvitation
    _ <- upgradeRcvConnToDuplex db "conn1" sndQueue1
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 sndQueue1))
    setRcvQueueStatus db rcvQueue1 Secured
      `shouldReturn` ()
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 {status = Secured} sndQueue1))
    setSndQueueStatus db sndQueue1 Confirmed
      `shouldReturn` ()
    getConn db "conn1"
      `shouldReturn` Right (SomeConn SCDuplex (DuplexConnection cData1 rcvQueue1 {status = Secured} sndQueue1 {status = Confirmed}))

hw :: ByteString
hw = encodeUtf8 "Hello world!"

ts :: UTCTime
ts = UTCTime (fromGregorian 2021 02 24) (secondsToDiffTime 0)

mkRcvMsgData :: InternalId -> InternalRcvId -> ExternalSndId -> BrokerId -> MsgHash -> RcvMsgData
mkRcvMsgData internalId internalRcvId externalSndId brokerId internalHash =
  RcvMsgData
    { internalRcvId,
      msgMeta =
        MsgMeta
          { integrity = MsgOk,
            recipient = (unId internalId, ts),
            sndMsgId = externalSndId,
            broker = (brokerId, ts)
          },
      msgType = AM_A_MSG_,
      msgFlags = SMP.noMsgFlags,
      msgBody = hw,
      internalHash,
      externalPrevSndHash = "hash_from_sender"
    }

testCreateRcvMsg_ :: DB.Connection -> PrevExternalSndId -> PrevRcvMsgHash -> ConnId -> RcvMsgData -> Expectation
testCreateRcvMsg_ db expectedPrevSndId expectedPrevHash connId rcvMsgData@RcvMsgData {..} = do
  let MsgMeta {recipient = (internalId, _)} = msgMeta
  updateRcvIds db connId
    `shouldReturn` (InternalId internalId, internalRcvId, expectedPrevSndId, expectedPrevHash)
  createRcvMsg db connId rcvMsgData
    `shouldReturn` ()

testCreateRcvMsg :: SpecWith SQLiteStore
testCreateRcvMsg =
  it "should reserve internal ids and create a RcvMsg" $ \st -> do
    g <- newTVarIO =<< drgNew
    let ConnData {connId} = cData1
    _ <- withTransaction st $ \db -> do
      createRcvConn db g cData1 rcvQueue1 SCMInvitation
    withTransaction st $ \db -> do
      testCreateRcvMsg_ db 0 "" connId $ mkRcvMsgData (InternalId 1) (InternalRcvId 1) 1 "1" "hash_dummy"
      testCreateRcvMsg_ db 1 "hash_dummy" connId $ mkRcvMsgData (InternalId 2) (InternalRcvId 2) 2 "2" "new_hash_dummy"

mkSndMsgData :: InternalId -> InternalSndId -> MsgHash -> SndMsgData
mkSndMsgData internalId internalSndId internalHash =
  SndMsgData
    { internalId,
      internalSndId,
      internalTs = ts,
      msgType = AM_A_MSG_,
      msgFlags = SMP.noMsgFlags,
      msgBody = hw,
      internalHash,
      prevMsgHash = internalHash
    }

testCreateSndMsg_ :: DB.Connection -> PrevSndMsgHash -> ConnId -> SndMsgData -> Expectation
testCreateSndMsg_ db expectedPrevHash connId sndMsgData@SndMsgData {..} = do
  updateSndIds db connId
    `shouldReturn` (internalId, internalSndId, expectedPrevHash)
  createSndMsg db connId sndMsgData
    `shouldReturn` ()

testCreateSndMsg :: SpecWith SQLiteStore
testCreateSndMsg =
  it "should create a SndMsg and return InternalId and PrevSndMsgHash" $ \st -> do
    g <- newTVarIO =<< drgNew
    let ConnData {connId} = cData1
    _ <- withTransaction st $ \db -> do
      createSndConn db g cData1 sndQueue1
    withTransaction st $ \db -> do
      testCreateSndMsg_ db "" connId $ mkSndMsgData (InternalId 1) (InternalSndId 1) "hash_dummy"
      testCreateSndMsg_ db "hash_dummy" connId $ mkSndMsgData (InternalId 2) (InternalSndId 2) "new_hash_dummy"

testCreateRcvAndSndMsgs :: SpecWith SQLiteStore
testCreateRcvAndSndMsgs =
  it "should create multiple RcvMsg and SndMsg, correctly ordering internal Ids and returning previous state" $ \st -> do
    let ConnData {connId} = cData1
    _ <- withTransaction st $ \db -> do
      g <- newTVarIO =<< drgNew
      createRcvConn db g cData1 rcvQueue1 SCMInvitation
    withTransaction st $ \db -> do
      _ <- upgradeRcvConnToDuplex db "conn1" sndQueue1
      testCreateRcvMsg_ db 0 "" connId $ mkRcvMsgData (InternalId 1) (InternalRcvId 1) 1 "1" "rcv_hash_1"
      testCreateRcvMsg_ db 1 "rcv_hash_1" connId $ mkRcvMsgData (InternalId 2) (InternalRcvId 2) 2 "2" "rcv_hash_2"
      testCreateSndMsg_ db "" connId $ mkSndMsgData (InternalId 3) (InternalSndId 1) "snd_hash_1"
      testCreateRcvMsg_ db 2 "rcv_hash_2" connId $ mkRcvMsgData (InternalId 4) (InternalRcvId 3) 3 "3" "rcv_hash_3"
      testCreateSndMsg_ db "snd_hash_1" connId $ mkSndMsgData (InternalId 5) (InternalSndId 2) "snd_hash_2"
      testCreateSndMsg_ db "snd_hash_2" connId $ mkSndMsgData (InternalId 6) (InternalSndId 3) "snd_hash_3"
