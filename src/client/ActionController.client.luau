local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local CurrentGameState = ReplicatedStorage:WaitForChild("CurrentGameState")
local ActionRequest = ReplicatedStorage:WaitForChild("ActionRequest")
local ExecutionPrompt = ReplicatedStorage:WaitForChild("ExecutionPrompt")
local RoleAssigned = ReplicatedStorage:WaitForChild("RoleAssigned")
local GetMyRole = ReplicatedStorage:WaitForChild("GetMyRole")
local AliveStatusUpdate = ReplicatedStorage:WaitForChild("AliveStatusUpdate")
local OrderVoided = ReplicatedStorage:WaitForChild("OrderVoided")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local actionUI = playerGui:WaitForChild("ActionUI")
local kingMurderAbility = actionUI:WaitForChild("KingMurderAbility")
local playerList = kingMurderAbility:WaitForChild("PlayerList")
local submitButton = kingMurderAbility:WaitForChild("SubmitButton")

local executionerMenu = actionUI:WaitForChild("ExecutionerMenu")
local targetDisplay = executionerMenu:WaitForChild("TargetDisplay")
local confirmKillButton = executionerMenu:WaitForChild("ConfirmKill")
local DEFAULT_TARGET_DISPLAY_COLOR = targetDisplay.TextColor3

local assassinationMenu = actionUI:WaitForChild("AssassinationMenu")
local targetList = assassinationMenu:WaitForChild("PlayerList")
local assassinateButton = assassinationMenu:WaitForChild("AssassinationButton")

local DEFAULT_COLOR = Color3.fromRGB(50, 50, 50)
local SELECTED_COLOR = Color3.fromRGB(0, 170, 0)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local VOIDED_COLOR = Color3.new(1, 0, 0)

local LIVING_VIEW_OF_DEAD_TRANSPARENCY = 1
local DEAD_VIEW_OF_DEAD_TRANSPARENCY = 0.5

local selectedTarget: string? = nil
local selectedAssassinationTarget: string? = nil
local localPlayerRole: string? = GetMyRole:InvokeServer()
local pendingExecutionTarget: string? = nil

local activeMenu = "None"
local aliveStatus: { [number]: boolean } = {}

local function isPlayerAlive(player: Player): boolean
	local status = aliveStatus[player.UserId]
	if status == nil then
		return true
	end
	return status
end

local function renderUI()
	kingMurderAbility.Visible = (activeMenu == "KingMurder")
	executionerMenu.Visible = (activeMenu == "Executioner")
	assassinationMenu.Visible = (activeMenu == "Assassination")
end

local function setCharacterTransparency(character: Model, transparency: number)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") then
			descendant.Transparency = transparency
		end
	end
end

local function setLocalTransparencyModifier(character: Model, modifier: number)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = modifier
		end
	end
end

local function updateGhostVisibility()
	local localPlayerAlive = isPlayerAlive(localPlayer)
	local deadCharacterTransparency = localPlayerAlive and LIVING_VIEW_OF_DEAD_TRANSPARENCY
		or DEAD_VIEW_OF_DEAD_TRANSPARENCY

	for _, player in Players:GetPlayers() do
		if not isPlayerAlive(player) then
			local character = player.Character
			if character then
				setCharacterTransparency(character, deadCharacterTransparency)

				if player == localPlayer then
					setLocalTransparencyModifier(character, deadCharacterTransparency)
				end
			end
		end
	end
end

local function setChatChannel(channelName: string)
	local textChannels = TextChatService:WaitForChild("TextChannels")
	local channel = textChannels:WaitForChild(channelName)
	local chatInputBarConfiguration = TextChatService:WaitForChild("ChatInputBarConfiguration")
	chatInputBarConfiguration.TargetTextChannel = channel
end

local function onCharacterAdded(player: Player)
	if not isPlayerAlive(player) then
		updateGhostVisibility()
	end
end

local function hookGhostRespawn(player: Player)
	player.CharacterAdded:Connect(function()
		onCharacterAdded(player)
	end)
end

for _, player in Players:GetPlayers() do
	hookGhostRespawn(player)
end

Players.PlayerAdded:Connect(hookGhostRespawn)

AliveStatusUpdate.OnClientEvent:Connect(function(snapshot: { { UserId: number, Name: string, IsAlive: boolean } })
	local wasLocalPlayerAlive = isPlayerAlive(localPlayer)

	local newStatus = {}
	for _, entry in pairs(snapshot) do
		newStatus[entry.UserId] = entry.IsAlive
	end
	aliveStatus = newStatus

	updateGhostVisibility()

	if wasLocalPlayerAlive and not isPlayerAlive(localPlayer) then
		activeMenu = "None"
		renderUI()
		setChatChannel("Graveyard")
	elseif not wasLocalPlayerAlive and isPlayerAlive(localPlayer) then
		setChatChannel("RBXGeneral")
	end
end)

