%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the combat_resolver domain service.
%%%
%%% Covers: range detection, damage formula, and resolve/3 outcomes.
%%% @end
%%%-------------------------------------------------------------------
-module(combat_resolver_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Test generator
%%--------------------------------------------------------------------

combat_resolver_test_() ->
    [
        {"is_in_range: same position is in range",     fun test_in_range_same_pos/0},
        {"is_in_range: within 150 units is in range",  fun test_in_range_within/0},
        {"is_in_range: exactly 150 units is in range", fun test_in_range_boundary/0},
        {"is_in_range: beyond 150 units is out",       fun test_out_of_range/0},
        {"calculate_damage: level 1 gives 10.0",       fun test_damage_level1/0},
        {"calculate_damage: level 2 gives 11.5",       fun test_damage_level2/0},
        {"calculate_damage: level 5 gives 16.0",       fun test_damage_level5/0},
        {"calculate_damage: level 10 gives 23.5",      fun test_damage_level10/0},
        {"resolve: in range returns damage + knockback",fun test_resolve_in_range/0},
        {"resolve: out of range returns error",         fun test_resolve_out_of_range/0},
        {"resolve: knockback direction is correct",     fun test_resolve_knockback_direction/0}
    ].

%%--------------------------------------------------------------------
%% is_in_range tests
%%--------------------------------------------------------------------

test_in_range_same_pos() ->
    ?assert(combat_resolver:is_in_range(0.0, 0.0, 0.0, 0.0)).

test_in_range_within() ->
    ?assert(combat_resolver:is_in_range(0.0, 0.0, 100.0, 0.0)).

test_in_range_boundary() ->
    %% Exactly 150 units away — still in range (=<)
    ?assert(combat_resolver:is_in_range(0.0, 0.0, 150.0, 0.0)).

test_out_of_range() ->
    ?assertNot(combat_resolver:is_in_range(0.0, 0.0, 151.0, 0.0)).

%%--------------------------------------------------------------------
%% calculate_damage tests
%%--------------------------------------------------------------------

test_damage_level1() ->
    ?assertEqual(10.0, combat_resolver:calculate_damage(1)).

test_damage_level2() ->
    ?assertEqual(11.5, combat_resolver:calculate_damage(2)).

test_damage_level5() ->
    ?assertEqual(16.0, combat_resolver:calculate_damage(5)).

test_damage_level10() ->
    ?assertEqual(23.5, combat_resolver:calculate_damage(10)).

%%--------------------------------------------------------------------
%% resolve/3 tests — uses player stubs built via player:new/2
%%--------------------------------------------------------------------

test_resolve_in_range() ->
    rand:seed(exsss, {10, 20, 30}),
    Attacker = player:set_position(player:new(<<"a1">>, <<"A">>), 0.0, 0.0),
    Defender = player:set_position(player:new(<<"d1">>, <<"D">>), 100.0, 0.0),
    Result   = combat_resolver:resolve(Attacker, Defender, 0.0),
    ?assertMatch({ok, _, _, _}, Result),
    {ok, Damage, _KbDx, _KbDy} = Result,
    ?assertEqual(10.0, Damage).

test_resolve_out_of_range() ->
    rand:seed(exsss, {11, 22, 33}),
    Attacker = player:set_position(player:new(<<"a2">>, <<"A">>), 0.0,   0.0),
    Defender = player:set_position(player:new(<<"d2">>, <<"D">>), 500.0, 0.0),
    ?assertEqual({error, out_of_range},
                 combat_resolver:resolve(Attacker, Defender, 0.0)).

test_resolve_knockback_direction() ->
    rand:seed(exsss, {12, 23, 34}),
    %% Attacker at origin, defender to the right → knockback should be positive X
    Attacker = player:set_position(player:new(<<"a3">>, <<"A">>), 0.0,  0.0),
    Defender = player:set_position(player:new(<<"d3">>, <<"D">>), 50.0, 0.0),
    {ok, _Damage, KbDx, KbDy} = combat_resolver:resolve(Attacker, Defender, 0.0),
    ?assert(KbDx > 0.0),
    ?assertEqual(0.0, KbDy).
