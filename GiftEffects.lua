-- GiftEffects: server-side visual/audio effects for gift events.
-- All effects are fire-and-forget; they clean themselves up.

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GiftEffects = {}

-- Sound asset IDs (free Creator Store assets + classic Roblox sounds)
local SOUND_DING = "rbxassetid://9126073001" -- synth bell ding
local SOUND_CHEER = "rbxassetid://126615573673174" -- crowd cheering
local SOUND_DRUMROLL = "rbxassetid://4398694764" -- drumroll
local SOUND_EXPLOSION = "rbxassetid://165969964" -- classic explosion

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local cameraShakeEvent = ReplicatedStorage:FindFirstChild("GiftCameraShake")

local TEAM_COLORS = {
	blue = Color3.fromRGB(50, 150, 255),
	red = Color3.fromRGB(255, 60, 60),
}

-- ============ helpers ============

local function playSound(parent, soundId, volume, pitch, duration)
	if not parent then return end
	local ok = pcall(function()
		local sound = Instance.new("Sound")
		sound.SoundId = soundId
		sound.Volume = volume or 0.5
		sound.PlaybackSpeed = pitch or 1
		sound.Parent = parent
		sound:Play()
		if duration then
			task.delay(duration, function() sound:Stop() end)
		end
		-- cleanup after the sound has had time to finish
		task.delay(10, function()
			if sound then sound:Destroy() end
		end)
	end)
	return ok
end

local function makeParticle(parent, color, size, speed, lifetime, texture)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = texture or SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(lifetime * 0.6, lifetime)
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0 -- burst-only, we call :Emit manually
	emitter.LightEmission = 0.8
	emitter.Parent = parent
	return emitter
end

local function burstAndClean(part, emitter, count, cleanupDelay)
	emitter:Emit(count)
	task.delay(cleanupDelay or 3, function()
		if part then part:Destroy() end
	end)
end

local function getRoot(model)
	return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
end

local function shakeAllClients(intensity)
	if cameraShakeEvent then
		cameraShakeEvent:FireAllClients(intensity)
	end
end

-- big floating "+N" text above the gifter's head: rises and fades out.
-- This is the single most visible gift indicator.
function GiftEffects.giftPopup(model, delta, team)
	local root = getRoot(model)
	local head = model:FindFirstChild("Head")
	if not root then return end

	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = (head and head.Position or root.Position) + Vector3.new(0, 3, 0)
	anchor.Parent = workspace

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.new(0, 260, 0, 90)
	bb.AlwaysOnTop = true
	bb.StudsOffset = Vector3.new(0, 0, 0)
	bb.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = "+" .. tostring(delta) .. " coins"
	label.TextColor3 = TEAM_COLORS[team] or Color3.fromRGB(255, 215, 0)
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.Parent = bb

	-- pop in, rise, and fade
	task.spawn(function()
		local grow = TweenService:Create(bb, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 340, 0, 120),
		})
		grow:Play()
		grow.Completed:Wait()

		local rise = TweenService:Create(anchor, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = anchor.Position + Vector3.new(0, 6, 0),
		})
		local fade = TweenService:Create(label, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
		rise:Play()
		fade:Play()
		fade.Completed:Wait()
		anchor:Destroy()
	end)
end

-- brief colored outline flash on the gifter so they pop out of the crowd
function GiftEffects.flashHighlight(model, team)
	local color = TEAM_COLORS[team] or Color3.fromRGB(255, 215, 0)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = color
	highlight.OutlineTransparency = 0
	highlight.Parent = model
	task.delay(1.5, function()
		if highlight then highlight:Destroy() end
	end)
end

-- ============ tier 1: sparkles + ding ============

function GiftEffects.sparkles(model, comboPitch)
	local root = getRoot(model)
	if not root then return end
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = root.Position + Vector3.new(0, 2, 0)
	anchor.Parent = workspace
	local emitter = makeParticle(anchor, Color3.fromRGB(255, 230, 120), 1.2, 8, 1.4)
	burstAndClean(anchor, emitter, 45, 2.5)
	playSound(anchor, SOUND_DING, 0.4, comboPitch or 1, 1.5)
end

-- ============ tier 2: golden shockwave + cheer ============

