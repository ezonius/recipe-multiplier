--- Recipe Multiplier — data-final-fixes.
---
--- Scales recipe results/ingredients (and crafting time) so that one craft yields
--- `multiplier` times as much. Which recipes get scaled is controlled by three
--- independent criteria (each toggleable via startup settings):
---   1. "type"      — every prototype of a given data.raw group (e.g. all `item`s),
---                    matching by the group name or `type=multiplier` in the setting string.
---   2. "name"      — specific item names, optionally with per-name multipliers.
---   3. "subgroup"  — recipes whose `subgroup` matches a name in the subgroup setting.
--- A recipe matched by several criteria is scaled once, by the first criterion that
--- claims it (type → name → subgroup).
--- Optionally (`re-enable-add-recipe`) the original recipes are left untouched and a
--- `<name>-bulk` copy is scaled instead.
---
--- Additionally multiplies the fluid volume of machines and the cargo-pod inventory.
--- Using LuaCATS annotations
require "util"

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

--- Engine hard-limits recipe ingredient/product amounts at this value.
local MAX_AMOUNT = 65535

--- Reads a numeric startup setting and falls back to `fallback` (with a log) when the
--- value cannot be converted to a number, instead of crashing downstream arithmetic.
---@param settingName string internal name of the startup setting
---@param fallback number value to use when the setting is missing or non-numeric
---@return number
local function parseNumberSetting(settingName, fallback)
	local setting = settings.startup[settingName]
	local value = setting and tonumber(setting.value)
	if not value then
		log("Warning: startup setting '" .. settingName .. "' has a non-numeric value ('" ..
			tostring(setting and setting.value) .. "'); using fallback " .. fallback .. ".")
		return fallback
	end
	return value
end

local modSettingsRecipeMultiplier = parseNumberSetting("re-amount-multiplier", 10)
local modSettingsRecyclingMultiplier = parseNumberSetting("re-recycling-amount-multiplier", 10)
local modSettingsAddRecipes = not not settings.startup["re-enable-add-recipe"].value
local modSettingsFluidFlowMultiplier = parseNumberSetting("re-fluid-flow-multiplier", 10)

local modSettingsEnableType = settings.startup["re-enable-type"].value
local modSettingsEnableName = settings.startup["re-enable-name"].value
local modSettingsEnableSubgroup = settings.startup["re-enable-subgroup"].value
local modSettingsScaleMixedNonStackable = not not settings.startup["re-scale-mixed-nonstackable"].value

-- ---------------------------------------------------------------------------
-- Startup log broadcast (shown in-game after loading a map; see control.lua)
-- ---------------------------------------------------------------------------

--- Notable startup messages (warnings, skips, errors). These are embedded into a
--- hidden item prototype's localised name so the control stage can broadcast them
--- after a game is loaded — data-stage `log()` output is otherwise only visible in
--- factorio-current.log.
local startupLogMessages = {}

--- Logs a notable message and queues it for the in-game startup broadcast.
---@param message string single-line message (newlines would break the per-line broadcast)
local function report(message)
	log(message)
	table.insert(startupLogMessages, message)
end

-- ---------------------------------------------------------------------------
-- Parsing of the "name, name2=multiplier, ..." style settings
-- ---------------------------------------------------------------------------

--- Parses a setting string of the format `"typeOrName=CustomMultiplier, typeOrName2"` into
--- a table mapping each `typeOrName` to its multiplier. Entries without an explicit
--- multiplier fall back to the global recipe multiplier. Entries that fail to parse are
--- skipped with a log (fail-safe: the remaining, valid entries still take effect) —
--- data stage code cannot fall back to "the last working setting", but since entries
--- are independent, dropping only the broken ones preserves everything else.
---@param settingString string e.g. `"iron-plate=100, copper-plate"`
---@param settingName string internal name of the setting, for log messages
---@return table<string, number>
local function parseSettingString(settingString, settingName)
	local result = {}
	if type(settingString) ~= "string" then
		log("Warning: startup setting '" .. settingName .. "' is not a string; ignoring it.")
		return result
	end
	for entry in settingString:gmatch("[^%s,]+") do
		local ok, typeOrName, numeration = pcall(function()
			return entry:match("([^=]+)=?(.*)")
		end)
		if not ok or not typeOrName or typeOrName == "" then
			report("Warning: could not parse entry '" .. tostring(entry) .. "' in startup setting '" ..
				settingName .. "'; skipping it.")
		elseif numeration ~= "" and tonumber(numeration) == nil then
			report("Warning: entry '" .. entry .. "' in startup setting '" .. settingName ..
				"' has a non-numeric multiplier ('" .. numeration .. "'); skipping it.")
		else
			result[typeOrName] = (tonumber(numeration) or modSettingsRecipeMultiplier or 1)
		end
	end
	return result
