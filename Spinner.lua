-- WeakestAuras -- radial wedge textures: the circular-progress primitive behind
-- the cooldown swipe and the circular progress texture orientations. Mirrors
-- WA2's BaseRegions/TextureCoords.lua + BaseRegions/CircularProgressTexture.lua.
--
-- A wedge is drawn by moving the quad's four corners onto the region center
-- plus points on the perimeter: Texture:SetVertexOffset (the ClassicAPI
-- corner-transform backport) places the corner, and the 8-argument corner form
-- of SetTexCoord says what the art samples there. Upstream's paired write,
-- ported.
--
-- The pair only composes because both sides refuse to crop. The engine can
-- shrink a region's drawn rect by its texcoord span before storing the drawn
-- corners (FUN_REGION_TEXCOORD_CROP), which would make the corner texcoords a
-- second writer of the geometry the offsets are measured against; it gates that
-- on SetTexCoordModifiesRect, off by default, so a partial or corner-form
-- texcoord leaves the quad at full size (/wa texprobe corners). ClassicAPI's
-- transform used to call the crop directly, bypassing the gate, and a wedge
-- then collapsed onto the shrunken rect's edge -- diagnosed off /wa progtex
-- corner dumps and fixed on the fork. **This file requires that fix**: without
-- it every wedge whose texcoords span less than the full art is destroyed.

if WeakestAuras.disabled then return end
local WA = WeakestAuras

-- ClassicAPI's embedded addon publishes these ("!!!" loads it first); the
-- literals cover the headless harness, where it is absent.
local UPPER_LEFT = UPPER_LEFT_VERTEX or 1
local LOWER_LEFT = LOWER_LEFT_VERTEX or 2
local UPPER_RIGHT = UPPER_RIGHT_VERTEX or 3
local LOWER_RIGHT = LOWER_RIGHT_VERTEX or 4

WA.TextureCoords = {}
WA.Spinner = {}

local defaultTexCoord = {
	ULx = 0, ULy = 0,
	LLx = 0, LLy = 1,
	URx = 1, URy = 0,
	LRx = 1, LRy = 1,
}

-- Perimeter points of the eight exact 45-degree angles, clockwise from twelve
-- o'clock, in texcoord space.
local exactAngles = {
	{ 0.5, 0 }, { 1, 0 }, { 1, 0.5 }, { 1, 1 },
	{ 0.5, 1 }, { 0, 1 }, { 0, 0.5 }, { 0, 0 },
}

