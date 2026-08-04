local GameState = {
	CurrentState = "WaitingForPlayers",
	CurrentDay = 1,
	PendingActions = {},
	SecretPairs = {},
	SpyConnections = {},
	SpyTarget = nil,
	PeasantVotes = {},
	LastTribunalDay = 0,
	MatchStats = {},
}

local PlayerData = {}

return {
	GameState = GameState,
	PlayerData = PlayerData,
}
