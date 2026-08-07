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

WA.RegisterSubRegionType("subtext", {
	displayName = "Text",
	supports = function(regionType)
		return regionType == "icon" or regionType == "progressbar"
	end,
	default = {
		type = "subtext",
		text_text = "%s",
		text_color = { 1, 1, 1, 1 },
		text_size = 12,
		text_anchorPoint = "CENTER",
		text_x = 0,
		text_y = 0,
		text_visible = true,
	},
	-- Icon: a %s stacks text bottom-right. Bar: %n name at the left, %p time at
	-- the right (upstream's own new-aura defaults, §8).
	addDefaultsForNewAura = function(data)
		if data.regionType == "icon" then
			table.insert(data.subRegions, {
				type = "subtext", text_text = "%s", text_color = { 1, 1, 1, 1 },
				text_size = 12, text_anchorPoint = "BOTTOMRIGHT", text_x = -2, text_y = 2,
				text_visible = true,
			})
		elseif data.regionType == "progressbar" then
			-- Offsets are from the *bar*, not the whole region (see modify below),
			-- so neither has to leave room for an icon that may not be there.
			table.insert(data.subRegions, {
				type = "subtext", text_text = "%n", text_color = { 1, 1, 1, 1 },
				text_size = 10, text_anchorPoint = "LEFT", text_x = 3, text_y = 0,
				text_visible = true,
			})
			table.insert(data.subRegions, {
				type = "subtext", text_text = "%p", text_color = { 1, 1, 1, 1 },
				text_size = 10, text_anchorPoint = "RIGHT", text_x = -3, text_y = 0,
				text_visible = true,
			})
		end
	end,
	-- Condition-overridable properties, namespaced sub.<n>.* (§8). Each setter
	-- is a method defined in create below.
	properties = {
		text_visible = { display = "Visible", setter = "SetVisible", type = "bool" },
		text_color = { display = "Color", setter = "SetTextColor", type = "color" },
	},
	create = function(parent)
		local region = { parent = parent }
		-- The FontString lives in a frame of its own, not on the region: a child
		-- frame's draw layers all sit above its parent's, so text created directly
		-- on the region renders *under* anything the region type builds as a child
		-- frame -- the progress bar, the icon's cooldown swipe. The level is
		-- (re)asserted in modify, since SetParent resets it.
		local frame = CreateFrame("Frame", nil, parent)
		frame:SetAllPoints(parent)
		region.frame = frame
		local fs = frame:CreateFontString(nil, "OVERLAY")
		region.fontString = fs

		function region:Update()
			WA.textCore.SetText(self.fontString,
				WA.ReplacePlaceHolders(self.text or "", self.parent, self.formatters))
		end
		function region:Show() if self.visible ~= false then self.fontString:Show() end end
		function region:Hide() self.fontString:Hide() end
		function region:SetVisible(b)
			self.visible = b
			if b then self.fontString:Show() else self.fontString:Hide() end
		end
		function region:SetTextColor(r, g, b, a)
			self.fontString:SetTextColor(r, g, b, a or 1)
		end
		return region
	end,
	modify = function(parent, region, parentData, subData)
		region.text = subData.text_text or ""
		region.visible = subData.text_visible ~= false
		region.formatters, region.everyFrameFormatters =
			WA.CreateFormatters(region.text, formatGetter(subData), parentData)

		local fs = region.fontString
		WA.textCore.Apply(fs, subData, "text_")

		region.frame:SetFrameLevel(parent:GetFrameLevel() + WA.regionPrototype.SUB_LEVEL)

		-- Anchored to the region's text anchor rather than the region itself: a
		-- progress bar sets it to the bar, so "%p at RIGHT" lands at the end of the
		-- fill instead of past the icon beside it (WA2's AuraBar AnchorSubRegion
		-- defaults anchorRegion to self.bar for the same reason).
		local anchor = parent.subRegionAnchor or parent
		local point = subData.text_anchorPoint or "CENTER"
		fs:ClearAllPoints()
		fs:SetPoint(point, anchor, point, subData.text_x or 0, subData.text_y or 0)

		if region.visible then fs:Show() else fs:Hide() end

		parent.subRegionEvents:AddSubscriber("Update", function() region:Update() end)
		parent.subRegionEvents:AddSubscriber("PreShow", function()
			if region.visible then fs:Show() end
		end)
		if WA.TextNeedsFrameTick(region.text, region.everyFrameFormatters) then
			parent.subRegionEvents:AddSubscriber("FrameTick", function() region:Update() end)
		end

		region:Update()
	end,
	-- BuildOptions field array for OptionsFrame's Display Effects list.
	options = function(parentData, subData, index)
		local fields = {
			{
				-- %i is absent from the label deliberately: it resolves to nothing
				-- here, this client's FontString having no inline texture escape.
				type = "input", name = "Text (%p %t %n %s)", key = "text_text",
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
				type = "range", name = "Size", key = "text_size", min = 6, max = 48, step = 1, half = true,
				get = function() return subData.text_size end,
				set = function(v) subData.text_size = v; WA.Add(parentData, true) end,
			},
			{
				type = "select", name = "Anchor", key = "text_anchorPoint", values = TEXT_ANCHORS, half = true,
				get = function() return subData.text_anchorPoint end,
				set = function(v) subData.text_anchorPoint = v; WA.Add(parentData, true) end,
			},
			{
				type = "color", name = "Color", key = "text_color",
				get = function() return subData.text_color end,
				set = function(v) subData.text_color = v; WA.Add(parentData, true) end,
			},
			{
				type = "range", name = "X", key = "text_x", min = -200, max = 200, step = 1, half = true,
				get = function() return subData.text_x end,
				set = function(v) subData.text_x = v; WA.Add(parentData, true) end,
			},
			{
				type = "range", name = "Y", key = "text_y", min = -200, max = 200, step = 1, half = true,
				get = function() return subData.text_y end,
				set = function(v) subData.text_y = v; WA.Add(parentData, true) end,
			},
		}

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
			end)
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
