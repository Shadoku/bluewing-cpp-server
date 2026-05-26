# Bluewing Godot Plugin

Godot 4 networking plugin built on the **Lacewing Relay Protocol** (Revision 3).  
Drop nodes into your scene tree, connect signals, call a handful of methods — the rest is handled for you.

## What's included

| File | Class | Purpose |
|---|---|---|
| `bluewing_client.gd` | `BluewingClient` | Connects to a relay server, sends/receives messages |
| `bluewing_server.gd` | `BluewingServer` | GDScript relay server, compatible with `BluewingClient` |
| `bluewing_network_manager.gd` | `BluewingNetworkManager` | Spawns/despawns nodes, syncs properties, manages ownership |
| `sync_config.gd` | `SyncConfig` | Resource that configures sync rate and interpolation per property |

---

## Installation

1. Copy `addons/bluewing/` into your project's `addons/` folder.
2. In Godot: **Project → Project Settings → Plugins → Bluewing Client → Enable**.

---

## Quick-start

### 1. Client only (connecting to an external server)

Add a `BluewingClient` node to your scene.

```gdscript
extends Node

@onready var client: BluewingClient = $BluewingClient

func _ready() -> void:
    client.connected.connect(_on_connected)
    client.channel_joined.connect(_on_channel_joined)
    client.channel_message.connect(_on_channel_message)
    client.connect_to_server("your.server.host", 6121)

func _on_connected() -> void:
    client.set_name("Alice")
    # wait for name_set signal, then:

func _on_name_set() -> void:
    client.join_channel("lobby")

func _on_channel_joined(channel: BluewingClient.Channel) -> void:
    print("Joined %s with %d peers" % [channel.name, channel.peers.size()])
    client.send_channel(channel, 0, "hello".to_utf8_buffer())

func _on_channel_message(
    channel: BluewingClient.Channel,
    peer:    BluewingClient.Peer,
    subchannel: int,
    data:    PackedByteArray,
    _variant: int,
    _blasted: bool
) -> void:
    print("%s says: %s" % [peer.name, data.get_string_from_utf8()])
```

**Reliable (TCP) vs. fast (UDP)**

```gdscript
# Guaranteed delivery, ordered — use for game events.
client.send_channel(channel, 0, data)
client.send_peer(channel, peer, 0, data)

# Low-latency UDP blast — use for frequent position updates.
client.blast_channel(channel, 0, data)
client.blast_peer(channel, peer, 0, data)
```

---

### 2. In-game host (one player acts as server)

Add both `BluewingServer` and `BluewingClient` nodes to your scene.

```gdscript
extends Node

@onready var server: BluewingServer = $BluewingServer
@onready var client: BluewingClient = $BluewingClient

func host_game() -> void:
    # Starts the server on port 6121, then connects the local client.
    server.start_as_host(client, 6121, "Welcome!")

func join_game(host_ip: String) -> void:
    client.connect_to_server(host_ip, 6121)
```

No special-casing needed: the hosting player is just another client from the server's perspective.

**Access control hooks** (optional — everything auto-approves by default):

```gdscript
func _ready() -> void:
    server.client_connected.connect(_on_client_connected)
    server.name_requested.connect(_on_name_requested)

func _on_client_connected(c: BluewingServer.RemoteClient) -> void:
    if _is_banned(c):
        server.deny_connect(c, "You are banned.")
    # If you don't call deny_connect, the connection is approved.

func _on_name_requested(c: BluewingServer.RemoteClient) -> void:
    if c._pending_name.length() < 3:
        server.deny_name(c, "Name must be at least 3 characters.")
```

---

### 3. Node synchronisation with `BluewingNetworkManager`

Add `BluewingClient` and `BluewingNetworkManager` nodes to your scene.

#### Setup

```gdscript
@onready var client:  BluewingClient       = $BluewingClient
@onready var manager: BluewingNetworkManager = $BluewingNetworkManager

func _ready() -> void:
    manager.setup(client)
    client.connected.connect(func(): client.set_name("Alice"))
    client.name_set.connect(func(): client.join_channel("game"))
    client.channel_joined.connect(manager.set_sync_channel)
    manager.node_spawned.connect(_on_node_spawned)
    client.connect_to_server("127.0.0.1", 6121)
```

#### Spawning and syncing a node (host only)

```gdscript
var player_scene := preload("res://player.tscn")

func spawn_player_for(peer_id: int) -> void:
    # Spawn on all peers; sync position and velocity.
    var node := manager.spawn_node(
        player_scene,
        get_parent(),
        peer_id,                # owner — this peer drives the node
        ["position", "velocity"]
    )
```

#### Syncing a pre-placed node (all clients must call this identically)

