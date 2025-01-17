for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{type = "logistic-container"}) do
        if entity.prototype.logistic_mode == "requester" then
            entity.request_from_buffers = true
        end
    end
end
