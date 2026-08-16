-- WeakestAuras -- the custom-option schema and config validator for imported auras.
-- Mirrors WeakestAurasOptions/AuthorOptions.lua and WeakAuras.lua's validator.

if WeakestAuras.disabled then return end
local WA = WeakestAuras

-- Forward declarations. The field builders near the top of this file close over
-- the read/write helpers defined below them, and in 5.0 a name that is not yet a
-- visible local compiles as a *global* read -- which resolves to nil at call
-- time, with the error swallowed. Every user-mode set went through
-- setOptionValue that way and silently did nothing.
local optionValue
local setOptionValue, setOptionValueAt

WA.author_option_classes = {
	toggle = "simple",
	input = "simple",
	number = "simple",
	range = "simple",
	color = "simple",
	select = "simple",
	media = "simple",
	multiselect = "simple",
	description = "noninteractive",
	space = "noninteractive",
	header = "noninteractive",
	group = "group",
}

WA.author_option_types = {
	toggle = "Toggle",
	input = "String",
	number = "Number",
	range = "Slider",
	description = "Description",
	color = "Color",
	select = "Dropdown Menu",
	space = "Space",
	multiselect = "Toggle List",
	media = "Media",
	header = "Separator",
	group = "Option Group",
}

WA.author_option_fields = {
	common = {
		type = true,
		name = true,
		useDesc = true,
		desc = true,
		key = true,
		width = true,
	},
	number = {
		min = 0,
		max = 1,
		step = .05,
		default = 0,
	},
	range = {
		min = 0,
		max = 1,
		step = .05,
		default = 0,
	},
	input = {
		default = "",
		useLength = false,
		length = 10,
		multiline = false,
	},
	toggle = {
		default = false,
	},
	description = {
		text = "",
		fontSize = "medium",
	},
	color = {
		default = {1, 1, 1, 1},
	},
	select = {
		values = {"val1"},
		default = 1,
	},
	space = {
		variableWidth = true,
		useHeight = false,
		height = 1,
	},
	media = {
		mediaType = "sound",
		media = "Interface\\AddOns\\WeakAuras\\Media\\Sounds\\AirHorn.ogg",
	},
	multiselect = {
		default = {true},
		values = {"val1"},
	},
	header = {
		useName = false,
		text = "",
	},
	group = {
		groupType = "simple",
		useCollapse = true,
		collapse = false,
		limitType = "none",
		size = 10,
		nameSource = 0,
		hideReorder = true,
		entryNames = nil,
		subOptions = {},
		noMerge = false,
	},
}

WA.author_option_media_defaults = {
	sound = "Interface\\AddOns\\WeakestAuras\\Media\\Sounds\\AirHorn.ogg",
	font = "Friz Quadrata TT",
	border = "1 Pixel",
	background = "None",
	statusbar = "Blizzard",
}

local function clearTable(t)
	for key in pairs(t) do t[key] = nil end
end

local function copyDefault(option)
	if type(option.default) == "table" then return WA.DeepCopy(option.default) end
	return option.default
end

local function valuesEqual(first, second)
	if first == second then return true end
	if type(first) ~= "table" or type(second) ~= "table" then return false end
	for key, value in pairs(first) do
		if not valuesEqual(value, second[key]) then return false end
	end
	for key, value in pairs(second) do
		if not valuesEqual(value, first[key]) then return false end
	end
	return true
end

local significantFieldsForMerge = {
	type = true, name = true, key = true, groupType = true,
	limitType = true, size = true, mediaType = true,
}

local specialCasesForMerge = { nameSource = true }

local function round(value)
	return math.floor(value + 0.5)
end

local function customOptionIsValid(option)
	if type(option) ~= "table" or not option.type then
		return false
	elseif WA.author_option_classes[option.type] == "simple" then
		if not option.key or not option.name then return false end
	elseif WA.author_option_classes[option.type] == "group" then
		if not option.key or not option.name or not option.subOptions then return false end
	end
	return true
end

local function reportCorruptOption(data, index)
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cffff0000WeakestAuras|r " .. tostring(data.id) .. " Custom Option #" .. index
				.. " in " .. tostring(data.id) .. " has been detected as corrupt, and has been deleted.",
			1, 0.3, 0.3)
	end
end

local function validateUserConfig(data, options, config)
	local authorOptionKeys, corruptOptions = {}, {}
	options = options or {}
	config = config or {}

	for index = 1, table.getn(options) do
		local option = options[index]
		if not customOptionIsValid(option) or authorOptionKeys[option.key] then
			reportCorruptOption(data, index)
			corruptOptions[index] = true
		else
			local optionClass = WA.author_option_classes[option.type]
			if option.key then authorOptionKeys[option.key] = index end
			if optionClass == "simple" then
				if config[option.key] == nil then
					config[option.key] = copyDefault(option)
				end
			elseif optionClass == "group" then
				local subOptions = option.subOptions
				if type(config[option.key]) ~= "table" then config[option.key] = {} end
				local subConfig = config[option.key]
				if option.groupType == "array" then
					local invalidArray = false
					for key, value in pairs(subConfig) do
						if type(key) ~= "number" or type(value) ~= "table" then
							invalidArray = true
							break
						end
					end
					if invalidArray then clearTable(subConfig) end
					if option.limitType == "fixed" then
						for i = table.getn(subConfig) + 1, option.size do subConfig[i] = {} end
					end
					if option.limitType ~= "none" then
						for i = option.size + 1, table.getn(subConfig) do subConfig[i] = nil end
					end
					for _, toValidate in pairs(subConfig) do
						validateUserConfig(data, subOptions, toValidate)
					end
				else
					local firstKey = next(subConfig)
					if type(firstKey) ~= "string" then clearTable(subConfig) end
					validateUserConfig(data, subOptions, subConfig)
				end
			end
		end
	end

	for key, value in pairs(config) do
		if not authorOptionKeys[key] then
			config[key] = nil
		else
			local option = options[authorOptionKeys[key]]
			local optionClass = WA.author_option_classes[option.type]
			if optionClass and optionClass ~= "group" then
				if option.type == "media" then
					if type(value) ~= "string" and (type(value) ~= "number" or option.mediaType ~= "sound") then
						config[key] = copyDefault(option)
					end
				elseif type(value) ~= type(option.default) then
					config[key] = copyDefault(option)
				elseif option.type == "input" and option.useLength then
					config[key] = string.sub(config[key], 1, option.length)
				elseif option.type == "number" or option.type == "range" then
					if (option.max and option.max < value) or (option.min and option.min > value) then
						config[key] = copyDefault(option)
					elseif option.type == "number" and option.step then
						local min = option.min or 0
						config[key] = option.step * round((value - min) / option.step) + min
					end
				elseif option.type == "select" then
					if value < 1 or value > table.getn(option.values) then config[key] = copyDefault(option) end
				elseif option.type == "multiselect" then
					local multiselect = config[key]
					if type(multiselect) ~= "table" then
						config[key] = {}
						multiselect = config[key]
					end
					for i = 1, table.getn(multiselect) do
						if option.default[i] ~= nil then
							if type(multiselect[i]) ~= "boolean" then multiselect[i] = option.default[i] end
						else
							multiselect[i] = nil
						end
					end
					if type(option.default) ~= "table" then option.default = {} end
					for i = 1, table.getn(option.default) do
						if type(multiselect[i]) ~= "boolean" then multiselect[i] = option.default[i] end
					end
				elseif option.type == "color" then
					if type(config[key]) ~= "table" then config[key] = {} end
					for i = 1, 4 do
						local component = config[key][i]
						if type(component) ~= "number" or component < 0 or component > 1 then
							config[key] = copyDefault(option)
							break
						end
					end
				end
			end
		end
	end

	for i = table.getn(options), 1, -1 do
		if corruptOptions[i] then table.remove(options, i) end
	end
