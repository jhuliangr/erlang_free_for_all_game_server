%%%-------------------------------------------------------------------
%%% @doc ETS-based player registry.
%%%
%%% Acts as the authoritative in-memory store for all connected player
%%% state. Each entry stores the player record plus the associated
%%% WebSocket process pid.
%%% @end
%%%-------------------------------------------------------------------
-module(player_registry).

-behaviour(gen_server).

%% Public API
-export([start_link/0, register/2, unregister/1,
         get_player/1, update_player/2, all_players/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TABLE, player_registry).
-define(SERVER, ?MODULE).

%% Table schema: {Id :: binary(), Player :: player:player(), Pid :: pid() | undefined}

-record(state, {table :: ets:tid()}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec register(player:player(), pid() | undefined) -> ok.
register(Player, Pid) ->
    gen_server:call(?SERVER, {register, Player, Pid}).

-spec unregister(binary()) -> ok.
unregister(Id) ->
    gen_server:call(?SERVER, {unregister, Id}).

-spec get_player(binary()) -> {ok, player:player()} | {error, not_found}.
get_player(Id) ->
    case ets:lookup(?TABLE, Id) of
        [{Id, Player, _Pid}] -> {ok, Player};
        []                   -> {error, not_found}
    end.

-spec update_player(binary(), player:player()) -> ok.
update_player(Id, Player) ->
    gen_server:call(?SERVER, {update_player, Id, Player}).

-spec all_players() -> [player:player()].
all_players() ->
    [Player || {_Id, Player, _Pid} <- ets:tab2list(?TABLE)].

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    Table = ets:new(?TABLE, [named_table, set, public,
                              {keypos, 1}, {read_concurrency, true}]),
    lager:info("Player registry started", []),
    {ok, #state{table = Table}}.

handle_call({register, Player, Pid}, _From, State) ->
    Id = player:id(Player),
    ets:insert(?TABLE, {Id, Player, Pid}),
    {reply, ok, State};

handle_call({unregister, Id}, _From, State) ->
    ets:delete(?TABLE, Id),
    {reply, ok, State};

handle_call({update_player, Id, Player}, _From, State) ->
    case ets:lookup(?TABLE, Id) of
        [{Id, _OldPlayer, Pid}] ->
            ets:insert(?TABLE, {Id, Player, Pid}),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

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
