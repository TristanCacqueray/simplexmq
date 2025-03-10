# 3.1.0

SMP server and agent:

- SMP protocol v4: batching multiple server commands/responses in a transport block.

# 3.0.0

SMP server:

- restore undeliverd messages when the server is restarted.
- SMP protocol v3 to support push notification:
  - updated SEND and MSG to add message flags (for notification flag that contros whether the notification is sent and for any future extensions) and to move message meta-data sent to the recipient into the encrypted envelope.
  - update NKEY and NID to add e2e encryption keys (for the notification meta-data encryption between SMP server and the client), and update NMSG to include this meta-data.
  - update ACK command to include message ID (to avoid acknowledging unprocessed message).
  - add NDEL commands to remove notification subscription credentials from SMP queue.
  - add GET command to receive messages without subscription - to be used in iOS notification service extension to receive messages without terminating app subscriptions.

SMP agent:

- new protocol for duplex connection handshake reducing traffic and connection time.
- support for SMP notifications server and managing device token.
- remove redundant FQDN validation from TLS handshake to prepare for access via Tor.
- support for fully stopping agent and for termporary suspending agent operations.
- improve management of duplicate message delivery.

SMP notifications server v1.0:

- SMP notifications protocol with version negotiation during handshake.
- device token registration and verification (via background notification).
- SMP notification subscriptions and push notifications via APNS.
- restoring notification subscriptions when the server is restarted.

# 2.3.0

SMP server:

- Save and restore undelivered messages, to avoid losing them. To save messages the server has to be stopped with SIGINT signal, if it is stopped with SIGTERM undelivered messages would not be saved.

# 2.2.0

SMP server:

- Fix sockets/threads/memory leak

SMP agent:

- Support stopping and resuming agent with `disconnectAgentClient` / `resumeAgentClient`

# 2.1.1

SMP server:

- gracefully close sockets on client disconnection
- CLI warning when deleting server configuration

# 2.1.0

SMP server:

- configuration to expire inactive clients in ini file, increased TTL and check interval for client expiration

# 2.0.0

Push notifications server (beta):

- supports APNS
- manage device tokens verification via notification delivery
- sending periodic background notification to check messages (not more frequent than every 20 min)

SMP server:

- disconnect inactive clients after some period
- remove undelivered messages after 30 days
- log aggregate usage daily stats: only the number of queues created/secured/deleted/used and messages sent/delivered is logged, as one line per day, so we can plan server capacity and diagnose any problems.

SMP agent:

- manage device tokens and notification server connection
- DOWN/UP events to the agent user about server disconnections/reconnections are now sent once per server

# 1.1.0

SMP server:

- message TTL and periodic deletion of old messages
- configuration to prevent creation of the new queues

SMP agent:

- asynchronous connection handshake
- configurable SMP servers at run-time
- use TCP keep-alive for connection stability
- improve stability of connection subscriptions
- auto-vacuum DB to remove deleted records

# 1.0.3

SMP server:

- Reduce server message queue quota to 128 messages.

SMP agent:

- Add "yes to migrations" option.
- Make new SMP client attempt to reconnect on network error.
- Reduce connection handshake expiration to 2 days.

JSON encoding of types used in simplex-chat, some other minor adjustments.

# 1.0.2

General:

- Enable TLS 1.3 parameters for TLS handshake (server and client).
- Switch from hs-tls fork to original repo now that it supports getFinished and getPeerFinished APIs for both TLS 1.2 and TLS 1.3.

SMP server:

- Perform TLS handshake in a separate thread per-connection.

SMP agent:

- Cease attempts to send HELLO after one week timeout.
- Coalesce requests to connect to SMP servers, to have 1 connection per server.

# 1.0.1

SMP server:

- Explicitly set line buffering in stdout/stderr to log each line when output is redirected to files.

# 1.0.0

Security and privacy improvements:

