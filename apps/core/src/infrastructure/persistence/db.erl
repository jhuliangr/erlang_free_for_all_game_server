%%%-------------------------------------------------------------------
%%% @doc PostgreSQL connection manager.
%%%
%%% Maintains a single persistent connection to the configured
%%% PostgreSQL database. Provides a simple query interface used by
%%% repository modules.
%%% @end
%%%-------------------------------------------------------------------
-module(db).

-behaviour(gen_server).

%% Public API
-export([start_link/0, query/2, query/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    conn :: pid() | undefined
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec query(iodata(), [term()]) -> {ok, [tuple()]} | {ok, non_neg_integer()} | {error, term()}.
query(Sql, Params) ->
    gen_server:call(?SERVER, {query, Sql, Params}, 10000).

-spec query(iodata(), [term()], non_neg_integer()) -> {ok, [tuple()]} | {ok, non_neg_integer()} | {error, term()}.
query(Sql, Params, Timeout) ->
    gen_server:call(?SERVER, {query, Sql, Params}, Timeout).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    case connect() of
        {ok, Conn} ->
            lager:info("Database connection established"),
            {ok, #state{conn = Conn}};
        {error, Reason} ->
            lager:error("Database connection failed: ~p", [Reason]),
            {ok, #state{conn = undefined}}
    end.

handle_call({query, Sql, Params}, _From, #state{conn = undefined} = State) ->
    case connect() of
        {ok, Conn} ->
            Result = execute(Conn, Sql, Params),
            {reply, Result, State#state{conn = Conn}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({query, Sql, Params}, _From, #state{conn = Conn} = State) ->
    case execute(Conn, Sql, Params) of
        {error, {connection, _}} ->
            %% Connection lost, try to reconnect
            lager:warning("Database connection lost, reconnecting"),
            case connect() of
                {ok, NewConn} ->
                    Result = execute(NewConn, Sql, Params),
                    {reply, Result, State#state{conn = NewConn}};
                {error, _} = Err ->
                    {reply, Err, State#state{conn = undefined}}
            end;
        Result ->
            {reply, Result, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn = undefined}) ->
    ok;
terminate(_Reason, #state{conn = Conn}) ->
    epgsql:close(Conn),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec connect() -> {ok, pid()} | {error, term()}.
connect() ->
    {ok, DbConfig} = application:get_env(core, db),
    Host     = proplists:get_value(host, DbConfig),
    Port     = proplists:get_value(port, DbConfig, 5432),
    Username = proplists:get_value(username, DbConfig),
    Password = proplists:get_value(password, DbConfig),
    Database = proplists:get_value(database, DbConfig),
    Ssl      = proplists:get_value(ssl, DbConfig, false),
    SslOpts = case Ssl of
        true -> [{ssl, true}, {ssl_opts, [{verify, verify_none}]}];
        false -> []
    end,
    Opts = [{host, Host},
            {port, Port},
            {username, Username},
            {password, Password},
            {database, Database},
            {timeout, 10000}] ++ SslOpts,
    epgsql:connect(maps:from_list(Opts)).

-spec execute(pid(), iodata(), [term()]) -> {ok, [tuple()]} | {ok, non_neg_integer()} | {error, term()}.
execute(Conn, Sql, Params) ->
    case epgsql:equery(Conn, Sql, Params) of
        {ok, Columns, Rows} ->
            ColNames = [element(2, C) || C <- Columns],
            Maps = [maps:from_list(lists:zip(ColNames, tuple_to_list(Row)))
                    || Row <- Rows],
            {ok, Maps};
        {ok, Count} ->
            {ok, Count};
        {ok, Count, Columns, Rows} ->
            ColNames = [element(2, C) || C <- Columns],
            Maps = [maps:from_list(lists:zip(ColNames, tuple_to_list(Row)))
                    || Row <- Rows],
            {ok, Count, Maps};
        {error, _} = Err ->
            Err
    end.
