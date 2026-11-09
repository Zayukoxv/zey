local STATE_IDLE, STATE_HEAD, STATE_WAIT = "idle", "head", "wait"

local kb = nil
local targetCombo = nil
local lastWant = false
local lastCb, lastKey = nil, nil
local engaged = false
local saved = nil
local state = STATE_IDLE
local lockedName = nil
local lastPos = nil
local lastList = ""
local lastRefresh = 0
local lastErr = nil
local projMethod = nil
local warned = {}
local lastPrint = {}
local curVoid = nil
local lastHop = 0
pcall(function() math.randomseed(os.time()) end)

local follow = nil
local cachedMine = nil
local velProp = "AssemblyLinearVelocity"
local voidSpot = nil
local camSwapped = false
local camTargetChar = nil
local ZERO = nil
pcall(function() ZERO = Vector3.new(0, 0, 0) end)

local tapPhase = "on"
local tapStart = 0
local tapShot = false
local tapWas = false
local tapShoot = nil
local ncParts, ncChar, ncLast, ncOn = {}, nil, 0, false
local retreating = false

local gen = 1
if type(_G) == "table" then
    _G.__orbit_gen = (_G.__orbit_gen or 0) + 1
    gen = _G.__orbit_gen
end
local function stale()
    return type(_G) == "table" and _G.__orbit_gen ~= gen
end
for _, tabName in ipairs({ "Orbit", "Zeyy Hook", "Zeyy Targeting", "Zeyy Void", "Zeyy Combat", "Zeyy Display" }) do
    pcall(UI.RemoveTab, tabName)
end

local function dbg(...)
    local ok, on = pcall(UI.GetValue, "orb_debug")
    if ok and on then print(...) end
end

local function warnOnce(key, msg)
    if not warned[key] then
        warned[key] = true
        dbg("[orbit] " .. msg)
    end
end

local function throttled(key, secs, ...)
    local now = os.clock()
    if not lastPrint[key] or now - lastPrint[key] >= secs then
        lastPrint[key] = now
        dbg(...)
    end
end

local function localPlayer()
    return game.Players.LocalPlayer
end

local function allPlayers()
    local ok, list = pcall(function() return game.Players:GetPlayers() end)
    if ok and list then return list end
    return {}
end

local function findPlayer(name)
    if not name then return nil end
    for _, plr in ipairs(allPlayers()) do
        if plr.Name == name then return plr end
    end
    return nil
end

local function getRoot(char)
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
end

local function myRoot()
    local lp = localPlayer()
    return lp and getRoot(lp.Character)
end

local function targetRoot(plr)
    local ok, r = pcall(function()
        local char = plr.Character
        if UI.GetValue("orb_part") == 1 then
            local t = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
            if t then return t end
        end
        return char:FindFirstChild("HumanoidRootPart")
    end)
    if ok then return r end
    return nil
end

local function readPos(root)
    local ok, p = pcall(function() return root.Position end)
    if ok and p then return p.X, p.Y, p.Z end
    return nil
end

