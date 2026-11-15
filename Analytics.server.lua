--[[
	ROBLOX LIVE ANALYTICS — script serveur
	À placer dans : ServerScriptService  (type : Script)

	Ce script envoie les statistiques de ton jeu vers ta base Firebase
	toutes les 15 secondes. Ton tableau de bord les lit en temps réel.

	Avant de publier :
	  1. Game Settings > Security > "Allow HTTP Requests" = ON
	  2. Colle ton URL Firebase et ton secret ci-dessous
	     (le site les remplit pour toi dans l'onglet "Connecter mon jeu")

	Événements perso (depuis n'importe quel autre Script serveur) :
	  local Track = game:GetService("ServerStorage"):WaitForChild("TrackAnalytics")
	  Track:Fire("niveau_termine", 1)            -- nom, valeur (optionnel)
	  Track:Fire("pieces_gagnees", 250, player)  -- le joueur est optionnel aussi

	Ce script ne s'exécute que sur le serveur : ton secret n'est jamais
	envoyé aux joueurs.
]]

local CONFIG = {
	FIREBASE_URL = "https://TON-PROJET-default-rtdb.europe-west1.firebasedatabase.app",
	SECRET = "COLLE_TON_SECRET_ICI",
	FLUSH_SECONDS = 15,        -- fréquence d'envoi
	UNIVERSE_SECONDS = 300,    -- fréquence de relevé des visites / favoris / likes
	STUDIO_SENDS_STATS = false, -- false : Studio envoie juste un test de connexion
}

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local LocalizationService = game:GetService("LocalizationService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BASE = string.gsub(CONFIG.FIREBASE_URL, "/+$", "")
local IS_STUDIO = RunService:IsStudio()
local JOB = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false))
local JOB_KEY = string.sub(string.gsub(JOB, "[^%w]", ""), 1, 20)
local SERVER_START = os.time()
local IS_PRIVATE = game.PrivateServerId ~= ""
local NULL = "__NULL__" -- remplacé par null dans le JSON (= suppression)

------------------------------------------------------------------------
-- Petites fonctions utiles
------------------------------------------------------------------------
local function dayKey(t) return os.date("!%Y%m%d", t or os.time()) end
local function hourKey(t) return os.date("!%Y%m%d%H", t or os.time()) end
local function minuteKey(t) return os.date("!%Y%m%d%H%M", t or os.time()) end
local function dayNumber(t) return math.floor((t or os.time()) / 86400) end

local function safeKey(s)
	s = tostring(s or "")
	s = string.gsub(s, "[%.%$#%[%]/]", "_")
	s = string.sub(s, 1, 60)
	if s == "" then s = "_" end
	return s
end

local function request(method, path, body)
	local url = BASE .. "/" .. path .. ".json?auth=" .. CONFIG.SECRET
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = method,
			Headers = { ["Content-Type"] = "application/json" },
			Body = body and (string.gsub(HttpService:JSONEncode(body), '"__NULL__"', "null")) or nil,
		})
	end)
	if not ok then
		warn("[Analytics] Requête impossible : " .. tostring(res))
		return false, nil
	end
	if not res.Success then
		warn("[Analytics] Firebase a répondu " .. tostring(res.StatusCode) .. " : " .. tostring(res.Body))
		return false, nil
	end
	return true, res.Body
end

------------------------------------------------------------------------
-- Studio : simple test de connexion
------------------------------------------------------------------------
if IS_STUDIO and not CONFIG.STUDIO_SENDS_STATS then
	task.spawn(function()
		local ok = request("PUT", "ping", {
			t = { [".sv"] = "timestamp" },
			from = "studio",
			place = game.PlaceId,
			universe = game.GameId,
		})
		if ok then
			print("[Analytics] ✅ Connexion à Firebase OK ! Regarde l'onglet « Connecter mon jeu » du site.")
		else
			warn("[Analytics] ❌ Connexion impossible. Vérifie l'URL, le secret et « Allow HTTP Requests ».")
		end
	end)
	return
end

------------------------------------------------------------------------
-- File d'attente : tout est regroupé et envoyé en une seule requête
------------------------------------------------------------------------
local pendingInc = {}   -- chemin -> nombre à ajouter
local pendingSet = {}   -- chemin -> valeur
local feedCounter = 0

local function inc(path, n)
	pendingInc[path] = (pendingInc[path] or 0) + (n or 1)
end

