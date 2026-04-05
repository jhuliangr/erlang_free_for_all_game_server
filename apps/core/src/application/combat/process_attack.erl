%%%-------------------------------------------------------------------
%%% @doc Process attack application service.
%%%
%%% Orchestrates a player attack: checks cooldown, resolves hits
%%% (instant or DoT) against nearby players, applies damage and
%%% knockback, awards XP to the attacker, and returns hit events.
%%% @end
%%%-------------------------------------------------------------------
-module(process_attack).

-export([execute/3]).

-define(XP_PER_KILL, 50.0).

%%--------------------------------------------------------------------
%% @doc Execute an attack from AttackerId at the given Angle.
%%
%% Checks cooldown before proceeding. Returns `{ok, [{DefenderId, Damage}]}`
%% on success, `{error, cooldown}` if on cooldown, or `{error, Reason}`.
%% @end
%%--------------------------------------------------------------------
-spec execute(binary(), float(), [binary()]) ->
    {ok, [{binary(), float()}]} | {error, term()}.
execute(AttackerId, Angle, NearbyIds) ->
    case player_registry:get_player(AttackerId) of
        {error, not_found} ->
            {error, attacker_not_found};
        {ok, Attacker} ->
            case player:can_attack(Attacker) of
                false ->
                    {error, cooldown};
                true ->
                    %% Record the attack timestamp
                    Attacker2 = player:record_attack(Attacker),
                    player_registry:update_player(AttackerId, Attacker2),
                    Hits = process_nearby(Attacker2, Angle, NearbyIds, []),
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

-spec process_nearby(player:player(), float(), [binary()], list()) -> list().
process_nearby(_Attacker, _Angle, [], Acc) ->
    Acc;
process_nearby(Attacker, Angle, [DefenderId | Rest], Acc) ->
    NewAcc = case player:id(Attacker) =:= DefenderId of
        true ->
            Acc;
        false ->
            case player_registry:get_player(DefenderId) of
                {error, not_found} ->
                    Acc;
                {ok, Defender} ->
                    case combat_resolver:resolve(Attacker, Defender, Angle) of
                        {error, out_of_range} ->
                            Acc;
                        {ok, Damage, KbDx, KbDy} ->
                            apply_instant_hit(DefenderId, Defender, Damage, KbDx, KbDy, Acc);
                        {dot, Dps, Duration, KbDx, KbDy} ->
                            apply_dot_hit(DefenderId, Defender, Dps, Duration, KbDx, KbDy, Acc)
                    end
            end
    end,
    process_nearby(Attacker, Angle, Rest, NewAcc).

-spec apply_instant_hit(binary(), player:player(), float(), float(), float(), list()) -> list().
apply_instant_hit(DefenderId, Defender, Damage, KbDx, KbDy, Acc) ->
    Damaged     = player:take_damage(Defender, Damage),
    KnockedBack = apply_knockback(Damaged, KbDx, KbDy),
    player_registry:update_player(DefenderId, KnockedBack),
    spatial_index:update(DefenderId, player:x(KnockedBack), player:y(KnockedBack)),
    IsKill = player:hp(KnockedBack) =< +0.0,
    Xp = case IsKill of
        true  -> ?XP_PER_KILL;
        false -> 0.0
    end,
    case IsKill of
        true ->
            Dead = player:add_death(KnockedBack),
            player_registry:update_player(DefenderId, Dead);
        false ->
            ok
    end,
    lager:info("Hit: defender=~s damage=~p kill=~p", [DefenderId, Damage, IsKill]),
    [{DefenderId, Damage, Xp} | Acc].

-spec apply_dot_hit(binary(), player:player(), float(), non_neg_integer(), float(), float(), list()) -> list().
apply_dot_hit(DefenderId, Defender, Dps, Duration, KbDx, KbDy, Acc) ->
    Dotted      = player:add_dot(Defender, Dps, Duration),
    KnockedBack = apply_knockback(Dotted, KbDx, KbDy),
    player_registry:update_player(DefenderId, KnockedBack),
    spatial_index:update(DefenderId, player:x(KnockedBack), player:y(KnockedBack)),
    %% Report total expected DoT damage for the combat event
    TotalDmg = Dps * Duration,
    lager:info("DoT applied: defender=~s dps=~p dur=~p", [DefenderId, Dps, Duration]),
    [{DefenderId, TotalDmg, 0.0} | Acc].

-spec apply_knockback(player:player(), float(), float()) -> player:player().
apply_knockback(Player, KbDx, KbDy) ->
    NewX = player:x(Player) + KbDx,
    NewY = player:y(Player) + KbDy,
    player:set_position(Player, NewX, NewY).
