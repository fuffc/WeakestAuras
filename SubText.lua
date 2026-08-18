-- WeakestAuras -- the "subtext" sub-region: a placeholder-driven FontString a
-- display can carry any number of (stacks, remaining time, name...). Mirrors
-- WA2's SubText (§8/§9).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- An instance is a plain object wrapping a FontString parented to the region.
-- It never polls: it subscribes to the region's subRegionEvents bus -- "Update"
-- (state changed) always, "FrameTick" only when its text contains %p, "PreShow"
-- to reassert visibility a condition may have cleared. Text is resolved through
-- WA.ReplacePlaceHolders against the region's active state, via the per-symbol
-- formatters built from this instance's text_text_format_* settings.

if WeakestAuras.disabled then return end

local WA = WeakestAuras
local proto = WA.regionPrototype

-- The nine standard frame anchor points offered by the Anchor dropdown.
local TEXT_ANCHORS = {
	"TOPLEFT", "TOP", "TOPRIGHT",
	"LEFT", "CENTER", "RIGHT",
	"BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

-- Per-symbol format settings (WA.format_types) are flat keys on the sub-region
-- under upstream's layout, text_text_format_<symbol>_<setting>. Both the
-- formatter build and the options generator address them through these.
local function formatGetter(subData)
	return function(key, default)
		local v = subData["text_text_format_" .. key]
		if v == nil then return default end
		return v
	end
end

-- Every string this text can end up showing: its own, plus any a condition can
-- swap in through text_text. Formatters are built once over the whole set, the
-- way the standalone text region does it (`displayTexts`), so a condition
-- supplying a %p hands over an already-formatted symbol rather than rendering
-- raw until the next modify. The scan is not narrowed to this instance's own
-- index -- modify is not told which index it is -- so a sibling's strings are
-- swept in too; a formatter for a symbol this text never shows is one unused
-- table entry.
local function subTexts(parentData, subData)
	local texts = { subData.text_text or "" }
	local conditions = parentData.conditions or {}
	for i = 1, table.getn(conditions) do
		local changes = conditions[i].changes or {}
		for c = 1, table.getn(changes) do
			local change = changes[c]
			local _, _, suffix = string.find(change.property or "", "^sub%.[0-9]+%.(.*)$")
			if suffix == "text_text" and type(change.value) == "string" then
				table.insert(texts, change.value)
			end
		end
	end
	return texts
end

WA.RegisterSubRegionType("subtext", {
	displayName = "Text",
	supports = function(regionType)
		return regionType == "icon" or regionType == "progressbar" or regionType == "texture"
			or regionType == "progresstexture"
	end,
	default = {
		type = "subtext",
		text_text = "%s",
		text_color = { 1, 1, 1, 1 },
		text_fontSize = 12,
		anchor_point = "CENTER",
		anchorXOffset = 0,
		anchorYOffset = 0,
		text_visible = true,
	},
	-- Icon: a %s stacks text bottom-right. Bar: %n name at the left, %p time at
	-- the right (upstream's own new-aura defaults, §8).
	addDefaultsForNewAura = function(data)
		if data.regionType == "icon" then
			table.insert(data.subRegions, {
				type = "subtext", text_text = "%s", text_color = { 1, 1, 1, 1 },
				text_fontSize = 12, anchor_point = "BOTTOMRIGHT", anchorXOffset = -2, anchorYOffset = 2,
				text_visible = true,
			})
		elseif data.regionType == "progressbar" then
			-- Offsets are from the *bar*, not the whole region (see modify below),
			-- so neither has to leave room for an icon that may not be there.
			table.insert(data.subRegions, {
				type = "subtext", text_text = "%n", text_color = { 1, 1, 1, 1 },
				text_fontSize = 10, anchor_point = "LEFT", anchorXOffset = 3, anchorYOffset = 0,
				text_visible = true,
			})
			table.insert(data.subRegions, {
				type = "subtext", text_text = "%p", text_color = { 1, 1, 1, 1 },
				text_fontSize = 10, anchor_point = "RIGHT", anchorXOffset = -3, anchorYOffset = 0,
				text_visible = true,
			})
		end
	end,
	-- Condition-overridable properties, namespaced sub.<n>.* (§8). Each setter
	-- is a method defined in create below.
	-- The offset keys keep upstream's `text_anchorXOffset` naming while pointing
	-- `dataKey` at our own saved field (`anchorXOffset`, renamed from `text_x` at
	-- internalVersion 3): WA2Import carries condition property names through
	-- verbatim, so an imported condition only lands if the property is spelled
	-- the way upstream spells it.
	properties = {
		text_visible = { display = "Visible", setter = "SetVisible", type = "bool" },
		text_text = { display = "Text", setter = "ChangeText", type = "string" },
		text_color = { display = "Color", setter = "SetTextColor", type = "color" },
		text_fontSize = { display = "Font Size", setter = "SetTextHeight", type = "number", min = 6, max = 48, step = 1 },
		text_anchorXOffset = { display = "X-Offset", setter = "SetXOffset", type = "number",
			min = -500, max = 500, step = 1, dataKey = "anchorXOffset" },
		text_anchorYOffset = { display = "Y-Offset", setter = "SetYOffset", type = "number",
			min = -500, max = 500, step = 1, dataKey = "anchorYOffset" },
	},
	create = function(parent)
		local region = { parent = parent }
		-- The FontString lives in a frame of its own, not on the region: a child
		-- frame's draw layers all sit above its parent's, so text created directly
		-- on the region renders *under* anything the region type builds as a child
		-- frame -- the progress bar, the icon's cooldown swipe. modifyFinish
		-- (re)asserts the level after every modify, since SetParent resets it.
		local frame = CreateFrame("Frame", nil, parent)
		frame:SetAllPoints(parent)
		region.frame = frame
		local fs = frame:CreateFontString(nil, "OVERLAY")
		region.fontString = fs

		function region:Update()
			WA.textCore.SetText(self.fontString,
				WA.ReplacePlaceHolders(self.text or "", self.parent, self.formatters))
		end
		function region:SetFrameLevel(level) self.frame:SetFrameLevel(level) end
		function region:Show() if self.visible ~= false then self.fontString:Show() end end
		function region:Hide() self.fontString:Hide() end
		function region:SetVisible(b)
			self.visible = b
			if b then self.fontString:Show() else self.fontString:Hide() end
		end
		function region:SetTextColor(r, g, b, a)
			self.fontString:SetTextColor(r, g, b, a or 1)
		end
		function region:SetTextHeight(size)
			WA.textCore.Apply(self.fontString, self.subData, "text_", size, WA.textCore.SUBTEXT_KEYS)
			self.fontString:SetTextHeight(size)
		end

		-- One stable reference per instance rather than a fresh closure per
		-- modify: RemoveSubscriber matches by identity, so a tick subscribed as an
		-- anonymous function can be added but never taken off again -- which is
		-- what ChangeText below needs to do when a %p string is swapped out.
		region.frameTick = function() region:Update() end

		-- Two independent reasons to repaint per frame: the string's own (%p, or
		-- an every-frame formatter), and a %c whose function runs per frame. The
		-- second is the parent's setting, asked one level up. Re-derived rather
		-- than decided once at modify, because a condition can swap the whole
		-- string afterwards: one that gains a %p has to start ticking, one that
		-- loses it has to stop.
		function region:ConfigureTick()
			local host = self.parent
			host.subRegionEvents:RemoveSubscriber("FrameTick", self.frameTick)
			local needsTick = WA.TextNeedsFrameTick(self.text, self.everyFrameFormatters)
				or (host.customTextFunc ~= nil and host.customTextMode == "update"
					and WA.ContainsCustomPlaceHolder(self.text))
			if needsTick then
				host.subRegionEvents:AddSubscriber("FrameTick", self.frameTick)
			end
			proto.RefreshFrameTick(host)
		end

		function region:ChangeText(msg)
			self.text = msg or ""
			self:ConfigureTick()
			self:Update()
		end

		-- Offsets are re-applied through the shared anchor resolver rather than a
		-- bare SetPoint: it owns which target and which points this sub-region is
		-- anchored against, and only the two numbers are being overridden.
		function region:ApplyAnchor()
			local effective = self.subData
			if self.xOffset ~= nil or self.yOffset ~= nil then
				effective = {}
				for k, v in pairs(self.subData) do effective[k] = v end
				if self.xOffset ~= nil then effective.anchorXOffset = self.xOffset end
				if self.yOffset ~= nil then effective.anchorYOffset = self.yOffset end
			end
			proto.AnchorSubRegion(self.fontString, self.parent, effective, self.anchorDefaults)
		end
		function region:SetXOffset(v) self.xOffset = v; self:ApplyAnchor() end
		function region:SetYOffset(v) self.yOffset = v; self:ApplyAnchor() end

		return region
	end,
	modify = function(parent, region, parentData, subData)
		region.subData = subData
		region.text = subData.text_text or ""
		region.visible = subData.text_visible ~= false
		-- Config is the source of truth again on every modify; a condition that
		-- is still active re-applies its override immediately afterwards.
		region.xOffset, region.yOffset = nil, nil
		region.formatters, region.everyFrameFormatters =
			WA.CreateFormatters(subTexts(parentData, subData), formatGetter(subData), parentData)

		local fs = region.fontString
		WA.textCore.Apply(fs, subData, "text_", nil, WA.textCore.SUBTEXT_KEYS)

		region.anchorDefaults = {
			mode = subData.anchor_mode or "point", target = parent.subRegionAnchor and "bar" or "region",
			anchorPoint = subData.anchor_point or "CENTER",
			selfPoint = subData.anchor_point or "CENTER",
			x = subData.anchorXOffset or 0, y = subData.anchorYOffset or 0,
		}
		region:ApplyAnchor()

		if region.visible then fs:Show() else fs:Hide() end

		parent.subRegionEvents:AddSubscriber("Update", function() region:Update() end)
		parent.subRegionEvents:AddSubscriber("PreShow", function()
			if region.visible then fs:Show() end
		end)
		-- The parent has already subscribed its own %c refresh ahead of this, so
		-- what a tick leaves to do here is re-resolve the string against the
		-- values it just recomputed.
		region:ConfigureTick()

		region:Update()
	end,
	-- BuildOptions field array for OptionsFrame's Display Effects list.
	options = function(parentData, subData, index)
		local fields = {
			{
				-- %i is absent from the label deliberately: it resolves to nothing
				-- here, this client's FontString having no inline texture escape.
				type = "input", name = "Text (%p %t %n %s %c)", key = "text_text",
				get = function() return subData.text_text end,
				-- Re-renders the tab: Format Options below is one row per symbol
				-- in this string, so editing it changes which rows exist.
				set = function(v)
					subData.text_text = v
					WA.SetDefaultFormatters(subData.text_text, formatGetter(subData),
						function(key, value) subData["text_text_format_" .. key] = value end,
						parentData)
					WA.Add(parentData, true)
					WA.RefreshOptions()
				end,
			},
			{
				type = "range", name = "Size", key = "text_fontSize", min = 6, max = 48, step = 1, half = true,
				get = function() return subData.text_fontSize end,
				set = function(v) subData.text_fontSize = v; WA.Add(parentData, true) end,
			},
			{
				type = "color", name = "Color", key = "text_color",
				get = function() return subData.text_color end,
				set = function(v) subData.text_color = v; WA.Add(parentData, true) end,
			},
		}
		local anchorFields = WA.regionPrototype.SubRegionAnchorFields(parentData, subData, {
			mode = subData.anchor_mode or "point", target = parentData.regionType == "progressbar" and "bar" or "region",
			anchorPoint = subData.anchor_point or "CENTER",
			selfPoint = subData.anchor_point or "CENTER",
			x = subData.anchorXOffset or 0, y = subData.anchorYOffset or 0,
		})
		for i = 1, table.getn(anchorFields) do table.insert(fields, anchorFields[i]) end

		-- Directly under the Text field, whose label can only name the five
		-- built-in symbols.
		local hint = WA.TextSymbolHint(parentData)
		if hint then table.insert(fields, 2, { type = "description", name = hint }) end

		-- Keyed inside the "sub:" namespace for the same reason the Format fold
		-- below is: removing a sub-region renumbers the rest, and clearCollapsed
		-- drops the whole namespace with it.
		local fontFields = WA.textCore.OptionFields(parentData, "sub:" .. index .. ":font",
			function(key) return subData["text_" .. key] end,
			function(key, v)
				subData["text_" .. key] = v
				WA.Add(parentData, true)
			end, WA.textCore.SUBTEXT_KEYS)
		for i = 1, table.getn(fontFields) do table.insert(fields, fontFields[i]) end

		local get = formatGetter(subData)
		local formatFields = WA.FormatOptionFields(subData.text_text, get,
			function(key, v)
				subData["text_text_format_" .. key] = v
				WA.Add(parentData, true)
			end, parentData)
		if table.getn(formatFields) > 0 then
			-- Folded away by default: every %symbol in the text grows a Format row,
			-- and with two or three symbols those rows bury the ones actually being
			-- edited under settings that get chosen once. The summary keeps the
			-- closed line honest about what they hold.
			--
			-- Keyed inside the "sub:" namespace so removing a sub-region clears this
			-- along with that sub-region's own fold state (OptionsFrame's
			-- clearCollapsed) -- otherwise the renumbering would land it on a
			-- different text's format rows.
			local S = WA.OptionsState
			local key = "sub:" .. index .. ":format"
			local collapsed = S.isCollapsed(parentData, key, true)
			table.insert(fields, {
				type = "disclosure", name = "Format Options",
				summary = WA.FormatSummary(subData.text_text, get, parentData),
				collapsed = collapsed,
				onToggle = function()
					S.setCollapsed(parentData, key, not collapsed)
					WA.RefreshOptions()
				end,
			})
			if not collapsed then
				for i = 1, table.getn(formatFields) do
					table.insert(fields, formatFields[i])
				end
			end
		end

		return fields
	end,
})
