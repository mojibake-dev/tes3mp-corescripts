-- slaveFreedomSync.lua  (v2: exact identification via OnObjectActivate)
-- [mojibake] Make a freed slave vanish for EVERYONE, matching vanilla's disable-on-cell-change.
--
-- "Freed" is the vanilla local slaveScript var slaveStatus==3 (a dialogue result sets it), which
-- TES3MP can't sync. We reproduce the removal server-side:
--   * IDENTIFY (exact): talking to an NPC is a server round-trip, so OnObjectActivate hands us the
--     exact target uniqueIndex + refId + the real activating pid (packetReader ObjectActivate ->
--     object.activatingPid). We remember, per player, the slave-refId NPCs they activate.
--   * COMMIT: freeing is a dialogue result that bumps the worldwide global freedslavescounter, so a
--     rise for pid means "the slave pid most-recently activated was just freed." We register that
--     exact uniqueIndex for removal (no geometry, no nearest-guess).
--   * REMOVE on the freer's next cell-change (vanilla timing): logicHandler.DeleteObject(pid, cell,
--     ui, true). This works even for a BASE NPC never recorded in objectData (it inserts into
--     packets.delete whenever the refNum > 0), and LoadObjectsDeleted re-applies it on every cell
--     load, so relogs/late-joiners never see the slave. periodicCellResets preserves packets.delete
--     so a reset can't resurrect it.
--
-- v1 used a nearest/facing-cone guess that mis-targeted, double-registered across players, and
-- missed stationary slaves with no synced .location. This replaces the guess with the activation.

local SLAVE_REFIDS = {
    ["abanji"]=true, ["adharanji"]=true, ["affri"]=true, ["ah-meesei"]=true, ["ahaht"]=true, ["ahdahni"]=true,
    ["ahdni"]=true, ["ahdri"]=true, ["ahjara"]=true, ["ahndahra"]=true, ["ahnisa"]=true, ["ahzini"]=true,
    ["aina"]=true, ["akish"]=true, ["am-ra"]=true, ["anjari"]=true, ["arabhi"]=true, ["aravi"]=true,
    ["argonian slave female"]=true, ["argonian slave male"]=true, ["ashidasha"]=true, ["asum"]=true, ["baadargo"]=true, ["bahdahna"]=true,
    ["bahdrashi"]=true, ["banalz"]=true, ["beekatan"]=true, ["bhusari"]=true, ["breech-star"]=true, ["bun-teemeeta"]=true,
    ["bunish"]=true, ["cattle_kha_f01"]=true, ["chalureel"]=true, ["cheesh-meeus"]=true, ["chiwish"]=true, ["ciralinde"]=true,
    ["dahleena"]=true, ["dahnara"]=true, ["davina"]=true, ["deesh-meeus"]=true, ["dreaded_water"]=true, ["dro'qanar"]=true,
    ["ekapi"]=true, ["el-lurasha"]=true, ["eutei"]=true, ["gah_julan"]=true, ["gih-ja"]=true, ["gilm"]=true,
    ["gish"]=true, ["grey_throat"]=true, ["han-tulm"]=true, ["haran"]=true, ["harassa"]=true, ["heedul"]=true,
    ["heir-zish"]=true, ["high-heart"]=true, ["huzei"]=true, ["idhassi"]=true, ["inee"]=true, ["inerri"]=true,
    ["inorra"]=true, ["j'jarsha"]=true, ["j'jazha"]=true, ["j'kara"]=true, ["j'oren_dar"]=true, ["j'raksa"]=true,
    ["j'ram-dar"]=true, ["j'zamha"]=true, ["jadier mannick"]=true, ["jeed-ei"]=true, ["jeelus-tei"]=true, ["jeer-maht"]=true,
    ["kaasha"]=true, ["kal_ma"]=true, ["kasa"]=true, ["khajit slave male"]=true, ["khamuzi"]=true, ["khazura"]=true,
    ["kiseena"]=true, ["kishni"]=true, ["kisimba"]=true, ["kisisa"]=true, ["m'shan"]=true, ["ma'dara"]=true,
    ["ma'jidarr"]=true, ["ma'khar"]=true, ["ma'zahn"]=true, ["manilian scerius"]=true, ["meeh-mei"]=true, ["meen-sa"]=true,
    ["meer"]=true, ["menelras"]=true, ["milah"]=true, ["mim-jeen"]=true, ["morning_clouds"]=true, ["muz-ra"]=true,
    ["nakuma"]=true, ["nam-la"]=true, ["neesha"]=true, ["neetinei"]=true, ["nisaba"]=true, ["nuralg"]=true,
    ["okaw"]=true, ["olank-neeus"]=true, ["oleen-gei"]=true, ["olink-nur"]=true, ["on-wazei"]=true, ["on_wan"]=true,
    ["peeradeeh"]=true, ["ra'karim"]=true, ["ra'mhirr"]=true, ["ra'sava"]=true, ["ra'zahr"]=true, ["reemukeeus"]=true,
    ["reesa"]=true, ["ri'darsha"]=true, ["ri'dumiwa"]=true, ["ri'vassa"]=true, ["ri'zaadha"]=true, ["s'bakha"]=true,
    ["s'rava"]=true, ["s'raverr"]=true, ["s'renji"]=true, ["s'vandra"]=true, ["seewul"]=true, ["servant arg male"]=true,
    ["shaba"]=true, ["shatalg"]=true, ["shivani"]=true, ["sholani"]=true, ["smart_snake"]=true, ["stream-murk"]=true,
    ["tanan"]=true, ["tasha"]=true, ["teegla"]=true, ["tern-feather"]=true, ["tim-jush"]=true, ["tsabhi"]=true,
    ["tsajadhi"]=true, ["tsalani"]=true, ["tsani"]=true, ["twice_bitten"]=true, ["ubaasi"]=true, ["udarra"]=true,
    ["ula"]=true, ["unjara"]=true, ["wanan_dum"]=true, ["weeltul"]=true, ["weer"]=true, ["wih-eius"]=true,
    ["wud-neeus"]=true, ["wuleen-shei"]=true, ["wusha"]=true, ["zahraji"]=true,
}

