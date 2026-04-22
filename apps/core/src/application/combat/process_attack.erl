%%%-------------------------------------------------------------------
%%% @doc Process attack application service.
%%%
%%% Orchestrates a player attack: checks cooldown, resolves hits
%%% (instant or DoT) against nearby players, applies damage and
%%% knockback, awards XP to the attacker, and returns hit events.
%%%
%%% Lag compensation: when the caller provides a `ClientTick`, each
%%% defender's range check is run against their snapshot position at
%%% that tick (via player_history). The tick is clamped to the oldest
%%% retained snapshot so clients cannot abuse it to rewind arbitrarily.
%%% Damage application and knockback always use the live state — only
%%% the "was it a hit?" test is rewound.
%%% @end
%%%-------------------------------------------------------------------
-module(process_attack).

-export([execute/3, execute/4]).

-define(XP_PER_KILL, 50.0).

%%--------------------------------------------------------------------
%% @doc Execute an attack without lag compensation.
%% @end
%%--------------------------------------------------------------------
-spec execute(binary(), float(), [binary()]) ->
    {ok, [{binary(), float()}]} | {error, term()}.
execute(AttackerId, Angle, NearbyIds) ->
    execute(AttackerId, Angle, NearbyIds, undefined).

%%--------------------------------------------------------------------
%% @doc Execute an attack from AttackerId at the given Angle.
%%
%% `ClientTick` is an optional non-negative integer: when present the
%% attack uses lag-compensated hit detection.
%%
%% Checks cooldown before proceeding. Returns `{ok, [{DefenderId, Damage}]}`
%% on success, `{error, cooldown}` if on cooldown, or `{error, Reason}`.
%% @end
%%--------------------------------------------------------------------
-spec execute(binary(), float(), [binary()], integer() | undefined) ->
    {ok, [{binary(), float()}]} | {error, term()}.
execute(AttackerId, Angle, NearbyIds, ClientTick) ->
    case player_registry:get_player(AttackerId) of
        {error, not_found} ->
            {error, attacker_not_found};
        {ok, Attacker} ->
            case player:can_attack(Attacker) of
                false ->
                    {error, cooldown};
                true ->
                    Attacker2 = player:record_attack(Attacker),
                    player_registry:update_player(AttackerId, Attacker2),
                    Hits = process_nearby(Attacker2, Angle, NearbyIds, ClientTick, []),
                    award_xp(AttackerId, Attacker2, Hits),
                    Results = [{DId, Dmg} || {DId, Dmg, _Xp} <- Hits],
                    {ok, Results}
            end
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec award_xp(binary(), player:player(), list()) -> ok.
award_xp(AttackerId, Attacker, Hits) ->
    KillCount = length([1 || {_DId, _Dmg, Xp} <- Hits, Xp > +0.0]),
    TotalXp = lists:foldl(fun({_DId, _Dmg, Xp}, Acc) -> Acc + Xp end,
                           +0.0, Hits),
    if
        TotalXp > +0.0 ->
            A1 = player:gain_xp(Attacker, TotalXp),
            A2 = lists:foldl(fun(_, Acc) -> player:add_kill(Acc) end,
                             A1, lists:seq(1, KillCount)),
            player_registry:update_player(AttackerId, A2);
        true ->
            ok
    end.

-spec process_nearby(player:player(), float(), [binary()],
                     integer() | undefined, list()) -> list().
process_nearby(_Attacker, _Angle, [], _Tick, Acc) ->
    Acc;
