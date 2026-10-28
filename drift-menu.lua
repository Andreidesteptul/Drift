--[[
	drift-ui - single-file build

	Paste the whole file into an executor and execute. Nothing to install.
	Insert toggles the window, the header drags it, the pill at the bottom
	cycles tabs, the magnifier filters cards by title.

	Every icon is drawn from Frames; there are no asset ids to load.
]]

-- gethui() keeps the window out of the game's own PlayerGui where the executor
-- supports it. CoreGui is the fallback, PlayerGui the last resort.
local __parent
do
	local players = game:GetService("Players")
	local ok, hidden = pcall(function()
		return gethui and gethui()
	end)
	if ok and hidden then
		__parent = hidden
	else
		local okCore, core = pcall(function()
			return game:GetService("CoreGui")
		end)
		if okCore and core then
			__parent = core
		else
			__parent = players.LocalPlayer:WaitForChild("PlayerGui")
		end
	end
end
--[[
	DriftUI 1.0

	A small, self-contained Roblox UI library. Everything is built from stock
	ScreenGui / Frame / UICorner / UIStroke instances, so rounded corners and
	clipping are native and cost one instance each instead of a stack of strips.

	No external assets: every icon is drawn from primitives, so there are no
	rbxassetid lookups to break.

	Typical use, from a LocalScript:

		local DriftUI = require(ReplicatedStorage.DriftUI)

		local app  = DriftUI.new({ parent = Players.LocalPlayer.PlayerGui })
		local tab  = app:Tab("aimbot", "target")
		local card = tab:Card("silent aim", "diamond")

		card:Toggle({ text = "Target-Bot", default = true, changed = function(on) end })
		card:Slider({ text = "Field of view", min = 0, max = 360, default = 120 })
		card:Dropdown({ text = "Hit part", options = { "Head", "Torso" } })
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local DriftUI = {}

-- > ( theme )

local Theme = {
	Font = Enum.Font.Gotham,
	FontMedium = Enum.Font.GothamMedium,
	FontBold = Enum.Font.GothamBold,
	FontMono = Enum.Font.Code,

	Shell = Color3.fromRGB(43, 43, 48),
	Rail = Color3.fromRGB(36, 36, 40),
	Card = Color3.fromRGB(51, 51, 57),
	CardAlt = Color3.fromRGB(59, 59, 66),
	Field = Color3.fromRGB(45, 45, 51),
	Track = Color3.fromRGB(66, 66, 74),
	Stroke = Color3.fromRGB(68, 68, 77),
	StrokeLit = Color3.fromRGB(96, 96, 108),

	Text = Color3.fromRGB(236, 236, 241),
	TextMuted = Color3.fromRGB(156, 156, 167),
	TextDim = Color3.fromRGB(108, 108, 120),

	Accent = Color3.fromRGB(74, 144, 230),
	AccentDeep = Color3.fromRGB(56, 118, 196),
	OnAccent = Color3.fromRGB(255, 255, 255),

	Knob = Color3.fromRGB(214, 214, 222),
	KnobOn = Color3.fromRGB(255, 255, 255),

	Good = Color3.fromRGB(96, 206, 140),
	Bad = Color3.fromRGB(232, 84, 96),
	Shadow = Color3.fromRGB(0, 0, 0),
}

local Dim = {
	W = 820,
	H = 560,

	RailX = 12,
	RailY = 12,
	RailW = 66,

	HeaderH = 48,
	ContentX = 94,
	ContentW = 710,
	BodyY = 60,
	BodyH = 448,

	CardGap = 14,
	CardPad = 12,
	CardTitle = 28,
	Row = 38,

	Radius = 18,
	CardRadius = 14,
	ControlRadius = 8,
}

-- > ( primitives )

local function make(class, props, children)
	local object = Instance.new(class)
	local parent = props and props.Parent
	for key, value in pairs(props or {}) do
		if key ~= "Parent" then
			object[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = object
	end
	if parent then
		object.Parent = parent
	end
	return object
end

local function corner(object, radius)
	return make("UICorner", {
		CornerRadius = UDim.new(0, radius),
		Parent = object,
	})
end

local function stroke(object, color, thickness, transparency)
	return make("UIStroke", {
		Color = color or Theme.Stroke,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = object,
	})
end

local function padding(object, x, y)
	y = y or x
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, x),
		PaddingRight = UDim.new(0, x),
		PaddingTop = UDim.new(0, y),
		PaddingBottom = UDim.new(0, y),
		Parent = object,
	})
end

local function tween(object, props, duration)
	local info = TweenInfo.new(duration or 0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local animation = TweenService:Create(object, info, props)
	animation:Play()
	return animation
end

local function textLabel(props)
	props.BackgroundTransparency = 1
	props.BorderSizePixel = 0
	props.Font = props.Font or Theme.Font
	props.TextColor3 = props.TextColor3 or Theme.Text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	return make("TextLabel", props)
end

-- Hover is tracked across the whole row, not just its background, because a
-- TextLabel sitting on top still swallows MouseEnter for the parent. Counting
-- nested enters and leaves means sliding from the label onto the switch does not
-- flicker the highlight off.
local function bindHover(root, onEnter, onLeave)
	local depth = 0
	local function wire(object)
		object.MouseEnter:Connect(function()
			depth += 1
			if depth == 1 then
				onEnter()
			end
		end)
		object.MouseLeave:Connect(function()
			depth = math.max(0, depth - 1)
			if depth == 0 then
				onLeave()
			end
		end)
		for _, child in ipairs(object:GetChildren()) do
			if child:IsA("GuiObject") then
				wire(child)
			end
		end
	end
	wire(root)
end

-- > ( icons )
-- Every icon is a handful of Frames. Cheap, resolution independent, and there is
-- nothing to load. Each builder returns a frame plus a paint function so a state
-- change can recolour the whole mark without rebuilding it.

local Icons = {}

local function shape(parent, width, height, dx, dy, color, radius, rotation)
	local object = make("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(width, height),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, dx, 0.5, dy),
		Rotation = rotation or 0,
		Parent = parent,
	})
	if radius and radius > 0 then
		corner(object, radius)
	end
	return object
end

