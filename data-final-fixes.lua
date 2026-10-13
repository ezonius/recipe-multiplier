--- Recipe Multiplier — data-final-fixes.
---
--- Scales recipe results/ingredients (and crafting time) so that one craft yields
--- `multiplier` times as much. Which recipes get scaled is controlled by three
--- independent criteria (each toggleable via startup settings):
--- 1. "type"      — every prototype of a given data.raw group (e.g. all `item`s),
---                    matching by the group name or `type=multiplier` in the setting string.
---                    Entries naming a recipe-category prototype instead (e.g. "recycling")
---                    claim every recipe whose `categories` include that category.
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
local modSettingsRecyclingInheritSource = not not settings.startup["re-recycling-inherit-source"].value
local modSettingsAddRecipes = not not settings.startup["re-enable-add-recipe"].value
local modSettingsFluidFlowMultiplier = parseNumberSetting("re-fluid-flow-multiplier", 10)

local modSettingsEnableType = settings.startup["re-enable-type"].value
local modSettingsEnableName = settings.startup["re-enable-name"].value
local modSettingsEnableSubgroup = settings.startup["re-enable-subgroup"].value
local modSettingsScaleMixedNonStackable = not not settings.startup["re-scale-mixed-nonstackable"].value
--- "scaled-amount": keep the chance, multiply the output amount (30% of 1 × 11 → 30% of 11).
--- "expected-value": split into a guaranteed part and a remainder chance
--- (30% of 1 × 11 → 3 guaranteed + 30% chance of 1).
local modSettingsProbabilityHandling = settings.startup["re-probability-handling"].value or "scaled-amount"
--- Minimum crafting time in seconds: recipes without an explicit per-name multiplier
--- ("iron-plate=100") are scaled by at least ceil(minTime / craftTime) so no batch
--- finishes faster than this. 0 disables the feature.
--- When on, recipes claimed explicitly via a recipe-category entry (e.g. "recycling=10")
--- are NOT exempt from the crafting-time minimum; the time-based minimum can then raise
--- their effective multiplier above the category's stated value.
local modSettingsMinTimeAppliesToCategoryExplicit = not not settings.startup["re-min-crafting-time-category-explicit"].value
local modSettingsMinCraftingTime = parseNumberSetting("re-min-crafting-time", 0)

-- ---------------------------------------------------------------------------
-- Startup log broadcast (shown in-game after loading a map; see control.lua)
-- ---------------------------------------------------------------------------

--- Notable startup messages (warnings, skips, errors). These are embedded into a
--- hidden item prototype's localised name so the control stage can broadcast them
--- after a game is loaded — data-stage `log()` output is otherwise only visible in
--- factorio-current.log.
local startupLogMessages = {}
--- Number of notable messages dropped because the broadcast queue is full. Localised
--- strings are limited to 20 parameters, so the queue cannot grow unbounded (heavily
--- modded games can produce thousands of skip messages).
local startupLogDropped = 0

--- Logs a notable message and queues it for the in-game startup broadcast. Only
--- user-facing problems belong here: strings the user typed that could not be
--- parsed or do not resolve to anything, and hard errors. Internal per-recipe
--- notes (skips, invalid modded entries) only go to factorio-current.log via
--- `note()`, so the in-game broadcast stays short and relevant.
---@param message string single-line message (newlines would break the per-line broadcast)
local function report(message)
	log(message)
	if #startupLogMessages < 15 then
		table.insert(startupLogMessages, message)
	else
		startupLogDropped = startupLogDropped + 1
	end
end

--- Logs an internal note to factorio-current.log only — never broadcast in-game.
---@param message string single-line message
local function note(message)
	log(message)
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
---@return table<string, number> itemNames
---@return table<string, boolean> explicitNames set of names that had an explicit "=number"
local function parseSettingString(settingString, settingName)
	local result = {}
	local explicit = {}
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
			local multiplier = tonumber(numeration)
			if multiplier then
				result[typeOrName] = multiplier
				explicit[typeOrName] = true
			else
				result[typeOrName] = modSettingsRecipeMultiplier or 1
			end
		end
	end
	return result, explicit
end

---@diagnostic disable-next-line: param-type-mismatch
local modSettingsItemTypes, modSettingsItemTypeExplicit = parseSettingString(
	settings.startup["re-item-types"].value, "re-item-types")
