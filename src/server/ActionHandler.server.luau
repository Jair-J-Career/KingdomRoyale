local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionRequest = ReplicatedStorage:WaitForChild("ActionRequest")
local GetMyRole = ReplicatedStorage:WaitForChild("GetMyRole")
local AliveStatusUpdate = ReplicatedStorage:WaitForChild("AliveStatusUpdate")
local OrderVoided = ReplicatedStorage:WaitForChild("OrderVoided")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData
local PendingActions = GameState.PendingActions

GetMyRole.OnServerInvoke = function(player: Player)
	local data = PlayerData[player.UserId]
	return data and data.Role or nil
end

local function broadcastAliveStatus()
	local snapshot = {}
	for _, player in Players:GetPlayers() do
		local data = PlayerData[player.UserId]
		table.insert(snapshot, {
			UserId = player.UserId,
			Name = player.Name,
			IsAlive = data ~= nil and data.IsAlive == true,
		})
	end
	AliveStatusUpdate:FireAllClients(snapshot)
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

	if requesterData.IsAlive == false then
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

	local targetData = PlayerData[targetPlayer.UserId]
	if targetData and targetData.Role == "Prince" then
		print(player.Name .. " failed to execute " .. targetPlayer.Name .. " -- the target is the Prince")
		return
	end

	local character = targetPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.Health = 0

	if targetData then
		targetData.IsAlive = false
	end

	PendingActions[orderUserId] = nil

	print(player.Name .. " executed " .. targetPlayer.Name .. " on the King's orders")

	broadcastAliveStatus()
end

local function handleAssassination(player: Player, targetName: string)
	if GameState.CurrentState ~= "NightPhase" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or requesterData.Role ~= "Revolutionary" or requesterData.IsAlive ~= true then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer or targetPlayer == player then
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

	-- Rule of Chronology: if the player we just killed had an order queued (e.g. a King's
	-- OrderMurder), that order dies with them and must not be actioned later tonight.
	if PendingActions[targetPlayer.UserId] then
		PendingActions[targetPlayer.UserId] = nil

		for _, executionerPlayer in Players:GetPlayers() do
			local executionerData = PlayerData[executionerPlayer.UserId]
			if executionerData and (executionerData.Role == "Sorcerer" or executionerData.Role == "Knight") then
				OrderVoided:FireClient(executionerPlayer)
			end
		end
	end

	print(player.Name .. " (Revolutionary) assassinated " .. targetPlayer.Name)

	broadcastAliveStatus()
end

ActionRequest.OnServerEvent:Connect(function(player: Player, actionType: string, targetName: string)
	if typeof(actionType) ~= "string" or typeof(targetName) ~= "string" then
		return
	end

	if actionType == "OrderMurder" then
		handleOrderMurder(player, targetName)
	elseif actionType == "ConfirmExecution" then
		handleConfirmExecution(player, targetName)
	elseif actionType == "Assassinate" then
		handleAssassination(player, targetName)
	end
end)