local function setPos(root, x, y, z)
    local ok = pcall(function() root.CFrame = CFrame.new(x, y, z) end)
    if not ok then
        ok = pcall(function() root.Position = Vector3.new(x, y, z) end)
    end
    pcall(function() root.Velocity = Vector3.new(0, 0, 0) end)
    pcall(function() root.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
    return ok
end

local function bodyFlag(char, name)
    local ok, v = pcall(function()
        local be = char:FindFirstChild("BodyEffects")
        if not be then return false end
        local f = be:FindFirstChild(name)
        return f and f.Value or false
    end)
    return ok and v == true
end

local function playerState(plr)
    local ok, alive, pos = pcall(function()
        local char = plr.Character
        if not char then return false end
        local hum = char:FindFirstChild("Humanoid")
        local head = char:FindFirstChild("Head")
        local root = char:FindFirstChild("HumanoidRootPart")
        if not (hum and head and root) then return false end
        if bodyFlag(char, "Dead") then return false end
        local knocked = bodyFlag(char, "K.O")
        if knocked and UI.GetValue("orb_stomp") then return true, head.Position end
        if hum.Health <= 0 then return false end
        if UI.GetValue("orb_ko") and knocked then return false end
        return true, head.Position
    end)
    if ok and alive then return true, pos end
    return false, nil
end

local function setNoclip(on)
    local lp = localPlayer()
    local char = lp and lp.Character
    if not char then return end
    if on then
        local now = os.clock()
        if char ~= ncChar or now - ncLast > 1 then
            ncChar = char
            ncLast = now
            local list = {}
            pcall(function()
                for _, d in ipairs(char:GetDescendants()) do
                    local cn = d.ClassName
                    if cn == "Part" or cn == "MeshPart" or cn == "UnionOperation" then
                        list[#list + 1] = d
                    end
                end
            end)
            ncParts = list
        end
        for i = 1, #ncParts do
            local part = ncParts[i]
            pcall(function() part.CanCollide = false end)
        end
        if not ncOn then
            ncOn = true
            pcall(function() char.Humanoid.PlatformStand = true end)
        end
    elseif ncOn then
        ncOn = false
        ncParts = {}
        ncChar = nil
        pcall(function() char.Humanoid.PlatformStand = false end)
    end
end

local function rotCF(m)
    if m == 1 then return CFrame.Angles(math.rad(90), 0, 0) end   -- face up
    if m == 2 then return CFrame.Angles(math.rad(-90), 0, 0) end  -- face down
    if m == 3 then return CFrame.Angles(0, 0, math.pi) end        -- upside down
    if m == 4 then return CFrame.Angles(0, os.clock() * 20, 0) end -- spin
    return nil
end

local anchored, anchoredRoot = false, nil
local function setAnchor(root, on)
    if on then
        if root and (not anchored or anchoredRoot ~= root) then
            pcall(function() root.Anchored = true end)
            anchored, anchoredRoot = true, root
        end
    elseif anchored then
        if anchoredRoot then pcall(function() anchoredRoot.Anchored = false end) end
        anchored, anchoredRoot = false, nil
    end
end

local function fastFollow()
    local f = follow
    local mine = cachedMine
    if not f or not mine then
        if ncOn then setNoclip(false) end
        setAnchor(nil, false)
        return
    end
    setNoclip(f.below == true)
    setAnchor(mine, (f.mode == "void" and UI.GetValue("orb_anchor")) and true or false)

    local x, y, z
    local goVoid = false
    if f.mode == "head" and f.tap then
        local now = os.clock()
        local el = now - tapStart
        if tapPhase == "on" then
            if not tapShot and el >= f.shootDelay and tapShoot then
                tapShot = true
                tapShoot(f.root)
            end
            if el >= f.onT then
                tapPhase = "off"
                tapStart = now
                tapShot = false
            end
        elseif el >= f.offT then
            tapPhase = "on"
            tapStart = now
            tapShot = false
        end
        goVoid = (tapPhase == "off") and not f.noVoid
    end

    if f.mode == "head" and goVoid then
        if f.rand and f.base and voidSpot then
            x, y, z = voidSpot(f.base)
        else
            x, y, z = f.vx, f.vy, f.vz
        end
    elseif f.mode == "head" then
        local ok, p = pcall(function() return f.root.Position end)
        if not ok or not p then return end
        if f.below then
            x, y, z = p.X, p.Y - 3 - f.off, p.Z
        else
            x, y, z = p.X, p.Y + 1.5 + f.off, p.Z
        end

        if f.lead > 0 then
            local okv, v = pcall(function() return f.root[velProp] end)
            if okv and v then
                x = x + v.X * f.lead
                y = y + v.Y * f.lead
                z = z + v.Z * f.lead
            elseif not okv and velProp ~= "Velocity" then
                velProp = "Velocity"
            end
        end
    elseif f.mode == "void" and f.rand and f.base and voidSpot then
        x, y, z = voidSpot(f.base)
    else
        x, y, z = f.x, f.y, f.z
    end

    if f.mode == "head" and not goVoid then
        if f.circ then
            local a = os.clock() * f.circSpd
            x = x + math.cos(a) * f.circR
            z = z + math.sin(a) * f.circR
        end
        if f.jit then
            local r = f.jitR
            x = x + (math.random() * 2 - 1) * r
            y = y + (math.random() * 2 - 1) * r * 0.5
            z = z + (math.random() * 2 - 1) * r
        end
    end

    local rm = 0
    if f.mode == "void" or goVoid then
        rm = UI.GetValue("orb_rot_void") or 0
    elseif f.mode == "head" then
        rm = UI.GetValue("orb_rot_head") or 0
    end
    local rot = (rm > 0) and rotCF(rm) or nil
    local okc = pcall(function()
        local cf = CFrame.new(x, y, z)
        if rot then cf = cf * rot end
        mine.CFrame = cf
    end)
    if not okc then
        pcall(function() mine.Position = Vector3.new(x, y, z) end)
    end
    if ZERO then
        local okz = pcall(function() mine[velProp] = ZERO end)
        if not okz and velProp ~= "Velocity" then velProp = "Velocity" end
        pcall(function() mine.AssemblyAngularVelocity = ZERO end)
    end
end

local function projectManual(pos)
    local ok, x, y, vis = pcall(function()
        local cam = workspace.CurrentCamera
        local cf = cam.CFrame
        local look, right, up, cpos = cf.LookVector, cf.RightVector, cf.UpVector, cf.Position
        local vs = cam.ViewportSize
        local dx, dy, dz = pos.X - cpos.X, pos.Y - cpos.Y, pos.Z - cpos.Z
        local z = dx * look.X + dy * look.Y + dz * look.Z
        if z <= 0.001 then return 0, 0, false end
        local th = math.tan(math.rad(cam.FieldOfView) / 2)
        local aspect = vs.X / vs.Y
        local nx = (dx * right.X + dy * right.Y + dz * right.Z) / (z * th * aspect)
        local ny = (dx * up.X + dy * up.Y + dz * up.Z) / (z * th)
        return (nx * 0.5 + 0.5) * vs.X, (0.5 - ny * 0.5) * vs.Y, true
    end)
    if ok and x then return x, y, vis end
    return nil
end

local function projectNative(pos)
    local ok, x, y, vis = pcall(function()
        local v, onScreen = workspace.CurrentCamera:WorldToViewportPoint(pos)
        return v.X, v.Y, (onScreen ~= false) and (v.Z > 0)
    end)
    if ok and x then return x, y, vis end
    return nil
end

local function screenPoint(pos)
    local x, y, vis = projectManual(pos)
    if x then
        if projMethod ~= "manual" then
            projMethod = "manual"
            dbg("[orbit] screen projection: manual")
        end
        return x, y, vis
    end
    x, y, vis = projectNative(pos)
    if x then
        if projMethod ~= "native" then
            projMethod = "native"
            dbg("[orbit] screen projection: WorldToViewportPoint")
        end
        return x, y, vis
    end
    return nil
end

local function crosshairPos()
    if UI.GetValue("orb_xhair") ~= 1 then
        local ok, x, y = pcall(function()
            local uis = game:GetService("UserInputService")
            local m = uis:GetMouseLocation()
            return m.X, m.Y
        end)
        if ok and x then return x, y end
        ok, x, y = pcall(function()
            local m = localPlayer():GetMouse()
            return m.X, m.Y
        end)
        if ok and x then return x, y end
        warnOnce("mouse", "could not read the mouse, using screen center")
    end
    local ok, x, y = pcall(function()
        local vs = workspace.CurrentCamera.ViewportSize
        return vs.X / 2, vs.Y / 2
    end)
    if ok and x then return x, y end
    return nil
end

local function pickClosest()
    local lp = localPlayer()
    local cx, cy = crosshairPos()
    local maxPx = tonumber(UI.GetValue("orb_fov")) or 3000
    local mx, my, mz = nil, nil, nil
    local rp = myRoot()
    if rp then mx, my, mz = readPos(rp) end

    local best, bestD = nil, nil
    local checked, onScreen = 0, 0
    for _, plr in ipairs(allPlayers()) do
        if plr ~= lp then
            local alive, pos = playerState(plr)
            if alive then
                checked = checked + 1
                local d = nil
                local sx, sy, vis = screenPoint(pos)
                if cx and sx then
                    if vis then
                        onScreen = onScreen + 1
                        d = math.sqrt((sx - cx) ^ 2 + (sy - cy) ^ 2)
                        if d > maxPx then d = nil end
                    end
                elseif mx then
                    warnOnce("proj", "screen projection unavailable, picking nearest player instead")
                    d = math.sqrt((pos.X - mx) ^ 2 + (pos.Y - my) ^ 2 + (pos.Z - mz) ^ 2)
                end
                if d and (not bestD or d < bestD) then
                    best, bestD = plr, d
                end
            end
        end
    end

    if best then
        dbg("[orbit] closest to crosshair:", best.Name, math.floor(bestD))
    else
        throttled("nocand", 3, "[orbit] no target found | cursor:",
            cx and math.floor(cx) or "nil", cy and math.floor(cy) or "nil",
            "| alive players:", checked, "| on screen:", onScreen,
            "| projection:", projMethod or "none")
    end
    return best
end

tapShoot = function(root)
    if type(mouse1click) ~= "function" then
        warnOnce("noclick", "mouse1click is not available here, so tap mode can't shoot")
        return
    end
    if type(isrbxactive) == "function" then
        local okF, focused = pcall(isrbxactive)
        if okF and not focused then return end
    end
    if UI.GetValue("orb_tap_aim") then
        if type(mousemoveabs) == "function" then
            local ok, p = pcall(function() return root.Position end)
            if ok and p then
                local sx, sy, vis = screenPoint(p)
                if sx and vis then
                    pcall(mousemoveabs, math.floor(sx), math.floor(sy))
                end
            end
        else
            warnOnce("nomove", "mousemoveabs is not available here, so tap mode can't aim")
        end
    end
    pcall(mouse1click)
end

local function selectedName()
    if not targetCombo then return nil end
    local ok, t = pcall(function() return targetCombo:GetText() end)
    if ok and t and t ~= "" and t ~= "(none)" then return t end
    return nil
end

local function refreshPlayers(force)
    if not targetCombo then return end
    local lp = localPlayer()
    local names = {}
    for _, plr in ipairs(allPlayers()) do
        if plr ~= lp then names[#names + 1] = plr.Name end
    end
    table.sort(names)

    local joined = table.concat(names, ",")
    if not force and joined == lastList then return end
    lastList = joined

    local prev = selectedName()
    pcall(function() targetCombo:Clear() end)
    pcall(function() targetCombo:Add("(none)") end)
    local idx = 0
    for i, n in ipairs(names) do
        pcall(function() targetCombo:Add(n) end)
        if n == prev then idx = i end
    end
    pcall(function() targetCombo:SetValue(idx) end)
end

local hud = {}
local hudMain = nil
local eventText, eventUntil, eventColor = nil, 0, { 255, 255, 255 }

local function pushEvent(text, r, g, b)
    eventText = text
    eventUntil = os.clock() + 3
    eventColor = { r or 255, g or 255, b or 255 }
end

local function healthInfo(plr)
    local ok, hp, max, ko = pcall(function()
        local char = plr.Character
        local hum = char and char:FindFirstChild("Humanoid")
        if not hum then return nil end
        return hum.Health, hum.MaxHealth, bodyFlag(char, "K.O")
    end)
    if ok and hp then return hp, max, ko end
    return nil
end

local function hudText(key)
    if hud[key] then return hud[key] end
    local ok, obj = pcall(function() return Drawing.new("Text") end)
    if not ok or not obj then
        warnOnce("draw", "Drawing.new(\"Text\") failed: " .. tostring(obj))
        return nil
    end
    pcall(function()
        obj.Center = true
        obj.Outline = true
        obj.OutlineColor = Color3.fromRGB(0, 0, 0)
        obj.Visible = false
    end)
    hud[key] = obj
    return obj
end

local FONT_NAMES = { "Monospace", "Plex", "UI", "System" }
local FONT_FALLBACK = { UI = 0, System = 1, Plex = 2, Monospace = 3 }

local function hudFont()
    local name = FONT_NAMES[(UI.GetValue("orb_hud_font") or 0) + 1] or "Monospace"
    local f = nil
    pcall(function() f = Drawing.Fonts[name] end)
    return f or FONT_FALLBACK[name]
end

local function drawLine(key, text, x, y, size, font, r, g, b)
    local obj = hudText(key)
    if not obj then return end
    pcall(function()
        if text then
            obj.Text = text
            obj.Size = size
            obj.Font = font
            obj.Color = Color3.fromRGB(r, g, b)
            obj.Position = Vector2.new(x, y)
            obj.Visible = true
        else
            obj.Visible = false
        end
    end)
end

local function hideHud()
    for _, obj in pairs(hud) do
        pcall(function() obj.Visible = false end)
    end
end

local function destroyHud()
    for key, obj in pairs(hud) do
        local ok = pcall(function() obj:Remove() end)
        if not ok then pcall(function() obj:Destroy() end) end
        hud[key] = nil
    end
end

local function renderHud()
    if not UI.GetValue("orb_hud") then
        hideHud()
        return
    end

    local now = os.clock()
    local showEvent = eventText ~= nil and now < eventUntil
    if not hudMain and not showEvent then
        hideHud()
        return
    end

    local okV, vx, vy = pcall(function()
        local vs = workspace.CurrentCamera.ViewportSize
        return vs.X, vs.Y
    end)
    if not okV or not vx then
        warnOnce("hudvs", "could not read the screen size for notifications")
        return
    end

    local size = tonumber(UI.GetValue("orb_hud_size")) or 18
    local fromBottom = tonumber(UI.GetValue("orb_hud_y")) or 140
    local font = hudFont()
    local x = vx / 2
    local lineH = size * 1.35
    local baseY = vy - fromBottom

    if hudMain then
        local m = hudMain
        local hpText, r, g, b
        if m.dead then
            hpText = "HP: 0 (dead)"
            r, g, b = 200, 60, 60
        elseif m.hp then
            local maxhp = (m.max and m.max > 0) and m.max or 100
            local pct = math.max(0, math.min(1, m.hp / maxhp))
            hpText = string.format("HP: %d/%d (%d%%)",
                math.floor(m.hp + 0.5), math.floor(maxhp + 0.5), math.floor(pct * 100 + 0.5))
            if m.ko then hpText = hpText .. " [K.O.]" end
            r, g, b = math.floor(255 * (1 - pct)), math.floor(255 * pct), 40
        else
            hpText = "HP: --"
            r, g, b = 200, 200, 200
        end
        if m.ff then hpText = hpText .. " [forcefield]" end
        drawLine("hp", hpText, x, baseY, size, font, r, g, b)
        drawLine("name", "Target: " .. m.name, x, baseY - lineH, size, font, 255, 255, 255)
    else
        drawLine("hp", nil)
        drawLine("name", nil)
    end

    if showEvent then
        local c = eventColor
        local ey = hudMain and (baseY - lineH * 2) or baseY
        drawLine("event", eventText, x, ey, size, font, c[1], c[2], c[3])
    else
        drawLine("event", nil)
    end
end

-- Kill effects: 2D Drawing effects that play around your character when your target dies.
-- Dots get a soft glow halo, a motion trail, a white-hot start that cools to the chosen
-- color, and a twinkle. Rings and bolts get a glow layer and an impact flash.
local particles = {}
local lastKillFx = 0
local killTrackName, killTrackAlive = nil, false
local FX_COUNT = 6 -- Burst, Shockwave, Spiral, Fountain, Lightning, Kill Text
local MAX_PARTICLES = 220

local function lerp(a, b, t) return a + (b - a) * t end

local function hsvRGB(h)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local q = 1 - f
    i = i % 6
    local r, g, b
    if i == 0 then r, g, b = 1, f, 0
    elseif i == 1 then r, g, b = q, 1, 0
    elseif i == 2 then r, g, b = 0, 1, f
    elseif i == 3 then r, g, b = 0, q, 1
    elseif i == 4 then r, g, b = f, 0, 1
    else r, g, b = 1, 0, q end
    return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
end

local function particleColor(mode)
    if mode == 1 then return 255, 50 + math.random(0, 40), 50 end
    if mode == 2 then return 235, 245, 255 end
    if mode == 3 then return 255, 185 + math.random(0, 55), 40 end
    return hsvRGB(math.random())
end

local function removeDrawing(o)
    if not o then return end
    local ok = pcall(function() o:Remove() end)
    if not ok then pcall(function() o:Destroy() end) end
end

local function removeParticle(pt)
    removeDrawing(pt.obj)
    removeDrawing(pt.halo)
    removeDrawing(pt.trail)
    removeDrawing(pt.glow)
end

local function mkDraw(class)
    local obj = nil
    local ok = pcall(function()
        obj = Drawing.new(class)
        obj.Visible = false
    end)
    if not ok or not obj then
        warnOnce("fxdraw_" .. class, "Drawing.new(\"" .. class .. "\") failed, that kill effect is unavailable")
        return nil
    end
    return obj
end

local function addParticle(pt)
    if #particles >= MAX_PARTICLES then return false end
    particles[#particles + 1] = pt
    return true
end

local function setColor(obj, r, g, b)
    pcall(function() obj.Color = Color3.fromRGB(math.floor(r), math.floor(g), math.floor(b)) end)
end

-- A glowing dot: halo and trail are created first so the bright core draws on top
local function addDot(pt, r, g, b)
    if #particles >= MAX_PARTICLES then return false end
    local halo = mkDraw("Circle")
    if halo then
        pcall(function() halo.Filled = true; halo.NumSides = 18; halo.Thickness = 1 end)
        setColor(halo, r, g, b)
    end
    local trail = mkDraw("Line")
    if trail then setColor(trail, r, g, b) end
    local obj = mkDraw("Circle")
    if not obj then
        removeDrawing(halo)
        removeDrawing(trail)
        return false
    end
    pcall(function() obj.Filled = true; obj.NumSides = 14; obj.Thickness = 1 end)
    setColor(obj, r, g, b)
    pt.obj, pt.halo, pt.trail = obj, halo, trail
    pt.cr, pt.cg, pt.cb = r, g, b
    pt.seed = math.random() * 100
    addParticle(pt)
    return true
end

-- A fast expanding flash of light
local function addFlash(now, rmax, life, r, g, b)
    if #particles >= MAX_PARTICLES then return end
    local o = mkDraw("Circle")
    if not o then return end
    pcall(function() o.Filled = true; o.NumSides = 32; o.Thickness = 1 end)
    setColor(o, lerp(r, 255, 0.6), lerp(g, 255, 0.6), lerp(b, 255, 0.6))
    addParticle({ kind = "flash", obj = o, born = now, life = life, rmax = rmax })
end

-- One lightning segment: a thick faint glow line under a thin white-hot core
local function addSeg(ax, ay, bx, by, thick, r, g, b, blife, now)
    if #particles >= MAX_PARTICLES then return false end
    local glow = mkDraw("Line")
    if not glow then return false end
    pcall(function() glow.Thickness = thick * 4 end)
    setColor(glow, r, g, b)
    local core = mkDraw("Line")
    if not core then
        removeDrawing(glow)
        return false
    end
    pcall(function() core.Thickness = thick end)
    setColor(core, lerp(r, 255, 0.75), lerp(g, 255, 0.75), lerp(b, 255, 0.75))
    addParticle({ kind = "line", obj = core, glow = glow, born = now, life = blife,
        ax = ax, ay = ay, bx = bx, by = by })
    return true
end

local function spawnKillParticles(force, name)
    if not force and not UI.GetValue("orb_kp") then return end
    local now = os.clock()
    if not force and now - lastKillFx < 0.5 then return end
    lastKillFx = now

    local count = math.min(tonumber(UI.GetValue("orb_kp_count")) or 30, 100)
    local size = tonumber(UI.GetValue("orb_kp_size")) or 4
    local spread = tonumber(UI.GetValue("orb_kp_spread")) or 140
    local life = (tonumber(UI.GetValue("orb_kp_life")) or 900) / 1000
    local mode = UI.GetValue("orb_kp_color") or 0
    local fx = UI.GetValue("orb_kp_fx") or 0
    if fx >= FX_COUNT then fx = math.random(0, FX_COUNT - 1) end

    if fx == 0 then
        -- Burst: glowing sparks with trails fly out in every direction
        local fr, fg, fb = particleColor(mode)
        addFlash(now, spread * 0.55, 0.3, fr, fg, fb)
        for _ = 1, count do
            local r, g, b = particleColor(mode)
            local ang = math.random() * 2 * math.pi
            local r0 = 12 + math.random() * 25
            local ok = addDot({
                kind = "burst", born = now,
                life = life * (0.7 + math.random() * 0.6),
                cos = math.cos(ang), sin = math.sin(ang),
                ox = math.cos(ang) * r0, oy = math.sin(ang) * r0,
                spd = spread * (0.4 + math.random() * 0.7),
                size = size * (0.6 + math.random() * 0.9),
            }, r, g, b)
            if not ok then break end
        end

    elseif fx == 1 then
        -- Shockwave: flash plus three glowing rings expanding in sequence
        local fr, fg, fb = particleColor(mode)
        addFlash(now, spread * 0.7, 0.28, fr, fg, fb)
        for i = 0, 2 do
            if #particles >= MAX_PARTICLES then break end
            local r, g, b = particleColor(mode)
            local thick = 2 + size * 0.4
            local halo = mkDraw("Circle")
            if halo then
                pcall(function() halo.Filled = false; halo.NumSides = 48; halo.Thickness = thick * 4 end)
                setColor(halo, r, g, b)
            end
            local obj = mkDraw("Circle")
            if not obj then removeDrawing(halo) break end
            pcall(function() obj.Filled = false; obj.NumSides = 48; obj.Thickness = thick end)
            setColor(obj, lerp(r, 255, 0.5), lerp(g, 255, 0.5), lerp(b, 255, 0.5))
            addParticle({ kind = "ring", obj = obj, halo = halo, born = now + i * 0.12,
                life = life, r0 = 8, r1 = spread * (1.0 + i * 0.18) })
        end

    elseif fx == 2 then
        -- Spiral: three arms of glowing comets spinning outward
        local arms = 3
        local per = math.max(2, math.floor(count / arms))
        for arm = 0, arms - 1 do
            for j = 0, per - 1 do
                local r, g, b = particleColor(mode)
                local ok = addDot({
                    kind = "spiral",
                    born = now + j * (life * 0.5 / per), life = life,
                    a0 = arm * 2 * math.pi / arms, turns = 1.2,
                    spd = spread * 1.2, size = size * (1 - j / per * 0.5) * 1.2,
                }, r, g, b)
                if not ok then return end
            end
        end

    elseif fx == 3 then
        -- Fountain: glowing sparks shoot up and rain back down
        local fr, fg, fb = particleColor(mode)
        addFlash(now, spread * 0.35, 0.25, fr, fg, fb)
        for _ = 1, count do
            local r, g, b = particleColor(mode)
            local ok = addDot({
                kind = "fountain", born = now,
                life = life * (0.8 + math.random() * 0.5),
                vx = (math.random() - 0.5) * spread * 1.5,
                vy = -(spread * 1.5 + math.random() * spread * 2),
                g = 700, size = size * (0.7 + math.random() * 0.8),
            }, r, g, b)
            if not ok then break end
        end

    elseif fx == 4 then
        -- Lightning: glowing forked bolts strike outward from an impact flash
        local fr, fg, fb = particleColor(mode)
        addFlash(now, spread * 0.5, 0.22, fr, fg, fb)
        local bolts = math.max(3, math.floor(count / 8))
        local segs = 7
        local boltLife = math.min(life, 0.5)
        local thick = math.max(1, size * 0.5)
        for _ = 1, bolts do
            local ang = math.random() * 2 * math.pi
            local len = spread * (0.8 + math.random() * 0.6)
            local dx, dy = math.cos(ang), math.sin(ang)
            local px, py = -dy, dx
            local r, g, b = particleColor(mode)
            local pts = { { dx * 20, dy * 20 } }
            for k = 1, segs do
                local d = 20 + (k / segs) * len
                local j = (math.random() - 0.5) * spread * 0.25
                pts[#pts + 1] = { dx * d + px * j, dy * d + py * j }
            end
            for k = 1, #pts - 1 do
                if not addSeg(pts[k][1], pts[k][2], pts[k + 1][1], pts[k + 1][2], thick, r, g, b, boltLife, now) then return end
            end
            -- forks
            for k = 2, #pts - 2 do
                if math.random() < 0.4 then
                    local fa = ang + (math.random() < 0.5 and -1 or 1) * (0.5 + math.random() * 0.5)
                    local fl = spread * (0.15 + math.random() * 0.2)
                    local fx2, fy2 = pts[k][1] + math.cos(fa) * fl, pts[k][2] + math.sin(fa) * fl
                    if not addSeg(pts[k][1], pts[k][2], fx2, fy2, math.max(1, thick * 0.6), r, g, b, boltLife, now) then return end
                end
            end
        end

    elseif fx == 5 then
        -- Kill text: floats up above your character
        local obj = mkDraw("Text")
        if not obj then return end
        local txt = (name and name ~= "") and (name .. " eliminated") or "Eliminated"
        pcall(function()
            obj.Text = txt
            obj.Size = 16 + size * 2
            obj.Center = true
            obj.Outline = true
            obj.OutlineColor = Color3.fromRGB(0, 0, 0)
        end)
        setColor(obj, particleColor(mode))
        local ok = addParticle({ kind = "text", obj = obj, born = now, life = math.max(life, 1.2) })
        if not ok then removeDrawing(obj) end
    end
end

local function hideParticle(pt)
    pcall(function() pt.obj.Visible = false end)
    if pt.halo then pcall(function() pt.halo.Visible = false end) end
    if pt.trail then pcall(function() pt.trail.Visible = false end) end
    if pt.glow then pcall(function() pt.glow.Visible = false end) end
    pt.px, pt.py = nil, nil
end

-- Draws a glowing dot: white-hot at first, cooling to its color, twinkling, with halo and trail
local function drawDot(pt, x, y, rad, a, t, now)
    local tw = 0.8 + 0.4 * math.sin(now * 28 + pt.seed)
    rad = math.max(0.6, rad * tw)
    local heat = math.max(0, 1 - t * 2.5)
    local o = pt.obj
    o.Position = Vector2.new(x, y)
    o.Radius = rad
    o.Transparency = a
    o.Color = Color3.fromRGB(math.floor(lerp(pt.cr, 255, heat)), math.floor(lerp(pt.cg, 255, heat)), math.floor(lerp(pt.cb, 255, heat)))
    o.Visible = true
    local h = pt.halo
    if h then
        h.Position = Vector2.new(x, y)
        h.Radius = rad * 2.8
        h.Transparency = a * 0.22
        h.Visible = true
    end
    local l = pt.trail
    if l and pt.px then
        l.From = Vector2.new(pt.px, pt.py)
        l.To = Vector2.new(x, y)
        l.Thickness = math.max(1, rad * 0.9)
        l.Transparency = a * 0.5
        l.Visible = true
    end
    pt.px, pt.py = x, y
end

local function updateParticles()
    if #particles == 0 then return end
    local now = os.clock()

    local cx, cy = nil, nil
    local r = myRoot()
    if r then
        local ok, p = pcall(function() return r.Position end)
        if ok and p then
            local sx, sy, vis = screenPoint(p)
            if sx and vis then cx, cy = sx, sy end
        end
    end
    if not cx then
        pcall(function()
            local vs = workspace.CurrentCamera.ViewportSize
            cx, cy = vs.X / 2, vs.Y / 2
        end)
    end

    for i = #particles, 1, -1 do
        local pt = particles[i]
        local t = (now - pt.born) / pt.life
        if t >= 1 then
            removeParticle(pt)
            table.remove(particles, i)
        elseif t < 0 or not cx then
            hideParticle(pt)
        else
            local k = pt.kind
            local ok = pcall(function()
                local o = pt.obj
                local inv = (1 - t) * (1 - t)
                if k == "burst" then
                    local d = pt.spd * (1 - inv)
                    drawDot(pt, cx + pt.ox + pt.cos * d, cy + pt.oy + pt.sin * d + 40 * t * t,
                        pt.size * (1 - 0.6 * t), 1 - t * t, t, now)
                elseif k == "spiral" then
                    local a = pt.a0 + t * pt.turns * 2 * math.pi
                    local rad = 15 + pt.spd * (1 - inv)
                    drawDot(pt, cx + math.cos(a) * rad, cy + math.sin(a) * rad,
                        pt.size * (1 - 0.5 * t), 1 - t * t, t, now)
                elseif k == "fountain" then
                    local tt = now - pt.born
                    drawDot(pt, cx + pt.vx * tt, cy + pt.vy * tt + 0.5 * pt.g * tt * tt,
                        pt.size * (1 - 0.5 * t), 1 - t * t, t, now)
                elseif k == "ring" then
                    local rad = pt.r0 + (pt.r1 - pt.r0) * (1 - inv)
                    o.Position = Vector2.new(cx, cy)
                    o.Radius = rad
                    o.Transparency = 1 - t
                    o.Visible = true
                    if pt.halo then
                        pt.halo.Position = Vector2.new(cx, cy)
                        pt.halo.Radius = rad
                        pt.halo.Transparency = (1 - t) * 0.25
                        pt.halo.Visible = true
                    end
                elseif k == "flash" then
                    o.Position = Vector2.new(cx, cy)
                    o.Radius = 6 + pt.rmax * (1 - inv)
                    o.Transparency = inv * 0.55
                    o.Visible = true
                elseif k == "line" then
                    local fl = (math.random() < 0.3) and 0.3 or (1 - t)
                    local from = Vector2.new(cx + pt.ax, cy + pt.ay)
                    local to = Vector2.new(cx + pt.bx, cy + pt.by)
                    o.From, o.To, o.Transparency, o.Visible = from, to, fl, true
                    if pt.glow then
                        pt.glow.From, pt.glow.To = from, to
                        pt.glow.Transparency = fl * 0.35
                        pt.glow.Visible = true
                    end
                elseif k == "text" then
                    o.Position = Vector2.new(cx, cy - 70 - 60 * t)
                    o.Transparency = 1 - t * t
                    o.Visible = true
                end
            end)
            if not ok then hideParticle(pt) end
        end
    end
end

local function destroyParticles()
    for i = #particles, 1, -1 do
        removeParticle(particles[i])
        particles[i] = nil
    end
end

local queue = {}
local qi = 1
local queueCombo = nil
local lastQueueList = nil
local cycleSawAlive = false
local skipRespawnMsg = false

local function ownHealth()
    local ok, hp, max = pcall(function()
        local hum = localPlayer().Character:FindFirstChild("Humanoid")
        if not hum then return nil end
        return hum.Health, hum.MaxHealth
    end)
    if ok and hp then return hp, max end
    return nil
end

local function queueIndex(name)
    for i, n in ipairs(queue) do
        if n == name then return i end
    end
    return nil
end

local function selectedQueueName()
    if not queueCombo then return nil end
    local ok, t = pcall(function() return queueCombo:GetText() end)
    if ok and t and t ~= "" and t ~= "(empty)" then return t end
    return nil
end

local function refreshQueue(force)
    if not queueCombo then return end
    local joined = table.concat(queue, ",")
    if not force and joined == lastQueueList then return end
    lastQueueList = joined

    local prev = selectedQueueName()
    pcall(function() queueCombo:Clear() end)
    if #queue == 0 then
        pcall(function() queueCombo:Add("(empty)") end)
        pcall(function() queueCombo:SetValue(0) end)
        return
    end
    local idx = 0
    for i, n in ipairs(queue) do
        pcall(function() queueCombo:Add(n) end)
        if n == prev then idx = i - 1 end
    end
    pcall(function() queueCombo:SetValue(idx) end)
end

local function addToQueue(name)
    if not name or queueIndex(name) then return end
    queue[#queue + 1] = name
    dbg("[orbit] queued:", name)
    refreshQueue(true)
end

local function addAllToQueue()
    local lp = localPlayer()
    for _, plr in ipairs(allPlayers()) do
        if plr ~= lp and not queueIndex(plr.Name) then
            queue[#queue + 1] = plr.Name
        end
    end
    refreshQueue(true)
end

local function removeFromQueue(name)
    local i = name and queueIndex(name)
    if not i then return end
    table.remove(queue, i)
    if i < qi then qi = qi - 1 end
    if qi < 1 or qi > #queue then qi = 1 end
    dbg("[orbit] removed from queue:", name)
    refreshQueue(true)
end

local function clearQueue()
    queue = {}
    qi = 1
    cycleSawAlive = false
    refreshQueue(true)
end

local function advanceCycle()
    local n = #queue
    if n == 0 then return nil end
    local firstIn = nil
    for step = 1, n do
        local idx = (qi - 1 + step) % n + 1
        local plr = findPlayer(queue[idx])
        if plr then
            if not firstIn then firstIn = { idx, plr } end
            local alive = playerState(plr)
            if alive then
                qi = idx
                return plr
            end
        end
    end
    if firstIn then
        qi = firstIn[1]
        return firstIn[2]
    end
    return nil
end

local function cycleTarget()
    if #queue == 0 then return nil end
    if qi > #queue then qi = 1 end
    local target = findPlayer(queue[qi])
    if not target then
        cycleSawAlive = false
        return advanceCycle()
    end
    local alive = playerState(target)
    if alive then
        cycleSawAlive = true
    elseif cycleSawAlive then
        cycleSawAlive = false
        spawnKillParticles(false, target.Name)
        local prevName = target.Name
        local nxt = advanceCycle()
        if nxt and nxt.Name ~= prevName then
            pushEvent("Next target: " .. nxt.Name, 255, 200, 80)
            dbg("[orbit] target died, moving on to:", nxt.Name)
        end
        return nxt or target
    end
    return target
end

local respawnSeen = nil
local waitReason = nil
local ffNotified = false
local lastEquipTry = 0
local equipTries = 0
local lastMyChar = nil

local function hasForcefield(plr)
    local ok, has = pcall(function()
        local char = plr.Character
        if not char then return false end
        for _, child in ipairs(char:GetChildren()) do
            if child.ClassName == "ForceField" then return true end
            local n = child.Name
            if n == "ForceField" or n == "FORCEFIELD" or n == "SpawnForceField" then return true end
        end
        return false
    end)
    if not ok then
        warnOnce("ffcheck", "forcefield check failed: " .. tostring(has))
        return false
    end
    return has == true
end

local function describeChildren(plr)
    pcall(function()
        local names = {}
        for _, c in ipairs(plr.Character:GetChildren()) do
            names[#names + 1] = c.ClassName .. ":" .. c.Name
            if #names >= 30 then break end
        end
        dbg("[orbit] character children:", table.concat(names, ", "))
    end)
end

local landedAt = 0

local function holdingTool()
    local ok, has = pcall(function()
        for _, child in ipairs(localPlayer().Character:GetChildren()) do
            if child.ClassName == "Tool" then return true end
        end
        return false
    end)
    return ok and has == true
end

local function autoEquip()
    local slot = tonumber(UI.GetValue("orb_slot")) or 0
    if slot < 1 or slot > 9 then return end

    local now = os.clock()
    if now - landedAt < 0.15 then return end
    if now - lastEquipTry < 0.4 then return end

    if holdingTool() then
        equipTries = 0
        return
    end
    if equipTries >= 6 then
        warnOnce("equiptries", "auto equip pressed slot " .. slot .. " 6 times and your hands are still empty")
        return
    end
    if type(keypress) ~= "function" then
        warnOnce("nokeypress", "keypress is not available here, so auto equip can't press hotbar keys")
        return
    end
    if type(isrbxactive) == "function" then
        local okF, focused = pcall(isrbxactive)
        if okF and not focused then return end
    end

    lastEquipTry = now
    equipTries = equipTries + 1
    local vk = 0x30 + slot
    pcall(function()
        keypress(vk)
        task.wait(0.05)
        if type(keyrelease) == "function" then keyrelease(vk) end
    end)
    dbg("[orbit] auto equip: pressed slot", slot, "(try " .. equipTries .. ")")
end

local lastStomp = 0
local stompActive = false

local function autoStomp()
    local now = os.clock()
    if now - lastStomp < 0.12 then return end
    if type(keypress) ~= "function" then
        warnOnce("nokeypress2", "keypress is not available here, so auto stomp can't press E")
        return
    end
    if type(isrbxactive) == "function" then
        local okF, focused = pcall(isrbxactive)
        if okF and not focused then return end
    end

    lastStomp = now
    pcall(function()
        keypress(0x45)
        task.wait(0.03)
        if type(keyrelease) == "function" then keyrelease(0x45) end
    end)
    throttled("stomp", 1, "[orbit] auto stomp: pressing E")
end

UI.AddTab("Zeyy Hook", function(tab)
    local s = tab:Section("Orbit", "Left")
    s:Toggle("orb_on", "Orbit", true)
    kb = s:Keybind("orb_kb", 0x58, "toggle")
    local ok, err = pcall(function() kb:AddToHotkey("Zeyy Hook", "orb_on") end)
    if not ok then warnOnce("hotkey", "AddToHotkey failed: " .. tostring(err)) end
    s:Combo("orb_side", "Side", {"Above", "Below"}, 0)
    s:Tip("Sit above or below the target. Stomping always uses above")
    s:Combo("orb_part", "Teleport To", {"Hitbox (Root)", "Torso"}, 0)
    s:Tip("Which part of the target you follow. Torso uses UpperTorso (R15) or Torso (R6) and falls back to the root if the part is missing")
    s:Combo("orb_rot_head", "Rotation On Target", {"Normal", "Face Up", "Face Down", "Upside Down", "Spin"}, 0)
    s:SliderInt("orb_offset", "Offset (studs)", 0, 15, 3)
    s:SliderInt("orb_lead", "Prediction (ms)", 0, 200, 40)
    s:Tip("Leads the target by this much so you stay on them while they move")
    s:Button("Stop & Return", function() UI.SetValue("orb_on", false) end)

    local m = tab:Section("Movement", "Left")
    m:Toggle("orb_circ", "Circle Target", false)
    m:Tip("Move in a circle around the target instead of sitting still")
    m:SliderInt("orb_circ_r", "Circle Radius", 1, 20, 6)
    m:SliderInt("orb_circ_spd", "Circle Speed", 1, 40, 10)
    m:Toggle("orb_jit", "Jitter", false)
    m:Tip("Randomly shakes your position every frame so you are harder to track")
    m:SliderInt("orb_jit_r", "Jitter Radius", 1, 15, 4)

    local tp = tab:Section("Tap Mode", "Right")
    tp:Toggle("orb_tap", "Enabled", false)
    tp:Tip("Instead of hovering, teleport onto the target, shoot, go back to the void, and repeat until they die (with Disable Void on, you stay on the target instead)")
    tp:SliderInt("orb_tap_on", "On Time (ms)", 10, 1000, 150)
    tp:SliderInt("orb_tap_shoot", "Shoot Delay (ms)", 0, 500, 60)
    tp:SliderInt("orb_tap_off", "Void Time (ms)", 10, 2000, 250)
    tp:Toggle("orb_tap_aim", "Aim At Target", true)
    tp:Tip("Moves your cursor onto the target before each shot")
end)

UI.AddTab("Zeyy Targeting", function(tab)
    local t = tab:Section("Target", "Left")
    t:Toggle("orb_only", "Target Only", false)
    t:Tip("Only orbit the player picked below")
    targetCombo = t:Combo("orb_target", "Player", {"(none)"}, 0)
    t:Button("Refresh Players", function() refreshPlayers(true) end)
    t:Combo("orb_xhair", "Aim From", {"Mouse", "Screen Center"}, 0)
    t:SliderInt("orb_fov", "Max Distance From Aim (px)", 50, 3000, 3000)
    t:Toggle("orb_ko", "K.O. Counts As Dead", false)

    local c = tab:Section("Combat", "Left")
    c:Toggle("orb_equip", "Auto Equip", false)
    c:SliderInt("orb_slot", "Hotbar Slot", 1, 9, 1)
    c:Tip("Presses this hotbar number when you land on the target empty-handed")
    c:Toggle("orb_stomp", "Auto Stomp", false)
    c:Tip("When the target is K.O.'d, drop close and press E until they are finished (pauses auto equip)")
    c:SliderInt("orb_stomp_h", "Stomp Height (studs)", 0, 8, 2)

    local q = tab:Section("Target Cycle", "Right")
    q:Toggle("orb_cycle", "Cycle Targets", false)
    q:Tip("Orbit everyone in the queue. When one dies, move to the next and keep looping through the list")
    queueCombo = q:Combo("orb_queue", "Queue", {"(empty)"}, 0)
    q:Button("Add Selected Player", function() addToQueue(selectedName()) end)
    q:Button("Add All Players", function() addAllToQueue() end)
    q:Button("Remove Selected", function() removeFromQueue(selectedQueueName()) end)
    q:Button("Clear Queue", function() clearQueue() end)
end)

UI.AddTab("Zeyy Void", function(tab)
    local v = tab:Section("Void", "Left")
    v:Toggle("orb_novoid", "Disable Void", false)
    v:Tip("Never teleport to the void. You hold still in place instead. Safe to toggle while already in the void: you return to the target's last spot")
    v:Combo("orb_voidmode", "Spot", {"Far Away", "Sky", "Below Map (safe)"}, 0)
    v:SliderInt("orb_dist", "Distance (studs)", 1000, 1000000, 20000)
    v:Tip("How far away the void spot is. Very large values can glitch physics or get flagged by anti-cheat")
    v:SliderInt("orb_up", "Up Distance (studs)", 0, 1000000, 0)
    v:Tip("Extra height added on top of the spot. Not used by Below Map")
    v:Toggle("orb_camdetach", "Camera Detach", false)
    v:Tip("While you are in the void, the camera views your target instead of following your character")
    v:Combo("orb_rot_void", "Void Rotation", {"Normal", "Face Up", "Face Down", "Upside Down", "Spin"}, 0)
    v:Tip("How your character is rotated while in the void")
    v:Toggle("orb_gunwait", "Void Until Gun Out", true)
    v:Tip("Stay in the void until you have a tool in your hands, then go to the target. Put it away and you return to the void. Replaces Auto Equip while on")
    v:Toggle("orb_anchor", "Anchor In Void", true)
    v:Tip("Freezes your character while it sits in the void so it can't fall, drift or die. Released when you come back")
    v:Toggle("orb_rand", "Random Spots", false)
    v:SliderInt("orb_hop", "Hop Interval (ms, 0 = every frame)", 0, 5000, 1000)
    v:Toggle("orb_ffwait", "Forcefield Wait", false)
    v:Tip("After a respawn, wait until their forcefield is gone (in the void, or holding still if Disable Void is on)")
    v:SliderInt("orb_ffmax", "Max Forcefield Wait (s)", 1, 15, 8)

    local r = tab:Section("Retreat", "Right")
    r:Toggle("orb_lowhp", "Low HP Retreat", false)
    r:Tip("When your health drops low, go to the void until it recovers, then jump back on the target (with Disable Void on, you hold still instead)")
    r:SliderInt("orb_lowhp_pct", "Retreat Below (%)", 1, 99, 30)
    r:SliderInt("orb_lowhp_resume", "Resume At (%)", 1, 100, 80)
end)

UI.AddTab("Zeyy Display", function(tab)
    local d = tab:Section("Display", "Left")
    d:Toggle("orb_hud", "Notifications", true)
    d:SliderInt("orb_hud_y", "Height (px from bottom)", 40, 600, 140)
    d:SliderInt("orb_hud_size", "Text Size", 10, 32, 18)
    d:Combo("orb_hud_font", "Font", {"Monospace", "Plex", "UI", "System"}, 0)
    d:Toggle("orb_debug", "Debug Console Output", false)
    d:Tip("Print status and debug messages to the console")

    local k = tab:Section("Kill Effects", "Right")
    k:Toggle("orb_kp", "Kill Effects", true)
    k:Tip("Plays an effect around your character every time your target dies")
    k:Combo("orb_kp_fx", "Effect", {"Burst", "Shockwave", "Spiral", "Fountain", "Lightning", "Kill Text", "Random"}, 0)
    k:SliderInt("orb_kp_count", "Amount", 5, 100, 30)
    k:SliderInt("orb_kp_size", "Size", 1, 12, 4)
    k:SliderInt("orb_kp_spread", "Spread (px)", 20, 400, 140)
    k:SliderInt("orb_kp_life", "Lifetime (ms)", 200, 3000, 900)
    k:Combo("orb_kp_color", "Color", {"Rainbow", "Red", "White", "Gold"}, 0)
    k:Button("Test Particles", function() spawnKillParticles(true, "Target") end)
end)

-- Roblox destroys parts below workspace.FallenPartsDestroyHeight (default -500),
-- which kills you. Never go below it.
local function safeY(y)
    local h = -500
    pcall(function() h = workspace.FallenPartsDestroyHeight end)
    if type(h) ~= "number" or h ~= h or h < -1e6 then h = -500 end
    return math.max(y, h + 100)
end

local function randomSpot(base, mode, dist, up)
    local a = math.random() * 2 * math.pi
    local r = dist * (0.4 + math.random() * 0.6)
    local ox, oz = math.cos(a) * r, math.sin(a) * r
    if mode == 1 then
        return base[1] + ox, dist * (0.5 + math.random() * 0.5) + up, base[3] + oz
    elseif mode == 2 then
        return base[1] + ox, safeY(-400), base[3] + oz
    end
    return base[1] + ox, base[2] + up, base[3] + oz
end

voidSpot = function(base)
    local mode = UI.GetValue("orb_voidmode") or 0
    local dist = tonumber(UI.GetValue("orb_dist")) or 20000
    local up = tonumber(UI.GetValue("orb_up")) or 0

    if UI.GetValue("orb_rand") then
        local now = os.clock()
        local hop = (tonumber(UI.GetValue("orb_hop")) or 1000) / 1000
        if not curVoid or now - lastHop >= hop then
            lastHop = now
            curVoid = { randomSpot(base, mode, dist, up) }
        end
        return curVoid[1], curVoid[2], curVoid[3]
    end

    curVoid = nil
    if mode == 1 then
        return base[1], dist + up, base[3]
    elseif mode == 2 then
        return base[1], safeY(-400), base[3]
    end
    return base[1] + dist, base[2] + up, base[3]
end

-- Hold still. If we were in the void (or have no hold yet), hold at the
-- target's last known spot (or our saved spot) instead of our current position.
local function holdHere(base)
    if follow and follow.mode == "hold" then return end
    local hx, hy, hz = nil, nil, nil
    if follow and follow.mode == "void" then
        local b = base or saved
        if b then hx, hy, hz = b[1], b[2], b[3] end
    end
    if not hx then
        local r = myRoot()
        if r then hx, hy, hz = readPos(r) end
    end
    if hx then
        local r = myRoot()
        if r then setPos(r, hx, hy, hz) end
        follow = { mode = "hold", x = hx, y = hy, z = hz }
    else
        follow = nil
    end
end

-- Goes to the void, or holds still if Disable Void is on
local function applyVoid(base)
    if UI.GetValue("orb_novoid") then
        curVoid = nil
        holdHere(base)
        return
    end
    local vx, vy, vz = voidSpot(base)
    follow = { mode = "void", x = vx, y = vy, z = vz, base = base,
        rand = UI.GetValue("orb_rand") and true or false }
end

-- Camera detach: while you sit in the void, view the target instead of your character
local function camRestore()
    if not camSwapped then return end
    camSwapped = false
    pcall(function()
        local hum = localPlayer().Character:FindFirstChild("Humanoid")
        if hum then workspace.CurrentCamera.CameraSubject = hum end
    end)
end

local function updateCamera()
    local f = follow
    if UI.GetValue("orb_camdetach") and f and f.mode == "void" then
        local hum = nil
        pcall(function() hum = camTargetChar and camTargetChar:FindFirstChild("Humanoid") end)
        if hum then
            pcall(function()
                local cam = workspace.CurrentCamera
                if cam.CameraSubject ~= hum then cam.CameraSubject = hum end
            end)
            camSwapped = true
            return
        end
    end
    camRestore()
end

local function stopOrbit()
    follow = nil
    camTargetChar = nil
    pcall(camRestore)
    pcall(setNoclip, false)
    pcall(setAnchor, nil, false)
    local root = myRoot()
    if engaged and root and saved then
        setPos(root, saved[1], saved[2], saved[3])
        dbg("[orbit] restored your position")
    end
    engaged = false
    retreating = false
    cycleSawAlive = false
    hudMain = nil
    stompActive = false
    respawnSeen = nil
    ffNotified = false
    pushEvent("Orbit stopped", 255, 255, 255)
    state = STATE_IDLE
    lockedName = nil
    lastPos = nil
    curVoid = nil
    waitReason = nil
    killTrackName = nil
    warned = {}
end

local function goIdle(root)
    hudMain = nil
    follow = nil
    camTargetChar = nil
    stompActive = false
    if state ~= STATE_IDLE then
        if saved then setPos(root, saved[1], saved[2], saved[3]) end
        state = STATE_IDLE
        dbg("[orbit] idle")
    end
end

local function step()
    local cb = UI.GetValue("orb_on") and true or false
    local keyOn = true
    if kb then
        local okK, v = pcall(function() return kb:IsEnabled() end)
        if okK then keyOn = v and true or false end
    end
    if cb ~= lastCb or keyOn ~= lastKey then
        lastCb, lastKey = cb, keyOn
        dbg("[orbit] checkbox:", cb, "| key:", keyOn)
    end

    local want = cb and keyOn
    if want ~= lastWant then
        lastWant = want
        dbg("[orbit] active ->", want)
        if not want then stopOrbit() end
    end
    if not want then return 0.05 end

    local root = myRoot()
    cachedMine = root
    if not root then return 0.05 end

    local myChar = nil
    pcall(function() myChar = localPlayer().Character end)
    if myChar and myChar ~= lastMyChar then
        if lastMyChar then dbg("[orbit] you respawned") end
        lastMyChar = myChar
        equipTries = 0
        lastEquipTry = 0
        landedAt = os.clock() + 0.5
        warned["equiptries"] = nil
    end

    if not engaged then
        local x, y, z = readPos(root)
        if not x then
            warnOnce("pos", "could not read your position")
            return 0.05
        end
        saved = { x, y, z }
        engaged = true
        pushEvent("Orbit started", 255, 255, 255)
        state = STATE_IDLE
        lockedName = nil
        lastPos = nil
    end

    if UI.GetValue("orb_lowhp") then
        local mhp, mmax = ownHealth()
        if mhp and mmax and mmax > 0 then
            local pct = mhp / mmax * 100
            local lo = tonumber(UI.GetValue("orb_lowhp_pct")) or 30
            local hi = tonumber(UI.GetValue("orb_lowhp_resume")) or 80
            if hi < lo then hi = lo end
            if not retreating and state ~= STATE_IDLE and mhp > 0 and pct <= lo then
                retreating = true
                state = STATE_WAIT
                pushEvent("Low HP - retreating", 255, 80, 80)
                dbg("[orbit] low HP, going to the void:", math.floor(pct))
            elseif retreating and pct >= hi then
                retreating = false
                skipRespawnMsg = true
                pushEvent("HP recovered - resuming", 80, 255, 80)
                dbg("[orbit] HP recovered, resuming:", math.floor(pct))
            end
        end
    elseif retreating then
        retreating = false
    end

    if retreating then
        hudMain = nil
        stompActive = false
        if not lastPos then
            local x, y, z = readPos(root)
            if x then lastPos = { x, y, z } end
        end
        if lastPos then applyVoid(lastPos) end
        return 0.02
    end

    local only = UI.GetValue("orb_only") and true or false
    local cycleOn = UI.GetValue("orb_cycle") and true or false
    local target = nil

    if cycleOn then
        if #queue == 0 then
            warnOnce("emptyq", "Cycle Targets is on but the queue is empty")
            goIdle(root)
            return 0.1
        end
        target = cycleTarget()
        if not target then
            warnOnce("qgone", "none of the queued players are in the game")
            goIdle(root)
            return 0.1
        end
        if target.Name ~= lockedName then
            local first = lockedName == nil
            lockedName = target.Name
            dbg("[orbit] target:", lockedName)
            if first then pushEvent("Locked on " .. lockedName, 255, 255, 255) end
        end
    elseif only then
        local name = selectedName()
        if not name then
            warnOnce("pick", "Target Only is on but no target is selected")
            goIdle(root)
            return 0.1
        end
        if name ~= lockedName then
            lockedName = name
            lastPos = nil
            dbg("[orbit] target:", name)
            pushEvent("Locked on " .. name, 255, 255, 255)
        end
        target = findPlayer(name)
        if not target then
            warnOnce("gone", "selected target is not in the game")
            goIdle(root)
            return 0.1
        end
    else
        if lockedName then target = findPlayer(lockedName) end
        if not target then
            lockedName = nil
            local best = pickClosest()
            if best then
                lockedName = best.Name
                lastPos = nil
                target = best
                pushEvent("Locked on " .. best.Name, 255, 255, 255)
            end
        end
        if not target then
            goIdle(root)
            return 0.05
        end
    end

    pcall(function() camTargetChar = target.Character end)
    local alive, pos = playerState(target)
    if target.Name ~= killTrackName then
        killTrackName = target.Name
        killTrackAlive = alive
    else
        if killTrackAlive and not alive then spawnKillParticles(false, target.Name) end
        killTrackAlive = alive
    end
    local hp, maxhp, ko = healthInfo(target)
    hudMain = { name = target.Name, hp = hp, max = maxhp, ko = ko, dead = not alive }

    local blocked = false
    if alive and state == STATE_WAIT and waitReason ~= "gun" and UI.GetValue("orb_ffwait") then
        local now = os.clock()
        if not respawnSeen then
            respawnSeen = now
            dbg("[orbit] target respawned, checking forcefield")
            describeChildren(target)
        end
        local maxw = tonumber(UI.GetValue("orb_ffmax")) or 8
        if hasForcefield(target) and (now - respawnSeen) < maxw then
            blocked = true
            if not ffNotified then
                ffNotified = true
                pushEvent(target.Name .. " respawned - waiting for forcefield", 255, 200, 80)
            end
        elseif ffNotified then
            ffNotified = false
            dbg("[orbit] forcefield wait over")
        end
    end
    hudMain.ff = blocked

    -- Stay in the void until a tool (your gun) is in your hands
    local koStomp = (ko and UI.GetValue("orb_stomp")) and true or false
    local waitGun = alive and not blocked and UI.GetValue("orb_gunwait") and not koStomp and not holdingTool()

    if alive and not blocked and not waitGun then
        if state == STATE_IDLE then
            local x, y, z = readPos(root)
            if x then saved = { x, y, z } end
        end
        if state ~= STATE_HEAD then
            if state == STATE_WAIT then
                if skipRespawnMsg then
                    skipRespawnMsg = false
                elseif waitReason == "gun" then
                    pushEvent("Gun out - on " .. target.Name, 80, 255, 80)
                else
                    pushEvent(target.Name .. " respawned", 80, 255, 80)
                end
            else
                pushEvent("On " .. target.Name, 255, 255, 255)
            end
            state = STATE_HEAD
            waitReason = nil
            dbg("[orbit] on head:", target.Name)
            respawnSeen = nil
            ffNotified = false
            equipTries = 0
            landedAt = os.clock()
            tapPhase = "on"
            tapStart = os.clock()
            tapShot = false
        end
        lastPos = { pos.X, pos.Y, pos.Z }

        local stomping = (ko and UI.GetValue("orb_stomp")) and true or false
        local tapping = (UI.GetValue("orb_tap") and not stomping) and true or false
        if not tapping then curVoid = nil end
        if tapping ~= tapWas then
            tapWas = tapping
            tapPhase = "on"
            tapStart = os.clock()
            tapShot = false
        end
        if stomping ~= stompActive then
            stompActive = stomping
            if stomping then
                pushEvent("Stomping " .. target.Name, 255, 200, 80)
                dbg("[orbit] target is K.O.'d, stomping:", target.Name)
            end
        end

        local off = tonumber(UI.GetValue("orb_offset")) or 3
        if stomping then off = tonumber(UI.GetValue("orb_stomp_h")) or 2 end

        local troot = targetRoot(target)
        if troot then
            local f = {
                mode = "head",
                root = troot,
                off = off,
                below = (not stomping) and UI.GetValue("orb_side") == 1,
                circ = (not stomping) and UI.GetValue("orb_circ") and true or false,
                circR = tonumber(UI.GetValue("orb_circ_r")) or 6,
                circSpd = (tonumber(UI.GetValue("orb_circ_spd")) or 10) / 2,
                jit = (not stomping) and UI.GetValue("orb_jit") and true or false,
                jitR = tonumber(UI.GetValue("orb_jit_r")) or 4,
                lead = (tonumber(UI.GetValue("orb_lead")) or 40) / 1000,
            }
            if tapping then
                local vx, vy, vz = voidSpot(lastPos)
                local onT = (tonumber(UI.GetValue("orb_tap_on")) or 150) / 1000
                local shootDelay = (tonumber(UI.GetValue("orb_tap_shoot")) or 60) / 1000
                if shootDelay >= onT then shootDelay = onT * 0.5 end
                f.tap = true
                f.base = lastPos
                f.rand = UI.GetValue("orb_rand") and true or false
                f.noVoid = UI.GetValue("orb_novoid") and true or false
                f.vx, f.vy, f.vz = vx, vy, vz
                f.onT = onT
                f.offT = (tonumber(UI.GetValue("orb_tap_off")) or 250) / 1000
                f.shootDelay = shootDelay
            end
            follow = f
        end

        if stomping then
            autoStomp()
        elseif UI.GetValue("orb_equip") and not UI.GetValue("orb_gunwait") then
            autoEquip()
        end
    else
        if state == STATE_IDLE then
            local x, y, z = readPos(root)
            if x then saved = { x, y, z } end
        end
        local reason = (not alive) and "dead" or (blocked and "ff" or "gun")
        if reason == "gun" and pos then lastPos = { pos.X, pos.Y, pos.Z } end
        if state ~= STATE_WAIT or waitReason ~= reason then
            state = STATE_WAIT
            waitReason = reason
            if reason == "dead" then
                pushEvent(target.Name .. " died", 255, 80, 80)
                dbg("[orbit] target is dead, waiting:", target.Name)
            elseif reason == "gun" then
                pushEvent("Waiting for gun", 255, 200, 80)
                dbg("[orbit] no tool in hand, waiting in the void until you equip one")
            end
        end
        if not alive then
            respawnSeen = nil
            ffNotified = false
        end
        stompActive = false
        if not lastPos then
            local x, y, z = readPos(root)
            if x then lastPos = { x, y, z } end
        end
        if lastPos then applyVoid(lastPos) end
    end

    return 0.01
end

task.spawn(function()
    dbg("[orbit] loop started")
    while true do
        if stale() then
            destroyHud()
            pcall(setNoclip, false)
            pcall(setAnchor, nil, false)
            pcall(destroyParticles)
            pcall(camRestore)
            follow = nil
            dbg("[orbit] old loop stopped")
            return
        end

        local now = os.clock()
        if now - lastRefresh > 2 then
            lastRefresh = now
            local okR, errR = pcall(refreshPlayers, false)
            pcall(refreshQueue, false)
            if not okR then warnOnce("refresh", "player list refresh failed: " .. tostring(errR)) end
        end

        local ok, result = pcall(step)
        local delay = 0.05
        if ok then
            delay = result or 0.05
        elseif tostring(result) ~= lastErr then
            lastErr = tostring(result)
            dbg("[orbit] error:", result)
        end
        pcall(renderHud)
        task.wait(delay)
    end
end)

task.spawn(function()
    while true do
        if stale() then return end
        pcall(fastFollow)
        pcall(updateCamera)
        pcall(updateParticles)
        task.wait()
    end
end)