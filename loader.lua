--[[
    Drift — loader.

    One line at the console:

        loadstring(game:HttpGet("https://raw.githubusercontent.com/Andreidesteptul/Drift/main/loader.lua"))()

    This file is public. It holds no key list, no token and no payload — only the
    gate origin and the protocol:

        1. auth      POST <gate>/auth          { key, hwid } -> { token, exp }
        2. manifest  GET  <gate>/f/games.txt   (gated)
        3. menu      GET  <gate>/f/menu.txt    (gated)
        4. features  GET  <gate>/f/features.txt and the per-module chunks (gated)

    Every payload request carries x-key / x-hwid / x-token. The worker decides,
    every time: a key revoked in KV dies on the next launch with no republish.

    The card is one object. It fades in on launch, runs four stages, grows a key
    field only when the saved key is missing or refused, then fades out and hands
    the screen to the menu.
]]

local VERSION = "2.0.0"
local PRODUCT = "Drift"

-- ---------------------------------------------------------------- gate -------
local GATE = {
    url = "https://drift-gate.clitanandrei00.workers.dev",
    failClosed = true,
    keyFile = "drift.key",
}

local function gateUrl(path)
    return (GATE.url:gsub("/+$", "")) .. path
end

local function accountId()
    local ok, plr = pcall(function() return game:GetService("Players").LocalPlayer end)
    if ok and plr and plr.UserId then return "uid." .. tostring(plr.UserId) end
    return nil
end

local function machineId()
    if type(gethwid) == "function" then
        local ok, value = pcall(gethwid)
        if ok and value and tostring(value) ~= "" then return tostring(value) end
    end

    if syn and type(syn.get_hwid) == "function" then
        local ok, value = pcall(syn.get_hwid)
        if ok and value and tostring(value) ~= "" then return tostring(value) end
    end

    if type(getgenv) == "function" then
        local ok, env = pcall(getgenv)
        if ok and type(env) == "table" and type(env.gethwid) == "function" then
            local ok2, value = pcall(env.gethwid)
            if ok2 and value and tostring(value) ~= "" then return tostring(value) end
        end
    end

    -- last resort: the account id. Stable per account, not per machine.
    return accountId()
end

-- ------------------------------------------------------------ key storage ----
-- The key is not a secret on this machine: the worker checks it against KV and
-- the device every launch. It is stored so a returning buyer does not retype it.

local KEY_FILES = { GATE.keyFile, "drift_key.txt" }

local function readKeyFile()
    if type(readfile) ~= "function" then return nil end
    for _, path in ipairs(KEY_FILES) do
        local ok, body = pcall(readfile, path)
        if ok and type(body) == "string" then
            local key = body:match("^%s*(%S+)%s*$")
            if key and #key >= 8 then return key end
        end
    end
    return nil
end

local function saveKeyFile(key)
    if type(writefile) ~= "function" then return end
    for _, path in ipairs(KEY_FILES) do
        pcall(writefile, path, key .. "\n")
    end
end

-- --------------------------------------------------------------- request -----
local function requestFn()
    return (syn and syn.request)
        or (http and http.request)
        or (fluxus and fluxus.request)
        or http_request
        or request
end

local session = nil

local function postAuth(key)
    local fn = requestFn()
    if type(fn) ~= "function" then return nil, "this executor has no request()" end

    local hwid = machineId()
    if not hwid then return nil, "no hardware id from this executor" end

    local httpSvc = game:GetService("HttpService")
    local body = httpSvc:JSONEncode({ key = key, hwid = hwid })

    local ok, res = pcall(fn, {
        Url = gateUrl("/auth"),
        Method = "POST",
        Headers = { ["content-type"] = "application/json" },
        Body = body,
    })
    if not ok or type(res) ~= "table" then
        return nil, GATE.failClosed and "gate unreachable" or nil
    end

    local code = tonumber(res.StatusCode or res.Status) or 0
    if code ~= 200 then
        local message = tostring(res.Body or ""):gsub("%s+$", "")
        if message == "" then message = "gate refused (" .. code .. ")" end
        return nil, message
    end

    local parsed
    local pok, value = pcall(function() return httpSvc:JSONDecode(tostring(res.Body)) end)
    if pok and type(value) == "table" then parsed = value end
    if not parsed or type(parsed.token) ~= "string" then
        return nil, "gate reply was unreadable"
    end

    return {
        key = key,
        hwid = hwid,
        token = parsed.token,
        exp = tonumber(parsed.exp) or 0,
    }
