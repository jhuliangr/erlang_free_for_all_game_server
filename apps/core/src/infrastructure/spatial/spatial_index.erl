%%%-------------------------------------------------------------------
%%% @doc ETS-based spatial hash grid for fast proximity queries.
%%%
%%% Divides the world into cells of CELL_SIZE x CELL_SIZE units.
%%% Each player occupies a single cell based on their (x, y) position.
%%% Nearby queries inspect all cells overlapping the query bounding box.
%%% @end
%%%-------------------------------------------------------------------
-module(spatial_index).

-behaviour(gen_server).

%% Public API
-export([start_link/0, insert/3, remove/1, query_nearby/3, update/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TABLE, spatial_index).
-define(CELL_SIZE, 200).
-define(SERVER, ?MODULE).

-record(state, {table :: ets:tid()}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec insert(binary(), float(), float()) -> ok.
insert(Id, X, Y) ->
    gen_server:call(?SERVER, {insert, Id, X, Y}).

-spec remove(binary()) -> ok.
remove(Id) ->
    gen_server:call(?SERVER, {remove, Id}).

-spec update(binary(), float(), float()) -> ok.
update(Id, X, Y) ->
    gen_server:call(?SERVER, {update, Id, X, Y}).

-spec query_nearby(float(), float(), float()) -> [binary()].
query_nearby(X, Y, Radius) ->
    gen_server:call(?SERVER, {query_nearby, X, Y, Radius}).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    Table = ets:new(?TABLE, [named_table, set, protected,
                              {keypos, 1}, {read_concurrency, true}]),
    lager:info("Spatial index started, cell_size=~p", [?CELL_SIZE]),
    {ok, #state{table = Table}}.

handle_call({insert, Id, X, Y}, _From, State) ->
    Cell = coords_to_cell(X, Y),
    ets:insert(?TABLE, {Id, Cell, X, Y}),
    {reply, ok, State};

handle_call({remove, Id}, _From, State) ->
    ets:delete(?TABLE, Id),
    {reply, ok, State};

handle_call({update, Id, X, Y}, _From, State) ->
    Cell = coords_to_cell(X, Y),
    ets:insert(?TABLE, {Id, Cell, X, Y}),
    {reply, ok, State};

handle_call({query_nearby, X, Y, Radius}, _From, State) ->
    Ids = do_query_nearby(X, Y, Radius),
    {reply, Ids, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec coords_to_cell(float(), float()) -> {integer(), integer()}.
coords_to_cell(X, Y) ->
    {trunc(X) div ?CELL_SIZE, trunc(Y) div ?CELL_SIZE}.

-spec do_query_nearby(float(), float(), float()) -> [binary()].
do_query_nearby(X, Y, Radius) ->
    MinCellX = trunc(X - Radius) div ?CELL_SIZE,
    MaxCellX = trunc(X + Radius) div ?CELL_SIZE,
    MinCellY = trunc(Y - Radius) div ?CELL_SIZE,
    MaxCellY = trunc(Y + Radius) div ?CELL_SIZE,
    RadiusSq  = Radius * Radius,
    Candidates = collect_cells(MinCellX, MaxCellX, MinCellY, MaxCellY, []),
    %% Filter by actual distance
    lists:filtermap(
        fun({Id, _Cell, Px, Py}) ->
            Dx = Px - X,
            Dy = Py - Y,
            case Dx * Dx + Dy * Dy =< RadiusSq of
                true  -> {true, Id};
                false -> false
            end
        end,
        Candidates
    ).

-spec collect_cells(integer(), integer(), integer(), integer(), list()) -> list().
collect_cells(MinCX, MaxCX, MinCY, MaxCY, Acc) ->
    Rows = lists:seq(MinCY, MaxCY),
    Cols = lists:seq(MinCX, MaxCX),
    lists:foldl(
        fun(CY, OuterAcc) ->
            lists:foldl(
                fun(CX, InnerAcc) ->
                    Entries = ets:match_object(?TABLE, {'_', {CX, CY}, '_', '_'}),
                    Entries ++ InnerAcc
                end,
                OuterAcc,
                Cols
            )
        end,
        Acc,
        Rows
    ).
