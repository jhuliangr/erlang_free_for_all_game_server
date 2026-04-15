%%%-------------------------------------------------------------------
%%% @doc Cowboy REST handler for the /api/leaderboard endpoint.
%%%
%%% Returns the top leaderboard entries as a JSON array.
%%% Supports an optional ?limit=N query parameter (default 50).
%%% @end
%%%-------------------------------------------------------------------
-module(leaderboard_handler).

-export([init/2]).

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">>  => <<"*">>,
    <<"access-control-allow-methods">> => <<"GET, OPTIONS">>,
    <<"access-control-allow-headers">> => <<"content-type, authorization">>
}).

-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 100).

%%--------------------------------------------------------------------
%% @doc Handle GET /api/leaderboard — returns top entries as JSON.
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
            Limit = parse_limit(Req0),
            Headers = ?CORS_HEADERS,
            case leaderboard_use_cases:get_top(Limit) of
                {ok, Entries} ->
                    Body = jsx:encode(#{
                        type    => <<"leaderboard">>,
                        entries => Entries
                    }),
                    Req = cowboy_req:reply(
                        200,
                        Headers#{<<"content-type">> => <<"application/json">>},
                        Body,
                        Req0
                    ),
                    {ok, Req, State};
                {error, Reason} ->
                    lager:error("Leaderboard query failed: ~p", [Reason]),
                    Body = jsx:encode(#{
                        type   => <<"error">>,
                        reason => <<"internal_error">>
                    }),
                    Req = cowboy_req:reply(
                        500,
                        Headers#{<<"content-type">> => <<"application/json">>},
                        Body,
                        Req0
                    ),
                    {ok, Req, State}
            end
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec parse_limit(cowboy_req:req()) -> pos_integer().
parse_limit(Req) ->
    QsVals = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"limit">>, 1, QsVals) of
        {_, BinVal} ->
            try binary_to_integer(BinVal) of
                N when N > 0, N =< ?MAX_LIMIT -> N;
                _ -> ?DEFAULT_LIMIT
            catch _:_ -> ?DEFAULT_LIMIT
            end;
        false ->
            ?DEFAULT_LIMIT
    end.
