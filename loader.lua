--[[
    Drift â€” loader.

    Users run ONE line:

        loadstring(game:HttpGet("<host>/init.txt"))()

    This file is public. Assume it is read line by line, and that anything
    written in it is a fact the buyer already knows. So it holds no key list,
    no token, and no payload: it holds a URL and a prompt.

      1. gate     -> POST <worker>/auth { key, hwid } -> { token, exp }
      2. manifest -> GET  <worker>/f/games.txt   (gated)
      3. run      -> GET  <worker>/f/menu.txt    (gated), then f/features.txt

    Every payload request carries x-key / x-hwid / x-token. The worker decides,
    every time. Revoking a key in KV kills it on the next launch, no republish.
]]

local PRODUCT  = "Drift"
local VERSION  = "1.3.0"

-- ---------------------------------------------------------------- gate -------
-- Point this at the deployed worker. The worker rewrites this line to its own
-- origin when it serves the loader, so a redeploy needs no edit here.
local GATE = {
        url = "https://drift-gate.clitanandrei00.workers.dev",
    -- worker unreachable => refuse the launch. A local fallback is a free pass.
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
        local ok, v = pcall(gethwid)
        if ok and v and tostring(v) ~= "" then return tostring(v) end
    end

    if syn and type(syn.get_hwid) == "function" then
        local ok, v = pcall(syn.get_hwid)
        if ok and v and tostring(v) ~= "" then return tostring(v) end
    end

    if type(getgenv) == "function" then
        local ok, env = pcall(getgenv)
        if ok and type(env) == "table" and type(env.gethwid) == "function" then
            local ok2, v = pcall(env.gethwid)
            if ok2 and v and tostring(v) ~= "" then return tostring(v) end
        end
    end

    -- last resort: the account id. Stable per account, not per machine.
    return accountId()
end

-- ------------------------------------------------------------ key storage ----
-- The key itself is not a secret on this machine â€” the worker checks it against
-- KV and the device every launch. It is stored so a returning buyer does not
-- retype it.

local KEY_FILES = { GATE.keyFile, "drift_key.txt" }

local function readKeyFile()
    if type(readfile) ~= "function" then return nil end
    for _, p in ipairs(KEY_FILES) do
        local ok, body = pcall(readfile, p)
        if ok and type(body) == "string" then
            local key = body:match("^%s*(%S+)%s*$")
            if key and #key >= 8 then return key end
        end
    end
    return nil
end

local function saveKeyFile(key)
    if type(writefile) ~= "function" then return end
    for _, p in ipairs(KEY_FILES) do
        pcall(writefile, p, key .. "\n")
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

-- ----------------------------------------------------------------- prompt ----
-- Blocking, self-contained, and gone the moment a key is accepted or the window
-- is closed. Nothing else in this file draws before the gate answers.

local function askKey(notice)
    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    local gui = Instance.new("ScreenGui")
    gui.Name = "drift_gate_" .. tostring(math.random(100000, 999999))
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 2147483000
    gui.Parent = parent
    if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(324, 138)
    frame.Position = UDim2.new(0.5, -162, 0.5, -69)
    frame.BackgroundColor3 = Color3.fromRGB(7, 7, 7)
    frame.BackgroundTransparency = 0.04
    frame.BorderSizePixel = 0
    frame.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(38, 38, 42)
    stroke.Thickness = 1
    stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.Text = "DRIFT"
    title.Font = Enum.Font.GothamBold
    title.TextSize = 12
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.BackgroundTransparency = 1
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Size = UDim2.new(1, -32, 0, 18)
    title.Position = UDim2.fromOffset(16, 14)
    title.Parent = frame

    local hint = Instance.new("TextLabel")
    hint.Text = notice ~= "" and notice or "enter your key"
    hint.Font = Enum.Font.Gotham
    hint.TextSize = 11
    hint.TextColor3 = notice ~= "" and Color3.fromRGB(235, 105, 105) or Color3.fromRGB(125, 125, 133)
    hint.BackgroundTransparency = 1
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextTruncate = Enum.TextTruncate.AtEnd
    hint.Size = UDim2.new(1, -32, 0, 14)
    hint.Position = UDim2.fromOffset(16, 33)
    hint.Parent = frame

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -32, 0, 34)
    box.Position = UDim2.fromOffset(16, 53)
    box.BackgroundColor3 = Color3.fromRGB(16, 16, 18)
    box.BorderSizePixel = 0
    box.Font = Enum.Font.Gotham
    box.TextSize = 12
    box.TextColor3 = Color3.fromRGB(237, 237, 239)
    box.PlaceholderText = "key"
    box.PlaceholderColor3 = Color3.fromRGB(88, 88, 96)
    box.Text = ""
    box.ClearTextOnFocus = false
    box.Parent = frame

    local boxCorner = Instance.new("UICorner")
    boxCorner.CornerRadius = UDim.new(0, 6)
    boxCorner.Parent = box

    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, -32, 0, 32)
    button.Position = UDim2.fromOffset(16, 94)
    button.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12
    button.TextColor3 = Color3.fromRGB(10, 10, 10)
    button.Text = "unlock"
    button.AutoButtonColor = false
    button.Parent = frame

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 6)
    buttonCorner.Parent = button

    box:CaptureFocus()

    local entered = nil
    local function submit()
        local value = (box.Text or ""):gsub("%s", "")
        if #value < 8 then
            hint.Text = "key is too short"
            hint.TextColor3 = Color3.fromRGB(235, 105, 105)
            return
        end
        entered = value
        gui:Destroy()
    end

    button.MouseButton1Click:Connect(submit)
    box.FocusLost:Connect(function(enterPressed)
        if enterPressed then submit() end
    end)

    local deadline = os.clock() + 240
    while not entered and gui.Parent and os.clock() < deadline do
        task.wait(0.1)
    end
    if gui.Parent then gui:Destroy() end

    return entered
end

-- the feature bridge pulls its modules through the same gate
local function publishChunk()
    if type(getgenv) ~= "function" then return end
    pcall(function()
        getgenv().DriftChunk = function(id) return fetchChunk(id) end
    end)
end

local function ensureSession()
    if session then return true end

    local saved = readKeyFile()
    if saved then
        local auth, err = postAuth(saved)
        if auth then
            session = auth
            publishChunk()
            return true
        end
        warn("[drift] saved key refused: " .. tostring(err))
    end

    local notice = ""
    for _ = 1, 3 do
        local typed = askKey(notice)
        if not typed then return false, "no key entered" end

        local auth, err = postAuth(typed)
        if auth then
            session = auth
            saveKeyFile(typed)
            publishChunk()
            return true
        end

        notice = tostring(err or "key refused")
        warn("[drift] " .. notice)
    end

    return false, "key refused"
