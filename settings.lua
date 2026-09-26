data:extend({
    {
        type = "int-setting",
        name = "re-amount-multiplier",
        order = "ab",
        setting_type = "startup",
        default_value = 10,
        minimum_value = 1,
        maximum_value = 1000,
    },
    {
        type = "int-setting",
        name = "re-recycling-amount-multiplier",
        order = "ac",
        setting_type = "startup",
        default_value = 10,
        minimum_value = 1,
        maximum_value = 1000,
    },
    {
        type = "bool-setting",
        name = "re-enable-type",
        order = "ae",
        setting_type = "startup",
        default_value = true,
    },
    {
        type = "string-setting",
        name = "re-item-types",
        order = "af",
        setting_type = "startup",
        default_value = "",
        allow_blank = true
    },
    {
        type = "bool-setting",
        name = "re-enable-name",
        order = "ag",
        setting_type = "startup",
        default_value = true,
    },
    {
        type = "string-setting",
        name = "re-item-names",
        order = "ah",
        setting_type = "startup",
        default_value =
        "iron-plate, copper-plate, pipe, pipe-to-ground, iron-gear-wheel, iron-stick, copper-cable, " ..
        "electronic-circuit, advanced-circuit, processing-unit, plastic-bar, sulfur, inserter, transport-belt, rail",
        allow_blank = true
    },
    {
        type = "bool-setting",
        name = "re-enable-subgroup",
        order = "ak",
        setting_type = "startup",
        default_value = false,
    },
    {
        type = "string-setting",
        name = "re-sub-groups",
        order = "al",
        setting_type = "startup",
        default_value = "",
        allow_blank = true
    },
    {
        type = "bool-setting",
        name = "re-scale-mixed-nonstackable",
        order = "bc",
        setting_type = "startup",
        default_value = true,
    },
    {
        type = "string-setting",
        name = "re-probability-handling",
        order = "bd",
        setting_type = "startup",
        default_value = "scaled-amount",
        allowed_values = {"scaled-amount", "expected-value"},
    },
    {
        type = "bool-setting",
        name = "re-enable-add-recipe",
        order = "ba",
        setting_type = "startup",
        default_value = false,
    },
    {
        type = "int-setting",
        name = "re-fluid-flow-multiplier",
        order = "bb",
        setting_type = "startup",
        default_value = 10,
        minimum_value = 1,
        maximum_value = 10000,
    },
})