end

function WA.ValidateUserConfig(data)
	if not data then return end
	data.authorOptions = data.authorOptions or {}
	data.config = data.config or {}
	validateUserConfig(data, data.authorOptions, data.config)
end

local function customOptionHalf(option)
	return (option.width or 1) < 2
end

local function setCustomConfig(data, option, value, config)
	config = config or data.config
	setOptionValue(data, option, value, config)
end

local function selectFields(fields, data, option, config)
	local values, labels = {}, {}
	for i = 1, table.getn(option.values or {}) do
		values[i] = i
		labels[i] = option.values[i]
	end
	local field = {
		type = "select", name = option.name, values = values, labels = labels,
		half = customOptionHalf(option),
		get = function() return optionValue(option, config) end,
		set = function(index)
			local value = index
			setCustomConfig(data, option, value, config)
		end,
	}
	table.insert(fields, field)
end

local function mediaField(fields, data, option, config)
	local mediaType = option.mediaType
	if mediaType == "sound" then
		local previews = {}
		for key in pairs(WA.sound_types or {}) do
			if key ~= " custom" and key ~= " KitID" then previews[key] = true end
		end
		table.insert(fields, {
			type = "select", name = option.name, values = WA.SoundValues or {},
			labels = WA.sound_types, previews = previews,
			onPreview = function(value)
				if value ~= " custom" and value ~= " KitID" and WA.PreviewSound then
					WA.PreviewSound(value)
				end
			end,
			half = customOptionHalf(option),
			get = function() return optionValue(option, config) end,
			set = function(value) setCustomConfig(data, option, value, config) end,
		})
	elseif mediaType == "font" and WA.textCore and WA.textCore.FONTS then
		local values, labels = {}, {}
		for i = 1, table.getn(WA.textCore.FONTS) do
			local font = WA.textCore.FONTS[i]
			values[i] = font.path
			labels[font.path] = font.name
		end
		table.insert(fields, {
			type = "select", name = option.name, values = values, labels = labels,
			half = customOptionHalf(option),
			get = function() return optionValue(option, config) end,
			set = function(value) setCustomConfig(data, option, value, config) end,
		})
	elseif mediaType == "statusbar" and WA.Widgets and WA.Widgets.BarTextures then
		local values = WA.Widgets.BarTextures()
		table.insert(fields, {
			type = "select", name = option.name, values = values,
			swatches = WA.Widgets.BarTextureSwatches and WA.Widgets.BarTextureSwatches() or nil,
			half = customOptionHalf(option),
			get = function() return optionValue(option, config) end,
			set = function(value) setCustomConfig(data, option, value, config) end,
		})
	else
		table.insert(fields, {
			type = "input", name = option.name, half = customOptionHalf(option),
			get = function() return optionValue(option, config) end,
			set = function(value) setCustomConfig(data, option, value, config) end,
		})
	end
end

local function simpleOptionField(fields, data, option, config)
	config = config or data.config
	local half = customOptionHalf(option)
	if option.type == "toggle" then
		table.insert(fields, {
			type = "toggle", name = option.name, half = half,
			get = function() return optionValue(option, config) and true or false end,
			set = function(value) setCustomConfig(data, option, value and true or false, config) end,
		})
	elseif option.type == "input" then
		table.insert(fields, {
			type = option.multiline and "multiline" or "input", name = option.name,
			half = half, height = option.multiline and 80 or nil,
			get = function() return optionValue(option, config) end,
			set = function(value) setCustomConfig(data, option, value, config) end,
		})
	elseif option.type == "number" then
		table.insert(fields, {
			type = "input", name = option.name, half = half,
			get = function() return optionValue(option, config) end,
			set = function(value)
				local number = tonumber(value)
				if number ~= nil then setCustomConfig(data, option, number, config) end
			end,
		})
	elseif option.type == "range" then
		table.insert(fields, {
			type = "range", name = option.name, half = half,
			min = option.min or 0, max = option.max or 100, step = option.step or 1,
			get = function() return optionValue(option, config) end,
			set = function(value) setCustomConfig(data, option, tonumber(value), config) end,
		})
	elseif option.type == "color" then
		table.insert(fields, {
			type = "color", name = option.name, half = half,
			get = function() return optionValue(option, config) end,
			set = function(value) setCustomConfig(data, option, value, config) end,
		})
	elseif option.type == "select" then
		selectFields(fields, data, option, config)
	elseif option.type == "multiselect" then
		table.insert(fields, {
			type = "description", name = option.name or "",
		})
		for i = 1, table.getn(option.values or {}) do
			local index = i
			table.insert(fields, {
				type = "toggle", name = option.values[i], half = half,
				get = function()
					local values = optionValue(option, config)
					return type(values) == "table" and values[index] and true or false
				end,
				set = function(value)
					setOptionValueAt(data, option, index, value and true or false, config)
				end,
			})
		end
	elseif option.type == "media" then
		mediaField(fields, data, option, config)
	end
end

local function placeholderField(fields, option)
	local name = option.name or option.key or "Unnamed option"
	local message
	if option.type == "group" then
		message = "Custom option group '" .. tostring(name) .. "' is not editable here."
	else
		message = "Custom option '" .. tostring(name) .. "' of type '"
			.. tostring(option.type) .. "' is not editable here."
	end
	table.insert(fields, { type = "description", name = message, half = customOptionHalf(option) })
