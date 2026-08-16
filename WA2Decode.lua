-- WeakestAuras -- transport for WeakAuras2 export strings: `!WA:2!<body>` down to
-- a plain Lua table. Reverses WA2's Transmission.lua and LibSerialize's wire
-- format, and knows nothing about auras. Import only; nothing here emits the
-- format, and nothing it decodes is ever executed.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- WeakAuras2's B64tobyte, which is the alphabet LibDeflate's EncodeForPrint
-- writes: a-z, A-Z, 0-9, then "(" and ")".
local ALPHABET = "abcdefghijklmnopqrstuvwxyz"
	.. "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	.. "0123456789()"

local SIXBIT = {}
for i = 1, string.len(ALPHABET) do
	SIXBIT[string.sub(ALPHABET, i, i)] = i - 1
end

local POW2 = { [0] = 1 }
for i = 1, 13 do POW2[i] = POW2[i - 1] * 2 end

-- LibDeflate emits *raw* deflate -- no zlib header, no checksum. That has no
-- magic bytes, so DecompressString cannot auto-detect it and the method must be
-- passed explicitly; omitting it (as ImportExport.lua does, where the data
-- really is zlib) refuses every WeakAuras string. Confirmed on this client by
-- /wa wa2probe, whose negative test is the live counterpart of this constant.
local RAW_DEFLATE = (Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate) or 0

-- A wago aura is a few tens of KB. Anything past this is refused rather than
-- handed to a deserializer that would grind over it.
local MAX_PAYLOAD = 512 * 1024

-- 6 bits per character, little-endian: each character adds its 6 bits above
-- whatever is already buffered, and whole bytes are emitted from the bottom.
-- Lua 5.0 has no bit library, so this is multiply and divide by powers of two;
-- the bitfield never exceeds 12 bits, so it stays exactly representable.
--
-- The loop runs one iteration past the end of the string on purpose. An
-- iteration emits the byte completed by the *previous* character, so stopping on
-- the last character would drop the final byte. That trailing out-of-range read
-- is the only place `or 0` is reachable: callers reject a body carrying a
-- character outside the alphabet before getting here.
local function decode6(str)
	local out, n = {}, 0
	local bitfield, bits = 0, 0
	local len = string.len(str)
	local i = 1
	while true do
		if bits >= 8 then
			n = n + 1
			out[n] = string.char(math.mod(bitfield, 256))
			bitfield = math.floor(bitfield / 256)
			bits = bits - 8
		end
		local ch = SIXBIT[string.sub(str, i, i)]
		bitfield = bitfield + (ch or 0) * POW2[bits]
		bits = bits + 6
		if i > len then break end
		i = i + 1
	end
	return table.concat(out, "", 1, n)
end

-- Offset and character of the first byte the alphabet does not cover, or nil.
-- WA2's own decoder reads an unknown character as zero, which turns a mangled
-- paste into plausible garbage that only surfaces as a deserializer bug.
local function badCharacter(body)
	for i = 1, string.len(body) do
		local ch = string.sub(body, i, i)
		if not SIXBIT[ch] then return i, ch end
	end
	return nil
end

-- `!WA:2!<body>` -> the LibSerialize bytes underneath, or nil and a reason
-- phrased for whoever pasted the string.
function WA.WA2Decode(text)
	if type(text) ~= "string" then return nil, "not a string" end

	local stripped = string.gsub(text, "%s", "")
	local _, stop, version = string.find(stripped, "^!WA:(%d+)!")
	if not stop then return nil, "not a WeakAuras export string" end
	if version ~= "2" then
		return nil, "WeakAuras transmission version " .. version .. " is not supported"
	end

	local body = string.sub(stripped, stop + 1)
	if body == "" then return nil, "the string carries no payload" end
	local at, ch = badCharacter(body)
	if at then
		return nil, "character \"" .. ch .. "\" at position " .. at .. " is not part of the format"
	end

	local ok, bytes = pcall(decode6, body)
	if not ok or type(bytes) ~= "string" or bytes == "" then
		return nil, "the body did not decode"
	end

	local E = C_EncodingUtil
	if not E or not E.DecompressString then
		return nil, "this client has no decompression API"
	end
	local inflated
	ok, inflated = pcall(E.DecompressString, bytes, RAW_DEFLATE)
	if not ok or type(inflated) ~= "string" or inflated == "" then
		return nil, "the payload did not decompress"
	end
	if string.len(inflated) > MAX_PAYLOAD then
		return nil, "the payload is larger than " .. MAX_PAYLOAD .. " bytes"
	end
	return inflated
end

-- ---------------------------------------------------------------------------
-- LibSerialize.
--
-- Type indices and the tag layout are transcribed from the library's own
-- _ReaderIndex, _EmbeddedIndex and "Encoding format" block:
--
--     NNNN NNN1   a 7-bit non-negative int, whole value in the tag
--     CCCC TT10   a 2-bit type index and a 4-bit count
--     NNNN S100   the low 4 bits of a 12-bit int plus its sign; one byte follows
--     TTTT T000   a 5-bit type index
-- ---------------------------------------------------------------------------

