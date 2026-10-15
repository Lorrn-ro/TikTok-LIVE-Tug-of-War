local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local GiftEffects = require(game.ServerScriptService.GiftEffects)
local RagdollModule = require(game.ServerScriptService.RagdollModule)

-- NOTE: replace this with your own public tunnel URL (e.g. from ngrok) before
-- running. It must point at your own locally-running Flask server (server.py),
-- at the "/data" route. Example: "https://your-subdomain.ngrok-free.dev/data"
local DATA_ENDPOINT = "https://YOUR_NGROK_URL_HERE/data"

-- add near your other state variables at the top
local assignedSlot = {}     -- name -> permanent slot number, set once
local nextSlot = { blue = 0, red = 0 }

local spawnedModels = {}
local currentCrown = nil
local ropePart = nil
local ropeVisuals = nil

local ATMOSPHERE_SMOOTH_SPEED = 2   -- slower than the rope: this should feel like it's rolling in
local inOvertime = false
local overtimeAlpha = 0   -- 0 = normal, 1 = fully intense

local ROPE_NORMAL_COLORS = {
	Color3.fromRGB(245, 215, 150),
	Color3.fromRGB(190, 135, 75),
	Color3.fromRGB(120, 75, 35),
}
local ROPE_HOT_COLOR = Color3.fromRGB(255, 60, 20)
local ROPE_CORE_NORMAL_COLOR = Color3.fromRGB(205, 150, 80)
local ROPE_CORE_HOT_COLOR = Color3.fromRGB(180, 20, 10)
local ROPE_SHAKE_MAX = 0.3   -- max random jitter in studs, at full intensity

local FALL_CLEANUP_DELAY = 6                   -- seconds the ragdolled body is left on the ground before despawn
local FALL_FLING_SPEED = 20                    -- sideways fling speed when they get knocked off the platform
local FALL_FLING_UP = 10                       -- upward pop so they clear the deck curb at the edge
local FALL_STAGGER = 0.8                       -- seconds between falls when several players are eliminated at once


-- gift event tracking
local prevCoins = {}
local crownOwner = nil
local teamGiftCount = { blue = 0, red = 0 }
local leadingTeam = nil
local drumrollPlayed = false
local lastRoundNumber = nil   -- round rollover detection for the round-end wipeout
local lastRopeValue = 0      -- rope value of the previous tick (who was losing)
local ROPE_DRUMROLL_THRESHOLD = 70 -- |rope| value that means a team is close to winning

local BLUE_START = Vector3.new(20, 10.7, 0)
local RED_START  = Vector3.new(-20, 10.7, 0)
local SPACING = 6
local ROPE_SCALE = 0.3
local MAX_VISIBLE_PER_TEAM = 7
local MAX_SPAWNS_PER_TICK = 1

-- add these near your other rope state, at the top of the file
local ROPE_SMOOTH_SPEED = 6   -- higher = catches up to the target faster (less smooth)
local currentRopeCFrame = nil
local currentRopeDistance = nil
local targetRopeCFrame = nil
local targetRopeDistance = nil
local ROPE_END_PADDING = 4   -- extra studs of rope sticking out past each end

-- add near your other top-level state
local currentPositions = {}   -- name -> current CFrame actually being drawn
local targetPositions = {}    -- name -> CFrame computed from the latest poll


-- new helper
local function getOrAssignSlot(name, team)
	if not assignedSlot[name] then
		nextSlot[team] = nextSlot[team] + 1
		assignedSlot[name] = nextSlot[team]
	end
	return assignedSlot[name]
end

local function getPositionInLine(team, index, rope)
	local shift = rope * ROPE_SCALE
	if team == "blue" then
		return BLUE_START + Vector3.new((index - 1) * SPACING + shift, 0, 0)
	else
		return RED_START + Vector3.new(-(index - 1) * SPACING + shift, 0, 0)
	end
end

-- Keep characters upright and stable. Procedural full-model leaning looked
-- unnatural across mixed avatar rigs, so the saved stance only turns each
-- team toward the rope; subtle tug motion is handled in GiftEffects.
-- Characters stand slightly offset from the rope line (Z=0) so the rope
-- passes through the gap between their arm and body (armpit).
-- Blue team is shifted to +Z, red team to -Z so the rope sits on their
-- pulling-hand side.
local function getRopeSideOffset(team)
	local offset = -0.5
	if team == "blue" then
		return Vector3.new(0, 0, offset)
	else
		return Vector3.new(0, 0, -offset)
	end
end

local function getFacingCFrame(team, pos)
	-- Face toward the center of the rope (perpendicular to the rope line).
	-- Blue team stands at +X so faces -X; red team stands at -X so faces +X.
	local bodyPos = pos + getRopeSideOffset(team)
	local lookDir = (team == "blue") and Vector3.new(-1, 0, 0) or Vector3.new(1, 0, 0)
	return CFrame.new(bodyPos, bodyPos + lookDir)
end

-- fixes characters sinking into the ground when they grow bigger
-- replace groundModel with this: instead of moving the model directly,
-- it just tells you HOW FAR OFF the ground the model's current pivot is
local function getGroundOffset(model)
	local ok, boxCFrame, boxSize = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok then return 0 end

	local pivotY = model:GetPivot().Position.Y
	local bottomY = boxCFrame.Position.Y - (boxSize.Y / 2)
	return pivotY - bottomY   -- how much higher the pivot sits above the feet right now
