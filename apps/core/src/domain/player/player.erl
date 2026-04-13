%%%-------------------------------------------------------------------
%%% @doc Player aggregate root.
%%%
%%% Represents a player in the game world. Encapsulates all player
%%% state including position, health, level, and equipped cosmetics.
%%% @end
%%%-------------------------------------------------------------------
-module(player).

-export([
    new/2,
    new/3,
    move/3,
    set_position/3,
    take_damage/2,
    gain_xp/2,
    equip/3,
    add_kill/1,
    add_death/1,
    add_dot/3,
    tick_dots/1,
    can_attack/1,
    record_attack/1,
    to_map/1,
    id/1,
    pid/1,
    set_pid/2,
    x/1,
    y/1,
    hp/1,
    level/1,
    xp/1,
    name/1,
    character/1,
    kills/1,
    deaths/1,
    xp_for_level/1
]).

-record(player, {
    id             :: binary(),
    name           :: binary(),
    pid            :: pid() | undefined,
    x              :: float(),
    y              :: float(),
    hp             :: float(),
    max_hp         :: float(),
    level          :: pos_integer(),
    xp             :: float(),
    kills          :: non_neg_integer(),
    deaths         :: non_neg_integer(),
    last_attack_at :: integer(),
    dot_effects    :: [dot_effect()],
    skin           :: binary(),
    weapon         :: binary(),
    character      :: binary()
}).

-type dot_effect() :: #{
    damage_per_sec := float(),
    ticks_left     := non_neg_integer(),
    last_tick_at   := integer()
}.

-type player() :: #player{}.
-export_type([player/0]).

%%--------------------------------------------------------------------
%% @doc Create a new player at a random spawn point.
%% @end
%%--------------------------------------------------------------------
-spec new(binary(), binary()) -> player().
new(Id, Name) ->
    new(Id, Name, <<"knight">>).

-spec new(binary(), binary(), binary()) -> player().
new(Id, Name, Char) ->
    Hp = character_stats:base_hp(Char),
    {SpawnX, SpawnY} = world:spawn_point(),
    #player{
        id             = Id,
        name           = Name,
        pid            = undefined,
        x              = SpawnX,
        y              = SpawnY,
        hp             = Hp,
        max_hp         = Hp,
        level          = 1,
        xp             = 0.0,
        kills          = 0,
        deaths         = 0,
        last_attack_at = 0,
        dot_effects    = [],
        skin           = <<"default">>,
        weapon         = <<"sword">>,
        character      = Char
    }.

%%--------------------------------------------------------------------
%% @doc Teleport the player to an absolute position, clamped to world bounds.
%% Used for knockback and server-authoritative repositioning.
%% @end
%%--------------------------------------------------------------------
-spec set_position(player(), float(), float()) -> player().
set_position(Player, X, Y) ->
    {W, H} = world:bounds(),
    NewX = world:clamp(X, 0.0, float(W)),
    NewY = world:clamp(Y, 0.0, float(H)),
    Player#player{x = NewX, y = NewY}.

