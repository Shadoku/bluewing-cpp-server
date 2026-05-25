## BluewingClient
## Godot 4 client for the Lacewing Relay Protocol (Revision 3).
## Drop this node into your scene tree and connect to its signals.
##
## Typical flow:
##   1. Call connect_to_server(host, port)
##   2. Wait for connected signal (requires UDP echo from server)
##   3. Call set_name("YourName")
##   4. Wait for name_set signal
##   5. Call join_channel("ChannelName")
##   6. Wait for channel_joined signal
##   7. Send/receive messages via send_server / send_channel / send_peer
##
## For TCP-only environments (UDP blocked by firewall), set tcp_only_mode = true
## before connecting; the connected signal will fire as soon as the TCP handshake
## succeeds instead of waiting for the UDP echo.

class_name BluewingClient
extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when the connection is fully established (UDP echo received, or
## immediately after the TCP handshake when tcp_only_mode is true).
signal connected()

## Emitted when the server denies the connection.
signal connection_denied(reason: String)

## Emitted when the TCP socket closes (cleanly or on error).
signal disconnected()

## Emitted after a successful set_name() call (first time setting a name).
signal name_set()

## Emitted after a successful set_name() call when the client already had a name.
signal name_changed(old_name: String)

## Emitted when the server rejects a set_name() call.
signal name_denied(attempted_name: String, reason: String)

## Emitted when we successfully join a channel.
signal channel_joined(channel: Channel)

## Emitted when the server rejects a join_channel() call.
signal channel_join_denied(channel_name: String, reason: String)

## Emitted just before our local state is cleaned up after leaving a channel.
signal channel_left(channel: Channel)

## Emitted when the server rejects a leave_channel() call.
signal channel_leave_denied(channel: Channel, reason: String)

## Emitted with an Array of {name, peer_count} Dictionaries after request_channel_list().
signal channel_list_received(listing: Array)

## Binary message from the server (not from a peer).
signal server_message(subchannel: int, data: PackedByteArray, variant: int, blasted: bool)

## Binary message from a peer, broadcast to all peers in a channel.
signal channel_message(channel: Channel, peer: Peer, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)

## Binary message sent directly to us from a specific peer.
signal peer_message(channel: Channel, peer: Peer, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)

## Binary message from the server addressed to a specific channel.
signal server_channel_message(channel: Channel, subchannel: int, data: PackedByteArray, variant: int, blasted: bool)

## A new peer joined a channel we are on.
signal peer_connected(channel: Channel, peer: Peer)

## A peer left a channel we are on.
signal peer_disconnected(channel: Channel, peer: Peer)

## A peer in one of our channels changed their name.
signal peer_name_changed(channel: Channel, peer: Peer, old_name: String)

## Emitted for non-fatal protocol errors (malformed messages, etc.).
signal error_received(message: String)

# ---------------------------------------------------------------------------
# Inner classes
# ---------------------------------------------------------------------------

class Peer:
	var id: int
	var name: String
	var is_channel_master: bool

	func _init(p_id: int, p_name: String, p_master: bool) -> void:
		id = p_id
		name = p_name
		is_channel_master = p_master

class Channel:
	var id: int
	var name: String
	var is_channel_master: bool
	var peers: Array[Peer] = []

	func _init(p_id: int, p_name: String, p_master: bool) -> void:
		id = p_id
		name = p_name
		is_channel_master = p_master

	func find_peer(peer_id: int) -> Peer:
		for p in peers:
			if p.id == peer_id:
				return p
		return null

# ---------------------------------------------------------------------------
# Public properties
# ---------------------------------------------------------------------------

## When true the connected signal fires immediately after the TCP handshake,
## without waiting for the UDP echo. Use this when UDP is blocked by a firewall.
var tcp_only_mode: bool = false

## Read-only: our peer ID assigned by the server (0xFFFF = not connected).
var client_id: int = 0xFFFF

## Read-only: our current name as confirmed by the server.
var client_name: String = ""

## Read-only: the welcome message sent by the server on connect.
var welcome_message: String = ""

## Read-only: channels we are currently joined to.
var channels: Array[Channel] = []

## Read-only: true once the full handshake is complete.
var is_connected_to_server: bool = false

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _tcp: StreamPeerTCP = null
var _udp: PacketPeerUDP = null

var _server_host: String = ""
var _server_port: int = 6121

# Set to true once TCP STATUS_CONNECTED is observed for the first time.
var _tcp_connected_seen: bool = false
# Set to true once we've sent the initial \0 byte and connect request.
var _handshake_sent: bool = false

# UDP hello timer: send a hello every 0.5 s until UDP welcome arrives.
var _udp_hello_active: bool = false
var _udp_hello_timer: float = 0.0

# TCP frame reader state machine
var _recv_buf: PackedByteArray = PackedByteArray()
var _read_state: int = 0   # 0=want_type  1=want_size  2=want_data
var _msg_type: int = 0
var _msg_size: int = 0
var _size_buf: PackedByteArray = PackedByteArray()
var _size_bytes_left: int = 0
var _data_buf: PackedByteArray = PackedByteArray()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Connect to a bluewing-cpp-server.  Default port is 6121.
func connect_to_server(host: String, port: int = 6121) -> void:
	if _tcp != null:
		push_warning("BluewingClient: already connecting or connected; call disconnect_from_server() first.")
		return

	_server_host = host
	_server_port = port
	_reset_state()

	_tcp = StreamPeerTCP.new()
	var err := _tcp.connect_to_host(host, port)
	if err != OK:
		push_error("BluewingClient: connect_to_host failed: %s" % error_string(err))
		_tcp = null


## Cleanly close the connection.
func disconnect_from_server() -> void:
	_teardown(false)


## Set our display name.  Must be done before joining a channel.
func set_name(p_name: String) -> void:
	if not _tcp_connected_seen:
		push_warning("BluewingClient: set_name called before TCP connection established.")
		return
	var data := PackedByteArray()
	data.append(0x01)  # setname subtype
	data.append_array(p_name.to_utf8_buffer())
	_send_tcp_frame(0, 0, data)


## Request to join (or create) a channel.
## hidden: channel will not appear in channel listings.
## autoclose: channel closes when the master leaves.
func join_channel(channel_name: String, hidden: bool = false, autoclose: bool = false) -> void:
	var flags: int = 0
	if hidden:
		flags |= 1
	if autoclose:
		flags |= 2
	var data := PackedByteArray()
	data.append(0x02)  # joinchannel subtype
	data.append(flags)
	data.append_array(channel_name.to_utf8_buffer())
	_send_tcp_frame(0, 0, data)


## Leave a channel.
func leave_channel(channel: Channel) -> void:
	var data := PackedByteArray()
	data.append(0x03)  # leavechannel subtype
	data.append(channel.id & 0xFF)
	data.append((channel.id >> 8) & 0xFF)
	_send_tcp_frame(0, 0, data)


## Request a list of public channels from the server.
func request_channel_list() -> void:
	var data := PackedByteArray()
	data.append(0x04)
	_send_tcp_frame(0, 0, data)


## Send a reliable (TCP) binary message to the server.
func send_server(subchannel: int, data: PackedByteArray, variant: int = 0) -> void:
	var msg := PackedByteArray()
	msg.append(subchannel & 0xFF)
	msg.append_array(data)
	_send_tcp_frame(1, variant, msg)


## Send a fast (UDP) binary message to the server.
func blast_server(subchannel: int, data: PackedByteArray, variant: int = 0) -> void:
	if _udp == null or not is_connected_to_server:
		return
	var msg := PackedByteArray()
	msg.append(subchannel & 0xFF)
	msg.append_array(data)
	_send_udp_frame(1, variant, msg)


## Broadcast a reliable (TCP) binary message to all peers in a channel.
func send_channel(channel: Channel, subchannel: int, data: PackedByteArray, variant: int = 0) -> void:
	var msg := PackedByteArray()
	msg.append(subchannel & 0xFF)
	msg.append(channel.id & 0xFF)
	msg.append((channel.id >> 8) & 0xFF)
	msg.append_array(data)
	_send_tcp_frame(2, variant, msg)


## Broadcast a fast (UDP) binary message to all peers in a channel.
func blast_channel(channel: Channel, subchannel: int, data: PackedByteArray, variant: int = 0) -> void:
	if _udp == null or not is_connected_to_server:
		return
	var msg := PackedByteArray()
	msg.append(subchannel & 0xFF)
	msg.append(channel.id & 0xFF)
	msg.append((channel.id >> 8) & 0xFF)
	msg.append_array(data)
	_send_udp_frame(2, variant, msg)


## Send a reliable (TCP) binary message directly to one peer.
func send_peer(channel: Channel, peer: Peer, subchannel: int, data: PackedByteArray, variant: int = 0) -> void:
	var msg := PackedByteArray()
	msg.append(subchannel & 0xFF)
	msg.append(channel.id & 0xFF)
	msg.append((channel.id >> 8) & 0xFF)
	msg.append(peer.id & 0xFF)
	msg.append((peer.id >> 8) & 0xFF)
	msg.append_array(data)
	_send_tcp_frame(3, variant, msg)


## Send a fast (UDP) binary message directly to one peer.
func blast_peer(channel: Channel, peer: Peer, subchannel: int, data: PackedByteArray, variant: int = 0) -> void:
	if _udp == null or not is_connected_to_server:
		return
	var msg := PackedByteArray()
	msg.append(subchannel & 0xFF)
	msg.append(channel.id & 0xFF)
	msg.append((channel.id >> 8) & 0xFF)
	msg.append(peer.id & 0xFF)
	msg.append((peer.id >> 8) & 0xFF)
	msg.append_array(data)
	_send_udp_frame(3, variant, msg)


## Look up a joined channel by its server-assigned ID.
func find_channel(channel_id: int) -> Channel:
	for c in channels:
		if c.id == channel_id:
			return c
	return null

# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	_poll_tcp(delta)
	_poll_udp()
	_tick_udp_hello(delta)

# ---------------------------------------------------------------------------
# TCP polling
# ---------------------------------------------------------------------------

func _poll_tcp(delta: float) -> void:
	if _tcp == null:
		return

	_tcp.poll()
	var status := _tcp.get_status()

	if status == StreamPeerTCP.STATUS_CONNECTED:
		if not _tcp_connected_seen:
			_tcp_connected_seen = true
			_on_tcp_connected()
		_read_tcp_data()
	elif status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
		if _tcp_connected_seen or status == StreamPeerTCP.STATUS_ERROR:
			_teardown(true)


func _on_tcp_connected() -> void:
	# Send the mandatory opening null byte then the Connect Request frame.
	_tcp.put_data(PackedByteArray([0x00]))
	var data := PackedByteArray()
	data.append(0x00)  # connect subtype
	data.append_array("revision 3".to_utf8_buffer())
	_send_tcp_frame(0, 0, data)
	_handshake_sent = true

	# Start UDP socket (needed for the UDP welcome handshake).
	_udp = PacketPeerUDP.new()
	_udp.connect_to_host(_server_host, _server_port)


func _read_tcp_data() -> void:
	var available := _tcp.get_available_bytes()
	if available <= 0:
		return
	var result := _tcp.get_data(available)
	if result[0] == OK and (result[1] as PackedByteArray).size() > 0:
		_recv_buf.append_array(result[1])
		_parse_frames()


# ---------------------------------------------------------------------------
# Frame parser (state machine)
# ---------------------------------------------------------------------------

func _parse_frames() -> void:
	var i := 0
	var n := _recv_buf.size()

	while i < n:
		if _read_state == 0:
			# Consume the type/variant byte.
			_msg_type = _recv_buf[i]
			i += 1
			_read_state = 1
			_size_bytes_left = 0
			_size_buf.clear()

		elif _read_state == 1:
			# Consume size byte(s).
			var b: int = _recv_buf[i]
			i += 1

			if _size_bytes_left == 0:
				if b < 254:
					_msg_size = b
					_data_buf.clear()
					_read_state = 2
				elif b == 254:
					_size_bytes_left = 2
				else:  # 255
					_size_bytes_left = 4
			else:
				_size_buf.append(b)
				_size_bytes_left -= 1
				if _size_bytes_left == 0:
					if _size_buf.size() == 2:
						_msg_size = _size_buf[0] | (_size_buf[1] << 8)
					else:
						_msg_size = (_size_buf[0]
							| (_size_buf[1] << 8)
							| (_size_buf[2] << 16)
							| (_size_buf[3] << 24))
					_data_buf.clear()
					_read_state = 2

		else:  # _read_state == 2
			# Copy up to _msg_size bytes into _data_buf.
			var needed := _msg_size - _data_buf.size()
			var avail  := n - i
			var copy   := mini(needed, avail)
			if copy > 0:
				_data_buf.append_array(_recv_buf.slice(i, i + copy))
				i += copy

			if _data_buf.size() == _msg_size:
				_handle_message(_msg_type, _data_buf.duplicate(), false)
				_read_state = 0
				_data_buf.clear()

	# Keep only unprocessed bytes.
	if i >= n:
		_recv_buf.clear()
	elif i > 0:
		_recv_buf = _recv_buf.slice(i)

# ---------------------------------------------------------------------------
# UDP polling
# ---------------------------------------------------------------------------

func _poll_udp() -> void:
	if _udp == null:
		return
	while _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		if packet.size() < 1:
			continue
		# UDP wire format (server → client): [type_byte][data...]
		_handle_message(packet[0], packet.slice(1), true)


func _tick_udp_hello(delta: float) -> void:
	if not _udp_hello_active or _udp == null:
		return
	_udp_hello_timer -= delta
	if _udp_hello_timer <= 0.0:
		_send_udp_hello()
		_udp_hello_timer = 0.5


func _send_udp_hello() -> void:
	# UDP Hello frame: [type|variant][client_id lo][client_id hi]
	var frame := PackedByteArray()
	frame.append((7 << 4) | 0)       # type 7, variant 0
	frame.append(client_id & 0xFF)
	frame.append((client_id >> 8) & 0xFF)
	_udp.put_packet(frame)

# ---------------------------------------------------------------------------
# Message dispatcher
# ---------------------------------------------------------------------------

func _handle_message(type_byte: int, data: PackedByteArray, blasted: bool) -> void:
	var msg_type: int = (type_byte >> 4)
	var variant:  int = (type_byte & 0x0F)

	match msg_type:
		0:
			_handle_response(data)
		1:
			_handle_binary_server_msg(data, variant, blasted)
		2:
			_handle_binary_channel_msg(data, variant, blasted)
		3:
			_handle_binary_peer_msg(data, variant, blasted)
		4:
			_handle_binary_server_channel_msg(data, variant, blasted)
		9:
			_handle_peer_msg(data)
		10:
			# UDP Welcome — only valid when received via UDP.
			if blasted:
				_udp_hello_active = false
				is_connected_to_server = true
				connected.emit()
		11:
			# Ping request from server — respond with empty type-9 frame.
			if blasted:
				var pong := PackedByteArray()
				pong.append((9 << 4) | 0)
				pong.append(client_id & 0xFF)
				pong.append((client_id >> 8) & 0xFF)
				if _udp != null:
					_udp.put_packet(pong)
			else:
				_send_tcp_frame(9, 0, PackedByteArray())
		12:
			# Server asks client to identify itself.
			var impl := "Bluewing GDScript b1"
			_send_tcp_frame(10, 0, impl.to_utf8_buffer())


# ---------------------------------------------------------------------------
# Response handlers (type 0 from server)
# ---------------------------------------------------------------------------

func _handle_response(data: PackedByteArray) -> void:
	if data.size() < 2:
		error_received.emit("Truncated response message.")
		return

	var response_type: int = data[0]
	var success:       bool = data[1] != 0
	var pos:           int  = 2

	match response_type:
		0:
			_handle_connect_response(success, data, pos)
		1:
			_handle_setname_response(success, data, pos)
		2:
			_handle_joinchannel_response(success, data, pos)
		3:
			_handle_leavechannel_response(success, data, pos)
		4:
			_handle_channellist_response(success, data, pos)
		_:
			error_received.emit("Unknown response type: %d" % response_type)


func _handle_connect_response(success: bool, data: PackedByteArray, pos: int) -> void:
	if success:
		if data.size() < pos + 2:
			error_received.emit("Truncated connect success response.")
			return
		client_id = data[pos] | (data[pos + 1] << 8)
		pos += 2
		welcome_message = data.slice(pos).get_string_from_utf8()

		if tcp_only_mode:
			is_connected_to_server = true
			connected.emit()
		else:
			# Begin sending UDP Hello messages until UDP Welcome arrives.
			_udp_hello_active = true
			_udp_hello_timer = 0.0
	else:
		var reason := data.slice(pos).get_string_from_utf8()
		connection_denied.emit(reason)


func _handle_setname_response(success: bool, data: PackedByteArray, pos: int) -> void:
	if data.size() < pos + 1:
		error_received.emit("Truncated setname response.")
		return
	var name_len: int = data[pos]; pos += 1
	if data.size() < pos + name_len:
		error_received.emit("Truncated name in setname response.")
		return
	var name_str := data.slice(pos, pos + name_len).get_string_from_utf8()
	pos += name_len

	if success:
		var old_name := client_name
		client_name = name_str
		if old_name.is_empty():
			name_set.emit()
		else:
			name_changed.emit(old_name)
	else:
		var reason := data.slice(pos).get_string_from_utf8()
		name_denied.emit(name_str, reason)


func _handle_joinchannel_response(success: bool, data: PackedByteArray, pos: int) -> void:
	var flags: int = 0
	if success:
		if data.size() < pos + 1:
			error_received.emit("Truncated joinchannel success response (flags).")
			return
		flags = data[pos]; pos += 1

	if data.size() < pos + 1:
		error_received.emit("Truncated joinchannel response (name length).")
		return
	var ch_name_len: int = data[pos]; pos += 1
	if data.size() < pos + ch_name_len:
		error_received.emit("Truncated joinchannel response (name).")
		return
	var ch_name := data.slice(pos, pos + ch_name_len).get_string_from_utf8()
	pos += ch_name_len

	if success:
		if data.size() < pos + 2:
			error_received.emit("Truncated joinchannel response (channel ID).")
			return
		var ch_id: int = data[pos] | (data[pos + 1] << 8); pos += 2
		var ch := Channel.new(ch_id, ch_name, (flags & 1) != 0)

		# Read the list of peers already in the channel.
		while pos + 4 <= data.size():
			var peer_id: int   = data[pos] | (data[pos + 1] << 8); pos += 2
			var peer_flags: int = data[pos]; pos += 1
			var peer_name_len: int = data[pos]; pos += 1
			if data.size() < pos + peer_name_len:
				break
			var peer_name := data.slice(pos, pos + peer_name_len).get_string_from_utf8()
			pos += peer_name_len
			ch.peers.append(Peer.new(peer_id, peer_name, (peer_flags & 1) != 0))

		channels.append(ch)
		channel_joined.emit(ch)
	else:
		var reason := data.slice(pos).get_string_from_utf8()
		channel_join_denied.emit(ch_name, reason)


func _handle_leavechannel_response(success: bool, data: PackedByteArray, pos: int) -> void:
	if data.size() < pos + 2:
		error_received.emit("Truncated leavechannel response.")
		return
	var ch_id: int = data[pos] | (data[pos + 1] << 8); pos += 2
	var ch := find_channel(ch_id)

	if success:
		if ch != null:
			channel_left.emit(ch)
			channels.erase(ch)
	else:
		var reason := data.slice(pos).get_string_from_utf8()
		if ch != null:
			channel_leave_denied.emit(ch, reason)
		else:
			error_received.emit("Leave channel denied for unknown channel %d: %s" % [ch_id, reason])


func _handle_channellist_response(success: bool, data: PackedByteArray, pos: int) -> void:
	if not success:
		var reason := data.slice(pos).get_string_from_utf8()
		error_received.emit("Channel list denied: " + reason)
		return

	var listing: Array = []
	while pos + 3 <= data.size():
		var peer_count: int = data[pos] | (data[pos + 1] << 8); pos += 2
		var name_len: int   = data[pos]; pos += 1
		if data.size() < pos + name_len:
			break
		var ch_name := data.slice(pos, pos + name_len).get_string_from_utf8()
		pos += name_len
		listing.append({"name": ch_name, "peer_count": peer_count})

	channel_list_received.emit(listing)

# ---------------------------------------------------------------------------
# Message type handlers
# ---------------------------------------------------------------------------

func _handle_binary_server_msg(data: PackedByteArray, variant: int, blasted: bool) -> void:
	if data.size() < 1:
		return
	server_message.emit(data[0], data.slice(1), variant, blasted)


func _handle_binary_channel_msg(data: PackedByteArray, variant: int, blasted: bool) -> void:
	if data.size() < 5:
		return
	var subchannel: int = data[0]
	var ch_id:   int = data[1] | (data[2] << 8)
	var peer_id: int = data[3] | (data[4] << 8)
	var ch := find_channel(ch_id)
	if ch == null:
		return
	var peer := ch.find_peer(peer_id)
	if peer == null:
		return
	channel_message.emit(ch, peer, subchannel, data.slice(5), variant, blasted)


func _handle_binary_peer_msg(data: PackedByteArray, variant: int, blasted: bool) -> void:
	if data.size() < 5:
		return
	var subchannel: int = data[0]
	var ch_id:   int = data[1] | (data[2] << 8)
	var peer_id: int = data[3] | (data[4] << 8)
	var ch := find_channel(ch_id)
	if ch == null:
		return
	var peer := ch.find_peer(peer_id)
	if peer == null:
		return
	peer_message.emit(ch, peer, subchannel, data.slice(5), variant, blasted)


func _handle_binary_server_channel_msg(data: PackedByteArray, variant: int, blasted: bool) -> void:
	if data.size() < 3:
		return
	var subchannel: int = data[0]
	var ch_id: int = data[1] | (data[2] << 8)
	var ch := find_channel(ch_id)
	if ch == null:
		return
	server_channel_message.emit(ch, subchannel, data.slice(3), variant, blasted)


func _handle_peer_msg(data: PackedByteArray) -> void:
	# Minimum: channel_id (2) + peer_id (2).
	if data.size() < 4:
		return
	var ch_id:   int = data[0] | (data[1] << 8)
	var peer_id: int = data[2] | (data[3] << 8)
	var ch := find_channel(ch_id)
	if ch == null:
		error_received.emit("Peer message for unknown channel ID %d." % ch_id)
		return

	if data.size() <= 4:
		# No flags/name means this peer has left.
		var peer := ch.find_peer(peer_id)
		if peer != null:
			peer_disconnected.emit(ch, peer)
			ch.peers.erase(peer)
		return

	# flags (1 byte) + name (rest of frame, not null-terminated).
	var flags:     int    = data[4]
	var peer_name: String = data.slice(5).get_string_from_utf8()
	var peer := ch.find_peer(peer_id)

	if peer == null:
		# New peer joined.
		peer = Peer.new(peer_id, peer_name, (flags & 1) != 0)
		ch.peers.append(peer)
		peer_connected.emit(ch, peer)
	else:
		# Existing peer: may have changed name or master status.
		peer.is_channel_master = (flags & 1) != 0
		if peer.name != peer_name:
			var old_name := peer.name
			peer.name = peer_name
			peer_name_changed.emit(ch, peer, old_name)

# ---------------------------------------------------------------------------
# Frame builders / senders
# ---------------------------------------------------------------------------

func _send_tcp_frame(type: int, variant: int, data: PackedByteArray) -> void:
	if _tcp == null:
		return
	var frame := _build_tcp_frame(type, variant, data)
	_tcp.put_data(frame)


func _build_tcp_frame(type: int, variant: int, data: PackedByteArray) -> PackedByteArray:
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
	return frame


## Send a UDP frame (server → client, no size prefix; just type byte + client_id + data).
func _send_udp_frame(type: int, variant: int, data: PackedByteArray) -> void:
	if _udp == null:
		return
	var frame := PackedByteArray()
	frame.append((type << 4) | (variant & 0x0F))
	frame.append(client_id & 0xFF)
	frame.append((client_id >> 8) & 0xFF)
	frame.append_array(data)
	_udp.put_packet(frame)

# ---------------------------------------------------------------------------
# Teardown / reset
# ---------------------------------------------------------------------------

func _teardown(fire_signal: bool) -> void:
	var was_active := _tcp_connected_seen
	_udp_hello_active = false

	if _udp != null:
		_udp.close()
		_udp = null

	if _tcp != null:
		_tcp.disconnect_from_host()
		_tcp = null

	_reset_state()

	if fire_signal and was_active:
		disconnected.emit()


func _reset_state() -> void:
	client_id = 0xFFFF
	client_name = ""
	welcome_message = ""
	channels.clear()
	is_connected_to_server = false
	_tcp_connected_seen = false
	_handshake_sent = false
	_udp_hello_active = false
	_udp_hello_timer = 0.0
	_recv_buf.clear()
	_read_state = 0
	_msg_type = 0
	_msg_size = 0
	_size_buf.clear()
	_size_bytes_left = 0
	_data_buf.clear()
