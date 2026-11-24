local addonName, ns = ...

-- Default Configuration
local DEFAULT_DURATION = 300 -- 5 minutes in seconds
local WARN_THRESHOLD = 30    -- Show seconds during final 30s
local REAPPLY_PREWARN = 20   -- Show clickable center reapply icon 20 seconds before expiration
local SOUND_COOLDOWN = 3.0   -- Minimum seconds between alert sounds
local PERIODIC_SCAN_INTERVAL = 0.25 -- Fast OOC check every 0.25s

local OATH_SPELLS = {
    ["Oath of Might"] = true,
    ["Oath of Wisdom"] = true,
    ["Oath of Kings"] = true,
    ["Oath of Sanctuary"] = true,
    ["Oath of Salvation"] = true,
    ["Oath of Light"] = true,
}

local OATH_SPELL_IDS = {
    -- Optional exact spell IDs, e.g. [123456] = true
}

local MATCH_ANY_OATH_KEYWORD = true
local FALLBACK_OATH_ICON = 135924 -- Spell_Holy_GreaterBlessingofLight / classic holy light icon fallback

OathTrackerDB = OathTrackerDB or {}

local function InitDefaults()
    if OathTrackerDB.point == nil then OathTrackerDB.point = "CENTER" end
    if OathTrackerDB.relativePoint == nil then OathTrackerDB.relativePoint = "CENTER" end
    if OathTrackerDB.x == nil then OathTrackerDB.x = 0 end
    if OathTrackerDB.y == nil then OathTrackerDB.y = 140 end
    if OathTrackerDB.locked == nil then OathTrackerDB.locked = false end
    if OathTrackerDB.soundEnabled == nil then OathTrackerDB.soundEnabled = true end
    if OathTrackerDB.intenseVisual == nil then OathTrackerDB.intenseVisual = true end
    if OathTrackerDB.guiHidden == nil then OathTrackerDB.guiHidden = false end
end
InitDefaults()

-- Single tracked target state (ONLY ONE target is ever tracked)
local singleTarget = {
    active = false,
    guid = nil,
    name = nil,
    shortName = nil,
    unit = nil,
    spellName = nil,
    spellId = nil,
    expires = 0,
    status = "NONE", -- "NONE", "ACTIVE", "MISSING_REAPPLY", "DEAD_REAPPLY", "OFFLINE"
    castTime = 0,
    wasActive = false,
    lastSlotSnapshot = nil,
}

local learnedDurations = {}
local knownOathSpellIds = {}
for sid, enabled in pairs(OATH_SPELL_IDS) do
    if enabled then knownOathSpellIds[sid] = true end
end

local lastAlertSoundTime = 0
local pendingCenterIconState = nil
local prewarnAlertPlayed = false

-- ============================================================================
-- SAFE VALUE & STRING HELPERS (WoW Forever / 16001)
-- ============================================================================
local function IsSafeValue(val)
    if val == nil then return false end
    if issecretvalue and issecretvalue(val) then return false end
    if canaccessvalue and not canaccessvalue(val) then return false end
    return true
end

local function SafeToString(val)
    if not IsSafeValue(val) then return nil end
    local t = type(val)
    if t == "string" then return val end
    if t == "number" or t == "boolean" then
        local ok, s = pcall(tostring, val)
        return ok and s or nil
    end
    return nil
end

local function SafeStrLower(str)
    if not IsSafeValue(str) or type(str) ~= "string" then return "" end
    local ok, res = pcall(string.lower, str)
    return ok and res or ""
end

local function SafeStrTrim(str)
    if not IsSafeValue(str) or type(str) ~= "string" then return "" end
    local ok, res = pcall(strtrim, str)
    return ok and res or str
end

local function SafeStringFind(haystack, needle)
    if not IsSafeValue(haystack) or type(haystack) ~= "string" then return false end
    if not IsSafeValue(needle) or type(needle) ~= "string" then return false end
    local ok, pos = pcall(string.find, haystack, needle, 1, true)
    return ok and (pos ~= nil) or false
end

local function NormalizeFullName(name)
    local s = SafeToString(name)
    if not s or s == "" then return "" end
    s = SafeStrTrim(s)
    s = string.gsub(s, "_", " ")
    s = string.gsub(s, "%s+", " ")
    return SafeStrLower(s)
end

local function GetFullUnitName(unit)
    if not IsSafeValue(unit) or not UnitExists(unit) then return nil end

    if UnitFullName then
        local ok, fname, realm = pcall(UnitFullName, unit)
        if ok and IsSafeValue(fname) and fname ~= "" then
            if string.find(fname, "%s") then
                return SafeStrTrim(fname)
            elseif IsSafeValue(realm) and realm ~= "" then
                return SafeStrTrim(fname .. " " .. realm)
            end
        end
    end

    if UnitNameUnmodified then
        local ok, uname = pcall(UnitNameUnmodified, unit)
        if ok and IsSafeValue(uname) and uname ~= "" then
            return SafeStrTrim(uname)
        end
    end

    local ok, name = pcall(UnitName, unit)
    if ok and IsSafeValue(name) and name ~= "" then
        return SafeStrTrim(name)
    end

    return nil
end

local function FormatDisplayName(fullName)
    if not fullName or fullName == "" then return "Target" end
    if #fullName > 22 then
        local first, rest = string.match(fullName, "^(%S+)%s+(%S+.*)$")
        if first and rest then
            return first .. " " .. string.sub(rest, 1, 1) .. "."
        end
        return string.sub(fullName, 1, 20) .. "..."
    end
    return fullName
end

