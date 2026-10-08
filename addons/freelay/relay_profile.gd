class_name RelayProfile
extends RefCounted
## A peer identity: an Ed25519 keypair plus derived ids.
##
## The seed never leaves this class except through save(); all signing goes
## through sign(). Storage format ("GRPF"):
##   magic(4) | version(1) | flags(1) | [salt(16) | nonce(24) | ct(32+16)]
##   flags bit0 = encrypted. Unencrypted stores the raw 32-byte seed instead.

const _MAGIC := "GRPF"
const _KDF_ITERATIONS := 20_000

var _keypair: Ed25519Keypair

var public_key: PackedByteArray:
	get: return _keypair.get_public_key()

var peer_id: String:
	get: return Freelay.derive_peer_id(public_key)

## Raw 16-byte digest (used for WebRTC glare resolution, §8.1).
var peer_id_digest: PackedByteArray:
	get: return Freelay.peer_id_digest(public_key)


static func generate() -> RelayProfile:
	var profile := RelayProfile.new()
	profile._keypair = FreelayCrypto.generate_keypair()
	return profile


static func from_seed(seed: PackedByteArray) -> RelayProfile:
	var kp := FreelayCrypto.keypair_from_seed(seed)
	if kp == null:
		return null
	var profile := RelayProfile.new()
	profile._keypair = kp
	return profile


func sign(message: PackedByteArray) -> PackedByteArray:
	return FreelayCrypto.sign(message, _keypair.get_seed())


## Internal: envelope construction needs the seed for Ed25519.sign.
## Deliberately underscore-prefixed; do not use from game code.
func _seed() -> PackedByteArray:
	return _keypair.get_seed()


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

## NOTE: the KDF is iterated BLAKE2b - deliberate but NOT memory-hard.
## Good enough against casual attackers; if gd-ed25519 ever exposes
## Monocypher's Argon2, switch to it here.
static func _derive_key(password: String, salt: PackedByteArray) -> PackedByteArray:
	var k := FreelayCrypto.blake2b("FLPKDF".to_utf8_buffer() + password.to_utf8_buffer() + salt)
	for _i in _KDF_ITERATIONS:
		k = FreelayCrypto.blake2b(k + salt)
	return k


func save(path: String, password: String = "") -> Error:
	var buf := StreamPeerBuffer.new()
	buf.put_data(_MAGIC.to_utf8_buffer())
	buf.put_u8(1)
	var seed := _keypair.get_seed()
	if password.is_empty():
		buf.put_u8(0)
		buf.put_data(seed)
	else:
		buf.put_u8(1)
		var salt := FreelayCrypto.random_bytes(16)
		var nonce := FreelayCrypto.random_bytes(24)
		var key := _derive_key(password, salt)
		var ct := FreelayCrypto.aead_encrypt(seed, key, nonce, _MAGIC.to_utf8_buffer())
		buf.put_data(salt)
		buf.put_data(nonce)
		buf.put_data(ct)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(buf.data_array)
	file.close()
	return OK


static func load_from(path: String, password: String = "") -> RelayProfile:
	var data := FileAccess.get_file_as_bytes(path)
	if data.size() < 6 or data.slice(0, 4).get_string_from_utf8() != _MAGIC:
		return null
	if data[4] != 1:
		return null
	var encrypted := data[5] == 1
	var seed: PackedByteArray
	if not encrypted:
		if data.size() < 6 + 32:
			return null
		seed = data.slice(6, 38)
	else:
		if data.size() < 6 + 16 + 24 + 48:
			return null
		var salt := data.slice(6, 22)
		var nonce := data.slice(22, 46)
		var ct := data.slice(46)
		var key := _derive_key(password, salt)
		var pt = FreelayCrypto.aead_decrypt(ct, key, nonce, _MAGIC.to_utf8_buffer())
		if pt == null:
			return null # wrong password or corrupted file
		seed = pt
	return RelayProfile.from_seed(seed)
