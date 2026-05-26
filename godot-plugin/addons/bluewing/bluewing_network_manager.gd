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
##
## ── Sync usage ────────────────────────────────────────────────────────────
##   # Simple: track listed properties with default settings.
##   manager.sync_add(player_node, ["position", "velocity"])
##
##   # With custom per-node config:
##   var cfg = SyncConfig.new(); cfg.interval = 0.1; cfg.reliable = false
##   manager.sync_add(player_node, ["position"], cfg)
##
##   # With per-property overrides (Dictionary of prop → SyncConfig|null):
##   manager.sync_add(player_node, {
##       "position": null,                           # inherits node_cfg
##       "health":   SyncConfig.new(),               # custom per property
##   })

class_name BluewingNetworkManager
extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal node_spawned(node: Node, network_id: int, owner_id: int)
signal node_despawned(network_id: int)
signal ownership_changed(node: Node, old_owner_id: int, new_owner_id: int)
signal custom_received(node: Node, data: PackedByteArray)

# ---------------------------------------------------------------------------
# Inner classes
# ---------------------------------------------------------------------------

class _PropInterp extends RefCounted:
	var snapshots:    Array = []  # Array of {time: float, value: Variant}
	var interpolate:  bool  = true
	var interp_delay: float = 0.1


class _SendGroup extends RefCounted:
	var props:       Array[String] = []
	var reliable:    bool  = false
	var interval:    float = 0.05
	var timer:       float = 0.0
	var last_values: Dictionary = {}


class _SyncEntry extends RefCounted:
	var node:        Node
	var network_id:  int
	var owner_id:    int
	var scene_path:  String
	var all_props:   Array[String] = []
	var send_groups: Array         = []  # Array[_SendGroup]
	var prop_interp: Dictionary    = {}  # prop_name → _PropInterp

# ---------------------------------------------------------------------------
# Exported properties
# ---------------------------------------------------------------------------

@export var client: BluewingClient
@export_range(0, 255) var sync_subchannel: int = 200

# ---------------------------------------------------------------------------
# Read-only runtime state
# ---------------------------------------------------------------------------

var sync_channel: BluewingClient.Channel = null
var is_host:      bool = false

# ---------------------------------------------------------------------------
# Protocol byte constants
# ---------------------------------------------------------------------------

const _SPAWN     := 0x01
const _DESPAWN   := 0x02
const _STATE     := 0x03
const _OWNER     := 0x04
const _REQ_FULL  := 0x05
const _FULL      := 0x06
const _CUSTOM    := 0x07
const _REQ_SPAWN := 0x08

# ---------------------------------------------------------------------------
# Internal registry
# ---------------------------------------------------------------------------

# network_id → _SyncEntry
var _nodes:      Dictionary = {}
# node instance_id → network_id
var _id_by_node: Dictionary = {}
var _next_id:    int        = 1

# ---------------------------------------------------------------------------
# Public sync API
# ---------------------------------------------------------------------------

## Register node properties for automatic synchronisation.
## Must be called AFTER register_existing() or spawn_node().
##
## props — either:
##   Array[String]       → all props share node_cfg (or SyncConfig defaults)
##   Dictionary          → keys are prop names, values are SyncConfig|null
##                         (null inherits node_cfg or defaults)
func sync_add(node: Node, props, node_cfg: SyncConfig = null) -> void:
	var net_id := _node_to_id(node)
	if net_id < 0:
		push_warning("BluewingNetworkManager: sync_add called on unregistered node.")
		return
	var entry := _nodes.get(net_id) as _SyncEntry
	if entry == null:
		return

	var fallback := SyncConfig.new()  # default values

	# Resolve props and per-prop effective configs.
	var prop_list:  Array[String] = []
	var prop_cfgs:  Dictionary    = {}  # prop → SyncConfig

	if props is Array:
		for p in props:
			prop_list.append(p as String)
			prop_cfgs[p] = node_cfg if node_cfg != null else fallback
	elif props is Dictionary:
		for p in props:
			var pc: SyncConfig = props[p]
			prop_list.append(p as String)
			prop_cfgs[p] = pc if pc != null else (node_cfg if node_cfg != null else fallback)

	# Group props by (reliable, interval) so each group gets one send timer.
	var groups: Dictionary = {}
	for p in prop_list:
		var cfg := prop_cfgs[p] as SyncConfig
		var key  := "%s:%.5f" % [str(cfg.reliable), cfg.interval]
		if not groups.has(key):
			groups[key] = {reliable = cfg.reliable, interval = cfg.interval, props = []}
		groups[key].props.append(p)

	for key in groups:
		var g: Dictionary = groups[key]
		var sg           := _SendGroup.new()
		sg.props    = g.props as Array[String]
		sg.reliable = g.reliable
		sg.interval = g.interval
		entry.send_groups.append(sg)

	for p in prop_list:
		var cfg := prop_cfgs[p] as SyncConfig
		var pi  := _PropInterp.new()
		pi.interpolate  = cfg.interpolate
		pi.interp_delay = cfg.interp_delay
		entry.prop_interp[p] = pi

	entry.all_props = prop_list


