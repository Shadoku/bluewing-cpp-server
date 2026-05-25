## BluewingNetworkManager
## Add this node alongside a BluewingClient to enable automatic node
## synchronisation with host/client ownership semantics.
##
## ── Ownership model ───────────────────────────────────────────────────────
##  owner_id = 0xFFFF  → "host-owned": controlled by whoever is channel master
##  owner_id = peer_id → controlled by that specific peer
##
## Only the owner sends state updates; all other peers receive and apply them.
## The channel master (host) is the sole authority for spawning, despawning,
## and transferring ownership.  Any peer may *request* a spawn from the host.
##
## ── Host election ─────────────────────────────────────────────────────────
## The initial channel master is the host.  If the host disconnects, the
## remaining peer with the lowest peer ID is elected host automatically.
## All clients perform this calculation independently so no negotiation is
## needed.
##
## ── Typical usage ─────────────────────────────────────────────────────────
##   # After the BluewingClient is ready:
##   manager.setup(client_node)
##
##   # In your channel_joined handler:
##   manager.set_sync_channel(channel)
##
##   # Host spawns a node for every player:
##   manager.spawn_node(player_scene, get_parent(), peer.id)
##
##   # Or let each client request their own spawn:
##   manager.request_spawn(player_scene)

class_name BluewingNetworkManager
extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when a remote SPAWN message instantiates a node locally.
signal node_spawned(node: Node, network_id: int, owner_id: int)

## Emitted when a remote DESPAWN message removes a node.
signal node_despawned(network_id: int)

## Emitted when a node's ownership changes (locally or from the network).
signal ownership_changed(node: Node, old_owner_id: int, new_owner_id: int)

## Emitted when send_custom() data arrives for a registered node.
signal custom_received(node: Node, data: PackedByteArray)

# ---------------------------------------------------------------------------
# Exported properties
# ---------------------------------------------------------------------------

## The BluewingClient this manager drives.  Set in the editor or via setup().
@export var client: BluewingClient

## Subchannel reserved for sync protocol traffic.
## Must not collide with subchannels used by your application.
@export_range(0, 255) var sync_subchannel: int = 200

## When true, state broadcast messages use reliable TCP instead of UDP.
## Individual BluewingSync nodes can override this with their own `reliable` flag.
@export var reliable_state: bool = false

# ---------------------------------------------------------------------------
# Read-only runtime state
# ---------------------------------------------------------------------------

## The channel currently used for synchronisation.
var sync_channel: BluewingClient.Channel = null

## True when we are the channel master (host).
var is_host: bool = false

# ---------------------------------------------------------------------------
# Protocol byte constants
# ---------------------------------------------------------------------------

const _SPAWN     := 0x01  ## broadcast: instantiate a scene on all peers
const _DESPAWN   := 0x02  ## broadcast: destroy a node on all peers
const _STATE     := 0x03  ## broadcast/blast: property update for a node
const _OWNER     := 0x04  ## reliable broadcast: change owner of a node
const _REQ_FULL  := 0x05  ## peer→host: request full state dump
const _FULL      := 0x06  ## host→peer: complete snapshot of all nodes
const _CUSTOM    := 0x07  ## broadcast: user-defined payload for a node
const _REQ_SPAWN := 0x08  ## peer→host: request host to spawn a scene

# ---------------------------------------------------------------------------
# Internal node registry
# ---------------------------------------------------------------------------

# network_id (int) → Dictionary with keys: node, owner_id, scene_path, sync
var _nodes: Dictionary = {}

# node instance_id (int) → network_id (int)
var _id_by_node: Dictionary = {}

# Host-side counter; only the host allocates IDs.
var _next_id: int = 1

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Connect the manager to a BluewingClient.
## Call this once before the client joins any channel.
func setup(p_client: BluewingClient) -> void:
	client = p_client
	_bind_signals()


## Declare which channel to use for synchronisation.
## Call this in your channel_joined handler, or let the manager auto-adopt
## the first joined channel by not calling this at all.
func set_sync_channel(channel: BluewingClient.Channel) -> void:
	sync_channel = channel
	is_host = channel.is_channel_master
	if not is_host:
		_send_reliable(_make([_REQ_FULL]))


