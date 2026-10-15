-- Makes everything tagged "FloatingDecor" (sky rocks, clouds) gently bob up
-- and down so the arena feels alive on stream.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local decor = {} -- [instance] = { base, phase, speed, amp }

local function track(inst)
	local base
	if inst:IsA("Model") then
		base = inst:GetPivot()
	else
		base = inst.CFrame
	end
	decor[inst] = {
		base = base,
		phase = math.random() * math.pi * 2,
		speed = 0.3 + math.random() * 0.4,
		amp = 1.2 + math.random() * 1.2,
	}
end

for _, inst in CollectionService:GetTagged("FloatingDecor") do
	track(inst)
end
CollectionService:GetInstanceAddedSignal("FloatingDecor"):Connect(track)

RunService.Heartbeat:Connect(function()
	local t = os.clock()
	for inst, info in decor do
		if inst.Parent then
			local offset = math.sin(t * info.speed + info.phase) * info.amp
			local cf = info.base * CFrame.new(0, offset, 0)
			if inst:IsA("Model") then
				inst:PivotTo(cf)
			else
				inst.CFrame = cf
			end
		else
			decor[inst] = nil
		end
	end
end)