## Remove all sync configuration for a node (keeps it registered, stops sending/receiving).
func sync_remove(node: Node) -> void:
	var net_id := _node_to_id(node)
	if net_id < 0:
		return
	var entry := _nodes.get(net_id) as _SyncEntry
	if entry == null:
		return
	entry.send_groups.clear()
	entry.prop_interp.clear()
	entry.all_props.clear()


## Returns true if the local client currently owns this node.
func sync_is_mine(node: Node) -> bool:
	var net_id := _node_to_id(node)
	if net_id < 0:
		return false
	var entry := _nodes.get(net_id) as _SyncEntry
	return entry != null and _is_mine(entry)


## Transfer ownership; short-hand for set_node_owner().  Host only.
func sync_set_owner(node: Node, peer_id: int) -> void:
	set_node_owner(node, peer_id)


## Return the current owner peer ID (–1 if not registered).
func sync_get_owner(node: Node) -> int:
	return get_owner_id(node)

# ---------------------------------------------------------------------------
# Public API (spawn / despawn / ownership)
# ---------------------------------------------------------------------------

func setup(p_client: BluewingClient) -> void:
	client = p_client
	_bind_signals()


func set_sync_channel(channel: BluewingClient.Channel) -> void:
	sync_channel = channel
	is_host = channel.is_channel_master
	if not is_host:
		_send_reliable(_make([_REQ_FULL]))


## Spawn a scene on all peers.  Only the host may call this.
##
## props / node_cfg — optional sync configuration passed directly to sync_add().
func spawn_node(
	scene:    PackedScene,
	parent:   Node        = self,
	owner_id: int         = 0xFFFF,
	props                 = null,
	node_cfg: SyncConfig  = null
) -> Node:
	if not is_host:
		push_warning("BluewingNetworkManager: only the host can call spawn_node(); use request_spawn() instead.")
		return null
	if sync_channel == null:
		push_error("BluewingNetworkManager: call set_sync_channel() before spawning.")
		return null

	var net_id := _next_id
	_next_id  += 1

	var node := scene.instantiate()
	parent.add_child(node)
	_register(node, net_id, owner_id, scene.resource_path)

	if props != null:
		sync_add(node, props, node_cfg)

	_broadcast(_make_spawn_msg(net_id, owner_id, scene.resource_path, net_id))
	return node


func request_spawn(scene: PackedScene) -> void:
	if is_host:
		spawn_node(scene, self, client.client_id)
		return
	var path_bytes := scene.resource_path.to_utf8_buffer()
	var msg        := PackedByteArray([_REQ_SPAWN, path_bytes.size() & 0xFF])
	msg.append_array(path_bytes)
	_send_reliable(msg)


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


func set_node_owner(node: Node, new_owner_id: int) -> void:
	if not is_host:
		push_warning("BluewingNetworkManager: only the host can transfer ownership.")
		return
	var net_id := _node_to_id(node)
	if net_id < 0:
		return
	_apply_ownership_change(net_id, new_owner_id)
	_send_reliable(_make_owner_msg(net_id, new_owner_id))


func register_existing(node: Node, network_id: int, owner_id: int = 0xFFFF) -> void:
	_register(node, network_id, owner_id, "")


func get_node_by_id(network_id: int) -> Node:
	var entry := _nodes.get(network_id) as _SyncEntry
	return entry.node if entry != null else null


func get_network_id(node: Node) -> int:
	return _node_to_id(node)


func get_owner_id(node: Node) -> int:
	var net_id := _node_to_id(node)
	if net_id < 0:
		return -1
	var entry := _nodes.get(net_id) as _SyncEntry
	return entry.owner_id if entry != null else -1


