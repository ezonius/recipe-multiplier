--- Using LuaCATS annotations
require "util"
local MAX_INGREDIENT_AMOUNT = 65535
local modSettingsRecipeMultiplier = tonumber(settings.startup["re-amount-multiplier"].value)
local modSettingsRecyclingMultiplier = tonumber(settings.startup["re-recycling-amount-multiplier"].value)
local modSettingsAddRecipes = not not settings.startup["re-enable-add-recipe"].value
local fluidFlowMultiplier = tonumber(settings.startup["re-fluid-flow-multiplier"].value)
local possibleFlags = { "draw-logistic-overlay", "hidden", "always-show", "hide-from-bonus-gui", "hide-from-fuel-tooltip",
    "not-stackable", "can-extend-inventory", "primary-place-result", "mod-openable", "only-in-cursor", "spawnable" }
local excludedGroups = {
    recipe = true,
    achievement = true,
    corpse = true,
    explosion = true,
    ['ambient-sound'] = true,
    ["delayed-active-trigger"] = true,
    ["noise-expression"] = true,
    ["noise-function"] = true,
    ["optimized-decorative"] = true,
    ["optimized-particle"] = true,
    ["smoke-with-trigger"] = true,
    ["technology"] = true,
    ["tile"] = true,
    ["virtual-signal"] = true,
    ["armor"] = true,
    ["deconstruction-item"] = true,
    ["rail-planner"] = true,
    ["upgrade-item"] = true,
    ["blueprint-book"] = true,
    ["custom-input"] = true,
    ["shortcut"] = true,
}

---@param itemName string internal name of the item
---@return string[]?
local function findItemByName(itemName)
    local results = nil
    for groupName, group in pairs(data.raw) do
        if not excludedGroups[groupName] then
            for _, entry in pairs(group) do
                if entry.name == itemName then
                    if not results then
                        results = {}
                    end
                    table.insert(results, groupName)
                end
            end
        end
    end
    return results
end

local function parseStringToTable(inputString)
    local resultTable = {}
    for item in inputString:gmatch("[^%s,]+") do
        resultTable[item] = item
    end
    return resultTable
end

---@param settingString string The parsable string in the format "typeOrName=CustomMultiplier, typeOrName2=CustomMultiplier2"
local function parseSettingString(settingString)
    local result = {}
    for entry in settingString:gmatch("[^%s,]+") do
        local typeOrName, numeration = entry:match("([^=]+)=?(.*)")
        if typeOrName then
            result[typeOrName] = tonumber(numeration) or modSettingsRecipeMultiplier or 1
        end
    end
    return result
end

local function tableContains(tbl, element)
    for _, value in ipairs(tbl) do
        if value == element then
            return true
        end
    end
    return false
end

---@diagnostic disable-next-line: param-type-mismatch
local modSettingsItemTypes = parseSettingString(settings.startup["re-item-types"].value)
---@diagnostic disable-next-line: param-type-mismatch
local modSettingsItemNames = parseSettingString(settings.startup["re-item-names"].value)
---@diagnostic disable-next-line: param-type-mismatch
local modSettingsSubGroups = parseSettingString(settings.startup["re-sub-groups"].value)

local function processItemFlags(item)
    if excludedGroups[item.type] then
        return false
    end
    if item.flags then
        for _, flag in ipairs(item.flags) do
            if tableContains(possibleFlags, flag) then
                if flag == "not-stackable" then
                    return false
                end
            end
        end
    end
    return true
end

---@param itemName string internal name of the item
---@param multiplier number multiplier for scaling the recipe
local function recipe_is_recycling(itemName)
    local cats = data.raw.recipe[itemName] and data.raw.recipe[itemName].categories
    if not cats then return false end
    for _, c in pairs(cats) do
        if c == "recycling" then return true end
    end
    return false
end

