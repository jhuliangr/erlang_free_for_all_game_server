%%%-------------------------------------------------------------------
%%% @doc EUnit tests for lag-compensated hit detection.
%%%
%%% Covers: combat_resolver:resolve_at/4 using an override position,
%%% plus the integration between player_history snapshots and the
%%% range check (defender rewound back into range).
%%% @end
%%%-------------------------------------------------------------------
-module(lag_compensation_tests).

-include_lib("eunit/include/eunit.hrl").

lag_compensation_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
         {"resolve_at uses override position for range check",
          fun test_resolve_at_override_in_range/0},
         {"resolve_at rejects when override is out of range",
          fun test_resolve_at_override_out_of_range/0},
         {"resolve_at uses live position for knockback direction",
          fun test_resolve_at_knockback_from_live/0},
         {"history rewind puts defender back in range",
          fun test_history_rewind_hits/0}
     ]}.

setup() ->
    rand:seed(exsss, {7, 7, 7}),
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

sync() ->
    catch gen_server:call(player_history, sync, 1000).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

test_resolve_at_override_in_range() ->
    Attacker = player:set_position(player:new(<<"a">>, <<"A">>), 0.0, 0.0),
    %% Live defender is far away (500,0) — out of 150u knight range.
    Defender = player:set_position(player:new(<<"d">>, <<"D">>), 500.0, 0.0),
    %% But the rewound hit position is within range.
    Result = combat_resolver:resolve_at(Attacker, Defender, 0.0, {100.0, 0.0}),
    ?assertMatch({ok, _, _, _}, Result).

test_resolve_at_override_out_of_range() ->
    Attacker = player:set_position(player:new(<<"a">>, <<"A">>), 0.0, 0.0),
    %% Live position in range, but rewound position is not.
    Defender = player:set_position(player:new(<<"d">>, <<"D">>), 100.0, 0.0),
    Result = combat_resolver:resolve_at(Attacker, Defender, 0.0, {500.0, 0.0}),
    ?assertEqual({error, out_of_range}, Result).

test_resolve_at_knockback_from_live() ->
    %% Attacker at origin; live defender to the right, rewound to the left.
    %% Knockback direction must follow the LIVE position (to the right).
    Attacker = player:set_position(player:new(<<"a">>, <<"A">>), 0.0,  0.0),
    Defender = player:set_position(player:new(<<"d">>, <<"D">>), 50.0, 0.0),
    {ok, _, KbDx, _} =
        combat_resolver:resolve_at(Attacker, Defender, 0.0, {-50.0, 0.0}),
    ?assert(KbDx > 0.0).

test_history_rewind_hits() ->
    %% At tick 1, defender was at (100, 0) — within 150u knight range.
    %% Their live position has since drifted to (500, 0) — out of range.
    %% A lag-compensated attack at tick 1 should still hit.
    Defender1 = player:set_position(player:new(<<"d">>, <<"D">>), 100.0, 0.0),
    player_history:snapshot(1, [Defender1]),
    sync(),
    {ok, XY, Used} = player_history:position_at(<<"d">>, 1),
    ?assertEqual({100.0, 0.0}, XY),
    ?assertEqual(1, Used),
    Attacker = player:set_position(player:new(<<"a">>, <<"A">>), 0.0, 0.0),
    LiveDefender = player:set_position(Defender1, 500.0, 0.0),
    Result = combat_resolver:resolve_at(Attacker, LiveDefender, 0.0, XY),
    ?assertMatch({ok, _, _, _}, Result).
