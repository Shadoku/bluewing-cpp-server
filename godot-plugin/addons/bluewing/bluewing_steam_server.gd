## BluewingSteamServer
## Lacewing relay server using Steam Networking Sockets for NAT traversal.
## Drop-in replacement for BluewingServer — compatible with BluewingSteamClient.
## Requires GodotSteam 4.x — https://godotsteam.com
##
## Usage difference from BluewingServer:
##   server.host()                         # no port — Steam handles addressing
##   server.start_as_host(steam_client)    # takes BluewingSteamClient
##
## Clients connect using this machine's int64 SteamID, not an IP address.
## Obtain the SteamID via Steam.get_steam_id() and share it through a lobby.

class_name BluewingSteamServer
extends Node

# ---------------------------------------------------------------------------
# Inner classes
# ---------------------------------------------------------------------------

class RemoteClient extends RefCounted:
	var id:            int
	var name:          String = ""
	var channels:      Array  = []  # Array[RemoteChannel]
	var _connection:   int    = -1  # Steam connection handle
	var _approved:     bool   = false
	var _hook_denied:  bool   = false
	var _hook_reason:  String = ""
	var _pending_name: String = ""


class RemoteChannel extends RefCounted:
	var id:        int
	var name:      String
	var clients:   Array        = []  # Array[RemoteClient]
	var master:    RemoteClient
	var hidden:    bool         = false
	var autoclose: bool         = false

# ---------------------------------------------------------------------------
# Signals — identical surface to BluewingServer
# ---------------------------------------------------------------------------

signal client_connected(client: RemoteClient)
signal client_disconnected(client: RemoteClient)
signal name_requested(client: RemoteClient)
signal channel_join_requested(client: RemoteClient, channel_name: String, hidden: bool, autoclose: bool)
signal channel_left(client: RemoteClient, channel: RemoteChannel)
signal message_server(client: RemoteClient, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)
signal message_channel(channel: RemoteChannel, sender: RemoteClient, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)
signal message_peer(channel: RemoteChannel, sender: RemoteClient, target: RemoteClient, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)

# ---------------------------------------------------------------------------
# Exported settings
# ---------------------------------------------------------------------------

## Virtual port for ISteamNetworkingSockets P2P.  Must match BluewingSteamClient.virtual_port.
@export var virtual_port: int = 0

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _listen_socket:   int    = -1
var _poll_group:      int    = -1
var _clients:         Array  = []  # Array[RemoteClient]
var _channels:        Array  = []  # Array[RemoteChannel]
var _next_client_id:  int    = 1
var _next_channel_id: int    = 1
var _welcome_message: String = ""

# connection handle (int) ↔ RemoteClient
var _conn_to_client: Dictionary = {}
var _client_to_conn: Dictionary = {}  # RemoteClient instance_id → connection handle

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Start listening for Steam P2P connections.
## The port parameter is ignored; Steam uses SteamIDs, not ports.
func host(_port: int = 0, welcome_message: String = "") -> Error:
	if not _steam_ok():
		return FAILED
	_welcome_message = welcome_message
	_listen_socket = Steam.create_listen_socket_p2p(virtual_port, [])  # GodotSteam
	if _listen_socket <= 0:
		push_error("BluewingSteamServer: create_listen_socket_p2p failed.")
		return FAILED
	_poll_group = Steam.create_poll_group()  # GodotSteam
	if not Steam.network_connection_status_changed.is_connected(_on_steam_status_changed):
		Steam.network_connection_status_changed.connect(_on_steam_status_changed)
	return OK


## Stop the server and disconnect all clients.
func unhost() -> void:
	for c in _clients.duplicate():
		_disconnect_client(c, false)
	_clients.clear()
	_channels.clear()
	_conn_to_client.clear()
	_client_to_conn.clear()
	_next_client_id  = 1
	_next_channel_id = 1
	if _poll_group != -1:
		Steam.destroy_poll_group(_poll_group)  # GodotSteam
		_poll_group = -1
	if _listen_socket != -1:
		Steam.close_listen_socket(_listen_socket)  # GodotSteam
		_listen_socket = -1


