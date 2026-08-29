-- absorbHealthFix.lua
-- [mojibake] Fixes TES3MP #603: Absorb Health drains the target but does NOT heal the caster
-- when the caster is not the target's authority.
--
-- ROOT CAUSE (corrected model): OpenMW mirrors the caster's heal-side as a linked effect
-- (mwmechanics/linkedeffects.cpp), but in multiplayer that mirror never reliably rides the
-- CASTER's own packet. The absorb reaches the server on the TARGET's packet: a player target ->
-- that player's PlayerSpellsActive; an NPC/creature target -> the cell owner's ActorSpellsActive.
-- In both, the absorb instance has hasPlayerCaster=true and caster.pid = the caster, with the
-- drain magnitude POSITIVE. (The previous patch keyed on caster.pid == the packet owner, the one
-- shape that never occurs, so it never fired -- confirmed by an empty diagnostic log across a full
-- day of casting.)
--
-- FIX: on an ADD action, for each ABSORB_HEALTH (86) instance with a player caster whose
-- caster.pid ~= the packet owner (the target/sender), heal that caster by sum(magnitude*duration),
-- capped at their base health. "caster.pid ~= ownerPid" IS the anti-double-heal condition: a
-- client only emits a packet for what it owns, and only heals the caster locally when it owns the
-- target, so if the caster IS the sender the engine already healed them locally -> skip.
--   PvP:            owner = target player, caster ~= owner -> heal (never healed locally). OK.
--   PvE, caster is authority: owner = caster -> caster.pid == owner -> skip (already healed). OK.
--   PvE, other authority:     owner = that player, caster ~= owner -> heal. OK.

local AbsorbHealthFix = {}

local ADD_ACTION = 1   -- SpellsActive change action: SET=0 / ADD=1 / REMOVE=2

local function log(level, msg) tes3mp.LogMessage(level, "[absorbHealthFix] " .. msg) end

-- Sum each caster's Absorb Health across one spellsActive map. ownerPid = the packet owner (the
-- drained player, or the actor-cell authority). Returns { [casterPid] = healAmount }.
local function collectHeals(spellsActive, ownerPid)
    local heals = {}
    for _spellId, instances in pairs(spellsActive or {}) do
        for _, inst in ipairs(instances) do
            if inst.hasPlayerCaster == true and inst.caster ~= nil
               and inst.caster.pid ~= nil and inst.caster.pid ~= ownerPid then
                local sum = 0
                for _, eff in ipairs(inst.effects or {}) do
                    if eff.id == enumerations.effects.ABSORB_HEALTH and (eff.magnitude or 0) > 0 then
                        -- total transferred = magnitude (points/sec) * duration (sec)
                        sum = sum + (eff.magnitude * math.max(eff.duration or 1, 1))
                    end
                end
                if sum > 0 then
                    heals[inst.caster.pid] = (heals[inst.caster.pid] or 0) + sum
                end
            end
        end
    end
    return heals
end

local function applyHeals(heals, ownerPid, source)
    for casterPid, heal in pairs(heals) do
        local caster = Players[casterPid]
        if caster ~= nil and caster:IsLoggedIn() then
            local newHp = math.min(tes3mp.GetHealthBase(casterPid),
                                   tes3mp.GetHealthCurrent(casterPid) + heal)
            tes3mp.SetHealthCurrent(casterPid, newHp)
            tes3mp.SendStatsDynamic(casterPid)
            log(enumerations.log.INFO, string.format(
                "healed %s +%.1f -> %.1f (absorb via %s target, owner pid %s)",
                logicHandler.GetChatName(casterPid), heal, newHp, source, tostring(ownerPid)))
        end
    end
end

-- Player target: the drained player's own PlayerSpellsActive packet.
AbsorbHealthFix.OnPlayerSpellsActive = function(eventStatus, pid, playerPacket)
    if playerPacket == nil or playerPacket.action ~= ADD_ACTION then return end
    applyHeals(collectHeals(playerPacket.spellsActive, pid), pid, "player")
end

-- NPC/creature target: the cell authority's ActorSpellsActive packet (one or more actors).
AbsorbHealthFix.OnActorSpellsActive = function(eventStatus, pid, cellDescription, actors)
    for _, actor in ipairs(actors or {}) do
        if actor.spellActiveChangesAction == ADD_ACTION then
            applyHeals(collectHeals(actor.spellsActive, pid), pid, "actor")
        end
    end
end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            log(enumerations.log.ERROR, name .. " error (server kept alive): " .. tostring(err))
        end
    end
end

customEventHooks.registerHandler("OnPlayerSpellsActive",
    safe("OnPlayerSpellsActive", AbsorbHealthFix.OnPlayerSpellsActive))
customEventHooks.registerHandler("OnActorSpellsActive",
    safe("OnActorSpellsActive", AbsorbHealthFix.OnActorSpellsActive))

return AbsorbHealthFix
