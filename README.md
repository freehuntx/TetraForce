![Version](https://img.shields.io/github/v/tag/loudsmilestudios/TetraForce?label=version)
![Discord](https://img.shields.io/discord/637735060757544983?label=Discord)
![Build Godot Project](https://github.com/fornclake/TetraForce/workflows/Build%20Godot%20Project/badge.svg?branch=master)

<img width="500" height="301" alt="Logo_FullyRendered_Small" src="https://github.com/user-attachments/assets/012812a1-d500-433c-9817-aeda9028b068" />

[Play Now!](https://theretrodragon.itch.io/tetraforce)

TetraForce is an action adventure game inspired by various action platformer
puzzle games, such as the top-down Legend of Zelda games and CrossCode. It is
designed to be very replayable for casual and experienced players, whether they
are playing by themselves or with friends. Three features we think are the most
to get excited about are easy to utilize multiplayer, item randomizer, and
moddability. With these features in mind and with more to come, it will be a
brand new gaming experience inspired by some of the best games ever made.

![Multiplayer Screenshot](https://miro.medium.com/max/2930/1*ydgwH7-VoGrR0l6yx1-_OQ.png)

TetraForce is built with the open source
[Godot Engine](https://godotengine.org/)

## Links

[Website](https://theretrodragon.itch.io/tetraforce)

[Discord server](https://discord.gg/pk427kD3f2)

## Web builds on GitHub Pages

The **Deploy Web to GitHub Pages** workflow (`.github/workflows/deploy_web.yml`)
exports the game with Godot 4.7.2 and publishes it to GitHub Pages. It runs on
pushes to `master`, or manually from the repository's Actions tab. Both branches
deploy to the same site; the latest successful deployment is live.

To enable deployment:

1. Open **Settings → Pages** in your GitHub repository.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**.
3. If the `github-pages` environment restricts deployment branches, allow
   `master` and `web-version` under **Settings → Environments → github-pages**.
4. Push to either branch, or run **Deploy Web to GitHub Pages** from
   **Actions**.

The deployed game's URL appears in the workflow's `github-pages` environment.
For a repository named `TetraForce`, the default URL is
`https://<owner>.github.io/TetraForce/`.

The workflow exports the `HTML5` preset to `build/web/index.html` and uploads
the entire `build/web` directory. Keep **Thread Support** disabled in the web
export preset: GitHub Pages does not provide the cross-origin isolation headers
required by threaded Godot web exports. Keep **Extensions Support** enabled:
Freelay's crypto dependency includes single-threaded WebAssembly libraries.
Quickstart and multiplayer hosting both work in the browser.

## Multiplayer with Freelay

Multiplayer uses [Godot Freelay](https://github.com/freehuntx/godot-freelay)
over MQTT WebSockets. The required addons (`freelay`, `mqtt-node`, and
`ed25519`) are bundled in `addons/` and load automatically.
The bundled `webrtc_native` GDExtension enables WebRTC on Windows and Linux;
browser builds use Godot's built-in WebRTC implementation.

### Playing together

- **Public:** select a shared public lobby. The first player hosts the game.
- **Automatic:** enter the same lobby name as your friends and press Connect.
  The game joins an existing host or selects a host after a short discovery period.
- **Direct:** host on desktop, or enter the host's IP and press Join.
  Uses TCP port 7777 (WebSocket). Browsers can join; the Host button is hidden.
  Internet hosts must forward TCP port 7777; LAN players use the host's local IP.

Lobby names are case-insensitive and must contain 1–64 characters after trimming
whitespace. Players must use the same multiplayer protocol, application ID, and
broker. Build-version labels (release tags, commit hashes, or "custom build") do
not restrict joining.
Public and Automatic work between desktop and browser without port forwarding.
The default capacity is 16 players including the host.

### Broker configuration

`project.godot` contains the configuration:

```ini
[freelay]
app_id="tetraforce"
broker_urls=PackedStringArray("wss://broker.hivemq.com:8884/mqtt")
webrtc_enabled=true
ice_servers=[{"urls": ["stun:stun.l.google.com:19302"]}]
```

The default is a public HiveMQ broker. To use your own broker, set its MQTT 3.1.1
WebSocket URL. HTTPS-hosted browser builds need a `wss://` URL with a valid TLS
certificate. All players in a lobby must connect to the same broker; different
brokers do not share lobby traffic.

After joining, clients automatically attempt a WebRTC connection to the host.
MQTT carries discovery and encrypted WebRTC signaling, and remains the fallback
when ICE cannot establish a direct connection or WebRTC disconnects. Both reliable
and unreliable data channels must be open before gameplay switches to WebRTC.
The broker connection remains required for the lobby/session lifecycle.

Set `freelay/webrtc_enabled=false` for relay-only multiplayer. Configure
`freelay/ice_servers` with your STUN/TURN server definitions if needed; the default
uses Google's public STUN service. No editor-plugin toggle is needed for
`webrtc_native`: Godot loads the GDExtension automatically and packages the matching
native library for desktop exports. The native addon is excluded from web exports.

For a headless host:

```sh
godot --headless --path . -- --dedicatedserver=true --lobby=my-lobby \
  --broker=wss://broker.example.com/mqtt --empty-server-timeout=300
```

`--broker` also overrides the project setting in desktop development runs.
`--lobby` sets the default lobby name. A dedicated host coordinates the session;
players still own the simulation of the maps they occupy.

### Integration details

- `engine/freelay_session.gd` handles signed lobby discovery, host selection,
  connection timeouts, and cleanup.
- `engine/freelay_migration.gd` coordinates committed session membership,
  encrypted checkpoints, signed handovers and majority-based crash elections.
- `engine/freelay_multiplayer_peer.gd` implements Godot's multiplayer-peer API
  over Freelay's encrypted private sessions. The host is peer 1 and assigns
  numeric IDs to clients, preserving scene authority and gameplay RPCs.
- `engine/network.gd` synchronizes player metadata, map ownership, dynamic
  objects, inventory, and persistent state. Late joiners receive a state snapshot.
  Each roster update carries names and skins in the same versioned snapshot;
  surviving puppets refresh from their own player ID, and older snapshots are ignored.
- Each lobby connection generates a fresh Freelay cryptographic identity.
  Discovery messages are signed plaintext; gameplay uses encrypted sessions
  between each client and the host. Client-to-client RPCs pass through the host.
- On MQTT, reliable/control traffic uses QoS 1 and transient movement updates use
  QoS 0. On WebRTC, gameplay uses DTLS-protected data channels. Oversized messages
  stay on the MQTT relay.
  The game adapter sequences and acknowledges reliable packets across both
  transports, retries missing packets, and prevents movement from overtaking
  reliable roster/path-cache setup. Acknowledgements use encrypted MQTT sessions.
- When the host exits or changes lobbies, gameplay pauses while a successor
  receives a final checkpoint and the remaining players reconnect. The successor
  becomes Godot peer 1; other survivors retain their IDs. Local avatars, HUDs and
  cameras stay alive, and map authorities are reassigned consistently.
- Unexpected host loss uses signed votes from the last committed session roster.
  A strict majority must elect and restore the successor before gameplay resumes.
  Election rounds skip unavailable candidates. A two-player room supports graceful
  handover, but cannot recover from an abrupt host loss with only one voter left.
  Migration times out after 25 seconds when agreement/restoration is impossible.
  Broker loss still ends the session, since signed coordination requires MQTT.
- Host liveness is checked after transport polling, using both signed discovery
  and authenticated gameplay traffic. A locally stalled/backgrounded window gets
  a receive grace period when it resumes. Initial profile admission allows 25
  seconds for cold browser map loading; intentional kicks show their actual reason
  and do not start an election.
- Checkpoints replicate shared state, profiles, map ownership, player positions
  and health, and objects with `NetworkObject` components. Map owners supply world
  state; each player supplies their own avatar. Add custom object state to
  `enter_properties` or `update_properties` to include it in migration snapshots.
  Abrupt loss restores the successor's latest checkpoint; recent in-flight updates
  can roll back. Graceful handover gathers a final checkpoint with gameplay paused.

The upstream version and local dependency patches are recorded in
`addons/freelay/UPSTREAM.md`.

### Regression checks

```sh
godot --headless --editor --import --path . --quit
godot --headless --path . res://tests/quickstart_regression.tscn
python tests/run_direct_regression.py
python tests/run_collision_regression.py
python tests/run_freelay_regression.py
```

The Freelay runner requires Mosquitto with WebSocket support. It starts a local
broker and three real game instances with different build-version labels, checks
explicit hosting and simultaneous automatic host selection, player movement,
client-to-client RPCs, dynamic object creation, late-join state, departures,
WebRTC upgrades and MQTT fallback, and
broker-loss recovery. The native WebRTC tests use local ICE candidates so they do
not depend on a public STUN service. Set `GODOT_BIN`
or `MOSQUITTO_BIN` to override the executables.

The runner also starts two hosts and two clients to exercise repeated live lobby
switching and cancelled joins. A WebSocket fixture checks that buffered CONNACK
replies are processed before timeouts, intentional cancellation does not reconnect,
and genuinely missing broker replies still reach the connection-error handler.
Four distinct appearance profiles are checked before and after a native client
leaves, including a replayed stale snapshot that attempts to replace everyone with
the browser's profile. The networking suite also deliberately drops a reliable
packet to verify retransmission and continued gameplay. To run only the appearance
and menu-quit regression, use `python tests/run_freelay_regression.py --appearance-only`.

Host-migration regressions cover two- and three-player graceful exits, forced host
termination, repeated handovers over WebRTC, simultaneous host/successor loss,
live-old-host step-down, missing quorum, rejected successor handshakes, signed outsider/stale votes, and
restoration of avatars, persistent state, broken objects and missing dynamic nodes.
Run them with `python tests/run_freelay_regression.py --migration-only`; optionally
select a scenario with `--migration-scenario=graceful`, `crash`, `repeated`,
`candidate-loss`, `host-connection-loss`, or `no-quorum`.

For two real WebAssembly instances, run
`node tests/run_freelay_browser_regression.mjs`. This requires Node 22+, Chromium,
Mosquitto with WebSocket support, and installed Godot web export templates. It
exports an isolated test configuration and checks stalls during joining and active
WebRTC play, committed checkpoints, rejection/rejoin, graceful host migration,
and RTC channel/callback cleanup. `GODOT_BIN`, `MOSQUITTO_BIN`, `CHROMIUM_BIN`, and
`PYTHON_BIN` can override the executables.

The game multiplayer protocol is now version 4. Refresh/re-export browser builds
alongside desktop updates; mismatched protocol builds show an update/reload message.
Normal quitting stops audio before the network-flush wait, allowing music playback
resources to be released before the engine exits.

On leaving, gameplay stops immediately and the native WebRTC connection gets a
short grace period for the encrypted MQTT leave notification to reach the other
player. Retained channels are drained/discarded during that grace period, then
explicitly closed to detach browser message callbacks. Browser channel receive
buffers are 1 MiB to accommodate short frame stalls. Queued MQTT packets are
batched into bounded WebSocket messages so ACKs/checkpoints are not limited to
one packet per game frame. A failed data-channel send disables that channel and
falls back to MQTT.
Late events from a cancelled lobby cannot interrupt the newly selected lobby.
Relayed updates from departed players are dropped before they reach Godot's
removed RPC/path caches, including movement packets delayed on an unordered channel.

The native ICE library may report `maximum number of host candidates` on machines
with many network interfaces. It uses the candidates it collected and continues
connecting. Browser ICE-TCP candidates are filtered for the native UDP-only backend.
`DRI_PRIME` warnings originate from the graphics-driver environment, not multiplayer.

## Contributing

If you would like to contribute, please have a look through our
[issues](https://github.com/loudsmilestudios/TetraForce/issues).

If there is an existing issue for something you would like to work on, leave a
comment on the issue or reach out to the current asignee of that issue. If there
is not an existing issue,
[please create a new one](https://github.com/loudsmilestudios/TetraForce/issues/new/choose)
to start a conversation.

Please review our
[Style Guide](https://github.com/fornclake/TetraForce/wiki/Style-Guide) before
contributing.

Create
[Pull Requests](https://opensource.com/article/19/7/create-pull-request-github)
to contribute code.