## Convenience: start the server, then connect the local Steam client to it.
func start_as_host(client: BluewingSteamClient, welcome_message: String = "") -> Error:
	var err := host(0, welcome_message)
	if err != OK:
		return err
	client.connect_to_steam(Steam.get_steam_id())  # GodotSteam
	return OK


## Approve a pending connect (or omit to auto-approve).
func approve_connect(client: RemoteClient, welcome_message: String = "") -> void:
	client._approved    = true
	client._hook_denied = false
	var msg := PackedByteArray([0x00, 0x01])
	_u16(msg, client.id)
	msg.append_array(welcome_message.to_utf8_buffer())
	_send_reliable(client, 0, 0, msg)


## Reject a pending connect.
func deny_connect(client: RemoteClient, reason: String = "") -> void:
	client._hook_denied = true
	client._hook_reason = reason
	var msg := PackedByteArray([0x00, 0x00])
	msg.append_array(reason.to_utf8_buffer())
	_send_reliable(client, 0, 0, msg)
	_disconnect_client(client, false)


## Reject a pending name request.
func deny_name(client: RemoteClient, reason: String = "") -> void:
	client._hook_denied = true
	client._hook_reason = reason
	var name_bytes := client._pending_name.to_utf8_buffer()
	var msg        := PackedByteArray([0x01, 0x00])
	msg.append(name_bytes.size() & 0xFF)
	msg.append_array(name_bytes)
	msg.append_array(reason.to_utf8_buffer())
	_send_reliable(client, 0, 0, msg)


## Reject a pending channel join.
func deny_join(client: RemoteClient, channel_name: String, reason: String = "") -> void:
	client._hook_denied = true
	client._hook_reason = reason
	var name_bytes := channel_name.to_utf8_buffer()
	var msg        := PackedByteArray([0x02, 0x00])
	msg.append(name_bytes.size() & 0xFF)
	msg.append_array(name_bytes)
	msg.append_array(reason.to_utf8_buffer())
	_send_reliable(client, 0, 0, msg)


## Forcibly disconnect a client.
func kick_client(client: RemoteClient, _reason: String = "") -> void:
	_disconnect_client(client, true)


## Broadcast a reliable server message to all clients in a channel.
func send_channel_message(channel: RemoteChannel, subchannel: int, data: PackedByteArray) -> void:
	var msg := PackedByteArray([subchannel & 0xFF])
	_u16(msg, channel.id)
	msg.append_array(data)
	for c in channel.clients:
		_send_reliable(c as RemoteClient, 4, 0, msg)


## Send a reliable server message to one client.
func send_to_client(client: RemoteClient, subchannel: int, data: PackedByteArray) -> void:
	var msg := PackedByteArray([subchannel & 0xFF])
	msg.append_array(data)
	_send_reliable(client, 1, 0, msg)


## Find a channel by name (null if not found).
func find_channel(channel_name: String) -> RemoteChannel:
	for ch in _channels:
		if (ch as RemoteChannel).name == channel_name:
			return ch
	return null


## Find a connected client by peer ID (null if not found).
func find_client(client_id: int) -> RemoteClient:
	return _find_client_by_id(client_id)


var is_hosting: bool:
	get: return _listen_socket != -1

# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _poll_group == -1:
		return
	_poll_steam_messages()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		unhost()

# ---------------------------------------------------------------------------
# Steam connection state changes
# ---------------------------------------------------------------------------

func _on_steam_status_changed(connection: int, state_info, _old_state: int) -> void:
	var state: int = state_info if typeof(state_info) == TYPE_INT \
		else (state_info as Dictionary).get("state", 0)

	match state:
		1:  # Connecting — new inbound connection
			Steam.accept_connection(connection)  # GodotSteam
			var c        := RemoteClient.new()
			c.id          = _next_client_id
			c._connection = connection
			_next_client_id += 1
			if _next_client_id >= 0xFFFF:
				_next_client_id = 1
			_clients.append(c)
			_conn_to_client[connection]              = c
			_client_to_conn[c.get_instance_id()]     = connection
			Steam.set_connection_poll_group(connection, _poll_group)  # GodotSteam

		4, 5:  # ClosedByPeer, ProblemDetectedLocally
			var c := _conn_to_client.get(connection) as RemoteClient
			if c != null:
				_disconnect_client(c, true)

