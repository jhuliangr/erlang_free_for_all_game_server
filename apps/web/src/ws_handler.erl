%%%-------------------------------------------------------------------
%%% @doc Cowboy WebSocket handler.
%%%
%%% One process per connected client. Handles the full lifecycle of a
%%% player session: joining, moving, attacking, equipping cosmetics,
%%% and disconnecting. All incoming messages are JSON; all outgoing
%%% messages are JSON.
%%%
%%% Incoming message types:
%%%   join    – {"type":"join","name":"Player1"}
%%%   move    – {"type":"move","dx":0.5,"dy":-0.3,"clientTick":42}
%%%   attack  – {"type":"attack","angle":1.57,"clientTick":42}
%%%   equip   – {"type":"equip","slot":"skin","itemId":"skin_fire"}
%%%
%%% `clientTick` is optional on move/attack. When present it is echoed
%%% back on the next `state_update` as `ackTick`, letting the client
%%% reconcile locally predicted state against server-confirmed state.
%%% Attacks may also include `clientTick` to trigger lag-compensated
%%% hit detection against the server's snapshot at that tick.
%%%
%%% Outgoing message types:
%%%   welcome       – {"type":"welcome","playerId":"...","serverTick":N,"serverTime":T}
%%%   state_update  – {"type":"state_update","players":[...diffs...],
%%%                    "removed":[...ids...],"tick":N,"serverTime":T,
%%%                    "ackTick":CT}
%%%   combat_event  – {"type":"combat_event","attackerId":"...","defenderId":"...","damage":10}
%%%
%%% state_update diff protocol:
%%%   Each entry in "players" always contains "id". For a player seen
%%%   for the first time (or after re-entering range) all fields are
%%%   included. On subsequent ticks only fields whose value changed
%%%   since the last sent state are included.
%%%   "removed" lists IDs of players that were visible last tick but
%%%   are no longer within the visible radius (or were throttled out
%%%   of this tick because they are mid-range; see game_loop).
%%%
%%% Anti-cheat controls enforced here:
%%%   - Move commands are rate-limited to ~25/sec per connection
%%%     (MOVE_MIN_INTERVAL_MS = 40) — excess inputs are silently
%%%     dropped. The authoritative 200u/s speed cap lives in
%%%     player:move/3 (max 10 units per accepted move).
%%%   - Attack cooldown is enforced per character in player:can_attack/1.
%%% @end
%%%-------------------------------------------------------------------
-module(ws_handler).

-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

%% Minimum milliseconds between accepted move inputs (DoS guard).
%% The authoritative speed cap is enforced by player:move/4 using a
%% time-based step (max MAX_SPEED * dt per accepted move), so this
%% interval only exists to cap connection work under flood. It is set
%% well below the client's self-throttle (40ms) to absorb network
%% jitter without silently dropping honest inputs — dropping a move
%% that the client predicted locally causes visible retrace.
-define(MOVE_MIN_INTERVAL_MS, 25).

%% Authoritative speed cap (units/sec). Enforced by computing the
%% per-move step as min(MAX_STEP_CAP, MAX_SPEED * dt_since_last_move).
-define(MAX_SPEED, 200.0).
%% Absolute cap per single accepted move. Prevents teleport when dt is
%% very large (long idle, first move after join).
-define(MAX_STEP_CAP, 10.0).

-record(state, {
    player_id        :: binary() | undefined,
    player_cache     :: map(),              %% PlayerId => last-sent player map
    last_move_at     :: integer(),          %% ms, for move rate limiting
    last_client_tick :: integer() | undefined
}).

%%--------------------------------------------------------------------
%% @doc Upgrade HTTP connection to WebSocket.
%%
%% `compress => false`: permessage-deflate adds CPU + latency on the
%% server's high-frequency small frames (20Hz state_update). We reserve
%% compression for application-level use on large payloads (see
%% encode_state_update/1).
%% @end
%%--------------------------------------------------------------------
init(Req, _Opts) ->
    {cowboy_websocket, Req,
     #state{player_id        = undefined,
            player_cache     = #{},
            last_move_at     = 0,
            last_client_tick = undefined},
     #{idle_timeout => 5000, compress => false}}.

