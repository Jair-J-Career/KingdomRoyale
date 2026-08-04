--!strict

local Players = game:GetService("Players")

local ProfileService = require(script.Parent.ProfileService)

local DataManager = {}

export type ProfileData = {
	RoyalCoins: number,
	TotalGamesCompleted: number,
	PlayerLevel: number,
}

local ProfileTemplate: ProfileData = {
	RoyalCoins = 0,
	TotalGamesCompleted = 0,
	PlayerLevel = 1,
}

local ProfileStore = ProfileService.GetProfileStore("PlayerData", ProfileTemplate)

-- Player.UserId -> Profile
local Profiles = {}
DataManager.Profiles = Profiles

function DataManager:GetProfile(player: Player)
	return Profiles[player]
end

function DataManager:UpdateLevel(player: Player)
	local profile = Profiles[player]
	if not profile then
		return
	end

	local newLevel = math.floor(profile.Data.TotalGamesCompleted / 5) + 1
	profile.Data.PlayerLevel = newLevel

	return newLevel
end

local function PlayerAdded(player: Player)
	local profile = ProfileStore:LoadProfileAsync(tostring(player.UserId))

	if profile ~= nil then
		profile:AddUserId(player.UserId)
		profile:Reconcile()

		profile:ListenToRelease(function()
			Profiles[player] = nil
			player:Kick("Your data has been loaded on another server or your profile was corrupted. Please rejoin.")
		end)

		if player:IsDescendantOf(Players) then
			Profiles[player] = profile
			DataManager:UpdateLevel(player)
		else
			profile:Release()
		end
	else
		player:Kick("Data could not be loaded. Please rejoin.")
	end
end

local function PlayerRemoving(player: Player)
	local profile = Profiles[player]
	if profile ~= nil then
		profile:Release()
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(PlayerAdded, player)
end

Players.PlayerAdded:Connect(PlayerAdded)
Players.PlayerRemoving:Connect(PlayerRemoving)

return DataManager
