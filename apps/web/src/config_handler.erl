%%%-------------------------------------------------------------------
%%% @doc Cowboy REST handler for the /api/config endpoint.
%%%
%%% Returns the full server-driven cosmetics and game-rules
%%% configuration as a JSON response. Clients use this data to render
%%% unlock conditions without hardcoding any values.
%%% @end
%%%-------------------------------------------------------------------
-module(config_handler).

-export([init/2]).

%%--------------------------------------------------------------------
%% @doc Handle GET /api/config — returns cosmetics config as JSON.
%% @end
%%--------------------------------------------------------------------
-spec init(cowboy_req:req(), term()) ->
    {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Config  = cosmetics:default_config(),
    Body    = jsx:encode(Config),
    Req = cowboy_req:reply(
        200,
        #{
            <<"content-type">>                => <<"application/json">>,
            <<"access-control-allow-origin">> => <<"*">>
        },
        Body,
        Req0
    ),
    {ok, Req, State}.
