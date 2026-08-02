# Kingdom Royale — Architecture

Complete architecture reference as of the end of Phase C ("The Passive Inheritors"). Phases A ("The Room Crashers": Spy, Martyr, Bishop) and B ("The Uprising": Peasant) are also fully implemented. This document is the single source of truth for the game's server/client engine — every section below was verified directly against the current contents of the source files it describes.

## 1. Project Structure

```
Kingdom_Royale/
├── default.project.json          # Rojo project map (DataModel tree)
└── src/
    ├── server/
    │   ├── init.server.luau       # placeholder entry script
    │   ├── GameLoop.server.luau   # Day/Night state machine, role assignment, teleports, collision groups, cooldown ticking
    │   ├── ActionHandler.server.luau  # Validates/executes every role ability + the King/Usurper order system
    │   └── ChatFilter.server.luau # ShouldDeliverCallback-based Graveyard/room-privacy/eavesdropping chat filter
    ├── client/
    │   ├── init.client.luau       # placeholder entry script
    │   ├── HUDController.client.luau   # Top clock + role card display
    │   └── ActionController.client.luau # State-driven menu UI for every role + ghost visibility polling
    └── shared/
        ├── GameState.luau         # Single source of truth for GameState + PlayerData
        ├── Tribunal.luau          # Shared Tribunal.Execute(targetPlayer) — see §12
        └── Hello.luau             # unused sample module
```

Rojo mapping (`default.project.json`):
- `src/shared` → `ReplicatedStorage.Shared`
- `src/server` → `ServerScriptService.Server`
- `src/client` → `StarterPlayer.StarterPlayerScripts.Client`

`GameLoop.server.luau` and `ActionHandler.server.luau` are independent `Script` instances (not ModuleScripts) that both `require()` `GameState.luau` and mutate the same live tables through it — there is no ownership boundary between them. This split exists because `GameLoop.server.luau` owns the day/night timer and phase transitions, while `ActionHandler.server.luau` owns the single `ActionRequest` dispatcher that every role ability routes through. `ChatFilter.server.luau` is a third, independent consumer of the same shared state, used only for read access.

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
| `NightPhase` | If `CurrentDay == 6`: `CurrentState = "GameOver"`, `updateGameStateDisplay()`, loop `break`. Else: `table.clear(PendingActions)`, `CurrentDay += 1`, teleport to `GrandHall.SpawnPoint_Main`, `tickCooldowns()`, `broadcastAliveStatus()` | `DayGathering` (or `GameOver`) |

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
}
PlayerData = {}
```

Because Luau tables are passed by reference, and Roblox caches a `ModuleScript`'s return value per-VM, every server script that `require()`s this module — `GameLoop.server.luau`, `ActionHandler.server.luau`, `ChatFilter.server.luau`, and `Tribunal.luau` — shares the exact same underlying `GameState`/`PlayerData` tables. There is no replication or ownership boundary; it's an in-process shared-state singleton, server-side only.

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
6. **Martyr redirect check** (`findLivingMartyrProtecting()`/`redirectToMartyr()` — see §11.2) — takes priority over the Prince check below; if a Martyr intercepts, the function returns here.
7. **Prince immunity**: `if requesterData.Role == "Sorcerer" and targetData.Role == "Prince"` — fires `StrikeIntercepted` (§5.3) and returns, **without** killing the Prince. This check is Sorcerer-specific: a Knight's strike is *not* blocked by it, so once the Knight becomes the active executioner (Sorcerer dead), they genuinely can kill a Prince a Sorcerer's magic couldn't touch. (An earlier version blocked *any* executor from killing a Prince — that blanket check was removed specifically to make the Knight Lockout/backup-executioner design mechanically meaningful.)
8. Otherwise: `humanoid.Health = 0`, `targetData.IsAlive = false`, `handleRoyalSuccession(targetPlayer.UserId)` (§13.1), then the Usurper-reveal bookkeeping (`FakeOrderRevealed`/`Cooldown = 3` if applicable), clear `ActiveMurder`, `broadcastAliveStatus()`.

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
    table.clear(GameState.PeasantVotes)

    local targetData = PlayerData[targetPlayer.UserId]
    if targetData and targetData.Role == "King" then
        TribunalResult:FireAllClients("THE MOB HAS EXPOSED " .. targetPlayer.Name:upper() .. " AS THE KING!", true)
    else
        TribunalResult:FireAllClients("THE MOB ACCUSED " .. targetPlayer.Name:upper() .. ", BUT THEY ARE NOT THE KING!", false)
    end
end
```

**Important**: this checks `targetData.Role == "King"` literally — **not** `HasCrown`. A Tribunal verdict on a crowned Double/Prince/Usurper (post-succession) will read as *"NOT THE KING"*, even though they now hold the real authority, because the Tribunal is testing the original starting-King identity, not the current crown-holder. This is a real behavioral quirk worth flagging, not something the current implementation reconciles.

Exists as a shared module (not a `BindableEvent`) specifically so `handlePeasantAccuse()` (early majority) and `GameLoop.server.luau`'s timeout branch (tie-break) call the exact same logic without duplicating it — both already depend on `GameState.luau`, so a plain `require()` needed no new `default.project.json` entries.

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