local function GetOathOfLightTexture()
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, "Oath of Light")
        if ok and IsSafeValue(tex) and tex then
            return tex
        end
        if singleTarget.spellId then
            local ok2, tex2 = pcall(C_Spell.GetSpellTexture, singleTarget.spellId)
            if ok2 and IsSafeValue(tex2) and tex2 then
                return tex2
            end
        end
        if singleTarget.spellName then
            local ok3, tex3 = pcall(C_Spell.GetSpellTexture, singleTarget.spellName)
            if ok3 and IsSafeValue(tex3) and tex3 then
                return tex3
            end
        end
    end
    if GetSpellTexture then
        local ok, tex = pcall(GetSpellTexture, "Oath of Light")
        if ok and IsSafeValue(tex) and tex then
            return tex
        end
    end
    return FALLBACK_OATH_ICON
end

local function IsOathSpellId(spellId)
    if not IsSafeValue(spellId) or type(spellId) ~= "number" then return false end
    if knownOathSpellIds[spellId] then return true end
    if C_Spell and C_Spell.GetSpellName then
        local ok, sName = pcall(C_Spell.GetSpellName, spellId)
        if ok and IsSafeValue(sName) and type(sName) == "string" then
            if OATH_SPELLS[sName] or (MATCH_ANY_OATH_KEYWORD and SafeStringFind(sName, "Oath")) then
                knownOathSpellIds[spellId] = true
                return true
            end
        end
    end
    return false
end

local function IsOathBuff(buffName, spellId)
    if IsOathSpellId(spellId) then
        return true
    end
    local sName = SafeToString(buffName)
    if not sName or sName == "" then return false end
    if OATH_SPELLS[sName] then
        if IsSafeValue(spellId) and type(spellId) == "number" then
            knownOathSpellIds[spellId] = true
        end
        return true
    end
    if MATCH_ANY_OATH_KEYWORD and SafeStringFind(sName, "Oath") then
        if IsSafeValue(spellId) and type(spellId) == "number" then
            knownOathSpellIds[spellId] = true
        end
        return true
    end
    return false
end

local function ResolveCurrentUnit(guid, fullName)
    local g = SafeToString(guid)
    if g and g ~= "" then
        if UnitExists("target") and IsSafeValue(UnitGUID("target")) and UnitGUID("target") == g then return "target" end
        if UnitExists("focus") and IsSafeValue(UnitGUID("focus")) and UnitGUID("focus") == g then return "focus" end
        if IsInRaid() then
            for i = 1, 40 do
                local u = "raid" .. i
                if UnitExists(u) and IsSafeValue(UnitGUID(u)) and UnitGUID(u) == g then return u end
            end
        elseif IsInGroup() then
            for i = 1, 4 do
                local u = "party" .. i
                if UnitExists(u) and IsSafeValue(UnitGUID(u)) and UnitGUID(u) == g then return u end
            end
        end
        if UnitExists("player") and IsSafeValue(UnitGUID("player")) and UnitGUID("player") == g then return "player" end
    end

    local targetNorm = NormalizeFullName(fullName)
    if targetNorm ~= "" then
        if UnitExists("target") and NormalizeFullName(GetFullUnitName("target")) == targetNorm then return "target" end
        if UnitExists("focus") and NormalizeFullName(GetFullUnitName("focus")) == targetNorm then return "focus" end
        if IsInRaid() then
            for i = 1, 40 do
                local u = "raid" .. i
                if UnitExists(u) and NormalizeFullName(GetFullUnitName(u)) == targetNorm then
                    return u
                end
            end
        elseif IsInGroup() then
            for i = 1, 4 do
                local u = "party" .. i
                if UnitExists(u) and NormalizeFullName(GetFullUnitName(u)) == targetNorm then
                    return u
                end
            end
        end
        if NormalizeFullName(GetFullUnitName("player")) == targetNorm then return "player" end
    end

    return nil
end

-- ============================================================================
-- AUDIBLE ALERT HELPER (Checks willPlay return value so muted/invalid IDs skip)
-- ============================================================================
local SOUND_KIT_CANDIDATES = {
    SOUNDKIT and SOUNDKIT.RAID_WARNING,
    SOUNDKIT and SOUNDKIT.READY_CHECK,
    SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3,
    SOUNDKIT and SOUNDKIT.TELL_MESSAGE,
    SOUNDKIT and SOUNDKIT.MAP_PING,
    SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN,
    8959,  -- Classic RaidWarning sound kit ID
    8960,  -- Classic ReadyCheck sound kit ID
    3081,  -- Classic TellMessage sound kit ID
}

local SOUND_FILE_CANDIDATES = {
    "Sound\\Interface\\RaidWarning.ogg",
    "Sound\\Interface\\RaidWarning.wav",
    "Sound\\Interface\\ReadyCheck.ogg",
    "Sound\\Interface\\ReadyCheck.wav",
    "Sound\\Interface\\AlarmClockWarning3.ogg",
    567397,
    567478,
}