- Faster and more secure 2-layer E2E encryption with additional encryption layer between servers and recipients:
  - application messages in each duplex connection (managed by SMP agents - see [overview](https://github.com/simplex-chat/simplexmq/blob/master/protocol/overview-tjr.md)) are encrypted using [double-ratchet algorithm](https://www.signal.org/docs/specifications/doubleratchet/), providing forward secrecy and break-in recovery. This layer uses two Curve448 keys per client for [X3DH key agreement](https://www.signal.org/docs/specifications/x3dh/), SHA512 based HKDFs and AES-GCM AEAD encryption.
  - SMP client messages are additionally E2E encrypted in each SMP queue to avoid cipher-text correlation of messages sent via multiple redundant queues (that will be supported soon). This and the next layer use [NaCl crypto_box algorithm](https://nacl.cr.yp.to/index.html) with XSalsa20Poly1305 cipher and Curve25519 keys for DH key agreement.
  - Messages delivered from the servers to the recipients are additionally encrypted to avoid cipher-text correlation between sent and received messages.
- To prevent any traffic correlation by content size, SimpleX uses fixed transport block size of 16kb (16384 bytes) with padding on all encryption layers:
  - application messages are padded to 15788 bytes before E2E double-ratchet encryption.
  - messages between SMP clients are padded to 16032 bytes before E2E encryption in each SMP queue.
  - messages from the server to the recipient are padded to padded to 16088 bytes before the additional encryption layer (see above).
- TLS 1.2+ with tls-unique channel binding in each command to prevent replay attacks.
- Server identity verification via server offline certificate fingerprints included in SMP server addresses.

New functionality:

- Support for notification servers with new SMP commands: `NKEY`/`NID`, `NSUB`/`NMSG`.

Efficiency improvements:

- Binary protocol encodings to reduce overhead from circa 15% to approximately 3.7% of transmitted application message size, with only 2.2% overhead for SMP protocol messages.
- More performant cryptographic algorithms.

For more information about SimpleX:

- [SimpleX overview](https://github.com/simplex-chat/simplexmq/blob/master/protocol/overview-tjr.md).
- [SimpleX chat v1 announcement](https://github.com/simplex-chat/simplex-chat/blob/master/blog/20220112-simplex-chat-v1-released.md).

# 0.5.2

- Fix message delivery logic that blocked delivery of all server messages when server per-queue quota exceeded, making it concurrent per SMP queue, not per server.

# 0.5.1

- Fix server subscription logic bug that was leading to memory leak / resource exhaustion in some edge cases.

# 0.5.0

- No changes in SMP server implementation - it is backwards compatible with v0.4.1
- SMP agent changes:
  - URI syntax for SMP queues and connection requests.
  - long-term connections links ("contacts") in SMP agent protocol.
  - agent command changes:
    - `REQ` notification and `ACPT` command are used only with long-term connection links.
    - `CONF` notification and `LET` commands are used for normal duplex connections.

# 0.4.1

- Include migrations in the package

# 0.4.0

- SMP server implementation and [SMP protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md) changes:
  - support 3072 bit RSA key size
  - add SMP queue quotas
  - set default transport block size to 4096 bits
  - allow SMP client to change transport block size during transport connection handshake
- SMP agent implementation and protocol changes:
  - additional connection confirmation step for initiating party
  - automatically resume subscribed duplex connections once transport connection is resumed
  - passing an arbitrary binary information between parties during the duplex connection handshake - can be used to identify parties
  - asynchronous duplex connection handshake - the parties do not have to be online at the same time
  - asynchronous message delivery - the agent does not need transport connection to accept client messages for delivery
  - additional confirmation of message reception from the client to prevent message loss in case of process termination
  - set transport block size to 8192 bits (in the future the agent protocol can allow to have different block sizes for different duplex connections)
  - added client commands and notifications (see [agent protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md)):
    - `REQ` - the notification about joining party establishing connection
    - `ACPT` - the command to accept connection with the joining party
    - `INFO` - the notification with the information from the initiating party
    - `DOWN`/`UP` - the notifications about losing/resuming the connection
    - `ACK` - the command to confirm that the message reception/processing is complete
    - `MID` - the response to `SEND` confirming that the message is accepted by the agent
    - `MERR` - the notification about permanent message delivery error (e.g., `ERR AUTH` indicating that the queue was removed)

# 0.3.2

- Support websockets
- SMP server CLI commands

# 0.3.1

- Released to hackage.org
- SMP agent protocol changes:
  - move SMP server from agent commands NEW/JOIN to agent config
  - send CON to user only when the 1st party responds HELLO
- Fix REPLY vulnerability
- Fix transaction busy error

# 0.3.0

- SMP encrypted transport over TCP
- Standard X509/PKCS8 encoding for RSA keys
- Sign and verify agent messages
- Verify message integrity based on previous message hash and ID
- Prevent timing attack allowing to determine if queue exists
- Only allow correct RSA keys and signature sizes

# 0.2.0

- SMP client library
- SMP agent with E2E encryption

# 0.1.0

- SMP protocol server implementation without encryption
