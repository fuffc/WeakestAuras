-- WeakestAuras -- copy-paste transport and reviewed display installation.
-- C_EncodingUtil handles the local format; WA2 uses the transport helpers below.
if WeakestAuras.disabled then return end

local WA = WeakestAuras

local MAGIC = "!WA1!"

-- Present only if the whole CBOR chain this file needs is available.
local E = C_EncodingUtil
WA.hasImportExport =
	E ~= nil and E.SerializeCBOR ~= nil and E.DeserializeCBOR ~= nil
	and E.CompressString ~= nil and E.DecompressString ~= nil
	and E.EncodeBase64 ~= nil and E.DecodeBase64 ~= nil

-- EditBoxes don't soft-wrap one unbroken line; chunk the blob (share.lua:36).
local function wrap(str, width)
	local out = {}
	for i = 1, string.len(str), width do
		table.insert(out, string.sub(str, i, i + width - 1))
	end
	return table.concat(out, "\n")
end

local function encodeBody(payload)
	return E.EncodeBase64(E.CompressString(E.SerializeCBOR(payload)))
end

-- Which addon's export format a pasted string is, by prefix alone: "wa1"
-- (ours), "wa2" (WeakAuras 2, !WA:2!), "wa2legacy" (WeakAuras' pre-2020 format,
-- a bare leading !), or nil for anything else.
--
-- Order is load-bearing: !WA1! also begins with the bare ! the legacy format is
-- recognised by, so ours has to be tested first or every WeakestAuras string
-- classifies as a decade-old WeakAuras one.
function WA.ClassifyImport(text)
	if type(text) ~= "string" then return nil end
	text = string.gsub(text, "%s", "")
	if string.sub(text, 1, string.len(MAGIC)) == MAGIC then return "wa1" end
	if string.find(text, "^!WA:%d+!") then return "wa2" end
	if string.sub(text, 1, 1) == "!" then return "wa2legacy" end
	return nil
end

-- Why a paste this file cannot read is unreadable, phrased for someone holding
-- a string they got from a website. "Not a WeakestAuras export string" is true
-- of a wago.io string and reads as "yours is corrupt", which sends people to
-- re-copy a string that was never going to work.
-- Kept short enough to wrap to two lines in the import dialog's status area
-- rather than three; naming wago.io is what tells someone holding one of its
-- strings why theirs is not corrupt.
local CLASSIFY_REFUSAL = {
	wa2 = "that is a WeakAuras string (wago.io). WeakestAuras cannot import those.",
	wa2legacy = "that is a very old WeakAuras string. Re-export it from a current WeakAuras.",
}

-- Reverses encode; nil on a foreign/garbage/truncated string. The !WA1! prefix
-- both identifies our format and lets this reject pfUI/WA2 strings cleanly.
local function decode(text)
	if not text then return nil end
	text = string.gsub(text, "%s", "")
	if string.sub(text, 1, string.len(MAGIC)) ~= MAGIC then return nil end
	local ok, result = pcall(function()
		return E.DeserializeCBOR(E.DecompressString(E.DecodeBase64(string.sub(text, string.len(MAGIC) + 1))))
	end)
	if not ok or type(result) ~= "table" then return nil end
	return result
end

-- A deep copy with the non-transmissible fields stripped (WA2's
-- stripNonTransmissableFields): parent (re-derived on import),
-- controlledChildren (children travel in payload.c and get fresh ids). `id`
-- stays (the suggested name); internalVersion stays (the importer's
-- MergeDefaults migration reads it). `uid` travels too, as it does upstream:
-- it is the only thing that lets a later import be recognised as the same aura
-- rather than an anonymous duplicate.
local function cleanForExport(data)
	local c = WA.DeepCopy(data)
	c.parent = nil
	c.controlledChildren = nil
	return c
end

