-- Path of Building
--
-- Module: Agent SSF Rules
-- Checks a build's items and gems against solo self-found crafting rules.
-- The default chase unique list is deliberately short; callers can extend or override it.
--
local t_insert = table.insert

local M = { }

-- Uniques that are unrealistic for an SSF baseline (chase drops, pinnacle-only or extremely rare)
M.defaultChaseUniques = {
	"Mageblood", "Headhunter", "Ashes of the Stars", "Ephemeral Edge", "Nimis", "Original Sin",
	"Progenesis", "The Squire", "Kalandra's Touch", "Voidforge",
}

local armourTypes = { ["Helmet"] = true, ["Body Armour"] = true, ["Gloves"] = true, ["Boots"] = true }

local function stripColors(text)
	return (tostring(text or ""):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
end

local function hasEldritchImplicit(item)
	if item.cleansing or item.tangle then
		return true
	end
	for _, modLine in ipairs(item.implicitModLines or { }) do
		if modLine.exarch or modLine.eater then
			return true
		end
	end
	return false
end

-- Count explicit affixes. Items crafted in PoB know their affixes; for pasted items count mod lines,
-- which overcounts hybrid mods (one affix, two lines).
local function countExplicits(item)
	local known = 0
	for _, list in ipairs({ item.prefixes or { }, item.suffixes or { } }) do
		for _, affix in ipairs(list) do
			if affix.modId and affix.modId ~= "None" then
				known = known + 1
			end
		end
	end
	if known > 0 then
		return known, true
	end
	local lines = 0
	for _, modLine in ipairs(item.explicitModLines or { }) do
		if item:CheckModLineVariant(modLine) then
			lines = lines + 1
		end
	end
	return lines, false
end

-- Is this unique (or its chosen version/variant) no longer obtainable? Uses PoB's own markers:
-- "Source: No longer obtainable" / Race Events uniques in the unique database, and "Pre x.y"
-- versions and variants, which describe how the item used to roll.
local function legacyReason(item)
	local title = (item.title or ""):gsub("^[Ff]oulborn ", "")
	local dbItem = main and main.uniqueDB and main.uniqueDB.byTitle and main.uniqueDB.byTitle[title:lower()]
	local source = item.source or (dbItem and dbItem.source)
	local league = item.league or (dbItem and dbItem.league)
	if source == "No longer obtainable" or league == "Race Events" then
		return "Legacy unique: no longer obtainable"
	end
	if item.versionList and item.selectedVersion then
		local version = item.versionList[item.selectedVersion]
		if type(version) == "string" and version:match("^Pre ") then
			return "Legacy version ("..version.."): can no longer be obtained"
		end
	end
	if item.variantList then
		local chosen = { }
		if item.usesVariantGroups and item.variantGroupSelections then
			for _, variantId in pairs(item.variantGroupSelections) do
				t_insert(chosen, variantId)
			end
		else
			t_insert(chosen, item.variant)
			for i, suffix in ipairs({ "", "2", "3", "4", "5" }) do
				if item["hasAltVariant"..suffix] and item["variantAlt"..suffix] then
					t_insert(chosen, item["variantAlt"..suffix])
				end
			end
		end
		for _, variantId in ipairs(chosen) do
			local name = item.variantList[variantId]
			if type(name) == "string" and name:match("^Pre ") then
				return "Legacy variant ("..name.."): can no longer be obtained"
			end
		end
	end
end

function M.Check(build, params)
	params = params or { }
	local chase = { }
	for _, name in ipairs(M.defaultChaseUniques) do
		chase[name:lower()] = true
	end
	for _, name in ipairs(params.chase_uniques or { }) do
		chase[name:lower()] = true
	end
	for _, name in ipairs(params.allowed_uniques or { }) do
		chase[name:lower()] = nil
	end

	local violations, notes = { }, { }
	local function add(list, slot, subject, message)
		t_insert(list, { slot = slot, subject = subject, message = message })
	end

	local itemsTab = build.itemsTab
	for _, slot in ipairs(itemsTab.orderedSlots) do
		local item = itemsTab.items[slot.selItemId]
		local active = item ~= nil and not slot.slotName:match("Swap")
		if active and slot.nodeId then
			active = build.spec.allocNodes[slot.nodeId] ~= nil
		end
		if active then
			local name = stripColors(item.name)
			local slotName = slot.slotName

			local influences = { }
			for _, info in ipairs(itemLib.influenceInfo.default) do
				if item[info.key] then
					t_insert(influences, info.display)
				end
			end
			if #influences > 2 then
				add(violations, slotName, name, "Has "..#influences.." influences ("..table.concat(influences, ", ").."); max 2 per item")
			end

			if hasEldritchImplicit(item) then
				if not armourTypes[item.type] then
					add(violations, slotName, name, "Eldritch implicits only exist on helmets, body armour, gloves and boots")
				end
				if #influences > 0 then
					add(violations, slotName, name, "Eldritch implicits can't coexist with base influences ("..table.concat(influences, ", ")..")")
				end
			end

			if item.rarity == "UNIQUE" or item.rarity == "RELIC" then
				local title = (item.title or name):gsub("^[Ff]oulborn ", "")
				if chase[title:lower()] then
					add(violations, slotName, name, "Chase unique; keep it out of SSF baselines (use an upgrade loadout)")
				end
				local legacy = legacyReason(item)
				if legacy then
					add(violations, slotName, name, legacy)
				end
				if item.foulborn or (item.title or ""):match("^[Ff]oulborn") then
					add(notes, slotName, name, "Foulborn (mutated) unique; acceptable when needed but call it out")
				end
				if item.rarity == "RELIC" then
					add(notes, slotName, name, "Relic (Foil) unique")
				end
			elseif item.rarity == "RARE" then
				local explicits, exact = countExplicits(item)
				local subType = item.base and item.base.subType
				local isJewel = item.base and item.base.type == "Jewel"
				if isJewel and not subType then
					if explicits >= 4 then
						add(violations, slotName, name, "4-mod jewels are effectively uncraftable in SSF")
					end
					local critMulti = 0
					for _, modLine in ipairs(item.explicitModLines or { }) do
						if modLine.line:lower():match("critical strike multiplier") then
							critMulti = critMulti + 1
						end
					end
					if critMulti >= 3 then
						add(violations, slotName, name, "Triple critical strike multiplier jewel is not realistic")
					end
				elseif not isJewel then
					if exact and explicits > 6 then
						add(violations, slotName, name, "Has "..explicits.." explicit affixes; rares have at most 6")
					elseif explicits >= 6 then
						add(notes, slotName, name, (exact and "6 explicit affixes" or explicits.." explicit mod lines (hybrid mods count twice)")..": hard to craft in SSF, aim for 4-5 useful mods")
					end
				end
			end

			if item.mirrored then
				add(notes, slotName, name, "Mirrored item")
			end
		end
	end

	for groupIndex, group in ipairs(build.skillsTab.socketGroupList) do
		if group.enabled then
			for _, gem in ipairs(group.gemList) do
				local gemData = gem.gemData
				if gem.enabled and gemData then
					local subject = gemData.name
					local where = "Skill group #"..groupIndex
					if gemData.grantedEffect and gemData.grantedEffect.legacy then
						add(violations, where, subject, "Legacy gem: can no longer be obtained")
					end
					if gemData.name == "Archmage" or gemData.name == "Archmage Support" then
						add(violations, where, subject, "Archmage Support is not allowed")
					end
					local tags = gemData.tags or { }
					if tags.awakened then
						if (gem.level or 0) > 5 then
							add(violations, where, subject, "Awakened gems max at level 5 (set to "..tostring(gem.level)..")")
						end
						add(notes, where, subject, "Awakened gem: chase tier in SSF")
					end
					if tags.exceptional then
						add(notes, where, subject, "Exceptional gem: chase tier in SSF")
					end
				end
			end
		end
	end

	return {
		ok = #violations == 0,
		violations = violations,
		notes = notes,
		chaseUniqueList = M.defaultChaseUniques,
	}
end

return M
