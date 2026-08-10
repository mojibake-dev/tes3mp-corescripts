-- JournalMainQuestOnly (frontier-aware).
--
-- On this server journals are per-player (config.shareJournal = false, an
-- "independent playthrough"). This CoreScript re-shares ONLY the MAIN QUEST so
-- the group stays on the same main-quest page while side quests stay personal.
--
-- Model: a group "frontier" -- the furthest index reached for each main-quest
-- quest -- lives in WorldInstance.data.customVariables and is persisted, so it
-- survives restarts and players who were offline.
--   * OnPlayerJournal: only entries that ADVANCE the frontier are pushed to the
--     other online players (forward-only). A newcomer replaying early steps the
--     group is already past is NOT broadcast backward at the veterans.
--   * OnPlayerAuthentified (fires after both new-character chargen and returning
--     login): the joining player is caught up to the frontier -- any main-quest
--     entry they lack is sent to their client and written into their save -- so
--     a new player starts where the group is.
--
-- Crash history: the previous version called Players[id]:SaveJournal() with no
-- packet, which indexed a nil at stateHelper.lua:234 and hard-crashed the WHOLE
-- server on the first main-quest journal entry any player received (chargen door,
-- mid-quest, anywhere). This version never calls SaveJournal itself: the
-- OnPlayerJournal validator returns makeEventStatus(true, true) so the stock
-- handler performs the per-player save, which removes the crash class entirely.
-- Persistence uses the same data.journal + SaveToDrive path the CoreScripts
-- LoadJournal / SaveJournal already use (validated: player/json.lua, world/json.lua).

local Methods = {}

function Methods.IsConfigSettingValid()
	return config.shareJournal == false
end

