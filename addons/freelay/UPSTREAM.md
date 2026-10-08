# Bundled dependency versions

Freelay and its dependencies were copied from
[freehuntx/godot-freelay](https://github.com/freehuntx/godot-freelay), commit
`f18dd791caafeda40189875fe17d86011a1e7d66` (asset version 0.0.1).
Each addon retains its upstream `LICENSE.md`.

## Local Freelay patches

- Reliable and control messages publish at MQTT QoS 1. Inbox, session, and
  public-message subscriptions request QoS 1. Unreliable frames use QoS 0.
- `RelayClient.close()` calls mqtt-node's actual `disconnect_from_broker()` API
  and retains the socket until the disconnect completes. TetraForce allows a
  one-second flush window before freeing the client node.
- Closing clients stop processing messages, avoiding presence self-healing
  re-announcing online presence while leaving.
- Peer connections only send FIN while the broker connection is open, avoiding
  attempted publishes after broker loss.
- WebRTC setup checks the native implementation, initialization, and channel
  creation before attempting an upgrade. Responders use the game's configured
  ICE servers. Both channels must be open before selecting WebRTC; closed/failed
  connections revert to MQTT. Messages above the portable SCTP size limit stay
  on MQTT, and failed data-channel sends fall back to the relay.
- WebRTC is polled before a send. A failed send tears down that direct connection
  so subsequent gameplay updates use MQTT. Intentional local leaves keep the
  underlying SCTP connection alive for two seconds after closing the game session,
  allowing the MQTT FIN to arrive before remote sends hit a closed socket.
- Browser TCP candidates are removed from SDP/trickle ICE when the recipient is
  the native libjuice UDP-only implementation; UDP/STUN/TURN candidates remain.

The game peer adapter also tracks SceneMultiplayer's peer-removal relay messages
and discards queued/late relayed packets from those IDs. This prevents unordered
RTC updates from referencing a peer's RPC cache after Godot has deleted it.
The adapter's protocol-v2 packets include reliable sequence numbers, cumulative
acknowledgements and retransmission across MQTT/RTC transitions. Unreliable updates
carry their reliable-setup watermark and are dropped if they overtake that setup.
Reliable control acknowledgements use `RelayPeerConnection.send_relay()` to remain
independent of data-channel transitions. These game-specific fields are carried
inside Freelay's normal encrypted Variant payloads; the Freelay wire format itself
is unchanged.

## Local mqtt-node patches

- Read and parse buffered WebSocket packets before evaluating the CONNACK timeout.
  This prevents false failures when a backgrounded instance resumes with its broker
  reply already buffered.
- Cancelled connections poll only the close handshake. The disconnect intent is
  saved before resetting session state, preventing an intentional leave from being
  misreported as a failed connection or triggering a reconnect.
- Real CONNACK timeouts still emit the addon's error signal for retry/UI handling,
  but are not logged as script errors. Freelay shows the last broker failure if the
  overall lobby-connection timeout expires.

## Single-threaded web crypto libraries

The upstream web binaries use shared memory and cannot load in TetraForce's
single-threaded web export. Additional `*.nothreads.wasm` libraries were built
from [freehuntx/gd-ed25519](https://github.com/freehuntx/gd-ed25519), tag `v1.0.0`,
commit `8859809fb1df516503e0c3a95bcf0f0b10e397d6`, with its pinned godot-cpp
submodule `b0e3b1e4b78a606f48d162898afb5eeda533d2a9`.

Build commands (Emscripten 6.0.9, SCons 4.10.1):

```sh
git clone --branch v1.0.0 --recurse-submodules https://github.com/freehuntx/gd-ed25519.git
```

Run in that checkout:

```sh
scons platform=web arch=wasm32 target=template_release threads=no -j8
scons platform=web arch=wasm32 target=template_debug threads=no -j8
```

Copy the resulting `project/addons/ed25519/web/*.nothreads.wasm` files into
`addons/ed25519/web/`. The GDExtension manifest selects them for `nothreads`
exports and retains upstream binaries for `threads` exports. Desktop/mobile
libraries are the upstream prebuilt binaries.

gd-ed25519 incorporates Monocypher, dual-licensed BSD-2-Clause/CC0-1.0; see
<https://monocypher.org/licence.html>. It also links godot-cpp (MIT).

## Native WebRTC

The official [godotengine/webrtc-native](https://github.com/godotengine/webrtc-native)
GDExtension release `1.2.2-stable` is bundled under `addons/webrtc_native/`.
It supports Godot 4.3+ and includes debug/release libraries for Windows, Linux,
macOS, Android, and iOS. Web builds use Godot's built-in implementation; the
web export preset excludes `addons/webrtc_native/*` so the native extension is
also removed from Godot's exported extension list. The upstream `exclude_tags`
manifest setting alone does not prevent the Godot 4.7 web runtime from trying to
load the native extension.

Source archive:
<https://github.com/godotengine/webrtc-native/releases/download/1.2.2-stable/godot-extension-webrtc_native.zip>

Archive SHA-256:
`98e9446921740d995bd9ca1be48798dc3c2ceed51e044a25ce18b3cff11f56e5`

The addon retains its upstream license files, including libdatachannel and its
dependencies. Its native libraries and GDExtension manifest are unmodified.