process_nearby(Attacker, Angle, [DefenderId | Rest], Tick, Acc) ->
    NewAcc = case player:id(Attacker) =:= DefenderId of
        true ->
            Acc;
        false ->
            case player_registry:get_player(DefenderId) of
                {error, not_found} ->
                    Acc;
                {ok, Defender} ->
                    HitXY = hit_position(DefenderId, Defender, Tick),
                    case combat_resolver:resolve_at(Attacker, Defender, Angle, HitXY) of
                        {error, out_of_range} ->
                            Acc;
                        {ok, Damage, KbDx, KbDy} ->
                            apply_instant_hit(DefenderId, Defender, Damage, KbDx, KbDy, Acc);
                        {dot, Dps, Duration, KbDx, KbDy} ->
                            apply_dot_hit(DefenderId, Defender, player:id(Attacker),
                                          Dps, Duration, KbDx, KbDy, Acc)
                    end
            end
    end,
    process_nearby(Attacker, Angle, Rest, Tick, NewAcc).

-spec hit_position(binary(), player:player(), integer() | undefined) ->
    {float(), float()}.
hit_position(_DefenderId, Defender, undefined) ->
    {player:x(Defender), player:y(Defender)};
hit_position(DefenderId, Defender, Tick) when is_integer(Tick), Tick >= 0 ->
    case player_history:position_at(DefenderId, Tick) of
        {ok, XY, _UsedTick} -> XY;
        not_found           -> {player:x(Defender), player:y(Defender)}
    end;
hit_position(_DefenderId, Defender, _Invalid) ->
    {player:x(Defender), player:y(Defender)}.

-spec apply_instant_hit(binary(), player:player(), float(), float(), float(), list()) -> list().
apply_instant_hit(DefenderId, Defender, Damage, KbDx, KbDy, Acc) ->
    %% Guard: if the defender was already at 0 HP we must not apply
    %% damage nor award XP. This can happen when two concurrent attacks
    %% resolve the same victim before the first one's removal has
    %% propagated through player_registry.
    case player:hp(Defender) =< +0.0 of
        true ->
            Acc;
        false ->
            Damaged     = player:take_damage(Defender, Damage),
            KnockedBack = apply_knockback(Damaged, KbDx, KbDy),
            IsKill = player:hp(KnockedBack) =< +0.0,
            Xp = case IsKill of
                true  -> ?XP_PER_KILL;
                false -> 0.0
            end,
            case IsKill of
                true ->
                    %% Record the death on the defender so the session
                    %% stats saved by leave_game reflect it, then remove
                    %% from the registry and spatial index. Removal is
                    %% what prevents the "keep hitting a corpse for XP"
                    %% exploit: the next query_nearby call will not
                    %% return this id.
                    Dead = player:add_death(KnockedBack),
                    player_registry:update_player(DefenderId, Dead),
                    player_use_cases:kill_player(DefenderId);
                false ->
                    player_registry:update_player(DefenderId, KnockedBack),
                    spatial_index:update(DefenderId,
                                         player:x(KnockedBack),
                                         player:y(KnockedBack))
            end,
            lager:info("Hit: defender=~s damage=~p kill=~p",
                       [DefenderId, Damage, IsKill]),
            [{DefenderId, Damage, Xp} | Acc]
    end.

-spec apply_dot_hit(binary(), player:player(), binary(), float(), non_neg_integer(), float(), float(), list()) -> list().
apply_dot_hit(DefenderId, Defender, AttackerId, Dps, Duration, KbDx, KbDy, Acc) ->
    Dotted      = player:add_dot(Defender, AttackerId, Dps, Duration),
    KnockedBack = apply_knockback(Dotted, KbDx, KbDy),
    player_registry:update_player(DefenderId, KnockedBack),
    spatial_index:update(DefenderId, player:x(KnockedBack), player:y(KnockedBack)),
    %% Report total expected DoT damage for the combat event
    TotalDmg = Dps * Duration,
    lager:info("DoT applied: attacker=~s defender=~s dps=~p dur=~p",
               [AttackerId, DefenderId, Dps, Duration]),
    [{DefenderId, TotalDmg, 0.0} | Acc].

-spec apply_knockback(player:player(), float(), float()) -> player:player().
apply_knockback(Player, KbDx, KbDy) ->
    NewX = player:x(Player) + KbDx,
    NewY = player:y(Player) + KbDy,
    player:set_position(Player, NewX, NewY).
