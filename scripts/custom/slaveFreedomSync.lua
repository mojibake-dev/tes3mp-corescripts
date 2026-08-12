-- slaveFreedomSync.lua
-- [mojibake] Make a freed slave vanish for EVERYONE, matching vanilla's disable-on-cell-change.
--
-- Vanilla "freed" is the local slaveScript var slaveStatus == 3 (set by a dialogue result script),
-- which TES3MP cannot sync; the vanilla script then wanders the NPC, drops its slave bracers, and
-- Disables it when its cell next reloads. We reproduce the *removal* server-side:
--   1. Trigger: the shared freedslavescounter rising (that global is now worldwide-synced, so
--      OnClientScriptGlobal fires reliably) tells us player `pid` just freed slave(s).
--   2. Identify: the nearest slaveScript NPC(s) to the freer in their current cell.
--   3. Remove on the freer's next cell-change (OnPlayerCellChange / OnPlayerDisconnect), matching
--      vanilla's timing: logicHandler.DeleteObject(..., forEveryone=true), which records the
--      deletion in the cell's `delete` packet -> LoadObjectsDeleted re-applies it on every load, so
--      relogs and late-joiners never see the slave (native persistence, no extra registry).
-- CellReset would resurrect it (it wipes the `delete` packet); periodicCellResets is patched to
-- preserve `delete`, so freed slaves stay gone through a reset.
--
-- Identification is a heuristic (nearest slave to the freer). This script logs verbosely so the
-- live 2-player test can confirm/tune it. Known edge: a jump >1 (mass rebellion, +10) removes the
-- nearest N; a slave not yet recorded in objectData at freeing-time won't be found (logged as WARN).

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

local lastFreedCount = nil          -- in-memory tracker of the shared freedslavescounter
local pendingByFreer = {}           -- [pid] = { { cell = <desc>, uniqueIndex = <ui> }, ... }

local function log(level, msg)
    tes3mp.LogMessage(level, "[slaveFreedomSync] " .. msg)
end

local function worldFreedCount()
    local cv = WorldInstance.data.clientVariables
    if cv and cv.globals and cv.globals.freedslavescounter and cv.globals.freedslavescounter.intValue then
        return cv.globals.freedslavescounter.intValue
    end
    return 0
end

-- Nearest `count` slaveScript NPCs to (x,y,z) among a loaded cell's recorded actors.
local function findNearestSlaves(cellDescription, x, y, z, count)
    local cell = LoadedCells[cellDescription]
    if cell == nil or cell.data == nil or cell.data.objectData == nil then return {} end
    local cands = {}
    for uniqueIndex, obj in pairs(cell.data.objectData) do
        if obj.refId and SLAVE_REFIDS[string.lower(obj.refId)] and obj.location then
            local dx = (obj.location.posX or 0) - x
            local dy = (obj.location.posY or 0) - y
            local dz = (obj.location.posZ or 0) - z
            table.insert(cands, { ui = uniqueIndex, d2 = dx * dx + dy * dy + dz * dz })
        end
    end
    table.sort(cands, function(a, b) return a.d2 < b.d2 end)
    local out = {}
    for i = 1, math.min(count, #cands) do table.insert(out, cands[i].ui) end
    return out
end

-- Delete a freer's pending freed slaves for everyone; load the cell briefly if it has since unloaded.
local function flush(pid)
    local list = pendingByFreer[pid]
    if list == nil then return end
    pendingByFreer[pid] = nil
    for _, e in ipairs(list) do
        local weLoaded = false
        if LoadedCells[e.cell] == nil then
            logicHandler.LoadCell(e.cell)
            weLoaded = true
        end
        local cell = LoadedCells[e.cell]
        if cell ~= nil and cell.data.objectData[e.uniqueIndex] ~= nil then
            logicHandler.DeleteObject(pid, e.cell, e.uniqueIndex, true)
            log(enumerations.log.INFO, "removed freed slave " .. e.uniqueIndex .. " in " .. e.cell .. " for everyone")
        else
            log(enumerations.log.WARN, "pending slave " .. e.uniqueIndex .. " in " .. e.cell .. " absent at flush; skipped")
        end
        if weLoaded then logicHandler.UnloadCell(e.cell) end
    end
end

customEventHooks.registerHandler("OnServerPostInit", function()
    lastFreedCount = worldFreedCount()
    log(enumerations.log.INFO, "armed; freedslavescounter baseline = " .. tostring(lastFreedCount))
end)

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
    if delta <= 0 then
        if newVal > lastFreedCount then lastFreedCount = newVal end
        return
    end
    lastFreedCount = newVal
    if Players[pid] == nil or not Players[pid]:IsLoggedIn() then return end
    local cellDescription = Players[pid].data.location.cell
    if cellDescription == nil then return end
    local x, y, z = tes3mp.GetPosX(pid), tes3mp.GetPosY(pid), tes3mp.GetPosZ(pid)
    local slaves = findNearestSlaves(cellDescription, x, y, z, delta)
    if #slaves == 0 then
        log(enumerations.log.WARN, logicHandler.GetChatName(pid) .. " freed " .. delta ..
            " but no slaveScript NPC was recorded in objectData of " .. cellDescription ..
            " (nothing to remove; identification may need tuning)")
        return
    end
    pendingByFreer[pid] = pendingByFreer[pid] or {}
    for _, ui in ipairs(slaves) do
        table.insert(pendingByFreer[pid], { cell = cellDescription, uniqueIndex = ui })
        log(enumerations.log.INFO, "pending removal: " .. ui .. " in " .. cellDescription ..
            " (freed by " .. logicHandler.GetChatName(pid) .. ", counter -> " .. newVal .. ")")
    end
end

Methods.OnPlayerCellChange = function(eventStatus, pid) flush(pid) end
Methods.OnPlayerDisconnect = function(eventStatus, pid) flush(pid) end

customEventHooks.registerHandler("OnClientScriptGlobal", Methods.OnClientScriptGlobal)
customEventHooks.registerHandler("OnPlayerCellChange", Methods.OnPlayerCellChange)
customEventHooks.registerHandler("OnPlayerDisconnect", Methods.OnPlayerDisconnect)

return Methods