local Methods = {}
local RING_MAX = 8

local lastFreedCount = nil          -- in-memory tracker of the shared freedslavescounter
local activatedByPid = {}           -- [pid] = { {cell, ui, refId}, ... }  most-recent last
local pendingByFreer = {}           -- [pid] = { {cell, ui, refId}, ... }  awaiting the freer's cell-change
local handled = {}                  -- [cell.."\0"..ui] = true  (global dedup, prevents wrong/double delete)

local function log(level, msg) tes3mp.LogMessage(level, "[slaveFreedomSync] " .. msg) end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log(enumerations.log.ERROR, name .. " error (server kept alive): " .. tostring(err)) end
    end
end

local function isSlave(refId) return refId ~= nil and SLAVE_REFIDS[string.lower(refId)] == true end

local function worldFreedCount()
    local cv = WorldInstance.data.clientVariables
    if cv and cv.globals and cv.globals.freedslavescounter and cv.globals.freedslavescounter.intValue then
        return cv.globals.freedslavescounter.intValue
    end
    return 0
end

local function registerPending(pid, cell, ui, refId)
    local key = cell .. "\0" .. ui
    if handled[key] then return false end
    handled[key] = true
    pendingByFreer[pid] = pendingByFreer[pid] or {}
    table.insert(pendingByFreer[pid], { cell = cell, ui = ui, refId = refId })
    log(enumerations.log.INFO, "pending removal: " .. ui .. " (" .. tostring(refId) .. ") in " .. cell)
    return true
end