end

local function compile(src)
    local fn = loadstring or (getgenv and getgenv().loadstring)
    if type(fn) ~= "function" then return nil, "this executor has no loadstring" end
    return fn(src)
end

-- Palette rides the menu's :root to the byte.
local C = {
    bg      = Color3.fromRGB(5, 7, 5),        -- #050705
    win     = Color3.fromRGB(6, 8, 5),        -- #060805
    text    = Color3.fromRGB(232, 237, 228),  -- #E8EDE4
    dim     = Color3.fromRGB(154, 163, 150),  -- #9AA396
    dim2    = Color3.fromRGB(110, 117, 104),  -- #6E7568
    white   = Color3.fromRGB(244, 248, 240),  -- #F4F8F0
    accent  = Color3.fromRGB(169, 209, 142),  -- #A9D18E
    accent2 = Color3.fromRGB(198, 229, 179),  -- #C6E5B3
    adark   = Color3.fromRGB(95, 143, 78),    -- #5F8F4E
    dark    = Color3.fromRGB(10, 20, 8),      -- #0A1408
    ok      = Color3.fromRGB(169, 209, 142),
    bad     = Color3.fromRGB(227, 143, 143),
    line    = Color3.fromRGB(48, 48, 54),     -- #303036 hairline on off-pill
    off     = Color3.fromRGB(110, 113, 116), -- unsupported text
}