---@type table<string, number>
---@diagnostic disable-next-line: param-type-mismatch
local modSettingsItemNames, modSettingsItemNameExplicit = parseSettingString(
	settings.startup["re-item-names"].value, "re-item-names")
---@type table<string, number>
---@diagnostic disable-next-line: param-type-mismatch
local modSettingsSubGroups, modSettingsSubGroupExplicit = parseSettingString(
	settings.startup["re-sub-groups"].value, "re-sub-groups")

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

--- Resolves the multiplier a recycling recipe inherits from its source item, when the
--- source item was scaled with an explicit "name=number" entry. Engine-generated recycling
--- recipes are named "<item>-recycling"; as a fallback, the recycled item is looked up as
--- the recipe's first item result.
---@param recipeName string internal name of the recycling recipe
---@param claims table<string, Claim> claim map built from all criteria
---@return number? sourceMultiplier nil when no explicitly-scaled source item could be found
local function findRecyclingSourceMultiplier(recipeName, claims)
	local sourceName = recipeName:match("^(.+)%-recycling$")
	local sourceClaim = sourceName and claims[sourceName]
	if not sourceClaim or not sourceClaim.explicit then
		local recipe = data.raw.recipe[recipeName]
		for _, entry in pairs(recipe and recipe.results or {}) do
			if entry.type == "item" and claims[entry.name] and claims[entry.name].explicit then
				sourceClaim = claims[entry.name]
				break
			end
		end
	end
	return sourceClaim and sourceClaim.explicit and sourceClaim.multiplier or nil
end

--- Scales the count fields of one product/ingredient entry by `multiplier`, respecting
--- `MAX_AMOUNT`. The stat-related fields (`ignored_by_*`) are scaled too so the
--- per-craft statistics stay proportional.
--- `extra_count_fraction` (per-craft chance of one additional product, must stay <= 1)
--- is split like the expected-value probability handling: after scaling by `multiplier`,
--- its integer part becomes guaranteed extra products folded into the count fields and
--- only the fractional remainder stays as the chance.
---@param entry table product or ingredient entry
---@param multiplier number
local function scaleEntryCounts(entry, multiplier)
	entry.amount = entry.amount and math.min(MAX_AMOUNT, entry.amount * multiplier)
	entry.amount_min = entry.amount_min and math.min(MAX_AMOUNT, entry.amount_min * multiplier)
	entry.amount_max = entry.amount_max and math.min(MAX_AMOUNT, entry.amount_max * multiplier)
	-- The ignored_by_* values are engine-side amounts too and share the same 65535 limit
	-- (they scale proportionally with the counts, so clamping them together keeps the
	-- stats ratios intact for huge multipliers).
	entry.ignored_by_stats = entry.ignored_by_stats and
		math.min(MAX_AMOUNT, entry.ignored_by_stats * multiplier)
	entry.ignored_by_productivity = entry.ignored_by_productivity and
		math.min(MAX_AMOUNT, entry.ignored_by_productivity * multiplier)
	local extraCountFraction = entry.extra_count_fraction
	if extraCountFraction and extraCountFraction > 0 then
		-- Split the scaled chance: the integer part becomes guaranteed extra products
		-- (folded into the already-scaled counts), the fraction stays as the chance.
		local guaranteedExtra = math.floor(extraCountFraction * multiplier)
		local remainder = extraCountFraction * multiplier - guaranteedExtra
		entry.extra_count_fraction = remainder > 0 and remainder or nil
		if guaranteedExtra > 0 then
			entry.amount = entry.amount and math.min(MAX_AMOUNT, entry.amount + guaranteedExtra)
			entry.amount_min = entry.amount_min and math.min(MAX_AMOUNT, entry.amount_min + guaranteedExtra)
			entry.amount_max = entry.amount_max and math.min(MAX_AMOUNT, entry.amount_max + guaranteedExtra)
		end
	end
end