end

local function fetchChunk(id)
    if not session then return nil, "no session" end

    local fn = requestFn()
    if type(fn) ~= "function" then return nil, "this executor has no request()" end

    local ok, res = pcall(fn, {
        Url = gateUrl("/f/" .. id .. ".txt"),
        Method = "GET",
        Headers = {
            ["x-key"] = session.key,
            ["x-hwid"] = session.hwid,
            ["x-token"] = session.token,
        },
    })
    if not ok or type(res) ~= "table" then return nil, "chunk unreachable" end

    local code = tonumber(res.StatusCode or res.Status) or 0
    if code ~= 200 then return nil, "chunk refused (" .. code .. ")" end

    local body = tostring(res.Body or "")
    if body == "" or body:sub(1, 1) == "<" then return nil, "chunk was empty" end
    return body
end

-- the feature bridge pulls its modules through the same gate
local function publishChunk()
    if type(getgenv) ~= "function" then return end
    pcall(function()
        getgenv().DriftChunk = function(id) return fetchChunk(id) end
    end)
end

local function compile(src)
    local fn = loadstring or (getgenv and getgenv().loadstring)
    if type(fn) ~= "function" then return nil, "this executor has no loadstring" end
    return fn(src)
end

-- ------------------------------------------------------------------ palette --
local C = {
    bg = Color3.fromRGB(5, 5, 5),
    line = Color3.fromRGB(32, 32, 34),
    hair = Color3.fromRGB(46, 46, 50),
    track = Color3.fromRGB(26, 26, 28),
    text = Color3.fromRGB(237, 237, 237),
    dim = Color3.fromRGB(126, 126, 134),
    white = Color3.fromRGB(255, 255, 255),
    bad = Color3.fromRGB(226, 118, 118),
    field = Color3.fromRGB(13, 13, 14),
}

