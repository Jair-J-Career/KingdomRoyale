local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TribunalResult = ReplicatedStorage:WaitForChild("TribunalResult")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData

local Tribunal = {}

-- Executes a Tribunal against targetPlayer: locks out the mechanic for the standard
-- one-day-on/one-day-off cadence, clears the vote pool, and reveals whether the mob
-- got it right. Callable from any server script that has reached a verdict, whether
-- via an early majority or an Evening Gathering timeout tie-break.
function Tribunal.Execute(targetPlayer: Player)
	GameState.LastTribunalDay = GameState.CurrentDay

	local targetData = PlayerData[targetPlayer.UserId]
	local targetIsKing = targetData ~= nil and targetData.Role == "King"

	if targetIsKing then
		for voterUserId, votedUserId in GameState.PeasantVotes do
			if votedUserId == targetPlayer.UserId then
				local voterStats = GameState.MatchStats[voterUserId]
				if not voterStats then
					voterStats = {}
					GameState.MatchStats[voterUserId] = voterStats
				end
				voterStats.VotedKingCorrectly = true
			end
		end
	end

	table.clear(GameState.PeasantVotes)

	if targetIsKing then
		TribunalResult:FireAllClients("THE MOB HAS EXPOSED " .. targetPlayer.Name:upper() .. " AS THE KING!", true)
	else
		TribunalResult:FireAllClients(
			"THE MOB ACCUSED " .. targetPlayer.Name:upper() .. ", BUT THEY ARE NOT THE KING!",
			false
		)
	end

	print(targetPlayer.Name .. " was put before the Tribunal.")
end

return Tribunal
