## BluewingServer
## GDScript Lacewing Relay Protocol server compatible with BluewingClient.
##
## Typical usage (standalone):
##   var server = BluewingServer.new()
##   add_child(server)
##   server.host(6121, "Welcome!")
##
## Typical usage (in-game host):
##   server.start_as_host(my_bluewing_client)
##
## To add access control, connect to the hook signals and call deny_*()
## from within the handler.  If no deny is called, everything auto-approves.

class_name BluewingServer
extends Node

# ---------------------------------------------------------------------------
# Public inner classes
# ---------------------------------------------------------------------------

class RemoteClient extends RefCounted:
	var id:      int
	var name:    String = ""
	var channels: Array = []  # Array[RemoteChannel]

	# --- internal ---
	var _stream:           StreamPeerTCP
	var _udp_ip:           String = ""
	var _udp_port:         int    = 0
	var _approved:         bool   = false
	var _hook_denied:      bool   = false
	var _hook_reason:      String = ""
	# Frame-reader state
	var _got_first_byte:   bool              = false
	var _recv_buf:         PackedByteArray   = PackedByteArray()
	var _read_state:       int               = 0
	var _msg_type:         int               = 0
	var _msg_size:         int               = 0
	var _size_buf:         PackedByteArray   = PackedByteArray()
	var _size_bytes_left:  int               = 0
	var _data_buf:         PackedByteArray   = PackedByteArray()
	# Pending request state (for name / join hooks)
	var _pending_name:     String            = ""


class RemoteChannel extends RefCounted:
	var id:        int
	var name:      String
	var clients:   Array = []  # Array[RemoteClient]
	var master:    RemoteClient  # null after master leaves (when not autoclose)
	var hidden:    bool = false
	var autoclose: bool = false

# ---------------------------------------------------------------------------
# Hook signals — call deny_*() inside the handler to reject; otherwise
# the request is auto-approved when the handler returns.
# ---------------------------------------------------------------------------

## A new TCP connection arrived.  Call deny_connect(client, reason) to reject.
signal client_connected(client: RemoteClient)

## A client disconnected (cleanly or on error).
signal client_disconnected(client: RemoteClient)

## A client requested a name.  The requested name is client._pending_name.
## Call deny_name(client, reason) to reject.
signal name_requested(client: RemoteClient)

## A client requested to join or create a channel.
## Call deny_join(client, reason) to reject.
signal channel_join_requested(client: RemoteClient, channel_name: String, hidden: bool, autoclose: bool)

## A client left a channel (after it has happened — informational only).
signal channel_left(client: RemoteClient, channel: RemoteChannel)