end

---@type table<string, number>
---@diagnostic disable-next-line: param-type-mismatch
local modSettingsItemTypes = parseSettingString(settings.startup["re-item-types"].value, "re-item-types")
---@type table<string, number>
---@diagnostic disable-next-line: param-type-mismatch
local modSettingsItemNames = parseSettingString(settings.startup["re-item-names"].value, "re-item-names")
---@type table<string, number>
---@diagnostic disable-next-line: param-type-mismatch
local modSettingsSubGroups = parseSettingString(settings.startup["re-sub-groups"].value, "re-sub-groups")

--- Runs one fail-safe block: any error is logged (with the criterion name) instead of
--- aborting the whole data stage, so a problem in one criterion cannot take down the
--- other criteria or the rest of the mod.
---@param criterionName string human-readable name of the criterion, for log messages
---@param fn function the code to run
local function runFailSafe(criterionName, fn)
	local ok, err = pcall(fn)
	if not ok then
		report("Error in '" .. criterionName .. "' (startup settings fail-safe, criterion skipped): " .. tostring(err))
	end
end

-- ---------------------------------------------------------------------------
-- Item filtering
-- ---------------------------------------------------------------------------

--- Item-ish prototype groups that must never cause a recipe to be scaled (things that
--- are in `data.raw` but are not actual craftable-item holders, plus non-craftable
--- special items that would break the game when their recipes were scaled).
local excludedGroups = {
	recipe = true,
	achievement = true,
	corpse = true,
	explosion = true,
	["ambient-sound"] = true,
	["delayed-active-trigger"] = true,
	["noise-expression"] = true,
	["noise-function"] = true,
	["optimized-decorative"] = true,
	["optimized-particle"] = true,
	["smoke-with-trigger"] = true,
	["technology"] = true,
	["tile"] = true,
	["virtual-signal"] = true,
	armor = true,
	["deconstruction-item"] = true,
	["rail-planner"] = true,
	["upgrade-item"] = true,
	["blueprint-book"] = true,
	["custom-input"] = true,
	shortcut = true,
}

--- Finds every `data.raw` group (excluding `excludedGroups`) that contains a prototype
--- with the given name. Used to locate item-like prototypes that do not live in
--- `data.raw.item` (e.g. tools, modules, space-location items).
---@param itemName string internal name of the item
---@return string[]? groupNames nil when the name was not found anywhere
local function findItemByName(itemName)
	local groupNames = nil
	for groupName, group in pairs(data.raw) do
		if not excludedGroups[groupName] then
			for _, entry in pairs(group) do
				if entry.name == itemName then
					groupNames = groupNames or {}
					table.insert(groupNames, groupName)
				end
			end
		end
	end
	return groupNames
end

--- Whether a prototype is eligible for recipe scaling. A prototype is excluded when it
--- belongs to an excluded group or carries the `not-stackable` flag (scaling those
--- recipes is prevented separately by `recipeHasUnscalableItems`).
---@param item table a prototype with `.type` and optional `.flags`
---@return boolean
local function isScalableItem(item)
	if excludedGroups[item.type] then
		return false
	end
	for _, flag in ipairs(item.flags or {}) do
		if flag == "not-stackable" then
			return false
		end
	end
	return true
end

--- Resolves a prototype name to a scalable item prototype: first as a plain item,
--- otherwise by searching all non-excluded `data.raw` groups and validating what is
--- found there (the name may live in another group, e.g. tools or modules).
---@param name string prototype name of an item-ish recipe entry
---@return boolean true when the prototype exists and is scalable
local function isScalableItemPrototype(name)
	if data.raw.item[name] then
		return isScalableItem(data.raw.item[name])
	end
	local groupNames = findItemByName(name)
	if not groupNames then
		return false
	end
	for _, groupName in pairs(groupNames) do
		if not isScalableItem(data.raw[groupName][name]) then
			return false
		end
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Non-stackable item protection
-- ---------------------------------------------------------------------------

--- Cache of item-name → item-prototype lookups. `false` means "not found" (nil cannot
--- be stored in the table without changing lookup semantics).
local itemPrototypeCache = {}

