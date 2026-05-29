## BluewingSteamLobby
## Manages Steam lobby creation, discovery, and the "Join Game" button.
## Requires GodotSteam 4.x — https://godotsteam.com
##
## Host flow:
##   lobby.lobby_created.connect(func(id): server.start_as_host(client))
##   lobby.create_lobby()
##
## Client flow:
##   lobby.lobby_joined.connect(func(id, sid): client.connect_to_steam(sid))
##   lobby.join_lobby(some_lobby_id)
##
## "Join Game" while already running:
##   lobby.join_game_requested.connect(func(id): lobby.join_lobby(id))

class_name BluewingSteamLobby
extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Host: emitted once the lobby is created and ready.
signal lobby_created(lobby_id: int)

## Client: emitted after joining a lobby; server_steam_id is who to connect to.
signal lobby_joined(lobby_id: int, server_steam_id: int)

## Emitted when the user clicks "Join Game" on a friend's game (game already running).
## Connect this to call join_lobby(lobby_id).
signal join_game_requested(lobby_id: int)

## Emitted on any lobby creation or join failure.
signal lobby_error(message: String)

# ---------------------------------------------------------------------------
# Exported settings
# ---------------------------------------------------------------------------

## Steam lobby type: 1=Private  2=FriendsOnly  3=Public  4=Invisible
@export_range(1, 4) var lobby_type: int = 3

## Maximum number of players in the lobby.
@export_range(2, 250) var max_players: int = 16

## Rich-presence "status" text shown in the Steam friends list.
@export var status_string: String = "In Game"

# ---------------------------------------------------------------------------
# Read-only state
# ---------------------------------------------------------------------------

## The lobby ID we currently own or have joined (0 = none).
var current_lobby_id: int = 0

## Steam ID of the server host (set from lobby data on join, or own ID on host).
var server_steam_id: int = 0

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Create a new lobby and advertise this machine as the server host.
func create_lobby() -> void:
	if not _steam_ok():
		return
	Steam.lobby_created.connect(_on_lobby_created, CONNECT_ONE_SHOT)
	Steam.create_lobby(lobby_type, max_players)  # GodotSteam


## Join an existing lobby by ID.  server_steam_id is populated on success.
func join_lobby(lobby_id: int) -> void:
	if not _steam_ok():
		return
	Steam.lobby_joined.connect(_on_lobby_joined, CONNECT_ONE_SHOT)
	Steam.join_lobby(lobby_id)  # GodotSteam


## Leave the current lobby and clear rich presence.
func leave_lobby() -> void:
	if current_lobby_id == 0:
		return
	Steam.leave_lobby(current_lobby_id)   # GodotSteam
	Steam.clear_rich_presence()            # GodotSteam
	current_lobby_id = 0
	server_steam_id  = 0


## Invite a friend (by their int64 SteamID) to the current lobby.
func invite_friend(steam_id: int) -> void:
	if current_lobby_id == 0:
		push_warning("BluewingSteamLobby: no active lobby to invite to.")
		return
	Steam.invite_user_to_lobby(current_lobby_id, steam_id)  # GodotSteam


## Request a list of public lobbies.  Results arrive via Steam.lobby_match_list.
func request_lobby_list() -> void:
	if not _steam_ok():
		return
	Steam.request_lobby_list()  # GodotSteam


## True when we own (are hosting) the current lobby.
var is_lobby_owner: bool:
	get:
		return current_lobby_id != 0 and Steam.get_lobby_owner(current_lobby_id) == Steam.get_steam_id()

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	if not _steam_ok():
		return
	# Fired when the game is already running and the user clicks "Join Game"
	# on a friend's entry in the Steam overlay.
	Steam.game_lobby_join_requested.connect(_on_join_requested)  # GodotSteam


func _exit_tree() -> void:
	leave_lobby()

# ---------------------------------------------------------------------------
# Steam callbacks
# ---------------------------------------------------------------------------

func _on_lobby_created(result: int, lobby_id: int) -> void:
	if result != 1:  # k_EResultOK
		lobby_error.emit("Lobby creation failed (result %d)." % result)
		return

	current_lobby_id = lobby_id
	server_steam_id  = Steam.get_steam_id()  # GodotSteam

	# Publish the server SteamID so joining clients know who to connect to.
	Steam.set_lobby_data(lobby_id, "server_steam_id", str(server_steam_id))
	Steam.set_lobby_data(lobby_id, "game", "bluewing")

	# "+connect_lobby <id>" is passed as a launch argument if the game was not running.
	Steam.set_rich_presence("connect", "+connect_lobby %d" % lobby_id)
	Steam.set_rich_presence("status", status_string)

	lobby_created.emit(lobby_id)


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:  # k_EChatRoomEnterResponseSuccess
		lobby_error.emit("Lobby join failed (response %d)." % response)
		return

	current_lobby_id = lobby_id
	var sid_str      := Steam.get_lobby_data(lobby_id, "server_steam_id")  # GodotSteam
	server_steam_id  = int(sid_str) if not sid_str.is_empty() else 0

	if server_steam_id == 0:
		lobby_error.emit("Lobby is missing server_steam_id data.")
		Steam.leave_lobby(lobby_id)
		current_lobby_id = 0
		return

	lobby_joined.emit(lobby_id, server_steam_id)


func _on_join_requested(lobby_id: int, _friend_id: int) -> void:
	join_game_requested.emit(lobby_id)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _steam_ok() -> bool:
	if not Engine.has_singleton("Steam"):
		push_error("BluewingSteamLobby: Steam singleton not found — is GodotSteam installed and initialised?")
		return false
	return true