OrderVoided.OnClientEvent:Connect(function()
	if activeMenu ~= "Executioner" then
		return
	end

	pendingExecutionTarget = nil
	targetDisplay.Text = "[TARGET VOIDED]"
	targetDisplay.TextColor3 = VOIDED_COLOR
	confirmKillButton.Active = false
	confirmKillButton.AutoButtonColor = false
end)

actionUI.Enabled = true

RoleAssigned.OnClientEvent:Connect(function(role: string)
	localPlayerRole = role
end)

local function resetButtonColors()
	for _, child in playerList:GetChildren() do
		if child:IsA("TextButton") then
			child.BackgroundColor3 = DEFAULT_COLOR
		end
	end
end

local function selectTarget(targetName: string, clickedButton: TextButton)
	selectedTarget = targetName
	resetButtonColors()
	clickedButton.BackgroundColor3 = SELECTED_COLOR
end

local function populatePlayerList()
	for _, child in playerList:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	for _, player in Players:GetPlayers() do
		if player ~= Players.LocalPlayer and isPlayerAlive(player) then
			local button = Instance.new("TextButton")
			button.Name = player.Name
			button.Text = player.Name
			button.Size = UDim2.new(1, 0, 0, 50)
			button.TextScaled = true
			button.BackgroundColor3 = DEFAULT_COLOR
			button.TextColor3 = TEXT_COLOR
			button.Parent = playerList

			button.MouseButton1Click:Connect(function()
				selectTarget(player.Name, button)
			end)
		end
	end
end

local function resetAssassinationButtonColors()
	for _, child in targetList:GetChildren() do
		if child:IsA("TextButton") then
			child.BackgroundColor3 = DEFAULT_COLOR
		end
	end
end

local function selectAssassinationTarget(targetName: string, clickedButton: TextButton)
	selectedAssassinationTarget = targetName
	resetAssassinationButtonColors()
	clickedButton.BackgroundColor3 = SELECTED_COLOR
end

local function populateAssassinationList()
	for _, child in targetList:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	for _, player in Players:GetPlayers() do
		if player == Players.LocalPlayer then
			print("[DEBUG] populateAssassinationList: skipping", player.Name, "(local player)")
		elseif not isPlayerAlive(player) then
			print("[DEBUG] populateAssassinationList: skipping", player.Name, "(dead, UserId:", player.UserId, ")")
		else
			print("[DEBUG] populateAssassinationList: adding", player.Name, "(UserId:", player.UserId, ")")

			local button = Instance.new("TextButton")
			button.Name = player.Name
			button.Text = player.Name
			button.Size = UDim2.new(1, 0, 0, 50)
			button.TextScaled = true
			button.BackgroundColor3 = DEFAULT_COLOR
			button.TextColor3 = TEXT_COLOR
			button.Parent = targetList

			button.MouseButton1Click:Connect(function()
				selectAssassinationTarget(player.Name, button)
			end)
		end
	end
end

local function updateVisibility()
	print("VISIBILITY CHECK -> Role: ", tostring(localPlayerRole), " | State: ", tostring(CurrentGameState.Value))

	local stateLower = string.lower(CurrentGameState.Value)

	if string.find(stateLower, "secret") and localPlayerRole == "King" then
		activeMenu = "KingMurder"
		populatePlayerList()
	elseif string.find(stateLower, "night") and localPlayerRole == "Revolutionary" then
		activeMenu = "Assassination"
		populateAssassinationList()
	elseif string.find(stateLower, "night") and activeMenu == "Executioner" then
		-- Do nothing, preserve the menu
	else
		activeMenu = "None"
	end

	renderUI()
end

CurrentGameState:GetPropertyChangedSignal("Value"):Connect(updateVisibility)

submitButton.MouseButton1Click:Connect(function()
	if not selectedTarget then
		return
	end

	ActionRequest:FireServer("OrderMurder", selectedTarget)
	selectedTarget = nil
	resetButtonColors()
	activeMenu = "None"
	renderUI()
end)

ExecutionPrompt.OnClientEvent:Connect(function(targetName: string)
	pendingExecutionTarget = targetName
	activeMenu = "Executioner"
	targetDisplay.Text = "The King demands the death of: " .. targetName
	targetDisplay.TextColor3 = DEFAULT_TARGET_DISPLAY_COLOR
	confirmKillButton.Active = true
	confirmKillButton.AutoButtonColor = true
	renderUI()
end)

confirmKillButton.MouseButton1Click:Connect(function()
	if pendingExecutionTarget then
		ActionRequest:FireServer("ConfirmExecution", pendingExecutionTarget)
		pendingExecutionTarget = nil
	end

	activeMenu = "None"
	renderUI()
end)

assassinateButton.MouseButton1Click:Connect(function()
	if not selectedAssassinationTarget then
		return
	end

	ActionRequest:FireServer("Assassinate", selectedAssassinationTarget)
	selectedAssassinationTarget = nil
	resetAssassinationButtonColors()
	activeMenu = "None"
	renderUI()
end)

updateVisibility()
renderUI()
