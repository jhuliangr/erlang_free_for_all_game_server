%%%-------------------------------------------------------------------
%%% @doc Cowboy REST handler for /api/match/players.
%%%
%%% Returns the live scoreboard of players currently connected to the
%%% match, ordered by kills (tiebreak: xp) and trimmed to `?limit=N`
%%% (default 5). Unlike /api/leaderboard (which reads the persisted
%%% all-time leaderboard from the database), this endpoint reflects
%%% the in-memory player registry — the authoritative source for
%%% "who's in the game right now".
%%%
%%% This exists because the WebSocket state_update stream is
%%% perspective-filtered (each client only sees nearby players), so
%%% the frontend can't compose a complete match scoreboard from its
%%% local store alone.
%%% @end
%%%-------------------------------------------------------------------
-module(match_players_handler).

-export([init/2]).

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">>  => <<"*">>,
    <<"access-control-allow-methods">> => <<"GET, OPTIONS">>,
    <<"access-control-allow-headers">> => <<"content-type, authorization">>
}).

-define(DEFAULT_LIMIT, 5).
-define(MAX_LIMIT, 50).

-spec init(cowboy_req:req(), term()) ->
    {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, ?CORS_HEADERS, <<>>, Req0),
            {ok, Req, State};
        <<"GET">> ->
            Limit = parse_limit(Req0),
            Entries = top_entries(Limit),
            Body = jsx:encode(#{
                type    => <<"match_players">>,
                entries => Entries
            }),
            Base = ?CORS_HEADERS,
            Headers = Base#{<<"content-type">> => <<"application/json">>},
            Req = cowboy_req:reply(200, Headers, Body, Req0),
            {ok, Req, State}
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec top_entries(pos_integer()) -> [map()].
top_entries(Limit) ->
    %% Only include connected players — grace-period disconnects and
    %% dead pids should not show in the live scoreboard.
    All = player_registry:all_players(),
    Connected = [P || P <- All, player:pid(P) =/= undefined],
    Sorted = lists:sort(
        fun(A, B) ->
            KA = player:kills(A),
            KB = player:kills(B),
            case KA =:= KB of
                true  -> player:xp(A) >= player:xp(B);
                false -> KA > KB
            end
        end,
        Connected
    ),
    Top = lists:sublist(Sorted, Limit),
    [#{id     => player:id(P),
       name   => player:name(P),
       kills  => player:kills(P),
       xp     => player:xp(P),
       level  => player:level(P)} || P <- Top].

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