# ---------------------------------------------------------------------------
# Steam message receive loop
# ---------------------------------------------------------------------------

func _poll_steam_messages() -> void:
	var messages: Array = Steam.receive_messages_on_poll_group(_poll_group, 256)  # GodotSteam
	for msg in messages:
		var conn:    int              = msg.get("connection", -1)
		var payload: PackedByteArray  = msg.get("payload", PackedByteArray())
		var flags:   int              = msg.get("flags", 0)
		if payload.is_empty():
			continue
		var c := _conn_to_client.get(conn) as RemoteClient
		if c == null:
			continue
		var type_byte: int = payload[0]
		var msg_type:  int = type_byte >> 4
		var variant:   int = type_byte & 0x0F
		var data           := payload.slice(1)
		var blasted:   bool = (flags & 8) == 0  # absence of RELIABLE flag = unreliable

		match msg_type:
			0: _handle_request(c, data)
			1: _handle_msg_server(c, data, variant, blasted)
			2: _handle_relay_channel(c, data, variant, blasted)
			3: _handle_relay_peer(c, data, variant, blasted)

# ---------------------------------------------------------------------------
# Request handlers
# ---------------------------------------------------------------------------

func _handle_request(c: RemoteClient, data: PackedByteArray) -> void:
	if data.is_empty():
		return
	match data[0]:
		0x00: _handle_connect(c, data)
		0x01: _handle_setname(c, data)
		0x02: _handle_joinchannel(c, data)
		0x03: _handle_leavechannel(c, data)
		0x04: _handle_channellist(c)


func _handle_connect(c: RemoteClient, _data: PackedByteArray) -> void:
	c._hook_denied = false
	c._hook_reason = ""
	client_connected.emit(c)
	if not c._hook_denied and not c._approved:
		approve_connect(c, _welcome_message)


func _handle_setname(c: RemoteClient, data: PackedByteArray) -> void:
	if not c._approved:
		return
	var requested := data.slice(1).get_string_from_utf8()
	for other in _clients:
		var o := other as RemoteClient
		if o != c and o._approved and o.name == requested:
			var nb  := requested.to_utf8_buffer()
			var msg := PackedByteArray([0x01, 0x00])
			msg.append(nb.size() & 0xFF)
			msg.append_array(nb)
			msg.append_array("Name already taken.".to_utf8_buffer())
			_send_reliable(c, 0, 0, msg)
			return

	c._pending_name = requested
	c._hook_denied  = false
	c._hook_reason  = ""
	name_requested.emit(c)
	if c._hook_denied:
		return

	c.name          = requested
	c._pending_name = ""
	var nb  := c.name.to_utf8_buffer()
	var msg := PackedByteArray([0x01, 0x01])
	msg.append(nb.size() & 0xFF)
	msg.append_array(nb)
	_send_reliable(c, 0, 0, msg)
	for ch in c.channels:
		_notify_peer_update(ch, c)


func _handle_joinchannel(c: RemoteClient, data: PackedByteArray) -> void:
	if not c._approved or c.name.is_empty() or data.size() < 3:
		return
	var flags:     int  = data[1]
	var hidden:    bool = (flags & 1) != 0
	var autoclose: bool = (flags & 2) != 0
	var ch_name        := data.slice(2).get_string_from_utf8()

	c._hook_denied = false
	c._hook_reason = ""
	channel_join_requested.emit(c, ch_name, hidden, autoclose)
	if c._hook_denied:
		return

	var ch := find_channel(ch_name)
	if ch == null:
		ch          = RemoteChannel.new()
		ch.id       = _next_channel_id
		ch.name     = ch_name
		ch.hidden   = hidden
		ch.autoclose = autoclose
		ch.master   = c
		_next_channel_id += 1
		if _next_channel_id >= 0xFFFF:
			_next_channel_id = 1
		_channels.append(ch)

	if c.channels.has(ch):
		return

	var is_master := (ch.master == c)
	var name_bytes := ch.name.to_utf8_buffer()
	var msg := PackedByteArray([0x02, 0x01, 0x01 if is_master else 0x00])
	msg.append(name_bytes.size() & 0xFF)
	msg.append_array(name_bytes)
	_u16(msg, ch.id)
	for peer in ch.clients:
		var p          := peer as RemoteClient
		var peer_nb    := p.name.to_utf8_buffer()
		_u16(msg, p.id)
		msg.append(0x01 if ch.master == p else 0x00)
		msg.append(peer_nb.size() & 0xFF)
		msg.append_array(peer_nb)
	_send_reliable(c, 0, 0, msg)

	_notify_peer_joined(ch, c)
	ch.clients.append(c)
	c.channels.append(ch)


