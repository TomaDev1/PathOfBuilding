describe("TestAgentAPI", function()
	local API, SSFRules, MCPServer
	local dkjson = require("dkjson")

	setup(function()
		dofile("Agent/Headless.lua").InstallZlib()
		API = LoadModule("Agent/BuildAPI")
		SSFRules = LoadModule("Agent/SSFRules")
		MCPServer = dofile("Agent/MCPServer.lua")
	end)

	before_each(function()
		newBuild()
	end)

	local function call(name, params)
		return API.Call(name, params or { })
	end

	local bow = [[
		Rarity: Rare
		Test Bow
		Thicket Bow
		Adds 20 to 40 Physical Damage
		30% increased Attack Speed
		Adds 10 to 50 Lightning Damage
		]]

	local function makeBowBuild()
		call("new_build", { class = "Deadeye", level = 90 })
		call("set_skill_group", { gems = { "Lightning Arrow", "Elemental Damage with Attacks", "Added Lightning Damage" }, label = "LA", main = true })
		call("equip_item", { item = bow })
	end

	it("creates a build with class, ascendancy and level", function()
		local res = call("new_build", { class = "Ranger", ascendancy = "Deadeye", level = 85 })
		assert.are.equals("Ranger", res.summary.class)
		assert.are.equals("Deadeye", res.summary.ascendancy)
		assert.are.equals(85, res.summary.level)
		assert.is_true(res.stats.life > 0)
		assert.is_not_nil(res.stats.maxHit.fire)
	end)

	it("adds gems and items and reports the stat changes", function()
		call("new_build", { class = "Ranger", level = 90 })
		call("set_skill_group", { gems = { "Lightning Arrow", "Elemental Damage with Attacks" }, label = "LA", main = true })
		local res = call("equip_item", { item = bow })
		assert.are.equals("Weapon 1", res.result.slot)
		assert.is_true(res.stats.dps > 0)
		assert.is_true(res.changes.dps.change > 0)

		local skills = call("get_skills")
		assert.are.equals(1, #skills.groups)
		assert.are.equals("Lightning Arrow", skills.groups[1].gems[1].name)
		assert.are.equals("Elemental Damage with Attacks", skills.groups[1].gems[2].name)
	end)

	it("reports item mods PoB can't parse", function()
		call("new_build", { class = "Ranger" })
		local res = call("equip_item", { item = "Rarity: Rare\nOdd Ring\nIron Ring\n+20 to maximum Life\nThis mod does not exist anywhere" })
		assert.are.same({ "This mod does not exist anywhere" }, res.result.unsupportedMods)
	end)

	it("rejects unknown gems", function()
		call("new_build", { })
		assert.has_error(function()
			call("set_skill_group", { gems = { "Definitely Not A Gem" } })
		end)
	end)

	it("allocates and deallocates passives by name", function()
		call("new_build", { class = "Ranger", level = 90 })
		local found = call("search_passives", { query = "Elemental Overload", type = "keystone" })
		assert.are.equals(1, found.total)
		local id = found.nodes[1].id
		local res = call("edit_tree", { allocate = { "Elemental Overload" } })
		assert.is_true(build.spec.allocNodes[id] ~= nil)
		assert.is_true(res.result.passivePoints > 1)
		call("edit_tree", { deallocate = { id } })
		assert.is_nil(build.spec.allocNodes[id])
	end)

	it("selects a mastery effect", function()
		call("new_build", { class = "Ranger", level = 90 })
		local found = call("search_passives", { query = "Mastery", type = "mastery", allocated = false, limit = 50 })
		local mastery
		for _, node in ipairs(found.nodes) do
			if node.pointsToAllocate and node.effects and #node.effects > 0 then
				mastery = node
				break
			end
		end
		assert.is_not_nil(mastery)
		local res = call("edit_tree", { masteries = { { node = mastery.id, effect = mastery.effects[1].id } } })
		assert.are.equals(1, #res.result.masteries)
		assert.are.equals(mastery.effects[1].id, build.spec.masterySelections[mastery.id])
	end)

	it("sets config options and custom mods", function()
		call("new_build", { })
		local res = call("set_config", { values = { enemyIsBoss = "Uber", usePowerCharges = true }, custom_mods = "+1 to maximum Power Charges" })
		assert.are.equals("Uber", build.configTab.input.enemyIsBoss)
		assert.are.equals(4, res.changes.charges.powerMax.after)
		local config = call("get_config", { query = "power charges" })
		assert.is_true(#config.options >= 1)
		assert.are.equals("+1 to maximum Power Charges", config.customMods[1].text)
		assert.has_error(function()
			call("set_config", { values = { enemyIsBoss = "Not a boss type" } })
		end)
	end)

	it("evaluates what-if scenarios without changing the build", function()
		makeBowBuild()
		local before = build.calcsTab.mainOutput.CombinedDPS
		local res = call("what_if", { scenarios = {
			{ name = "more damage", changes = { { type = "custom_mods", mods = "50% more Damage" } } },
			{ name = "broken", changes = { { type = "allocate", nodes = { "No Such Passive" } } } },
		} })
		assert.are.equals(before, build.calcsTab.mainOutput.CombinedDPS)
		assert.is_true(res.scenarios[1].changes.dps.percent > 49)
		assert.is_not_nil(res.scenarios[2].error)
	end)

	it("round-trips a build through a share code", function()
		makeBowBuild()
		local dps = build.calcsTab.mainOutput.CombinedDPS
		local saved = call("save_build", { })
		assert.is_true(#saved.code > 100)
		newBuild()
		local res = call("load_build", { code = saved.code })
		assert.are.equals(API.Round(dps), res.stats.combinedDPS)
		assert.are.equals("Deadeye", res.summary.ascendancy)
	end)

	it("ranks passives, gems and items in batches", function()
		makeBowBuild()
		local passives = call("rank_passives", { max_points = 8, limit = 5 })
		assert.is_true(passives.evaluated > 0)
		for i = 2, #passives.results do
			assert.is_true(passives.results[i - 1].perPoint >= passives.results[i].perPoint, tostring(passives.results[i - 1].perPoint) .. " < " .. tostring(passives.results[i].perPoint))
		end

		local gems = call("rank_gems", { candidates = { "Trinity", "Added Cold Damage", "Mirage Archer" } })
		assert.are.equals(3, gems.evaluated)
		assert.is_true(gems.results[1].metricChange >= gems.results[3].metricChange)
		-- the build is left as it was
		assert.are.equals(3, #build.skillsTab.socketGroupList[1].gemList)

		local items = call("compare_items", { items = {
			{ name = "same", item = bow },
			{ name = "worse", item = "Rarity: Rare\nWeak Bow\nThicket Bow\n+10 to Dexterity" },
		} })
		assert.are.equals("same", items.results[1].name)
		assert.are.equals(0, items.results[1].metricChange)
		assert.is_true(items.results[2].dpsPercent < 0)
	end)

	it("runs ablation over gems, items and tree", function()
		makeBowBuild()
		local res = call("ablation", { })
		local kinds = { }
		for _, entry in ipairs(res.results) do
			kinds[entry.kind] = true
		end
		assert.is_true(kinds.gem)
		assert.is_true(kinds.item)
		-- removing the bow loses all damage, so it ranks first
		assert.are.equals(-100, res.results[1].dpsPercent)
	end)

	it("creates, switches and compares loadouts", function()
		makeBowBuild()
		call("loadouts", { create = "Endgame" })
		call("edit_tree", { allocate = { "Elemental Overload" } })
		local res = call("compare_loadouts", { })
		assert.are.equals(2, #res.loadouts)
		local names = { }
		for _, entry in ipairs(res.loadouts) do
			names[entry.loadout] = entry
		end
		assert.is_not_nil(names.Endgame)
		assert.is_true(names.Endgame.passivePoints > names.Default.passivePoints)
		local switched = call("loadouts", { select = "Default" })
		assert.are.equals("Default", switched.active.tree)
	end)

	it("checks SSF item and gem rules", function()
		call("new_build", { class = "Witch", level = 90 })
		call("equip_item", { item = "Rarity: Rare\nGreedy Helm\nHubris Circlet\nShaper Item\nElder Item\nCrusader Item\n+50 to maximum Life" })
		call("equip_item", { item = "Rarity: Unique\nMageblood\nHeavy Belt" })
		call("set_skill_group", { gems = { { name = "Arc" }, { name = "Archmage" }, { name = "Awakened Added Lightning Damage", level = 6 } } })
		local res = SSFRules.Check(build, { })
		assert.is_false(res.ok)
		local messages = { }
		for _, v in ipairs(res.violations) do
			table.insert(messages, v.message)
		end
		local text = table.concat(messages, "\n")
		assert.is_truthy(text:find("3 influences", 1, true))
		assert.is_truthy(text:find("Chase unique", 1, true))
		assert.is_truthy(text:find("Archmage", 1, true))
		assert.is_truthy(text:find("Awakened gems max at level 5", 1, true))

		local allowed = SSFRules.Check(build, { allowed_uniques = { "Mageblood" } })
		assert.are.equals(#res.violations - 1, #allowed.violations)
	end)

	it("rejects legacy items and gems", function()
		call("new_build", { class = "Marauder", level = 90 })
		local function violationsFor(slot)
			local found = { }
			for _, v in ipairs(SSFRules.Check(build, { }).violations) do
				if v.slot == slot then
					table.insert(found, v.message)
				end
			end
			return table.concat(found, "\n")
		end

		-- Unique that is no longer obtainable at all
		call("equip_item", { item = "Rarity: Unique\nNgamahu Tiki\nCoral Amulet" })
		assert.is_truthy(violationsFor("Amulet"):find("no longer obtainable", 1, true))

		-- Old version of a unique that still drops in its current form
		call("equip_item", { item = "Rarity: Unique\nArn's Anguish\nCloth Belt\nVariant: Pre 3.17.0\nVariant: Current\nSelected Variant: 1\n+(600-700) to Armour" })
		assert.is_truthy(violationsFor("Belt"):find("Legacy variant (Pre 3.17.0)", 1, true))
		call("equip_item", { item = "Rarity: Unique\nArn's Anguish\nCloth Belt\nVariant: Pre 3.17.0\nVariant: Current\nSelected Variant: 2\n+(600-700) to Armour" })
		assert.are.equals("", violationsFor("Belt"))

		-- Legacy gems
		local legacyGem
		for _, gemData in pairs(build.data.gems) do
			if gemData.grantedEffect.legacy then
				legacyGem = gemData
				break
			end
		end
		assert.is_not_nil(legacyGem)
		local group = { label = "", enabled = true, mainActiveSkill = 1, gemList = {
			{ gemId = legacyGem.id, nameSpec = legacyGem.name, level = 20, quality = 0, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1 },
		} }
		build.skillsTab:ProcessSocketGroup(group)
		table.insert(build.skillsTab.socketGroupList, group)
		assert.is_truthy(violationsFor("Skill group #1"):find("Legacy gem", 1, true))
	end)

	it("syncs a Luminary player's buffs into a Mercenary build", function()
		-- A bare-bones Mercenary: attack skill and a curse, with a wand
		call("new_build", { class = "Scion", ascendancy = "Luminary", level = 83 })
		call("set_skill_group", { gems = { "Kinetic Blast" }, label = "KB", main = true })
		call("set_skill_group", { gems = { "Elemental Weakness" }, label = "Curse" })
		call("equip_item", { item = "Rarity: Rare\nTest Wand\nImbued Wand\nAdds 20 to 40 Physical Damage" })
		call("equip_item", { item = "Rarity: Unique\nKaom's Heart\nGlorious Plate" })
		call("set_config", { custom_mods = { "+20000 to maximum Life" } })
		local mercPath = os.tmpname()
		call("save_build", { path = mercPath })
		local mercAlone = call("get_stats").stats

		call("new_build", { class = "Scion", ascendancy = "Luminary", level = 95 })
		call("edit_tree", { allocate = { "Golden Glory", "Loyal Bodyguard", "Legendary Arms" } })
		call("set_skill_group", { gems = { "Flame Link" }, label = "Link", main = true })
		local playerAlone = call("get_stats").stats

		local res = call("merc_sync", { merc = mercPath })
		os.remove(mercPath)
		assert.are.equals("player", res.loaded)
		assert.are.same({ "Flame Link" }, res.merc.buffsFromPlayer.Link)
		assert.are.same({ "Elemental Weakness" }, res.player.buffsFromMerc.Curse)
		assert.is_true(res.merc.stats.dps > mercAlone.dps)
		-- 8% more damage per unique, and a unique body armour is never allowed
		assert.is_truthy(table.concat(res.merc.luminaryMods, "\n"):find("8% more Damage", 1, true))
		assert.are.equals(1, #res.merc.warnings)
		assert.is_truthy(res.merc.warnings[1]:find("Body Armour", 1, true))
		-- Loyal Bodyguard: 20% of hits are taken from the Mercenary's bigger Life pool
		assert.is_true(res.player.after.minMaxHit > playerAlone.minMaxHit * 1.2)
		assert.are.equals("Scion", call("get_summary").class)
	end)

	it("applies Light Radius to Link effect with Golden Glory", function()
		call("new_build", { class = "Scion", ascendancy = "Luminary", level = 95 })
		call("set_skill_group", { gems = { "Flame Link" }, label = "Link", main = true })
		call("set_config", { custom_mods = { "100% increased Light Radius" } })
		local before = call("get_stats", { fields = { "LinkEffectMod" } })
		call("edit_tree", { allocate = { "Golden Glory" } })
		local after = call("get_stats", { fields = { "LinkEffectMod" } })
		local field = function(res) return (res.fields or res.raw).LinkEffectMod end
		assert.are.equals(1, field(before))
		assert.is_true(field(after) >= 2)
	end)

	it("serves tools over MCP", function()
		local out = { buf = { } }
		function out:write(...)
			for _, s in ipairs({ ... }) do
				table.insert(self.buf, s)
			end
		end
		function out:flush() end
		local server = MCPServer.New({ out = out, boot = function() end })
		local function request(id, method, params)
			out.buf = { }
			server:HandleLine(dkjson.encode({ jsonrpc = "2.0", id = id, method = method, params = params }))
			return dkjson.decode(table.concat(out.buf))
		end

		local init = request(1, "initialize", { protocolVersion = "2025-06-18", capabilities = { }, clientInfo = { name = "test", version = "1" } })
		assert.are.equals("2025-06-18", init.result.protocolVersion)
		assert.are.equals("path-of-building", init.result.serverInfo.name)

		out.buf = { }
		server:HandleLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
		assert.are.equals(0, #out.buf)

		local list = request(2, "tools/list", { })
		local names = { }
		for _, def in ipairs(list.result.tools) do
			names[def.name] = true
			assert.are.equals("object", def.inputSchema.type)
		end
		assert.is_true(names.load_build and names.what_if and names.rank_passives and true)

		local ok = request(3, "tools/call", { name = "new_build", arguments = { class = "Witch" } })
		assert.is_nil(ok.result.isError)
		local payload = dkjson.decode(ok.result.content[1].text)
		assert.are.equals("Witch", payload.summary.class)

		local bad = request(4, "tools/call", { name = "edit_tree", arguments = { allocate = { "No Such Passive" } } })
		assert.is_true(bad.result.isError)
		assert.is_truthy(bad.result.content[1].text:find("No passive node named", 1, true))

		local missing = request(5, "no/such/method", { })
		assert.are.equals(-32601, missing.error.code)
	end)
end)