-- hero assets: ring leaf + falling silhouettes
local ASSETS = {
    ringLeaf = "iVBORw0KGgoAAAANSUhEUgAAAHAAAABwCAYAAADG4PRLAAAKgElEQVR4AeydfYwcZR3Hf8/sXntN41kgiiX4RmJti3d7NpYSo3/U" ..
        "xAQhtDbI3hEjUilRozTuHVKJGs4EkURutySEhCgiJKS3i0K1pspfqBByaqm3V6OIvCWttvYsxb7Rl7t5eL57HXKZffZlZp7nmXmG" ..
        "2czvZuZ5nt/rp8+z89JeHco+VlcgA2g1PqIMYAbQ8gpYHn42AzOAllfA8vCzGZgBtLwCloefzcB3JkDLs05R+NkMtBxmBjADaHkF" ..
        "LA8/m4EZQMsrYHn42QzMAFpeAcvDz2ZgBjBABQwOvfH+TSu+XLn2LgiODbo26iqVMxDA2Lm5vxCx70JwjDZK4SeVANm52RsFqz4h" ..
        "3tZ3vs07T83eeoAP7nmwZ+Kv966dmCpvrk5V7qnVK7UPXHLJ1/2E0IY+jMFY6DzNx/L+cbadWwew9lx5yY76+IbadGVcAJlc1nPy" ..
        "LHOcPzNGPyPGt3Hi1+dyuQv9INCGPozBWOgcnu47V6uXJ2vCVsOmsO3XS/q5NQB37K18oTpV/g1fSqccYr/inI8IIOuiFpgTrYOt" ..
        "hk1hGz7gK6pdU/qOKUdh/WBmVOvl550cf5wYXRPWTtd6wgd8waeQa7vWi2lgYgH+Yt/2gYl6eacjZpuozRohpjf4/HV1avzJ2nS5" ..
        "37Tzbv053Q40Oa5aHx+bc906I9po0q/UF2Of55ymEZO0P+bGRAHcUf/xulq9MknE7qQFn2QcsjsncMEzVb4iGfHMR5EYgNX6+FaH" ..
        "cpMqLkzmU1P/U6wI6zijPyFW9dbDWUwEQFGQnxCx+8iaD7tvoj4uYo4/4FgBiu8WVquXdxOxLWTZh4mYEbu4BWFxhh4rwNp0Zae4" ..
        "D/tcnAWI4hux16a374xiI6pubACr05WHiPiGTgm8efo0/evV1+jAwUOE407jzffzDfO5mPcMj7EArNYrdxDnX0EAneTp5yYbAKf/" ..
        "8QJN7p1KJkSRSyOnTslo6DcOsLbv3s+KmXd3N7lg1i0chxnob1vYH+8xv3s+N7NRGAfIXafrq00A85cjuQDFH8sAufnzCntuFODE" ..
        "VPlHItBVQrraLl3+vqZxgPr6G280tUsa4mhadT5HY76NAazVt3+UMfpOkMyW9PbShcuWNakcOZpYgIQckWtT0JoajAEkcr8dJoeL" ..
        "LmgGeEBckYaxZU4nXK5h4jMC8LHpymXinunmMAFauIwSckXOYfINqmMEYJ7zUPCQTKtl9MVXXkN3YiVKzkGSMgKQEX0xSFD+sbJl" ..
        "FBcyEP/YpJxHzbnbPLQDrE6NrxdLyge7DUg2TraMYlySZyFyRu6IU6doB0gOXRU1ASyjH/nwh5rMYAZCmjqS0qAg906p6Afo0vpO" ..
        "QXTTj1kIkP6x9b+/4G9Kzrmi3NslpBXgw68+3EuMrW0XQLd9gCebhbixx8Pubu10HqdwhMi9UQOFJv2mtALsPfb/gt9hlPOLxD2h" ..
        "7MYeACFRbOvSVV0Df5xaAeYcvsLvMMo5ZiGWUpkN3Nwn8ftQdQ38uWsFKN5WR7r69AeLcwBstZTi+xBLKsZFEdiARLHh6eqogWcb" ..
        "e60Axb3QxXCiWgBRtpSi6IAYxR/eOeIdJATvIKPYgq6uGsA2RCtA7lLzg0yK/sFSWli9krD3W8Myuv/gQX9zV+cHxDNW6HuDcQ7x" ..
        "zsPsxf2glhp4sWgFyBjr8Ryp3gPelWsGpWZnZ+ek7Z0aZbAwqzvptetnXF8N4FcrQM7dk3CiSwBxYNVKZeYXzj7PKHx4x2H2umug" ..
        "FSCRMxMm6SA6+D6UXdQEsYGxstmHdtjHPrzorYFWgIzocPjEu9cEQEg7jU7LqgxgIHgtnDNHbw20AnQZ/0+LvJQ3A2C75fT4yfar" ..
        "uWz5lF3pBg2ccb010AqQuWx/0ISjjMeMWf/JKwObaPUUB/YCG/MpuJproBXg2Tl6xZeP9lNcdLx/+fImP+9aurSpzWuQAVQBD/Z1" ..
        "10ArwC99ohTuhgyZR5B8PtekLWvDoFY366oA6q6BVoAokJB9QhK54R5PdvGC7z5I9KD536LbaG/BBMBn2ocQX2+rx24rLmt+eRwq" ..
        "Sof9MZReACX9ADl/PkA8xobiqhPid4ilU83sI3Jd2uu3r/pcO0Cem/uD6qCj2sPSiYfWMju4HZG1h2nrdfK/D6MXREc7wOH+218W" ..
        "D3T3BAlK99hWSyfg4SpWhX/GaM+m/q0vd7IVtV87QATIOE1gnwTBzJMtnVg2AVBVjJyZydkIwDzLV1UVJood3O/J4MEmXk9hr0pc" ..
        "4jVVttrZMQLwusLWA8TppXaB6O47IR6lAaDMD15LqVo6G/YZvXRD/6iRp1BGAM4nxQP9y6SGjsIfM68flVrDsonlU9oZtpGby9UY" ..
        "wKHC6C+JmLyKFM8H4ABQrXd2dD5XtVZbWTMGsBGAO3dPY5+AH4CHpVN5KC4ZzdEoQLZoyQPiu/CU8qIFNKgNHqdTbNGiBwKGE2m4" ..
        "UYDFy79xghwqR4q4C2VcsLQapg0eHIrcGjni2JAYBYicWP+lY2Kv9QrtXIu/1ITHZFqWTZGQ2Pafz00cat/edmAcYJEV5zhjd7wd" ..
        "gYaDJb2Lm6wu6+ujdm/smxQCNiAn5BZQLfJw4wAR8fBA6TFGpO0tRe/iZoAXvHvhL7FHFOpEPCp8Bjmps9i9pVgAIjzXyW/GPhUS" ..
        "Yy6xARwWD3o5p1ttB4gckEtcecQGEAkPD47cL5bS3+LYRkHsyCHO2GMF2Eic0y3iT/H/Gsd2/ZiZW9wT++85jR1gcXDk37kc+6pd" ..
        "7Ig4Z1+7YeWtxv7ea6v6xA4QgV3fX3qCMTaKYxsEsQ4Plp5IQqyJAIhCFAdKZc659qc08BVFECNijWJDpW4wgCo9S2wND46KWcif" ..
        "knQlpIk/NR9jQsIRYSQKoIiHxKuYq8TVnbabfPgII7hZR2xhdHXqJA4gkn3PwLHPJAkiYrlYxITYkiaJBLiejc1SfvHVROxZiv0j" ..
        "YhCxNGKKPZbmABIJEGHitUzv4rMCIu3GeUyy+8Txs1cjlpj8d3SbWICIfOPKbceHCiPXMMZ+jnOzwn8K3zd/attxs36DeUs0QC+V" ..
        "4kBpMxHDe0Qy82FjQ4XRW8z4iubFCoBIcahQ+oHY3yRE93bTeV+6/Sixbw1AZDtUGHmEcffTONYhsA0fOmzrsmkEoMrgi4O3Pcvm" ..
        "8u8VNncJUbXtgk3YVmXQlB3rAKIwxTVbZ8RM2UCc7sJ5JBE2YAs2I9mJSdlKgF6thgZHvk+uu0mcHxESdDsC3YaNoJoJGu8kKJZQ" ..
        "oQx9/LadvY5zOSP2eLcGMJadmf0YdLvVSeo46wGisBv7v/XfYqFUZERbhLT8b13QJ2QLxhavuP0QdG2XVAD0IBQLIw/letjq02fO" ..
        "/NNr8/ZoQx/GeG1p2KcKIIBct7p08NDhmd/heKGgDX0L29JwnDqAgMKJn8B+ocjaFvbbepxOgD35RwWQY0K87Rifb/POU7NPMsDQ" ..
        "RX70m0++yHtya4n4DyE4RltogwlWTCVA1BvAHint+h4Ex2hLo6QWYBphyXLKAMqqYlFbBtAiWLJQM4CyqljUlgG0CJYs1AygrCoW" ..
        "tWUALYIlCzWFAGVpprctA2g52wyg5QDfAgAA///BLxajAAAABklEQVQDAMO/LQ7bCuRDAAAAAElFTkSuQmCC",
    fallLeaf = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAYAAACbU/80AAAENklEQVR4AaxVXW/cVBA9Z7zwN9hIFIj4EOWjUp9YA0GKgIcIEARa" ..
        "1RYIUYEq+sBzUyEIQlQVCIggBW8QHxVCFPHSRy8BClTlQyDUxzX/g6w5c6+9u2kSWkLHPnPOnTvje8f2rg1X2T47fzI7feGt4vSF" ..
        "t4vPf36n+OKXd8svf10ZnvntveFXv6+WX/+xWp65WHR92bN/Ftn/3sBHP5zIPv7xRPHJTyeHn55/syaTgmCWkJkZM5I9mnVp7Bql" ..
        "ab1rRxievbh2zMyuM+zCim+Xe8W518u1c2/UKi+gxcRdUl4g3QH0Qzqw6zEA1Fiqwe5/2sAH3y9nH373WskkKQ3sqUOoK8GgbiJT" ..
        "egyGGOmsbZggTVO1tCXJN4YrtFPrr5ao6be3B+9EF4Jby663gCFCOtOrQDoDBCpujKrLbmC1fLl3an15qF33zIuNMGfBQqc+nu5a" ..
        "2mKMgQlSY2lSLJAG0gZzswcHhn8xXxyJlarpUnlEPNCyJjyiIUh6OAJRM7B7AtIUAjP4CrIdN/D++isZ9KwZdws6hy5ih5Q2LRrZ" ..
        "QFJ3RnPcDs2cOVO5hs7I1iAzYcu5Ui51Udd63gCBKTBoj0TlnnBjM+N6DDZKm4tKAWmCg3R2cfs74Isndk3pz5f+ttJAU0nQzoRR" ..
        "LExYOWHcdK9cr/d5s5g/ZuUlG8zRmDU8poSdgkQXcgScwHBIB46j4EOOFDUnrWmQGgBiyFxvBsGq7V4J2LQBf+nUrd5270SpdDZd" ..
        "rGF1Q8XobB5XjmtG7V2TRORY49qU07Imj2PKbEqjNisAIhonipOIrq84BQjOjqgho+Bn4OCakTT17O+7frHvkRbjDayUy10jHYj/" ..
        "ako3dSGQLVMNGEhnzYtJ5yY2nSsdu1atcuSre/csprjErB0nyeiYrqyTCgkqkg86MkAdkJF0D5IIh7PDR4EhNYErI8YvHqYsbCB2" ..
        "b5l5seAcYeqYiHdE2rsSyBgjnbUFZ4GMmjTQEXINiTFP9ywOsI2ZxzodHKILuHf4QKzTVcCUZsiDPIHGtxwjPorQ9zlNL3numDIL" ..
        "3StAEmZCYIudU2yC8xRIzzOQbNBo5VJ5FOv5VzUtnduhczRm6r5LcklQiNjMCoHuIhoZcwDnTQARxxjcf+NTM5dbHDLf6z2xyDuN" ..
        "FzC2HGPmWepMXSFqTpixe68RBlYjnbvhwJa3HTuYauqelqsYEgg/EDydgoJMe5JvT80FGVlz/RqWPnDTwdQ/sWHqCp02kAxo7JNW" ..
        "mREkEVjaO2bLNPg4QjmkapibYWZ+Nsvn9W3HLsyA+q9D+186vqEOQA7oAHWgIjFgDf/n6hPo1/otjzb+nnn41mf40C1P5w/enPfn" ..
        "Z/PwVcMuzTrGcIF8/9HqwL6j6ZP7XkyfuPsIH7/ryMxjd7yQPnrn8/kjew/nC7c/ly/c9mx/Ye/hkL/L9baU/QMAAP//CiEZTgAA" ..
        "AAZJREFUAwDwhL9mEbS4jwAAAABJRU5ErkJggg==",
}

