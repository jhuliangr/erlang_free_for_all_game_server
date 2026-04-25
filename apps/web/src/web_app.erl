%%%-------------------------------------------------------------------
%%% @doc Web OTP application.
%%%
%%% Starts the Cowboy HTTP/WebSocket listener on the configured port
%%% (default 8080) and brings up the web supervision tree.
%%% @end
%%%-------------------------------------------------------------------
-module(web_app).

-behaviour(application).

-export([start/2, stop/1]).

%%--------------------------------------------------------------------
%% @doc Start the web application.
%% @end
%%--------------------------------------------------------------------
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    Port = application:get_env(web, port, 8080),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/config",         config_handler,         []},
            {"/api/leaderboard",    leaderboard_handler,    []},
            {"/api/match/players",  match_players_handler,  []},
            {"/ws",                 ws_handler,             []}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(
        http_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    lager:info("Cowboy listening on port ~p", [Port]),

    {ok, Pid} = web_sup:start_link(),

    %% Run database migrations after supervisor starts (db gen_server is up)
    case leaderboard_repo:create_table() of
        ok ->
            lager:info("Leaderboard table ready");
        {error, MigErr} ->
            lager:warning("Leaderboard migration failed: ~p (leaderboard will be unavailable)", [MigErr])
    end,

    {ok, Pid}.

%%--------------------------------------------------------------------
%% @doc Stop the web application.
%% @end
%%--------------------------------------------------------------------
-spec stop(term()) -> ok.
stop(_State) ->
    cowboy:stop_listener(http_listener).
