%%%-------------------------------------------------------------------
%%% @doc Game loop gen_server.
%%%
%%% Drives the authoritative server tick at 50 ms intervals. On each
%%% tick every connected player receives a `state_update` message with
%%% the tick number, server timestamp, and the list of visible players
%%% tiered by distance:
%%%
%%%   near (< NEAR_RADIUS)   — included every tick      (full rate)
%%%   mid  (< FAR_RADIUS)    — included every Nth tick  (throttled)
%%%   far  (>= FAR_RADIUS)   — omitted
%%%
%%% The tick counter and server timestamp travel with every outgoing
%%% message so clients can reconcile inputs and measure round-trip
%%% latency without relying on wall-clock sync.
%%% @end
%%%-------------------------------------------------------------------
-module(game_loop).

-behaviour(gen_server).

%% Public API
-export([start_link/0, stop/0, current_tick/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TICK_MS, 50).
-define(NEAR_RADIUS, 250.0).
-define(FAR_RADIUS, 500.0).
-define(MID_THROTTLE, 3).  %% mid-range players refreshed every 3rd tick
-define(DOT_CHECK_INTERVAL, 1000).  %% Process DoTs every 1 second
-define(SERVER, ?MODULE).

-record(state, {
    last_dot_tick :: integer(),
    tick          :: non_neg_integer()
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
%% @doc Read the current tick counter. Used by lag compensation.
%% @end
%%--------------------------------------------------------------------
-spec current_tick() -> non_neg_integer().
current_tick() ->
    try gen_server:call(?SERVER, current_tick, 100)
    catch _:_ -> 0
    end.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    lager:info("Game loop starting, tick=~pms near=~p far=~p",
               [?TICK_MS, ?NEAR_RADIUS, ?FAR_RADIUS]),
    schedule_tick(),
    {ok, #state{last_dot_tick = erlang:system_time(millisecond), tick = 0}}.

handle_call(current_tick, _From, #state{tick = T} = State) ->
    {reply, T, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, #state{tick = T} = State) ->
    NextTick = T + 1,
    tick(NextTick),
    Now = erlang:system_time(millisecond),
    NewState = case Now - State#state.last_dot_tick >= ?DOT_CHECK_INTERVAL of
        true ->
            process_dots(),
            State#state{last_dot_tick = Now};
        false ->
            State
    end,
    schedule_tick(),
    {noreply, NewState#state{tick = NextTick}};
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

-spec tick(non_neg_integer()) -> ok.
tick(TickN) ->
    AllPlayers = player_registry:all_players(),
    %% Snapshot positions for lag-compensation rewind. Include
    %% disconnected players too: an attack can legitimately target
    %% someone whose WS dropped mid-swing during the grace period.
    player_history:snapshot(TickN, AllPlayers),
    %% Only include connected players (pid =/= undefined) in state updates.
    %% Disconnected players in their grace period should be invisible.
    Connected = [P || P <- AllPlayers, player:pid(P) =/= undefined],
    %% Process pickup pickups BEFORE building state updates so that
    %% any heals land in the same frame the pickup disappears.
    Healed = process_pickups(Connected),
    Pickups = pickup_manager:get_all(),
    Now = erlang:system_time(millisecond),
    lists:foreach(
      fun(Player) -> send_state_update(Player, Healed, Pickups, TickN, Now) end,
      Healed
    ).

-spec process_pickups([player:player()]) -> [player:player()].
process_pickups(Players) ->
    lists:map(
      fun(P) ->
          case pickup_manager:try_consume(player:x(P), player:y(P)) of
              [] -> P;
              Consumed ->
                  Heal = pickup_manager:heal_amount() * length(Consumed),
                  Healed = player:heal(P, Heal),
                  player_registry:update_player(player:id(P), Healed),
                  Healed
          end
      end,
      Players
    ).

-spec send_state_update(player:player(), [player:player()], [map()],
                        non_neg_integer(), integer()) -> ok.
send_state_update(Player, AllPlayers, Pickups, TickN, Now) ->
    Pid = player:pid(Player),
    case Pid of
        undefined ->
            ok;
        _ ->
            Px = player:x(Player),
            Py = player:y(Player),
            {Near, Mid} = partition_by_distance(Px, Py, AllPlayers),
            Visible = case TickN rem ?MID_THROTTLE =:= 0 of
                true  -> Near ++ Mid;
                false -> Near
            end,
            NearbyMaps = [player:to_map(P) || P <- Visible],
            Pid ! {state_update, NearbyMaps, Pickups, TickN, Now},
            ok
    end.

-spec partition_by_distance(float(), float(), [player:player()]) ->
    {[player:player()], [player:player()]}.
partition_by_distance(Px, Py, Players) ->
    NearSq = ?NEAR_RADIUS * ?NEAR_RADIUS,
    FarSq  = ?FAR_RADIUS * ?FAR_RADIUS,
    lists:foldl(
      fun(Other, {NearAcc, MidAcc}) ->
          D2 = distance_sq(Px, Py, player:x(Other), player:y(Other)),
          if
              D2 =< NearSq -> {[Other | NearAcc], MidAcc};
              D2 =< FarSq  -> {NearAcc, [Other | MidAcc]};
              true         -> {NearAcc, MidAcc}
          end
      end,
      {[], []},
      Players
    ).

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
    {Updated, Hits} = player:tick_dots(Player),
    case Hits of
        [] ->
            ok;
        _ ->
            PlayerId = player:id(Updated),
            player_registry:update_player(PlayerId, Updated),
            %% One combat_event per DoT source so the client can
            %% credit each tick to the player who originally applied
            %% the DoT. `attackerId` stays as the <<"dot">> sentinel
            %% (clients rely on it to style/skip these events);
            %% `sourceId` carries the real applier.
            lists:foreach(
                fun({ApplierId, Dmg}) ->
                    Event = jsx:encode(#{
                        type       => <<"combat_event">>,
                        attackerId => <<"dot">>,
                        sourceId   => ApplierId,
                        defenderId => PlayerId,
                        damage     => Dmg
                    }),
                    web_broadcaster:broadcast(Event)
                end,
                Hits
            ),
            %% Handle DoT kill: record death, persist, then remove
            %% from the registry and spatial index.
            case player:hp(Updated) =< +0.0 of
                true ->
                    Dead = player:add_death(Updated),
                    player_registry:update_player(PlayerId, Dead),
                    player_use_cases:kill_player(PlayerId);
                false ->
                    ok
            end
    end.
