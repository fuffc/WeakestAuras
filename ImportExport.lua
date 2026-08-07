-- WeakestAuras -- copy-paste import/export of displays. Rides ClassicAPI's
-- C_EncodingUtil (SerializeCBOR -> CompressString(zlib) -> EncodeBase64 and the
-- three inverses), the exact chain pfUI's share.lua uses live on this client --
-- so WA2's Transmission.lua (LibSerialize + LibDeflate + custom base64) is
-- unnecessary. Because CBOR deserializes to plain data that the engine consumes
-- (never loadstring'd), a pasted string can carry data but never code -- the
-- security property to preserve: do NOT add a Lua-source import path.
--
-- C_EncodingUtil is undocumented in ClassicAPI's API.md (present at runtime,
-- pfUI depends on it), so its presence is probed at load and import/export
-- degrades gracefully (buttons disabled / clear message) if a build lacks it.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local MAGIC = "!WA1!"
local ADDON_VERSION = (GetAddOnMetadata and GetAddOnMetadata("WeakestAuras", "Version")) or "0.2.0"

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

local function encode(payload)
	return MAGIC .. wrap(E.EncodeBase64(E.CompressString(E.SerializeCBOR(payload))), 92)
end

-- Reverses encode; nil on a foreign/garbage/truncated string. The !WA1! prefix
-- both identifies our format and lets this reject pfUI/WA2 strings cleanly.
local function decode(text)
	if not text then return nil end
	text = string.gsub(text, "%s", "")
	if string.sub(text, 1, string.len(MAGIC)) ~= MAGIC then return nil end
	local ok, result = pcall(function()
		return E.DeserializeCBOR(E.DecompressString(E.DecodeBase64(string.sub(text, string.len(MAGIC) + 1))))
	end)
	if ok and type(result) == "table" then return result end
	return nil
end

-- A deep copy with the non-transmissible fields stripped (WA2's
-- stripNonTransmissableFields): parent (re-derived on import), uid (regenerated),
-- controlledChildren (children travel in payload.c and get fresh ids). `id`
-- stays (the suggested name); internalVersion stays (the importer's
-- MergeDefaults migration reads it).
local function cleanForExport(data)
	local c = WA.DeepCopy(data)
	c.parent = nil
	c.uid = nil
	c.controlledChildren = nil
	return c
end

-- A display's data as a transport string, or nil + reason. Groups bring their
-- direct children in payload.c. Nested-group export is deliberately shallow: a
-- child that is itself a group loses its own children (controlledChildren
-- stripped), the flat single-level group being the common case -- revisit with
-- recursion if nested groups become one.
function WA.Export(id)
	if not WA.hasImportExport then return nil, "C_EncodingUtil is not available on this client" end
	local data = WeakestAurasDB.displays[id]
	if not data then return nil, "no such display: " .. tostring(id) end

	local payload = { m = "WeakestAuras", v = ADDON_VERSION, d = cleanForExport(data) }
	if WA.IsGroup(data) and data.controlledChildren then
		payload.c = {}
		for i = 1, table.getn(data.controlledChildren) do
			local child = WeakestAurasDB.displays[data.controlledChildren[i]]
			if child then table.insert(payload.c, cleanForExport(child)) end
		end
	end

	local ok, blob = pcall(encode, payload)
	if not ok then return nil, "serialization failed: " .. tostring(blob) end
	return blob
end

-- Installs one imported display: fresh non-colliding id + new uid, stored, then
-- MergeDefaults (fills fields the exporter's version lacked, runs trigger
-- migrate; internalVersion-gated so a newer exporter's fields survive and an
-- older one's get defaulted). Returns the new id. Importing "Foo" twice never
-- overwrites: WA.UniqueId gives the second one "Foo 2".
local function installDisplay(data, parentId)
	local base = data.id
	if not base or base == "" then base = "Imported" end
	local newId = WA.UniqueId(base)
	data.id = newId
	data.uid = WA.NewUID()
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
		for i = 1, table.getn(payload.c) do
			local childId = installDisplay(payload.c[i], newId)
			table.insert(root.controlledChildren, childId)
			WA.Add(WeakestAurasDB.displays[childId])
		end
	end

	WA.Add(root)
	return newId
end