func send_custom(node: Node, data: PackedByteArray) -> void:
	var net_id := _node_to_id(node)
	if net_id < 0:
		return
	var msg := _make([_CUSTOM])
	_u16(msg, net_id)
	msg.append_array(data)
	_broadcast(msg)

# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	if client != null:
		_bind_signals()


func _process(delta: float) -> void:
	var to_despawn: Array[int] = []

	for net_id in _nodes:
		var entry := _nodes[net_id] as _SyncEntry
		if not is_instance_valid(entry.node):
			to_despawn.append(net_id)
			continue
		if _is_mine(entry):
			_tick_entry_send(entry, delta)
		elif not entry.prop_interp.is_empty():
			_tick_entry_interp(entry)

	for net_id in to_despawn:
		_auto_despawn(net_id)

# ---------------------------------------------------------------------------
# Per-entry tick (owner side: send state)
# ---------------------------------------------------------------------------

func _tick_entry_send(entry: _SyncEntry, delta: float) -> void:
	for sg_obj in entry.send_groups:
		var sg := sg_obj as _SendGroup
		sg.timer += delta
		if sg.timer < sg.interval:
			continue
		sg.timer = 0.0

		var current: Dictionary = {}
		for prop in sg.props:
			var v = entry.node.get(prop)
			if v != null:
				current[prop] = v

		if current == sg.last_values:
			continue
		sg.last_values = current.duplicate(true)

		var state_data := var_to_bytes(current)
		_broadcast_state(entry.network_id, state_data, sg.reliable)

# ---------------------------------------------------------------------------
# Per-entry tick (non-owner side: interpolate received state)
# ---------------------------------------------------------------------------

func _tick_entry_interp(entry: _SyncEntry) -> void:
	var render_time := Time.get_ticks_msec() / 1000.0

	for prop in entry.prop_interp:
		var pi := entry.prop_interp[prop] as _PropInterp
		if not pi.interpolate or pi.snapshots.size() < 2:
			continue

		var rt := render_time - pi.interp_delay
		var s0: Dictionary = pi.snapshots[0]
		var s1: Dictionary = pi.snapshots[pi.snapshots.size() - 1]

		for i in range(pi.snapshots.size() - 1):
			var a: Dictionary = pi.snapshots[i]
			var b: Dictionary = pi.snapshots[i + 1]
			if (a.time as float) <= rt and rt <= (b.time as float):
				s0 = a
				s1 = b
				break

		var dt: float = (s1.time as float) - (s0.time as float)
		var v = s1.value if dt < 0.0001 else _lerp_value(
			s0.value, s1.value,
			clampf((rt - (s0.time as float)) / dt, 0.0, 1.0)
		)

		if is_instance_valid(entry.node):
			entry.node.set(prop, v)

		while pi.snapshots.size() > 2 and (pi.snapshots[1] as Dictionary).time <= rt:
			pi.snapshots.pop_front()


static func _lerp_value(v0, v1, alpha: float):
	match typeof(v1):
		TYPE_FLOAT:      return lerpf(v0, v1, alpha)
		TYPE_INT:        return roundi(lerpf(float(v0), float(v1), alpha))
		TYPE_VECTOR2:    return (v0 as Vector2).lerp(v1, alpha)
		TYPE_VECTOR3:    return (v0 as Vector3).lerp(v1, alpha)
		TYPE_COLOR:      return (v0 as Color).lerp(v1, alpha)
		TYPE_QUATERNION: return (v0 as Quaternion).slerp(v1, alpha)
		TYPE_TRANSFORM2D: return (v0 as Transform2D).interpolate_with(v1, alpha)
		TYPE_TRANSFORM3D: return (v0 as Transform3D).interpolate_with(v1, alpha)
		TYPE_BASIS:      return (v0 as Basis).slerp(v1, alpha)
		_:               return v1

# ---------------------------------------------------------------------------
# Signal binding
# ---------------------------------------------------------------------------

func _bind_signals() -> void:
	if client == null:
		return
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
	if sync_channel != null and sync_channel.id != channel.id:
		return
	sync_channel = channel
	is_host      = channel.is_channel_master
	if not is_host:
		_send_reliable(_make([_REQ_FULL]))


func _on_channel_left(channel: BluewingClient.Channel) -> void:
	if sync_channel == null or sync_channel.id != channel.id:
		return
	for net_id in _nodes.keys().duplicate():
		var entry := _nodes[net_id] as _SyncEntry
		if entry.owner_id != client.client_id:
			if is_instance_valid(entry.node):
				entry.node.queue_free()
		_nodes.erase(net_id)
	_id_by_node.clear()
	sync_channel = null
	is_host      = false


