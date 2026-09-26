# Recipe Multiplier

A [Factorio](https://www.factorio.com/) 2.x mod that turns normal crafting into **batch crafting**: a scaled recipe produces `multiplier` times as much, consumes `multiplier` times as many ingredients, and takes `multiplier` times as long per craft. Machine throughput (items per minute) stays exactly the same — each craft is just a bigger batch, which cuts down on crafting animations and entity updates.

## How recipe selection works

The mod scales *recipes* (not items directly). Which recipes get scaled is decided by three independent, toggleable criteria. **Priority order: Item types → Item/Recipe names → Recipe sub groups.** A recipe claimed by several criteria is scaled once, by the first criterion that matches.

### 1. Item types (`re-enable-type` / `re-item-types`)

A "type" is a prototype group in `data.raw` — e.g. `item`, `tool`, `module`, `ammo` — *not* the in-game item category. Every scalable prototype of that group has its recipe scaled. The special type `recipe` scales every recipe in the game (for which all ingredients/products resolve to scalable prototypes).

Format: `item=100, tool` — entries without `=number` use the main multiplier.

### 2. Item/Recipe names (`re-enable-name` / `re-item-names`)

Scale by internal prototype name (the string shown by **ctrl + shift + F** while hovering an item in game). Recipes normally share the name of their main product, so listing `iron-plate` scales the `iron-plate` recipe. Names override the type criterion's multiplier, and — importantly — a recipe named here is **skipped by the sub group criterion**, which makes this list a handy exclusion list too.

Format: `iron-plate=100, copper-plate` — entries without `=number` use the main multiplier.

### 3. Recipe sub groups (`re-enable-subgroup` / `re-sub-groups`)

Scale all recipes whose recipe `subgroup` (crafting category, e.g. `crafting`, `smelting`, `chemistry`) is listed. Checked last: only recipes not already claimed by the two criteria above are affected.

Format: `smelting=20, chemistry` — entries without `=number` use the main multiplier.

### Recycling

Recipes in the `recycling` category (scrapping machines back into parts) use the separate `re-recycling-amount-multiplier` instead of the main one.

### Safety limits

- Ingredient/product amounts are capped at the engine maximum (65535).
- Recipes producing or consuming **non-stackable** items (stack size ≤ 1, e.g. space science) are skipped automatically — the engine forbids more than one such item per craft.
- The mod logs every recipe it scales or skips to the game log.

## Other settings

### Add recipe instead of changing the existing recipe (`re-enable-add-recipe`)

- **Off (default):** original recipes are overwritten with their scaled versions — the standard "batch crafting" setup.
- **On:** originals stay intact and each one gains a `<recipe>-bulk` copy with the multiplier applied. Machines can then craft both the small and the big variant, so you choose per production line.

### Fluid flow multiplier (`re-fluid-flow-multiplier`)

Multiplies the internal fluid volume of assembling machines and furnaces. Fluid throughput becomes a bottleneck with very high crafting speeds; a larger fluid box lets fluids move to and from machines quicker. The cargo pod inventory is also enlarged (×100) so large batch deliveries fit.

## Tips

- Use **ctrl + shift + F** on any item in game to see its name, prototype type and recipe sub group.
- A full list of names and types is on the wiki: [Data.raw](https://wiki.factorio.com/Data.raw).
- All settings are **startup** settings — changing them requires a map restart.
