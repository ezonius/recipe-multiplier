--- Recipe Multiplier — control stage.
---
--- The data stage collects notable startup messages (warnings, skipped recipes,
--- errors) into the hidden item prototype "recipe-multiplier-startup-log" (see
--- data-final-fixes.lua). Here we broadcast them in the chat after a map is
--- loaded, so issues are visible in-game instead of only in factorio-current.log.

local LOG_ITEM_NAME = "recipe-multiplier-startup-log"

--- Prints one chat line per collected startup message. Each message is a string
--- element of the carrier prototype's localised name ({ "", msg1, msg2, ... }).
local function printStartupLog()
	local carrier = prototypes.item[LOG_ITEM_NAME]
	if not carrier then
		return -- no notable messages during the last data stage
	end
	local messages = carrier.localised_name
	if type(messages) ~= "table" then
		return
	end
	game.print("Recipe Multiplier startup messages:", { r = 1, g = 0.7, b = 0.2 })
	for index = 2, #messages do
		game.print(messages[index], { r = 1, g = 0.7, b = 0.2 })
	end
end

-- game.print is not available in on_load, so a flag set there is consumed by the
-- first on_tick. This re-broadcasts the messages every time a map is loaded.
local pendingBroadcast = false

script.on_init(function()
	pendingBroadcast = true
end)

script.on_load(function()
	pendingBroadcast = true
end)

script.on_event(defines.events.on_tick, function()
	if pendingBroadcast then
		pendingBroadcast = false
		printStartupLog()
	end
end)

--- Console command: re-print the last data stage's notable messages on demand.
commands.add_command("recipe-multiplier-startup-log", { "command-help.recipe-multiplier-startup-log" }, function()
	printStartupLog()
end)