func _handle_leavechannel(c: RemoteClient, data: PackedByteArray) -> void:
	if data.size() < 3:
		return
	var ch_id := data[1] | (data[2] << 8)
	var ch    := _find_channel_by_id(ch_id)
	if ch == null or not c.channels.has(ch):
		return
	var msg := PackedByteArray([0x03, 0x01])
	_u16(msg, ch.id)
	_send_reliable(c, 0, 0, msg)
	_remove_from_channel(c, ch)
	channel_left.emit(c, ch)


func _handle_channellist(c: RemoteClient) -> void:
	if not c._approved:
		return
	var msg := PackedByteArray([0x04, 0x01])
	for channel in _channels:
		var ch := channel as RemoteChannel
		if ch.hidden:
			continue
		_u16(msg, ch.clients.size())
		var nb := ch.name.to_utf8_buffer()
		msg.append(nb.size() & 0xFF)
		msg.append_array(nb)
	_send_reliable(c, 0, 0, msg)

# ---------------------------------------------------------------------------
# Relay handlers
# ---------------------------------------------------------------------------

func _handle_msg_server(c: RemoteClient, data: PackedByteArray, variant: int, blasted: bool) -> void:
	if not c._approved or data.is_empty():
		return
	message_server.emit(c, data[0], data.slice(1), variant, blasted)


func _handle_relay_channel(c: RemoteClient, data: PackedByteArray, variant: int, blasted: bool) -> void:
	if not c._approved or data.size() < 3:
		return
	var subchannel: int = data[0]
	var ch_id:      int = data[1] | (data[2] << 8)
	var ch := _find_channel_by_id(ch_id)
	if ch == null or not c.channels.has(ch):
		return
	var payload := data.slice(3)
	message_channel.emit(ch, c, subchannel, payload, variant, blasted)

	var relay := PackedByteArray([subchannel & 0xFF])
	_u16(relay, ch.id)
	_u16(relay, c.id)
	relay.append_array(payload)
	for peer in ch.clients:
		var p := peer as RemoteClient
		if p != c:
			_send_to(p, 2, variant, relay, not blasted)


func _handle_relay_peer(c: RemoteClient, data: PackedByteArray, variant: int, blasted: bool) -> void:
	if not c._approved or data.size() < 5:
		return
	var subchannel: int = data[0]
	var ch_id:      int = data[1] | (data[2] << 8)
	var target_id:  int = data[3] | (data[4] << 8)
	var ch := _find_channel_by_id(ch_id)
	if ch == null or not c.channels.has(ch):
		return
	var target := _find_client_in_channel(ch, target_id)
	if target == null:
		return
	var payload := data.slice(5)
	message_peer.emit(ch, c, target, subchannel, payload, variant, blasted)

	var relay := PackedByteArray([subchannel & 0xFF])
	_u16(relay, ch.id)
	_u16(relay, c.id)
	relay.append_array(payload)
	_send_to(target, 3, variant, relay, not blasted)

# ---------------------------------------------------------------------------
# Disconnect / channel cleanup
# ---------------------------------------------------------------------------

func _disconnect_client(c: RemoteClient, fire_signal: bool) -> void:
	if not _clients.has(c):
		return
	for ch in c.channels.duplicate():
		_remove_from_channel(c, ch as RemoteChannel)
	var conn := _client_to_conn.get(c.get_instance_id(), -1) as int
	if conn != -1:
		Steam.close_connection(conn, 0, "", false)  # GodotSteam
		_conn_to_client.erase(conn)
		_client_to_conn.erase(c.get_instance_id())
	_clients.erase(c)
	if fire_signal and c._approved:
		client_disconnected.emit(c)