-- ---------------------------------------------------------------- drivers ----
local Players     = game:GetService("Players")
local LP          = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

local function parentGui()
    local g = (gethui and gethui()) or game:GetService("CoreGui")
    local ok = pcall(function() return g end)
    return ok and g or LP:WaitForChild("PlayerGui")
end

local function make(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local function round(o, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = o
    return c
end

local function stroke(o, color, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color or C.accent
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = o
    return s
end

-- soft disk bleed: one rounded frame behind whatever glows
local function aura(parent, size, transparency, color)
    local a = make("Frame", {
        Name = "Aura",
        Size = UDim2.fromOffset(size, size),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        BackgroundColor3 = color or C.accent,
        BackgroundTransparency = transparency or 0.87,
        BorderSizePixel = 0, ZIndex = 0,
    }, parent)
    round(a, math.floor(size / 2) + 1)
    return a
end

local gui = make("ScreenGui", {
    Name = "premium_" .. tostring(math.random(1e6)),
    ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 2147483647,
}, parentGui())
if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end

-- ---------------------------------------------------------------- stage ------
-- The mock's wide stage: the hero floats on the full screen, leaf field over
-- everything, game scene faint behind one dark wash.
local stage = make("Frame", {
    Name = "GameWindow",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = C.bg,
    BackgroundTransparency = 0.30,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, gui)
make("UIGradient", {
    Rotation = 90,
    Color = ColorSequence.new(Color3.fromRGB(7, 10, 7), Color3.fromRGB(4, 7, 4)),
}, stage)

-- atmosphere: soft matcha wash at the ring, deep green under the fold
local topGlow = aura(stage, 380, 0.94)
topGlow.Position = UDim2.new(0.5, 0, 0.18, 0)
local bottomGlow = aura(stage, 900, 0.95, C.adark)
bottomGlow.Position = UDim2.new(0.5, 0, 1.22, 0)

-- assets --------------------------------------------------------------
local function b64d(s)
    s = s:gsub("[^%w%+%/]", "")
    local A = {}
    for i = 65, 90 do A[string.char(i)] = i - 65 end
    for i = 97, 122 do A[string.char(i)] = i - 71 end
    for i = 48, 57 do A[string.char(i)] = i + 4 end
    A["+"] = 62
    A["/"] = 63
    local out = {}
    local i, n = 1, #s
    while i + 3 <= n do
        local n24 = (A[string.char(s:byte(i))] or 0) * 262144
            + (A[string.char(s:byte(i + 1))] or 0) * 4096
            + (A[string.char(s:byte(i + 2))] or 0) * 64
            + (A[string.char(s:byte(i + 3))] or 0)
        out[#out + 1] = string.char(
            (math.floor(n24 / 65536)) % 256,
            (math.floor(n24 / 256)) % 256,
            n24 % 256)
        i = i + 4
    end
    local rem = n - i + 1
    if rem == 2 then
        local n24 = (A[string.char(s:byte(i))] or 0) * 4096
            + (A[string.char(s:byte(i + 1))] or 0) * 64
        out[#out + 1] = string.char((math.floor(n24 / 256)) % 256)
    elseif rem == 3 then
        local n24 = (A[string.char(s:byte(i))] or 0) * 4096
            + (A[string.char(s:byte(i + 1))] or 0) * 64
            + (A[string.char(s:byte(i + 2))] or 0)
        out[#out + 1] = string.char(
            (math.floor(n24 / 65536)) % 256,
            (math.floor(n24 / 256)) % 256)
    end
    return table.concat(out)
end

local IMG = {}
if writefile and getcustomasset then
    for name, b64 in pairs(ASSETS) do
        pcall(function()
            local path = "tea_loader_assets_" .. name .. ".png"
            writefile(path, b64d(b64))
            IMG[name] = getcustomasset(path)
        end)
    end
end

-- intro capture: children ease home on their own delays
local intro = {}
local function shifted(p, dy)
    if p == nil then return UDim2.fromOffset(0, dy) end
    local ok, x = pcall(function() return p.X end)
    if ok and x ~= nil then
        return UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset + dy)
    end
    local t = {}
    for i = 1, #p do t[i] = p[i] end
    if #t == 4 then
        t[4] = t[4] + dy
    elseif #t == 2 then
        t[2] = t[2] + dy
    end
    return UDim2.new(t[1], t[2], t[3], t[4])
end

local function introAdd(o, delay, dy, kind)
    local isStroke = o:IsA("UIStroke")
    local prop
    if isStroke then
        prop = "Transparency"
    elseif o:IsA("ImageLabel") then
        prop = "ImageTransparency"
    elseif kind == "text" or o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox") then
        prop = "TextTransparency"
    else
        prop = "BackgroundTransparency"
    end
    local base = o[prop]
    local p0 = nil
    if not isStroke then
        p0 = o.Position
        o.Position = shifted(p0, dy or 10)
    end
    o[prop] = 1
    intro[#intro + 1] = { o = o, prop = prop, base = base, p0 = p0, delay = delay or 0 }
end

local function playIntro()
    local TweenService = game:GetService("TweenService")
    for _, it in ipairs(intro) do
        local info = TweenInfo.new(0.62, Enum.EasingStyle.Quart,
            Enum.EasingDirection.Out, 0, false, it.delay)
        local goal = { Position = it.p0 }
        goal[it.prop] = it.base
        TweenService:Create(it.o, info, goal):Play()
    end
end

-- ---------------------------------------------------------------- leaf field -
-- Fall over the whole screen. Rolled rounded frames, not PNGs, so the
-- background never depends on getcustomasset landing in the executor. Three
-- depth bands: near leaves are big and solid, far leaves are small ghosts, and
-- everything sways on its own phase so the field never reads as a grid.
local LEAF_BANDS = {
    { wMin = 10, wSpan = 9,  tMin = 0.72, tSpan = 10, sMin = 9,  sSpan = 10, z = 1 },
    { wMin = 18, wSpan = 13, tMin = 0.45, tSpan = 12, sMin = 19, sSpan = 15, z = 1 },
    { wMin = 30, wSpan = 22, tMin = 0.17, tSpan = 14, sMin = 33, sSpan = 22, z = 2 },
}

local function leafField(parent, count)
    local leaves = {}
    for i = 1, count do
        local band = LEAF_BANDS[(i - 1) % #LEAF_BANDS + 1]
        local w = band.wMin + ((i * 7) % band.wSpan)
        local h = math.max(6, math.floor(w * 0.55))
        local trans = band.tMin + ((i * 13) % band.tSpan) / 100
        local leaf = make("Frame", {
            Name = "Leaf" .. i,
            BackgroundColor3 = Color3.fromRGB(169, 209, 142),
            BackgroundTransparency = trans,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(((i * 53) % 100) / 100, 0, ((i * 71) % 100) / 100, 0),
            Size = UDim2.fromOffset(w, h),
            Rotation = (i * 97) % 360,
            ZIndex = band.z,
        }, parent)
        round(leaf, math.max(3, math.floor(h / 2)))
        leaves[#leaves + 1] = {
            img = leaf,
            x0 = ((i * 53) % 100) / 100,
            speed = band.sMin + ((i * 11) % band.sSpan),
            rotSpeed = 9 + ((i * 7) % 24),
            swayAmp = 0.006 + ((i * 5) % 9) / 1000,
            swayRate = 0.5 + ((i * 3) % 11) / 10,
            phase = (i * 1.7) % (math.pi * 2),
        }
    end
    task.spawn(function()
        local last = os.clock()
        while gui and gui.Parent do
            local now = os.clock()
            local dt = math.min(now - last, 0.1)
            last = now
            for _, l in ipairs(leaves) do
                local p = l.img.Position
                local ny = p.Y.Scale + (l.speed * dt) / 720
                local nx = l.x0 + math.sin(now * l.swayRate + l.phase) * l.swayAmp
                if ny > 1.06 then
                    l.x0 = (((l.x0 * 100) + 37) % 96 + 2) / 100
                    l.img.Position = UDim2.new(l.x0, 0, -0.06, 0)
                else
                    l.img.Position = UDim2.new(nx, 0, ny, 0)
                end
                l.img.Rotation = l.img.Rotation + (l.rotSpeed * dt)
            end
            task.wait(0.04)
        end
    end)
end

leafField(stage, 54)

-- ---------------------------------------------------------------- hero -------
-- Mock ratios over a 647-tall reference stage, driven as y fractions of the
-- screen so every resolution holds the composition.
local function fracY(v)
    return UDim2.new(0.5, 0, v / 647, 0)
end

-- ring: 118 circle, dashed halo, leaf mark — round the ring so the stroke
-- follows the circle (the old build forgot the corner and drew a square).
local ring = make("Frame", {
    Name = "HeroRing",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = fracY(117),
    Size = UDim2.fromOffset(118, 118),
    BackgroundTransparency = 1,
    BorderSizePixel = 0, ZIndex = 3,
}, stage)
round(ring, 59)
local ringGlow = aura(ring, 96, 0.88)
ringGlow.ZIndex = 2
local ringStroke = stroke(ring, C.accent, 1, 0.55)
introAdd(ringStroke, 0.05, 0)

local halo = make("Frame", {
    Name = "Halo",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(150, 150),
    BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2,
}, ring)
for i = 1, 24 do
    local tick = make("Frame", {
        Name = "Tick" .. i,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, -75),
        Size = UDim2.fromOffset(2, 8),
        BackgroundColor3 = C.accent,
        BackgroundTransparency = 0.68,
        BorderSizePixel = 0,
        Rotation = (i - 1) * 15,
        ZIndex = 2,
    }, halo)
    introAdd(tick, 0.05, 0)
end
pcall(function()
    local TweenService = game:GetService("TweenService")
    TweenService:Create(halo,
        TweenInfo.new(26, Enum.EasingStyle.Linear, Enum.EasingDirection.Out,
            -1, false, 0),
        { Rotation = 360 }):Play()
end)

local ringLeafGlyph = make("TextLabel", {
    Name = "RingGlyph", Text = "\u{1F343}",
    Font = Enum.Font.GothamBold, TextSize = 34,
    TextColor3 = C.accent, BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(40, 40), ZIndex = 3,
}, ring)
local leafImg = make("ImageLabel", {
    Image = IMG.ringLeaf or "",
    BackgroundTransparency = 1, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(56, 56), ZIndex = 4,
}, ring)
introAdd(leafImg, 0.10, 8)

local setRichMark
do
    local mark = make("TextLabel", {
        Name = "Wordmark", RichText = true,
        Font = Enum.Font.GothamBlack, TextSize = 46,
        TextColor3 = C.white, BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = fracY(288),
        Size = UDim2.fromOffset(620, 56),
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3,
    }, stage)
    setRichMark = function(em, rest)
        mark.Text = '<font color="#A9D18E">' .. em
            .. '</font><font color="#F4F8F0">' .. rest .. '</font>'
    end
    setRichMark("tea", ".premium")
    introAdd(mark, 0.16, 12)
end

local tagline = make("TextLabel", {
    Name = "Tagline", Text = "S U P P O R T E D   ·   A U T O   L O A D",
    Font = Enum.Font.GothamBold, TextSize = 12,
    TextColor3 = C.dim2, BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(0.5, 0),
    Position = fracY(340),
    Size = UDim2.fromOffset(620, 14),
    TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3,
}, stage)
introAdd(tagline, 0.20, 10)

-- game chip: thumb + name above the progress
local chip = make("Frame", {
    Name = "GameChip",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = fracY(372),
    Size = UDim2.fromOffset(300, 40),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.96,
    BorderSizePixel = 0, ZIndex = 3,
}, stage)
round(chip, 99)
introAdd(chip, 0.24, 10)
stroke(chip, Color3.fromRGB(255, 255, 255), 1, 0.90)

local chipThumb = make("Frame", {
    Name = "Thumb",
    Position = UDim2.fromOffset(7, 7),
    Size = UDim2.fromOffset(26, 26),
    BackgroundColor3 = Color3.fromRGB(16, 16, 20),
    BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 4,
}, chip)
round(chipThumb, 7)
stroke(chipThumb, Color3.fromRGB(255, 255, 255), 1, 0.91)

local monogram = make("TextLabel", {
    Name = "Mono", Text = "?", Font = Enum.Font.GothamBold, TextSize = 14,
    TextColor3 = C.dim, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
    ZIndex = 5,
}, chipThumb)
local icon = make("ImageLabel", {
    Image = "", BackgroundTransparency = 1,
    Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Crop, ZIndex = 5,
}, chipThumb)

local gname = make("TextLabel", {
    Name = "GameName", Text = "-", Font = Enum.Font.GothamBold, TextSize = 13,
    TextColor3 = C.white, BackgroundTransparency = 1,
    Position = UDim2.fromOffset(42, 6), Size = UDim2.new(1, -54, 0, 20),
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 4,
}, chip)
-- supported pill kept live but off-mock: the state rides the session line
local gpill = make("Frame", {
    Name = "SupportPill",
    Position = UDim2.fromOffset(42, 23),
    Size = UDim2.fromOffset(86, 12),
    BackgroundColor3 = C.ok, BackgroundTransparency = 0.91, BorderSizePixel = 0,
    Visible = false, ZIndex = 4,
}, chip)
round(gpill, 6)
local gpillStroke = stroke(gpill, C.ok, 1, 0.76)
local gpillDot = make("Frame", {
    Name = "Dot", Size = UDim2.fromOffset(4, 4),
    Position = UDim2.fromOffset(5, 4),
    BackgroundColor3 = C.ok, BorderSizePixel = 0, ZIndex = 4,
}, gpill)
round(gpillDot, 2)
local gpillText = make("TextLabel", {
    Name = "SupportText", Text = "unsupported", Font = Enum.Font.GothamBold, TextSize = 9,
    TextColor3 = C.ok, BackgroundTransparency = 1,
    Position = UDim2.fromOffset(12, 0),
    Size = UDim2.new(1, -18, 1, 0),
    TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 4,
}, gpill)

-- progress: 330 hairline bar, mock labels. Fills on the fetch loop.
local prog = make("Frame", {
    Name = "Prog",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = fracY(437),
    Size = UDim2.fromOffset(330, 28),
    BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 3,
}, stage)
introAdd(prog, 0.28, 10)

local bar = make("Frame", {
    Name = "Bar", Position = UDim2.fromOffset(0, 0),
    Size = UDim2.new(1, 0, 0, 3),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 0.92,
    BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 3,
}, prog)
round(bar, 2)
local gfill = make("Frame", {
    Name = "Fill", Size = UDim2.new(0, 0, 1, 0),
    BackgroundColor3 = C.accent, BorderSizePixel = 0, ZIndex = 3,
}, bar)
round(gfill, 2)
make("UIGradient", {
    Rotation = 0,
    Color = ColorSequence.new(C.adark, C.accent2),
}, gfill)

local glabel = make("TextLabel", {
    Name = "StepLabel", Text = "pulling menu…", Font = Enum.Font.GothamBold, TextSize = 12,
    TextColor3 = C.accent, BackgroundTransparency = 1,
    Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, -44, 0, 16),
    TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 4,
}, prog)
local gpct = make("TextLabel", {
    Name = "Pct", Text = "0%", Font = Enum.Font.GothamBold, TextSize = 12,
    TextColor3 = C.dim, BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 10),
    Size = UDim2.fromOffset(44, 16), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 4,
}, prog)

-- chip row: the mock's five pills. They cycle during the pull — combat,
-- visuals, exploits, extras, settings — as the reference loader does.
local chipDefs = { "combat", "visuals", "exploits", "extras", "settings" }
local chipWidths = { 78, 86, 84, 70, 82 }
local chipList = {}
do
    local row = make("Frame", {
        Name = "Chips",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = fracY(486),
        Size = UDim2.fromOffset(360, 28),
        BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 3,
    }, stage)
    local lay = Instance.new("UIListLayout")
    lay.FillDirection = Enum.FillDirection.Horizontal
    lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
    lay.Padding = UDim.new(0, 9)
    lay.Parent = row
    for i = 1, #chipDefs do
        local on = (chipDefs[i] == "settings")
        local chipBtn = make("TextButton", {
            Name = "Chip_" .. chipDefs[i], Text = "", AutoButtonColor = false,
            Size = UDim2.fromOffset(chipWidths[i], 28),
            LayoutOrder = i, ZIndex = 3,
            BackgroundColor3 = on and C.accent or C.win,
            BackgroundTransparency = on and 0 or 0.97,
            BorderSizePixel = 0,
        }, row)
        round(chipBtn, 14)
        local chipStroke = stroke(chipBtn, on and C.accent or Color3.fromRGB(199, 205, 193), 1,
            on and 0 or 0.90)
        local dot = make("Frame", {
            Name = "Dot", Size = UDim2.fromOffset(6, 6),
            Position = UDim2.fromOffset(9, 11), BorderSizePixel = 0,
            BackgroundColor3 = on and C.dark or C.accent,
            ZIndex = 4,
        }, chipBtn)
        round(dot, 3)
        local lbl = make("TextLabel", {
            Name = "Label", Text = chipDefs[i], Font = Enum.Font.GothamBold, TextSize = 12,
            TextColor3 = on and C.dark or C.dim, BackgroundTransparency = 1,
            Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -26, 1, 0),
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 4,
        }, chipBtn)
        chipList[i] = { btn = chipBtn, dot = dot, label = lbl, stroke = chipStroke }
        chipBtn.MouseButton1Click:Connect(function()
            for j, c in ipairs(chipList) do
                local isOn = (j == i)
                c.btn.BackgroundColor3 = isOn and C.accent or C.win
                c.btn.BackgroundTransparency = isOn and 0 or 0.97
                c.label.TextColor3 = isOn and C.dark or C.dim
                c.dot.BackgroundColor3 = isOn and C.dark or C.accent
            end
        end)
    end
end

-- one pill lit at a time: the boot crawls this combat -> settings
local function lightChip(active)
    for i, c in ipairs(chipList) do
        local on = (i == active)
        c.btn.BackgroundColor3 = on and C.accent or C.win
        c.btn.BackgroundTransparency = on and 0 or 0.97
        c.label.TextColor3 = on and C.dark or C.dim
        c.dot.BackgroundColor3 = on and C.dark or C.accent
        if c.stroke then
            c.stroke.Color = on and C.accent or Color3.fromRGB(199, 205, 193)
            c.stroke.Transparency = on and 0 or 0.90
        end
    end
end

-- state line: session info lives here, off the visible mock geometry
local gstrip = make("Frame", {
    Name = "ModuleStrip",
    Position = UDim2.fromOffset(0, 0),
    Size = UDim2.new(1, 0, 0, 18),
    BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
}, stage)
local footDot = make("Frame", {
    Name = "StateDot", Size = UDim2.fromOffset(5, 5),
    Position = UDim2.fromOffset(16, 6.5),
    BackgroundColor3 = C.ok, BorderSizePixel = 0,
}, gstrip)
round(footDot, 3)
local gstate = make("TextLabel", {
    Name = "StateLine", Text = "reading manifest", Font = Enum.Font.Gotham, TextSize = 9,
    TextColor3 = Color3.fromRGB(60, 66, 58), BackgroundTransparency = 1,
    Size = UDim2.new(0, 300, 1, 0), Position = UDim2.fromOffset(27, 0),
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
}, gstrip)

-- module id list: kept live for manual matching, rides the hidden strip
local list = make("Frame", {
    Name = "ModuleList",
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -14, 0.5, 0),
    Size = UDim2.fromOffset(262, 18),
    BackgroundTransparency = 1, BorderSizePixel = 0,
}, gstrip)
local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
layout.Padding = UDim.new(0, 6)
layout.Parent = list

-- run plate: stays for the flow contract; the stage auto-runs instead
local runScript = make("TextButton", {
    Name = "RunButton", Text = "Run Script", Font = Enum.Font.GothamBold, TextSize = 14,
    TextColor3 = C.dark,
    BackgroundColor3 = C.accent, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0.5, 0),
    Position = fracY(560),
    Size = UDim2.fromOffset(200, 38),
    AutoButtonColor = false,
    Visible = false,
}, stage)
round(runScript, 19)
local runGrad = make("UIGradient", {
    Rotation = 90,
    Color = ColorSequence.new(Color3.fromRGB(198, 229, 179), Color3.fromRGB(148, 196, 124)),
}, runScript)

