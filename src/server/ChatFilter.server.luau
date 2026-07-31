local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local CurrentGameState = ReplicatedStorage:WaitForChild("CurrentGameState")

local SharedState = require(ReplicatedStorage.Shared.GameState)
local GameState = SharedState.GameState
local PlayerData = SharedState.PlayerData

local GENERAL_CHANNEL_NAME = "RBXGeneral"
local GRAVEYARD_CHANNEL_NAME = "Graveyard"

local function getTextChannels(): Folder
	local textChannels = TextChatService:FindFirstChild("TextChannels")
	if not textChannels then
		textChannels = Instance.new("Folder")
		textChannels.Name = "TextChannels"
		textChannels.Parent = TextChatService
	end
	return textChannels :: Folder
end

local textChannels = getTextChannels()

local graveyardChannel = textChannels:FindFirstChild(GRAVEYARD_CHANNEL_NAME) :: TextChannel?
if not graveyardChannel then
	graveyardChannel = Instance.new("TextChannel")
	graveyardChannel.Name = GRAVEYARD_CHANNEL_NAME
	graveyardChannel.Parent = textChannels
end

local function getGeneralChannel(): TextChannel?
	return textChannels:FindFirstChild(GENERAL_CHANNEL_NAME) :: TextChannel?
end

local function isAlive(player: Player): boolean
	local data = PlayerData[player.UserId]
	return data == nil or data.IsAlive ~= false
end

local function moveToGraveyard(player: Player)
	local ok = pcall(function()
		graveyardChannel:AddUserAsync(player.UserId)
	end)
	if not ok then
		return
	end

	local generalChannel = getGeneralChannel()
	if generalChannel then
		pcall(function()
			generalChannel:RemoveUserAsync(player.UserId)
		end)
	end
end

local function moveToGeneral(player: Player)
	local generalChannel = getGeneralChannel()
	if generalChannel then
		pcall(function()
			generalChannel:AddUserAsync(player.UserId)
		end)
	end

	pcall(function()
		graveyardChannel:RemoveUserAsync(player.UserId)
	end)
end

local function onCharacterAdded(player: Player, character: Model)
	if not isAlive(player) then
		moveToGraveyard(player)
		return
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Died:Connect(function()
		moveToGraveyard(player)
	end)
end

local function onPlayerAdded(player: Player)
	if isAlive(player) then
		moveToGeneral(player)
	else
		moveToGraveyard(player)
	end

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)

local function resetGraveyardForNewMatch()
	for _, player in Players:GetPlayers() do
		moveToGeneral(player)
	end
end

CurrentGameState.Changed:Connect(function()
	if GameState.CurrentState == "DayGathering" and GameState.CurrentDay == 1 then
		resetGraveyardForNewMatch()
	end
end)

Players.PlayerRemoving:Connect(function(player)
	pcall(function()
		graveyardChannel:RemoveUserAsync(player.UserId)
	end)
end)
