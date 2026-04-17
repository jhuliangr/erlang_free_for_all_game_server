%%%-------------------------------------------------------------------
%%% @doc Rolling per-tick snapshot of player positions.
%%%
%%% Used for lag-compensated hit detection: when a client reports an
%%% attack that was aimed at tick T on its screen, the server rewinds
%%% the defender's position to tick T (clamped to the oldest retained
%%% snapshot) before running range checks.
%%%
%%% Storage: one ETS row per tick of form
%%%   {Tick :: non_neg_integer(), #{PlayerId => {X, Y}}}
%%%
%%% Retention: the most recent HISTORY_DEPTH ticks. At 50ms tick and
%%% HISTORY_DEPTH = 20 this covers 1 second — larger than typical
%%% round-trip latencies on public internet, and capped so old ticks
%%% cannot be abused to rewind indefinitely.
%%% @end
%%%-------------------------------------------------------------------
-module(player_history).

-behaviour(gen_server).

-export([start_link/0,
         snapshot/2,
         position_at/2,
         latest_tick/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TABLE, player_history).
-define(HISTORY_DEPTH, 20).
-define(SERVER, ?MODULE).

-record(state, {
    latest_tick :: non_neg_integer()
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc Store a positional snapshot for the given tick.
%% `Players` is a list of `player:player()` records.
%% @end
%%--------------------------------------------------------------------
-spec snapshot(non_neg_integer(), [player:player()]) -> ok.
snapshot(Tick, Players) ->
    gen_server:cast(?SERVER, {snapshot, Tick, Players}).

%%--------------------------------------------------------------------
%% @doc Look up a player's position at the given tick.
%%
%% If the requested tick is older than the retained window the oldest
%% available snapshot is returned. Returns `not_found` when the player
%% was not present at that tick (or when history is empty).
%% @end
%%--------------------------------------------------------------------
-spec position_at(binary(), non_neg_integer()) ->
    {ok, {float(), float()}, non_neg_integer()} | not_found.
position_at(PlayerId, RequestedTick) ->
    case latest_tick_ets() of
        0 ->
            not_found;
        Latest ->
            OldestRetained = max(0, Latest - ?HISTORY_DEPTH + 1),
            Tick = clamp(RequestedTick, OldestRetained, Latest),
            case ets:lookup(?TABLE, Tick) of
                [{Tick, Positions}] ->
                    case maps:find(PlayerId, Positions) of
                        {ok, XY} -> {ok, XY, Tick};
                        error    -> not_found
                    end;
                [] ->
                    not_found
            end
    end.

-spec latest_tick() -> non_neg_integer().
latest_tick() ->
    latest_tick_ets().

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    ets:new(?TABLE, [named_table, set, protected,
                     {keypos, 1}, {read_concurrency, true}]),
    %% Sentinel row holding the latest tick for lock-free reads.
    ets:insert(?TABLE, {latest_tick, 0}),
    lager:info("Player history started, depth=~p ticks", [?HISTORY_DEPTH]),
    {ok, #state{latest_tick = 0}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({snapshot, Tick, Players}, State) ->
    Positions = lists:foldl(
        fun(P, Acc) ->
            Acc#{player:id(P) => {player:x(P), player:y(P)}}
        end, #{}, Players),
    ets:insert(?TABLE, {Tick, Positions}),
    ets:insert(?TABLE, {latest_tick, Tick}),
    evict_old(Tick),
    {noreply, State#state{latest_tick = Tick}};

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

-spec latest_tick_ets() -> non_neg_integer().
latest_tick_ets() ->
    case ets:lookup(?TABLE, latest_tick) of
        [{latest_tick, T}] -> T;
        []                 -> 0
    end.

-spec evict_old(non_neg_integer()) -> ok.
evict_old(CurrentTick) when CurrentTick >= ?HISTORY_DEPTH ->
    ets:delete(?TABLE, CurrentTick - ?HISTORY_DEPTH),
    ok;
evict_old(_) ->
    ok.

-spec clamp(integer(), integer(), integer()) -> integer().
clamp(V, Lo, _Hi) when V < Lo -> Lo;
clamp(V, _Lo, Hi) when V > Hi -> Hi;
clamp(V, _Lo, _Hi)            -> V.
