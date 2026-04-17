%%%-------------------------------------------------------------------
%%% @doc Combat domain service.
%%%
%%% Resolves combat interactions between players using character-
%%% specific stats for damage, range, and knockback.
%%% @end
%%%-------------------------------------------------------------------
-module(combat_resolver).

-export([
    resolve/3,
    resolve_at/4,
    is_in_range/5
]).

%%--------------------------------------------------------------------
%% @doc Check whether two positions are within the attacker's range.
%% @end
%%--------------------------------------------------------------------
-spec is_in_range(float(), float(), float(), float(), float()) -> boolean().
is_in_range(X1, Y1, X2, Y2, Range) ->
    Dx = X2 - X1,
    Dy = Y2 - Y1,
    DistSq = Dx * Dx + Dy * Dy,
    DistSq =< Range * Range.

%%--------------------------------------------------------------------
%% @doc Resolve a combat interaction between attacker and defender.
%%%
%%% Uses the attacker's character class to determine damage, range,
%%% and knockback. For mage, returns `{dot, ...}` instead of instant
%%% damage.
%%%
%%% Returns:
%%%   {ok, Damage, KbDx, KbDy}       — instant hit
%%%   {dot, DamagePerSec, DurationSec, KbDx, KbDy} — DoT hit (mage)
%%%   {error, out_of_range}
%%% @end
%%--------------------------------------------------------------------
-spec resolve(player:player(), player:player(), float()) ->
    {ok, float(), float(), float()} |
    {dot, float(), non_neg_integer(), float(), float()} |
    {error, out_of_range}.
resolve(Attacker, Defender, Angle) ->
    resolve_at(Attacker, Defender, Angle, {player:x(Defender), player:y(Defender)}).

%%--------------------------------------------------------------------
%% @doc Like resolve/3 but uses the given {X, Y} as the defender's
%% position for the in-range check. The defender's live state is still
%% used for damage scaling and knockback direction (the knockback is
%% applied to the live position on return). This is what powers
%% lag-compensated hit detection.
%% @end
%%--------------------------------------------------------------------
-spec resolve_at(player:player(), player:player(), float(),
                 {float(), float()}) ->
    {ok, float(), float(), float()} |
    {dot, float(), non_neg_integer(), float(), float()} |
    {error, out_of_range}.
resolve_at(Attacker, Defender, _Angle, {HitX, HitY}) ->
    Char = player:character(Attacker),
    Stats = character_stats:get(Char),
    Range = maps:get(attack_range, Stats),
    KbDist = maps:get(knockback_distance, Stats),

    Ax = player:x(Attacker),
    Ay = player:y(Attacker),

    case is_in_range(Ax, Ay, HitX, HitY, Range) of
        false ->
            {error, out_of_range};
        true ->
            %% Knockback uses the live defender position so the visual
            %% result is consistent with the current world state — we
            %% only rewind for the range check.
            LiveX = player:x(Defender),
            LiveY = player:y(Defender),
            {KbX, KbY} = knockback_vector(Ax, Ay, LiveX, LiveY, KbDist),
            case maps:get(dot, Stats) of
                false ->
                    BaseDmg = maps:get(base_damage, Stats),
                    LevelScale = 1.0 + 0.15 * (player:level(Attacker) - 1),
                    Damage = BaseDmg * LevelScale,
                    {ok, Damage, KbX, KbY};
                #{damage_per_sec := Dps, duration_sec := Dur} ->
                    {dot, Dps, Dur, KbX, KbY}
            end
    end.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec knockback_vector(float(), float(), float(), float(), float()) ->
    {float(), float()}.
knockback_vector(_Ax, _Ay, _Dx, _Dy, +0.0) ->
    {0.0, 0.0};
knockback_vector(Ax, Ay, Dx, Dy, Distance) ->
    KbDx = Dx - Ax,
    KbDy = Dy - Ay,
    Magnitude = math:sqrt(KbDx * KbDx + KbDy * KbDy),
    {NormDx, NormDy} = if
        Magnitude > 0.0 ->
            {KbDx / Magnitude, KbDy / Magnitude};
        true ->
            {1.0, 0.0}
    end,
    {NormDx * Distance, NormDy * Distance}.
