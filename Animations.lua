-- WeakestAuras -- the central display-animation registry and its reusable
-- easing, transition and preset definitions. Mirrors WA2's animation contract (§13).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md

if WeakestAuras.disabled then return end
local WA = WeakestAuras

WA.anim_types = { none = "None", preset = "Preset", custom = "Custom" }
WA.anim_type_values = { "none", "preset", "custom" }
WA.anim_ease_types = { none = "None", easeIn = "Ease In", easeOut = "Ease Out", easeOutIn = "Ease In and Out" }
WA.anim_ease_values = { "none", "easeIn", "easeOut", "easeOutIn" }
WA.anim_ease_functions = {
	none = function(p) return p end,
	easeIn = function(p, n) return p ^ n end,
	easeOut = function(p, n) return 1 - (1 - p) ^ n end,
	easeOutIn = function(p, n) if p < 0.5 then return (p * 2) ^ n * 0.5 end return 1 - ((1 - p) * 2) ^ n * 0.5 end,
}
WA.anim_translate_types = { straightTranslate = "Normal", circle = "Circle", spiral = "Spiral", spiralandpulse = "Spiral In And Out", shake = "Shake", bounce = "Bounce", bounceDecay = "Bounce with Decay", custom = "Custom Function" }
WA.anim_translate_values = { "straightTranslate", "circle", "spiral", "spiralandpulse", "shake", "bounce", "bounceDecay", "custom" }
WA.anim_scale_types = { straightScale = "Normal", pulse = "Pulse", fauxspin = "Spin", fauxflip = "Flip", custom = "Custom Function" }
WA.anim_scale_values = { "straightScale", "pulse", "fauxspin", "fauxflip", "custom" }
WA.anim_alpha_types = { straight = "Normal", alphaPulse = "Pulse", hide = "Hide", custom = "Custom Function" }
WA.anim_alpha_values = { "straight", "alphaPulse", "hide", "custom" }
WA.anim_rotate_types = { straight = "Normal", backandforth = "Back and Forth", wobble = "Wobble", custom = "Custom Function" }
WA.anim_rotate_values = { "straight", "backandforth", "wobble", "custom" }
WA.anim_color_types = { straightColor = "Legacy RGB Gradient", straightHSV = "Gradient", pulseColor = "Legacy RGB Gradient Pulse", pulseHSV = "Gradient Pulse", custom = "Custom Function" }
WA.anim_color_values = { "straightColor", "straightHSV", "pulseColor", "pulseHSV", "custom" }
WA.anim_start_preset_types = { slidetop = "Slide from Top", slideleft = "Slide from Left", slideright = "Slide from Right", slidebottom = "Slide from Bottom", fade = "Fade In", shrink = "Grow", grow = "Shrink", spiral = "Spiral", bounceDecay = "Bounce", starShakeDecay = "Star Shake" }
WA.anim_start_preset_values = { "slidetop", "slideleft", "slideright", "slidebottom", "fade", "shrink", "grow", "spiral", "bounceDecay", "starShakeDecay" }
WA.anim_main_preset_types = { shake = "Shake", spin = "Spin", flip = "Flip", wobble = "Wobble", pulse = "Pulse", alphaPulse = "Flash", rotateClockwise = "Rotate Right", rotateCounterClockwise = "Rotate Left", spiralandpulse = "Spiral", orbit = "Orbit", bounce = "Bounce" }
WA.anim_main_preset_values = { "shake", "spin", "flip", "wobble", "pulse", "alphaPulse", "rotateClockwise", "rotateCounterClockwise", "spiralandpulse", "orbit", "bounce" }
WA.anim_finish_preset_types = { slidetop = "Slide to Top", slideleft = "Slide to Left", slideright = "Slide to Right", slidebottom = "Slide to Bottom", fade = "Fade Out", shrink = "Shrink", grow = "Grow", spiral = "Spiral", bounceDecay = "Bounce", starShakeDecay = "Star Shake" }
WA.anim_finish_preset_values = { "slidetop", "slideleft", "slideright", "slidebottom", "fade", "shrink", "grow", "spiral", "bounceDecay", "starShakeDecay" }
WA.duration_types = { seconds = "Seconds", relative = "Relative" }
WA.duration_values = { "seconds", "relative" }
WA.duration_types_no_choice = { seconds = "Seconds" }
WA.duration_values_no_choice = { "seconds" }