local mainQuestPrefixes = { "a1", "a2", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8", "c0", "c2", "c3" }

-- Tribunal + Bloodmoon main-quest journal ids (lowercased): their TR_/BM_ buckets
-- mix main + side quests, so no clean prefix -- explicit set instead.
local dlcMainQuest = {
	["tr_dbhunt"]=true, ["tr_dbattack"]=true, ["tr_assassins"]=true, ["tr_showpower"]=true,
	["tr_killgoblins"]=true, ["tr_mazedband"]=true, ["tr_bamz"]=true, ["tr_sothasil"]=true,
	["tr_mhattack"]=true, ["tr_blade"]=true, ["tr_champion"]=true,
	["bm_trial"]=true, ["bm_water"]=true, ["bm_earth"]=true, ["bm_trees"]=true,
	["bm_beasts"]=true, ["bm_sun"]=true, ["bm_wind"]=true, ["bm_stones"]=true,
	["bm_skaalattack"]=true, ["bm_ceremony1"]=true, ["bm_ceremony2"]=true, ["bm_wildhunt"]=true,
	["bm_brodirgrove"]=true, ["bm_frostgiant1"]=true, ["bm_frostgiant2"]=true,
	["bm_lycanthropycure"]=true, ["bm_wolfgiver"]=true, ["bm_wolfgiver_a"]=true, ["bm_sadseer"]=true,
}

function Methods.IsMainQuestId(quest)
	local q = string.lower(quest or "")
	return tableHelper.containsValue(mainQuestPrefixes, string.sub(q, 1, 2)) or dlcMainQuest[q] == true
end

-- The group main-quest frontier: { [questLower] = { quest, index, type, actorRefId, timestamp } }.
-- Stored in WorldInstance customVariables so it persists across restarts.
function Methods.GetFrontier()
	if WorldInstance.data.customVariables == nil then
		WorldInstance.data.customVariables = {}
	end
	if WorldInstance.data.customVariables.mainQuestFrontier == nil then
		WorldInstance.data.customVariables.mainQuestFrontier = {}
	end
	return WorldInstance.data.customVariables.mainQuestFrontier
end

-- True if the player's saved journal already holds quest q at >= index.
function Methods.PlayerHasEntry(player, questLower, index)
	if player.data.journal == nil then return false end
	for _, item in ipairs(player.data.journal) do
		if string.lower(item.quest or "") == questLower and (item.index or -1) >= index then
			return true
		end
	end
	return false
end

-- Send one frontier item to a player's client (mirrors StateHelper:LoadJournal).
function Methods.SendItemToClient(pid, e)
	if e.type == enumerations.journal.ENTRY then
		local actorRefId = e.actorRefId or "player"
		if e.timestamp ~= nil then
			tes3mp.AddJournalEntryWithTimestamp(pid, e.quest, e.index, actorRefId,
				e.timestamp.daysPassed, e.timestamp.month, e.timestamp.day)
		else
			tes3mp.AddJournalEntry(pid, e.quest, e.index, actorRefId)
		end
	else
		tes3mp.AddJournalIndex(pid, e.quest, e.index)
	end
end

-- Forward-only propagation: for each main-quest item in the incoming journal
-- changes that pushes the frontier forward, advance the frontier and broadcast
-- it to the other logged-in players. Never touches the originating player's
-- save -- the stock OnPlayerJournal handler does that.
function Methods.PropagateForwardMainQuest(pid)
	local frontier = Methods.GetFrontier()
	local advanced = false
	for i = 0, tes3mp.GetJournalChangesSize(pid) - 1 do
		local questOriginal = tes3mp.GetJournalItemQuest(pid, i)
		local questLower = string.lower(questOriginal or "")
		if Methods.IsMainQuestId(questLower) then
			local itemType = tes3mp.GetJournalItemType(pid, i)
			local index = tes3mp.GetJournalItemIndex(pid, i)
			local current = frontier[questLower]
			if current == nil or index > current.index then
				local e = {
					quest = questOriginal,
					index = index,
					type = itemType,
					timestamp = {
						daysPassed = WorldInstance.data.time.daysPassed,
						month = WorldInstance.data.time.month,
						day = WorldInstance.data.time.day,
					},
				}
				if itemType == enumerations.journal.ENTRY then
					e.actorRefId = tes3mp.GetJournalItemActorRefId(pid, i) or "player"
				end
				frontier[questLower] = e
				advanced = true
				for otherPid, otherPlayer in pairs(Players) do
					if otherPid ~= pid and otherPlayer ~= nil and otherPlayer:IsLoggedIn() then
						Methods.SendItemToClient(otherPid, e)
						tes3mp.SendJournalChanges(otherPid)
					end
				end
			end
		end
	end
	if advanced then
		WorldInstance:SaveToDrive()
	end
end

-- Catch a joining player up to the frontier: send + persist any main-quest entry
-- they lack, so a new player starts where the group is. Idempotent (dedups
-- against the player's own saved journal), so caught-up players are undisturbed.
function Methods.CatchUpToFrontier(pid)
	local player = Players[pid]
	if player == nil then return end
	if player.data.journal == nil then player.data.journal = {} end
	local frontier = Methods.GetFrontier()
	local added = false
	for questLower, e in pairs(frontier) do
		if not Methods.PlayerHasEntry(player, questLower, e.index) then
			Methods.SendItemToClient(pid, e)
			table.insert(player.data.journal, {
				type = e.type,
				index = e.index,
				quest = e.quest,
				actorRefId = e.actorRefId or "player",
				timestamp = e.timestamp,
			})
			added = true
		end
	end
	if added then
		tes3mp.SendJournalChanges(pid)
		player:SaveToDrive()
	end
end

-- Fold a connecting player's own saved main-quest journal into the group frontier,
-- so the frontier reflects everyone's real progress, not just entries generated
-- after this script was deployed. Forward-only max: it never lowers the frontier,
-- so a newcomer's low chargen index cannot pull the group back to the intro.
function Methods.AbsorbPlayerProgress(pid)
	local player = Players[pid]
	if player == nil or player.data.journal == nil then return end
	local frontier = Methods.GetFrontier()
	local advanced = false
	for _, item in ipairs(player.data.journal) do
		local questLower = string.lower(item.quest or "")
		if Methods.IsMainQuestId(questLower) then
			local idx = item.index or -1
			local cur = frontier[questLower]
			if cur == nil or idx > cur.index then
				frontier[questLower] = {
					quest = item.quest,
					index = idx,
					type = item.type,
					actorRefId = item.actorRefId,
					timestamp = item.timestamp,
				}
				advanced = true
			end
		end
	end
	if advanced then WorldInstance:SaveToDrive() end
end

customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
	if Methods.IsConfigSettingValid() == false then
		tes3mp.LogMessage(enumerations.log.WARN,
			"[JournalMainQuestOnly] config.shareJournal must be false for this script to work!")
	end
end)

-- Only propagate; never save here. Returning validDefaultHandler = true lets the
-- stock handler persist the originating player's journal with the real packet
-- (this is what removes the old nil-packet crash). Both callbacks are pcall-wrapped
-- so a bug in THIS script can never abort the server: worst case a share silently
-- no-ops and logs, while the stock per-player journal save still runs.
customEventHooks.registerValidator("OnPlayerJournal", function(eventStatus, pid, playerPacket)
	local ok, err = pcall(Methods.PropagateForwardMainQuest, pid)
	if not ok then
		tes3mp.LogMessage(enumerations.log.ERROR,
			"[JournalMainQuestOnly] forward-propagation error (server kept alive): " .. tostring(err))
	end
	return customEventHooks.makeEventStatus(true, true)
end)

-- Fires after both new-character chargen and returning-player login. Absorb this
-- player's own saved progress into the frontier first (self-healing backfill), then
-- catch them up to the frontier so a new character starts where the group is.
customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
	local ok, err = pcall(function()
		Methods.AbsorbPlayerProgress(pid)
		Methods.CatchUpToFrontier(pid)
	end)
	if not ok then
		tes3mp.LogMessage(enumerations.log.ERROR,
			"[JournalMainQuestOnly] join handler error (server kept alive): " .. tostring(err))
	end
end)

return Methods
