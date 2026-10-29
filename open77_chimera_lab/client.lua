local KIT = "open77_uikit"
local sequence, answers, running = 0, {}, false

RegisterNetEvent("open77:chimeraLab:response", function(id, value, reason)
    if answers[id] == false then answers[id] = { value = value, reason = reason } end
end)

local function request(op, fields)
    sequence = sequence % 2147483647 + 1
    local id = sequence
    fields = fields or {}; fields.op = op
    answers[id] = false
    local sent, why = TriggerServerEvent("open77:chimeraLab:request", id, fields)
    if sent == false then answers[id] = nil; return nil, why or "network_unavailable" end
    local deadline = Open77.time.monotonic() + 8
    while answers[id] == false and Open77.time.monotonic() < deadline do Wait(50) end
    local answer = answers[id]; answers[id] = nil
    if not answer then return nil, "server_response_timeout" end
    return answer.value, answer.reason
end
local function kit(method, ...)
    local promise, reason = Open77.exports.call(KIT, method, ...)
    if not promise then return nil, reason end
    return promise:await()
end
local function notice(title, message)
    local _, reason = kit("alert", { title = title, message = tostring(message or "Unknown error"), confirm = "OK", tone = "warning" })
    if reason then print("[chimera lab] " .. tostring(reason) .. ": " .. tostring(message)) end
end
local function menu(id, title, description, options)
    local registered, reason = kit("menu", { id = id, title = title, description = description, options = options })
    if not registered then notice("Menu unavailable", reason); return nil end
    local answer, showReason = kit("showMenu", id)
    if not answer then notice("Menu unavailable", showReason); return nil end
    return answer.ok and answer.value and answer.value.id or nil
end
local function confirm(title, message)
    local answer, reason = kit("alert", { title = title, message = message, confirm = "Confirm", cancel = "Cancel", tone = "danger" })
    if not answer then notice("Confirmation unavailable", reason); return false end
    return answer.ok == true
end
local function form(title, fields)
    local answer, reason = kit("input", { title = title, fields = fields, confirm = "Apply", cancel = "Cancel" })
    if not answer then notice("Input unavailable", reason); return nil end
    return answer.ok and answer.value or nil
end
local function fmt(value)
    return type(value) == "number" and string.format("%.2f", value) or "?"
end
local function text(value)
    return tostring(value or "unknown"):gsub("[%c]", " "):sub(1, 64)
end
local function spawn()
    local data, reason = request("spawn")
    if not data then notice("Spawn refused", reason); return end
    local deadline = Open77.time.monotonic() + 15
    while Open77.time.monotonic() < deadline do
        Wait(500)
        local result, failure = request("result", { requestId = data.requestId })
        if not result then notice("Spawn failed", failure); return end
        if result.status == "created" then return result.id end
        if result.status == "failed" then notice("Spawn failed", result.reason); return end
    end
    notice("Spawn still pending", "The provider has not finished placement. Refresh the list to check again.")
end
local function action(op, id, args)
    args = args or {}; args.id = id
    local result, reason = request(op, args)
    if not result then notice("Action failed", reason); return nil end
    return result