-- A display's data as one unwrapped transport string, or nil + reason. Groups
-- bring their direct children in payload.c. Nested-group export is deliberately
-- shallow: a child that is itself a group loses its own children
-- (controlledChildren stripped), the flat single-level group being the common
-- case -- revisit with recursion if nested groups become one.
function WA.ExportRaw(id)
	if not WA.hasImportExport then return nil, "C_EncodingUtil is not available on this client" end
	local data = WeakestAurasDB.displays[id]
	if not data then return nil, "no such display: " .. tostring(id) end

	local payload = { m = "WeakestAuras", v = WA.version, d = cleanForExport(data) }
	if WA.IsGroup(data) and data.controlledChildren then
		payload.c = {}
		for i = 1, table.getn(data.controlledChildren) do
			local child = WeakestAurasDB.displays[data.controlledChildren[i]]
			if child then table.insert(payload.c, cleanForExport(child)) end
		end
	end

	local ok, body = pcall(encodeBody, payload)
	if not ok then return nil, "serialization failed: " .. tostring(body) end
	return MAGIC .. body
end

-- The same string wrapped for an EditBox. The wrap belongs to the display of an
-- export and not to the format -- newlines through the chat system are wasteful
-- at best -- so anything transporting one uses WA.ExportRaw and this stays the
-- only place that knows the column.
function WA.Export(id)
	local raw, err = WA.ExportRaw(id)
	if not raw then return nil, err end
	return MAGIC .. wrap(string.sub(raw, string.len(MAGIC) + 1), 92)
end

-- The id of the display holding this uid, if any. uids are unique inside the
-- database because installDisplay regenerates any incoming one already taken.
function WA.FindByUID(uid)
	if not uid then return nil end
	for id, d in pairs(WeakestAurasDB.displays) do
		if d.uid == uid then return id end
	end
	return nil
end

local UPDATE_PRESERVED = {
	id = true, uid = true, parent = true, controlledChildren = true,
	anchorFrameType = true, anchorFrameFrame = true, anchorFrameParent = true,
	selfPoint = true, anchorPoint = true,
	xOffset = true, yOffset = true, frameStrata = true,
	scale = true, width = true, height = true,
}

local function importReport(reason)
	return { created = {}, dropped = {}, code = {}, refused = reason }
end

local function localPending(payload)
	if type(payload) ~= "table" or payload.m ~= "WeakestAuras"
		or type(payload.d) ~= "table" then
		return nil, "unrecognized or wrong-format string"
	end
	local root = WA.DeepCopy(payload.d)
	local children = {}
	root.parent = nil
	root.controlledChildren = nil
	if payload.c ~= nil then
		if type(payload.c) ~= "table" or not WA.IsGroup(root) then
			return nil, "child displays require a group root"
		end
		for i = 1, table.getn(payload.c) do
			if type(payload.c[i]) ~= "table" then
				return nil, "child display " .. i .. " is not a table"
			end
			local child = WA.DeepCopy(payload.c[i])
			child.parent = nil
			child.controlledChildren = nil
			table.insert(children, child)
		end
	end
	return { root = root, children = children }
end

local function decodeWA2(text)
	local bytes, err = WA.WA2Decode(text)
	if not bytes then return nil, err end
	local payload, why = WA.WA2Deserialize(bytes)
	if not payload then return nil, why end
	return payload
end

function WA.ImportPreview(str)
	local class = WA.ClassifyImport(str)
	local refusal = class == "wa2legacy" and CLASSIFY_REFUSAL[class] or nil
	if refusal then return nil, importReport(refusal) end
	if class == "wa1" then
		local payload = decode(str)
		if not payload then return nil, importReport("not a WeakestAuras export string") end
		local pending, why = localPending(payload)
		if not pending then return nil, importReport(why) end
		local report = importReport(nil)
		WA.CollectImportCode(pending.root, report, tostring(pending.root.id or "?") .. " - ")
		for i = 1, table.getn(pending.children) do
			local child = pending.children[i]
			WA.CollectImportCode(child, report, tostring(child.id or "?") .. " - ")
		end
		report.format = class
		return pending, report
	end
	if class == "wa2" then
		local payload, why = decodeWA2(str)
		if not payload then
			return nil, importReport("WeakAuras string could not be imported: " .. tostring(why))
		end
		local pending, report = WA.WA2Translate(payload)
		report.format = class
		return pending, report
	end
	return nil, importReport("not a WeakestAuras export string")
end

