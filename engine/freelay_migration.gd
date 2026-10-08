class_name FreelayMigration
extends RefCounted
## Session control is signed over the lobby; game checkpoints are encrypted.
## Only admitted, committed members vote. A departing host can authorize a
## successor, otherwise a strict majority of the previous roster is required.

const TIMEOUT = 25.0
const ROUND_SECONDS = 4.0
var session: Node
var session_id = ""
var epoch = 0
var members: Dictionary = {} # Freelay identity -> stable Godot ID
var roster = ""
var snapshot: Dictionary = {}
var worlds: Dictionary = {}
var revision = 0
var snapshot_revision = -1
var active = false
var preparing = false
var leaving = false
var installed = false
var complete = false
var age = 0.0
var term = 0
var voted_for = ""
var votes: Dictionary = {}
var winner = ""
var authorization: Dictionary = {}
var restored: Dictionary = {}
var remap: Dictionary = {}
var next_members: Dictionary = {}
var _tick_age = 0.0
var _proposal: Dictionary = {}
var _proposal_acks: Dictionary = {}
var _committed_proposal: Dictionary = {}
var _handover_age = 0.0
var _final_acks: Dictionary = {}
var _checkpoint_frozen = false
var _restore_received = false
var _quorum_ready_age = -1.0
var _voluntary_leaves: Dictionary = {}

func _init(owner: Node):
	session = owner

func identity() -> String:
	return session.client.profile.peer_id

func attach(peer: FreelayMultiplayerPeer):
	peer.control_message.connect(_control)
	if peer.is_host():
		if session_id.is_empty():
			session_id = Freelay.base32(FreelayCrypto.random_bytes(16))
		peer.session_id = session_id
		peer.host_epoch = epoch

func tick(delta: float):
	if session.peer == null or !session._started:
		return
	_tick_age += delta
	if active:
		age += delta
		if age > TIMEOUT:
			print("Host migration timeout: epoch=%s term=%s roster=%s votes=%s winner=%s" % [epoch, term, roster, votes, winner])
			session._fail("Host migration timed out. A majority of the previous session must be reachable after an unexpected host loss.")
			return
	if _tick_age < 0.5:
		return
	_tick_age = 0.0
	if leaving and winner.is_empty():
		if session.peer.connections.is_empty():
			complete = true
			return
		_handover_age += 0.5
		_send({"kind": "migration_prepare"})
		_collect_world()
		if _handover_age >= 1.0 and !_checkpoint_frozen:
			_checkpoint_frozen = true
			_publish_checkpoint()
		if _checkpoint_frozen:
			_send_checkpoint()
			var survivors = {}
			var acknowledged = true
			for id in session.peer.connections:
				var remote = session.peer.identities[id]
				if members.has(remote):
					survivors[remote] = members[remote]
					acknowledged = acknowledged and _final_acks.has(remote)
			if acknowledged:
				var candidates = survivors.keys()
				candidates.sort()
				if !candidates.is_empty():
					authorization = {"candidate": candidates[0], "revision": revision, "survivors": survivors}
					winner = candidates[0]
					_send_authorization()
		return
	if active:
		if preparing:
			_collect_world()
			return # The live old host is gathering the final checkpoint.
		if !winner.is_empty():
			if leaving:
				_send_authorization()
			elif winner == identity():
				if authorization.is_empty():
					_send({"kind": "migration_vote", "term": term, "candidate": winner})
				_send({"kind": "migration_elected", "term": term, "candidate": winner})
				_check_restored()
			elif installed and _restore_received:
				if authorization.is_empty():
					_send({"kind": "migration_vote", "term": term, "candidate": winner})
				session.peer.send_control({"type": "restored"}, 1)
			return
		var round_term = 1 + int(age / ROUND_SECONDS)
		if round_term > term:
			term = round_term
			voted_for = ""
			votes.clear()
		_cast_vote()
		return
	_collect_world()
	if session.peer.is_host():
		_publish_roster()
		_publish_checkpoint()
		_send_checkpoint()
		if !_committed_proposal.is_empty():
			_send({"kind": "migration_roster_commit", "digest": roster})

func _collect_world():
	var world = network.capture_migration_world()
	if session.peer.is_host():
		_accept_world(1, world)
	else:
		session.peer.send_control({"type": "world", "world": world}, 1)