local function ringShape(parent, width, height, dx, dy, color, thickness)
	local object = make("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(width, height),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, dx, 0.5, dy),
		Parent = parent,
	})
	corner(object, math.min(width, height) / 2)
	stroke(object, color, thickness or 1.6, 0)
	return object
end

function Icons.build(kind, size, color, parent)
	local root = make("Frame", {
		Name = "Icon_" .. tostring(kind),
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	})

	local fills, rings = {}, {}
	local function fill(...)
		local object = shape(root, ...)
		fills[#fills + 1] = object
		return object
	end
	local function outline(...)
		local object = ringShape(root, ...)
		rings[#rings + 1] = object
		return object
	end

	local s = size

	if kind == "dot" then
		fill(s * 0.32, s * 0.32, 0, 0, color, s * 0.16)
	elseif kind == "target" then
		outline(s * 0.66, s * 0.66, 0, 0, color, math.max(1.4, s * 0.09))
		fill(s * 0.18, s * 0.18, 0, 0, color, s * 0.09)
	elseif kind == "diamond" then
		fill(s * 0.50, s * 0.50, 0, 0, color, s * 0.10, 45)
	elseif kind == "user" then
		fill(s * 0.34, s * 0.34, 0, -s * 0.16, color, s * 0.17)
		fill(s * 0.54, s * 0.26, 0, s * 0.21, color, s * 0.09)
	elseif kind == "eye" then
		outline(s * 0.74, s * 0.46, 0, 0, color, math.max(1.4, s * 0.08))
		fill(s * 0.18, s * 0.18, 0, 0, color, s * 0.09)
	elseif kind == "shield" then
		fill(s * 0.46, s * 0.46, 0, 0, color, s * 0.10, 45)
		outline(s * 0.18, s * 0.18, 0, 0, color, 1.4)
	elseif kind == "gear" then
		fill(s * 0.34, s * 0.34, 0, 0, color, s * 0.17)
		for index = 1, 4 do
			fill(s * 0.10, s * 0.62, 0, 0, color, s * 0.05, index * 45)
		end
	elseif kind == "sliders" then
		for index = 1, 3 do
			local dy = (index - 2) * s * 0.24
			fill(s * 0.64, s * 0.08, 0, dy, color, s * 0.04)
			fill(s * 0.14, s * 0.14, (index - 2) * s * 0.13, dy, color, s * 0.07)
		end
	elseif kind == "spark" then
		fill(s * 0.09, s * 0.62, 0, 0, color, s * 0.045, 35)
		fill(s * 0.09, s * 0.62, 0, 0, color, s * 0.045, -35)
	elseif kind == "bolt" then
		fill(s * 0.14, s * 0.34, s * 0.04, -s * 0.14, color, s * 0.05, 20)
		fill(s * 0.14, s * 0.34, -s * 0.04, s * 0.14, color, s * 0.05, 20)
		fill(s * 0.28, s * 0.10, 0, 0, color, s * 0.05)
	elseif kind == "close" then
		fill(s * 0.62, s * 0.09, 0, 0, color, s * 0.045, 45)
		fill(s * 0.62, s * 0.09, 0, 0, color, s * 0.045, -45)
	elseif kind == "search" then
		outline(s * 0.50, s * 0.50, -s * 0.05, -s * 0.05, color, math.max(1.3, s * 0.09))
		fill(s * 0.30, s * 0.09, s * 0.16, s * 0.16, color, s * 0.045, -45)
	elseif kind == "chevron" then
		fill(s * 0.28, s * 0.08, -s * 0.09, 0, color, s * 0.04, 45)
		fill(s * 0.28, s * 0.08, s * 0.09, 0, color, s * 0.04, -45)
	else
		fill(s * 0.32, s * 0.32, 0, 0, color, s * 0.16)
	end

	local function paint(nextColor)
		for _, object in ipairs(fills) do
			object.BackgroundColor3 = nextColor
		end
		for _, object in ipairs(rings) do
			local line = object:FindFirstChildOfClass("UIStroke")
			if line then
				line.Color = nextColor
			end
		end
	end

	return root, paint
end

-- > ( control builders )
-- Every builder takes the row it belongs to and returns a handle with Get/Set,
-- so the caller decides placement and the control decides behaviour.

local Controls = {}

local function rowLabel(card, row, name, controlW)
	return textLabel({
		Size = UDim2.new(1, -(controlW + 12), 1, 0),
		Font = Theme.FontMedium,
		TextSize = 12,
		TextColor3 = Theme.Text,
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
end

function Controls.toggle(card, row, config)
	rowLabel(card, row, config.text or "", 56)

	local trackW, trackH = 44, 24
	local knobSize = trackH - 6

	local track = make("Frame", {
		BackgroundColor3 = Theme.Track,
		Size = UDim2.fromOffset(trackW, trackH),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		BorderSizePixel = 0,
		Parent = row,
	})
	corner(track, trackH / 2)

	local knob = make("Frame", {
		BackgroundColor3 = Theme.Knob,
		Size = UDim2.fromOffset(knobSize, knobSize),
		Position = UDim2.fromOffset(3, 3),
		BorderSizePixel = 0,
		Parent = track,
	})
	corner(knob, knobSize / 2)

	local button = make("TextButton", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		AutoButtonColor = false,
		Parent = track,
	})

	local value = config.default == true

	local function paint(animate)
		local targetX = value and (trackW - knobSize - 3) or 3
		local targetTrack = value and Theme.Accent or Theme.Track
		local targetKnob = value and Theme.KnobOn or Theme.Knob
		if animate then
			tween(knob, { Position = UDim2.fromOffset(targetX, 3), BackgroundColor3 = targetKnob })
			tween(track, { BackgroundColor3 = targetTrack })
		else
			knob.Position = UDim2.fromOffset(targetX, 3)
			knob.BackgroundColor3 = targetKnob
			track.BackgroundColor3 = targetTrack
		end
	end

	local handle = {}
	function handle:Get()
		return value
	end
	function handle:Set(next, silent)
		value = next == true
		paint(true)
		if not silent and config.changed then
			task.spawn(config.changed, value)
		end
	end

	button.MouseButton1Click:Connect(function()
		handle:Set(not value)
	end)

	paint(false)
	return handle
end

function Controls.slider(card, row, config)
	local min = config.min or 0
	local max = config.max or 100
	local decimals = config.decimals or 0
	local value = math.clamp(config.default or min, min, max)

	local controlW = 172
	local trackW = 132
	local valueW = 34

	rowLabel(card, row, config.text or "", controlW + 12)

	local holder = make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(controlW, Dim.Row),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Parent = row,
	})

	local hit = make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(trackW, Dim.Row),
		Parent = holder,
	})

	local rail = make("Frame", {
		BackgroundColor3 = Theme.Track,
		Size = UDim2.fromOffset(trackW, 4),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		BorderSizePixel = 0,
		Parent = hit,
	})
	corner(rail, 2)

	local fillBar = make("Frame", {
		BackgroundColor3 = Theme.Accent,
		Size = UDim2.fromOffset(trackW, 4),
		BorderSizePixel = 0,
		Parent = rail,
	})
	corner(fillBar, 2)

	local knob = make("Frame", {
		BackgroundColor3 = Theme.KnobOn,
		Size = UDim2.fromOffset(14, 14),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		BorderSizePixel = 0,
		Parent = hit,
	})
	corner(knob, 7)

	local readout = textLabel({
		Size = UDim2.fromOffset(valueW, Dim.Row),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Font = Theme.FontBold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = holder,
	})

	local function ratio()
		if max == min then
			return 0
		end
		return (value - min) / (max - min)
	end

	local function render()
		local p = ratio()
		fillBar.Size = UDim2.fromOffset(math.max(1, trackW * p), 4)
		knob.Position = UDim2.new(p, 0, 0.5, 0)
		readout.Text = string.format("%." .. decimals .. "f", value)
	end

	local handle = {}
	function handle:Get()
		return value
	end
	function handle:Set(next, silent)
		value = math.clamp(next, min, max)
		render()
		if not silent and config.changed then
			task.spawn(config.changed, value)
		end
	end

	-- Dragging listens on the input service rather than the frame so the knob
	-- keeps following once the pointer leaves the 132px strip, which is the
	-- difference between a usable slider and a toy. Only X is read, so the
	-- GUI-inset quirk on GetMouseLocation cannot skew it.
	local dragging = false
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
		end
	end)

	card:_track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))

	card:_track(UserInputService.InputChanged:Connect(function(input)
		if not dragging or not rail.Parent then
			return
		end
		local pointer = UserInputService:GetMouseLocation().X
		local left = rail.AbsolutePosition.X
		local width = rail.AbsoluteSize.X
		if width <= 0 then
			return
		end
		handle:Set(min + math.clamp((pointer - left) / width, 0, 1) * (max - min))
	end))

	render()
	return handle