end
local HAND_ROPE_Y_OFFSET = 0 -- tune up/down if the rope sits slightly above/below the palms

local function getRopeAttachHeight(model)
	if not model then
		return nil
	end

	-- Prefer the animated hand positions so the rope lines up with the actual
	-- tug pose instead of cutting through upper arms/torso. Since the rope is one
	-- level cylinder across the front players, average both hands when available.
	local leftHand = model:FindFirstChild("LeftHand")
	local rightHand = model:FindFirstChild("RightHand")
	if leftHand and rightHand then
		return ((leftHand.Position.Y + rightHand.Position.Y) / 2) + HAND_ROPE_Y_OFFSET
	elseif leftHand then
		return leftHand.Position.Y + HAND_ROPE_Y_OFFSET
	elseif rightHand then
		return rightHand.Position.Y + HAND_ROPE_Y_OFFSET
	end

	-- Fallback for unexpected/non-R15 rigs.
	local root = model:FindFirstChild("HumanoidRootPart")
	local torso = model:FindFirstChild("UpperTorso") or root
	local head = model:FindFirstChild("Head")
	if root and torso then
		return math.min(torso.Position.Y - 0.15, root.Position.Y + 0.9)
	elseif torso then
		return torso.Position.Y - 0.15
	elseif root then
		return root.Position.Y + 0.9
	elseif head then
		return head.Position.Y - head.Size.Y * 0.8
	end
	return nil
end

local ROPE_CORE_DIAMETER = 0.5
local ROPE_STRAND_DIAMETER = 0.12
local ROPE_STRAND_RADIUS = 0.32
local ROPE_SEGMENT_COUNT = 28
local ROPE_WRAP_TURNS = 4.5
local ROPE_KNOT_SIZE = 0.9