end
local function pickPhase(id, profiles)
    local phases = {}
    for _, profile in ipairs(profiles or {}) do
        if profile.id == "chimera" then phases = profile.phases or {}; break end
    end
    local options, map = {}, {}
    for i, phase in ipairs(phases) do
        local key = "phase" .. i
        options[#options + 1] = { id = key, label = text(phase.label) }
        map[key] = phase.id
    end
    if #options == 0 then notice("Phases unavailable", "The provider returned no phases."); return nil end
    local choice = menu("chimera_phase", "Set phase", "Earlier phases recreate the boss with a new ID.", options)
    if choice and map[choice] then return action("setPhase", id, { value = map[choice] }) end
end
local function pickTarget(id, candidates)
    candidates = candidates or {}
    local page, pages = 1, math.max(1, math.ceil(#candidates / 60))
    while true do
        local options, map = { { id = "native", label = "Native AI selection" } }, {}
        for i = (page - 1) * 60 + 1, math.min(page * 60, #candidates) do
            local player, key = candidates[i], "player" .. i
            options[#options + 1] = { id = key, label = text(player.name) .. " (#" .. tostring(player.id) .. ")" }
            map[key] = player.id
        end
        if page > 1 then options[#options + 1] = { id = "previous", label = "Previous page" } end
        if page < pages then options[#options + 1] = { id = "next", label = "Next page" } end
        local choice = menu("chimera_target", "Choose target", "Ready, living players within 60 m. Page " .. page .. " of " .. pages .. ".", options)
        if choice == "native" then return action("setTarget", id, {}) end
        if choice == "previous" then page = page - 1
        elseif choice == "next" then page = page + 1
        elseif choice and map[choice] then return action("setTarget", id, { playerId = map[choice] })
        else return nil end
    end
end
local function policy(id)
    local choice = menu("chimera_policy", "Damage policy", "Configured policy resumes after repair.", {
        { id = "mortal", label = "Mortal" }, { id = "immortal", label = "Immortal" },
        { id = "invulnerable", label = "Invulnerable" },
    })
    if choice then return action("setDamagePolicy", id, { value = choice }) end
end
local function settings(id, boss, targets, profiles)
    local choice = menu("chimera_settings", "Boss controls", "Changes apply to the selected boss.", {
        { id = "phase", label = "Phase" }, { id = "health", label = "Current and maximum health" },
        { id = "difficulty", label = "Difficulty multipliers" }, { id = "target", label = "Target" },
        { id = "policy", label = "Damage policy" },
        { id = "ai", label = "AI: " .. (boss.aiEnabled and "on" or "off") },
        { id = "combat", label = "Combat: " .. (boss.combatEnabled and "on" or "off") },
        { id = "damage", label = "Apply exact damage" }, { id = "back", label = "Back" },
    })
    if choice == "phase" then return pickPhase(id, profiles)
    elseif choice == "target" then return pickTarget(id, targets)
    elseif choice == "policy" then return policy(id)
    elseif choice == "ai" then return action("setAIEnabled", id, { value = not boss.aiEnabled })
    elseif choice == "combat" then return action("setCombatEnabled", id, { value = not boss.combatEnabled })
    elseif choice == "health" then
        local v = form("Set health", {
            { id = "health", type = "text", label = "Current health", max = 32, default = tostring(boss.health), required = true },
            { id = "maxHealth", type = "text", label = "Maximum health", max = 32, default = tostring(boss.maxHealth), required = true },
        })
        if v then return action("setHealth", id, { health = tonumber(v.health), maxHealth = tonumber(v.maxHealth) }) end
    elseif choice == "difficulty" then
        local d = boss.difficulty or {}
        local v = form("Set difficulty", {
            { id = "health", type = "number", label = "Health multiplier", min = 0.01, max = 100, step = 0.01, default = d.healthMultiplier, required = true },
            { id = "damage", type = "number", label = "Damage multiplier", min = 0, max = 100, step = 0.01, default = d.damageMultiplier, required = true },
        })
        if v then return action("setDifficulty", id, { healthMultiplier = v.health, damageMultiplier = v.damage }) end
    elseif choice == "damage" then
        local v = form("Apply damage", {
            { id = "amount", type = "text", label = "Exact damage", max = 32, required = true },
        })
        if v then return action("applyDamage", id, { amount = tonumber(v.amount) }) end
    end
end
local function bossMenu(id, profiles)
    while id do
        local data, reason = request("get", { id = id })
        if not data then notice("Boss unavailable", reason); return nil end
        local b, t = data.boss, data.boss.target or {}
        local d, a = b.difficulty or {}, b.authority or {}
        local policies = { [0] = "mortal", [1] = "immortal", [2] = "invulnerable" }
        local description = string.format("Health %s / %s | %s%s | Host %s | H %s / D %s | %s | Target %s %s (actual %s)",
            fmt(b.health), fmt(b.maxHealth), text(b.phase), b.repairing and " (repairing)" or "", text(a.playerId),
            fmt(d.healthMultiplier), fmt(d.damageMultiplier), text(policies[b.damagePolicy] or b.damagePolicy),
            text(t.mode), text(t.playerId), text(t.actualPlayerId))
        local choice = menu("chimera_boss", text(b.label) .. " #" .. id, description, {
            { id = "controls", label = "Boss controls" }, { id = "spawn", label = "Spawn another" },
            { id = "reset", label = "Reset to armored", tone = "danger" },
            { id = "kill", label = "Kill", tone = "danger" },
            { id = "remove", label = "Despawn", tone = "danger" },
            { id = "refresh", label = "Refresh" }, { id = "back", label = "Back to bosses" },
        })
        if not choice or choice == "back" then return nil end
        local result
        if choice == "controls" then result = settings(id, b, data.targets, profiles)
        elseif choice == "spawn" then spawn()
        elseif choice == "reset" and confirm("Reset boss?", "This recreates the boss with a new ID.") then result = action("reset", id)
        elseif choice == "kill" and confirm("Kill boss?", "This kills the boss; it does not despawn it.") then result = action("kill", id)
        elseif choice == "remove" and confirm("Despawn boss?", "This removes the selected boss.") then
            result = action("remove", id); if result then return nil end
        end
        if result and result.boss and result.boss.id then id = result.boss.id end
    end
end
local function run()
    local page = 1
    while true do
        local data, reason = request("list")
        if not data then notice("Boss list unavailable", reason); return end
        local bosses, options, map = data.bosses or {}, { { id = "spawn", label = "Spawn Chimera" } }, {}
        local pages = math.max(1, math.ceil(#bosses / 60))
        page = math.min(page, pages)
        for index = (page - 1) * 60 + 1, math.min(page * 60, #bosses) do
            local b = bosses[index]; local key = "boss" .. index
            options[#options + 1] = { id = key, label = text(b.label) .. " #" .. tostring(b.id),
                description = text(b.phase) .. " | " .. fmt(b.health) .. " / " .. fmt(b.maxHealth) }
            map[key] = b.id
        end
        if page > 1 then options[#options + 1] = { id = "previous", label = "Previous page" } end
        if page < pages then options[#options + 1] = { id = "next", label = "Next page" } end
        local description = #bosses == 0 and "No lab-owned bosses in this bucket. Spawn one to begin." or
            ("Lab-owned bosses in your bucket. Page " .. page .. " of " .. pages .. ".")
        local choice = menu("chimera_list", "Chimera lab", description, options)
        if not choice then return end
        if choice == "spawn" then local id = spawn(); if id then bossMenu(id, data.profiles) end
        elseif choice == "previous" then page = page - 1
        elseif choice == "next" then page = page + 1
        elseif map[choice] then bossMenu(map[choice], data.profiles) end
    end
end
RegisterNetEvent("open77:chimeraLab:open", function()
    if running then return end
    running = true
    CreateThread(function()
        local ok, reason = pcall(run)
        running = false
        if not ok then print("[chimera lab] " .. tostring(reason)) end
    end)
end)
