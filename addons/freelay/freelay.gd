class_name Freelay
extends RefCounted
## Freelay protocol constants and pure helper functions.
## Spec: freelay-spec.md - everything here mirrors §1, §2, §3 and §12.

const TOPIC_ROOT := "fl"

# Envelope / frame versions (§4, §7.4)
const ENVELOPE_VERSION := 0x01
const FRAME_VERSION := 0x01

# Envelope msg_type registry (§10.1)
const MSG_CHANNEL_DATA := 0x01
const MSG_PRESENCE := 0x02
const MSG_HELLO := 0x03
const MSG_WELCOME := 0x04
const MSG_REJECT := 0x05

# Session frame_type registry (§10.2)
const FRAME_CONFIRM := 0x00
const FRAME_DATA := 0x01
const FRAME_DATA_UNRELIABLE := 0x02
const FRAME_FIN := 0x03
const FRAME_RTC_OFFER := 0x10
const FRAME_RTC_ANSWER := 0x11
const FRAME_RTC_ICE := 0x12

# Reason codes (§10.3)
const REASON_UNSPECIFIED := 0x00
const REASON_DECLINED := 0x01
const REASON_RATE_LIMITED := 0x02
const REASON_UNSUPPORTED_VERSION := 0x03
const REASON_SHUTTING_DOWN := 0x04

# Protocol constants (§12)
const FRESHNESS_WINDOW_MS := 120_000
const HEARTBEAT_INTERVAL_S := 30.0
const STALE_AFTER_MS := 90_000
const HELLO_RETRIES := 3
const HELLO_RETRY_INTERVAL_S := 2.0
const HANDSHAKE_TIMEOUT_S := 10.0
const REPLAY_WINDOW := 64
const SELF_HEAL_MIN_INTERVAL_S := 1.0
const MAX_MESSAGE_SIZE := 65_536 # MUST-limit (§10.4)

const PRESENCE_ONLINE := 0x01
const PRESENCE_OFFLINE := 0x00

const _B32_ALPHABET := "abcdefghijklmnopqrstuvwxyz234567"

static var _crc_table: PackedInt64Array = PackedInt64Array()


static func now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


## RFC 4648 base32, lowercase, no padding (§1).
static func base32(data: PackedByteArray) -> String:
	var out := ""
	var acc := 0
	var bits := 0
	for b in data:
		acc = (acc << 8) | b
		bits += 8
		while bits >= 5:
			bits -= 5
			out += _B32_ALPHABET[(acc >> bits) & 31]
	if bits > 0:
		out += _B32_ALPHABET[(acc << (5 - bits)) & 31]
	return out


## CRC32 (ISO-HDLC, zlib-compatible) for the app id (§2.2).
static func crc32(data: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for i in 256:
			var c := i
			for _j in 8:
				c = (0xEDB88320 ^ (c >> 1)) if (c & 1) else (c >> 1)
			_crc_table[i] = c
	var crc := 0xFFFFFFFF
	for b in data:
		crc = _crc_table[(crc ^ b) & 0xFF] ^ (crc >> 8)
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF


static func sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()


## §2.1 - raw 16-byte digest a peer id is derived from.
static func peer_id_digest(public_key: PackedByteArray) -> PackedByteArray:
	return sha256(public_key).slice(0, 16)


## §2.1 - peer_id = base32(SHA-256(pk)[0..16]) → 26 chars.
static func derive_peer_id(public_key: PackedByteArray) -> String:
	return base32(peer_id_digest(public_key))


## §2.2 - app_id = crc32(app_string) as 8 lowercase hex chars.
static func derive_app_id(app_string: String) -> String:
	return "%08x" % crc32(app_string.to_utf8_buffer())


## §2.3 - channel_id = base32(SHA-256("FLCH" || name)[0..8]) → 13 chars.
static func derive_channel_id(channel_name: String) -> String:
	var input := "FLCH".to_utf8_buffer() + channel_name.to_utf8_buffer()
	return base32(sha256(input).slice(0, 8))


# ---------------------------------------------------------------------------
# Topic builders (§3.1). `root` is "fl/{app_id}".
# ---------------------------------------------------------------------------

static func make_root(app_string: String) -> String:
	return "%s/%s" % [TOPIC_ROOT, derive_app_id(app_string)]


static func topic_presence(root: String, peer_id: String) -> String:
	return "%s/presence/%s" % [root, peer_id]


static func topic_channel_msg(root: String, channel_id: String) -> String:
	return "%s/ch/%s/msg" % [root, channel_id]


static func topic_channel_member(root: String, channel_id: String, peer_id: String) -> String:
	return "%s/ch/%s/p/%s" % [root, channel_id, peer_id]


static func topic_inbox(root: String, peer_id: String) -> String:
	return "%s/peer/%s/inbox" % [root, peer_id]


static func topic_session(root: String, peer_id: String, session_id_b32: String) -> String:
	return "%s/peer/%s/s/%s" % [root, peer_id, session_id_b32]
