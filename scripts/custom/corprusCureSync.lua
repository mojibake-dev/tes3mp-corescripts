-- corprusCureSync: the corprus cure is a per-player script result on a shared journal.
--
-- Divayth Fyr's cure runs two script lines on the player who had the dialogue: RemoveSpell corprus, then
-- AddSpell "corprus immunity" (vanilla Morrowind.esm, the A2_3_CorprusCure results). This server shares the
-- journal across players, so everyone reaches stage 50 of the quest while only one player is cured; the others
-- keep the disease and its daily attribute drain while every NPC treats them as cured (2026-11-20: Lex cured, Eli
-- and Slime Pup not). This runs the same two lines on every player who still carries the disease once the shared
-- journal says cured: when the cure entry arrives, and for a latecomer at their first cell change after login.
-- The engine does the stat work exactly as in single player: the drains go, the Strength and Endurance gains stay.
local corprusCureSync = {}

local DISEASE = "corprus"
local IMMUNITY = "corprus immunity"
local QUEST = "a2_3_corpruscure"
local CURED_INDEX = 50
local RETRY_SECONDS = 60 -- one cure per player per minute at most, so a failing command cannot loop

local recentlyCured = {}

local function log(level, msg) tes3mp.LogMessage(level, "[corprusCureSync] " .. msg) end

local function hasSpell(pid, spellId)
    local spellbook = Players[pid].data.spellbook
    if type(spellbook) ~= "table" then return false end
    for _, id in pairs(spellbook) do
        if type(id) == "string" and string.lower(id) == spellId then return true end
    end
    return false
end

local function journalCured(pid)
    local journal = Players[pid].data.journal
    if type(journal) ~= "table" then return false end
    for _, entry in pairs(journal) do
        if type(entry) == "table" and type(entry.quest) == "string" and string.lower(entry.quest) == QUEST
            and (tonumber(entry.index) or 0) >= CURED_INDEX then
            return true
        end
    end
    return false
end

local function cure(pid, why)
    recentlyCured[pid] = os.time()
    logicHandler.RunConsoleCommandOnPlayer(pid, "player->RemoveSpell " .. DISEASE, false)
    logicHandler.RunConsoleCommandOnPlayer(pid, "player->AddSpell \"" .. IMMUNITY .. "\"", false)
    log(enumerations.log.WARN, "cured " .. logicHandler.GetChatName(pid) .. " (" .. why .. ")")
end

-- A player needs the cure when the shared journal says cured and their own spellbook still holds the disease.
local function check(pid, why)
    if Players[pid] == nil or not Players[pid]:IsLoggedIn() then return end
    if recentlyCured[pid] ~= nil and os.time() - recentlyCured[pid] < RETRY_SECONDS then return end
    if journalCured(pid) and hasSpell(pid, DISEASE) then cure(pid, why) end
end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log(enumerations.log.ERROR, name .. " failed: " .. tostring(err)) end
    end
end

-- Runs after the default handler stored the entry. The cured player's entry is shared to everyone, so every
-- logged-in player is checked, not only the one whose packet this was.
customEventHooks.registerHandler("OnPlayerJournal", safe("OnPlayerJournal", function(eventStatus, pid)
    for otherPid, _ in pairs(Players) do check(otherPid, "journal") end
end))

-- A latecomer: by the first cell change the client is in the world and can run console commands.
customEventHooks.registerHandler("OnPlayerCellChange", safe("OnPlayerCellChange", function(eventStatus, pid)
    check(pid, "login")
end))

customEventHooks.registerHandler("OnPlayerDisconnect", safe("OnPlayerDisconnect", function(eventStatus, pid)
    recentlyCured[pid] = nil
end))

return corprusCureSync
