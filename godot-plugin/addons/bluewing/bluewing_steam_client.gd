## BluewingSteamClient
## Drop-in replacement for BluewingClient using Steam Networking Sockets.
## Provides NAT traversal through Valve's relay network — no port forwarding needed.
## Requires GodotSteam 4.x — https://godotsteam.com
##
## Usage difference from BluewingClient:
##   # Instead of:  client.connect_to_server("host", 6121)
##   # Use:         client.connect_to_steam(server_steam_id)
##   # where server_steam_id is the int64 SteamID of the machine running
##   # BluewingSteamServer, typically from BluewingSteamLobby.server_steam_id.
##
## All signals and protocol methods (set_name, join_channel, send_channel,
## blast_channel, etc.) are identical to BluewingClient.

class_name BluewingSteamClient
extends BluewingClient

## Virtual port for ISteamNetworkingSockets P2P.
## Must match BluewingSteamServer.virtual_port.
@export var virtual_port: int = 0

# ---------------------------------------------------------------------------
# Private Steam state
# ---------------------------------------------------------------------------

var _steam_connection: int = -1  # handle returned by Steam.connect_p2p

# ---------------------------------------------------------------------------
# Public API — Steam-specific
# ---------------------------------------------------------------------------

## Connect to a BluewingSteamServer using the host's int64 SteamID.
## Typically supplied by BluewingSteamLobby.server_steam_id after joining a lobby.
func connect_to_steam(server_steam_id: int) -> void:
	if _steam_connection != -1:
		push_warning("BluewingSteamClient: already connecting; call disconnect_from_server() first.")
		return
	if not _steam_ok():
		return

	_reset_state()
	# connected fires after the Lacewing connect response, not after a UDP echo.
	tcp_only_mode = true

	_steam_connection = Steam.connect_p2p(server_steam_id, virtual_port, [])  # GodotSteam

	if not Steam.network_connection_status_changed.is_connected(_on_steam_status_changed):
		Steam.network_connection_status_changed.connect(_on_steam_status_changed)


## Not applicable for Steam transport.  Use connect_to_steam() instead.
func connect_to_server(_host: String, _port: int = 6121) -> void:
	push_warning("BluewingSteamClient: use connect_to_steam(server_steam_id) for Steam transport.")

# ---------------------------------------------------------------------------
# Lifecycle — replaces base _process entirely
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	_poll_steam()

# ---------------------------------------------------------------------------
# Transport overrides
# ---------------------------------------------------------------------------

## Reliable (TCP-equivalent) send via Steam.
func _send_tcp_frame(type: int, variant: int, data: PackedByteArray) -> void:
	if _steam_connection == -1:
		return
	var frame := PackedByteArray([(type << 4) | (variant & 0x0F)])
	frame.append_array(data)
	Steam.send_message_to_connection(_steam_connection, frame, 8)  # 8 = k_nSteamNetworkingSend_Reliable


## Unreliable (UDP-equivalent) send via Steam.
## Note: no client_id prefix — server identifies the sender by connection handle.
func _send_udp_frame(type: int, variant: int, data: PackedByteArray) -> void:
	if _steam_connection == -1:
		return
	var frame := PackedByteArray([(type << 4) | (variant & 0x0F)])
	frame.append_array(data)
	Steam.send_message_to_connection(_steam_connection, frame, 0)  # 0 = unreliable


## Close the Steam connection then let the base class reset all Lacewing state.
func _teardown(fire_signal: bool) -> void:
	if _steam_connection != -1:
		Steam.close_connection(_steam_connection, 0, "", false)  # GodotSteam
		_steam_connection = -1
	super._teardown(fire_signal)

# ---------------------------------------------------------------------------
# Steam event handlers
# ---------------------------------------------------------------------------

func _on_steam_status_changed(connection: int, state_info, _old_state: int) -> void:
	if connection != _steam_connection:
		return

	# state_info may be an int or a Dictionary depending on the GodotSteam version.
	var state: int = state_info if typeof(state_info) == TYPE_INT \
		else (state_info as Dictionary).get("state", 0)

	match state:
		3:  # k_ESteamNetworkingConnectionState_Connected
			if not _tcp_connected_seen:
				_tcp_connected_seen = true
				_send_connect_request()
		4, 5:  # ClosedByPeer, ProblemDetectedLocally
			_teardown(true)


## Send the Lacewing connect request once the Steam connection is established.
func _send_connect_request() -> void:
	var data := PackedByteArray([0x00])  # connect subtype
	data.append_array("revision 3".to_utf8_buffer())
	_send_tcp_frame(0, 0, data)

# ---------------------------------------------------------------------------
# Steam receive loop
# ---------------------------------------------------------------------------

func _poll_steam() -> void:
	if _steam_connection == -1:
		return

	# Each call returns a batch of complete messages (no fragmentation).
	var messages: Array = Steam.receive_messages_on_connection(_steam_connection, 256)  # GodotSteam
	for msg in messages:
		var payload: PackedByteArray = msg.get("payload", PackedByteArray())
		if payload.is_empty():
			continue
		# Unreliable flag absent (flags & 8 == 0) means blasted.
		var blasted: bool = (msg.get("flags", 0) & 8) == 0
		_handle_message(payload[0], payload.slice(1), blasted)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _steam_ok() -> bool:
	if not Engine.has_singleton("Steam"):
		push_error("BluewingSteamClient: Steam singleton not found — is GodotSteam installed and initialised?")
		return false
	return true
