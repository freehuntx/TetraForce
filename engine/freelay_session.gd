extends Node
## Signed lobby discovery and deterministic host selection; encrypted gameplay.
signal session_ready(peer: FreelayMultiplayerPeer)
signal failed(reason: String)
signal disconnected(reason: String)
signal migration_started
signal migration_peer_ready(peer: FreelayMultiplayerPeer)
signal migration_state_ready(snapshot: Dictionary, remap: Dictionary)
signal migration_finished

const DISCOVERY_SECONDS = 3.0
const CONNECT_TIMEOUT = 25.0
var client: RelayClient
var channel: RelayChannel
var peer: FreelayMultiplayerPeer
var lobby = ""
var mode = "auto"
var capacity = 16
var _age = 0.0
var _discovery_age = 0.0
var _announce_age = 0.0
var _candidates: Dictionary = {}
var _hosts: Dictionary = {}
var _started = false
var _closing = false
var _channel_ready = false
var _last_connection_error = ""
var migration: FreelayMigration

func open(lobby_name: String, join_mode: String, max_players = 16):
	migration = FreelayMigration.new(self)
	lobby = lobby_name.strip_edges().to_lower()
	mode = join_mode
	capacity = max_players
	if lobby.is_empty() or lobby.length() > 64:
		_fail("Enter a lobby name between 1 and 64 characters.")
		return
	client = RelayClient.new()
	client.app_id = ProjectSettings.get_setting("freelay/app_id", "tetraforce")
	client.broker_urls = ProjectSettings.get_setting("freelay/broker_urls", PackedStringArray(["wss://broker.hivemq.com:8884/mqtt"]))
	if client.app_id.is_empty() or client.broker_urls.is_empty():
		client.free()
		client = null
		_fail("Configure freelay/app_id and freelay/broker_urls in Project Settings.")
		return
	client.peer_connection_requested.connect(_incoming_connection)
	client.opened.connect(_opened)
	add_child(client)
	client.open()
	# Fail cleanly on broker loss: RPC caches/world state require a fresh join.
	client._mqtt.disconnected.connect(_broker_disconnected)
	client._mqtt.error.connect(func(reason: String): _last_connection_error = reason)

func _opened():
	if _closing:
		return
	channel = client.join("lobby/" + lobby)
	channel.joined.connect(func():
		_channel_ready = true
		_announce()
	)
	channel.message.connect(_lobby_message)
	channel.peer_left.connect(func(remote: RelayPeer):
		_candidates.erase(remote.peer_id)
		_hosts.erase(remote.peer_id)
		if _started and peer != null:
			if !peer.is_host() and (!migration.active or migration.preparing) and peer.identities.get(1) == remote.peer_id:
				migration.host_lost("The host left the lobby.")
			elif peer.is_host():
				var departed = peer.identities.find_key(remote.peer_id)
				if departed != null and peer.connections.has(departed):
					peer.connections[departed].close()
	)

func _process(delta):
	if _closing or client == null:
		return
	_age += delta
	migration.tick(delta)
	if _closing:
		return
	if !_started and _age >= CONNECT_TIMEOUT:
		var reason = "Timed out connecting to the lobby. Check the broker URL and your connection."
		if !_last_connection_error.is_empty():
			reason += "\n" + _last_connection_error
		_fail(reason)
		return
	if !_channel_ready:
		return
	_announce_age += delta
	if _announce_age >= 1.0:
		_announce_age = 0.0
		_announce()
	if peer != null:
		if _started and !peer.is_host() and (!migration.active or migration.preparing):
			var host = peer.identities.get(1, "")
			if Time.get_ticks_msec() - _hosts.get(host, Time.get_ticks_msec()) > 5000:
				migration.host_lost("Host heartbeat timed out.")
		return
	_discovery_age += delta
	if _discovery_age < DISCOVERY_SECONDS:
		return
	var live_hosts: Array = []
	for id in _hosts:
		if Time.get_ticks_msec() - _hosts[id] < 4000:
			live_hosts.append(id)
	live_hosts.sort()
	if !live_hosts.is_empty():
		if mode == "host":
			_fail("This lobby already has a host. Choose Join or a different lobby name.")
		else:
			_join_host(live_hosts[0])
	elif mode != "join":
		var candidates: Array = [client.profile.peer_id]
		for id in _candidates:
			if Time.get_ticks_msec() - _candidates[id] < 4000:
				candidates.append(id)
		candidates.sort()
		if candidates[0] == client.profile.peer_id:
			_become_host()