local function makeRopeCylinder(name, color, material, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Material = material or Enum.Material.Fabric
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function ensureRopeVisuals(parent)
	if ropeVisuals and ropeVisuals.Parent then
		return ropeVisuals
	end

	ropeVisuals = Instance.new("Folder")
	ropeVisuals.Name = "TugRopeVisuals"
	ropeVisuals.Parent = workspace

	local strands = Instance.new("Folder")
	strands.Name = "BraidedStrands"
	strands.Parent = ropeVisuals

	for strandIndex = 1, 3 do
		for segmentIndex = 1, ROPE_SEGMENT_COUNT do
			local color
			if strandIndex == 1 then
				color = Color3.fromRGB(245, 215, 150)
			elseif strandIndex == 2 then
				color = Color3.fromRGB(190, 135, 75)
			else
				color = Color3.fromRGB(120, 75, 35)
			end
			makeRopeCylinder("Strand_" .. strandIndex .. "_" .. segmentIndex, color, Enum.Material.Fabric, strands)
		end
	end

	local knots = Instance.new("Folder")
	knots.Name = "EndKnots"
	knots.Parent = ropeVisuals
	makeRopeCylinder("LeftKnot", Color3.fromRGB(165, 105, 50), Enum.Material.Fabric, knots)
	makeRopeCylinder("RightKnot", Color3.fromRGB(165, 105, 50), Enum.Material.Fabric, knots)

	return ropeVisuals
end

local function updateRopeVisuals(baseCFrame, distance)
	local visuals = ensureRopeVisuals()
	local strandsFolder = visuals:FindFirstChild("BraidedStrands")
	local knotsFolder = visuals:FindFirstChild("EndKnots")
	if not strandsFolder or not knotsFolder then return end

	local segmentLength = distance / ROPE_SEGMENT_COUNT
	local usableLength = math.max(distance - ROPE_KNOT_SIZE, segmentLength)
	local startX = -usableLength / 2
	local twoPi = math.pi * 2

	for strandIndex = 1, 3 do
		local strandPhase = ((strandIndex - 1) / 3) * twoPi
		for segmentIndex = 1, ROPE_SEGMENT_COUNT do
			local segment = strandsFolder:FindFirstChild("Strand_" .. strandIndex .. "_" .. segmentIndex)
			if segment then
				local t1 = (segmentIndex - 1) / ROPE_SEGMENT_COUNT
				local t2 = segmentIndex / ROPE_SEGMENT_COUNT
				local angle1 = (t1 * ROPE_WRAP_TURNS * twoPi) + strandPhase
				local angle2 = (t2 * ROPE_WRAP_TURNS * twoPi) + strandPhase

				local p1 = Vector3.new(
					startX + (t1 * usableLength),
					math.cos(angle1) * ROPE_STRAND_RADIUS,
					math.sin(angle1) * ROPE_STRAND_RADIUS
				)
				local p2 = Vector3.new(
					startX + (t2 * usableLength),
					math.cos(angle2) * ROPE_STRAND_RADIUS,
					math.sin(angle2) * ROPE_STRAND_RADIUS
				)
				local center = (p1 + p2) / 2
				local worldP1 = baseCFrame:PointToWorldSpace(p1)
				local worldP2 = baseCFrame:PointToWorldSpace(p2)
				local worldCenter = baseCFrame:PointToWorldSpace(center)
				local length = (worldP2 - worldP1).Magnitude

				segment.Size = Vector3.new(length, ROPE_STRAND_DIAMETER, ROPE_STRAND_DIAMETER)
				segment.CFrame = CFrame.new(worldCenter, worldP2) * CFrame.Angles(0, math.rad(90), 0)
			end
		end
	end

	local leftKnot = knotsFolder:FindFirstChild("LeftKnot")
	local rightKnot = knotsFolder:FindFirstChild("RightKnot")
	if leftKnot then
		leftKnot.Size = Vector3.new(ROPE_KNOT_SIZE, ROPE_KNOT_SIZE, ROPE_KNOT_SIZE)
		leftKnot.CFrame = baseCFrame * CFrame.new(-distance / 2, 0, 0)
	end
	if rightKnot then
		rightKnot.Size = Vector3.new(ROPE_KNOT_SIZE, ROPE_KNOT_SIZE, ROPE_KNOT_SIZE)
		rightKnot.CFrame = baseCFrame * CFrame.new(distance / 2, 0, 0)
	end
end

local function ensureRopePart()
	if not ropePart then
		ropePart = Instance.new("Part")
		ropePart.Name = "TugRope"
		ropePart.Shape = Enum.PartType.Cylinder
		ropePart.Material = Enum.Material.Fabric
		ropePart.Color = Color3.fromRGB(205, 150, 80)
		ropePart.Anchored = true
		ropePart.CanCollide = false
		ropePart.CastShadow = false
		ropePart.Parent = workspace
		ensureRopeVisuals()
	end
	return ropePart
end

local function updateRope(rope, blueMaxSlot, redMaxSlot, blueFrontName, redFrontName, wobbleTeam)
	ensureRopePart()

	local blueModel = blueFrontName and spawnedModels[blueFrontName]
	local redModel = redFrontName and spawnedModels[redFrontName]

	local blueHeight = getRopeAttachHeight(blueModel)
	local redHeight = getRopeAttachHeight(redModel)

	local ropeHeight
	if blueHeight and redHeight then
		ropeHeight = (blueHeight + redHeight) / 2
	elseif blueHeight or redHeight then
		ropeHeight = blueHeight or redHeight
	else
		ropeHeight = BLUE_START.Y + 3
	end

	local blueXZ = getPositionInLine("blue", math.max(blueMaxSlot, 1), rope)
	local redXZ = getPositionInLine("red", math.max(redMaxSlot, 1), rope)

	local posA = Vector3.new(blueXZ.X, ropeHeight, blueXZ.Z)
	local posB = Vector3.new(redXZ.X, ropeHeight, redXZ.Z)

	local distance = (posA - posB).Magnitude
	local midpoint = (posA + posB) / 2

	targetRopeCFrame = CFrame.new(midpoint, posB) * CFrame.Angles(0, math.rad(90), 0)
	targetRopeDistance = distance + ROPE_END_PADDING

	if currentRopeCFrame == nil then
		currentRopeCFrame = targetRopeCFrame   -- first update ever: snap, nothing to blend from
		currentRopeDistance = targetRopeDistance
	end

	if wobbleTeam then
		GiftEffects.ropeWobble(ropePart, targetRopeCFrame, wobbleTeam == "blue" and 1 or -1)
	end


end

local function updateRopeStrandColors(heatAlpha)
	if not ropeVisuals then return end
	local strandsFolder = ropeVisuals:FindFirstChild("BraidedStrands")
	if not strandsFolder then return end

	for strandIndex = 1, 3 do
		local baseColor = ROPE_NORMAL_COLORS[strandIndex]
		local color = baseColor:Lerp(ROPE_HOT_COLOR, heatAlpha)
		for segmentIndex = 1, ROPE_SEGMENT_COUNT do
			local segment = strandsFolder:FindFirstChild("Strand_" .. strandIndex .. "_" .. segmentIndex)
			if segment then
				segment.Color = color
			end
		end
	end
end

local function updateTeamCounterText(teamName, count, rope)
	local partName = teamName .. "CounterPart"
	local part = workspace:FindFirstChild(partName)

	if not part then
		part = Instance.new("Part")
		part.Name = partName
		part.Size = Vector3.new(2, 2, 2)
		part.Transparency = 1
		part.CanCollide = false
		part.Anchored = true
		part.Parent = workspace
	end

	local team = (teamName == "Blue") and "blue" or "red"
	local pos = getPositionInLine(team, MAX_VISIBLE_PER_TEAM + 1, rope)

	local sideSign = (team == "blue") and 1 or -1
	part.Position = pos + Vector3.new(sideSign * -35, 15, 0)

	local bb = part:FindFirstChild("OverflowGui")
	if not bb then
		bb = Instance.new("BillboardGui")
		bb.Name = "OverflowGui"
		bb.Size = UDim2.new(0, 200, 0, 50)
		bb.AlwaysOnTop = true

		local label = Instance.new("TextLabel")
		label.Name = "TextLabel"
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.Parent = bb
		bb.Parent = part
	end

	local label = bb.TextLabel
	if count > 0 then
		label.Text = "+" .. tostring(count) .. " more..."
		label.TextColor3 = (teamName == "Blue") and Color3.fromRGB(50, 150, 255) or Color3.fromRGB(255, 50, 50)
	else
		label.Text = ""
	end
end

-- Resizing via the Body*Scale NumberValues is NOT synchronous: the Humanoid
-- resizes parts and recomputes joint offsets over the following frames.
-- Poll on Heartbeat until the torso size stops changing so every position
-- read afterwards (grounding, rope height) reflects the FINAL rig geometry.
local function waitForRigToSettle(model, timeout)
	local torso = model:FindFirstChild("UpperTorso")
	if not torso then
		RunService.Heartbeat:Wait()
		return
	end

	local lastSize = torso.Size
	local stableFrames = 0
	local deadline = os.clock() + (timeout or 3)

	while stableFrames < 2 and os.clock() < deadline do
		RunService.Heartbeat:Wait()
		if torso.Size == lastSize then
			stableFrames += 1
		else
			stableFrames = 0
			lastSize = torso.Size
		end
	end
end

local function setModelScale(model, coins)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local scale = 1.0 + (coins * 0.15)
	scale = math.min(scale, 1.2)

	local bodyHeight = humanoid:FindFirstChild("BodyHeightScale")
	if bodyHeight then
		local changed = (bodyHeight.Value ~= scale)
		bodyHeight.Value = scale
		local bodyWidth = humanoid:FindFirstChild("BodyWidthScale")
		local bodyDepth = humanoid:FindFirstChild("BodyDepthScale")
		local headScale = humanoid:FindFirstChild("HeadScale")
		if bodyWidth then bodyWidth.Value = scale end
		if bodyDepth then bodyDepth.Value = scale end
		if headScale then headScale.Value = scale end

		if changed then
			task.spawn(function()
				waitForRigToSettle(model)
			end)
		end
	end
end

local function updateCrown(topPlayersList)
	if not topPlayersList or #topPlayersList == 0 then
		if currentCrown then
			currentCrown:Destroy()
			currentCrown = nil
			crownOwner = nil
		end
		return
	end

	local topGifterData = topPlayersList[1]
	if not topGifterData then return end

	local topGifterName = topGifterData[1]
	local topGifterCoins = topGifterData[3]

	if not topGifterCoins or topGifterCoins <= 0 then
		if currentCrown then
			currentCrown:Destroy()
			currentCrown = nil
			crownOwner = nil
		end
		return
	end

	-- same owner as last poll: leave the existing crown alone entirely
	if crownOwner == topGifterName and currentCrown and currentCrown.Parent then
		return
	end

	if currentCrown then
		currentCrown:Destroy()
		currentCrown = nil
	end

	local topModel = spawnedModels[topGifterName]
	if topModel and topModel:FindFirstChild("Head") then
		local crownPart = Instance.new("Part")
		crownPart.Name = "GifterCrown"
		crownPart.Size = Vector3.new(1.8, 0.6, 1.8)
		crownPart.Color = Color3.fromRGB(255, 215, 0)
		crownPart.Material = Enum.Material.Neon
		crownPart.CanCollide = false
		crownPart.Anchored = true
		crownPart.Parent = topModel

		currentCrown = crownPart

		local head = topModel.Head
		local targetPos = head.Position + Vector3.new(0, head.Size.Y / 2 + 0.4, 0)
		if crownOwner ~= nil and crownOwner ~= topGifterName then
			GiftEffects.crownExplosion(targetPos)
			GiftEffects.crownDrop(crownPart, targetPos)
		end
		crownOwner = topGifterName
	end
end

local function spawnAvatar(name, team, coins)
	local ok, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(name)
	end)
	if not ok then return nil end

	local ok2, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if not ok2 then return nil end

	local ok3, model = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
	end)
	if not ok3 then return nil end

	model.Parent = workspace
	task.wait(0.1)

	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.Anchored = true
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	local head = model:FindFirstChild("Head")
	if head then
		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.new(0, 60, 0, 20)
		billboard.StudsOffset = Vector3.new(0, 3, 0)
		billboard.MaxDistance = 90   -- stops rendering once the camera is this far away
		billboard.Parent = head

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = name
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextScaled = true
		label.Parent = billboard
	end

	return model
