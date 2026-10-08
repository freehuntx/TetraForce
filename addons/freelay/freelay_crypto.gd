class_name FreelayCrypto
extends RefCounted
## Thin adapter around gd-ed25519 v1.0.0 (Ed25519 / X25519 / Monocypher) and
## Godot's Crypto for randomness.
##
## Every call into the GDExtension lives in this file, so if a method name
## differs from the assumption, there is exactly ONE place to fix it.

static var _rng: Crypto = null


static func random_bytes(count: int) -> PackedByteArray:
	if _rng == null:
		_rng = Crypto.new()
	return _rng.generate_random_bytes(count)


# ---------------------------------------------------------------------------
# Ed25519 (RFC 8032, SHA-512) - signatures (§4.1)
# ---------------------------------------------------------------------------

## Sign with the 32-byte seed. Passing an empty public key makes the addon
## derive it internally (v1.0.0 behavior; mismatched keys fail fast).
static func sign(message: PackedByteArray, seed: PackedByteArray) -> PackedByteArray:
	return Ed25519.sign(message, seed, PackedByteArray())


static func verify(signature: PackedByteArray, message: PackedByteArray, public_key: PackedByteArray) -> bool:
	if signature.size() != 64 or public_key.size() != 32:
		return false
	return Ed25519.verify(signature, message, public_key)


## Deterministic keypair from a 32-byte seed (also accepts 64-byte libsodium
## secret keys). Returns null on invalid input.
static func keypair_from_seed(seed: PackedByteArray) -> Ed25519Keypair:
	return Ed25519Keypair.from_seed(seed)


static func generate_keypair() -> Ed25519Keypair:
	return Ed25519Keypair.generate()


# ---------------------------------------------------------------------------
# X25519 - ephemeral Diffie-Hellman (§7.3)
# ---------------------------------------------------------------------------

static func x25519_generate() -> X25519Keypair:
	return X25519.generate_keypair()


static func x25519_public(keypair: X25519Keypair) -> PackedByteArray:
	return keypair.get_public_key()


static func x25519_private(keypair: X25519Keypair) -> PackedByteArray:
	return keypair.get_private_key()


## Raw DH. The addon performs constant-time all-zero (low-order point)
## detection and returns null/empty in that case - callers MUST abort then.
static func x25519_shared_secret(own_private: PackedByteArray, their_public: PackedByteArray) -> PackedByteArray:
	var shared = X25519.shared_secret(own_private, their_public)
	if shared == null or shared.is_empty():
		return PackedByteArray()
	return shared


# ---------------------------------------------------------------------------
# Symmetric primitives (Monocypher class)
# ---------------------------------------------------------------------------

static func blake2b(data: PackedByteArray, out_len: int = 32) -> PackedByteArray:
	var digest = Monocypher.blake2b(data, out_len)
	if digest == null:
		push_error("FreelayCrypto.blake2b failed (out_len out of range?)")
		return PackedByteArray()
	return digest


## XChaCha20-Poly1305 AEAD. Returns ciphertext || 16-byte tag, empty on error.
## NOTE: Monocypher's parameter order is (key, nonce, plaintext, ad).
static func aead_encrypt(plaintext: PackedByteArray, key: PackedByteArray, nonce: PackedByteArray, ad: PackedByteArray) -> PackedByteArray:
	var ct = Monocypher.aead_encrypt(key, nonce, plaintext, ad)
	if ct == null:
		push_error("FreelayCrypto.aead_encrypt failed (bad key/nonce size?)")
		return PackedByteArray()
	return ct


## Returns null on authentication failure (distinct from empty plaintext).
## NOTE: Monocypher's parameter order is (key, nonce, ciphertext_with_tag, ad).
static func aead_decrypt(ciphertext: PackedByteArray, key: PackedByteArray, nonce: PackedByteArray, ad: PackedByteArray) -> Variant:
	return Monocypher.aead_decrypt(key, nonce, ciphertext, ad)


# ---------------------------------------------------------------------------
# Freelay key schedule (§7.3)
# ---------------------------------------------------------------------------

## Returns { "send": key, "recv": key } for the given role, or {} on failure.
static func derive_session_keys(
	own_eph_private: PackedByteArray,
	their_eph_public: PackedByteArray,
	pk_initiator: PackedByteArray,
	pk_responder: PackedByteArray,
	session_id: PackedByteArray,
	is_initiator: bool
) -> Dictionary:
	var shared := x25519_shared_secret(own_eph_private, their_eph_public)
	if shared.is_empty():
		return {}
	var k_root := blake2b("FLKDF".to_utf8_buffer() + shared + pk_initiator + pk_responder + session_id)
	var k_i2r := blake2b("FLI2R".to_utf8_buffer() + k_root)
	var k_r2i := blake2b("FLR2I".to_utf8_buffer() + k_root)
	if is_initiator:
		return {"send": k_i2r, "recv": k_r2i}
	return {"send": k_r2i, "recv": k_i2r}


## §7.4 - nonce = 16 zero bytes || counter (u64 BE).
static func frame_nonce(counter: int) -> PackedByteArray:
	var nonce := PackedByteArray()
	nonce.resize(24) # zero-filled
	var buf := StreamPeerBuffer.new()
	buf.big_endian = true
	buf.put_u64(counter)
	var counter_bytes := buf.data_array
	for i in 8:
		nonce[16 + i] = counter_bytes[i]
	return nonce