end

function Controls.dropdown(card, row, config)
	local options = config.options or {}
	local value = config.default or options[1]
	local buttonW = 160

	rowLabel(card, row, config.text or "", buttonW + 12)

	local button = make("TextButton", {
		BackgroundColor3 = Theme.Field,
		Size = UDim2.fromOffset(buttonW, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		AutoButtonColor = false,
		Text = "",
		Parent = row,
	})
	corner(button, Dim.ControlRadius)
	local line = stroke(button, Theme.Stroke, 1, 0)

	textLabel({
		Size = UDim2.new(1, -34, 1, 0),
		Position = UDim2.fromOffset(11, 0),
		Font = Theme.Font,
		TextSize = 12,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = Theme.Text,
		Parent = button,
	}).Name = "Value"

	local chevron = Icons.build("chevron", 12, Theme.TextMuted, button)
	chevron.AnchorPoint = Vector2.new(0.5, 0.5)
	chevron.Position = UDim2.new(1, -17, 0.5, 0)

	local handle = {}
	function handle:Get()
		return value
	end
	function handle:Set(next, silent)
		value = next
		button.Value.Text = tostring(next or "")
		if not silent and config.changed then
			task.spawn(config.changed, value)
		end
	end

	button.MouseEnter:Connect(function()
		line.Color = Theme.StrokeLit
		button.BackgroundColor3 = Theme.CardAlt
	end)
	button.MouseLeave:Connect(function()
		line.Color = Theme.Stroke
		button.BackgroundColor3 = Theme.Field
	end)

	button.MouseButton1Click:Connect(function()
		card.app:popup(button, buttonW, options, value, function(picked)
			handle:Set(picked)
		end)
	end)

	handle:Set(value, true)
	return handle
end

function Controls.textbox(card, row, config)
	local fieldW = 150
	rowLabel(card, row, config.text or "", fieldW + 12)

	local field = make("Frame", {
		BackgroundColor3 = Theme.Field,
		Size = UDim2.fromOffset(fieldW, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Parent = row,
	})
	corner(field, Dim.ControlRadius)
	local line = stroke(field, Theme.Stroke, 1, 0)

	local box = make("TextBox", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.Font,
		TextSize = 12,
		TextColor3 = Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		PlaceholderText = config.placeholder or "",
		PlaceholderColor3 = Theme.TextDim,
		ClearTextOnFocus = false,
		Text = tostring(config.default or ""),
		Parent = field,
	})
	padding(box, 10, 0)

	local handle = {}
	function handle:Get()
		return box.Text
	end
	function handle:Set(next, silent)
		box.Text = tostring(next or "")
		if not silent and config.changed then
			task.spawn(config.changed, box.Text)
		end
	end

	box.Focused:Connect(function()
		line.Color = Theme.Accent
	end)
	box.FocusLost:Connect(function()
		line.Color = Theme.Stroke
		if config.changed then
			task.spawn(config.changed, box.Text)
		end
	end)

	return handle
end

function Controls.keybind(card, row, config)
	local fieldW = 110
	rowLabel(card, row, config.text or "", fieldW + 12)

	local field = make("Frame", {
		BackgroundColor3 = Theme.Field,
		Size = UDim2.fromOffset(fieldW, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Parent = row,
	})
	corner(field, Dim.ControlRadius)
	local line = stroke(field, Theme.Stroke, 1, 0)

	local shown = textLabel({
		Size = UDim2.fromScale(1, 1),
		Font = Theme.FontMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = tostring(config.default or "None"),
		Parent = field,
	})

	local key = config.default or "None"
	local listening = false

	local function render()
		shown.Text = listening and "press a key" or tostring(key)
		shown.TextColor3 = listening and Theme.Accent or Theme.Text
		line.Color = listening and Theme.Accent or Theme.Stroke
	end

	-- Only one field may capture at a time, and the capture has to die with the
	-- window: an armed listener that is never fed a key would otherwise keep
	-- swallowing input for the rest of the session.
	local function stopCapture()
		local capture = card.app._keyCapture
		if capture then
			capture:Disconnect()
			card.app._keyCapture = nil
		end
	end

	local handle = {}
	function handle:Get()
		return key
	end

	field.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		stopCapture()
		listening = true
		render()

		local connection
		connection = UserInputService.InputBegan:Connect(function(press, processed)
			if processed then
				return
			end
			if press.UserInputType == Enum.UserInputType.MouseButton1 then
				-- Clicked away without binding.
				listening = false
				render()
				connection:Disconnect()
				if card.app._keyCapture == connection then
					card.app._keyCapture = nil
				end
				return
			end
			if press.KeyCode == Enum.KeyCode.Unknown then
				return
			end
			key = press.KeyCode == Enum.KeyCode.Escape and "None" or press.KeyCode.Name
			listening = false
			render()
			connection:Disconnect()
			if card.app._keyCapture == connection then
				card.app._keyCapture = nil
			end
			if config.changed then
				task.spawn(config.changed, key)
			end
		end)

		card.app._keyCapture = connection
		card:_track(connection)
	end)

	render()
	return handle
end

function Controls.color(card, row, config)
	rowLabel(card, row, config.text or "", 68)

	local swatch = make("TextButton", {
		BackgroundColor3 = config.default or Theme.Accent,
		Size = UDim2.fromOffset(56, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		AutoButtonColor = false,
		Text = "",
		Parent = row,
	})
	corner(swatch, Dim.ControlRadius)

	local value = config.default or Theme.Accent

	local handle = {}
	function handle:Get()
		return value
	end
	function handle:Set(next, silent)
		value = next
		swatch.BackgroundColor3 = next
		if not silent and config.changed then
			task.spawn(config.changed, value)
		end
	end

	swatch.MouseButton1Click:Connect(function()
		card.app:popupGrid(swatch, 224, config.presets, value, function(picked)
			handle:Set(picked)
		end)
	end)

	return handle
end

function Controls.button(card, row, config)
	row.Size = UDim2.new(1, 0, 0, 40)

	local face = make("TextButton", {
		BackgroundColor3 = Theme.CardAlt,
		Size = UDim2.new(1, 0, 0, 34),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AutoButtonColor = false,
		Text = config.text or "Button",
		Font = Theme.FontMedium,
		TextSize = 13,
		TextColor3 = Theme.Text,
		Parent = row,
	})
	corner(face, Dim.ControlRadius)

	face.MouseEnter:Connect(function()
		face.BackgroundColor3 = Theme.Field
	end)
	face.MouseLeave:Connect(function()
		face.BackgroundColor3 = Theme.CardAlt
	end)
	face.MouseButton1Click:Connect(function()
		if config.clicked then
			task.spawn(config.clicked)
		end
	end)

	return { Instance = face }
end

-- > ( card )

local Card = {}
Card.__index = Card

function Card:_row()
	self.order += 1
	return make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Dim.Row),
		LayoutOrder = self.order,
		Parent = self.frame,
	})