-- --------------------------------------------------------------------- card --
local function buildCard()
    local parent
    if type(gethui) == "function" then
        local ok, value = pcall(gethui)
        if ok and typeof(value) == "Instance" then parent = value end
    end
    if not parent then parent = game:GetService("CoreGui") end

    for _, child in ipairs(parent:GetChildren()) do
        local name = child.Name
        if name == "drift_boot" or name:match("^drift_gate_") then
            pcall(function() child:Destroy() end)
        end
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "drift_boot"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 2147483000
    gui.Parent = parent
    if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end

    local tw = game:GetService("TweenService")
    local function tween(object, info, duration)
        local t = tw:Create(object, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), info)
        t:Play()
        return t
    end

    local root = Instance.new("Frame")
    root.Name = "card"
    root.AnchorPoint = Vector2.new(0.5, 0.5)
    root.Position = UDim2.fromScale(0.5, 0.5)
    root.Size = UDim2.fromOffset(404, 86)
    root.BackgroundColor3 = C.bg
    root.BackgroundTransparency = 0.04
    root.BorderSizePixel = 0
    root.ClipsDescendants = true
    root.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = root

    local stroke = Instance.new("UIStroke")
    stroke.Color = C.line
    stroke.Thickness = 1
    stroke.Parent = root

    -- mark: a square with one hairline sliding through it
    local mark = Instance.new("Frame")
    mark.Size = UDim2.fromOffset(22, 22)
    mark.Position = UDim2.fromOffset(18, 17)
    mark.BackgroundTransparency = 1
    mark.ClipsDescendants = true
    mark.Parent = root

    local markCorner = Instance.new("UICorner")
    markCorner.CornerRadius = UDim.new(0, 6)
    markCorner.Parent = mark

    local markStroke = Instance.new("UIStroke")
    markStroke.Color = C.white
    markStroke.Thickness = 1.2
    markStroke.Parent = mark

    local sweep = Instance.new("Frame")
    sweep.Size = UDim2.fromOffset(30, 1)
    sweep.Position = UDim2.fromOffset(-4, -16)
    sweep.Rotation = -45
    sweep.BackgroundColor3 = C.white
    sweep.BorderSizePixel = 0
    sweep.Parent = mark

    local wordmark = Instance.new("TextLabel")
    wordmark.Text = "D R I F T"
    wordmark.Font = Enum.Font.GothamBold
    wordmark.TextSize = 12
    wordmark.TextColor3 = C.white
    wordmark.TextXAlignment = Enum.TextXAlignment.Left
    wordmark.BackgroundTransparency = 1
    wordmark.Size = UDim2.fromOffset(110, 16)
    wordmark.Position = UDim2.fromOffset(50, 14)
    wordmark.Parent = root

    local divider = Instance.new("Frame")
    divider.Size = UDim2.fromOffset(1, 10)
    divider.Position = UDim2.fromOffset(148, 17)
    divider.BackgroundColor3 = C.hair
    divider.BorderSizePixel = 0
    divider.Parent = root

    local versionLabel = Instance.new("TextLabel")
    versionLabel.Text = VERSION
    versionLabel.Font = Enum.Font.Code
    versionLabel.TextSize = 10
    versionLabel.TextColor3 = C.dim
    versionLabel.TextXAlignment = Enum.TextXAlignment.Left
    versionLabel.BackgroundTransparency = 1
    versionLabel.Size = UDim2.fromOffset(80, 14)
    versionLabel.Position = UDim2.fromOffset(157, 15)
    versionLabel.Parent = root

    local counter = Instance.new("TextLabel")
    counter.Text = "01 / 04"
    counter.Font = Enum.Font.Code
    counter.TextSize = 10
    counter.TextColor3 = C.dim
    counter.TextXAlignment = Enum.TextXAlignment.Right
    counter.BackgroundTransparency = 1
    counter.Size = UDim2.fromOffset(80, 14)
    counter.Position = UDim2.fromOffset(306, 15)
    counter.Parent = root

    local status = Instance.new("TextLabel")
    status.Text = "› link up"
    status.Font = Enum.Font.Code
    status.TextSize = 11
    status.TextColor3 = C.dim
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextTruncate = Enum.TextTruncate.AtEnd
    status.BackgroundTransparency = 1
    status.Size = UDim2.fromOffset(368, 14)
    status.Position = UDim2.fromOffset(18, 45)
    status.Parent = root

    local track = Instance.new("Frame")
    track.Size = UDim2.fromOffset(368, 2)
    track.Position = UDim2.fromOffset(18, 70)
    track.BackgroundColor3 = C.track
    track.BorderSizePixel = 0
    track.Parent = root

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = C.white
    fill.BorderSizePixel = 0
    fill.Parent = track

    local spark = Instance.new("Frame")
    spark.Size = UDim2.fromOffset(14, 2)
    spark.Position = UDim2.fromOffset(0, 0)
    spark.BackgroundColor3 = C.white
    spark.BackgroundTransparency = 0.55
    spark.BorderSizePixel = 0
    spark.Parent = track

    -- key field, hidden until the gate asks for one
    local keyBox = Instance.new("TextBox")
    keyBox.Size = UDim2.fromOffset(368, 30)
    keyBox.Position = UDim2.fromOffset(18, 86)
    keyBox.BackgroundColor3 = C.field
    keyBox.BorderSizePixel = 0
    keyBox.Font = Enum.Font.Code
    keyBox.TextSize = 11
    keyBox.TextColor3 = C.text
    keyBox.PlaceholderText = "paste your key"
    keyBox.PlaceholderColor3 = Color3.fromRGB(80, 80, 88)
    keyBox.Text = ""
    keyBox.ClearTextOnFocus = false
    keyBox.Visible = false
    keyBox.Parent = root

    local keyCorner = Instance.new("UICorner")
    keyCorner.CornerRadius = UDim.new(0, 6)
    keyCorner.Parent = keyBox

    local keyStroke = Instance.new("UIStroke")
    keyStroke.Color = C.line
    keyStroke.Thickness = 1
    keyStroke.Parent = keyBox

    local keyHint = Instance.new("TextLabel")
    keyHint.Text = "enter submits · the key binds to this device on first use"
    keyHint.Font = Enum.Font.Code
    keyHint.TextSize = 9
    keyHint.TextColor3 = C.dim
    keyHint.TextXAlignment = Enum.TextXAlignment.Left
    keyHint.BackgroundTransparency = 1
    keyHint.Size = UDim2.fromOffset(268, 14)
    keyHint.Position = UDim2.fromOffset(18, 126)
    keyHint.Visible = false
    keyHint.Parent = root

    local submit = Instance.new("TextButton")
    submit.Size = UDim2.fromOffset(92, 28)
    submit.Position = UDim2.fromOffset(294, 122)
    submit.BackgroundColor3 = C.white
    submit.BorderSizePixel = 0
    submit.Font = Enum.Font.GothamBold
    submit.TextSize = 11
    submit.TextColor3 = Color3.fromRGB(10, 10, 10)
    submit.Text = "enter"
    submit.AutoButtonColor = false
    submit.Visible = false
    submit.Parent = root

    local submitCorner = Instance.new("UICorner")
    submitCorner.CornerRadius = UDim.new(0, 6)
    submitCorner.Parent = submit

    local card = {
        gui = gui,
        alive = true,
        expanded = false,
        progress = 0,
    }

    local function setStatus(text, color)
        status.Text = "› " .. text
        status.TextColor3 = color or C.dim
    end

    local function setStage(index, text)
        counter.Text = string.format("%02d / 04", math.clamp(index, 1, 4))
        if text then setStatus(text, C.dim) end
    end

    local function setProgress(alpha)
        card.progress = math.clamp(alpha, 0, 1)
        tween(fill, { Size = UDim2.new(card.progress, 0, 1, 0) }, 0.32)
    end

    local function shake()
        local base = root.Position
        for index = 1, 2 do
            tween(root, { Position = base + UDim2.fromOffset(index == 1 and -4 or 4, 0) }, 0.06)
            task.wait(0.07)
        end
        tween(root, { Position = base }, 0.08)
    end

    local function fail(text)
        setStatus(text, C.bad)
        shake()
    end

    local function expandKey(notice)
        card.expanded = true
        root.Size = UDim2.fromOffset(404, 86)
        keyBox.Visible = true
        keyHint.Visible = true
        submit.Visible = true
        setStatus(notice ~= "" and notice or "key required", notice ~= "" and C.bad or C.white)
        tween(root, { Size = UDim2.fromOffset(404, 174) }, 0.22)
        task.wait(0.23)
        pcall(function() keyBox:CaptureFocus() end)
    end

    local function collapseKey()
        card.expanded = false
        keyBox.Visible = false
        keyHint.Visible = false
        submit.Visible = false
        tween(root, { Size = UDim2.fromOffset(404, 86) }, 0.18)
    end

    local function close()
        if not card.alive then return end
        card.alive = false
        tween(root, { BackgroundTransparency = 1 }, 0.24)
        tween(stroke, { Transparency = 1 }, 0.24)
        for _, child in ipairs(root:GetDescendants()) do
            if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
                pcall(function() tween(child, { TextTransparency = 1 }, 0.2) end)
            elseif child:IsA("Frame") then
                pcall(function() tween(child, { BackgroundTransparency = 1 }, 0.2) end)
            end
        end
        task.delay(0.4, function()
            pcall(function() gui:Destroy() end)
        end)
    end

    -- sweep loop: the only motion on an idle card
    task.spawn(function()
        while card.alive do
            if not card.expanded then
                sweep.Position = UDim2.fromOffset(-4, -16)
                tween(sweep, { Position = UDim2.fromOffset(-4, 18) }, 1.15)
                task.wait(1.45)
            else
                task.wait(0.2)
            end
        end
    end)

    -- spark loop: a soft comet riding the unlit part of the track
    task.spawn(function()
        while card.alive do
            local start = math.floor(card.progress * 354)
            spark.Position = UDim2.fromOffset(start, 0)
            tween(spark, { Position = UDim2.fromOffset(354, 0) }, 1.05)
            task.wait(1.15)
        end
    end)

    card.setStatus = setStatus
    card.setStage = setStage
    card.setProgress = setProgress
    card.fail = fail
    card.expandKey = expandKey
    card.collapseKey = collapseKey
    card.close = close
    card.keyBox = keyBox
    card.submit = submit

    return card