local function setStep(active) end   -- dots went with the key stage

local rows = {}
local selected = nil
local manual = false

local function paintRows()
    for id, row in pairs(rows) do
        local on = selected ~= nil and selected.id == id
        row.button.BackgroundTransparency = on and 0.25 or 1
        row.label.TextColor3 = on and C.accent or C.dim
        row.mark.BackgroundColor3 = on and C.accent or Color3.fromRGB(30, 36, 28)
    end
end

local refresh   -- forward declaration: a row click repaints

local function buildRows(entries)
    for _, row in pairs(rows) do row.button:Destroy() end
    rows = {}
    for i, g in ipairs(entries) do
        local pillBtn = make("TextButton", {
            Name = "Row_" .. g.id, Text = "", AutoButtonColor = false,
            LayoutOrder = i, ZIndex = 4,
            Size = UDim2.fromOffset(120, 18),
            BackgroundColor3 = C.accent, BackgroundTransparency = 1,
            BorderSizePixel = 0,
        }, list)
        round(pillBtn, 9)
        make("TextLabel", {
            Name = "PlainText", Text = g.name, Font = Enum.Font.GothamBold, TextSize = 10,
            TextColor3 = C.dim, BackgroundTransparency = 1,
            Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -18, 1, 0),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 5,
        }, pillBtn)
        local markDot = make("Frame", {
            Name = "Mark", Size = UDim2.fromOffset(5, 5),
            Position = UDim2.fromOffset(6, 6.5),
            BackgroundColor3 = Color3.fromRGB(30, 36, 28), BorderSizePixel = 0,
            ZIndex = 5,
        }, pillBtn)
        round(markDot, 3)
        -- the pill text IS the module id, exactly as the manifest writes it
        local idLabel = make("TextLabel", {
            Name = "IdText", Text = g.id, Font = Enum.Font.GothamBold, TextSize = 10,
            TextColor3 = C.dim, BackgroundTransparency = 1,
            Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -20, 1, 0),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 5,
        }, pillBtn)
        rows[g.id] = { button = pillBtn, label = idLabel, mark = markDot, entry = g }
        pillBtn.MouseButton1Click:Connect(function()
            selected = g
            manual = true
            refresh()
        end)
    end
