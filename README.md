# Chimera boss encounter (PvE)

> Source mirror of the OPEN//77 Chimera boss resources. Full documentation: https://open2077.net/docs/chimera

## Repository layout

| Folder | Resource | Copy to |
|---|---|---|
| `open77_chimera/` | the encounter provider (server + client) | `resources/gamemodes/open77_chimera` |
| `open77_chimera_lab/` | optional staff lab menu (`/chimera`, `auto_start false`) | `resources/dev/open77_chimera_lab` |

`open77_chimera` runs the Militech Chimera, the walking war machine of Phantom Liberty, as a multiplayer PvE boss. The server owns the encounter: health, phases, difficulty, weak-spot damage, targeting and the controlling resource. One nearby player's client hosts the boss's native AI, and every other player within range sees the same combat presentation: shots, effects, sounds, phase changes, destroyed parts and the death collapse.

The resource never spawns a boss by itself. A gamemode creates encounters through its exports, or staff use the `/chimera` lab menu.

**Experimental · server and client.** Requires the Unstable server and client **2.50.0-unstable+op77.161** or later, and Phantom Liberty on every client (the boss is the `Character.main_boss_chimera` record).

## Install

`open77_chimera` (the encounter provider) and `open77_chimera_lab` (the optional staff menu) are distributed separately from the server archive. Copy their folders into `resources/` (for example `resources/gamemodes/open77_chimera` and `resources/dev/open77_chimera_lab`), then add them to `resources.load` in `server.jsonc`:

```jsonc
"resources": {
  "load": [
    "open77_shell", "open77_pause",
    // ...
    "open77_uikit",          // the lab menu's widgets
    "open77_chimera",
    "open77_chimera_lab",    // optional: staff menu
    "my_raid"                // your gamemode, after the provider
  ]
}
```

