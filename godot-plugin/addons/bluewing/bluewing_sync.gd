## BluewingSync
## Attach this as a child of any node you want to automatically synchronise
## over the network via a BluewingNetworkManager.
##
## Scene structure example:
##   CharacterBody3D           ← the node whose properties will be synced
##   └── BluewingSync          ← this component (child)
##
## Declare the parent node's property paths in sync_properties, e.g.:
##   ["position", "rotation", "health", "velocity"]
##
## BluewingNetworkManager finds this node automatically when the parent is
## registered (via spawn_node or register_existing).  You do not need to
## call any setup methods yourself.

class_name BluewingSync
extends Node

# ---------------------------------------------------------------------------
# Exported configuration
# ---------------------------------------------------------------------------

## Property paths on the *parent* node that will be synchronised.
## Examples: ["position", "rotation", "velocity", "health"]
@export var sync_properties: Array[String] = []

## Seconds between state transmissions when this client is the owner.
## 0.05 = 20 Hz, 0.1 = 10 Hz.
@export_range(0.01, 2.0, 0.01, "suffix:s") var sync_interval: float = 0.05

## Use reliable TCP for state updates instead of UDP.
## UDP is lower latency; TCP guarantees delivery.
@export var reliable: bool = false

## Smoothly interpolate incoming state on non-owned copies of this node.
## Best for continuous values such as position and rotation.
@export var interpolate: bool = true

## How far behind real-time the interpolation renderer sits (seconds).
## Larger values are smoother but more delayed.
@export_range(0.0, 1.0, 0.01, "suffix:s") var interp_delay: float = 0.1

# ---------------------------------------------------------------------------
# Read-only runtime state
# ---------------------------------------------------------------------------

## Network ID assigned by the manager.  –1 until registered.
var network_id: int = -1

## Peer ID of the current owner.  0xFFFF means "owned by the channel master".
var owner_id: int = 0xFFFF

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when ownership transfers.
signal ownership_changed(old_owner_id: int, new_owner_id: int)

## Emitted each time state is applied from the network.
signal state_received()

# ---------------------------------------------------------------------------
# Private
# ---------------------------------------------------------------------------

var _manager: BluewingNetworkManager = null
var _send_timer: float = 0.0
var _last_state: Dictionary = {}

# Interpolation buffer — list of {time: float, state: Dictionary}.
var _snapshots: Array = []
const _SNAPSHOT_LIMIT := 16

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Returns true if the local client currently owns (is authoritative for) this node.
func is_mine() -> bool:
	if _manager == null or _manager.client == null:
		return false
	if owner_id == 0xFFFF:
		return _manager.is_host
	return _manager.client.client_id == owner_id


## Immediately transmit the current state, bypassing the sync_interval timer.
func force_sync() -> void:
	if not is_mine() or _manager == null or network_id < 0:
		return
	_do_send()

# ---------------------------------------------------------------------------
# Internal API — called exclusively by BluewingNetworkManager
# ---------------------------------------------------------------------------

func _setup(manager: BluewingNetworkManager, net_id: int, p_owner_id: int) -> void:
	_manager = manager
	network_id = net_id
	owner_id = p_owner_id


func _apply_ownership(new_owner_id: int) -> void:
	var old := owner_id
	owner_id = new_owner_id
	if old != new_owner_id:
		ownership_changed.emit(old, new_owner_id)


## Capture the parent's sync_properties into a PackedByteArray.
func _capture_state() -> PackedByteArray:
	var parent := get_parent()
	if parent == null or sync_properties.is_empty():
		return PackedByteArray()
	var state: Dictionary = {}
	for prop in sync_properties:
		var v = parent.get(prop)
		if v != null:
			state[prop] = v
	return var_to_bytes(state)


## Apply received bytes to the parent node.
## immediate=true skips the interpolation buffer (used for initial full-state sync).
func _apply_state(data: PackedByteArray, immediate: bool = false) -> void:
	if data.is_empty():
		return
	var state = bytes_to_var(data)
	if typeof(state) != TYPE_DICTIONARY:
		return

	if interpolate and not immediate:
		_snapshots.append({
			"time":  Time.get_ticks_msec() / 1000.0,
			"state": state,
		})
		if _snapshots.size() > _SNAPSHOT_LIMIT:
			_snapshots.pop_front()
	else:
		_set_props(state)

	state_received.emit()