## Spawn a scene on all peers.  Only the host may call this.
##
## parent   — where to attach the node locally (defaults to this manager).
## owner_id — peer ID of the node's owner; 0xFFFF keeps it host-controlled.
##
## Returns the local Node instance, or null on error.
func spawn_node(
	scene: PackedScene,
	parent: Node = self,
	owner_id: int = 0xFFFF
) -> Node:
	if not is_host:
		push_warning("BluewingNetworkManager: only the host can call spawn_node(); use request_spawn() instead.")
		return null
	if sync_channel == null:
		push_error("BluewingNetworkManager: call set_sync_channel() before spawning.")
		return null

	var net_id := _next_id
	_next_id += 1

	var node := scene.instantiate()
	parent.add_child(node)
	_register(node, net_id, owner_id, scene.resource_path)

	# Tell all current peers to spawn this node.
	_broadcast(_make_spawn_msg(net_id, owner_id, scene.resource_path, node))
	return node


## Ask the host to spawn a scene and assign ownership to this client.
## The host will broadcast a SPAWN message, which arrives on every peer
## (including the caller) via the node_spawned signal.
func request_spawn(scene: PackedScene) -> void:
	if is_host:
		spawn_node(scene, self, client.client_id)
		return
	var path_bytes := scene.resource_path.to_utf8_buffer()
	var msg := PackedByteArray([_REQ_SPAWN, path_bytes.size() & 0xFF])
	msg.append_array(path_bytes)
	_send_reliable(msg)


## Remove a node from all peers.  Only the host may call this.
func despawn_node(node: Node) -> void:
	if not is_host:
		push_warning("BluewingNetworkManager: only the host can call despawn_node().")
		return
	var net_id := _node_to_id(node)
	if net_id < 0:
		push_warning("BluewingNetworkManager: node is not registered.")
		return
	_broadcast(_make([_DESPAWN, net_id & 0xFF, (net_id >> 8) & 0xFF]))
	_unregister(net_id)
	node.queue_free()


## Transfer ownership of a registered node to a different peer.
## Only the host may call this.  Pass 0xFFFF to reclaim host control.
func set_node_owner(node: Node, new_owner_id: int) -> void:
	if not is_host:
		push_warning("BluewingNetworkManager: only the host can transfer ownership.")
		return
	var net_id := _node_to_id(node)
	if net_id < 0:
		return
	_apply_ownership_change(net_id, new_owner_id)
	_send_reliable(_make_owner_msg(net_id, new_owner_id))


## Register a node that already exists in every peer's scene tree (e.g. a
## terrain singleton or a pre-placed level object).
## Must be called with the same network_id and owner_id on EVERY client.
func register_existing(node: Node, network_id: int, owner_id: int = 0xFFFF) -> void:
	_register(node, network_id, owner_id, "")


## Look up a registered node by its network ID.  Returns null if not found.
func get_node_by_id(network_id: int) -> Node:
	return (_nodes.get(network_id, {}) as Dictionary).get("node", null)


## Get the network ID for a registered node (–1 if not found).
func get_network_id(node: Node) -> int:
	return _node_to_id(node)


## Get the current owner peer ID for a registered node (–1 if not found).
func get_owner_id(node: Node) -> int:
	var net_id := _node_to_id(node)
	if net_id < 0:
		return -1
	return (_nodes.get(net_id, {}) as Dictionary).get("owner_id", -1)


## Broadcast an arbitrary payload to all peers for a specific node.
## Received as the custom_received signal on all peers (including the sender).
func send_custom(node: Node, data: PackedByteArray) -> void:
	var net_id := _node_to_id(node)
	if net_id < 0:
		return
	var msg := _make([_CUSTOM])
	_u16(msg, net_id)
	msg.append_array(data)
	_broadcast(msg)

# ---------------------------------------------------------------------------
# Internal — called by BluewingSync
# ---------------------------------------------------------------------------

func _broadcast_state(net_id: int, state_data: PackedByteArray, reliable: bool) -> void:
	if sync_channel == null or client == null:
		return
	var msg := _make([_STATE])
	_u16(msg, net_id)
	msg.append_array(state_data)
	if reliable:
		client.send_channel(sync_channel, sync_subchannel, msg)
	else:
		client.blast_channel(sync_channel, sync_subchannel, msg)

# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	if client != null:
		_bind_signals()

# ---------------------------------------------------------------------------
# Signal binding
# ---------------------------------------------------------------------------