function GiftEffects.shockwave(model)
	local root = getRoot(model)
	if not root then return end

	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 200, 60)
	ring.Anchored = true
	ring.CanCollide = false
	ring.Size = Vector3.new(0.4, 2, 2)
	ring.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace

	local tween = TweenService:Create(ring, TweenInfo.new(0.7, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.4, 30, 30),
		Transparency = 1,
	})
	tween:Play()
	tween.Completed:Once(function()
		ring:Destroy()
	end)

	playSound(root, SOUND_CHEER, 0.5, 1, 2)
end

-- ============ tier 3: lightning strike + shake + emote ============

local CHEER_ANIM_ID = "rbxassetid://507770677" -- R15 cheer emote

function GiftEffects.playEmote(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local ok = pcall(function()
		local anim = Instance.new("Animation")
		anim.AnimationId = CHEER_ANIM_ID
		local track = animator:LoadAnimation(anim)
		track:Play()
		task.delay(2.5, function()
			if track then track:Stop() end
		end)
	end)
	return ok
end

function GiftEffects.lightning(model)
	local root = getRoot(model)
	if not root then return end

	local top = root.Position + Vector3.new(0, 60, 0)
	local bottom = root.Position
	local bolt = Instance.new("Part")
	bolt.Material = Enum.Material.Neon
	bolt.Color = Color3.fromRGB(170, 200, 255)
	bolt.Anchored = true
	bolt.CanCollide = false
	bolt.Size = Vector3.new(0.8, (top - bottom).Magnitude, 0.8)
	bolt.CFrame = CFrame.new((top + bottom) / 2)
	bolt.Parent = workspace

	-- flash the whole bolt a few times then remove
	task.spawn(function()
		for _ = 1, 3 do
			bolt.Transparency = 0
			task.wait(0.06)
			bolt.Transparency = 0.7
			task.wait(0.06)
		end
		bolt:Destroy()
	end)

	-- impact burst at the feet
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = bottom
	anchor.Parent = workspace
	local emitter = makeParticle(anchor, Color3.fromRGB(200, 220, 255), 1, 14, 0.8)
	burstAndClean(anchor, emitter, 40, 2)

	playSound(root, SOUND_EXPLOSION, 0.4, 1.5, 1)
	shakeAllClients(0.5)
end

-- ============ tier 4: coin meteor + confetti + big shake ============

function GiftEffects.meteor(model)
	local root = getRoot(model)
	if not root then return end
	local target = root.Position

	local rock = Instance.new("Part")
	rock.Shape = Enum.PartType.Ball
	rock.Material = Enum.Material.Neon
	rock.Color = Color3.fromRGB(255, 170, 40)
	rock.Anchored = true
	rock.CanCollide = false
	rock.Size = Vector3.new(3, 3, 3)
	rock.Position = target + Vector3.new(6, 70, 0)
	rock.Parent = workspace

	-- fiery trail
	local trailEmitter = makeParticle(rock, Color3.fromRGB(255, 140, 30), 2.5, 2, 0.6)
	trailEmitter.Rate = 60

	local tween = TweenService:Create(rock, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		CFrame = CFrame.new(target),
	})
	tween:Play()
	tween.Completed:Once(function()
		rock:Destroy()

		-- explosion burst of coins
		local anchor = Instance.new("Part")
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Position = target
		anchor.Parent = workspace
		local coinBurst = makeParticle(anchor, Color3.fromRGB(255, 215, 0), 1, 18, 1.4)
		burstAndClean(anchor, coinBurst, 120, 3)

		playSound(anchor, SOUND_EXPLOSION, 0.6, 1, 2)
		shakeAllClients(1)
	end)
end

function GiftEffects.confetti(model)
	local root = getRoot(model)
	if not root then return end
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = root.Position + Vector3.new(0, 4, 0)
	anchor.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 180, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 230, 90)),
	})
	emitter.Size = NumberSequence.new(0.8)
	emitter.Lifetime = NumberRange.new(1.5, 2.5)
	emitter.Speed = NumberRange.new(20, 30)
	emitter.SpreadAngle = Vector2.new(60, 60)
	emitter.Acceleration = Vector3.new(0, -30, 0)
	emitter.Rate = 0
	emitter.Parent = anchor

	burstAndClean(anchor, emitter, 150, 4)
