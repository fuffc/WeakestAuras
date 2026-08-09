-- WeakestAuras -- the state machine: the glue between trigger systems (which
-- produce states) and regions (which consume them). Everything meets at the
-- state table. Mirrors WA2's WeakAuras.lua glue (§2/§3/§6-7).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- Two things cross the producer<->glue boundary and nothing else: a trigger
-- system fetches its per-trigger allstates via WA.GetTriggerStateForTrigger,
-- mutates them (setting state.changed on any field change), then calls
-- WA.UpdatedTriggerState(id). The glue combines states across triggers, decides
-- visibility, and drives regions through region:Update()/Expand()/Collapse().

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- triggerState[id] (§3): per-display combination state + per-trigger
-- allstates. [triggernum] = allstates (cloneId -> state; "" is the sole,
-- non-clone key produced). Kept file-local; Debug reads it via
-- WA.GetDisplayTriggerState.
local triggerState = {}

-- regions[id] = { regionType = "icon", byClone = { [cloneId] = frame } }. Keyed
-- by display id and re-keyed on rename (WA.Rename) -- everything the engine owns
-- is id-keyed, matching upstream. CloneId is plumbed throughout but "" is the
-- only value ever produced, so the "pool" is a create-on-demand stub; real
-- pooling arrives with clones.
local regions = {}

-- loaded[id] = true while a display's load conditions pass (Load.lua, §11).
-- "Loaded" is distinct from "added": WA.Add compiles every display's
-- triggers/region/conditions; only a loaded display is *registered* with its
-- trigger systems (in their scan/event index) and allowed to show. An unloaded
-- display keeps its compiled state but produces nothing and stays hidden.
local loaded = {}

-- standby[id] = true while a display is *not* loaded but every character-level
-- constraint passes -- only a transient one (combat, zone, group, stance, ...)
-- is holding it back. A label for the options window and nothing more: the
-- engine decides what to register and show from `loaded` alone, so this must
-- stay a table of its own rather than an extra value in `loaded`, which is read
-- as a bare truthy in WA.Add's two paths below.
local standby = {}

-- Forward decl: WA.Add (above the preview section) re-injects a forced aura's
-- fake state synchronously after a recompile. Assigned in the preview section.
local fakeForced

-- forced[id] = true for every leaf whose fake state the preview ticker injects
-- (forced visibility, §14 FakeStatesFor). A group in the options list
-- contributes its leaf descendants here, so selecting or eye-toggling a group
-- fake-shows its children -- which is what makes an inactive dynamic group's
-- layout visible to debug. Read by WA.Add (a forced leaf is collapse-exempt)
-- and the trigger watchers (they skip a forced leaf so a real scan doesn't fight
-- the fake). The union of the selection preview + eye pins; see WA.SetPreview.
WA.forced = {}

-- True while the /wa options window is open. Mutes every non-forced display's
-- real state (see UpdatedTriggerState) so config starts from a blank board and
-- reveals only what you're editing -- WA2's SetFakeStates behavior.
WA.optionsOpen = false

-- Trigger *systems* (runtime state producers), keyed by trigger.type. Distinct
-- from Data.lua's WA.triggerTypes (the options-side registry).
WA.triggerSystems = {}

-- ---------------------------------------------------------------------------
-- Trigger system registration + lookup
-- ---------------------------------------------------------------------------

function WA.RegisterTriggerSystem(types, system)
	for i = 1, table.getn(types) do
		WA.triggerSystems[types[i]] = system
	end
end

-- The system owning triggernum n of this display, or nil.
function WA.GetTriggerSystem(data, triggernum)
	local trigger = WA.GetTrigger(data, triggernum)
	return trigger and trigger.type and WA.triggerSystems[trigger.type] or nil
end

-- Each distinct registered system exactly once -- Delete/Rename fan out to all
-- of them since a display's own systems may already be gone by then.
-- safecall-wrapped so one system's error (e.g. a loadFunc side effect
-- throwing) can't silently abort the rest of applyLoad -- previously an
-- uncaught error here left loaded[id] claiming success (WA.Add sets it before
-- this runs) while the system that threw never actually finished
-- registering, with nothing printed to explain why.
local function eachSystem(fn)
	local seen = {}
	for _, system in pairs(WA.triggerSystems) do
		if not seen[system] then
			seen[system] = true
			WA.safecall("trigger system", fn, system)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Regions (create-on-demand stub pool)
-- ---------------------------------------------------------------------------