end

local function updatePlayers(playerList, team, rope)
	local spawnsThisTick = 0
	local totalInRoster = #playerList

	local overflowCount = math.max(0, totalInRoster - MAX_VISIBLE_PER_TEAM)
	if team == "blue" then
		updateTeamCounterText("Blue", overflowCount, rope)
	elseif team == "red" then
		updateTeamCounterText("Red", overflowCount, rope)
	end

	local frontName = nil
	local lastGiftTeam = nil
	local maxSlotThisTeam = 0

	for _, playerData in ipairs(playerList) do
		local name = playerData[1]
		local coins = playerData[3]

		local alreadyHasSlot = assignedSlot[name] ~= nil
		local roomForNewSlot = nextSlot[team] < MAX_VISIBLE_PER_TEAM

		if alreadyHasSlot or roomForNewSlot then
			local slot = getOrAssignSlot(name, team)
			if slot then
				maxSlotThisTeam = math.max(maxSlotThisTeam, slot)
				local pos = getPositionInLine(team, slot, rope)

				if not spawnedModels[name] then
					if spawnsThisTick < MAX_SPAWNS_PER_TICK then
						local model = spawnAvatar(name, team, coins)
						if model then
							spawnedModels[name] = model
							spawnsThisTick += 1
							task.wait(0.1)
						end
					end
				end

				local model = spawnedModels[name]

				local prev = prevCoins[name]
				if prev == nil then
					prevCoins[name] = coins
				elseif coins > prev and model then
					local delta = coins - prev
					prevCoins[name] = coins

					local teamModels = {}
					for _, pd in ipairs(playerList) do
						local m = spawnedModels[pd[1]]
						if m then table.insert(teamModels, m) end
					end

					GiftEffects.onGift(model, name, delta, team, teamModels)

					teamGiftCount[team] += 1
					if teamGiftCount[team] % 10 == 0 then
						GiftEffects.teamAura(teamModels, team)
					end

					lastGiftTeam = team
				end

				if model then
					model:SetAttribute("Team", team)
					setModelScale(model, coins)

					local groundOffset = getGroundOffset(model)
					local adjustedPos = pos + Vector3.new(0, groundOffset, 0)
					local facing = getFacingCFrame(team, adjustedPos)

					targetPositions[name] = facing

					if not currentPositions[name] then
						currentPositions[name] = facing
						model:PivotTo(facing)
					end

					GiftEffects.setPullBase(model, model:GetPivot(), team)
					GiftEffects.setPersistentAura(model, coins, team)
					GiftEffects.setPullIntensity(model, coins)
				end

				frontName = name
			end
		end
	end

	return nextSlot[team], frontName, lastGiftTeam, maxSlotThisTeam
