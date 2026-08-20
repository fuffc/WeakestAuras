-- WeakestAuras -- the "subbackground" sub-region: the region's own art, given a
-- row in the Display Effects list. Mirrors WA2's Background (§8).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- Draws nothing, and is not a backdrop despite the name. Draw order comes off an
-- entry's position in data.subRegions, so without a row standing for the region
-- itself there is no way to say "below the icon" -- every effect would sit above
-- it forever. This row's SetFrameLevel retargets the parent region, which is
-- what moving it up or down the list actually does.
--
-- `enforced`: MergeDefaults keeps exactly one on every aura that supports it,
-- and the options list offers neither add, delete nor duplicate. Upstream
-- expresses the same thing as supportsAdd = false plus an options block with no
-- __delete/__duplicate and a __notcollapsable.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

WA.RegisterSubRegionType("subbackground", {
	displayName = "Background",
	supports = function(regionType)
		return regionType ~= "group" and regionType ~= "dynamicgroup"
	end,
	enforced = true,
	default = { type = "subbackground" },
	create = function(parent)
		local region = { parent = parent }
		function region:SetFrameLevel(level) self.parent:SetFrameLevel(level) end
		return region
	end,
	modify = function(parent, region)
		region.parent = parent
	end,
	-- A header and nothing under it. The arrows live on the header, which the
	-- options list paints for every effect.
	options = function()
		return {}
	end,
})
