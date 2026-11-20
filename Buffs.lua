-- Alt-click a buff to track it. Missing and expiring buffs share a movable
-- row of reminders and one timer for the next warning.

local SIZE, GAP = 40, 4
local HEIGHT = 150 -- above the centre of the screen, until moved

-- A buff is about to run out in the last tenth of its duration, and no sooner
-- than Blizzard's buff bar says so: it turns the time white at 90 seconds.
-- A weapon buff's duration is not told, so it gets the 90 seconds.
local WARN_FRACTION = 0.1
local WARN_MOST = BUFF_DURATION_WARNING_TIME

local SLOT_NAME = { [0] = "Main hand", "Off hand", "Ranged" } -- by Enum.WeaponSlot

-- BuffsDB, in the order added. A buff is { name, icon, spellID }: known by
-- its name, so that any rank of it counts, from anyone. A weapon buff is
-- { name, icon, slot, enchant }: that enchantment on that hand's weapon.
-- BuffsDB.x and .y are where the row has been moved to.
local tracked

-- The reminders sit in a row that the game hides in combat and while dead.
-- The driver is set now, while the row has no buttons: once it has, an addon
-- may not hide it in combat, and this may be loading in combat.
local row = CreateFrame("Frame", nil, UIParent)
row:SetSize(1, SIZE)
row:SetMovable(true)
row:SetClampedToScreen(true)
RegisterStateDriver(row, "visibility", "[combat] hide; [@player,dead] hide; show")

-- The row is placed by its centre, from the screen's: it grows and shrinks
-- about its centre as reminders come and go.
local function place()
	row:ClearAllPoints()
	row:SetPoint("CENTER", BuffsDB.x or 0, BuffsDB.y or HEIGHT)
end

-- Lets go of the row being moved, and keeps where it was left.
local moving
local function drop()
	if InCombatLockdown() then return end -- finish on PLAYER_REGEN_ENABLED
	moving = false
	row:StopMovingOrSizing()
	local x, y = row:GetCenter()
	if x then
		local screenX, screenY = UIParent:GetCenter()
		BuffsDB.x, BuffsDB.y = x - screenX, y - screenY
	end
	place()
end
-- The visibility driver can hide the row in the middle of a drag.
row:SetScript("OnHide", function()
	if moving then drop() end
end)

local buttons = {}
local refresh

local function untrack(buff)
	tDeleteItem(tracked, buff)
	print(("Buffs: no longer tracking %s."):format(buff.name))
	refresh()
end

local function showTooltip(button)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	GameTooltip:SetText(button.buff.name)
	GameTooltip:AddLine("Alt-click to stop tracking", GRAY_FONT_COLOR:GetRGB())
	GameTooltip:AddLine("Alt-drag to move", GRAY_FONT_COLOR:GetRGB())
	GameTooltip:Show()
end

-- The reminder button at a place in the row, made the first time it is needed.
-- A button keeps the buff it reminds of, not the buff's place in the list:
-- the list can change in combat, when the buttons cannot.
local function acquire(index)
	local button = buttons[index]
	if button then return button end
	button = CreateFrame("Button", nil, row, "SecureActionButtonTemplate")
	buttons[index] = button
	button:SetSize(SIZE, SIZE)
	button:SetPoint("LEFT", (index - 1) * (SIZE + GAP), 0)

	-- An unmodified left click casts by name so Blizzard picks the known rank.
	button:SetAttribute("type1", "spell")
	button:SetAttribute("unit", "player")
	button:SetAttribute("useOnKeyDown", false)
	button:SetScript("PostClick", function(self)
		if IsAltKeyDown() then untrack(self.buff) end
	end)

	button:SetScript("OnEnter", showTooltip)
	button:SetScript("OnLeave", GameTooltip_Hide)

	-- An Alt-drag moves the whole row. A drag is not a click, so it neither
	-- casts nor stops tracking.
	button:RegisterForDrag("LeftButton")
	button:SetScript("OnDragStart", function()
		if IsAltKeyDown() and not InCombatLockdown() then
			moving = true
			row:StartMoving()
		end
	end)
	button:SetScript("OnDragStop", function()
		if moving then drop() end
	end)

	button.icon = button:CreateTexture()
	button.icon:SetAllPoints()
	button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- inside the icon's border
	-- How much of the warning time is left, drawn by the game: a shrinking
	-- wedge and a countdown.
	button.time = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
	button.time:SetDrawBling(false)
	return button
