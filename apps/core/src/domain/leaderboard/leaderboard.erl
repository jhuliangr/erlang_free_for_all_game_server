%%%-------------------------------------------------------------------
%%% @doc Leaderboard domain entity.
%%%
%%% Represents a single leaderboard entry recording a player's
%%% session performance: kills, deaths, max level reached, and
%%% a computed score.
%%% @end
%%%-------------------------------------------------------------------
-module(leaderboard).

-export([
    new/4,
    score/3,
    to_map/1
]).

-record(leaderboard_entry, {
    player_name :: binary(),
    kills       :: non_neg_integer(),
    deaths      :: non_neg_integer(),
    max_level   :: pos_integer(),
    score       :: non_neg_integer()
}).

-type entry() :: #leaderboard_entry{}.
-export_type([entry/0]).

%%--------------------------------------------------------------------
%% @doc Create a new leaderboard entry from session stats.
%% @end
%%--------------------------------------------------------------------
-spec new(binary(), non_neg_integer(), non_neg_integer(), pos_integer()) -> entry().
new(PlayerName, Kills, Deaths, MaxLevel) ->
    #leaderboard_entry{
        player_name = PlayerName,
        kills       = Kills,
        deaths      = Deaths,
        max_level   = MaxLevel,
        score       = score(Kills, Deaths, MaxLevel)
    }.

%%--------------------------------------------------------------------
%% @doc Compute score from session stats.
%% Formula: kills * 100 + max_level * 50 - deaths * 25
%% @end
%%--------------------------------------------------------------------
-spec score(non_neg_integer(), non_neg_integer(), pos_integer()) -> non_neg_integer().
score(Kills, Deaths, MaxLevel) ->
    max(0, Kills * 100 + MaxLevel * 50 - Deaths * 25).

%%--------------------------------------------------------------------
%% @doc Serialize to a JSON-compatible map.
%% @end
%%--------------------------------------------------------------------
-spec to_map(entry()) -> map().
to_map(E) ->
    #{
        player_name => E#leaderboard_entry.player_name,
        kills       => E#leaderboard_entry.kills,
        deaths      => E#leaderboard_entry.deaths,
        max_level   => E#leaderboard_entry.max_level,
        score       => E#leaderboard_entry.score
    }.
