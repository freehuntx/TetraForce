extends Node
## Browser-only probe driven by tests/run_freelay_browser_regression.mjs.
var main: Main
var role = "join"
var _marker_sent = false
var _leaving = false
var _age = 0.0
var _tracked: Dictionary = {}
var _kinds: Dictionary = {}
var _mqtt_frames = 0
var _lobby_name = ""

func _ready():
	var args = {}
	for argument in OS.get_cmdline_user_args():
		var parts = argument.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	role = args.get("role", "join")
	_lobby_name = args.get("lobby")
	ProjectSettings.set_setting("freelay/broker_urls", PackedStringArray([args.get("broker")]))
	ProjectSettings.set_setting("freelay/ice_servers", [])
	main = preload("res://engine/main.tscn").instantiate()
	add_child(main)
	global.options.player_data.name = "Browser " + role
	await get_tree().create_timer(0.7).timeout
	main.connect_lobby(_lobby_name, role)

func _process(delta):
	if !OS.has_feature("web") or !is_instance_valid(main):
		return
	_age += delta
	if _age < 0.1:
		return
	_age = 0.0
	var action = JavaScriptBridge.eval("window.tetraAction || ''")
	if !str(action).is_empty():
		JavaScriptBridge.eval("window.tetraAction = ''")
		match action:
			"leave":
				_leaving = true
				main.end_game()
			"bad-profile":
				network.rpc_id(1, "_receive_my_player_data", {"name": 0, "skin": global.options.player_data.skin})
			"rejoin":
				_tracked.clear()
				_kinds.clear()
				_mqtt_frames = 0
				main.get_node("message").hide()
				main.connect_lobby(_lobby_name, "join")
	var status = {"role": role, "leaving": _leaving, "players": network.player_list.size(), "migrating": network.migrating, "marker": network.states.get("browser_marker", []), "map": is_instance_valid(network.current_map), "error": main.get_node("message/Label").text if main.get_node("message").visible else ""}
	if is_instance_valid(main.relay_session):
		var session = main.relay_session
		status.started = session._started
		status.checkpoint = !session.migration.snapshot.is_empty()
		status.members = session.migration.members.size()
		status.epoch = session.migration.epoch
		status.debug = {"roster": session.migration.roster, "proposal": session.migration._proposal, "acks": session.migration._proposal_acks, "send": session.peer._send_sequences if session.peer != null else {}, "receive": session.peer._receive_sequences if session.peer != null else {}, "connections": {}}
		status.debug.kinds = _kinds
		status.debug.mqtt_frames = _mqtt_frames
		status.debug.outgoing = session.client._mqtt._outgoing_bytes
		if !_tracked.has("mqtt"):
			_tracked["mqtt"] = true
			session.client._mqtt.message.connect(func(topic, _payload, _retained):
				if "/s/" in topic:
					_mqtt_frames += 1
			)
		if session.peer != null:
			for id in session.peer.connections:
				var conn = session.peer.connections[id]
				if !_tracked.has(conn.get_instance_id()):
					_tracked[conn.get_instance_id()] = true
					conn.message.connect(func(data):
						if data is Dictionary:
							var kind = str(data.get("kind", "?")) + (":" + str(data.get("data", {}).get("type", "?")) if data.get("kind") == "control" else "")
							_kinds[kind] = _kinds.get(kind, 0) + 1
					)
				status.debug.connections[id] = {"tracked": session.client._connections.has(conn._session_id_b32), "state": conn.state, "last_received": Time.get_ticks_msec() - conn.last_received_msec, "r_packets": conn._rtc_ch_r.get_available_packet_count() if conn._rtc_ch_r != null else -1, "u_packets": conn._rtc_ch_u.get_available_packet_count() if conn._rtc_ch_u != null else -1}
		status.host = session.client.profile.peer_id if session.peer != null and session.peer.is_host() else (session.peer.identities.get(1, "") if session.peer != null else "")
		status.rtc = session.peer != null and !session.peer.connections.is_empty()
		if session.peer != null:
			for conn in session.peer.connections.values():
				status.rtc = status.rtc and conn.transport == RelayPeerConnection.TRANSPORT_RTC
	if !_marker_sent and status.players == 2 and multiplayer.is_server() and !network.migrating:
		_marker_sent = true
		network.set_state("browser_marker", [42])
	JavaScriptBridge.eval("window.tetraState = " + JSON.stringify(status))
