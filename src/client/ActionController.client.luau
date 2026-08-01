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
local FakeOrderRevealed = ReplicatedStorage:WaitForChild("FakeOrderRevealed")
local PartnerDitched = ReplicatedStorage:WaitForChild("PartnerDitched")
local RoomPartnerSync = ReplicatedStorage:WaitForChild("RoomPartnerSync")

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

local usurperMenu = actionUI:WaitForChild("UsurperMenu")
local usurperTargetList = usurperMenu:WaitForChild("PlayerList")
local fakeOrderButton = usurperMenu:WaitForChild("FakeOrderButton")

local spyMenu = actionUI:WaitForChild("SpyMenu")
local spyTargetList = spyMenu:WaitForChild("PlayerList")
local eavesdropButton = spyMenu:WaitForChild("EavesdropButton")

local DEFAULT_COLOR = Color3.fromRGB(50, 50, 50)
local SELECTED_COLOR = Color3.fromRGB(0, 170, 0)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local VOIDED_COLOR = Color3.new(1, 0, 0)

local LIVING_VIEW_OF_DEAD_TRANSPARENCY = 1
local DEAD_VIEW_OF_DEAD_TRANSPARENCY = 0.5

local selectedTarget: string? = nil
local selectedAssassinationTarget: string? = nil
local selectedUsurperTarget: string? = nil
local selectedSpyTarget: string? = nil
local currentRoomPartner: string? = nil
local localPlayerRole: string? = GetMyRole:InvokeServer()
local pendingExecutionTarget: string? = nil

local activeMenu = "None"
local aliveStatus: { [number]: boolean } = {}
local cooldownStatus: { [number]: number } = {}

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
	usurperMenu.Visible = (activeMenu == "Usurper")
	spyMenu.Visible = (activeMenu == "Spy")
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
			if character and character.Parent then
				setCharacterTransparency(character, deadCharacterTransparency)
			end
		end
	end

	if not localPlayerAlive then
		local localCharacter = Players.LocalPlayer.Character
		if localCharacter and localCharacter.Parent then
			setCharacterTransparency(localCharacter, DEAD_VIEW_OF_DEAD_TRANSPARENCY)
			setLocalTransparencyModifier(localCharacter, DEAD_VIEW_OF_DEAD_TRANSPARENCY)
		end
	end
end

AliveStatusUpdate.OnClientEvent:Connect(
	function(snapshot: { { UserId: number, Name: string, IsAlive: boolean, Cooldown: number? } })
		local wasLocalPlayerAlive = isPlayerAlive(localPlayer)

		local newStatus = {}
		local newCooldowns = {}
		for _, entry in pairs(snapshot) do
			newStatus[entry.UserId] = entry.IsAlive
			newCooldowns[entry.UserId] = entry.Cooldown or 0
		end
		aliveStatus = newStatus
		cooldownStatus = newCooldowns

		updateGhostVisibility()

		if wasLocalPlayerAlive and not isPlayerAlive(localPlayer) then
			activeMenu = "None"
			renderUI()
			game:GetService("TextChatService").TextChannels.RBXGeneral:DisplaySystemMessage("<font color='#FF0000'><b>Welcome to the Graveyard chat. The living cannot hear you.</b></font>")
		end
	end
)

local BANNER_TEXT_COLOR = Color3.fromRGB(255, 0, 0)

local function showTemporaryBanner(name: string, text: string, duration: number)
	local existing = actionUI:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end

	local banner = Instance.new("TextLabel")
	banner.Name = name
	banner.Size = UDim2.new(0.6, 0, 0.1, 0)
	banner.Position = UDim2.new(0.2, 0, 0.05, 0)
	banner.BackgroundTransparency = 1
	banner.TextScaled = true
	banner.Font = Enum.Font.SourceSansBold
	banner.TextColor3 = BANNER_TEXT_COLOR
	banner.Text = text
	banner.Parent = actionUI

	task.delay(duration, function()
		banner:Destroy()
	end)
end

