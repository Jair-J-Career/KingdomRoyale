local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionRequest = ReplicatedStorage:WaitForChild("ActionRequest")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData

local PendingActions = {}

local function handleOrderMurder(player: Player, targetName: string)
	if GameState.CurrentState ~= "SecretMeetings" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or requesterData.Role ~= "King" then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer or targetPlayer == player then
		return
	end

	PendingActions[player.UserId] = {
		ActionType = "OrderMurder",
		Target = targetPlayer.Name,
	}

	print(player.Name .. " successfully ordered the murder of " .. targetPlayer.Name)
end

ActionRequest.OnServerEvent:Connect(function(player: Player, actionType: string, targetName: string)
	if typeof(actionType) ~= "string" or typeof(targetName) ~= "string" then
		return
	end

	if actionType == "OrderMurder" then
		handleOrderMurder(player, targetName)
	end
end)