end

-- ============ team reactions ============

-- lean every character on a team back for a moment, like they're digging in
function GiftEffects.leanTeam(models, team)
	-- leaning back is a local pitch rotation, identical for both facing directions
	local angle = 12
	task.spawn(function()
		for _, model in pairs(models) do
			local pivot = model:GetPivot()
			model:PivotTo(pivot * CFrame.Angles(math.rad(angle), 0, 0))
		end
		task.wait(0.35)
		for _, model in pairs(models) do
			if model.Parent then
				local pivot = model:GetPivot()
				model:PivotTo(pivot * CFrame.Angles(math.rad(-angle), 0, 0))
			end
		end
	end)
end

-- colored aura on every character of a team (milestone celebration)
function GiftEffects.teamAura(models, team)
	local color = TEAM_COLORS[team] or Color3.new(1, 1, 1)
	for _, model in pairs(models) do
		local highlight = Instance.new("Highlight")
		highlight.FillColor = color
		highlight.FillTransparency = 0.6
		highlight.OutlineColor = color
		highlight.Parent = model
		task.delay(3, function()
			if highlight then highlight:Destroy() end
		end)
	end
end

-- glowing strip on the ground under the leading team's line
local glowParts = {}
function GiftEffects.setGroundGlow(team, centerPosition, length)
	-- remove any existing glow
	for _, p in pairs(glowParts) do
		if p then p:Destroy() end
	end
	glowParts = {}
	if not team then return end

	local color = TEAM_COLORS[team]
	if not color then return end

	local glow = Instance.new("Part")
	glow.Name = "TeamGroundGlow"
	glow.Material = Enum.Material.Neon
	glow.Color = color
	glow.Anchored = true
	glow.CanCollide = false
	glow.Size = Vector3.new(length or 20, 0.2, 8)
	glow.Position = centerPosition - Vector3.new(0, 4.8, 0)
	glow.Transparency = 0.4
	glow.Parent = workspace
	table.insert(glowParts, glow)

	-- gentle pulse
	task.spawn(function()
		while glow.Parent do
			local t = TweenService:Create(glow, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Transparency = 0.15 })
			t:Play()
			t.Completed:Wait()
			if not glow.Parent then break end
			local t2 = TweenService:Create(glow, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Transparency = 0.4 })
			t2:Play()
			t2.Completed:Wait()
		end
	end)
end

-- ============ rope wobble ============

-- after the rope snaps to a new position, briefly overshoot toward the pulling
-- team and spring back so the movement feels physical
function GiftEffects.ropeWobble(ropePart, targetCFrame, pullDirection)
	if not ropePart or not targetCFrame then return end
	local dir = pullDirection or 1
	local overshoot = targetCFrame.Position + Vector3.new(dir * 2.5, 0, 0)

	local t1 = TweenService:Create(ropePart, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(overshoot) * targetCFrame.Rotation,
	})
	t1:Play()
	t1.Completed:Once(function()
		local t2 = TweenService:Create(ropePart, TweenInfo.new(0.5, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
			CFrame = targetCFrame,
		})
		t2:Play()
	end)
end

-- ============ crown drama ============

function GiftEffects.crownExplosion(position)
	if not position then return end
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = position
	anchor.Parent = workspace
	local emitter = makeParticle(anchor, Color3.fromRGB(255, 215, 0), 1, 12, 1)
	burstAndClean(anchor, emitter, 60, 2)
	playSound(anchor, SOUND_EXPLOSION, 0.3, 1.8, 1)
end

function GiftEffects.crownDrop(crownPart, targetPosition)
	if not crownPart then return end
	crownPart.Position = targetPosition + Vector3.new(0, 40, 0)
	crownPart.Transparency = 0
	local tween = TweenService:Create(crownPart, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = targetPosition,
	})
	tween:Play()
	tween.Completed:Once(function()
		-- dust puff on landing
		local anchor = Instance.new("Part")
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Position = targetPosition
		anchor.Parent = workspace
		local puff = makeParticle(anchor, Color3.fromRGB(200, 190, 160), 1.5, 8, 0.8)
		burstAndClean(anchor, puff, 30, 2)
	end)