end

local authorOptionTypes = {
	"toggle", "input", "number", "range", "color", "select",
	"description", "space", "header", "multiselect", "media", "group",
}

local authorWidthValues = {1, 2}
local authorWidthLabels = {[1] = "Half", [2] = "Full"}

local function authorField(field, index, action)
	field.authorIndex = index
	field.authorAction = action
	return field
end

local function authorKeyIsAvailable(data, option, key, options)
	if not key or key == "" then return false end
	options = options or data.authorOptions or {}
	for i = 1, table.getn(options) do
		local other = options[i]
		if other ~= option and other.key == key then return false end
	end
	return true
end

local function ensureUniqueAuthorKey(candidate, suffix, options, index)
	index = index or 1
	local key = candidate
	local existingKeys = {}
	local goodKey = true
	for i = 1, table.getn(options or {}) do
		local option = options[i]
		if option and option.key then existingKeys[option.key] = true end
	end
	if existingKeys[key] then goodKey = false end
	if not goodKey then
		local prefix = candidate .. (suffix or "")
		while not goodKey do
			key = prefix .. index
			goodKey = not existingKeys[key]
			index = index + 1
		end
	end
	return key
end

local function authorOptionChanged(data)
	WA.MergeDefaults(data)
	WA.Add(data)
	WA.RefreshAuraEnvConfig(data.id)
	if WA.RefreshOptions then WA.RefreshOptions() end
end

local function setAuthorOption(data, option, key, value, options)
	if key == "key" and not authorKeyIsAvailable(data, option, value, options) then return end
	option[key] = value
	authorOptionChanged(data)
end

local function authorInputField(index, name, key, data, option, half, options)
	return authorField({
		type = "input", name = name, half = half,
		get = function() return option[key] end,
		set = function(value) setAuthorOption(data, option, key, value, options) end,
	}, index, key)
end

local function authorNumberField(index, name, key, data, option, half, options)
	return authorField({
		type = "input", name = name, half = half,
		get = function() return option[key] end,
		set = function(value)
			local number = tonumber(value)
			if number ~= nil then setAuthorOption(data, option, key, number, options) end
		end,
	}, index, key)
end

local authorMediaTypes = {"sound", "font", "border", "background", "statusbar"}
local authorMediaLabels = {
	sound = "Sound", font = "Font", border = "Border",
	background = "Background", statusbar = "Status Bar",
}

local function authorMediaValues(option)
	local mediaType = option.mediaType
	local values, labels = {}, {}
	if mediaType == "sound" then
		values = WA.SoundValues or {}
		labels = WA.sound_types or {}
	elseif mediaType == "font" and WA.textCore and WA.textCore.FONTS then
		for i = 1, table.getn(WA.textCore.FONTS) do
			local font = WA.textCore.FONTS[i]
			values[i] = font.path
			labels[font.path] = font.name
		end
	elseif mediaType == "statusbar" and WA.Widgets and WA.Widgets.BarTextures then
		values = WA.Widgets.BarTextures()
		labels = {}
		for i = 1, table.getn(values) do labels[values[i]] = values[i] end
	end
	return values, labels
end

local function authorMediaFields(fields, data, option, index)
	table.insert(fields, authorField({
		type = "select", name = "Media Type", values = authorMediaTypes,
		labels = authorMediaLabels, half = true,
		get = function() return option.mediaType end,
		set = function(value)
			option.mediaType = value
			option.default = WA.author_option_media_defaults[value]
			authorOptionChanged(data)
		end,
	}, index, "mediaType"))

	local values, labels = authorMediaValues(option)
	if table.getn(values) > 0 then
		local field = {
			type = "select", name = "Default", values = values, labels = labels,
			half = false,
			get = function() return option.default end,
			set = function(value) setAuthorOption(data, option, "default", value) end,
		}
		if option.mediaType == "sound" then
			field.previews = {}
			for i = 1, table.getn(values) do
				local value = values[i]
				if value ~= " custom" and value ~= " KitID" then field.previews[value] = true end
			end
			field.onPreview = function(value)
				if value ~= " custom" and value ~= " KitID" and WA.PreviewSound then
					WA.PreviewSound(value)
				end
			end
		elseif option.mediaType == "statusbar" and WA.Widgets.BarTextureSwatches then
			field.swatches = WA.Widgets.BarTextureSwatches()
		end
		table.insert(fields, authorField(field, index, "default"))
	else
		table.insert(fields, authorInputField(index, "Default", "default", data, option, false))
	end
end

local function normalizeMultiselectDefault(option)
	if type(option.default) ~= "table" then option.default = {} end
	local count = table.getn(option.values or {})
	for i = 1, count do
		if type(option.default[i]) ~= "boolean" then option.default[i] = false end
	end
	for i = table.getn(option.default), count + 1, -1 do option.default[i] = nil end
end

local function reorderMultiselectDefault(option, fromIndex, before)
	local value = table.remove(option.default, fromIndex)
	local insertAt = (fromIndex < before) and (before - 1) or before
	table.insert(option.default, insertAt, value)
	normalizeMultiselectDefault(option)
end

local function authorMultiselectFields(fields, data, option, index)
	local valuesField = authorField({
		type = "namelist", name = "Values", get = function() return option.values end,
		onChange = function()
			normalizeMultiselectDefault(option)
			authorOptionChanged(data)
		end,
		onReorder = function(fromIndex, before)
			reorderMultiselectDefault(option, fromIndex, before)
			authorOptionChanged(data)
		end,
		onRemove = function(indexValue)
			table.remove(option.default, indexValue)
			authorOptionChanged(data)
		end,
		onAdd = function()
			table.insert(option.default, table.getn(option.values), false)
			authorOptionChanged(data)
		end,
	}, index, "values")
	table.insert(fields, valuesField)

	normalizeMultiselectDefault(option)
	for valueIndex = 1, table.getn(option.values or {}) do
		local i = valueIndex
		table.insert(fields, authorField({
			type = "toggle", name = "Default: " .. tostring(option.values[i]), half = true,
			get = function() return option.default[i] and true or false end,
			set = function(value)
				option.default[i] = value and true or false
				authorOptionChanged(data)
			end,
		}, index, "default" .. i))
	end
end

