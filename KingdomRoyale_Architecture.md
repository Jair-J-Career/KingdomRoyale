# Kingdom Royale — Architecture

Complete architecture reference as of the end of Phase D ("Endgame — Win Conditions & Economy", §14). Phases A ("The Room Crashers": Spy, Martyr, Bishop), B ("The Uprising": Peasant), and C ("The Passive Inheritors": Crown succession) are also fully implemented. This document is the single source of truth for the game's server/client engine — every section below was verified directly against the current contents of the source files it describes.

## 1. Project Structure

```
Kingdom_Royale/
├── default.project.json          # Rojo project map (DataModel tree)
└── src/
    ├── server/
    │   ├── init.server.luau       # placeholder entry script
    │   ├── GameLoop.server.luau   # Day/Night state machine, role assignment, teleports, collision groups, cooldown ticking, win-condition evaluation, hub teleport
    │   ├── ActionHandler.server.luau  # Validates/executes every role ability + the King/Usurper order system + MatchStats kill/intercept tracking
    │   ├── ChatFilter.server.luau # ShouldDeliverCallback-based Graveyard/room-privacy/eavesdropping chat filter
    │   ├── DataManager.luau       # ProfileService wrapper — persistent RoyalCoins/TotalGamesCompleted/PlayerLevel, see §14.1
    │   ├── EconomyManager.luau    # Match-end payout calculator, see §14.2
    │   └── ProfileService.lua     # Mad Studio's standalone ProfileService (vendored, unmodified)
    ├── client/
    │   ├── init.client.luau       # placeholder entry script
    │   ├── HUDController.client.luau   # Top clock + role card display
    │   └── ActionController.client.luau # State-driven menu UI for every role + ghost visibility polling + Game Over reveal (§6.5)
    └── shared/
        ├── GameState.luau         # Single source of truth for GameState + PlayerData + MatchStats
        ├── Tribunal.luau          # Shared Tribunal.Execute(targetPlayer) — see §12
        └── Hello.luau             # unused sample module
```

Rojo mapping (`default.project.json`):
- `src/shared` → `ReplicatedStorage.Shared`
- `src/server` → `ServerScriptService.Server`
- `src/client` → `StarterPlayer.StarterPlayerScripts.Client`

`GameLoop.server.luau` and `ActionHandler.server.luau` are independent `Script` instances (not ModuleScripts) that both `require()` `GameState.luau` and mutate the same live tables through it — there is no ownership boundary between them. This split exists because `GameLoop.server.luau` owns the day/night timer and phase transitions, while `ActionHandler.server.luau` owns the single `ActionRequest` dispatcher that every role ability routes through. `ChatFilter.server.luau` is a third, independent consumer of the same shared state, used only for read access.

`DataManager.luau` and `EconomyManager.luau` are `ModuleScript`s, not `Script`s — they export tables and are `require()`d by whatever needs them. `EconomyManager` is required by `GameLoop.server.luau` via `require(script.Parent.EconomyManager)` — a sibling require, since both live in the same Rojo-mapped `src/server` folder — and `EconomyManager` itself `require()`s `DataManager` the same way. `ProfileService.lua` is Mad Studio's standalone ProfileService module, vendored unmodified; `DataManager.luau` is the only script that requires it directly. See §14 for the full data/economy layer.

## 2. Roles & Win Conditions

15 roles are defined in `ROLES` (`GameLoop.server.luau`), matching a 15-player lobby:

```lua
local ROLES = {
    "King", "Prince", "Double", "Sorcerer", "Knight",
    "Revolutionary", "Usurper", "Bishop", "Martyr", "Spy",
    "Peasant", "Peasant", "Peasant", "Peasant", "Peasant",
}
```