end

local function playFallAndDestroy(model)
	task.spawn(function()   -- own thread, so the main loop never waits on it
		-- hand the body over to physics: unanchor everything so the ragdoll
		-- constraints can actually move it
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = false
			end
		end

		RagdollModule.ragdoll(model)

		-- fling the whole ragdoll assembly outward: mostly off the back edge of
		-- the deck, with a sideways pull toward the opponent's half so it reads
		-- as "the rope dragged them off" in the direction they were losing
		local team = model:GetAttribute("Team")
		local sideways = (team == "red") and 1 or -1   -- blue stands at +X, red at -X
		local flingDir = Vector3.new(sideways * 0.45, 0, -1).Unit
		local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso") or model:FindFirstChild("HumanoidRootPart")
		if torso then
			torso.AssemblyLinearVelocity = (flingDir * FALL_FLING_SPEED) + Vector3.new(0, FALL_FLING_UP, 0)
		end

		-- leave the body sprawled on the ground for a moment, then clean up
		task.delay(FALL_CLEANUP_DELAY, function()
			if model.Parent then model:Destroy() end
		end)
	end)
end

-- Fall several players one at a time instead of all in the same frame: the
-- front player (gripping the rope, closest to the middle) goes first, then the
-- next one FALL_STAGGER seconds later, like the rope yanks them off in a
-- domino sequence. Waiting players keep tugging until their turn comes.
local function fallModelsInSequence(models)
	if #models == 0 then return end
	table.sort(models, function(a, b)
		return math.abs(a:GetPivot().Position.X) < math.abs(b:GetPivot().Position.X)
	end)
	task.spawn(function()
		for i, model in ipairs(models) do
			if model.Parent then
				GiftEffects.stopPulling(model)
				playFallAndDestroy(model)
			end
			if i < #models then
				task.wait(FALL_STAGGER)
			end
		end
	end)
end


local function removeMissingPlayers(currentNames, eliminatedSet)
	local toFall = {}

	for name, model in pairs(spawnedModels) do
		if not currentNames[name] then
			GiftEffects.clearAura(model)
			spawnedModels[name] = nil   -- stops the main loop from repositioning it mid-fall
			prevCoins[name] = nil
			if eliminatedSet[name] then
				table.insert(toFall, model)
			else
				GiftEffects.stopPulling(model)
				model:Destroy()   -- round reset: no fall
			end
		end
	end

	-- the gift server can eliminate several players in one update when the
	-- rope blows past multiple thresholds at once; stagger the falls so it
	-- reads as a sequence instead of the whole team dropping dead
	fallModelsInSequence(toFall)
end

RunService.Heartbeat:Connect(function(dt)
	local alpha = 1 - math.exp(-ROPE_SMOOTH_SPEED * dt)
	for name, target in pairs(targetPositions) do
		local model = spawnedModels[name]
		if model then
			currentPositions[name] = currentPositions[name]:Lerp(target, alpha)
			-- Move only the HumanoidRootPart so animation-driven Motor6D transforms
			-- on the limbs are preserved (PivotTo on the whole model overrides them).
			local hrp = model:FindFirstChild("HumanoidRootPart")
			if hrp then
				hrp.CFrame = currentPositions[name]
			else
				model:PivotTo(currentPositions[name])
			end
		end
	end
end)

RunService.Heartbeat:Connect(function(dt)
	if not targetRopeCFrame then return end

	local alpha = 1 - math.exp(-ROPE_SMOOTH_SPEED * dt)
	currentRopeCFrame = currentRopeCFrame:Lerp(targetRopeCFrame, alpha)
	currentRopeDistance = currentRopeDistance + (targetRopeDistance - currentRopeDistance) * alpha

	local heatAlpha = overtimeAlpha
	local shakeOffset = Vector3.new(0, 0, 0)
	if heatAlpha > 0.01 then
		shakeOffset = Vector3.new(
			(math.random() - 0.5) * ROPE_SHAKE_MAX * heatAlpha,
			(math.random() - 0.5) * ROPE_SHAKE_MAX * heatAlpha,
			0
		)
	end
	local shakenCFrame = currentRopeCFrame + shakeOffset

	ropePart.Size = Vector3.new(currentRopeDistance, ROPE_CORE_DIAMETER, ROPE_CORE_DIAMETER)
	ropePart.Color = ROPE_CORE_NORMAL_COLOR:Lerp(ROPE_CORE_HOT_COLOR, heatAlpha)
	ropePart.CFrame = shakenCFrame
	updateRopeVisuals(shakenCFrame, currentRopeDistance)

	updateRopeStrandColors(heatAlpha)
end)