end

-- A hover plate rather than a colour change on the row itself: rows are
-- transparent so the card fill shows through, and swapping that fill per row
-- would fight the card's corner radius.
function Card:_hover(row)
	local glow = make("Frame", {
		BackgroundColor3 = Theme.CardAlt,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 8, 0, Dim.Row - 6),
		Position = UDim2.fromOffset(-4, 3),
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = row,
	})
	corner(glow, 8)

	for _, child in ipairs(row:GetChildren()) do
		if child ~= glow and child:IsA("GuiObject") then
			child.ZIndex = 2
		end
	end

	bindHover(row, function()
		glow.BackgroundTransparency = 0.55
	end, function()
		glow.BackgroundTransparency = 1
	end)
end

function Card:_finish(row)
	self:_hover(row)
	self.tab.app:_touch()
end

function Card:_track(connection)
	self.tab.app:_track(connection)
end

function Card:Toggle(config)
	local row = self:_row()
	local handle = Controls.toggle(self, row, config)
	self:_finish(row)
	return handle
end

function Card:Slider(config)
	local row = self:_row()
	local handle = Controls.slider(self, row, config)
	self:_finish(row)
	return handle
end

function Card:Dropdown(config)
	local row = self:_row()
	local handle = Controls.dropdown(self, row, config)
	self:_finish(row)
	return handle
end

function Card:TextBox(config)
	local row = self:_row()
	local handle = Controls.textbox(self, row, config)
	self:_finish(row)
	return handle
end

function Card:Keybind(config)
	local row = self:_row()
	local handle = Controls.keybind(self, row, config)
	self:_finish(row)
	return handle
end

function Card:Color(config)
	local row = self:_row()
	local handle = Controls.color(self, row, config)
	self:_finish(row)
	return handle
end

function Card:Button(config)
	local row = self:_row()
	local handle = Controls.button(self, row, config)
	self:_finish(row)
	return handle
end

function Card:Label(text)
	local row = self:_row()
	row.Size = UDim2.new(1, 0, 0, 30)
	local label = textLabel({
		Size = UDim2.fromScale(1, 1),
		Font = Theme.Font,
		TextSize = 11,
		TextColor3 = Theme.TextDim,
		Text = text,
		Parent = row,
	})
	self.tab.app:_touch()
	return label
end

function Card:SetVisible(state)
	self.frame.Visible = state
end

-- > ( tab )

local Tab = {}
Tab.__index = Tab