-- Creates or returns the region frame for (id, cloneId). Rebuilds the whole
-- entry when the display's regionType changed under it. Regions are created
-- lazily and start collapsed (hidden); the state machine expands them.
local function EnsureRegion(id, cloneId)
	local data = WeakestAurasDB.displays[id]
	if not data then return nil end
	-- Not WA.regionTypes directly: an aura naming a type this addon lacks builds
	-- through the `fallback` region, which says so on screen rather than leaving a
	-- row in the list with nothing behind it.
	local rt = WA.RegionSpecFor(data)
	if not rt or not rt.create then return nil end

	local entry = regions[id]
	-- The spec as well as the name, so an aura that was falling back and whose
	-- real type has since been registered gets rebuilt rather than kept.
	if not entry or entry.regionType ~= data.regionType or entry.spec ~= rt then
		if entry then
			for _, frame in pairs(entry.byClone) do frame:Hide() end
		end
		entry = { regionType = data.regionType, spec = rt, byClone = {} }
		regions[id] = entry
	end

	local frame = entry.byClone[cloneId]
	if not frame then
		frame = rt.create(UIParent, data)
		-- Its own identity, upstream's region.id/region.cloneId pair: anything
		-- reached *through* a region and needing to know which aura it belongs to
		-- (the aura environment, an error message naming the aura) has only the
		-- frame to ask. WA.Rename re-stamps it.
		frame.id = id
		frame.cloneId = cloneId
		entry.byClone[cloneId] = frame
		if rt.modify then rt.modify(frame, data) end
	end
	return frame
end

-- (Re)applies saved config to every existing clone of a display -- the single
-- code path both "apply saved config" (WA.Add) and a regionType switch run.
local function SetRegion(data)
	local rt = WA.RegionSpecFor(data)
	if not rt or not rt.create then return end
	EnsureRegion(data.id, "")
	local entry = regions[data.id]
	if entry and rt.modify then
		for _, frame in pairs(entry.byClone) do
			rt.modify(frame, data)
		end
	end
end

local function CollapseAll(id)
	local entry = regions[id]
	if not entry then return end
	local data = WeakestAurasDB.displays[id]
	for _, frame in pairs(entry.byClone) do
		-- Re-run conditions in hide mode first (restores base property values,
		-- clears activation bookkeeping) while the region still has its states.
		if data and data.uid then WA.RunConditions(frame, data.uid, true) end
		frame:Collapse()
	end
end

-- Collapse clones whose cloneId no longer has a state (Show->Show pruning).
local function CollapseStaleClones(id, allstates)
	local entry = regions[id]
	if not entry then return end
	local data = WeakestAurasDB.displays[id]
	for cloneId, frame in pairs(entry.byClone) do
		if not allstates[cloneId] then
			if data and data.uid then WA.RunConditions(frame, data.uid, true) end
			frame:Collapse()
		end
	end
end

-- Iterate every live region frame (all clones of all displays). Conditions.lua
-- uses this to re-run conditions for shown regions on a global-condition event.
function WA.ForEachRegion(fn)
	for id, entry in pairs(regions) do
		for _, frame in pairs(entry.byClone) do fn(frame, id) end
	end
end

-- Every live clone frame of one display. Regions.lua's dynamicgroup grower uses
-- it to collect a child's visible clones for layout.
function WA.ForEachClone(id, fn)
	local entry = regions[id]
	if not entry then return end
	for cloneId, frame in pairs(entry.byClone) do fn(frame, cloneId) end
end

-- The live on-screen frame for a display (default the base "" clone). The mover
-- grabs the previewed region through this. nil if the
-- display hasn't been rendered yet. Ensures the region so the options preview,
-- which always targets the base clone, can attach a mover before any state.
function WA.GetRegion(id, cloneId)
	return EnsureRegion(id, cloneId or "")
end

-- Like GetRegion but never creates -- returns nil if the frame doesn't exist
-- yet. Regions.lua's WA.RelayoutGroup uses it so recomputing a group's box
-- after a child edit doesn't spuriously spin up an unrendered group.
function WA.PeekRegion(id, cloneId)
	local entry = regions[id]
	return entry and entry.byClone[cloneId or ""]
end

-- ---------------------------------------------------------------------------
-- Producer-side API + conditions hook
-- ---------------------------------------------------------------------------

-- A trigger system's handle on its own allstates for one trigger -- it mutates
-- this table directly (add/update/remove states, set state.changed), then calls
-- WA.UpdatedTriggerState. nil if the display hasn't been Added yet.
function WA.GetTriggerStateForTrigger(id, triggernum)
	local ts = triggerState[id]
	if not ts then return nil end
	if not ts[triggernum] then ts[triggernum] = {} end
	return ts[triggernum]
end

-- Runs a display's condition function against the just-applied states.
-- Conditions.lua overrides this; the no-op default keeps the apply path
-- (ApplyStatesToRegions) working when that file hasn't loaded.
function WA.RunConditions(region, uid, hide) end

-- ---------------------------------------------------------------------------
-- Apply states to regions (§3 ApplyStatesToRegions)
-- ---------------------------------------------------------------------------

local function ApplyStatesToRegions(id, activeTrigger, allstates)
	local ts = triggerState[id]
	local data = WeakestAurasDB.displays[id]
	for cloneId, state in pairs(allstates) do
		local region = EnsureRegion(id, cloneId)
		if region then
			region.state = state
			if data.anchorFrameType == "NAMEPLATE" or data.anchorFrameType == "UNITFRAME" then
				WA.regionPrototype.ApplyPosition(region, data)
			end
			region.states = region.states or {}
			-- Every trigger's state for this clone is readable (falling back to
			-- the "" state), so text can say %2.p and conditions can check
			-- trigger 3 while another trigger drives the display (§3).
			for triggernum = 1, ts.numTriggers do
				local as = ts[triggernum]
				region.states[triggernum] = as and (as[cloneId] or as[""]) or nil
			end
			if state.changed or not region.toShow then
				WA.safecall(id, region.Update, region)
				region.subRegionEvents:Notify("Update", state, region.states)
				region:Expand()
				WA.RunConditions(region, data.uid, false)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- UpdatedTriggerState (§3): the seven steps