end

local function setGameState(text, ok)
    gstate.Text = text
    local c = ok and C.ok or (ok == false and C.bad or Color3.fromRGB(78, 78, 88))
    gstate.TextColor3 = c
    footDot.BackgroundColor3 = c
end

local STEPS = {
    "pulling manifest…",
    "matching game…",
    "arming module…",
}

local function progress(p)
    p = math.clamp(p, 0, 1)
    gfill.Size = UDim2.new(p, 0, 1, 0)
    gpct.Text = tostring(math.floor(p * 100 + 0.5)) .. "%"
    if p <= 0 then
        glabel.Text = "pulling menu…"
    elseif p >= 1 then
        glabel.Text = "Ready — inserted"
    end
end

local function spin()
    local live = true
    task.spawn(function()
        local t0 = os.clock()
        while live do
            local p = math.min(0.9, (os.clock() - t0) * 0.5)
            progress(p)
            task.wait(0.04)
        end
    end)
    return function() live = false end
end

local GAMES = {}

local function parseManifest(body)
    local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok or type(data) ~= "table" then return nil, "manifest is not json" end
    local raw = data.games or data
    if type(raw) ~= "table" then return nil, "manifest has no games list" end

    local out = {}
    for _, g in ipairs(raw) do
        if type(g) == "table" and g.id and g.name then
            local places = {}
            local first = nil
            if type(g.places) == "table" then
                for _, p in ipairs(g.places) do
                    local n = tonumber(p)
                    if n then places[n] = true; first = first or n end
                end
            end
            local single = tonumber(g.place)
            if single then places[single] = true; first = first or single end
            out[#out + 1] = {
                id = tostring(g.id),
                name = tostring(g.name),
                places = places,
                place = first,
                universe = tonumber(g.universe),
                icon = type(g.icon) == "string" and g.icon or "",
            }
        end
    end
    return out