local function PlayMissingOathSound(forceTest)
    if not forceTest and not OathTrackerDB.soundEnabled then
        return
    end
    if not forceTest and InCombatLockdown() then
        return
    end
    local now = GetTime()
    if not forceTest and (now - lastAlertSoundTime) < SOUND_COOLDOWN then
        return
    end
    lastAlertSoundTime = now

    local channels = { "Master", "SFX", "Dialog", "Ambience" }

    -- 1. Try PlaySound and verify `willPlay == true` (pcall alone returns true even if WoW did not play a sound!)
    if PlaySound then
        for _, kitId in ipairs(SOUND_KIT_CANDIDATES) do
            if kitId then
                for _, ch in ipairs(channels) do
                    local ok, willPlay = pcall(PlaySound, kitId, ch, false)
                    if ok and willPlay then
                        return
                    end
                end
                local okDef, willPlayDef = pcall(PlaySound, kitId)
                if okDef and willPlayDef then
                    return
                end
            end
        end
    end

    -- 2. Fallback to PlaySoundFile (classic file paths & FileDataIDs) and verify `willPlay == true`
    if PlaySoundFile then
        for _, fileRef in ipairs(SOUND_FILE_CANDIDATES) do
            for _, ch in ipairs(channels) do
                local ok, willPlay = pcall(PlaySoundFile, fileRef, ch)
                if ok and willPlay then
                    return
                end
            end
            local okDef, willPlayDef = pcall(PlaySoundFile, fileRef)
            if okDef and willPlayDef then
                return
            end
        end
    end
end

-- ============================================================================
-- CENTER CLICKABLE REAPPLY ICON (38x38, always active OOC even if main GUI is hidden)
-- ============================================================================
local centerIconBtn = CreateFrame("Button", "OathTrackerCenterAlertButton", UIParent, "SecureActionButtonTemplate")
centerIconBtn:SetSize(38, 38)
centerIconBtn:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
centerIconBtn:SetFrameStrata("DIALOG")
centerIconBtn:RegisterForClicks("AnyUp", "AnyDown")
centerIconBtn:Hide()

centerIconBtn.border = centerIconBtn:CreateTexture(nil, "BACKGROUND")
centerIconBtn.border:SetPoint("TOPLEFT", -3, 3)
centerIconBtn.border:SetPoint("BOTTOMRIGHT", 3, -3)
centerIconBtn.border:SetColorTexture(1.0, 0.15, 0.15, 0.95)

centerIconBtn.icon = centerIconBtn:CreateTexture(nil, "ARTWORK")
centerIconBtn.icon:SetAllPoints(centerIconBtn)
centerIconBtn.icon:SetTexture(FALLBACK_OATH_ICON)
centerIconBtn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

centerIconBtn.glow = centerIconBtn:CreateTexture(nil, "OVERLAY")
centerIconBtn.glow:SetAllPoints(centerIconBtn)
centerIconBtn.glow:SetColorTexture(1.0, 0.25, 0.15, 0.30)
centerIconBtn.glow:SetBlendMode("ADD")

centerIconBtn.timerText = centerIconBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
centerIconBtn.timerText:SetPoint("CENTER", centerIconBtn, "CENTER", 0, 0)
centerIconBtn.timerText:SetText("")

centerIconBtn.label = centerIconBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
centerIconBtn.label:SetPoint("TOP", centerIconBtn, "BOTTOM", 0, -4)
centerIconBtn.label:SetText("|cffff2222REAPPLY OATH|r")

centerIconBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Oath Reapply - Click to Cast", 1, 0.2, 0.2)
    if singleTarget.name and singleTarget.spellName then
        GameTooltip:AddLine("Target: |cffffffff" .. singleTarget.name .. "|r", 1, 1, 1)
        GameTooltip:AddLine("Spell: |cff00ff00" .. singleTarget.spellName .. "|r", 1, 1, 1)
    end
    GameTooltip:Show()
end)
centerIconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function UpdateCenterReapplyIcon(shouldShow, remainingSeconds)
    if InCombatLockdown() then
        pendingCenterIconState = shouldShow
        return
    end
    pendingCenterIconState = nil

    if not shouldShow or not singleTarget.active or not singleTarget.spellName then
        centerIconBtn:SetAttribute("type", nil)
        centerIconBtn:SetAttribute("unit", nil)
        centerIconBtn:SetAttribute("spell", nil)
        centerIconBtn.timerText:SetText("")
        centerIconBtn:Hide()
        return
    end

    local resolvedUnit = ResolveCurrentUnit(singleTarget.guid, singleTarget.name)
    if resolvedUnit then
        singleTarget.unit = resolvedUnit
    end

    local targetAttr = resolvedUnit or singleTarget.name
    centerIconBtn.icon:SetTexture(GetOathOfLightTexture())
    centerIconBtn:SetAttribute("type", "spell")
    centerIconBtn:SetAttribute("spell", singleTarget.spellName)
    centerIconBtn:SetAttribute("unit", targetAttr)

    local shortLabel = singleTarget.shortName or FormatDisplayName(singleTarget.name)
    if remainingSeconds and remainingSeconds > 0 then
        centerIconBtn.border:SetColorTexture(1.0, 0.75, 0.1, 0.95)
        centerIconBtn.timerText:SetText(string.format("|cffffdd00%d|r", math.ceil(remainingSeconds)))
        centerIconBtn.label:SetText("|cffffcc00REAPPLY (" .. math.ceil(remainingSeconds) .. "s) -> " .. shortLabel .. "|r")
    else
        centerIconBtn.border:SetColorTexture(1.0, 0.15, 0.15, 0.95)
        centerIconBtn.timerText:SetText("")
        centerIconBtn.label:SetText("|cffff2222REAPPLY -> " .. shortLabel .. "|r")
    end
    centerIconBtn:Show()
end

local function SetSingleTargetAlertStatus(newStatus)
    if not singleTarget.active then return end
    local wasAlert = (singleTarget.status == "DEAD_REAPPLY" or singleTarget.status == "MISSING_REAPPLY")
    local isNowAlert = (newStatus == "DEAD_REAPPLY" or newStatus == "MISSING_REAPPLY")

    singleTarget.status = newStatus
    if isNowAlert then
        singleTarget.expires = 0
        prewarnAlertPlayed = false
        if not wasAlert then
            PlayMissingOathSound(false)
        end
        UpdateCenterReapplyIcon(true, nil)
    else
        local rem = singleTarget.expires - GetTime()
        if rem > 0 and rem <= REAPPLY_PREWARN then
            UpdateCenterReapplyIcon(true, rem)
        else
            prewarnAlertPlayed = false
            UpdateCenterReapplyIcon(false, nil)
        end
    end