-- ---------------------------------------------------------------------------

function WA.UpdatedTriggerState(id)
	local ts = triggerState[id]
	if not ts then return end
	local data = WeakestAurasDB.displays[id]
	if not data then return end
	local numTriggers = ts.numTriggers

	-- 1. Prune states flagged hidden (show == false is the legacy removal path;
	-- deleting the key is the other one, both handled).
	for triggernum = 1, numTriggers do
		local as = ts[triggernum]
		if as then
			for cloneId, state in pairs(as) do
				if state.show == false then as[cloneId] = nil end
			end
		end
	end

	-- 2. Per-trigger active flag + count. Every surviving state is also stamped
	-- with the identity fields upstream guarantees (WA2's WeakAuras.lua own
	-- UpdatedTriggerState): a trigger system only has to fill in what it knows,
	-- and anything downstream can rely on these being there. `id` in particular
	-- is what makes %n fall back to the display's own name for a trigger that
	-- reports no name of its own (TextReplace's `n` symbol reads name or id).
	local triggerCount = 0
	for triggernum = 1, numTriggers do
		local as = ts[triggernum]
		local anyShown = false
		if as then
			local entry = data.triggers[triggernum]
			for _, state in pairs(as) do
				state.id = id
				state.triggernum = triggernum
				state.trigger = entry and entry.trigger
				if state.show then anyShown = true end
			end
		end
		if ts.triggers[triggernum] ~= anyShown then
			ts.triggers[triggernum] = anyShown
			if anyShown then ts.activationTime[triggernum] = GetTime() end
		end
		if anyShown then triggerCount = triggerCount + 1 end
	end
	ts.triggerCount = triggerCount

	-- 3. Overall show via the disjunctive.
	local newShow
	if ts.disjunctive == "any" then
		newShow = triggerCount > 0
	elseif ts.disjunctive == "custom" and ts.triggerLogicFunc then
		local ok, res = WA.RunAuraFunc(id, id .. ": custom logic", ts.triggerLogicFunc, ts.triggers)
		newShow = (ok and res) and true or false
	else -- "all"
		newShow = numTriggers > 0 and triggerCount == numTriggers
	end

	-- While the options window is open, mute every display except the ones the
	-- user is actively viewing (selection + eye pins, which the preview ticker
	-- force-shows). Everything else is hidden regardless of its real trigger, so
	-- config starts from a blank board and you reveal what you work on -- WA2's
	-- SetFakeStates/FakeStatesFor. WA.forced leaves are exempt (fakeOne owns them).
	if WA.optionsOpen and not WA.forced[id] then
		newShow = false
	end

	-- 4. Resolve the active trigger (fixed number, or first_active scan).
	local activeTrigger = ts.activeTriggerMode
	if activeTrigger == WA.trigger_modes.first_active then
		activeTrigger = 1
		for triggernum = 1, numTriggers do
			if ts.triggers[triggernum] then activeTrigger = triggernum; break end
		end
	end
	local allstates = ts[activeTrigger]

	-- 5. Shown but the active trigger has no state: synthesize a fallback.
	if newShow and (not allstates or not next(allstates)) then
		local system = WA.GetTriggerSystem(data, activeTrigger)
		local fallback = {}
		if system and system.CreateFallbackState then
			system.CreateFallbackState(data, activeTrigger, fallback)
		end
		fallback.show = true
		fallback.changed = true
		ts[activeTrigger] = ts[activeTrigger] or {}
		ts[activeTrigger][""] = fallback
		allstates = ts[activeTrigger]
	end
	ts.activeStates = allstates

	-- 6. Apply by transition.
	local wasShown = ts.show
	ts.show = newShow
	if newShow then
		ApplyStatesToRegions(id, activeTrigger, allstates)
		if wasShown then CollapseStaleClones(id, allstates) end
	elseif wasShown then
		CollapseAll(id)
	end

	-- 7. Reset changed flags.
	for triggernum = 1, numTriggers do
		local as = ts[triggernum]
		if as then
			for _, state in pairs(as) do state.changed = false end
		end
	end

	-- This display's clones just changed visibility, which changes its parent
	-- group's layout: a dynamicgroup re-arranges its now-visible children, a
	-- static group refreshes its box. Cheap and idempotent; the batching happens
	-- naturally since all of this id's clones settle within this one call.
	if data.parent then WA.RelayoutGroup(data.parent) end
	if WA.regionPrototype and WA.regionPrototype.SyncOptionsAnchorMarkers then
		WA.regionPrototype.SyncOptionsAnchorMarkers()
	end
end

-- Toggle the config-mode mute (WA2 SetFakeStates/ClearFakeStates). Opening
-- re-evaluates every rendered display so non-forced ones hide; closing restores
-- their real states. OptionsFrame calls this from the panel's show/hide.
function WA.SetOptionsOpen(open)
	WA.optionsOpen = open and true or false
	if WA.regionPrototype and WA.regionPrototype.SetOptionsAnchors then
		WA.regionPrototype.SetOptionsAnchors(WA.optionsOpen)
	end
	for id in pairs(triggerState) do
		WA.safecall(id, WA.UpdatedTriggerState, id)
	end
end

-- ---------------------------------------------------------------------------
-- Add / Remove / Rename (§3 pAdd, scaled)
-- ---------------------------------------------------------------------------

local function anchorDependency(data)
	if not data then return nil end
	local target = WA.GetAnchorAuraID and WA.GetAnchorAuraID(data)
	if target then return target end
	return data.parent
end

function WA.CheckForAnchorCycle(source)
	local visited = {}
	local current = source
	while current do
		if visited[current] then return true end
		visited[current] = true
		current = anchorDependency(WeakestAurasDB.displays[current])
	end
	return false
end

local function resetAnchorCycle(data)
	if not data or not WA.CheckForAnchorCycle(data.id) then return false end
	data.anchorFrameType = "UIPARENT"
	data.anchorFrameFrame = nil
	DEFAULT_CHAT_FRAME:AddMessage(
		"|cffff0000WeakestAuras|r Warning: anchoring in aura '" .. tostring(data.id)
			.. "' was reset because it creates an anchoring cycle.", 1, 0.3, 0.3)
	return true
end

local function dependencyOrder(ids)
	local ordered, added, visiting = {}, {}, {}
	local function visit(id)
		if added[id] then return end
		if visiting[id] then return end
		visiting[id] = true
		local data = WeakestAurasDB.displays[id]
		local anchor = WA.GetAnchorAuraID and WA.GetAnchorAuraID(data)
		if anchor and ids[anchor] then visit(anchor) end
		local parent = data and data.parent
		if parent and ids[parent] then visit(parent) end
		visiting[id] = nil
		added[id] = true
		table.insert(ordered, id)
	end
	for id in pairs(ids) do visit(id) end
	return ordered
end

-- Recomputes the standby label for a display whose load state is `isLoaded`.
-- Returns whether it changed, so a caller that skipped the load transition can
-- still repaint the list. A loaded display is never on standby.
local function setStandby(data, isLoaded)
	local id = data.id
	local was = standby[id]
	standby[id] = (not isLoaded and WA.EvalLoadStatic(data)) and true or nil
	return standby[id] ~= was
end

-- Registers or unregisters a compiled display with its trigger systems by its
-- desired load state, and shows/hides accordingly (§11). Loading hands
-- the display to each system's LoadDisplays (which starts scanning / registers
-- events); unloading calls UnloadDisplays, wipes the produced states, and
-- collapses the region. Sets loaded[id] to the new state. Callers decide when to
-- (re)run UpdatedTriggerState -- LoadDisplays already force-initializes status
-- triggers, so WA.Add/SetDisplayLoaded only need it for the aura watcher path.
--
-- Repaints the aura list whenever the label it renders moved. Both routes here
-- need it and neither is the options window: a zone/combat change comes through
-- ScanForLoads, and an edit on the Load tab comes through WA.Add, which never
-- touched WA.RefreshList -- the row's load state would sit stale until the user
-- next clicked something. WA.RefreshList is itself a no-op while the panel is
-- closed, so the login-time AddAllDisplays sweep costs nothing.
local function applyLoad(data, shouldLoad)
	local id = data.id
	shouldLoad = shouldLoad and true or false
	local wasLoaded, wasStandby = loaded[id], standby[id]
	loaded[id] = shouldLoad
	setStandby(data, shouldLoad)
	if shouldLoad then
		eachSystem(function(system) if system.LoadDisplays then system.LoadDisplays({ id }) end end)
	else
		eachSystem(function(system) if system.UnloadDisplays then system.UnloadDisplays({ id }) end end)
		local ts = triggerState[id]
		if ts then
			-- Drop every produced state so a later reload starts clean (§11:
			-- unloading wipes trigger state); ts.show=false so the reload's first
			-- UpdatedTriggerState sees the region as currently hidden.
			for triggernum = 1, ts.numTriggers do ts[triggernum] = {} end
			ts.show = false
		end
		CollapseAll(id)
	end
	if (loaded[id] ~= wasLoaded or standby[id] ~= wasStandby) and WA.RefreshList then
		WA.RefreshList()
	end