%%--------------------------------------------------------------------
%% @doc Move the player by (Dx, Dy), clamped to world bounds.
%% Speed is 200 units/sec; at 50ms tick, max 10 units per tick.
%% @end
%%--------------------------------------------------------------------
-spec move(player(), float(), float()) -> player().
move(Player, Dx, Dy) ->
    MaxStep = 10.0,
    %% Normalize the direction vector then scale to at most MaxStep units.
    Magnitude = math:sqrt(Dx * Dx + Dy * Dy),
    {StepX, StepY} = if
        Magnitude > 0.0 ->
            Factor = min(1.0, MaxStep / Magnitude),
            {Dx / Magnitude * MaxStep * Factor,
             Dy / Magnitude * MaxStep * Factor};
        true ->
            {0.0, 0.0}
    end,
    %% Clamp to world bounds
    {W, H} = world:bounds(),
    NewX = world:clamp(Player#player.x + StepX, 0.0, float(W)),
    NewY = world:clamp(Player#player.y + StepY, 0.0, float(H)),
    Player#player{x = NewX, y = NewY}.

%%--------------------------------------------------------------------
%% @doc Apply damage to the player. HP will not go below 0.
%% @end
%%--------------------------------------------------------------------
-spec take_damage(player(), float()) -> player().
take_damage(Player, Damage) ->
    NewHp = max(0.0, Player#player.hp - Damage),
    Player#player{hp = NewHp}.

%%--------------------------------------------------------------------
%% @doc Give XP to the player, leveling up when threshold is reached.
%% @end
%%--------------------------------------------------------------------
-spec gain_xp(player(), float()) -> player().
gain_xp(Player, Xp) ->
    NewXp = Player#player.xp + Xp,
    level_up(Player#player{xp = NewXp}).

%%--------------------------------------------------------------------
%% @doc Equip a cosmetic item in the given slot (skin or weapon).
%% @end
%%--------------------------------------------------------------------
-spec equip(player(), skin | weapon | character, binary()) -> player().
equip(Player, skin, ItemId) ->
    Player#player{skin = ItemId};
equip(Player, weapon, ItemId) ->
    Player#player{weapon = ItemId};
equip(Player, character, ItemId) ->
    Valid = [<<"mage">>, <<"knight">>, <<"rogue">>, <<"golem">>],
    case lists:member(ItemId, Valid) of
        true ->
            NewMaxHp = character_stats:base_hp(ItemId),
            NewHp = min(Player#player.hp, NewMaxHp),
            Player#player{character = ItemId, max_hp = NewMaxHp, hp = NewHp};
        false ->
            Player
    end.

%%--------------------------------------------------------------------
%% @doc Serialize the player to a map for JSON encoding.
%% @end
%%--------------------------------------------------------------------
-spec to_map(player()) -> map().
to_map(Player) ->
    #{
        id     => Player#player.id,
        name   => Player#player.name,
        x      => Player#player.x,
        y      => Player#player.y,
        hp     => Player#player.hp,
        max_hp => Player#player.max_hp,
        level  => Player#player.level,
        xp     => Player#player.xp,
        kills  => Player#player.kills,
        deaths => Player#player.deaths,
        skin      => Player#player.skin,
        weapon    => Player#player.weapon,
        character => Player#player.character
    }.

%%--------------------------------------------------------------------
%% Accessors
%%--------------------------------------------------------------------

-spec id(player()) -> binary().
id(#player{id = Id}) -> Id.

-spec pid(player()) -> pid() | undefined.
pid(#player{pid = Pid}) -> Pid.

-spec set_pid(player(), pid() | undefined) -> player().
set_pid(Player, Pid) -> Player#player{pid = Pid}.

-spec x(player()) -> float().
x(#player{x = X}) -> X.

-spec y(player()) -> float().
y(#player{y = Y}) -> Y.

-spec hp(player()) -> float().
hp(#player{hp = Hp}) -> Hp.

-spec level(player()) -> pos_integer().
level(#player{level = Level}) -> Level.

-spec xp(player()) -> float().
xp(#player{xp = Xp}) -> Xp.

-spec name(player()) -> binary().
name(#player{name = Name}) -> Name.

-spec character(player()) -> binary().
character(#player{character = C}) -> C.

-spec kills(player()) -> non_neg_integer().
kills(#player{kills = K}) -> K.

-spec deaths(player()) -> non_neg_integer().
deaths(#player{deaths = D}) -> D.

-spec add_kill(player()) -> player().
add_kill(Player) -> Player#player{kills = Player#player.kills + 1}.

-spec add_death(player()) -> player().
add_death(Player) -> Player#player{deaths = Player#player.deaths + 1}.

%%--------------------------------------------------------------------
%% @doc Check if the player's attack cooldown has elapsed.
%% @end
%%--------------------------------------------------------------------
-spec can_attack(player()) -> boolean().
can_attack(Player) ->
    Cooldown = character_stats:cooldown_ms(Player#player.character),
    case Cooldown of
        0 -> true;
        _ ->
            Now = erlang:system_time(millisecond),
            Now - Player#player.last_attack_at >= Cooldown
    end.

%%--------------------------------------------------------------------
%% @doc Record that the player just attacked (updates cooldown timer).
%% @end
%%--------------------------------------------------------------------
-spec record_attack(player()) -> player().
record_attack(Player) ->
    Player#player{last_attack_at = erlang:system_time(millisecond)}.

%%--------------------------------------------------------------------
%% @doc Apply a new DoT effect to this player.
%% @end
%%--------------------------------------------------------------------
-spec add_dot(player(), float(), non_neg_integer()) -> player().
add_dot(Player, DamagePerSec, DurationSec) ->
    Now = erlang:system_time(millisecond),
    Dot = #{damage_per_sec => DamagePerSec,
            ticks_left     => DurationSec,
            last_tick_at   => Now},
    Player#player{dot_effects = [Dot | Player#player.dot_effects]}.

%%--------------------------------------------------------------------
%% @doc Process all active DoT effects. Called once per second.
%%
%% Returns `{UpdatedPlayer, TotalDotDamage}` where TotalDotDamage
%% is the sum of damage applied this tick (for combat event broadcast).
%% @end
%%--------------------------------------------------------------------
-spec tick_dots(player()) -> {player(), float()}.
tick_dots(#player{dot_effects = []} = Player) ->
    {Player, 0.0};
tick_dots(Player) ->
    Now = erlang:system_time(millisecond),
    {NewDots, TotalDmg} = lists:foldl(
        fun(#{damage_per_sec := Dps, ticks_left := Left, last_tick_at := LastAt} = Dot,
            {DotsAcc, DmgAcc}) ->
            Elapsed = Now - LastAt,
            case Elapsed >= 1000 andalso Left > 0 of
                true ->
                    Remaining = Left - 1,
                    NewDot = Dot#{ticks_left := Remaining, last_tick_at := Now},
                    case Remaining > 0 of
                        true  -> {[NewDot | DotsAcc], DmgAcc + Dps};
                        false -> {DotsAcc, DmgAcc + Dps}
                    end;
                false when Left > 0 ->
                    {[Dot | DotsAcc], DmgAcc};
                false ->
                    {DotsAcc, DmgAcc}
            end
        end,
        {[], 0.0},
        Player#player.dot_effects
    ),
    Damaged = case TotalDmg > 0.0 of
        true  -> take_damage(Player, TotalDmg);
        false -> Player
    end,
    {Damaged#player{dot_effects = NewDots}, TotalDmg}.

%%--------------------------------------------------------------------
%% @doc XP required to reach the given level.
%% Formula: round(100 * 1.5^(Level - 1))
%% @end
%%--------------------------------------------------------------------
-spec xp_for_level(pos_integer()) -> float().
xp_for_level(Level) ->
    round(100 * math:pow(1.5, Level - 1)) * 1.0.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

-spec level_up(player()) -> player().
level_up(Player) ->
    Required = xp_for_level(Player#player.level + 1),
    if
        Player#player.xp >= Required ->
            NewLevel = Player#player.level + 1,
            NewXp    = Player#player.xp - Required,
            lager:info("Player ~s leveled up to ~p", [Player#player.id, NewLevel]),
            level_up(Player#player{level = NewLevel, xp = NewXp});
        true ->
            Player
    end.