local function feed(kind, player, extra)
	feedCounter = feedCounter + 1
	local ms = math.floor(DateTime.now().UnixTimestampMillis)
	local key = string.format("%013d_%s_%04d", ms, string.sub(JOB_KEY, 1, 6), feedCounter % 10000)
	pendingSet["f/" .. key] = {
		k = kind,
		n = player and player.Name or nil,
		d = player and player.DisplayName or nil,
		u = player and player.UserId or nil,
		x = extra,
		t = ms,
	}
end

------------------------------------------------------------------------
-- Suivi des joueurs
------------------------------------------------------------------------
local playerStore = DataStoreService:GetDataStore("LiveAnalytics_Players_v1")
local RETENTION_DAYS = { 1, 3, 7, 14, 30 }
local sessions = {}     -- [userId] = { join, device, country, premium, new }
local paidToday = {}    -- [userId] = dayKey

local function sessionBucket(sec)
	local m = sec / 60
	if m < 1 then return "a_lt1" end
	if m < 5 then return "b_1_5" end
	if m < 15 then return "c_5_15" end
	if m < 30 then return "d_15_30" end
	if m < 60 then return "e_30_60" end
	return "f_60p"
end

local function onPlayerAdded(player)
	local now = os.time()
	local today = dayKey(now)
	local s = { join = now, device = "?", country = "??", premium = false, new = false }
	sessions[player.UserId] = s

	inc("d/" .. today .. "/j")

	-- Premium
	if player.MembershipType == Enum.MembershipType.Premium then
		s.premium = true
		inc("d/" .. today .. "/pg")
	end

	-- Pays
	local okC, cc = pcall(function()
		return LocalizationService:GetCountryRegionForPlayerAsync(player)
	end)
	if okC and cc then
		s.country = cc
		inc("d/" .. today .. "/cc/" .. safeKey(cc))
	end

	-- Nouveau joueur / joueur unique du jour / rétention
	local today_n = dayNumber(now)
	local okU, err = pcall(function()
		playerStore:UpdateAsync(tostring(player.UserId), function(data)
			if type(data) ~= "table" or not data.first then
				s.new = true
				inc("d/" .. today .. "/nu")
				inc("d/" .. today .. "/u")
				inc("c/" .. today .. "/n")
				return { first = today_n, last = today_n, ret = {} }
			end
			if data.last ~= today_n then
				inc("d/" .. today .. "/u")
			end
			local diff = today_n - data.first
			data.ret = data.ret or {}
			for _, d in ipairs(RETENTION_DAYS) do
				if diff == d and not data.ret[tostring(d)] then
					data.ret[tostring(d)] = true
					inc("c/" .. dayKey(data.first * 86400) .. "/d" .. d)
				end
			end
			data.last = today_n
			return data
		end)
	end)
	if not okU then warn("[Analytics] DataStore : " .. tostring(err)) end

	feed("join", player, { new = s.new, cc = s.country })
end

local function onPlayerRemoving(player)
	local s = sessions[player.UserId]
	if not s then return end
	sessions[player.UserId] = nil
	local now = os.time()
	local today = dayKey(now)
	local dur = math.max(0, now - s.join)
	inc("d/" .. today .. "/ss")
	inc("d/" .. today .. "/pt", dur)
	inc("d/" .. today .. "/sb/" .. sessionBucket(dur))
	feed("leave", player, { dur = dur })
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, p in ipairs(Players:GetPlayers()) do task.spawn(onPlayerAdded, p) end

------------------------------------------------------------------------
-- Appareil (envoyé une fois par le LocalScript)
------------------------------------------------------------------------
local deviceRemote = ReplicatedStorage:FindFirstChild("AnalyticsDevice")
if not deviceRemote then
	deviceRemote = Instance.new("RemoteEvent")
	deviceRemote.Name = "AnalyticsDevice"
	deviceRemote.Parent = ReplicatedStorage
end
local VALID_DEVICES = { pc = true, mobile = true, tablet = true, console = true, vr = true }
deviceRemote.OnServerEvent:Connect(function(player, device)
	local s = sessions[player.UserId]
	if not s or s.device ~= "?" then return end
	if type(device) ~= "string" or not VALID_DEVICES[device] then return end
	s.device = device
	inc("d/" .. dayKey() .. "/dev/" .. device)
end)