end

-- Whether a tracked buff is on and, if it is, when it runs out (0 for never)
-- and how long before that to give warning.
local function status(buff, now)
	if buff.slot then
		for _, enchant in pairs(C_Item.GetWeaponEnchantInfo(buff.slot)) do
			if enchant.hasEnchant and enchant.enchantID == buff.enchant then
				return true, enchant.timeLeft > 0 and now + enchant.timeLeft / 1000 or 0, WARN_MOST
			end
		end
	else
		local aura = C_UnitAuras.GetAuraDataBySpellName("player", buff.name, "HELPFUL")
		-- A name can match a different rank from the spell originally tracked.
		-- Leave its reminder quiet while the actual aura or its timing is private.
		if not canaccessvalue(aura) then return true, 0 end
		if aura then
			if not canaccesstable(aura) or not canaccessallvalues(aura.expirationTime, aura.duration, aura.timeMod) then
				return true, 0
			end
			-- Blizzard displays (expirationTime - now) / timeMod on its buff bar.
			local rate = aura.timeMod and aura.timeMod > 0 and aura.timeMod or 1
			return true, aura.expirationTime, math.min(aura.duration * WARN_FRACTION, WARN_MOST * rate), rate
		end
	end
end

-- Weapon enchant time remaining is reported in whole milliseconds.
local function sameTime(a, b)
	return a == b or (a and b and math.abs(a - b) < 0.001)
end

local timer, timerAt
local visibleCount = 0

local function onWarning()
	timer, timerAt = nil, nil
	refresh()
end