-- ============================================================
-- BIGGEST GIFTER COSMIC ENTITY (background spectacle)
-- ============================================================
local COSMIC_SCALE = 20.0
local COSMIC_POSITION = Vector3.new(0, 50, -99)

local cosmicEntityModel = nil
local cosmicEntityOwner = nil   -- name of whoever currently holds this spot
local cosmicBobPhase = 0
local cosmicAnimTrack = nil   -- dancing animation track for the cosmic entity

local function spawnCosmicEntity(name)
	local ok, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(name)
	end)
	if not ok then warn("COSMIC: failed to find user", name, userId) return nil end

	local ok2, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if not ok2 then warn("COSMIC: failed to get description for", name, description) return nil end

	description.HeightScale = COSMIC_SCALE
	description.WidthScale = COSMIC_SCALE
	description.DepthScale = COSMIC_SCALE
	description.HeadScale = COSMIC_SCALE

	local ok3, model = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
	end)
	if not ok3 then warn("COSMIC: failed to build model for", name, model) return nil end

	model.Parent = workspace
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	task.wait(0.1)

	-- Only anchor the HumanoidRootPart so Motor6D joints can still animate the limbs.
	-- If ALL parts are anchored, PivotTo overrides animation-driven transforms every frame.
	local hrp = model:FindFirstChild("HumanoidRootPart")
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.Anchored = (part == hrp)
		end
	end

	model:PivotTo(CFrame.new(COSMIC_POSITION))

	-- Play the dancing animation on loop for the cosmic entity
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end

		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://112252982739673"

		local success, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)

		if success and track then
			track.Looped = true
			track.Priority = Enum.AnimationPriority.Action
			track:Play()
			cosmicAnimTrack = track
		else
			warn("COSMIC: failed to load dance animation", track)
		end
	end

	local head = model:FindFirstChild("Head")
	if head then
		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.new(0, 300, 0, 100)
		billboard.StudsOffset = Vector3.new(0, 70, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = head

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 3, 0)
		label.BackgroundTransparency = 1
		label.Text = name .. ""
		label.TextColor3 = Color3.fromRGB(255, 215, 0)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.Parent = billboard
	end

	return model
end

local function updateCosmicEntity(biggestGifterData)
	if not biggestGifterData then
		if cosmicEntityModel then
			cosmicEntityModel:Destroy()
			cosmicEntityModel = nil
			cosmicEntityOwner = nil
			cosmicAnimTrack = nil
		end
		return
	end

	local name = biggestGifterData[1]
	if name == cosmicEntityOwner then
		return
	end

	if cosmicEntityModel then
		cosmicEntityModel:Destroy()
		cosmicEntityModel = nil
		cosmicAnimTrack = nil
	end

	cosmicEntityModel = spawnCosmicEntity(name)
	cosmicEntityOwner = name
end
local COSMIC_BASE_ROTATION = CFrame.Angles(0, math.rad(180), 0)

local function createTeamLabel(teamName, basePosition, color, sideSign)
	local part = Instance.new("Part")
	part.Name = teamName .. "TeamLabel"
	part.Size = Vector3.new(1, 1, 1)
	part.Transparency = 1
	part.CanCollide = false
	part.Anchored = true
	part.Position = basePosition + Vector3.new(sideSign * 10, 25, 0)
	part.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 180, 0, 50)
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = teamName
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextStrokeTransparency = 0
	label.Parent = billboard
end

createTeamLabel("BLUE TEAM", BLUE_START, Color3.fromRGB(50, 150, 255), 1)
createTeamLabel("RED TEAM", RED_START, Color3.fromRGB(255, 50, 50), -1)


RunService.Heartbeat:Connect(function(dt)
	if not cosmicEntityModel then return end

	cosmicBobPhase = cosmicBobPhase + dt

	local bobHeight = math.sin(cosmicBobPhase * 1.5) * 3
	local swayAngle = math.sin(cosmicBobPhase * 2) * math.rad(8)

	local basePos = COSMIC_POSITION + Vector3.new(0, bobHeight, 0)
	local sway = CFrame.Angles(0, 0, swayAngle)

	-- Move only the HumanoidRootPart so animation-driven Motor6D transforms on
	-- the limbs are preserved (PivotTo on the whole model would override them).
	local hrp = cosmicEntityModel:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.CFrame = CFrame.new(basePos) * COSMIC_BASE_ROTATION * sway
	else
		cosmicEntityModel:PivotTo(CFrame.new(basePos) * COSMIC_BASE_ROTATION * sway)
	end
end)

local winnerBannerPart = nil

local function ensureWinnerBanner()
	if winnerBannerPart then return winnerBannerPart end

	winnerBannerPart = Instance.new("Part")
	winnerBannerPart.Name = "WinnerBanner"
	winnerBannerPart.Size = Vector3.new(2, 2, 2)
	winnerBannerPart.Transparency = 1
	winnerBannerPart.CanCollide = false
	winnerBannerPart.Anchored = true
	winnerBannerPart.Position = Vector3.new(0, 45, 0)
	winnerBannerPart.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "WinnerBannerGui"
	billboard.Size = UDim2.new(0, 500, 0, 150)
	billboard.AlwaysOnTop = true
	billboard.Parent = winnerBannerPart

	local label = Instance.new("TextLabel")
	label.Name = "WinnerLabel"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.Parent = billboard

	return winnerBannerPart
end

