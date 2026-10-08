class_name FreelayEnvelope
extends RefCounted
## Signed plaintext envelope (spec §4).
##
## Layout:  ver(1) | msg_type(1) | sender_pk(32) | seq(u32) | ts(u64) |
##          body(n) | signature(64)
## Signature input: "FLSIG" || topic || envelope[0 .. 46+n]

const HEADER_SIZE := 46
const SIG_SIZE := 64
const MIN_SIZE := HEADER_SIZE + SIG_SIZE

var msg_type: int
var sender_pk: PackedByteArray
var seq: int
var timestamp: int
var body: PackedByteArray
var raw: PackedByteArray # full wire bytes (set by encode/decode)

## Cached: peer id derived from sender_pk.
var sender_peer_id: String:
	get: return Freelay.derive_peer_id(sender_pk)


static func encode(topic: String, p_msg_type: int, seed: PackedByteArray, p_sender_pk: PackedByteArray, p_seq: int, p_body: PackedByteArray) -> FreelayEnvelope:
	var ts := Freelay.now_ms()
	var buf := StreamPeerBuffer.new()
	buf.big_endian = true
	buf.put_u8(Freelay.ENVELOPE_VERSION)
	buf.put_u8(p_msg_type)
	buf.put_data(p_sender_pk)
	buf.put_u32(p_seq)
	buf.put_u64(ts)
	buf.put_data(p_body)
	var unsigned := buf.data_array
	var sig := FreelayCrypto.sign("FLSIG".to_utf8_buffer() + topic.to_utf8_buffer() + unsigned, seed)
	if sig.is_empty():
		push_error("FreelayEnvelope: signing failed")
		return null
	var env := FreelayEnvelope.new()
	env.msg_type = p_msg_type
	env.sender_pk = p_sender_pk
	env.seq = p_seq
	env.timestamp = ts
	env.body = p_body
	env.raw = unsigned + sig
	return env


## Parses and cryptographically verifies. Returns null on any failure.
## Freshness/monotonicity are NOT checked here (presence has special rules,
## §6) - use FreelayReplayGuard for the generic §4.2 rules.
static func decode_and_verify(topic: String, data: PackedByteArray) -> FreelayEnvelope:
	if data.size() < MIN_SIZE or data.size() > Freelay.MAX_MESSAGE_SIZE:
		return null
	if data[0] != Freelay.ENVELOPE_VERSION:
		return null
	var unsigned := data.slice(0, data.size() - SIG_SIZE)
	var sig := data.slice(data.size() - SIG_SIZE)
	var pk := data.slice(2, 34)
	if not FreelayCrypto.verify(sig, "FLSIG".to_utf8_buffer() + topic.to_utf8_buffer() + unsigned, pk):
		return null
	var buf := StreamPeerBuffer.new()
	buf.big_endian = true
	buf.data_array = data
	var env := FreelayEnvelope.new()
	env.raw = data
	buf.get_u8() # version
	env.msg_type = buf.get_u8()
	env.sender_pk = pk
	buf.seek(34)
	env.seq = buf.get_u32()
	env.timestamp = buf.get_u64()
	env.body = data.slice(HEADER_SIZE, data.size() - SIG_SIZE)
	return env


## §4.2 rules 4+5: freshness window + per-(sender, topic) monotonic
## (timestamp, seq) tuple, with a bounded LRU over senders.
class ReplayGuard:
	extends RefCounted

	const MAX_ENTRIES := 2048

	var _last: Dictionary = {} # "pkhex|topic" -> [ts, seq]
	var _order: Array[String] = []

	## Returns true if the envelope passes and records it.
	func check(env: FreelayEnvelope, topic: String, apply_freshness := true) -> bool:
		if apply_freshness:
			if absi(Freelay.now_ms() - env.timestamp) > Freelay.FRESHNESS_WINDOW_MS:
				return false
		var key := env.sender_pk.hex_encode() + "|" + topic
		if _last.has(key):
			var prev: Array = _last[key]
			# lexicographic (timestamp, seq) comparison
			if env.timestamp < prev[0] or (env.timestamp == prev[0] and env.seq <= prev[1]):
				return false
			_last[key] = [env.timestamp, env.seq]
		else:
			_last[key] = [env.timestamp, env.seq]
			_order.append(key)
			if _order.size() > MAX_ENTRIES:
				_last.erase(_order.pop_front())
		return true