func _bind_signals() -> void:
	if client == null:
		return
	# Idempotent: skip if already bound.
	if client.channel_joined.is_connected(_on_channel_joined):
		return
	client.channel_joined.connect(_on_channel_joined)
	client.channel_left.connect(_on_channel_left)
	client.channel_message.connect(_on_channel_msg)
	client.peer_message.connect(_on_peer_msg)
	client.peer_connected.connect(_on_peer_joined)
	client.peer_disconnected.connect(_on_peer_left)

# ---------------------------------------------------------------------------
# BluewingClient event handlers
# ---------------------------------------------------------------------------

func _on_channel_joined(channel: BluewingClient.Channel) -> void:
	# Auto-adopt the first channel joined when no channel has been set.
	if sync_channel != null and sync_channel.id != channel.id:
		return
	sync_channel = channel
	is_host = channel.is_channel_master
	if not is_host:
		_send_reliable(_make([_REQ_FULL]))


func _on_channel_left(channel: BluewingClient.Channel) -> void:
	if sync_channel == null or sync_channel.id != channel.id:
		return
	# Remove all nodes that we did not own locally.
	for net_id in _nodes.keys().duplicate():
		var entry := _nodes[net_id] as Dictionary
		if entry.get("owner_id") != client.client_id:
			var n := entry.get("node") as Node
			if n and is_instance_valid(n):
				n.queue_free()
		_nodes.erase(net_id)
	_id_by_node.clear()
	sync_channel = null
	is_host = false


func _on_peer_joined(channel: BluewingClient.Channel, peer: BluewingClient.Peer) -> void:
	if sync_channel == null or channel.id != sync_channel.id:
		return
	# Host sends the complete node snapshot directly to the new peer.
	if is_host:
		_send_full_state_to(peer)


func _on_peer_left(channel: BluewingClient.Channel, peer: BluewingClient.Peer) -> void:
	if sync_channel == null or channel.id != sync_channel.id:
		return

	# If the departing peer was the channel master, elect a new host.
	if peer.is_channel_master:
		_elect_host()

	# If we are now host, reclaim ownership of nodes the departed peer owned.
	if is_host:
		for net_id in _nodes.keys():
			if (_nodes[net_id] as Dictionary).get("owner_id") == peer.id:
				_apply_ownership_change(net_id, 0xFFFF)
				_send_reliable(_make_owner_msg(net_id, 0xFFFF))


## Deterministic host election: the client with the smallest peer ID wins.
## Every remaining peer runs the same calculation and reaches the same result.
func _elect_host() -> void:
	if sync_channel == null or client == null:
		return
	var min_id: int = client.client_id
	for p in sync_channel.peers:
		if (p as BluewingClient.Peer).id < min_id:
			min_id = (p as BluewingClient.Peer).id
	is_host = (min_id == client.client_id)


func _on_channel_msg(
	channel: BluewingClient.Channel,
	peer: BluewingClient.Peer,
	subchannel: int,
	data: PackedByteArray,
	_variant: int,
	_blasted: bool
) -> void:
	if sync_channel == null or channel.id != sync_channel.id:
		return
	if subchannel == sync_subchannel:
		_dispatch(data, peer)


func _on_peer_msg(
	channel: BluewingClient.Channel,
	peer: BluewingClient.Peer,
	subchannel: int,
	data: PackedByteArray,
	_variant: int,
	_blasted: bool
) -> void:
	if sync_channel == null or channel.id != sync_channel.id:
		return
	if subchannel == sync_subchannel:
		_dispatch(data, peer)

# ---------------------------------------------------------------------------
# Message dispatcher
# ---------------------------------------------------------------------------

func _dispatch(data: PackedByteArray, from: BluewingClient.Peer) -> void:
	if data.is_empty():
		return
	match data[0]:
		_SPAWN:     _recv_spawn(data)
		_DESPAWN:   _recv_despawn(data)
		_STATE:     _recv_state(data)
		_OWNER:     _recv_owner(data)
		_REQ_FULL:  if is_host: _send_full_state_to(from)
		_FULL:      _recv_full(data)
		_CUSTOM:    _recv_custom(data)
		_REQ_SPAWN: if is_host: _recv_req_spawn(data, from)

# ---------------------------------------------------------------------------
# Receive handlers
# ---------------------------------------------------------------------------

