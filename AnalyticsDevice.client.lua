--[[
	STUDIO STATS — script client (détection de l'appareil)
	À placer dans : StarterPlayer > StarterPlayerScripts  (type : LocalScript)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local VRService = game:GetService("VRService")

local remote = ReplicatedStorage:WaitForChild("AnalyticsDevice", 30)
if not remote then return end

task.wait(2) -- laisse le temps à la caméra de connaître la taille de l'écran

local device = "pc"
if VRService.VREnabled then
	device = "vr"
elseif GuiService:IsTenFootInterface() then
	device = "console"
elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
	local cam = workspace.CurrentCamera
	local size = cam and cam.ViewportSize or Vector2.new(0, 0)
	if math.min(size.X, size.Y) >= 700 then
		device = "tablet"
	else
		device = "mobile"
	end
end

remote:FireServer(device)
