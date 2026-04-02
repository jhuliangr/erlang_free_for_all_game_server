%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the player aggregate.
%%%
%%% Covers: creation, movement clamping, damage floor, XP and
%%% level-up mechanics.
%%% @end
%%%-------------------------------------------------------------------
-module(player_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Test generator
%%--------------------------------------------------------------------

player_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
         {"new player has correct defaults",        fun test_new_player/0},
         {"move clamped at world boundary",         fun test_move_clamp/0},
         {"move with zero delta stays put",         fun test_move_zero/0},
         {"take_damage reduces hp",                 fun test_take_damage/0},
         {"take_damage never goes below zero",      fun test_take_damage_floor/0},
         {"gain_xp increases xp",                   fun test_gain_xp/0},
         {"gain_xp triggers level up",              fun test_gain_xp_level_up/0},
         {"gain_xp multi-level up",                 fun test_gain_xp_multi_level/0},
         {"equip skin updates skin",                fun test_equip_skin/0},
         {"equip weapon updates weapon",            fun test_equip_weapon/0},
         {"equip character updates character",      fun test_equip_character/0},
         {"equip invalid character is ignored",     fun test_equip_invalid_character/0},
         {"to_map serializes all fields",           fun test_to_map/0},
         {"set_position clamps to world bounds",    fun test_set_position/0}
     ]}.

%%--------------------------------------------------------------------
%% Setup / teardown
%%--------------------------------------------------------------------

setup() ->
    %% world:spawn_point/0 uses rand, seed for reproducibility
    rand:seed(exsss, {1, 2, 3}),
    ok.

teardown(_) ->
    ok.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

test_new_player() ->
    P = player:new(<<"p1">>, <<"Alice">>),
    ?assertEqual(<<"p1">>,     player:id(P)),
    ?assertEqual(<<"Alice">>,  player:name(P)),
    ?assertEqual(undefined,    player:pid(P)),
    ?assertEqual(1,            player:level(P)),
    ?assertEqual(0.0,          player:xp(P)),
    ?assertEqual(100.0,        player:hp(P)),
    %% Position should be within world bounds (100 margin)
    ?assert(player:x(P) >= 100.0),
    ?assert(player:x(P) =< 1900.0),
    ?assert(player:y(P) >= 100.0),
    ?assert(player:y(P) =< 1900.0).

test_move_clamp() ->
    %% Create player near the origin (force position via set_position)
    P0 = player:new(<<"p2">>, <<"Bob">>),
    P1 = player:set_position(P0, 5.0, 5.0),
    %% Try to move far to the left/up (should clamp at 0,0)
    P2 = player:move(P1, -1000.0, -1000.0),
    ?assertEqual(0.0, player:x(P2)),
    ?assertEqual(0.0, player:y(P2)).

test_move_zero() ->
    P0 = player:new(<<"p3">>, <<"Carol">>),
    X0 = player:x(P0),
    Y0 = player:y(P0),
    P1 = player:move(P0, 0.0, 0.0),
    ?assertEqual(X0, player:x(P1)),
    ?assertEqual(Y0, player:y(P1)).

test_take_damage() ->
    P0 = player:new(<<"p4">>, <<"Dan">>),
    P1 = player:take_damage(P0, 30.0),
    ?assertEqual(70.0, player:hp(P1)).

test_take_damage_floor() ->
    P0 = player:new(<<"p5">>, <<"Eve">>),
    P1 = player:take_damage(P0, 999.0),
    ?assertEqual(0.0, player:hp(P1)).

test_gain_xp() ->
    P0 = player:new(<<"p6">>, <<"Frank">>),
    P1 = player:gain_xp(P0, 50.0),
    ?assertEqual(50.0, player:xp(P1)),
    ?assertEqual(1,    player:level(P1)).

test_gain_xp_level_up() ->
    P0 = player:new(<<"p7">>, <<"Grace">>),
    %% Level 1 requires 100 XP to reach level 2
    P1 = player:gain_xp(P0, 100.0),
    ?assertEqual(2,    player:level(P1)),
    ?assertEqual(0.0,  player:xp(P1)).

test_gain_xp_multi_level() ->
    P0 = player:new(<<"p8">>, <<"Hank">>),
    %% Level 1->2 needs 100, level 2->3 needs 150; total 250 XP
    P1 = player:gain_xp(P0, 250.0),
    ?assert(player:level(P1) >= 2).

test_equip_skin() ->
    P0 = player:new(<<"p9">>, <<"Iris">>),
    P1 = player:equip(P0, skin, <<"skin_fire">>),
    Map = player:to_map(P1),
    ?assertEqual(<<"skin_fire">>, maps:get(skin, Map)).

test_equip_weapon() ->
    P0 = player:new(<<"p10">>, <<"Jake">>),
    P1 = player:equip(P0, weapon, <<"sword_legendary">>),
    Map = player:to_map(P1),
    ?assertEqual(<<"sword_legendary">>, maps:get(weapon, Map)).

test_equip_character() ->
    P0 = player:new(<<"p13">>, <<"Mia">>),
    P1 = player:equip(P0, character, <<"mage">>),
    Map = player:to_map(P1),
    ?assertEqual(<<"mage">>, maps:get(character, Map)).

test_equip_invalid_character() ->
    P0 = player:new(<<"p14">>, <<"Nate">>),
    P1 = player:equip(P0, character, <<"dragon">>),
    Map = player:to_map(P1),
    ?assertEqual(<<"knight">>, maps:get(character, Map)).

test_to_map() ->
    P0 = player:new(<<"p11">>, <<"Kim">>),
    Map = player:to_map(P0),
    ?assert(is_map(Map)),
    ?assert(maps:is_key(id,     Map)),
    ?assert(maps:is_key(name,   Map)),
    ?assert(maps:is_key(x,      Map)),
    ?assert(maps:is_key(y,      Map)),
    ?assert(maps:is_key(hp,     Map)),
    ?assert(maps:is_key(max_hp, Map)),
    ?assert(maps:is_key(level,  Map)),
    ?assert(maps:is_key(xp,     Map)),
    ?assert(maps:is_key(skin,      Map)),
    ?assert(maps:is_key(weapon,    Map)),
    ?assert(maps:is_key(character, Map)).

test_set_position() ->
    P0 = player:new(<<"p12">>, <<"Leo">>),
    P1 = player:set_position(P0, 500.0, 750.0),
    ?assertEqual(500.0, player:x(P1)),
    ?assertEqual(750.0, player:y(P1)),
    %% Clamping beyond world bounds
    P2 = player:set_position(P0, 99999.0, -500.0),
    ?assertEqual(2000.0, player:x(P2)),
    ?assertEqual(0.0,    player:y(P2)).