```gdscript
# Called on every client after the scene loads.
func setup_world() -> void:
    manager.register_existing($WorldObject, 1)   # net_id must match on all peers
    manager.sync_add($WorldObject, ["some_property"])
```

#### Receiving spawned nodes

```gdscript
func _on_node_spawned(node: Node, network_id: int, owner_id: int) -> void:
    # The node is already in the scene tree.  Add sync config if the host
    # did not pass props to spawn_node() (or to extend what the host configured).
    manager.sync_add(node, ["position", "velocity"])
```

#### Per-property sync configuration

```gdscript
var fast_cfg := SyncConfig.new()
fast_cfg.interval   = 0.05    # 20 Hz
fast_cfg.reliable   = false   # UDP

var slow_cfg := SyncConfig.new()
slow_cfg.interval   = 0.5     # 2 Hz
slow_cfg.reliable   = true    # TCP
slow_cfg.interpolate = false

manager.sync_add(player, {
    "position": fast_cfg,   # blasted 20x/s, interpolated
    "health":   slow_cfg,   # reliable, snaps to latest value
    "name":     null,       # inherits node_cfg (or defaults if none)
})
```

Default `SyncConfig` values:

| Property | Default | Meaning |
|---|---|---|
| `interval` | `0.05` s | Send rate (20 Hz) |
| `reliable` | `false` | UDP blast |
| `interpolate` | `true` | Smooth lerp on remote copies |
| `interp_delay` | `0.1` s | Interpolation buffer depth |

#### Ownership

```gdscript
# Only the owner sends state; all others receive and apply it.
manager.sync_is_mine(node)           # → bool
manager.sync_get_owner(node)         # → peer_id (0xFFFF = host-owned)
manager.sync_set_owner(node, peer_id) # host only

# Or via the low-level method:
manager.set_node_owner(node, peer_id)
```

#### Requesting a spawn from a non-host client

```gdscript
# The host will instantiate the scene and assign ownership to this peer.
manager.request_spawn(preload("res://player.tscn"))
```

---

## Signal reference

### `BluewingClient`

| Signal | When |
|---|---|
| `connected()` | Full handshake complete (TCP + UDP) |
| `connection_denied(reason)` | Server rejected the connection |
| `disconnected()` | TCP socket closed |
| `name_set()` | First name confirmed by server |
| `name_changed(old_name)` | Name updated |
| `name_denied(attempted, reason)` | Server rejected the name |
| `channel_joined(channel)` | Successfully joined a channel |
| `channel_join_denied(name, reason)` | Server rejected the join |
| `channel_left(channel)` | Left a channel |
| `peer_connected(channel, peer)` | New peer joined one of our channels |
| `peer_disconnected(channel, peer)` | Peer left one of our channels |
| `peer_name_changed(channel, peer, old)` | Peer renamed |
| `server_message(sub, data, variant, blasted)` | Message from the server |
| `channel_message(ch, peer, sub, data, variant, blasted)` | Peer broadcast |
| `peer_message(ch, peer, sub, data, variant, blasted)` | Direct peer message |

### `BluewingServer`

| Signal | When / hook pattern |
|---|---|
| `client_connected(client)` | New TCP connection. Call `deny_connect(client, reason)` to reject. |
| `client_disconnected(client)` | Informational; no approve/deny. |
| `name_requested(client)` | Name is in `client._pending_name`. Call `deny_name(client, reason)` to reject. |
| `channel_join_requested(client, name, hidden, autoclose)` | Call `deny_join(client, name, reason)` to reject. |
| `channel_left(client, channel)` | Informational. |
| `message_server(client, sub, data, variant, blasted)` | Client sent a message to the server. |
| `message_channel(channel, sender, sub, data, variant, blasted)` | Relayed channel broadcast. |
| `message_peer(channel, sender, target, sub, data, variant, blasted)` | Relayed peer message. |

### `BluewingNetworkManager`

| Signal | When |
|---|---|
| `node_spawned(node, network_id, owner_id)` | Remote SPAWN applied locally |
| `node_despawned(network_id)` | Remote DESPAWN applied locally |
| `ownership_changed(node, old_owner, new_owner)` | Ownership transferred |
| `custom_received(node, data)` | Custom payload received for a node |

---

## TCP-only mode

If UDP is blocked by a firewall, set `client.tcp_only_mode = true` before calling `connect_to_server()`.  
The `connected` signal fires immediately after the TCP handshake instead of waiting for the UDP echo.  
Blasted (UDP) messages will silently no-op; use `send_*` variants instead.

---

## Subchannel convention

The manager reserves subchannel **200** for its own protocol traffic (`sync_subchannel` property).  
Use subchannels 0–199 for your application messages.
