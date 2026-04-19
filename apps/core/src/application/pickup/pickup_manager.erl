%%%-------------------------------------------------------------------
%%% @doc Pickup manager gen_server.
%%%
%%% Spawns and tracks up to MAX_PICKUPS health pickups scattered
%%% around the world. Each pickup restores HEAL_AMOUNT HP (capped at
%%% the player's max_hp) when a player passes within PICKUP_RADIUS.
%%% Consumed pickups respawn after RESPAWN_MS so the map never has
%%% more than MAX_PICKUPS active and takes a visible amount of time
%%% to refill after a wave of players sweep through.
%%%
%%% Pickup positions avoid landing inside a PLAYER_CLEARANCE radius
%%% of any currently-connected player at spawn time. If the random
%%% sampler cannot find a free slot after MAX_SAMPLE_ATTEMPTS tries
%%% we accept the last candidate — better to spawn slightly off than
%%% to never spawn at all in a crowded map.
%%% @end
%%%-------------------------------------------------------------------
-module(pickup_manager).

-behaviour(gen_server).

%% Public API
-export([start_link/0,
         get_all/0,
         try_consume/2,
         heal_amount/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(MAX_PICKUPS, 5).
-define(HEAL_AMOUNT, 40.0).
-define(PICKUP_RADIUS, 25.0).     %% collision radius vs player position
-define(PLAYER_CLEARANCE, 80.0).  %% avoid spawning within this of a player
-define(RESPAWN_MS, 60_000).      %% 1 minute after consumption
-define(SPAWN_MARGIN, 100).       %% keep pickups off the world edge
-define(MAX_SAMPLE_ATTEMPTS, 20).

-record(state, {
    %% Active pickups: #{PickupId => {X, Y}}.
    pickups = #{} :: #{binary() => {float(), float()}}
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc Return all currently-active pickups as a list of maps:
%% `[#{id => Id, x => X, y => Y}]'.
%% @end
%%--------------------------------------------------------------------
-spec get_all() -> [map()].
get_all() ->
    try gen_server:call(?SERVER, get_all, 100)
    catch _:_ -> []
    end.

%%--------------------------------------------------------------------
%% @doc Test whether the player at (X, Y) overlaps any pickup. For
%% each pickup consumed the caller is returned a list of pickup ids
%% so they can broadcast / react. The pickups are removed atomically
%% and a respawn is scheduled for RESPAWN_MS later.
%% @end
%%--------------------------------------------------------------------
-spec try_consume(float(), float()) -> [binary()].
try_consume(X, Y) ->
    try gen_server:call(?SERVER, {try_consume, X, Y}, 100)
    catch _:_ -> []
    end.

%%--------------------------------------------------------------------
%% @doc Heal amount applied when a pickup is consumed. Exposed so
%% callers (game_loop) don't duplicate the constant.
%% @end
%%--------------------------------------------------------------------
-spec heal_amount() -> float().
heal_amount() -> ?HEAL_AMOUNT.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    %% Seed the map at startup. Players haven't joined yet so the
    %% "avoid players" check is trivially satisfied.
    Initial = lists:foldl(
        fun(_, Acc) -> spawn_one(Acc) end,
        #{},
        lists:seq(1, ?MAX_PICKUPS)
    ),
    lager:info("Pickup manager started with ~p pickups", [map_size(Initial)]),
    {ok, #state{pickups = Initial}}.

handle_call(get_all, _From, #state{pickups = Pickups} = State) ->
    List = [#{id => Id, x => X, y => Y}
            || {Id, {X, Y}} <- maps:to_list(Pickups)],
    {reply, List, State};
handle_call({try_consume, PlayerX, PlayerY}, _From,
            #state{pickups = Pickups} = State) ->
    R2 = ?PICKUP_RADIUS * ?PICKUP_RADIUS,
    {Consumed, Remaining} = maps:fold(
        fun(Id, {Px, Py}, {Acc, KeepAcc}) ->
            Dx = PlayerX - Px,
            Dy = PlayerY - Py,
            case Dx * Dx + Dy * Dy =< R2 of
                true  -> {[Id | Acc], KeepAcc};
                false -> {Acc, maps:put(Id, {Px, Py}, KeepAcc)}
            end
        end,
        {[], #{}},
        Pickups
    ),
    case Consumed of
        [] -> ok;
        _  ->
            lager:info("Consumed ~p pickups, respawn in ~pms",
                       [length(Consumed), ?RESPAWN_MS]),
            erlang:send_after(?RESPAWN_MS, self(),
                              {respawn_batch, length(Consumed)})
    end,
    {reply, Consumed, State#state{pickups = Remaining}};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Respawn N pickups, one per consumed entry. We top up to MAX_PICKUPS
%% as a safety net in case anything got out of sync.
handle_info({respawn_batch, N}, #state{pickups = Pickups} = State) ->
    Target = min(?MAX_PICKUPS, map_size(Pickups) + N),
    Needed = max(0, Target - map_size(Pickups)),
    New = lists:foldl(
        fun(_, Acc) -> spawn_one(Acc) end,
        Pickups,
        lists:seq(1, Needed)
    ),
    case Needed of
        0 -> ok;
        _ -> lager:info("Respawned ~p pickups (total=~p)",
                        [Needed, map_size(New)])
    end,
    {noreply, State#state{pickups = New}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec spawn_one(#{binary() => {float(), float()}}) ->
    #{binary() => {float(), float()}}.
spawn_one(Pickups) ->
    Id = generate_id(),
    {X, Y} = find_spawn_position(),
    maps:put(Id, {X, Y}, Pickups).

-spec generate_id() -> binary().
generate_id() ->
    <<"pk_", (base64:encode(crypto:strong_rand_bytes(6)))/binary>>.

-spec find_spawn_position() -> {float(), float()}.
find_spawn_position() ->
    find_spawn_position(?MAX_SAMPLE_ATTEMPTS).

find_spawn_position(0) ->
    %% Give up and accept any random point. Unlikely with 5 pickups
    %% and an 80u clearance on a 2000x2000 world.
    random_position();
find_spawn_position(Attempts) ->
    Candidate = random_position(),
    case is_clear_of_players(Candidate) of
        true  -> Candidate;
        false -> find_spawn_position(Attempts - 1)
    end.

-spec random_position() -> {float(), float()}.
random_position() ->
    {W, H} = world:bounds(),
    X = float(?SPAWN_MARGIN + rand:uniform(W - 2 * ?SPAWN_MARGIN)),
    Y = float(?SPAWN_MARGIN + rand:uniform(H - 2 * ?SPAWN_MARGIN)),
    {X, Y}.

-spec is_clear_of_players({float(), float()}) -> boolean().
is_clear_of_players({X, Y}) ->
    R2 = ?PLAYER_CLEARANCE * ?PLAYER_CLEARANCE,
    Players = safe_all_players(),
    not lists:any(
        fun(P) ->
            Dx = player:x(P) - X,
            Dy = player:y(P) - Y,
            Dx * Dx + Dy * Dy < R2
        end,
        Players
    ).

%% player_registry may not be available during init if startup order
%% changes; fall back to no players so spawn still succeeds.
-spec safe_all_players() -> [player:player()].
safe_all_players() ->
    try player_registry:all_players()
    catch _:_ -> []
    end.