--- Looks an item up across all item-ish prototype groups (as listed by the engine's
--- `defines.prototypes["item"]`), regardless of which concrete group it belongs to.
---@param itemName string internal name of the item
---@return table? itemPrototype the first matching item-ish prototype, or nil when unknown
local function findItemPrototypeAnywhere(itemName)
	local cached = itemPrototypeCache[itemName]
	if cached ~= nil then
		return cached or nil
	end
	local found = nil
	for typeName in pairs(defines.prototypes["item"]) do
		local group = data.raw[typeName]
		if group and group[itemName] then
			found = group[itemName]
			break
		end
	end
	itemPrototypeCache[itemName] = found or false
	return found
end

--- Non-stackable items (stack_size <= 1 or the `not-stackable` flag) can never appear
--- more than once in a single craft, so any recipe using them cannot be batched.
---@param itemPrototype table? an item prototype, or nil when it could not be found
---@return boolean
local function isNonStackable(itemPrototype)
	if not itemPrototype then
		return true
	end
	for _, flag in ipairs(itemPrototype.flags or {}) do
		if flag == "not-stackable" then
			return true
		end
	end
	local stackSize = itemPrototype.stack_size
	return not stackSize or stackSize <= 1
end

--- The engine rejects item products of non-stackable items when their max count
--- exceeds 1 (e.g. "Recipe item-product X is not stackable but has a max count of N").
--- Such product entries must stay unscaled, and a recipe whose products are ALL
--- non-stackable cannot be batched at all (nothing would change except time/input).
---@param recipe table recipe prototype with results and ingredients
---@return boolean true when every product of this recipe is a non-stackable item
local function allProductsNonStackable(recipe)
	for _, entry in pairs(recipe.results or {}) do
		-- Non-item products (fluids etc.) and stackable items can all be scaled.
		if entry.type ~= "item" or not isNonStackable(findItemPrototypeAnywhere(entry.name)) then
			return false
		end
	end
	return true
end

--- Conservative pre-check (the default behaviour): the recipe is skipped entirely when
--- ANY of its products or ingredients is a non-stackable item whose scaled count would
--- exceed 1 (the engine hard-errors for products in that case).
---@param recipe table recipe prototype with results and ingredients
---@param multiplier number multiplier about to be applied
---@return boolean true when scaling this recipe by `multiplier` would crash recipe setup
local function recipeHasUnscalableItems(recipe, multiplier)
	---@param entries table? results or ingredients of the recipe
	local function checkEntries(entries)
		for _, entry in pairs(entries or {}) do
			if entry.type == "item" and isNonStackable(findItemPrototypeAnywhere(entry.name)) then
				-- The engine validates max count = amount_max + extra_count_fraction <= 1,
				-- so scaling is legal when the result lands exactly on 1.
				local count = (entry.amount_max or entry.amount or 0) + (entry.extra_count_fraction or 0)
				if count * multiplier > 1 then
					return true
				end
			end
		end
		return false
	end
	return checkEntries(recipe.results) or checkEntries(recipe.ingredients)
end

-- ---------------------------------------------------------------------------
-- Recipe scaling
-- ---------------------------------------------------------------------------

--- Whether the recipe belongs to the `recycling` category (those get their own
--- dedicated multiplier).
---@param recipeName string internal name of the recipe
---@return boolean
local function isRecyclingRecipe(recipeName)
	local recipe = data.raw.recipe[recipeName]
	for _, category in pairs(recipe and recipe.categories or {}) do
		if category == "recycling" then
			return true
		end
	end
	return false
end

--- Scales the amounts of one recipe result list by `multiplier`, respecting
--- `MAX_AMOUNT`. Products may use min/max ranges and fractional counts; all of the
--- count-related fields are scaled, the stat-related ones (`ignored_by_*`) too so
--- the per-craft statistics stay proportional.
---@param results table[]? deep copy of the recipe's results
---@param multiplier number
local function scaleRecipeResults(results, multiplier)
	for _, result in pairs(results or {}) do
		-- With the mixed-products toggle on, non-stackable item products keep their
		-- original count (max count 1 stays legal). With it off, the whole recipe was
		-- already skipped by `recipeHasUnscalableItems` before this point, so every
		-- remaining product can be scaled safely.
		local isNonStackableProduct = modSettingsScaleMixedNonStackable and result.type == "item" and
			isNonStackable(findItemPrototypeAnywhere(result.name))
		if not isNonStackableProduct then
			result.amount = result.amount and math.min(MAX_AMOUNT, result.amount * multiplier)
			result.amount_min = result.amount_min and math.min(MAX_AMOUNT, result.amount_min * multiplier)
			result.amount_max = result.amount_max and math.min(MAX_AMOUNT, result.amount_max * multiplier)
			result.ignored_by_stats = result.ignored_by_stats and result.ignored_by_stats * multiplier
			result.ignored_by_productivity = result.ignored_by_productivity and
				result.ignored_by_productivity * multiplier
			result.extra_count_fraction = result.extra_count_fraction and result.extra_count_fraction * multiplier
		else
			log("Left non-stackable product '" .. result.name .. "' unscaled (stays at max count 1).")
		end
	end