func _on_peer_joined(channel: BluewingClient.Channel, peer: BluewingClient.Peer) -> void:
	if sync_channel == null or channel.id != sync_channel.id:
		return
	if is_host:
		_send_full_state_to(peer)


func _on_peer_left(channel: BluewingClient.Channel, peer: BluewingClient.Peer) -> void:
	if sync_channel == null or channel.id != sync_channel.id:
		return
	if peer.is_channel_master:
		_elect_host()
	if is_host:
		for net_id in _nodes.keys():
			var entry := _nodes[net_id] as _SyncEntry
			if entry.owner_id == peer.id:
				_apply_ownership_change(net_id, 0xFFFF)
				_send_reliable(_make_owner_msg(net_id, 0xFFFF))


func _elect_host() -> void:
	if sync_channel == null or client == null:
		return
	var min_id: int = client.client_id
	for p in sync_channel.peers:
		if (p as BluewingClient.Peer).id < min_id:
			min_id = (p as BluewingClient.Peer).id
	is_host = (min_id == client.client_id)


func _on_channel_msg(
	channel:    BluewingClient.Channel,
	_peer:      BluewingClient.Peer,
	subchannel: int,
	data:       PackedByteArray,
	_variant:   int,
	_blasted:   bool
) -> void:
	if sync_channel == null or channel.id != sync_channel.id:
		return
	if subchannel == sync_subchannel:
		_dispatch(data, _peer)


func _on_peer_msg(
	channel:    BluewingClient.Channel,
	_peer:      BluewingClient.Peer,
	subchannel: int,
	data:       PackedByteArray,
	_variant:   int,
	_blasted:   bool
) -> void:
	if sync_channel == null or channel.id != sync_channel.id:
		return
	if subchannel == sync_subchannel:
		_dispatch(data, _peer)

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
	var net_id    := _r16(data, pos); pos += 2
	var owner_id  := _r16(data, pos); pos += 2
	var path_len  := data[pos];       pos += 1
	if data.size() < pos + path_len + 2:
		return
	var scene_path := data.slice(pos, pos + path_len).get_string_from_utf8(); pos += path_len
	var state_len  := _r16(data, pos); pos += 2
	var state_data := PackedByteArray()
	if state_len > 0 and data.size() >= pos + state_len:
		state_data = data.slice(pos, pos + state_len)

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
	var entry  := _nodes.get(net_id) as _SyncEntry
	if entry == null:
		return
	var node := entry.node
	_unregister(net_id)
	if is_instance_valid(node):
		node.queue_free()
	node_despawned.emit(net_id)


func _recv_state(data: PackedByteArray) -> void:
	if data.size() < 3:
		return
	var net_id := _r16(data, 1)
	var entry  := _nodes.get(net_id) as _SyncEntry
	if entry == null:
		return
	if entry.owner_id == client.client_id:
		return
	if is_host and entry.owner_id == 0xFFFF:
		return
	_apply_state_to(net_id, data.slice(3))


func _recv_owner(data: PackedByteArray) -> void:
	if data.size() < 5:
		return
	_apply_ownership_change(_r16(data, 1), _r16(data, 3))


func _recv_full(data: PackedByteArray) -> void:
	var pos := 1
	while pos + 5 <= data.size():
		var net_id    := _r16(data, pos); pos += 2
		var owner_id  := _r16(data, pos); pos += 2
		var path_len  := data[pos];       pos += 1
		if data.size() < pos + path_len + 2:
			break
		var scene_path := data.slice(pos, pos + path_len).get_string_from_utf8(); pos += path_len
		var state_len  := _r16(data, pos); pos += 2
		if data.size() < pos + state_len:
			break
		var state_data := data.slice(pos, pos + state_len); pos += state_len

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
	var entry  := _nodes.get(net_id) as _SyncEntry
	if entry != null:
		custom_received.emit(entry.node, data.slice(3))


func _recv_req_spawn(data: PackedByteArray, from: BluewingClient.Peer) -> void:
	if data.size() < 2:
		return
	var path_len := data[1]
	if data.size() < 2 + path_len:
		return
	var scene_path := data.slice(2, 2 + path_len).get_string_from_utf8()
	var scene      := load(scene_path) as PackedScene
	if scene == null:
		push_error("BluewingNetworkManager: cannot load requested scene '%s'" % scene_path)
		return
	spawn_node(scene, self, from.id)