end

-- ------------------------------------------------------------------- prompt --
local function askKey(card, notice)
    card:expandKey(notice)

    local entered = nil
    local box = card.keyBox

    local function submit()
        local value = (box.Text or ""):gsub("%s", "")
        if #value < 8 then
            card:fail("key is too short")
            return
        end
        entered = value
    end

    local clickConnection = card.submit.MouseButton1Click:Connect(submit)
    local focusConnection = box.FocusLost:Connect(function(enterPressed)
        if enterPressed then submit() end
    end)

    local deadline = os.clock() + 240
    while not entered and card.gui.Parent and os.clock() < deadline do
        task.wait(0.05)
    end

    clickConnection:Disconnect()
    focusConnection:Disconnect()
    card:collapseKey()

    return entered
end

local function ensureSession(card)
    if session then return true end

    local saved = readKeyFile()
    if saved then
        card:setStatus("checking saved key", C.dim)
        local auth, err = postAuth(saved)
        if auth then
            session = auth
            publishChunk()
            card:setStatus("key verified", C.white)
            return true
        end
        card:setStatus("saved key refused", C.bad)
        warn("[drift] saved key refused: " .. tostring(err))
        task.wait(0.5)
    end

    local notice = ""
    for _ = 1, 3 do
        local typed = askKey(card, notice)
        if not typed then return false, "no key entered" end

        card:setStatus("verifying", C.dim)
        local auth, err = postAuth(typed)
        if auth then
            session = auth
            saveKeyFile(typed)
            publishChunk()
            card:setStatus("key accepted", C.white)
            return true
        end

        notice = tostring(err or "key refused")
        card:fail(notice)
        warn("[drift] " .. notice)
        task.wait(0.8)
    end

    return false, "key refused"