local function authorSimpleTypeFields(fields, data, option, index)
	local optionType = option.type
	if optionType == "toggle" then
		table.insert(fields, authorField({
			type = "select", name = "Default", values = {0, 1},
			labels = {[0] = "False", [1] = "True"}, half = true,
			get = function() return option.default and 1 or 0 end,
			set = function(value) setAuthorOption(data, option, "default", value == 1) end,
		}, index, "default"))
	elseif optionType == "input" then
		table.insert(fields, authorInputField(index, "Default", "default", data, option, false))
		table.insert(fields, authorField({
			type = "toggle", name = "Limit Length", half = true,
			get = function() return option.useLength and true or false end,
			set = function(value) setAuthorOption(data, option, "useLength", value and true or false) end,
		}, index, "useLength"))
		if option.useLength then
			table.insert(fields, authorNumberField(index, "Length", "length", data, option, true))
		end
		table.insert(fields, authorField({
			type = "toggle", name = "Multiline", half = true,
			get = function() return option.multiline and true or false end,
			set = function(value) setAuthorOption(data, option, "multiline", value and true or false) end,
		}, index, "multiline"))
	elseif optionType == "number" then
		table.insert(fields, authorNumberField(index, "Default", "default", data, option, true))
		table.insert(fields, authorNumberField(index, "Minimum", "min", data, option, true))
		table.insert(fields, authorNumberField(index, "Maximum", "max", data, option, true))
		table.insert(fields, authorNumberField(index, "Step", "step", data, option, true))
	elseif optionType == "range" then
		table.insert(fields, authorField({
			type = "range", name = "Default", min = option.min or 0,
			max = option.max or 1, step = option.step or .05, half = true,
			get = function() return option.default end,
			set = function(value) setAuthorOption(data, option, "default", tonumber(value)) end,
		}, index, "default"))
		table.insert(fields, authorNumberField(index, "Minimum", "min", data, option, true))
		table.insert(fields, authorNumberField(index, "Maximum", "max", data, option, true))
		table.insert(fields, authorNumberField(index, "Step", "step", data, option, true))
	elseif optionType == "color" then
		table.insert(fields, authorField({
			type = "color", name = "Default", half = true,
			get = function() return option.default end,
			set = function(value) setAuthorOption(data, option, "default", value) end,
		}, index, "default"))
	elseif optionType == "select" then
		local values, labels = {}, {}
		for valueIndex = 1, table.getn(option.values or {}) do
			values[valueIndex] = valueIndex
			labels[valueIndex] = option.values[valueIndex]
		end
		table.insert(fields, authorField({
			type = "select", name = "Default", values = values, labels = labels, half = true,
			get = function() return option.default end,
			set = function(value) setAuthorOption(data, option, "default", value) end,
		}, index, "default"))
		table.insert(fields, authorField({
			type = "namelist", name = "Values",
			get = function() return option.values end,
			onChange = function() authorOptionChanged(data) end,
		}, index, "values"))
	elseif optionType == "media" then
		authorMediaFields(fields, data, option, index)
	elseif optionType == "multiselect" then
		authorMultiselectFields(fields, data, option, index)
	elseif optionType == "group" then
		placeholderField(fields, option)
	end
end

local function authorNoninteractiveFields(fields, data, option, index)
	if option.type == "description" then
		table.insert(fields, authorInputField(index, "Text", "text", data, option, false))
		table.insert(fields, authorField({
			type = "select", name = "Font Size", values = {"small", "medium", "large"},
			labels = {small = "Small", medium = "Medium", large = "Large"}, half = true,
			get = function() return option.fontSize end,
			set = function(value) setAuthorOption(data, option, "fontSize", value) end,
		}, index, "fontSize"))
	elseif option.type == "header" then
		table.insert(fields, authorField({
			type = "toggle", name = "Use Name", half = true,
			get = function() return option.useName and true or false end,
			set = function(value) setAuthorOption(data, option, "useName", value and true or false) end,
		}, index, "useName"))
		table.insert(fields, authorInputField(index, "Text", "text", data, option, false))
	elseif option.type == "space" then
		table.insert(fields, authorField({
			type = "toggle", name = "Variable Width", half = true,
			get = function() return option.variableWidth and true or false end,
			set = function(value) setAuthorOption(data, option, "variableWidth", value and true or false) end,
		}, index, "variableWidth"))
		table.insert(fields, authorField({
			type = "toggle", name = "Use Height", half = true,
			get = function() return option.useHeight and true or false end,
			set = function(value) setAuthorOption(data, option, "useHeight", value and true or false) end,
		}, index, "useHeight"))
		if option.useHeight then
			table.insert(fields, authorNumberField(index, "Height", "height", data, option, true))
		end
	end
end

local function authorGroupFields(fields, data, option, index)
	local groupTypes = {"simple", "array"}
	local groupTypeLabels = {simple = "Simple", array = "Array"}
	table.insert(fields, authorField({
		type = "select", name = "Group Type", values = groupTypes,
		labels = groupTypeLabels, half = true,
		get = function() return option.groupType end,
		set = function(value) setAuthorOption(data, option, "groupType", value) end,
	}, index, "groupType"))
	if option.groupType ~= "array" then return end

	local limitTypes = {"none", "max", "fixed"}
	local limitLabels = {none = "Unlimited", max = "Limited", fixed = "Fixed Size"}
	table.insert(fields, authorField({
		type = "select", name = "Limit Type", values = limitTypes,
		labels = limitLabels, half = true,
		get = function() return option.limitType end,
		set = function(value) setAuthorOption(data, option, "limitType", value) end,
	}, index, "limitType"))
	table.insert(fields, authorNumberField(index, "Size", "size", data, option, true))

	local nameSources, nameSourceLabels = {-1, 0}, {
		[-1] = "Fixed Names", [0] = "Entry Order",
	}
	for subIndex = 1, table.getn(option.subOptions or {}) do
		local subOption = option.subOptions[subIndex]
		if subOption and (subOption.type == "input" or subOption.type == "number"
			or subOption.type == "range" or option.nameSource == subIndex) then
			table.insert(nameSources, subIndex)
			nameSourceLabels[subIndex] = subOption.name or subOption.key or
				("Option " .. tostring(subIndex))
		end
	end
	table.insert(fields, authorField({
		type = "select", name = "Entry Name Source", values = nameSources,
		labels = nameSourceLabels, half = true,
		get = function() return option.nameSource or 0 end,
		set = function(value) setAuthorOption(data, option, "nameSource", value) end,
	}, index, "nameSource"))
	table.insert(fields, authorField({
		type = "toggle", name = "Hide Reorder", half = true,
		get = function() return option.hideReorder and true or false end,
		set = function(value) setAuthorOption(data, option, "hideReorder", value and true or false) end,
	}, index, "hideReorder"))
end