WA.anim_function_strings = {
straight = [[function(progress, start, delta)
	return start + progress * delta
end]],
straightTranslate = [[function(progress, startX, startY, deltaX, deltaY)
	return startX + progress * deltaX, startY + progress * deltaY
end]],
straightScale = [[function(progress, startX, startY, scaleX, scaleY)
	return startX + progress * (scaleX - startX), startY + progress * (scaleY - startY)
end]],
straightColor = [[function(progress, r1, g1, b1, a1, r2, g2, b2, a2)
	return r1 + progress * (r2 - r1), g1 + progress * (g2 - g1), b1 + progress * (b2 - b1), a1 + progress * (a2 - a1)
end]],
straightHSV = [[function(progress, r1, g1, b1, a1, r2, g2, b2, a2)
	return WeakestAuras.GetHSVTransition(progress, r1, g1, b1, a1, r2, g2, b2, a2)
end]],
circle = [[function(progress, startX, startY, deltaX, deltaY)
	local angle = progress * 2 * math.pi
	return startX + deltaX * math.cos(angle), startY + deltaY * math.sin(angle)
end]],
circle2 = [[function(progress, startX, startY, deltaX, deltaY)
	local angle = progress * 2 * math.pi
	return startX + deltaX * math.sin(angle), startY + deltaY * math.cos(angle)
end]],
spiral = [[function(progress, startX, startY, deltaX, deltaY)
	local angle = progress * 2 * math.pi
	return startX + progress * deltaX * math.cos(angle), startY + progress * deltaY * math.sin(angle)
end]],
spiralandpulse = [[function(progress, startX, startY, deltaX, deltaY)
	local angle = (progress + 0.25) * 2 * math.pi
	return startX + math.cos(angle) * deltaX * math.cos(angle * 2), startY + math.abs(math.cos(angle)) * deltaY * math.sin(angle * 2)
end]],
shake = [[function(progress, startX, startY, deltaX, deltaY)
	local p
	if progress < 0.25 then p = progress * 4 elseif progress < 0.75 then p = 2 - progress * 4 else p = (progress - 1) * 4 end
	return startX + p * deltaX, startY + p * deltaY
end]],
starShakeDecay = [[function(progress, startX, startY, deltaX, deltaY)
	local spokes, circles = 10, 4
	local r = math.min(math.abs(deltaX), math.abs(deltaY))
	if r == 0 then return startX, startY end
	local xs, ys = deltaX / r, deltaY / r
	local da, p = circles * 2 / spokes * math.pi, progress * spokes
	local i = math.floor(p); p = p - i
	local a1, a2 = i * da, i * da + da
	local x1, y1 = r * math.cos(a1), r * math.sin(a1)
	local x2, y2 = r * math.cos(a2), r * math.sin(a2)
	local e = math.sin(progress * math.pi / 2)
	return startX + e * (p * x2 + (1 - p) * x1) * xs, startY + e * (p * y2 + (1 - p) * y1) * ys
end]],
bounceDecay = [[function(progress, startX, startY, deltaX, deltaY)
	local p = math.mod(progress * 3.5, 1)
	local b = math.ceil(progress * 3.5)
	local d = math.sin(p * math.pi) * b / 4
	return startX + d * deltaX, startY + d * deltaY
end]],
bounce = [[function(progress, startX, startY, deltaX, deltaY)
	local d = math.sin(progress * math.pi)
	return startX + d * deltaX, startY + d * deltaY
end]],
pulse = [[function(progress, startX, startY, scaleX, scaleY)
	local p = (math.sin(progress * 2 * math.pi - math.pi / 2) + 1) / 2
	return startX + p * (scaleX - 1), startY + p * (scaleY - 1)
end]],
alphaPulse = [[function(progress, start, delta)
	local p = (math.sin(progress * 2 * math.pi - math.pi / 2) + 1) / 2
	return start + p * delta
end]],
pulseColor = [[function(progress, r1, g1, b1, a1, r2, g2, b2, a2)
	local p = (math.sin(progress * 2 * math.pi - math.pi / 2) + 1) / 2
	return r1 + p * (r2 - r1), g1 + p * (g2 - g1), b1 + p * (b2 - b1), a1 + p * (a2 - a1)
end]],
pulseHSV = [[function(progress, r1, g1, b1, a1, r2, g2, b2, a2)
	local p = (math.sin(progress * 2 * math.pi - math.pi / 2) + 1) / 2
	return WeakestAuras.GetHSVTransition(p, r1, g1, b1, a1, r2, g2, b2, a2)
end]],
fauxspin = [[function(progress, startX, startY, scaleX, scaleY)
	return math.cos(progress * 2 * math.pi) * scaleX, startY + progress * (scaleY - startY)
end]],
fauxflip = [[function(progress, startX, startY, scaleX, scaleY)
	return startX + progress * (scaleX - startX), math.cos(progress * 2 * math.pi) * scaleY
end]],
backandforth = [[function(progress, start, delta)
	local p
	if progress < 0.25 then p = progress * 4 elseif progress < 0.75 then p = 2 - progress * 4 else p = (progress - 1) * 4 end
	return start + p * delta
end]],
wobble = [[function(progress, start, delta)
	return start + math.sin(progress * 2 * math.pi) * delta
end]],
hide = [[function() return 0 end]],
}

