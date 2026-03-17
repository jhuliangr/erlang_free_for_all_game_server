%%%-------------------------------------------------------------------
%%% @doc Achievement evaluator domain service.
%%%
%%% Evaluates a player's statistics against a list of achievement
%%% definitions and returns the IDs of all achievements that have
%%% been unlocked.
%%% @end
%%%-------------------------------------------------------------------
-module(achievement_evaluator).

-export([evaluate/2]).

%%--------------------------------------------------------------------
%% @doc Evaluate which achievements are unlocked given player stats.
%%
%% PlayerStats is a map of the form `#{kills => N, level => L}`.
%% AchievementDefs is a list of maps, each with at least:
%%   `#{id => Id, condition => #{type => Type, value => Value}}`.
%%
%% Returns a list of unlocked achievement IDs.
%% @end
%%--------------------------------------------------------------------
-spec evaluate(map(), [map()]) -> [binary()].
evaluate(PlayerStats, AchievementDefs) ->
    lists:filtermap(fun(Def) -> check_achievement(PlayerStats, Def) end,
                    AchievementDefs).

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec check_achievement(map(), map()) -> {true, binary()} | false.
check_achievement(Stats, #{id := Id, condition := #{type := Type, value := Required}}) ->
    StatKey = condition_key(Type),
    PlayerValue = maps:get(StatKey, Stats, 0),
    if
        PlayerValue >= Required -> {true, Id};
        true                    -> false
    end;
check_achievement(_Stats, _Def) ->
    false.

-spec condition_key(binary()) -> atom().
condition_key(<<"kills">>) -> kills;
condition_key(<<"level">>) -> level;
condition_key(_)           -> unknown.