local function authorOptionFields(fields, data, option, index, options)
	table.insert(fields, authorField({
		type = "select", name = "Option Type", values = authorOptionTypes,
		labels = WA.author_option_types,
		get = function() return option.type end,
		set = function(value)
			local old = option
			local defaults = WA.author_option_fields[value] or {}
			local newOption = WA.DeepCopy(defaults)
			local commonFields = WA.author_option_fields.common
			for key in pairs(commonFields) do
				if old[key] ~= nil then newOption[key] = WA.DeepCopy(old[key]) end
			end
			newOption.type = value
			local optionClass = WA.author_option_classes[value]
			if optionClass == "noninteractive" then
				newOption.name = nil
				newOption.desc = nil
				newOption.key = nil
				newOption.useDesc = nil
				newOption.default = nil
			else
				newOption.name = newOption.name or "Option " .. index
				newOption.key = newOption.key or ensureUniqueAuthorKey(
					"option" .. index, "", options or data.authorOptions, 1)
			end
			(options or data.authorOptions)[index] = newOption
			authorOptionChanged(data)
		end,
	}, index, "type"))

	local optionClass = WA.author_option_classes[option.type]
	if optionClass ~= "noninteractive" then
		table.insert(fields, authorInputField(index, "Display Name", "name", data, option, true, options))
		table.insert(fields, authorInputField(index, "Option Key", "key", data, option, true, options))
		if optionClass == "simple" then
			table.insert(fields, authorField({
				type = "toggle", name = "Description", half = true,
				get = function() return option.useDesc and true or false end,
				set = function(value) setAuthorOption(data, option, "useDesc", value and true or false) end,
			}, index, "useDesc"))
			if option.useDesc then
				table.insert(fields, authorInputField(index, "Description Text", "desc", data, option, false))
			end
		end
	end
	table.insert(fields, authorField({
		type = "select", name = "Width", values = authorWidthValues,
		labels = authorWidthLabels, half = true,
		get = function() return option.width or 1 end,
		set = function(value) setAuthorOption(data, option, "width", value) end,
	}, index, "width"))

	if optionClass == "simple" then
		authorSimpleTypeFields(fields, data, option, index)
	elseif optionClass == "noninteractive" then
		authorNoninteractiveFields(fields, data, option, index)
	elseif optionClass == "group" then
		authorGroupFields(fields, data, option, index)
	end
end

local function authorOptionActions(data, options, index, option)
	return WA.Widgets.ListActions(options, index, function()
		authorOptionChanged(data)
	end, function(list, itemIndex)
		local copy = WA.DeepCopy(option)
		if copy.key then
			copy.key = ensureUniqueAuthorKey(copy.key .. "copy", "", options, 1)
		end
		if copy.name then copy.name = copy.name .. " - Copy" end
		table.insert(list, itemIndex + 1, copy)
	end)
end

local function optionPathString(path)
	return table.concat(path, ".")
end

local function copyOptionPath(path, value)
	local copy = {}
	for i = 1, table.getn(path) do copy[i] = path[i] end
	table.insert(copy, value)
	return copy
end

local arrayPages = {}

local function arrayPageKey(data, path)
	return tostring(data.id) .. "::config:" .. optionPathString(path)
end

local function getArrayPage(data, path, count)
	local key = arrayPageKey(data, path)
	local page = arrayPages[key] or 1
	if page < 1 then page = 1 end
	if count and count > 0 and page > count then page = count end
	arrayPages[key] = page
	return page
end

local function setArrayPage(data, path, page)
	page = tonumber(page) or 1
	if page < 1 then page = 1 end
	arrayPages[arrayPageKey(data, path)] = page
end

local function initReferences(mergedOption, data, options, index, config, path, parent)
	mergedOption.references = {
		[data.id] = {
			data = data, options = options, index = index,
			config = config, path = path, parent = parent,
		},
	}
	if not mergedOption.subOptions then return end
	local subConfig
	if config then
		if mergedOption.groupType == "simple" then
			subConfig = config[mergedOption.key]
		else
			local configList = config[mergedOption.key]
			local count = type(configList) == "table" and table.getn(configList) or 0
			local page = getArrayPage(data, path, count)
			subConfig = type(configList) == "table" and configList[page] or nil
		end
	end
	local subOptions = options[index].subOptions
	for i = 1, table.getn(mergedOption.subOptions) do
		local subPath = {}
		for j = 1, table.getn(path) do subPath[j] = path[j] end
		table.insert(subPath, i)
		initReferences(mergedOption.subOptions[i], data, subOptions, i,
			subConfig, subPath, mergedOption)
	end
end

local function mergeOptions(mergedOptions, data, options, config, prepath, parent)
	local nextInsert = 1
	prepath = prepath or {}
	options = options or {}
	for i = 1, table.getn(options) do
		local path = {}
		for j = 1, table.getn(prepath) do path[j] = prepath[j] end
		table.insert(path, i)
		local nextOption = options[i]
		local shouldMerge = false
		if not nextOption.noMerge then
			for j = nextInsert, table.getn(mergedOptions) + 1 do
				local mergedOption = mergedOptions[j]
				if not mergedOption then break end
				local validMerge = not mergedOption.noMerge
				if validMerge then
					for field in pairs(significantFieldsForMerge) do
						if nextOption[field] ~= mergedOption[field] then
							validMerge = false
							break
						end
					end
				end
				if validMerge then
					shouldMerge = true
					nextInsert = j
					break
				end
			end
		end

		if shouldMerge then
			local mergedOption = mergedOptions[nextInsert]
			mergedOption.references[data.id] = {
				data = data, options = options, index = i,
				config = config, path = path, parent = parent,
			}
			for key, value in pairs(nextOption) do
				if key == "subOptions" then
					local subConfig
					if config then
						if mergedOption.groupType == "simple" then
							subConfig = config[mergedOption.key]
						else
							local configList = config[mergedOption.key]
							local count = type(configList) == "table" and table.getn(configList) or 0
							local page = getArrayPage(data, path, count)
							subConfig = type(configList) == "table" and configList[page] or nil
						end
					end
					mergeOptions(mergedOption.subOptions, data, value, subConfig, path, mergedOption)
					if mergedOption.groupType == "array" and mergedOption.nameSource ~= nil then
						if (nextOption.nameSource or 0) < 1 or mergedOption.nameSource < 1 then
							if mergedOption.nameSource ~= nextOption.nameSource then
								mergedOption.nameSource = nil
							end
						else
							local source = mergedOption.subOptions[mergedOption.nameSource]
							local sourceReference = source and source.references[data.id]
							if not sourceReference or sourceReference.index ~= nextOption.nameSource then
								mergedOption.nameSource = nil
							end
						end
					end
				elseif not specialCasesForMerge[key] and not valuesEqual(mergedOption[key], value) then
					mergedOption[key] = nil
				end
			end
		else
			nextInsert = table.getn(mergedOptions) + 1
			local newOption = WA.DeepCopy(nextOption)
			initReferences(newOption, data, options, i, config, path, parent)
			table.insert(mergedOptions, nextInsert, newOption)
		end
		nextInsert = nextInsert + 1
	end