end

-- ============ combo + drumroll ============

local comboTracker = {} -- [name] = {count, lastTime}
local COMBO_WINDOW = 6 -- seconds

function GiftEffects.getComboPitch(name)
	local now = os.clock()
	local entry = comboTracker[name]
	if not entry or (now - entry.lastTime) > COMBO_WINDOW then
		comboTracker[name] = { count = 1, lastTime = now }
		return 1
	end
	entry.count += 1
	entry.lastTime = now
	-- each combo step raises the ding pitch, capped
	return 1 + math.min(entry.count - 1, 8) * 0.12
end

function GiftEffects.drumroll(position)
	if not position then return end
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = position + Vector3.new(0, 8, 0)
	anchor.Parent = workspace
	playSound(anchor, SOUND_DRUMROLL, 0.6, 1, 3)
	task.delay(4, function()
		if anchor then anchor:Destroy() end
	end)
end

-- ============ persistent match-long aura ============

-- tiered aura that stays on a gifter for the whole match and deepens
-- as they gift more. Replaces the old 1.5s highlight flash.
local AURA_TIERS = {
	{ coins = 1,  color = Color3.fromRGB(255, 230, 120), fill = 0.85, beam = false, pad = false }, -- soft gold shimmer
	{ coins = 3,  color = Color3.fromRGB(255, 200, 60),  fill = 0.7,  beam = false, pad = true  }, -- golden glow + ground pad
	{ coins = 6,  color = Color3.fromRGB(255, 140, 40),  fill = 0.55, beam = true,  pad = true  }, -- orange aura + sky beam
	{ coins = 10, color = Color3.fromRGB(255, 80, 200),  fill = 0.4,  beam = true,  pad = true  }, -- hot pink legend aura
}

local function getAuraTier(coins)
	local tier = AURA_TIERS[1]
	for _, t in ipairs(AURA_TIERS) do
		if coins >= t.coins then tier = t end
	end
	return tier
end

-- remove any leftover aura pieces that live OUTSIDE the GiftAura folder
-- (light + sparkles sit on the torso, counter sits on the head) so tier
-- rebuilds don't stack duplicates on top of each other
local function clearAuraPieces(model)
	local root = getRoot(model)
	local torso = model:FindFirstChild("UpperTorso") or root
	if torso then
		for _, child in ipairs(torso:GetChildren()) do
			if child.Name == "AuraLight" or child.Name == "AuraSparkles" then
				child:Destroy()
			end
		end
	end
	local head = model:FindFirstChild("Head")
	if head then
		for _, child in ipairs(head:GetChildren()) do
			if child.Name == "AuraCounter" then
				child:Destroy()
			end
		end
	end
end