------------------------------------------------------------------------
-- Achats (Robux)
------------------------------------------------------------------------
local productInfoCache = {}
local function getInfo(id, infoType)
	local key = tostring(infoType) .. tostring(id)
	if productInfoCache[key] then return productInfoCache[key] end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(id, infoType)
	end)
	if ok and info then
		productInfoCache[key] = info
		return info
	end
	return nil
end

local function recordPurchase(player, kind, id, infoType)
	local info = getInfo(id, infoType)
	local price = (info and info.PriceInRobux) or 0
	local name = (info and info.Name) or tostring(id)
	local today = dayKey()
	local pkey = kind .. "_" .. tostring(id)
	inc("d/" .. today .. "/rb", price)
	inc("d/" .. today .. "/pu")
	inc("d/" .. today .. "/pr/" .. pkey .. "/r", price)
	inc("d/" .. today .. "/pr/" .. pkey .. "/c")
	pendingSet["names/" .. pkey] = name
	if player and paidToday[player.UserId] ~= today then
		paidToday[player.UserId] = today
		inc("d/" .. today .. "/py")
	end
	feed("buy", player, { item = name, r = price, kind = kind })
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
	if purchased then recordPurchase(player, "pass", passId, Enum.InfoType.GamePass) end
end)

MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
	if purchased then
		recordPurchase(Players:GetPlayerByUserId(userId), "prod", productId, Enum.InfoType.Product)
	end
end)

------------------------------------------------------------------------
-- Événements perso
------------------------------------------------------------------------
local trackEvent = ServerStorage:FindFirstChild("TrackAnalytics")
if not trackEvent then
	trackEvent = Instance.new("BindableEvent")
	trackEvent.Name = "TrackAnalytics"
	trackEvent.Parent = ServerStorage
end
trackEvent.Event:Connect(function(name, value, player)
	if type(name) ~= "string" or name == "" then return end
	local key = safeKey(name)
	local v = tonumber(value) or 1
	local today = dayKey()
	inc("d/" .. today .. "/ev/" .. key .. "/c")
	inc("d/" .. today .. "/ev/" .. key .. "/v", v)
	if typeof(player) == "Instance" and player:IsA("Player") then
		feed("event", player, { e = name, v = v })
	end
end)

------------------------------------------------------------------------
-- Santé du serveur
------------------------------------------------------------------------
local fpsSamples, fpsSum = 0, 0
RunService.Heartbeat:Connect(function(dt)
	if dt > 0 then
		fpsSum = fpsSum + (1 / dt)
		fpsSamples = fpsSamples + 1
	end
end)

local currentHour, hourPeak, hourSum, hourN = nil, 0, 0, 0

local function buildLive()
	local fps = fpsSamples > 0 and math.floor(fpsSum / fpsSamples + 0.5) or 60
	fpsSum, fpsSamples = 0, 0

	local pl, pingSum, pingN = {}, 0, 0
	local now = os.time()
	for _, p in ipairs(Players:GetPlayers()) do
		local s = sessions[p.UserId]
		local okP, ping = pcall(function() return p:GetNetworkPing() end)
		local pingMs = okP and math.floor(ping * 1000 + 0.5) or nil
		if pingMs then pingSum = pingSum + pingMs; pingN = pingN + 1 end
		pl[tostring(p.UserId)] = {
			n = p.Name,
			d = p.DisplayName,
			dev = s and s.device or "?",
			cc = s and s.country or "??",
			pr = s and s.premium or false,
			nw = s and s.new or false,
			j = s and s.join or now,
			pi = pingMs,
		}
	end

	return {
		p = #Players:GetPlayers(),
		max = Players.MaxPlayers,
		fps = fps,
		ping = pingN > 0 and math.floor(pingSum / pingN + 0.5) or 0,
		mem = math.floor(Stats:GetTotalMemoryUsageMb() + 0.5),
		ver = game.PlaceVersion,
		up = SERVER_START,
		priv = IS_PRIVATE,
		pl = pl,
		t = { [".sv"] = "timestamp" },
	}
end

