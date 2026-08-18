-- WeakestAuras -- the "subborder" sub-region: a solid edge drawn around the
-- whole region. Mirrors WA2's Border (§8), including its field names.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- A backdrop Frame area-anchored over the parent and tinted via
-- SetBackdropBorderColor; SetBackdrop{edgeFile,edgeSize} is native on 1.12
-- (tooltips use it). Opt-in: addDefaultsForNewAura does not seed one, so an
-- aura carries a border only once the user adds it.

if WeakestAuras.disabled then return end

local WA = WeakestAuras
local proto = WA.regionPrototype

-- Stock solid-white texture on 1.12; tinted to any colour by the backdrop
-- border colour. A solid edge, sized by border_size.
local EDGE = "Interface\\Buttons\\WHITE8X8"

WA.RegisterSubRegionType("subborder", {
	displayName = "Border",
	supports = function(regionType)
		return regionType == "icon" or regionType == "progressbar" or regionType == "text"
			or regionType == "texture" or regionType == "progresstexture"
	end,
	default = {
		type = "subborder",
		border_visible = true,
		border_color = { 0, 0, 0, 1 },
		border_size = 1,
		border_offset = 0,
		anchor_mode = "area",
		anchor_area = "region",
	},
	-- Condition-overridable (§8): visibility + colour. Size/offset are
	-- config-only (a condition animating border thickness is niche).
	properties = {
		border_visible = { display = "Visible", setter = "SetVisible", type = "bool" },
		border_color = { display = "Color", setter = "SetBorderColor", type = "color" },
	},
	create = function(parent)
		local region = { parent = parent }
		local frame = CreateFrame("Frame", nil, parent)
		region.frame = frame

		function region:SetVisible(b)
			self.visible = b
			if b then self.frame:Show() else self.frame:Hide() end
		end
		function region:SetBorderColor(r, g, b, a)
			self.frame:SetBackdropBorderColor(r, g, b, a or 1)
		end
		function region:SetFrameLevel(level) self.frame:SetFrameLevel(level) end
		function region:Show() if self.visible ~= false then self.frame:Show() end end
		function region:Hide() self.frame:Hide() end
		return region
	end,
	modify = function(parent, region, parentData, subData)
		region.visible = subData.border_visible ~= false

		local frame = region.frame
		proto.AnchorSubRegion(frame, parent, subData, {
			areaOnly = true, areaTarget = "region", x = subData.border_offset or 0,
			y = subData.border_offset or 0,
		})
		local size = subData.border_size or 1
		if size < 1 then size = 1 end
		frame:SetBackdrop({ edgeFile = EDGE, edgeSize = size })
		local c = subData.border_color or { 0, 0, 0, 1 }
		frame:SetBackdropBorderColor(c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 1)

		if region.visible then frame:Show() else frame:Hide() end

		-- Reassert a condition-cleared visibility when the region reappears
		-- (same shape subtext uses for text_visible). No per-frame work, so no
		-- Update/FrameTick subscription.
		parent.subRegionEvents:AddSubscriber("PreShow", function()
			if region.visible then frame:Show() end
		end)
	end,
	-- BuildOptions field array for OptionsFrame's Display Effects list.
	options = function(parentData, subData, index)
		local fields = {
			{
				type = "toggle", name = "Show border", key = "border_visible",
				get = function() return subData.border_visible ~= false end,
				set = function(v) subData.border_visible = v and true or false; WA.Add(parentData, true) end,
			},
			{
				type = "color", name = "Color", key = "border_color",
				get = function() return subData.border_color end,
				set = function(v) subData.border_color = v; WA.Add(parentData, true) end,
			},
			{
				type = "range", name = "Size", key = "border_size", min = 1, max = 16, step = 1, half = true,
				get = function() return subData.border_size end,
				set = function(v) subData.border_size = v; WA.Add(parentData, true) end,
			},
		}
		local anchorFields = proto.SubRegionAnchorFields(parentData, subData, {
			areaOnly = true, areaTarget = "region", x = subData.border_offset or 0,
			y = subData.border_offset or 0,
		})
		for i = 1, table.getn(anchorFields) do table.insert(fields, anchorFields[i]) end
		return fields
	end,
})