end

-- The load system's entry point when a display's load state may have flipped
-- (Load.lua's ScanForLoads, §11). Idempotent -- a no-op when the state is
-- unchanged or the display isn't compiled (a group, or not yet Added).
function WA.SetDisplayLoaded(data, shouldLoad)
	local id = data.id
	if not triggerState[id] then return end
	shouldLoad = shouldLoad and true or false
	if (loaded[id] and true or false) == shouldLoad then
		-- No load transition, but a character-level constraint can still have
		-- flipped under an unloaded display (a level-up, a spell learned), which
		-- moves it between Standby and Not Loaded.
		if setStandby(data, shouldLoad) and WA.RefreshList then WA.RefreshList() end
		return
	end
	applyLoad(data, shouldLoad)
	if shouldLoad then WA.UpdatedTriggerState(id) end
end

-- Read-only (Debug.lua's /wa load): is this display currently loaded?
function WA.IsDisplayLoaded(id)
	return loaded[id] and true or false
end

-- The three-state load label the aura list renders, plus the leaf counts its
-- tooltip needs: "loaded" / "standby" / "unloaded", nLoaded, nStandby, nLeaves.
-- A group rolls its whole subtree up by priority, matching WA2's own header
-- test -- any leaf loaded makes the group loaded, else any leaf on standby
-- makes it standby. A leaf counts as one leaf, so both cases read the same.
function WA.DisplayLoadState(id)
	local data = WeakestAurasDB.displays[id]
	if not data then return "unloaded", 0, 0, 0 end
	if not WA.IsGroup(data) then
		if loaded[id] then return "loaded", 1, 0, 1 end
		if standby[id] then return "standby", 0, 1, 1 end
		return "unloaded", 0, 0, 1
	end

	local nLoaded, nStandby, nLeaves = 0, 0, 0
	local children = data.controlledChildren or {}
	for i = 1, table.getn(children) do
		local _, cl, cs, cn = WA.DisplayLoadState(children[i])
		nLoaded, nStandby, nLeaves = nLoaded + cl, nStandby + cs, nLeaves + cn
	end
	local state = "unloaded"
	if nLoaded > 0 then state = "loaded" elseif nStandby > 0 then state = "standby" end
	return state, nLoaded, nStandby, nLeaves
end

-- Compiles a customTriggerLogic string ("function(t) return t[1] and not t[2]
-- end") into a callable (§3). User-authored, so it goes through WA.LoadFunction
-- like every other custom-code site -- which is also where it picks up the
-- sandbox: writes from it used to land in the real global namespace.
local function compileTriggerLogic(str, id)
	if not str or str == "" then return nil end
	return WA.LoadFunction(str, id .. ": custom logic")
end

-- Renders/repositions a group's container frame (no triggers/state -- see
-- WA.Add's group branch). Re-anchors existing child frames to it afterward, so
-- a group (re)built after its children already have frames pulls them in;
-- children created later resolve the group on demand via ApplyPosition. Nested
-- child groups recurse.
function WA.AddGroup(data)
	SetRegion(data) -- runs groupModify: positions frame, sizes box, draws border
	local kids = data.controlledChildren or {}
	for i = 1, table.getn(kids) do
		local cd = WeakestAurasDB.displays[kids[i]]
		if cd and WA.IsGroup(cd) then
			WA.AddGroup(cd)
		elseif cd then
			local cf = WA.PeekRegion(cd.id, "")
			if cf then WA.regionPrototype.ApplyPosition(cf, cd) end
		end
	end
end

-- Re-anchors a child whose group membership just changed and refreshes the
-- boxes of the groups it left and joined. The runtime side of Data.lua's
-- reparent primitives (WA.AddChildToGroup/RemoveChildFromGroup/ReorderAura):
-- a child's frame is parented by data.parent now (ApplyPosition), so moving it
-- between groups must re-anchor it. Safe before render -- an unrendered child
-- simply anchors correctly when first shown. A moved child that is itself a
-- group carries its own children (they SetParent to its frame).
function WA.RefreshMembership(childId, oldParent, newParent)
	local cd = WeakestAurasDB.displays[childId]
	if cd then
		local cf = WA.PeekRegion(childId, "")
		if cf then WA.regionPrototype.ApplyPosition(cf, cd) end
	end
	if oldParent then WA.RelayoutGroup(oldParent) end
	if newParent and newParent ~= oldParent then WA.RelayoutGroup(newParent) end
end

function WA.Add(data, simpleChange)
	-- The aura list's row previews render this display's own appearance fields
	-- (Regions.lua's modifyThumbnail), so any edit that reaches here -- including
	-- the pure-visual fast path below -- has to repaint the row, not just the
	-- region. WA.RefreshList is a no-op while the options panel is closed.
	if WA.RefreshList then WA.RefreshList() end
	if WA.IsGroup(data) then WA.AddGroup(data); return end
	resetAnchorCycle(data)

	local id = data.id

	-- Fast-path (WA2's pAdd simpleChange): a pure-visual edit (region/subregion
	-- appearance) doesn't change which states are produced or the load status, so
	-- skip the collapse + trigger/condition/load recompile. Re-apply the region's
	-- visuals -- modify rebuilds subregions too (RegionPrototype.modifyFinish) -- and
	-- let UpdatedTriggerState re-layer states + conditions on the fresh base. Only
	-- valid once the display has been fully Added (triggerState exists); the first
	-- Add and any structural edit (trigger/load/condition/regionType) fall through.
	if simpleChange and triggerState[id] then
		SetRegion(data)
		-- A size/offset edit shifts this aura's contribution to its group's box.
		if data.parent then WA.RelayoutGroup(data.parent) end
		if WA.forced[id] then
			if fakeForced then fakeForced(id) end
		elseif loaded[id] then
			WA.UpdatedTriggerState(id)
		end
		return
	end

	local triggers = data.triggers
	local numTriggers = table.getn(triggers)

	-- Collapse-first baseline (WA2's pAdd): a recompile reuses the live region
	-- frame, so force it hidden before re-deriving -- otherwise a recompile that now
	-- resolves to hidden (e.g. switching Show always->on-cooldown while off cooldown)
	-- strands the previously-visible frame on screen. The re-derivation below re-shows
	-- it synchronously if it should stay up (GenericTrigger via force_events, aura via
	-- TriggerAura.LoadDisplays' sync rescan), so there's no visible flicker. The
	-- previewed aura is exempt -- its visibility is owned by the preview ticker, which
	-- we re-run synchronously at the end instead (WA2's FakeStatesFor snapshot).
	if not WA.forced[id] then CollapseAll(id) end

	-- The fresh ts's `show` must describe the region as it actually is right now,
	-- since UpdatedTriggerState only collapses on a shown->hidden transition. The
	-- collapse above makes that false for the normal path -- but the forced path
	-- skipped it, so a still-expanded preview must carry its `show` over or a
	-- recompile that now resolves to hidden strands the frame on screen with no
	-- transition left to take it down (e.g. flipping the disjunctive back to "all").
	local prev = triggerState[id]
	local ts = {
		disjunctive = triggers.disjunctive or "all",
		numTriggers = numTriggers,
		activeTriggerMode = triggers.activeTriggerMode or WA.trigger_modes.first_active,
		triggerLogicFunc = nil,
		triggerLogicSource = nil,
		triggers = {},
		triggerCount = 0,
		activationTime = {},
		activatedConditions = {},
		show = (WA.forced[id] and prev and prev.show) and true or false,
		activeStates = nil,
	}
	if ts.disjunctive == "custom" then
		ts.triggerLogicSource = triggers.customTriggerLogic
		-- Edited code, so whatever the old code cached in aura_env is stale.
		if not prev or prev.triggerLogicSource ~= ts.triggerLogicSource then
			WA.ClearAuraEnv(id)
		end
		ts.triggerLogicFunc = compileTriggerLogic(triggers.customTriggerLogic, id)
	end
	for i = 1, numTriggers do ts[i] = {} end
	triggerState[id] = ts

	-- Clear every system's prior registration for this id first, so a trigger
	-- switched across systems (e.g. aura -> a generic prototype) doesn't leave
	-- the old system still producing states into this id's slots. Cheap and safe
	-- (each Delete no-ops on an id it doesn't own); the current systems re-Add
	-- below.
	eachSystem(function(system) if system.Delete then system.Delete(id) end end)

	-- Each system compiles its own triggers out of data.triggers (it iterates,
	-- picking its own types), so call each owning system once.
	local called = {}
	for i = 1, numTriggers do
		local system = WA.GetTriggerSystem(data, i)
		if system and not called[system] then
			called[system] = true
			if system.Add then system.Add(data) end
		end
	end

	SetRegion(data)
	-- Compile this display's conditions before the first state application, so
	-- the RunConditions call inside UpdatedTriggerState has something to run
	-- (a no-op unless Conditions.lua has overridden it).
	WA.LoadConditions(data)

	-- The systems above only compiled this display (they don't self-register into
	-- their active scan/event index anymore). applyLoad registers it iff its load
	-- conditions currently pass -- so an unloaded aura is compiled-but-dark, and a
	-- recompile (this WA.Add) re-decides load state every time (§11). Runs
	-- unconditionally rather than through SetDisplayLoaded's transition guard: the
	-- Delete above cleared the systems' registration, so even an unchanged load
	-- state must re-register.
	applyLoad(data, WA.EvalLoad(data))
	if WA.forced[id] then
		-- Re-establish the fake state in the same frame (the recompile wiped it and
		-- the region was left untouched above), so an edit doesn't drop the preview
		-- until the 0.1s ticker's next fire.
		if fakeForced then fakeForced(id) end
	elseif loaded[id] then
		WA.UpdatedTriggerState(id)
	end

	-- A recompile can change this aura's size/offset (regionType switch, etc.),
	-- so refresh its group's box now that its frame reflects the new config.
	if data.parent then WA.RelayoutGroup(data.parent) end
end

function WA.Remove(data)
	local id = data.id
	CollapseAll(id)
	local entry = regions[id]
	if entry then
		for _, frame in pairs(entry.byClone) do frame:Hide() end
		regions[id] = nil
	end
	triggerState[id] = nil
	loaded[id] = nil
	standby[id] = nil
	WA.ClearAuraEnv(id)
	WA.UnloadConditions(data)
	eachSystem(function(system) if system.Delete then system.Delete(id) end end)
	-- Its group's box no longer needs to cover this child.
	if data.parent then WA.RelayoutGroup(data.parent) end
end

function WA.Rename(oldId, newId)
	if triggerState[oldId] then
		triggerState[newId] = triggerState[oldId]
		triggerState[oldId] = nil
	end
	if regions[oldId] then
		regions[newId] = regions[oldId]
		regions[oldId] = nil
		for _, frame in pairs(regions[newId].byClone) do frame.id = newId end
	end
	if loaded[oldId] ~= nil then
		loaded[newId] = loaded[oldId]
		loaded[oldId] = nil
	end
	if standby[oldId] ~= nil then
		standby[newId] = standby[oldId]
		standby[oldId] = nil
	end
	WA.RenameAuraEnv(oldId, newId)
	eachSystem(function(system) if system.Rename then system.Rename(oldId, newId) end end)
end

-- Builds runtime state + regions for every display (leaf and group). Called
-- once after all Register*/NormalizeAll have run (OptionsFrame.lua, the last
-- file). WA.Add routes groups to WA.AddGroup; order is irrelevant since a
-- child's ApplyPosition ensures its group frame on demand and AddGroup
-- re-anchors children that already exist.
function WA.AddMany(list)
	local ids = {}
	for i = 1, table.getn(list or {}) do
		local data = list[i]
		if data and data.id then ids[data.id] = true end
	end
	for id in pairs(ids) do resetAnchorCycle(WeakestAurasDB.displays[id]) end
	local order = dependencyOrder(ids)
	for i = 1, table.getn(order) do
		local id = order[i]
		local data = WeakestAurasDB.displays[id]
		if data then WA.safecall(id, WA.Add, data) end
	end
end

function WA.AddAllDisplays()
	local ids = {}
	for id in pairs(WeakestAurasDB.displays) do ids[id] = true end
	local order = dependencyOrder(ids)
	for i = 1, table.getn(order) do
		local id = order[i]
		local data = WeakestAurasDB.displays[id]
		if data then WA.safecall(id, WA.Add, data) end
	end
end

-- Debug read-only accessor (Debug.lua's /wa states).
function WA.GetDisplayTriggerState(id)
	return triggerState[id]
end

-- ---------------------------------------------------------------------------
-- Forced visibility / fake states (§14 + FakeStatesFor). While the
-- options window is open, any number of leaves can be "forced" -- shown with a
-- looping fake state so they can be sized/positioned/debugged even when their
-- real trigger doesn't match. A group forces its leaf descendants, so selecting
-- (or eye-toggling) a dynamic group fake-shows its children and the grower lays
-- them out instead of stacking them at the baseline. Two sources merge into
-- WA.forced: the current selection preview (transient) and per-row eye pins
-- (persist across selection until options closes).
-- ---------------------------------------------------------------------------

local pinned = {}          -- leaf id -> true: eye-pinned (persists across selection)
local selectionLeaves = {} -- leaf id -> true: from the current selection preview
local previewTicker
local PREVIEW_CYCLE = 7 -- seconds; matches WA2's fake-timer loop length

-- The leaf ids under id (id itself if it's a leaf), accumulated into `into`.
local function collectLeaves(id, into)
	local data = WeakestAurasDB.displays[id]
	if not data then return end
	if WA.IsGroup(data) then
		local kids = data.controlledChildren or {}
		for i = 1, table.getn(kids) do collectLeaves(kids[i], into) end
	else
		into[id] = true
	end
end

-- Injects one leaf's looping fake state (name/icon from each trigger) and
-- re-runs the state machine so the region shows. *Every* trigger is faked, not
-- just trigger 1 (WA2's UpdateFakeStatesFor, which loops data.triggers): the
-- combination in UpdatedTriggerState still runs over the fakes, so faking only
-- one leaves disjunctive="all" (and any custom logic) unsatisfied -- the preview
-- would stay dark for exactly the multi-trigger displays that need it most.
local function fakeOne(id)
	local data = WeakestAurasDB.displays[id]
	local ts = triggerState[id]
	if not data or not ts then return end

	local remain = PREVIEW_CYCLE - math.mod(GetTime(), PREVIEW_CYCLE)
	for triggernum = 1, ts.numTriggers do
		local system = WA.GetTriggerSystem(data, triggernum)
		local name, icon = data.id, "Interface\\Icons\\INV_Misc_QuestionMark"
		if system and system.GetNameAndIcon then
			local n, i = system.GetNameAndIcon(data, triggernum)
			-- An unconfigured trigger reports "" rather than nil, and "" is truthy
			-- in Lua -- so test for content, not just presence, or the preview shows
			-- a blank %n. The display's own id is the fallback, matching what %n
			-- itself falls back to (TextReplace).
			if n and n ~= "" then name = n end
			if i then icon = i end
		end

		local states = ts[triggernum] or {}
		ts[triggernum] = states
		local state = states[""]
		if not state then state = {}; states[""] = state end
		state.show = true
		state.changed = true
		state.progressType = "timed"
		state.name = name
		state.icon = icon
		state.stacks = 3
		state.duration = PREVIEW_CYCLE
		state.expirationTime = GetTime() + remain
	end
	WA.UpdatedTriggerState(id)
end
fakeForced = fakeOne -- resolve the forward decl WA.Add uses

-- Retires a leaf's fake state; the watcher re-establishes the real one (or the
-- region goes dark) on its next scan.
local function retireFake(id)
	local ts = triggerState[id]
	if not ts then return end
	for triggernum = 1, ts.numTriggers do
		local as = ts[triggernum]
		if as and as[""] then
			as[""].show = false
			as[""].changed = true
		end
	end
	WA.UpdatedTriggerState(id)
	-- The wipe above deleted every state, including ones a still-true status
	-- trigger owns -- and an event-driven system only writes state when its event
	-- fires, so "in combat" would read as inactive until the next regen event.
	-- Re-run each system's force pass now (the aura scanner's 0.2s poll, which
	-- skips forced ids, needs no help).
	eachSystem(function(system) if system.ForceUpdate then system.ForceUpdate({ id }) end end)
end

local function previewTick()
	for id in pairs(WA.forced) do fakeOne(id) end
end

-- Rebuilds WA.forced = pinned + selectionLeaves, retiring the fakes that dropped
-- out and (re)starting/stopping the ticker to match.
local function recomputeForced()
	local nextSet = {}
	for id in pairs(pinned) do nextSet[id] = true end
	for id in pairs(selectionLeaves) do nextSet[id] = true end
	for id in pairs(WA.forced) do
		if not nextSet[id] then WA.forced[id] = nil; retireFake(id) end
	end
	for id in pairs(nextSet) do WA.forced[id] = true end
	if next(WA.forced) then
		if not previewTicker then previewTicker = C_Timer.NewTicker(0.1, previewTick) end
		previewTick()
	elseif previewTicker then
		previewTicker:Cancel()
		previewTicker = nil
	end
end

-- The selection preview: fake the selected aura, replacing whatever the previous
-- selection contributed. Selecting a group reveals all its children; selecting a
-- *child* reveals its whole parent group too, so you edit a member in the
-- context of the group's layout rather than in isolation (the mover still
-- attaches to just the selected node). Called on every selection change; nil
-- clears the selection contribution.
function WA.SetPreview(id)
	selectionLeaves = {}
	if id then
		local data = WeakestAurasDB.displays[id]
		local revealId = id
		if data and data.parent and WeakestAurasDB.displays[data.parent] then
			revealId = data.parent
		end
		collectLeaves(revealId, selectionLeaves)
	end
	recomputeForced()
end

-- Eye toggle for a list row: pins/unpins id's leaves so they stay forced across
-- selection changes. A group toggles all its leaf descendants together -- pin
-- all unless already all-pinned, then unpin all (WA2's Priority/Recheck).
-- The eye toggle over several displays at once, for the aura list's bucket
-- headers: every leaf under any of them is pinned, unless they all already are,
-- in which case they're all released. Mirrors WA2's header view button, which
-- drives PriorityShow/PriorityHide across the bucket's children.
function WA.ToggleForcedMany(ids)
	local leaves = {}
	for i = 1, table.getn(ids) do collectLeaves(ids[i], leaves) end
	local allPinned = true
	for lid in pairs(leaves) do if not pinned[lid] then allPinned = false; break end end
	for lid in pairs(leaves) do
		if allPinned then pinned[lid] = nil else pinned[lid] = true end
	end
	recomputeForced()
end

function WA.ToggleForced(id)
	local leaves = {}
	collectLeaves(id, leaves)
	local allPinned = true
	for lid in pairs(leaves) do if not pinned[lid] then allPinned = false; break end end
	for lid in pairs(leaves) do
		if allPinned then pinned[lid] = nil else pinned[lid] = true end
	end
	recomputeForced()
end

-- A single leaf's config visibility for the eye: 2 = eye-pinned (stays shown
-- across selection), 1 = shown only because it's the current selection, 0 =
-- hidden/muted. Mirrors WA2's view.visibility priorities (2 eye, 1 pick, 0 off).
local function leafVis(id)
	if pinned[id] then return 2 elseif selectionLeaves[id] then return 1 else return 0 end
end

-- Eye state for rendering a row. A leaf reads leafVis directly; a group rolls up
-- its leaves the WA2 way (all shown-and-pinned -> 2, all hidden -> 0, else 1
-- partial), so the icon shows at a glance whether the whole subtree is pinned,
-- partly visible, or dark.
-- The same roll-up across several displays (a bucket header's eye).
function WA.ForcedStateMany(ids)
	local leaves = {}
	for i = 1, table.getn(ids) do collectLeaves(ids[i], leaves) end
	local count, all2, all0 = 0, 0, 0
	for lid in pairs(leaves) do
		count = count + 1
		local v = leafVis(lid)
		if v == 2 then all2 = all2 + 1 end
		if v == 0 then all0 = all0 + 1 end
	end
	if count == 0 then return 0 end
	if all2 == count then return 2 end
	if all0 == count then return 0 end
	return 1
end

function WA.ForcedState(id)
	local data = WeakestAurasDB.displays[id]
	if not data then return 0 end
	if not WA.IsGroup(data) then return leafVis(id) end
	local leaves = {}
	collectLeaves(id, leaves)
	local count, all2, all0 = 0, 0, 0
	for lid in pairs(leaves) do
		count = count + 1
		local v = leafVis(lid)
		if v == 2 then all2 = all2 + 1 end
		if v == 0 then all0 = all0 + 1 end
	end
	if count == 0 then return 0 end
	if all2 == count then return 2 end
	if all0 == count then return 0 end
	return 1
end

-- Wipe every forced contribution (options closing); retires all fakes.
function WA.ClearForced()
	pinned = {}
	selectionLeaves = {}
	recomputeForced()
end
