-- noFriendlyFire.lua
-- [mojibake] Chip-but-never-kill. Allies can damage each other, but a friendly KILLING blow
-- can't stick.
--
-- Player death is CLIENT-AUTHORITATIVE: the victim's own client detects + animates the death and
-- reports it (apps/openmw/mwmechanics/character.cpp sendDeath), so the server can't pre-empt it and
-- a validator returning false does NOT "cancel" the death, it only skips BasePlayer:ProcessDeath.
-- We use that: on a player-vs-player death we skip ProcessDeath (so no death message + no
-- respawn-at-temple timer starts) and revive the victim IN PLACE with Resurrect(REGULAR), which does
-- not teleport and refills health (apps/openmw/mwmechanics/creaturestats.cpp), unlike
-- BasePlayer:Resurrect which yanks to a shrine/temple per config.
--
-- The previous version restored health on every OnObjectHit; that read the stale server health
-- cache and OVER-healed, undoing enemy (PvE) damage ("enemies barely hurt me"). That per-hit
-- heal-back is intentionally gone: friendly chip damage now lands normally.

local NoFriendlyFire = {}

local function log(level, msg)
    tes3mp.LogMessage(level, "[noFriendlyFire] " .. msg)
end

-- True when pid was just killed by a DIFFERENT logged-in player (not an NPC/creature, not suicide).
-- DoesPlayerHavePlayerKiller reflects killer.isPlayer; GetPlayerKillerPid resolves the killer guid to
-- a live pid or -1 (apps/openmw-mp/Script/Functions/Mechanics.cpp).
local function killedByPlayer(pid)
    if not tes3mp.DoesPlayerHavePlayerKiller(pid) then return false end
    local killerPid = tes3mp.GetPlayerKillerPid(pid)
    return killerPid ~= nil and killerPid >= 0 and killerPid ~= pid
        and Players[killerPid] ~= nil and Players[killerPid]:IsLoggedIn()
end

-- Validator: for a friendly kill, skip the default ProcessDeath so no temple-respawn timer starts.
-- Safe to return validDefaultHandler=false ONLY because the handler below always revives them.
NoFriendlyFire.OnPlayerDeathValidator = function(eventStatus, pid)
    if killedByPlayer(pid) then
        return customEventHooks.makeEventStatus(false, true)
    end
end

-- Handler: revive the friendly-killed player where they fell.
NoFriendlyFire.OnPlayerDeathHandler = function(eventStatus, pid)
    if killedByPlayer(pid) then
        tes3mp.Resurrect(pid, enumerations.resurrect.REGULAR)
        if Players[pid] ~= nil then Players[pid].data.spellsActive = {} end  -- match ProcessDeath's effect clear
        log(enumerations.log.INFO, logicHandler.GetChatName(pid) .. " revived in place (friendly kill negated)")
    end
end

local function safe(name, fn)
    return function(...)
        local ok, ret = pcall(fn, ...)
        if not ok then
            log(enumerations.log.ERROR, name .. " error (server kept alive): " .. tostring(ret))
            return
        end
        return ret
    end
end

customEventHooks.registerValidator("OnPlayerDeath", safe("OnPlayerDeathValidator", NoFriendlyFire.OnPlayerDeathValidator))
customEventHooks.registerHandler("OnPlayerDeath", safe("OnPlayerDeathHandler", NoFriendlyFire.OnPlayerDeathHandler))

return NoFriendlyFire