func _accept_world(id: int, world: Dictionary):
	var map = world.get("map", "")
	if map != network.player_list.get(id) or !(world.get("objects") is Dictionary):
		return
	if network.map_hosts.get(map) == id:
		# The map owner owns the non-player objects. Each avatar is supplied
		# separately by its own authority, never by a different map owner.
		var objects = {}
		for path in world.objects:
			if !str(path).get_slice("/", 0).is_valid_int():
				objects[path] = world.objects[path]
		for path in worlds.get(map, {}).get("objects", {}):
			if str(path).get_slice("/", 0).is_valid_int():
				objects[path] = worlds[map].objects[path]
		worlds[map] = {"map": map, "objects": objects}
	if !worlds.has(map):
		worlds[map] = {"map": map, "objects": {}}
	if world.objects.has(str(id)):
		worlds[map].objects[str(id)] = world.objects[str(id)]

func _publish_checkpoint():
	if !session.peer.is_host():
		return
	for map in worlds:
		for path in worlds[map].get("objects", {}).keys():
			var first = str(path).get_slice("/", 0)
			if first.is_valid_int() and network.player_list.get(int(first)) != map:
				worlds[map].objects.erase(path)
	revision += 1
	snapshot = network.capture_migration_snapshot(worlds)
	snapshot_revision = revision

func _send_checkpoint():
	session.peer.send_control({"type": "checkpoint", "session": session_id, "epoch": epoch, "revision": revision, "snapshot": snapshot})

func _digest(value: Dictionary) -> String:
	var sorted_ids = value.keys()
	sorted_ids.sort()
	var text = session_id + ":" + str(epoch)
	for id in sorted_ids:
		text += ":" + id + "=" + str(value[id])
	return text.sha256_text()

func _publish_roster():
	var proposed = {identity(): 1}
	for id in session.peer.identities:
		if network.player_data.has(id):
			proposed[session.peer.identities[id]] = id
	var digest = _digest(proposed)
	if digest == roster:
		return
	if _proposal.get("digest") != digest:
		_proposal = {"type": "roster", "session": session_id, "epoch": epoch, "members": proposed, "digest": digest}
		_proposal_acks = {identity(): true}
	session.peer.send_control(_proposal)
	_commit_roster()

func _commit_roster():
	if _proposal.is_empty() or _proposal_acks.size() != _proposal.members.size():
		return
	# Membership changes also need the previous roster's majority, so a
	# minority cannot shrink its voter set and then elect a competing host.
	if !members.is_empty():
		var previous_acks = 0
		for id in _proposal_acks:
			if members.has(id):
				previous_acks += 1
		for id in _voluntary_leaves:
			if members.has(id) and !_proposal.members.has(id) and !_proposal_acks.has(id):
				previous_acks += 1
		if previous_acks < int(members.size() / 2) + 1:
			return
	members = _proposal.members.duplicate()
	roster = _proposal.digest
	_committed_proposal = _proposal.duplicate(true)
	_voluntary_leaves.clear()
	_send({"kind": "migration_roster_commit", "digest": roster})

func _control(id: int, data: Dictionary):
	var type = data.get("type", "")
	if session.peer.is_host():
		match type:
			"world":
				if !installed and !_checkpoint_frozen and data.get("world") is Dictionary:
					_accept_world(id, data.world)
			"roster_ack":
				var remote = session.peer.identities.get(id, "")
				if !active and data.get("digest") == _proposal.get("digest") and _proposal.get("members", {}).has(remote):
					_proposal_acks[remote] = true
					_commit_roster()
			"checkpoint_ack":
				if leaving and data.get("revision") == revision:
					_final_acks[session.peer.identities.get(id, "")] = true
			"restored":
				if installed:
					restored[session.peer.identities.get(id, "")] = true
					_check_restored()
		return
	if id != 1:
		return
	match type:
		"roster":
			if data.get("members") is Dictionary and data.members.has(identity()):
				session_id = data.get("session", "")
				epoch = data.get("epoch", 0)
				if _digest(data.members) != data.get("digest"):
					return
				_proposal = data.duplicate(true)
				session.peer.send_control({"type": "roster_ack", "digest": data.digest}, 1)
		"checkpoint":
			if data.get("session") == session_id and data.get("epoch") == epoch and data.get("revision", -1) >= snapshot_revision and data.get("snapshot") is Dictionary:
				snapshot = data.snapshot.duplicate(true)
				snapshot_revision = data.revision
				revision = snapshot_revision
				session.peer.send_control({"type": "checkpoint_ack", "revision": snapshot_revision}, 1)
		"restore":
			if active and installed and !_restore_received and data.get("epoch") == epoch + 1 and data.get("snapshot") is Dictionary:
				_restore_received = true
				session.migration_state_ready.emit(data.snapshot, remap)
				await session.get_tree().process_frame
				await session.get_tree().process_frame
				if session._closing:
					return
				session.peer.send_control({"type": "restored"}, 1)
		"resume":
			if active and installed and _restore_received and data.get("epoch") == epoch + 1 and data.get("members") is Dictionary:
				next_members = data.members.duplicate()
				_finish()