end

local function firstReference(option)
	if not option.references then return nil end
	for _, reference in pairs(option.references) do return reference end
	return nil
end

local function referenceConfig(reference)
	if reference.config then return reference.config end
	local parent = reference.parent
	if not parent or not parent.references then return nil end
	local parentReference = parent.references[reference.data.id]
	if not parentReference or not parentReference.config then return nil end
	local parentOption = parentReference.options[parentReference.index]
	local list = parentReference.config[parentOption.key]
	if type(list) ~= "table" then
		list = {}
		parentReference.config[parentOption.key] = list
	end
	local page = getArrayPage(reference.data, parentReference.path, table.getn(list))
	list[page] = list[page] or {}
	reference.config = list[page]
	return reference.config
end

optionValue = function(option, config)
	if not option.references then return config and config[option.key] end
	local found, value = false, nil
	for _, reference in pairs(option.references) do
		local childConfig = reference.config
		local current = childConfig and childConfig[option.key]
		if not found then
			value, found = current, true
		elseif not valuesEqual(value, current) then
			return nil
		end
	end
	return value
end

local function finishReferenceWrites(option)
	for validationId, validationReference in pairs(option.references) do
		WA.ValidateUserConfig(validationReference.data)
		WA.Add(validationReference.data, true)
		WA.RefreshAuraEnvConfig(validationReference.data.id)
	end
	if WA.RefreshOptions then WA.RefreshOptions() end
end

setOptionValue = function(data, option, value, config)
	if not option.references then
		config[option.key] = value
		WA.Add(data, true)
		WA.RefreshAuraEnvConfig(data.id)
		return
	end
	for referenceId, reference in pairs(option.references) do
		local childOption = reference.options[reference.index]
		local childConfig = referenceConfig(reference)
		if childConfig then childConfig[childOption.key] = WA.DeepCopy(value) end
	end
	finishReferenceWrites(option)
end

setOptionValueAt = function(data, option, index, value, config)
	if not option.references then
		local values = config[option.key]
		if type(values) ~= "table" then values = {}; config[option.key] = values end
		values[index] = value
		WA.Add(data, true)
		WA.RefreshAuraEnvConfig(data.id)
		return
	end
	for referenceId, reference in pairs(option.references) do
		local childOption = reference.options[reference.index]
		local childConfig = referenceConfig(reference)
		if childConfig then
			local values = childConfig[childOption.key]
			if type(values) ~= "table" then values = {}; childConfig[childOption.key] = values end
			values[index] = value
		end
	end
	finishReferenceWrites(option)
end

local function arrayEntryLabel(option, entry, index)
	local fallback = "Entry " .. tostring(index)
	local source = tonumber(option.nameSource) or 0
	if source == -1 then
		if type(option.entryNames) == "table" and option.entryNames[index] ~= nil then
			return tostring(option.entryNames[index])
		end
	elseif source > 0 then
		local sourceOption = option.subOptions and option.subOptions[source]
		if sourceOption and type(entry) == "table" then
			local value = entry[sourceOption.key]
			if value ~= nil and type(value) ~= "table" then return tostring(value) end
		end
	end
	return fallback
end

local function arrayEntries(config, option)
	local entries = config[option.key]
	if type(entries) ~= "table" then
		entries = {}
		config[option.key] = entries
	end
	return entries
end

local function arrayConfigChanged(data)
	WA.ValidateUserConfig(data)
	WA.Add(data, true)
	WA.RefreshAuraEnvConfig(data.id)
	if WA.RefreshOptions then WA.RefreshOptions() end
end

local function arrayReferenceChanged(option)
	finishReferenceWrites(option)
end

local function arrayAction(actions, icon, tooltip, onClick)
	table.insert(actions, {icon = icon, tooltip = tooltip, onClick = onClick})
end

local userOptionFields

