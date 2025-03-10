{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

-- |
-- Module      : Simplex.Messaging.Agent.Protocol
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- Types, parsers, serializers and functions to send and receive SMP agent protocol commands and responses.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md
module Simplex.Messaging.Agent.Protocol
  ( -- * Protocol parameters
    currentSMPAgentVersion,
    supportedSMPAgentVRange,
    e2eEncConnInfoLength,
    e2eEncUserMsgLength,

    -- * SMP agent protocol types
    ConnInfo,
    ACommand (..),
    AParty (..),
    SAParty (..),
    MsgHash,
    MsgMeta (..),
    ConnectionStats (..),
    SMPConfirmation (..),
    AgentMsgEnvelope (..),
    AgentMessage (..),
    AgentMessageType (..),
    APrivHeader (..),
    AMessage (..),
    SMPServer,
    pattern SMPServer,
    SrvLoc (..),
    SMPQueueUri (..),
    SMPQueueInfo (..),
    ConnectionMode (..),
    SConnectionMode (..),
    AConnectionMode (..),
    cmInvitation,
    cmContact,
    ConnectionModeI (..),
    ConnectionRequestUri (..),
    AConnectionRequestUri (..),
    ConnReqUriData (..),
    ConnReqScheme (..),
    simplexChat,
    AgentErrorType (..),
    CommandErrorType (..),
    ConnectionErrorType (..),
    BrokerErrorType (..),
    SMPAgentError (..),
    ATransmission,
    ATransmissionOrError,
    ARawTransmission,
    ConnId,
    ConfirmationId,
    InvitationId,
    MsgIntegrity (..),
    MsgErrorType (..),
    QueueStatus (..),
    ACorrId,
    AgentMsgId,
    NotificationsMode (..),
    NotificationInfo (..),

    -- * Encode/decode
    serializeCommand,
    connMode,
    connMode',
    commandP,
    connModeT,
    serializeQueueStatus,
    queueStatusT,
    agentMessageType,

    -- * TCP transport functions
    tPut,
    tGet,
    tPutRaw,
    tGetRaw,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad.IO.Class
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Composition ((.:), (.:.))
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind (Type)
import qualified Data.List.NonEmpty as L
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.System (SystemTime)
import Data.Time.ISO8601
import Data.Type.Equality
import Data.Typeable ()
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import Simplex.Messaging.Agent.QueryString
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (E2ERatchetParams, E2ERatchetParamsUri)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol
  ( ErrorType,
    MsgBody,
    MsgFlags,
    MsgId,
    NMsgMeta,
    SMPServer,
    SndPublicVerifyKey,
    SrvLoc (..),
    pattern SMPServer,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (Transport (..), TransportError, serializeTransportError, transportErrorP)
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import Test.QuickCheck (Arbitrary (..))
import Text.Read
import UnliftIO.Exception (Exception)

currentSMPAgentVersion :: Version
currentSMPAgentVersion = 2

supportedSMPAgentVRange :: VersionRange
supportedSMPAgentVRange = mkVersionRange 1 currentSMPAgentVersion

-- it is shorter to allow all handshake headers,
-- including E2E (double-ratchet) parameters and
-- signing key of the sender for the server
e2eEncConnInfoLength :: Int
e2eEncConnInfoLength = 14848

e2eEncUserMsgLength :: Int
e2eEncUserMsgLength = 15856

-- | Raw (unparsed) SMP agent protocol transmission.
type ARawTransmission = (ByteString, ByteString, ByteString)

-- | Parsed SMP agent protocol transmission.
type ATransmission p = (ACorrId, ConnId, ACommand p)

-- | SMP agent protocol transmission or transmission error.
type ATransmissionOrError p = (ACorrId, ConnId, Either AgentErrorType (ACommand p))

type ACorrId = ByteString

-- | SMP agent protocol participants.
data AParty = Agent | Client
  deriving (Eq, Show)

-- | Singleton types for SMP agent protocol participants.
data SAParty :: AParty -> Type where
  SAgent :: SAParty Agent
  SClient :: SAParty Client

deriving instance Show (SAParty p)

deriving instance Eq (SAParty p)

instance TestEquality SAParty where
  testEquality SAgent SAgent = Just Refl
  testEquality SClient SClient = Just Refl
  testEquality _ _ = Nothing

data ACmd = forall p. ACmd (SAParty p) (ACommand p)

deriving instance Show ACmd

type ConnInfo = ByteString

-- | Parameterized type for SMP agent protocol commands and responses from all participants.
data ACommand (p :: AParty) where
  NEW :: AConnectionMode -> ACommand Client -- response INV
  INV :: AConnectionRequestUri -> ACommand Agent
  JOIN :: AConnectionRequestUri -> ConnInfo -> ACommand Client -- response OK
  CONF :: ConfirmationId -> [SMPServer] -> ConnInfo -> ACommand Agent -- ConnInfo is from sender, [SMPServer] will be empty only in v1 handshake
  LET :: ConfirmationId -> ConnInfo -> ACommand Client -- ConnInfo is from client
  REQ :: InvitationId -> L.NonEmpty SMPServer -> ConnInfo -> ACommand Agent -- ConnInfo is from sender
  ACPT :: InvitationId -> ConnInfo -> ACommand Client -- ConnInfo is from client
  RJCT :: InvitationId -> ACommand Client
  INFO :: ConnInfo -> ACommand Agent
  CON :: ACommand Agent -- notification that connection is established
  SUB :: ACommand Client
  END :: ACommand Agent
  DOWN :: SMPServer -> [ConnId] -> ACommand Agent
  UP :: SMPServer -> [ConnId] -> ACommand Agent
  SEND :: MsgFlags -> MsgBody -> ACommand Client
  MID :: AgentMsgId -> ACommand Agent
  SENT :: AgentMsgId -> ACommand Agent
  MERR :: AgentMsgId -> AgentErrorType -> ACommand Agent
  MSG :: MsgMeta -> MsgFlags -> MsgBody -> ACommand Agent
  ACK :: AgentMsgId -> ACommand Client
  OFF :: ACommand Client
  DEL :: ACommand Client
  CHK :: ACommand Client
  STAT :: ConnectionStats -> ACommand Agent
  OK :: ACommand Agent
  ERR :: AgentErrorType -> ACommand Agent
  SUSPENDED :: ACommand Agent

deriving instance Eq (ACommand p)

deriving instance Show (ACommand p)

data ConnectionStats = ConnectionStats
  { rcvServers :: [SMPServer],
    sndServers :: [SMPServer]
  }
  deriving (Eq, Show, Generic)

instance StrEncoding ConnectionStats where
  strEncode ConnectionStats {rcvServers, sndServers} =
    "rcv=" <> strEncodeList rcvServers <> " snd=" <> strEncodeList sndServers
  strP = do
    rcvServers <- "rcv=" *> strListP
    sndServers <- " snd=" *> strListP
    pure ConnectionStats {rcvServers, sndServers}

instance ToJSON ConnectionStats where toEncoding = J.genericToEncoding J.defaultOptions

data NotificationsMode = NMPeriodic | NMInstant
  deriving (Eq, Show)

instance StrEncoding NotificationsMode where
  strEncode = \case
    NMPeriodic -> "PERIODIC"
    NMInstant -> "INSTANT"
  strP =
    A.takeTill (== ' ') >>= \case
      "PERIODIC" -> pure NMPeriodic
      "INSTANT" -> pure NMInstant
      _ -> fail "bad NotificationsMode"

instance ToJSON NotificationsMode where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance ToField NotificationsMode where toField = toField . strEncode

instance FromField NotificationsMode where fromField = blobFieldDecoder $ parseAll strP

data NotificationInfo = NotificationInfo
  { ntfConnId :: ConnId,
    ntfTs :: SystemTime,
    ntfMsgMeta :: Maybe NMsgMeta
  }
  deriving (Show)

data ConnectionMode = CMInvitation | CMContact
  deriving (Eq, Show)

data SConnectionMode (m :: ConnectionMode) where
  SCMInvitation :: SConnectionMode CMInvitation
  SCMContact :: SConnectionMode CMContact

deriving instance Eq (SConnectionMode m)

deriving instance Show (SConnectionMode m)

instance TestEquality SConnectionMode where
  testEquality SCMInvitation SCMInvitation = Just Refl
  testEquality SCMContact SCMContact = Just Refl
  testEquality _ _ = Nothing

data AConnectionMode = forall m. ConnectionModeI m => ACM (SConnectionMode m)

instance Eq AConnectionMode where
  ACM m == ACM m' = isJust $ testEquality m m'

cmInvitation :: AConnectionMode
cmInvitation = ACM SCMInvitation

cmContact :: AConnectionMode
cmContact = ACM SCMContact

deriving instance Show AConnectionMode

connMode :: SConnectionMode m -> ConnectionMode
connMode SCMInvitation = CMInvitation
connMode SCMContact = CMContact

connMode' :: ConnectionMode -> AConnectionMode
connMode' CMInvitation = cmInvitation
connMode' CMContact = cmContact

class ConnectionModeI (m :: ConnectionMode) where sConnectionMode :: SConnectionMode m

instance ConnectionModeI CMInvitation where sConnectionMode = SCMInvitation

instance ConnectionModeI CMContact where sConnectionMode = SCMContact

type MsgHash = ByteString

-- | Agent message metadata sent to the client
data MsgMeta = MsgMeta
  { integrity :: MsgIntegrity,
    recipient :: (AgentMsgId, UTCTime),
    broker :: (MsgId, UTCTime),
    sndMsgId :: AgentMsgId
  }
  deriving (Eq, Show)

data SMPConfirmation = SMPConfirmation
  { -- | sender's public key to use for authentication of sender's commands at the recepient's server
    senderKey :: SndPublicVerifyKey,
    -- | sender's DH public key for simple per-queue e2e encryption
    e2ePubKey :: C.PublicKeyX25519,
    -- | sender's information to be associated with the connection, e.g. sender's profile information
    connInfo :: ConnInfo,
    -- | optional reply queues included in confirmation (added in agent protocol v2)
    smpReplyQueues :: [SMPQueueInfo]
  }
  deriving (Show)

data AgentMsgEnvelope
  = AgentConfirmation
      { agentVersion :: Version,
        e2eEncryption :: Maybe (E2ERatchetParams 'C.X448),
        encConnInfo :: ByteString
      }
  | AgentMsgEnvelope
      { agentVersion :: Version,
        encAgentMessage :: ByteString
      }
  | AgentInvitation -- the connInfo in contactInvite is only encrypted with per-queue E2E, not with double ratchet,
      { agentVersion :: Version,
        connReq :: ConnectionRequestUri 'CMInvitation,
        connInfo :: ByteString -- this message is only encrypted with per-queue E2E, not with double ratchet,
      }
  deriving (Show)

instance Encoding AgentMsgEnvelope where
  smpEncode = \case
    AgentConfirmation {agentVersion, e2eEncryption, encConnInfo} ->
      smpEncode (agentVersion, 'C', e2eEncryption, Tail encConnInfo)
    AgentMsgEnvelope {agentVersion, encAgentMessage} ->
      smpEncode (agentVersion, 'M', Tail encAgentMessage)
    AgentInvitation {agentVersion, connReq, connInfo} ->
      smpEncode (agentVersion, 'I', Large $ strEncode connReq, Tail connInfo)
  smpP = do
    agentVersion <- smpP
    smpP >>= \case
      'C' -> do
        (e2eEncryption, Tail encConnInfo) <- smpP
        pure AgentConfirmation {agentVersion, e2eEncryption, encConnInfo}
      'M' -> do
        Tail encAgentMessage <- smpP
        pure AgentMsgEnvelope {agentVersion, encAgentMessage}
      'I' -> do
        connReq <- strDecode . unLarge <$?> smpP
        Tail connInfo <- smpP
        pure AgentInvitation {agentVersion, connReq, connInfo}
      _ -> fail "bad AgentMsgEnvelope"

-- SMP agent message formats (after double ratchet decryption,
-- or in case of AgentInvitation - in plain text body)
data AgentMessage
  = AgentConnInfo ConnInfo
  | -- AgentConnInfoReply is only used in duplexHandshake mode (v2), allowing to include reply queue(s) in the initial confirmation.
    -- It makes REPLY message unnecessary.
    AgentConnInfoReply (L.NonEmpty SMPQueueInfo) ConnInfo
  | AgentMessage APrivHeader AMessage
  deriving (Show)

instance Encoding AgentMessage where
  smpEncode = \case
    AgentConnInfo cInfo -> smpEncode ('I', Tail cInfo)
    AgentConnInfoReply smpQueues cInfo -> smpEncode ('D', smpQueues, Tail cInfo) -- 'D' stands for "duplex"
    AgentMessage hdr aMsg -> smpEncode ('M', hdr, aMsg)
  smpP =
    smpP >>= \case
      'I' -> AgentConnInfo . unTail <$> smpP
      'D' -> AgentConnInfoReply <$> smpP <*> (unTail <$> smpP)
      'M' -> AgentMessage <$> smpP <*> smpP
      _ -> fail "bad AgentMessage"

data AgentMessageType = AM_CONN_INFO | AM_CONN_INFO_REPLY | AM_HELLO_ | AM_REPLY_ | AM_A_MSG_
  deriving (Eq, Show)

instance Encoding AgentMessageType where
  smpEncode = \case
    AM_CONN_INFO -> "C"
    AM_CONN_INFO_REPLY -> "D"
    AM_HELLO_ -> "H"
    AM_REPLY_ -> "R"
    AM_A_MSG_ -> "M"
  smpP =
    A.anyChar >>= \case
      'C' -> pure AM_CONN_INFO
      'D' -> pure AM_CONN_INFO_REPLY
      'H' -> pure AM_HELLO_
      'R' -> pure AM_REPLY_
      'M' -> pure AM_A_MSG_
      _ -> fail "bad AgentMessageType"

agentMessageType :: AgentMessage -> AgentMessageType
agentMessageType = \case
  AgentConnInfo _ -> AM_CONN_INFO
  AgentConnInfoReply {} -> AM_CONN_INFO_REPLY
  AgentMessage _ aMsg -> case aMsg of
    -- HELLO is used both in v1 and in v2, but differently.
    -- - in v1 (and, possibly, in v2 for simplex connections) can be sent multiple times,
    --   until the queue is secured - the OK response from the server instead of initial AUTH errors confirms it.
    -- - in v2 duplexHandshake it is sent only once, when it is known that the queue was secured.
    HELLO -> AM_HELLO_
    -- REPLY is only used in v1
    REPLY _ -> AM_REPLY_
    A_MSG _ -> AM_A_MSG_

data APrivHeader = APrivHeader
  { -- | sequential ID assigned by the sending agent
    sndMsgId :: AgentMsgId,
    -- | digest of the previous message
    prevMsgHash :: MsgHash
  }
  deriving (Show)

instance Encoding APrivHeader where
  smpEncode APrivHeader {sndMsgId, prevMsgHash} =
    smpEncode (sndMsgId, prevMsgHash)
  smpP = APrivHeader <$> smpP <*> smpP

data AMsgType = HELLO_ | REPLY_ | A_MSG_
  deriving (Eq)

instance Encoding AMsgType where
  smpEncode = \case
    HELLO_ -> "H"
    REPLY_ -> "R"
    A_MSG_ -> "M"
  smpP =
    smpP >>= \case
      'H' -> pure HELLO_
      'R' -> pure REPLY_
      'M' -> pure A_MSG_
      _ -> fail "bad AMsgType"

-- | Messages sent between SMP agents once SMP queue is secured.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md#messages-between-smp-agents
data AMessage
  = -- | the first message in the queue to validate it is secured
    HELLO
  | -- | reply queues information
    REPLY (L.NonEmpty SMPQueueInfo)
  | -- | agent envelope for the client message
    A_MSG MsgBody
  deriving (Show)

instance Encoding AMessage where
  smpEncode = \case
    HELLO -> smpEncode HELLO_
    REPLY smpQueues -> smpEncode (REPLY_, smpQueues)
    A_MSG body -> smpEncode (A_MSG_, Tail body)
  smpP =
    smpP
      >>= \case
        HELLO_ -> pure HELLO
        REPLY_ -> REPLY <$> smpP
        A_MSG_ -> A_MSG . unTail <$> smpP

instance forall m. ConnectionModeI m => StrEncoding (ConnectionRequestUri m) where
  strEncode = \case
    CRInvitationUri crData e2eParams -> crEncode "invitation" crData (Just e2eParams)
    CRContactUri crData -> crEncode "contact" crData Nothing
    where
      crEncode :: ByteString -> ConnReqUriData -> Maybe (E2ERatchetParamsUri 'C.X448) -> ByteString
      crEncode crMode ConnReqUriData {crScheme, crAgentVRange, crSmpQueues} e2eParams =
        strEncode crScheme <> "/" <> crMode <> "#/?" <> queryStr
        where
          queryStr =
            strEncode . QSP QEscape $
              [("v", strEncode crAgentVRange), ("smp", strEncode crSmpQueues)]
                <> maybe [] (\e2e -> [("e2e", strEncode e2e)]) e2eParams
  strP = do
    ACR m cr <- strP
    case testEquality m $ sConnectionMode @m of
      Just Refl -> pure cr
      _ -> fail "bad connection request mode"

instance StrEncoding AConnectionRequestUri where
  strEncode (ACR _ cr) = strEncode cr
  strP = do
    crScheme <- strP
    crMode <- A.char '/' *> crModeP <* optional (A.char '/') <* "#/?"
    query <- strP
    crAgentVRange <- queryParam "v" query
    crSmpQueues <- queryParam "smp" query
    let crData = ConnReqUriData {crScheme, crAgentVRange, crSmpQueues}
    case crMode of
      CMInvitation -> do
        crE2eParams <- queryParam "e2e" query
        pure . ACR SCMInvitation $ CRInvitationUri crData crE2eParams
      CMContact -> pure . ACR SCMContact $ CRContactUri crData
    where
      crModeP = "invitation" $> CMInvitation <|> "contact" $> CMContact

instance ConnectionModeI m => FromJSON (ConnectionRequestUri m) where
  parseJSON = strParseJSON "ConnectionRequestUri"

instance ConnectionModeI m => ToJSON (ConnectionRequestUri m) where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON AConnectionRequestUri where
  parseJSON = strParseJSON "ConnectionRequestUri"

instance ToJSON AConnectionRequestUri where
  toJSON = strToJSON
  toEncoding = strToJEncoding

-- debug :: Show a => String -> a -> a
-- debug name value = unsafePerformIO (putStrLn $ name <> ": " <> show value) `seq` value
-- {-# INLINE debug #-}

instance StrEncoding ConnectionMode where
  strEncode = \case
    CMInvitation -> "INV"
    CMContact -> "CON"
  strP = "INV" $> CMInvitation <|> "CON" $> CMContact

instance StrEncoding AConnectionMode where
  strEncode (ACM cMode) = strEncode $ connMode cMode
  strP = connMode' <$> strP

connModeT :: Text -> Maybe ConnectionMode
connModeT = \case
  "INV" -> Just CMInvitation
  "CON" -> Just CMContact
  _ -> Nothing

-- | SMP agent connection ID.
type ConnId = ByteString

type ConfirmationId = ByteString

type InvitationId = ByteString

data SMPQueueInfo = SMPQueueInfo
  { clientVersion :: Version,
    smpServer :: SMPServer,
    senderId :: SMP.SenderId,
    dhPublicKey :: C.PublicKeyX25519
  }
  deriving (Eq, Show)

instance Encoding SMPQueueInfo where
  smpEncode SMPQueueInfo {clientVersion, smpServer, senderId, dhPublicKey} =
    smpEncode (clientVersion, smpServer, senderId, dhPublicKey)
  smpP = do
    (clientVersion, smpServer, senderId, dhPublicKey) <- smpP
    pure SMPQueueInfo {clientVersion, smpServer, senderId, dhPublicKey}

-- This instance seems contrived and there was a temptation to split a common part of both types.
-- But this is created to allow backward and forward compatibility where SMPQueueUri
-- could have more fields to convert to different versions of SMPQueueInfo in a different way,
-- and this instance would become non-trivial.
instance VersionI SMPQueueInfo where
  type VersionRangeT SMPQueueInfo = SMPQueueUri
  version = clientVersion
  toVersionRangeT SMPQueueInfo {smpServer, senderId, dhPublicKey} vr =
    SMPQueueUri {clientVRange = vr, smpServer, senderId, dhPublicKey}

instance VersionRangeI SMPQueueUri where
  type VersionT SMPQueueUri = SMPQueueInfo
  versionRange = clientVRange
  toVersionT SMPQueueUri {smpServer, senderId, dhPublicKey} v =
    SMPQueueInfo {clientVersion = v, smpServer, senderId, dhPublicKey}

-- | SMP queue information sent out-of-band.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#out-of-band-messages
data SMPQueueUri = SMPQueueUri
  { smpServer :: SMPServer,
    senderId :: SMP.SenderId,
    clientVRange :: VersionRange,
    dhPublicKey :: C.PublicKeyX25519
  }
  deriving (Eq, Show)

instance StrEncoding SMPQueueUri where
  -- v1 uses short SMP queue URI format
  strEncode SMPQueueUri {smpServer = srv, senderId = qId, clientVRange = _vr, dhPublicKey = k} =
    strEncode srv <> "/" <> strEncode qId <> "#" <> strEncode k
  strP = do
    smpServer <- strP <* A.char '/'
    senderId <- strP <* optional (A.char '/') <* A.char '#'
    (vr, dhPublicKey) <- unversioned <|> versioned
    pure SMPQueueUri {smpServer, senderId, clientVRange = vr, dhPublicKey}
    where
      unversioned = (SMP.smpClientVRange,) <$> strP <* A.endOfInput
      versioned = do
        dhKey_ <- optional strP
        query <- optional (A.char '/') *> A.char '?' *> strP
        vr <- queryParam "v" query
        dhKey <- maybe (queryParam "dh" query) pure dhKey_
        pure (vr, dhKey)

data ConnectionRequestUri (m :: ConnectionMode) where
  CRInvitationUri :: ConnReqUriData -> E2ERatchetParamsUri 'C.X448 -> ConnectionRequestUri CMInvitation
  -- contact connection request does NOT contain E2E encryption parameters -
  -- they are passed in AgentInvitation message
  CRContactUri :: ConnReqUriData -> ConnectionRequestUri CMContact

deriving instance Eq (ConnectionRequestUri m)

deriving instance Show (ConnectionRequestUri m)

data AConnectionRequestUri = forall m. ConnectionModeI m => ACR (SConnectionMode m) (ConnectionRequestUri m)

instance Eq AConnectionRequestUri where
  ACR m cr == ACR m' cr' = case testEquality m m' of
    Just Refl -> cr == cr'
    _ -> False

deriving instance Show AConnectionRequestUri

data ConnReqUriData = ConnReqUriData
  { crScheme :: ConnReqScheme,
    crAgentVRange :: VersionRange,
    crSmpQueues :: L.NonEmpty SMPQueueUri
  }
  deriving (Eq, Show)

data ConnReqScheme = CRSSimplex | CRSAppServer SrvLoc
  deriving (Eq, Show)

instance StrEncoding ConnReqScheme where
  strEncode = \case
    CRSSimplex -> "simplex:"
    CRSAppServer srv -> "https://" <> strEncode srv
  strP =
    "simplex:" $> CRSSimplex
      <|> "https://" *> (CRSAppServer <$> strP)

simplexChat :: ConnReqScheme
simplexChat = CRSAppServer $ SrvLoc "simplex.chat" ""

-- | SMP queue status.
data QueueStatus
  = -- | queue is created
    New
  | -- | queue is confirmed by the sender
    Confirmed
  | -- | queue is secured with sender key (only used by the queue recipient)
    Secured
  | -- | queue is active
    Active
  | -- | queue is disabled (only used by the queue recipient)
    Disabled
  deriving (Eq, Show, Read)

serializeQueueStatus :: QueueStatus -> Text
serializeQueueStatus = \case
  New -> "new"
  Confirmed -> "confirmed"
  Secured -> "secured"
  Active -> "active"
  Disabled -> "disabled"

queueStatusT :: Text -> Maybe QueueStatus
queueStatusT = \case
  "new" -> Just New
  "confirmed" -> Just Confirmed
  "secured" -> Just Secured
  "active" -> Just Active
  "disabled" -> Just Disabled
  _ -> Nothing

type AgentMsgId = Int64

-- | Result of received message integrity validation.
data MsgIntegrity = MsgOk | MsgError {errorInfo :: MsgErrorType}
  deriving (Eq, Show, Generic)

instance StrEncoding MsgIntegrity where
  strP = "OK" $> MsgOk <|> "ERR " *> (MsgError <$> strP)
  strEncode = \case
    MsgOk -> "OK"
    MsgError e -> "ERR" <> strEncode e

instance ToJSON MsgIntegrity where
  toJSON = J.genericToJSON $ sumTypeJSON fstToLower
  toEncoding = J.genericToEncoding $ sumTypeJSON fstToLower

instance FromJSON MsgIntegrity where
  parseJSON = J.genericParseJSON $ sumTypeJSON fstToLower

-- | Error of message integrity validation.
data MsgErrorType
  = MsgSkipped {fromMsgId :: AgentMsgId, toMsgId :: AgentMsgId}
  | MsgBadId {msgId :: AgentMsgId}
  | MsgBadHash
  | MsgDuplicate
  deriving (Eq, Show, Generic)

instance StrEncoding MsgErrorType where
  strP =
    "ID " *> (MsgBadId <$> A.decimal)
      <|> "IDS " *> (MsgSkipped <$> A.decimal <* A.space <*> A.decimal)
      <|> "HASH" $> MsgBadHash
      <|> "DUPLICATE" $> MsgDuplicate
  strEncode = \case
    MsgSkipped fromMsgId toMsgId ->
      B.unwords ["NO_ID", bshow fromMsgId, bshow toMsgId]
    MsgBadId aMsgId -> "ID " <> bshow aMsgId
    MsgBadHash -> "HASH"
    MsgDuplicate -> "DUPLICATE"

instance ToJSON MsgErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON fstToLower
  toEncoding = J.genericToEncoding $ sumTypeJSON fstToLower

instance FromJSON MsgErrorType where
  parseJSON = J.genericParseJSON $ sumTypeJSON fstToLower

-- | Error type used in errors sent to agent clients.
data AgentErrorType
  = -- | command or response error
    CMD {cmdErr :: CommandErrorType}
  | -- | connection errors
    CONN {connErr :: ConnectionErrorType}
  | -- | SMP protocol errors forwarded to agent clients
    SMP {smpErr :: ErrorType}
  | -- | NTF protocol errors forwarded to agent clients
    NTF {ntfErr :: ErrorType}
  | -- | SMP server errors
    BROKER {brokerErr :: BrokerErrorType}
  | -- | errors of other agents
    AGENT {agentErr :: SMPAgentError}
  | -- | agent implementation or dependency errors
    INTERNAL {internalErr :: String}
  deriving (Eq, Generic, Show, Exception)

instance ToJSON AgentErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

-- | SMP agent protocol command or response error.
data CommandErrorType
  = -- | command is prohibited in this context
    PROHIBITED
  | -- | command syntax is invalid
    SYNTAX
  | -- | entity ID is required with this command
    NO_CONN
  | -- | message size is not correct (no terminating space)
    SIZE
  | -- | message does not fit in SMP block
    LARGE
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON CommandErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

-- | Connection error.
data ConnectionErrorType
  = -- | connection is not in the database
    NOT_FOUND
  | -- | connection already exists
    DUPLICATE
  | -- | connection is simplex, but operation requires another queue
    SIMPLEX
  | -- | connection not accepted on join HELLO after timeout
    NOT_ACCEPTED
  | -- | connection not available on reply confirmation/HELLO after timeout
    NOT_AVAILABLE
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON ConnectionErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

-- | SMP server errors.
data BrokerErrorType
  = -- | invalid server response (failed to parse)
    RESPONSE {smpErr :: ErrorType}
  | -- | unexpected response
    UNEXPECTED
  | -- | network error
    NETWORK
  | -- | handshake or other transport error
    TRANSPORT {transportErr :: TransportError}
  | -- | command response timeout
    TIMEOUT
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON BrokerErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

-- | Errors of another SMP agent.
-- TODO encode/decode without A prefix
data SMPAgentError
  = -- | client or agent message that failed to parse
    A_MESSAGE
  | -- | prohibited SMP/agent message
    A_PROHIBITED
  | -- | incompatible version of SMP client, agent or encryption protocols
    A_VERSION
  | -- | cannot decrypt message
    A_ENCRYPTION
  | -- | duplicate message - this error is detected by ratchet decryption - this message will be ignored and not shown
    A_DUPLICATE
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON SMPAgentError where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

instance StrEncoding AgentErrorType where
  strP =
    "CMD " *> (CMD <$> parseRead1)
      <|> "CONN " *> (CONN <$> parseRead1)
      <|> "SMP " *> (SMP <$> strP)
      <|> "NTF " *> (NTF <$> strP)
      <|> "BROKER RESPONSE " *> (BROKER . RESPONSE <$> strP)
      <|> "BROKER TRANSPORT " *> (BROKER . TRANSPORT <$> transportErrorP)
      <|> "BROKER " *> (BROKER <$> parseRead1)
      <|> "AGENT " *> (AGENT <$> parseRead1)
      <|> "INTERNAL " *> (INTERNAL <$> parseRead A.takeByteString)
  strEncode = \case
    CMD e -> "CMD " <> bshow e
    CONN e -> "CONN " <> bshow e
    SMP e -> "SMP " <> strEncode e
    NTF e -> "NTF " <> strEncode e
    BROKER (RESPONSE e) -> "BROKER RESPONSE " <> strEncode e
    BROKER (TRANSPORT e) -> "BROKER TRANSPORT " <> serializeTransportError e
    BROKER e -> "BROKER " <> bshow e
    AGENT e -> "AGENT " <> bshow e
    INTERNAL e -> "INTERNAL " <> bshow e

instance Arbitrary AgentErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandErrorType where arbitrary = genericArbitraryU

instance Arbitrary ConnectionErrorType where arbitrary = genericArbitraryU

instance Arbitrary BrokerErrorType where arbitrary = genericArbitraryU

instance Arbitrary SMPAgentError where arbitrary = genericArbitraryU

-- | SMP agent command and response parser
commandP :: Parser ACmd
commandP =
  "NEW " *> newCmd
    <|> "INV " *> invResp
    <|> "JOIN " *> joinCmd
    <|> "CONF " *> confMsg
    <|> "LET " *> letCmd
    <|> "REQ " *> reqMsg
    <|> "ACPT " *> acptCmd
    <|> "RJCT " *> rjctCmd
    <|> "INFO " *> infoCmd
    <|> "SUB" $> ACmd SClient SUB
    <|> "END" $> ACmd SAgent END
    <|> "DOWN " *> downsResp
    <|> "UP " *> upsResp
    <|> "SEND " *> sendCmd
    <|> "MID " *> msgIdResp
    <|> "SENT " *> sentResp
    <|> "MERR " *> msgErrResp
    <|> "MSG " *> message
    <|> "ACK " *> ackCmd
    <|> "OFF" $> ACmd SClient OFF
    <|> "DEL" $> ACmd SClient DEL
    <|> "CHK" $> ACmd SClient CHK
    <|> "STAT " *> statResp
    <|> "ERR " *> agentError
    <|> "CON" $> ACmd SAgent CON
    <|> "OK" $> ACmd SAgent OK
  where
    newCmd = ACmd SClient . NEW <$> strP
    invResp = ACmd SAgent . INV <$> strP
    joinCmd = ACmd SClient .: JOIN <$> strP_ <*> A.takeByteString
    confMsg = ACmd SAgent .:. CONF <$> A.takeTill (== ' ') <* A.space <*> strListP <* A.space <*> A.takeByteString
    letCmd = ACmd SClient .: LET <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString
    reqMsg = ACmd SAgent .:. REQ <$> A.takeTill (== ' ') <* A.space <*> strP_ <*> A.takeByteString
    acptCmd = ACmd SClient .: ACPT <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString
    rjctCmd = ACmd SClient . RJCT <$> A.takeByteString
    infoCmd = ACmd SAgent . INFO <$> A.takeByteString
    downsResp = ACmd SAgent .: DOWN <$> strP_ <*> connections
    upsResp = ACmd SAgent .: UP <$> strP_ <*> connections
    sendCmd = ACmd SClient .: SEND <$> smpP <* A.space <*> A.takeByteString
    msgIdResp = ACmd SAgent . MID <$> A.decimal
    sentResp = ACmd SAgent . SENT <$> A.decimal
    msgErrResp = ACmd SAgent .: MERR <$> A.decimal <* A.space <*> strP
    message = ACmd SAgent .:. MSG <$> msgMetaP <* A.space <*> smpP <* A.space <*> A.takeByteString
    ackCmd = ACmd SClient . ACK <$> A.decimal
    statResp = ACmd SAgent . STAT <$> strP
    connections = strP `A.sepBy'` A.char ','
    msgMetaP = do
      integrity <- strP
      recipient <- " R=" *> partyMeta A.decimal
      broker <- " B=" *> partyMeta base64P
      sndMsgId <- " S=" *> A.decimal
      pure MsgMeta {integrity, recipient, broker, sndMsgId}
    partyMeta idParser = (,) <$> idParser <* A.char ',' <*> tsISO8601P
    agentError = ACmd SAgent . ERR <$> strP

parseCommand :: ByteString -> Either AgentErrorType ACmd
parseCommand = parse commandP $ CMD SYNTAX

-- | Serialize SMP agent command.
serializeCommand :: ACommand p -> ByteString
serializeCommand = \case
  NEW cMode -> "NEW " <> strEncode cMode
  INV cReq -> "INV " <> strEncode cReq
  JOIN cReq cInfo -> B.unwords ["JOIN", strEncode cReq, serializeBinary cInfo]
  CONF confId srvs cInfo -> B.unwords ["CONF", confId, strEncodeList srvs, serializeBinary cInfo]
  LET confId cInfo -> B.unwords ["LET", confId, serializeBinary cInfo]
  REQ invId srvs cInfo -> B.unwords ["REQ", invId, strEncode srvs, serializeBinary cInfo]
  ACPT invId cInfo -> B.unwords ["ACPT", invId, serializeBinary cInfo]
  RJCT invId -> "RJCT " <> invId
  INFO cInfo -> "INFO " <> serializeBinary cInfo
  SUB -> "SUB"
  END -> "END"
  DOWN srv conns -> B.unwords ["DOWN", strEncode srv, connections conns]
  UP srv conns -> B.unwords ["UP", strEncode srv, connections conns]
  SEND msgFlags msgBody -> "SEND " <> smpEncode msgFlags <> " " <> serializeBinary msgBody
  MID mId -> "MID " <> bshow mId
  SENT mId -> "SENT " <> bshow mId
  MERR mId e -> B.unwords ["MERR", bshow mId, strEncode e]
  MSG msgMeta msgFlags msgBody -> B.unwords ["MSG", serializeMsgMeta msgMeta, smpEncode msgFlags, serializeBinary msgBody]
  ACK mId -> "ACK " <> bshow mId
  OFF -> "OFF"
  DEL -> "DEL"
  CHK -> "CHK"
  STAT srvs -> "STAT " <> strEncode srvs
  CON -> "CON"
  ERR e -> "ERR " <> strEncode e
  OK -> "OK"
  SUSPENDED -> "SUSPENDED"
  where
    showTs :: UTCTime -> ByteString
    showTs = B.pack . formatISO8601Millis
    connections :: [ConnId] -> ByteString
    connections = B.intercalate "," . map strEncode
    serializeMsgMeta :: MsgMeta -> ByteString
    serializeMsgMeta MsgMeta {integrity, recipient = (rmId, rTs), broker = (bmId, bTs), sndMsgId} =
      B.unwords
        [ strEncode integrity,
          "R=" <> bshow rmId <> "," <> showTs rTs,
          "B=" <> encode bmId <> "," <> showTs bTs,
          "S=" <> bshow sndMsgId
        ]

serializeBinary :: ByteString -> ByteString
serializeBinary body = bshow (B.length body) <> "\n" <> body

-- | Send raw (unparsed) SMP agent protocol transmission to TCP connection.
tPutRaw :: Transport c => c -> ARawTransmission -> IO ()
tPutRaw h (corrId, entity, command) = do
  putLn h corrId
  putLn h entity
  putLn h command

-- | Receive raw (unparsed) SMP agent protocol transmission from TCP connection.
tGetRaw :: Transport c => c -> IO ARawTransmission
tGetRaw h = (,,) <$> getLn h <*> getLn h <*> getLn h

-- | Send SMP agent protocol command (or response) to TCP connection.
tPut :: (Transport c, MonadIO m) => c -> ATransmission p -> m ()
tPut h (corrId, connId, command) =
  liftIO $ tPutRaw h (corrId, connId, serializeCommand command)

-- | Receive client and agent transmissions from TCP connection.
tGet :: forall c m p. (Transport c, MonadIO m) => SAParty p -> c -> m (ATransmissionOrError p)
tGet party h = liftIO (tGetRaw h) >>= tParseLoadBody
  where
    tParseLoadBody :: ARawTransmission -> m (ATransmissionOrError p)
    tParseLoadBody t@(corrId, connId, command) = do
      let cmd = parseCommand command >>= fromParty >>= tConnId t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (corrId, connId, fullCmd)

    fromParty :: ACmd -> Either AgentErrorType (ACommand p)
    fromParty (ACmd (p :: p1) cmd) = case testEquality party p of
      Just Refl -> Right cmd
      _ -> Left $ CMD PROHIBITED

    tConnId :: ARawTransmission -> ACommand p -> Either AgentErrorType (ACommand p)
    tConnId (_, connId, _) cmd = case cmd of
      -- NEW, JOIN and ACPT have optional connId
      NEW _ -> Right cmd
      JOIN {} -> Right cmd
      ACPT {} -> Right cmd
      -- ERROR response does not always have connId
      ERR _ -> Right cmd
      DOWN {} -> Right cmd
      UP {} -> Right cmd
      -- other responses must have connId
      _
        | B.null connId -> Left $ CMD NO_CONN
        | otherwise -> Right cmd

    cmdWithMsgBody :: ACommand p -> m (Either AgentErrorType (ACommand p))
    cmdWithMsgBody = \case
      SEND msgFlags body -> SEND msgFlags <$$> getBody body
      MSG msgMeta msgFlags body -> MSG msgMeta msgFlags <$$> getBody body
      JOIN qUri cInfo -> JOIN qUri <$$> getBody cInfo
      CONF confId srvs cInfo -> CONF confId srvs <$$> getBody cInfo
      LET confId cInfo -> LET confId <$$> getBody cInfo
      REQ invId srvs cInfo -> REQ invId srvs <$$> getBody cInfo
      ACPT invId cInfo -> ACPT invId <$$> getBody cInfo
      INFO cInfo -> INFO <$$> getBody cInfo
      cmd -> pure $ Right cmd

    getBody :: ByteString -> m (Either AgentErrorType ByteString)
    getBody binary =
      case B.unpack binary of
        ':' : body -> return . Right $ B.pack body
        str -> case readMaybe str :: Maybe Int of
          Just size -> liftIO $ do
            body <- cGet h size
            s <- getLn h
            return $ if B.null s then Right body else Left $ CMD SIZE
          Nothing -> return . Left $ CMD SYNTAX