function Tab:Card(title, iconKind, side)
	self.order += 1
	self.cardsMade += 1

	-- Alternating columns keeps the grid balanced without knowing how tall a card
	-- will be before it renders. `side` overrides it when a specific arrangement
	-- matters.
	local columnIndex = side or ((self.cardsMade % 2 == 1) and 1 or 2)

	local frame = make("Frame", {
		Name = "Card_" .. tostring(title),
		BackgroundColor3 = Theme.Card,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BorderSizePixel = 0,
		LayoutOrder = self.order,
		Parent = self.columns[columnIndex],
	})
	corner(frame, Dim.CardRadius)
	stroke(frame, Theme.Stroke, 1, 0.45)
	padding(frame, Dim.CardPad, Dim.CardPad)
	make("UIListLayout", {
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = frame,
	})

	local head = make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Dim.CardTitle),
		LayoutOrder = 0,
		Parent = frame,
	})

	textLabel({
		Size = UDim2.new(1, -26, 1, 0),
		Font = Theme.FontMedium,
		TextSize = 13,
		TextColor3 = Theme.Text,
		Text = title,
		Parent = head,
	})

	if iconKind then
		local mark = Icons.build(iconKind, 16, Theme.TextMuted, head)
		mark.AnchorPoint = Vector2.new(1, 0.5)
		mark.Position = UDim2.new(1, 0, 0.5, 0)
	end

	local card = setmetatable({
		app = self.app,
		tab = self,
		frame = frame,
		title = title,
		order = 0,
	}, Card)

	self.cards[#self.cards + 1] = card
	self.app:_touch()
	return card
end

-- > ( app )

local App = {}
App.__index = App

function DriftUI.new(options)
	options = options or {}

	local self = setmetatable({
		tabs = {},
		byName = {},
		active = nil,
		options = options,
		connections = {},
		visible = true,
	}, App)

	local player = Players.LocalPlayer
	self.parent = options.parent or (player and player:WaitForChild("PlayerGui"))

	self:_build()
	self:_bindInput()
	return self
end

function App:_track(connection)
	self.connections[#self.connections + 1] = connection
end

function App:_build()
	local gui = make("ScreenGui", {
		Name = "DriftUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 100,
		Parent = self.parent,
	})
	self.gui = gui

	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
	local startX = math.max(0, math.floor((viewport.X - Dim.W) / 2))
	local startY = math.max(0, math.floor((viewport.Y - Dim.H) / 2))

	local shell = make("Frame", {
		Name = "Shell",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(Dim.W, Dim.H),
		Position = UDim2.fromOffset(startX, startY),
		Parent = gui,
	})
	self.shell = shell

	-- Depth without a shadow pass: two rounded plates sitting slightly larger and
	-- slightly lower than the window. Cheap, and it lifts the shell off the game.
	local outer = make("Frame", {
		Name = "ShadowOuter",
		BackgroundColor3 = Theme.Shadow,
		BackgroundTransparency = 0.86,
		Size = UDim2.new(1, 18, 1, 24),
		Position = UDim2.fromOffset(-9, -4),
		BorderSizePixel = 0,
		Parent = shell,
	})
	corner(outer, Dim.Radius + 8)

	local inner = make("Frame", {
		Name = "ShadowInner",
		BackgroundColor3 = Theme.Shadow,
		BackgroundTransparency = 0.72,
		Size = UDim2.new(1, 8, 1, 14),
		Position = UDim2.fromOffset(-4, 2),
		BorderSizePixel = 0,
		Parent = shell,
	})
	corner(inner, Dim.Radius + 3)

	local window = make("Frame", {
		Name = "Window",
		BackgroundColor3 = Theme.Shell,
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		Parent = shell,
	})
	corner(window, Dim.Radius)
	self.window = window

	local rail = make("Frame", {
		Name = "Rail",
		BackgroundColor3 = Theme.Rail,
		Size = UDim2.new(0, Dim.RailW, 1, -24),
		Position = UDim2.fromOffset(Dim.RailX, Dim.RailY),
		BorderSizePixel = 0,
		Parent = window,
	})
	corner(rail, Dim.CardRadius + 2)
	self.rail = rail

	local logo = Icons.build("dot", 22, Theme.Text, rail)
	logo.Position = UDim2.fromOffset(22, 22)

	local tabList = make("Frame", {
		Name = "TabList",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		Position = UDim2.fromOffset(0, 64),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = rail,
	})
	make("UIListLayout", {
		Padding = UDim.new(0, 8),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = tabList,
	})
	self.tabList = tabList

	local avatar = make("Frame", {
		Name = "Avatar",
		BackgroundColor3 = Theme.CardAlt,
		Size = UDim2.fromOffset(36, 36),
		Position = UDim2.new(0.5, 0, 1, -18),
		AnchorPoint = Vector2.new(0.5, 1),
		BorderSizePixel = 0,
		Parent = rail,
	})
	corner(avatar, 18)
	stroke(avatar, Theme.Stroke, 1, 0.2)
	local avatarMark = Icons.build("user", 18, Theme.TextMuted, avatar)
	avatarMark.Position = UDim2.fromOffset(9, 9)

	local header = make("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, Dim.ContentW, 0, Dim.HeaderH),
		Position = UDim2.fromOffset(Dim.ContentX, 12),
		Parent = window,
	})
	self.header = header

	textLabel({
		Size = UDim2.new(0, 220, 1, 0),
		Font = Theme.FontBold,
		TextSize = 15,
		Text = self.options.title or "Drift",
		Parent = header,
	})

	textLabel({
		Size = UDim2.new(0, 80, 1, 0),
		Position = UDim2.new(1, -196, 0, 0),
		Font = Theme.FontMono,
		TextSize = 10,
		TextColor3 = Theme.TextDim,
		Text = self.options.version or "",
		Parent = header,
	})

	-- > search
	local searchWrap = make("Frame", {
		Name = "Search",
		BackgroundColor3 = Theme.Field,
		Size = UDim2.fromOffset(32, 32),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -44, 0.5, 0),
		ClipsDescendants = true,
		Parent = header,
	})
	corner(searchWrap, 9)
	local searchLine = stroke(searchWrap, Theme.Stroke, 1, 0)

	local searchIcon = Icons.build("search", 15, Theme.TextMuted, searchWrap)
	searchIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	searchIcon.Position = UDim2.new(1, -16, 0.5, 0)

	local searchBox = make("TextBox", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -42, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Font = Theme.Font,
		TextSize = 12,
		TextColor3 = Theme.Text,
		PlaceholderText = "search",
		PlaceholderColor3 = Theme.TextDim,
		Text = "",
		ClearTextOnFocus = false,
		Visible = false,
		Parent = searchWrap,
	})
	self.searchBox = searchBox
	self.searchBar = searchWrap

	local openSearch = false
	local function setSearch(state)
		if openSearch == state then
			return
		end
		openSearch = state
		if state then
			searchBox.Visible = true
			tween(searchWrap, { Size = UDim2.fromOffset(190, 32) }, 0.18)
			task.defer(function()
				searchBox:CaptureFocus()
			end)
		else
			searchBox.Text = ""
			self:_filter("")
			tween(searchWrap, { Size = UDim2.fromOffset(32, 32) }, 0.18)
			task.delay(0.18, function()
				searchBox.Visible = false
			end)
		end
	end

	searchWrap.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not openSearch then
			setSearch(true)
		end
	end)
	searchWrap.MouseEnter:Connect(function()
		searchLine.Color = Theme.StrokeLit
	end)
	searchWrap.MouseLeave:Connect(function()
		searchLine.Color = searchBox:IsFocused() and Theme.Accent or Theme.Stroke
	end)
	searchBox.Focused:Connect(function()
		searchLine.Color = Theme.Accent
	end)
	searchBox.FocusLost:Connect(function()
		searchLine.Color = Theme.Stroke
		if searchBox.Text == "" then
			setSearch(false)
		end
	end)
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		self:_filter(searchBox.Text)
	end)

	-- > close
	local close = make("TextButton", {
		Name = "Close",
		BackgroundColor3 = Theme.Field,
		Size = UDim2.fromOffset(32, 32),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		AutoButtonColor = false,
		Text = "",
		Parent = header,
	})
	corner(close, 9)
	self.closeButton = close
	local closeIcon = Icons.build("close", 13, Theme.TextMuted, close)
	closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	closeIcon.Position = UDim2.fromScale(0.5, 0.5)
	close.MouseButton1Click:Connect(function()
		self:SetVisible(false)
	end)
	close.MouseEnter:Connect(function()
		close.BackgroundColor3 = Theme.CardAlt
	end)
	close.MouseLeave:Connect(function()
		close.BackgroundColor3 = Theme.Field
	end)

	-- > body
	local body = make("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(Dim.ContentX, Dim.BodyY),
		Size = UDim2.new(0, Dim.ContentW, 0, Dim.BodyH),
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollingEnabled = true,
		ClipsDescendants = true,
		Parent = window,
	})
	self.body = body

	local colW = math.floor((Dim.ContentW - Dim.CardGap) / 2)
	self.columns = {}

	for index = 1, 2 do
		local column = make("Frame", {
			Name = "Column" .. index,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(colW, 0),
			Position = UDim2.fromOffset((index - 1) * (colW + Dim.CardGap), 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = body,
		})
		make("UIListLayout", {
			Padding = UDim.new(0, Dim.CardGap),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = column,
		})
		self.columns[index] = column
	end

	-- > pager
	local pager = make("TextButton", {
		Name = "Pager",
		BackgroundColor3 = Theme.Shell,
		Size = UDim2.fromOffset(158, 30),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		AutoButtonColor = false,
		Text = "",
		Parent = window,
	})
	corner(pager, 15)
	local pagerLine = stroke(pager, Theme.Accent, 1, 0.35)
	self.pager = pager

	local dot = make("Frame", {
		BackgroundColor3 = Theme.Accent,
		Size = UDim2.fromOffset(8, 8),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 22, 0.5, 0),
		BorderSizePixel = 0,
		Parent = pager,
	})
	corner(dot, 4)

	local pagerText = textLabel({
		Size = UDim2.new(1, -40, 1, 0),
		Position = UDim2.fromOffset(34, 0),
		Font = Theme.FontMedium,
		TextSize = 12,
		TextColor3 = Theme.Text,
		Text = "—",
		Parent = pager,
	})
	self.pagerText = pagerText

	pager.MouseButton1Click:Connect(function()
		self:Cycle(1)
	end)
	pager.MouseEnter:Connect(function()
		pagerLine.Transparency = 0.05
		pager.BackgroundColor3 = Theme.Rail
	end)
	pager.MouseLeave:Connect(function()
		pagerLine.Transparency = 0.35
		pager.BackgroundColor3 = Theme.Shell
	end)

	-- Overlay layer for popups: a sibling of the window children so a dropdown can
	-- spill past the scrolling card area instead of being clipped by it.
	local overlay = make("Frame", {
		Name = "Overlay",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 200,
		ClipsDescendants = false,
		Parent = window,
	})
	self.overlay = overlay

	self._canvasDirty = true
	self:_startLoop()