Win conditions (`WIN_CONDITIONS` in `ActionHandler.server.luau`, used by the Bishop's reveal — see §11.3):

| Win Condition | Roles |
|---|---|
| The Crown | King, Sorcerer, Prince, Knight, Double |
| The Uprising | Revolutionary, Peasant, Spy |
| The Rogue | Usurper |
| The Oathbound | Martyr |
| *(none)* | Bishop — has no entry in `WIN_CONDITIONS`; scanning a Bishop resolves `winCondition` to `nil` and would display `"NIL"` in the reveal banner. Untested in practice since the current test rigs never seat two Bishops. |

> **Two different, same-named "win condition" concepts.** The table above labels each role's *faction* — used only by the Bishop's reveal (§10.3) and, as of Phase D, by `EconomyManager`'s faction-victory bonus (§14.2, via its own copy of this same mapping, `ROLE_FACTIONS`). It has nothing to do with what actually **ends the match** — that's a separate, unrelated concept: `GameLoop.server.luau`'s `evaluateWinConditions()` (§14.4), which decides when the game is *over* by checking which roles are still alive, not which faction "should" win a hypothetical vote. A faction label and an end-of-match trigger are two different systems that happen to share vocabulary.

## 3. The State Machine & Timers (`GameLoop.server.luau`)

A single `while true do` loop, driven by `GameState.CurrentState`, alternates between a **wait** step and an **action** step every iteration, then always calls `updateGameStateDisplay()` at the very bottom regardless of which branch ran.

### 3.1 Wait durations

```lua
if GameState.CurrentState == "WaitingForPlayers" then
    repeat task.wait(1) until #Players:GetPlayers() >= 3
elseif GameState.CurrentState == "SecretMeetings" then
    task.wait(20)
elseif GameState.CurrentState == "EveningGathering" then
    if GameState.CurrentDay > 1 then task.wait(20) else task.wait(5) end
else
    task.wait(5)  -- DayGathering, EveningGathering-on-Day-1 falls through above, NightPhase
end
```

| Phase | Wait | Why |
|---|---|---|
| `WaitingForPlayers` | polls every 1s until `#Players >= 3` | lobby fill |
| `DayGathering` | 5s | passive — just a teleport/cooldown-tick beat |
| `SecretMeetings` | 20s | players hold a private conversation, King orders, Spy eavesdrops, Martyr swears, Bishop scans |
| `EveningGathering` | 20s from Day 2 onward, 5s on Day 1 | Peasants need time to cast Tribunal votes; Day 1 has no prior day to vote about, so it stays quick |
| `NightPhase` | 5s | passive — executions already resolved instantly server-side |

### 3.2 Phase transition table

| Current `CurrentState` | Action taken | Next `CurrentState` |
|---|---|---|
| `WaitingForPlayers` | Wait for **4** connected players (`while #Players:GetPlayers() < 4 do task.wait(1) end` — see the note below on why this differs from the 3-player wait above), then wait for every connected player to have a spawned `Character` (`player.CharacterAdded:Wait()` per player missing one), then `task.wait(2)` to let physics settle, then `assignRoles()`, teleport to `GrandHall.SpawnPoint_Main` | `DayGathering` |
| `DayGathering` | Decrement every living Bishop's `BishopCooldown` (if `> 0`) via a dedicated loop, then `runSecretMeetings()` (pairs players into `Workspace.SecretRooms`, fires Gossip pings, runs Third Wheel Martyr placement — see §11.1/§11.2) | `SecretMeetings` |
| `SecretMeetings` | `table.clear(GameState.SecretPairs)`, `GameState.SpyTarget = nil`, `removeSpyInvisibility()` for every living Spy, teleport to `GrandHall.SpawnPoint_Main` | `EveningGathering` |
| `EveningGathering` | **Tribunal timeout tie-break** (see §12.4), then `table.clear(GameState.PeasantVotes)`, then a 6s pause *if* the tie-break fired, then teleport to `PrivateQuarters.SpawnPoint_Private`, `notifyExecutioners()` | `NightPhase` |
| `NightPhase` | Calls `evaluateWinConditions()` (§14.4) first. **If it returns a winning faction**: `CurrentState = "GameOver"`, `updateGameStateDisplay()`, `EconomyManager:DistributeMatchRewards()`, fire `GameOverReveal` to all clients, `task.wait(15)`, `TeleportService:TeleportAsync()` everyone to the hub, loop `break`. **Else if `CurrentDay == 6`** (nobody's win condition was met — a draw): the identical `GameOver`/payout/reveal/teleport/`break` sequence, but with `winningFaction = "None"` and `wasPacifist = false`. **Otherwise**: `table.clear(PendingActions)`, `CurrentDay += 1`, teleport to `GrandHall.SpawnPoint_Main`, `tickCooldowns()`, `broadcastAliveStatus()` | `DayGathering` (or `GameOver`) |

> **Note on the double player-count gate**: the `WaitingForPlayers` *wait* step uses `#Players:GetPlayers() >= 3`, but the `WaitingForPlayers` *action* block immediately re-gates on `#Players:GetPlayers() < 4`. The `>= 3` outer condition is effectively dead — the loop can't proceed past `WaitingForPlayers` until 4 players connect regardless, because the inner gate is stricter. This is a leftover from iterative test-rig tuning (earlier rigs used 3 players, current ones use 4); if the lobby size is ever changed again, both numbers need to move together or the outer wait becomes misleading.

`notifyExecutioners()` (called on entering `NightPhase`): reads `PendingActions.ActiveMurder`; if none exists, returns immediately (no prompts sent that night). Otherwise scans for a living Sorcerer (`isSorcAlive`), then loops every player whose `Role` is `Sorcerer` or `Knight` and fires `ExecutionPrompt:FireClient(player, targetName)` — **except** a Knight is skipped entirely (`continue`) if `isSorcAlive == true` (see §8.2, Knight Lockout). This loop does **not** check the recipient's own `IsAlive` — a dead Sorcerer/Knight can still receive the prompt; `handleConfirmExecution()`'s own `requesterData.IsAlive == false` guard is what actually makes a dead executioner's confirm a no-op.

`tickCooldowns()` (called once per `NightPhase → DayGathering` transition): decrements every `PlayerData` entry's generic `Cooldown` field (floor 0) if it's set — this is the Usurper's fake-order penalty (see §8.1), not related to `BishopCooldown` or `LastTribunalDay`, which use their own separate mechanisms.

`updateGameStateDisplay()`: writes `ReplicatedStorage.CurrentGameState.Value = string.format("Day %d: %s", CurrentDay, displayName)` via `STATE_DISPLAY_NAMES`. This `StringValue` is the *only* channel the client reads game phase from — `ActionController.client.luau` lowercases it and does substring matches (`"secret"`, `"night"`, `"evening"`, `"day gathering"`), and also parses the leading day number back out of it (see §6.3).

## 4. Data Layer

### 4.1 `GameState.luau` (shared module, `ReplicatedStorage.Shared.GameState`)

```lua
GameState = {
    CurrentState = "WaitingForPlayers",
    CurrentDay = 1,
    PendingActions = {},
    SecretPairs = {},      -- bidirectional map: [UserId] = partnerUserId, current SecretMeetings pairing
    SpyConnections = {},   -- [UserId] = the Spy's active DescendantAdded RBXScriptConnection, while eavesdropping
    SpyTarget = nil,       -- UserId the currently-eavesdropping Spy is standing over, or nil
    PeasantVotes = {},     -- [voterUserId] = accusedUserId, current EveningGathering's Tribunal vote pool
    LastTribunalDay = 0,   -- CurrentDay value as of the last Tribunal.Execute() call, or 0 if none has ever fired
    MatchStats = {},       -- [UserId] = { Kills, InterceptedKingHit, VotedKingCorrectly } -- see §14.3
}
PlayerData = {}
```

Because Luau tables are passed by reference, and Roblox caches a `ModuleScript`'s return value per-VM, every server script that `require()`s this module — `GameLoop.server.luau`, `ActionHandler.server.luau`, `ChatFilter.server.luau`, and `Tribunal.luau` — shares the exact same underlying `GameState`/`PlayerData` tables. There is no replication or ownership boundary; it's an in-process shared-state singleton, server-side only. `EconomyManager.luau` (§14.2) is a partial exception: it `require()`s this module too, but only for `PlayerData` — `GameState.MatchStats` isn't read through that require, it's handed in explicitly as `EconomyManager:DistributeMatchRewards()`'s third parameter by whichever caller (currently only `GameLoop.server.luau`) reads `GameState.MatchStats` itself.

`LastTribunalDay` is an **absolute day tracker**, not a countdown, by design: an earlier version used a decrementing `GameState.TribunalCooldown` (set to `2` on use, ticked down once per `DayGathering`), mirroring `PlayerData.BishopCooldown`. It was scrapped because the client used to independently derive "what day is it" by regex-matching the display string (`string.match(CurrentGameState.Value, "Day (%d+)")`), and that parse could race the server's cooldown ticks closely enough to make the Peasant menu fail to open on the day it should have. The fix was two-fold: (1) record the exact `CurrentDay` a Tribunal fired on instead of a countdown, and (2) have the server broadcast `CurrentDay` directly in `AliveStatusUpdate` so the client never derives it from a string at all (see §6.3). `TribunalCooldown` no longer exists anywhere in the codebase.

### 4.2 `PlayerData`

Keyed by `player.UserId`. Populated by `assignRoles()` in `GameLoop.server.luau` when `WaitingForPlayers` transitions to `DayGathering`:

```lua
PlayerData[userId] = {
    Role = "King" | "Prince" | "Double" | "Sorcerer" | "Knight" | "Revolutionary"
         | "Usurper" | "Bishop" | "Martyr" | "Spy" | "Peasant",
    IsAlive = true,
    ProtectedTargetUserId = nil,   -- Martyr only, see §11.2
    BishopCooldown = 0,            -- Bishop only, see §11.3
    ScannedPlayers = {},           -- Bishop only, see §11.3
    HasCrown = (role == "King"),   -- everyone; only the starting King begins true, see §13
}
```

`Cooldown` is **not** in this initial literal — it's the Usurper's fake-order penalty field, and stays implicitly `nil` for every player until `handleConfirmExecution()` first sets `usurperData.Cooldown = 3` after a fake order is caught (see §8.1). `tickCooldowns()` and `broadcastAliveStatus()` both treat a missing `Cooldown` as falsy/`0` via truthy checks and `or 0` fallbacks respectively, so this is safe.

Mutation summary:
- `IsAlive` → `false` on any successful kill (`handleConfirmExecution()`, `handleAssassination()`, or a Martyr's own death inside `redirectToMartyr()`).
- `ProtectedTargetUserId` → set exactly once by `handleMartyrOath()`, never cleared for the rest of the game.
- `BishopCooldown` → `2` on every successful `handleBishopReveal()`; decremented by the dedicated per-day loop in `GameLoop.server.luau`'s `DayGathering` branch (not `tickCooldowns()`).
- `ScannedPlayers` → grows via `table.insert()` in `handleBishopReveal()`, never shrinks.
- `HasCrown` → flipped by `handleRoyalSuccession()` (see §13); the dead holder's flips to `false`, the successor's flips to `true`.
- `Cooldown` → set to `3` by `handleConfirmExecution()` when a Usurper's fake order is confirmed; decremented by `tickCooldowns()` once per `NightPhase → DayGathering` transition.

Clients never read `PlayerData` directly — they learn their own role via `GetMyRole`/`RoleAssigned`, and everything else via the `AliveStatusUpdate` broadcast (§5.2).

### 4.3 `PendingActions`

A single-slot mailbox for whichever murder order is currently active:

```lua
PendingActions.ActiveMurder = {
    RequesterRole = "King" | "Usurper",  -- always this literal string, regardless of the requester's actual PlayerData.Role
    Target = "TargetPlayerName",
    RequesterId = 123456789,
}
```

Only one order can be active — a King's order (`handleOrderMurder()`, `SecretMeetings` only, gated on `requesterData.HasCrown == true`) always overwrites a Usurper's fake one (`handleFakeMurder()`, `DayGathering` only, gated on `Role == "Usurper"` **and** `HasCrown ~= true` — see §13.3), never the reverse; a King's order rejects and voids any pending fake order, while a Usurper's attempt while a King's order already stands is rejected outright. `RequesterRole` is always the literal string `"King"` or `"Usurper"` — it tags *which precedence rule applies*, not the requester's literal `PlayerData.Role`, so a crowned Double/Prince/Usurper issuing the real order still writes `RequesterRole = "King"`. The whole table is `table.clear()`-ed on `NightPhase → DayGathering`.

## 5. Networking

### 5.1 RemoteEvents / RemoteFunctions (`default.project.json`, under `ReplicatedStorage`)

| Name | Type | Direction | Payload / Purpose |
|---|---|---|---|
| `RoleAssigned` | RemoteEvent | Server → Client | `(role: string)` — fired once per player in `assignRoles()`. |
| `ActionRequest` | RemoteEvent | Client → Server | `(actionType: string, targetName: string?)`. `targetName` is required for every `actionType` except `"BishopReveal"`, which is fired with no second argument. Dispatches to: `"OrderMurder"`, `"OrderFakeMurder"`, `"MartyrOath"`, `"ConfirmExecution"`, `"Assassinate"`, `"Eavesdrop"`, `"BishopReveal"`, `"Accuse"`. |
| `ExecutionPrompt` | RemoteEvent | Server → Client | `(targetName: string)` — fired to eligible Sorcerer/Knight players in `notifyExecutioners()`. |
| `GetMyRole` | RemoteFunction | Client → Server | Invoked once at client start; returns the caller's `Role`, or `nil`. |
| `AliveStatusUpdate` | RemoteEvent | Server → Client | Full snapshot array — see §5.2. |
| `OrderVoided` | RemoteEvent | Server → Client | No args. Fired to an executioner whose order died with its requester, or a Usurper overridden by the King. |
| `FakeOrderRevealed` | RemoteEvent | Server → Client | No args. Fired to the executioner right after a kill turns out to have been the Usurper's fake order. |
| `RoomPartnerSync` | RemoteEvent | Server → Client | `(partnerName: string?)` — `""` for a solo player. Fired whenever `SecretMeetings` pairing runs. |
| `PartnerDitched` | RemoteEvent | Server → Client | No args. Fired to a Spy's or Martyr's original room partner the moment they're abandoned. |
| `StrikeIntercepted` | RemoteEvent | Server → Client | `(interceptorLabel: string, originalTargetName: string)`. **Dual-purpose** — see §5.3. |
| `RoleRevealed` | RemoteEvent | Server → Client | `(targetName: string, winCondition: string)` — fired to the Bishop only. |
| `GossipPing` | RemoteEvent | Server → Client | No args. Fired to a Peasant whose room partner is also a Peasant or a Double. |
| `TribunalResult` | RemoteEvent | Server → Client | `(message: string, isKing: boolean)` — broadcast to everyone. |
| `CrownInherited` | RemoteEvent | Server → Client | No args. Fired privately to a new crown-holder. |
| `GameOverReveal` | RemoteEvent | Server → Client | `(winningFaction: string, wasPacifist: boolean, finalRoles: {[playerName]: role})` — broadcast once, from `GameLoop.server.luau`'s `NightPhase` branch, at match end. See §14.5. |

Plus the non-Remote `CurrentGameState` `StringValue` (§3.2) — a passive, poll-free channel clients listen to via `GetPropertyChangedSignal("Value")`.

### 5.2 The `AliveStatusUpdate` snapshot

`broadcastAliveStatus()` exists as **two independent, byte-identical implementations** (`GameLoop.server.luau` and `ActionHandler.server.luau` — a known duplication, not a shared helper; both were verified field-for-field identical as of this rewrite, after an earlier drift where the Bishop fields were added to only one copy and briefly desynced the client's cached values). Both compute `alivePeasantCount` and `isSorcererAlive` once per call (a separate loop over all players before the snapshot loop), then fire:

```lua
{
    {
        UserId = 123, Name = "Player1",
        IsAlive = true,
        Cooldown = 0,                    -- Usurper penalty, 0 if unset
        ProtectedTarget = nil,           -- Martyr's ProtectedTargetUserId
        BishopCooldown = 0,
        ScannedPlayers = {},
        LastTribunalDay = 0,             -- GameState-level, same for every entry
        AlivePeasantCount = 3,           -- GameState-level, same for every entry
        CurrentDay = 2,                  -- GameState-level, same for every entry
        HasCrown = false,
        IsSorcererAlive = true,          -- GameState-level, same for every entry
    },
    ...
}
```

Every player's entry is included for shape-consistency, but each client only ever reads its own entry (matched by `UserId == localPlayer.UserId`) in `ActionController.client.luau`'s `AliveStatusUpdate.OnClientEvent` handler, caching the results into: `localProtectedTarget`, `localBishopCooldown`, `localScannedPlayers`, `localLastTribunalDay`, `localAlivePeasantCount`, `localCurrentDay` (falls back to its *previous* value rather than `1` if ever missing from a snapshot — so a malformed broadcast can't regress the client back to Day 1), `localHasCrown` (coerced with `== true`), and `localIsSorcererAlive` (coerced with `== true`). `aliveStatus`/`cooldownStatus` are separate parallel lookup tables built from *every* entry in the snapshot (not just the local player's), since those need to answer "is *any* given player alive" for menu population.

### 5.3 `StrikeIntercepted` is dual-purpose

Both call sites reuse the exact same remote and the exact same client-side banner template — *"YOUR STRIKE ON `<originalTargetName, upper>` WAS INTERCEPTED BY `<interceptorLabel, upper>`!"*:
- **Martyr redirect** (`redirectToMartyr()`): `StrikeIntercepted:FireClient(attackerPlayer, martyrPlayer.Name, originalTargetPlayer.Name)` — reads naturally: *"...INTERCEPTED BY `<MARTYR NAME>`!"*
- **Prince immunity** (`handleConfirmExecution()`): `StrikeIntercepted:FireClient(player, "THE PRINCE'S IMMUNITY", targetPlayer.Name)` — the "interceptor name" slot is filled with a literal phrase instead of a player name, producing: *"YOUR STRIKE ON `<PRINCE NAME>` WAS INTERCEPTED BY THE PRINCE'S IMMUNITY!"* — a deliberate reuse of the banner's placeholder structure rather than a second banner/remote.

## 6. Client UI Controller (`ActionController.client.luau`)

### 6.1 The `activeMenu` pattern

- **`activeMenu`** (`local activeMenu = "None"`) is the *only* piece of state that determines what's on screen. Valid values: `"None"`, `"KingMurder"`, `"Executioner"`, `"Assassination"`, `"Usurper"`, `"Spy"`, `"Martyr"`, `"Bishop"`, `"Peasant"`.
- **`renderUI()`** is the *only* function allowed to touch `.Visible`:
  ```lua
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
  ```
  The `hasCastPeasantVote` reset at the top is a deliberate piggyback (see §12.5) — every time the Peasant menu becomes visible, a fresh voting window has begun, so resetting the "did I vote this window" flag lives in the same place the menu itself turns on.
- Every other piece of logic — `updateVisibility()`, the `ExecutionPrompt` handler, and every button click handler — only ever *decides* a new `activeMenu` value and then calls `renderUI()`. Nothing else touches `.Visible`.

### 6.2 Client-local state mirrored from the server

Beyond `aliveStatus`/`cooldownStatus`: `currentRoomPartner` (from `RoomPartnerSync`, coerced `""`/`nil` → Lua `nil`), and everything listed in §5.2 (`localProtectedTarget`, `localBishopCooldown`, `localScannedPlayers`, `localLastTribunalDay`, `localAlivePeasantCount`, `localCurrentDay`, `localHasCrown`, `localIsSorcererAlive`), plus the purely-local `hasCastPeasantVote`.

### 6.3 `updateVisibility()` — the full branch chain

Bound to `CurrentGameState:GetPropertyChangedSignal("Value")`, and called once at script init. Lowercases the state string, then evaluates in order:

```lua
if string.find(stateLower, "secret") and localHasCrown == true then
    activeMenu = "KingMurder"; populatePlayerList()
elseif string.find(stateLower, "secret") and localPlayerRole == "Spy" then
    activeMenu = "Spy"; populateSpyList()
elseif string.find(stateLower, "secret") and localPlayerRole == "Martyr" and localProtectedTarget == nil then
    activeMenu = "Martyr"; populateMartyrList()
elseif string.find(stateLower, "secret") and localPlayerRole == "Bishop"
    and localBishopCooldown == 0 and currentRoomPartner ~= nil and not bishopPartnerAlreadyScanned then
    activeMenu = "Bishop"
elseif string.find(stateLower, "evening") and localPlayerRole == "Peasant"
    and localCurrentDay > 1 and localCurrentDay > (localLastTribunalDay + 1) and localAlivePeasantCount >= 3 then
    activeMenu = "Peasant"; populatePeasantList()
elseif string.find(stateLower, "night") and localPlayerRole == "Revolutionary" then
    activeMenu = "Assassination"; populateAssassinationList()
elseif string.find(stateLower, "night") and activeMenu == "Executioner"
    and (localPlayerRole == "Sorcerer" or (localPlayerRole == "Knight" and localIsSorcererAlive == false)) then
    -- Do nothing, preserve the menu
elseif string.find(stateLower, "day gathering") and localPlayerRole == "Usurper"
    and localCooldown == 0 and not localHasCrown then
    activeMenu = "Usurper"; populateUsurperList()
else
    activeMenu = "None"
end

renderUI()
```

Key details:
- **The King branch checks `localHasCrown == true`, not `localPlayerRole == "King"`.** This is what makes the King's Murder menu "follow the crown" through succession without any role-specific code — see §13.4.
- **The Martyr branch** permanently stops matching once `localProtectedTarget` becomes non-`nil` (oath sworn) — no later branch matches a Martyr either, so the menu falls through to `"None"` and never reopens.
- **The Bishop branch** precomputes `bishopPartnerAlreadyScanned` just above the chain (resolves `currentRoomPartner`'s `Player` via `Players:FindFirstChild`, checks `table.find(localScannedPlayers, partnerPlayer.UserId)`) — mirrors the server's validation client-side so the menu only appears when a reveal would actually succeed.
- **The Executioner "preserve" branch does not *open* the menu** — that only happens via `ExecutionPrompt.OnClientEvent` (server-triggered). This branch only decides whether an *already-open* Executioner menu survives the `NightPhase` state-change tick; the role/`localIsSorcererAlive` condition mirrors the server's Knight Lockout (§8.2) so a Knight menu opened while a Sorcerer was still alive won't be artificially kept open either.
- **The Usurper branch requires `not localHasCrown`** in addition to its original `Cooldown == 0` gate — once a Usurper inherits the crown, this branch stops matching (see §13.3), and the King branch above takes over on the next `SecretMeetings`.
- A `local currentDay` used to be parsed here via `string.match(CurrentGameState.Value, "Day (%d+)")` — that line and every reference to it were removed entirely; `localCurrentDay` (server-synced, see §5.2) is used instead.

### 6.4 `showTemporaryBanner` and its colors

```lua
local function showTemporaryBanner(name: string, text: string, duration: number, color: Color3?)
```

`color` defaults to `BANNER_TEXT_COLOR` (red) when omitted. Palette in use:

| Constant | RGB | Used by |
|---|---|---|
| `BANNER_TEXT_COLOR` | `255, 0, 0` (red) | `OrderVoided`, `FakeOrderRevealed`, `PartnerDitched`, `StrikeIntercepted`, `TribunalResult` (non-King verdict) |
| `BANNER_SUCCESS_COLOR` | `0, 200, 0` (green) | `RoleRevealed`, `TribunalResult` (King exposed) |
| `BANNER_INFO_COLOR` | `130, 150, 190` (blue-gray) | `GossipPing` |
| `BANNER_GRAY_COLOR` | `160, 160, 160` (gray) | Tribunal void banner (§12.5) |
| `BANNER_GOLD_COLOR` | `212, 175, 55` (gold) | `CrownInherited` |

Each banner is name-keyed (`actionUI:FindFirstChild(name)`) so re-firing the same banner destroys and replaces the previous instance instead of stacking.

### 6.5 The Game Over reveal

`GameOverReveal.OnClientEvent` (§5.1, §14.5) is the one piece of UI that doesn't go through `activeMenu`/`renderUI()`'s state machine at all — it force-sets `activeMenu = "None"` and calls `renderUI()` once, purely to close out whatever role menu happened to be open, then builds a standalone `Frame` (named `GameOverReveal`, parented directly to `actionUI`, destroyed and rebuilt if one somehow already exists) rather than toggling visibility on a pre-built menu the way every other role UI does — there's no `GameOverRevealUI` object living in `ActionUI` at design time, since it's the only menu that never repeats within a session.

- **Title**: `"<FACTION> WINS!"`, or `"DRAW -- OUT OF TIME"` when `winningFaction == "None"` (the day-6 draw sentinel from §14.4), with `" (PACIFIST)"` appended when `wasPacifist` is true. Rendered in `BANNER_GOLD_COLOR` (§6.4's palette), reused here rather than adding a sixth banner color.
- **Roster**: `finalRoles` (`{[playerName]: role}`) is sorted alphabetically by name (`formatFinalRoles()`) and rendered as one `TextLabel` per player inside a `ScrollingFrame` with `AutomaticCanvasSize = Enum.AutomaticSize.Y`, so it scrolls cleanly regardless of lobby size (4 players or the full 15) instead of a fixed-height list needing per-size tuning.
- **Console mirror**: every line is also `print()`-ed server-readably (`"<Name> was the <Role>"`), a leftover from this being verified via Studio's output window before the GUI half was confirmed working end-to-end — kept as a redundant sanity-check channel, not load-bearing for gameplay.
- **Self-cleanup**: `task.delay(15, function() container:Destroy() end)` — matches the server's own `task.wait(15)` (§14.6) before it fires `TeleportAsync`, so the reveal disappears right around when the teleport actually happens, not before.

## 7. Ghost & Respawn System

Dead players stay in-game as visible-to-themselves, invisible-to-the-living "ghosts," split across a server physics layer and a client visuals layer that don't depend on each other.

**Server (`GameLoop.server.luau`) — collision:**
- At script start: two `PhysicsService` collision groups, `"Alive"` and `"Ghosts"` (registration wrapped in `pcall`, since re-registering an existing group errors on script re-run), made mutually non-collidable.
- `applyGhostState(character)` (from `catchRespawn()` when `PlayerData[userId].IsAlive == false` on `CharacterAdded`): sets every `BasePart`'s `CollisionGroup = "Ghosts"` **and** `CanCollide = false` (belt-and-suspenders — Roblox's rig-building code can reset `CanCollide` on limbs after `CharacterAdded`, but not `CollisionGroup`); disables every `BillboardGui`; sets `Humanoid.DisplayDistanceType = None`.
- `applyAliveState(character)`: the else-branch, sets `CollisionGroup = "Alive"` for a (re)spawning-alive player.
- `catchRespawn()` is hooked on every player's `CharacterAdded` (both at script start and via `Players.PlayerAdded`), so it fires on every respawn, not just the first.

**Client (`ActionController.client.luau`) — visuals:**
- `updateGhostVisibility()` sets `Transparency` on every dead player's `BasePart`/`Decal` descendants: fully invisible (`1`) if the local player is alive, translucent (`0.5`) if the local player is also dead — ghosts see each other and themselves; the living see nothing.
- The local player's *own* dead character additionally gets `LocalTransparencyModifier` set (not just `Transparency`) — Roblox's default camera/occlusion scripts silently override plain `Transparency` on the local avatar, but respect `LocalTransparencyModifier`.
- Both blocks guard with `if character and character.Parent then` to skip mid-destruction characters.
- Fires reactively on every `AliveStatusUpdate`, plus a **1-second polling loop** (`task.spawn(function() while task.wait(1) do updateGhostVisibility() end end)`) — polling exists because earlier event-driven approaches raced Roblox's asset streaming and produced an intermittent "opaque ghost" bug.

## 8. The Crown & Executioners

### 8.1 King / Usurper murder orders

- **King's real order** (`handleOrderMurder()`, `SecretMeetings` only): gated on `requesterData.HasCrown == true` — **not** `Role == "King"` (see §13.3). If a Usurper's fake order is currently active, `OrderVoided` fires to that Usurper before the King's order overwrites it.
- **Usurper's fake order** (`handleFakeMurder()`, `DayGathering` only): gated on `Role == "Usurper"`, alive, **and** `HasCrown ~= true` (a crowned Usurper is blocked server-side, not just client-side — see §13.3). If a King's order is already active, the attempt is rejected and `OrderVoided` fires immediately back to the Usurper.
- **The executioner never knows which is which up front** — `ExecutionPrompt` only carries a target name. The distinction surfaces only in `handleConfirmExecution()`, *after* a kill lands: if `activeMurder.RequesterRole == "Usurper"`, `FakeOrderRevealed` fires to the executioner and `PlayerData[RequesterId].Cooldown = 3` — three `tickCooldowns()` ticks (three `NightPhase → DayGathering` transitions) before the Usurper's menu (gated on `Cooldown == 0`) reopens.

### 8.2 Sorcerer execution, Knight Lockout, Prince immunity

`handleConfirmExecution()` (`NightPhase` only, caller must be `Sorcerer` or `Knight`) validates, in order:
1. Caller role is `Sorcerer` or `Knight`.
2. **Knight Lockout**: if the caller is a `Knight`, scan all connected players for a living `Sorcerer`; if one exists, return immediately — the Knight is a **backup executioner only**, unable to act while the Sorcerer lives.
3. Caller `IsAlive`.
4. `PendingActions.ActiveMurder` exists and matches `targetName`.
5. Target resolves to a connected `Player` with a `Humanoid`.
6. **Martyr redirect check** (`findLivingMartyrProtecting()`/`redirectToMartyr()` — see §11.2) — takes priority over the Prince check below; if a Martyr intercepts, the function returns here. As of Phase D, `redirectToMartyr()` also checks whether the *original* target was the King (`PlayerData[originalTargetPlayer.UserId].Role == "King"`) and, if so, flags `GameState.MatchStats[martyrPlayer.UserId].InterceptedKingHit = true` — see §14.3.
7. **Prince immunity**: `if requesterData.Role == "Sorcerer" and targetData.Role == "Prince"` — fires `StrikeIntercepted` (§5.3) and returns, **without** killing the Prince. This check is Sorcerer-specific: a Knight's strike is *not* blocked by it, so once the Knight becomes the active executioner (Sorcerer dead), they genuinely can kill a Prince a Sorcerer's magic couldn't touch. (An earlier version blocked *any* executor from killing a Prince — that blanket check was removed specifically to make the Knight Lockout/backup-executioner design mechanically meaningful.)
8. Otherwise: `humanoid.Health = 0`, `targetData.IsAlive = false`, then `GameState.MatchStats[player.UserId].Kills` is incremented (creating the entry if it doesn't exist yet — see §14.3), then `handleRoyalSuccession(targetPlayer.UserId)` (§13.1), then the Usurper-reveal bookkeeping (`FakeOrderRevealed`/`Cooldown = 3` if applicable), clear `ActiveMurder`, `broadcastAliveStatus()`.

The Revolutionary's `handleAssassination()` (`NightPhase`, instant, no `ExecutionPrompt` round-trip) follows the same Martyr-redirect-first, then-kill, then-`handleRoyalSuccession()` shape, but has **no** Prince-immunity check at all — a Revolutionary can kill a Prince outright. It also carries its own **Rule of Chronology**: if the just-killed player was the `RequesterId` of the night's `PendingActions.ActiveMurder`, that order dies with them (cleared, and `OrderVoided` fired to every Sorcerer/Knight) so an open `ExecutionPrompt` doesn't get actioned on a dead man's orders.

## 9. Chat Filtering (`ChatFilter.server.luau`)

All players share one `RBXGeneral` text channel — no separate `"Graveyard"` channel, no per-room channel, no channel-switching. Every rule (ghosts, room privacy, Spy eavesdropping, Martyr's third-wheel room) is enforced per-recipient by a single `ShouldDeliverCallback`, evaluated in this order:

1. **Ghost filter** (all phases): dead sender → living recipient is always blocked, everywhere, regardless of room state.
2. **Room privacy + Spy + Martyr** (`SecretMeetings` only — outside this phase, only the ghost filter applies):
   - **Spy silence**: if the sender is the actively-eavesdropping Spy (`GameState.SpyTarget ~= nil`), their message is blocked for *everyone*, unconditionally — eavesdropping is read-only.
   - **Spy's inbox**: if the recipient is the actively-eavesdropping Spy, delivery is allowed only from the eavesdropped-on player (`senderId == spyTarget`) or that player's original partner (`senderId == GameState.SecretPairs[spyTarget]`) — exactly the two people in the infiltrated room, no one else.
   - **Martyr's outbox**: if the sender is an oathbound Martyr (`ProtectedTargetUserId ~= nil`), delivery is allowed only to their protected target or that target's `SecretPairs` partner — an explicit `return false` for everyone else, so this can never fall through to the general pairing check below (a fix for a prior leak where it could).
   - **Martyr's inbox**: mirror of the above — if the recipient is an oathbound Martyr, delivery is allowed from their protected target or that target's partner. (Note: unlike the Martyr's outbox, this branch has no trailing `else return false` — a non-matching sender falls through to the general pairing check below instead of being explicitly denied here.)
   - **General pairing**: two living players can hear each other only if `GameState.SecretPairs[senderId] == targetId` (current room partners).
   - Anything not matched by the above: `return false`.
3. Outside `SecretMeetings`: always `return true` (subject to the ghost filter above).

`GameState.SpyTarget` is reset and `SecretPairs` cleared on the `SecretMeetings → EveningGathering` transition, so branch 2 only ever evaluates meaningfully while `SecretMeetings` is actually active.

**Client**: the local player's alive→dead transition triggers a local-only system message in `RBXGeneral`: *"Welcome to the Graveyard chat. The living cannot hear you."* No equivalent message exists for the Spy or Martyr — both mechanics are silent by design.

## 10. Phase A — The Room Crashers

### 10.1 The Spy

Trades their own `SecretMeetings` pairing for the ability to physically relocate into someone else's room, invisible, and read that room's chat.

- **Room partner tracking**: `runSecretMeetings()` → `pairPlayersInRoom()` writes both directions of `GameState.SecretPairs` and fires `RoomPartnerSync` to each of the pair (solo player gets `""`). Client stores as `currentRoomPartner`.
- **`handleEavesdrop()`** (`SecretMeetings`, alive Spy, valid target with resolvable `HumanoidRootPart`s on both sides):
  1. Notifies the Spy's *current* partner via `PartnerDitched` (doesn't touch `SecretPairs` — it's a notification, not a re-pairing).
  2. Teleports: `spyCharacter:PivotTo(targetRoot.CFrame * CFrame.new(0, 5, 0))`.
  3. `applySpyInvisibility()`: every `BasePart` → `Transparency = 1`, `CollisionGroup = "Spies"` (a third collision group, non-collidable with `"Alive"`, registered alongside `"Alive"`/`"Ghosts"`); every `Decal` → `Transparency = 1`; every `BillboardGui` → disabled.
  4. `hookSpyDescendantListener()`: a `DescendantAdded` connection (stored per-player in `GameState.SpyConnections`, replacing any prior one) applies the same treatment to late-streamed accessories/limbs.
  5. `GameState.SpyTarget = targetPlayer.UserId` — the flag `ChatFilter.server.luau` reads (§9).
- **Cleanup**: on `SecretMeetings → EveningGathering`, every living Spy has invisibility/collision restored (`HumanoidRootPart` stays `Transparency = 1`, matching default character behavior) and their `SpyConnections` entry disconnected.
- **Client list** (`populateSpyList()`): the standard all-alive-except-self shape, plus one extra filter excluding `currentRoomPartner`.

### 10.2 The Martyr

A one-time, irrevocable oath to protect their *current* room partner at the time of swearing (target selection is now unrestricted — see below) — but the physical/data effects still key off whoever they *targeted*, regardless of pairing.

- **`handleMartyrOath()`** (`SecretMeetings`, alive Martyr, `ProtectedTargetUserId == nil`, `type(targetName) == "string"`): resolves the target (any alive player — **not** restricted to the current partner, an earlier restriction that was lifted), notifies the old partner via `PartnerDitched`, severs both directions of the old `SecretPairs` entry (`GameState.SecretPairs[player.UserId] = nil` and the partner's mirror — a fix for a chat-leak where the abandoned partner's stale pairing kept letting their messages reach the Martyr), teleports the Martyr to the target's room (`PivotTo`, same 5-stud-above trick as the Spy — **no** invisibility applied, the Martyr stays fully visible), then sets `ProtectedTargetUserId = targetPlayer.UserId` permanently.
- **Third Wheel forced matchmaking** (`runSecretMeetings()`, every day after the standard pairing pass): for any alive Martyr with a non-`nil` `ProtectedTargetUserId`, resolves the protected player; if alive, severs the Martyr's current `SecretPairs` entry (same leak-prevention as above) and teleports the Martyr (`PivotTo`) into wherever the protected target ended up that day's standard pairing — **not** a forced pairing anymore (an earlier version pulled both out of the pool early and force-paired them into `Room1`; that was replaced so the target gets a normal partner and the Martyr shows up as an uninvited third person).
- **The Night Sacrifice**: `findLivingMartyrProtecting(targetUserId)` is checked by both `handleConfirmExecution()` and `handleAssassination()` immediately before applying lethal damage. If found, `redirectToMartyr()` kills the **Martyr** instead (`Humanoid.Health = 0`, `IsAlive = false`), fires `StrikeIntercepted` to the attacker only (§5.3), and both call sites otherwise run their normal post-kill bookkeeping as if the *original* target had died (Usurper-reveal logic still fires based on who *ordered* the kill, not who died). A dead Martyr can never intercept again (`findLivingMartyrProtecting()` filters `IsAlive == true`).
- **Chat**: see §9 — the Martyr's room is a "third wheel" chat scenario, symmetric to (but independent of) the Spy's.
- **Client list** (`populateMartyrList()`): the standard all-alive-except-self shape (matches the Spy's, minus the partner exclusion) — mirrors the unrestricted-target design above.

### 10.3 The Bishop

A stealthy, cooldown-gated ability revealing which win condition their *current room partner* is fighting for, without ever notifying the target.

- **Data**: `BishopCooldown`/`ScannedPlayers` initialized in `assignRoles()`; `BishopCooldown` decremented by a dedicated per-day loop in `GameLoop.server.luau`'s `DayGathering` branch (not `tickCooldowns()`).
- **`handleBishopReveal(player)`** — fired with **no** `targetName` (`ActionRequest:FireServer("BishopReveal")`, requiring the dispatcher's top-level guard to accept a `nil` targetName — see §5.1): `SecretMeetings`, alive Bishop, `BishopCooldown == 0`. Target is resolved implicitly: `targetId = GameState.SecretPairs[player.UserId]` — a solo Bishop (`targetId == nil`) cannot scan. Rejects if already in `ScannedPlayers` (permanent, one scan per target ever). On success: `BishopCooldown = 2`, records the scan, fires `RoleRevealed:FireClient(player, targetPlayer.Name, WIN_CONDITIONS[targetData.Role])` to the Bishop only — no broadcast, no trace visible to anyone else.
- **Client**: `BishopMenu` has only a `RevealButton`, no target list (the target is implicit) — see §6.3 for the visibility gate.

## 11. Phase B — The Uprising (The Peasant)

### 11.1 Gossip

A passive, involuntary tell fired inside `runSecretMeetings()` right after `pairPlayersInRoom()`:

```lua
if dataA.Role == "Peasant" and (dataB.Role == "Peasant" or dataB.Role == "Double") then
    GossipPing:FireClient(playerA)
end
-- (mirrored for playerB)
```

Both checks run independently — a Peasant+Peasant pair pings *both*; a Peasant+Double pair pings only the Peasant. No validation, no cooldown, nothing recorded — the only trace is the client's 5-second `BANNER_INFO_COLOR` banner: *"WHISPERS IN THE DARK: YOUR PARTNER MIGHT BE A PEASANT..."* — deliberately vague, doesn't distinguish the two trigger cases.

### 11.2 The Tribunal — accusation & majority

`handlePeasantAccuse()` (`ActionRequest("Accuse", targetName)`), validates in order:
1. `type(targetName) == "string"` (dispatcher-wide guard is loosened to allow `nil` for `BishopReveal`, so every target-taking handler added its own explicit check — this one, plus `handleEavesdrop()` and `handleMartyrOath()`).
2. `GameState.CurrentState == "EveningGathering"`.
3. `GameState.CurrentDay > 1` — Day 1 has no prior day to have voted about.
4. Caller is an alive `Peasant`.
5. **Absolute-day cooldown**: `GameState.CurrentDay <= GameState.LastTribunalDay + 1` → blocked (see §4.1's `LastTribunalDay` note for why this is a day-comparison, not a countdown).
6. At least 3 living Peasants (`alivePeasants >= 3`) — below that, the mechanic is disabled entirely.

Then: resolves the target, records `GameState.PeasantVotes[player.UserId] = targetPlayer.UserId` (overwrites any earlier vote from the same Peasant this window — it's a plain map, not an append-only list), computes `requiredVotes = math.floor(alivePeasants / 2) + 1`, tallies current votes for that target, and calls `Tribunal.Execute(targetPlayer)` (§12) if the threshold is met.

### 11.3 The Tribunal — timeout tie-break

Covered in full in §3.2's `EveningGathering` row. Summary: if the 20-second timer expires with `GameState.PeasantVotes` still non-empty (no early majority fired — an early majority already clears the table, so this naturally skips when one occurred), the server tallies every cast vote, finds the max vote count, collects every target tied at that count, picks one at random (`tiedTargets[math.random(1, #tiedTargets)]`), and calls `Tribunal.Execute()` on them exactly as an early majority would. A `tribunalFiredLate` flag gates an extra 6-second pause *before* the `PrivateQuarters` teleport (not after — the pause has to happen while players are still in the Grand Hall, or they'd already be in their Night Phase rooms by the time they could read the verdict). An early majority never gets this extra pause; it already has the rest of the 20-second window.

### 11.4 `Tribunal.luau` — the shared execution module

```lua
function Tribunal.Execute(targetPlayer: Player)
    GameState.LastTribunalDay = GameState.CurrentDay

    local targetData = PlayerData[targetPlayer.UserId]
    local targetIsKing = targetData ~= nil and targetData.Role == "King"

    if targetIsKing then
        for voterUserId, votedUserId in GameState.PeasantVotes do
            if votedUserId == targetPlayer.UserId then
                local voterStats = GameState.MatchStats[voterUserId]
                if not voterStats then
                    voterStats = {}
                    GameState.MatchStats[voterUserId] = voterStats
                end
                voterStats.VotedKingCorrectly = true
            end
        end
    end

    table.clear(GameState.PeasantVotes)

    if targetIsKing then
        TribunalResult:FireAllClients("THE MOB HAS EXPOSED " .. targetPlayer.Name:upper() .. " AS THE KING!", true)
    else
        TribunalResult:FireAllClients("THE MOB ACCUSED " .. targetPlayer.Name:upper() .. ", BUT THEY ARE NOT THE KING!", false)
    end
end
```

**Important**: `targetIsKing` checks `targetData.Role == "King"` literally — **not** `HasCrown`. A Tribunal verdict on a crowned Double/Prince/Usurper (post-succession) will read as *"NOT THE KING"*, even though they now hold the real authority, because the Tribunal is testing the original starting-King identity, not the current crown-holder. This is a real behavioral quirk worth flagging, not something the current implementation reconciles.

**As of Phase D**, the function was restructured — `table.clear(GameState.PeasantVotes)` moved from the top to *after* a new vote-scanning pass, because the Peasant Economy bonus (§14.2/§14.3) needs to know who voted correctly, and `GameState.PeasantVotes` is the only record of that; clearing it first (the original order) would have destroyed the evidence before it could be read. When `targetIsKing`, every entry in `GameState.PeasantVotes` that voted for `targetPlayer.UserId` gets `GameState.MatchStats[voterUserId].VotedKingCorrectly = true` (creating the `MatchStats` entry if missing) before the pool is cleared. Computing `targetIsKing` into a local up front (rather than re-checking `targetData.Role == "King"` twice) matters beyond style here — both the vote scan and the banner now need to agree on the exact same reading of `targetData`, taken at the exact same point in time.

Exists as a shared module (not a `BindableEvent`) specifically so `handlePeasantAccuse()` (early majority) and `GameLoop.server.luau`'s timeout branch (tie-break) call the exact same logic without duplicating it — both already depend on `GameState.luau`, so a plain `require()` needed no new `default.project.json` entries. This now also means both call paths get the `VotedKingCorrectly` bookkeeping for free, including the timeout tie-break — a Peasant who voted for the King but didn't reach the 20-second early majority still gets credit if the timeout tie-break happens to land on the King.

### 11.5 Client UI

- `populatePeasantList()` (standard all-alive-except-self shape) / `AccuseButton` fires `ActionRequest("Accuse", targetName)`.
- Visibility gate: see §6.3.
- `hasCastPeasantVote`: reset to `false` inside `renderUI()` whenever `activeMenu == "Peasant"` (fresh window); set `true` by the `AccuseButton` handler right after firing, *before* `activeMenu` is set back to `"None"` — so the reset-on-open branch doesn't immediately erase the flag it was just asked to set.
- `TribunalResult.OnClientEvent(message, isKing)`: forces `activeMenu = "None"` + `renderUI()` first (closes the menu for every Peasant, voted or not); then `if localPlayerRole == "Peasant" and isPlayerAlive(localPlayer) and not hasCastPeasantVote` shows the 3-second gray void banner *"THE MOB REACHED A MAJORITY WITHOUT YOU."* (role- and alive-gated, so the King/Bishop/other roles and dead Peasant ghosts don't see it); then the 6-second green/red verdict banner.

## 12. Phase C — The Passive Inheritors

### 12.1 `handleRoyalSuccession(deadUserId)`

```lua
if not deadData or deadData.HasCrown ~= true then return end

-- Double, then Prince, then Usurper -- first living match wins
```

Three sequential scans over `Players:GetPlayers()`, each `break`-ing on the first living match: **Double** first, then **Prince**, then **Usurper** as the final fallback (added specifically for the case where King, Double, and Prince are all dead — the Usurper inherits the *real* crown). If none are found alive, the function returns and the crown is simply gone (no further fallback). On success: successor's `HasCrown = true`, dead player's `HasCrown = false`, `CrownInherited:FireClient(successorPlayer)` — private, no broadcast, nothing logged client-visibly. Called from both `handleConfirmExecution()` and `handleAssassination()`, immediately after the target's `IsAlive` flips to `false` — **not** from the Martyr's own death inside `redirectToMartyr()` (a Martyr can never hold `HasCrown` in the first place, since it only ever starts on the King and transfers to Double/Prince/Usurper).

### 12.2 Prince's Sorcerer-immunity & Knight Lockout

Covered in full in §8.2.

### 12.3 The `HasCrown` UI hand-off

Because `updateVisibility()`'s King branch checks `localHasCrown` (§6.3) rather than a role string, and both `handleOrderMurder()`/`handleFakeMurder()` check `HasCrown` server-side (§8.1), the entire "who can act as King" question is decided by one boolean, checked identically everywhere — no role-name special-casing needed anywhere in the authorization path. This is also what suppresses the Usurper's own menu the moment they inherit (§6.3's Usurper branch: `and not localHasCrown`), and what closes off their fake-order ability server-side too (`handleFakeMurder()`'s `if requesterData.HasCrown == true then return end`) — a crowned Usurper loses fake orders entirely, not just the UI for them.

### 12.4 The `CrownInherited` banner — a known timing gap

`CrownInherited.OnClientEvent` shows the 6-second gold banner *"THE KING IS DEAD. LONG LIVE THE KING. YOU NOW HOLD THE CROWN."* and calls `renderUI()`. Because succession only ever fires from a kill — which only ever happens during `NightPhase` — and the King's Murder menu is only ever offered during `SecretMeetings`, this `renderUI()` call **cannot** make the menu "instantly" appear at the moment of inheritance; it repaints whatever `activeMenu` already is (still `"None"`). The new crown-holder correctly gets the King menu on the *next* `SecretMeetings` phase's own `updateVisibility()` call, once `localHasCrown` has synced via the following `AliveStatusUpdate` — this is guaranteed by §6.3's King branch, independent of this `renderUI()` call. This was a deliberate implementation decision (confirmed against the alternative of trying to force the menu open outside its normal phase gate, which would have broken the established phase-gating pattern every other menu relies on) rather than an oversight.

## 13. Known Quirks & Implementation Notes

A consolidated list of real, verified-against-code behaviors worth knowing before touching this system further:

1. **Double player-count gate** (§3.2): `WaitingForPlayers`'s outer wait (`>= 3`) is superseded by a stricter inner gate (`< 4`) in the action block. Keep both in sync if the lobby size changes again.
2. **`notifyExecutioners()` doesn't check the recipient's `IsAlive`** — a dead Sorcerer/Knight still receives `ExecutionPrompt`; `handleConfirmExecution()`'s own alive check is what makes their confirm a no-op.
3. **`PlayerData.Cooldown` (Usurper) is never initialized** in `assignRoles()`'s table literal — it's implicitly `nil` until `handleConfirmExecution()` first sets it to `3`. Both `tickCooldowns()` and `broadcastAliveStatus()` handle this gracefully (truthy check / `or 0`).
4. **`StrikeIntercepted` is dual-purpose** (§5.3) — Martyr redirect and Prince immunity share the remote and banner template via placeholder substitution.
5. **`Tribunal.luau` checks `Role == "King"`, not `HasCrown`** (§11.4) — a Tribunal verdict on a post-succession crown-holder will incorrectly read "not the King."
6. **The two `broadcastAliveStatus()` copies have drifted before** (§5.2) — nothing structurally enforces they stay identical; verify both when adding a new snapshot field.
7. **`TEST_RIG_ROLES`** (top of `GameLoop.server.luau`) is a mutable testing knob, currently `{ "King", "Revolutionary", "Prince", "Usurper" }` — expected to keep changing between test sessions; the *real* role distribution is whatever's left in `ROLES` after the test-rig slots, shuffled.
8. **The Martyr's oath target is no longer restricted to the current room partner** — an earlier version enforced `GameState.SecretPairs[player.UserId] == targetPlayer.UserId` server-side; that check was removed, and the Martyr now teleports to *whichever* alive player they target, severing their old pairing in the process (§11.2).
9. **`GameState.MatchStats` is never cleared** (§14.3) — harmless today, since `GameLoop.server.luau`'s main loop `break`s permanently once `NightPhase` resolves a win/draw (§3.2), so there's no second match in the same server session to leak stats into. If the loop is ever changed to support rematches without a full server restart, `MatchStats` (and `PendingActions`, `SecretPairs`, etc.) would need an explicit `table.clear()` on match start.
10. **`EconomyManager.luau`'s `ROLE_FACTIONS` is a second, independent copy of `ActionHandler.server.luau`'s `WIN_CONDITIONS` table** (§2, §14.2) — same drift risk already flagged for the two `broadcastAliveStatus()` copies (quirk 6): nothing structurally keeps them in sync if a role's faction ever changes.
11. **`EconomyManager`'s "Double Bonus" (`INTERCEPTED_KING_HIT_BONUS`) is not gated to `Role == "Double"`** — it pays out to whoever's `matchStats.InterceptedKingHit` flag is set, which as wired is always the intercepting **Martyr** (`redirectToMartyr()` sets it on the Martyr's own `UserId`, never on a player with the `Double` role). This was an explicit, discussed design choice during Phase D, not an oversight — the original spec's "interceptor" language was read as "whoever physically intercepted," not the `Double` role specifically.
12. **`MatchPlayerStats.LandedKill` (§14.3) is currently unreachable** — `ActionHandler.server.luau`'s only kill-tracking write is to `.Kills` (incremented per kill), never `.LandedKill`. The `LandedKill` fallback in `EconomyManager:DistributeMatchRewards()` exists only for a caller that hand-builds a `matchStats` table without a kill *count* (e.g. a future path that only knows "did they land at least one kill," not how many) — no such caller exists yet.
13. **`GameLoop.server.luau`'s `TeleportService:TeleportAsync()` call (§14.6) is not wrapped in `pcall`** — if it throws (expected in Studio Play Solo, since the place isn't published; also possible in production during a live API outage), the error propagates uncaught and kills the script's main coroutine at that line instead of reaching the following `break`. The end state (loop stops) is practically the same, but via an unhandled error rather than a clean exit, and with no retry — worth a `pcall` before this goes live.

## 14. Endgame — Win Conditions & Economy (Phase D)

The match now ends itself, pays players, shows everyone the final roster, and sends them home — closing the loop that Phases A–C's role abilities all ultimately feed into. Four new/changed files: `DataManager.luau`, `EconomyManager.luau`, and `ProfileService.lua` (all new, `src/server`), plus additions to `GameState.luau`, `ActionHandler.server.luau`, `Tribunal.luau` (§11.4), `GameLoop.server.luau`, and `ActionController.client.luau` (§6.5).

### 14.1 `DataManager.luau` — persistent player data

A thin `ModuleScript` wrapper around Mad Studio's `ProfileService.lua`, intended to be required identically from both a Hub place and a Match place (session-locking a player's profile to whichever server currently holds it — see the `TeleportAsync` caveat at the end of §14.6).

```lua
local ProfileTemplate: ProfileData = {
    RoyalCoins = 0,
    TotalGamesCompleted = 0,
    PlayerLevel = 1,
}

local ProfileStore = ProfileService.GetProfileStore("PlayerData", ProfileTemplate)
local Profiles = {}   -- keyed by Player instance, NOT UserId -- see the note below
DataManager.Profiles = Profiles

function DataManager:GetProfile(player: Player)
    return Profiles[player]
end

function DataManager:UpdateLevel(player: Player)
    local profile = Profiles[player]
    if not profile then return end
    local newLevel = math.floor(profile.Data.TotalGamesCompleted / 5) + 1
    profile.Data.PlayerLevel = newLevel
    return newLevel
end
```

- **`Profiles` is keyed by the `Player` Instance itself, not `UserId`** — every other lookup table in this codebase (`PlayerData`, `GameState.MatchStats`, `aliveStatus`, `cooldownStatus`, ...) is keyed by `UserId`. This is a deliberate inconsistency worth remembering if you ever add a third data table: `DataManager:GetProfile(player)` takes the `Player` object, everything else takes `player.UserId`.
- **`PlayerAdded(player)`** calls `ProfileStore:LoadProfileAsync(tostring(player.UserId))` with no `not_released_handler` argument, which defaults to `"ForceLoad"` (per `ProfileService`'s own docs, vendored at the top of `ProfileService.lua`) — a profile still session-locked by another server (e.g. mid-`TeleportAsync` hop between the Hub and a Match place) will be force-loaded rather than rejected, at the cost of the old server's session eventually getting kicked via `ListenToRelease`.
- **`DataManager:UpdateLevel(player)`** is the exact flat formula from the original spec (`math.floor(TotalGamesCompleted / 5) + 1`) and is called twice in the current codebase: once right after a profile loads (`PlayerAdded`, so a returning player's level is correct immediately, not just after their next match), and once per player inside `EconomyManager:DistributeMatchRewards()` (§14.2) after `TotalGamesCompleted` is incremented.
- **Currently the only consumer is `EconomyManager.luau`** — nothing else (e.g. a Hub-side coin/level display) calls `DataManager:GetProfile()` yet, even though the module was written to support that from either place.

### 14.2 `EconomyManager.luau` — match-end payout calculator

`EconomyManager:DistributeMatchRewards(winningFaction: string, wasPacifist: boolean, matchStats: {[UserId]: MatchPlayerStats}?)` loops `Players:GetPlayers()` once; a player missing either a `DataManager` profile or a `PlayerData` role entry is silently skipped (`continue`) — no error, no payout, no `TotalGamesCompleted` increment.

Per-player payout, in order:

| Bonus | Amount | Condition |
|---|---|---|
| Base | +50 | Everyone (that has both a profile and role data) |
| Faction Victory | +100 | `ROLE_FACTIONS[role] == winningFaction` (its own copy of §2's `WIN_CONDITIONS` — see quirk 10) |
| Martyr | +75 | Role is `Martyr`, `ProtectedTargetUserId` is set, and that target is still `IsAlive == true` |
| Executioner Kills | `Kills * 25` | `matchStats[UserId].Kills > 0` (falls back to a flat +25 if only `.LandedKill == true` is set — see quirk 12, currently unreachable) |
| Intercepted King Hit | +75 | `matchStats[UserId].InterceptedKingHit == true` — **not** role-gated, see quirk 11 |
| Peasant Correct Vote | +50 | Role is `Peasant` **and** `matchStats[UserId].VotedKingCorrectly == true` |
| Spy Survival | +50 | Role is `Spy` and `IsAlive == true` |
| Rogue Survival | +75 | Role is `Usurper` and `IsAlive == true` |
| Usurper Mastery | +150 | Role is `Usurper` and `HasCrown == true` |
| **Pacifist** | **×3** | Applied last, to the running total, if `wasPacifist == true` |

After the multiplier: `profile.Data.RoyalCoins += payout`, `profile.Data.TotalGamesCompleted += 1`, `DataManager:UpdateLevel(player)`, then a per-player `print("[ECONOMY] %s (%s) earned %d RoyalCoins this match", ...)`.

A `winningFaction` of `"None"` (the Day 6 draw sentinel — see §14.4) never matches any `ROLE_FACTIONS` value, so nobody gets the Faction Victory bonus on a draw, but every role-specific bonus (Martyr, survival, mastery, tracked stats) still applies independently — a draw isn't a "no rewards" state, just a "no faction bonus" state.

### 14.3 `GameState.MatchStats` — transient, per-match tracked stats

Three of `EconomyManager`'s bonuses (Executioner Kills, Intercepted King Hit, Peasant Correct Vote) depend on *moment-in-time* facts that no longer exist anywhere else by the time the match ends — `GameState.PeasantVotes` in particular is `table.clear()`-ed after every single `Tribunal.Execute()` call (§11.4), so nothing about *who* voted correctly on *which* day survives past that Tribunal without being copied out first. `GameState.MatchStats` (`[UserId] = { Kills: number?, LandedKill: boolean?, InterceptedKingHit: boolean?, VotedKingCorrectly: boolean? }`) exists purely to carry those facts forward to match end. It is written from exactly three places, each lazily creating its own `MatchStats[UserId]` entry if one doesn't exist yet (so entries only exist for players who actually triggered one of these events — most players will have no entry at all):

- `ActionHandler.server.luau`'s `handleConfirmExecution()` — increments `.Kills` on the executing Sorcerer/Knight after every landed kill (§8.2, point 8).
- `ActionHandler.server.luau`'s `redirectToMartyr()` — sets `.InterceptedKingHit = true` on the intercepting Martyr, if the original target was the King (§8.2, point 6).
- `Tribunal.luau`'s `Tribunal.Execute()` — sets `.VotedKingCorrectly = true` on every Peasant whose vote matched the executed target, if that target was the King (§11.4).

`GameLoop.server.luau` passes `GameState.MatchStats` directly as `EconomyManager:DistributeMatchRewards()`'s third argument at match end (§14.4/§3.2) — `EconomyManager` never reads `GameState.MatchStats` on its own (§4.1's note); the whole table is handed in by value-of-reference from the caller.

### 14.4 `evaluateWinConditions()` — the three win triggers + the Day 6 draw

A new helper in `GameLoop.server.luau`, called at the top of the `NightPhase` branch (§3.2) — by that point in the tick, every kill/redirect for the night has already resolved server-side, so `PlayerData` reflects the night's final state. Returns `(winningFaction: string?, wasPacifist: boolean)` — `nil` faction means "no winner yet, keep playing."

Single pass over `Players:GetPlayers()`, tracking (via an `elseif` chain, since `Role` is singular per player) whether the Revolutionary, Usurper, King, Double, and Prince are each still alive, plus — as a separate, non-exclusive check — whether a *crowned* Usurper has ever existed and whether they're still alive:

```lua
-- HasCrown persists on a dead Usurper's data if no living heir ever inherited it (see
-- handleRoyalSuccession in ActionHandler.server.luau), so this still fires post-mortem.
if data.Role == "Usurper" and data.HasCrown == true then
    hasCrownedUsurperExisted = true
    if data.IsAlive == true then
        isCrownedUsurperAlive = true
    end
end
```

Three checks, evaluated in this order (first match wins):

1. **Royal Win → `"The Crown"`**: both rebel threats (Revolutionary and Usurper) are dead.
2. **Rebel Win → `"The Uprising"`**: the King, Double, and Prince are all dead, **and** a crowned Usurper impostor existed and is also dead (§12.1's succession chain is what could have made the Usurper crowned in the first place — see §13.1's `handleRoyalSuccession` fallback order). A Usurper who never received the crown doesn't satisfy this condition on their own death — only a *crowned* Usurper's death counts here.
3. **Pacifist Win → `"Everyone"`, `wasPacifist = true`**: `CurrentDay == 6` and every connected player is still `IsAlive == true` (`aliveCount == totalPlayers`).

If none of the three match, `evaluateWinConditions()` returns `nil, false`, and `GameLoop.server.luau`'s caller falls through to its own separate `elseif GameState.CurrentDay == 6` check (§3.2) — a **fourth, unconditional** outcome not part of `evaluateWinConditions()` itself: if Day 6 arrives and none of the three win conditions above were met (someone died, but no faction was fully wiped), the match still ends, with `winningFaction = "None"` and `wasPacifist = false`. This fallback was added specifically so Day 6 always produces *some* `GameOver` and *some* payout — without it, an incomplete board state at the deadline would leave the loop with nothing left to do (`CurrentDay` can't exceed 6 anywhere else in the code) and players would get no completion reward at all.

### 14.5 `GameOverReveal` — server broadcast

`GameLoop.server.luau`'s `buildFinalRoles()` builds a `{[playerName]: role}` table from the current `PlayerData` for every currently-connected player (anyone who disconnected earlier in the match is absent from both this and `EconomyManager`'s payout loop — consistent, since both independently iterate `Players:GetPlayers()` at essentially the same instant with no yield in between). `GameOverReveal:FireAllClients(winningFaction, wasPacifist, buildFinalRoles())` fires once, immediately after `EconomyManager:DistributeMatchRewards()`, in both the win branch and the Day 6 draw branch of `NightPhase` (§3.2). Client-side handling: §6.5.

### 14.6 Hub return — `TeleportService`

```lua
local TeleportService = game:GetService("TeleportService")
local HUB_PLACE_ID = 104433635710806
```

After firing `GameOverReveal`, `GameLoop.server.luau` does `task.wait(15)` — giving players time to read the reveal UI (§6.5, which self-destructs on the same 15-second timer) — then `TeleportService:TeleportAsync(HUB_PLACE_ID, Players:GetPlayers())`, then `break`s out of the main loop for good; the server never returns to `WaitingForPlayers`. See quirk 13 for the unhandled-error caveat: this call isn't wrapped in `pcall`, and reliably **errors in Studio Play Solo** specifically because an unpublished place can't be a valid `TeleportAsync` destination — this is expected during local testing, not a sign anything upstream (payouts, reveal UI) is broken. The full pipeline was verified end-to-end through the reveal UI in Play Solo; the teleport hop itself can only be verified against a published place.
