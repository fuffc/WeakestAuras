-- WeakestAuras -- the "subtick" sub-region: a marker drawn across a progress
-- bar's fill axis, placed either at a threshold in the bar's value space or by
-- following an independent progress source. Mirrors WA2's Tick (§8), including
-- its field names.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- One marker per instance (subData.tick_placement is a plain number, not
-- upstream's tick_placements array -- our sub-region list already supports N
-- instances, so a second marker is a second subRegions entry). The marker rides
-- the four doors the progressbar region exposes: GetBarGeometry, PlaceOnBar,
-- GetInverse and GetProgress, and is drawn on the bar frame itself rather than
-- the region, the same way the spark is.
--
-- No separate inverse_direction flag: a threshold sits at its value in the
-- bar's value space and flips with the bar, one rule, unlike upstream's own
-- flag which is seeded from the parent's inverse and then XORed against it
-- again. FollowSource maps its source's own 0..1 onto the bar's full length
-- instead, which upstream has no equivalent of.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local SOLID_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local DEFAULT_TEXTURE = "Interface\\CastingBar\\UI-CastingBar-Spark"

local PLACEMENT_MODES = { "AtValue", "AtMissingValue", "AtPercent", "FollowSource" }
local PLACEMENT_MODE_LABELS = {
	AtValue = "At Value",
	AtMissingValue = "At Missing Value",
	AtPercent = "At Percent",
	FollowSource = "Follow Source",
}
local BLEND_MODES = { "BLEND", "ADD" }
local BLEND_MODE_LABELS = { BLEND = "Blend", ADD = "Add" }

local function isVertical(o)
	return o == "VERTICAL" or o == "VERTICAL_INVERSE"
end

-- FollowSource's own source picker: the parent bar's fill (-2) plus one entry
-- per trigger on the aura, the same values/labels-map convention
-- proto.ProgressOptions uses. No -1 (automatic) and no 0 (manual) -- a fixed
-- value on a marker is what AtPercent already is.
local function progressSourceOptions(parentData)
	local values = { -2 }
	local labels = { [-2] = "This bar" }
	local triggerCount = parentData.triggers and table.getn(parentData.triggers) or 0
	for i = 1, triggerCount do
		table.insert(values, i)
		labels[i] = "Trigger " .. i
	end
	return values, labels
end