end

function App:_startLoop()
	self:_track(RunService.Heartbeat:Connect(function()
		if not self._canvasDirty then
			return
		end
		local tallest = 0
		for _, column in ipairs(self.columns) do
			tallest = math.max(tallest, column.AbsoluteSize.Y)
		end
		local wanted = math.max(0, math.ceil(tallest + 4))
		local current = self.body.CanvasSize.Y.Offset
		if math.abs(current - wanted) >= 1 then
			self.body.CanvasSize = UDim2.fromOffset(0, wanted)
		else
			-- Settled. Stop measuring until something changes the content again.
			self._canvasDirty = false
		end
	end))
end

function App:_touch()
	self._canvasDirty = true
end

function App:_bindInput()
	local function viewport()
		local camera = workspace.CurrentCamera
		return camera and camera.ViewportSize or Vector2.new(1920, 1080)
	end

	local dragStart = nil
	local dragOrigin = nil

	self.header.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		-- The header holds the search field and the close button. Pressing those
		-- must not start a drag, so anything right of the last header control is
		-- left alone. X only: GetMouseLocation is offset by the top bar while GUI
		-- positions are not.
		local limit = math.min(self.searchBar.AbsolutePosition.X, self.closeButton.AbsolutePosition.X) - 8
		if UserInputService:GetMouseLocation().X >= limit then
			return
		end
		dragStart = UserInputService:GetMouseLocation()
		dragOrigin = Vector2.new(self.shell.Position.X.Offset, self.shell.Position.Y.Offset)
	end)

	self:_track(UserInputService.InputChanged:Connect(function(input)
		if not dragStart or input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local now = UserInputService:GetMouseLocation()
		local delta = now - dragStart
		local view = viewport()
		local x = math.clamp(dragOrigin.X + delta.X, -Dim.W + 140, view.X - 140)
		local y = math.clamp(dragOrigin.Y + delta.Y, 0, math.max(0, view.Y - 60))
		self.shell.Position = UDim2.fromOffset(x, y)
	end))

	self:_track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragStart = nil
		end
	end))

	self:_track(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == (self.options.key or Enum.KeyCode.Insert) then
			self:SetVisible(not self.visible)
		end
	end))