-- Upstream writes `angle % 360`. Lua 5.0's math.mod keeps the dividend's sign
-- (math.mod(-30, 360) == -30 where 5.1's % gives 330), and angleToCoord's band
-- tests assume [0, 360) -- the +360 branch is load-bearing.
local function normalizeAngle(angle)
	angle = math.mod(angle, 360)
	if angle < 0 then angle = angle + 360 end
	return angle
end

local function tanDeg(angle)
	return math.tan(math.rad(angle))
end

-- Angle (degrees, 0 at twelve o'clock, increasing clockwise) -> the point on
-- the unit-square perimeter where a ray from the center at that angle exits.
local function angleToCoord(angle)
	angle = normalizeAngle(angle)
	if math.mod(angle, 45) == 0 then
		local index = math.floor(angle / 45) + 1
		return exactAngles[index][1], exactAngles[index][2]
	end
	if angle < 45 then
		return 0.5 + tanDeg(angle) / 2, 0
	elseif angle < 135 then
		return 1, 0.5 + tanDeg(angle - 90) / 2
	elseif angle < 225 then
		return 0.5 - tanDeg(angle) / 2, 1
	elseif angle < 315 then
		return 0, 0.5 - tanDeg(angle - 90) / 2
	end
	return 0.5 + tanDeg(angle) / 2, 0
end

-- Corner names in clockwise perimeter order, repeated so any start index reads
-- four consecutive corners. This order is what keeps every wedge's quad
-- consistently wound -- the engine culls a quad whose winding inverts, so a
-- reordering here shows up as a vanished wedge, not a distorted one.
local pointOrder = { "LL", "UL", "UR", "LR", "LL", "UL", "UR", "LR", "LL", "UL", "UR", "LR" }

-- Crop/mirror/rotate one texcoord around the texture center. scalex/scaley are
-- crop factors (1 = none, larger samples a wider area); texRotation is degrees.
local function TransformPoint(x, y, scalex, scaley, texRotation, mirror_h, mirror_v, user_x, user_y)
	x = x - 0.5
	y = y - 0.5
	-- Grow the sampled area by sqrt(2) so a rotated square still covers its
	-- frame (upstream's "shrink texture" step, expressed on the coords).
	x = x * 1.4142
	y = y * 1.4142
	x = x / scalex
	y = y / scaley
	if mirror_h then x = -x end
	if mirror_v then y = -y end
	local cos_rotation = math.cos(math.rad(texRotation))
	local sin_rotation = math.sin(math.rad(texRotation))
	x, y = cos_rotation * x - sin_rotation * y, sin_rotation * x + cos_rotation * y
	x = x + 0.5
	y = y + 0.5
	return x + (user_x or 0), y + (user_y or 0)
end

-- Published because the icon's cooldown edge has to reach the same perimeter
-- point the wedge's moving corner sits on, at any aspect ratio.
WA.TextureCoords.AngleToCoord = angleToCoord

-- Published because the progresstexture region's linear orientations crop,
-- mirror and rotate through the same formula: one meaning for `crop_x` and
-- friends across both orientation families is what lets a WeakAuras2 aura's
-- values travel here untranslated.
WA.TextureCoords.TransformPoint = TransformPoint

-- ---------------------------------------------------------------------------
-- TextureCoords: one texture's paired texcoord + vertex-offset bookkeeping.
-- ---------------------------------------------------------------------------

local coordFuncs = {}

-- Move one corner to texcoord-space point (x, y), writing both halves: the
-- texcoord the corner samples, and the vertex displacement from the corner's
-- default position, in pixels of the drawn quad. Texcoord y grows downward
-- while vertex y grows upward, hence the one flipped sign.
function coordFuncs.MoveCorner(self, width, height, corner, x, y)
	local rx = defaultTexCoord[corner .. "x"] - x
	local ry = defaultTexCoord[corner .. "y"] - y
	self[corner .. "vx"] = -rx * width
	self[corner .. "vy"] = ry * height
	self[corner .. "x"] = x
	self[corner .. "y"] = y
end

function coordFuncs.Hide(self)
	self.texture:Hide()
end

function coordFuncs.Show(self)
	self:Apply()
	self.texture:Show()
end

function coordFuncs.SetFull(self)
	self.ULx, self.ULy = 0, 0
	self.LLx, self.LLy = 0, 1
	self.URx, self.URy = 1, 0
	self.LRx, self.LRy = 1, 1
	self.ULvx, self.ULvy = 0, 0
	self.LLvx, self.LLvy = 0, 0
	self.URvx, self.URvy = 0, 0
	self.LRvx, self.LRvy = 0, 0
end

-- The one boundary where the wedge reaches the client. Offsets before
-- texcoords, upstream's order.
function coordFuncs.Apply(self)
	local texture = self.texture
	texture:SetVertexOffset(UPPER_RIGHT, self.URvx, self.URvy)
	texture:SetVertexOffset(UPPER_LEFT, self.ULvx, self.ULvy)
	texture:SetVertexOffset(LOWER_RIGHT, self.LRvx, self.LRvy)
	texture:SetVertexOffset(LOWER_LEFT, self.LLvx, self.LLvy)
	texture:SetTexCoord(self.ULx, self.ULy, self.LLx, self.LLy,
		self.URx, self.URy, self.LRx, self.LRy)
end

-- Shape this texture into the wedge from angle1 to angle2, a span that may not
-- exceed two quadrants (the spinner splits wider spans across its textures).
function coordFuncs.SetAngle(self, width, height, angle1, angle2)
	local index = math.floor((angle1 + 45) / 90)

	local middleCorner = pointOrder[index + 1]
	local startCorner = pointOrder[index + 2]
	local endCorner1 = pointOrder[index + 3]
	local endCorner2 = pointOrder[index + 4]

	self:MoveCorner(width, height, middleCorner, 0.5, 0.5)
	self:MoveCorner(width, height, startCorner, angleToCoord(angle1))

	local edge1 = math.floor((angle1 - 45) / 90)
	local edge2 = math.floor((angle2 - 45) / 90)

	if edge1 == edge2 then
		self:MoveCorner(width, height, endCorner1, angleToCoord(angle2))
	else
		self:MoveCorner(width, height, endCorner1,
			defaultTexCoord[endCorner1 .. "x"], defaultTexCoord[endCorner1 .. "y"])
	end

	self:MoveCorner(width, height, endCorner2, angleToCoord(angle2))
end

function coordFuncs.Transform(self, scalex, scaley, texRotation, mirror_h, mirror_v, user_x, user_y)
	self.ULx, self.ULy = TransformPoint(self.ULx, self.ULy, scalex, scaley, texRotation, mirror_h, mirror_v, user_x, user_y)
	self.LLx, self.LLy = TransformPoint(self.LLx, self.LLy, scalex, scaley, texRotation, mirror_h, mirror_v, user_x, user_y)
	self.URx, self.URy = TransformPoint(self.URx, self.URy, scalex, scaley, texRotation, mirror_h, mirror_v, user_x, user_y)
	self.LRx, self.LRy = TransformPoint(self.LRx, self.LRy, scalex, scaley, texRotation, mirror_h, mirror_v, user_x, user_y)
end

function WA.TextureCoords.Create(texture)
	local coord = {
		ULx = 0, ULy = 0,
		LLx = 0, LLy = 1,
		URx = 1, URy = 0,
		LRx = 1, LRy = 1,
		ULvx = 0, ULvy = 0,
		LLvx = 0, LLvy = 0,
		URvx = 0, URvy = 0,
		LRvx = 0, LRvy = 0,
		texture = texture,
	}
	for name, func in pairs(coordFuncs) do coord[name] = func end
	return coord
end

-- ---------------------------------------------------------------------------
-- Spinner: three wedge textures covering an arbitrary angle span.
-- ---------------------------------------------------------------------------

local spinnerFuncs = {}

-- Changing what a wedge samples reaches the engine's own corner store, which
-- writes back the plain axis-aligned quad, so the wedge shape has to be
-- rewritten after it. Both art setters own that rather than each caller: the
-- progresstexture region's texture setters happened to reach UpdateTextures on
-- their own path, the swipe's colour setter did not, and its wedges collapsed.
function spinnerFuncs.SetTexture(self, path)
	for i = 1, 3 do self.textures[i]:SetTexture(path) end
	self:UpdateTextures()
end

-- Vanilla's numeric SetTexture form is a solid fill -- the swipe's dark wedges.
function spinnerFuncs.SetSolidColor(self, r, g, b, a)
	for i = 1, 3 do self.textures[i]:SetTexture(r, g, b, a) end
	self:UpdateTextures()
end

function spinnerFuncs.SetDesaturated(self, desaturate)
	for i = 1, 3 do self.textures[i]:SetDesaturated(desaturate and true or false) end
end

function spinnerFuncs.SetBlendMode(self, blendMode)
	for i = 1, 3 do self.textures[i]:SetBlendMode(blendMode or "BLEND") end
end

-- Whole-spinner rotation (radians). Safe alongside the wedge offsets: rotation
-- and vertex offsets live in one ClassicAPI transform that composes them --
-- one writer, unlike SetTexCoord.
function spinnerFuncs.SetAuraRotation(self, radians)
	for i = 1, 3 do self.textures[i]:SetRotation(radians or 0) end
end

function spinnerFuncs.SetColor(self, r, g, b, a)
	for i = 1, 3 do self.textures[i]:SetVertexColor(r, g, b, a or 1) end
end

function spinnerFuncs.Show(self)
	self.visible = true
	self:UpdateTextures()
end

function spinnerFuncs.Hide(self)
	self.visible = false
	for i = 1, 3 do self.textures[i]:Hide() end
end

function spinnerFuncs.SetCropX(self, crop_x)
	self.crop_x = crop_x
	self:UpdateTextures()
end

function spinnerFuncs.SetCropY(self, crop_y)
	self.crop_y = crop_y
	self:UpdateTextures()
end

function spinnerFuncs.SetTexRotation(self, texRotation)
	self.texRotation = texRotation
	self:UpdateTextures()
end

function spinnerFuncs.SetMirrorHV(self, mirror_h, mirror_v)
	self.mirror_h = mirror_h
	self.mirror_v = mirror_v
end

function spinnerFuncs.SetMirror(self, mirror)
	self.mirror = mirror
	self:UpdateTextures()
end

function spinnerFuncs.SetWidth(self, width)
	self.width = width
end

function spinnerFuncs.SetHeight(self, height)
	self.height = height
end

function spinnerFuncs.SetScale(self, scalex, scaley)
	self.scalex, self.scaley = scalex, scaley
end

-- A reused spinner must not carry its last shape into the next owner: the
-- client keys vertex offsets and rotation on the raw texture and holds them
-- until explicitly cleared, so releasing without this hands the next user a
-- pre-warped quad.
function spinnerFuncs.Reset(self)
	for i = 1, 3 do
		self.coords[i]:SetFull()
		self.coords[i]:Apply()
	end
	self:SetAuraRotation(0)
	self.angle1, self.angle2 = nil, nil
end

function spinnerFuncs.UpdateTextures(self)
	if not self.visible then return end
	local crop_x = self.crop_x or 1
	local crop_y = self.crop_y or 1
	local texRotation = self.texRotation or 0
	local mirror_h = self.mirror_h or false
	if self.mirror then
		mirror_h = not mirror_h
	end
	local mirror_v = self.mirror_v or false

	local width = (self.width or 0) * (self.scalex or 1) + 2 * self.offset
	local height = (self.height or 0) * (self.scaley or 1) + 2 * self.offset
	if width == 0 or height == 0 then return end

	local angle1 = self.angle1
	local angle2 = self.angle2
	if angle1 == nil or angle2 == nil then return end

	if angle2 - angle1 >= 360 then
		self.coords[1]:SetFull()
		self.coords[1]:Transform(crop_x, crop_y, texRotation, mirror_h, mirror_v)
		self.coords[1]:Show()
		self.coords[2]:Hide()
		self.coords[3]:Hide()
		return
	end
	if angle1 == angle2 then
		self.coords[1]:Hide()
		self.coords[2]:Hide()
		self.coords[3]:Hide()
		return
	end

	local index1 = math.floor((angle1 + 45) / 90)
	local index2 = math.floor((angle2 + 45) / 90)

	if index1 + 1 >= index2 then
		self.coords[1]:SetAngle(width, height, angle1, angle2)
		self.coords[1]:Transform(crop_x, crop_y, texRotation, mirror_h, mirror_v)
		self.coords[1]:Show()
		self.coords[2]:Hide()
		self.coords[3]:Hide()
	elseif index1 + 3 >= index2 then
		local firstEndAngle = (index1 + 1) * 90 + 45
		self.coords[1]:SetAngle(width, height, angle1, firstEndAngle)
		self.coords[1]:Transform(crop_x, crop_y, texRotation, mirror_h, mirror_v)
		self.coords[1]:Show()
		self.coords[2]:SetAngle(width, height, firstEndAngle, angle2)
		self.coords[2]:Transform(crop_x, crop_y, texRotation, mirror_h, mirror_v)
		self.coords[2]:Show()
		self.coords[3]:Hide()
	else
		local firstEndAngle = (index1 + 1) * 90 + 45
		local secondEndAngle = firstEndAngle + 180
		self.coords[1]:SetAngle(width, height, angle1, firstEndAngle)
		self.coords[1]:Transform(crop_x, crop_y, texRotation, mirror_h, mirror_v)
		self.coords[1]:Show()
		self.coords[2]:SetAngle(width, height, firstEndAngle, secondEndAngle)
		self.coords[2]:Transform(crop_x, crop_y, texRotation, mirror_h, mirror_v)
		self.coords[2]:Show()
		self.coords[3]:SetAngle(width, height, secondEndAngle, angle2)
		self.coords[3]:Transform(crop_x, crop_y, texRotation, mirror_h, mirror_v)
		self.coords[3]:Show()
	end
end

-- The wedge from angle1 to angle2 (degrees, clockwise from twelve o'clock).
-- angle2 may exceed 360 to express a span crossing the top; a span of 360 or
-- more shows everything, a zero span nothing.
function spinnerFuncs.SetProgress(self, angle1, angle2)
	self.angle1 = angle1
	self.angle2 = angle2
	self:UpdateTextures()
end

function WA.Spinner.Create(frame, layer)
	if not WA.hasTextureTransforms then return nil end
	local spinner = {
		textures = {},
		coords = {},
		offset = 0,
		visible = true,
		parentFrame = frame,
	}
	for i = 1, 3 do
		local texture = frame:CreateTexture(nil, layer or "ARTWORK")
		if texture.SetSnapToPixelGrid then texture:SetSnapToPixelGrid(false) end
		if texture.SetTexelSnappingBias then texture:SetTexelSnappingBias(0) end
		texture:SetAllPoints(frame)
		spinner.textures[i] = texture
		spinner.coords[i] = WA.TextureCoords.Create(texture)
	end
	for name, func in pairs(spinnerFuncs) do spinner[name] = func end
	return spinner
end
