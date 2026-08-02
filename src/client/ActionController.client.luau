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
local StrikeIntercepted = ReplicatedStorage:WaitForChild("StrikeIntercepted")
local RoleRevealed = ReplicatedStorage:WaitForChild("RoleRevealed")
local GossipPing = ReplicatedStorage:WaitForChild("GossipPing")
local TribunalResult = ReplicatedStorage:WaitForChild("TribunalResult")
local CrownInherited = ReplicatedStorage:WaitForChild("CrownInherited")

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

local martyrMenu = actionUI:WaitForChild("MartyrMenu")
local martyrTargetList = martyrMenu:WaitForChild("PlayerList")
local oathButton = martyrMenu:WaitForChild("OathButton")

local bishopMenu = actionUI:WaitForChild("BishopMenu")
local revealButton = bishopMenu:WaitForChild("RevealButton")

local peasantMenu = actionUI:WaitForChild("PeasantMenu")
local peasantTargetList = peasantMenu:WaitForChild("PlayerList")
local accuseButton = peasantMenu:WaitForChild("AccuseButton")

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
local selectedMartyrTarget: string? = nil
local selectedPeasantTarget: string? = nil
local currentRoomPartner: string? = nil
local localPlayerRole: string? = GetMyRole:InvokeServer()
local pendingExecutionTarget: string? = nil
local localProtectedTarget: number? = nil
local localBishopCooldown: number = 0
local localScannedPlayers: { number } = {}
local localLastTribunalDay: number = 0
local localAlivePeasantCount: number = 0
local localCurrentDay: number = 1
local hasCastPeasantVote = false
local localHasCrown = false
local localIsSorcererAlive = false

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
	if activeMenu == "Peasant" then
		hasCastPeasantVote = false
	end

	kingMurderAbility.Visible = (activeMenu == "KingMurder")
	executionerMenu.Visible = (activeMenu == "Executioner")
	assassinationMenu.Visible = (activeMenu == "Assassination")
	usurperMenu.Visible = (activeMenu == "Usurper")
	spyMenu.Visible = (activeMenu == "Spy")
	martyrMenu.Visible = (activeMenu == "Martyr")
	bishopMenu.Visible = (activeMenu == "Bishop")
	peasantMenu.Visible = (activeMenu == "Peasant")
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
	function(snapshot: {
		{
			UserId: number,
			Name: string,
			IsAlive: boolean,
			Cooldown: number?,
			ProtectedTarget: number?,
			BishopCooldown: number?,
			ScannedPlayers: { number }?,
			LastTribunalDay: number?,
			AlivePeasantCount: number?,
			CurrentDay: number?,
			HasCrown: boolean?,
			IsSorcererAlive: boolean?,
		}
	})
		local wasLocalPlayerAlive = isPlayerAlive(localPlayer)

		local newStatus = {}
		local newCooldowns = {}
		for _, entry in pairs(snapshot) do
			newStatus[entry.UserId] = entry.IsAlive
			newCooldowns[entry.UserId] = entry.Cooldown or 0
			if entry.UserId == localPlayer.UserId then
				localProtectedTarget = entry.ProtectedTarget
				localBishopCooldown = entry.BishopCooldown or 0
				localScannedPlayers = entry.ScannedPlayers or {}
				localLastTribunalDay = entry.LastTribunalDay or 0
				localAlivePeasantCount = entry.AlivePeasantCount or 0
				localCurrentDay = entry.CurrentDay or localCurrentDay
				localHasCrown = entry.HasCrown == true
				localIsSorcererAlive = entry.IsSorcererAlive == true
			end
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
local BANNER_SUCCESS_COLOR = Color3.fromRGB(0, 200, 0)
local BANNER_INFO_COLOR = Color3.fromRGB(130, 150, 190)
local BANNER_GRAY_COLOR = Color3.fromRGB(160, 160, 160)
local BANNER_GOLD_COLOR = Color3.fromRGB(212, 175, 55)

local function showTemporaryBanner(name: string, text: string, duration: number, color: Color3?)
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
	banner.TextColor3 = color or BANNER_TEXT_COLOR
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

local function resetMartyrButtonColors()
	for _, child in martyrTargetList:GetChildren() do
		if child:IsA("TextButton") then
			child.BackgroundColor3 = DEFAULT_COLOR
		end
	end
end

local function selectMartyrTarget(targetName: string, clickedButton: TextButton)
	selectedMartyrTarget = targetName
	resetMartyrButtonColors()
	clickedButton.BackgroundColor3 = SELECTED_COLOR
end

local function populateMartyrList()
	clearNoTargetsLabel(martyrTargetList)
	for _, child in martyrTargetList:GetChildren() do
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
			button.Parent = martyrTargetList

			button.MouseButton1Click:Connect(function()
				selectMartyrTarget(player.Name, button)
			end)
		end
	end

	setActionButtonEnabled(oathButton, targetCount > 0)
	if targetCount == 0 then
		showNoTargetsLabel(martyrTargetList)
	end
end

local function resetPeasantButtonColors()
	for _, child in peasantTargetList:GetChildren() do
		if child:IsA("TextButton") then
			child.BackgroundColor3 = DEFAULT_COLOR
		end
	end
end

local function selectPeasantTarget(targetName: string, clickedButton: TextButton)
	selectedPeasantTarget = targetName
	resetPeasantButtonColors()
	clickedButton.BackgroundColor3 = SELECTED_COLOR
end