--- Scales the amounts of one recipe result list by `multiplier`, respecting
--- `MAX_AMOUNT`. Products may use min/max ranges and fractional counts.
---
--- Chance-based products (`probability` < 1) are handled according to the
--- "re-probability-handling" setting:
--- * "scaled-amount" (default): the chance stays the same, the output amount is
---   multiplied (30% chance of 1 × 11 → 30% chance of 11).
--- * "expected-value": the entry is split so the expected output stays proportional
---   (30% chance of 1 × 11 → guaranteed 3 + 30% chance of 1 extra). The whole
---   probability (or independent_probability) × multiplier is converted: the integer part becomes a guaranteed
---   (probability-free) entry, the fractional part stays as the chance for one
---   original-sized output.
---@param results table[]? deep copy of the recipe's results
---@param multiplier number
local function scaleRecipeResults(results, multiplier)
	results = results or {}
	-- Iterate backwards so guaranteed entries inserted at `i + 1` are not visited twice.
	for i = #results, 1, -1 do
		local result = results[i]
		-- With the mixed-products toggle on, non-stackable item products keep their
		-- original count (max count 1 stays legal). With it off, the whole recipe was
		-- already skipped by `recipeHasUnscalableItems` before this point, so every
		-- remaining product can be scaled safely.
		local isNonStackableProduct = modSettingsScaleMixedNonStackable and result.type == "item" and
			isNonStackable(findItemPrototypeAnywhere(result.name))
		if isNonStackableProduct then
			log("Left non-stackable product '" .. result.name .. "' unscaled (stays at max count 1).")
		elseif modSettingsProbabilityHandling == "expected-value" and
			((result.probability or 1) < 1 or (result.independent_probability or 1) < 1) then
			-- Products may declare the chance either as `probability` (roll shared with
			-- other products via probability/override_probabilities semantics) or as
			-- `independent_probability` (roll independent of other products, e.g.
			-- oxide-asteroid-crushing). Both are converted the same way.
			local probField = result.probability and "probability" or "independent_probability"
			local scaledProbability = result[probField] * multiplier
			local guaranteed = math.floor(scaledProbability)
			local fraction = scaledProbability - guaranteed
			if guaranteed > 0 then
				-- The integer part of probability × multiplier becomes a guaranteed output of
				-- `guaranteed` full (range-scaled) batches, with no probability attached.
				local guaranteedEntry = util.table.deepcopy(result)
				guaranteedEntry.probability = nil
				guaranteedEntry.independent_probability = nil
				scaleEntryCounts(guaranteedEntry, guaranteed)
				table.insert(results, i + 1, guaranteedEntry)
			end
			if fraction > 0 then
				-- The fractional part stays as a chance for one original-sized output; its
				-- count fields are deliberately left unscaled (the expected value of this
				-- branch is already fraction × original output).
				result[probField] = fraction
			else
				table.remove(results, i)
			end
		else
			scaleEntryCounts(result, multiplier)
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
---@param userInitiated boolean? true when the recipe name came directly from the
--- "re-item-names" setting — a missing recipe is then a user typo and is broadcast
--- in-game. Names from other criteria are engine/mod internals and only logged.
---@param explicitMultiplier boolean? true when the recipe is exempt from the crafting-time
--- minimum (explicit "name=number" entries, unless overridden by
--- "re-min-crafting-time-category-explicit" for recipe-category claims)
local function updateRecipeAmounts(itemName, multiplier, userInitiated, explicitMultiplier)
	local original = data.raw.recipe[itemName]
	if not original then
		local message = "Warning: recipe name '" .. itemName .. "' does not exist."
		if userInitiated then
			report(message)
		else
			note(message)
		end
		return
	end
	local effectiveMultiplier = multiplier

	-- Crafting-time minimum: recipes without an explicit "name=number" multiplier are
	-- scaled by at least ceil(minTime / craftTime), so no batch is faster than the
	-- configured minimum duration. Only integer multipliers are used.
	if modSettingsMinCraftingTime > 0 and not explicitMultiplier then
		local craftTime = original.energy_required or 0.5
		local timeMultiplier = math.ceil(modSettingsMinCraftingTime / craftTime)
		effectiveMultiplier = math.max(effectiveMultiplier, timeMultiplier)
		if timeMultiplier > 1 then
			note("Crafting-time minimum raised " .. itemName .. " to multiplier " .. effectiveMultiplier ..
				" (crafting time " .. craftTime .. "s, minimum " .. modSettingsMinCraftingTime .. "s).")
		end
	end

	if effectiveMultiplier > 1 then
		-- Recipes whose products are ALL non-stackable items can never be batched.
		if allProductsNonStackable(original) then
			note("Skipped " .. itemName ..
				": all products are non-stackable items, batch scaling has no effect.")
			return
		end
		-- With the mixed-products toggle off, the conservative rule applies: skip the
		-- whole recipe when any non-stackable item's scaled count would exceed 1.
		if not modSettingsScaleMixedNonStackable and recipeHasUnscalableItems(original, effectiveMultiplier) then
			note("Skipped " .. itemName .. ": contains non-stackable items and cannot be scaled by " ..
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
--- Entries naming a recipe-category prototype (e.g. "recycling") are also tracked so the
--- crafting-time minimum can optionally apply to their explicit multipliers.
---@return table<string, number> itemNames
---@return table<string, boolean> explicitNames names whose group had an explicit "=number" multiplier
---@return table<string, boolean> categoryExplicitNames names explicitly claimed via a recipe-category entry
local function collectItemNamesFromTypes()
	local itemNames = {}
	local explicitNames = {}
	local categoryExplicitNames = {}
	for itemTypeName, multiplier in pairs(modSettingsItemTypes) do
		local isExplicit = not not modSettingsItemTypeExplicit[itemTypeName]
		if itemTypeName == "recipe" then
			-- Scaling the "recipe" group means scaling the recipes named like the recipe
			-- itself, but only when all of their items resolve to scalable prototypes.
			for recipeName, recipe in pairs(data.raw.recipe) do
				local isValid = true
				for _, entry in pairs(recipe.ingredients or {}) do
					---@diagnostic disable-next-line: param-type-mismatch
					if entry.type == "item" and not isScalableItemPrototype(entry.name) then
						note("Ingredient " .. entry.name .. " of recipe " .. recipeName .. " is invalid")
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
						note("Product " .. entry.name .. " of recipe " .. recipeName .. " is invalid")
						isValid = false
						break
					end
				end
				if isValid then
					itemNames[recipeName] = multiplier
					explicitNames[recipeName] = isExplicit
				end
			end
		elseif data.raw[itemTypeName] then
			for itemName, item in pairs(data.raw[itemTypeName]) do
				if isScalableItem(item) then
					itemNames[itemName] = multiplier
					explicitNames[itemName] = isExplicit
				end
			end
		elseif data.raw["recipe-category"][itemTypeName] then
			-- A recipe-category name (e.g. "recycling" or "macerating") claims every recipe
			-- whose `categories` list includes it. This is how recycling recipes are targeted
			-- since the dedicated recycling-multiplier setting was deprecated.
			for recipeName, recipe in pairs(data.raw.recipe) do
				for _, category in pairs(recipe.categories or {}) do
				if category == itemTypeName then
					itemNames[recipeName] = multiplier
					explicitNames[recipeName] = isExplicit
					if isExplicit then
						categoryExplicitNames[recipeName] = true
					end
					break
					end
				end
			end
		else
			report("Warning: item type '" .. itemTypeName .. "' does not exist.")
		end
	end
	return itemNames, explicitNames, categoryExplicitNames
end

-- ---------------------------------------------------------------------------
-- Claim resolution: each criterion adds claims (recipeName → multiplier) and an
-- explicit claim always replaces an implicit one instead of stacking on top of
-- it. After all criteria have run, every recipe is scaled exactly once with the
-- winning claim, so multipliers from different criteria can never multiply up.
-- ---------------------------------------------------------------------------
--- A claim on one recipe: which multiplier to use and how it was specified.
---@class Claim
---@field multiplier number
---@field explicit boolean true when the multiplier came from an explicit "name=number" entry
---@field userInitiated boolean? true when the name came directly from a user setting
---@field fromCategory boolean? true when the claim came from an explicit recipe-category entry (e.g. "recycling=10")

--- Merges a claim into `claims`, applying the precedence rules:
--- * an explicit claim ("=number") replaces any existing implicit claim,
--- * an implicit claim never replaces an existing explicit one,
--- * two implicit claims keep the existing one (criterion priority: types → names → subgroups).
---@param claims table<string, Claim>
---@param recipeName string
---@param multiplier number
---@param explicit boolean
---@param userInitiated boolean?
local function addClaim(claims, recipeName, multiplier, explicit, userInitiated)
	local existing = claims[recipeName]
	if existing then
		if existing.explicit or not explicit then
			return
		end
		userInitiated = existing.userInitiated or userInitiated
	end
	claims[recipeName] = { multiplier = multiplier, explicit = explicit, userInitiated = userInitiated }
end

local claims = {}

if modSettingsEnableType then
	runFailSafe("criterion 1: item types (re-item-types)", function()
		local itemNamesFromTypes, explicitNamesFromTypes, categoryExplicitFromTypes = collectItemNamesFromTypes()
		for itemName, multiplier in pairs(itemNamesFromTypes) do
			addClaim(claims, itemName, multiplier, explicitNamesFromTypes[itemName])
		end
		-- Mark claims that came from explicit recipe-category entries so the crafting-time
		-- minimum can optionally apply to them (see "re-min-crafting-time-category-explicit").
		for recipeName in pairs(categoryExplicitFromTypes) do
			if claims[recipeName] then
				claims[recipeName].fromCategory = true
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
			addClaim(claims, itemName, multiplier, modSettingsItemNameExplicit[itemName], true)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Criterion 3: scale recipes by subgroup ("re-sub-groups")
-- ---------------------------------------------------------------------------

if modSettingsEnableSubgroup then
	runFailSafe("criterion 3: subgroups (re-sub-groups)", function()
		-- Valid subgroups are item-subgroup prototypes; recipes may also reference subgroups
		-- from other item-subgroup sets. Anything not matching a single recipe's subgroup is
		-- reported as a likely typo (e.g. an item/recipe name entered in the wrong setting).
		local knownSubgroups = {}
		for name in pairs(data.raw["item-subgroup"] or {}) do
			knownSubgroups[name] = true
		end
		for _, recipe in pairs(data.raw.recipe) do
			if recipe.subgroup then
				knownSubgroups[recipe.subgroup] = true
			end
		end
		for subgroupName in pairs(modSettingsSubGroups) do
			if not knownSubgroups[subgroupName] then
				report("Warning: sub group '" .. subgroupName ..
					"' in setting 're-sub-groups' does not exist (no item subgroup and no recipe uses it). " ..
					"Note: this setting matches sub groups, not item/recipe names — explicit per-name " ..
					"multipliers like 'empty-steel-barrel=30' belong in the 're-item-names' setting.")
			end
		end
		for recipeName, recipe in pairs(data.raw.recipe) do
			local multiplier = recipe.subgroup and modSettingsSubGroups[recipe.subgroup]
			if multiplier then
				-- An explicit subgroup multiplier ("empty-steel-barrel=30") replaces an implicit
				-- claim from another criterion (e.g. the type criterion's global multiplier) instead
				-- of being applied on top of it. Explicitly named recipes keep theirs.
				addClaim(claims, recipeName, multiplier, modSettingsSubGroupExplicit[recipe.subgroup])
			end
		end
	end)
end

-- Apply exactly one scale pass per recipe, with the winning claim.
for recipeName, claim in pairs(claims) do
	runFailSafe("scaling " .. recipeName, function()
		local multiplier = claim.multiplier
		-- Recycling recipes: an explicit claim on the recipe itself wins; otherwise an
		-- explicitly-scaled source item is inherited (toggleable); otherwise the normal
		-- implicit claim multiplier is used.
		if isRecyclingRecipe(recipeName) and not claim.explicit then
			local sourceMultiplier = modSettingsRecyclingInheritSource and
				findRecyclingSourceMultiplier(recipeName, claims)
			if sourceMultiplier then
				note("Recycling recipe " .. recipeName .. " inherits multiplier " .. sourceMultiplier ..
					" from its explicitly-scaled source item.")
				multiplier = sourceMultiplier
			end
		end
		-- An explicit claim on the recipe itself is normally exempt from the time minimum,
		-- but explicit recipe-category entries (e.g. "recycling=10") can be made subject to
		-- it via "re-min-crafting-time-category-explicit".
		local timeMinExempt = claim.explicit and
			not (modSettingsMinTimeAppliesToCategoryExplicit and claim.fromCategory)
		updateRecipeAmounts(recipeName, multiplier, claim.userInitiated, timeMinExempt)
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
	if startupLogDropped > 0 then
		table.insert(startupLogMessages, "... and " .. startupLogDropped ..
			" more messages, suppressed here — see factorio-current.log for the full list.")
	end
	data:extend({
		{
			type = "item",
			name = "recipe-multiplier-startup-log",
			icon = "__base__/graphics/icons/iron-plate.png",
			icon_size = 64,
			stack_size = 1,
			-- In 2.0 "hidden" is a boolean property, not an item flag.
			hidden = true,
			-- First element "" makes this a concatenation; every following string is
			-- one startup message, printed as its own chat line by control.lua.
			localised_name = { "", table.unpack(startupLogMessages) },
		},
	})
end
