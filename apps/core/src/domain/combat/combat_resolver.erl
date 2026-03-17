%%%-------------------------------------------------------------------
%%% @doc Combat domain service.
%%%
%%% Resolves combat interactions between players. Calculates damage,
%%% checks attack range, and computes knockback vectors.
%%% @end
%%%-------------------------------------------------------------------
-module(combat_resolver).

-export([
    resolve/3,
    calculate_damage/1,
    is_in_range/4
]).

-define(ATTACK_RANGE, 150.0).
-define(KNOCKBACK_DISTANCE, 50.0).

%%--------------------------------------------------------------------
%% @doc Check whether two positions are within attack range.
%% Range is 150 units.
%% @end
%%--------------------------------------------------------------------
-spec is_in_range(float(), float(), float(), float()) -> boolean().
is_in_range(X1, Y1, X2, Y2) ->
    Dx = X2 - X1,
    Dy = Y2 - Y1,
    DistSq = Dx * Dx + Dy * Dy,
    DistSq =< ?ATTACK_RANGE * ?ATTACK_RANGE.

%%--------------------------------------------------------------------
%% @doc Calculate damage dealt by a player of the given level.
%% Formula: 10 * (1 + 0.15 * (Level - 1))
%% @end
%%--------------------------------------------------------------------
-spec calculate_damage(pos_integer()) -> float().
calculate_damage(Level) ->
    10.0 * (1.0 + 0.15 * (Level - 1)).

%%--------------------------------------------------------------------
%% @doc Resolve a combat interaction between attacker and defender.
%%
%% Returns `{ok, Damage, KnockbackDx, KnockbackDy}` if in range,
%% or `{error, out_of_range}` otherwise.
%%
%% Knockback is applied away from the attacker (opposite of the
%% vector from attacker to defender), scaled to KNOCKBACK_DISTANCE.
%% @end
%%--------------------------------------------------------------------
-spec resolve(player:player(), player:player(), float()) ->
    {ok, float(), float(), float()} | {error, out_of_range}.
resolve(Attacker, Defender, _Angle) ->
    Ax = player:x(Attacker),
    Ay = player:y(Attacker),
    Dx = player:x(Defender),
    Dy = player:y(Defender),
    case is_in_range(Ax, Ay, Dx, Dy) of
        false ->
            {error, out_of_range};
        true ->
            Damage = calculate_damage(player:level(Attacker)),
            %% Knockback direction: from attacker toward defender
            KbDx = Dx - Ax,
            KbDy = Dy - Ay,
            Magnitude = math:sqrt(KbDx * KbDx + KbDy * KbDy),
            {NormDx, NormDy} = if
                Magnitude > 0.0 ->
                    {KbDx / Magnitude, KbDy / Magnitude};
                true ->
                    %% Defender is at exactly the same position; push in a default direction
                    {1.0, 0.0}
            end,
            KbX = NormDx * ?KNOCKBACK_DISTANCE,
            KbY = NormDy * ?KNOCKBACK_DISTANCE,
            {ok, Damage, KbX, KbY}
    end.