local function arrayGroupFields(fields, data, option, config, path, indent)
	local references = option.references
	local first = firstReference(option)
	local firstOption = first and first.options[first.index] or option
	local firstConfig = first and first.config or config
	local firstEntries = references and firstConfig and firstConfig[firstOption.key]
	if type(firstEntries) ~= "table" then firstEntries = arrayEntries(config, option) end
	local count = table.getn(firstEntries)
	local values, labels = {}, {}

	local function referenceEntries(reference)
		local childOption = reference.options[reference.index]
		local childConfig = reference.config or {}
		local entries = childConfig[childOption.key]
		if type(entries) ~= "table" then entries = {} end
		return entries, childOption
	end

	local function mergedCount()
		local result = count
		if references then
			result = 0
			for _, reference in pairs(references) do
				local entries = referenceEntries(reference)
				if table.getn(entries) > result then result = table.getn(entries) end
			end
		end
		return result
	end

	local function mergedLabel(index)
		if not references then return arrayEntryLabel(option, firstEntries[index], index) end
		local label, conflict = nil, false
		for _, reference in pairs(references) do
			local entries, childOption = referenceEntries(reference)
			local current = arrayEntryLabel(childOption, entries[index], index)
			if label == nil then label = current
			elseif label ~= current then conflict = true end
		end
		if conflict or label == nil then return "Entry " .. tostring(index) end
		return label
	end

	count = mergedCount()
	for i = 1, count do
		values[i] = i
		labels[i] = mergedLabel(i)
	end

	local function referencePage(reference)
		local entries = referenceEntries(reference)
		return getArrayPage(reference.data, reference.path, table.getn(entries))
	end

	local function currentPage()
		if not references then return getArrayPage(data, path, table.getn(arrayEntries(config, option))) end
		local page, found = nil, false
		for _, reference in pairs(references) do
			local current = referencePage(reference)
			if not found then page, found = current, true
			elseif page ~= current then return nil end
		end
		return page
	end

	local actions = {}
	local iconDir = WA.Widgets and WA.Widgets.LIBWIDGETS_TEXTURES or
		"Interface\\AddOns\\WeakestAuras\\libs\\LibWidgets\\textures\\"
	table.insert(fields, {
		type = "select", name = option.name or option.key or "Group",
		values = values, labels = labels, half = customOptionHalf(option),
		actions = actions,
		configPath = optionPathString(path),
		get = function()
			if count == 0 or (references and not currentPage()) then return nil end
			return currentPage()
		end,
		set = function(value)
			if references then
				for _, reference in pairs(references) do setArrayPage(reference.data, reference.path, value) end
			else
				setArrayPage(data, path, value)
			end
			if WA.RefreshOptions then WA.RefreshOptions() end
		end,
	})

	if option.limitType ~= "fixed" then
		local canAdd = true
		if references then
			for _, reference in pairs(references) do
				local entries, childOption = referenceEntries(reference)
				if childOption.limitType ~= "none" and table.getn(entries) >= (tonumber(childOption.size) or 0) then
					canAdd = false
				end
			end
		else
			canAdd = option.limitType == "none" or count < (tonumber(option.size) or 0)
		end
		if canAdd then
			arrayAction(actions, "Interface\\Buttons\\UI-PlusButton-Up", "Add Entry", function()
				if references then
					for _, reference in pairs(references) do
						local current, childOption = referenceEntries(reference)
						if childOption.limitType == "none" or table.getn(current) < (tonumber(childOption.size) or 0) then
							table.insert(current, {})
							setArrayPage(reference.data, reference.path, table.getn(current))
						end
					end
					arrayReferenceChanged(option)
				else
					local current = arrayEntries(config, option)
					if option.limitType ~= "none" and table.getn(current) >= (tonumber(option.size) or 0) then return end
					table.insert(current, {})
					setArrayPage(data, path, table.getn(current))
					arrayConfigChanged(data)
				end
			end)
		end
	end

	if count > 1 and not option.hideReorder and option.nameSource ~= -1 then
		arrayAction(actions, iconDir .. "up", "Move Entry Up", function()
			if references then
				for _, reference in pairs(references) do
					local current = referenceEntries(reference)
					local page = referencePage(reference)
					if page > 1 and current[page] then
						current[page], current[page - 1] = current[page - 1], current[page]
						setArrayPage(reference.data, reference.path, page - 1)
					end
				end
				arrayReferenceChanged(option)
			else
				local current = arrayEntries(config, option)
				local page = getArrayPage(data, path, table.getn(current))
				if page <= 1 or not current[page] then return end
				current[page], current[page - 1] = current[page - 1], current[page]
				setArrayPage(data, path, page - 1)
				arrayConfigChanged(data)
			end
		end)
		arrayAction(actions, iconDir .. "down", "Move Entry Down", function()
			if references then
				for _, reference in pairs(references) do
					local current = referenceEntries(reference)
					local page = referencePage(reference)
					if page < table.getn(current) and current[page] then
						current[page], current[page + 1] = current[page + 1], current[page]
						setArrayPage(reference.data, reference.path, page + 1)
					end
				end
				arrayReferenceChanged(option)
			else
				local current = arrayEntries(config, option)
				local page = getArrayPage(data, path, table.getn(current))
				if page >= table.getn(current) or not current[page] then return end
				current[page], current[page + 1] = current[page + 1], current[page]
				setArrayPage(data, path, page + 1)
				arrayConfigChanged(data)
			end
		end)
	end

	if option.limitType ~= "fixed" and count > 0 then
		arrayAction(actions, LibWidgets.ICON_DELETE, "Delete Entry", function()
			if references then
				for _, reference in pairs(references) do
					local current = referenceEntries(reference)
					local page = referencePage(reference)
					if table.getn(current) > 0 then
						table.remove(current, page)
						setArrayPage(reference.data, reference.path, math.min(page, table.getn(current)))
					end
				end
				arrayReferenceChanged(option)
			else
				local current = arrayEntries(config, option)
				local page = getArrayPage(data, path, table.getn(current))
				if table.getn(current) == 0 then return end
				table.remove(current, page)
				local newCount = table.getn(current)
				setArrayPage(data, path, newCount > 0 and math.min(page, newCount) or 1)
				arrayConfigChanged(data)
			end
		end)
	end

	local page = currentPage() or (references and referencePage(first) or getArrayPage(data, path, count))
	local selected = firstEntries[page]
	if references and not selected then
		for _, reference in pairs(references) do
			local entries = referenceEntries(reference)
			if entries[page] then selected = entries[page]; break end
		end
	end
	if count > 0 and selected then
		userOptionFields(fields, data, option.subOptions, selected, path, indent + 1)
	end
end

local function annotateFields(fields, start, indent, key, value)
	for i = start + 1, table.getn(fields) do
		if indent and indent > 0 then fields[i].indent = indent end
		if key then fields[i][key] = value end
	end
end

local function optionSubConfig(option, config)
	local reference = firstReference(option)
	if reference then
		local childOption = reference.options[reference.index]
		local childConfig = referenceConfig(reference)
		if childConfig and type(childConfig[childOption.key]) ~= "table" then
			childConfig[childOption.key] = {}
		end
		return childConfig and childConfig[childOption.key] or {}
	end
	if type(config[option.key]) ~= "table" then config[option.key] = {} end
	return config[option.key]
end

local function optionCollapsed(option, data, path, defaultCollapsed)
	if not WA.OptionsState then return defaultCollapsed end
	if not option.references then
		return WA.OptionsState.isCollapsed(data, "config:" .. optionPathString(path), defaultCollapsed)
	end
	for _, reference in pairs(option.references) do
		if WA.OptionsState.isCollapsed(reference.data, "config:" .. optionPathString(reference.path), defaultCollapsed) then
			return true
		end
	end
	return false
end

local function setOptionCollapsed(option, data, path, value)
	if not WA.OptionsState then return end
	if not option.references then
		WA.OptionsState.setCollapsed(data, "config:" .. optionPathString(path), value)
		return
	end
	for _, reference in pairs(option.references) do
		WA.OptionsState.setCollapsed(reference.data, "config:" .. optionPathString(reference.path), value)
	end
end

