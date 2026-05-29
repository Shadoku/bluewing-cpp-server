# Bluewing — Godot Multiplayer Plugin

Godot 4 networking built on the Lacewing Relay Protocol.  
Drop nodes into your scene, connect signals, and call a handful of methods.  
Ships with both a **raw TCP/UDP transport** and a **Steam transport** (NAT traversal via Valve's relay network, no port forwarding).

---

## Contents

1. [What's included](#whats-included)
2. [Installation](#installation)
3. [Core concepts](#core-concepts)
4. [Walkthrough A — Non-Steam game](#walkthrough-a--non-steam-game)
5. [Walkthrough B — Steam game](#walkthrough-b--steam-game)
6. [Feature recipes](#feature-recipes)
   - [Dedicated server with access control](#dedicated-server-with-access-control)
   - [Mixed sync rates and reliability](#mixed-sync-rates-and-reliability)
   - [Custom binary game events](#custom-binary-game-events)
   - [Ownership transfer](#ownership-transfer)
   - [Pre-placed world objects](#pre-placed-world-objects)
7. [Signal reference](#signal-reference)
8. [SyncConfig reference](#syncconfig-reference)
9. [Subchannel convention](#subchannel-convention)

---

## What's included

| Class | File | Purpose |
|---|---|---|
| `BluewingClient` | `bluewing_client.gd` | Connects to a relay server; sends and receives messages |
| `BluewingServer` | `bluewing_server.gd` | In-process relay server (in-game hosting or standalone) |
| `BluewingNetworkManager` | `bluewing_network_manager.gd` | Spawns/despawns nodes, syncs properties, manages ownership |
| `SyncConfig` | `sync_config.gd` | Resource — per-node or per-property sync settings |
| `BluewingSteamClient` | `bluewing_steam_client.gd` | Steam transport drop-in for `BluewingClient` |
| `BluewingSteamServer` | `bluewing_steam_server.gd` | Steam transport drop-in for `BluewingServer` |
| `BluewingSteamLobby` | `bluewing_steam_lobby.gd` | Steam lobby, "Join Game" button, rich presence |

---

## Installation

1. Copy `addons/bluewing/` into your project's `addons/` folder.
2. **Project → Project Settings → Plugins → Bluewing Client → Enable**.

For Steam transport, also install [GodotSteam 4.x](https://godotsteam.com) and initialise Steam before any Bluewing calls.

---

## Core concepts

**Channels** are named rooms on the relay server.  Peers in the same channel can exchange messages.  The first peer to join a channel becomes its **master** (host).

**Ownership** controls who sends authoritative state for a node.  
`owner_id = 0xFFFF` means host-owned; any other value is a specific peer's ID.  Only the owner calls `set`; everyone else receives and applies incoming state.

**Reliable vs. blast** — `send_*` methods use TCP (guaranteed, ordered).  `blast_*` methods use UDP (fast, may drop).  Use reliable for game events; use blast for position updates.

**BluewingNetworkManager** sits above the client and handles the sync protocol automatically.  You point it at a client, call `sync_add()` with the properties you want tracked, and it does the rest.

---

## Walkthrough A — Non-Steam game

This example builds a simple 3D game: one player can host, others join by IP address.  Each player spawns a character that moves around and can pick up a health pack.

### Scene tree

```
GameScene (Node)
├── BluewingServer          # inactive when joining; active when hosting
├── BluewingClient
├── BluewingNetworkManager
└── World (Node3D)
    ├── HealthPack (MeshInstance3D)   # pre-placed; syncs its `visible` property
    └── Players (Node3D)              # spawned player nodes land here
```

### `player.tscn`

Your player scene should be a `CharacterBody3D` (or any node) with exported properties for sync:

```gdscript
# player.gd
extends CharacterBody3D

var health: int = 100
# position and velocity are built-in CharacterBody3D properties
```

### Main menu script

```gdscript
# main_menu.gd
extends Control

@export var host_port: int = 6121

func _on_host_pressed() -> void:
    GameState.player_name = $NameField.text
    GameState.is_host     = true
    get_tree().change_scene_to_file("res://game_scene.tscn")

func _on_join_pressed() -> void:
    GameState.player_name = $NameField.text
    GameState.is_host     = false
    GameState.host_ip     = $IPField.text
    get_tree().change_scene_to_file("res://game_scene.tscn")
```

### Game scene script — full flow

```gdscript
# game_scene.gd
extends Node

const PLAYER_SCENE := preload("res://player.tscn")
const HEALTH_PACK_NET_ID := 1  # fixed network ID shared by all peers

@onready var server:  BluewingServer        = $BluewingServer
@onready var client:  BluewingClient        = $BluewingClient
@onready var manager: BluewingNetworkManager = $BluewingNetworkManager
@onready var players: Node3D               = $World/Players
@onready var health_pack: MeshInstance3D   = $World/HealthPack

# Subchannel IDs for custom messages (must not be 200 — that's reserved for sync).
const SUB_CHAT   := 0
const SUB_PICKUP := 1

func _ready() -> void:
    # Wire up the manager to our client.
    manager.setup(client)

    # When a remote peer spawns a node, we get this signal.
    manager.node_spawned.connect(_on_node_spawned)

    # When a node_id's custom payload arrives, handle it.
    manager.custom_received.connect(_on_custom_received)

    # Listen for chat and pickup events from peers.
    client.channel_message.connect(_on_channel_message)

    # Connection flow signals.
    client.connected.connect(_on_connected)
    client.name_set.connect(_on_name_set)
    client.channel_joined.connect(_on_channel_joined)
    client.peer_connected.connect(_on_peer_connected)
    client.peer_disconnected.connect(_on_peer_disconnected)
    client.disconnected.connect(_on_disconnected)

    if GameState.is_host:
        # Register the pre-placed health pack with a fixed network ID,
        # then host server and connect local client.
        server.start_as_host(client, host_port, "Welcome!")
    else:
        client.connect_to_server(GameState.host_ip, host_port)


# ── Connection flow ─────────────────────────────────────────────────────────

func _on_connected() -> void:
    client.set_name(GameState.player_name)

func _on_name_set() -> void:
    client.join_channel("game", false, true)  # autoclose when master leaves

func _on_channel_joined(channel: BluewingClient.Channel) -> void:
    manager.set_sync_channel(channel)

    # Register the pre-placed health pack on every peer with the same net ID.
    manager.register_existing(health_pack, HEALTH_PACK_NET_ID)
    manager.sync_add(health_pack, ["visible"])

    if manager.is_host:
        # Host spawns a player for itself.
        _spawn_player_for(client.client_id)
    else:
        # Non-host asks the host to spawn a player owned by this peer.
        manager.request_spawn(PLAYER_SCENE)


# ── Peer lifecycle ───────────────────────────────────────────────────────────

func _on_peer_connected(channel: BluewingClient.Channel, peer: BluewingClient.Peer) -> void:
    # Host spawns a player for each new joiner.
    if manager.is_host:
        _spawn_player_for(peer.id)

func _on_peer_disconnected(_channel: BluewingClient.Channel, peer: BluewingClient.Peer) -> void:
    # Host despawns that peer's player node.
    if manager.is_host:
        for net_id in range(1, manager._next_id):
            var node := manager.get_node_by_id(net_id)
            if node and manager.get_owner_id(node) == peer.id:
                manager.despawn_node(node)
                break

func _on_disconnected() -> void:
    get_tree().change_scene_to_file("res://main_menu.tscn")


# ── Spawning ─────────────────────────────────────────────────────────────────

func _spawn_player_for(peer_id: int) -> Node:
    # spawn_node broadcasts to all peers and returns the local instance.
    var node := manager.spawn_node(
        PLAYER_SCENE,
        players,
        peer_id,
        ["position", "velocity", "health"]   # properties to sync
    )
    node.name = "Player_%d" % peer_id
    return node

func _on_node_spawned(node: Node, _net_id: int, owner_id: int) -> void:
    # Called on non-host peers when they receive a remote SPAWN.
    node.name = "Player_%d" % owner_id
    node.get_parent().reparent(players) if node.get_parent() != players else null


# ── Custom events ────────────────────────────────────────────────────────────

func _on_channel_message(
    _ch:        BluewingClient.Channel,
    peer:       BluewingClient.Peer,
    subchannel: int,
    data:       PackedByteArray,
    _variant:   int,
    _blasted:   bool
) -> void:
    match subchannel:
        SUB_CHAT:
            $UI/Chat.add_message("%s: %s" % [peer.name, data.get_string_from_utf8()])
        SUB_PICKUP:
            # A peer collected the health pack; hide it locally.
            health_pack.visible = false

func _on_custom_received(node: Node, data: PackedByteArray) -> void:
    # Example: a shoot event attached to the shooter's node.
    if data.size() >= 1 and data[0] == 0x01:  # 0x01 = shoot
        node.play_shoot_effect()


# ── Sending events ────────────────────────────────────────────────────────────

func send_chat(text: String) -> void:
    if manager.sync_channel == null:
        return
    client.send_channel(manager.sync_channel, SUB_CHAT, text.to_utf8_buffer())

func collect_health_pack() -> void:
    if manager.sync_channel == null:
        return
    health_pack.visible = false
    # Notify peers so they hide it too.
    client.send_channel(manager.sync_channel, SUB_PICKUP, PackedByteArray())

func fire_weapon() -> void:
    # Attach the shoot event to our own player node so peers can react.
    var my_node := manager.get_node_by_id(_find_my_net_id())
    if my_node:
        manager.send_custom(my_node, PackedByteArray([0x01]))  # 0x01 = shoot

func _find_my_net_id() -> int:
    for net_id in range(1, manager._next_id):
        if manager.get_owner_id(manager.get_node_by_id(net_id)) == client.client_id:
            return net_id
    return -1
```

> **What this achieves:** the host spawns a player for each peer, movement and health are synchronised automatically, and one-off events (chat, pickup, shoot) are sent as explicit messages.

---

## Walkthrough B — Steam game

Replace the three Bluewing nodes with their Steam equivalents.  The game logic script stays **identical** — only the `_ready()` setup changes.

### Prerequisites

- [GodotSteam 4.x](https://godotsteam.com) installed and the Steam singleton initialised before this script runs.
- A Steamworks App ID configured in your project.

### Scene tree

```
GameScene (Node)
├── BluewingSteamServer
├── BluewingSteamClient
├── BluewingSteamLobby
├── BluewingNetworkManager
└── World (Node3D)
    ├── HealthPack
    └── Players
```

### Main menu script — Steam version

```gdscript
# main_menu_steam.gd
extends Control

func _ready() -> void:
    # Handle "Join Game" when the game is already running.
    $BluewingSteamLobby.join_game_requested.connect(func(id): _join_lobby(id))

    # Handle cold-start from Steam friends list (+connect_lobby argument).
    var args := OS.get_cmdline_args()
    var idx   := args.find("+connect_lobby")
    if idx != -1 and idx + 1 < args.size():
        _join_lobby(int(args[idx + 1]))

func _on_host_pressed() -> void:
    GameState.player_name = $NameField.text
    GameState.is_host     = true
    # Create lobby first; start_as_host() is called once the lobby is ready.
    $BluewingSteamLobby.lobby_created.connect(
        func(_id): get_tree().change_scene_to_file("res://game_scene_steam.tscn"),
        CONNECT_ONE_SHOT
    )
    $BluewingSteamLobby.create_lobby()

func _on_join_pressed() -> void:
    # In a real game you'd show a lobby browser.  Here we join a pasted lobby ID.
    _join_lobby(int($LobbyIDField.text))

func _join_lobby(lobby_id: int) -> void:
    GameState.player_name = $NameField.text
    GameState.is_host     = false
    $BluewingSteamLobby.lobby_joined.connect(
        func(_id, _sid): get_tree().change_scene_to_file("res://game_scene_steam.tscn"),
        CONNECT_ONE_SHOT
    )
    $BluewingSteamLobby.join_lobby(lobby_id)
```

### Game scene script — Steam version

Only `_ready()` changes from the non-Steam version.  Everything else is identical.

```gdscript
# game_scene_steam.gd  (only _ready shown — rest is identical to game_scene.gd)
extends Node

@onready var server:  BluewingSteamServer   = $BluewingSteamServer
@onready var client:  BluewingSteamClient   = $BluewingSteamClient
@onready var lobby:   BluewingSteamLobby    = $BluewingSteamLobby
@onready var manager: BluewingNetworkManager = $BluewingNetworkManager
# ... (same @onready vars as non-Steam version)

func _ready() -> void:
    manager.setup(client)
    manager.node_spawned.connect(_on_node_spawned)
    manager.custom_received.connect(_on_custom_received)
    client.channel_message.connect(_on_channel_message)
    client.connected.connect(_on_connected)
    client.name_set.connect(_on_name_set)
    client.channel_joined.connect(_on_channel_joined)
    client.peer_connected.connect(_on_peer_connected)
    client.peer_disconnected.connect(_on_peer_disconnected)
    client.disconnected.connect(_on_disconnected)

    if GameState.is_host:
        # Lobby was already created by the main menu; start the server now.
        server.start_as_host(client, "Welcome!")
    else:
        # Lobby was already joined; connect to the server using the host's SteamID.
        client.connect_to_steam(lobby.server_steam_id)

# All other methods (_on_connected, _spawn_player_for, etc.) are unchanged.
```

> **What changes:** `start_as_host` takes a `BluewingSteamClient` instead of a `BluewingClient`, and `connect_to_server(ip)` becomes `connect_to_steam(steam_id)`.  The lobby handles discovery so players never need to share IP addresses.

---

## Feature recipes

### Dedicated server with access control

Run `BluewingServer` as a standalone server process (no local client).  Use the hook signals to enforce rules.

```gdscript
# dedicated_server.gd
extends Node

@onready var server: BluewingServer = $BluewingServer

# Simple ban list keyed by connecting IP (not exposed by the Lacewing protocol,
# but you can key on peer name instead).
var banned_names := ["cheater123", "griefer99"]
var max_players  := 16

func _ready() -> void:
    server.client_connected.connect(_on_client_connected)
    server.name_requested.connect(_on_name_requested)
    server.channel_join_requested.connect(_on_channel_join_requested)
    server.message_server.connect(_on_server_message)

    var err := server.host(6121, "Dedicated server v1.0")
    if err != OK:
        push_error("Server failed to start: %s" % error_string(err))
        get_tree().quit()
    else:
        print("Server listening on port 6121")

func _on_client_connected(c: BluewingServer.RemoteClient) -> void:
    # Count approved connections; reject if full.
    var count := server._clients.filter(func(x): return (x as BluewingServer.RemoteClient)._approved).size()
    if count >= max_players:
        server.deny_connect(c, "Server is full (%d/%d)." % [count, max_players])

func _on_name_requested(c: BluewingServer.RemoteClient) -> void:
    var name := c._pending_name
    if name.length() < 2 or name.length() > 20:
        server.deny_name(c, "Name must be 2–20 characters.")
        return
    if name in banned_names:
        server.deny_name(c, "That name is not allowed.")
        return
    # No deny call = auto-approved.

func _on_channel_join_requested(
    c:         BluewingServer.RemoteClient,
    ch_name:   String,
    _hidden:   bool,
    _autoclose: bool
) -> void:
    # Only allow joining channels named "game" or "lobby".
    if ch_name not in ["game", "lobby"]:
        server.deny_join(c, ch_name, "Unknown channel.")

func _on_server_message(
    c:          BluewingServer.RemoteClient,
    subchannel: int,
    data:       PackedByteArray,
    _variant:   int,
    _blasted:   bool
) -> void:
    # Example: clients send their version number on subchannel 0 at connect time.
    if subchannel == 0 and data.size() >= 2:
        var version := data[0] * 100 + data[1]
        if version < 101:  # require v1.1+
            server.kick_client(c, "Outdated client.")
```

---

### Mixed sync rates and reliability

Different properties need different transport characteristics.  Use a `Dictionary` with per-property `SyncConfig` objects to fine-tune each one.

```gdscript
# In your spawn or setup code, after manager.spawn_node() or register_existing():

var pos_cfg := SyncConfig.new()
pos_cfg.interval    = 0.05    # 20 Hz — fast enough for smooth movement
pos_cfg.reliable    = false   # UDP blast — latency matters more than guarantee
pos_cfg.interpolate = true    # lerp on remote copies
pos_cfg.interp_delay = 0.1   # 100 ms interpolation buffer

var health_cfg := SyncConfig.new()
health_cfg.interval    = 0.5   # 2 Hz — health doesn't change 20 times a second
health_cfg.reliable    = true  # TCP — we must not miss a health update
health_cfg.interpolate = false # snap immediately; interpolating health looks wrong

var anim_cfg := SyncConfig.new()
anim_cfg.interval    = 0.1    # 10 Hz
anim_cfg.reliable    = false
anim_cfg.interpolate = false  # animation state should snap, not lerp

manager.sync_add(player_node, {
    "position":       pos_cfg,
    "velocity":       pos_cfg,    # reuse the same config object
    "health":         health_cfg,
    "animation_state": anim_cfg,
})
```

> Position and velocity share one send group (same interval + reliability), so they go out in a single blast packet.  Health goes out in a separate reliable packet at 2 Hz.  They never block each other.

---

### Custom binary game events

Use `manager.send_custom()` to attach arbitrary payloads to a specific node (e.g. a damage event attached to the attacker), or use `client.send_channel()` for events that aren't node-specific.

```gdscript
# ── Encoding helpers ─────────────────────────────────────────────────────────

const EVT_DAMAGE  := 0x01
const EVT_HEAL    := 0x02
const EVT_RESPAWN := 0x03

static func _encode_damage(amount: int, attacker_id: int) -> PackedByteArray:
    var buf := PackedByteArray([EVT_DAMAGE])
    buf.append(amount & 0xFF)
    buf.append(attacker_id & 0xFF)
    buf.append((attacker_id >> 8) & 0xFF)
    return buf

static func _encode_heal(amount: int) -> PackedByteArray:
    return PackedByteArray([EVT_HEAL, amount & 0xFF])

# ── Sending ───────────────────────────────────────────────────────────────────

func deal_damage(target_node: Node, amount: int) -> void:
    # Attach the event to the target node so the receiver knows which player was hit.
    manager.send_custom(target_node, _encode_damage(amount, client.client_id))

func use_medkit(my_node: Node) -> void:
    manager.send_custom(my_node, _encode_heal(25))

# ── Receiving ────────────────────────────────────────────────────────────────

func _ready() -> void:
    manager.custom_received.connect(_on_custom_received)

func _on_custom_received(node: Node, data: PackedByteArray) -> void:
    if data.is_empty():
        return
    match data[0]:
        EVT_DAMAGE:
            if data.size() < 3:
                return
            var amount      := data[1]
            var attacker_id := data[2] | (data[3] << 8) if data.size() >= 4 else 0
            # Apply damage on all copies of this node.
            (node as CharacterBody3D).health -= amount
            $UI.show_damage_number(node.position, amount)

        EVT_HEAL:
            if data.size() >= 2:
                (node as CharacterBody3D).health = mini(
                    (node as CharacterBody3D).health + data[1], 100
                )

        EVT_RESPAWN:
            node.position = Vector3.ZERO
            (node as CharacterBody3D).health = 100
```

> `send_custom` broadcasts to all peers reliably; the node reference on the receiving end is the locally-instantiated copy of that network node.

---

### Ownership transfer

The host can give any peer authority over any node at runtime.  A common pattern is letting a peer inherit host-owned nodes when the host leaves.

```gdscript
# ── Giving a peer control of an NPC ──────────────────────────────────────────

func give_npc_to(npc_node: Node, new_owner: BluewingClient.Peer) -> void:
    if not manager.is_host:
        return
    manager.sync_set_owner(npc_node, new_owner.id)
    # new_owner will now send state; everyone else (including the old host) receives.

# ── Detect when you gain ownership ───────────────────────────────────────────

func _ready() -> void:
    manager.ownership_changed.connect(_on_ownership_changed)

func _on_ownership_changed(node: Node, old_owner: int, new_owner: int) -> void:
    if new_owner == client.client_id:
        print("We are now driving: ", node.name)
        # Optionally re-register sync config with preferred settings.
        manager.sync_remove(node)
        manager.sync_add(node, ["position", "velocity"])

# ── Reclaim when peer leaves (host side) ─────────────────────────────────────

func _on_peer_disconnected(_ch: BluewingClient.Channel, peer: BluewingClient.Peer) -> void:
    if not manager.is_host:
        return
    # The manager auto-reclaims orphaned nodes to 0xFFFF (host-owned).
    # If you want to assign them to another specific peer:
    for net_id in manager._nodes.keys():
        if manager.get_owner_id(manager.get_node_by_id(net_id)) == 0xFFFF:
            # Reassign to the peer with the lowest ID (excluding ourselves).
            var candidates := sync_channel.peers.filter(func(p): return p.id != client.client_id)
            if not candidates.is_empty():
                candidates.sort_custom(func(a, b): return a.id < b.id)
                manager.sync_set_owner(manager.get_node_by_id(net_id), candidates[0].id)
```

---

### Pre-placed world objects

Objects that exist in every peer's scene from the start (terrain, doors, switches) don't need to be spawned — just registered with a fixed ID.

```gdscript
# game_scene.gd  (excerpt — called after channel_joined)

const NET_DOOR_NORTH := 100
const NET_DOOR_SOUTH := 101
const NET_LEVER      := 102

func _register_world_objects() -> void:
    # Must be called on every peer with the same IDs.
    manager.register_existing($World/DoorNorth, NET_DOOR_NORTH, 0xFFFF)
    manager.register_existing($World/DoorSouth, NET_DOOR_SOUTH, 0xFFFF)
    manager.register_existing($World/Lever,     NET_LEVER,      0xFFFF)

    # Doors sync their open/close state — host-owned, slow, reliable.
    var door_cfg      := SyncConfig.new()
    door_cfg.interval  = 1.0
    door_cfg.reliable  = true
    door_cfg.interpolate = false
    manager.sync_add($World/DoorNorth, ["is_open"], door_cfg)
    manager.sync_add($World/DoorSouth, ["is_open"], door_cfg)

    # Lever syncs its rotation — any peer who pulls it becomes owner momentarily.
    var lever_cfg     := SyncConfig.new()
    lever_cfg.interval = 0.1
    lever_cfg.reliable = false
    manager.sync_add($World/Lever, ["rotation"], lever_cfg)

func _on_lever_pulled() -> void:
    # Transfer ownership to this peer so we can send the updated rotation.
    if manager.is_host:
        manager.sync_set_owner($World/Lever, client.client_id)
    # Then animate the lever locally; sync will propagate the rotation.
```

---

## Signal reference

### `BluewingClient`

| Signal | Args | When |
|---|---|---|
| `connected` | — | Handshake complete (TCP + UDP echo, or immediately when `tcp_only_mode = true`) |
| `connection_denied` | `reason: String` | Server rejected the connection |
| `disconnected` | — | TCP socket closed |
| `name_set` | — | First name confirmed |
| `name_changed` | `old_name: String` | Name updated |
| `name_denied` | `attempted: String, reason: String` | Server rejected the name |
| `channel_joined` | `channel: Channel` | Joined a channel |
| `channel_join_denied` | `name: String, reason: String` | Join rejected |
| `channel_left` | `channel: Channel` | Left a channel |
| `channel_leave_denied` | `channel: Channel, reason: String` | Leave rejected |
| `channel_list_received` | `listing: Array` | Result of `request_channel_list()` |
| `peer_connected` | `channel, peer` | New peer in one of our channels |
| `peer_disconnected` | `channel, peer` | Peer left |
| `peer_name_changed` | `channel, peer, old_name` | Peer renamed |
| `server_message` | `sub, data, variant, blasted` | Message from the server |
| `channel_message` | `channel, peer, sub, data, variant, blasted` | Peer broadcast |
| `peer_message` | `channel, peer, sub, data, variant, blasted` | Direct peer message |
| `server_channel_message` | `channel, sub, data, variant, blasted` | Server addressed to a channel |
| `error_received` | `message: String` | Non-fatal protocol error |

### `BluewingServer` / `BluewingSteamServer`

Signals are identical on both classes.

| Signal | Hook pattern |
|---|---|
| `client_connected(client)` | Call `deny_connect(client, reason)` to reject; omit to auto-approve. |
| `client_disconnected(client)` | Informational. |
| `name_requested(client)` | Requested name is in `client._pending_name`. Call `deny_name(client, reason)` to reject. |
| `channel_join_requested(client, name, hidden, autoclose)` | Call `deny_join(client, name, reason)` to reject. |
| `channel_left(client, channel)` | Informational. |
| `message_server(client, sub, data, variant, blasted)` | A client addressed the server directly. |
| `message_channel(channel, sender, sub, data, variant, blasted)` | Peer channel broadcast (informational — already relayed). |
| `message_peer(channel, sender, target, sub, data, variant, blasted)` | Peer direct message (informational — already relayed). |

### `BluewingNetworkManager`

| Signal | Args | When |
|---|---|---|
| `node_spawned` | `node, network_id, owner_id` | Remote SPAWN received and applied |
| `node_despawned` | `network_id` | Remote DESPAWN received |
| `ownership_changed` | `node, old_owner, new_owner` | Ownership transferred |
| `custom_received` | `node, data` | `send_custom()` payload arrived |

### `BluewingSteamLobby`

| Signal | Args | When |
|---|---|---|
| `lobby_created` | `lobby_id: int` | Lobby successfully created (host) |
| `lobby_joined` | `lobby_id, server_steam_id` | Lobby joined; `server_steam_id` is who to connect to |
| `join_game_requested` | `lobby_id: int` | "Join Game" clicked while game is running |
| `lobby_error` | `message: String` | Any lobby operation failed |

---

## SyncConfig reference

`SyncConfig` is a `Resource`.  Create instances in code or save them as `.tres` files.

| Property | Type | Default | Description |
|---|---|---|---|
| `interval` | `float` | `0.05` | Seconds between sends (0.05 = 20 Hz) |
| `reliable` | `bool` | `false` | `true` = TCP; `false` = UDP blast |
| `interpolate` | `bool` | `true` | Smoothly lerp on remote copies |
| `interp_delay` | `float` | `0.1` | Interpolation buffer depth in seconds |

**Interpolation** works for: `float`, `int`, `Vector2`, `Vector3`, `Color`, `Quaternion`, `Transform2D`, `Transform3D`, `Basis`.  All other types snap to the latest authoritative value.

**Grouping:** properties that share the same `interval` and `reliable` values are batched into one packet.  Declare them together for best efficiency:

```gdscript
# position and velocity share one 20 Hz UDP group → one packet per tick.
manager.sync_add(node, {
    "position": pos_cfg,
    "velocity": pos_cfg,   # same object = same group
    "health":   health_cfg,
})
```

---

## Subchannel convention

`BluewingNetworkManager` reserves **subchannel 200** for all sync protocol traffic.  
Use subchannels **0–199** for your own `send_channel` / `blast_channel` calls.

Define your subchannels as constants at the top of your game script:

```gdscript
const SUB_CHAT    := 0   # UTF-8 text
const SUB_PING    := 1   # latency probe
const SUB_PICKUP  := 2   # world-event notifications
const SUB_VOTE    := 3   # game-mode voting
# 200 is reserved — do not use
```

---

## TCP-only mode

If UDP is blocked (strict firewalls, some mobile networks), set `client.tcp_only_mode = true` **before** calling `connect_to_server()`.  
`connected` fires immediately after the TCP handshake; `blast_*` calls silently no-op — use `send_*` variants instead.

```gdscript
func join_behind_firewall(host: String) -> void:
    client.tcp_only_mode = true
    client.connect_to_server(host, 6121)
```

The Steam transport (`BluewingSteamClient`) never needs this — Valve's relay handles NAT automatically.