end

-- ============================================================================
-- RESET FUNCTION
-- ============================================================================
local function ResetTrackerState(silent)
    singleTarget.active = false
    singleTarget.guid = nil
    singleTarget.name = nil
    singleTarget.shortName = nil
    singleTarget.unit = nil
    singleTarget.spellName = nil
    singleTarget.spellId = nil
    singleTarget.expires = 0
    singleTarget.status = "NONE"
    singleTarget.castTime = 0
    singleTarget.wasActive = false
    singleTarget.lastSlotSnapshot = nil
    prewarnAlertPlayed = false

    UpdateCenterReapplyIcon(false, nil)

    if not silent then
        print("|cff00ccff[Oath Tracker]|r Tracked target cleared.")
    end
end

-- ============================================================================
-- MAIN TRACKER WINDOW (Compact Single-Target Status + Reset + Hide GUI)
-- ============================================================================
local frame = CreateFrame("Frame", "OathTrackerMainFrame", UIParent, "BackdropTemplate")
frame:SetSize(286, 86)
frame:SetPoint(OathTrackerDB.point, UIParent, OathTrackerDB.relativePoint, OathTrackerDB.x, OathTrackerDB.y)
frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
frame:SetBackdropColor(0.06, 0.07, 0.11, 0.92)
frame:SetBackdropBorderColor(0.25, 0.65, 0.95, 0.9)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)

frame:SetScript("OnDragStart", function(self)
    if not OathTrackerDB.locked then
        self:StartMoving()
    end
end)

frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    OathTrackerDB.point = point
    OathTrackerDB.relativePoint = relativePoint
    OathTrackerDB.x = x
    OathTrackerDB.y = y
end)

local headerBg = frame:CreateTexture(nil, "ARTWORK")
headerBg:SetPoint("TOPLEFT", 4, -4)
headerBg:SetPoint("TOPRIGHT", -4, -4)
headerBg:SetHeight(22)
headerBg:SetColorTexture(0.12, 0.16, 0.24, 0.95)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", headerBg, "LEFT", 6, 0)
title:SetText("|cff33ccffOath Tracker|r")

local hideGuiBtn = CreateFrame("Button", "OathTrackerHideButton", frame, "UIPanelButtonTemplate")
hideGuiBtn:SetSize(22, 18)
hideGuiBtn:SetPoint("RIGHT", headerBg, "RIGHT", -2, 0)
hideGuiBtn:SetText("|cffff6666X|r")
hideGuiBtn:SetScript("OnClick", function()
    OathTrackerDB.guiHidden = true
    frame:Hide()
    print("|cff00ccff[Oath Tracker]|r GUI hidden. Type |cffffcc00/oath show|r to restore it.")
end)
hideGuiBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Hide GUI (/oath hide)", 1, 0.4, 0.4)
    GameTooltip:AddLine("Tracking stays active. Type /oath show to bring it back.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
hideGuiBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local visualToggleBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
visualToggleBtn:SetSize(22, 18)
visualToggleBtn:SetPoint("RIGHT", hideGuiBtn, "LEFT", -2, 0)

local soundToggleBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
soundToggleBtn:SetSize(22, 18)
soundToggleBtn:SetPoint("RIGHT", visualToggleBtn, "LEFT", -2, 0)

local resetBtn = CreateFrame("Button", "OathTrackerResetButton", frame, "UIPanelButtonTemplate")
resetBtn:SetSize(44, 18)
resetBtn:SetPoint("RIGHT", soundToggleBtn, "LEFT", -3, 0)
resetBtn:SetText("|cffffaa44Reset|r")
resetBtn:SetScript("OnClick", function()
    ResetTrackerState(false)
end)
resetBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Reset Tracked Target", 1, 0.7, 0.2)
    GameTooltip:AddLine("Clears the currently tracked target.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function RefreshOptionButtons()
    if OathTrackerDB.soundEnabled then
        soundToggleBtn:SetText("|cff33ff33S|r")
    else
        soundToggleBtn:SetText("|cffff4444S|r")
    end

    if OathTrackerDB.intenseVisual then
        visualToggleBtn:SetText("|cff33ff33V|r")
    else
        visualToggleBtn:SetText("|cff888888V|r")
    end
end

soundToggleBtn:SetScript("OnClick", function()
    OathTrackerDB.soundEnabled = not OathTrackerDB.soundEnabled
    RefreshOptionButtons()
    if OathTrackerDB.soundEnabled then
        PlayMissingOathSound(true)
        print("|cff00ccff[Oath Tracker]|r Alert sound: |cff33ff33ON|r")
    else
        print("|cff00ccff[Oath Tracker]|r Alert sound: |cffff4444OFF|r")
    end
end)
soundToggleBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Toggle Alert Sound (/oath sound)", 0, 0.8, 1)
    GameTooltip:AddLine("Status: " .. (OathTrackerDB.soundEnabled and "|cff33ff33Enabled|r" or "|cffff4444Disabled|r"), 1, 1, 1)
    GameTooltip:Show()
end)
soundToggleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

visualToggleBtn:SetScript("OnClick", function()
    OathTrackerDB.intenseVisual = not OathTrackerDB.intenseVisual
    RefreshOptionButtons()
    print("|cff00ccff[Oath Tracker]|r Pulse visual alert: " .. (OathTrackerDB.intenseVisual and "|cff33ff33ON|r" or "|cffff4444OFF|r"))
end)
visualToggleBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Toggle Pulse Visuals (/oath visual)", 0, 0.8, 1)
    GameTooltip:AddLine("Status: " .. (OathTrackerDB.intenseVisual and "|cff33ff33Enabled|r" or "|cffff4444Disabled|r"), 1, 1, 1)
    GameTooltip:Show()
end)
visualToggleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Single-target row
local statusRow = CreateFrame("Frame", nil, frame)
statusRow:SetSize(268, 24)
statusRow:SetPoint("TOPLEFT", 9, -32)

