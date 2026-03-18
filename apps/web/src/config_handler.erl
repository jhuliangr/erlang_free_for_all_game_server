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

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">>  => <<"*">>,
    <<"access-control-allow-methods">> => <<"GET, OPTIONS">>,
    <<"access-control-allow-headers">> => <<"content-type, authorization">>
}).

%%--------------------------------------------------------------------
%% @doc Handle GET /api/config — returns cosmetics config as JSON.
%%      Handle OPTIONS preflight for CORS.
%% @end
%%--------------------------------------------------------------------
-spec init(cowboy_req:req(), term()) ->
    {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, ?CORS_HEADERS, <<>>, Req0),
            {ok, Req, State};
        <<"GET">> ->
            Config = cosmetics:default_config(),
            Body   = jsx:encode(Config),
            Req = cowboy_req:reply(
                200,
                ?CORS_HEADERS#{<<"content-type">> => <<"application/json">>},
                Body,
                Req0
            ),
            {ok, Req, State}
    end.
