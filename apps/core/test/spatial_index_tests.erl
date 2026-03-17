%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the spatial_index gen_server.
%%%
%%% Covers: insert + query, remove, and empty-result scenarios.
%%% The gen_server is started fresh for each test via setup/teardown.
%%% @end
%%%-------------------------------------------------------------------
-module(spatial_index_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Test generator
%%--------------------------------------------------------------------

spatial_index_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
         {"insert and query_nearby finds the player",  fun test_insert_query/0},
         {"query_nearby returns empty when no players",fun test_query_empty/0},
         {"remove deletes the player from the index",  fun test_remove/0},
         {"query_nearby excludes out-of-radius entries",fun test_query_excludes_far/0},
         {"update moves the player to new cell",       fun test_update/0},
         {"multiple players: only nearby returned",    fun test_multiple_players/0}
     ]}.

%%--------------------------------------------------------------------
%% Setup / teardown
%%--------------------------------------------------------------------

setup() ->
    %% Start a fresh gen_server instance; if one is already running stop it.
    case whereis(spatial_index) of
        undefined -> ok;
        Pid       -> gen_server:stop(Pid)
    end,
    {ok, _Pid} = spatial_index:start_link(),
    ok.

teardown(_) ->
    case whereis(spatial_index) of
        undefined -> ok;
        Pid       -> gen_server:stop(Pid)
    end.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

test_insert_query() ->
    spatial_index:insert(<<"p1">>, 100.0, 100.0),
    Result = spatial_index:query_nearby(100.0, 100.0, 50.0),
    ?assert(lists:member(<<"p1">>, Result)).

test_query_empty() ->
    Result = spatial_index:query_nearby(1000.0, 1000.0, 50.0),
    ?assertEqual([], Result).

test_remove() ->
    spatial_index:insert(<<"p2">>, 200.0, 200.0),
    spatial_index:remove(<<"p2">>),
    Result = spatial_index:query_nearby(200.0, 200.0, 100.0),
    ?assertNot(lists:member(<<"p2">>, Result)).

test_query_excludes_far() ->
    spatial_index:insert(<<"near">>, 500.0, 500.0),
    spatial_index:insert(<<"far">>,  800.0, 800.0),
    Result = spatial_index:query_nearby(500.0, 500.0, 100.0),
    ?assert(lists:member(<<"near">>, Result)),
    ?assertNot(lists:member(<<"far">>, Result)).

test_update() ->
    spatial_index:insert(<<"p3">>, 100.0, 100.0),
    spatial_index:update(<<"p3">>, 900.0, 900.0),
    %% Should no longer appear near original position
    OldArea = spatial_index:query_nearby(100.0, 100.0, 50.0),
    ?assertNot(lists:member(<<"p3">>, OldArea)),
    %% Should appear near new position
    NewArea = spatial_index:query_nearby(900.0, 900.0, 50.0),
    ?assert(lists:member(<<"p3">>, NewArea)).

test_multiple_players() ->
    spatial_index:insert(<<"a">>, 300.0, 300.0),
    spatial_index:insert(<<"b">>, 305.0, 300.0),
    spatial_index:insert(<<"c">>, 700.0, 700.0),
    Result = spatial_index:query_nearby(300.0, 300.0, 50.0),
    ?assert(lists:member(<<"a">>, Result)),
    ?assert(lists:member(<<"b">>, Result)),
    ?assertNot(lists:member(<<"c">>, Result)).