%%--------------------------------------------------------------------
%% @doc WebSocket handshake complete.
%% @end
%%--------------------------------------------------------------------
websocket_init(State) ->
    lager:info("WebSocket connection established", []),
    schedule_ping(),
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Handle incoming text frames.
%% @end
%%--------------------------------------------------------------------
websocket_handle({text, Data}, State) ->
    try
        Msg = jsx:decode(Data, [return_maps]),
        handle_message(Msg, State)
    catch
        _:_ ->
            ErrorReply = jsx:encode(#{type => <<"error">>, reason => <<"invalid_json">>}),
            {reply, {text, ErrorReply}, State}
    end;
websocket_handle({ping, _}, State) ->
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Handle Erlang messages sent to this process.
%% @end
%%--------------------------------------------------------------------
websocket_info({state_update, Players, Pickups, Tick, ServerTime},
               #state{player_cache = Cache, last_client_tick = LastCT} = State) ->
    Diffs = [diff_player(P, maps:get(maps:get(id, P), Cache, undefined)) || P <- Players],

    CurrentIds = [maps:get(id, P) || P <- Players],
    Removed = [Id || Id <- maps:keys(Cache), not lists:member(Id, CurrentIds)],

    NewCache = maps:from_list([{maps:get(id, P), P} || P <- Players]),

    Base = #{
        type       => <<"state_update">>,
        players    => Diffs,
        removed    => Removed,
        pickups    => Pickups,
        tick       => Tick,
        serverTime => ServerTime
    },
    Payload = case LastCT of
        undefined -> Base;
        _         -> Base#{ackTick => LastCT}
    end,
    Msg = jsx:encode(Payload),
    {reply, {text, Msg}, State#state{player_cache = NewCache}};

websocket_info({send, Msg}, State) ->
    {reply, {text, Msg}, State};

websocket_info({kick, Reason}, State) ->
    %% Sent by a newer ws_handler that is taking over this player's
    %% session. We notify the client with a `kicked` frame then close
    %% the connection. The new handler has already set the player's
    %% pid to itself, so when this process terminates the broadcaster's
    %% DOWN handler will see the mismatch and skip the grace period.
    ReasonBin = case Reason of
        B when is_binary(B) -> B;
        A when is_atom(A)   -> atom_to_binary(A, utf8);
        _                   -> <<"kicked">>
    end,
    Payload = jsx:encode(#{type => <<"kicked">>, reason => ReasonBin}),
    {reply, [{text, Payload}, {close, 4000, ReasonBin}], State};

websocket_info(send_ping, State) ->
    schedule_ping(),
    {reply, ping, State};

websocket_info(_Info, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Clean up when the WebSocket is closed.
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _Req, #state{player_id = undefined}) ->
    ok;
terminate(_Reason, _Req, #state{player_id = PlayerId}) ->
    %% Do NOT call leave_game here. The web_broadcaster DOWN handler
    %% will start a 5-second grace period. If the player reconnects
    %% within that window their state (position, HP, etc.) is preserved.
    %% If they don't, web_broadcaster removes them after the timeout.
    lager:info("WebSocket closed for player ~s (grace period managed by broadcaster)", [PlayerId]),
    ok.

%%--------------------------------------------------------------------
%% Internal: dispatch decoded JSON messages
%%--------------------------------------------------------------------

handle_message(#{<<"type">> := <<"join">>, <<"name">> := Name} = Msg, State) ->
    RequestedId = maps:get(<<"playerId">>, Msg, undefined),
    CharacterId = maps:get(<<"character">>, Msg, <<"knight">>),
    Self = self(),
    {PlayerId, Player, OldPid} = case RequestedId of
        undefined ->
            NewId = base64:encode(crypto:strong_rand_bytes(8)),
            {ok, P} = player_use_cases:join_game(NewId, Name, CharacterId),
            {NewId, P, undefined};
        _ ->
            case player_registry:get_player(RequestedId) of
                {ok, Existing} ->
                    %% Reconnecting — preserve position, HP, level, etc.
                    %% Capture the prior owner so we can kick it after
                    %% we've claimed the pid slot.
                    lager:info("Player ~s reconnecting (preserving state)", [RequestedId]),
                    Reconnected = player:equip(Existing, character, CharacterId),
                    {RequestedId, Reconnected, player:pid(Existing)};
                {error, not_found} ->
                    %% Player was already removed (timeout expired) — fresh start
                    NewId = base64:encode(crypto:strong_rand_bytes(8)),
                    {ok, P} = player_use_cases:join_game(NewId, Name, CharacterId),
                    {NewId, P, undefined}
            end
    end,
    Updated = player:set_pid(Player, Self),
    player_registry:update_player(PlayerId, Updated),
    %% Session takeover: if another live ws_handler was owning this
    %% player, kick it *after* we've persisted our own pid. Order
    %% matters — web_broadcaster's DOWN handler will only start a
    %% grace period if the exiting pid still matches the registry's
    %% pid, so claiming first prevents a spurious grace timer.
    case OldPid of
        undefined -> ok;
        Self      -> ok;
        _         ->
            lager:info("Player ~s: session takeover, kicking old pid ~p",
                       [PlayerId, OldPid]),
            OldPid ! {kick, duplicate_session}
    end,
    web_broadcaster:register_ws(PlayerId, Self),
    Welcome = jsx:encode(#{
        type       => <<"welcome">>,
        playerId   => PlayerId,
        player     => player:to_map(Updated),
        serverTick => game_loop:current_tick(),
        serverTime => erlang:system_time(millisecond)
    }),
    lager:info("Player ~s joined as ~s", [PlayerId, Name]),
    {reply, {text, Welcome},
     State#state{player_id = PlayerId,
                 player_cache = #{},
                 last_move_at = 0,
                 last_client_tick = undefined}};

handle_message(#{<<"type">> := <<"move">>, <<"dx">> := Dx, <<"dy">> := Dy} = Msg,
               #state{player_id = PlayerId, last_move_at = LastAt} = State)
  when PlayerId =/= undefined ->
    Now = erlang:system_time(millisecond),
    CT  = optional_tick(Msg),
    case Now - LastAt >= ?MOVE_MIN_INTERVAL_MS of
        false ->
            %% Drop: client exceeded the input rate. Do NOT advance
            %% last_client_tick — if we did, the next state_update's
            %% ackTick would cover a tick the server never applied, and
            %% the client's reconciliation would discard the matching
            %% pending input from its replay buffer. That shows up on
            %% screen as the local player pausing or stepping backward
            %% while walking in a straight line.
            {ok, State};
        true ->
            NextCT = update_client_tick(State#state.last_client_tick, CT),
            %% Time-based step cap: the distance applied per accepted
            %% move is bounded by MAX_SPEED * dt, so the total distance
            %% per second cannot exceed MAX_SPEED regardless of how
            %% many inputs slip through the rate limit. Absolute per-
            %% move cap of MAX_STEP_CAP prevents teleport on the first
            %% move after a long pause (when dt is huge).
            DtMs   = Now - LastAt,
            MaxStep = erlang:min(?MAX_STEP_CAP, ?MAX_SPEED * DtMs / 1000.0),
            case player_registry:get_player(PlayerId) of
                {ok, Player} ->
                    Moved  = player:move(Player, float(Dx), float(Dy), MaxStep),
                    Moved2 = player:set_pid(Moved, self()),
                    player_registry:update_player(PlayerId, Moved2),
                    spatial_index:update(PlayerId, player:x(Moved2), player:y(Moved2));
                {error, not_found} ->
                    ok
            end,
            {ok, State#state{last_move_at = Now, last_client_tick = NextCT}}
    end;

handle_message(#{<<"type">> := <<"attack">>, <<"angle">> := Angle} = Msg,
               #state{player_id = PlayerId} = State)
  when PlayerId =/= undefined ->
    CT     = optional_tick(Msg),
    NextCT = update_client_tick(State#state.last_client_tick, CT),
    case player_registry:get_player(PlayerId) of
        {ok, Attacker} ->
            Range = character_stats:attack_range(player:character(Attacker)),
            %% For lag-compensated attacks we widen the query a bit to
            %% catch defenders who have since moved out of range.
            QueryRadius = Range * 1.25,
            NearbyIds = spatial_index:query_nearby(
                player:x(Attacker), player:y(Attacker), QueryRadius),
            case process_attack:execute(PlayerId, float(Angle), NearbyIds, CT) of
                {ok, Hits} ->
                    broadcast_combat_events(PlayerId, Hits);
                {error, cooldown} ->
                    ok;
                {error, _} ->
                    ok
            end;
        {error, not_found} ->
            ok
    end,
    {ok, State#state{last_client_tick = NextCT}};

handle_message(#{<<"type">> := <<"equip">>,
                 <<"slot">>  := SlotBin,
                 <<"itemId">> := ItemId},
               #state{player_id = PlayerId} = State)
  when PlayerId =/= undefined ->
    Slot = case SlotBin of
        <<"skin">>      -> skin;
        <<"weapon">>    -> weapon;
        <<"character">> -> character;
        _               -> skin
    end,
    player_use_cases:equip_cosmetic(PlayerId, Slot, ItemId),
    {ok, State};

handle_message(_Unknown, State) ->
    ErrorReply = jsx:encode(#{type => <<"error">>, reason => <<"unknown_message_type">>}),
    {reply, {text, ErrorReply}, State}.

%%--------------------------------------------------------------------
%% Internal: schedule a WebSocket ping frame every 2.5 seconds.
%% The client auto-responds with pong, which resets cowboy's idle_timeout.
%% If the client is unreachable, no pong arrives and the 5s timeout fires.
%%--------------------------------------------------------------------
schedule_ping() ->
    erlang:send_after(2500, self(), send_ping).

%%--------------------------------------------------------------------
%% Internal: build a diff map.
%%
%% Returns the full map when the player is new (Old = undefined).
%% Otherwise returns a map with only `id` plus the fields whose
%% value differs from the previously sent state.
%%--------------------------------------------------------------------

-spec diff_player(map(), map() | undefined) -> map().
diff_player(New, undefined) ->
    New;
diff_player(New, Old) ->
    maps:fold(
        fun(K, V, Acc) ->
            case maps:get(K, Old, undefined) of
                V -> Acc;
                _ -> Acc#{K => V}
            end
        end,
        #{id => maps:get(id, New)},
        New
    ).

%%--------------------------------------------------------------------
%% Extract optional clientTick from incoming message.
%%--------------------------------------------------------------------
-spec optional_tick(map()) -> integer() | undefined.
optional_tick(Msg) ->
    case maps:get(<<"clientTick">>, Msg, undefined) of
        T when is_integer(T) -> T;
        _                    -> undefined
    end.

%%--------------------------------------------------------------------
%% Keep the most recent client tick (monotonic). Ignores nil and
%% out-of-order (older) values so `ackTick` always reflects the
%% newest confirmed input.
%%--------------------------------------------------------------------
-spec update_client_tick(integer() | undefined, integer() | undefined) ->
    integer() | undefined.
update_client_tick(Current, undefined) -> Current;
update_client_tick(undefined, New)     -> New;
update_client_tick(Current, New) when New >= Current -> New;
update_client_tick(Current, _Older)    -> Current.

%%--------------------------------------------------------------------
%% Broadcast combat events to all involved parties
%%--------------------------------------------------------------------

-spec broadcast_combat_events(binary(), [{binary(), float()}]) -> ok.
broadcast_combat_events(_AttackerId, []) ->
    ok;
broadcast_combat_events(AttackerId, [{DefenderId, Damage} | Rest]) ->
    Event = jsx:encode(#{
        type       => <<"combat_event">>,
        attackerId => AttackerId,
        defenderId => DefenderId,
        damage     => Damage
    }),
    web_broadcaster:broadcast(Event),
    broadcast_combat_events(AttackerId, Rest).