local function canUpdatePending(pending)
	return pending and pending.root and not WA.IsGroup(pending.root)
		and table.getn(pending.children or {}) == 0
end

local function removeId(list, id)
	for i = table.getn(list or {}), 1, -1 do
		if list[i] == id then table.remove(list, i) end
	end
end

local function installOne(data, parentId)
	local base = data.id
	if not base or base == "" then base = "Imported" end
	local newId = WA.UniqueId(base)
	data.id = newId
	if not data.uid or WA.FindByUID(data.uid) then data.uid = WA.NewUID() end
	data.parent = parentId
	data.internalVersion = 4
	WeakestAurasDB.displays[newId] = data
	local ok, err = pcall(WA.MergeDefaults, data)
	if not ok then
		WeakestAurasDB.displays[newId] = nil
		error(err, 0)
	end
	return newId
end

local function rollbackInstalled(installed)
	for i = table.getn(installed), 1, -1 do
		local data = installed[i]
		if data.parent then
			local parent = WeakestAurasDB.displays[data.parent]
			if parent then removeId(parent.controlledChildren, data.id) end
		else
			removeId(WeakestAurasDB.order, data.id)
		end
		WeakestAurasDB.displays[data.id] = nil
	end
end

-- A dynamic group's sortHybridTable names its children by id, and every id in an
-- import is reassigned by WA.UniqueId. Keys naming a display that travelled in
-- this same import move with it; anything else is a stale key the author's own
-- profile carried and is left exactly as it arrived.
--
-- An anchor reference (`WeakestAuras:<id>`) is the same problem seen from the
-- other side, and it has to be repaired here rather than at translation time:
-- a display can be anchored to one installed *after* it -- the corpus's
-- ComboFill1 anchors to a Cback1 that arrives twenty displays later -- so the
-- map is only complete once the whole pack is in.
-- A glow aimed at another display names it the same way an anchor does, so it
-- needs the same repair -- in both places one can be written: the show/hide
-- action blocks, and any `glowexternal` condition change.
local function remapGlowFrame(block, byOldId)
	if type(block) ~= "table" or block.glow_frame_type ~= "FRAMESELECTOR" then return end
	if type(block.glow_frame) ~= "string" then return end
	local prefix = WA.ANCHOR_AURA_PREFIX
	local _, _, oldId = string.find(block.glow_frame, "^" .. prefix .. "(.+)$")
	if oldId and byOldId[oldId] then
		block.glow_frame = prefix .. byOldId[oldId]
	end
end

local function remapGlowFrames(data, byOldId)
	local actions = data.actions
	if type(actions) == "table" then
		for _, phase in ipairs({ "init", "start", "finish" }) do
			remapGlowFrame(actions[phase], byOldId)
		end
	end
	local conditions = data.conditions
	for n = 1, table.getn(conditions or {}) do
		local changes = conditions[n] and conditions[n].changes or {}
		for c = 1, table.getn(changes) do
			if changes[c] and changes[c].property == "glowexternal" then
				remapGlowFrame(changes[c].value, byOldId)
			end
		end
	end
end

local function remapChildIdKeys(installed, byOldId)
	local prefix = WA.ANCHOR_AURA_PREFIX
	for i = 1, table.getn(installed) do
		local data = installed[i]
		if type(data.sortHybridTable) == "table" then
			local remapped = {}
			for oldId, value in pairs(data.sortHybridTable) do
				remapped[byOldId[oldId] or oldId] = value
			end
			data.sortHybridTable = remapped
		end
		if data.anchorFrameType == "SELECTFRAME" and type(data.anchorFrameFrame) == "string" then
			local _, _, oldId = string.find(data.anchorFrameFrame, "^" .. prefix .. "(.+)$")
			-- Only an id that travelled in this import is rewritten. One naming a
			-- display already here is the user's own aura and is left alone; one
			-- naming neither is a stale reference from the sender's profile, and
			-- inventing a target for it would anchor the display to a stranger.
			if oldId and byOldId[oldId] then
				data.anchorFrameFrame = prefix .. byOldId[oldId]
			end
		end
		remapGlowFrames(data, byOldId)
	end
end

