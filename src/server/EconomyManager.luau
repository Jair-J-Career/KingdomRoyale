--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataManager = require(script.Parent.DataManager)

local SharedState = require(ReplicatedStorage.Shared.GameState)
local PlayerData = SharedState.PlayerData

local EconomyManager = {}

-- Mirrors ActionHandler.server.luau's WIN_CONDITIONS -- keep both in sync if roles/factions change.
local ROLE_FACTIONS = {
	King = "The Crown",
	Sorcerer = "The Crown",
	Prince = "The Crown",
	Knight = "The Crown",
	Double = "The Crown",
	Revolutionary = "The Uprising",
	Peasant = "The Uprising",
	Spy = "The Uprising",
	Usurper = "The Rogue",
	Martyr = "The Oathbound",
}

local BASE_MATCH_COMPLETION = 50
local FACTION_VICTORY_BONUS = 100
local MARTYR_BONUS = 75
local EXECUTIONER_KILL_BONUS = 25
local INTERCEPTED_KING_HIT_BONUS = 75
local PEASANT_CORRECT_VOTE_BONUS = 50
local SPY_SURVIVAL_BONUS = 50
local ROGUE_SURVIVAL_BONUS = 75
local USURPER_MASTERY_BONUS = 150
local PACIFIST_MULTIPLIER = 3

-- Some bonuses depend on moment-in-time facts (a landed kill, an intercepted hit, a correct
-- Tribunal vote) that no longer exist in PlayerData/GameState by the time the match ends --
-- GameState.PeasantVotes, for example, is cleared after every Tribunal.Execute() call. Whatever
-- system observes those events during the match should accumulate them here, keyed by UserId,
-- and pass the table in at match end.
export type MatchPlayerStats = {
	Kills: number?,
	LandedKill: boolean?,
	InterceptedKingHit: boolean?,
	VotedKingCorrectly: boolean?,
}

function EconomyManager:DistributeMatchRewards(
	winningFaction: string,
	wasPacifist: boolean,
	matchStats: { [number]: MatchPlayerStats }?
)
	for _, player in Players:GetPlayers() do
		local profile = DataManager:GetProfile(player)
		local roleData = PlayerData[player.UserId]

		if not profile or not roleData then
			continue
		end

		local payout = BASE_MATCH_COMPLETION
		local stats = matchStats and matchStats[player.UserId]

		if ROLE_FACTIONS[roleData.Role] == winningFaction then
			payout += FACTION_VICTORY_BONUS
		end

		if roleData.Role == "Martyr" and roleData.ProtectedTargetUserId ~= nil then
			local protectedData = PlayerData[roleData.ProtectedTargetUserId]
			if protectedData and protectedData.IsAlive == true then
				payout += MARTYR_BONUS
			end
		end

		if stats then
			if stats.Kills and stats.Kills > 0 then
				payout += stats.Kills * EXECUTIONER_KILL_BONUS
			elseif stats.LandedKill == true then
				payout += EXECUTIONER_KILL_BONUS
			end

			if stats.InterceptedKingHit == true then
				payout += INTERCEPTED_KING_HIT_BONUS
			end

			if roleData.Role == "Peasant" and stats.VotedKingCorrectly == true then
				payout += PEASANT_CORRECT_VOTE_BONUS
			end
		end

		if roleData.Role == "Spy" and roleData.IsAlive == true then
			payout += SPY_SURVIVAL_BONUS
		end

		if roleData.Role == "Usurper" and roleData.IsAlive == true then
			payout += ROGUE_SURVIVAL_BONUS
		end

		if roleData.Role == "Usurper" and roleData.HasCrown == true then
			payout += USURPER_MASTERY_BONUS
		end

		if wasPacifist then
			payout *= PACIFIST_MULTIPLIER
		end

		profile.Data.RoyalCoins += payout
		profile.Data.TotalGamesCompleted += 1

		DataManager:UpdateLevel(player)

		print(string.format("[ECONOMY] %s (%s) earned %d RoyalCoins this match", player.Name, roleData.Role, payout))
	end
end

return EconomyManager