`open77_chimera` starts automatically. `open77_chimera_lab` declares `auto_start false`: start it with `ensure open77_chimera_lab` from the console or [RCON](https://open2077.net/docs/rcon) when staff need it. The lab depends on [`open77_uikit`](https://open2077.net/docs/ui-kit).

The provider declares its own permissions (`world.npcs`, `npcs.read`, `world.query`, `players.life.read`, `players.damage.apply`, `network.events`). A gamemode that controls bosses only needs the dependency below.

## Quick start

A resource that controls Chimeras declares the dependency:

```lua
resource "my_raid"
version "1.0.0"
dependency "open77_chimera >=1.0.0"
server_script "server.lua"
```

Then, in `server.lua`, create a boss at a known spot and give it a harder profile:

```lua
local boss = exports.open77_chimera

RegisterCommand("raid.start", function(playerId)
    local state, reason = boss:create({
        position = { x = -2047.0, y = -2406.8, z = -7.4 },
        yaw = 180,
        bucket = 0,
        maxHealth = 100,
    })
    if not state then
        print("Chimera refused: " .. tostring(reason))
        return
    end

    -- Twice the effective health, 80% of the native damage.
    boss:setDifficulty(state.id, { healthMultiplier = 2, damageMultiplier = 0.8 })
    print(("Chimera %s is up in bucket %d"):format(state.id, state.bucket))
end, true)
```

`exports.open77_chimera:method(...)` and `Open77.exports.callSync("open77_chimera", "method", ...)` are equivalent. Both **raise** when the provider is not running; wrap them in `pcall` when its availability is uncertain (see [Cross-resource server exports](https://open2077.net/docs/server-exports)).

## Ownership and IDs

- Boss IDs are **strings**.
- Each resource controls only the encounters it created. `get`, `list` and every mutation refuse another resource's boss with `boss_not_owned`; lab-created bosses belong to the lab.
- Stopping the controlling resource removes its encounters. Stopping `open77_chimera` removes all of them.
- `reset`, a backward `setPhase` and recovery from death **recreate** the NPC. The result carries the new `id` and the old one as `replacedId`: keep the returned ID, the old one is stale.

Most mutations return the boss's updated state, or `nil, reason`. `remove` returns a boolean.

## Encounter lifecycle

| Export | Description |
| --- | --- |
| `boss:profiles()` | Lists the supported profiles and their phases. Only `chimera` exists. |
| `boss:create(options)` | Creates an encounter at an explicit position and returns its state. |
| `boss:spawn(playerId, options)` | Requests a checked placement near a ready, living player; returns a request ID. |
| `boss:result(requestId)` | `{ status = "pending" }`, `{ status = "created", id }` or `{ status = "failed", reason }`. |
| `boss:get(id)` | Reads the encounter's state. |
| `boss:list(options)` | Lists the calling resource's encounters, sorted by ID; optional `{ bucket = bucketId }` filter. |
| `boss:remove(id)` | Despawns the encounter. |
| `boss:kill(id)` | Kills the boss without despawning its wreck. |
| `boss:reset(id)` | Recreates a fresh, armored boss; returns its state with `replacedId`. |

### Creation options

| Option | Default | Notes |
| --- | --- | --- |
| `profile` | `"chimera"` | Any other value is `boss_profile_invalid`. |
| `position` | required for `create` | `{ x, y, z }`. Not checked against the navmesh. |
| `yaw` | `0` | Degrees. |
| `bucket` | `0` | Routing bucket of the encounter. |
| `maxHealth` | `100` | Greater than `0`, at most `100000`. |
| `health` | `maxHealth` | `0` to `maxHealth`. |
| `difficulty` | `{ healthMultiplier = 1, damageMultiplier = 1 }` | See [Difficulty](#difficulty-and-damage). |
| `damagePolicy` | `Open77.npcs.damage.mortal` | `.mortal`, `.immortal` or `.invulnerable`. |
| `aiEnabled`, `combatEnabled` | `true` | Booleans. |

### Placement near a player

`spawn` asks the player's client to probe sixteen directions for a level, unobstructed path about 18 metres long, then creates the boss at the end of the first clear one, in the player's bucket. The request is asynchronous: accepting it does not mean the boss exists.

```lua
local requestId, reason = boss:spawn(playerId, { maxHealth = 100 })
if not requestId then return print(reason) end

CreateThread(function()
    for _ = 1, 25 do
        Wait(250)
        local result = boss:result(requestId)
        if result and result.status == "created" then
            print("Chimera " .. result.id)
            return
        elseif result and result.status == "failed" then
            print("Placement failed: " .. tostring(result.reason))
            return
        end
    end
end)
```

A request fails after 5 seconds (`boss_spawn_timeout`), when the player moves more than 2 metres before the answer (`boss_player_moved`) or disconnects, or when no direction is clear. Each resource can have one pending request per player (`boss_spawn_pending`). Finished results are kept for 60 seconds. The probe checks a level path, not the boss's whole footprint: in an arena, prefer `create` at a position you have checked yourself.

## Encounter state

`get`, `list` and the mutations return:

| Field | Meaning |
| --- | --- |
| `id`, `profile`, `label`, `controller` | Boss ID, `"chimera"`, `"Chimera"`, controlling resource. |
| `bucket`, `position`, `yaw` | Where the boss is. |
| `health`, `maxHealth`, `healthPercent`, `alive` | Health state. |
| `phase` | `armored`, `exposed`, `gas` or `core`. |
| `repairing`, `gas` | The repair cycle is running; the gas cloud is active. |
| `damagePolicy`, `aiEnabled`, `combatEnabled` | Current controls. |
| `difficulty` | `{ healthMultiplier, damageMultiplier }`. |
| `target` | `{ mode = "forced" \| "native", playerId, actualPlayerId }`. |
| `authority` | `{ playerId, epoch }`: the player whose client hosts the AI. |
| `parts` | Seventeen numbers, the remaining fraction (`0` to `1`) of each weak spot. |
| `nativePhase` | The provider's internal phase number, for diagnostics. |

## Phases and the repair cycle

| Phase | Starts at | What changes |
| --- | --- | --- |
| `armored` | 100% | The opening phase: armor plates, turrets and legs intact. |
| `exposed` | 70% | Crossing 70% from damage starts a **60-second repair**: the boss is invulnerable until it ends. |
| `gas` | 40% | The gas cloud is enabled. |
| `core` | 1% | The core phase, until death. |

`setPhase(id, phase)` jumps to a phase by setting health to 100%, 70%, 39% or 1% of the maximum. A forward jump skips the repair delay. A backward jump, or any change from a dead boss, recreates the NPC with a new ID.

During the repair, `setDamagePolicy` records the new policy and applies it when the repair ends. A scripted `setHealth` ends a running repair at once and restores the configured policy; a raid that wants a shorter repair can call `setHealth(id, state.health)` when its own timer runs out.

Healing does not rewind a phase or restore destroyed parts.

## Weak spots

The Chimera has seventeen weak spots: turrets, armor plates, leg armor and the Metalstorm. Until the `core` phase, a hit on a weak spot removes part of that spot, and the boss loses health in proportion: **2%** of its maximum health per whole part in `armored`, **5%** in `exposed` and `gas`. A breaking hit counts in full; a destroyed part costs nothing more. Weak-spot hits do not count during a repair, in the `core` phase, or when the damage policy is not `mortal`.

The `parts` array of the state shows what is left of each spot. Parts and health are replicated to every player within 250 metres, so late joiners see the same destroyed parts and, after a kill, the same wreck.

## Difficulty and damage

| Export | Description |
| --- | --- |
| `boss:setHealth(id, health, maxHealth?)` | Sets exact health and, optionally, the maximum. Pass `nil` for `health` to keep the current percentage while changing the maximum. A dead boss cannot be healed (`boss_dead`). |
| `boss:applyDamage(id, amount)` | Applies exact scripted damage (`0` < amount ≤ `1000000`) through the damage and repair rules. It is not scaled by difficulty. |
| `boss:setDifficulty(id, difficulty)` | Partially updates `healthMultiplier` (`0.01` to `100`) and/or `damageMultiplier` (`0` to `100`). |
| `boss:setDamagePolicy(id, policy)` | `Open77.npcs.damage.mortal`, `.immortal` or `.invulnerable`. |

- **Health multiplier**: incoming player damage, weak-spot damage included, is divided by it. `2` means twice the effective health. A high multiplier still lets the armored phase reach the 70% repair threshold before every part is destroyed.
- **Damage multiplier**: scales the boss's outgoing combat damage.
- Changing the difficulty keeps the current health percentage and phase.

Scale both multipliers with the squad size rather than raising `maxHealth`: health percentages, phase thresholds and weak-spot pricing then stay the same for every group.

## AI and targeting

| Export | Description |
| --- | --- |
| `boss:setAIEnabled(id, enabled)` | Enables or disables the native AI. |
| `boss:setCombatEnabled(id, enabled)` | Enables or disables combat. Projectiles already in flight stay active. |
| `boss:setTarget(id, playerId)` | Forces a target: a ready, living player in the same bucket within 60 metres. Pass `nil` to return to native target selection. |
| `boss:setPhase(id, phase)` | See [Phases](#phases-and-the-repair-cycle). |

A forced target is cleared automatically when that player disconnects, dies, changes bucket or moves more than 60 metres away.

To keep the boss passive during an intro, disable combat and make it invulnerable, then switch both back. Keeping the native AI on during the intro and toggling only combat avoids a boss that stands still afterwards.

## Server commands and the lab menu

The provider registers three restricted commands; ACL rights are `command.<name>` (see [Commands & permissions](https://open2077.net/docs/server-acl)):

| Command | Effect |
| --- | --- |
| `chimera.spawn` | Requests a placement near you. The boss belongs to `open77_chimera`. |
| `chimera.state [id]` | Prints the boss in your bucket: health, phase, repair, gas, authority and parts. |
| `chimera.remove [id]` | Removes the boss in your bucket. |

Without an ID, these commands act on the only Chimera in your bucket.

With `open77_chimera_lab` started, `/chimera` opens a staff menu built with the UI kit. It requires the ACL right `command.chimera`, and the server checks that right again for every request the menu sends. The menu lists the lab's bosses in your bucket and offers:

- spawn, refresh, kill, despawn and reset to armored (with confirmations);
- phase, current and maximum health, difficulty multipliers and exact damage;
- damage policy, AI and combat toggles;
- target: a ready, living player within 60 metres, or native selection.

The lab only manages bosses it created; it is also a working example of the export API.

## Build a raid around the boss

The exports are enough to build a full raid: a ready check, an intro, scaled difficulty, reinforcements at health thresholds, target locks and an enrage timer. The sketch below follows how a roleplay server runs the Chimera as a mission inside its own routing bucket. Mission matchmaking, payouts and the client cinematic are the gamemode's own and are left out.

```lua
local PROVIDER = "open77_chimera"
local SCALING = {
    standard = { health = 1.0, healthPerOperator = 0.45, damage = 0.8, waves = { 75, 40 }, enrageMinutes = 12, enrageDamage = 1.5 },
    hard     = { health = 1.8, healthPerOperator = 0.6,  damage = 1.1, waves = { 85, 60, 35, 15 }, enrageMinutes = 10, enrageDamage = 1.6 },
}

local function boss(method, ...)
    local ok, value, reason = pcall(Open77.exports.callSync, PROVIDER, method, ...)
    if not ok then return nil, tostring(value) end
    return value, reason
end

local function multipliers(raid)
    local s = SCALING[raid.difficulty]
    return s.health + s.healthPerOperator * math.max(0, #raid.members - 1), s.damage
end

-- 1. Place the boss, passive while the clients play the intro.
local function placeBoss(raid, stand)
    local state, reason = boss("create", { position = stand, yaw = 180, bucket = raid.bucket, maxHealth = 100 })
    if not state then return false, reason end
    raid.bossId = state.id
    boss("setCombatEnabled", raid.bossId, false)
    boss("setDamagePolicy", raid.bossId, Open77.npcs.damage.invulnerable)
    return true
end

-- 2. The fight: difficulty scaled by the squad size.
local function beginFight(raid)
    local health, damage = multipliers(raid)
    boss("setDifficulty", raid.bossId, { healthMultiplier = health, damageMultiplier = damage })
    boss("setDamagePolicy", raid.bossId, Open77.npcs.damage.mortal)
    boss("setCombatEnabled", raid.bossId, true)
    raid.startedAt, raid.waves = os.time(), 0
end

-- 3. Every second: follow the boss, react to its state.
local function fightTick(raid)
    local s = SCALING[raid.difficulty]
    local state = boss("get", raid.bossId)
    if not state then
        -- Some transitions recreate the NPC: find ours again in the raid's bucket.
        local list = boss("list", { bucket = raid.bucket })
        state = list and list[1]
        if not state then return "failed" end
        raid.bossId = state.id
    end
    if not state.alive then return "victory" end

    if state.phase ~= raid.lastPhase then
        announce(raid, state.phase)          -- your HUD: "ARMOR BREACHED", "CORE EXPOSED"...
        raid.lastPhase = state.phase
    end
    while raid.waves < #s.waves and state.healthPercent <= s.waves[raid.waves + 1] do
        raid.waves = raid.waves + 1
        spawnReinforcements(raid, state.position)   -- your NPCs, in the boss's combat group "open77_chimera"
    end
    if not raid.enraged and os.time() - raid.startedAt >= s.enrageMinutes * 60 then
        raid.enraged = true
        local health, damage = multipliers(raid)
        boss("setDifficulty", raid.bossId, { healthMultiplier = health, damageMultiplier = damage * s.enrageDamage })
    end
end

-- 4. Target lock: the boss hunts one operator for a while.
local function lockOn(raid, playerId)
    if boss("setTarget", raid.bossId, playerId) then
        SetTimeout(9000, function() boss("setTarget", raid.bossId, nil) end)
    end
end

-- 5. Always clean up, whatever the outcome.
local function finish(raid)
    if raid.bossId then boss("remove", raid.bossId) end
end
```

Points worth keeping from that design:

- Run each raid in its own [routing bucket](https://open2077.net/docs/server-api#routing-buckets) and pass it to `create` and `list`; the boss, its effects and its target checks stay inside it.
- Scale `healthMultiplier` and `damageMultiplier` with the number of players and the difficulty instead of changing `maxHealth`, so phase thresholds and wave triggers stay in percent.
- Read the state every tick and handle a changed ID through `list`.
- Reinforcement NPCs fight beside the boss when they join its combat group, `open77_chimera` (see [NPC spawning](https://open2077.net/docs/npcs)).
- The server decides victory from `state.alive`, never from a client report.
- The raid can show the repair: `state.repairing` is true while the boss is shielded.

## Errors

| Reason | Meaning |
| --- | --- |
| `boss_controller_required` | The export was not called from a resource. |
| `boss_not_owned` / `boss_not_found` | Not your encounter, or it no longer exists (a stale ID after a recreate). |
| `boss_profile_invalid`, `boss_position_invalid`, `boss_options_invalid` | Invalid creation options. |
| `boss_health_invalid`, `boss_dead` | Health out of range, or healing a dead boss. |
| `boss_damage_invalid`, `boss_damage_refused` | `applyDamage` amount out of range, or refused by the NPC runtime. |
| `boss_policy_invalid`, `boss_phase_invalid` | Unknown damage policy or phase. |
| `boss_target_invalid`, `boss_target_refused`, `boss_attitude_unavailable` | The target is not a ready, living player in the bucket within 60 metres, or the attitude change failed. |
| `boss_player_invalid`, `boss_spawn_pending`, `boss_spawn_timeout`, `boss_player_moved`, `boss_placement_invalid`, `boss_create_refused` | `spawn` refusals and placement failures. |
| `boss_kill_refused`, `boss_remove_refused` | The NPC runtime refused the operation. |

Other reasons come from the generic NPC API, for example a difficulty value out of range.

## Generic NPC difficulty APIs

The difficulty model is not Chimera-specific. Server resources with the `world.npcs` permission can use it on NPCs they own:

| API | Description |
| --- | --- |
| `Open77.npcs.setDifficulty(id, difficulty)` | Partially updates `{ healthMultiplier, damageMultiplier }`. |
| `Open77.npcs.getDifficulty(id)` | Returns `{ healthMultiplier, damageMultiplier }`. |
| `Open77.npcs.applyCrossfireDamage(victimId, attackerId, amount, source?, cause?)` | NPC-to-NPC damage scaled by the attacker's damage multiplier and the victim's health multiplier. Both NPCs must belong to the caller. |

The low-level aliases are `GetNpcDifficulty(id)` and `CrossfireNpc(victimId, attackerId, amount, source, cause)`. For a Chimera, use the provider's exports instead: they keep the phase, repair and weak-spot state consistent.

## Known limitations

- Chimera is the only boss profile. Other bosses need their own provider.
- The native Metalstorm turret deployment is unresolved: on the host and on observers, its fire can come from the hull.
- `create` does not check the navmesh, and `spawn` checks a level path rather than the whole footprint.
- Combat presentation is sent to players within 250 metres of the boss.
- A recreated boss has a new ID; scripts must follow the returned ID.

## Related guides

- [NPC spawning](https://open2077.net/docs/npcs): the NPC API underneath, combat groups and damage policies.
- [Writing a gamemode](https://open2077.net/docs/writing-a-gamemode): structure a mode around encounters.
- [Cross-resource server exports](https://open2077.net/docs/server-exports): calling `open77_chimera` safely.
- [The UI kit](https://open2077.net/docs/ui-kit): the widgets the lab menu uses.
- [op77_map3d](https://open2077.net/docs/map3d): mark the raid on the 3D map and jam the map inside the arena.
