%%%-------------------------------------------------------------------
%%% @doc Leaderboard repository.
%%%
%%% Persists and queries leaderboard entries in PostgreSQL.
%%% @end
%%%-------------------------------------------------------------------
-module(leaderboard_repo).

-export([
    create_table/0,
    save/1,
    top/1
]).

%%--------------------------------------------------------------------
%% @doc Create the leaderboard table if it doesn't exist.
%% @end
%%--------------------------------------------------------------------
-spec create_table() -> ok | {error, term()}.
create_table() ->
    Statements = [
        "CREATE TABLE IF NOT EXISTS leaderboard_entries ("
        "  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "  player_name TEXT NOT NULL,"
        "  kills INTEGER NOT NULL DEFAULT 0,"
        "  deaths INTEGER NOT NULL DEFAULT 0,"
        "  max_level INTEGER NOT NULL DEFAULT 1,"
        "  score INTEGER NOT NULL DEFAULT 0,"
        "  played_at TIMESTAMPTZ NOT NULL DEFAULT NOW()"
        ")",
        "CREATE INDEX IF NOT EXISTS idx_leaderboard_score"
        "  ON leaderboard_entries(score DESC)",
        "CREATE INDEX IF NOT EXISTS idx_leaderboard_played_at"
        "  ON leaderboard_entries(played_at DESC)"
    ],
    run_statements(Statements).

-spec run_statements([string()]) -> ok | {error, term()}.
run_statements([]) -> ok;
run_statements([Sql | Rest]) ->
    case db:query(Sql, []) of
        {ok, _} -> run_statements(Rest);
        {error, _} = Err -> Err
    end.

%%--------------------------------------------------------------------
%% @doc Save a leaderboard entry to the database.
%% @end
%%--------------------------------------------------------------------
-spec save(leaderboard:entry()) -> ok | {error, term()}.
save(Entry) ->
    Map = leaderboard:to_map(Entry),
    Sql = "INSERT INTO leaderboard_entries "
          "(player_name, kills, deaths, max_level, score) "
          "VALUES ($1, $2, $3, $4, $5)",
    Params = [
        maps:get(player_name, Map),
        maps:get(kills, Map),
        maps:get(deaths, Map),
        maps:get(max_level, Map),
        maps:get(score, Map)
    ],
    case db:query(Sql, Params) of
        {ok, _} -> ok;
        {error, _} = Err ->
            lager:error("Failed to save leaderboard entry: ~p", [Err]),
            Err
    end.

%%--------------------------------------------------------------------
%% @doc Get the top N leaderboard entries by score.
%% @end
%%--------------------------------------------------------------------
-spec top(pos_integer()) -> {ok, [map()]} | {error, term()}.
top(Limit) ->
    Sql = "SELECT player_name, kills, deaths, max_level, score, played_at "
          "FROM leaderboard_entries "
          "ORDER BY score DESC "
          "LIMIT $1",
    case db:query(Sql, [Limit]) of
        {ok, Rows} ->
            Entries = [format_row(R) || R <- Rows],
            {ok, Entries};
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec format_row(map()) -> map().
format_row(Row) ->
    #{
        player_name => maps:get(<<"player_name">>, Row),
        kills       => maps:get(<<"kills">>, Row),
        deaths      => maps:get(<<"deaths">>, Row),
        max_level   => maps:get(<<"max_level">>, Row),
        score       => maps:get(<<"score">>, Row),
        played_at   => maps:get(<<"played_at">>, Row)
    }.