local function populatePeasantList()
	clearNoTargetsLabel(peasantTargetList)
	for _, child in peasantTargetList:GetChildren() do
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
			button.Parent = peasantTargetList

			button.MouseButton1Click:Connect(function()
				selectPeasantTarget(player.Name, button)
			end)
		end
	end

	setActionButtonEnabled(accuseButton, targetCount > 0)
	if targetCount == 0 then
		showNoTargetsLabel(peasantTargetList)
	end
end

local function updateVisibility()
	print("VISIBILITY CHECK -> Role: ", tostring(localPlayerRole), " | State: ", tostring(CurrentGameState.Value))

	local stateLower = string.lower(CurrentGameState.Value)
	local localCooldown = cooldownStatus[localPlayer.UserId] or 0

	local bishopPartnerAlreadyScanned = false
	if currentRoomPartner then
		local partnerPlayer = Players:FindFirstChild(currentRoomPartner)
		if partnerPlayer and table.find(localScannedPlayers, partnerPlayer.UserId) then
			bishopPartnerAlreadyScanned = true
		end
	end

	if string.find(stateLower, "secret") and localHasCrown == true then
		activeMenu = "KingMurder"
		populatePlayerList()
	elseif string.find(stateLower, "secret") and localPlayerRole == "Spy" then
		activeMenu = "Spy"
		populateSpyList()
	elseif string.find(stateLower, "secret") and localPlayerRole == "Martyr" and localProtectedTarget == nil then
		activeMenu = "Martyr"
		populateMartyrList()
	elseif
		string.find(stateLower, "secret")
		and localPlayerRole == "Bishop"
		and localBishopCooldown == 0
		and currentRoomPartner ~= nil
		and not bishopPartnerAlreadyScanned
	then
		activeMenu = "Bishop"
	elseif
		string.find(stateLower, "evening")
		and localPlayerRole == "Peasant"
		and localCurrentDay > 1
		and localCurrentDay > (localLastTribunalDay + 1)
		and localAlivePeasantCount >= 3
	then
		activeMenu = "Peasant"
		populatePeasantList()
	elseif string.find(stateLower, "night") and localPlayerRole == "Revolutionary" then
		activeMenu = "Assassination"
		populateAssassinationList()
	elseif
		string.find(stateLower, "night")
		and activeMenu == "Executioner"
		and (localPlayerRole == "Sorcerer" or (localPlayerRole == "Knight" and localIsSorcererAlive == false))
	then
		-- Do nothing, preserve the menu
	elseif string.find(stateLower, "day gathering") and localPlayerRole == "Usurper" and localCooldown == 0 and not localHasCrown then
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

oathButton.MouseButton1Click:Connect(function()
	if not selectedMartyrTarget then
		return
	end

	ActionRequest:FireServer("MartyrOath", selectedMartyrTarget)
	selectedMartyrTarget = nil
	resetMartyrButtonColors()
	activeMenu = "None"
	renderUI()
end)

accuseButton.MouseButton1Click:Connect(function()
	if not selectedPeasantTarget then
		return
	end

	ActionRequest:FireServer("Accuse", selectedPeasantTarget)
	hasCastPeasantVote = true
	selectedPeasantTarget = nil
	resetPeasantButtonColors()
	activeMenu = "None"
	renderUI()
end)

StrikeIntercepted.OnClientEvent:Connect(function(martyrName: string, originalTargetName: string)
	showTemporaryBanner(
		"StrikeInterceptedBanner",
		"YOUR STRIKE ON " .. originalTargetName:upper() .. " WAS INTERCEPTED BY " .. martyrName:upper() .. "!",
		6
	)
end)

revealButton.MouseButton1Click:Connect(function()
	ActionRequest:FireServer("BishopReveal")
	activeMenu = "None"
	renderUI()
end)

RoleRevealed.OnClientEvent:Connect(function(targetName: string, winCondition: string)
	showTemporaryBanner(
		"RoleRevealedBanner",
		targetName:upper() .. " FIGHTS FOR: " .. winCondition:upper(),
		6,
		BANNER_SUCCESS_COLOR
	)
end)

GossipPing.OnClientEvent:Connect(function()
	showTemporaryBanner(
		"GossipPingBanner",
		"WHISPERS IN THE DARK: YOUR PARTNER MIGHT BE A PEASANT...",
		5,
		BANNER_INFO_COLOR
	)
end)

TribunalResult.OnClientEvent:Connect(function(message: string, isKing: boolean)
	activeMenu = "None"
	renderUI()

	if isPlayerAlive(localPlayer) and localPlayerRole == "Peasant" and not hasCastPeasantVote then
		showTemporaryBanner("TribunalVoidBanner", "THE MOB REACHED A MAJORITY WITHOUT YOU.", 3, BANNER_GRAY_COLOR)
	end

	showTemporaryBanner(
		"TribunalResultBanner",
		message,
		6,
		isKing and BANNER_SUCCESS_COLOR or BANNER_TEXT_COLOR
	)
end)

CrownInherited.OnClientEvent:Connect(function()
	showTemporaryBanner(
		"CrownInheritedBanner",
		"THE KING IS DEAD. LONG LIVE THE KING. YOU NOW HOLD THE CROWN.",
		6,
		BANNER_GOLD_COLOR
	)

	renderUI()
end)

updateVisibility()
renderUI()

task.spawn(function()
	while task.wait(1) do
		updateGhostVisibility()
	end
end)
