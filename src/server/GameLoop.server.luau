local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

local CurrentGameState = ReplicatedStorage:WaitForChild("CurrentGameState")
local RoleAssigned = ReplicatedStorage:WaitForChild("RoleAssigned")
local ExecutionPrompt = ReplicatedStorage:WaitForChild("ExecutionPrompt")
local AliveStatusUpdate = ReplicatedStorage:WaitForChild("AliveStatusUpdate")
local RoomPartnerSync = ReplicatedStorage:WaitForChild("RoomPartnerSync")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData
local PendingActions = GameState.PendingActions

local ALIVE_COLLISION_GROUP = "Alive"
local GHOST_COLLISION_GROUP = "Ghosts"
local SPY_COLLISION_GROUP = "Spies"

local function registerCollisionGroup(name: string)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

registerCollisionGroup(ALIVE_COLLISION_GROUP)
registerCollisionGroup(GHOST_COLLISION_GROUP)
registerCollisionGroup(SPY_COLLISION_GROUP)
PhysicsService:CollisionGroupSetCollidable(ALIVE_COLLISION_GROUP, GHOST_COLLISION_GROUP, false)
PhysicsService:CollisionGroupSetCollidable(ALIVE_COLLISION_GROUP, SPY_COLLISION_GROUP, false)

local STATE_DISPLAY_NAMES = {
	WaitingForPlayers = "Waiting for Players",
	DayGathering = "Day Gathering",
	SecretMeetings = "Secret Meetings",
	EveningGathering = "Evening Gathering",
	NightPhase = "Night Phase",
	GameOver = "Game Over",
}

local function updateGameStateDisplay()
	local displayName = STATE_DISPLAY_NAMES[GameState.CurrentState] or GameState.CurrentState
	CurrentGameState.Value = string.format("Day %d: %s", GameState.CurrentDay, displayName)
end

local ROLES = {
	"King",
	"Prince",
	"Double",
	"Sorcerer",
	"Knight",
	"Revolutionary",
	"Usurper",
	"Bishop",
	"Martyr",
	"Spy",
	"Peasant",
	"Peasant",
	"Peasant",
	"Peasant",
	"Peasant",
}

local function shuffle(array)
	for i = #array, 2, -1 do
		local j = math.random(i)
		array[i], array[j] = array[j], array[i]
	end
end

-- Test rig: the first three players (sorted by name) are forced into fixed roles
-- so the Bishop's cooldown-based scan ability can be tested against a King.
local TEST_RIG_ROLES = { "Bishop", "Peasant", "King" }

local function broadcastAliveStatus()
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
		})
	end
	AliveStatusUpdate:FireAllClients(snapshot)
end

local function tickCooldowns()
	for _, data in PlayerData do
		if data.Cooldown and data.Cooldown > 0 then
			data.Cooldown -= 1
		end
	end
end

local function assignRoles()
	local availableRoles = table.clone(ROLES)

	local players = Players:GetPlayers()
	table.sort(players, function(a, b)
		return a.Name < b.Name
	end)

	for i, role in TEST_RIG_ROLES do
		local player = players[i]
		if player then
			PlayerData[player.UserId] = {
				Role = role,
				IsAlive = true,
				ProtectedTargetUserId = nil,
				BishopCooldown = 0,
				ScannedPlayers = {},
			}
			print(player.Name .. " has been assigned the role of " .. role)
			RoleAssigned:FireClient(player, role)

			table.remove(availableRoles, table.find(availableRoles, role))
		end
	end

	shuffle(availableRoles)

	for i = #TEST_RIG_ROLES + 1, #players do
		local player = players[i]
		local role = table.remove(availableRoles, 1)
		PlayerData[player.UserId] = {
			Role = role,
			IsAlive = true,
			ProtectedTargetUserId = nil,
			BishopCooldown = 0,
			ScannedPlayers = {},
		}
		print(player.Name .. " has been assigned the role of " .. role)
		RoleAssigned:FireClient(player, role)
	end

	broadcastAliveStatus()
end

local function teleportPlayerTo(player: Player, cframe: CFrame)
	local character = player.Character
	local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoidRootPart then
		humanoidRootPart.CFrame = cframe
	end
end

