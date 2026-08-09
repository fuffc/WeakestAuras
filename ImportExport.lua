-- WeakestAuras -- copy-paste import/export of displays. Rides ClassicAPI's
-- C_EncodingUtil (SerializeCBOR -> CompressString(zlib) -> EncodeBase64 and the
-- three inverses), the exact chain pfUI's share.lua uses live on this client --
-- so WA2's Transmission.lua (LibSerialize + LibDeflate + custom base64) is
-- unnecessary. CBOR deserializes to plain data, so nothing here executes what it
-- decodes; what it must also not do is *hand* the engine a field the engine will
-- loadstring, which is what dropCode below enforces in both directions. Do NOT
-- add a Lua-source import path.
--
-- One field is knowingly outside that guard: a generic trigger's `customTrigger`
-- still travels, because sharing a custom trigger is the point of having one.
-- Receiving an aura is therefore a data-trust question for everything except
-- that -- see design/plans/SHARING_PLAN.md and drift.md §D2.
--
-- C_EncodingUtil is undocumented in ClassicAPI's API.md (present at runtime,
-- pfUI depends on it), so its presence is probed at load and import/export
-- degrades gracefully (buttons disabled / clear message) if a build lacks it.

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

-- Fields the engine would loadstring, removed from a display. The text region's
-- customText is one, and it never travels: the receiving side would compile a
-- stranger's Lua. Enforced on the way in as well as stripped on the way out,
-- since a transport string can be assembled by hand.
local function dropCode(display)
	if type(display) ~= "table" then return end
	display.customText = nil
end

-- Reverses encode; nil on a foreign/garbage/truncated string. The !WA1! prefix
-- both identifies our format and lets this reject pfUI/WA2 strings cleanly.
-- Every import path decodes here, which is why the code strip lives here too.
local function decode(text)
	if not text then return nil end
	text = string.gsub(text, "%s", "")
	if string.sub(text, 1, string.len(MAGIC)) ~= MAGIC then return nil end
	local ok, result = pcall(function()
		return E.DeserializeCBOR(E.DecompressString(E.DecodeBase64(string.sub(text, string.len(MAGIC) + 1))))
	end)
	if not ok or type(result) ~= "table" then return nil end
	dropCode(result.d)
	if type(result.c) == "table" then
		for i = 1, table.getn(result.c) do dropCode(result.c[i]) end
	end
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
	dropCode(c)
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

-- The id of the display this string is another copy of, plus whether it can be
-- updated in place. Lets the import dialog say so before anything is installed.
-- Groups answer false: replacing one means reconciling its children against the
-- incoming set, and a child held here but missing from the import has no safe
-- default -- keeping it leaves a stale aura, deleting it is irreversible.
function WA.ImportInfo(str)
	if not WA.hasImportExport then return nil end
	local payload = decode(str)
	if not payload or type(payload.d) ~= "table" then return nil end
	local id = WA.FindByUID(payload.d.uid)
	if not id then return nil end
	local target = WeakestAurasDB.displays[id]
	local canUpdate = not (WA.IsGroup(target) or WA.IsGroup(payload.d)
		or type(payload.c) == "table")
	return id, canUpdate
end

-- Fields an update keeps from the display it replaces. Position and size are
-- yours rather than the author's -- upstream defaults its "Size & Position"
-- category off for the same reason -- and the id stays so an update never
-- renames an aura out from under the list. Everything else is replaced.
local UPDATE_PRESERVED = {
	id = true, uid = true, parent = true, controlledChildren = true,
	anchorFrameType = true, anchorFrameFrame = true, anchorFrameParent = true,
	selfPoint = true, anchorPoint = true,
	xOffset = true, yOffset = true, frameStrata = true,
	scale = true, width = true, height = true,
}

-- Replaces the display this string is a copy of, in place. Destructive by
-- design and only ever reached from its own button. The existing table is
-- mutated rather than swapped out, because the region and trigger state are
-- bound to it; WA.Add then recompiles it exactly as any options edit would.
function WA.ImportOverwrite(str)
	if not WA.hasImportExport then return nil, "C_EncodingUtil is not available on this client" end
	local payload = decode(str)
	if not payload then return nil, "not a WeakestAuras export string" end
	if payload.m ~= "WeakestAuras" or type(payload.d) ~= "table" then
		return nil, "unrecognized or wrong-format string"
	end

	local targetId, canUpdate = WA.ImportInfo(str)
	if not targetId then return nil, "no aura here matches that one" end
	if not canUpdate then return nil, "groups cannot be updated in place" end

	local target = WeakestAurasDB.displays[targetId]
	local incoming = payload.d
	for k in pairs(target) do
		if not UPDATE_PRESERVED[k] then target[k] = nil end
	end
	for k, v in pairs(incoming) do
		if not UPDATE_PRESERVED[k] then target[k] = v end
	end
	WA.MergeDefaults(target)
	WA.Add(target)
	return targetId
end

-- Installs one imported display: fresh non-colliding id, stored, then
-- MergeDefaults (fills fields the exporter's version lacked, runs trigger
-- migrate; internalVersion-gated so a newer exporter's fields survive and an
-- older one's get defaulted). Returns the new id. Importing "Foo" twice never
-- overwrites: WA.UniqueId gives the second one "Foo 2".
local function installDisplay(data, parentId)
	local base = data.id
	if not base or base == "" then base = "Imported" end
	local newId = WA.UniqueId(base)
	data.id = newId
	-- Identity survives the import, so a later one can be recognised as the same
	-- aura. A uid already held here means this is a deliberate second copy and
	-- gets a fresh one instead: Conditions.lua keys its compiled state by uid, so
	-- two displays sharing one would overwrite each other's condition state.
	if not data.uid or WA.FindByUID(data.uid) then
		data.uid = WA.NewUID()
	end
	data.parent = parentId
	WeakestAurasDB.displays[newId] = data
	WA.MergeDefaults(data)
	return newId
end

-- Imports a transport string into a new display, live (WA.Add builds runtime
-- state + region immediately -- no reload). Returns the new id, or nil + reason.
-- No loadstring anywhere: the payload is data the engine consumes, never code.
function WA.Import(str)
	if not WA.hasImportExport then return nil, "C_EncodingUtil is not available on this client" end
	local payload = decode(str)
	if not payload then return nil, "not a WeakestAuras export string" end
	if payload.m ~= "WeakestAuras" or type(payload.d) ~= "table" then
		return nil, "unrecognized or wrong-format string"
	end

	local root = payload.d
	local newId = installDisplay(root, nil)
	-- GetOrder self-heals: it appends any top-level display order doesn't know
	-- about yet, so a fresh import lands at the end of the list on next read.
	WA.GetOrder()

	if type(payload.c) == "table" and WA.IsGroup(root) then
		root.controlledChildren = {}
		local imported = { root }
		for i = 1, table.getn(payload.c) do
			local child = payload.c[i]
			local childId = installDisplay(child, newId)
			table.insert(root.controlledChildren, childId)
			table.insert(imported, child)
		end
		WA.AddMany(imported)
	else
		WA.Add(root)
	end
	return newId
end