func _recv_spawn(data: PackedByteArray) -> void:
	var pos := 1
	if data.size() < pos + 5:
		return
	var net_id   := _r16(data, pos); pos += 2
	var owner_id := _r16(data, pos); pos += 2
	var path_len := data[pos];       pos += 1
	if data.size() < pos + path_len + 2:
		return
	var scene_path := data.slice(pos, pos + path_len).get_string_from_utf8(); pos += path_len
	var state_len  := _r16(data, pos); pos += 2
	var state_data := PackedByteArray()
	if state_len > 0 and data.size() >= pos + state_len:
		state_data = data.slice(pos, pos + state_len)

	# Already registered → just refresh state (handles re-delivery in FULL).
	if _nodes.has(net_id):
		_apply_state_to(net_id, state_data, true)
		return

	if scene_path.is_empty():
		push_warning("BluewingNetworkManager: SPAWN received with empty scene path for ID %d." % net_id)
		return

	var scene := load(scene_path) as PackedScene
	if scene == null:
		push_error("BluewingNetworkManager: cannot load scene '%s'" % scene_path)
		return

	var node := scene.instantiate()
	add_child(node)
	_register(node, net_id, owner_id, scene_path)
	_apply_state_to(net_id, state_data, true)
	node_spawned.emit(node, net_id, owner_id)


func _recv_despawn(data: PackedByteArray) -> void:
	if data.size() < 3:
		return
	var net_id := _r16(data, 1)
	var entry := _nodes.get(net_id, {}) as Dictionary
	if entry.is_empty():
		return
	var node := entry.get("node") as Node
	_unregister(net_id)
	if node and is_instance_valid(node):
		node.queue_free()
	node_despawned.emit(net_id)


func _recv_state(data: PackedByteArray) -> void:
	if data.size() < 3:
		return
	var net_id := _r16(data, 1)
	var entry := _nodes.get(net_id, {}) as Dictionary
	if entry.is_empty():
		return
	# Do not overwrite state on nodes we are authoritative for.
	var oid: int = entry.get("owner_id", 0xFFFF)
	if oid == client.client_id:
		return
	if is_host and oid == 0xFFFF:
		return
	_apply_state_to(net_id, data.slice(3))


func _recv_owner(data: PackedByteArray) -> void:
	if data.size() < 5:
		return
	_apply_ownership_change(_r16(data, 1), _r16(data, 3))


func _recv_full(data: PackedByteArray) -> void:
	# Payload is a packed sequence of spawn records; delegate each one.
	var pos := 1
	while pos + 5 <= data.size():
		var net_id   := _r16(data, pos); pos += 2
		var owner_id := _r16(data, pos); pos += 2
		var path_len := data[pos];       pos += 1
		if data.size() < pos + path_len + 2:
			break
		var scene_path := data.slice(pos, pos + path_len).get_string_from_utf8(); pos += path_len
		var state_len  := _r16(data, pos); pos += 2
		if data.size() < pos + state_len:
			break
		var state_data := data.slice(pos, pos + state_len); pos += state_len

		# Re-assemble as a SPAWN message and let _recv_spawn handle it.
		var msg := PackedByteArray([_SPAWN])
		_u16(msg, net_id)
		_u16(msg, owner_id)
		msg.append(path_len)
		msg.append_array(scene_path.to_utf8_buffer())
		_u16(msg, state_len)
		msg.append_array(state_data)
		_recv_spawn(msg)


func _recv_custom(data: PackedByteArray) -> void:
	if data.size() < 3:
		return
	var net_id := _r16(data, 1)
	var entry := _nodes.get(net_id, {}) as Dictionary
	if not entry.is_empty():
		custom_received.emit(entry.get("node"), data.slice(3))


func _recv_req_spawn(data: PackedByteArray, from: BluewingClient.Peer) -> void:
	if data.size() < 2:
		return
	var path_len := data[1]
	if data.size() < 2 + path_len:
		return
	var scene_path := data.slice(2, 2 + path_len).get_string_from_utf8()
	var scene := load(scene_path) as PackedScene
	if scene == null:
		push_error("BluewingNetworkManager: cannot load requested scene '%s'" % scene_path)
		return
	# Spawn and assign ownership to the requesting peer.
	spawn_node(scene, self, from.id)

# ---------------------------------------------------------------------------
# Senders
# ---------------------------------------------------------------------------

func _broadcast(msg: PackedByteArray) -> void:
	if sync_channel == null or client == null:
		return
	if reliable_state:
		client.send_channel(sync_channel, sync_subchannel, msg)
	else:
		client.blast_channel(sync_channel, sync_subchannel, msg)