local function updateWinnerBanner(winner)
	local part = ensureWinnerBanner()
	local label = part.WinnerBannerGui.WinnerLabel

	if winner == "blue" then
		label.Text = "BLUE WINS!"
		label.TextColor3 = Color3.fromRGB(50, 150, 255)
	elseif winner == "red" then
		label.Text = "RED WINS!"
		label.TextColor3 = Color3.fromRGB(255, 50, 50)
	elseif winner == "draw" then
		label.Text = "DRAW!"
		label.TextColor3 = Color3.fromRGB(200, 200, 200)
	else
		label.Text = ""
	end
end

local Lighting = game:GetService("Lighting")

-- capture your scene's actual current settings as the "normal" baseline,
-- so we always have something correct to ease back to once overtime ends
local NORMAL_BRIGHTNESS = Lighting.Brightness
local NORMAL_AMBIENT = Lighting.Ambient
local NORMAL_OUTDOOR_AMBIENT = Lighting.OutdoorAmbient
local NORMAL_FOG_END = Lighting.FogEnd
local NORMAL_FOG_COLOR = Lighting.FogColor

-- how intense overtime should feel
local OVERTIME_BRIGHTNESS = math.max(NORMAL_BRIGHTNESS * 0.3, 0.5)
local OVERTIME_AMBIENT = Color3.fromRGB(40, 0, 0)
local OVERTIME_OUTDOOR_AMBIENT = Color3.fromRGB(60, 10, 10)
local OVERTIME_FOG_END = 300
local OVERTIME_FOG_COLOR = Color3.fromRGB(30, 0, 0)



local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local overtimeSky = ReplicatedStorage:WaitForChild("OvertimeSky")
local normalSky = Lighting:FindFirstChildOfClass("Sky")   -- whatever's sitting in Lighting at game start

local skySwapped = false

RunService.Heartbeat:Connect(function()
	if inOvertime and not skySwapped then
		if normalSky then
			normalSky.Parent = ReplicatedStorage
		end
		overtimeSky.Parent = Lighting
		skySwapped = true

	elseif not inOvertime and skySwapped then
		overtimeSky.Parent = ReplicatedStorage
		if normalSky then
			normalSky.Parent = Lighting
		end
		skySwapped = false
	end
end)

RunService.Heartbeat:Connect(function(dt)
	local targetAlpha = inOvertime and 1 or 0
	local lerpSpeed = 1 - math.exp(-ATMOSPHERE_SMOOTH_SPEED * dt)
	overtimeAlpha = overtimeAlpha + (targetAlpha - overtimeAlpha) * lerpSpeed

	Lighting.Brightness = NORMAL_BRIGHTNESS + (OVERTIME_BRIGHTNESS - NORMAL_BRIGHTNESS) * overtimeAlpha
	Lighting.Ambient = NORMAL_AMBIENT:Lerp(OVERTIME_AMBIENT, overtimeAlpha)
	Lighting.OutdoorAmbient = NORMAL_OUTDOOR_AMBIENT:Lerp(OVERTIME_OUTDOOR_AMBIENT, overtimeAlpha)
	Lighting.FogEnd = NORMAL_FOG_END + (OVERTIME_FOG_END - NORMAL_FOG_END) * overtimeAlpha
	Lighting.FogColor = NORMAL_FOG_COLOR:Lerp(OVERTIME_FOG_COLOR, overtimeAlpha)
end)

local SoundService = game:GetService("SoundService")

local calmMusic = Instance.new("Sound")
calmMusic.Name = "CalmMusic"
calmMusic.SoundId = "rbxassetid://102159248773355"   -- 01 Shiawase, normal play
calmMusic.Looped = true
calmMusic.Volume = 0.5
calmMusic.Parent = SoundService
calmMusic:Play()

local intenseMusic = Instance.new("Sound")
intenseMusic.Name = "IntenseMusic"
intenseMusic.SoundId = "rbxassetid://129783230965684"   -- 1004(1), overtime
intenseMusic.Looped = true
intenseMusic.Volume = 0
intenseMusic.Parent = SoundService
intenseMusic:Play()

local wasInOvertime = false


RunService.Heartbeat:Connect(function()
	if inOvertime and not wasInOvertime then
		intenseMusic.TimePosition = 0
	end
	wasInOvertime = inOvertime

	calmMusic.Volume = 0.25 * (1 - overtimeAlpha)
	intenseMusic.Volume = 0.8 * overtimeAlpha
end)

local TweenService = game:GetService("TweenService")   -- add near your other services at the top

local TIMER_WARNING_THRESHOLD = 15
local timerPopupPlaying = false
local wasInOvertimeForTimer = false

local function ensureTimerDisplay()
	local anchor = workspace:FindFirstChild("TimerAnchor")
	if not anchor then
		warn("TIMER: no 'TimerAnchor' Part found in Workspace. Create one and place it where you want the timer to show.")
		return nil
	end

	local billboard = anchor:FindFirstChild("TimerGui")
	if not billboard then
		billboard = Instance.new("BillboardGui")
		billboard.Name = "TimerGui"
		billboard.Size = UDim2.new(0, 250, 0, 80)
		billboard.AlwaysOnTop = true
		billboard.Parent = anchor

		local label = Instance.new("TextLabel")
		label.Name = "TimerLabel"
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = ""
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.Parent = billboard
	end

	return anchor
end