## Informational message signals (no approve/deny).
signal message_server(client: RemoteClient, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)
signal message_channel(channel: RemoteChannel, sender: RemoteClient, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)
signal message_peer(channel: RemoteChannel, sender: RemoteClient, target: RemoteClient, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Start the server on the given port.
func host(port: int = 6121, welcome_message: String = "") -> Error:
	_welcome_message = welcome_message
	_port = port

	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(port)
	if err != OK:
		_tcp_server = null
		push_error("BluewingServer: TCPServer.listen(%d) failed: %s" % [port, error_string(err)])
		return err

	_udp = PacketPeerUDP.new()
	err = _udp.bind(port)
	if err != OK:
		_tcp_server.stop()
		_tcp_server = null
		_udp = null
		push_error("BluewingServer: UDP bind(%d) failed: %s" % [port, error_string(err)])
		return err

	return OK


## Stop the server and disconnect all clients.
func unhost() -> void:
	for c in _clients.duplicate():
		_disconnect_client(c, false)
	_clients.clear()
	_channels.clear()
	_next_client_id = 1
	_next_channel_id = 1

	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	if _udp != null:
		_udp.close()
		_udp = null


## Convenience: start the server and connect the given client to localhost.
func start_as_host(client: BluewingClient, port: int = 6121, welcome_message: String = "") -> Error:
	var err := host(port, welcome_message)
	if err != OK:
		return err
	client.connect_to_server("127.0.0.1", port)
	return OK


## Approve a pending connect (call from client_connected handler, or omit to auto-approve).
func approve_connect(client: RemoteClient, welcome_message: String = "") -> void:
	client._approved = true
	client._hook_denied = false
	var msg := PackedByteArray([0x00, 0x01])
	_u16(msg, client.id)
	msg.append_array(welcome_message.to_utf8_buffer())
	_send_tcp_to(client, 0, 0, msg)


## Reject a pending connect request.
func deny_connect(client: RemoteClient, reason: String = "") -> void:
	client._hook_denied = true
	client._hook_reason = reason
	var msg := PackedByteArray([0x00, 0x00])
	msg.append_array(reason.to_utf8_buffer())
	_send_tcp_to(client, 0, 0, msg)
	# Disconnect after the frame is flushed (next poll will clean it up).
	client._stream.disconnect_from_host()


## Reject a pending name request (call from name_requested handler).
func deny_name(client: RemoteClient, reason: String = "") -> void:
	client._hook_denied = true
	client._hook_reason = reason
	var name_bytes := client._pending_name.to_utf8_buffer()
	var msg := PackedByteArray([0x01, 0x00])
	msg.append(name_bytes.size() & 0xFF)
	msg.append_array(name_bytes)
	msg.append_array(reason.to_utf8_buffer())
	_send_tcp_to(client, 0, 0, msg)


## Reject a pending channel join (call from channel_join_requested handler).
func deny_join(client: RemoteClient, channel_name: String, reason: String = "") -> void:
	client._hook_denied = true
	client._hook_reason = reason
	var name_bytes := channel_name.to_utf8_buffer()
	var msg := PackedByteArray([0x02, 0x00])
	msg.append(name_bytes.size() & 0xFF)
	msg.append_array(name_bytes)
	msg.append_array(reason.to_utf8_buffer())
	_send_tcp_to(client, 0, 0, msg)


## Forcibly disconnect a client.
func kick_client(client: RemoteClient, reason: String = "") -> void:
	_disconnect_client(client, true)


## Broadcast a reliable server message to all clients in a channel.
func send_channel_message(channel: RemoteChannel, subchannel: int, data: PackedByteArray) -> void:
	var msg := PackedByteArray([subchannel & 0xFF])
	_u16(msg, channel.id)
	msg.append_array(data)
	for c in channel.clients:
		_send_tcp_to(c, 4, 0, msg)


## Send a reliable server message to one specific client.
func send_to_client(client: RemoteClient, subchannel: int, data: PackedByteArray) -> void:
	var msg := PackedByteArray([subchannel & 0xFF])
	msg.append_array(data)
	_send_tcp_to(client, 1, 0, msg)


## Find a channel by name (null if not found).
func find_channel(channel_name: String) -> RemoteChannel:
	for ch in _channels:
		if (ch as RemoteChannel).name == channel_name:
			return ch
	return null


## Find a connected client by peer ID (null if not found).
func find_client(client_id: int) -> RemoteClient:
	return _find_client_by_id(client_id)


## Whether the server is currently listening.
var is_hosting: bool:
	get: return _tcp_server != null and _tcp_server.is_listening()

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _tcp_server:      TCPServer = null
var _udp:             PacketPeerUDP = null
var _clients:         Array = []  # Array[RemoteClient]
var _channels:        Array = []  # Array[RemoteChannel]
var _next_client_id:  int = 1
var _next_channel_id: int = 1
var _welcome_message: String = ""
var _port:            int = 6121

# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _tcp_server == null:
		return
	_poll_new_connections()
	_poll_clients()
	_poll_udp()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		unhost()

# ---------------------------------------------------------------------------
# Connection polling
# ---------------------------------------------------------------------------

func _poll_new_connections() -> void:
	while _tcp_server != null and _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var c := RemoteClient.new()
		c.id = _next_client_id
		_next_client_id += 1
		if _next_client_id >= 0xFFFF:
			_next_client_id = 1
		c._stream = stream
		_clients.append(c)


func _poll_clients() -> void:
	var to_remove: Array = []
	for client in _clients:
		var c := client as RemoteClient
		c._stream.poll()
		var status := c._stream.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			_read_client(c)
		elif status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			to_remove.append(c)
	for c in to_remove:
		_disconnect_client(c, true)


func _read_client(c: RemoteClient) -> void:
	var avail := c._stream.get_available_bytes()
	if avail <= 0:
		return
	var result := c._stream.get_data(avail)
	if result[0] != OK:
		return
	var bytes: PackedByteArray = result[1]
	if bytes.is_empty():
		return

	var start := 0
	if not c._got_first_byte:
		if bytes[0] != 0x00:
			_disconnect_client(c, true)
			return
		c._got_first_byte = true
		start = 1

	if start < bytes.size():
		c._recv_buf.append_array(bytes.slice(start))
	_parse_client_frames(c)


func _parse_client_frames(c: RemoteClient) -> void:
	var i := 0
	var n := c._recv_buf.size()

	while i < n:
		if c._read_state == 0:
			c._msg_type = c._recv_buf[i]
			i += 1
			c._read_state = 1
			c._size_bytes_left = 0
			c._size_buf.clear()

		elif c._read_state == 1:
			var b: int = c._recv_buf[i]
			i += 1
			if c._size_bytes_left == 0:
				if b < 254:
					c._msg_size = b
					c._data_buf.clear()
					c._read_state = 2
				elif b == 254:
					c._size_bytes_left = 2
				else:
					c._size_bytes_left = 4
			else:
				c._size_buf.append(b)
				c._size_bytes_left -= 1
				if c._size_bytes_left == 0:
					if c._size_buf.size() == 2:
						c._msg_size = c._size_buf[0] | (c._size_buf[1] << 8)
					else:
						c._msg_size = (c._size_buf[0] | (c._size_buf[1] << 8)
							| (c._size_buf[2] << 16) | (c._size_buf[3] << 24))
					c._data_buf.clear()
					c._read_state = 2

		else:
			var needed := c._msg_size - c._data_buf.size()
			var avail  := n - i
			var copy   := mini(needed, avail)
			if copy > 0:
				c._data_buf.append_array(c._recv_buf.slice(i, i + copy))
				i += copy
			if c._data_buf.size() == c._msg_size:
				_handle_client_message(c, c._msg_type, c._data_buf.duplicate())
				c._read_state = 0
				c._data_buf.clear()

	if i >= n:
		c._recv_buf.clear()
	elif i > 0:
		c._recv_buf = c._recv_buf.slice(i)

# ---------------------------------------------------------------------------
# UDP polling
# ---------------------------------------------------------------------------

func _poll_udp() -> void:
	if _udp == null:
		return
	while _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		var from_ip   := _udp.get_packet_ip()
		var from_port := _udp.get_packet_port()
		if packet.size() < 1:
			continue
		var type_byte: int = packet[0]
		var msg_type:  int = type_byte >> 4
		var variant:   int = type_byte & 0x0F
		# All client→server UDP frames carry [type|var, id_lo, id_hi, ...data]
		if packet.size() < 3:
			continue
		var cid: int = packet[1] | (packet[2] << 8)
		var c := _find_client_by_id(cid)
		if c == null or not c._approved:
			continue
		var payload := packet.slice(3)

		match msg_type:
			7:  # UDP Hello
				c._udp_ip   = from_ip
				c._udp_port = from_port
				_send_udp_to_addr(from_ip, from_port, PackedByteArray([(10 << 4) | 0]))
			9:  # Pong — keep-alive, no action needed
				pass
			1:  # blast_server
				message_server.emit(c, payload[0] if payload.size() > 0 else 0,
					payload.slice(1), variant, true)
			2:  # blast_channel
				_relay_udp_channel(c, variant, payload)
			3:  # blast_peer
				_relay_udp_peer(c, variant, payload)

# ---------------------------------------------------------------------------
# Message dispatcher
# ---------------------------------------------------------------------------

func _handle_client_message(c: RemoteClient, type_byte: int, data: PackedByteArray) -> void:
	var msg_type: int = type_byte >> 4
	var variant:  int = type_byte & 0x0F

	match msg_type:
		0:  _handle_request(c, data)
		1:  _handle_msg_server(c, data, variant)
		2:  _handle_msg_channel(c, data, variant)
		3:  _handle_msg_peer(c, data, variant)
		9:  pass  # TCP pong

# ---------------------------------------------------------------------------
# Request handlers (type 0 from client)
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


func _handle_connect(c: RemoteClient, data: PackedByteArray) -> void:
	# data[0]=0x00, data[1:]="revision 3" (we don't enforce version)
	c._hook_denied = false
	c._hook_reason = ""
	client_connected.emit(c)
	if not c._hook_denied and not c._approved:
		approve_connect(c, _welcome_message)


func _handle_setname(c: RemoteClient, data: PackedByteArray) -> void:
	if not c._approved:
		return
	# data[0]=0x01, data[1:]= name bytes
	var requested := data.slice(1).get_string_from_utf8()

	# Uniqueness check.
	for other in _clients:
		var o := other as RemoteClient
		if o != c and o._approved and o.name == requested:
			var name_bytes := requested.to_utf8_buffer()
			var msg := PackedByteArray([0x01, 0x00])
			msg.append(name_bytes.size() & 0xFF)
			msg.append_array(name_bytes)
			msg.append_array("Name already taken.".to_utf8_buffer())
			_send_tcp_to(c, 0, 0, msg)
			return

	c._pending_name = requested
	c._hook_denied = false
	c._hook_reason = ""
	name_requested.emit(c)
	if c._hook_denied:
		return

	c.name = requested
	c._pending_name = ""
	var name_bytes := c.name.to_utf8_buffer()
	var msg := PackedByteArray([0x01, 0x01])
	msg.append(name_bytes.size() & 0xFF)
	msg.append_array(name_bytes)
	_send_tcp_to(c, 0, 0, msg)

	# Notify all channels this client is in about the name change.
	for ch in c.channels:
		_notify_peer_update(ch, c)


func _handle_joinchannel(c: RemoteClient, data: PackedByteArray) -> void:
	if not c._approved or c.name.is_empty():
		return
	# data[0]=0x02, data[1]=flags, data[2:]= channel name
	if data.size() < 3:
		return
	var flags:    int    = data[1]
	var hidden:   bool   = (flags & 1) != 0
	var autoclose: bool  = (flags & 2) != 0
	var ch_name := data.slice(2).get_string_from_utf8()

	c._hook_denied = false
	c._hook_reason = ""
	channel_join_requested.emit(c, ch_name, hidden, autoclose)
	if c._hook_denied:
		return

	# Find or create the channel.
	var ch := find_channel(ch_name)
	if ch == null:
		ch = RemoteChannel.new()
		ch.id     = _next_channel_id
		ch.name   = ch_name
		ch.hidden = hidden
		ch.autoclose = autoclose
		ch.master = c
		_next_channel_id += 1
		if _next_channel_id >= 0xFFFF:
			_next_channel_id = 1
		_channels.append(ch)

	# Check already joined.
	if c.channels.has(ch):
		return

	var is_master := (ch.master == c)

	# Build join-success response: [0x02, 0x01, flags, ch_name_len, ch_name, ch_id_lo, ch_id_hi, ...peers]
	var name_bytes := ch.name.to_utf8_buffer()
	var msg := PackedByteArray([0x02, 0x01, 0x01 if is_master else 0x00])
	msg.append(name_bytes.size() & 0xFF)
	msg.append_array(name_bytes)
	_u16(msg, ch.id)
	for peer in ch.clients:
		var p := peer as RemoteClient
		var peer_name_bytes := p.name.to_utf8_buffer()
		_u16(msg, p.id)
		msg.append(0x01 if ch.master == p else 0x00)
		msg.append(peer_name_bytes.size() & 0xFF)
		msg.append_array(peer_name_bytes)
	_send_tcp_to(c, 0, 0, msg)

	# Notify existing channel members about the new peer.
	_notify_peer_joined(ch, c)

	ch.clients.append(c)
	c.channels.append(ch)


func _handle_leavechannel(c: RemoteClient, data: PackedByteArray) -> void:
	if data.size() < 3:
		return
	var ch_id: int = data[1] | (data[2] << 8)
	var ch := _find_channel_by_id(ch_id)
	if ch == null or not c.channels.has(ch):
		return

	var msg := PackedByteArray([0x03, 0x01])
	_u16(msg, ch.id)
	_send_tcp_to(c, 0, 0, msg)

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
		var name_bytes := ch.name.to_utf8_buffer()
		msg.append(name_bytes.size() & 0xFF)
		msg.append_array(name_bytes)
	_send_tcp_to(c, 0, 0, msg)

# ---------------------------------------------------------------------------
# Message relay handlers
# ---------------------------------------------------------------------------

func _handle_msg_server(c: RemoteClient, data: PackedByteArray, variant: int) -> void:
	if not c._approved or data.is_empty():
		return
	message_server.emit(c, data[0], data.slice(1), variant, false)


func _handle_msg_channel(c: RemoteClient, data: PackedByteArray, variant: int) -> void:
	if not c._approved or data.size() < 3:
		return
	var subchannel: int = data[0]
	var ch_id: int = data[1] | (data[2] << 8)
	var ch := _find_channel_by_id(ch_id)
	if ch == null or not c.channels.has(ch):
		return
	var payload := data.slice(3)
	message_channel.emit(ch, c, subchannel, payload, variant, false)

	# Relay to all other channel members via TCP.
	var relay := PackedByteArray([subchannel & 0xFF])
	_u16(relay, ch.id)
	_u16(relay, c.id)
	relay.append_array(payload)
	for peer in ch.clients:
		var p := peer as RemoteClient
		if p != c:
			_send_tcp_to(p, 2, variant, relay)


func _handle_msg_peer(c: RemoteClient, data: PackedByteArray, variant: int) -> void:
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
	message_peer.emit(ch, c, target, subchannel, payload, variant, false)

	var relay := PackedByteArray([subchannel & 0xFF])
	_u16(relay, ch.id)
	_u16(relay, c.id)
	relay.append_array(payload)
	_send_tcp_to(target, 3, variant, relay)


func _relay_udp_channel(sender: RemoteClient, variant: int, payload: PackedByteArray) -> void:
	# payload after client_id: [subchannel, ch_id_lo, ch_id_hi, ...data]
	if payload.size() < 3:
		return
	var subchannel: int = payload[0]
	var ch_id: int = payload[1] | (payload[2] << 8)
	var ch := _find_channel_by_id(ch_id)
	if ch == null or not sender.channels.has(ch):
		return
	var data := payload.slice(3)
	message_channel.emit(ch, sender, subchannel, data, variant, true)

	# Relay: [type|var, subchannel, ch_id_lo, ch_id_hi, sender_id_lo, sender_id_hi, ...data]
	var packet := PackedByteArray([(2 << 4) | variant, subchannel & 0xFF])
	_u16(packet, ch.id)
	_u16(packet, sender.id)
	packet.append_array(data)
	for peer in ch.clients:
		var p := peer as RemoteClient
		if p != sender and not p._udp_ip.is_empty():
			_send_udp_to_addr(p._udp_ip, p._udp_port, packet)


func _relay_udp_peer(sender: RemoteClient, variant: int, payload: PackedByteArray) -> void:
	# payload: [subchannel, ch_id_lo, ch_id_hi, target_id_lo, target_id_hi, ...data]
	if payload.size() < 5:
		return
	var subchannel: int = payload[0]
	var ch_id:      int = payload[1] | (payload[2] << 8)
	var target_id:  int = payload[3] | (payload[4] << 8)
	var ch := _find_channel_by_id(ch_id)
	if ch == null or not sender.channels.has(ch):
		return
	var target := _find_client_in_channel(ch, target_id)
	if target == null or target._udp_ip.is_empty():
		return
	var data := payload.slice(5)
	message_peer.emit(ch, sender, target, subchannel, data, variant, true)

	var packet := PackedByteArray([(3 << 4) | variant, subchannel & 0xFF])
	_u16(packet, ch.id)
	_u16(packet, sender.id)
	packet.append_array(data)
	_send_udp_to_addr(target._udp_ip, target._udp_port, packet)

# ---------------------------------------------------------------------------
# Disconnect / channel cleanup
# ---------------------------------------------------------------------------

func _disconnect_client(c: RemoteClient, fire_signal: bool) -> void:
	if not _clients.has(c):
		return

	for ch in c.channels.duplicate():
		_remove_from_channel(c, ch)

	c._stream.disconnect_from_host()
	_clients.erase(c)

	if fire_signal and c._approved:
		client_disconnected.emit(c)


func _remove_from_channel(c: RemoteClient, ch: RemoteChannel) -> void:
	ch.clients.erase(c)
	c.channels.erase(ch)

	# Notify remaining channel members this peer left.
	_notify_peer_left(ch, c)

	if ch.clients.is_empty():
		_channels.erase(ch)
		return

	if ch.master == c:
		if ch.autoclose:
			# Close channel: notify all remaining clients they've been removed.
			for peer in ch.clients.duplicate():
				var p := peer as RemoteClient
				p.channels.erase(ch)
				# Send leave notification to the peer (no response, server-initiated).
				_notify_peer_left(ch, p)
			ch.clients.clear()
			_channels.erase(ch)
		else:
			# Elect new master: lowest ID wins.
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
	# type 9 with flags + name = peer joined.
	var name_bytes := new_peer.name.to_utf8_buffer()
	var msg := PackedByteArray()
	_u16(msg, ch.id)
	_u16(msg, new_peer.id)
	msg.append(0x01 if ch.master == new_peer else 0x00)
	msg.append_array(name_bytes)
	for peer in ch.clients:
		_send_tcp_to(peer as RemoteClient, 9, 0, msg)


func _notify_peer_left(ch: RemoteChannel, gone_peer: RemoteClient) -> void:
	# type 9 with only channel_id + peer_id = peer left.
	var msg := PackedByteArray()
	_u16(msg, ch.id)
	_u16(msg, gone_peer.id)
	for peer in ch.clients:
		_send_tcp_to(peer as RemoteClient, 9, 0, msg)


func _notify_peer_update(ch: RemoteChannel, changed_peer: RemoteClient) -> void:
	# Re-send peer-joined format to update name or master status.
	var name_bytes := changed_peer.name.to_utf8_buffer()
	var msg := PackedByteArray()
	_u16(msg, ch.id)
	_u16(msg, changed_peer.id)
	msg.append(0x01 if ch.master == changed_peer else 0x00)
	msg.append_array(name_bytes)
	for peer in ch.clients:
		if (peer as RemoteClient) != changed_peer:
			_send_tcp_to(peer as RemoteClient, 9, 0, msg)

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
# Frame builders / senders
# ---------------------------------------------------------------------------

func _send_tcp_to(c: RemoteClient, type: int, variant: int, data: PackedByteArray) -> void:
	if c._stream == null:
		return
	var frame := PackedByteArray()
	frame.append((type << 4) | (variant & 0x0F))
	var sz := data.size()
	if sz < 254:
		frame.append(sz)
	elif sz < 0xFFFF:
		frame.append(254)
		frame.append(sz & 0xFF)
		frame.append((sz >> 8) & 0xFF)
	else:
		frame.append(255)
		frame.append(sz & 0xFF)
		frame.append((sz >> 8) & 0xFF)
		frame.append((sz >> 16) & 0xFF)
		frame.append((sz >> 24) & 0xFF)
	frame.append_array(data)
	c._stream.put_data(frame)


func _send_udp_to_addr(ip: String, port: int, packet: PackedByteArray) -> void:
	if _udp == null:
		return
	_udp.set_dest_address(ip, port)
	_udp.put_packet(packet)

# ---------------------------------------------------------------------------
# Byte utilities
# ---------------------------------------------------------------------------

static func _u16(buf: PackedByteArray, value: int) -> void:
	buf.append(value & 0xFF)
	buf.append((value >> 8) & 0xFF)