func _send_reliable(msg: PackedByteArray) -> void:
	if sync_channel == null or client == null:
		return
	client.send_channel(sync_channel, sync_subchannel, msg)


func _send_to_peer(peer: BluewingClient.Peer, msg: PackedByteArray) -> void:
	if sync_channel == null or client == null:
		return
	client.send_peer(sync_channel, peer, sync_subchannel, msg)


func _send_full_state_to(peer: BluewingClient.Peer) -> void:
	var msg := _make([_FULL])
	for net_id in _nodes:
		var entry := _nodes[net_id] as Dictionary
		var path_bytes := (entry.get("scene_path", "") as String).to_utf8_buffer()
		var state_data := PackedByteArray()
		var sync := entry.get("sync") as BluewingSync
		if sync:
			state_data = sync._capture_state()

		_u16(msg, net_id)
		_u16(msg, entry.get("owner_id", 0xFFFF))
		msg.append(path_bytes.size() & 0xFF)
		msg.append_array(path_bytes)
		_u16(msg, state_data.size())
		msg.append_array(state_data)

	_send_to_peer(peer, msg)

# ---------------------------------------------------------------------------
# Message builders
# ---------------------------------------------------------------------------

func _make_spawn_msg(net_id: int, owner_id: int, scene_path: String, node: Node) -> PackedByteArray:
	var entry := _nodes.get(net_id, {}) as Dictionary
	var state_data := PackedByteArray()
	var sync := entry.get("sync") as BluewingSync
	if sync:
		state_data = sync._capture_state()

	var path_bytes := scene_path.to_utf8_buffer()
	var msg := _make([_SPAWN])
	_u16(msg, net_id)
	_u16(msg, owner_id)
	msg.append(path_bytes.size() & 0xFF)
	msg.append_array(path_bytes)
	_u16(msg, state_data.size())
	msg.append_array(state_data)
	return msg


func _make_owner_msg(net_id: int, new_owner_id: int) -> PackedByteArray:
	var msg := _make([_OWNER])
	_u16(msg, net_id)
	_u16(msg, new_owner_id)
	return msg

# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------

func _register(node: Node, net_id: int, owner_id: int, scene_path: String) -> void:
	# Find an attached BluewingSync component if present.
	var sync: BluewingSync = null
	for child in node.get_children():
		if child is BluewingSync:
			sync = child
			break

	_nodes[net_id] = {
		"node":       node,
		"owner_id":   owner_id,
		"scene_path": scene_path,
		"sync":       sync,
	}
	_id_by_node[node.get_instance_id()] = net_id

	if sync:
		sync._setup(self, net_id, owner_id)


func _unregister(net_id: int) -> void:
	var entry := _nodes.get(net_id, {}) as Dictionary
	if entry.is_empty():
		return
	var node := entry.get("node") as Node
	if node:
		_id_by_node.erase(node.get_instance_id())
	_nodes.erase(net_id)


func _node_to_id(node: Node) -> int:
	return _id_by_node.get(node.get_instance_id(), -1)


func _apply_state_to(net_id: int, state_data: PackedByteArray, immediate: bool = false) -> void:
	var sync := (_nodes.get(net_id, {}) as Dictionary).get("sync") as BluewingSync
	if sync:
		sync._apply_state(state_data, immediate)


func _apply_ownership_change(net_id: int, new_owner_id: int) -> void:
	var entry := _nodes.get(net_id, {}) as Dictionary
	if entry.is_empty():
		return
	var old_owner: int = entry.get("owner_id", 0xFFFF)
	entry["owner_id"] = new_owner_id
	var sync := entry.get("sync") as BluewingSync
	if sync:
		sync._apply_ownership(new_owner_id)
	ownership_changed.emit(entry.get("node"), old_owner, new_owner_id)

# ---------------------------------------------------------------------------
# Byte utilities
# ---------------------------------------------------------------------------

## Build a PackedByteArray from a literal list of byte values.
static func _make(bytes: Array) -> PackedByteArray:
	var b := PackedByteArray()
	for v in bytes:
		b.append(v & 0xFF)
	return b


static func _r16(data: PackedByteArray, pos: int) -> int:
	return data[pos] | (data[pos + 1] << 8)


static func _u16(buf: PackedByteArray, value: int) -> void:
	buf.append(value & 0xFF)
	buf.append((value >> 8) & 0xFF)