statusRow.bg = statusRow:CreateTexture(nil, "BACKGROUND")
statusRow.bg:SetAllPoints(statusRow)
statusRow.bg:SetColorTexture(0.12, 0.14, 0.20, 0.75)

statusRow.accent = statusRow:CreateTexture(nil, "ARTWORK")
statusRow.accent:SetPoint("LEFT", 0, 0)
statusRow.accent:SetSize(4, 24)
statusRow.accent:SetColorTexture(0.4, 0.4, 0.5, 1.0)

statusRow.nameText = statusRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statusRow.nameText:SetPoint("LEFT", 8, 0)
statusRow.nameText:SetWidth(146)
statusRow.nameText:SetJustifyH("LEFT")
statusRow.nameText:SetText("|cff888888No target tracked|r")

statusRow.statusText = statusRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statusRow.statusText:SetPoint("RIGHT", -6, 0)
statusRow.statusText:SetWidth(108)
statusRow.statusText:SetJustifyH("RIGHT")
statusRow.statusText:SetText("|cff888888OOC Only|r")

local modeFooter = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
modeFooter:SetPoint("BOTTOMLEFT", 10, 7)
modeFooter:SetText("Active Out of Combat | /oath show")

-- ============================================================================
-- OUT-OF-COMBAT BUFF INSPECTION
-- ============================================================================
local function GetSafeUnitIdentity(unit)
    if not IsSafeValue(unit) or not UnitExists(unit) then return nil, nil end
    if C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret and C_Secrets.ShouldUnitIdentityBeSecret(unit) then
        return nil, nil
    end

    local guid = UnitGUID(unit)
    if not IsSafeValue(guid) then guid = nil end

    local fullName = GetFullUnitName(unit)
    if not IsSafeValue(fullName) or fullName == "" then
        return nil, nil
    end

    return guid, fullName
end

local function InspectUnitBuffs(unit)
    local foundBuffName = nil
    local foundExpires = nil
    local foundSpellId = nil
    local slotParts = {}

    local aurasLocked = false
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        aurasLocked = true
    end

    if not aurasLocked and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
            if not ok or not aura then break end

            local auraId = IsSafeValue(aura.spellId) and aura.spellId or nil
            local auraName = SafeToString(aura.name)
            local auraExp = IsSafeValue(aura.expirationTime) and aura.expirationTime or 0
            local auraInst = IsSafeValue(aura.auraInstanceID) and aura.auraInstanceID or i

            table.insert(slotParts, tostring(auraInst) .. ":" .. tostring(auraId or auraName or "?") .. ":" .. tostring(auraExp))

            local auraSecret = false
            if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret and auraId then
                local sOk, isSec = pcall(C_Secrets.ShouldSpellAuraBeSecret, auraId)
                if sOk and isSec then auraSecret = true end
            end

            if not auraSecret and IsOathBuff(auraName, auraId) then
                foundBuffName = auraName or singleTarget.spellName or "Oath of Light"
                foundSpellId = auraId or singleTarget.spellId

                if IsSafeValue(aura.duration) and type(aura.duration) == "number" and aura.duration > 0 and foundSpellId then
                    learnedDurations[foundSpellId] = aura.duration
                end

                if IsSafeValue(aura.expirationTime) and type(aura.expirationTime) == "number" and aura.expirationTime > 0 then
                    foundExpires = aura.expirationTime
                else
                    local dur = (foundSpellId and learnedDurations[foundSpellId]) or DEFAULT_DURATION
                    foundExpires = (singleTarget.expires and singleTarget.expires > GetTime())
                                   and singleTarget.expires
                                   or (GetTime() + dur)
                end
                break
            end
        end
        return foundBuffName, foundExpires, foundSpellId, table.concat(slotParts, "|"), aurasLocked
    end

    if not aurasLocked and UnitBuff then
        for i = 1, 40 do
            local ok, auraName, _, _, duration, expirationTime, _, _, _, spellId = pcall(UnitBuff, unit, i)
            if not ok or not auraName then break end

            local sName = SafeToString(auraName)
            local sId = IsSafeValue(spellId) and spellId or nil
            local sExp = IsSafeValue(expirationTime) and expirationTime or 0
            table.insert(slotParts, tostring(i) .. ":" .. tostring(sId or sName or "?") .. ":" .. tostring(sExp))

            if IsOathBuff(sName, sId) then
                foundBuffName = sName or singleTarget.spellName or "Oath of Light"
                foundSpellId = sId or singleTarget.spellId
                if IsSafeValue(expirationTime) and type(expirationTime) == "number" and expirationTime > 0 then
                    foundExpires = expirationTime
                else
                    foundExpires = (singleTarget.expires and singleTarget.expires > GetTime())
                                   and singleTarget.expires
                                   or (GetTime() + DEFAULT_DURATION)
                end
                break
            end
        end
    end

    return foundBuffName, foundExpires, foundSpellId, table.concat(slotParts, "|"), aurasLocked
end

