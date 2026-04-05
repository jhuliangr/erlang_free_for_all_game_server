%%%-------------------------------------------------------------------
%%% @doc Cosmetics domain module.
%%%
%%% Provides the server-driven configuration for all cosmetics,
%%% weapons, achievements, and game rules. This data is served to
%%% clients via the /api/config endpoint so that no unlock logic is
%%% hardcoded on the client.
%%% @end
%%%-------------------------------------------------------------------
-module(cosmetics).

-export([default_config/0]).

%%--------------------------------------------------------------------
%% @doc Return the full cosmetics and game-rules configuration map.
%% @end
%%--------------------------------------------------------------------
-spec default_config() -> map().
default_config() ->
    #{
        skins => [
            #{id => <<"skin_default">>,
              name => <<"Default">>,
              unlockCondition => null},
            #{id => <<"skin_fire">>,
              name => <<"Fire">>,
              unlockCondition => #{type => <<"kills">>, value => 10}},
            #{id => <<"skin_ice">>,
              name => <<"Ice">>,
              unlockCondition => #{type => <<"level">>, value => 5}}
        ],
        weapons => [
            #{id => <<"sword_default">>,
              name => <<"Sword">>,
              unlockCondition => null},
            #{id => <<"sword_legendary">>,
              name => <<"Legendary Sword">>,
              unlockCondition => #{type => <<"kills">>, value => 50}}
        ],
        characters => [
            #{id => <<"mage">>,   name => <<"Mage">>,   stats => character_stats:get(<<"mage">>)},
            #{id => <<"knight">>, name => <<"Knight">>, stats => character_stats:get(<<"knight">>)},
            #{id => <<"rogue">>,  name => <<"Rogue">>,  stats => character_stats:get(<<"rogue">>)},
            #{id => <<"golem">>,  name => <<"Golem">>,  stats => character_stats:get(<<"golem">>)}
        ],
        achievements => [
            #{id => <<"first_blood">>,
              name => <<"First Blood">>,
              condition => #{type => <<"kills">>, value => 1}},
            #{id => <<"veteran">>,
              name => <<"Veteran">>,
              condition => #{type => <<"kills">>, value => 100}},
            #{id => <<"survivor">>,
              name => <<"Survivor">>,
              condition => #{type => <<"level">>, value => 10}}
        ],
        gameRules => #{
            baseHp          => 100,
            baseSwordDamage => 10,
            attackRange     => 150,
            speed           => 200,
            xpPerKill       => 50,
            tickMs          => 50
        }
    }.