local function isAlive(player: Player): boolean
	local data = PlayerData[player.UserId]
	return data ~= nil and data.IsAlive == true
end

local function teleportPlayersTo(spawnPart: BasePart)
	for _, player in Players:GetPlayers() do
		if isAlive(player) then
			teleportPlayerTo(player, spawnPart.CFrame)
		end
	end
end

local function applyGhostState(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CollisionGroup = GHOST_COLLISION_GROUP
		elseif descendant:IsA("BillboardGui") then
			descendant.Enabled = false
		end
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
end

local function applyAliveState(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = ALIVE_COLLISION_GROUP
		end
	end
end

local function removeSpyInvisibility(character: Model, player: Player)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant.Name == "HumanoidRootPart" then
				descendant.Transparency = 1
			else
				descendant.Transparency = 0
			end
			descendant.CollisionGroup = ALIVE_COLLISION_GROUP
		elseif descendant:IsA("Decal") then
			descendant.Transparency = 0
		elseif descendant:IsA("BillboardGui") then
			descendant.Enabled = true
		end
	end

	local connection = GameState.SpyConnections[player.UserId]
	if connection then
		connection:Disconnect()
		GameState.SpyConnections[player.UserId] = nil
	end
end

local function catchRespawn(player: Player, character: Model)
	local data = PlayerData[player.UserId]
	if data and data.IsAlive == false then
		applyGhostState(character)
	else
		applyAliveState(character)
	end
end

local function hookRespawnCatcher(player: Player)
	player.CharacterAdded:Connect(function(character)
		catchRespawn(player, character)
	end)
end

for _, player in Players:GetPlayers() do
	hookRespawnCatcher(player)
end

Players.PlayerAdded:Connect(hookRespawnCatcher)

local function notifyExecutioners()
	print("Entering Night Phase. Checking PendingActions...")

	local activeMurder = PendingActions.ActiveMurder
	print(
		"[DEBUG] ActiveMurder RequesterRole:",
		activeMurder and activeMurder.RequesterRole or "<none>",
		"Target:",
		activeMurder and activeMurder.Target or "<none>"
	)

	for _, player in Players:GetPlayers() do
		local data = PlayerData[player.UserId]
		print("[DEBUG] Player:", player.Name, "Role:", data and data.Role or "<no PlayerData>")
	end

	if not activeMurder then
		return
	end

	local targetName = activeMurder.Target

	for _, player in Players:GetPlayers() do
		local data = PlayerData[player.UserId]
		if data and (data.Role == "Sorcerer" or data.Role == "Knight") then
			print("Sending ExecutionPrompt to: ", player.Name, " for target: ", targetName)
			ExecutionPrompt:FireClient(player, targetName)
		end
	end
end

local function pairPlayersInRoom(playerA: Player, playerB: Player, room: BasePart, note: string?)
	teleportPlayerTo(playerA, room.CFrame)
	teleportPlayerTo(playerB, room.CFrame)
	GameState.SecretPairs[playerA.UserId] = playerB.UserId
	GameState.SecretPairs[playerB.UserId] = playerA.UserId
	RoomPartnerSync:FireClient(playerA, playerB.Name)
	RoomPartnerSync:FireClient(playerB, playerA.Name)
	print(playerA.Name .. " has been paired with " .. playerB.Name .. " in " .. room.Name .. (note or ""))
end

local function runSecretMeetings()
	-- Give late-loading characters (e.g. a player who just joined) time to finish spawning
	-- before we go grabbing HumanoidRootParts for teleportation.
	task.wait(1)

	local players = {}
	for _, player in Players:GetPlayers() do
		if isAlive(player) then
			table.insert(players, player)
		end
	end

	-- Test rig: sort by name (same order assignRoles() uses) instead of shuffling, so the
	-- Spy/King/Sorcerer test rig always lands Player1+Player2 in Room1 and Player3 solo in Room8.
	table.sort(players, function(a, b)
		return a.Name < b.Name
	end)

	local roomIndex = 1

	for i = 1, #players, 2 do
		local playerA = players[i]
		local playerB = players[i + 1]

		if playerB then
			local room = Workspace.SecretRooms:FindFirstChild("Room" .. roomIndex)
			print("[MATCHMAKING] Pairing " .. playerA.Name .. " and " .. playerB.Name .. " in Room " .. roomIndex)
			pairPlayersInRoom(playerA, playerB, room)
			roomIndex += 1
		else
			local soloRoom = Workspace.SecretRooms.Room8
			teleportPlayerTo(playerA, soloRoom.CFrame)
			RoomPartnerSync:FireClient(playerA, "")
			print(playerA.Name .. " has no pair and was sent to " .. soloRoom.Name)
		end
	end

	-- Third Wheel: after the standard pairing pass has placed everyone (including any Martyr's
	-- protected target) into a room, any Martyr who has sworn their oath teleports into their
	-- protected target's room as an uninvited third person, wherever that target ended up.
	for _, player in players do
		local data = PlayerData[player.UserId]
		if data and data.Role == "Martyr" and data.ProtectedTargetUserId then
			local protectedPlayer = Players:GetPlayerByUserId(data.ProtectedTargetUserId)
			if protectedPlayer and isAlive(protectedPlayer) then
				local protectedCharacter = protectedPlayer.Character
				local protectedRoot = protectedCharacter and protectedCharacter:FindFirstChild("HumanoidRootPart")
				local martyrCharacter = player.Character
				if protectedRoot and martyrCharacter then
					local oldPartnerId = GameState.SecretPairs[player.UserId]
					if oldPartnerId then
						GameState.SecretPairs[player.UserId] = nil
						GameState.SecretPairs[oldPartnerId] = nil
					end

					martyrCharacter:PivotTo(protectedRoot.CFrame * CFrame.new(0, 5, 0))
					print(player.Name .. " (Martyr) infiltrated " .. protectedPlayer.Name .. "'s room to honor their oath")
				end
			end
		end
	end
end

updateGameStateDisplay()

while true do
	if GameState.CurrentState == "WaitingForPlayers" then
		repeat
			task.wait(1)
		until #Players:GetPlayers() >= 3
	elseif GameState.CurrentState == "SecretMeetings" then
		task.wait(20)
	else
		task.wait(5)
	end

	print(GameState.CurrentState, GameState.CurrentDay)

	if GameState.CurrentState == "WaitingForPlayers" then
		-- Force the server to wait for all 3 test clients to connect
		while #Players:GetPlayers() < 3 do
			task.wait(1)
		end

		assignRoles()
		GameState.CurrentState = "DayGathering"
		teleportPlayersTo(Workspace.GrandHall.SpawnPoint_Main)
	elseif GameState.CurrentState == "DayGathering" then
		for _, player in Players:GetPlayers() do
			if isAlive(player) then
				local data = PlayerData[player.UserId]
				if data and data.Role == "Bishop" and data.BishopCooldown and data.BishopCooldown > 0 then
					data.BishopCooldown -= 1
				end
			end
		end

		GameState.CurrentState = "SecretMeetings"
		runSecretMeetings()
	elseif GameState.CurrentState == "SecretMeetings" then
		GameState.CurrentState = "EveningGathering"
		table.clear(GameState.SecretPairs)
		GameState.SpyTarget = nil

		for _, player in Players:GetPlayers() do
			local data = PlayerData[player.UserId]
			if data and data.Role == "Spy" and data.IsAlive == true then
				local character = player.Character
				if character then
					removeSpyInvisibility(character, player)
				end
			end
		end

		teleportPlayersTo(Workspace.GrandHall.SpawnPoint_Main)
	elseif GameState.CurrentState == "EveningGathering" then
		GameState.CurrentState = "NightPhase"
		teleportPlayersTo(Workspace.PrivateQuarters.SpawnPoint_Private)
		notifyExecutioners()
	elseif GameState.CurrentState == "NightPhase" then
		if GameState.CurrentDay == 6 then
			GameState.CurrentState = "GameOver"
			updateGameStateDisplay()
			break
		else
			table.clear(PendingActions)
			GameState.CurrentDay += 1
			GameState.CurrentState = "DayGathering"
			teleportPlayersTo(Workspace.GrandHall.SpawnPoint_Main)
			tickCooldowns()
			broadcastAliveStatus()
		end
	end

	updateGameStateDisplay()
end