end

-- ---------------------------------------------------------------- manifest ----
local function parseManifest(body)
    local httpSvc = game:GetService("HttpService")
    local ok, data = pcall(function() return httpSvc:JSONDecode(body) end)
    if not ok or type(data) ~= "table" then return nil, "manifest is not json" end

    local raw = data.games or data
    if type(raw) ~= "table" then return nil, "manifest has no games list" end

    local out = {}
    for _, entry in ipairs(raw) do
        if type(entry) == "table" and entry.id and entry.name then
            local places = {}
            if type(entry.places) == "table" then
                for _, place in ipairs(entry.places) do
                    local n = tonumber(place)
                    if n then places[n] = true end
                end
            end
            local single = tonumber(entry.place)
            if single then places[single] = true end

            out[#out + 1] = {
                id = tostring(entry.id),
                name = tostring(entry.name),
                places = places,
                universe = tonumber(entry.universe),
            }
        end
    end

    return out
end

local function matchGame(games)
    local place = tonumber(game.PlaceId) or 0
    local universe = tonumber(game.GameId) or 0

    for _, entry in ipairs(games or {}) do
        if entry.places[place] then return entry end
        if entry.universe and universe ~= 0 and entry.universe == universe then return entry end
    end
    return nil
end

-- ------------------------------------------------------------------- launch --
local card = buildCard()