function WA.InstallPendingImport(pending)
	if type(pending) ~= "table" or type(pending.root) ~= "table" then
		return nil, "no pending import"
	end
	if pending.confirmed then return nil, "import already confirmed" end
	local root, children = pending.root, pending.children or {}
	if table.getn(children) > 0 and not WA.IsGroup(root) then
		return nil, "child displays require a group root"
	end
	local installed = {}
	local ok, rootId = pcall(function()
		WA.GetOrder()
		-- A child's `parent` still names its group by the id it had in the export;
		-- the map is what turns that into the id it was just given here. The list
		-- is ordered parents-first, so a parent is always already in the map.
		local byOldId = {}
		local rootOldId = root.id
		local id = installOne(root, nil)
		table.insert(installed, root)
		table.insert(WeakestAurasDB.order, id)
		byOldId[rootOldId] = id
		for i = 1, table.getn(children) do
			local child = children[i]
			local oldId, parentId = child.id, byOldId[child.parent] or id
			child.parent = nil
			local childId = installOne(child, nil)
			table.insert(installed, child)
			table.insert(WeakestAurasDB.order, childId)
			byOldId[oldId] = childId
			-- Reparenting through the primitive rather than writing the arrays:
			-- it owns detach, the cycle guard and RefreshMembership. It answers
			-- nothing, so the placement is read back rather than assumed.
			WA.AddChildToGroup(parentId, childId)
			if WeakestAurasDB.displays[childId].parent ~= parentId then
				error("\"" .. childId .. "\" could not be placed in \"" .. parentId .. "\"", 0)
			end
		end
		remapChildIdKeys(installed, byOldId)
		WA.GetOrder()
		WA.AddMany(installed)
		return id
	end)
	if not ok then
		rollbackInstalled(installed)
		return nil, tostring(rootId)
	end
	pending.confirmed = rootId
	return rootId
end

function WA.UpdatePendingImport(pending, targetId)
	if not canUpdatePending(pending) then return nil, "groups cannot be updated in place" end
	local target = WeakestAurasDB.displays[targetId]
	if not target then return nil, "no aura here matches that one" end
	local incoming = pending.root
	local original = WA.DeepCopy(target)
	for key in pairs(target) do
		if not UPDATE_PRESERVED[key] then target[key] = nil end
	end
	for key, value in pairs(incoming) do
		if not UPDATE_PRESERVED[key] then target[key] = WA.DeepCopy(value) end
	end
	target.id, target.uid, target.parent = targetId, original.uid, original.parent
	target.internalVersion = 4
	local ok, err = pcall(WA.MergeDefaults, target)
	if not ok then
		for key in pairs(target) do target[key] = nil end
		for key, value in pairs(original) do target[key] = value end
		return nil, tostring(err)
	end
	WA.Add(target)
	pending.confirmed = targetId
	return targetId
end

function WA.ConfirmImport(pending, mode, targetId)
	if mode == "update" then return WA.UpdatePendingImport(pending, targetId) end
	return WA.InstallPendingImport(pending)
end

function WA.ImportInfo(str)
	if not WA.hasImportExport then return nil end
	local pending, report = WA.ImportPreview(str)
	if not pending or report.refused then return nil end
	local id = WA.FindByUID(pending.root.uid)
	if not id then return nil end
	return id, canUpdatePending(pending)
end

function WA.ImportOverwrite(str)
	if not WA.hasImportExport then return nil, "C_EncodingUtil is not available on this client" end
	local class = WA.ClassifyImport(str)
	if class == "wa2legacy" then return nil, CLASSIFY_REFUSAL[class] end
	local pending, report = WA.ImportPreview(str)
	if not pending or report.refused then return nil, report.refused or "not a WeakestAuras export string" end
	local targetId = WA.FindByUID(pending.root.uid)
	if not targetId then return nil, "no aura here matches that one" end
	return WA.UpdatePendingImport(pending, targetId)
end

function WA.Import(str)
	if not WA.hasImportExport then return nil, "C_EncodingUtil is not available on this client" end
	local pending, report = WA.ImportPreview(str)
	if not pending or report.refused then return nil, report.refused or "not a WeakestAuras export string" end
	return WA.InstallPendingImport(pending)
end
