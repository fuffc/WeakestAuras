-- WeakestAuras -- the singleton frame chooser used by selected-frame anchors.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local chooserFrame
local chooserBox
local chooserData
local chooserApply
local chooserOriginal
local chooserFocus
local chooserFocusName

local function recurseGetName(frame)
	if not frame then return nil end
	local name = frame.GetName and frame:GetName() or nil
	if name and name ~= "" then return name end
	local parent = frame.GetParent and frame:GetParent()
	if not parent then return nil end
	for key, child in pairs(parent) do
		if child == frame then
			local parentName = recurseGetName(parent) or ""
			return parentName .. "." .. tostring(key)
		end
	end
	return nil
end

local function findRegionUnderMouse(focus)
	local focusName = focus and recurseGetName(focus) or nil
	if focusName and focusName ~= "WorldFrame" then return focus, focusName end

	local chosen
	local chosenName
	local chosenIsGroup
	if WA.ForEachRegion then
		WA.ForEachRegion(function(region)
			local data = WeakestAurasDB.displays[region.id]
			if data and region.IsVisible and region:IsVisible()
				and MouseIsOver and MouseIsOver(region) then
				local isGroup = WA.IsGroup(data)
				if not chosen or (chosenIsGroup and not isGroup) then
					chosen = region
					chosenName = "WeakestAuras:" .. region.id
					chosenIsGroup = isGroup
				end
			end
		end)
	end
	return chosen, chosenName
end

local function ensureChooser()
	if chooserFrame then return end
	chooserFrame = CreateFrame("Frame", "WeakestAurasFrameChooser", UIParent)
	chooserFrame:SetFrameStrata("TOOLTIP")
	chooserBox = CreateFrame("Frame", nil, chooserFrame)
	chooserBox:SetFrameStrata("TOOLTIP")
	chooserBox:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	chooserBox:SetBackdropBorderColor(0, 1, 0, 1)
	chooserBox:Hide()
	chooserFrame:Hide()
end

local function stopChooser(restore)
	if not chooserFrame then return end
	if restore and chooserData and chooserApply then chooserApply(chooserOriginal) end
	chooserFrame:SetScript("OnUpdate", nil)
	chooserBox:Hide()
	chooserFrame:Hide()
	if ResetCursor then ResetCursor() end
	chooserData, chooserApply, chooserOriginal = nil, nil, nil
	chooserFocus, chooserFocusName = nil, nil
end

function WA.StopFrameChooser()
	stopChooser(false)
end

function WA.StartFrameChooser(data, apply)
	if not data or type(apply) ~= "function" then return end
	ensureChooser()
	stopChooser(false)
	chooserData = data
	chooserApply = apply
	chooserOriginal = data.anchorFrameFrame
	chooserFocus, chooserFocusName = nil, nil
	chooserFrame:Show()
	if SetCursor then SetCursor("Interface\\Cursor\\Point") end
	chooserFrame:SetScript("OnUpdate", function()
		if IsMouseButtonDown and IsMouseButtonDown("RightButton") then
			stopChooser(true)
			if WA.RefreshOptions then WA.RefreshOptions() end
			return
		end

		local focus = GetMouseFocus and GetMouseFocus() or nil
		local picked, pickedName = findRegionUnderMouse(focus)
		if picked ~= chooserFocus then
			chooserFocus = picked
			chooserFocusName = pickedName
			if picked and pickedName then
				chooserBox:ClearAllPoints()
				chooserBox:SetPoint("BOTTOMLEFT", picked, "BOTTOMLEFT", -4, -4)
				chooserBox:SetPoint("TOPRIGHT", picked, "TOPRIGHT", 4, 4)
				chooserBox:Show()
			else
				chooserBox:Hide()
			end
		end

		if chooserFocusName and chooserApply and chooserFocusName ~= chooserData.anchorFrameFrame then
			chooserApply(chooserFocusName)
		end
		if IsMouseButtonDown and IsMouseButtonDown("LeftButton") and chooserFocusName then
			stopChooser(false)
			if WA.RefreshOptions then WA.RefreshOptions() end
		end
	end)
end

WA._test = WA._test or {}
WA._test.recurseFrameName = recurseGetName
WA._test.stopFrameChooser = stopChooser