local ok, err = pcall(function()
    card:setStatus("link up", C.dim)
    task.wait(0.12)

    -- 1. auth
    card:setStage(1)
    local unlocked, gateError = ensureSession(card)
    if not unlocked then
        error(tostring(gateError or "key refused"), 0)
    end
    card:setProgress(0.25)

    -- 2. manifest
    card:setStage(2, "syncing manifest")
    local manifestBody, manifestError = fetchChunk("games")
    if not manifestBody then error(tostring(manifestError or "manifest unavailable"), 0) end

    local games, parseError = parseManifest(manifestBody)
    if not games then error(tostring(parseError), 0) end

    local target = matchGame(games)
    card:setProgress(0.5)
    if target then
        card:setStatus("profile: " .. target.name, C.white)
    else
        card:setStatus("no profile for this place · menu only", C.dim)
    end
    task.wait(0.15)

    -- 3. menu
    card:setStage(3, "loading menu")
    local menuSource, menuError = fetchChunk("menu")
    if not menuSource then error(tostring(menuError or "menu unavailable"), 0) end

    local menuChunk, compileError = compile(menuSource)
    if type(menuChunk) ~= "function" then
        error(tostring(compileError or "menu does not compile"), 0)
    end
    card:setProgress(0.75)
    task.wait(0.1)

    -- 4. features
    card:setStage(4, "wiring features")
    local env = (type(getgenv) == "function" and getgenv()) or _G
    env.DriftFeatures = nil

    card:setStatus("ready · press insert", C.white)
    card:setProgress(1)
    task.wait(0.24)
    card.close()

    local lib = menuChunk()
    if type(lib) ~= "table" then error("menu returned nothing", 0) end
    env.DriftLib = lib

    local featureBody = fetchChunk("features")
    if featureBody then
        local featureChunk, featureError = compile(featureBody)
        if type(featureChunk) == "function" then
            local featureOk, featureErr = pcall(featureChunk)
            if not featureOk then warn("[drift] features: " .. tostring(featureErr)) end
        else
            warn("[drift] features do not compile: " .. tostring(featureError))
        end
    else
        warn("[drift] features chunk unavailable")
    end

    -- the game profile rides the legacy global: southlondon.lua reads it
    local profile = {
        version = VERSION,
        product = PRODUCT,
        game = target and {
            id = target.id,
            name = target.name,
            place = tonumber(game.PlaceId) or 0,
            universe = tonumber(game.GameId) or 0,
        } or nil,
    }
    env.TeaPremium = profile
    env.DriftSession = profile

    if target then
        local gameBody = fetchChunk(target.id)
        if gameBody then
            local gameChunk, gameError = compile(gameBody)
            if type(gameChunk) == "function" then
                local gameOk, gameErr = pcall(gameChunk)
                if not gameOk then warn("[drift] profile: " .. tostring(gameErr)) end
            else
                warn("[drift] profile does not compile: " .. tostring(gameError))
            end
        else
            warn("[drift] profile chunk unavailable")
        end
    end

    print(string.format("[drift] %s ready · %s · press INSERT",
        VERSION, target and target.name or "no profile"))
end)

if not ok then
    pcall(function()
        card:fail(tostring(err))
    end)
    warn("[drift] launch stopped: " .. tostring(err))
    task.wait(2.4)
    pcall(function() card:close() end)
end