end

local function matchGame(place, universe)
    for _, g in ipairs(GAMES) do
        if g.places[place] then return g end
        if g.universe and g.universe == universe then return g end
    end
    return nil
end

local function placeInfo()
    local place = tonumber(game.PlaceId) or 0
    local universe = tonumber(game.GameId) or 0
    local name = tostring(game.Name or "unknown")
    return place, universe, name
end

local function iconFor(g)
    if not g then return "" end
    if g.icon ~= "" then
        if g.icon:match("^[%a]+://") then return g.icon end
        return "rbxassetid://" .. g.icon
    end
    local thumbId = g.universe or g.place
    if thumbId then
        return string.format("rbxthumb://type=GameIcon&id=%.0f&w=150&h=150", thumbId)
    end
    return ""
end

refresh = function()
    local place, universe, placeName = placeInfo()
    local auto = matchGame(place, universe)

    if manual then

    elseif auto then
        selected = auto
    else
        selected = nil
    end

    local label = selected and selected.name or placeName
    gname.Text = label
    icon.Image = iconFor(selected)
    local mono = string.upper(string.sub(label or "?", 1, 1))
    monogram.Text = (mono ~= "") and mono or "?"
    monogram.TextColor3 = selected and C.accent or C.dim

    if selected then
        gpillText.Text = "supported"
        gpillText.TextColor3 = C.ok
        gpillDot.BackgroundColor3 = C.ok
        gpill.BackgroundColor3 = C.ok
        gpill.BackgroundTransparency = 0.91
        gpillStroke.Color = C.ok
        gpillStroke.Transparency = 0.76
        setGameState(manual and "picked by hand" or "detected by place id", true)
        runScript.Text = "Run Script"
        runScript.BackgroundTransparency = 0
        runGrad.Enabled = true
        runScript.TextColor3 = Color3.fromRGB(16, 30, 10)
        runScript.AutoButtonColor = true
    else
        gpillText.Text = "unsupported"
        gpillText.TextColor3 = C.off
        gpillDot.BackgroundColor3 = C.off
        gpill.BackgroundColor3 = C.off
        gpill.BackgroundTransparency = 0.85
        gpillStroke.Color = C.line
        gpillStroke.Transparency = 0
        setGameState(GAMES[1] and "not supported in this game" or "manifest is empty", false)
        runScript.Text = "Unsupported game"
        runScript.BackgroundTransparency = 0.35
        runGrad.Enabled = false
        runScript.TextColor3 = C.off
        runScript.AutoButtonColor = false
    end

    paintRows()
