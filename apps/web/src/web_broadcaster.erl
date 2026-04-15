%%%-------------------------------------------------------------------
%%% @doc WebSocket broadcaster gen_server.
%%%
%%% Maintains a registry of {PlayerId, WsPid} pairs and provides
%%% broadcast/unicast operations. Messages are pre-encoded by callers
%%% (typically ws_broadcaster in the core app) and forwarded as-is.
%%% @end
%%%-------------------------------------------------------------------
-module(web_broadcaster).

-behaviour(gen_server).

%% Public API
-export([start_link/0,
         register_ws/2,
         unregister_ws/1,
         broadcast/1,
         send_to/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    clients          :: [{binary(), pid()}],
    disconnect_timers :: #{binary() => reference()}
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec register_ws(binary(), pid()) -> ok.
register_ws(PlayerId, Pid) ->
    gen_server:cast(?SERVER, {register, PlayerId, Pid}).

-spec unregister_ws(binary()) -> ok.
unregister_ws(PlayerId) ->
    gen_server:cast(?SERVER, {unregister, PlayerId}).

-spec broadcast(binary()) -> ok.
broadcast(Message) ->
    gen_server:cast(?SERVER, {broadcast, Message}).

-spec send_to(binary(), binary()) -> ok.
send_to(PlayerId, Message) ->
    gen_server:cast(?SERVER, {send_to, PlayerId, Message}).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    lager:info("Web broadcaster started", []),
    {ok, #state{clients = [], disconnect_timers = #{}}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({register, PlayerId, Pid}, State) ->
    monitor(process, Pid),
    %% Cancel any pending disconnect timer for this player (reconnect scenario)
    Timers = case maps:find(PlayerId, State#state.disconnect_timers) of
        {ok, OldRef} ->
            erlang:cancel_timer(OldRef),
            lager:info("Cancelled disconnect timer for reconnecting player ~s", [PlayerId]),
            maps:remove(PlayerId, State#state.disconnect_timers);
        error ->
            State#state.disconnect_timers
    end,
    Clients = lists:keystore(PlayerId, 1, State#state.clients, {PlayerId, Pid}),
    lager:info("WS registered: ~s", [PlayerId]),
    {noreply, State#state{clients = Clients, disconnect_timers = Timers}};

handle_cast({unregister, PlayerId}, State) ->
    Clients = lists:keydelete(PlayerId, 1, State#state.clients),
    lager:info("WS unregistered: ~s", [PlayerId]),
    {noreply, State#state{clients = Clients}};

handle_cast({broadcast, Message}, State) ->
    lists:foreach(
        fun({_PlayerId, Pid}) -> Pid ! {send, Message} end,
        State#state.clients
    ),
    {noreply, State};

handle_cast({send_to, PlayerId, Message}, State) ->
    case lists:keyfind(PlayerId, 1, State#state.clients) of
        {PlayerId, Pid} -> Pid ! {send, Message};
        false           -> ok
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% When a WebSocket process dies, start a 5-second grace period
    %% to allow the player to reconnect before removing them.
    Timers = lists:foldl(
        fun({PlayerId, P}, Acc) when P =:= Pid ->
                case player_registry:get_player(PlayerId) of
                    {ok, Player} ->
                        case player:pid(Player) =:= Pid of
                            true ->
                                %% Mark player as disconnected (pid = undefined)
                                Updated = player:set_pid(Player, undefined),
                                player_registry:update_player(PlayerId, Updated),
                                %% Start 5-second disconnect timer
                                Ref = erlang:send_after(5000, self(), {disconnect_timeout, PlayerId}),
                                lager:info("Player ~s disconnected, 5s grace period started", [PlayerId]),
                                maps:put(PlayerId, Ref, Acc);
                            false ->
                                Acc  %% Already reconnected with a new WS process
                        end;
                    {error, not_found} ->
                        Acc
                end;
           ({_PlayerId, _OtherPid}, Acc) ->
                Acc
        end,
        State#state.disconnect_timers,
        State#state.clients
    ),
    Clients = lists:filter(fun({_Id, P}) -> P =/= Pid end, State#state.clients),
    {noreply, State#state{clients = Clients, disconnect_timers = Timers}};

handle_info({disconnect_timeout, PlayerId}, State) ->
    %% Grace period expired. Remove the player only if they haven't reconnected.
    Timers = maps:remove(PlayerId, State#state.disconnect_timers),
    case player_registry:get_player(PlayerId) of
        {ok, Player} ->
            case player:pid(Player) of
                undefined ->
                    %% Still disconnected — remove from game
                    web_broadcaster:unregister_ws(PlayerId),
                    player_use_cases:leave_game(PlayerId),
                    lager:info("Player ~s removed after disconnect timeout", [PlayerId]);
                _Pid ->
                    %% Player reconnected — do nothing
                    lager:info("Player ~s reconnected before timeout expired", [PlayerId])
            end;
        {error, not_found} ->
            ok
    end,
    {noreply, State#state{disconnect_timers = Timers}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