local function buildAura(model, coins, team)
	local tier = getAuraTier(coins)
	local root = getRoot(model)
	if not root then return end
	clearAuraPieces(model)

	local aura = Instance.new("Folder")
	aura.Name = "GiftAura"
	aura.Parent = model

	-- permanent team-colored highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "AuraHighlight"
	highlight.FillColor = tier.color
	highlight.FillTransparency = tier.fill
	highlight.OutlineColor = tier.color
	highlight.OutlineTransparency = 0
	highlight.Parent = aura

	-- glowing light at the chest so they visibly radiate
	local torso = model:FindFirstChild("UpperTorso") or root
	local light = Instance.new("PointLight")
	light.Name = "AuraLight"
	light.Color = tier.color
	light.Brightness = 1 + (coins >= 6 and 1 or 0)
	light.Range = 8 + math.min(coins, 10)
	light.Parent = torso

	-- continuous gentle sparkle stream rising off them
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "AuraSparkles"
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(tier.color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(1, 2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = coins >= 6 and 12 or 6
	emitter.LightEmission = 0.9
	emitter.Acceleration = Vector3.new(0, 2, 0)
	emitter.Parent = torso

	-- glowing pad on the ground under their feet (welded so it follows them)
	if tier.pad then
		local pad = Instance.new("Part")
		pad.Name = "AuraPad"
		pad.Shape = Enum.PartType.Cylinder
		pad.Material = Enum.Material.Neon
		pad.Color = tier.color
		pad.CanCollide = false
		pad.Massless = true
		pad.Size = Vector3.new(0.2, 4, 4)
		-- sit the pad on the actual ground under their feet (bounding-box
		-- based, so it works on scaled-up rigs too instead of sinking)
		local groundY = root.Position.Y - 3
		local okBox, boxCF, boxSize = pcall(function()
			return model:GetBoundingBox()
		end)
		if okBox then
			groundY = boxCF.Position.Y - boxSize.Y / 2
		end
		pad.CFrame = CFrame.new(root.Position.X, groundY + 0.15, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
		pad.Transparency = 0.5
		pad.Parent = aura
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = pad
		weld.Parent = aura
	end

	-- vertical beam of light into the sky for big gifters (welded to follow)
	if tier.beam then
		local beam = Instance.new("Part")
		beam.Name = "AuraBeam"
		beam.Material = Enum.Material.Neon
		beam.Color = tier.color
		beam.CanCollide = false
		beam.Massless = true
		beam.Size = Vector3.new(1.2, 60, 1.2)
		beam.CFrame = CFrame.new(root.Position + Vector3.new(0, 30, 0))
		beam.Transparency = 0.6
		beam.Parent = aura
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = beam
		weld.Parent = aura
	end

	-- floating gift counter above the name tag
	local head = model:FindFirstChild("Head")
	if head then
		local bb = Instance.new("BillboardGui")
		bb.Name = "AuraCounter"
		bb.Size = UDim2.new(0, 120, 0, 30)
		bb.StudsOffset = Vector3.new(0, 5, 0)
		bb.AlwaysOnTop = true
		bb.Parent = head

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.Text = "\u{1F381} " .. tostring(coins)
		label.TextColor3 = tier.color
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.Parent = bb
	end

	return aura
end

-- call every tick; rebuilds the aura only when the tier changes so it
-- persists for the whole match instead of flashing for 1.5 seconds
function GiftEffects.setPersistentAura(model, coins, team)
	if not model then return end
	if coins <= 0 then
		GiftEffects.clearAura(model)
		return
	end

	local existing = model:FindFirstChild("GiftAura")
	local tier = getAuraTier(coins)
	if existing then
		-- update the counter text in place; only rebuild if tier changed
		-- (the counter lives on the Head, OUTSIDE the GiftAura folder)
		local head = model:FindFirstChild("Head")
		local counter = head and head:FindFirstChild("AuraCounter")
		if counter then
			local label = counter:FindFirstChild("TextLabel")
			if label then
				label.Text = "\u{1F381} " .. tostring(coins)
			end
		end
		if existing:GetAttribute("TierCoins") ~= tier.coins then
			existing:Destroy()
			local aura = buildAura(model, coins, team)
			if aura then aura:SetAttribute("TierCoins", tier.coins) end
		end
		return
	end

	local aura = buildAura(model, coins, team)
	if aura then aura:SetAttribute("TierCoins", tier.coins) end
end

function GiftEffects.clearAura(model)
	if not model then return end
	local aura = model:FindFirstChild("GiftAura")
	if aura then aura:Destroy() end
	clearAuraPieces(model)
end

-- ============ rope-pulling animation ============

-- Team-specific custom looping R15 tug animations authored for this experience.
-- Assignments are intentionally swapped so each side uses the animation that
-- visually aligns with standing on the same side of the rope.
local TUG_ANIMATION_IDS = {
	blue = "rbxassetid://121056625780110",
	red = "rbxassetid://121056625780110",
	default = "rbxassetid://121056625780110",
}
local pullStates = {} -- [model] = {team, animationId, baseIntensity, boost, animation, track}

local function getAnimator(model)
	local humanoid = model and model:FindFirstChildWhichIsA("Humanoid")
	if not humanoid then return nil end

	local animator = humanoid:FindFirstChildWhichIsA("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	return animator, humanoid
end

local function getPullSpeed(state)
	local intensity = math.clamp((state.baseIntensity or 1) + (state.boost or 0), 0.75, 2.25)
	-- Keep the animation readable at low/no gifts, then ramp visible effort for
	-- gifted players and temporary team spikes.
	return math.clamp(0.9 + ((intensity - 1) * 0.45), 0.75, 1.55)
end

local function applyPullSpeed(state)
	if state and state.track then
		state.track:AdjustSpeed(getPullSpeed(state))
	end
end

local function cleanupPullState(state)
	if not state then return end
	local track = state.track
	if track then
		pcall(function()
			track:Stop(0.18)
		end)
		pcall(function()
			track:Destroy()
		end)
	end
	if state.animation then
		state.animation:Destroy()
	end
	state.track = nil
	state.animation = nil
end

local function getAnimationIdForTeam(team)
	return TUG_ANIMATION_IDS[team] or TUG_ANIMATION_IDS.default
end

local function ensurePullAnimation(model, state)
	if not model or not model.Parent then return end
	local desiredAnimationId = getAnimationIdForTeam(state.team)
	if state.track and state.animationId == desiredAnimationId then
		if not state.track.IsPlaying then
			state.track:Play(0.18, 1, getPullSpeed(state))
		end
		applyPullSpeed(state)
		return
	elseif state.track then
		cleanupPullState(state)
	end

	local animator = getAnimator(model)
	if not animator then return end

	local animation = Instance.new("Animation")
	animation.Name = "CustomTugPullAnimation"
	animation.AnimationId = desiredAnimationId

	local ok, trackOrErr = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if not ok or not trackOrErr then
		animation:Destroy()
		return
	end

	local track = trackOrErr
	track.Name = "CustomTugPullTrack"
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action
	state.animation = animation
	state.animationId = desiredAnimationId
	state.track = track
	track:Play(0.18, 1, getPullSpeed(state))
end

-- call every tick after positioning + grounding the model; starts/maintains the
-- correct team-specific tug animation without changing the model pivot, so it
-- will not fight the main rope/team positioning code
function GiftEffects.setPullBase(model, baseCFrame, team)
	if not model or not baseCFrame then return end
	local state = pullStates[model]
	if not state then
		state = {
			team = team,
			baseIntensity = 1,
			boost = 0,
		}
		pullStates[model] = state
	end
	state.team = team or state.team
	ensurePullAnimation(model, state)
end

-- gifters pull harder: faster custom tug animation, scaling with coins
function GiftEffects.setPullIntensity(model, coins)
	local state = pullStates[model]
	if not state then return end
	state.baseIntensity = 1 + math.min(coins or 0, 10) * 0.06
	applyPullSpeed(state)
end

-- temporary extra effort spike (e.g. whole team digging in after a gift);
-- decays back out after `duration` seconds
function GiftEffects.spikePull(model, amount, duration)
	local state = pullStates[model]
	if not state then return end
	state.boost = amount or 0
	applyPullSpeed(state)
	task.delay(duration or 1.5, function()
		if pullStates[model] == state then
			state.boost = 0
			applyPullSpeed(state)
		end
	end)
end

function GiftEffects.stopPulling(model)
	local state = pullStates[model]
	if state then
		cleanupPullState(state)
	end
	pullStates[model] = nil
end

-- ============ main entry point ============

-- delta = how many coins were gifted this event
function GiftEffects.onGift(model, name, delta, team, teamModels)
	if not model then return end
	local comboPitch = GiftEffects.getComboPitch(name)

	-- every gift, no matter the tier: popup so it's always obvious
	-- (the persistent aura handles the lasting highlight)
	GiftEffects.giftPopup(model, delta, team)

	if delta <= 2 then
		GiftEffects.sparkles(model, comboPitch)
	elseif delta <= 5 then
		GiftEffects.shockwave(model)
		GiftEffects.sparkles(model, comboPitch)
	elseif delta <= 9 then
		GiftEffects.lightning(model)
		GiftEffects.playEmote(model)
		GiftEffects.sparkles(model, comboPitch)
	else
		GiftEffects.meteor(model)
		GiftEffects.confetti(model)
		GiftEffects.playEmote(model)
	end

	-- the whole team digs in harder for a moment (the pull loop keeps
	-- everyone animated continuously; this spikes the effort)
	if teamModels and team then
		for _, m in pairs(teamModels) do
			GiftEffects.spikePull(m, 0.5, 1.5)
		end
	end
end

return GiftEffects
