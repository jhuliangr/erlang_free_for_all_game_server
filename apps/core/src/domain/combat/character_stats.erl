%%%-------------------------------------------------------------------
%%% @doc Character stats domain module.
%%%
%%% Defines per-character combat attributes: base HP, base damage,
%%% attack range, knockback distance, attack cooldown, and whether
%%% the character applies damage-over-time instead of instant damage.
%%% @end
%%%-------------------------------------------------------------------
-module(character_stats).

-compile({no_auto_import, [get/1]}).

-export([
    get/1,
    base_hp/1,
    base_damage/1,
    attack_range/1,
    knockback_distance/1,
    cooldown_ms/1,
    dot_config/1
]).

-type character_id() :: binary().
-type stats() :: map().
-export_type([character_id/0, stats/0]).

%%--------------------------------------------------------------------
%% @doc Get the full stats map for a character.
%%
%% Stats map keys:
%%   base_hp            - starting/max HP
%%   base_damage        - instant damage per hit
%%   attack_range       - melee/ranged reach in world units
%%   knockback_distance - how far the defender is pushed back
%%   cooldown_ms        - minimum milliseconds between attacks
%%   dot                - false | #{damage_per_sec, duration_sec}
%% @end
%%--------------------------------------------------------------------
-spec get(character_id()) -> stats().
get(<<"knight">>) ->
    #{
        base_hp            => 100.0,
        base_damage        => 10.0,
        attack_range       => 150.0,
        knockback_distance => 50.0,
        cooldown_ms        => 334,      %% max 3 attacks/sec
        dot                => false
    };
get(<<"mage">>) ->
    #{
        base_hp            => 80.0,
        base_damage        => 0.0,      %% no instant damage
        attack_range       => 200.0,
        knockback_distance => 30.0,
        cooldown_ms        => 1000,     %% 1 attack/sec
        dot                => #{damage_per_sec => 1.0, duration_sec => 5}
    };
get(<<"rogue">>) ->
    #{
        base_hp            => 80.0,
        base_damage        => 7.0,
        attack_range       => 80.0,     %% short range
        knockback_distance => 0.0,      %% no knockback
        cooldown_ms        => 0,        %% unlimited attacks
        dot                => false
    };
get(<<"golem">>) ->
    #{
        base_hp            => 120.0,
        base_damage        => 20.0,
        attack_range       => 150.0,
        knockback_distance => 150.0,    %% massive knockback
        cooldown_ms        => 2000,     %% 1 attack every 2 sec
        dot                => false
    };
get(_) ->
    get(<<"knight">>).

%%--------------------------------------------------------------------
%% Convenience accessors
%%--------------------------------------------------------------------

-spec base_hp(character_id()) -> float().
base_hp(CharId) -> maps:get(base_hp, get(CharId)).

-spec base_damage(character_id()) -> float().
base_damage(CharId) -> maps:get(base_damage, get(CharId)).

-spec attack_range(character_id()) -> float().
attack_range(CharId) -> maps:get(attack_range, get(CharId)).

-spec knockback_distance(character_id()) -> float().
knockback_distance(CharId) -> maps:get(knockback_distance, get(CharId)).

-spec cooldown_ms(character_id()) -> non_neg_integer().
cooldown_ms(CharId) -> maps:get(cooldown_ms, get(CharId)).

-spec dot_config(character_id()) -> false | map().
dot_config(CharId) -> maps:get(dot, get(CharId)).
