-- WeakestAuras -- data model: the saved aura shape, region/trigger type
-- registries (RegisterRegionType/RegisterTriggerType), and aura CRUD.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md

if WeakestAuras.disabled then return end

local WA = WeakestAuras

WeakestAurasDB.displays = WeakestAurasDB.displays or {}

-- Region types (Regions.lua) and trigger types (Triggers.lua) register themselves
-- here by name; the options window looks a data's regionType/trigger.type up in
-- these tables rather than switching on a fixed list, so adding a new display or
-- trigger kind never touches OptionsFrame.lua.
WA.regionTypes = {}
WA.triggerTypes = {}
-- Sub-region types (SubText.lua) register here; a display's data.subRegions is
-- an ordered array of instances of these (§8). Same
-- options/runtime split as region types: the spec carries defaults +
-- create/modify + a supports(regionType) gate + condition properties.
WA.subRegionTypes = {}

-- spec = { defaults = { field = value, ... }, options = function(data) return {...} end,
--          icon = "Interface\\Icons\\..." -- list-row fallback texture, used only
--          when this type registers no createThumbnail, or WA.AcquireThumbnail
--          returns nil (see OptionsFrame.lua's refreshList),
--          createThumbnail = function(parent) ... return frame end, -- optional
--          modifyThumbnail = function(frame, data) ... end }  -- optional
-- createThumbnail/modifyThumbnail are the real per-region-type preview: a small
-- frame built once and repainted per aura, pooled below rather than created per
-- row since frames on this client can't be destroyed. modifyThumbnail runs after
-- the caller has already sized the frame (WA.AcquireThumbnail), so it can read
-- back frame:GetWidth()/GetHeight() for anything that scales with the box.
function WA.RegisterRegionType(name, spec)
	WA.regionTypes[name] = spec
end

WA.thumbnailPools = {}
local function thumbnailPool(regionType)
	local pool = WA.thumbnailPools[regionType]
	if not pool then
		pool = {}
		WA.thumbnailPools[regionType] = pool
	end
	return pool
end

-- Returns a frame parented to `parent`, sized size x size, modified for `data`
-- and Shown; nil when the type registers no createThumbnail. The caller anchors
-- it. Order matters: the frame is sized BEFORE modifyThumbnail runs, since a
-- mock bar/glyph derives its fill length from the box it's already been given.
function WA.AcquireThumbnail(regionType, parent, data, size)
	local spec = WA.regionTypes[regionType]
	if not spec or not spec.createThumbnail then return nil end
	local pool = thumbnailPool(regionType)
	local frame = table.remove(pool)
	if not frame then
		frame = spec.createThumbnail(parent)
		if not frame then return nil end
		frame.thumbType = regionType
	end
	frame:SetParent(parent)
	-- A pooled frame still carries the anchor of the row it last sat on, whose
	-- frame is a live object -- the caller's own SetPoint would otherwise be
	-- laid over a point pinned to somebody else's row.
	frame:ClearAllPoints()
	frame:SetWidth(size)
	frame:SetHeight(size)
	if spec.modifyThumbnail then spec.modifyThumbnail(frame, data) end
	frame:Show()
	return frame
end

-- Hides `frame` and returns it to its own type's pool. Safe on nil. Guards
-- against inserting the same frame twice, in case a caller ever releases
-- without having reacquired in between.
function WA.ReleaseThumbnail(frame)
	if not frame then return end
	frame:Hide()
	local pool = thumbnailPool(frame.thumbType)
	for i = 1, table.getn(pool) do
		if pool[i] == frame then return end
	end
	table.insert(pool, frame)
end

-- Re-paints an already-acquired thumbnail in place, for a caller that knows
-- the frame's type hasn't changed and only needs the display's fields
-- refreshed (OptionsFrame.lua's refreshList) -- the acquire/release dance is
-- for a type change only. No-op when the type registers no modifyThumbnail or
-- frame is nil.
function WA.ModifyThumbnail(regionType, frame, data)
	if not frame then return end
	local spec = WA.regionTypes[regionType]
	if spec and spec.modifyThumbnail then spec.modifyThumbnail(frame, data) end
end

-- Read-only: how many released frames of this type are sitting in the pool
-- right now. Exists for the headless harness to assert the acquire/release
-- accounting never leaks a frame past what the visible rows need.
function WA.ThumbnailPoolSize(regionType)
	local pool = WA.thumbnailPools[regionType]
	return pool and table.getn(pool) or 0
end

-- spec = { defaults = ..., options = ..., summary = function(data) return "..." end,
--          migrate = function(trigger) ... end }
-- summary: one-line "what this watches" text for the aura list row's second line.
-- migrate: optional, in-place field-rename fixup for a saved trigger table of
-- this type (e.g. auraType -> debuffType); must be idempotent, MergeDefaults
-- runs it on every touch. This is the *options-side* registry (defaults +
-- options tab + summary per trigger.type); the *runtime* layer that actually
-- produces states is a trigger system registered via WA.RegisterTriggerSystem
-- (StateMachine.lua), mirroring upstream's triggerTypesOptions vs triggerSystems
-- split.
function WA.RegisterTriggerType(name, spec)
	WA.triggerTypes[name] = spec
end

-- spec = { displayName, supports = function(regionType) return bool end,
--          default = {...}, create = function(parent) end,
--          modify = function(parent, subRegion, parentData, subRegionData) end,
--          addDefaultsForNewAura = function(data) end, properties = {...} }
function WA.RegisterSubRegionType(name, spec)
	WA.subRegionTypes[name] = spec
end

-- Seeds a leaf display's data.subRegions with each supporting sub-region type's
-- defaults (§8: icon gets a %s stacks text, bar gets %n + %p). Run once
-- per display via the internalVersion gate in MergeDefaults, so it both
-- initializes new auras and preserves the (formerly hardcoded) text on auras
-- saved before subRegions existed, without re-adding on every load.
function WA.AddDefaultsForNewAura(data)
	if WA.IsGroup(data) then return end
	data.subRegions = data.subRegions or {}
	for _, spec in pairs(WA.subRegionTypes) do
		if spec.addDefaultsForNewAura and (not spec.supports or spec.supports(data.regionType)) then
			spec.addDefaultsForNewAura(data)
		end
	end
end

-- The trigger config table for triggernum n (data.triggers[n].trigger), or nil.
-- The options UI and summary read this instead of reaching into the array shape
-- directly.
function WA.GetTrigger(data, n)
	if not data.triggers then return nil end
	local entry = data.triggers[n]
	return entry and entry.trigger
end

-- onlyGroups: if provided (true/false), lists only types whose isGroup flag
-- matches -- used to keep an existing aura's own Region type selector from
-- offering to convert across the leaf/group boundary (see OptionsFrame.lua's
-- getInfoOptions), matching upstream WeakAuras2's own behavior: its
-- "Convert to..." menu is simply never offered for a group (always has
-- controlledChildren) and never lists group/dynamicgroup as a target for a
-- leaf, rather than handling the conversion's fallout. Omitted (nil), lists
-- every registered type regardless of category (e.g. the "+ New" picker,
-- which is free to create either kind from scratch).
-- `internal` types are never listed: `fallback` exists to stand in for a region
-- this addon does not have, so offering it as something to create or convert to
-- would be offering the absence itself.
function WA.RegionTypeList(onlyGroups)
	local list = {}
	for name, spec in pairs(WA.regionTypes) do
		if not spec.internal and (onlyGroups == nil or (spec.isGroup == true) == onlyGroups) then
			table.insert(list, name)
		end
	end
	table.sort(list)
	return list
end

-- The region spec that will actually build this display: its own type's, or the
-- `fallback` type's when the addon has no such region. An aura can name a
-- regionType we do not have -- upstream ships progresstexture, model and
-- stopmotion, all of which exist in the wild -- and nothing rejects one on
-- import, so without this it gets a row in the list and is then simply never
-- drawn, with nothing on screen to say why.
--
-- Resolved wherever a region is built rather than rewritten at import, so an aura
-- whose type we later gain starts working on its own, with no second migration.
function WA.RegionSpecFor(data)
	local spec = data and WA.regionTypes[data.regionType]
	if spec then
		if data.regionType == "progresstexture"
			and (data.orientation == "CLOCKWISE" or data.orientation == "ANTICLOCKWISE") then
			return WA.regionTypes["fallback"]
		end
		return spec
	end
	return WA.regionTypes["fallback"]
end

-- True if this aura's regionType is a container (group/dynamicgroup) rather
-- than a leaf display: it has no trigger of its own, and is addressed by id
-- in another aura's controlledChildren instead of (or as well as) WA.GetOrder().
function WA.IsGroup(data)
	local region = WA.regionTypes[data.regionType]
	return region ~= nil and region.isGroup == true
end

-- A texture value this client can actually draw, or nil for one it cannot --
-- every caller already has a placeholder for nil, so an unusable value falls
-- back to it instead of painting the engine's missing-texture block.
--
-- Two forms reach us from a WeakAuras export and neither is a file here:
--
-- * A **fileID** (a bare number, e.g. 135274). Modern clients keep a numeric
--   handle per texture and `SetTexture` accepts it; this one has no such table
--   and nothing can map it back to a path. 125 of the 160 manual icons in the
--   corpus are fileIDs, so this is the common case, not an edge one.
-- * An **atlas name** (`Legionfall_BarSpark`, `GarrMission_EncounterBar-Spark`).
--   Atlases are a retail concept with no 1.12 equivalent, and they are
--   recognisable by having no path separator -- a real texture path here always
--   has one.
--
-- A path we *can* form may still be missing (someone else's addon folder), and
-- nothing offline can tell: `SetTexture` reports nothing and `GetTexture` hands
-- back whatever string it was given. That case still draws the block.
function WA.DrawableTexture(value)
	if type(value) == "number" then return nil end
	if type(value) ~= "string" or value == "" then return nil end
	if not string.find(value, "\\", 1, true) and not string.find(value, "/", 1, true) then
		return nil
	end
	return value
end

-- Resolves the icon a leaf display currently shows: Manual mode uses
-- data.displayIcon outright; Automatic asks the first trigger that can name
-- one (WA.GetTriggerSystem's GetNameAndIcon), falling back to displayIcon.
-- nil when nothing resolves -- every caller applies its own placeholder.
-- Same rule region:UpdateIcon applies at runtime (Regions.lua); shared here so
-- the aura list row and the icon/progressbar thumbnails can't drift apart.
function WA.ResolveDisplayIcon(data)
	if WA.IsGroup(data) then return nil end
	if data.iconSource == 0 then
		return WA.DrawableTexture(data.displayIcon)
	end
	for n = 1, table.getn(data.triggers or {}) do
		local system = WA.GetTriggerSystem and WA.GetTriggerSystem(data, n)
		if system and system.GetNameAndIcon then
			local _, icon = system.GetNameAndIcon(data, n)
			icon = WA.DrawableTexture(icon)
			if icon then return icon end
		end
	end
	return WA.DrawableTexture(data.displayIcon)
end

-- A table-valued default (e.g. a group's controlledChildren = {}) must be
-- copied per-instance, not handed out by reference -- mergeMissing used to
-- assign the defaults table itself, which would leave every new aura of that
-- type sharing one physical controlledChildren array. The same trap catches
-- anything copying a whole display, so the exporter and WA.DuplicateAura share
-- this rather than each carrying their own six lines.
function WA.DeepCopy(v)
	if type(v) ~= "table" then return v end
	local copy = {}
	for k2, v2 in pairs(v) do copy[k2] = WA.DeepCopy(v2) end
	return copy
end

local function mergeMissing(target, defaults)
	if not defaults then return end
	for k, v in pairs(defaults) do
		if target[k] == nil then target[k] = WA.DeepCopy(v) end
	end
end

local function renameField(target, oldKey, newKey)
	if target[oldKey] ~= nil then
		target[newKey] = target[oldKey]
		target[oldKey] = nil
	end
end

local TEXT_REGION_RENAMES = {
	text_font = "font",
	text_size = "fontSize",
	text_flags = "outline",
	text_color = "color",
	text_justifyH = "justify",
	text_justifyV = "justifyV",
	text_spacing = "spacing",
	text_shadowColor = "shadowColor",
	text_shadowX = "shadowXOffset",
	text_shadowY = "shadowYOffset",
}
local SUBTEXT_RENAMES = {
	text_size = "text_fontSize",
	text_flags = "text_fontType",
	text_justifyH = "text_justify",
	text_shadowX = "text_shadowXOffset",
	text_shadowY = "text_shadowYOffset",
	text_anchorPoint = "anchor_point",
	text_x = "anchorXOffset",
	text_y = "anchorYOffset",
}

local function migrateConditionProperties(data)
	local conditions = data.conditions or {}
	for i = 1, table.getn(conditions) do
		local changes = conditions[i].changes or {}
		for j = 1, table.getn(changes) do
			local property = changes[j].property
			if property == "text_size" then
				changes[j].property = "fontSize"
			elseif property == "text_color" then
				changes[j].property = "color"
			else
				local _, _, prefix, suffix = string.find(property or "", "^(sub%.[0-9]+%.)(.*)$")
				if suffix == "text_size" then
					changes[j].property = prefix .. "text_fontSize"
				end
			end
		end
	end
end

-- A sub-region imported from upstream before the combined anchor was split
-- carries the anchored part where a bare point belongs ("OUTER_TOPLEFT"), which
-- SetPoint rejects outright.
local function migrateSchemaV4(data)
	local proto = WA.regionPrototype
	for i = 1, table.getn(data.subRegions or {}) do
		local subData = data.subRegions[i]
		local anchor = subData and subData.anchor_point
		if type(anchor) == "string" and not proto.IsAnchorPoint(anchor) then
			local point = proto.ResolveAnchorPoint(anchor, "CENTER")
			subData.anchor_target = subData.anchor_target or anchor
			subData.anchor_point = point
			if not proto.IsAnchorPoint(subData.self_point) then
				subData.self_point = proto.AutoSelfPoint(anchor, point, data.regionType)
			end
		end
	end
end

local function migrateSchemaV3(data)
	if data.regionType == "text" then
		for oldKey, newKey in pairs(TEXT_REGION_RENAMES) do
			renameField(data, oldKey, newKey)
		end
	end
	for i = 1, table.getn(data.subRegions or {}) do
		local subData = data.subRegions[i]
		if subData then
			for oldKey, newKey in pairs(SUBTEXT_RENAMES) do
				renameField(subData, oldKey, newKey)
			end
			if subData.tick_placement ~= nil then
				subData.tick_placements = { subData.tick_placement }
				subData.tick_placement = nil
			end
		end
	end
	if data.regionType == "progresstexture" then
		renameField(data, "cropX", "crop_x")
		renameField(data, "cropY", "crop_y")
		renameField(data, "userX", "user_x")
		renameField(data, "userY", "user_y")
	end
	migrateConditionProperties(data)
end

-- Fills in missing fields from the aura's regionType/trigger.type defaults, and
-- migrates saved data through the local schema versions (upstream's `triggers`
-- array + combination metadata, §1). Safe to call repeatedly (e.g. after
-- switching regionType, or normalizing older saved data) -- never overwrites a
-- field the user already set.
function WA.MergeDefaults(data)
	local region = WA.regionTypes[data.regionType]
	mergeMissing(data, region and region.defaults)

	if WA.IsGroup(data) then
		-- Groups combine other displays; they have no trigger of their own.
		-- Old NewAura seeded every aura (groups included) with a stray
		-- trigger/triggers table -- clear it so a group never carries one.
		data.trigger = nil
		data.triggers = nil
	else
		-- Collapse the old single `data.trigger` into triggers[1].trigger,
		-- unchanged inside (§1).
		if data.trigger then
			data.triggers = { { trigger = data.trigger } }
			data.trigger = nil
		end
		data.triggers = data.triggers or {}
		if not data.triggers[1] then data.triggers[1] = { trigger = {} } end
		if data.triggers.disjunctive == nil then data.triggers.disjunctive = "all" end
		if data.triggers.activeTriggerMode == nil then
			data.triggers.activeTriggerMode = WA.trigger_modes.first_active
		end

		for i = 1, table.getn(data.triggers) do
			local entry = data.triggers[i]
			entry.trigger = entry.trigger or {}
			entry.untrigger = entry.untrigger or {}
			entry.trigger.type = entry.trigger.type or "aura"
			local ttype = WA.triggerTypes[entry.trigger.type]
			if ttype and ttype.migrate then ttype.migrate(entry.trigger) end
			mergeMissing(entry.trigger, ttype and ttype.defaults)
		end

		-- A fixed activeTriggerMode left pointing past the end (a trigger the
		-- user deleted) self-heals back to first_active, so saved data never
		-- resolves a shown-but-nonexistent trigger -- same self-repair spirit as
		-- GetOrder (upstream clamps here too).
		local atm = data.triggers.activeTriggerMode
		if type(atm) == "number" and atm ~= WA.trigger_modes.first_active
			and (atm < 1 or atm > table.getn(data.triggers)) then
			data.triggers.activeTriggerMode = WA.trigger_modes.first_active
		end
	end

	-- Always present, even on an aura that uses none, so adding one never needs
	-- a migration pass.
	data.subRegions = data.subRegions or {}
	data.conditions = data.conditions or {}
	data.load = data.load or {}
	data.authorOptions = data.authorOptions or {}
	data.config = data.config or {}
	WA.ValidateUserConfig(data)
	data.actions = data.actions or {}
	data.actions.init = data.actions.init or {}
	data.actions.start = data.actions.start or {}
	data.actions.finish = data.actions.finish or {}
	data.animation = data.animation or {}
	data.animation.start = data.animation.start or { type = "none" }
	data.animation.main = data.animation.main or { type = "none" }
	data.animation.finish = data.animation.finish or { type = "none" }
	data.animation.start.duration_type = data.animation.start.duration_type or "seconds"
	data.animation.main.duration_type = data.animation.main.duration_type or "seconds"
	data.animation.finish.duration_type = data.animation.finish.duration_type or "seconds"

	-- Second migration (upstream's internalVersion/Modernize pattern): seed the
	-- default sub-region texts exactly once. internalVersion < 1 covers both a
	-- brand-new aura (NewAura routes through here) and one predating sub-regions,
	-- whose countdown/stacks text was hardcoded in the region -- both get the
	-- defaults, and the bump keeps them from being re-added if the user later
	-- clears every text. Depends on every RegisterSubRegionType having run, same
	-- ordering constraint NormalizeAll already relies on (see OptionsFrame.lua).
	data.internalVersion = data.internalVersion or 0
	if not WA.IsGroup(data) and data.internalVersion < 1 then
		WA.AddDefaultsForNewAura(data)
		data.internalVersion = 1
	end

	-- Third migration: position moved from a fixed
	-- CENTER/UIParent x/y to the full anchor tuple (selfPoint/anchorPoint/
	-- xOffset/yOffset). mergeMissing above already seeded the tuple defaults;
	-- carry a pre-tuple aura's old x/y onto the offsets before dropping them.
	-- A brand-new aura has no x/y, so it keeps the seeded defaults untouched.
	if not WA.IsGroup(data) and data.internalVersion < 2 then
		if data.x ~= nil then data.xOffset = data.x end
		if data.y ~= nil then data.yOffset = data.y end
		data.x = nil
		data.y = nil
		data.internalVersion = 2
	end

	if data.internalVersion < 3 then
		migrateSchemaV3(data)
		data.internalVersion = 3
	end

	if data.internalVersion < 4 then
		migrateSchemaV4(data)
		data.internalVersion = 4
	end
end

-- Re-ensures WeakestAurasDB.order is a table on every touch rather than trusting the
-- one-time `or {}` at file load up top: a SavedVariables table restored after that line
-- ran (e.g. one saved before this field existed) clobbers the whole WeakestAurasDB
-- global, wiping out that early init same as MergeDefaults re-ensures data.trigger
-- exists every call instead of assuming NewAura's initial `{}` stuck.
local function ensureOrder()
	WeakestAurasDB.order = WeakestAurasDB.order or {}
	return WeakestAurasDB.order
end

-- Addon-wide settings that belong to no single display (the mover's lock and
-- magnetism toggles). Re-ensured on every touch for the same reason
-- ensureOrder is -- a SavedVariables table restored from before this field
-- existed replaces the whole WeakestAurasDB global.
function WA.Options()
	WeakestAurasDB.options = WeakestAurasDB.options or {}
	return WeakestAurasDB.options
end

-- The ordered child-id array `id` currently sits in: its parent group's
-- controlledChildren if it has one, WeakestAurasDB.order otherwise. A dangling
-- .parent (the parent got deleted without going through WA.DeleteAura) falls
-- back to the top-level order, same as a plain unparented id -- repairOrder
-- below cleans up the inconsistency on the next read either way.
local function currentList(id)
	local data = WeakestAurasDB.displays[id]
	if data and data.parent then
		local parent = WeakestAurasDB.displays[data.parent]
		if parent then
			parent.controlledChildren = parent.controlledChildren or {}
			return parent.controlledChildren
		end
	end
	return ensureOrder()
end

local function indexOf(list, id)
	for i = 1, table.getn(list) do
		if list[i] == id then return i end
	end
	return nil
end

local function removeFromList(list, id)
	local i = indexOf(list, id)
	if i then table.remove(list, i) end
	return i
end

-- Detaches id from wherever it currently sits (its parent's controlledChildren,
-- or the top-level order) without deciding where it goes next -- the shared
-- first step of AddChildToGroup, RemoveChildFromGroup, and (for a cross-list
-- move) ReorderAura.
local function detach(id)
	local data = WeakestAurasDB.displays[id]
	removeFromList(currentList(id), id)
	if data then data.parent = nil end
end

-- Drops stale/misplaced ids from a group's controlledChildren (a child that
-- was deleted, or reparented elsewhere since this was last read), and appends
-- any child whose .parent points here but isn't listed yet. Same self-healing
-- spirit as repairOrder below, just scoped to one group's own list.
local function repairGroupChildren(groupId)
	local group = WeakestAurasDB.displays[groupId]
	if not group then return end
	group.controlledChildren = group.controlledChildren or {}
	local list = group.controlledChildren
	local seen = {}
	for i = table.getn(list), 1, -1 do
		local id = list[i]
		local child = WeakestAurasDB.displays[id]
		if not child or child.parent ~= groupId or seen[id] then
			table.remove(list, i)
		else
			seen[id] = true
		end
	end
	for id, child in pairs(WeakestAurasDB.displays) do
		if child.parent == groupId and not seen[id] then
			table.insert(list, id)
			seen[id] = true
		end
	end
end

-- Keeps WeakestAurasDB.order in sync with what's actually top-level in .displays
-- (drops ids a delete/rename left stale or that became a group's child since,
-- appends any top-level display order doesn't know about yet -- a fresh save, or
-- a DB saved before order existed), and reconciles every group's controlledChildren
-- the same way. Cheap and idempotent -- WA.GetOrder just calls it on every read
-- rather than special-casing each caller that mutates .displays or reparents a child.
local function repairOrder()
	for id, data in pairs(WeakestAurasDB.displays) do
		if WA.IsGroup(data) then repairGroupChildren(id) end
	end

	local order = ensureOrder()
	local seen = {}
	for i = table.getn(order), 1, -1 do
		local id = order[i]
		local data = WeakestAurasDB.displays[id]
		if not data or data.parent ~= nil or seen[id] then
			table.remove(order, i)
		else
			seen[id] = true
		end
	end
	for id, data in pairs(WeakestAurasDB.displays) do
		if data.parent == nil and not seen[id] then
			table.insert(order, id)
			seen[id] = true
		end
	end
end

-- The display order the aura list (OptionsFrame.lua) renders in -- a user-arranged
-- order via drag-to-reorder, not alphabetical. Top-level only; a group's own
-- controlledChildren is its children's order.
function WA.GetOrder()
	repairOrder()
	return WeakestAurasDB.order
end

-- Detaches childId from whatever group currently owns it (a no-op if it's
-- already top-level) and returns it to the end of the top-level order. Also
-- what WA.DeleteAura promotes a deleted group's children with.
function WA.RemoveChildFromGroup(childId)
	local child = WeakestAurasDB.displays[childId]
	if not child or not child.parent then return end
	local oldParent = child.parent
	detach(childId)
	table.insert(ensureOrder(), childId)
	if WA.RefreshMembership then WA.RefreshMembership(childId, oldParent, nil) end
end

-- True if candidateId is groupId itself, or nested anywhere under it via
-- controlledChildren -- guards AddChildToGroup against creating a cycle
-- (dropping a group onto its own descendant in OptionsFrame.lua's tree).
local function isSelfOrDescendant(groupId, candidateId)
	if groupId == candidateId then return true end
	local data = WeakestAurasDB.displays[groupId]
	if not data or not data.controlledChildren then return false end
	for i = 1, table.getn(data.controlledChildren) do
		if isSelfOrDescendant(data.controlledChildren[i], candidateId) then return true end
	end
	return false
end

-- Moves childId into parentId's controlledChildren, detaching it from any
-- previous group (or the top level) first. index positions it within the new
-- parent's list (1..n+1; omitted or out of range appends). See WA.ReorderAura
-- for the boundary-move version driven by drag-and-drop.
function WA.AddChildToGroup(parentId, childId, index)
	local parent = WeakestAurasDB.displays[parentId]
	local child = WeakestAurasDB.displays[childId]
	if not parent or not child or not WA.IsGroup(parent) then return end
	if isSelfOrDescendant(childId, parentId) then return end

	local oldParent = child.parent
	detach(childId)
	parent.controlledChildren = parent.controlledChildren or {}
	local list = parent.controlledChildren
	local n = table.getn(list)
	if not index or index < 1 or index > n + 1 then index = n + 1 end
	table.insert(list, index, childId)
	child.parent = parentId
	if WA.RefreshMembership then WA.RefreshMembership(childId, oldParent, parentId) end
end

-- Moves `id` to sit just before whatever currently occupies `before` (1..n+1;
-- n+1 appends) within newParentId's child list (nil = top level, i.e.
-- WeakestAurasDB.order). Handles both a same-list reorder -- OptionsFrame.lua's
-- drag-to-reorder is the only caller today, always with newParentId = nil,
-- unchanged from the flat-list behavior this replaces -- and a cross-list move
-- (dragging a child out of a group, into a different one, or between top level
-- and a group), which the aura list's group drop-targets commit through.
function WA.ReorderAura(id, newParentId, before)
	if newParentId == id then return end
	if not WeakestAurasDB.displays[id] then return end
	local oldParent = WeakestAurasDB.displays[id].parent

	local newList
	if newParentId == nil then
		newList = ensureOrder()
	else
		local parent = WeakestAurasDB.displays[newParentId]
		if not parent or not WA.IsGroup(parent) then return end
		parent.controlledChildren = parent.controlledChildren or {}
		newList = parent.controlledChildren
	end

	local oldList = currentList(id)
	local sameList = (oldList == newList)
	local from = indexOf(oldList, id)
	if not from then return end

	local n = table.getn(newList)
	if before < 1 then before = 1 elseif before > n + 1 then before = n + 1 end

	if sameList then
		if before == from or before == from + 1 then return end
		table.remove(oldList, from)
		local insertAt = before > from and before - 1 or before
		table.insert(newList, insertAt, id)
	else
		table.remove(oldList, from)
		table.insert(newList, before, id)
		WeakestAurasDB.displays[id].parent = newParentId
		if WA.RefreshMembership then WA.RefreshMembership(id, oldParent, newParentId) end
	end
end

local function newUID()
	local s = ""
	for i = 1, 8 do
		s = s .. string.format("%x", math.random(0, 15))
	end
	return s
end
-- Exposed for the importer, which regenerates a stable-across-rename uid for
-- every imported display (ImportExport.lua).
WA.NewUID = newUID

-- Hook point for the display engine to (re)build this aura's runtime state and
-- on-screen region. Defined here as a no-op purely so every options callback in
-- Regions.lua/Triggers.lua has something to call regardless of load order;
-- StateMachine.lua (loaded later, see WeakestAuras.toc) overrides this with the
-- real pAdd-lite. `data` is already the live table stored in
-- WeakestAurasDB.displays, so edits persist even before that loads.
function WA.Add(data) end

-- Mirrors WA.Add: hook point to tear down whatever runtime state/region this
-- aura was driving, called from WA.DeleteAura right before the display itself
-- is dropped. Also overridden by StateMachine.lua.
function WA.Remove(data) end

-- Hook point to re-key runtime state (triggerState, regions, scan indexes) from
-- oldId to newId after WA.RenameAura moves the display's key -- everything in
-- the engine is keyed by the display id, which is the rename. No-op until
-- StateMachine.lua overrides it.
function WA.Rename(oldId, newId) end

-- Hook points for the conditions engine (Conditions.lua overrides these):
-- LoadConditions (re)compiles a display's condition list at WA.Add time,
-- UnloadConditions tears it down at WA.Remove, RunConditions evaluates it
-- against the just-applied states, and ReleaseConditionsForClone discards
-- activation/timer bookkeeping when a pooled clone leaves a display. No-ops
-- until Conditions.lua loads, so the state machine can call them unconditionally.
-- RunConditions is declared in StateMachine.lua (its apply path is the primary
-- caller).
function WA.LoadConditions(data) end
function WA.UnloadConditions(data) end
function WA.ReleaseConditionsForClone(uid, cloneId) end

-- Hook points for the load system (Load.lua overrides these): EvalLoad returns
-- whether a display's data.load conditions currently pass (class/level/zone/
-- combat/...), EvalLoadStatic the same with the moment-dependent ones skipped
-- (the Standby label). No-op defaults return true, so before Load.lua loads
-- (and for a display with no load conditions) "loaded = added".
function WA.EvalLoad(data) return true end
function WA.EvalLoadStatic(data) return true end

-- Hook point for an option `set` to re-render the current options tab -- used by
-- toggles that reveal/hide dependent fields (e.g. "Use stacks" showing the
-- operator+value row), where a plain WA.Add persists the value but the tab needs
-- rebuilding to show the newly-relevant controls. No-op until OptionsFrame.lua
-- overrides it with its refreshTabContent; harmless when the window is closed.
function WA.RefreshOptions() end

-- The group that would own an aura created against targetId: the target itself
-- when it's a group, the target's parent when it's a leaf, nil for top level.
function WA.PlacementParent(targetId)
	local target = targetId and WeakestAurasDB.displays[targetId]
	if not target then return nil end
	if WA.IsGroup(target) then return targetId end
	return target.parent
end

-- Whether a display of regionType may be placed against targetId. A dynamic
-- group arranges its children itself and can't own a nested group -- the one
-- placement refused outright, so a caller offering the type (the aura list's
-- New picker) asks here before offering it rather than creating and discarding.
function WA.CanPlaceAura(regionType, targetId)
	local spec = WA.regionTypes[regionType]
	if not spec then return false end
	if spec.isGroup ~= true then return true end
	local parentId = WA.PlacementParent(targetId)
	local parent = parentId and WeakestAurasDB.displays[parentId]
	return not (parent and parent.regionType == "dynamicgroup")
end

-- Moves an already-registered display to where a creation targeted at targetId
-- belongs: into targetId when it's a group, immediately after it when it's a
-- leaf, the end of the top level with no target. Shared by WA.NewAura and any
-- other "put this one beside that one" caller.
-- `data` must already be in WeakestAurasDB.displays *and* in some sibling list
-- -- the move runs through WA.ReorderAura, which does nothing for an id it
-- can't find. WA.NewAura appends top-level before calling this for that reason.
function WA.PlaceAura(data, targetId)
	if not data or WeakestAurasDB.displays[data.id] ~= data then return nil end
	if targetId == data.id then return data end
	if not WA.CanPlaceAura(data.regionType, targetId) then return nil end

	local target = targetId and WeakestAurasDB.displays[targetId]
	if not target then
		WA.ReorderAura(data.id, nil, table.getn(ensureOrder()) + 1)
		return data
	end

	local parentId = WA.PlacementParent(targetId)
	if parentId and isSelfOrDescendant(data.id, parentId) then return nil end

	if WA.IsGroup(target) then
		WA.AddChildToGroup(targetId, data.id)
	else
		local list = currentList(targetId)
		local at = indexOf(list, targetId)
		WA.ReorderAura(data.id, target.parent, at and at + 1 or table.getn(list) + 1)
	end
	return data
end

-- The first free id of the form "Base", "Base 2", "Base 3", ... -- the naming
-- rule new auras, imports and duplicates all name themselves by.
function WA.UniqueId(base)
	local id, n = base, 1
	while WeakestAurasDB.displays[id] do
		n = n + 1
		id = base .. " " .. n
	end
	return id
end

function WA.NewAura(regionType, targetId)
	regionType = regionType or "icon"
	local spec = WA.regionTypes[regionType]
	if not spec or spec.internal then return nil end
	if not WA.CanPlaceAura(regionType, targetId) then return nil end

	local id = WA.UniqueId("New Aura")

	-- No trigger seeded here: MergeDefaults builds the triggers array (or leaves
	-- it nil for a group), so both a fresh aura and older saved data take the
	-- one code path.
	local data = { id = id, uid = newUID(), regionType = regionType }
	WA.MergeDefaults(data)
	WeakestAurasDB.displays[id] = data
	table.insert(ensureOrder(), id)
	WA.PlaceAura(data, targetId)
	return data
end

-- A copy's name: bump a trailing number when the source has one
-- ("Rejuvenation 2" -> "Rejuvenation 3"), otherwise fall back to the shared
-- suffixing rule. `^(.-)(%d+)$` needs the non-greedy head, or "Aura 19" would
-- split as "Aura 1" + "9"; string.find returns the captures after its indices,
-- there being no string.match on this client.
local function duplicateId(id)
	local _, _, base, digits = string.find(id, "^(.-)(%d+)$")
	if not base then return WA.UniqueId(id) end
	local n = tonumber(digits)
	local candidate = base .. (n + 1)
	while WeakestAurasDB.displays[candidate] do
		n = n + 1
		candidate = base .. (n + 1)
	end
	return candidate
end

-- One display copied to a fresh id/uid at top level, carrying no children and
-- no parent -- duplicateTree places it.
local function copyDisplay(data)
	local copy = WA.DeepCopy(data)
	copy.id = duplicateId(data.id)
	copy.uid = newUID()
	copy.parent = nil
	copy.controlledChildren = WA.IsGroup(data) and {} or nil
	WeakestAurasDB.displays[copy.id] = copy
	table.insert(ensureOrder(), copy.id)
	return copy
end

local function duplicateTree(data)
	local copy = copyDisplay(data)
	local children = data.controlledChildren
	if children then
		for i = 1, table.getn(children) do
			local child = WeakestAurasDB.displays[children[i]]
			if child then WA.AddChildToGroup(copy.id, duplicateTree(child).id) end
		end
	end
	return copy
end

local function addTree(data)
	WA.Add(data)
	local children = data.controlledChildren
	if children then
		for i = 1, table.getn(children) do
			local child = WeakestAurasDB.displays[children[i]]
			if child then addTree(child) end
		end
	end
end

-- Copies `id`, placing the copy directly after the original among its siblings.
-- Groups copy recursively: upstream leaves that to its display-button layer,
-- which has no counterpart here, and a group duplicate that came out empty
-- would read as a bug. The whole tree is built before anything is added, so no
-- region is created against a half-assembled hierarchy. Returns the new id.
function WA.DuplicateAura(id)
	local data = WeakestAurasDB.displays[id]
	if not data then return nil end

	local copy = duplicateTree(data)
	local list = currentList(id)
	local at = indexOf(list, id)
	if data.parent then
		WA.AddChildToGroup(data.parent, copy.id, at and at + 1 or nil)
	elseif at then
		WA.ReorderAura(copy.id, nil, at + 1)
	end

	addTree(copy)
	return copy.id
end

-- Appends a new trigger (defaulting to an "aura" type) to a leaf display's
-- triggers array and seeds its defaults via MergeDefaults; returns the new
-- trigger's index. A group has no triggers, so it's a no-op there. The caller
-- runs WA.Add (StateMachine recompiles the whole triggers array).
function WA.AddTrigger(data)
	if WA.IsGroup(data) then return nil end
	data.triggers = data.triggers or {}
	table.insert(data.triggers, { trigger = { type = "aura" } })
	WA.MergeDefaults(data)
	return table.getn(data.triggers)
end

-- Removes trigger n. Refuses to drop the last one (an aura always needs at
-- least trigger 1); MergeDefaults re-clamps a now-dangling activeTriggerMode.
-- The array reindexes implicitly (table.remove), so trigger n+1 becomes n --
-- the combination core keys everything by position, so nothing else needs
-- renumbering.
function WA.DeleteTrigger(data, n)
	if not data.triggers or table.getn(data.triggers) <= 1 then return end
	table.remove(data.triggers, n)
	WA.MergeDefaults(data)
end

-- Deleting a group ungroups its children (promotes them to top-level) rather
-- than cascading the delete -- the less-destructive default, matching the
-- aura list's two-click delete confirm.
function WA.DeleteAura(id)
	local data = WeakestAurasDB.displays[id]
	if not data then return end
	for _, other in pairs(WeakestAurasDB.displays) do
		if other.anchorFrameType == "SELECTFRAME"
			and other.anchorFrameFrame == "WeakestAuras:" .. id then
			other.anchorFrameFrame = nil
			other.anchorFrameType = "UIPARENT"
			WA.Add(other, true)
		end
	end

	if WA.IsGroup(data) and data.controlledChildren then
		-- Snapshot first: RemoveChildFromGroup mutates controlledChildren as
		-- it goes, which would skip entries if we iterated the live array.
		local children = {}
		for i = 1, table.getn(data.controlledChildren) do
			children[i] = data.controlledChildren[i]
		end
		for i = 1, table.getn(children) do
			WA.RemoveChildFromGroup(children[i])
		end
	end

	detach(id)
	WA.Remove(data)
	if WA.ClearWarningsFor then WA.ClearWarningsFor(data.uid) end
	WeakestAurasDB.displays[id] = nil
end

-- Deletes a group *with* everything under it, the cascading counterpart to
-- WA.DeleteAura's promote-the-children default. The descendant set is
-- snapshotted before any of it is deleted, for the same reason DeleteAura
-- snapshots controlledChildren: the remove path mutates the lists this would
-- otherwise be walking. Post-order, so no group is deleted while it still
-- believes it has children.
function WA.DeleteAuraTree(id)
	if not WeakestAurasDB.displays[id] then return end

	local doomed = {}
	local function collect(current)
		local data = WeakestAurasDB.displays[current]
		if not data then return end
		local children = data.controlledChildren
		for i = 1, table.getn(children or {}) do collect(children[i]) end
		table.insert(doomed, current)
	end
	collect(id)

	for i = 1, table.getn(doomed) do WA.DeleteAura(doomed[i]) end
end

-- Renames the display, moving it to the new key. Returns false (no-op) if the
-- name is blank or already taken.
function WA.RenameAura(id, newId)
	if not newId or newId == "" or newId == id then return false end
	if WeakestAurasDB.displays[newId] then return false end
	local data = WeakestAurasDB.displays[id]
	if not data then return false end
	local dependants = {}
	for _, other in pairs(WeakestAurasDB.displays) do
		if other.anchorFrameType == "SELECTFRAME"
			and other.anchorFrameFrame == "WeakestAuras:" .. id then
			table.insert(dependants, other)
		end
	end
	data.id = newId
	WeakestAurasDB.displays[id] = nil
	WeakestAurasDB.displays[newId] = data

	-- id doubles as the display's key in .displays, so every other place that
	-- references this one by id string -- its parent's controlledChildren
	-- entry, or (if this is a group) each child's own .parent -- needs
	-- repointing too, not just the top-level order below.
	if data.parent then
		local parent = WeakestAurasDB.displays[data.parent]
		if parent and parent.controlledChildren then
			local i = indexOf(parent.controlledChildren, id)
			if i then parent.controlledChildren[i] = newId end
		end
	end
	if data.controlledChildren then
		for i = 1, table.getn(data.controlledChildren) do
			local child = WeakestAurasDB.displays[data.controlledChildren[i]]
			if child then child.parent = newId end
		end
	end

	local order = ensureOrder()
	for i = 1, table.getn(order) do
		if order[i] == id then
			order[i] = newId
			break
		end
	end

	-- Re-key the engine's runtime state to match the new id (no-op stub until
	-- StateMachine.lua loads).
	WA.Rename(id, newId)
	for i = 1, table.getn(dependants) do
		local other = dependants[i]
		other.anchorFrameFrame = "WeakestAuras:" .. newId
		WA.Add(other, true)
	end
	return true
end

-- Normalizes every saved aura against the currently-registered region/trigger
-- types. Must run only after all RegisterRegionType/RegisterTriggerType calls
-- have happened -- see the call site in OptionsFrame.lua (the last file loaded)
-- for why it doesn't just run here at file load.
--
-- safecall-wrapped per aura: this runs unconditionally before
-- WA.AddAllDisplays (same call site, OptionsFrame.lua's last two lines), so an
-- unguarded error on one malformed aura previously aborted the whole loop --
-- silently, since nothing here printed -- and with it every *other* aura's
-- WA.Add for the rest of the session (AddAllDisplays never got reached).
function WA.NormalizeAll()
	for id, data in pairs(WeakestAurasDB.displays) do
		WA.safecall(id, WA.MergeDefaults, data)
	end
end