local SERIALIZATION_VERSION_MAX = 2
local MAX_DEPTH = 64

local T_NIL = 0
local T_NUM_FLOAT = 9
local T_NUM_FLOATSTR, T_NUM_FLOATSTR_NEG = 10, 11
local T_BOOL_T, T_BOOL_F = 12, 13
-- Each of these families runs 8, 16, 24 in consecutive indices, so the count
-- width is the offset from the first plus one.
local T_STR_8 = 14
local T_TABLE_8 = 17
local T_ARRAY_8 = 20
local T_MIXED_8 = 23
local T_STRINGREF_8 = 26
local T_TABLEREF_8 = 29

local EMB_STRING, EMB_TABLE, EMB_ARRAY, EMB_MIXED = 0, 1, 2, 3

-- Byte counts for the fixed-width integer types, indices 1-8. NUM_64 is seven
-- bytes on the wire despite its name -- 56 bits, which covers a double's exact
-- integer range with room to spare.
local INT_WIDTH = { 2, 2, 3, 3, 4, 4, 7, 7 }
local INT_NEGATIVE = { [2] = true, [4] = true, [6] = true, [8] = true }

-- Past 2^53 a Lua number stops representing consecutive integers, so a value
-- above it would come back quietly wrong rather than merely large.
local MAX_EXACT_INT = 9007199254740992

local function readByte(r)
	if r.pos > r.len then error("the payload ends mid-value", 0) end
	local b = string.byte(r.data, r.pos)
	r.pos = r.pos + 1
	return b
end

-- Lua 5.0's string.byte takes one index; the (s, i, j) range form is 5.1. Every
-- byte is therefore its own call, and a run of bytes is a string.sub instead.
local function readRaw(r, n)
	if n < 0 or r.pos + n - 1 > r.len then error("the payload ends mid-value", 0) end
	local s = string.sub(r.data, r.pos, r.pos + n - 1)
	r.pos = r.pos + n
	return s
end

-- Multi-byte integers are big-endian, most significant byte first. That is the
-- opposite order from the 6-bit print decode above. They are separate layers of
-- the format and sharing one convention between them decodes numbers that are
-- merely wrong rather than numbers that fail.
local function readUInt(r, width)
	local value = 0
	for i = 1, width do value = value * 256 + readByte(r) end
	return value
end

local function addStringReference(r, value)
	-- Only strings longer than two bytes enter the pool. Their order must match
	-- the writer's order or every later STRINGREF points at the wrong value.
	if string.len(value) > 2 then
		r.stringCount = r.stringCount + 1
		r.strings[r.stringCount] = value
	end
end

local function newTableReference(r)
	-- Register before reading contents: _ReadMixed fills both halves into the
	-- same table, and a table can refer to itself or an ancestor.
	r.tableCount = r.tableCount + 1
	local value = {}
	r.tables[r.tableCount] = value
	return value
end

-- Sign / 11-bit exponent / 52-bit mantissa reassembled by arithmetic; Lua 5.0
-- has no string.unpack or bit library. Denormals and inf/nan are decoded for
-- completeness, but no aura carries one. `WA.INF` is the Lua 5.0 substitute
-- for the absent math.huge, and powers of two replace the absent math.ldexp.
local function readFloat(r)
	local b1 = readByte(r)
	local b2 = readByte(r)
	local b3 = readByte(r)
	local b4 = readByte(r)
	local b5 = readByte(r)
	local b6 = readByte(r)
	local b7 = readByte(r)
	local b8 = readByte(r)
	local negative = b1 >= 128
	local exponent = math.mod(b1, 128) * 16 + math.floor(b2 / 16)
	local mantissa = math.mod(b2, 16) * 281474976710656
		+ b3 * 1099511627776
		+ b4 * 4294967296
		+ b5 * 16777216
		+ b6 * 65536
		+ b7 * 256
		+ b8
	local sign = negative and -1 or 1
	if exponent == 0 then
		if mantissa == 0 then return sign * 0.0 end
		return sign * (mantissa / 4503599627370496) * (2 ^ -1022)
	end
	if exponent == 2047 then
		if mantissa == 0 then return sign * WA.INF end
		return 0 / 0
	end
	return sign * (1 + mantissa / 4503599627370496) * (2 ^ (exponent - 1023))
end

local readValue

local function fillArray(r, t, count, depth)
	for i = 1, count do t[i] = readValue(r, depth + 1) end
	return t
end

local function fillMap(r, t, count, depth)
	for i = 1, count do
		local key = readValue(r, depth + 1)
		if key == nil then error("a table key decoded as nil", 0) end
		t[key] = readValue(r, depth + 1)
	end
	return t
end