end

-- fade helpers
local function fadeGroup(root, dur)
    local TweenService = game:GetService("TweenService")
    local info = TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    local tweens = {}
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
            tweens[#tweens + 1] = TweenService:Create(d, info, { TextTransparency = 1 })
        elseif d:IsA("Frame") or d:IsA("ImageLabel") or d:IsA("ScrollingFrame") then
            tweens[#tweens + 1] = TweenService:Create(d, info, { BackgroundTransparency = 1 })
        elseif d:IsA("UIStroke") then
            tweens[#tweens + 1] = TweenService:Create(d, info, { Transparency = 1 })
        end
    end
    for _, tw in ipairs(tweens) do tw:Play() end
end

local function fadeOut()
    pcall(function() fadeGroup(stage, 0.3) end)
    task.wait(0.34)
    gui:Destroy()
end

local function loadManifest()
    local body, err = fetchChunk("games")
    if not body then return nil, err or "manifest unreachable" end
    if body:sub(1, 1) == "<" then return nil, "host served a page, not the manifest" end
    return parseManifest(body)
end

local busy = false

-- the run: fetch menu + module, publish the session, insert both
local function startRun()
    if busy then return end
    if not selected then return end
    busy = true

    local target = selected
    setStep(3)
    runScript.Text = "Loading"
    runScript.BackgroundTransparency = 0.35
    runGrad.Enabled = false
    runScript.TextColor3 = Color3.fromRGB(198, 198, 208)
    setGameState("checking key", nil)
    local unlocked, gerr = ensureSession()
    if not unlocked then
        busy = false
        refresh()
        setGameState(gerr or "key refused", false)
        return
    end

    setGameState("fetching " .. target.name, nil)

    local stop = spin()
    local menu, err = fetchChunk("menu")
    stop()

    if not menu then
        busy = false
        refresh()
        setGameState(err or "menu unavailable", false)
        return
    end

    local module = fetchChunk(target.id)

    setGameState("loading " .. target.name, true)
    progress(1)

    if type(getgenv) == "function" then
        pcall(function()
            getgenv().TeaPremium = {
                version = VERSION,
                product = PRODUCT,
                game = {
                    id = target.id,
                    name = target.name,
                    place = tonumber(game.PlaceId) or 0,
                    universe = tonumber(game.GameId) or 0,
                },
            }
        end)
    end

    fadeOut()

    local chunk, cerr = compile(menu)
    if not chunk then
        warn("[premium] load failed: " .. tostring(cerr))
        return
    end
    -- the menu chunk returns the library: keep it, features hang off it
    local ok, lib = pcall(chunk)
    if not ok then
        warn("[premium] runtime error: " .. tostring(lib))
    elseif type(getgenv) == "function" then
        pcall(function()
            getgenv().DriftLib = lib
        end)

        -- optional: binds the standalone feature modules to the menu
        local fsrc = fetchChunk("features")
        if fsrc then
            local fchunk, ferr = compile(fsrc)
            if fchunk then
                local fok, ferr2 = pcall(fchunk)
                if not fok then warn("[drift] features: " .. tostring(ferr2)) end
            else
                warn("[drift] features do not compile: " .. tostring(ferr))
            end
        end
    end

    if module then
        local mchunk, merr = compile(module)
        if not mchunk then
            warn("[premium] game module failed: " .. tostring(merr))
        else
            local mok, mrerr = pcall(mchunk)
            if not mok then warn("[premium] game module error: " .. tostring(mrerr)) end
        end
    end
end

runScript.MouseButton1Click:Connect(startRun)

-- ---------------------------------------------------------------- boot -------
-- No key stage: the stage shows immediately, the progress crawls so the hero
-- gets its moment, the manifest pulls, the game matches, the run fires itself.
playIntro()
setGameState(GAMES[1] and "" or "reading manifest", nil)

task.spawn(function()
    -- staged crawl: the five chips cycle combat -> visuals -> exploits ->
    -- extras -> settings while the bar climbs and the leaves fall
    local steps = {
        { 0.14, 0.62 }, { 0.32, 0.62 }, { 0.52, 0.62 }, { 0.72, 0.62 }, { 0.90, 0.62 },
    }
    for i, s in ipairs(steps) do
        lightChip(i)
        progress(s[1])
        task.wait(s[2])
    end
    progress(1)
    glabel.Text = "opening tea"
    task.wait(0.55)

    local unlocked, gerr = ensureSession()
    if not unlocked then
        setGameState(gerr or "key refused", false)
        gpct.Text = "--"
        return
    end

    local entries, err = loadManifest()
    if not entries then
        setGameState(err or "manifest unavailable", false)
        gpct.Text = "--"
        return
    end
    GAMES = entries
    buildRows(GAMES)
    refresh()
    setStep(2)
    progress(0.94)
    lightChip(5)

    -- the place watcher: a move re-matches, and the first good match runs
    task.spawn(function()
        local p0, u0 = placeInfo()
        local last = p0 .. ":" .. u0
        while gui and gui.Parent do
            local p, u = placeInfo()
            local now = p .. ":" .. u
            if now ~= last then
                last = now
                manual = false
                refresh()
            end
            if selected and not busy then startRun(); break end
            task.wait(0.8)
        end
    end)
end)