local function playOvertimePopup(billboard)
	if timerPopupPlaying then return end
	timerPopupPlaying = true

	billboard.Size = UDim2.new(0, 500, 0, 160)   -- burst in big
	local tween = TweenService:Create(
		billboard,
		TweenInfo.new(1.2, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Size = UDim2.new(0, 250, 0, 80) }   -- settle to resting size
	)
	tween:Play()
	tween.Completed:Connect(function()
		timerPopupPlaying = false
	end)
end

local function updateTimerDisplay(timeLeft, isOvertime)
	local anchor = ensureTimerDisplay()
	if not anchor then return end

	local billboard = anchor.TimerGui
	local label = billboard.TimerLabel

	if isOvertime and not wasInOvertimeForTimer then
		playOvertimePopup(billboard)
	end
	wasInOvertimeForTimer = isOvertime

	if isOvertime then
		label.Text = "OVERTIME"
		label.TextColor3 = Color3.fromRGB(255, 40, 40)
	else
		local minutes = math.floor(timeLeft / 60)
		local seconds = math.floor(timeLeft % 60)
		label.Text = string.format("%d:%02d", minutes, seconds)

		local urgency = math.clamp(1 - (timeLeft / TIMER_WARNING_THRESHOLD), 0, 1)
		label.TextColor3 = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(255, 40, 40), urgency)
	end
end

RunService.Heartbeat:Connect(function()
	if not currentCrown or not crownOwner then return end
	local model = spawnedModels[crownOwner]
	if not model then return end
	local head = model:FindFirstChild("Head")
	if not head then return end
	currentCrown.Position = head.Position + Vector3.new(0, head.Size.Y / 2 + 0.4, 0)
end)

while true do
	local ok, err = pcall(function()
		local result = HttpService:GetAsync(DATA_ENDPOINT)
		local data = HttpService:JSONDecode(result)
		inOvertime = (data.state.time_left <= 0) and (not data.state.winner)
		local rope = data.state.rope
		local blueList = data.state.highest_gifters_blue
		local redList = data.state.highest_gifters_red
		local topPlayers = data.state.top_players
		local blueVisible, blueFront, blueGift, blueMaxSlot = updatePlayers(blueList, "blue", rope)
		local redVisible, redFront, redGift, redMaxSlot = updatePlayers(redList, "red", rope)

		-- round rollover: the team the rope was dragging toward the edge just
		-- lost. Yank their remaining players off one by one instead of letting
		-- everyone silently vanish when the new round's roster replaces them.
		local roundNum = data.state.round_number
		if lastRoundNumber ~= nil and roundNum ~= lastRoundNumber then
			local loserTeam = nil
			if lastRopeValue > 2 then
				loserTeam = "blue"   -- red was winning, blue gets dragged off
			elseif lastRopeValue < -2 then
				loserTeam = "red"
			end
			if loserTeam then
				for name, model in pairs(spawnedModels) do
					if model:GetAttribute("Team") == loserTeam then
						spawnedModels[name] = nil
						prevCoins[name] = nil
						GiftEffects.clearAura(model)
						GiftEffects.stopPulling(model)
						model:Destroy()
					end
				end
			end
			assignedSlot = {}
			nextSlot = { blue = 0, red = 0 }
		end
		lastRoundNumber = roundNum
		lastRopeValue = rope

		local currentNames = {}
		for _, p in ipairs(blueList) do currentNames[p[1]] = true end
		for _, p in ipairs(redList) do currentNames[p[1]] = true end
		local eliminatedSet = {}
		for _, n in ipairs(data.state.eliminated or {}) do
			eliminatedSet[n] = true
		end
		removeMissingPlayers(currentNames, eliminatedSet)

		local wobbleTeam = blueGift or redGift
		updateRope(rope, blueMaxSlot, redMaxSlot, blueFront, redFront, wobbleTeam)
		updateCrown(topPlayers)
		updateWinnerBanner(data.state.winner)
		updateCosmicEntity(data.state.biggest_gifter)
		updateTimerDisplay(data.state.time_left, inOvertime)

		-- ground glow + confetti when a team takes the lead
		-- (positive rope = red pulling ahead, negative = blue)
		local newLeader = nil
		if rope > 2 then
			newLeader = "red"
		elseif rope < -2 then
			newLeader = "blue"
		end
		if newLeader ~= leadingTeam then
			leadingTeam = newLeader
			if leadingTeam then
				local count = (leadingTeam == "blue") and blueVisible or redVisible
				local startPos = (leadingTeam == "blue") and BLUE_START or RED_START
				local dir = (leadingTeam == "blue") and 1 or -1
				local center = startPos + Vector3.new(dir * math.max(count - 1, 0) * SPACING / 2, 0, 0)
				GiftEffects.setGroundGlow(leadingTeam, center, math.max(count, 1) * SPACING + 4)

				-- confetti cannon from the new leader's front character
				local frontName = (leadingTeam == "blue") and blueFront or redFront
				local frontModel = frontName and spawnedModels[frontName]
				if frontModel then
					GiftEffects.confetti(frontModel)
				end
			else
				GiftEffects.setGroundGlow(nil)
			end
		end

		-- drumroll when the rope gets close to a winning threshold
		if math.abs(rope) >= ROPE_DRUMROLL_THRESHOLD and not drumrollPlayed then
			drumrollPlayed = true
			GiftEffects.drumroll(Vector3.new(0, BLUE_START.Y, 0))
		elseif math.abs(rope) < ROPE_DRUMROLL_THRESHOLD * 0.8 then
			drumrollPlayed = false
		end
	end)

	if not ok then
		print("Error fetching data:", err)
	end

	task.wait(0.5)
end