WA.anim_presets = {
	slidetop = { type = "custom", duration = 0.25, use_translate = true, x = 0, y = 50, use_alpha = true, alpha = 0 },
	slideleft = { type = "custom", duration = 0.25, use_translate = true, x = -50, y = 0, use_alpha = true, alpha = 0 },
	slideright = { type = "custom", duration = 0.25, use_translate = true, x = 50, y = 0, use_alpha = true, alpha = 0 },
	slidebottom = { type = "custom", duration = 0.25, use_translate = true, x = 0, y = -50, use_alpha = true, alpha = 0 },
	fade = { type = "custom", duration = 0.25, use_alpha = true, alpha = 0 },
	grow = { type = "custom", duration = 0.25, use_scale = true, scalex = 2, scaley = 2, use_alpha = true, alpha = 0 },
	shrink = { type = "custom", duration = 0.25, use_scale = true, scalex = 0, scaley = 0, use_alpha = true, alpha = 0 },
	spiral = { type = "custom", duration = 0.5, use_translate = true, x = 100, y = 100, translateType = "spiral", use_alpha = true, alpha = 0 },
	bounceDecay = { type = "custom", duration = 1.5, use_translate = true, x = 50, y = 50, translateType = "bounceDecay", use_alpha = true, alpha = 0 },
	starShakeDecay = { type = "custom", duration = 1, use_translate = true, x = 50, y = 50, translateType = "starShakeDecay", use_alpha = true, alpha = 0 },
	shake = { type = "custom", duration = 0.5, use_translate = true, x = 10, y = 0, translateType = "circle2" },
	spin = { type = "custom", duration = 1, use_scale = true, scalex = 1, scaley = 1, scaleType = "fauxspin" },
	flip = { type = "custom", duration = 1, use_scale = true, scalex = 1, scaley = 1, scaleType = "fauxflip" },
	wobble = { type = "custom", duration = 0.5, use_rotate = true, rotate = 3, rotateType = "wobble" },
	pulse = { type = "custom", duration = 0.75, use_scale = true, scalex = 1.05, scaley = 1.05, scaleType = "pulse" },
	alphaPulse = { type = "custom", duration = 0.5, use_alpha = true, alpha = 0.5, alphaType = "alphaPulse" },
	rotateClockwise = { type = "custom", duration = 4, use_rotate = true, rotate = -360 },
	rotateCounterClockwise = { type = "custom", duration = 4, use_rotate = true, rotate = 360 },
	spiralandpulse = { type = "custom", duration = 6, use_translate = true, x = 100, y = 100, translateType = "spiralandpulse" },
	orbit = { type = "custom", duration = 4, use_translate = true, x = 100, y = 100, translateType = "circle", use_rotate = true, rotate = 360 },
	bounce = { type = "custom", duration = 0.6, use_translate = true, x = 0, y = 25, translateType = "bounce" },
}

local function rgbToHsv(r, g, b)
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local d, h, s = max - min, 0, 0
	if max ~= 0 then s = d / max end
	if d ~= 0 then
		if max == r then h = math.mod((g - b) / d, 6) elseif max == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
		h = h * 60; if h < 0 then h = h + 360 end
	end
	return h, s, max
end
local function hsvToRgb(h, s, v)
	if s == 0 then return v, v, v end
	h = math.mod(h, 360) / 60
	local i, f = math.floor(h), h - math.floor(h)
	local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
	if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v else return v, p, q end