# ---------------------------------------------------------------------------
# Godot lifecycle
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _manager == null or network_id < 0:
		return

	if is_mine():
		_tick_owner(delta)
	elif interpolate and _snapshots.size() >= 2:
		_tick_interp()

# ---------------------------------------------------------------------------
# Owner-side: detect changes and send
# ---------------------------------------------------------------------------

func _tick_owner(delta: float) -> void:
	_send_timer += delta
	if _send_timer < sync_interval:
		return
	_send_timer = 0.0

	var parent := get_parent()
	if parent == null:
		return

	var current: Dictionary = {}
	for prop in sync_properties:
		var v = parent.get(prop)
		if v != null:
			current[prop] = v

	# Only transmit when something has changed.
	if current != _last_state:
		_last_state = current.duplicate(true)
		_do_send()


func _do_send() -> void:
	var data := _capture_state()
	if data.size() > 0:
		_manager._broadcast_state(network_id, data, reliable)

# ---------------------------------------------------------------------------
# Receiver-side: interpolation
# ---------------------------------------------------------------------------

func _tick_interp() -> void:
	var render_time := Time.get_ticks_msec() / 1000.0 - interp_delay

	# Find the two snapshots that straddle render_time.
	var s0: Dictionary = _snapshots[0]
	var s1: Dictionary = _snapshots[_snapshots.size() - 1]

	for i in range(_snapshots.size() - 1):
		var a: Dictionary = _snapshots[i]
		var b: Dictionary = _snapshots[i + 1]
		if (a["time"] as float) <= render_time and render_time <= (b["time"] as float):
			s0 = a
			s1 = b
			break

	var dt: float = (s1["time"] as float) - (s0["time"] as float)
	if dt < 0.0001:
		_set_props(s1["state"])
	else:
		var alpha := clampf((render_time - (s0["time"] as float)) / dt, 0.0, 1.0)
		_lerp_props(s0["state"], s1["state"], alpha)

	# Prune snapshots that are no longer needed.
	while _snapshots.size() > 2 and (_snapshots[1] as Dictionary)["time"] <= render_time:
		_snapshots.pop_front()


func _set_props(state: Dictionary) -> void:
	var parent := get_parent()
	if parent == null:
		return
	for prop in state:
		parent.set(prop, state[prop])


func _lerp_props(s0: Dictionary, s1: Dictionary, alpha: float) -> void:
	var parent := get_parent()
	if parent == null:
		return

	for prop in s1:
		var v1 = s1[prop]
		if not s0.has(prop):
			parent.set(prop, v1)
			continue
		var v0 = s0[prop]

		# Interpolate based on runtime type.
		match typeof(v1):
			TYPE_FLOAT:
				parent.set(prop, lerpf(v0, v1, alpha))
			TYPE_INT:
				parent.set(prop, roundi(lerpf(float(v0), float(v1), alpha)))
			TYPE_VECTOR2:
				parent.set(prop, (v0 as Vector2).lerp(v1, alpha))
			TYPE_VECTOR3:
				parent.set(prop, (v0 as Vector3).lerp(v1, alpha))
			TYPE_COLOR:
				parent.set(prop, (v0 as Color).lerp(v1, alpha))
			TYPE_QUATERNION:
				parent.set(prop, (v0 as Quaternion).slerp(v1, alpha))
			TYPE_TRANSFORM2D:
				parent.set(prop, (v0 as Transform2D).interpolate_with(v1, alpha))
			TYPE_TRANSFORM3D:
				parent.set(prop, (v0 as Transform3D).interpolate_with(v1, alpha))
			TYPE_BASIS:
				parent.set(prop, (v0 as Basis).slerp(v1, alpha))
			_:
				# Non-interpolatable types snap to the latest authoritative value.
				parent.set(prop, v1)