OrderVoided.OnClientEvent:Connect(function()
	if activeMenu == "Executioner" then
		pendingExecutionTarget = nil
		targetDisplay.Text = "[TARGET VOIDED]"
		targetDisplay.TextColor3 = VOIDED_COLOR
		confirmKillButton.Active = false
		confirmKillButton.AutoButtonColor = false
	end

	if isPlayerAlive(localPlayer) and localPlayerRole == "Usurper" then
		showTemporaryBanner("OrderVoidedBanner", "THE KING HAS MADE THEIR DECREE. YOUR ORDER IS VOID.", 6)
	end
end)

FakeOrderRevealed.OnClientEvent:Connect(function()
	showTemporaryBanner("FakeOrderRevealedBanner", "THE KING DID NOT ORDER THAT!", 5)
end)

PartnerDitched.OnClientEvent:Connect(function()
	showTemporaryBanner("PartnerDitchedBanner", "YOUR PARTNER HAS ABANDONED YOU. YOU ARE ALONE.", 6)
end)

RoomPartnerSync.OnClientEvent:Connect(function(partnerName: string?)
	currentRoomPartner = (partnerName and partnerName ~= "") and partnerName or nil
end)

actionUI.Enabled = true

RoleAssigned.OnClientEvent:Connect(function(role: string)
	localPlayerRole = role
end)

local NO_TARGETS_LABEL_NAME = "NoValidTargetsLabel"
local NO_TARGETS_TEXT_COLOR = Color3.fromRGB(200, 60, 60)

local function clearNoTargetsLabel(listContainer: Instance)
	local label = listContainer:FindFirstChild(NO_TARGETS_LABEL_NAME)
	if label then
		label:Destroy()
	end
end

local function showNoTargetsLabel(listContainer: Instance)
	local label = Instance.new("TextLabel")
	label.Name = NO_TARGETS_LABEL_NAME
	label.Text = "NO VALID TARGETS"
	label.Size = UDim2.new(1, 0, 0, 50)
	label.TextScaled = true
	label.BackgroundTransparency = 1
	label.TextColor3 = NO_TARGETS_TEXT_COLOR
	label.Parent = listContainer
end

local function setActionButtonEnabled(button: TextButton, enabled: boolean)
	button.Active = enabled
	button.AutoButtonColor = enabled
end

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
	clearNoTargetsLabel(playerList)
	for _, child in playerList:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local targetCount = 0
	for _, player in Players:GetPlayers() do
		if player ~= Players.LocalPlayer and isPlayerAlive(player) then
			targetCount += 1

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

	setActionButtonEnabled(submitButton, targetCount > 0)
	if targetCount == 0 then
		showNoTargetsLabel(playerList)
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
	clearNoTargetsLabel(targetList)
	for _, child in targetList:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local targetCount = 0
	for _, player in Players:GetPlayers() do
		if player == Players.LocalPlayer then
			print("[DEBUG] populateAssassinationList: skipping", player.Name, "(local player)")
		elseif not isPlayerAlive(player) then
			print("[DEBUG] populateAssassinationList: skipping", player.Name, "(dead, UserId:", player.UserId, ")")
		else
			print("[DEBUG] populateAssassinationList: adding", player.Name, "(UserId:", player.UserId, ")")
			targetCount += 1

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

	setActionButtonEnabled(assassinateButton, targetCount > 0)
	if targetCount == 0 then
		showNoTargetsLabel(targetList)
	end
end

local function resetUsurperButtonColors()
	for _, child in usurperTargetList:GetChildren() do
		if child:IsA("TextButton") then
			child.BackgroundColor3 = DEFAULT_COLOR
		end
	end
end

local function selectUsurperTarget(targetName: string, clickedButton: TextButton)
	selectedUsurperTarget = targetName
	resetUsurperButtonColors()
	clickedButton.BackgroundColor3 = SELECTED_COLOR
end

