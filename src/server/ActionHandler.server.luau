local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionRequest = ReplicatedStorage:WaitForChild("ActionRequest")
local GetMyRole = ReplicatedStorage:WaitForChild("GetMyRole")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData
local PendingActions = GameState.PendingActions

GetMyRole.OnServerInvoke = function(player: Player)
	local data = PlayerData[player.UserId]
	return data and data.Role or nil
end

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

local function handleConfirmExecution(player: Player, targetName: string)
	if GameState.CurrentState ~= "NightPhase" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or (requesterData.Role ~= "Sorcerer" and requesterData.Role ~= "Knight") then
		return
	end

	local orderUserId, order
	for userId, action in PendingActions do
		if action.ActionType == "OrderMurder" and action.Target == targetName then
			orderUserId = userId
			order = action
			break
		end
	end

	if not order then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer then
		return
	end

	local character = targetPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.Health = 0

	local targetData = PlayerData[targetPlayer.UserId]
	if targetData then
		targetData.IsAlive = false
	end

	PendingActions[orderUserId] = nil

	print(player.Name .. " executed " .. targetPlayer.Name .. " on the King's orders")
end

ActionRequest.OnServerEvent:Connect(function(player: Player, actionType: string, targetName: string)
	if typeof(actionType) ~= "string" or typeof(targetName) ~= "string" then
		return
	end

	if actionType == "OrderMurder" then
		handleOrderMurder(player, targetName)
	elseif actionType == "ConfirmExecution" then
		handleConfirmExecution(player, targetName)
	end
end)
