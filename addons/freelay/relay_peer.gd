class_name RelayPeer
extends RefCounted
## A remote peer: verified public key plus derived id and bookkeeping.

var public_key: PackedByteArray
var peer_id: String
var last_seen_ms: int = 0
var muted := false
var meta: Dictionary = {}


static func from_public_key(pk: PackedByteArray) -> RelayPeer:
	var peer := RelayPeer.new()
	peer.public_key = pk
	peer.peer_id = Freelay.derive_peer_id(pk)
	peer.last_seen_ms = Freelay.now_ms()
	return peer


func mute() -> void:
	muted = true


func unmute() -> void:
	muted = false