-- Shows a reminder for each tracked buff that is missing or about to run out.
function refresh()
	-- The row is hidden and its buttons may not be touched; this runs again
	-- when combat ends.
	if InCombatLockdown() or (#tracked == 0 and visibleCount == 0 and not timer) then return end

	local now, soonest, shown = GetTime(), nil, 0
	for _, buff in ipairs(tracked) do
		-- Weapon buffs are never hidden. While the game hides a buff, nothing
		-- can be said about it.
		if buff.slot or not C_Secrets.ShouldSpellAuraBeSecret(buff.spellID) then
			local on, expires, warning, rate = status(buff, now)
			local warnAt = on and expires > 0 and expires - warning
			if warnAt and warnAt > now then
				if not soonest or warnAt < soonest then soonest = warnAt end
			elseif not on or warnAt then
				shown = shown + 1
				local button = acquire(shown)
				if button.buff ~= buff then
					button.buff = buff
					button:SetAttribute("spell", not buff.slot and buff.name or nil)
					button.icon:SetTexture(buff.icon)
					if GameTooltip:IsOwned(button) then showTooltip(button) end
				end
				if (on and shown > visibleCount) or not sameTime(expires, button.expires)
					or warning ~= button.warning or rate ~= button.rate then
					if on then button.time:SetCooldown(expires - warning, warning, rate or 1)
					else button.time:Clear() end
					button.expires, button.warning, button.rate = expires, warning, rate
				end
				if shown > visibleCount then button:Show() end
			end
		end
	end
	if shown ~= visibleCount then
		for index = shown + 1, visibleCount do buttons[index]:Hide() end
		row:SetWidth(math.max(shown * (SIZE + GAP) - GAP, 1))
		visibleCount = shown
	end

	-- UNIT_AURA also fires for unrelated buffs. Keep the existing timer
	-- when the tracked buff still has the same deadline.
	if not sameTime(soonest, timerAt) then
		if timer then timer:Cancel() end
		timerAt = soonest
		timer = soonest and C_Timer.NewTimer(soonest - now, onWarning)
	end
end

-- What a buff on the buff bar would be tracked as, from what Blizzard keeps
-- with its icon. Nothing while the game hides the buff: in combat its
-- identity is hidden, and with it its name.
local function buffOf(info)
	local id = info.auraInstanceID
	local aura = canaccessvalue(id) and id and C_UnitAuras.GetAuraDataByAuraInstanceID("player", id)
	if canaccessvalue(aura) and aura and canaccesstable(aura) and canaccessallvalues(aura.name, aura.icon, aura.spellId) then
		return { name = aura.name, icon = aura.icon, spellID = aura.spellId }
	end
end

-- Blizzard's button carries the slot, charges, expiry and, optionally, an
-- enchant-specific icon. Two enchants on the same weapon can expire together.
local function weaponBuffOf(info)
	local slot, now = info.ID - INVSLOT_MAINHAND, GetTime()
	local showsIcon = CVarCallbackRegistry:GetCVarValueBool("displayTemporaryEnchantIcon")
	local nearest, gap, tied
	for _, enchant in pairs(C_Item.GetWeaponEnchantInfo(slot)) do
		if enchant.hasEnchant and enchant.charges == info.count
			and (not showsIcon or enchant.enchantIconID == info.texture) then
			local off = math.abs(now + enchant.timeLeft / 1000 - info.expirationTime)
			if not gap or off < gap then
				nearest, gap, tied = enchant, off, false
			elseif off == gap and enchant.enchantID ~= nearest.enchantID then
				tied = true
			end
		end
	end
	if tied then
		return nil, "Buffs: these weapon enchants have the same expiry and can't be told apart."
	elseif nearest then
		local icon = nearest.enchantIconID ~= 0 and nearest.enchantIconID or info.texture
		return { name = SLOT_NAME[slot] .. " weapon buff", icon = icon, slot = slot, enchant = nearest.enchantID }
	end
	return nil, "Buffs: that weapon enchant has changed. Try its icon again."
end

-- An Alt-click on a buff of the buff bar tracks it, or stops tracking it. In
-- combat the list changes at once and the reminders when combat ends.
local function onBuffClick(auraButton, mouseButton)
	if not tracked or mouseButton ~= "LeftButton" or not IsAltKeyDown() or auraButton.isExample then return end
	local kind, info = auraButton.auraType, auraButton.buttonInfo
	if not info or not canaccesstable(info) then return end
	local buff, reason
	if kind == "Buff" then
		if auraButton.unit ~= "player" then return end
		buff = buffOf(info)
	elseif kind == "TempEnchant" then
		buff, reason = weaponBuffOf(info)
	else
		return
	end
	if not buff then
		print(reason or "Buffs: that buff can't be read right now. Try out of combat.")
		return
	end
	for _, other in ipairs(tracked) do
		if other.name == buff.name and other.slot == buff.slot and other.enchant == buff.enchant then
			return untrack(other)
		end
	end
	tracked[#tracked + 1] = buff
	print(("Buffs: tracking %s."):format(buff.name))
	refresh()
end

-- Consolidated buffs use a separate set of the same buttons in the flyout.
for _, frame in ipairs({ BuffFrame, BuffFrame.ConsolidatedBuffs.Tooltip.Auras }) do
	for _, auraButton in ipairs(frame.auraFrames) do
		if not auraButton.isAuraAnchor then
			auraButton:HookScript("OnClick", onBuffClick)
		end
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_LOGIN" then
		if type(BuffsDB) ~= "table" then BuffsDB = {} end
		tracked = BuffsDB
		place()
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("PLAYER_REGEN_DISABLED")
		self:RegisterUnitEvent("UNIT_AURA", "player")
		self:RegisterEvent("WEAPON_ENCHANT_CHANGED")
		self:RegisterEvent("WEAPON_SLOT_CHANGED")
		-- Buffs can be read again, and the buttons changed.
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		self:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
	elseif event == "PLAYER_REGEN_DISABLED" then
		if moving then drop() end
		return
	elseif event == "PLAYER_REGEN_ENABLED" and moving then
		drop()
	end
	refresh()
end)
