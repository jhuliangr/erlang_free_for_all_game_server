%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the combat_resolver domain service.
%%%
%%% Covers: range detection (with the explicit Range parameter),
%%% damage scaling via resolve/3, and knockback direction.
%%% @end
%%%-------------------------------------------------------------------
-module(combat_resolver_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KNIGHT_RANGE, 150.0).

%%--------------------------------------------------------------------
%% Test generator
%%--------------------------------------------------------------------

combat_resolver_test_() ->
    [
        {"is_in_range: same position is in range",      fun test_in_range_same_pos/0},
        {"is_in_range: within range is in range",       fun test_in_range_within/0},
        {"is_in_range: exactly at Range is in range",   fun test_in_range_boundary/0},
        {"is_in_range: beyond Range is out",            fun test_out_of_range/0},
        {"resolve: level 1 knight deals 10.0 damage",   fun test_damage_level1/0},
        {"resolve: level 2 knight deals 11.5 damage",   fun test_damage_level2/0},
        {"resolve: damage scales with level",           fun test_damage_scales/0},
        {"resolve: in range returns damage + knockback",fun test_resolve_in_range/0},
        {"resolve: out of range returns error",         fun test_resolve_out_of_range/0},
        {"resolve: knockback direction is correct",     fun test_resolve_knockback_direction/0}
    ].

%%--------------------------------------------------------------------
%% is_in_range tests
%%--------------------------------------------------------------------

test_in_range_same_pos() ->
    ?assert(combat_resolver:is_in_range(0.0, 0.0, 0.0, 0.0, ?KNIGHT_RANGE)).

test_in_range_within() ->
    ?assert(combat_resolver:is_in_range(0.0, 0.0, 100.0, 0.0, ?KNIGHT_RANGE)).

test_in_range_boundary() ->
    %% Exactly at Range — still in range (=<)
    ?assert(combat_resolver:is_in_range(0.0, 0.0, ?KNIGHT_RANGE, 0.0, ?KNIGHT_RANGE)).

test_out_of_range() ->
    ?assertNot(combat_resolver:is_in_range(0.0, 0.0, ?KNIGHT_RANGE + 1.0, 0.0, ?KNIGHT_RANGE)).

%%--------------------------------------------------------------------
%% Damage scaling tests — exercised through resolve/3
%%--------------------------------------------------------------------

test_damage_level1() ->
    rand:seed(exsss, {10, 20, 30}),
    Attacker = player:set_position(player:new(<<"a1">>, <<"A">>), 0.0, 0.0),
    Defender = player:set_position(player:new(<<"d1">>, <<"D">>), 100.0, 0.0),
    {ok, Damage, _, _} = combat_resolver:resolve(Attacker, Defender, 0.0),
    ?assertEqual(10.0, Damage).

test_damage_level2() ->
    %% Granting 100 XP levels a fresh knight to level 2 (threshold 1→2 is 100).
    rand:seed(exsss, {11, 20, 30}),
    Attacker0 = player:set_position(player:new(<<"a2">>, <<"A">>), 0.0, 0.0),
    Attacker  = player:gain_xp(Attacker0, 100.0),
    ?assertEqual(2, player:level(Attacker)),
    Defender = player:set_position(player:new(<<"d2">>, <<"D">>), 100.0, 0.0),
    {ok, Damage, _, _} = combat_resolver:resolve(Attacker, Defender, 0.0),
    ?assertEqual(11.5, Damage).

test_damage_scales() ->
    %% Damage scales at 15% per level above 1.
    %% Grant enough XP to reach a higher level (exact level depends on
    %% thresholds; assert against whatever level was actually reached).
    rand:seed(exsss, {12, 20, 30}),
    Attacker0 = player:set_position(player:new(<<"a3">>, <<"A">>), 0.0, 0.0),
    Attacker  = player:gain_xp(Attacker0, 1000.0),
    L = player:level(Attacker),
    ?assert(L > 1),
    Defender = player:set_position(player:new(<<"d3">>, <<"D">>), 100.0, 0.0),
    {ok, Damage, _, _} = combat_resolver:resolve(Attacker, Defender, 0.0),
    ExpectedDmg = 10.0 * (1.0 + 0.15 * (L - 1)),
    ?assertEqual(ExpectedDmg, Damage).

%%--------------------------------------------------------------------
%% resolve/3 tests — uses player stubs built via player:new/2
%%--------------------------------------------------------------------

test_resolve_in_range() ->
    rand:seed(exsss, {13, 20, 30}),
    Attacker = player:set_position(player:new(<<"a4">>, <<"A">>), 0.0, 0.0),
    Defender = player:set_position(player:new(<<"d4">>, <<"D">>), 100.0, 0.0),
    Result   = combat_resolver:resolve(Attacker, Defender, 0.0),
    ?assertMatch({ok, _, _, _}, Result),
    {ok, Damage, _KbDx, _KbDy} = Result,
    ?assertEqual(10.0, Damage).

test_resolve_out_of_range() ->
    rand:seed(exsss, {14, 22, 33}),
    Attacker = player:set_position(player:new(<<"a5">>, <<"A">>), 0.0,   0.0),
    Defender = player:set_position(player:new(<<"d5">>, <<"D">>), 500.0, 0.0),
    ?assertEqual({error, out_of_range},
                 combat_resolver:resolve(Attacker, Defender, 0.0)).

test_resolve_knockback_direction() ->
    rand:seed(exsss, {15, 23, 34}),
    %% Attacker at origin, defender to the right → knockback should be positive X
    Attacker = player:set_position(player:new(<<"a6">>, <<"A">>), 0.0,  0.0),
    Defender = player:set_position(player:new(<<"d6">>, <<"D">>), 50.0, 0.0),
    {ok, _Damage, KbDx, KbDy} = combat_resolver:resolve(Attacker, Defender, 0.0),
    ?assert(KbDx > 0.0),
    ?assertEqual(0.0, KbDy).
