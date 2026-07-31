local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CurrentGameState = ReplicatedStorage:WaitForChild("CurrentGameState")
local RoleAssigned = ReplicatedStorage:WaitForChild("RoleAssigned")
local ExecutionPrompt = ReplicatedStorage:WaitForChild("ExecutionPrompt")
local AliveStatusUpdate = ReplicatedStorage:WaitForChild("AliveStatusUpdate")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData
local PendingActions = GameState.PendingActions

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
	"Bodyguard",
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
-- so the King -> Executioner -> Revolutionary flows can all be tested together.
local TEST_RIG_ROLES = { "King", "Sorcerer", "Revolutionary" }

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
		elseif descendant:IsA("BillboardGui") then
			descendant.Enabled = false
		end
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
end

local function catchRespawn(player: Player, character: Model)
	local data = PlayerData[player.UserId]
	if data and data.IsAlive == false then
		applyGhostState(character)
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

	for i, action in PendingActions do
		print("[DEBUG] PendingActions[" .. tostring(i) .. "] ActionType:", action.ActionType, "Target:", action.Target)
	end

	for _, player in Players:GetPlayers() do
		local data = PlayerData[player.UserId]
		print("[DEBUG] Player:", player.Name, "Role:", data and data.Role or "<no PlayerData>")
	end

	local targetName
	for _, action in PendingActions do
		if action.ActionType == "OrderMurder" then
			targetName = action.Target
			break
		end
	end

	if not targetName then
		return
	end

	for _, player in Players:GetPlayers() do
		local data = PlayerData[player.UserId]
		if data and (data.Role == "Sorcerer" or data.Role == "Knight") then
			print("Sending ExecutionPrompt to: ", player.Name, " for target: ", targetName)
			ExecutionPrompt:FireClient(player, targetName)
		end
	end
end

local function runSecretMeetings()
	local players = {}
	for _, player in Players:GetPlayers() do
		if isAlive(player) then
			table.insert(players, player)
		end
	end
	shuffle(players)

	local roomIndex = 1
	for i = 1, #players, 2 do
		local playerA = players[i]
		local playerB = players[i + 1]

		if playerB then
			local room = Workspace.SecretRooms:FindFirstChild("Room" .. roomIndex)
			teleportPlayerTo(playerA, room.CFrame)
			teleportPlayerTo(playerB, room.CFrame)
			print(playerA.Name .. " has been paired with " .. playerB.Name .. " in " .. room.Name)
			roomIndex += 1
		else
			local soloRoom = Workspace.SecretRooms.Room8
			teleportPlayerTo(playerA, soloRoom.CFrame)
			print(playerA.Name .. " has no pair and was sent to " .. soloRoom.Name)
		end
	end
end

updateGameStateDisplay()

while true do
	if GameState.CurrentState == "WaitingForPlayers" then
		repeat
			task.wait(1)
		until #Players:GetPlayers() >= 3
	else
		task.wait(5)
	end

	print(GameState.CurrentState, GameState.CurrentDay)

	if GameState.CurrentState == "WaitingForPlayers" then
		assignRoles()
		GameState.CurrentState = "DayGathering"
		teleportPlayersTo(Workspace.GrandHall.SpawnPoint_Main)
	elseif GameState.CurrentState == "DayGathering" then
		GameState.CurrentState = "SecretMeetings"
		runSecretMeetings()
	elseif GameState.CurrentState == "SecretMeetings" then
		GameState.CurrentState = "EveningGathering"
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
		end
	end

	updateGameStateDisplay()
end
