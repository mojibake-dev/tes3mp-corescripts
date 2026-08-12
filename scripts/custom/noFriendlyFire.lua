-- noFriendlyFire.lua
-- [mojibake] Players can't damage each other. TES3MP applies player-vs-player damage on the
-- victim's client, so it can't be cleanly blocked; instead we negate it: when a player is struck
-- by another player, restore the damage that hit dealt. Adapted from rickoff's PreventDamage
-- (github.com/rickoff/Tes3mp-0.8.x), made unconditional (always on, no /pvp toggle).
--
-- Caveat (inherent to this heal-back approach): covers MELEE hits; the very first hit may
-- under-restore, but death is prevented; spell damage and damage-over-time are not covered.

local NoFriendlyFire = {}

NoFriendlyFire.OnObjectHit = function(eventStatus, pid, cellDescription, objects, targetPlayers)
    if targetPlayers == nil then return end
    for targetPid, targetPlayer in pairs(targetPlayers) do
        if Players[targetPid] ~= nil and Players[targetPid]:IsLoggedIn()
            and targetPlayer.hittingPid ~= nil          -- struck by another PLAYER (nil = NPC/creature)
            and targetPlayer.hit ~= nil and targetPlayer.hit.success == true then
            local dmg = targetPlayer.hit.damage or 0
            if dmg > 0 then
                tes3mp.SetHealthCurrent(targetPid, tes3mp.GetHealthCurrent(targetPid) + dmg)
                tes3mp.SendStatsDynamic(targetPid)
            end
        end
    end
end

customEventHooks.registerHandler("OnObjectHit", NoFriendlyFire.OnObjectHit)

return NoFriendlyFire