userOptionFields = function(fields, data, options, config, path, indent)
	for index = 1, table.getn(options or {}) do
		local option = options[index]
		local optionPath = copyOptionPath(path, index)
		local start = table.getn(fields)
		local optionClass = option and WA.author_option_classes[option.type]
		if optionClass == "simple" then
			simpleOptionField(fields, data, option, config)
		elseif optionClass == "noninteractive" then
			if option.type == "description" then
				table.insert(fields, {
					type = "description",
					name = option.useDesc and option.desc or option.text or "",
					half = customOptionHalf(option),
				})
			elseif option.type == "header" then
				table.insert(fields, {
					type = "header",
					name = option.useName and option.name or option.text or "",
					half = customOptionHalf(option),
				})
			else
				table.insert(fields, {
					type = "space", half = customOptionHalf(option),
					useHeight = option.useHeight, height = option.height,
				})
			end
		elseif optionClass == "group" and option.groupType == "simple" then
			local collapseKey = "config:" .. optionPathString(optionPath)
			local defaultCollapsed = option.collapse
			if defaultCollapsed == nil then defaultCollapsed = true end
			local collapsed = optionCollapsed(option, data, optionPath, defaultCollapsed)
			if option.useCollapse then
				table.insert(fields, {
					type = "header", name = option.name or option.key or "Group",
					collapsed = collapsed, configPath = optionPathString(optionPath),
					onToggle = function()
						setOptionCollapsed(option, data, optionPath, not collapsed)
						if WA.RefreshOptions then WA.RefreshOptions() end
					end,
				})
				annotateFields(fields, start, indent, "configPath", optionPathString(optionPath))
			end
			if not collapsed or not option.useCollapse then
				local childConfig = optionSubConfig(option, config)
				userOptionFields(fields, data, option.subOptions, childConfig, optionPath, indent + 1)
			end
		elseif optionClass == "group" and option.groupType == "array" then
			local collapseKey = "config:" .. optionPathString(optionPath)
			local defaultCollapsed = option.collapse
			if defaultCollapsed == nil then defaultCollapsed = true end
			local collapsed = optionCollapsed(option, data, optionPath, defaultCollapsed)
			if option.useCollapse then
				table.insert(fields, {
					type = "header", name = option.name or option.key or "Group",
					collapsed = collapsed, configPath = optionPathString(optionPath),
					onToggle = function()
						setOptionCollapsed(option, data, optionPath, not collapsed)
						if WA.RefreshOptions then WA.RefreshOptions() end
					end,
				})
				annotateFields(fields, start, indent, "configPath", optionPathString(optionPath))
			end
			if not collapsed or not option.useCollapse then
				arrayGroupFields(fields, data, option, config, optionPath, indent)
			end
		elseif optionClass == "group" or not optionClass then
			placeholderField(fields, option or {})
		end
		if not (optionClass == "group" and (option.groupType == "simple" or option.groupType == "array")) then
			annotateFields(fields, start, indent, "configPath", optionPathString(optionPath))
		end
	end
end

local function authorOptionBlock(fields, data, options, index, option, path, indent)
	local optionPath = copyOptionPath(path, index)
	local pathKey = optionPathString(optionPath)
	local collapsed = WA.OptionsState and WA.OptionsState.isCollapsed(
		data, "author:" .. pathKey, true) or false
	local start = table.getn(fields)
	local title = option.name or option.text or option.key or "Option " .. index
	table.insert(fields, authorField({
		type = "header", name = title, collapsed = collapsed,
		actions = authorOptionActions(data, options, index, option),
		onToggle = function()
			if WA.OptionsState then
				WA.OptionsState.setCollapsed(data, "author:" .. pathKey, not collapsed)
			end
			if WA.RefreshOptions then WA.RefreshOptions() end
		end,
	}, index, "header"))
	annotateFields(fields, start, indent, "authorPath", pathKey)
	if not collapsed then
		local bodyStart = table.getn(fields)
		authorOptionFields(fields, data, option, index, options)
		annotateFields(fields, bodyStart, indent, "authorPath", pathKey)
		if WA.author_option_classes[option.type] == "group" then
			for childIndex = 1, table.getn(option.subOptions or {}) do
				authorOptionBlock(fields, data, option.subOptions, childIndex,
					option.subOptions[childIndex], optionPath, indent + 1)
			end
		end
	end
end

local function authorModeFields(fields, data)
	data.authorOptions = data.authorOptions or {}
	for index = 1, table.getn(data.authorOptions) do
		authorOptionBlock(fields, data, data.authorOptions, index,
			data.authorOptions[index], {}, 0)
	end

	table.insert(fields, {type = "header", name = ""})
	table.insert(fields, {
		type = "button", name = "Add Option", authorAction = "add",
		onClick = function()
			local index = table.getn(data.authorOptions) + 1
			local option = {
				type = "toggle", name = "Option " .. index,
				key = ensureUniqueAuthorKey("option" .. index, "", data.authorOptions, 1),
				default = false, width = 1, useDesc = false,
			}
			table.insert(data.authorOptions, option)
			authorOptionChanged(data)
		end,
	})
	table.insert(fields, {
		type = "button", name = "Enter User Mode", authorAction = "enterUser",
		onClick = function()
			data.authorMode = false
			authorOptionChanged(data)
		end,
	})
end

local function groupLeafData(data)
	local leaves = {}
	if WA.OptionsState and WA.OptionsState.leafDescendants then
		local ids = WA.OptionsState.leafDescendants(data.id)
		for i = 1, table.getn(ids) do
			local child = WeakestAurasDB.displays[ids[i]]
			if child then table.insert(leaves, child) end
		end
	end
	return leaves
end

local function mergedGroupOptions(data)
	local merged = {}
	local leaves = groupLeafData(data)
	for i = 1, table.getn(leaves) do
		local child = leaves[i]
		mergeOptions(merged, child, child.authorOptions or {}, child.config or {}, {}, nil)
	end
	return merged
end

local function userModeFields(fields, data, options)
	local merged = options ~= nil
	options = options or data.authorOptions or {}
	userOptionFields(fields, data, options, data.config or {}, {}, 0)
	table.insert(fields, {type = "header", name = ""})
	table.insert(fields, {
		type = "button", name = "Reset to Defaults",
		onClick = function()
			if merged then
				local leaves = groupLeafData(data)
				for i = 1, table.getn(leaves) do
					local child = leaves[i]
					child.config = {}
					WA.ValidateUserConfig(child)
					WA.Add(child, true)
					WA.RefreshAuraEnvConfig(child.id)
				end
			else
				data.config = {}
				WA.ValidateUserConfig(data)
				WA.Add(data, true)
				WA.RefreshAuraEnvConfig(data.id)
			end
			if WA.RefreshOptions then WA.RefreshOptions() end
		end,
	})
	if not merged then
		table.insert(fields, {
			type = "button", name = "Enter Author Mode", authorAction = "enterAuthor",
			onClick = function()
				data.authorMode = true
				authorOptionChanged(data)
			end,
		})
	end
end

function WA.CustomOptionsFields(fields, data)
	if not data then return end
	if WA.IsGroup(data) then
		userModeFields(fields, data, mergedGroupOptions(data))
	elseif data.authorMode then
		authorModeFields(fields, data)
	else
		userModeFields(fields, data)
	end
end