local function readExtended(r, idx, depth)
	if idx == T_NIL then return nil end
	if idx == T_BOOL_T then return true end
	if idx == T_BOOL_F then return false end

	local width = INT_WIDTH[idx]
	if width then
		local value = readUInt(r, width)
		if value > MAX_EXACT_INT then
			error("an integer past 2^53 cannot be represented here", 0)
		end
		if INT_NEGATIVE[idx] then return -value end
		return value
	end

	if idx == T_NUM_FLOAT or idx == T_NUM_FLOATSTR or idx == T_NUM_FLOATSTR_NEG then
		if idx == T_NUM_FLOAT then return readFloat(r) end
		local text = readRaw(r, readByte(r))
		local value = tonumber(text)
		if value == nil then error("malformed floating point string", 0) end
		if idx == T_NUM_FLOATSTR_NEG then return -value end
		return value
	end

	if idx >= T_STR_8 and idx <= T_STR_8 + 2 then
		local value = readRaw(r, readUInt(r, idx - T_STR_8 + 1))
		addStringReference(r, value)
		return value
	end
	if idx >= T_TABLE_8 and idx <= T_TABLE_8 + 2 then
		return fillMap(r, newTableReference(r), readUInt(r, idx - T_TABLE_8 + 1), depth)
	end
	if idx >= T_ARRAY_8 and idx <= T_ARRAY_8 + 2 then
		return fillArray(r, newTableReference(r), readUInt(r, idx - T_ARRAY_8 + 1), depth)
	end
	if idx >= T_MIXED_8 and idx <= T_MIXED_8 + 2 then
		local countWidth = idx - T_MIXED_8 + 1
		local arrayCount = readUInt(r, countWidth)
		local mapCount = readUInt(r, countWidth)
		local value = newTableReference(r)
		fillArray(r, value, arrayCount, depth)
		return fillMap(r, value, mapCount, depth)
	end

	if idx >= T_STRINGREF_8 and idx <= T_STRINGREF_8 + 2 then
		local index = readUInt(r, idx - T_STRINGREF_8 + 1)
		if index < 1 or index > r.stringCount then
			error("string reference " .. index .. " outside 1.." .. r.stringCount, 0)
		end
		return r.strings[index]
	end
	if idx >= T_TABLEREF_8 and idx <= T_TABLEREF_8 + 2 then
		local index = readUInt(r, idx - T_TABLEREF_8 + 1)
		if index < 1 or index > r.tableCount then
			error("table reference " .. index .. " outside 1.." .. r.tableCount, 0)
		end
		return r.tables[index]
	end

	error("unknown type index " .. idx, 0)
end

function readValue(r, depth)
	if depth > MAX_DEPTH then
		error("the payload nests deeper than " .. MAX_DEPTH .. " levels", 0)
	end
	local tag = readByte(r)

	if math.mod(tag, 2) == 1 then
		return math.floor(tag / 2)
	end

	if math.mod(tag, 4) == 2 then
		local kind = math.mod(math.floor(tag / 4), 4)
		local count = math.floor(tag / 16)
		if kind == EMB_STRING then
			local value = readRaw(r, count)
			addStringReference(r, value)
			return value
		end
		if kind == EMB_TABLE then return fillMap(r, newTableReference(r), count, depth) end
		if kind == EMB_ARRAY then return fillArray(r, newTableReference(r), count, depth) end
		-- An embedded MIXED packs both counts into the one nibble -- the array
		-- part in its low two bits, the map part in its high two -- and stores
		-- each **one less** than its true value. A table with an empty half is
		-- written as ARRAY or TABLE instead, so the embedded form never has to
		-- represent zero and spends the bit on a larger range. Dropping either
		-- +1 still decodes simple payloads for a while before drifting, which is
		-- what makes it worth stating rather than deriving.
		local arrayCount = math.mod(count, 4) + 1
		local mapCount = math.floor(count / 4) + 1
		local value = newTableReference(r)
		fillArray(r, value, arrayCount, depth)
		return fillMap(r, value, mapCount, depth)
	end

	if math.mod(tag, 8) == 4 then
		local value = math.floor(tag / 16) + readByte(r) * 16
		if math.mod(math.floor(tag / 8), 2) == 1 then return -value end
		return value
	end

	return readExtended(r, math.floor(tag / 8), depth)
end

-- LibSerialize bytes -> a Lua table, or nil and a reason. Every read is bounds
-- checked, so a truncated or hostile payload is refused rather than thrown.
function WA.WA2Deserialize(bytes)
	if type(bytes) ~= "string" or bytes == "" then return nil, "empty payload" end

	local r = {
		data = bytes,
		pos = 1,
		len = string.len(bytes),
		strings = {},
		stringCount = 0,
		tables = {},
		tableCount = 0,
	}
	local ok, result = pcall(function()
		local version = readByte(r)
		if version > SERIALIZATION_VERSION_MAX then
			error("serialization version " .. version .. " is newer than this reader", 0)
		end
		return readValue(r, 0)
	end)

	if not ok then return nil, tostring(result) end
	-- A WeakAuras string always carries a table, so a top-level nil is a payload
	-- that decoded successfully into nothing worth returning.
	if result == nil then return nil, "the payload decoded to nil" end
	return result
end
