local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CurrentGameState = ReplicatedStorage:WaitForChild("CurrentGameState")
local RoleAssigned = ReplicatedStorage:WaitForChild("RoleAssigned")

local GameState = {
	CurrentState = "WaitingForPlayers",
	CurrentDay = 1,
}

local PlayerData = {}

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

local function assignRoles()
	local shuffledRoles = table.clone(ROLES)
	shuffle(shuffledRoles)

	for i, player in Players:GetPlayers() do
		local role = shuffledRoles[i]
		PlayerData[player.UserId] = {
			Role = role,
		}
		print(player.Name .. " has been assigned the role of " .. role)
		RoleAssigned:FireClient(player, role)
	end
end

local function teleportPlayerTo(player: Player, cframe: CFrame)
	local character = player.Character
	local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoidRootPart then
		humanoidRootPart.CFrame = cframe
	end
end

local function teleportPlayersTo(spawnPart: BasePart)
	for _, player in Players:GetPlayers() do
		teleportPlayerTo(player, spawnPart.CFrame)
	end
end

local function runSecretMeetings()
	local players = Players:GetPlayers()
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
	task.wait(5)
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
	elseif GameState.CurrentState == "NightPhase" then
		if GameState.CurrentDay == 6 then
			GameState.CurrentState = "GameOver"
			updateGameStateDisplay()
			break
		else
			GameState.CurrentDay += 1
			GameState.CurrentState = "DayGathering"
			teleportPlayersTo(Workspace.GrandHall.SpawnPoint_Main)
		end
	end

	updateGameStateDisplay()
end