end

function App:_filter(query)
	query = string.lower(query or "")
	for _, tab in ipairs(self.tabs) do
		for _, card in ipairs(tab.cards) do
			local match = query == "" or string.find(string.lower(card.title), query, 1, true) ~= nil
			card.frame.Visible = match
		end
	end
	self:_touch()
end

function App:Tab(name, iconKind)
	local tab = setmetatable({
		app = self,
		name = name,
		label = name:sub(1, 1):upper() .. name:sub(2),
		cards = {},
		columns = self.columns,
		order = 0,
		cardsMade = 0,
		index = #self.tabs + 1,
	}, Tab)

	local button = make("TextButton", {
		Name = "Tab_" .. name,
		BackgroundColor3 = Theme.CardAlt,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(44, 44),
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = tab.index,
		Parent = self.tabList,
	})
	corner(button, 13)

	local mark, paint = Icons.build(iconKind or "dot", 21, Theme.TextMuted, button)
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Position = UDim2.fromScale(0.5, 0.5)

	tab.button = button
	tab.paint = paint

	button.MouseEnter:Connect(function()
		if self.active ~= tab then
			button.BackgroundTransparency = 0.9
			paint(Theme.Text)
		end
	end)
	button.MouseLeave:Connect(function()
		if self.active ~= tab then
			button.BackgroundTransparency = 1
			paint(Theme.TextMuted)
		end
	end)
	button.MouseButton1Click:Connect(function()
		self:Select(name)
	end)

	self.tabs[#self.tabs + 1] = tab
	self.byName[name] = tab

	if not self.active then
		self:Select(name)
	end
	return tab
end

function App:Select(name)
	local tab = self.byName[name]
	if not tab or self.active == tab then
		return
	end

	if self.active then
		local previous = self.active
		previous.button.BackgroundTransparency = 1
		previous.button.BackgroundColor3 = Theme.CardAlt
		previous.paint(Theme.TextMuted)
	end

	self.active = tab
	tab.button.BackgroundTransparency = 0
	tab.button.BackgroundColor3 = Theme.Accent
	tab.paint(Theme.OnAccent)
	self.pagerText.Text = tab.label
	self:closePopup()
	self:_touch()
end

function App:Cycle(step)
	local count = #self.tabs
	if count == 0 or not self.active then
		return
	end
	local index = ((self.active.index - 1 + (step or 1)) % count) + 1
	self:Select(self.tabs[index].name)
end

function App:SetVisible(state)
	self.visible = state
	self.shell.Visible = state
end

function App:Toggle()
	self:SetVisible(not self.visible)
end

function App:closePopup()
	for _, object in ipairs(self.popupParts or {}) do
		object:Destroy()
	end
	self.popupParts = nil
end

-- Shared popup frame: a catcher covering the whole window closes on an outside
-- click, and the panel above it holds the actual controls.
function App:_popupShell(anchor, width, height)
	self:closePopup()

	local overlay = self.overlay
	local origin = overlay.AbsolutePosition
	local anchorPos = anchor.AbsolutePosition
	local anchorSize = anchor.AbsoluteSize

	local left = anchorPos.X - origin.X
	local top = anchorPos.Y - origin.Y

	local x = left + anchorSize.X - width
	local y = top + anchorSize.Y + 6

	if y + height > Dim.H - 12 then
		y = top - height - 6
	end
	x = math.clamp(x, 8, math.max(8, Dim.W - width - 8))
	y = math.clamp(y, 8, math.max(8, Dim.H - height - 8))

	local catcher = make("TextButton", {
		Name = "PopupCatcher",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		AutoButtonColor = false,
		ZIndex = 209,
		Parent = overlay,
	})
	catcher.MouseButton1Click:Connect(function()
		self:closePopup()
	end)

	local panel = make("Frame", {
		Name = "Popup",
		BackgroundColor3 = Theme.CardAlt,
		Size = UDim2.fromOffset(width, height),
		Position = UDim2.fromOffset(x, y),
		BorderSizePixel = 0,
		ZIndex = 210,
		Parent = overlay,
	})
	corner(panel, Dim.ControlRadius + 3)
	stroke(panel, Theme.Stroke, 1, 0.15)

	self.popupParts = { catcher, panel }
	return panel
end

function App:popup(anchor, width, options, current, onPick)
	local rowH = 28
	local height = #options * rowH + 8
	local panel = self:_popupShell(anchor, width, height)

	for index, option in ipairs(options) do
		local row = make("TextButton", {
			BackgroundColor3 = Theme.CardAlt,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -8, 0, rowH - 2),
			Position = UDim2.fromOffset(4, 4 + (index - 1) * rowH),
			AutoButtonColor = false,
			Text = "",
			ZIndex = 211,
			Parent = panel,
		})
		corner(row, 6)

		textLabel({
			Size = UDim2.new(1, -20, 1, 0),
			Position = UDim2.fromOffset(10, 0),
			Font = Theme.Font,
			TextSize = 12,
			TextColor3 = (option == current) and Theme.Accent or Theme.TextMuted,
			Text = tostring(option),
			ZIndex = 212,
			Parent = row,
		})

		row.MouseEnter:Connect(function()
			row.BackgroundTransparency = 0.4
		end)
		row.MouseLeave:Connect(function()
			row.BackgroundTransparency = 1
		end)
		row.MouseButton1Click:Connect(function()
			self:closePopup()
			onPick(option)
		end)
	end
end

