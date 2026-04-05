%%%-------------------------------------------------------------------
%%% @doc Leaderboard application use cases.
%%%
%%% Orchestrates leaderboard operations: recording session results
%%% and fetching top entries.
%%% @end
%%%-------------------------------------------------------------------
-module(leaderboard_use_cases).

-export([
    record_session/1,
    get_top/1
]).

%%--------------------------------------------------------------------
%% @doc Record a player's session stats to the leaderboard.
%%
%% Takes a player record and persists their session performance.
%% Only records if the player had any meaningful activity.
%% @end
%%--------------------------------------------------------------------
-spec record_session(player:player()) -> ok | {error, term()}.
record_session(Player) ->
    Kills    = player:kills(Player),
    Deaths   = player:deaths(Player),
    Level    = player:level(Player),
    %% Only record if the player had some activity
    case Kills + Deaths > 0 orelse Level > 1 of
        true ->
            Entry = leaderboard:new(
                player:name(Player),
                Kills,
                Deaths,
                Level
            ),
            leaderboard_repo:save(Entry);
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc Get the top N leaderboard entries.
%% @end
%%--------------------------------------------------------------------
-spec get_top(pos_integer()) -> {ok, [map()]} | {error, term()}.
get_top(Limit) ->
    leaderboard_repo:top(Limit).