-- ONLY checks the single tracked target, and ONLY Out of Combat
local function CheckSingleTrackedTargetOOC()
    if InCombatLockdown() then return end
    if not singleTarget.active then return end

    local liveUnit = ResolveCurrentUnit(singleTarget.guid, singleTarget.name)
    if liveUnit then
        singleTarget.unit = liveUnit
    end

    local u = singleTarget.unit
    if not u or not UnitExists(u) then
        return
    end

    local isDead = UnitIsDeadOrGhost(u)
    local isConnected = UnitIsConnected(u)

    if IsSafeValue(isDead) and isDead then
        SetSingleTargetAlertStatus("DEAD_REAPPLY")
        return
    end

    if IsSafeValue(isConnected) and not isConnected then
        singleTarget.status = "OFFLINE"
        UpdateCenterReapplyIcon(false, nil)
        return
    end

    if singleTarget.status == "DEAD_REAPPLY" then
        SetSingleTargetAlertStatus("MISSING_REAPPLY")
    end

    local foundBuffName, foundExpires, foundSpellId, slotSnapshot, aurasLocked = InspectUnitBuffs(u)

    if foundBuffName then
        singleTarget.spellName = foundBuffName
        singleTarget.spellId = foundSpellId or singleTarget.spellId
        singleTarget.expires = foundExpires
        singleTarget.wasActive = true
        singleTarget.lastSlotSnapshot = slotSnapshot
        SetSingleTargetAlertStatus("ACTIVE")
    else
        local sinceCast = GetTime() - (singleTarget.castTime or 0)
        if sinceCast > 0.25 then
            if not aurasLocked then
                SetSingleTargetAlertStatus("MISSING_REAPPLY")
            elseif singleTarget.wasActive and singleTarget.lastSlotSnapshot and singleTarget.lastSlotSnapshot ~= slotSnapshot then
                SetSingleTargetAlertStatus("MISSING_REAPPLY")
            end
            singleTarget.lastSlotSnapshot = slotSnapshot
        end
    end
end

-- ============================================================================
-- BACKGROUND ENGINE (Runs even when main GUI is hidden via X or /oath hide)
-- ============================================================================
local pendingCastTargetGUID = nil
local pendingCastTargetName = nil
local pendingCastTargetUnit = nil

local engineFrame = CreateFrame("Frame")
engineFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
engineFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
engineFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
engineFrame:RegisterEvent("UNIT_AURA")
engineFrame:RegisterEvent("UNIT_FLAGS")
engineFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
engineFrame:RegisterEvent("UNIT_SPELLCAST_SENT")
engineFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

engineFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        InitDefaults()
        RefreshOptionButtons()
        if InCombatLockdown() then
            frame:Hide()
            centerIconBtn:Hide()
        else
            if OathTrackerDB.guiHidden then
                frame:Hide()
            else
                frame:Show()
            end
            CheckSingleTrackedTargetOOC()
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat: hide addon & center icon immediately (OOC-only mode)
        frame:Hide()
        centerIconBtn:Hide()

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat: restore main GUI only if user hasn't hidden it, and check tracked target
        if not OathTrackerDB.guiHidden then
            frame:Show()
        end
        if pendingCenterIconState ~= nil then
            UpdateCenterReapplyIcon(pendingCenterIconState, nil)
        end
        CheckSingleTrackedTargetOOC()

    elseif event == "GROUP_ROSTER_UPDATE" then
        if not InCombatLockdown() then
            CheckSingleTrackedTargetOOC()
        end

    elseif event == "UNIT_AURA" or event == "UNIT_FLAGS" then
        if InCombatLockdown() or not singleTarget.active then return end
        local unit = ...
        if unit and IsSafeValue(unit) then
            local trackedUnit = ResolveCurrentUnit(singleTarget.guid, singleTarget.name) or singleTarget.unit
            if trackedUnit and (unit == trackedUnit or UnitIsUnit(unit, trackedUnit)) then
                CheckSingleTrackedTargetOOC()
            end
        end

    elseif event == "UNIT_SPELLCAST_SENT" then
        local unit, targetName, castGUID, spellId = ...
        if unit == "player" and IsSafeValue(spellId) then
            local spellName = nil
            if C_Spell and C_Spell.GetSpellName then
                local ok, s = pcall(C_Spell.GetSpellName, spellId)
                if ok then spellName = SafeToString(s) end
            end
            if IsOathBuff(spellName, spellId) then
                local chosenUnit = nil
                local chosenGuid = nil
                local chosenName = nil

                local cleanTarget = SafeToString(targetName)
                if cleanTarget and SafeStrTrim(cleanTarget) ~= "" then
                    local trimmed = SafeStrTrim(cleanTarget)
                    local resolved = ResolveCurrentUnit(nil, trimmed)
                    if resolved then
                        chosenUnit = resolved
                        chosenGuid, chosenName = GetSafeUnitIdentity(resolved)
                    else
                        chosenName = trimmed
                    end
                end

                if not chosenName then
                    if UnitExists("target") and UnitIsFriend("player", "target") then
                        chosenUnit = "target"
                        chosenGuid, chosenName = GetSafeUnitIdentity("target")
                    elseif UnitExists("mouseover") and UnitIsFriend("player", "mouseover") then
                        chosenUnit = "mouseover"
                        chosenGuid, chosenName = GetSafeUnitIdentity("mouseover")
                    else
                        chosenUnit = "player"
                        chosenGuid, chosenName = GetSafeUnitIdentity("player")
                    end
                end

                pendingCastTargetGUID = chosenGuid
                pendingCastTargetName = chosenName
                pendingCastTargetUnit = chosenUnit
            end
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellId = ...
        if unit == "player" and IsSafeValue(spellId) then
            local spellName = nil
            if C_Spell and C_Spell.GetSpellName then
                local ok, s = pcall(C_Spell.GetSpellName, spellId)
                if ok then spellName = SafeToString(s) end
            end
            if IsOathBuff(spellName, spellId) then
                local resolvedSpellName = spellName or "Oath of Light"
                local dur = (IsSafeValue(spellId) and learnedDurations[spellId]) or DEFAULT_DURATION

                local tGuid = pendingCastTargetGUID
                local tName = pendingCastTargetName
                local tUnit = pendingCastTargetUnit

                if not tName then
                    if UnitExists("target") and UnitIsFriend("player", "target") then
                        tUnit = "target"
                        tGuid, tName = GetSafeUnitIdentity("target")
                    else
                        tUnit = "player"
                        tGuid, tName = GetSafeUnitIdentity("player")
                    end
                end

                singleTarget.active = true
                singleTarget.guid = tGuid
                singleTarget.name = tName or "Target"
                singleTarget.shortName = FormatDisplayName(singleTarget.name)
                singleTarget.unit = tUnit
                singleTarget.spellName = resolvedSpellName
                singleTarget.spellId = IsSafeValue(spellId) and spellId or nil
                singleTarget.expires = GetTime() + dur
                singleTarget.status = "ACTIVE"
                singleTarget.castTime = GetTime()
                singleTarget.wasActive = true
                singleTarget.lastSlotSnapshot = nil
                prewarnAlertPlayed = false

                pendingCastTargetGUID = nil
                pendingCastTargetName = nil
                pendingCastTargetUnit = nil

                if not InCombatLockdown() then
                    UpdateCenterReapplyIcon(false, nil)
                    C_Timer.After(0.25, CheckSingleTrackedTargetOOC)
                end
            end
        end
    end