------------------------------------------------------------------------
-- Envoi groupé
------------------------------------------------------------------------
local function flush(closing)
	local body = {}
	local now = os.time()
	local count = #Players:GetPlayers()

	if closing then
		body["live/" .. JOB_KEY] = NULL
	else
		body["live/" .. JOB_KEY] = buildLive()
		body["m/" .. minuteKey(now) .. "/" .. JOB_KEY] = count

		local hk = hourKey(now)
		if hk ~= currentHour then
			currentHour, hourPeak, hourSum, hourN = hk, 0, 0, 0
		end
		hourPeak = math.max(hourPeak, count)
		hourSum = hourSum + count
		hourN = hourN + 1
		body["h/" .. hk .. "/" .. JOB_KEY] = { pk = hourPeak, s = hourSum, n = hourN, fs = CONFIG.FLUSH_SECONDS }
	end

	local sentInc, sentSet = pendingInc, pendingSet
	pendingInc, pendingSet = {}, {}
	for path, n in pairs(sentInc) do
		body[path] = { [".sv"] = { increment = n } }
	end
	for path, v in pairs(sentSet) do
		body[path] = v
	end

	local ok = request("PATCH", "", body)
	if not ok then
		-- on remet en file pour le prochain envoi
		for path, n in pairs(sentInc) do inc(path, n) end
		for path, v in pairs(sentSet) do
			if pendingSet[path] == nil then pendingSet[path] = v end
		end
	end
	return ok
end

------------------------------------------------------------------------
-- Statistiques publiques du jeu (visites, favoris, likes)
------------------------------------------------------------------------
local function fetchUniverse()
	local uid = game.GameId
	if uid == 0 then return end
	local okA, rawA = pcall(function()
		return HttpService:GetAsync("https://games.roproxy.com/v1/games?universeIds=" .. uid)
	end)
	local okB, rawB = pcall(function()
		return HttpService:GetAsync("https://games.roproxy.com/v1/games/votes?universeIds=" .. uid)
	end)
	if not okA then return end
	local okDA, a = pcall(function() return HttpService:JSONDecode(rawA) end)
	if not okDA or not a.data or not a.data[1] then return end
	local g = a.data[1]
	local up, down = nil, nil
	if okB then
		local okDB, b = pcall(function() return HttpService:JSONDecode(rawB) end)
		if okDB and b.data and b.data[1] then
			up, down = b.data[1].upVotes, b.data[1].downVotes
		end
	end
	pendingSet["uni/now"] = {
		name = g.name, visits = g.visits, playing = g.playing, fav = g.favoritedCount,
		up = up, down = down, maxp = g.maxPlayers, created = g.created, updated = g.updated,
		t = { [".sv"] = "timestamp" },
	}
	pendingSet["uni/h/" .. hourKey()] = { v = g.visits, f = g.favoritedCount, up = up, dn = down }
end

------------------------------------------------------------------------
-- Ménage : supprime les données minute > 3 jours et le fil > 2 jours
------------------------------------------------------------------------
local function cleanup()
	local now = os.time()
	local function shallowKeys(node)
		local ok, res = pcall(function()
			return HttpService:RequestAsync({
				Url = BASE .. "/" .. node .. ".json?shallow=true&auth=" .. CONFIG.SECRET,
				Method = "GET",
			})
		end)
		if not ok or not res.Success then return {} end
		local okD, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
		if not okD or type(data) ~= "table" then return {} end
		return data
	end
	local body, n = {}, 0
	local mLimit = minuteKey(now - 3 * 86400)
	for k in pairs(shallowKeys("m")) do
		if k < mLimit and n < 2000 then body["m/" .. k] = NULL; n = n + 1 end
	end
	local fLimit = string.format("%013d", (now - 2 * 86400) * 1000)
	for k in pairs(shallowKeys("f")) do
		if k < fLimit and n < 4000 then body["f/" .. k] = NULL; n = n + 1 end
	end
	if n > 0 then request("PATCH", "", body) end
end

------------------------------------------------------------------------
-- Boucles
------------------------------------------------------------------------
inc("d/" .. dayKey() .. "/srv")

task.spawn(function()
	task.wait(3)
	fetchUniverse()
	while true do
		flush(false)
		task.wait(CONFIG.FLUSH_SECONDS)
	end
end)

task.spawn(function()
	while true do
		task.wait(CONFIG.UNIVERSE_SECONDS)
		fetchUniverse()
	end
end)

task.spawn(function()
	task.wait(math.random(60, 600))
	if math.random() < 0.25 then cleanup() end
end)

game:BindToClose(function()
	for _, p in ipairs(Players:GetPlayers()) do onPlayerRemoving(p) end
	flush(true)
end)

print("[Analytics] 📊 Statistiques en direct activées (serveur " .. JOB_KEY .. ")")
