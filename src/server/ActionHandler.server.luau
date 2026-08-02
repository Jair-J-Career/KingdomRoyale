local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActionRequest = ReplicatedStorage:WaitForChild("ActionRequest")
local GetMyRole = ReplicatedStorage:WaitForChild("GetMyRole")
local AliveStatusUpdate = ReplicatedStorage:WaitForChild("AliveStatusUpdate")
local OrderVoided = ReplicatedStorage:WaitForChild("OrderVoided")
local FakeOrderRevealed = ReplicatedStorage:WaitForChild("FakeOrderRevealed")
local PartnerDitched = ReplicatedStorage:WaitForChild("PartnerDitched")
local StrikeIntercepted = ReplicatedStorage:WaitForChild("StrikeIntercepted")
local RoleRevealed = ReplicatedStorage:WaitForChild("RoleRevealed")
local CrownInherited = ReplicatedStorage:WaitForChild("CrownInherited")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData
local PendingActions = GameState.PendingActions

local Tribunal = require(ReplicatedStorage.Shared.Tribunal)

local WIN_CONDITIONS = {
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

GetMyRole.OnServerInvoke = function(player: Player)
	local data = PlayerData[player.UserId]
	return data and data.Role or nil
end

local function broadcastAliveStatus()
	local alivePeasantCount = 0
	local isSorcererAlive = false
	for _, player in Players:GetPlayers() do
		local data = PlayerData[player.UserId]
		if data and data.Role == "Peasant" and data.IsAlive == true then
			alivePeasantCount += 1
		end
		if data and data.Role == "Sorcerer" and data.IsAlive == true then
			isSorcererAlive = true
		end
	end

	local snapshot = {}
	for _, player in Players:GetPlayers() do
		local data = PlayerData[player.UserId]
		table.insert(snapshot, {
			UserId = player.UserId,
			Name = player.Name,
			IsAlive = data ~= nil and data.IsAlive == true,
			Cooldown = (data and data.Cooldown) or 0,
			ProtectedTarget = data and data.ProtectedTargetUserId,
			BishopCooldown = data and data.BishopCooldown,
			ScannedPlayers = data and data.ScannedPlayers,
			LastTribunalDay = GameState.LastTribunalDay,
			AlivePeasantCount = alivePeasantCount,
			CurrentDay = GameState.CurrentDay,
			HasCrown = data and data.HasCrown,
			IsSorcererAlive = isSorcererAlive,
		})
	end
	AliveStatusUpdate:FireAllClients(snapshot)
end

local function findLivingMartyrProtecting(targetUserId: number): Player?
	for _, candidate in Players:GetPlayers() do
		local candidateData = PlayerData[candidate.UserId]
		if
			candidateData
			and candidateData.Role == "Martyr"
			and candidateData.IsAlive == true
			and candidateData.ProtectedTargetUserId == targetUserId
		then
			return candidate
		end
	end
	return nil
end

local function redirectToMartyr(martyrPlayer: Player, attackerPlayer: Player, originalTargetPlayer: Player): boolean
	local martyrCharacter = martyrPlayer.Character
	local martyrHumanoid = martyrCharacter and martyrCharacter:FindFirstChildOfClass("Humanoid")
	if not martyrHumanoid then
		return false
	end

	martyrHumanoid.Health = 0

	local martyrData = PlayerData[martyrPlayer.UserId]
	if martyrData then
		martyrData.IsAlive = false
	end

	StrikeIntercepted:FireClient(attackerPlayer, martyrPlayer.Name, originalTargetPlayer.Name)

	print(martyrPlayer.Name .. " (Martyr) sacrificed themselves to save " .. originalTargetPlayer.Name)

	return true
end

local function handleRoyalSuccession(deadUserId: number)
	local deadData = PlayerData[deadUserId]
	if not deadData or deadData.HasCrown ~= true then
		return
	end

	local successorPlayer: Player? = nil

	for _, candidate in Players:GetPlayers() do
		local candidateData = PlayerData[candidate.UserId]
		if candidateData and candidateData.IsAlive == true and candidateData.Role == "Double" then
			successorPlayer = candidate
			break
		end
	end

	if not successorPlayer then
		for _, candidate in Players:GetPlayers() do
			local candidateData = PlayerData[candidate.UserId]
			if candidateData and candidateData.IsAlive == true and candidateData.Role == "Prince" then
				successorPlayer = candidate
				break
			end
		end
	end

	if not successorPlayer then
		for _, candidate in Players:GetPlayers() do
			local candidateData = PlayerData[candidate.UserId]
			if candidateData and candidateData.IsAlive == true and candidateData.Role == "Usurper" then
				successorPlayer = candidate
				break
			end
		end
	end

	if not successorPlayer then
		return
	end

	local successorData = PlayerData[successorPlayer.UserId]
	successorData.HasCrown = true
	deadData.HasCrown = false

	CrownInherited:FireClient(successorPlayer)

	print(successorPlayer.Name .. " (" .. successorData.Role .. ") has secretly inherited the Crown")
end

local function handleOrderMurder(player: Player, targetName: string)
	if GameState.CurrentState ~= "SecretMeetings" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or requesterData.HasCrown ~= true then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer or targetPlayer == player then
		return
	end

	local activeMurder = PendingActions.ActiveMurder
	if activeMurder and activeMurder.RequesterRole == "Usurper" then
		local usurperPlayer = Players:GetPlayerByUserId(activeMurder.RequesterId)
		if usurperPlayer then
			OrderVoided:FireClient(usurperPlayer)
		end
	end

	PendingActions.ActiveMurder = {
		RequesterRole = "King",
		Target = targetPlayer.Name,
		RequesterId = player.UserId,
	}

	print(player.Name .. " successfully ordered the murder of " .. targetPlayer.Name)
end

local function handleFakeMurder(player: Player, targetName: string)
	if GameState.CurrentState ~= "DayGathering" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or requesterData.Role ~= "Usurper" then
		return
	end

	if requesterData.IsAlive ~= true then
		return
	end

	if requesterData.HasCrown == true then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer or targetPlayer == player then
		return
	end

	local activeMurder = PendingActions.ActiveMurder
	if activeMurder and activeMurder.RequesterRole == "King" then
		OrderVoided:FireClient(player)
		return
	end

	PendingActions.ActiveMurder = {
		RequesterRole = "Usurper",
		Target = targetPlayer.Name,
		RequesterId = player.UserId,
	}

	print(player.Name .. " (Usurper) issued a fake murder order on " .. targetPlayer.Name)
end

local function handleMartyrOath(player: Player, targetName: string)
	if type(targetName) ~= "string" then
		return
	end

	if GameState.CurrentState ~= "SecretMeetings" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or requesterData.Role ~= "Martyr" then
		return
	end

	if requesterData.IsAlive ~= true then
		return
	end

	if requesterData.ProtectedTargetUserId ~= nil then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer or targetPlayer == player then
		return
	end

	local martyrCharacter = player.Character
	local martyrRoot = martyrCharacter and martyrCharacter:FindFirstChild("HumanoidRootPart")
	if not martyrRoot then
		return
	end

	local targetCharacter = targetPlayer.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end

	local partnerUserId = GameState.SecretPairs[player.UserId]
	if partnerUserId then
		local partnerPlayer = Players:GetPlayerByUserId(partnerUserId)
		if partnerPlayer then
			PartnerDitched:FireClient(partnerPlayer)
		end
	end

	local oldPartnerId = GameState.SecretPairs[player.UserId]
	if oldPartnerId then
		GameState.SecretPairs[player.UserId] = nil
		GameState.SecretPairs[oldPartnerId] = nil
	end

	print("[MARTYR] Teleporting to " .. targetName)
	martyrCharacter:PivotTo(targetRoot.CFrame * CFrame.new(0, 5, 0))

	requesterData.ProtectedTargetUserId = targetPlayer.UserId

	print(player.Name .. " (Martyr) swore an oath to protect " .. targetPlayer.Name)
end

local function handleBishopReveal(player: Player)
	if GameState.CurrentState ~= "SecretMeetings" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or requesterData.Role ~= "Bishop" then
		return
	end

	if requesterData.IsAlive ~= true then
		return
	end

	if requesterData.BishopCooldown ~= 0 then
		return
	end

	local targetId = GameState.SecretPairs[player.UserId]
	if targetId == nil then
		return
	end

	if table.find(requesterData.ScannedPlayers, targetId) then
		return
	end

	requesterData.BishopCooldown = 2
	table.insert(requesterData.ScannedPlayers, targetId)

	local targetPlayer = Players:GetPlayerByUserId(targetId)
	local targetData = PlayerData[targetId]
	if not targetPlayer or not targetData then
		return
	end

	local winCondition = WIN_CONDITIONS[targetData.Role]

	RoleRevealed:FireClient(player, targetPlayer.Name, winCondition)

	print(player.Name .. " (Bishop) secretly scanned " .. targetPlayer.Name .. " -- " .. tostring(winCondition))
end

local function handlePeasantAccuse(player: Player, targetName: string)
	if type(targetName) ~= "string" then
		return
	end

	if GameState.CurrentState ~= "EveningGathering" then
		return
	end

	if GameState.CurrentDay <= 1 then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or requesterData.Role ~= "Peasant" then
		return
	end

	if requesterData.IsAlive ~= true then
		return
	end

	if GameState.CurrentDay <= GameState.LastTribunalDay + 1 then
		return
	end

	local alivePeasants = 0
	for _, candidate in Players:GetPlayers() do
		local candidateData = PlayerData[candidate.UserId]
		if candidateData and candidateData.Role == "Peasant" and candidateData.IsAlive == true then
			alivePeasants += 1
		end
	end

	if alivePeasants < 3 then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer or targetPlayer == player then
		return
	end

	GameState.PeasantVotes[player.UserId] = targetPlayer.UserId

	local requiredVotes = math.floor(alivePeasants / 2) + 1

	local voteCount = 0
	for _, votedUserId in GameState.PeasantVotes do
		if votedUserId == targetPlayer.UserId then
			voteCount += 1
		end
	end

	print(player.Name .. " (Peasant) accused " .. targetPlayer.Name .. " -- votes: " .. voteCount .. "/" .. requiredVotes)

	if voteCount >= requiredVotes then
		Tribunal.Execute(targetPlayer)
	end
end

local function handleConfirmExecution(player: Player, targetName: string)
	if GameState.CurrentState ~= "NightPhase" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or (requesterData.Role ~= "Sorcerer" and requesterData.Role ~= "Knight") then
		return
	end

	if requesterData.Role == "Knight" then
		for _, candidate in Players:GetPlayers() do
			local candidateData = PlayerData[candidate.UserId]
			if candidateData and candidateData.Role == "Sorcerer" and candidateData.IsAlive == true then
				return
			end
		end
	end

	if requesterData.IsAlive == false then
		return
	end

	local activeMurder = PendingActions.ActiveMurder
	if not activeMurder or activeMurder.Target ~= targetName then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer then
		return
	end

	local targetData = PlayerData[targetPlayer.UserId]

	local character = targetPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local martyrPlayer = findLivingMartyrProtecting(targetPlayer.UserId)
	if martyrPlayer and redirectToMartyr(martyrPlayer, player, targetPlayer) then
		print(player.Name .. " executed on the King's orders, but the strike on " .. targetPlayer.Name .. " was intercepted")

		if activeMurder.RequesterRole == "Usurper" then
			FakeOrderRevealed:FireClient(player)

			local usurperData = PlayerData[activeMurder.RequesterId]
			if usurperData then
				usurperData.Cooldown = 3
			end
		end

		PendingActions.ActiveMurder = nil

		broadcastAliveStatus()
		return
	end

	if requesterData.Role == "Sorcerer" and targetData and targetData.Role == "Prince" then
		StrikeIntercepted:FireClient(player, "THE PRINCE'S IMMUNITY", targetPlayer.Name)
		print(player.Name .. " (Sorcerer) struck at " .. targetPlayer.Name .. ", but the Prince's immunity intercepted it")
		return
	end

	humanoid.Health = 0

	if targetData then
		targetData.IsAlive = false
	end

	handleRoyalSuccession(targetPlayer.UserId)

	if activeMurder.RequesterRole == "Usurper" then
		FakeOrderRevealed:FireClient(player)

		local usurperData = PlayerData[activeMurder.RequesterId]
		if usurperData then
			usurperData.Cooldown = 3
		end
	end

	PendingActions.ActiveMurder = nil

	print(player.Name .. " executed " .. targetPlayer.Name .. " on the King's orders")

	broadcastAliveStatus()
end

local SPY_COLLISION_GROUP = "Spies"

local function applySpyInvisibility(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CollisionGroup = SPY_COLLISION_GROUP
		elseif descendant:IsA("Decal") then
			descendant.Transparency = 1
		elseif descendant:IsA("BillboardGui") then
			descendant.Enabled = false
		end
	end
end

local function hookSpyDescendantListener(player: Player, character: Model)
	local existing = GameState.SpyConnections[player.UserId]
	if existing then
		existing:Disconnect()
	end

	GameState.SpyConnections[player.UserId] = character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CollisionGroup = SPY_COLLISION_GROUP
		elseif descendant:IsA("Decal") then
			descendant.Transparency = 1
		elseif descendant:IsA("BillboardGui") then
			descendant.Enabled = false
		end
	end)
end

local function handleEavesdrop(player: Player, targetName: string)
	if type(targetName) ~= "string" then
		return
	end

	if GameState.CurrentState ~= "SecretMeetings" then
		return
	end

	local requesterData = PlayerData[player.UserId]
	if not requesterData or requesterData.Role ~= "Spy" then
		return
	end

	if requesterData.IsAlive ~= true then
		return
	end

	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer or targetPlayer == player then
		return
	end

	local spyCharacter = player.Character
	local spyRoot = spyCharacter and spyCharacter:FindFirstChild("HumanoidRootPart")
	if not spyRoot then
		return
	end

	local targetCharacter = targetPlayer.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end

	local partnerUserId = GameState.SecretPairs[player.UserId]
	if partnerUserId then
		local partnerPlayer = Players:GetPlayerByUserId(partnerUserId)
		if partnerPlayer then
			PartnerDitched:FireClient(partnerPlayer)
		end
	end

	print("[SPY] Teleporting to " .. targetName)
	spyCharacter:PivotTo(targetRoot.CFrame * CFrame.new(0, 5, 0))
	GameState.SpyTarget = targetPlayer.UserId

	applySpyInvisibility(spyCharacter)
	hookSpyDescendantListener(player, spyCharacter)

	print(player.Name .. " (Spy) ditched their partner to eavesdrop on " .. targetPlayer.Name)
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

	local martyrPlayer = findLivingMartyrProtecting(targetPlayer.UserId)
	if martyrPlayer and redirectToMartyr(martyrPlayer, player, targetPlayer) then
		print(player.Name .. " (Revolutionary) struck at " .. targetPlayer.Name .. ", but the blow was intercepted")
		broadcastAliveStatus()
		return
	end

	humanoid.Health = 0

	local targetData = PlayerData[targetPlayer.UserId]
	if targetData then
		targetData.IsAlive = false
	end

	handleRoyalSuccession(targetPlayer.UserId)

	-- Rule of Chronology: if the player we just killed had an order queued (e.g. a King's
	-- OrderMurder), that order dies with them and must not be actioned later tonight.
	local activeMurder = PendingActions.ActiveMurder
	if activeMurder and activeMurder.RequesterId == targetPlayer.UserId then
		PendingActions.ActiveMurder = nil

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

ActionRequest.OnServerEvent:Connect(function(player: Player, actionType: string, targetName: string?)
	if typeof(actionType) ~= "string" then
		return
	end

	if targetName ~= nil and typeof(targetName) ~= "string" then
		return
	end

	if actionType == "OrderMurder" then
		handleOrderMurder(player, targetName)
	elseif actionType == "OrderFakeMurder" then
		handleFakeMurder(player, targetName)
	elseif actionType == "MartyrOath" then
		handleMartyrOath(player, targetName)
	elseif actionType == "ConfirmExecution" then
		handleConfirmExecution(player, targetName)
	elseif actionType == "Assassinate" then
		handleAssassination(player, targetName)
	elseif actionType == "Eavesdrop" then
		handleEavesdrop(player, targetName)
	elseif actionType == "BishopReveal" then
		handleBishopReveal(player)
	elseif actionType == "Accuse" then
		handlePeasantAccuse(player, targetName)
	end
end)
