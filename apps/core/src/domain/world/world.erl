%%%-------------------------------------------------------------------
%%% @doc World domain module.
%%%
%%% Defines the game world boundaries and provides utility functions
%%% for spatial operations such as spawning and clamping.
%%% @end
%%%-------------------------------------------------------------------
-module(world).

-export([
    bounds/0,
    spawn_point/0,
    clamp/3
]).

-define(WIDTH,  2000).
-define(HEIGHT, 2000).
-define(MARGIN, 100).

%%--------------------------------------------------------------------
%% @doc Return the world dimensions as {Width, Height}.
%% @end
%%--------------------------------------------------------------------
-spec bounds() -> {pos_integer(), pos_integer()}.
bounds() ->
    {?WIDTH, ?HEIGHT}.

%%--------------------------------------------------------------------
%% @doc Return a random spawn point within the world, with a margin.
%% @end
%%--------------------------------------------------------------------
-spec spawn_point() -> {float(), float()}.
spawn_point() ->
    X = float(?MARGIN + rand:uniform(?WIDTH  - 2 * ?MARGIN)),
    Y = float(?MARGIN + rand:uniform(?HEIGHT - 2 * ?MARGIN)),
    {X, Y}.

%%--------------------------------------------------------------------
%% @doc Clamp a value between Min and Max (inclusive).
%% @end
%%--------------------------------------------------------------------
-spec clamp(number(), number(), number()) -> number().
clamp(Value, Min, Max) ->
    max(Min, min(Max, Value)).
