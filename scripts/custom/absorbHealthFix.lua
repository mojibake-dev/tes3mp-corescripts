-- absorbHealthFix.lua
-- [mojibake] Fixes TES3MP issue #603: Absorb Health drains the target but does NOT heal the caster
-- when the caster lacks the target cell's authority (the heal-side effectTick only runs on the
-- authoritative client; when another player is authority, only the drain-side stat sync wins).
--
-- The data IS reachable: OpenMW mirrors the absorbed effect onto the CASTER as an ActiveSpell
-- (linkedeffects.cpp) which emits ID_PLAYER_SPELLS_ACTIVE. So the caster's own packet carries an
-- ABSORB_HEALTH (86) effect whose caster.pid == the caster. We restore the caster's health server-
-- side, but ONLY when they are NOT the cell authority (else the engine already healed them locally,
-- and an unconditional heal would double).
--
-- Conservative + observable: heals by |magnitude| (never damages), capped at base health, on the ADD
-- action (once per cast). It logs every self-absorb (action, magnitude, authority) so the exact
-- semantics can be confirmed live and tuned (e.g. lasting-duration absorbs, which currently heal by
-- the base magnitude only, and the ADD-action value below).

local AbsorbHealthFix = {}

-- spellsActive change action follows the SET=0 / ADD=1 / REMOVE=2 convention. Confirmed via the
-- diagnostic log below if it ever differs.
local ADD_ACTION = 1

local function log(level, msg) tes3mp.LogMessage(level, "[absorbHealthFix] " .. msg) end

AbsorbHealthFix.OnPlayerSpellsActive = function(eventStatus, pid, playerPacket)
    if playerPacket == nil or playerPacket.spellsActive == nil then return end
    local caster = Players[pid]
    if caster == nil or not caster:IsLoggedIn() then return end

    -- Sum the caster's OWN Absorb Health magnitude in this packet (caster.pid == pid = self-cast mirror).
    local heal = 0
    for _spellId, instances in pairs(playerPacket.spellsActive) do
        for _, inst in ipairs(instances) do
            if inst.hasPlayerCaster == true and inst.caster ~= nil and inst.caster.pid == pid then
                for _, eff in ipairs(inst.effects or {}) do
                    if eff.id == enumerations.effects.ABSORB_HEALTH then
                        heal = heal + math.abs(eff.magnitude or 0)
                    end
                end
            end
        end
    end
    if heal <= 0 then return end

    local cellDescription = caster.data.location.cell
    local authority = nil
    if cellDescription ~= nil and LoadedCells[cellDescription] ~= nil then
        authority = LoadedCells[cellDescription]:GetAuthority()
    end

    -- Diagnostic: always log a self-absorb so magnitude / action / authority can be verified live.
    log(enumerations.log.INFO, "self-absorb by " .. logicHandler.GetChatName(pid) .. " action=" ..
        tostring(playerPacket.action) .. " heal=" .. heal .. " cellAuthority=" .. tostring(authority))

    -- Only restore once per cast (ADD) and only when the caster is NOT authority (engine did not heal).
    if playerPacket.action ~= ADD_ACTION then return end
    if authority == pid then return end

    local newHp = math.min(tes3mp.GetHealthBase(pid), tes3mp.GetHealthCurrent(pid) + heal)
    tes3mp.SetHealthCurrent(pid, newHp)
    tes3mp.SendStatsDynamic(pid)
    log(enumerations.log.INFO, "  -> restored caster to " .. newHp)
end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log(enumerations.log.ERROR, name .. " error (server kept alive): " .. tostring(err)) end
    end
end

customEventHooks.registerHandler("OnPlayerSpellsActive", safe("OnPlayerSpellsActive", AbsorbHealthFix.OnPlayerSpellsActive))

return AbsorbHealthFix
