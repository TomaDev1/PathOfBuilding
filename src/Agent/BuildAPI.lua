-- Path of Building
--
-- Module: Agent Build API
-- A scriptable interface to the currently loaded build, intended for AI agents and other tools.
-- Every function takes a params table and returns a plain Lua table (no classes, no cycles),
-- so results can be serialised straight to JSON. Errors are raised with error().
--
-- Requires a booted headless PoB (HeadlessWrapper.lua or Agent/Headless.lua), which provides
-- the global `build` and `runCallback`.
--
local t_insert = table.insert
local t_concat = table.concat
local t_sort = table.sort
local m_huge = math.huge
local m_floor = math.floor
local m_abs = math.abs
local m_min = math.min
local m_max = math.max

local SSFRules = LoadModule("Agent/SSFRules")

local API = { }

local damageTypes = { "Physical", "Fire", "Cold", "Lightning", "Chaos" }

-----------------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------------

local function stripColors(text)
	if type(text) ~= "string" then
		return text
	end
	return (text:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
end
API.StripColors = stripColors

-- Round a number for display: large values to integers, small ones to 2 decimals.
-- Non-finite values become strings so they survive JSON encoding.
local function num(value)
	if type(value) ~= "number" then
		return value
	end
	if value ~= value then
		return "NaN"
	elseif value == m_huge then
		return "Infinite"
	elseif value == -m_huge then
		return "-Infinite"
	end
	if m_abs(value) >= 1000 then
		return m_floor(value + 0.5)
	end
	return m_floor(value * 100 + 0.5) / 100
end
API.Round = num

local function lower(s)
	return tostring(s or ""):lower()
end

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function requireBuild()
	if not build or not build.calcsTab or not build.spec then
		error("No build is loaded. Use load_build or new_build first.")
	end
end

-- Run a frame so pending changes are recalculated; surface any error PoB raised while doing so
local function frame()
	local launch = __mainObject__
	launch.promptMsg = nil
	runCallback("OnFrame")
	if launch.promptMsg then
		local msg = stripColors(launch.promptMsg):gsub("\nPress Enter/Escape.*$", "")
		launch.promptMsg = nil
		error(trim(msg), 0)
	end
end

local function recalc()
	build.buildFlag = true
	frame()
end

-- PoB in dev mode saves the open build to its file whenever it switches builds. The agent loads
-- builds constantly (snapshots, what-ifs), so make sure that can never overwrite a user's file.
local function disableAutoSave()
	if main then
		main.disableDevAutoSave = true
	end
	if build then
		build.dbFileName = nil
		build.unsaved = false
	end
end
disableAutoSave()

local function loadXML(xml, name)
	disableAutoSave()
	loadBuildFromXML(xml, name)
	disableAutoSave()
end

local function snapshot()
	return {
		xml = build:SaveDB("snapshot"),
		name = build.buildName,
	}
end

local function restore(snap)
	loadXML(snap.xml, snap.name)
	frame()
end

-- Run fn with the build restored afterwards, even if fn fails
local function withRestore(fn)
	local snap = snapshot()
	local ok, res = pcall(fn)
	restore(snap)
	if not ok then
		error(res, 0)
	end
	return res
end
API.WithRestore = withRestore

-----------------------------------------------------------------------------
-- Stats
-----------------------------------------------------------------------------

-- Headline numbers for an output table (player output from calcs or a misc calculator)
local function headline(output, minionOutput)
	output = output or { }
	local res = { }
	local fullDPS = output.FullDPS or 0
	local combined = output.CombinedDPS or 0
	if fullDPS > 0 then
		res.dps = num(fullDPS)
		res.dpsSource = "FullDPS"
	else
		res.dps = num(combined)
		res.dpsSource = "CombinedDPS"
	end
	res.combinedDPS = num(combined)
	res.hitDPS = num(output.TotalDPS or 0)
	res.dotDPS = num(output.TotalDotDPS or output.TotalDot or 0)
	res.igniteDPS = output.IgniteDPS and num(output.IgniteDPS) or nil
	res.bleedDPS = output.BleedDPS and num(output.BleedDPS) or nil
	res.poisonDPS = output.PoisonDPS and num(output.PoisonDPS) or nil
	res.averageHit = output.AverageHit and num(output.AverageHit) or nil
	res.speed = output.Speed and num(output.Speed) or nil
	res.critChance = output.CritChance and num(output.CritChance) or nil
	res.critMultiplier = output.CritMultiplier and num(output.CritMultiplier * 100) or nil
	res.hitChance = output.HitChance and num(output.HitChance) or nil
	if data and data.misc and data.misc.DotDpsCap and (output.TotalDotDPS or output.TotalDot or 0) >= data.misc.DotDpsCap then
		res.dotCapped = true
	end
	if minionOutput then
		res.minion = {
			combinedDPS = num(minionOutput.CombinedDPS or 0),
			hitDPS = num(minionOutput.TotalDPS or 0),
			life = num(minionOutput.Life or 0),
		}
	end

	res.ehp = num(output.TotalEHP or 0)
	res.maxHit = { }
	local minHit, minType = m_huge, nil
	for _, damageType in ipairs(damageTypes) do
		local value = output[damageType.."MaximumHitTaken"] or 0
		res.maxHit[damageType:lower()] = num(value)
		if value < minHit then
			minHit, minType = value, damageType:lower()
		end
	end
	res.minMaxHit = num(minHit)
	res.minMaxHitType = minType

	res.life = num(output.Life or 0)
	res.lifeUnreserved = num(output.LifeUnreserved or 0)
	res.energyShield = num(output.EnergyShield or 0)
	res.mana = num(output.Mana or 0)
	res.manaUnreserved = num(output.ManaUnreserved or 0)
	res.ward = (output.Ward or 0) > 0 and num(output.Ward) or nil
	res.armour = num(output.Armour or 0)
	res.evasion = num(output.Evasion or 0)
	res.physicalDamageReduction = num(output.PhysicalDamageReduction or 0)
	res.resist = { }
	res.resistOverCap = { }
	for _, damageType in ipairs({ "Fire", "Cold", "Lightning", "Chaos" }) do
		res.resist[damageType:lower()] = num(output[damageType.."Resist"] or 0)
		res.resistOverCap[damageType:lower()] = num(output[damageType.."ResistOverCap"] or 0)
	end
	res.block = num(output.EffectiveBlockChance or output.BlockChance or 0)
	res.spellBlock = num(output.EffectiveSpellBlockChance or output.SpellBlockChance or 0)
	res.spellSuppression = num(output.EffectiveSpellSuppressionChance or output.SpellSuppressionChance or 0)
	res.lifeRegen = num(output.LifeRegenRecovery or 0)
	res.esRegen = num(output.EnergyShieldRegenRecovery or 0)
	res.netLifeRegen = output.NetLifeRegen and num(output.NetLifeRegen) or nil
	res.manaRegen = num(output.ManaRegenRecovery or 0)
	res.manaCost = output.ManaCost and num(output.ManaCost) or nil
	res.manaPerSecondCost = output.ManaPerSecondCost and num(output.ManaPerSecondCost) or nil
	res.movementSpeed = output.EffectiveMovementSpeedMod and num(output.EffectiveMovementSpeedMod * 100 - 100) or nil
	res.attributes = {
		str = num(output.Str or 0), dex = num(output.Dex or 0), int = num(output.Int or 0),
		reqStr = num(output.ReqStr or 0), reqDex = num(output.ReqDex or 0), reqInt = num(output.ReqInt or 0),
	}
	res.charges = {
		power = num(output.PowerCharges or 0), powerMax = num(output.PowerChargesMax or 0),
		frenzy = num(output.FrenzyCharges or 0), frenzyMax = num(output.FrenzyChargesMax or 0),
		endurance = num(output.EnduranceCharges or 0), enduranceMax = num(output.EnduranceChargesMax or 0),
	}
	return res
end
API.Headline = headline

-- The few numbers worth repeating next to ranked results
local function compactHeadline(head)
	return {
		dps = head.dps, dpsSource = head.dpsSource, ehp = head.ehp,
		minMaxHit = head.minMaxHit, minMaxHitType = head.minMaxHitType,
		life = head.life, energyShield = head.energyShield,
	}
end

local function currentHeadline()
	local env = build.calcsTab.mainEnv
	return headline(build.calcsTab.mainOutput, env and env.minion and env.minion.output)
end

-- Resolve a metric name to a number from a headline table or raw output
local metricAliases = {
	dps = "dps", ehp = "ehp", min_max_hit = "minMaxHit", minmaxhit = "minMaxHit", life = "life",
	es = "energyShield", energy_shield = "energyShield", mana = "mana", armour = "armour", evasion = "evasion",
}
local function metricValue(head, output, metric)
	local key = metricAliases[lower(metric)]
	local v
	if key then
		v = head[key]
	else
		v = output and output[metric]
	end
	if type(v) ~= "number" then
		return v == "Infinite" and m_huge or 0
	end
	return v
end

-- Compute deltas between two headline tables
local function diffHeadline(base, new)
	local res = { }
	local function walk(a, b, out)
		for k, bv in pairs(b) do
			local av = a and a[k]
			if type(bv) == "number" and type(av) == "number" then
				if bv ~= av then
					local entry = { before = av, after = bv, change = num(bv - av) }
					if av ~= 0 then
						entry.percent = num((bv - av) / m_abs(av) * 100)
					end
					out[k] = entry
				end
			elseif type(bv) == "table" and type(av) == "table" then
				local sub = { }
				walk(av, bv, sub)
				if next(sub) then
					out[k] = sub
				end
			elseif bv ~= av and type(bv) ~= "table" then
				out[k] = { before = av, after = bv }
			end
		end
	end
	walk(base, new, res)
	return res
end
API.DiffHeadline = diffHeadline

-- The sidebar as PoB displays it, as plain text lines
local function sidebarLines()
	local lines = { }
	for _, row in ipairs(build.controls.statBox.list) do
		if row[1] then
			local text = stripColors(row[1])
			if row[2] then
				text = text .. " " .. stripColors(row[2])
			end
			text = trim(text)
			if text ~= "" then
				t_insert(lines, text)
			end
		end
	end
	return lines
end

local function warnings()
	local res = { }
	for _, line in ipairs(build.controls.warnings and build.controls.warnings.lines or { }) do
		t_insert(res, stripColors(line))
	end
	return res
end

-----------------------------------------------------------------------------
-- Lookups
-----------------------------------------------------------------------------

local function nodeTypeName(node)
	if node.ascendancyName then
		return "Ascendancy" .. (node.isNotable and "Notable" or "")
	end
	return node.type
end

local function findNode(ref)
	local spec = build.spec
	local id = tonumber(ref)
	if id then
		local node = spec.nodes[id]
		if not node then
			error("No passive node with id "..ref)
		end
		return node
	end
	local wanted = lower(trim(ref))
	local matches = { }
	for _, node in pairs(spec.nodes) do
		if node.dn and lower(node.dn) == wanted then
			t_insert(matches, node)
		end
	end
	if #matches == 0 then
		error("No passive node named '"..tostring(ref).."'. Use search_passives to find it.")
	end
	if #matches > 1 then
		-- Prefer the closest unallocated copy, or any allocated one
		t_sort(matches, function(a, b)
			if a.alloc ~= b.alloc then
				return a.alloc
			end
			return (a.pathDist or 1000) < (b.pathDist or 1000)
		end)
		if matches[1].type == "Normal" then
			local ids = { }
			for i = 1, m_min(#matches, 8) do
				ids[i] = matches[i].id
			end
			error("'"..tostring(ref).."' matches "..#matches.." nodes; pass a node id instead (e.g. "..t_concat(ids, ", ")..")")
		end
	end
	return matches[1]
end
API.FindNode = findNode

local function describeNode(node, withPath)
	local res = {
		id = node.id,
		name = node.dn,
		type = nodeTypeName(node),
		allocated = node.alloc and true or false,
		stats = { },
	}
	for _, line in ipairs(node.sd or { }) do
		t_insert(res.stats, stripColors(line))
	end
	if node.ascendancyName then
		res.ascendancy = node.ascendancyName
	end
	if withPath and not node.alloc then
		res.pointsToAllocate = node.path and #node.path or nil
	end
	return res
end

local function findSlot(name)
	local itemsTab = build.itemsTab
	if itemsTab.slots[name] then
		return itemsTab.slots[name]
	end
	local wanted = lower(name)
	for slotName, slot in pairs(itemsTab.slots) do
		if lower(slotName) == wanted then
			return slot
		end
	end
	-- Allow "Jewel 26725" or a node name for jewel sockets
	local ok, node = pcall(findNode, (tostring(name):gsub("^[Jj]ewel%s*", "")))
	if ok and node and itemsTab.sockets[node.id] then
		return itemsTab.sockets[node.id]
	end
	error("Unknown item slot '"..tostring(name).."'")
end

local function socketGroupLabel(group)
	return stripColors(group.displayLabel or group.label or "?")
end

local function findSocketGroup(ref)
	local list = build.skillsTab.socketGroupList
	local index = tonumber(ref)
	if index then
		if not list[index] then
			error("No socket group #"..index.." (there are "..#list..")")
		end
		return list[index], index
	end
	local wanted = lower(ref)
	for i, group in ipairs(list) do
		if lower(socketGroupLabel(group)) == wanted or lower(group.label) == wanted then
			return group, i
		end
	end
	for i, group in ipairs(list) do
		if lower(socketGroupLabel(group)):find(wanted, 1, true) then
			return group, i
		end
	end
	error("No socket group matching '"..tostring(ref).."'")
end

-----------------------------------------------------------------------------
-- Descriptions of build parts
-----------------------------------------------------------------------------

local function describeItem(item, slotName)
	local res = {
		slot = slotName,
		id = item.id,
		name = stripColors(item.name),
		rarity = item.rarity,
		base = item.baseName,
		type = item.type,
	}
	local influences = { }
	for _, info in ipairs(itemLib.influenceInfo.all) do
		if item[info.key] then
			t_insert(influences, info.display)
		end
	end
	if #influences > 0 then
		res.influences = influences
	end
	if item.corrupted then res.corrupted = true end
	if item.foulborn then res.foulborn = true end
	local unsupported = { }
	for _, list in ipairs({ item.enchantModLines, item.scourgeModLines, item.implicitModLines, item.explicitModLines, item.crucibleModLines }) do
		for _, modLine in ipairs(list or { }) do
			if modLine.extra and item:CheckModLineVariant(modLine) then
				t_insert(unsupported, stripColors(modLine.line))
			end
		end
	end
	if #unsupported > 0 then
		res.unsupportedMods = unsupported
	end
	return res
end

local function equippedItems(includeText)
	local itemsTab = build.itemsTab
	local res = { }
	for _, slot in ipairs(itemsTab.orderedSlots) do
		local item = itemsTab.items[slot.selItemId]
		local active = true
		if slot.nodeId then
			active = build.spec.allocNodes[slot.nodeId] ~= nil
		elseif slot.slotName:match("Swap") then
			active = false
		end
		if item and active then
			local entry = describeItem(item, slot.slotName)
			if includeText then
				entry.text = item:BuildRaw()
			end
			t_insert(res, entry)
		end
	end
	return res
end

local function describeSocketGroup(group, index)
	local res = {
		index = index,
		label = socketGroupLabel(group),
		slot = group.slot,
		enabled = group.enabled and true or false,
		includeInFullDPS = group.includeInFullDPS and true or false,
		isMain = build.mainSocketGroup == index,
		gems = { },
	}
	if group.source then
		res.source = group.source
	end
	for _, gem in ipairs(group.gemList) do
		local gemData = gem.gemData
		t_insert(res.gems, {
			name = gemData and gemData.name or gem.nameSpec,
			level = gem.level,
			quality = gem.quality,
			enabled = gem.enabled and true or false,
			support = gemData and gemData.grantedEffect and gemData.grantedEffect.support or nil,
			error = gem.errMsg and stripColors(gem.errMsg) or nil,
		})
	end
	if group.displaySkillList and #group.displaySkillList > 0 then
		res.activeSkills = { }
		for i, activeSkill in ipairs(group.displaySkillList) do
			local entry = { index = i, name = activeSkill.activeEffect.grantedEffect.name }
			local parts = activeSkill.activeEffect.grantedEffect.parts
			if parts and #parts > 1 then
				entry.parts = { }
				for j, part in ipairs(parts) do
					entry.parts[j] = part.name
				end
				entry.selectedPart = activeSkill.activeEffect.srcInstance.skillPart or 1
			end
			t_insert(res.activeSkills, entry)
		end
		res.mainActiveSkill = group.mainActiveSkill or 1
	end
	return res
end

-- Loadouts are tree specs paired with item/skill/config sets of the same title. PoB's own dropdown
-- hides loadouts whose tree is on an older tree version, so pair them up by title directly.
local function loadoutNames()
	local names = { }
	for _, spec in ipairs(build.treeTab.specList) do
		t_insert(names, spec.title or "Default")
	end
	return names
end

local function findSetByTitle(sets, orderList, title)
	if #orderList == 1 then
		return orderList[1]
	end
	for _, id in ipairs(orderList) do
		if lower(sets[id].title or "Default") == lower(title) then
			return id
		end
	end
end

local function setTitle(sets, id)
	return sets[id] and sets[id].title or "Default"
end

local function activeSets()
	return {
		tree = build.spec.title or "Default",
		items = setTitle(build.itemsTab.itemSets, build.itemsTab.activeItemSetId),
		skills = setTitle(build.skillsTab.skillSets, build.skillsTab.activeSkillSetId),
		config = setTitle(build.configTab.configSets, build.configTab.activeConfigSetId),
	}
end

local function summary()
	local spec = build.spec
	local used, ascUsed = spec:CountAllocNodes()
	local res = {
		name = build.buildName,
		file = API.sourcePath,
		level = build.characterLevel,
		class = spec.curClassName,
		ascendancy = spec.curAscendClassName ~= "None" and spec.curAscendClassName or nil,
		treeVersion = spec.treeVersion,
		passivePoints = used,
		ascendancyPoints = ascUsed,
		bandit = build.configTab.input.bandit,
		activeSets = activeSets(),
		loadouts = loadoutNames(),
	}
	if spec.curSecondaryAscendClassId and spec.tree.alternate_ascendancies and spec.tree.alternate_ascendancies[spec.curSecondaryAscendClassId] then
		res.secondaryAscendancy = spec.tree.alternate_ascendancies[spec.curSecondaryAscendClassId].name
	end
	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if mainGroup then
		res.mainSkill = {
			group = build.mainSocketGroup,
			label = socketGroupLabel(mainGroup),
		}
		local active = mainGroup.displaySkillList and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
		if active then
			res.mainSkill.skill = active.activeEffect.grantedEffect.name
		end
	end
	res.keystones = { }
	res.notables = { }
	res.ascendancyNodes = { }
	res.masteries = { }
	for _, node in pairs(spec.allocNodes) do
		if node.ascendancyName and node.type ~= "AscendClassStart" then
			if node.isNotable then
				t_insert(res.ascendancyNodes, node.dn)
			end
		elseif node.type == "Keystone" then
			t_insert(res.keystones, node.dn)
		elseif node.type == "Notable" then
			t_insert(res.notables, node.dn)
		elseif node.type == "Mastery" then
			local sd = { }
			for _, line in ipairs(node.sd or { }) do
				t_insert(sd, stripColors(line))
			end
			t_insert(res.masteries, node.dn .. ": " .. t_concat(sd, " / "))
		end
	end
	t_sort(res.keystones)
	t_sort(res.notables)
	t_sort(res.ascendancyNodes)
	t_sort(res.masteries)
	res.skills = { }
	for i, group in ipairs(build.skillsTab.socketGroupList) do
		t_insert(res.skills, describeSocketGroup(group, i))
	end
	res.items = equippedItems(false)
	return res
end

-----------------------------------------------------------------------------
-- Mutations (shared by the individual tools and by what_if)
-----------------------------------------------------------------------------

local Changes = { }
API.Changes = Changes

function Changes.allocate(p)
	local spec = build.spec
	local done = { }
	for _, ref in ipairs(p.nodes or { p.node }) do
		local node = findNode(ref)
		if not node.alloc then
			if node.type == "Mastery" then
				error("'"..node.dn.."' is a mastery; use the masteries parameter of edit_tree to pick an effect")
			end
			if not node.path then
				error("'"..node.dn.."' ("..node.id..") cannot be reached from the current tree")
			end
			spec:AllocNode(node)
		end
		t_insert(done, node.dn)
	end
	return done
end

function Changes.deallocate(p)
	local spec = build.spec
	local done = { }
	for _, ref in ipairs(p.nodes or { p.node }) do
		local node = findNode(ref)
		if node.alloc then
			if node.type == "ClassStart" or node.type == "AscendClassStart" then
				error("Cannot deallocate a class start node")
			end
			spec:DeallocNode(node)
			t_insert(done, node.dn)
		end
	end
	return done
end

function Changes.mastery(p)
	local spec = build.spec
	local node = findNode(p.node)
	if node.type ~= "Mastery" then
		error("'"..node.dn.."' is not a mastery")
	end
	local wanted = lower(p.effect)
	local chosen
	for _, masteryEffect in ipairs(node.masteryEffects or { }) do
		local effect = spec.tree.masteryEffects[masteryEffect.effect]
		local text = lower(t_concat(masteryEffect.stats or effect.sd or { }, " / "))
		if tostring(masteryEffect.effect) == tostring(p.effect) or text:find(wanted, 1, true) then
			chosen = effect
			break
		end
	end
	if not chosen then
		local options = { }
		for _, masteryEffect in ipairs(node.masteryEffects or { }) do
			t_insert(options, masteryEffect.effect .. ": " .. t_concat(masteryEffect.stats or { }, " / "))
		end
		error("No effect matching '"..tostring(p.effect).."' on "..node.dn..". Options: "..t_concat(options, "; "))
	end
	local assigned = isValueInTable(spec.masterySelections, chosen.id)
	if assigned and assigned ~= node.id then
		error("That mastery effect is already selected on node "..assigned)
	end
	node.sd = chosen.sd
	node.allMasteryOptions = false
	spec.tree:ProcessStats(node)
	spec.masterySelections[node.id] = chosen.id
	if not node.alloc then
		if not node.path then
			error("'"..node.dn.."' cannot be reached from the current tree")
		end
		spec:AllocNode(node)
	end
	return node.dn .. ": " .. t_concat(chosen.sd, " / ")
end

local function findClass(name)
	local wanted = lower(name)
	for classId, class in pairs(build.spec.tree.classes) do
		if lower(class.name) == wanted then
			return classId, class
		end
		for ascendId, ascend in pairs(class.classes) do
			if lower(ascend.name) == wanted then
				return classId, class, ascendId
			end
		end
	end
	error("Unknown class or ascendancy '"..tostring(name).."'")
end

function Changes.class(p)
	local spec = build.spec
	local classId, _, ascendId = findClass(p.class)
	if classId ~= spec.curClassId then
		spec:ResetNodes()
		spec:SelectClass(classId)
	end
	if ascendId then
		Changes.ascendancy({ ascendancy = p.class })
	end
	return spec.curClassName
end

function Changes.ascendancy(p)
	local spec = build.spec
	local classId, _, ascendId = findClass(p.ascendancy)
	if not ascendId then
		error("'"..tostring(p.ascendancy).."' is not an ascendancy")
	end
	if classId ~= spec.curClassId then
		spec:ResetNodes()
		spec:SelectClass(classId)
	end
	-- Drop nodes from the old ascendancy
	for id, node in pairs(spec.allocNodes) do
		if node.ascendancyName and node.ascendancyName ~= spec.tree.classes[classId].classes[ascendId].name
			and node.type ~= "AscendClassStart" and not (spec.tree.secondaryAscendNameMap and spec.tree.secondaryAscendNameMap[node.ascendancyName]) then
			node.alloc = false
			spec.allocNodes[id] = nil
		end
	end
	spec:SelectAscendClass(ascendId)
	return spec.curAscendClassName
end

function Changes.secondary_ascendancy(p)
	local spec = build.spec
	local alt = spec.tree.alternate_ascendancies
	if not alt then
		error("This tree version has no secondary ascendancies")
	end
	if p.secondary_ascendancy == "None" or p.secondary_ascendancy == "" then
		spec:SelectSecondaryAscendClass(0)
		return "None"
	end
	for id, ascend in pairs(alt) do
		if lower(ascend.name) == lower(p.secondary_ascendancy) then
			spec:SelectSecondaryAscendClass(id)
			return ascend.name
		end
	end
	error("Unknown secondary ascendancy '"..tostring(p.secondary_ascendancy).."'")
end

function Changes.tree_url(p)
	local errMsg = build.spec:DecodeURL(p.url)
	if errMsg then
		error("Could not import tree: "..tostring(errMsg))
	end
	return "imported"
end

function Changes.level(p)
	local level = m_min(m_max(m_floor(tonumber(p.level) or 1), 1), 100)
	build.characterLevel = level
	build.characterLevelAutoMode = false
	build.controls.characterLevel:SetText(level)
	build.configTab:BuildModList()
	return level
end

function Changes.equip(p)
	local itemsTab = build.itemsTab
	local raw = p.item or p.item_text
	if not raw or not raw:match("%S") then
		error("item text is required")
	end
	local item = new("Item"):Item(raw:gsub("\r\n", "\n"))
	if not item.base then
		error("Could not parse item (unknown base type). Paste the item text as copied from the game or from PoB.")
	end
	item:NormaliseQuality()
	item:BuildModList()
	local slotName = p.slot
	if slotName then
		local slot = findSlot(slotName)
		slotName = slot.slotName
		if not itemsTab:IsItemValidForSlot(item, slotName) then
			error("A "..tostring(item.type).." can't go in "..slotName)
		end
	else
		slotName = item:GetPrimarySlot()
		if not itemsTab.slots[slotName] then
			error("Specify a slot for this item")
		end
	end
	itemsTab:AddItem(item, true)
	itemsTab.slots[slotName]:SetSelItemId(item.id)
	itemsTab:PopulateSlots()
	build.buildFlag = true
	local desc = describeItem(item, slotName)
	return desc
end

function Changes.unequip(p)
	local slot = findSlot(p.slot)
	slot:SetSelItemId(0)
	build.itemsTab:PopulateSlots()
	build.buildFlag = true
	return slot.slotName
end

local function buildGemList(gems)
	local list = { }
	for _, g in ipairs(gems) do
		if type(g) == "string" then
			g = { name = g }
		end
		t_insert(list, {
			nameSpec = g.name,
			level = tonumber(g.level) or 20,
			quality = tonumber(g.quality) or 0,
			enabled = g.enabled ~= false,
			enableGlobal1 = true,
			enableGlobal2 = true,
			count = tonumber(g.count) or 1,
		})
	end
	return list
end

function Changes.set_skill_group(p)
	local skillsTab = build.skillsTab
	local group, index
	if p.group then
		group, index = findSocketGroup(p.group)
	else
		group = { label = "", enabled = true, gemList = { }, mainActiveSkill = 1 }
		t_insert(skillsTab.socketGroupList, group)
		index = #skillsTab.socketGroupList
	end
	if p.label ~= nil then group.label = p.label end
	if p.slot ~= nil then group.slot = p.slot ~= "" and findSlot(p.slot).slotName or nil end
	if p.enabled ~= nil then group.enabled = p.enabled and true or false end
	if p.include_in_full_dps ~= nil then group.includeInFullDPS = p.include_in_full_dps and true or false end
	if p.gems then
		group.gemList = buildGemList(p.gems)
	end
	skillsTab:ProcessSocketGroup(group)
	local errors = { }
	for _, gem in ipairs(group.gemList) do
		if gem.errMsg then
			t_insert(errors, stripColors(gem.errMsg))
		end
	end
	if #errors > 0 then
		error(t_concat(errors, "; "))
	end
	if p.main then
		build.mainSocketGroup = index
	end
	build.buildFlag = true
	return index
end

function Changes.remove_skill_group(p)
	local _, index = findSocketGroup(p.group)
	table.remove(build.skillsTab.socketGroupList, index)
	if build.mainSocketGroup == index then
		build.mainSocketGroup = 1
	elseif build.mainSocketGroup > index then
		build.mainSocketGroup = build.mainSocketGroup - 1
	end
	build.buildFlag = true
	return index
end

local function findGem(group, ref)
	local index = tonumber(ref)
	if index then
		if not group.gemList[index] then
			error("Socket group has no gem #"..index)
		end
		return group.gemList[index], index
	end
	local wanted = lower(ref)
	for i, gem in ipairs(group.gemList) do
		local name = gem.gemData and gem.gemData.name or gem.nameSpec
		if lower(name) == wanted or lower(name) == wanted.." support" then
			return gem, i
		end
	end
	for i, gem in ipairs(group.gemList) do
		local name = gem.gemData and gem.gemData.name or gem.nameSpec
		if lower(name):find(wanted, 1, true) then
			return gem, i
		end
	end
	error("No gem matching '"..tostring(ref).."' in that socket group")
end

function Changes.set_gem(p)
	local group = findSocketGroup(p.group)
	local gem = findGem(group, p.gem)
	if p.name then
		gem.nameSpec = p.name
		gem.gemId, gem.skillId, gem.gemData = nil
	end
	if p.level then gem.level = tonumber(p.level) end
	if p.quality then gem.quality = tonumber(p.quality) end
	if p.enabled ~= nil then gem.enabled = p.enabled and true or false end
	build.skillsTab:ProcessSocketGroup(group)
	if gem.errMsg then
		error(stripColors(gem.errMsg))
	end
	build.buildFlag = true
	return gem.gemData and gem.gemData.name or gem.nameSpec
end

function Changes.main_skill(p)
	local group, index = findSocketGroup(p.group)
	build.mainSocketGroup = index
	if p.skill then
		group.mainActiveSkill = tonumber(p.skill) or 1
	end
	build.buildFlag = true
	frame()
	local active = group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	if active then
		local src = active.activeEffect.srcInstance
		if p.part then
			local parts = active.activeEffect.grantedEffect.parts or { }
			local partIndex = tonumber(p.part)
			if not partIndex then
				for i, part in ipairs(parts) do
					if lower(part.name):find(lower(p.part), 1, true) then
						partIndex = i
						break
					end
				end
			end
			if not partIndex or not parts[partIndex] then
				error("Unknown skill part '"..tostring(p.part).."'")
			end
			src.skillPart = partIndex
		end
		if p.stages then
			src.skillStageCount = tonumber(p.stages)
		end
		if p.minion then
			src.skillMinion = p.minion
		end
	end
	build.buildFlag = true
	return index
end

local configVarList
local function getConfigVarList()
	if not configVarList then
		configVarList = LoadModule("Modules/ConfigOptions")
	end
	return configVarList
end

local function findConfigVar(name)
	local wanted = lower(name)
	for _, varData in ipairs(getConfigVarList()) do
		if varData.var and lower(varData.var) == wanted then
			return varData
		end
	end
	for _, varData in ipairs(getConfigVarList()) do
		if varData.var and varData.label and lower(stripColors(varData.label)):gsub(":$", "") == wanted then
			return varData
		end
	end
	error("Unknown config option '"..tostring(name).."'. Use get_config with all=true to list options.")
end

local function coerceConfigValue(varData, value)
	if varData.type == "check" then
		return value == true or value == "true" or value == 1
	elseif varData.type == "count" or varData.type == "integer" or varData.type == "countAllowZero" or varData.type == "float" then
		if value == nil or value == "" then
			return nil
		end
		local n = tonumber(value)
		if not n then
			error("Config option '"..varData.var.."' needs a number")
		end
		return n
	elseif varData.type == "list" then
		for _, entry in ipairs(varData.list) do
			if entry.val == value or lower(entry.val) == lower(value) or lower(stripColors(entry.label)) == lower(value) then
				return entry.val
			end
		end
		local options = { }
		for _, entry in ipairs(varData.list) do
			t_insert(options, tostring(entry.val))
		end
		error("Invalid value '"..tostring(value).."' for '"..varData.var.."'. Options: "..t_concat(options, ", "))
	end
	return value
end

function Changes.config(p)
	local configTab = build.configTab
	local set = { }
	for name, value in pairs(p.values or { }) do
		local varData = findConfigVar(name)
		configTab.input[varData.var] = coerceConfigValue(varData, value)
		set[varData.var] = configTab.input[varData.var] == nil and "default" or configTab.input[varData.var]
	end
	configTab:UpdateControls()
	configTab:BuildModList()
	build.buildFlag = true
	return set
end

-- Custom modifiers go in their own named block in the active config set
function Changes.custom_mods(p)
	local configTab = build.configTab
	local configSet = configTab.configSets[configTab.activeConfigSetId]
	configSet.customModsList = configSet.customModsList or { }
	local title = p.title or "Agent"
	local block
	for _, b in ipairs(configSet.customModsList) do
		if b.title == title then
			block = b
		end
	end
	local text = p.mods
	if type(text) == "table" then
		text = t_concat(text, "\n")
	end
	if not block then
		block = { title = title, enabled = true, text = "" }
		t_insert(configSet.customModsList, block)
	end
	if p.append and block.text ~= "" then
		block.text = block.text .. "\n" .. (text or "")
	else
		block.text = text or ""
	end
	block.enabled = true
	configTab:UpdateControls()
	configTab:BuildModList()
	build.buildFlag = true
	-- Report lines PoB can't parse
	local unsupported = { }
	for line in (block.text .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("%S") then
			local modList, extra = modLib.parseMod(line)
			if not modList or extra then
				t_insert(unsupported, line)
			end
		end
	end
	return { block = title, unsupported = unsupported }
end

function Changes.loadout(p)
	local wanted = lower(p.name or p.loadout):gsub("^%[[%d%.]+%] ", "")
	local treeTab, itemsTab, skillsTab, configTab = build.treeTab, build.itemsTab, build.skillsTab, build.configTab
	local specIndex
	for i, spec in ipairs(treeTab.specList) do
		if lower(spec.title or "Default") == wanted then
			specIndex = i
			break
		end
	end
	if not specIndex then
		error("No loadout named '"..tostring(p.name or p.loadout).."'. Loadouts: "..t_concat(loadoutNames(), ", "))
	end
	local title = treeTab.specList[specIndex].title or "Default"
	if specIndex ~= treeTab.activeSpec then
		treeTab:SetActiveSpec(specIndex)
	end
	local itemSetId = findSetByTitle(itemsTab.itemSets, itemsTab.itemSetOrderList, title)
	if itemSetId and itemSetId ~= itemsTab.activeItemSetId then
		itemsTab:SetActiveItemSet(itemSetId)
	end
	local skillSetId = findSetByTitle(skillsTab.skillSets, skillsTab.skillSetOrderList, title)
	if skillSetId and skillSetId ~= skillsTab.activeSkillSetId then
		skillsTab:SetActiveSkillSet(skillSetId)
	end
	local configSetId = findSetByTitle(configTab.configSets, configTab.configSetOrderList, title)
	if configSetId and configSetId ~= configTab.activeConfigSetId then
		configTab:SetActiveConfigSet(configSetId)
	end
	build.buildFlag = true
	return title
end

-- Copy the active tree, item, skill and config sets into a new loadout with the given name
function Changes.create_loadout(p)
	local title = p.name
	if not title or not title:match("%S") then
		error("A loadout name is required")
	end
	for _, existing in ipairs(loadoutNames()) do
		if lower(existing) == lower(title) then
			error("A loadout named '"..title.."' already exists")
		end
	end
	local treeTab, itemsTab, skillsTab, configTab = build.treeTab, build.itemsTab, build.skillsTab, build.configTab

	local curSpec = build.spec
	local newSpec = new("PassiveSpec"):PassiveSpec(build, curSpec.treeVersion)
	newSpec.jewels = copyTable(curSpec.jewels)
	newSpec:RestoreUndoState(curSpec:CreateUndoState())
	newSpec:BuildClusterJewelGraphs()
	newSpec.title = title
	t_insert(treeTab.specList, newSpec)

	-- Item sets keep the live slot state in the slots, so save it to the active set first
	for slotName, slot in pairs(itemsTab.slots) do
		if not slot.nodeId and itemsTab.activeItemSet[slotName] then
			itemsTab.activeItemSet[slotName].selItemId = slot.selItemId
			itemsTab.activeItemSet[slotName].active = slot.active
		end
	end
	local newItemSet = copyTable(itemsTab.activeItemSet)
	newItemSet.id = 1
	while itemsTab.itemSets[newItemSet.id] do
		newItemSet.id = newItemSet.id + 1
	end
	newItemSet.title = title
	itemsTab.itemSets[newItemSet.id] = newItemSet
	t_insert(itemsTab.itemSetOrderList, newItemSet.id)

	local skillSet = skillsTab.skillSets[skillsTab.activeSkillSetId]
	local newSkillSet = copyTable(skillSet, true)
	newSkillSet.socketGroupList = { }
	for _, socketGroup in ipairs(skillSet.socketGroupList) do
		local newGroup = copyTable(socketGroup, true)
		newGroup.gemList = { }
		for gemIndex, gem in ipairs(socketGroup.gemList) do
			newGroup.gemList[gemIndex] = copyTable(gem, true)
		end
		t_insert(newSkillSet.socketGroupList, newGroup)
	end
	newSkillSet.id = 1
	while skillsTab.skillSets[newSkillSet.id] do
		newSkillSet.id = newSkillSet.id + 1
	end
	newSkillSet.title = title
	skillsTab.skillSets[newSkillSet.id] = newSkillSet
	t_insert(skillsTab.skillSetOrderList, newSkillSet.id)

	local newConfigSet = copyTable(configTab.configSets[configTab.activeConfigSetId])
	newConfigSet.id = 1
	while configTab.configSets[newConfigSet.id] do
		newConfigSet.id = newConfigSet.id + 1
	end
	newConfigSet.title = title
	configTab.configSets[newConfigSet.id] = newConfigSet
	t_insert(configTab.configSetOrderList, newConfigSet.id)

	-- Sets that were unnamed must be named for loadouts to pair up by name
	local function nameDefault(sets, orderList, fallback)
		for _, id in ipairs(orderList) do
			if not sets[id].title then
				sets[id].title = fallback
			end
		end
	end
	local curTitle = curSpec.title or "Default"
	if not curSpec.title then
		curSpec.title = curTitle
	end
	nameDefault(itemsTab.itemSets, itemsTab.itemSetOrderList, curTitle)
	nameDefault(skillsTab.skillSets, skillsTab.skillSetOrderList, curTitle)
	nameDefault(configTab.configSets, configTab.configSetOrderList, curTitle)

	build:SyncLoadouts()
	build.modFlag = true
	if p.activate ~= false then
		Changes.loadout({ name = title })
	end
	return title
end

-- Apply one change described as { type = "...", ... }
local changeAliases = {
	allocate = "allocate", alloc = "allocate", deallocate = "deallocate", dealloc = "deallocate",
	mastery = "mastery", class = "class", ascendancy = "ascendancy", secondary_ascendancy = "secondary_ascendancy",
	tree_url = "tree_url", level = "level", equip = "equip", equip_item = "equip", unequip = "unequip",
	set_skill_group = "set_skill_group", add_skill_group = "set_skill_group", remove_skill_group = "remove_skill_group",
	set_gem = "set_gem", main_skill = "main_skill", set_main_skill = "main_skill", config = "config", set_config = "config",
	custom_mods = "custom_mods", add_mods = "custom_mods", loadout = "loadout", select_loadout = "loadout",
}
function API.ApplyChange(change)
	local kind = changeAliases[lower(change.type)]
	if not kind then
		local kinds = { }
		for k in pairs(Changes) do
			t_insert(kinds, k)
		end
		t_sort(kinds)
		error("Unknown change type '"..tostring(change.type).."'. Types: "..t_concat(kinds, ", "))
	end
	if kind == "custom_mods" and change.append == nil then
		change.append = true
	end
	return Changes[kind](change)
end

-----------------------------------------------------------------------------
-- Tools
-----------------------------------------------------------------------------

local tools = { }
local toolOrder = { }
local function tool(def)
	tools[def.name] = def
	t_insert(toolOrder, def.name)
end

-- JSON schema helpers
local function obj(props, required)
	return { type = "object", properties = props or { }, required = required }
end
local S = {
	str = function(desc) return { type = "string", description = desc } end,
	int = function(desc) return { type = "integer", description = desc } end,
	num = function(desc) return { type = "number", description = desc } end,
	bool = function(desc) return { type = "boolean", description = desc } end,
	ref = function(desc) return { type = { "string", "integer" }, description = desc } end,
	arr = function(items, desc) return { type = "array", items = items, description = desc } end,
}

local function statsResult(p)
	local res = { stats = currentHeadline() }
	if p and p.include_sidebar then
		res.sidebar = sidebarLines()
	end
	local warn = warnings()
	if #warn > 0 then
		res.warnings = warn
	end
	return res
end

-- Mutating tools return what changed plus a compact summary; get_stats has the full picture
local function afterChange(result, baseline)
	recalc()
	local stats = currentHeadline()
	local res = { result = result, stats = compactHeadline(stats) }
	if baseline then
		res.changes = diffHeadline(baseline, stats)
	end
	local warn = warnings()
	if #warn > 0 then
		res.warnings = warn
	end
	build.modFlag = true
	return res
end

tool{
	name = "load_build",
	description = "Load a build into Path of Building. Give exactly one of: path (a PoB .xml build file), xml (the file contents), or code (a PoB export/share code, e.g. from pobb.in; fetch the raw code yourself for links). Returns a summary and headline stats.",
	inputSchema = obj({
		path = S.str("Path to a .xml build file"),
		xml = S.str("Build XML text"),
		code = S.str("PoB export code (base64, as copied from 'Generate' in PoB)"),
		name = S.str("Name for the build (defaults to the file name)"),
	}),
	handler = function(p)
		local xml = p.xml
		local name = p.name
		if p.path then
			local f, err = io.open(p.path, "rb")
			if not f then
				error("Could not open '"..p.path.."': "..tostring(err))
			end
			xml = f:read("*a")
			f:close()
			name = name or p.path:match("([^/\\]+)%.xml$") or p.path
		elseif p.code then
			local code = trim(p.code):gsub("^https?://%S+/", "")
			local decoded = common.base64.decode((code:gsub("-", "+"):gsub("_", "/")))
			xml = decoded and Inflate(decoded)
			if not xml or xml == "" then
				error("Could not decode the build code. Make sure it is the raw code, not a link.")
			end
		end
		if not xml then
			error("Give one of path, xml or code")
		end
		loadXML(xml, name or "Imported build")
		frame()
		if __mainObject__.main.mode ~= "BUILD" and __mainObject__.main.newMode ~= "BUILD" and not build.spec then
			error("PoB could not load that build")
		end
		API.sourcePath = p.path
		local res = statsResult()
		res.summary = summary()
		return res
	end,
}

tool{
	name = "new_build",
	description = "Start a new empty build, optionally choosing class, ascendancy and level.",
	inputSchema = obj({
		class = S.str("Class or ascendancy name, e.g. 'Witch' or 'Necromancer'"),
		ascendancy = S.str("Ascendancy name"),
		level = S.int("Character level (default 1, or PoB's default level setting)"),
		name = S.str("Build name"),
	}),
	handler = function(p)
		disableAutoSave()
		newBuild()
		disableAutoSave()
		API.sourcePath = nil
		if p.name then
			build.buildName = p.name
		end
		if p.class then Changes.class({ class = p.class }) end
		if p.ascendancy then Changes.ascendancy({ ascendancy = p.ascendancy }) end
		if p.level then Changes.level({ level = p.level }) end
		recalc()
		local res = statsResult()
		res.summary = summary()
		return res
	end,
}

tool{
	name = "save_build",
	description = "Export the current build. Returns a PoB share code (importable in PoB or pobb.in). With path, also writes the build XML to that file (e.g. into the PoB Builds folder so it can be opened in the app).",
	inputSchema = obj({
		path = S.str("File to write the .xml build to"),
		include_xml = S.bool("Also return the raw XML"),
	}),
	handler = function(p)
		requireBuild()
		local xml = build:SaveDB(p.path or "code")
		if not xml then
			error("Saving failed")
		end
		local res = { }
		local compressed = Deflate(xml)
		if compressed and compressed ~= "" then
			res.code = common.base64.encode(compressed):gsub("+", "-"):gsub("/", "_")
		end
		if p.path then
			local f, err = io.open(p.path, "wb")
			if not f then
				error("Could not write '"..p.path.."': "..tostring(err))
			end
			f:write(xml)
			f:close()
			API.sourcePath = p.path
			build.modFlag = false
			res.path = p.path
		end
		if p.include_xml then
			res.xml = xml
		end
		return res
	end,
}

tool{
	name = "list_build_files",
	description = "List PoB .xml build files in a folder (defaults to the POB_BUILDS_DIR environment variable).",
	inputSchema = obj({ dir = S.str("Folder to list") }),
	handler = function(p)
		local dir = p.dir or os.getenv("POB_BUILDS_DIR")
		if not dir then
			error("Give dir, or set POB_BUILDS_DIR")
		end
		local cmd
		if package.config:sub(1, 1) == "\\" then
			cmd = 'dir /b /s "'..dir:gsub("/", "\\")..'\\*.xml" 2>nul'
		else
			cmd = 'find "'..dir..'" -name "*.xml" 2>/dev/null'
		end
		local files = { }
		local pipe = io.popen(cmd)
		if pipe then
			for line in pipe:lines() do
				t_insert(files, (line:gsub("\r$", "")))
			end
			pipe:close()
		end
		t_sort(files)
		return { dir = dir, files = files }
	end,
}

tool{
	name = "get_summary",
	description = "Describe the loaded build: class, ascendancy, level, main skill, socket groups and gems, equipped items (with mods PoB can't parse), allocated keystones/notables/masteries, and loadouts.",
	inputSchema = obj(),
	handler = function()
		requireBuild()
		return summary()
	end,
}

tool{
	name = "get_stats",
	description = "Headline stats for the current build as PoB calculates them: DPS (FullDPS when set up, else CombinedDPS), hit/DoT DPS, EHP, max hit per damage type and the minimum, pools, resistances (with overcap), block/suppression, regen, costs, attributes vs requirements, charges. Optionally the full PoB sidebar text and any raw output fields.",
	inputSchema = obj({
		include_sidebar = S.bool("Include the PoB sidebar exactly as displayed"),
		fields = S.arr({ type = "string" }, "Raw PoB output fields to include, e.g. ['ManaUnreserved', 'LifeLeechGainRate']"),
	}),
	handler = function(p)
		requireBuild()
		local res = statsResult(p)
		if p.fields then
			res.fields = { }
			local output = build.calcsTab.mainOutput
			for _, field in ipairs(p.fields) do
				local value = output[field]
				if type(value) == "table" then
					local flat = { }
					for k, v in pairs(value) do
						if type(v) ~= "table" then
							flat[k] = num(v)
						end
					end
					value = flat
				end
				res.fields[field] = num(value)
			end
		end
		return res
	end,
}

tool{
	name = "search_passives",
	description = "Search the passive tree by node name or stat text. Returns node ids, types, stats, whether they are allocated, and how many points it would take to reach them.",
	inputSchema = obj({
		query = S.str("Text to find in node names or stats, e.g. 'Elemental Overload' or 'maximum life'"),
		type = S.str("Filter: normal, notable, keystone, mastery, socket, ascendancy"),
		allocated = S.bool("Only allocated (true) or unallocated (false) nodes"),
		max_points = S.int("Only nodes reachable within this many points"),
		limit = S.int("Max results (default 25)"),
	}),
	handler = function(p)
		requireBuild()
		local wanted = lower(p.query)
		local typeFilter = p.type and lower(p.type)
		local results = { }
		for _, node in pairs(build.spec.nodes) do
			local ok = node.dn and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
			if ok and wanted ~= "" then
				local text = lower(node.dn) .. "\n" .. lower(t_concat(node.sd or { }, "\n"))
				if node.type == "Mastery" and node.masteryEffects then
					for _, effect in ipairs(node.masteryEffects) do
						text = text .. "\n" .. lower(t_concat(effect.stats or { }, "\n"))
					end
				end
				ok = text:find(wanted, 1, true) ~= nil
			end
			if ok and typeFilter then
				if typeFilter == "ascendancy" then
					ok = node.ascendancyName ~= nil
				elseif typeFilter == "socket" then
					ok = node.type == "Socket"
				else
					ok = lower(node.type) == typeFilter and not node.ascendancyName
				end
			end
			if ok and p.allocated ~= nil then
				ok = (node.alloc and true or false) == p.allocated
			end
			if ok and p.max_points and not node.alloc then
				ok = node.path ~= nil and #node.path <= p.max_points
			end
			if ok then
				local entry = describeNode(node, true)
				if node.type == "Mastery" and not node.alloc and node.masteryEffects then
					entry.effects = { }
					for _, effect in ipairs(node.masteryEffects) do
						t_insert(entry.effects, { id = effect.effect, stats = effect.stats })
					end
				end
				t_insert(results, entry)
			end
		end
		t_sort(results, function(a, b)
			if a.allocated ~= b.allocated then
				return a.allocated
			end
			local da, db = a.pointsToAllocate or 1000, b.pointsToAllocate or 1000
			if da ~= db then
				return da < db
			end
			return a.id < b.id
		end)
		local limit = p.limit or 25
		local total = #results
		while #results > limit do
			table.remove(results)
		end
		return { total = total, nodes = results }
	end,
}

tool{
	name = "edit_tree",
	description = "Change the passive tree. Nodes can be given by id or exact name (search_passives finds them). Allocating takes the shortest path; deallocating also removes nodes that depend on it. Returns the new stats and the change versus before.",
	inputSchema = obj({
		allocate = S.arr(S.ref(), "Nodes to allocate"),
		deallocate = S.arr(S.ref(), "Nodes to deallocate"),
		masteries = S.arr(obj({ node = S.ref("Mastery node id or name"), effect = S.ref("Effect id or text it contains") }, { "node", "effect" }), "Mastery effects to choose (allocates the mastery)"),
		class = S.str("Change class (resets the tree)"),
		ascendancy = S.str("Change ascendancy"),
		secondary_ascendancy = S.str("Change secondary ascendancy (bloodline), or 'None'"),
		tree_url = S.str("Replace the tree with a passive tree URL (official, PoB or poeplanner)"),
		level = S.int("Character level"),
		reset = S.bool("Deallocate everything first"),
	}),
	handler = function(p)
		requireBuild()
		local before = currentHeadline()
		local result = { }
		if p.tree_url then result.tree_url = Changes.tree_url({ url = p.tree_url }) end
		if p.class then result.class = Changes.class({ class = p.class }) end
		if p.ascendancy then result.ascendancy = Changes.ascendancy({ ascendancy = p.ascendancy }) end
		if p.secondary_ascendancy then result.secondary_ascendancy = Changes.secondary_ascendancy({ secondary_ascendancy = p.secondary_ascendancy }) end
		if p.reset then
			build.spec:ResetNodes()
			build.spec:BuildAllDependsAndPaths()
		end
		if p.deallocate then result.deallocated = Changes.deallocate({ nodes = p.deallocate }) end
		if p.allocate then result.allocated = Changes.allocate({ nodes = p.allocate }) end
		if p.masteries then
			result.masteries = { }
			for _, m in ipairs(p.masteries) do
				t_insert(result.masteries, Changes.mastery(m))
			end
		end
		if p.level then result.level = Changes.level({ level = p.level }) end
		build.spec:AddUndoState()
		local used, ascUsed = build.spec:CountAllocNodes()
		result.passivePoints = used
		result.ascendancyPoints = ascUsed
		return afterChange(result, before)
	end,
}

tool{
	name = "get_items",
	description = "List equipped items (active weapon set, flasks and jewels in allocated sockets) with full item text, or the item in one slot.",
	inputSchema = obj({ slot = S.str("Only this slot, e.g. 'Body Armour', 'Ring 1', 'Jewel 26725'") }),
	handler = function(p)
		requireBuild()
		if p.slot then
			local slot = findSlot(p.slot)
			local item = build.itemsTab.items[slot.selItemId]
			if not item then
				return { slot = slot.slotName, empty = true }
			end
			local res = describeItem(item, slot.slotName)
			res.text = item:BuildRaw()
			return res
		end
		local slots = { }
		for _, slot in ipairs(build.itemsTab.orderedSlots) do
			local shown = not slot.nodeId and not slot.slotName:match("Swap") and not slot.slotName:match("Abyssal")
			if shown then
				t_insert(slots, slot.slotName)
			end
		end
		local jewelSockets = { }
		for nodeId, slot in pairs(build.itemsTab.sockets) do
			if build.spec.allocNodes[nodeId] then
				t_insert(jewelSockets, slot.slotName)
			end
		end
		t_sort(jewelSockets)
		return { items = equippedItems(true), slots = slots, allocatedJewelSockets = jewelSockets }
	end,
}

tool{
	name = "equip_item",
	description = "Add an item from its text (as copied in-game with Ctrl+C, or PoB's item text format) and equip it. Without slot it goes in the item's natural slot (Ring 1, Weapon 1, ...). Use slot 'Jewel <nodeId>' for jewel sockets. Reports mods PoB can't parse and the stat changes.",
	inputSchema = obj({
		item = S.str("Item text"),
		slot = S.str("Slot to equip into"),
	}, { "item" }),
	handler = function(p)
		requireBuild()
		local before = currentHeadline()
		return afterChange(Changes.equip(p), before)
	end,
}

tool{
	name = "unequip_item",
	description = "Empty an item slot.",
	inputSchema = obj({ slot = S.str("Slot name") }, { "slot" }),
	handler = function(p)
		requireBuild()
		local before = currentHeadline()
		return afterChange(Changes.unequip(p), before)
	end,
}

tool{
	name = "get_skills",
	description = "List socket groups with their gems, which group is the main skill, and the active skills/parts available for set_main_skill.",
	inputSchema = obj(),
	handler = function()
		requireBuild()
		local res = { mainSocketGroup = build.mainSocketGroup, groups = { } }
		for i, group in ipairs(build.skillsTab.socketGroupList) do
			t_insert(res.groups, describeSocketGroup(group, i))
		end
		return res
	end,
}

tool{
	name = "set_skill_group",
	description = "Create a socket group, or replace/modify an existing one (group = index or label). gems replaces the whole gem list; each gem is a name or {name, level, quality, enabled}. Support gems can be named without 'Support'.",
	inputSchema = obj({
		group = S.ref("Existing group index or label; omit to add a new group"),
		gems = S.arr({ type = { "string", "object" } }, "Gems, e.g. ['Cyclone', {name: 'Melee Physical Damage', level: 20, quality: 20}]"),
		label = S.str("Group label"),
		slot = S.str("Item slot the gems are socketed in, e.g. 'Body Armour' ('' for none)"),
		enabled = S.bool("Whether the group is enabled"),
		include_in_full_dps = S.bool("Count this group's skills in FullDPS"),
		main = S.bool("Make this the main skill group"),
	}),
	handler = function(p)
		requireBuild()
		local before = currentHeadline()
		return afterChange(Changes.set_skill_group(p), before)
	end,
}

tool{
	name = "set_gem",
	description = "Change one gem in a socket group: swap it for another gem, or change level, quality or enabled.",
	inputSchema = obj({
		group = S.ref("Group index or label"),
		gem = S.ref("Gem index in the group or (part of) its name"),
		name = S.str("Replace with this gem"),
		level = S.int("Gem level"),
		quality = S.int("Gem quality"),
		enabled = S.bool("Enable or disable the gem"),
	}, { "group", "gem" }),
	handler = function(p)
		requireBuild()
		local before = currentHeadline()
		return afterChange(Changes.set_gem(p), before)
	end,
}

tool{
	name = "remove_skill_group",
	description = "Delete a socket group.",
	inputSchema = obj({ group = S.ref("Group index or label") }, { "group" }),
	handler = function(p)
		requireBuild()
		local before = currentHeadline()
		return afterChange(Changes.remove_skill_group(p), before)
	end,
}

tool{
	name = "set_main_skill",
	description = "Choose the main skill used for DPS: socket group, active skill within it, skill part (e.g. a specific stage or projectile mode), stage count and minion.",
	inputSchema = obj({
		group = S.ref("Group index or label"),
		skill = S.int("Active skill index within the group (see get_skills)"),
		part = S.ref("Skill part index or name"),
		stages = S.int("Stage count for multi-stage skills"),
		minion = S.str("Minion id for minion skills"),
	}, { "group" }),
	handler = function(p)
		requireBuild()
		local before = currentHeadline()
		return afterChange(Changes.main_skill(p), before)
	end,
}

tool{
	name = "get_config",
	description = "Show the Configuration tab: options that differ from default (enemy type, charges, buffs, conditions...) and custom modifiers. With all=true, list every option with its type and allowed values (filter with query).",
	inputSchema = obj({
		all = S.bool("List all options, not just changed ones"),
		query = S.str("Only options whose name, label or section contains this text"),
	}),
	handler = function(p)
		requireBuild()
		local configTab = build.configTab
		local input = configTab.input
		local wanted = p.query and lower(p.query)
		local options = { }
		local section
		for _, varData in ipairs(getConfigVarList()) do
			if varData.section then
				section = varData.section
			elseif varData.var then
				local value = input[varData.var]
				local default = configTab:GetDefaultState(varData.var, type(value))
				if varData.defaultIndex and varData.list then
					default = varData.list[varData.defaultIndex].val
				end
				local changed = value ~= nil and value ~= default and not (value == false and default == nil)
				local label = stripColors(varData.label or ""):gsub(":$", "")
				local matches = not wanted or lower(varData.var):find(wanted, 1, true) or lower(label):find(wanted, 1, true) or lower(section):find(wanted, 1, true)
				if matches and (p.all or changed) then
					local entry = { var = varData.var, label = label, section = section, type = varData.type, value = value, default = default }
					if varData.list then
						entry.options = { }
						for _, opt in ipairs(varData.list) do
							t_insert(entry.options, opt.val)
						end
					end
					t_insert(options, entry)
				end
			end
		end
		local configSet = configTab.configSets[configTab.activeConfigSetId]
		local custom = { }
		for _, block in ipairs(configSet.customModsList or { }) do
			if block.text and block.text:match("%S") then
				t_insert(custom, { title = block.title, enabled = block.enabled, text = block.text })
			end
		end
		return { options = options, customMods = custom }
	end,
}

tool{
	name = "set_config",
	description = "Set Configuration tab options by var name or label, e.g. {enemyIsBoss: 'Pinnacle', usePowerCharges: true, multiplierRage: 30}. Use null/'' for a number to reset it. Use custom_mods to add modifier lines (as typed in PoB's Custom Modifiers box) for quick what-if tests; they go in a block named 'Agent' that is replaced each call.",
	inputSchema = obj({
		values = { type = "object", description = "Map of option var name to value" },
		custom_mods = { type = { "string", "array" }, description = "Modifier lines for the 'Agent' custom modifier block ('' to clear)" },
	}),
	handler = function(p)
		requireBuild()
		local before = currentHeadline()
		local result = { }
		if p.values then
			result.set = Changes.config(p)
		end
		if p.custom_mods then
			result.customMods = Changes.custom_mods({ mods = p.custom_mods, title = "Agent" })
		end
		return afterChange(result, before)
	end,
}

tool{
	name = "loadouts",
	description = "List loadouts (matching tree/item/skill/config sets), switch to one, or create one by copying the current setup (for progression tiers like league start / early maps / endgame / chase).",
	inputSchema = obj({
		select = S.str("Switch to this loadout"),
		create = S.str("Create a loadout with this name from the current setup, and switch to it"),
	}),
	handler = function(p)
		requireBuild()
		local res = { }
		if p.create then
			res.created = Changes.create_loadout({ name = p.create })
			recalc()
		end
		if p.select then
			res.selected = Changes.loadout({ name = p.select })
			recalc()
		end
		res.loadouts = loadoutNames()
		res.active = activeSets()
		if p.create or p.select then
			res.stats = compactHeadline(currentHeadline())
		end
		return res
	end,
}

tool{
	name = "compare_loadouts",
	description = "Calculate headline stats for every loadout (or the named ones) side by side, then return to the current one. Use to verify a multi-tier build file.",
	inputSchema = obj({
		names = S.arr({ type = "string" }, "Loadouts to compare (default all)"),
		fields = S.arr({ type = "string" }, "Extra raw output fields to include"),
	}),
	handler = function(p)
		requireBuild()
		local names = p.names or loadoutNames()
		if #names == 0 then
			error("This build has no loadouts")
		end
		return withRestore(function()
			local res = { }
			for _, name in ipairs(names) do
				local ok, err = pcall(function()
					Changes.loadout({ name = name })
					recalc()
				end)
				local entry = { loadout = name }
				if ok then
					entry.stats = currentHeadline()
					entry.level = build.characterLevel
					entry.passivePoints = build.spec:CountAllocNodes()
					if p.fields then
						entry.fields = { }
						for _, field in ipairs(p.fields) do
							entry.fields[field] = num(build.calcsTab.mainOutput[field])
						end
					end
					local warn = warnings()
					if #warn > 0 then
						entry.warnings = warn
					end
				else
					entry.error = tostring(err)
				end
				t_insert(res, entry)
			end
			return { loadouts = res }
		end)
	end,
}

local changeSchema = {
	type = "object",
	description = "A change: {type, ...params}. Types and params: allocate {nodes}, deallocate {nodes}, mastery {node, effect}, class {class}, ascendancy {ascendancy}, secondary_ascendancy {secondary_ascendancy}, tree_url {url}, level {level}, equip {item, slot?}, unequip {slot}, set_skill_group {group?, gems?, label?, slot?, enabled?, include_in_full_dps?, main?}, remove_skill_group {group}, set_gem {group, gem, name?, level?, quality?, enabled?}, main_skill {group, skill?, part?, stages?}, config {values}, custom_mods {mods}, loadout {name}.",
	properties = { type = S.str("Change type") },
	required = { "type" },
}

tool{
	name = "what_if",
	description = "Try one or more scenarios without keeping them. Each scenario is a list of changes applied on top of the current build; returns the baseline and, per scenario, the resulting stats and the change versus baseline. The build is restored afterwards. Use for item/gem/node/config comparisons and 'what is +1 max res worth' (custom_mods).",
	inputSchema = obj({
		scenarios = S.arr(obj({
			name = S.str("Label for this scenario"),
			changes = S.arr(changeSchema, "Changes to apply"),
		}, { "changes" }), "Scenarios to evaluate"),
		full = S.bool("Return full stats for each scenario rather than just the changes"),
	}, { "scenarios" }),
	handler = function(p)
		requireBuild()
		local baseline = currentHeadline()
		local results = { }
		for i, scenario in ipairs(p.scenarios) do
			local entry = { name = scenario.name or ("Scenario "..i) }
			local ok, err = pcall(withRestore, function()
				local applied = { }
				for _, change in ipairs(scenario.changes) do
					t_insert(applied, API.ApplyChange(change))
				end
				recalc()
				local stats = currentHeadline()
				entry.changes = diffHeadline(baseline, stats)
				if p.full then
					entry.stats = stats
				end
				entry.applied = applied
				local warn = warnings()
				if #warn > 0 then
					entry.warnings = warn
				end
			end)
			if not ok then
				entry.error = tostring(err)
			end
			t_insert(results, entry)
		end
		return { baseline = baseline, scenarios = results }
	end,
}

-- Collect the headline numbers we rank by from a calculator output
local function scoreEntry(baseHead, baseOutput, output, metric)
	local head = headline(output, output.Minion)
	local base = metricValue(baseHead, baseOutput, metric)
	local new = metricValue(head, output, metric)
	local function pct(a, b)
		if type(a) ~= "number" or type(b) ~= "number" or a == 0 or a == m_huge or b == m_huge then
			return 0
		end
		return (b - a) / m_abs(a) * 100
	end
	return {
		metricChange = new - base,
		metricPercent = pct(base, new),
		dpsPercent = num(pct(baseHead.dps, head.dps)),
		ehpPercent = num(pct(baseHead.ehp, head.ehp)),
		minMaxHitChange = num((type(head.minMaxHit) == "number" and head.minMaxHit or 0) - (type(baseHead.minMaxHit) == "number" and baseHead.minMaxHit or 0)),
		lifeChange = num(head.life - baseHead.life),
		esChange = num(head.energyShield - baseHead.energyShield),
	}
end

tool{
	name = "rank_passives",
	description = "Rank passive choices by value per point using PoB's calculator (like the Power Report, but reporting DPS, EHP, min max hit, life and ES together). mode 'add' scores reachable unallocated notables/keystones/masteries (including their path); mode 'remove' scores what each allocated node is worth (removing it and everything that depends on it).",
	inputSchema = obj({
		metric = S.str("Rank by: dps (default), ehp, min_max_hit, life, es, or any raw output field"),
		mode = S.str("'add' (default) or 'remove'"),
		max_points = S.int("For add: only nodes within this many points (default 5)"),
		include_small = S.bool("For add: also score small passives (slower)"),
		include_masteries = S.bool("For add: score mastery effects (default true)"),
		include_ascendancy = S.bool("For add: also score reachable ascendancy nodes (ignores the 8 point limit)"),
		limit = S.int("Results to return (default 20)"),
	}),
	handler = function(p)
		requireBuild()
		local metric = p.metric or "dps"
		local useFullDPS = true
		local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
		local baseHead = headline(calcBase, calcBase.Minion)
		local maxPoints = p.max_points or 5
		local spec = build.spec
		local entries = { }
		local grantedPassives = build.calcsTab.mainEnv.grantedPassives or { }
		if lower(p.mode or "add") == "remove" then
			for _, node in pairs(spec.allocNodes) do
				if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.modKey ~= "" and not grantedPassives[node.id] then
					if p.include_small or node.type ~= "Normal" or node.ascendancyName then
						local removeNodes = { }
						for _, dep in ipairs(node.depends or { node }) do
							removeNodes[dep] = true
						end
						local points = m_max(#(node.depends or { }), 1)
						local entry = scoreEntry(baseHead, calcBase, calcFunc({ removeNodes = removeNodes }, useFullDPS), metric)
						entry.node = describeNode(node)
						entry.points = points
						entry.perPoint = entry.metricPercent / points
						t_insert(entries, entry)
					end
				end
			end
			-- Lower is a bigger loss, so the most valuable nodes come first
			t_sort(entries, function(a, b) return a.metricChange < b.metricChange end)
		else
			for _, node in pairs(spec.nodes) do
				local candidate = not node.alloc and node.path and #node.path <= maxPoints and node.modKey ~= "" and not grantedPassives[node.id]
					and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
				if candidate and node.type == "Normal" and not p.include_small and not node.ascendancyName then
					candidate = false
				end
				if candidate and node.ascendancyName then
					candidate = p.include_ascendancy and true or false
				end
				if candidate and node.type == "Mastery" then
					if p.include_masteries ~= false and node.allMasteryOptions then
						for _, masteryEffect in ipairs(node.masteryEffects or { }) do
							local effect = spec.tree.masteryEffects[masteryEffect.effect]
							if effect and not isValueInTable(spec.masterySelections, effect.id) then
								local effectNode = { id = node.id, type = node.type, name = node.name, dn = node.dn, sd = { } }
								for i, sd in ipairs(effect.sd or { }) do
									effectNode.sd[i] = sd
								end
								spec.tree:ProcessStats(effectNode)
								local addNodes = { [effectNode] = true }
								for _, pathNode in ipairs(node.path) do
									if pathNode ~= node then
										addNodes[pathNode] = true
									end
								end
								local entry = scoreEntry(baseHead, calcBase, calcFunc({ addNodes = addNodes }, useFullDPS), metric)
								entry.node = describeNode(node)
								entry.node.stats = { }
								for _, line in ipairs(effect.sd or { }) do
									t_insert(entry.node.stats, stripColors(line))
								end
								entry.node.masteryEffect = effect.id
								entry.points = #node.path
								entry.perPoint = entry.metricPercent / entry.points
								t_insert(entries, entry)
							end
						end
					end
				elseif candidate then
					local addNodes = { }
					for _, pathNode in ipairs(node.path) do
						addNodes[pathNode] = true
					end
					local entry = scoreEntry(baseHead, calcBase, calcFunc({ addNodes = addNodes }, useFullDPS), metric)
					entry.node = describeNode(node)
					entry.points = #node.path
					entry.perPoint = entry.metricPercent / entry.points
					t_insert(entries, entry)
				end
			end
			t_sort(entries, function(a, b)
				if a.perPoint ~= b.perPoint then
					return a.perPoint > b.perPoint
				end
				return a.metricChange > b.metricChange
			end)
		end
		local limit = p.limit or 20
		local res = { }
		for i = 1, m_min(limit, #entries) do
			local e = entries[i]
			e.metricChange = num(e.metricChange)
			e.metricPercent = num(e.metricPercent)
			e.perPoint = num(e.perPoint)
			res[i] = e
		end
		return { metric = metric, baseline = compactHeadline(baseHead), evaluated = #entries, results = res }
	end,
}

tool{
	name = "ablation",
	description = "Find what really scales the build: remove one component at a time and measure DPS, EHP and min max hit. Components: each enabled gem (except the main active skill), each equipped item, and allocated keystones, ascendancy notables, notables and masteries. Sorted by DPS impact (or the given metric).",
	inputSchema = obj({
		metric = S.str("Sort by: dps (default), ehp, min_max_hit, life, es or a raw output field"),
		components = S.arr({ type = "string" }, "Which kinds to test: gems, items, tree (default all)"),
		limit = S.int("Results to return (default all)"),
	}),
	handler = function(p)
		requireBuild()
		local metric = p.metric or "dps"
		local kinds = { }
		for _, k in ipairs(p.components or { "gems", "items", "tree" }) do
			kinds[lower(k)] = true
		end
		recalc()
		local baseHead = currentHeadline()
		local baseOutput = build.calcsTab.mainOutput
		local entries = { }
		local function record(kind, name, output)
			local entry = scoreEntry(baseHead, baseOutput, output, metric)
			entry.kind = kind
			entry.removed = name
			entry.dpsPercent = entry.dpsPercent
			t_insert(entries, entry)
		end
		local calcFunc = build.calcsTab:GetMiscCalculator()

		if kinds.tree then
			local grantedPassives = build.calcsTab.mainEnv.grantedPassives or { }
			for _, node in pairs(build.spec.allocNodes) do
				if (node.type == "Keystone" or node.type == "Notable" or node.type == "Mastery" or (node.ascendancyName and node.isNotable))
					and node.modKey ~= "" and not grantedPassives[node.id] then
					local label = node.dn
					if node.type == "Mastery" then
						local sd = { }
						for _, line in ipairs(node.sd or { }) do
							t_insert(sd, stripColors(line))
						end
						label = label .. ": " .. t_concat(sd, " / ")
					end
					record(node.ascendancyName and "ascendancy" or lower(node.type), label, calcFunc({ removeNodes = { [node] = true } }, true))
				end
			end
		end
		if kinds.items then
			for _, item in ipairs(equippedItems(false)) do
				record("item", item.slot .. ": " .. item.name, calcFunc({ repSlotName = item.slot }, true))
			end
		end
		if kinds.gems then
			local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
			local mainGem
			if mainGroup and mainGroup.displaySkillList then
				local active = mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
				mainGem = active and active.activeEffect.srcInstance
			end
			for gi, group in ipairs(build.skillsTab.socketGroupList) do
				if group.enabled then
					for _, gem in ipairs(group.gemList) do
						if gem.enabled and gem ~= mainGem and (gem.gemData or gem.grantedEffect) then
							gem.enabled = false
							local ok, output = pcall(calcFunc, nil, true)
							gem.enabled = true
							if not ok then
								error(output, 0)
							end
							record("gem", "#" .. gi .. " " .. socketGroupLabel(group) .. ": " .. (gem.gemData and gem.gemData.name or gem.nameSpec), output)
						end
					end
				end
			end
		end
		-- Biggest loss first
		t_sort(entries, function(a, b) return a.metricChange < b.metricChange end)
		local limit = p.limit or #entries
		local res = { }
		for i = 1, m_min(limit, #entries) do
			local e = entries[i]
			e.metricChange = num(e.metricChange)
			e.metricPercent = num(e.metricPercent)
			res[i] = e
		end
		return { metric = metric, baseline = compactHeadline(baseHead), results = res }
	end,
}

local function parseItem(raw)
	local item = new("Item"):Item(tostring(raw):gsub("\r\n", "\n"))
	if not item.base then
		error("Could not parse item (unknown base type)")
	end
	item:NormaliseQuality()
	item:BuildModList()
	return item
end

tool{
	name = "compare_items",
	description = "Score many candidate items at once without equipping them (uses PoB's fast item-comparison path). Each candidate is item text plus an optional slot (defaults to the item's natural slot; for rings use 'Ring 1' or 'Ring 2'). Returns each candidate's change in DPS, EHP, min max hit, life, ES and resistances versus what is equipped, ranked by the metric.",
	inputSchema = obj({
		items = S.arr(obj({
			name = S.str("Label for this candidate"),
			item = S.str("Item text"),
			slot = S.str("Slot to compare against"),
		}, { "item" }), "Candidate items"),
		metric = S.str("Rank by: dps (default), ehp, min_max_hit, life, es, or a raw output field"),
	}, { "items" }),
	handler = function(p)
		requireBuild()
		local metric = p.metric or "dps"
		local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
		local baseHead = headline(calcBase, calcBase.Minion)
		local results = { }
		for i, candidate in ipairs(p.items) do
			local entry = { name = candidate.name or ("Item "..i) }
			local ok, err = pcall(function()
				local item = parseItem(candidate.item)
				local slotName = candidate.slot and findSlot(candidate.slot).slotName or item:GetPrimarySlot()
				if not build.itemsTab:IsItemValidForSlot(item, slotName) then
					error("A "..tostring(item.type).." can't go in "..tostring(slotName))
				end
				entry.slot = slotName
				entry.item = describeItem(item, slotName)
				entry.item.slot = nil
				local output = calcFunc({ repSlotName = slotName, repItem = item }, true)
				local score = scoreEntry(baseHead, calcBase, output, metric)
				for k, v in pairs(score) do
					entry[k] = v
				end
				local newHead = headline(output, output.Minion)
				local res = diffHeadline(baseHead, newHead).resist
				if res then
					entry.resistChange = res
				end
			end)
			if not ok then
				entry.error = tostring(err)
				entry.metricChange = -m_huge
			end
			t_insert(results, entry)
		end
		t_sort(results, function(a, b) return a.metricChange > b.metricChange end)
		for _, e in ipairs(results) do
			e.metricChange = e.error and nil or num(e.metricChange)
			e.metricPercent = num(e.metricPercent)
		end
		return { metric = metric, baseline = compactHeadline(baseHead), results = results }
	end,
}

tool{
	name = "rank_gems",
	description = "Score many gems in one slot of a socket group at once (PoB's fast gem-sorting path): replace an existing gem, or fill a new extra socket. Candidates default to every support gem; awakened/exceptional ones are skipped unless include_chase. Returns DPS/EHP changes ranked by the metric.",
	inputSchema = obj({
		group = S.ref("Socket group index or label (default: main skill group)"),
		replace = S.ref("Gem to replace (index or name); omit to test adding a gem"),
		candidates = S.arr({ type = "string" }, "Gem names to try (default: all support gems)"),
		level = S.int("Gem level (default: each gem's max natural level)"),
		quality = S.int("Gem quality (default: the replaced gem's quality, else 20)"),
		include_chase = S.bool("Include awakened and exceptional gems"),
		metric = S.str("Rank by: dps (default), ehp, min_max_hit, or a raw output field"),
		limit = S.int("Results to return (default 20)"),
	}),
	handler = function(p)
		requireBuild()
		local metric = p.metric or "dps"
		local group = findSocketGroup(p.group or build.mainSocketGroup)
		local gemList = group.gemList
		local index, original
		if p.replace then
			original, index = findGem(group, p.replace)
			original = copyTable(original, true)
		else
			index = #gemList + 1
		end
		local inGroup = { }
		for i, gem in ipairs(gemList) do
			if gem.gemData and i ~= index then
				inGroup[gem.gemData.id] = true
			end
		end
		local candidates = { }
		if p.candidates then
			for _, name in ipairs(p.candidates) do
				local errMsg, gemData = build.skillsTab:FindSkillGem(name)
				if not gemData then
					errMsg, gemData = build.skillsTab:FindSkillGem(name .. " Support")
				end
				if gemData then
					t_insert(candidates, gemData)
				end
			end
		else
			for _, gemData in pairs(build.data.gems) do
				local ge = gemData.grantedEffect
				local chase = gemData.tags.awakened or gemData.tags.exceptional or (ge.legacy and ge.plusVersionOf)
				if ge.support and not ge.hideFromGemList and not ge.legacy and (p.include_chase or not chase) then
					t_insert(candidates, gemData)
				end
			end
		end

		-- Recalculate the base with the slot empty (or holding the original gem)
		local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
		local baseHead = headline(calcBase, calcBase.Minion)
		local results = { }
		local ok, err = pcall(function()
			for _, gemData in ipairs(candidates) do
				if not inGroup[gemData.id] then
					gemList[index] = {
						level = p.level or gemData.naturalMaxLevel or 20,
						quality = p.quality or (original and original.quality) or 20,
						count = 1, enabled = true, enableGlobal1 = true, enableGlobal2 = true,
						gemId = gemData.id, nameSpec = gemData.name, skillId = gemData.grantedEffectId,
						gemData = gemData,
					}
					local output = calcFunc(nil, true)
					local entry = scoreEntry(baseHead, calcBase, output, metric)
					entry.gem = gemData.name
					t_insert(results, entry)
				end
			end
		end)
		if original then
			gemList[index] = original
		else
			gemList[index] = nil
		end
		if not ok then
			error(err, 0)
		end
		t_sort(results, function(a, b) return a.metricChange > b.metricChange end)
		local limit = p.limit or 20
		local res = { }
		for i = 1, m_min(limit, #results) do
			local e = results[i]
			e.metricChange = num(e.metricChange)
			e.metricPercent = num(e.metricPercent)
			res[i] = e
		end
		return {
			metric = metric, group = socketGroupLabel(group),
			replacing = original and (original.gemData and original.gemData.name or original.nameSpec) or nil,
			baseline = compactHeadline(baseHead), evaluated = #results, results = res,
		}
	end,
}

tool{
	name = "check_ssf_rules",
	description = "Check equipped items and gems against SSF crafting rules: at most 2 influences per item, eldritch implicits only on helmet/body/gloves/boots and never with base influences, no Archmage Support, awakened gems max level 5, jewel mod limits, and chase uniques that shouldn't be in an SSF baseline. Awakened/exceptional gems and foulborn uniques are flagged as notes.",
	inputSchema = obj({
		chase_uniques = S.arr({ type = "string" }, "Extra unique names to treat as chase items"),
		allowed_uniques = S.arr({ type = "string" }, "Unique names to allow even if on the default chase list"),
	}),
	handler = function(p)
		requireBuild()
		return SSFRules.Check(build, p)
	end,
}

API.tools = tools
API.toolOrder = toolOrder

function API.ListTools()
	local list = { }
	for _, name in ipairs(toolOrder) do
		local def = tools[name]
		t_insert(list, { name = def.name, description = def.description, inputSchema = def.inputSchema })
	end
	return list
end

function API.Call(name, params)
	local def = tools[name]
	if not def then
		error("Unknown tool '"..tostring(name).."'")
	end
	return def.handler(params or { })
end

return API