func _send(data: Dictionary):
	var message = data.duplicate()
	message.merge({"session": session_id, "epoch": epoch, "roster": roster}, true)
	session.channel.send(message)

func message(remote: RelayPeer, data: Dictionary):
	var sender = remote.peer_id
	if data.get("kind") == "migration_roster_commit":
		if session.peer != null and !session.peer.is_host() and sender == session.peer.identities.get(1) and data.get("digest") == _proposal.get("digest") and data.get("session") == session_id and data.get("epoch") == epoch:
			members = _proposal.members.duplicate()
			roster = _proposal.digest
		return
	if data.get("session") != session_id or data.get("epoch") != epoch or data.get("roster") != roster or !members.has(sender):
		return
	var host = members.find_key(1)
	match data.get("kind"):
		"migration_member_leave":
			if sender != host and session.peer.is_host() and !active:
				_voluntary_leaves[sender] = true
		"migration_prepare":
			if sender == host and !installed:
				preparing = true
				_begin()
				_collect_world()
		"migration_authorize":
			var survivors = data.get("survivors", {})
			var valid_survivors = survivors is Dictionary and !survivors.is_empty()
			if valid_survivors:
				for id in survivors:
					valid_survivors = valid_survivors and members.get(id) == survivors[id] and survivors[id] != 1
			if sender == host and !installed and voted_for.is_empty() and valid_survivors and survivors.has(data.get("candidate")) and survivors.has(identity()) and snapshot_revision == data.get("revision"):
				preparing = false
				_begin()
				authorization = {"candidate": data.candidate, "revision": data.revision, "survivors": survivors}
				winner = data.candidate
				_install()
		"migration_vote":
			if preparing or sender == host or !authorization.is_empty() or !winner.is_empty():
				return
			var incoming_term = data.get("term", 0)
			if !(incoming_term is int) or incoming_term < 1 or incoming_term < term:
				return
			var candidates = _candidates()
			if candidates.is_empty() or data.get("candidate") != candidates[(incoming_term - 1) % candidates.size()]:
				return
			if session.peer.is_host() and !installed:
				# Once crash voting starts, the old host steps down instead of
				# issuing a competing graceful authorization for the same epoch.
				session.call_deferred("_yield_host")
				return
			_begin()
			if incoming_term > term:
				term = incoming_term
				voted_for = ""
				votes.clear()
			votes[sender] = data.candidate
			_cast_vote()
			_try_elected()
		"migration_elected":
			if data.get("term") == term and sender == data.get("candidate"):
				_try_elected()
		"migration_departed":
			if leaving and sender == winner:
				complete = true

func _candidates() -> Array:
	var result = []
	for id in members:
		if members[id] != 1:
			result.append(id)
	result.sort()
	return result

func host_lost(reason: String):
	preparing = false
	if !session._started:
		session._fail(reason)
	elif members.size() <= 1 or snapshot.is_empty():
		session._fail("The host left before a migration checkpoint was established.\n" + reason)
	else:
		_begin()

func _begin():
	if active:
		return
	active = true
	age = 0.0
	if session.peer != null:
		session.peer.suspended = true
	session.migration_started.emit()

func _cast_vote():
	if leaving or !active or !winner.is_empty() or term < 1:
		return
	var candidates = _candidates()
	if candidates.is_empty():
		return
	if voted_for.is_empty():
		voted_for = candidates[(term - 1) % candidates.size()]
	votes[identity()] = voted_for
	_send({"kind": "migration_vote", "term": term, "candidate": voted_for})
	_try_elected()