func _announce():
	if channel == null or !channel.is_joined() or !client.is_open():
		return
	var role = "join" if mode == "join" else "candidate"
	if peer != null:
		role = "host" if peer.is_host() else "join"
	channel.send({"kind": "discovery", "role": role, "version": global.version})

func _lobby_message(remote: RelayPeer, data: Variant):
	if !(data is Dictionary):
		return
	if str(data.get("kind", "")).begins_with("migration_"):
		migration.message(remote, data)
		return
	if data.get("kind") != "discovery" or data.get("version") != global.version:
		return
	match data.get("role"):
		"host":
			_hosts[remote.peer_id] = Time.get_ticks_msec()
		"candidate":
			_candidates[remote.peer_id] = Time.get_ticks_msec()
			# Reply immediately so a new arrival discovers an existing host.
			if peer != null and peer.is_host():
				_announce()

func _become_host():
	peer = FreelayMultiplayerPeer.new()
	peer.configure_host(global.version, lobby, capacity)
	migration.attach(peer)
	_started = true
	_announce()
	session_ready.emit(peer)

func _join_host(id: String):
	peer = FreelayMultiplayerPeer.new()
	var conn = client.connect_peer(id)
	peer.configure_client(conn, global.version, lobby)
	migration.attach(peer)
	peer.admitted.connect(func():
		_started = true
		capacity = peer.max_players
		_hosts[peer.identities.get(1)] = Time.get_ticks_msec()
		session_ready.emit(peer)
	)
	peer.connection_lost.connect(func(reason: String):
		if _closing:
			return
		migration.host_lost(reason)
	)

func prepare_leave():
	if migration != null and !_closing:
		await migration.prepare_leave()

func _yield_host():
	if _closing:
		return
	if migration.leaving:
		migration.complete = true
		close()
		return
	migration._begin()
	disconnected.emit("Host ownership was transferred after the gameplay connection was lost. You can rejoin the lobby.")

func _migration_connect(host: String, members: Dictionary, id: String, epoch: int):
	if _closing:
		return
	if peer != null:
		peer.close()
	peer = FreelayMultiplayerPeer.new()
	peer.session_id = id
	peer.host_epoch = epoch
	peer.reserved_ids = members.duplicate()
	peer._next_id = 2
	for assigned in members.values():
		peer._next_id = maxi(peer._next_id, assigned + 1)
	if host == client.profile.peer_id:
		peer.configure_host(global.version, lobby, capacity)
		migration.attach(peer)
		# attach keeps the election's base epoch until restoration completes.
		peer.host_epoch = epoch
		migration_peer_ready.emit(peer)
		migration.peer_ready(peer)
	else:
		var conn = client.connect_peer(host)
		peer.configure_client(conn, global.version, lobby)
		migration.attach(peer)
		var joining_peer = peer
		peer.admitted.connect(func():
			capacity = peer.max_players
			_hosts[host] = Time.get_ticks_msec()
			migration_peer_ready.emit(peer)
			migration.peer_ready(peer)
		)
		peer.connection_lost.connect(func(reason: String):
			if !_closing and peer == joining_peer:
				if migration.active:
					# Signed votes can arrive before the winner's deferred server
					# installation. Retry the encrypted handshake, bounded by the
					# migration timeout, instead of treating that race as a failure.
					get_tree().create_timer(0.5).timeout.connect(func():
						if !_closing and migration.active and migration.installed and peer == joining_peer:
							_migration_connect(host, members, id, epoch)
					)
				else:
					migration.host_lost(reason)
		)

func _incoming_connection(conn: RelayPeerConnection):
	if _closing or peer == null or !peer.is_host() or (migration.active and (!migration.installed or !peer.reserved_ids.has(conn.remote_peer_id))):
		conn.reject()
	else:
		peer.accept_connection(conn)

func _broker_disconnected(reason: String):
	if _closing:
		return
	if _started:
		disconnected.emit("Broker connection lost: " + reason)
	else:
		_fail("Could not connect to the MQTT broker: " + reason)

func _fail(reason: String):
	print("Freelay session failed: " + reason)
	close()
	failed.emit(reason)

func close():
	if _closing:
		return
	_closing = true
	if peer != null:
		peer.close()
	if client != null:
		client.close()
	# Let MQTT flush signed leaves, FIN and DISCONNECT before freeing sockets.
	get_tree().create_timer(1.0).timeout.connect(queue_free)
