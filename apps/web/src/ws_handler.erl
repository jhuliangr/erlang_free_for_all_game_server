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
%%%   move    – {"type":"move","dx":0.5,"dy":-0.3}
%%%   attack  – {"type":"attack","angle":1.57}
%%%   equip   – {"type":"equip","slot":"skin","itemId":"skin_fire"}
%%%
%%% Outgoing message types:
%%%   welcome       – {"type":"welcome","playerId":"..."}
%%%   state_update  – {"type":"state_update","players":[...diffs...],"removed":[...ids...]}
%%%   combat_event  – {"type":"combat_event","attackerId":"...","defenderId":"...","damage":10}
%%%
%%% state_update diff protocol:
%%%   Each entry in "players" always contains "id". For a player seen
%%%   for the first time (or after re-entering range) all fields are
%%%   included. On subsequent ticks only fields whose value changed
%%%   since the last sent state are included.
%%%   "removed" lists IDs of players that were visible last tick but
%%%   are no longer within the nearby radius.
%%% @end
%%%-------------------------------------------------------------------
-module(ws_handler).

-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

-record(state, {
    player_id    :: binary() | undefined,
    player_cache :: map()               %% PlayerId => last-sent player map
}).

%%--------------------------------------------------------------------
%% @doc Upgrade HTTP connection to WebSocket.
%% @end
%%--------------------------------------------------------------------
init(Req, _Opts) ->
    {cowboy_websocket, Req,
     #state{player_id = undefined, player_cache = #{}},
     #{idle_timeout => 60000, compress => true}}.

%%--------------------------------------------------------------------
%% @doc WebSocket handshake complete.
%% @end
%%--------------------------------------------------------------------
websocket_init(State) ->
    lager:info("WebSocket connection established", []),
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
websocket_info({state_update, Players}, #state{player_cache = Cache} = State) ->
    Diffs = [diff_player(P, maps:get(maps:get(id, P), Cache, undefined)) || P <- Players],

    CurrentIds = [maps:get(id, P) || P <- Players],
    Removed = [Id || Id <- maps:keys(Cache), not lists:member(Id, CurrentIds)],

    NewCache = maps:from_list([{maps:get(id, P), P} || P <- Players]),

    Msg = jsx:encode(#{
        type    => <<"state_update">>,
        players => Diffs,
        removed => Removed
    }),
    {reply, {text, Msg}, State#state{player_cache = NewCache}};

websocket_info({send, Msg}, State) ->
    {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc Clean up when the WebSocket is closed.
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _Req, #state{player_id = undefined}) ->
    ok;
terminate(_Reason, _Req, #state{player_id = PlayerId}) ->
    %% Only clean up if this process is still the active connection.
    %% A reconnect may have already replaced us with a new WS pid.
    case player_registry:get_player(PlayerId) of
        {ok, Player} ->
            case player:pid(Player) =:= self() of
                true ->
                    web_broadcaster:unregister_ws(PlayerId),
                    player_use_cases:leave_game(PlayerId),
                    lager:info("WebSocket terminated for player ~s", [PlayerId]);
                false ->
                    lager:info("Stale WebSocket closed for player ~s (reconnected)", [PlayerId])
            end;
        {error, not_found} ->
            ok
    end,
    ok.

%%--------------------------------------------------------------------
%% Internal: dispatch decoded JSON messages
%%--------------------------------------------------------------------

handle_message(#{<<"type">> := <<"join">>, <<"name">> := Name} = Msg, State) ->
    RequestedId = maps:get(<<"playerId">>, Msg, undefined),
    {PlayerId, Player} = case RequestedId of
        undefined ->
            NewId = base64:encode(crypto:strong_rand_bytes(8)),
            {ok, P} = player_use_cases:join_game(NewId, Name),
            {NewId, P};
        _ ->
            case player_registry:get_player(RequestedId) of
                {ok, Existing} ->
                    lager:info("Player ~s reconnecting", [RequestedId]),
                    {RequestedId, Existing};
                {error, not_found} ->
                    NewId = base64:encode(crypto:strong_rand_bytes(8)),
                    {ok, P} = player_use_cases:join_game(NewId, Name),
                    {NewId, P}
            end
    end,
    Updated = player:set_pid(Player, self()),
    player_registry:update_player(PlayerId, Updated),
    web_broadcaster:register_ws(PlayerId, self()),
    Welcome = jsx:encode(#{
        type     => <<"welcome">>,
        playerId => PlayerId,
        player   => player:to_map(Updated)
    }),
    lager:info("Player ~s joined as ~s", [PlayerId, Name]),
    {reply, {text, Welcome}, State#state{player_id = PlayerId, player_cache = #{}}};

handle_message(#{<<"type">> := <<"move">>, <<"dx">> := Dx, <<"dy">> := Dy},
               #state{player_id = PlayerId} = State)
  when PlayerId =/= undefined ->
    case player_registry:get_player(PlayerId) of
        {ok, Player} ->
            Moved   = player:move(Player, float(Dx), float(Dy)),
            Moved2  = player:set_pid(Moved, self()),
            player_registry:update_player(PlayerId, Moved2),
            spatial_index:update(PlayerId, player:x(Moved2), player:y(Moved2));
        {error, not_found} ->
            ok
    end,
    {ok, State};

handle_message(#{<<"type">> := <<"attack">>, <<"angle">> := Angle},
               #state{player_id = PlayerId} = State)
  when PlayerId =/= undefined ->
    case player_registry:get_player(PlayerId) of
        {ok, Attacker} ->
            NearbyIds = spatial_index:query_nearby(
                player:x(Attacker), player:y(Attacker), 150.0),
            {ok, Hits} = process_attack:execute(PlayerId, float(Angle), NearbyIds),
            broadcast_combat_events(PlayerId, Hits);
        {error, not_found} ->
            ok
    end,
    {ok, State};

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