local function populateUsurperList()
	clearNoTargetsLabel(usurperTargetList)
	for _, child in usurperTargetList:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local targetCount = 0
	for _, player in Players:GetPlayers() do
		if player ~= Players.LocalPlayer and isPlayerAlive(player) then
			targetCount += 1

			local button = Instance.new("TextButton")
			button.Name = player.Name
			button.Text = player.Name
			button.Size = UDim2.new(1, 0, 0, 50)
			button.TextScaled = true
			button.BackgroundColor3 = DEFAULT_COLOR
			button.TextColor3 = TEXT_COLOR
			button.Parent = usurperTargetList

			button.MouseButton1Click:Connect(function()
				selectUsurperTarget(player.Name, button)
			end)
		end
	end

	setActionButtonEnabled(fakeOrderButton, targetCount > 0)
	if targetCount == 0 then
		showNoTargetsLabel(usurperTargetList)
	end
end

local function resetSpyButtonColors()
	for _, child in spyTargetList:GetChildren() do
		if child:IsA("TextButton") then
			child.BackgroundColor3 = DEFAULT_COLOR
		end
	end
end

local function selectSpyTarget(targetName: string, clickedButton: TextButton)
	selectedSpyTarget = targetName
	resetSpyButtonColors()
	clickedButton.BackgroundColor3 = SELECTED_COLOR
end

local function populateSpyList()
	clearNoTargetsLabel(spyTargetList)
	for _, child in spyTargetList:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local targetCount = 0
	for _, player in Players:GetPlayers() do
		if player.Name == currentRoomPartner then
			continue
		end

		if player ~= Players.LocalPlayer and isPlayerAlive(player) then
			targetCount += 1

			local button = Instance.new("TextButton")
			button.Name = player.Name
			button.Text = player.Name
			button.Size = UDim2.new(1, 0, 0, 50)
			button.TextScaled = true
			button.BackgroundColor3 = DEFAULT_COLOR
			button.TextColor3 = TEXT_COLOR
			button.Parent = spyTargetList

			button.MouseButton1Click:Connect(function()
				selectSpyTarget(player.Name, button)
			end)
		end
	end

	setActionButtonEnabled(eavesdropButton, targetCount > 0)
	if targetCount == 0 then
		showNoTargetsLabel(spyTargetList)
	end
end

local function updateVisibility()
	print("VISIBILITY CHECK -> Role: ", tostring(localPlayerRole), " | State: ", tostring(CurrentGameState.Value))

	local stateLower = string.lower(CurrentGameState.Value)
	local localCooldown = cooldownStatus[localPlayer.UserId] or 0

	if string.find(stateLower, "secret") and localPlayerRole == "King" then
		activeMenu = "KingMurder"
		populatePlayerList()
	elseif string.find(stateLower, "secret") and localPlayerRole == "Spy" then
		activeMenu = "Spy"
		populateSpyList()
	elseif string.find(stateLower, "night") and localPlayerRole == "Revolutionary" then
		activeMenu = "Assassination"
		populateAssassinationList()
	elseif string.find(stateLower, "night") and activeMenu == "Executioner" then
		-- Do nothing, preserve the menu
	elseif string.find(stateLower, "day gathering") and localPlayerRole == "Usurper" and localCooldown == 0 then
		activeMenu = "Usurper"
		populateUsurperList()
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

fakeOrderButton.MouseButton1Click:Connect(function()
	if not selectedUsurperTarget then
		return
	end

	ActionRequest:FireServer("OrderFakeMurder", selectedUsurperTarget)
	selectedUsurperTarget = nil
	resetUsurperButtonColors()
	activeMenu = "None"
	renderUI()
end)

eavesdropButton.MouseButton1Click:Connect(function()
	if not selectedSpyTarget then
		return
	end

	ActionRequest:FireServer("Eavesdrop", selectedSpyTarget)
	selectedSpyTarget = nil
	resetSpyButtonColors()
	activeMenu = "None"
	renderUI()
end)

updateVisibility()
renderUI()

task.spawn(function()
	while task.wait(1) do
		updateGhostVisibility()
	end
end)
