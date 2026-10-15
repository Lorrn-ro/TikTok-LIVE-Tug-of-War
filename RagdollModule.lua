local RagdollModule = {}

-- Sockets are built from the motor's own C0/C1 so the ragdoll joints sit
-- exactly where the animated joints were (works for any rig, R6 or R15).
local function buildAttachmentsAndConstraints(motor)
	local a0 = Instance.new("Attachment")
	a0.Name = motor.Name .. "RagdollAttachment0"
	a0.CFrame = motor.C0
	a0.Parent = motor.Part0

	local a1 = Instance.new("Attachment")
	a1.Name = motor.Name .. "RagdollAttachment1"
	a1.CFrame = motor.C1
	a1.Parent = motor.Part1

	local socket = Instance.new("BallSocketConstraint")
	socket.Name = motor.Name .. "RagdollSocket"
	socket.Attachment0 = a0
	socket.Attachment1 = a1
	socket.LimitsEnabled = true
	socket.TwistLimitsEnabled = true
	socket.Parent = motor.Part0
end

function RagdollModule.ragdoll(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	if character:GetAttribute("Ragdolled") then return end
	character:SetAttribute("Ragdolled", true)

	-- stop animations so they don't fight the constraints
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
	end

	-- stop the humanoid from trying to stand back up or turn around
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	-- swap every joint motor for a ball socket, except the root joint which
	-- keeps the HumanoidRootPart glued to the torso ("Root" on R15,
	-- "RootJoint" on R6)
	for _, motor in character:GetDescendants() do
		if motor:IsA("Motor6D") and motor.Name ~= "RootJoint" and motor.Name ~= "Root" then
			motor.Enabled = false
			buildAttachmentsAndConstraints(motor)
		end
	end

	-- let limbs collide with the ground; the root part itself stays
	-- non-collidable so it doesn't drag the body around
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = (part.Name ~= "HumanoidRootPart")
		end
	end
end

function RagdollModule.unragdoll(character)
	for _, thing in character:GetDescendants() do
		if thing:IsA("BallSocketConstraint") then
			thing:Destroy()
		elseif thing:IsA("Attachment") and string.find(thing.Name, "RagdollAttachment", 1, true) then
			thing:Destroy()
		elseif thing:IsA("Motor6D") then
			thing.Enabled = true
		end
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end

	character:SetAttribute("Ragdolled", nil)
end

return RagdollModule