func _remove_from_channel(c: RemoteClient, ch: RemoteChannel) -> void:
	ch.clients.erase(c)
	c.channels.erase(ch)
	_notify_peer_left(ch, c)

	if ch.clients.is_empty():
		_channels.erase(ch)
		return

	if ch.master == c:
		if ch.autoclose:
			for peer in ch.clients.duplicate():
				var p := peer as RemoteClient
				p.channels.erase(ch)
				_notify_peer_left(ch, p)
			ch.clients.clear()
			_channels.erase(ch)
		else:
			var new_master := ch.clients[0] as RemoteClient
			for peer in ch.clients:
				var p := peer as RemoteClient
				if p.id < new_master.id:
					new_master = p
			ch.master = new_master
			_notify_peer_update(ch, new_master)

# ---------------------------------------------------------------------------
# Peer notification helpers
# ---------------------------------------------------------------------------

func _notify_peer_joined(ch: RemoteChannel, new_peer: RemoteClient) -> void:
	var nb  := new_peer.name.to_utf8_buffer()
	var msg := PackedByteArray()
	_u16(msg, ch.id)
	_u16(msg, new_peer.id)
	msg.append(0x01 if ch.master == new_peer else 0x00)
	msg.append_array(nb)
	for peer in ch.clients:
		_send_reliable(peer as RemoteClient, 9, 0, msg)


func _notify_peer_left(ch: RemoteChannel, gone_peer: RemoteClient) -> void:
	var msg := PackedByteArray()
	_u16(msg, ch.id)
	_u16(msg, gone_peer.id)
	for peer in ch.clients:
		_send_reliable(peer as RemoteClient, 9, 0, msg)


func _notify_peer_update(ch: RemoteChannel, changed_peer: RemoteClient) -> void:
	var nb  := changed_peer.name.to_utf8_buffer()
	var msg := PackedByteArray()
	_u16(msg, ch.id)
	_u16(msg, changed_peer.id)
	msg.append(0x01 if ch.master == changed_peer else 0x00)
	msg.append_array(nb)
	for peer in ch.clients:
		if (peer as RemoteClient) != changed_peer:
			_send_reliable(peer as RemoteClient, 9, 0, msg)

# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------

func _find_client_by_id(id: int) -> RemoteClient:
	for c in _clients:
		if (c as RemoteClient).id == id:
			return c
	return null


func _find_channel_by_id(id: int) -> RemoteChannel:
	for ch in _channels:
		if (ch as RemoteChannel).id == id:
			return ch
	return null


func _find_client_in_channel(ch: RemoteChannel, client_id: int) -> RemoteClient:
	for c in ch.clients:
		if (c as RemoteClient).id == client_id:
			return c
	return null

# ---------------------------------------------------------------------------
# Steam send helpers
# ---------------------------------------------------------------------------

func _send_reliable(c: RemoteClient, type: int, variant: int, data: PackedByteArray) -> void:
	_send_to(c, type, variant, data, true)


func _send_to(c: RemoteClient, type: int, variant: int, data: PackedByteArray, reliable: bool) -> void:
	var conn := _client_to_conn.get(c.get_instance_id(), -1) as int
	if conn == -1:
		return
	var frame := PackedByteArray([(type << 4) | (variant & 0x0F)])
	frame.append_array(data)
	# 8 = k_nSteamNetworkingSend_Reliable; 0 = unreliable
	Steam.send_message_to_connection(conn, frame, 8 if reliable else 0)  # GodotSteam

# ---------------------------------------------------------------------------
# Byte utilities
# ---------------------------------------------------------------------------

func _steam_ok() -> bool:
	if not Engine.has_singleton("Steam"):
		push_error("BluewingSteamServer: Steam singleton not found — is GodotSteam installed and initialised?")
		return false
	return true


static func _u16(buf: PackedByteArray, value: int) -> void:
	buf.append(value & 0xFF)
	buf.append((value >> 8) & 0xFF)