func _try_elected():
	if !winner.is_empty() or voted_for.is_empty():
		return
	if votes.get(voted_for) != voted_for:
		return # An unreachable candidate cannot accept the role.
	var count = 0
	for id in votes:
		if votes[id] == voted_for:
			count += 1
	if count >= int(members.size() / 2) + 1:
		winner = voted_for
		_install()

func _send_authorization():
	_send({"kind": "migration_authorize", "candidate": winner, "revision": revision, "survivors": authorization.survivors})

func _install():
	if installed or leaving:
		return
	installed = true
	remap.clear()
	next_members.clear()
	for id in members:
		if members[id] != 1 and (authorization.is_empty() or authorization.survivors.has(id)):
			var new_id = 1 if id == winner else members[id]
			remap[members[id]] = new_id
			next_members[id] = new_id
	session.call_deferred("_migration_connect", winner, next_members, session_id, epoch + 1)

func peer_ready(peer: FreelayMultiplayerPeer):
	peer.reserved_ids = next_members.duplicate()
	if peer.is_host():
		session.migration_state_ready.emit(snapshot, remap)
		restored[identity()] = true
	_check_restored()

func _check_restored():
	if !installed or session.peer == null or !session.peer.is_host():
		return
	# A graceful leave waits for every survivor; crash recovery needs the
	# previous roster's quorum. Unreachable members are removed on resume.
	var required = next_members.size() if !authorization.is_empty() else int(members.size() / 2) + 1
	if !authorization.is_empty() and members.size() > 2:
		# Restored voters are locked to this successor. Requiring the old
		# majority prevents an authorized minority from competing with a
		# crash election already in progress elsewhere in the same roster.
		required = maxi(required, int(members.size() / 2) + 1)
	for id in session.peer.connections:
		if !restored.has(session.peer.identities.get(id)):
			session.peer.send_control({"type": "restore", "epoch": epoch + 1, "snapshot": snapshot}, id)
	if restored.size() < required:
		return
	if authorization.is_empty() and restored.size() < next_members.size():
		if _quorum_ready_age < 0.0:
			_quorum_ready_age = age
		if age - _quorum_ready_age < 2.0:
			return # Let slower voters reconnect before excluding unreachable peers.
	# SceneMultiplayer must have polled connection events before RPCs resume.
	if session.peer._events.size() > 0:
		return
	for remote in next_members.keys():
		if !restored.has(remote):
			next_members.erase(remote)
	session.peer.send_control({"type": "resume", "epoch": epoch + 1, "members": next_members})
	_send({"kind": "migration_departed"})
	_finish()

func _finish():
	epoch += 1
	members = next_members.duplicate()
	roster = _digest(members)
	worlds.clear()
	for map in snapshot.get("worlds", {}):
		var objects = {}
		for old_path in snapshot.worlds[map].get("objects", {}):
			var parts = str(old_path).split("/")
			if parts[0].is_valid_int():
				if !remap.has(int(parts[0])) or !(remap[int(parts[0])] in members.values()):
					continue
				parts[0] = str(remap[int(parts[0])])
			objects["/".join(parts)] = snapshot.worlds[map].objects[old_path].duplicate(true)
		worlds[map] = {"map": map, "objects": objects}
	active = false
	preparing = false
	installed = false
	complete = true
	age = 0.0
	term = 0
	voted_for = ""
	votes.clear()
	winner = ""
	authorization.clear()
	restored.clear()
	_restore_received = false
	_quorum_ready_age = -1.0
	_proposal.clear()
	_committed_proposal.clear()
	session.peer.suspended = false
	snapshot_revision = -1
	network.trim_migration_players(members.values())
	session.migration_finished.emit()

func prepare_leave():
	if session.peer == null or active:
		return
	if !session.peer.is_host():
		if members.has(identity()):
			_send({"kind": "migration_member_leave"})
			await session.get_tree().create_timer(0.1).timeout
		return
	if members.size() < 2 or session.peer.connections.is_empty():
		return
	leaving = true
	complete = false
	_begin()
	while !complete and age < TIMEOUT and !session._closing:
		await session.get_tree().process_frame
