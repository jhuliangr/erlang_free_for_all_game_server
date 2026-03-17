%%%-------------------------------------------------------------------
%%% @doc Process attack application service.
%%%
%%% Orchestrates a player attack: resolves hits against nearby players,
%%% applies damage and knockback, awards XP to the attacker, and
%%% returns a list of hit events.
%%% @end
%%%-------------------------------------------------------------------
-module(process_attack).

-export([execute/3]).

-define(XP_PER_KILL, 50.0).

%%--------------------------------------------------------------------
%% @doc Execute an attack from AttackerId at the given Angle.
%%
%% NearbyIds is the list of candidate player IDs to check for hits.
%% Returns `{ok, [{DefenderId, Damage}]}` or `{error, Reason}`.
%% @end
%%--------------------------------------------------------------------
-spec execute(binary(), float(), [binary()]) ->
    {ok, [{binary(), float()}]} | {error, term()}.
execute(AttackerId, Angle, NearbyIds) ->
    case player_registry:get_player(AttackerId) of
        {error, not_found} ->
            {error, attacker_not_found};
        {ok, Attacker} ->
            Hits = process_nearby(Attacker, Angle, NearbyIds, []),
            TotalXp = lists:foldl(fun({_DId, _Dmg, Xp}, Acc) -> Acc + Xp end,
                                  0.0, Hits),
            if
                TotalXp > 0.0 ->
                    UpdatedAttacker = player:gain_xp(Attacker, TotalXp),
                    player_registry:update_player(AttackerId, UpdatedAttacker);
                true ->
                    ok
            end,
            Results = [{DId, Dmg} || {DId, Dmg, _Xp} <- Hits],
            {ok, Results}
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

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
                            apply_hit(DefenderId, Defender, Damage, KbDx, KbDy, Acc)
                    end
            end
    end,
    process_nearby(Attacker, Angle, Rest, NewAcc).

-spec apply_hit(binary(), player:player(), float(), float(), float(), list()) -> list().
apply_hit(DefenderId, Defender, Damage, KbDx, KbDy, Acc) ->
    Damaged     = player:take_damage(Defender, Damage),
    KnockedBack = apply_knockback(Damaged, KbDx, KbDy),
    player_registry:update_player(DefenderId, KnockedBack),
    spatial_index:update(DefenderId, player:x(KnockedBack), player:y(KnockedBack)),
    Xp = case player:hp(KnockedBack) =:= 0.0 of
        true  -> ?XP_PER_KILL;
        false -> 0.0
    end,
    lager:info("Hit: defender=~s damage=~p xp_awarded=~p", [DefenderId, Damage, Xp]),
    [{DefenderId, Damage, Xp} | Acc].

%% Apply knockback by setting absolute position (bypasses per-tick speed cap).
-spec apply_knockback(player:player(), float(), float()) -> player:player().
apply_knockback(Player, KbDx, KbDy) ->
    NewX = player:x(Player) + KbDx,
    NewY = player:y(Player) + KbDy,
    player:set_position(Player, NewX, NewY).