# ---------------------------------------------------------------------------
# Senders
# ---------------------------------------------------------------------------

func _broadcast(msg: PackedByteArray) -> void:
	if sync_channel == null or client == null:
		return
	client.send_channel(sync_channel, sync_subchannel, msg)


func _send_reliable(msg: PackedByteArray) -> void:
	if sync_channel == null or client == null:
		return
	client.send_channel(sync_channel, sync_subchannel, msg)


func _send_to_peer(peer: BluewingClient.Peer, msg: PackedByteArray) -> void:
	if sync_channel == null or client == null:
		return
	client.send_peer(sync_channel, peer, sync_subchannel, msg)


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


func _send_full_state_to(peer: BluewingClient.Peer) -> void:
	var msg := _make([_FULL])
	for net_id in _nodes:
		var entry      := _nodes[net_id] as _SyncEntry
		var path_bytes := entry.scene_path.to_utf8_buffer()
		var state_data := _capture_entry_state(entry)
		_u16(msg, net_id)
		_u16(msg, entry.owner_id)
		msg.append(path_bytes.size() & 0xFF)
		msg.append_array(path_bytes)
		_u16(msg, state_data.size())
		msg.append_array(state_data)
	_send_to_peer(peer, msg)

# ---------------------------------------------------------------------------
# Message builders
# ---------------------------------------------------------------------------

func _make_spawn_msg(net_id: int, owner_id: int, scene_path: String, _lookup_id: int) -> PackedByteArray:
	var entry      := _nodes.get(net_id) as _SyncEntry
	var state_data := _capture_entry_state(entry) if entry != null else PackedByteArray()
	var path_bytes := scene_path.to_utf8_buffer()
	var msg        := _make([_SPAWN])
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
	var entry         := _SyncEntry.new()
	entry.node        = node
	entry.network_id  = net_id
	entry.owner_id    = owner_id
	entry.scene_path  = scene_path
	_nodes[net_id]                        = entry
	_id_by_node[node.get_instance_id()]   = net_id


func _unregister(net_id: int) -> void:
	var entry := _nodes.get(net_id) as _SyncEntry
	if entry == null:
		return
	if is_instance_valid(entry.node):
		_id_by_node.erase(entry.node.get_instance_id())
	_nodes.erase(net_id)


func _node_to_id(node: Node) -> int:
	return _id_by_node.get(node.get_instance_id(), -1)


func _is_mine(entry: _SyncEntry) -> bool:
	if entry.owner_id == 0xFFFF:
		return is_host
	return client != null and client.client_id == entry.owner_id


func _capture_entry_state(entry: _SyncEntry) -> PackedByteArray:
	if entry == null or entry.all_props.is_empty() or not is_instance_valid(entry.node):
		return PackedByteArray()
	var state: Dictionary = {}
	for prop in entry.all_props:
		var v = entry.node.get(prop)
		if v != null:
			state[prop] = v
	return var_to_bytes(state) if not state.is_empty() else PackedByteArray()


func _apply_state_to(net_id: int, state_data: PackedByteArray, immediate: bool = false) -> void:
	var entry := _nodes.get(net_id) as _SyncEntry
	if entry == null or state_data.is_empty():
		return
	var state = bytes_to_var(state_data)
	if typeof(state) != TYPE_DICTIONARY:
		return

	var now := Time.get_ticks_msec() / 1000.0
	for prop in state:
		var v = state[prop]
		var pi := entry.prop_interp.get(prop) as _PropInterp
		if pi != null and pi.interpolate and not immediate:
			pi.snapshots.append({time = now, value = v})
			if pi.snapshots.size() > 16:
				pi.snapshots.pop_front()
		else:
			if is_instance_valid(entry.node):
				entry.node.set(prop, v)


func _apply_ownership_change(net_id: int, new_owner_id: int) -> void:
	var entry := _nodes.get(net_id) as _SyncEntry
	if entry == null:
		return
	var old_owner := entry.owner_id
	entry.owner_id = new_owner_id
	ownership_changed.emit(entry.node, old_owner, new_owner_id)


func _auto_despawn(net_id: int) -> void:
	if is_host:
		var msg := _make([_DESPAWN])
		_u16(msg, net_id)
		_broadcast(msg)
	_unregister(net_id)
	node_despawned.emit(net_id)

# ---------------------------------------------------------------------------
# Byte utilities
# ---------------------------------------------------------------------------

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
