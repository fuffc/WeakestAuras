-- WeakestAuras: a WeakAuras-style buff/debuff/cooldown display addon for the
-- 1.12 client. Built on the modern C_UnitAuras/C_Spell/C_Timer surface that
-- the ClassicAPI client patch backports.
--
-- Copyright (C) 2026 fuffc
--
-- This addon reimplements the architecture of WeakAuras (the WeakAuras team,
-- https://github.com/WeakAuras/WeakAuras2) for a client its own source cannot
-- run on, and parts of it -- the trigger-state glue above all -- follow that
-- source closely enough to be a derived work. It is therefore distributed
-- under the same terms: GNU General Public License version 2 or later, in
-- LICENSE. There is NO WARRANTY, to the extent permitted by law.

WeakestAuras = CreateFrame("Frame")

-- ClassicAPI publishes this global (packed X*10000+Y*100+Z) on every load/
-- reload. Its absence means the client patch isn't installed, and none of
-- the aura APIs this addon needs exist.
if not CLASSIC_API_VERSION then
  WeakestAuras.disabled = true
  DEFAULT_CHAT_FRAME:AddMessage(
    "|cffff0000WeakestAuras|r requires the ClassicAPI client patch, which was not detected. " ..
    "Get it from https://github.com/brues-code/ClassicAPI",
    1, 0.2, 0.2
  )
  return
end

WeakestAurasDB = WeakestAurasDB or {}

-- Capability probes, resolved once at load. ClassicAPI is the hard gate above;
-- SuperWoW and Nampower feed per-trigger version-skew guards (a prototype
-- declaring `enable = function() return WA.hasNampower end`) rather than a
-- second load gate, so a missing mod degrades feature-by-feature.
--
-- All three are meant to hard-disable. The blocker is SUPERWOW_VERSION /
-- SUPERWOW_STRING: DoiteAuras only ever gates on GetNampowerVersion and never
-- reads a SuperWoW global, so neither name is confirmed on a live client. Probe
-- them in-game before making either one brick the load.
WeakestAuras.hasClassicAPI = CLASSIC_API_VERSION ~= nil
WeakestAuras.hasSuperWoW = (SUPERWOW_VERSION ~= nil) or (SUPERWOW_STRING ~= nil)
WeakestAuras.hasNampower = type(GetNampowerVersion) == "function"

-- WeakAuras2's active-trigger sentinel (Private.trigger_modes.first_active):
-- an activeTriggerMode of this value means "the display follows whichever
-- trigger is the first one currently active" rather than a fixed trigger
-- number. Lives here so both Data.lua (schema default) and StateMachine.lua
-- (resolution) share the one constant.
WeakestAuras.trigger_modes = { first_active = -10 }

-- Unit tokens a trigger may target. All are native or ClassicAPI-backed and
-- resolve to a single unit; a multi-unit token (party as a group) needs the
-- clone path and is deliberately absent. raid1..raid40 and partyN are reachable
-- through the "specific" entry's free-text field rather than bloating every
-- dropdown by 40+ entries.
WeakestAuras.unit_tokens = {
	"player", "target", "targettarget", "focus", "focustarget",
	"pet", "pettarget", "mouseover", "specific",
}
WeakestAuras.unit_labels = {
	player = "Player", target = "Target", targettarget = "Target of Target",
	focus = "Focus", focustarget = "Target of Focus",
	pet = "Pet", pettarget = "Target of Pet", mouseover = "Mouseover",
	specific = "Specific Unit",
}

DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WeakestAuras|r loaded.", 1, 1, 1)
