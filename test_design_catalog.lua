local root = os.getenv("DESIGNS_ROOT") or "/home/ubuntu/dapps-dbasic-release"
local expected = {
    ["coffee.appdock-design"] = { id = "coffee", title = "Coffee", button_style = "3d", logo_shape = "circle", wallpaper = "designs/wallpapers/coffee.jpg" },
    ["old-paper.appdock-design"] = { id = "old_paper", title = "Old Paper", button_style = "rounded", logo_shape = "rounded", wallpaper = "designs/wallpapers/old-paper.jpg" },
    ["ozean.appdock-design"] = { id = "ozean", title = "Ozean", button_style = "3d", logo_shape = "circle", wallpaper = "designs/wallpapers/ozean.jpg" },
}
local required = { "id", "title", "version", "highlight", "background", "button", "text", "dropdown", "button_style", "logo_shape", "wallpaper" }

for filename, specification in pairs(expected) do
    local file = assert(io.open(root .. "/designs/" .. filename, "rb"))
    local values = {}
    for line in file:lines() do
        local key, value = line:match("^([a-z_]+)=(.*)$")
        assert(key and value and values[key] == nil, "Design entries must have unique allowed key=value lines")
        values[key] = value
    end
    file:close()
    for _, key in ipairs(required) do assert(values[key] and values[key] ~= "", filename .. " must declare " .. key) end
    assert(values.id == specification.id and values.title == specification.title and values.version == "1.0.0", filename .. " must retain its expected public identity")
    for _, key in ipairs({ "highlight", "background", "button", "text", "dropdown" }) do assert(values[key]:match("^#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$"), filename .. " must declare a six-digit hexadecimal " .. key) end
    assert(values.button_style == specification.button_style and values.logo_shape == specification.logo_shape and values.wallpaper == specification.wallpaper, filename .. " must preserve its declared style and local wallpaper path")
    local wallpaper = assert(io.open(root .. "/" .. values.wallpaper, "rb"), filename .. " must reference an existing local wallpaper")
    assert(wallpaper:seek("end") > 20000, filename .. " wallpaper must be a nontrivial local image asset")
    wallpaper:close()
end

local catalog = assert(io.open(root .. "/dapps.txt", "rb")):read("*a")
for filename in pairs(expected) do assert(catalog:find("designs/" .. filename .. " | 1.0.0 | palette | design", 1, true), "Catalog must publish " .. filename .. " as a Design") end
print("Additional Designs catalog test: OK")