--- Cache of item-name → item-prototype lookups (false = not found, since nil can't be stored).
local itemPrototypeCache = {}

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

---@param itemPrototype table? an item prototype, or nil when it could not be found
---@return boolean
local function item_is_non_stackable(itemPrototype)
    if not itemPrototype then
        return true
    end
    if tableContains(itemPrototype.flags or {}, "not-stackable") then
        return true
    end
    local stackSize = itemPrototype.stack_size
    return not stackSize or stackSize <= 1
end

--- The engine rejects item products of non-stackable items (stack_size <= 1 or "not-stackable"
--- flag) when their max count exceeds 1, e.g. "Recipe item-product X is not stackable but has a
--- max count of N". Such recipes cannot be batched, so they must be left completely unscaled.
---@param recipe table recipe prototype with results and ingredients
---@param multiplier number multiplier about to be applied
---@return boolean true when scaling this recipe by multiplier would crash recipe setup
local function recipe_has_unscalable_items(recipe, multiplier)
    local checkEntries = function(entries, kind)
        for _, entry in pairs(entries or {}) do
            if entry.type == "item" then
                if item_is_non_stackable(findItemPrototypeAnywhere(entry.name)) then
                    local count = (entry.amount_max or entry.amount or 0) + (entry.extra_count_fraction or 0)
                    if count * multiplier > 1 then
                        log("Skipped " .. recipe.name .. ": item " .. kind .. " '" .. tostring(entry.name) ..
                            "' is not stackable and cannot be scaled by " .. multiplier .. ".")
                        return true
                    end
                end
            end
        end
        return false
    end
    return checkEntries(recipe.results, "product") or checkEntries(recipe.ingredients, "ingredient")
end

local function updateRecipeAmounts(itemName, multiplier)
    if not data.raw.recipe[itemName] then
        log("Warning: recipe name '" .. itemName .. "' does not exist.")
        return
    end
    if recipe_is_recycling(itemName) then
        ---@diagnostic disable-next-line: cast-local-type
        multiplier = modSettingsRecyclingMultiplier
    end

    -- Compat shim: recipes producing/consuming non-stackable items cannot be batched.
    if multiplier > 1 and recipe_has_unscalable_items(data.raw.recipe[itemName], multiplier) then
        return
    end

    local recipe
    if modSettingsAddRecipes then
        data.raw.recipe[itemName .. "-bulk"] = util.table.deepcopy(data.raw.recipe[itemName])
        recipe = data.raw.recipe[itemName .. "-bulk"]
        recipe.localised_name = { "?", { "", { "entity-name." .. recipe.name } }, { "item-name." .. recipe.name } }
        recipe.localised_description = { "?", { "", { "recipe-description." .. recipe.name } }, { "recipe-description." .. recipe.name } }
        recipe.name = recipe.name .. "-bulk"
    else
        recipe = data.raw.recipe[itemName]
    end
    if not recipe or not recipe.results or not recipe.ingredients then
        return
    end

    --- Change recipe results
    local newResult = util.table.deepcopy(recipe.results)
    if newResult then
        for _, result in pairs(newResult) do
            result.amount = result.amount and math.min(MAX_INGREDIENT_AMOUNT, result.amount * multiplier)
            result.amount_min = result.amount_min and math.min(MAX_INGREDIENT_AMOUNT, result.amount_min * multiplier)
            result.amount_max = result.amount_max and math.min(MAX_INGREDIENT_AMOUNT, result.amount_max * multiplier)
            result.ignored_by_stats = result.ignored_by_stats and result.ignored_by_stats * multiplier
            result.ignored_by_productivity = result.ignored_by_productivity and
                result.ignored_by_productivity * multiplier
            result.extra_count_fraction = result.extra_count_fraction and result.extra_count_fraction * multiplier
        end
        recipe.results = newResult
    end

    --- Change recipe ingredients
    local newIngredients = util.table.deepcopy(recipe.ingredients)
    if newIngredients then
        for _, ingredient in pairs(newIngredients) do
            ingredient.amount = math.min(MAX_INGREDIENT_AMOUNT, ingredient.amount * multiplier)
        end
        recipe.ingredients = newIngredients
    end

    --- Change crafting speed
    if not recipe.energy_required then
        recipe.energy_required = 0.5
    end
    recipe.energy_required = recipe.energy_required * multiplier

    log("Scaled " .. recipe.name .. " by " .. multiplier)
end

if settings.startup["re-enable-type"].value then
    local itemNamesFromTypes = {}
    for itemTypeName, multiplier in pairs(modSettingsItemTypes) do
        if data.raw[itemTypeName] and itemTypeName ~= "recipe" then
            for itemName, item in pairs(data.raw[itemTypeName]) do
                local shouldChange = processItemFlags(item)
                if shouldChange and (not modSettingsItemNames[itemName] or not settings.startup["re-enable-name"].value) then
                    itemNamesFromTypes[itemName] = multiplier
                end
            end
        elseif itemTypeName == "recipe" then
            for recipeName, recipe in pairs(data.raw[itemTypeName]) do
                if recipe.ingredients then
                    for _, ingredient in pairs(recipe.ingredients) do
                        if ingredient.type == "item" and not data.raw.item[ingredient.name] then
                            local foundGroupsForItem = findItemByName(ingredient.name)
                            --if recipe.name == "light-armor" then
                            --    error(serpent.block(foundGroupsForItem))
                            --end
                            if foundGroupsForItem then
                                for _, foundGroupName in pairs(foundGroupsForItem) do
                                    if not processItemFlags(data.raw[foundGroupName][ingredient.name]) then
                                        log("Ingredient " ..
                                            ingredient.name .. " of recipe " .. recipe.name .. " is invalid")
                                        goto dontChange
                                    end
                                end
                            else
                                log("Ingredient " ..
                                    ingredient.name .. " of recipe " .. recipe.name .. " is invalid")
                                goto dontChange
                            end
                        elseif ingredient.type == "item" and not processItemFlags(data.raw.item[ingredient.name]) then
                            goto dontChange
                        end
                    end
                end
                if recipe.results then
                    for _, result in pairs(recipe.results) do
                        if result.type == "item" and not data.raw.item[result.name] then
                            local foundGroupsForItem = findItemByName(result.name)

                            if foundGroupsForItem then
                                for _, foundGroupName in pairs(foundGroupsForItem) do
                                    if not processItemFlags(data.raw[foundGroupName][result.name]) then
                                        log("Product " .. result.name .. " of recipe " .. recipe.name .. " is invalid")
                                        goto dontChange
                                    end
                                end
                            else
                                log("Product " .. result.name .. " of recipe " .. recipe.name .. " is invalid")
                                goto dontChange
                            end
                        elseif result.type == "research-progress" then
                            goto dontChange
                        elseif result.type == "item" and not processItemFlags(data.raw.item[result.name]) then
                            goto dontChange
                        end
                    end
                end
                itemNamesFromTypes[recipeName] = multiplier
                ::dontChange::
            end
        else
            log("Warning: item type '" .. itemTypeName .. "' does not exist.")
        end
    end
    for itemName, multiplier in pairs(itemNamesFromTypes) do
        if not modSettingsItemNames[itemName] then
            updateRecipeAmounts(itemName, multiplier)
        end
    end
end


if settings.startup["re-enable-name"].value then
    for itemName, multiplier in pairs(modSettingsItemNames) do
        updateRecipeAmounts(itemName, multiplier)
    end
end

if settings.startup["re-enable-subgroup"].value then
    local namesEnabled = settings.startup["re-enable-name"].value
    for recipeName, recipe in pairs(data.raw.recipe) do
        local multiplier = recipe.subgroup and modSettingsSubGroups[recipe.subgroup]
        if multiplier and not (namesEnabled and modSettingsItemNames[recipeName]) then
            updateRecipeAmounts(recipeName, multiplier)
        end
    end
end

if fluidFlowMultiplier > 0 then
    local typesToCheck = { "assembling-machine", "furnace" }
    for _, type in pairs(typesToCheck) do
        for itemName, item in pairs(data.raw[type]) do
            if item.fluid_box then
                item.fluid_box.volume = math.ceil(item.fluid_box.volume * fluidFlowMultiplier)
            end
            if (item.fluid_boxes) then
                for _, fluid_box in pairs(item.fluid_boxes) do
                    fluid_box.volume = math.ceil(fluid_box.volume * fluidFlowMultiplier)
                end
            end
        end
    end
end

local cargoPod = data.raw["cargo-pod"]["cargo-pod"]
if cargoPod then
    cargoPod.inventory_size = cargoPod.inventory_size * 100
end