end)

-- ============================================================================
-- OOC UPDATE LOOP (Attached to engineFrame so it keeps running even if main GUI is hidden)
-- ============================================================================
local elapsedUi = 0
local elapsedScan = 0

engineFrame:SetScript("OnUpdate", function(self, elapsed)
    if InCombatLockdown() then return end

    elapsedUi = elapsedUi + elapsed
    elapsedScan = elapsedScan + elapsed

    if elapsedScan >= PERIODIC_SCAN_INTERVAL then
        elapsedScan = 0
        CheckSingleTrackedTargetOOC()
    end

    if elapsedUi < 0.05 then return end
    elapsedUi = 0

    local now = GetTime()

    if not singleTarget.active then
        if frame:IsShown() then
            statusRow.nameText:SetText("|cff888888No target tracked|r")
            statusRow.statusText:SetText("|cff888888Cast Oath|r")
            statusRow.bg:SetColorTexture(0.12, 0.14, 0.20, 0.75)
            statusRow.accent:SetColorTexture(0.4, 0.4, 0.5, 1.0)
            frame:SetBackdropBorderColor(0.25, 0.65, 0.95, 0.9)
            frame:SetBackdropColor(0.06, 0.07, 0.11, 0.92)
            headerBg:SetColorTexture(0.12, 0.16, 0.24, 0.95)
        end
        return
    end

    local displayLabel = singleTarget.shortName or FormatDisplayName(singleTarget.name)
    if frame:IsShown() then
        statusRow.nameText:SetText("|cffffffff" .. displayLabel .. "|r")
    end

    local alertActive = false
    local prewarnActive = false

    if singleTarget.status == "DEAD_REAPPLY" then
        alertActive = true
        if frame:IsShown() then
            statusRow.statusText:SetText("|cffff3333DEAD -> REAPPLY|r")
            statusRow.bg:SetColorTexture(0.45, 0.06, 0.06, 0.85)
            statusRow.accent:SetColorTexture(1.0, 0.15, 0.15, 1.0)
        end
        UpdateCenterReapplyIcon(true, nil)

    elseif singleTarget.status == "MISSING_REAPPLY" then
        alertActive = true
        if frame:IsShown() then
            statusRow.statusText:SetText("|cffff3333MISSING|r")
            statusRow.bg:SetColorTexture(0.45, 0.06, 0.06, 0.85)
            statusRow.accent:SetColorTexture(1.0, 0.15, 0.15, 1.0)
        end
        UpdateCenterReapplyIcon(true, nil)

    elseif singleTarget.status == "OFFLINE" then
        if frame:IsShown() then
            statusRow.statusText:SetText("|cff999999OFFLINE|r")
            statusRow.bg:SetColorTexture(0.14, 0.14, 0.16, 0.70)
            statusRow.accent:SetColorTexture(0.5, 0.5, 0.5, 1.0)
        end
        UpdateCenterReapplyIcon(false, nil)

    else
        local remaining = singleTarget.expires - now
        if remaining <= 0 then
            SetSingleTargetAlertStatus("MISSING_REAPPLY")
            alertActive = true
            if frame:IsShown() then
                statusRow.statusText:SetText("|cffff3333EXPIRED|r")
                statusRow.bg:SetColorTexture(0.45, 0.06, 0.06, 0.85)
                statusRow.accent:SetColorTexture(1.0, 0.15, 0.15, 1.0)
            end

        elseif remaining <= REAPPLY_PREWARN then
            prewarnActive = true
            if not prewarnAlertPlayed then
                prewarnAlertPlayed = true
                PlayMissingOathSound(false)
            end
            UpdateCenterReapplyIcon(true, remaining)
            if frame:IsShown() then
                statusRow.statusText:SetText(string.format("|cffffcc00%ds|r", math.ceil(remaining)))
                statusRow.bg:SetColorTexture(0.35, 0.25, 0.04, 0.80)
                statusRow.accent:SetColorTexture(1.0, 0.8, 0.1, 1.0)
            end

        elseif remaining <= WARN_THRESHOLD then
            UpdateCenterReapplyIcon(false, nil)
            if frame:IsShown() then
                statusRow.statusText:SetText(string.format("|cffffcc00%ds|r", math.ceil(remaining)))
                statusRow.bg:SetColorTexture(0.35, 0.25, 0.04, 0.80)
                statusRow.accent:SetColorTexture(1.0, 0.8, 0.1, 1.0)
            end

        else
            UpdateCenterReapplyIcon(false, nil)
            if frame:IsShown() then
                local mins = math.ceil(remaining / 60)
                statusRow.statusText:SetText(string.format("|cff33ff55%d Min|r", mins))
                statusRow.bg:SetColorTexture(0.08, 0.22, 0.14, 0.75)
                statusRow.accent:SetColorTexture(0.2, 0.9, 0.4, 1.0)
            end
        end
    end

    if (alertActive or prewarnActive) and OathTrackerDB.intenseVisual then
        local pulse = 0.5 + 0.5 * math.sin(now * 7.5)
        if frame:IsShown() then
            if alertActive then
                frame:SetBackdropBorderColor(1.0, 0.15 + 0.25 * pulse, 0.15, 1.0)
                frame:SetBackdropColor(0.22 + 0.12 * pulse, 0.03, 0.04, 0.95)
                headerBg:SetColorTexture(0.55 + 0.25 * pulse, 0.06, 0.06, 0.95)
            else
                frame:SetBackdropBorderColor(1.0, 0.75, 0.15, 1.0)
                frame:SetBackdropColor(0.18 + 0.08 * pulse, 0.14, 0.03, 0.95)
                headerBg:SetColorTexture(0.45 + 0.15 * pulse, 0.32, 0.05, 0.95)
            end
        end
        centerIconBtn.glow:SetAlpha(0.15 + 0.45 * pulse)
    elseif alertActive then
        if frame:IsShown() then
            frame:SetBackdropBorderColor(0.95, 0.25, 0.25, 0.95)
            frame:SetBackdropColor(0.14, 0.05, 0.06, 0.92)
            headerBg:SetColorTexture(0.32, 0.08, 0.08, 0.95)
        end
        centerIconBtn.glow:SetAlpha(0.25)
    elseif prewarnActive then
        if frame:IsShown() then
            frame:SetBackdropBorderColor(0.95, 0.75, 0.20, 0.95)
            frame:SetBackdropColor(0.14, 0.11, 0.04, 0.92)
            headerBg:SetColorTexture(0.32, 0.24, 0.06, 0.95)
        end
        centerIconBtn.glow:SetAlpha(0.20)
    else
        if frame:IsShown() then
            frame:SetBackdropBorderColor(0.25, 0.65, 0.95, 0.9)
            frame:SetBackdropColor(0.06, 0.07, 0.11, 0.92)
            headerBg:SetColorTexture(0.12, 0.16, 0.24, 0.95)
        end
    end
end)

