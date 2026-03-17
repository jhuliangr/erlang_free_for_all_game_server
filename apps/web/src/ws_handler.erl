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
%%%   state_update  – {"type":"state_update","players":[...]}
%%%   combat_event  – {"type":"combat_event","attackerId":"...","defenderId":"...","damage":10}
%%% @end
%%%-------------------------------------------------------------------
-module(ws_handler).

-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

-record(state, {
    player_id :: binary() | undefined
}).

%%--------------------------------------------------------------------
%% @doc Upgrade HTTP connection to WebSocket.
%% @end
%%--------------------------------------------------------------------
init(Req, _Opts) ->
    {cowboy_websocket, Req, #state{player_id = undefined},
     #{idle_timeout => 60000}}.

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
websocket_info({state_update, Players}, State) ->
    Msg = jsx:encode(#{type => <<"state_update">>, players => Players}),
    {reply, {text, Msg}, State};

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
    web_broadcaster:unregister_ws(PlayerId),
    player_use_cases:leave_game(PlayerId),
    lager:info("WebSocket terminated for player ~s", [PlayerId]),
    ok.

%%--------------------------------------------------------------------
%% Internal: dispatch decoded JSON messages
%%--------------------------------------------------------------------

handle_message(#{<<"type">> := <<"join">>, <<"name">> := Name}, State) ->
    PlayerId = base64:encode(crypto:strong_rand_bytes(8)),
    {ok, Player} = player_use_cases:join_game(PlayerId, Name),
    %% Register this pid with the registry and broadcaster
    player_registry:update_player(PlayerId,
        player:set_pid(Player, self())),
    web_broadcaster:register_ws(PlayerId, self()),
    Welcome = jsx:encode(#{
        type     => <<"welcome">>,
        playerId => PlayerId,
        player   => player:to_map(player:set_pid(Player, self()))
    }),
    lager:info("Player ~s joined as ~s", [PlayerId, Name]),
    {reply, {text, Welcome}, State#state{player_id = PlayerId}};

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
        <<"skin">>   -> skin;
        <<"weapon">> -> weapon;
        _            -> skin
    end,
    player_use_cases:equip_cosmetic(PlayerId, Slot, ItemId),
    {ok, State};

handle_message(_Unknown, State) ->
    ErrorReply = jsx:encode(#{type => <<"error">>, reason => <<"unknown_message_type">>}),
    {reply, {text, ErrorReply}, State}.

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