end

--- Scales the amounts of one recipe ingredient list by `multiplier`, respecting
--- `MAX_AMOUNT`.
---@param ingredients table[]? deep copy of the recipe's ingredients
---@param multiplier number
local function scaleRecipeIngredients(ingredients, multiplier)
	for _, ingredient in pairs(ingredients or {}) do
		ingredient.amount = math.min(MAX_AMOUNT, ingredient.amount * multiplier)
	end
end

--- Scales one recipe's results, ingredients and crafting time by `multiplier`.
--- Depending on `re-enable-add-recipe`, either the recipe itself or a `<name>-bulk`
--- copy of it is scaled.
---@param itemName string internal name of the item whose recipe should be scaled
---@param multiplier number multiplier for scaling the recipe
local function updateRecipeAmounts(itemName, multiplier)
	local original = data.raw.recipe[itemName]
	if not original then
		report("Warning: recipe name '" .. itemName .. "' does not exist.")
		return
	end
	local effectiveMultiplier = isRecyclingRecipe(itemName) and modSettingsRecyclingMultiplier or multiplier

	if effectiveMultiplier > 1 then
		-- Recipes whose products are ALL non-stackable items can never be batched.
		if allProductsNonStackable(original) then
			report("Skipped " .. itemName ..
				": all products are non-stackable items, batch scaling has no effect.")
			return
		end
		-- With the mixed-products toggle off, the conservative rule applies: skip the
		-- whole recipe when any non-stackable item's scaled count would exceed 1.
		if not modSettingsScaleMixedNonStackable and recipeHasUnscalableItems(original, effectiveMultiplier) then
			report("Skipped " .. itemName .. ": contains non-stackable items and cannot be scaled by " ..
				effectiveMultiplier .. " (enable 'Scale recipes with mixed stackability products' to scale the " ..
				"stackable parts anyway).")
			return
		end
	end

	local recipe
	if modSettingsAddRecipes then
		---@type table
		local bulkRecipe = util.table.deepcopy(original)
		bulkRecipe.name = itemName .. "-bulk"
		-- The engine only shows localised names for known recipe names, so fall back
		-- ("?") to the original recipe's strings for the copy.
		bulkRecipe.localised_name = { "?", { "", { "entity-name." .. itemName } }, { "item-name." .. itemName } }
		bulkRecipe.localised_description =
			{ "?", { "", { "recipe-description." .. itemName } }, { "recipe-description." .. itemName } }
		data.raw.recipe[bulkRecipe.name] = bulkRecipe
		recipe = bulkRecipe
	else
		recipe = original
	end
	if not recipe.results or not recipe.ingredients then
		return
	end

	-- Scale on deep copies so partially-scaled recipes never leak to other prototypes
	-- that share the same result/ingredient tables.
	local scaledResults = util.table.deepcopy(recipe.results)
	scaleRecipeResults(scaledResults, effectiveMultiplier)
	recipe.results = scaledResults

	local scaledIngredients = util.table.deepcopy(recipe.ingredients)
	scaleRecipeIngredients(scaledIngredients, effectiveMultiplier)
	recipe.ingredients = scaledIngredients

	-- Crafting time is scaled along with the batch so the throughput stays the same
	-- per craft as before (0.5 ticks is the engine default when unset).
	recipe.energy_required = (recipe.energy_required or 0.5) * effectiveMultiplier

	log("Scaled " .. recipe.name .. " by " .. effectiveMultiplier)
end

-- ---------------------------------------------------------------------------
-- Criterion 1: scale recipes for whole prototype groups ("re-item-types")
-- ---------------------------------------------------------------------------