WA.RegisterSubRegionType("subtick", {
	displayName = "Tick",
	supports = function(regionType)
		return regionType == "progressbar"
	end,
	default = {
		type = "subtick",
		tick_visible = true,
		tick_color = { 1, 1, 1, 1 },
		tick_placement_mode = "AtValue",
		tick_placement = 50,
		tick_progressSource = -2,
		tick_thickness = 2,
		tick_length = 30,
		automatic_length = true,
		use_texture = false,
		tick_texture = DEFAULT_TEXTURE,
		tick_blend_mode = "ADD",
		tick_desaturate = false,
		tick_rotation = 0,
		tick_mirror = false,
		tick_xOffset = 0,
		tick_yOffset = 0,
	},
	-- Condition-overridable (§8): visibility, colour and placement -- one
	-- marker per instance, so this needs no arg1/index the way upstream's
	-- array-of-placements would.
	properties = {
		tick_visible = { display = "Visible", setter = "SetVisible", type = "bool" },
		tick_color = { display = "Color", setter = "SetTickColor", type = "color" },
		tick_placement = { display = "Placement", setter = "SetTickPlacement", type = "number", min = -1000, max = 1000, step = 1 },
	},
	create = function(parent)
		local _, _, _, bar = parent:GetBarGeometry()
		local region = { parent = parent }
		local texture = bar:CreateTexture(nil, "OVERLAY")
		region.texture = texture

		-- Combines the condition-set visible flag with the range gate below: a
		-- threshold outside the bar's current min/max must not park a marker on
		-- the end cap, and a condition forcing tick_visible on can't override
		-- that (upstream ANDs tick_visible with hasProgress the same way).
		function region:ApplyVisibility()
			if self.visible ~= false and self.inRange ~= false then
				self.texture:Show()
			else
				self.texture:Hide()
			end
		end

		function region:SetVisible(b)
			self.visible = b
			self:ApplyVisibility()
		end
		function region:SetTickColor(r, g, b, a)
			self.color = { r, g, b, a or 1 }
			self.texture:SetVertexColor(r, g, b, a or 1)
		end
		function region:SetTickPlacement(v)
			self.placement = tonumber(v) or 0
			self:UpdatePlacement()
		end

		-- Re-derives the marker's position (and whether it has anywhere valid
		-- to sit) from the parent's live value range or, in FollowSource, from
		-- the chosen source. Runs on every "Update" -- the range or the
		-- source's own state can move -- and, only in FollowSource, on every
		-- "FrameTick" too, since a swept marker has to move every frame.
		function region:UpdatePlacement()
			local fraction
			-- GetInverse() is already baked into GetProgress() -- applying it
			-- again below would double-flip. A trigger source has no such
			-- fraction of its own, so it takes the same flip the threshold
			-- modes do.
			local skipInverse = false

			if self.placementMode == "FollowSource" then
				local source = self.progressSource or -2
				if source == -2 then
					fraction = self.parent:GetProgress()
					skipInverse = true
				else
					local st = self.parent.states and self.parent.states[source]
					if st then
						if st.progressType == "timed" then
							if st.duration and st.duration > 0 then
								fraction = (st.expirationTime - GetTime()) / st.duration
							end
						elseif st.total and st.total > 0 then
							fraction = (st.value or 0) / st.total
						end
					end
					if fraction then
						if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
					end
				end
			else
				local minValue, maxValue = self.parent:GetMinMaxProgress()
				local valueRange = maxValue - minValue

				local target
				if self.placementMode == "AtValue" then
					target = self.placement
				elseif self.placementMode == "AtMissingValue" then
					target = maxValue - self.placement
				elseif self.placementMode == "AtPercent" then
					target = minValue + self.placement * valueRange / 100
				end

				if target and valueRange ~= 0 then
					local f = (target - minValue) / valueRange
					if f >= 0 and f <= 1 then fraction = f end
				end
			end

			if not fraction then
				self.inRange = false
			else
				self.inRange = true
				local o, bw, bh = self.parent:GetBarGeometry()
				local fillExtent = isVertical(o) and bh or bw
				local distance = fraction * fillExtent
				if not skipInverse and self.parent:GetInverse() then distance = fillExtent - distance end
				self.parent:PlaceOnBar(self.texture, distance, self.xOffset or 0, self.yOffset or 0)
			end

			self:ApplyVisibility()
		end

		function region:Show() self:ApplyVisibility() end
		function region:Hide() self.texture:Hide() end
		return region
	end,
	modify = function(parent, region, parentData, subData)
		region.visible = subData.tick_visible ~= false
		region.placementMode = subData.tick_placement_mode or "AtValue"
		region.placement = tonumber(subData.tick_placement) or 0
		region.progressSource = tonumber(subData.tick_progressSource) or -2
		region.xOffset = subData.tick_xOffset or 0
		region.yOffset = subData.tick_yOffset or 0

		local orientation, barW, barH = parent:GetBarGeometry()
		local vertical = isVertical(orientation)
		region.thickness = subData.tick_thickness or 2
		local length = (subData.automatic_length ~= false)
			and (vertical and barW or barH)
			or (subData.tick_length or 30)
		if vertical then
			region.texture:SetWidth(length)
			region.texture:SetHeight(region.thickness)
		else
			region.texture:SetWidth(region.thickness)
			region.texture:SetHeight(length)
		end

		region.useTexture = subData.use_texture and true or false
		if region.useTexture then
			region.texture:SetTexture(subData.tick_texture or DEFAULT_TEXTURE)
			region.texture:SetBlendMode(subData.tick_blend_mode or "ADD")
			region.texture:SetDesaturated(subData.tick_desaturate and true or false)
			region.texture:SetTexCoord(WA.GetTexCoordSpark(tonumber(subData.tick_rotation) or 0, subData.tick_mirror))
		else
			region.texture:SetTexture(SOLID_TEXTURE)
			region.texture:SetBlendMode("BLEND")
			region.texture:SetDesaturated(false)
			region.texture:SetTexCoord(0, 0, 1, 1)
		end
		-- SetTexture drops the tint with the old texture object (same trap as
		-- the bar's own SetBarTexture), so the colour is re-applied after.
		local c = subData.tick_color or { 1, 1, 1, 1 }
		region:SetTickColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)

		region:UpdatePlacement()

		parent.subRegionEvents:AddSubscriber("Update", function() region:UpdatePlacement() end)
		parent.subRegionEvents:AddSubscriber("PreShow", function()
			region:ApplyVisibility()
		end)
		if region.placementMode == "FollowSource" then
			parent.subRegionEvents:AddSubscriber("FrameTick", function() region:UpdatePlacement() end)
		end
	end,
	-- BuildOptions field array for OptionsFrame's Display Effects list.
	options = function(parentData, subData, index)
		local fields = {
			{
				type = "toggle", name = "Show tick", key = "tick_visible", half = true,
				get = function() return subData.tick_visible ~= false end,
				set = function(v) subData.tick_visible = v and true or false; WA.Add(parentData, true) end,
			},
			{
				type = "color", name = "Color", key = "tick_color", half = true,
				get = function() return subData.tick_color end,
				set = function(v) subData.tick_color = v; WA.Add(parentData, true) end,
			},
			{
				type = "select", name = "Placement mode", key = "tick_placement_mode",
				values = PLACEMENT_MODES, labels = PLACEMENT_MODE_LABELS,
				get = function() return subData.tick_placement_mode end,
				set = function(v)
					subData.tick_placement_mode = v
					WA.Add(parentData, true)
					-- Repaints the tab: Placement only means anything in the
					-- three threshold modes, and the source picker only in
					-- FollowSource.
					WA.RefreshOptions()
				end,
			},
		}

		if subData.tick_placement_mode == "FollowSource" then
			local sourceValues, sourceLabels = progressSourceOptions(parentData)
			table.insert(fields, {
				type = "select", name = "Tick source", key = "tick_progressSource",
				values = sourceValues, labels = sourceLabels,
				get = function() return subData.tick_progressSource or -2 end,
				set = function(v) subData.tick_progressSource = v; WA.Add(parentData, true) end,
			})
		else
			table.insert(fields, {
				type = "input", name = "Placement", key = "tick_placement",
				get = function() return tostring(subData.tick_placement or 0) end,
				set = function(v) subData.tick_placement = tonumber(v) or 0; WA.Add(parentData, true) end,
			})
		end

		table.insert(fields, {
			type = "range", name = "Thickness", key = "tick_thickness", min = 0, max = 20, step = 1, half = true,
			get = function() return subData.tick_thickness end,
			set = function(v) subData.tick_thickness = v; WA.Add(parentData, true) end,
		})
		table.insert(fields, {
			type = "toggle", name = "Automatic length", key = "automatic_length", half = true,
			get = function() return subData.automatic_length ~= false end,
			set = function(v)
				subData.automatic_length = v and true or false
				WA.Add(parentData, true)
				-- Repaints the tab: the length field below only applies
				-- with automatic length off.
				WA.RefreshOptions()
			end,
		})

		if subData.automatic_length == false then
			table.insert(fields, {
				type = "range", name = "Length", key = "tick_length", min = 0, max = 100, step = 1,
				get = function() return subData.tick_length end,
				set = function(v) subData.tick_length = v; WA.Add(parentData, true) end,
			})
		end

		table.insert(fields, {
			type = "toggle", name = "Use texture", key = "use_texture",
			get = function() return subData.use_texture and true or false end,
			set = function(v)
				subData.use_texture = v and true or false
				WA.Add(parentData, true)
				-- Repaints the tab: the texture fields below only apply with
				-- this on.
				WA.RefreshOptions()
			end,
		})

		if subData.use_texture then
			local textureFields = {
				{
					type = "input", name = "Texture", key = "tick_texture",
					get = function() return subData.tick_texture end,
					set = function(v) subData.tick_texture = v; WA.Add(parentData, true) end,
				},
				{
					type = "select", name = "Blend mode", key = "tick_blend_mode", half = true,
					values = BLEND_MODES, labels = BLEND_MODE_LABELS,
					get = function() return subData.tick_blend_mode end,
					set = function(v) subData.tick_blend_mode = v; WA.Add(parentData, true) end,
				},
				{
					type = "toggle", name = "Desaturate", key = "tick_desaturate", half = true,
					get = function() return subData.tick_desaturate and true or false end,
					set = function(v) subData.tick_desaturate = v and true or false; WA.Add(parentData, true) end,
				},
				{
					type = "select", name = "Rotation", key = "tick_rotation", half = true,
					values = { 0, 90, 180, 270 },
					labels = { [0] = "0", [90] = "90", [180] = "180", [270] = "270" },
					get = function() return subData.tick_rotation end,
					set = function(v) subData.tick_rotation = v; WA.Add(parentData, true) end,
				},
				{
					type = "toggle", name = "Mirror", key = "tick_mirror", half = true,
					get = function() return subData.tick_mirror and true or false end,
					set = function(v) subData.tick_mirror = v and true or false; WA.Add(parentData, true) end,
				},
			}
			for _, f in ipairs(textureFields) do
				table.insert(fields, f)
			end
		end

		table.insert(fields, {
			type = "range", name = "X offset", key = "tick_xOffset", min = -100, max = 100, step = 1, half = true,
			get = function() return subData.tick_xOffset end,
			set = function(v) subData.tick_xOffset = v; WA.Add(parentData, true) end,
		})
		table.insert(fields, {
			type = "range", name = "Y offset", key = "tick_yOffset", min = -100, max = 100, step = 1, half = true,
			get = function() return subData.tick_yOffset end,
			set = function(v) subData.tick_yOffset = v; WA.Add(parentData, true) end,
		})

		return fields
	end,
})
