%%%-------------------------------------------------------------------
%%% @doc Web application supervisor.
%%%
%%% Supervises the core infrastructure gen_servers:
%%% player_registry, spatial_index, game_loop, web_broadcaster.
%%% All children use the `one_for_one` strategy.
%%% @end
%%%-------------------------------------------------------------------
-module(web_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

%%--------------------------------------------------------------------
%% @doc Start the supervisor.
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc Supervisor init callback.
%% @end
%%--------------------------------------------------------------------
init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 5,
        period    => 10
    },

    Children = [
        child_spec(db,              db,              start_link, []),
        child_spec(player_registry, player_registry, start_link, []),
        child_spec(spatial_index,   spatial_index,   start_link, []),
        child_spec(player_history,  player_history,  start_link, []),
        child_spec(web_broadcaster, web_broadcaster, start_link, []),
        %% Pickup manager must start before game_loop so the first
        %% tick can already find pickups in the world.
        child_spec(pickup_manager,  pickup_manager,  start_link, []),
        child_spec(game_loop,       game_loop,       start_link, [])
    ],

    {ok, {SupFlags, Children}}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec child_spec(atom(), atom(), atom(), list()) -> supervisor:child_spec().
child_spec(Id, Module, Function, Args) ->
    #{
        id      => Id,
        start   => {Module, Function, Args},
        restart => permanent,
        type    => worker,
        modules => [Module]
    }.