function App:popupGrid(anchor, width, presets, current, onPick)
	local palette = presets or {
		Color3.fromRGB(232, 84, 96),
		Color3.fromRGB(240, 138, 74),
		Color3.fromRGB(240, 200, 90),
		Color3.fromRGB(126, 208, 116),
		Color3.fromRGB(96, 206, 190),
		Color3.fromRGB(74, 144, 230),
		Color3.fromRGB(126, 116, 232),
		Color3.fromRGB(206, 116, 220),
		Color3.fromRGB(255, 255, 255),
		Color3.fromRGB(150, 150, 160),
		Color3.fromRGB(90, 90, 98),
		Color3.fromRGB(20, 20, 24),
	}

	local chip, gap = 40, 8
	local columns = 5
	local rows = math.ceil(#palette / columns)
	local height = rows * (chip + gap) + gap + 2

	local panel = self:_popupShell(anchor, width, height)

	for index, color in ipairs(palette) do
		local column = (index - 1) % columns
		local row = math.floor((index - 1) / columns)

		local swatch = make("TextButton", {
			BackgroundColor3 = color,
			Size = UDim2.fromOffset(chip, chip),
			Position = UDim2.fromOffset(8 + column * (chip + gap), 8 + row * (chip + gap)),
			AutoButtonColor = false,
			Text = "",
			ZIndex = 211,
			Parent = panel,
		})
		corner(swatch, 9)
		stroke(swatch, Theme.StrokeLit, 1, 0.55)

		swatch.MouseEnter:Connect(function()
			tween(swatch, { Size = UDim2.fromOffset(chip + 2, chip + 2) }, 0.1)
		end)
		swatch.MouseLeave:Connect(function()
			tween(swatch, { Size = UDim2.fromOffset(chip, chip) }, 0.1)
		end)
		swatch.MouseButton1Click:Connect(function()
			self:closePopup()
			onPick(color)
		end)
	end
end

function App:Destroy()
	for _, connection in ipairs(self.connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	self.connections = {}
	self:closePopup()
	if self.gui then
		self.gui:Destroy()
		self.gui = nil
	end
end

DriftUI.Theme = Theme
DriftUI.Dim = Dim
DriftUI.Icons = Icons


local app = DriftUI.new({
	parent = __parent,
	title = "Drift",
	version = "v2.4.1",
	key = Enum.KeyCode.Insert,
})

local state = {}

local function track(key)
	return function(value)
		state[key] = value
	end
end

-- > aimbot

local aim = app:Tab("aimbot", "target")

local silent = aim:Card("silent aim", "diamond")
silent:Toggle({ text = "Target-Bot", default = true, changed = track("targetBot") })
silent:Slider({ text = "Field of view", min = 0, max = 360, default = 120, changed = track("fov") })
silent:Dropdown({
	text = "Hit part",
	options = { "Head", "Torso", "Random" },
	default = "Head",
	changed = track("hitPart"),
})
silent:Keybind({ text = "Toggle key", default = "None", changed = track("aimKey") })

local checks = aim:Card("checks & fov", "shield")
checks:Toggle({ text = "Wall check", default = true, changed = track("wallCheck") })
checks:Toggle({ text = "Visible check", default = true, changed = track("visCheck") })
checks:Toggle({ text = "FOV circle", default = false, changed = track("fovCircle") })
checks:Slider({ text = "Circle radius", min = 20, max = 500, default = 120, changed = track("circleRadius") })
checks:Color({
	text = "Circle colour",
	default = Color3.fromRGB(74, 144, 230),
	changed = track("circleColour"),
})

-- > visuals

local visuals = app:Tab("visuals", "eye")

local esp = visuals:Card("player esp", "user")
esp:Toggle({ text = "Boxes", default = true, changed = track("boxes") })
esp:Toggle({ text = "Names", default = true, changed = track("names") })
esp:Toggle({ text = "Health bar", default = false, changed = track("health") })
esp:Dropdown({
	text = "Team check",
	options = { "Enemies", "All", "Team only" },
	default = "Enemies",
	changed = track("teamCheck"),
})
esp:Color({
	text = "Box colour",
	default = Color3.fromRGB(96, 206, 140),
	changed = track("boxColour"),
})

local chams = visuals:Card("chams", "spark")
chams:Toggle({ text = "Enabled", default = false, changed = track("chams") })
chams:Slider({ text = "Transparency", min = 0, max = 1, decimals = 2, default = 0.35, changed = track("chamAlpha") })
chams:Color({
	text = "Colour",
	default = Color3.fromRGB(126, 116, 232),
	changed = track("chamColour"),
})

-- > player

local player = app:Tab("player", "gear")

local whitelist = player:Card("player whitelist", "shield")
local entries = {}

local listHandle = whitelist:Label("no players whitelisted")

whitelist:TextBox({ text = "Username", placeholder = "name", default = "", changed = track("whitelistEntry") })
whitelist:Button({
	text = "Add player",
	clicked = function()
		local name = state.whitelistEntry
		if not name or name == "" then
			return
		end
		for _, existing in ipairs(entries) do
			if existing == name then
				return
			end
		end
		entries[#entries + 1] = name
		listHandle.Text = table.concat(entries, ", ")
	end,
})

local priority = player:Card("target priority", "target")
priority:Dropdown({
	text = "Priority",
	options = { "Closest", "Lowest health", "Crosshair" },
	default = "Closest",
	changed = track("priority"),
})
priority:Toggle({ text = "Ignore whitelisted", default = true, changed = track("ignoreWhitelist") })
priority:Slider({ text = "Max distance", min = 50, max = 2000, default = 500, changed = track("maxDistance") })

-- > misc

local misc = app:Tab("misc", "bolt")

local movement = misc:Card("movement", "spark")
movement:Slider({ text = "Walk speed", min = 16, max = 200, default = 16, changed = track("walkSpeed") })
movement:Toggle({ text = "Infinite jump", default = false, changed = track("infiniteJump") })

local world = misc:Card("world", "target")
world:Toggle({ text = "Full bright", default = false, changed = track("fullBright") })
world:Dropdown({
	text = "Time of day",
	options = { "Default", "Noon", "Sunset", "Night" },
	default = "Default",
	changed = track("timeOfDay"),
})

-- > config

local config = app:Tab("config", "sliders")

local profiles = config:Card("profiles", "sliders")
profiles:TextBox({ text = "Profile name", placeholder = "default", default = "default", changed = track("profile") })
profiles:Button({ text = "Save profile", clicked = function() end })
profiles:Button({ text = "Load profile", clicked = function() end })
profiles:Dropdown({
	text = "On open",
	options = { "Remember last", "Always default", "Ask" },
	default = "Remember last",
	changed = track("onOpen"),
})

local about = config:Card("about", "shield")
about:Label("drift-ui 1.0")
about:Label("Insert toggles the menu. Drag the header to move it.")
