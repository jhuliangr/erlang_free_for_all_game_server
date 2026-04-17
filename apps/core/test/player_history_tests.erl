%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the player_history lag-compensation store.
%%%
%%% Covers: snapshot storage, position lookup, tick clamping on
%%% underflow, and the HISTORY_DEPTH retention window.
%%% @end
%%%-------------------------------------------------------------------
-module(player_history_tests).

-include_lib("eunit/include/eunit.hrl").

player_history_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
         {"position_at on empty history returns not_found",
          fun test_empty_history/0},
         {"single snapshot is retrievable",
          fun test_single_snapshot/0},
         {"most recent snapshot wins for latest tick",
          fun test_latest_snapshot/0},
         {"past ticks return the stored position at that tick",
          fun test_rewind/0},
         {"requesting unknown player returns not_found",
          fun test_unknown_player/0},
         {"ticks older than HISTORY_DEPTH clamp to oldest retained",
          fun test_clamp_underflow/0},
         {"ticks newer than latest clamp to latest",
          fun test_clamp_overflow/0},
         {"eviction removes ticks beyond HISTORY_DEPTH",
          fun test_eviction/0}
     ]}.

%%--------------------------------------------------------------------
%% Setup / teardown
%%--------------------------------------------------------------------

setup() ->
    rand:seed(exsss, {1, 2, 3}),
    case whereis(player_history) of
        undefined -> ok;
        Pid       -> gen_server:stop(Pid)
    end,
    {ok, _} = player_history:start_link(),
    ok.

teardown(_) ->
    case whereis(player_history) of
        undefined -> ok;
        Pid       -> gen_server:stop(Pid)
    end,
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

sync() ->
    %% Block until previous casts have been processed.
    catch gen_server:call(player_history, sync, 1000).

player_at(Id, X, Y) ->
    P0 = player:new(Id, Id),
    player:set_position(P0, X, Y).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

test_empty_history() ->
    ?assertEqual(not_found, player_history:position_at(<<"nobody">>, 5)).

test_single_snapshot() ->
    P = player_at(<<"a">>, 100.0, 200.0),
    player_history:snapshot(1, [P]),
    sync(),
    ?assertMatch({ok, {100.0, 200.0}, _}, player_history:position_at(<<"a">>, 1)).

test_latest_snapshot() ->
    P = player_at(<<"b">>, 50.0, 50.0),
    player_history:snapshot(1, [P]),
    sync(),
    ?assertEqual(1, player_history:latest_tick()).

test_rewind() ->
    P1 = player_at(<<"c">>, 10.0, 10.0),
    P2 = player_at(<<"c">>, 20.0, 20.0),
    P3 = player_at(<<"c">>, 30.0, 30.0),
    player_history:snapshot(1, [P1]),
    player_history:snapshot(2, [P2]),
    player_history:snapshot(3, [P3]),
    sync(),
    ?assertMatch({ok, {10.0, 10.0}, 1}, player_history:position_at(<<"c">>, 1)),
    ?assertMatch({ok, {20.0, 20.0}, 2}, player_history:position_at(<<"c">>, 2)),
    ?assertMatch({ok, {30.0, 30.0}, 3}, player_history:position_at(<<"c">>, 3)).

test_unknown_player() ->
    P = player_at(<<"d">>, 0.0, 0.0),
    player_history:snapshot(1, [P]),
    sync(),
    ?assertEqual(not_found,
                 player_history:position_at(<<"someone_else">>, 1)).

test_clamp_underflow() ->
    %% Write 25 ticks (> HISTORY_DEPTH=20). Oldest retained is tick 6.
    %% Requesting tick 0 should clamp to 6.
    lists:foreach(
      fun(T) ->
          P = player_at(<<"e">>, float(T), float(T)),
          player_history:snapshot(T, [P])
      end,
      lists:seq(1, 25)
    ),
    sync(),
    {ok, XY, UsedTick} = player_history:position_at(<<"e">>, 0),
    ?assertEqual({6.0, 6.0}, XY),
    ?assertEqual(6, UsedTick).

test_clamp_overflow() ->
    P = player_at(<<"f">>, 5.0, 5.0),
    player_history:snapshot(10, [P]),
    sync(),
    %% Requesting a tick newer than the latest should clamp to latest.
    {ok, XY, UsedTick} = player_history:position_at(<<"f">>, 9999),
    ?assertEqual({5.0, 5.0}, XY),
    ?assertEqual(10, UsedTick).

test_eviction() ->
    %% Write more than HISTORY_DEPTH snapshots. The oldest ones must
    %% no longer have their ETS row.
    lists:foreach(
      fun(T) ->
          P = player_at(<<"g">>, float(T), 0.0),
          player_history:snapshot(T, [P])
      end,
      lists:seq(1, 25)
    ),
    sync(),
    %% Tick 1 should have been evicted (kept ticks are 6..25).
    ?assertEqual([], ets:lookup(player_history, 1)),
    ?assertNotEqual([], ets:lookup(player_history, 25)).
