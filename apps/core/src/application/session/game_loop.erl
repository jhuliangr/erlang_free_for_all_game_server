%%%-------------------------------------------------------------------
%%% @doc Game loop gen_server.
%%%
%%% Drives the authoritative server tick at 50 ms intervals. On each
%%% tick every connected player receives a `state_update` message
%%% containing the list of nearby players (within 500 units).
%%% @end
%%%-------------------------------------------------------------------
-module(game_loop).

-behaviour(gen_server).

%% Public API
-export([start_link/0, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TICK_MS, 50).
-define(NEARBY_RADIUS, 500.0).
-define(DOT_CHECK_INTERVAL, 1000).  %% Process DoTs every 1 second
-define(SERVER, ?MODULE).

-record(state, {
    last_dot_tick :: integer()
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    lager:info("Game loop starting, tick=~pms", [?TICK_MS]),
    schedule_tick(),
    {ok, #state{last_dot_tick = erlang:system_time(millisecond)}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    tick(),
    Now = erlang:system_time(millisecond),
    NewState = case Now - State#state.last_dot_tick >= ?DOT_CHECK_INTERVAL of
        true ->
            process_dots(),
            State#state{last_dot_tick = Now};
        false ->
            State
    end,
    schedule_tick(),
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec schedule_tick() -> reference().
schedule_tick() ->
    erlang:send_after(?TICK_MS, self(), tick).

-spec tick() -> ok.
tick() ->
    Players = player_registry:all_players(),
    lists:foreach(fun(Player) -> send_state_update(Player, Players) end, Players).

-spec send_state_update(player:player(), [player:player()]) -> ok.
send_state_update(Player, AllPlayers) ->
    Pid = player:pid(Player),
    case Pid of
        undefined ->
            ok;
        _ ->
            Px = player:x(Player),
            Py = player:y(Player),
            Nearby = lists:filter(
                fun(Other) ->
                    distance_sq(Px, Py, player:x(Other), player:y(Other)) =<
                        ?NEARBY_RADIUS * ?NEARBY_RADIUS
                end,
                AllPlayers
            ),
            NearbyMaps = [player:to_map(P) || P <- Nearby],
            Pid ! {state_update, NearbyMaps},
            ok
    end.

-spec distance_sq(float(), float(), float(), float()) -> float().
distance_sq(X1, Y1, X2, Y2) ->
    Dx = X2 - X1,
    Dy = Y2 - Y1,
    Dx * Dx + Dy * Dy.

%%--------------------------------------------------------------------
%% @doc Process DoT effects on all players. Applies accumulated
%% damage, broadcasts damage events, and handles DoT kills.
%% @end
%%--------------------------------------------------------------------
-spec process_dots() -> ok.
process_dots() ->
    Players = player_registry:all_players(),
    lists:foreach(fun process_player_dots/1, Players).

-spec process_player_dots(player:player()) -> ok.
process_player_dots(Player) ->
    {Updated, DotDmg} = player:tick_dots(Player),
    case DotDmg > 0.0 of
        true ->
            PlayerId = player:id(Updated),
            player_registry:update_player(PlayerId, Updated),
            %% Broadcast DoT damage as a combat event
            Event = jsx:encode(#{
                type       => <<"combat_event">>,
                attackerId => <<"dot">>,
                defenderId => PlayerId,
                damage     => DotDmg
            }),
            web_broadcaster:broadcast(Event),
            %% Handle DoT kill
            case player:hp(Updated) =< +0.0 of
                true ->
                    Dead = player:add_death(Updated),
                    player_registry:update_player(PlayerId, Dead);
                false ->
                    ok
            end;
        false ->
            ok
    end.
