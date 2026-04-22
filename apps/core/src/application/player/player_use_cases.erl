%%%-------------------------------------------------------------------
%%% @doc Player application use cases.
%%%
%%% Orchestrates domain objects and infrastructure services to fulfil
%%% player-related application commands: joining, leaving, and
%%% equipping cosmetics.
%%% @end
%%%-------------------------------------------------------------------
-module(player_use_cases).

-export([
    join_game/2,
    join_game/3,
    leave_game/1,
    kill_player/1,
    equip_cosmetic/3
]).

%%--------------------------------------------------------------------
%% @doc Join the game: create a new player, register it in all indexes.
%%
%% Returns `{ok, Player}` with the newly created player record.
%% @end
%%--------------------------------------------------------------------
-spec join_game(binary(), binary()) -> {ok, player:player()}.
join_game(PlayerId, Name) ->
    join_game(PlayerId, Name, <<"knight">>).

-spec join_game(binary(), binary(), binary()) -> {ok, player:player()}.
join_game(PlayerId, Name, Character) ->
    Player = player:new(PlayerId, Name, Character),
    player_registry:register(Player, undefined),
    spatial_index:insert(PlayerId, player:x(Player), player:y(Player)),
    lager:info("Player joined: ~s (~s) as ~s", [PlayerId, Name, Character]),
    {ok, Player}.

%%--------------------------------------------------------------------
%% @doc Leave the game: remove the player from all indexes.
%% @end
%%--------------------------------------------------------------------
-spec leave_game(binary()) -> ok.
leave_game(PlayerId) ->
    %% Save session stats to leaderboard before removing
    case player_registry:get_player(PlayerId) of
        {ok, Player} ->
            leaderboard_use_cases:record_session(Player);
        {error, not_found} ->
            ok
    end,
    player_registry:unregister(PlayerId),
    spatial_index:remove(PlayerId),
    lager:info("Player left: ~s", [PlayerId]),
    ok.

%%--------------------------------------------------------------------
%% @doc Kill a player: notify their WS handler (so the client can
%% transition to the game-over screen) and then remove them from the
%% registry. This is the right call for any in-game death path — DoT,
%% melee, or any future server-driven removal — because the game loop
%% stops iterating over removed players and therefore stops broadcasting
%% state_update to them. Without this notification the client would be
%% stuck on its last known state with no further traffic to signal the
%% death.
%% @end
%%--------------------------------------------------------------------
-spec kill_player(binary()) -> ok.
kill_player(PlayerId) ->
    case player_registry:get_player(PlayerId) of
        {ok, Player} ->
            case player:pid(Player) of
                undefined -> ok;
                Pid       -> Pid ! {player_killed}
            end;
        {error, not_found} ->
            ok
    end,
    leave_game(PlayerId).

%%--------------------------------------------------------------------
%% @doc Equip a cosmetic item for the given player.
%%
%% Slot must be the atom `skin` or `weapon`.
%% @end
%%--------------------------------------------------------------------
-spec equip_cosmetic(binary(), skin | weapon | character, binary()) -> ok | {error, not_found}.
equip_cosmetic(PlayerId, Slot, ItemId) ->
    case player_registry:get_player(PlayerId) of
        {ok, Player} ->
            Updated = player:equip(Player, Slot, ItemId),
            player_registry:update_player(PlayerId, Updated),
            ok;
        {error, not_found} = Err ->
            Err
    end.
