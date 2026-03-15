# FiveM Resource CPU/Thread Audit (Pre-Refactor)

This audit identifies polling loops, high-frequency threads, and systems that should move to event-driven or sleep-driven designs.

## Priority 1 (Convert first)

### 1) `APEX-VehicleShop/core/client.lua` marker scanner is effectively always-on
- Thread runs forever with `Wait(1)` and scans every configured shop each cycle.
- It draws markers and checks key input in the same hot loop.
- This is the strongest CPU hotspot in the vehicleshop client because it is always active even when far from all shops.
- **Convert to:** adaptive sleep + zone entry/exit (`polyzone`/distance buckets) + only `Wait(0)` while inside interaction distance.

### 2) `APEX-Garage/client/add.lua` interaction mega-loop mixes many systems in one frame loop
- Large interaction thread checks garage open/store/delete/deposit logic with dynamic `sleep`, but still drops to `sleep = 0` near zones and contains blocking waits such as `while not fistLoad do Wait(0) end` after key press.
- This combines interaction state checks, UI triggers, and data readiness polling in one constantly scheduled thread.
- **Convert to:** event/state-machine split:
  - marker enter/leave events set active context,
  - key-press handlers run only when context is active,
  - async callback/event for `reloadData` completion instead of busy-wait loops.

### 3) `APEX-CustomCar/client/core.lua` main marker/action thread scans all custom positions repeatedly
- Thread loops forever; iterates all `Config.Positions`; draws markers and checks interaction repeatedly.
- It sets `waitTime = 0` near markers and while actionable, so frame-by-frame work becomes heavy in busy areas.
- **Convert to:** nearest-point cache + coarse scan (e.g., 500–1000 ms) when far, and high-frequency checks only for selected nearest point.

## Priority 2 (Likely unnecessary or should be event-driven)

### 4) `APEX-CustomCar/client/core.lua` UI cash updater polls every 100 ms while UI open
- Separate thread calls `updateCash()` every 100 ms during UI session.
- Cash is already naturally event-driven in ESX (money/account update events).
- **Convert to:** update via `esx:setMoney` / `esx:setAccountMoney` events; keep optional low-rate fallback (1–2 s) only if needed.

### 5) `APEX-Garage/client/add.lua` dimension whitelist cache polls every 500 ms
- Thread continuously calls exported dimension functions regardless of player movement/state.
- **Convert to:** update on routing-bucket/dimension change events (or throttled only when system is awake).

### 6) `APEX-Garage/client/add.lua` text UI arbiter loops continuously and uses `Wait(0)` when payload exists
- UI request multiplexer loops forever, pruning request map and reopening textui when changed.
- `Wait(0)` while payload active is unnecessary if updates are event-based.
- **Convert to:** open/close/update textui only on state transitions from marker-enter/leave and interaction context changes.

### 7) `APEX-Garage/client/client.lua` control-disabling thread always running
- Thread permanently runs and disables all controls every frame while menu/progress active.
- Works, but can be replaced by explicit begin/end control lock states.
- **Convert to:** start a temporary lock thread only when menu opens; stop it on close (or use dedicated input contexts).

### 8) `APEX-Garage/client/client.lua` UI auto-close distance checker polls every 200 ms
- Distance check thread is always alive; does periodic polling while UI open.
- **Convert to:** integrate into active UI session handler (single thread lifetime scoped to open menu).

## Priority 3 (Keep but optimize cadence/scope)

### 9) `APEX-Garage/client/add.lua` marker rendering thread
- Already sleep-driven and attempts nearest-marker rendering.
- Still loops forever and can go `sleep = 0` when near marker contexts.
- **Improve:** keep thread but ensure only one marker context active and avoid redundant distance calculations.

### 10) `APEX-Garage/client/add.lua` ghost/closest-marker tracking loop
- Uses adaptive sleeps and interval gating (`shouldRunMarkerScan`), which is better than pure frame polling.
- Still central polling architecture for marker state.
- **Improve:** feed marker state from enter/exit zone events to reduce repeated closest-marker scans.

### 11) `APEX-Garage/client/client.lua` prop streaming scanner (`Wait(1000)` over all zones)
- Reasonable cadence, but still full-zone sweep each tick.
- **Improve:** spatial partition/grid buckets so only nearby zones are checked.

### 12) `APEX-VehicleShop/function/function_client.lua` `DisableKeyInShop()` uses `Wait(1)`
- Spawned per shop-open and runs until menu closes.
- **Improve:** `Wait(0)` only if truly frame-critical; otherwise selective control disabling with slightly higher sleep.

## Server-side polling systems to review

### 13) `APEX-VehicleShop/core/server.lua` periodic ticket/cache cleanup loop (`Wait(10000)`)
- Cleanup loop scans multiple tables every 10 seconds.
- Acceptable on server, but can move to lazy eviction during access to reduce perpetual polling.

### 14) `APEX-VehicleShop/core/server.lua` webhook worker loops
- Worker tick loop (`WEBHOOK_WORKER_TICK_MS`) plus persistence loop (`Wait(5000)`).
- Functionally valid queue worker model.
- **Improve:** wake-on-enqueue model (sleep until next due item) instead of fixed tick.

### 15) `APEX-Garage/server/server.lua` damage flush loop
- Flushes pending updates every configured interval.
- Usually fine; keep if batching is desired.
- **Improve:** also flush when queue length threshold reached or on idle timeout rather than pure fixed cadence.

## Threads that are mostly initialization (not high-priority CPU issues)
- ESX bootstrap loops waiting for shared object in:
  - `APEX-CustomCar/client/job.lua`
  - `APEX-Garage/client/client.lua`
  - `APEX-Garage/server/server.lua`
  - `APEX-VehicleShop/core/client.lua`
  - `APEX-VehicleShop/core/server.lua`
- These are temporary startup waits; low impact compared to perpetual gameplay loops.

## Recommended refactor order
1. `APEX-VehicleShop/core/client.lua` shop marker polling loop.
2. `APEX-Garage/client/add.lua` interaction mega-loop + `fistLoad` busy waits.
3. `APEX-CustomCar/client/core.lua` position scan/action loop.
4. Garage text UI arbiter + dimension cache polling.
5. Server queue/ticket loops (convert from fixed polling to wake/scheduled processing where practical).
