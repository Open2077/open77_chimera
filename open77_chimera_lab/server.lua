-- Only this adapter knows the provider name; all boss operations use its public exports.
local PROVIDER = "open77_chimera"
local pending = {}

local function allowed(player)
    return type(player) == "number" and player > 0 and Open77.acl ~= nil and
        Open77.acl.isAllowed(player, "command.chimera") == true
end
local function call(method, ...)
    local ok, value, reason = pcall(Open77.exports.callSync, PROVIDER, method, ...)
    if not ok then return nil, tostring(value) end
    return value, reason
end
local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end
local function playerPosition(id)
    local read = Open77.players.get(id)
    local life = Open77.players.getLifeState(id)
    if not read or not read.ready or not life or life.phase ~= "alive" then return nil end
    return Open77.players.position(id)
end
local function targets(boss)
    local out = {}
    for _, raw in ipairs(Open77.players.all() or {}) do
        local id = tonumber(raw)
        local p = id and playerPosition(id)
        local at = boss.position
        if p and at and p.bucket == boss.bucket and
            (p.x-at.x)^2 + (p.y-at.y)^2 + (p.z-at.z)^2 <= 3600 then
            out[#out + 1] = { id = id, name = Open77.players.name(id) or ("Player " .. id) }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end
local function ownedInBucket(id, bucket)
    if type(id) ~= "string" or #id == 0 or #id > 64 then return nil, "invalid_boss_id" end
    local state, reason = call("get", id)
    if not state then return nil, reason or "boss_not_found" end
    if state.bucket ~= bucket then return nil, "boss_in_other_bucket" end
    return state
end

local function handle(player, request)
    if not allowed(player) then return nil, "permission_denied:command.chimera" end
    if type(request) ~= "table" or type(request.op) ~= "string" then return nil, "invalid_request" end
    local pos = Open77.players.position(player)
    if not pos then return nil, "player_position_unavailable" end
    local op = request.op
    if op == "list" then
        local list, err = call("list", { bucket = pos.bucket })
        if not list then return nil, err end
        local profiles, profileError = call("profiles")
        if not profiles then return nil, profileError end
        return { bosses = list, profiles = profiles }
    elseif op == "spawn" then
        if not playerPosition(player) then return nil, "player_not_ready" end
        local id, err = call("spawn", player, { profile = "chimera" })
        if not id then return nil, err end
        pending[player] = id
        return { requestId = id }
    elseif op == "result" then
        local id = pending[player]
        if id == nil or request.requestId ~= id then return nil, "unknown_spawn_request" end
        local result, err = call("result", id)
        if not result then pending[player] = nil; return nil, err end
        if result.status ~= "pending" then pending[player] = nil end
        return result
    end

    local boss, err = ownedInBucket(request.id, pos.bucket)
    if not boss then return nil, err end
    if op == "get" then return { boss = boss, targets = targets(boss) } end
    local value
    if op == "remove" or op == "kill" or op == "reset" then
        value, err = call(op, boss.id)
    elseif op == "setPhase" then
        if request.value ~= "armored" and request.value ~= "exposed" and request.value ~= "gas" and request.value ~= "core" then
            return nil, "invalid_phase"
        end
        value, err = call(op, boss.id, request.value)
    elseif op == "setHealth" then
        if not finite(request.health) or not finite(request.maxHealth) or request.maxHealth <= 0 or
            request.maxHealth > 100000 or request.health < 0 or request.health > request.maxHealth then return nil, "invalid_health" end
        value, err = call(op, boss.id, request.health, request.maxHealth)
    elseif op == "setDifficulty" then
        local h, d = request.healthMultiplier, request.damageMultiplier
        if not finite(h) or h < 0.01 or h > 100 or not finite(d) or d < 0 or d > 100 then
            return nil, "invalid_difficulty"
        end
        value, err = call(op, boss.id, { healthMultiplier = h, damageMultiplier = d })
    elseif op == "applyDamage" then
        if not finite(request.amount) or request.amount <= 0 then return nil, "invalid_damage" end
        value, err = call(op, boss.id, request.amount)
    elseif op == "setDamagePolicy" then
        local policies = Open77.npcs.damage
        local policy = type(request.value) == "string" and policies[request.value] or nil
        if policy == nil or (request.value ~= "mortal" and request.value ~= "immortal" and request.value ~= "invulnerable") then
            return nil, "invalid_damage_policy"
        end
        value, err = call(op, boss.id, policy)
    elseif op == "setAIEnabled" or op == "setCombatEnabled" then
        if type(request.value) ~= "boolean" then return nil, "invalid_boolean" end
        value, err = call(op, boss.id, request.value)
    elseif op == "setTarget" then
        local target = request.playerId
        if target ~= nil then
            if not finite(target) or target < 1 or target % 1 ~= 0 then return nil, "invalid_target" end
            local found = false
            for _, candidate in ipairs(targets(boss)) do if candidate.id == target then found = true; break end end
            if not found then return nil, "target_not_nearby_or_ready" end
        end
        value, err = call(op, boss.id, target)
    else
        return nil, "unknown_action"
    end
    if not value then return nil, err or "action_failed" end
    return { boss = type(value) == "table" and value or nil, removed = op == "remove" }
end

RegisterCommand("chimera", function(player)
    if not allowed(player) then return end
    TriggerClientEvent("open77:chimeraLab:open", player)
end, true)

RegisterNetEvent("open77:chimeraLab:request", function(sequence, request)
    local player = source
    if type(sequence) ~= "number" or sequence % 1 ~= 0 or sequence < 1 or sequence > 2147483647 then return end
    local result, reason = handle(player, request)
    TriggerClientEvent("open77:chimeraLab:response", player, sequence, result, reason)
end)
AddEventHandler("onPlayerDisconnected", function(player) pending[tonumber(player)] = nil end)