-- ============================================================================
-- SLASH COMMANDS (/oath)
-- ============================================================================
SLASH_OATHTRACKER1 = "/oath"
SlashCmdList["OATHTRACKER"] = function(msg)
    msg = SafeStrLower(SafeStrTrim(msg or ""))

    if msg == "reset" then
        ResetTrackerState(false)
    elseif msg == "scan" then
        CheckSingleTrackedTargetOOC()
        print("|cff00ccff[Oath Tracker]|r Checked tracked target.")
    elseif msg == "sound" then
        OathTrackerDB.soundEnabled = not OathTrackerDB.soundEnabled
        RefreshOptionButtons()
        if OathTrackerDB.soundEnabled then
            PlayMissingOathSound(true)
            print("|cff00ccff[Oath Tracker]|r Alert sound: |cff33ff33ON|r")
        else
            print("|cff00ccff[Oath Tracker]|r Alert sound: |cffff4444OFF|r")
        end
    elseif msg == "visual" then
        OathTrackerDB.intenseVisual = not OathTrackerDB.intenseVisual
        RefreshOptionButtons()
        print("|cff00ccff[Oath Tracker]|r Pulse visual alert: " .. (OathTrackerDB.intenseVisual and "|cff33ff33ON|r" or "|cffff4444OFF|r"))
    elseif msg == "lock" then
        OathTrackerDB.locked = not OathTrackerDB.locked
        print("|cff00ccff[Oath Tracker]|r Window " .. (OathTrackerDB.locked and "locked." or "unlocked."))
    elseif msg == "hide" then
        OathTrackerDB.guiHidden = true
        frame:Hide()
        print("|cff00ccff[Oath Tracker]|r GUI hidden. Type |cffffcc00/oath show|r to restore it.")
    elseif msg == "show" then
        OathTrackerDB.guiHidden = false
        if not InCombatLockdown() then
            frame:Show()
            print("|cff00ccff[Oath Tracker]|r GUI shown.")
        else
            print("|cff00ccff[Oath Tracker]|r GUI will appear as soon as combat ends.")
        end
    else
        print("|cff00ccffOath Tracker Commands:|r")
        print("  |cffffcc00/oath show / hide|r - Show or hide the tracker GUI")
        print("  |cffffcc00/oath reset|r - Clear tracked target")
        print("  |cffffcc00/oath sound|r - Toggle & test alert sound")
        print("  |cffffcc00/oath visual|r - Toggle pulse visual alert")
        print("  |cffffcc00/oath scan|r - Manually check tracked target (OOC)")
        print("  |cffffcc00/oath lock|r - Lock/unlock window position")
    end
end