--- Builds a `itemName → multiplier` map from the "re-item-types" setting. For every
--- named `data.raw` group, all scalable prototypes of that group claim their recipes;
--- prototypes that do not resolve to plain items are validated first (they may be
--- item-like entries from other groups) and skipped when invalid.
---@return table<string, number> itemNames
local function collectItemNamesFromTypes()
	local itemNames = {}
	for itemTypeName, multiplier in pairs(modSettingsItemTypes) do
		if itemTypeName == "recipe" then
			-- Scaling the "recipe" group means scaling the recipes named like the recipe
			-- itself, but only when all of their items resolve to scalable prototypes.
			for recipeName, recipe in pairs(data.raw.recipe) do
				local isValid = true
				for _, entry in pairs(recipe.ingredients or {}) do
					---@diagnostic disable-next-line: param-type-mismatch
					if entry.type == "item" and not isScalableItemPrototype(entry.name) then
						report("Ingredient " .. entry.name .. " of recipe " .. recipeName .. " is invalid")
						isValid = false
						break
					end
				end
				for _, entry in pairs(recipe.results or {}) do
					if entry.type == "research-progress" then
						isValid = false
						break
					end
					---@diagnostic disable-next-line: param-type-mismatch
					if entry.type == "item" and not isScalableItemPrototype(entry.name) then
						report("Product " .. entry.name .. " of recipe " .. recipeName .. " is invalid")
						isValid = false
						break
					end
				end
				if isValid then
					itemNames[recipeName] = multiplier
				end
			end
		elseif data.raw[itemTypeName] then
			for itemName, item in pairs(data.raw[itemTypeName]) do
				if isScalableItem(item) then
					itemNames[itemName] = multiplier
				end
			end
		else
			report("Warning: item type '" .. itemTypeName .. "' does not exist.")
		end
	end
	return itemNames
end

if modSettingsEnableType then
	runFailSafe("criterion 1: item types (re-item-types)", function()
		local itemNamesFromTypes = collectItemNamesFromTypes()
		for itemName, multiplier in pairs(itemNamesFromTypes) do
			if not modSettingsItemNames[itemName] then
				updateRecipeAmounts(itemName, multiplier)
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Criterion 2: scale recipes by explicit item name ("re-item-names")
-- ---------------------------------------------------------------------------

if modSettingsEnableName then
	runFailSafe("criterion 2: item names (re-item-names)", function()
		for itemName, multiplier in pairs(modSettingsItemNames) do
			updateRecipeAmounts(itemName, multiplier)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Criterion 3: scale recipes by subgroup ("re-sub-groups")
-- ---------------------------------------------------------------------------

if modSettingsEnableSubgroup then
	runFailSafe("criterion 3: subgroups (re-sub-groups)", function()
		for recipeName, recipe in pairs(data.raw.recipe) do
			local multiplier = recipe.subgroup and modSettingsSubGroups[recipe.subgroup]
			-- Explicitly named recipes keep their name-based multiplier (or stay unscaled).
			if multiplier and not (modSettingsEnableName and modSettingsItemNames[recipeName]) then
				updateRecipeAmounts(recipeName, multiplier)
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Fluid flow and cargo pod
-- ---------------------------------------------------------------------------

-- Bigger machine fluid volumes so fluid throughput scales up with the recipes.
if modSettingsFluidFlowMultiplier > 0 then
	for _, typeName in pairs({ "assembling-machine", "furnace" }) do
		for _, machine in pairs(data.raw[typeName]) do
			if machine.fluid_box then
				machine.fluid_box.volume = math.ceil(machine.fluid_box.volume * modSettingsFluidFlowMultiplier)
			end
			for _, fluidBox in pairs(machine.fluid_boxes or {}) do
				fluidBox.volume = math.ceil(fluidBox.volume * modSettingsFluidFlowMultiplier)
			end
		end
	end
end

local cargoPod = data.raw["cargo-pod"]["cargo-pod"]
if cargoPod then
	cargoPod.inventory_size = cargoPod.inventory_size * 100
end

-- ---------------------------------------------------------------------------
-- Startup log carrier prototype
-- ---------------------------------------------------------------------------

-- The control stage cannot read factorio-current.log, so notable startup messages
-- (warnings, skipped recipes, errors) are smuggled to the runtime stage inside a
-- hidden item prototype's localised name: {"", msg1, msg2, ...}. control.lua
-- broadcasts one message per line after a map is loaded.
if #startupLogMessages > 0 then
	data:extend({
		{
			type = "item",
			name = "recipe-multiplier-startup-log",
			icon = "__base__/graphics/icons/iron-plate.png",
			icon_size = 64,
			stack_size = 1,
			-- "hidden" is a valid item flag; the stub's flag union is incomplete.
			---@diagnostic disable-next-line: assign-type-mismatch
			flags = { "hidden" },
			-- First element "" makes this a concatenation; every following string is
			-- one startup message, printed as its own chat line by control.lua.
			localised_name = { "", table.unpack(startupLogMessages) },
		},
	})
end