-- Fallback only (no activation recorded / mass rebellion): nearest recorded slave-refIds to (x,y,z).
local function nearestSlaves(cell, x, y, z, n)
    local c = LoadedCells[cell]
    if c == nil or c.data == nil or c.data.objectData == nil then return {} end
    local cands = {}
    for ui, obj in pairs(c.data.objectData) do
        if isSlave(obj.refId) and obj.location and not handled[cell .. "\0" .. ui] then
            local dx, dy, dz = (obj.location.posX or 0) - x, (obj.location.posY or 0) - y, (obj.location.posZ or 0) - z
            table.insert(cands, { ui = ui, refId = obj.refId, d2 = dx*dx + dy*dy + dz*dz })
        end
    end
    table.sort(cands, function(a, b) return a.d2 < b.d2 end)
    local out = {}
    for i = 1, math.min(n, #cands) do table.insert(out, cands[i]) end
    return out
end

-- 1. Remember which slave each player is talking to (exact identity, no geometry).
Methods.OnObjectActivate = function(eventStatus, pid, cellDescription, objects, targetPlayers)
    if objects == nil then return end
    for uniqueIndex, object in pairs(objects) do
        if isSlave(object.refId) then
            local ring = activatedByPid[pid]
            if ring == nil then ring = {}; activatedByPid[pid] = ring end
            table.insert(ring, { cell = cellDescription, ui = uniqueIndex, refId = object.refId })
            while #ring > RING_MAX do table.remove(ring, 1) end
        end
    end
end

-- 2. freedslavescounter rose for pid -> register the slave(s) they just freed.
Methods.OnClientScriptGlobal = function(eventStatus, pid, variables)
    if variables == nil then return end
    local newVal = nil
    for id, v in pairs(variables) do
        if type(id) == "string" and string.lower(id) == "freedslavescounter" and type(v) == "table" and v.intValue then
            newVal = v.intValue
        end
    end
    if newVal == nil then return end
    if lastFreedCount == nil then lastFreedCount = worldFreedCount() end
    local delta = newVal - lastFreedCount
    if delta <= 0 then if newVal > lastFreedCount then lastFreedCount = newVal end return end
    lastFreedCount = newVal

    local needed = delta
    -- primary: the most-recently activated slaves by this pid
    local ring = activatedByPid[pid]
    if ring ~= nil then
        for i = #ring, 1, -1 do
            if needed <= 0 then break end
            local a = ring[i]
            if registerPending(pid, a.cell, a.ui, a.refId) then needed = needed - 1 end
            table.remove(ring, i)
        end
    end
    -- fallback: nearest recorded slaves in the freer's cell (mass rebellion / no activation seen)
    if needed > 0 and Players[pid] ~= nil and Players[pid]:IsLoggedIn() then
        local cell = Players[pid].data.location.cell
        if cell ~= nil then
            local x, y, z = tes3mp.GetPosX(pid), tes3mp.GetPosY(pid), tes3mp.GetPosZ(pid)
            for _, s in ipairs(nearestSlaves(cell, x, y, z, needed)) do
                if registerPending(pid, cell, s.ui, s.refId) then needed = needed - 1 end
            end
        end
    end
    if needed > 0 then
        log(enumerations.log.WARN, logicHandler.GetChatName(pid) .. " freed " .. delta ..
            " but " .. needed .. " could not be identified (no activation + not in objectData)")
    end
end

-- 3. Remove the freed slave(s) for everyone when the freer next changes cells / disconnects.
local function flush(pid)
    local list = pendingByFreer[pid]
    if list == nil then return end
    pendingByFreer[pid] = nil
    for _, e in ipairs(list) do
        local weLoaded = false
        if LoadedCells[e.cell] == nil then logicHandler.LoadCell(e.cell); weLoaded = true end
        local cell = LoadedCells[e.cell]
        if cell ~= nil then
            if cell.data.objectData[e.ui] == nil then cell:InitializeObjectData(e.ui, e.refId) end
            logicHandler.DeleteObject(pid, e.cell, e.ui, true)
            log(enumerations.log.INFO, "removed freed slave " .. e.ui .. " in " .. e.cell .. " for everyone")
        else
            log(enumerations.log.WARN, "could not load " .. e.cell .. " to remove " .. e.ui)
        end
        if weLoaded then logicHandler.UnloadCell(e.cell) end
    end
end

Methods.OnPlayerCellChange = function(eventStatus, pid) flush(pid) end
Methods.OnPlayerDisconnect = function(eventStatus, pid) flush(pid); activatedByPid[pid] = nil end

customEventHooks.registerHandler("OnServerPostInit", safe("OnServerPostInit", function()
    lastFreedCount = worldFreedCount()
    log(enumerations.log.INFO, "armed (v2 OnObjectActivate); freedslavescounter baseline = " .. tostring(lastFreedCount))
end))
customEventHooks.registerHandler("OnObjectActivate", safe("OnObjectActivate", Methods.OnObjectActivate))
customEventHooks.registerHandler("OnClientScriptGlobal", safe("OnClientScriptGlobal", Methods.OnClientScriptGlobal))
customEventHooks.registerHandler("OnPlayerCellChange", safe("OnPlayerCellChange", Methods.OnPlayerCellChange))
customEventHooks.registerHandler("OnPlayerDisconnect", safe("OnPlayerDisconnect", Methods.OnPlayerDisconnect))

return Methods
