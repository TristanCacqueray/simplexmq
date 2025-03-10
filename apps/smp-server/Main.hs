{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Logger.Simple
import Data.Functor (($>))
import Data.Ini (lookupValue)
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.CLI (ServerCLIConfig (..), protocolServerCLI, readStrictIni)
import Simplex.Messaging.Server.Env.STM (ServerConfig (..), defaultInactiveClientExpiration, defaultMessageExpiration)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (simplexMQVersion, supportedSMPServerVRange)
import System.FilePath (combine)

cfgPath :: FilePath
cfgPath = "/etc/opt/simplex"

logPath :: FilePath
logPath = "/var/opt/simplex"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogInfo
  withGlobalLogging logCfg . protocolServerCLI smpServerCLIConfig $ \cfg@ServerConfig {inactiveClientExpiration} -> do
    putStrLn $ case inactiveClientExpiration of
      Just ExpirationConfig {ttl, checkInterval} -> "expiring clients inactive for " <> show ttl <> " seconds every " <> show checkInterval <> " seconds"
      _ -> "not expiring inactive clients"
    runSMPServer cfg

smpServerCLIConfig :: ServerCLIConfig ServerConfig
smpServerCLIConfig =
  let caCrtFile = combine cfgPath "ca.crt"
      serverKeyFile = combine cfgPath "server.key"
      serverCrtFile = combine cfgPath "server.crt"
   in ServerCLIConfig
        { cfgDir = cfgPath,
          logDir = logPath,
          iniFile = combine cfgPath "smp-server.ini",
          storeLogFile = combine logPath "smp-server-store.log",
          caKeyFile = combine cfgPath "ca.key",
          caCrtFile,
          serverKeyFile,
          serverCrtFile,
          fingerprintFile = combine cfgPath "fingerprint",
          defaultServerPort = "5223",
          executableName = "smp-server",
          serverVersion = "SMP server v" <> simplexMQVersion,
          mkIniFile = \enableStoreLog defaultServerPort ->
            "[STORE_LOG]\n\
            \# The server uses STM memory for persistence,\n\
            \# that will be lost on restart (e.g., as with redis).\n\
            \# This option enables saving memory to append only log,\n\
            \# and restoring it when the server is started.\n\
            \# Log is compacted on start (deleted objects are removed).\n"
              <> ("enable: " <> (if enableStoreLog then "on" else "off") <> "\n")
              <> "# Undelivered messages are optionally saved and restored when the server restarts,\n\
                 \# they are preserved in the .bak file until the next restart.\n"
              <> ("restore_messages: " <> (if enableStoreLog then "on" else "off") <> "\n")
              <> ("log_stats: off\n\n")
              <> "[TRANSPORT]\n"
              <> ("port: " <> defaultServerPort <> "\n")
              <> "websockets: off\n\n"
              <> "[INACTIVE_CLIENTS]\n\
                 \# TTL and interval to check inactive clients\n\
                 \disconnect: off\n"
              <> ("# ttl: " <> show (ttl defaultInactiveClientExpiration) <> "\n")
              <> ("# check_interval: " <> show (checkInterval defaultInactiveClientExpiration) <> "\n"),
          mkServerConfig = \storeLogFile transports ini ->
            let settingIsOn section name = if lookupValue section name ini == Right "on" then Just () else Nothing
                logStats = settingIsOn "STORE_LOG" "log_stats"
             in ServerConfig
                  { transports,
                    tbqSize = 16,
                    serverTbqSize = 64,
                    msgQueueQuota = 128,
                    queueIdBytes = 24,
                    msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
                    caCertificateFile = caCrtFile,
                    privateKeyFile = serverKeyFile,
                    certificateFile = serverCrtFile,
                    storeLogFile,
                    storeMsgsFile =
                      let messagesPath = combine logPath "smp-server-messages.log"
                       in case lookupValue "STORE_LOG" "restore_messages" ini of
                            Right "on" -> Just messagesPath
                            Right _ -> Nothing
                            -- if the setting is not set, it is enabled when store log is enabled
                            _ -> storeLogFile $> messagesPath,
                    allowNewQueues = True,
                    messageExpiration = Just defaultMessageExpiration,
                    inactiveClientExpiration =
                      settingIsOn "INACTIVE_CLIENTS" "disconnect"
                        $> ExpirationConfig
                          { ttl = readStrictIni "INACTIVE_CLIENTS" "ttl" ini,
                            checkInterval = readStrictIni "INACTIVE_CLIENTS" "check_interval" ini
                          },
                    logStatsInterval = logStats $> 86400, -- seconds
                    logStatsStartTime = 0, -- seconds from 00:00 UTC
                    serverStatsLogFile = combine logPath "smp-server-stats.daily.log",
                    serverStatsBackupFile = logStats $> combine logPath "smp-server-stats.log",
                    smpServerVRange = supportedSMPServerVRange
                  }
        }
