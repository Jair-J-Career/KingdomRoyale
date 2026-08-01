local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData

local textChannels = TextChatService:WaitForChild("TextChannels")
local generalChannel = textChannels:WaitForChild("RBXGeneral")

generalChannel.ShouldDeliverCallback = function(textChatMessage: TextChatMessage, targetTextSource: TextSource)
	local senderTextSource = textChatMessage.TextSource
	if not senderTextSource then
		return true
	end

	local senderId = senderTextSource.UserId
	local targetId = targetTextSource.UserId

	local senderData = PlayerData[senderId]
	local targetData = PlayerData[targetId]

	if not senderData or not targetData then
		return true
	end

	if senderData.IsAlive == false and targetData.IsAlive == true then
		print("[CHAT FILTER] Blocked ghost message to living player")
		return false
	end

	if GameState.CurrentState == "SecretMeetings" then
		local spyTarget = GameState.SpyTarget

		if senderData.Role == "Spy" and spyTarget ~= nil then
			return false
		end

		if targetData.Role == "Spy" and spyTarget ~= nil then
			if senderId == spyTarget then
				return true
			end

			if senderId == GameState.SecretPairs[spyTarget] then
				return true
			end

			return false
		end

		if senderData.IsAlive == true and targetData.IsAlive == true then
			if GameState.SecretPairs[senderId] == targetId then
				return true
			end
		end

		return false
	end

	return true
end
