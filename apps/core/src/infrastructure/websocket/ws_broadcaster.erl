%%%-------------------------------------------------------------------
%%% @doc WebSocket broadcaster infrastructure module.
%%%
%%% Thin facade over web_broadcaster that encodes messages to JSON
%%% before dispatching. Domain and application layers call this
%%% module; it knows about jsx but nothing about cowboy internals.
%%% @end
%%%-------------------------------------------------------------------
-module(ws_broadcaster).

-export([broadcast/1, send_to/2]).

%%--------------------------------------------------------------------
%% @doc Broadcast a map message to all connected WebSocket clients.
%% The message is JSON-encoded before sending.
%% @end
%%--------------------------------------------------------------------
-spec broadcast(map()) -> ok.
broadcast(Message) ->
    Encoded = jsx:encode(Message),
    web_broadcaster:broadcast(Encoded).

%%--------------------------------------------------------------------
%% @doc Send a map message to a specific player's WebSocket client.
%% @end
%%--------------------------------------------------------------------
-spec send_to(binary(), map()) -> ok.
send_to(PlayerId, Message) ->
    Encoded = jsx:encode(Message),
    web_broadcaster:send_to(PlayerId, Encoded).