end
function WA.GetHSVTransition(p, r1, g1, b1, a1, r2, g2, b2, a2)
	local h1, s1, v1 = rgbToHsv(r1, g1, b1); local h2, s2, v2 = rgbToHsv(r2, g2, b2)
	local d = h2 - h1
	if d < -180 then d = d + 360 elseif d > 180 then d = d - 360 end
	local r, g, b = hsvToRgb(h1 + p * d, s1 + p * (s2 - s1), v1 + p * (v2 - v1))
	return r, g, b, a1 + p * (a2 - a1)
end
function WA.ParseNumber(value)
	if type(value) == "number" then return value, "number" end
	if type(value) ~= "string" then return nil, nil end
	local a, b, n, d = string.find(value, "^%s*([%-%d%.]+)%s*/%s*([%-%d%.]+)%s*$")
	if a then n, d = tonumber(n), tonumber(d); if n and d and d ~= 0 then return n / d, "fraction" end return nil, nil end
	local number = tonumber(value)
	return number, number and "number" or nil
end

local animations, updating, lastUpdate = {}, false, GetTime()
local animationFrame = CreateFrame("Frame")
local function callFunction(region, tag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	local values
	WA.ActivateAuraEnvForRegion(region)
	local ok = WA.safecall(tag, function()
		values = { fn(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) }
	end)
	WA.DeactivateAuraEnv()
	if not ok then return false end
	return true, unpack(values)
end
local function clear(anim)
	local r = anim.region
	if r.SetOffsetAnim then r:SetOffsetAnim(0, 0) end
	if r.SetAnimAlpha then r:SetAnimAlpha(nil) end
	if r.Scale then r:Scale(1, 1) end
	if r.SetAnimRotation then r:SetAnimRotation(nil) end
	if r.ColorAnim then r:ColorAnim(nil) end
end
-- Whether an animation block's `<slot>Func` is Lua that can run, asked of the
-- block alone so the import review can put the same question to a payload it
-- never animates. A preset block never reaches its own functions -- WA.Animate
-- swaps in the preset's table before it reads a slot -- and a slot set to a
-- named curve reaches that curve instead, so the stored source is dead however
-- the slot is enabled.
function WA.AnimationCodeIsLive(anim, slot)
	if type(anim) ~= "table" or anim.type ~= "custom" then return false end
	return (anim["use_" .. slot] and anim[slot .. "Type"] == "custom") and true or false
end
local function compileSlot(anim, slot, fallback)
	local source = WA.AnimationCodeIsLive(anim, slot) and anim[slot .. "Func"]
	if not source then source = WA.anim_function_strings[anim[slot .. "Type"] or fallback] end
	return source and WA.LoadFunction(source, nil) or nil
end
local function run(key, anim, elapsed, time)
	local finish = false
	if anim.duration_type == "seconds" then
		anim.progress = anim.progress + elapsed / (anim.duration > 0 and anim.duration or 1)
		if anim.progress >= 1 then anim.progress, finish = 1, true end
	elseif anim.duration_type == "relative" then
		local r = anim.region
		if (r.progressType == "timed" and (r.duration or 0) < 0.01) or (r.progressType == "static" and (r.value or 0) < 0.01) then
			anim.progress = 0; if anim.type == "start" or anim.type == "finish" then finish = true end
		else
			local p = r.progressType == "static" and ((r.total or 0) > 0 and r.value / r.total or 0) or 1 - ((r.expirationTime - time) / r.duration)
			if r.stateInverse then p = 1 - p end
			anim.progress = anim.duration > 0 and p / anim.duration or 0
			local iteration = math.floor(anim.progress)
			if not anim.iteration then anim.iteration = iteration elseif anim.iteration ~= iteration then anim.iteration, finish = nil, true end
		end
	else anim.progress, finish = 1, true end
	local p = anim.inverse and 1 - anim.progress or anim.progress
	p = anim.easeFunc(p, anim.easeStrength or 3)
	if anim.translateFunc then local ok, x, y = callFunction(anim.region, anim.auraUID, anim.translateFunc, p, 0, 0, anim.dX, anim.dY); if ok then anim.region:SetOffsetAnim(x, y) end end
	if anim.alphaFunc then local ok, a = callFunction(anim.region, anim.auraUID, anim.alphaFunc, p, anim.startAlpha, anim.dAlpha); if ok then anim.region:SetAnimAlpha(a) end end
	if anim.scaleFunc and anim.region.Scale then local ok, x, y = callFunction(anim.region, anim.auraUID, anim.scaleFunc, p, 1, 1, anim.scaleX, anim.scaleY); if ok then anim.region:Scale(x, y) end end
	if anim.rotateFunc and anim.region.SetAnimRotation then local ok, v = callFunction(anim.region, anim.auraUID, anim.rotateFunc, p, anim.region:GetBaseRotation(), anim.rotate); if ok then anim.region:SetAnimRotation(v) end end
	if anim.colorFunc and anim.region.ColorAnim then local r, g, b, a = anim.region:GetColor(); local ok, nr, ng, nb, na = callFunction(anim.region, anim.auraUID, anim.colorFunc, p, r or 1, g or 1, b or 1, a or 1, anim.colorR, anim.colorG, anim.colorB, anim.colorA); if ok then anim.region:ColorAnim(nr, ng, nb, na) end end
	if finish then
		if anim.loop then WA.Animate(anim.namespace, anim.auraUID, anim.type, anim.anim, anim.region, anim.inverse, anim.onFinished, true, anim.region.cloneId) else clear(anim); animations[key] = nil; if anim.onFinished then anim.onFinished() end end
	end
end
local function update()
	if not updating then return end
	local time = GetTime(); local elapsed = time - lastUpdate; lastUpdate = time
	for key, anim in pairs(animations) do run(key, anim, elapsed, time) end
	for _ in pairs(animations) do return end
	updating = false; animationFrame:SetScript("OnUpdate", nil)
end
animationFrame:SetScript("OnUpdate", update)
function WA.Animate(namespace, uid, kind, anim, region, inverse, onFinished, loop, cloneId)
	local key = tostring(region); local source = anim
	if source and source.type == "preset" then source = WA.anim_presets[source.preset] end
	if not source or source.type ~= "custom" then if animations[key] then WA.CancelAnimation(region, true, true, true, true, true) end return false end
	local valid = source.use_translate or source.use_alpha or (source.use_scale and region.Scale) or (source.use_rotate and region.SetAnimRotation) or (source.use_color and region.Color)
	if not valid then if animations[key] then WA.CancelAnimation(region, true, true, true, true, true) end return false end
	if animations[key] and animations[key].type == kind and not loop then return "no replace" end
	local old = animations[key]; local baseAlpha = old and old.startAlpha or region:GetAlpha()
	local a = { region = region, auraUID = uid, namespace = namespace, type = kind, loop = loop, inverse = inverse, onFinished = onFinished, anim = source, progress = 0, duration = WA.ParseNumber(source.duration) or 0, duration_type = source.duration_type or "seconds", easeFunc = WA.anim_ease_functions[source.easeType or "none"] or WA.anim_ease_functions.none, easeStrength = source.easeStrength, startX = old and old.startX or 0, startY = old and old.startY or 0, startAlpha = baseAlpha, startWidth = old and old.startWidth or region:GetWidth(), startHeight = old and old.startHeight or region:GetHeight(), dX = source.use_translate and (source.x or 0), dY = source.use_translate and (source.y or 0), dAlpha = source.use_alpha and ((source.alpha or 0) - baseAlpha), scaleX = source.use_scale and (source.scalex or 1), scaleY = source.use_scale and (source.scaley or 1), rotate = source.rotate or 0, colorR = source.colorR or 1, colorG = source.colorG or 1, colorB = source.colorB or 1, colorA = source.colorA or 1 }
	if source.use_translate then a.translateFunc = compileSlot(source, "translate", "straightTranslate") end
	if source.use_alpha then a.alphaFunc = compileSlot(source, "alpha", "straight") end
	if source.use_scale and region.Scale then a.scaleFunc = compileSlot(source, "scale", "straightScale") end
	if source.use_rotate and region.SetAnimRotation then a.rotateFunc = compileSlot(source, "rotate", "straight") end
	if source.use_color and region.Color then a.colorFunc = compileSlot(source, "color", "straightColor") end
	animations[key] = a; updating = true; lastUpdate = GetTime(); animationFrame:SetScript("OnUpdate", update)
	return true
end
function WA.CancelAnimation(region, resetPos, resetAlpha, resetScale, resetRotation, resetColor, doOnFinished)
	local key, anim = tostring(region), animations[tostring(region)]
	if not anim then return false end
	if resetPos or resetAlpha or resetScale or resetRotation or resetColor then clear(anim) end
	animations[key] = nil
	if doOnFinished and anim.onFinished then anim.onFinished() end
	for _ in pairs(animations) do return true end
	updating = false; animationFrame:SetScript("OnUpdate", nil)
	return true
end
WA._animationFrame, WA._animationUpdate, WA._animations = animationFrame, update, animations
