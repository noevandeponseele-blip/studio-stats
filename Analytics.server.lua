--[[
	STUDIO STATS — script serveur (v2)
	À placer dans : ServerScriptService  (type : Script)

	Envoie les statistiques de ton jeu vers ta base Firebase toutes les
	15 secondes. Ton tableau de bord Studio Stats les lit en direct.

	Avant de publier :
	  1. Game Settings > Security > "Allow HTTP Requests" = ON
	  2. Le site remplit l'adresse, la clé API et l'email pour toi (page "Connecter mon jeu").
	     Tu ajoutes seulement le mot de passe du compte.

	──────────── Ce que tu peux envoyer toi-même ────────────
	Depuis n'importe quel autre Script serveur :

	local SS = game:GetService("ServerStorage")

	-- Événement simple (nom, valeur optionnelle, joueur optionnel)
	SS:WaitForChild("TrackAnalytics"):Fire("boss_vaincu", 1, player)

	-- Étape d'un entonnoir (joueur, nom de l'entonnoir, numéro d'étape, nom de l'étape)
	SS:WaitForChild("TrackFunnel"):Fire(player, "tutoriel", 1, "Parler au PNJ")
	SS:WaitForChild("TrackFunnel"):Fire(player, "tutoriel", 2, "Premier saut")

	-- Économie (joueur, "source" ou "sink", monnaie, montant, objet / raison)
	SS:WaitForChild("TrackEconomy"):Fire(player, "source", "Pieces", 50, "quete")
	SS:WaitForChild("TrackEconomy"):Fire(player, "sink", "Pieces", 200, "epee")

	Ce script ne s'exécute que sur le serveur : le mot de passe n'est jamais
	envoyé aux joueurs. Attention : les personnes qui ont le droit de modifier
	ton jeu dans Studio peuvent le lire.
]]

local CONFIG = {
	FIREBASE_URL = "https://TON-PROJET-default-rtdb.europe-west1.firebasedatabase.app",
	API_KEY = "COLLE_TA_CLE_API_WEB",     -- Paramètres du projet > Général > Clé API Web
	EMAIL = "COLLE_L_EMAIL_DU_COMPTE",      -- le compte créé dans Authentication
	PASSWORD = "COLLE_LE_MOT_DE_PASSE",     -- reste sur le serveur, jamais envoyé aux joueurs
	FLUSH_SECONDS = 15,         -- fréquence d'envoi
	UNIVERSE_SECONDS = 300,     -- relevé visites / favoris / likes / icône
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

-- Même script pour tous tes jeux : chaque jeu range ses données dans games/<identifiant du jeu>
local ROOT = string.gsub(CONFIG.FIREBASE_URL, "/+$", "")
local GAME_KEY = game.GameId ~= 0 and tostring(game.GameId) or "studio"
local BASE = ROOT .. "/games/" .. GAME_KEY
local USE_AUTH = CONFIG.EMAIL ~= "" and not string.find(CONFIG.EMAIL, "^COLLE_")

------------------------------------------------------------------------
-- Connexion sécurisée (Firebase Authentication) : jeton valable 1 h, renouvelé tout seul
------------------------------------------------------------------------
local idToken, refreshToken, tokenExpires = nil, nil, 0

local function authCall(url, body, contentType)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "POST", Headers = { ["Content-Type"] = contentType }, Body = body })
	end)
	if not ok or not res.Success then
		warn("[Studio Stats] Connexion au compte impossible : " .. tostring(ok and res.Body or res))
		return nil
	end
	local okD, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
	return okD and data or nil
end

local function signIn()
	local data = authCall("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=" .. CONFIG.API_KEY,
		HttpService:JSONEncode({ email = CONFIG.EMAIL, password = CONFIG.PASSWORD, returnSecureToken = true }), "application/json")
	if data and data.idToken then
		idToken, refreshToken = data.idToken, data.refreshToken
		tokenExpires = os.time() + (tonumber(data.expiresIn) or 3600) - 300
		return true
	end
	warn("[Studio Stats] ❌ Email ou mot de passe refusé par Firebase. Vérifie PASSWORD et EMAIL en haut du script (et que le compte existe dans Authentication → Users).")
	return false
end

local function renew()
	local data = authCall("https://securetoken.googleapis.com/v1/token?key=" .. CONFIG.API_KEY,
		"grant_type=refresh_token&refresh_token=" .. HttpService:UrlEncode(refreshToken), "application/x-www-form-urlencoded")
	if data and data.id_token then
		idToken, refreshToken = data.id_token, data.refresh_token
		tokenExpires = os.time() + (tonumber(data.expires_in) or 3600) - 300
		return true
	end
	return false
end

local function authParam()
	if not USE_AUTH then return nil end
	if not idToken or os.time() >= tokenExpires then
		if not (refreshToken and renew()) then signIn() end
	end
	return idToken and ("auth=" .. idToken) or nil
end
local GAME_NAME = "Mon jeu"
local NULL = "__NULL__" -- remplacé par null dans le JSON (= suppression)
local IS_STUDIO = RunService:IsStudio()
local JOB = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false))
local JOB_KEY = string.sub(string.gsub(JOB, "[^%w]", ""), 1, 20)
local SERVER_START = os.time()
local IS_PRIVATE = game.PrivateServerId ~= ""

------------------------------------------------------------------------
-- Outils
------------------------------------------------------------------------
-- Clés de temps en UTC. L'heure contient "_" pour rester une clé texte dans Firebase.
local function dayKey(t) return os.date("!%Y%m%d", t or os.time()) end
local function hourKey(t) return os.date("!%Y%m%d_%H", t or os.time()) end
local function minuteKey(t) return os.date("!%Y%m%d%H%M", t or os.time()) end
local function dayNumber(t) return math.floor((t or os.time()) / 86400) end
local function dayKeyFromNumber(n) return dayKey(n * 86400) end

local function safeKey(s)
	s = tostring(s or "")
	s = string.gsub(s, "[%.%$#%[%]/]", "_")
	s = string.sub(s, 1, 60)
	if s == "" then s = "_" end
	return s
end

local function withAuth(url, extra)
	local a = authParam()
	local q = {}
	if a then table.insert(q, a) end
	if extra then table.insert(q, extra) end
	if #q == 0 then return url end
	return url .. "?" .. table.concat(q, "&")
end

-- path commençant par "/" = depuis la racine de la base (réglages communs à tous tes jeux)
local function request(method, path, body, extra, retried)
	local full = string.sub(path, 1, 1) == "/" and (ROOT .. path) or (BASE .. "/" .. path)
	local url = withAuth(full .. ".json", extra)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = method,
			Headers = { ["Content-Type"] = "application/json" },
			Body = body ~= nil and (string.gsub(HttpService:JSONEncode(body), '"__NULL__"', "null")) or nil,
		})
	end)
	if not ok then
		warn("[Studio Stats] Requête impossible : " .. tostring(res))
		return false, nil
	end
	if not res.Success then
		if (res.StatusCode == 401 or res.StatusCode == 403) and USE_AUTH and not retried then
			idToken = nil -- jeton expiré ou refusé : on se reconnecte une fois
			return request(method, path, body, extra, true)
		end
		warn("[Studio Stats] Firebase a répondu " .. tostring(res.StatusCode) .. " : " .. tostring(res.Body))
		return false, nil
	end
	return true, res.Body
end

------------------------------------------------------------------------
-- Studio : simple test de connexion
------------------------------------------------------------------------
if IS_STUDIO and not CONFIG.STUDIO_SENDS_STATS then
	task.spawn(function()
		local body = { t = { [".sv"] = "timestamp" }, from = "studio", place = game.PlaceId, universe = game.GameId }
		local ok = request("PUT", "ping", body)
		if ok then request("PUT", "/ping", body) end
		if ok then
			print("[Studio Stats] ✅ Connexion à Firebase OK ! Regarde l'onglet « Connecter mon jeu » du site.")
		else
			warn("[Studio Stats] ❌ Connexion impossible. Vérifie l'adresse, la clé API, l'email / mot de passe, les règles et « Allow HTTP Requests ».")
		end
	end)
	-- Les BindableEvents existent quand même, pour que tes scripts ne plantent pas en Studio
	for _, n in ipairs({ "TrackAnalytics", "TrackFunnel", "TrackEconomy" }) do
		if not ServerStorage:FindFirstChild(n) then
			local b = Instance.new("BindableEvent"); b.Name = n; b.Parent = ServerStorage
		end
	end
	return
end

------------------------------------------------------------------------
-- File d'attente : tout est regroupé et envoyé en une seule requête
------------------------------------------------------------------------
local pendingInc = {}   -- chemin -> nombre à ajouter
local pendingSet = {}   -- chemin -> valeur
local feedCounter = 0

local function inc(path, n)
	if n == 0 then return end
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
local playerStore = DataStoreService:GetDataStore("StudioStats_Players_v2")
local RETENTION_DAYS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 30 }
local sessions = {}     -- [userId] = { join, device, country, premium, new, once = {} }
local paidToday = {}    -- [userId] = dayKey

-- once : pour compter un joueur une seule fois par jour (événements, étapes d'entonnoir)
local function firstTimeToday(s, tag)
	local today = dayKey()
	if s.once[tag] == today then return false end
	s.once[tag] = today
	return true
end

local function onPlayerAdded(player)
	local now = os.time()
	local today = dayKey(now)
	local hk = hourKey(now)
	local s = { join = now, device = "?", country = "??", premium = false, new = false, once = {} }
	sessions[player.UserId] = s

	inc("d/" .. today .. "/j")
	inc("hj/" .. hk .. "/j")

	if player.MembershipType == Enum.MembershipType.Premium then
		s.premium = true
		inc("d/" .. today .. "/pg")
	end

	local okC, cc = pcall(function()
		return LocalizationService:GetCountryRegionForPlayerAsync(player)
	end)
	if okC and cc then
		s.country = cc
		inc("d/" .. today .. "/cc/" .. safeKey(cc))
	end

	-- Nouveau / unique du jour / rétention / WAU-MAU glissants
	local D = dayNumber(now)
	local okU, err = pcall(function()
		playerStore:UpdateAsync(tostring(player.UserId), function(data)
			local isNew = type(data) ~= "table" or not data.first
			if isNew then data = { first = D, last = nil, ret = {} } end
			data.ret = data.ret or {}
			local prev = data.last
			if prev ~= D then
				-- premier passage de la journée
				inc("d/" .. today .. "/u")
				-- WAU : le joueur compte pour les jours D..D+6 qui ne le comptaient pas encore
				local fromW = prev and math.max(D, prev + 7) or D
				for d = fromW, D + 6 do inc("d/" .. dayKeyFromNumber(d) .. "/wau") end
				local fromM = prev and math.max(D, prev + 30) or D
				for d = fromM, D + 29 do inc("d/" .. dayKeyFromNumber(d) .. "/mau") end
			end
			if isNew then
				s.new = true
				inc("d/" .. today .. "/nu")
				inc("c/" .. today .. "/n")
				inc("hj/" .. hk .. "/n")
			else
				local diff = D - data.first
				for _, d in ipairs(RETENTION_DAYS) do
					if diff == d and not data.ret[tostring(d)] then
						data.ret[tostring(d)] = true
						inc("c/" .. dayKeyFromNumber(data.first) .. "/d" .. d)
					end
				end
			end
			data.last = D
			return data
		end)
	end)
	if not okU then warn("[Studio Stats] DataStore : " .. tostring(err)) end

	feed("join", player, { new = s.new, cc = s.country })
end

local function onPlayerRemoving(player)
	local s = sessions[player.UserId]
	if not s then return end
	sessions[player.UserId] = nil
	local now = os.time()
	local today = dayKey(now)
	local dur = math.max(0, now - s.join)
	local minute = math.min(60, math.floor(dur / 60))  -- 60 = une heure ou plus
	inc("d/" .. today .. "/ss")
	inc("d/" .. today .. "/pt", dur)
	inc("d/" .. today .. "/am/m" .. minute)              -- toutes les visites
	if s.new then inc("d/" .. today .. "/fm/m" .. minute) end -- premières visites
	local dev = s.device ~= "?" and s.device or "inconnu"
	inc("d/" .. today .. "/dvs/" .. dev .. "/s")
	inc("d/" .. today .. "/dvs/" .. dev .. "/pt", dur)
	local hk = hourKey(now)
	inc("hj/" .. hk .. "/ss")
	inc("hj/" .. hk .. "/pt", dur)
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

local queueSaleNotification -- défini plus bas (notifications)
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
	inc("hj/" .. hourKey() .. "/rb", price)
	pendingSet["names/" .. pkey] = name
	if player and paidToday[player.UserId] ~= today then
		paidToday[player.UserId] = today
		inc("d/" .. today .. "/py")
	end
	feed("buy", player, { item = name, r = price, kind = kind })
	queueSaleNotification(name, price)
end

------------------------------------------------------------------------
-- Notifications de ventes sur ton téléphone (app ntfy) — réglées depuis le site
------------------------------------------------------------------------
local notifyCfg = { on = false }
local notifyQueue = {}

local function loadNotify()
	local ok, raw = request("GET", "/settings/notify", nil) -- réglage commun à tous tes jeux
	if ok and raw and raw ~= "null" then
		local okD, data = pcall(function() return HttpService:JSONDecode(raw) end)
		if okD and type(data) == "table" then notifyCfg = data end
	elseif ok then
		notifyCfg = { on = false }
	end
end

local function money(n, cur)
	local s = string.format("%.2f", n)
	s = string.gsub(s, "%.", ",")
	return cur == "USD" and ("$" .. s) or (s .. " €")
end

queueSaleNotification = function(itemName, price)
	local c = notifyCfg
	if not c or not c.on or type(c.topic) ~= "string" or not string.match(c.topic, "^[%w_%-]+$") then return end
	if #c.topic < 16 or (tonumber(c.min) or 0) > price then return end
	local earned = price * 0.7                                   -- Roblox garde 30 %
	local usd = earned * (tonumber(c.rate) or 0.0038)            -- taux DevEx (USD par Robux gagné)
	local cur = c.cur == "USD" and "USD" or "EUR"
	local amount = cur == "USD" and usd or usd * (tonumber(c.fx) or 0.89)
	table.insert(notifyQueue, {
		topic = c.topic,
		title = "+" .. money(amount, cur) .. " gagnés",
		message = GAME_NAME .. " · " .. itemName .. " · " .. tostring(price) .. " R$ (≈ " .. tostring(math.floor(earned)) .. " R$ pour toi)",
		tags = { "moneybag" },
		priority = 4,
		click = type(c.click) == "string" and string.match(c.click, "^https://") and c.click or nil,
	})
end

task.spawn(function()
	while true do
		local n = table.remove(notifyQueue, 1)
		if n then
			pcall(function()
				HttpService:RequestAsync({ Url = "https://ntfy.sh/", Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode(n) })
			end)
			task.wait(3) -- pas plus d'une notification toutes les 3 secondes
		else
			task.wait(1)
		end
	end
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
	if purchased then recordPurchase(player, "pass", passId, Enum.InfoType.GamePass) end
end)

MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
	if purchased then
		recordPurchase(Players:GetPlayerByUserId(userId), "prod", productId, Enum.InfoType.Product)
	end
end)

------------------------------------------------------------------------
-- Événements perso, entonnoirs, économie
------------------------------------------------------------------------
local function bindable(name)
	local b = ServerStorage:FindFirstChild(name)
	if not b then
		b = Instance.new("BindableEvent")
		b.Name = name
		b.Parent = ServerStorage
	end
	return b
end
local function isPlayer(p) return typeof(p) == "Instance" and p:IsA("Player") end

bindable("TrackAnalytics").Event:Connect(function(name, value, player)
	if type(name) ~= "string" or name == "" then return end
	local key = safeKey(name)
	local v = tonumber(value) or 1
	local today = dayKey()
	inc("d/" .. today .. "/ev/" .. key .. "/c")
	inc("d/" .. today .. "/ev/" .. key .. "/v", v)
	if isPlayer(player) then
		local s = sessions[player.UserId]
		if s and firstTimeToday(s, "ev:" .. key) then inc("d/" .. today .. "/ev/" .. key .. "/u") end
		feed("event", player, { e = name, v = v })
	end
end)

local stepNamesSent = {}
bindable("TrackFunnel").Event:Connect(function(player, funnel, step, stepName)
	if not isPlayer(player) or type(funnel) ~= "string" then return end
	step = tonumber(step)
	if not step then return end
	step = math.floor(step)
	local s = sessions[player.UserId]
	if not s then return end
	local fk = safeKey(funnel)
	local today = dayKey()
	if firstTimeToday(s, "fn:" .. fk .. ":" .. step) then
		inc("d/" .. today .. "/fn/" .. fk .. "/s" .. step)
	end
	local nameKey = fk .. "/s" .. step
	if type(stepName) == "string" and stepNamesSent[nameKey] ~= stepName then
		stepNamesSent[nameKey] = stepName
		pendingSet["fnames/" .. nameKey] = string.sub(stepName, 1, 80)
	end
end)

bindable("TrackEconomy").Event:Connect(function(player, flow, currency, amount, item)
	amount = tonumber(amount)
	if not amount or amount <= 0 then return end
	if flow ~= "source" and flow ~= "sink" then return end
	local today = dayKey()
	local cur = safeKey(currency or "Monnaie")
	local it = safeKey(item or "autre")
	inc("d/" .. today .. "/eco/" .. cur .. "/" .. (flow == "source" and "src" or "snk") .. "/" .. it, amount)
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

local cur = { hour = nil, pk = 0, s = 0, n = 0, fs = 0, ps = 0, mm = 0 }

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
			n = p.Name, d = p.DisplayName,
			dev = s and s.device or "?", cc = s and s.country or "??",
			pr = s and s.premium or false, nw = s and s.new or false,
			j = s and s.join or now, pi = pingMs,
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
		local live = buildLive()
		body["live/" .. JOB_KEY] = live
		body["m/" .. minuteKey(now) .. "/" .. JOB_KEY] = count

		local hk = hourKey(now)
		if hk ~= cur.hour then cur = { hour = hk, pk = 0, s = 0, n = 0, fs = 0, ps = 0, mm = 0 } end
		cur.pk = math.max(cur.pk, count)
		cur.s = cur.s + count
		cur.n = cur.n + 1
		cur.fs = cur.fs + live.fps
		cur.ps = cur.ps + live.ping
		cur.mm = math.max(cur.mm, live.mem)
		body["h/" .. hk .. "/" .. JOB_KEY] = {
			pk = cur.pk, s = cur.s, n = cur.n, fs = CONFIG.FLUSH_SECONDS,
			fps = cur.fs, ping = cur.ps, mem = cur.mm,
		}
	end

	local sentInc, sentSet = pendingInc, pendingSet
	pendingInc, pendingSet = {}, {}
	for path, n in pairs(sentInc) do body[path] = { [".sv"] = { increment = n } } end
	for path, v in pairs(sentSet) do body[path] = v end

	local ok = request("PATCH", "", body)
	if not ok then
		for path, n in pairs(sentInc) do inc(path, n) end
		for path, v in pairs(sentSet) do
			if pendingSet[path] == nil then pendingSet[path] = v end
		end
	end
	return ok
end

------------------------------------------------------------------------
-- Statistiques publiques du jeu + icône
------------------------------------------------------------------------
local function getJson(url)
	local ok, raw = pcall(function() return HttpService:GetAsync(url) end)
	if not ok then return nil end
	local okD, data = pcall(function() return HttpService:JSONDecode(raw) end)
	return okD and data or nil
end

local function fetchUniverse()
	local uid = game.GameId
	if uid == 0 then return end
	local a = getJson("https://games.roproxy.com/v1/games?universeIds=" .. uid)
	if not a or not a.data or not a.data[1] then return end
	local g = a.data[1]
	local b = getJson("https://games.roproxy.com/v1/games/votes?universeIds=" .. uid)
	local up, down = nil, nil
	if b and b.data and b.data[1] then up, down = b.data[1].upVotes, b.data[1].downVotes end
	local ic = getJson("https://thumbnails.roproxy.com/v1/games/icons?universeIds=" .. uid .. "&size=150x150&format=Png&isCircular=false")
	local icon = ic and ic.data and ic.data[1] and ic.data[1].imageUrl or nil
	pendingSet["uni/now"] = {
		name = g.name, visits = g.visits, playing = g.playing, fav = g.favoritedCount,
		up = up, down = down, maxp = g.maxPlayers, created = g.created, updated = g.updated,
		icon = icon, place = game.PlaceId, universe = uid,
		t = { [".sv"] = "timestamp" },
	}
	pendingSet["uni/h/" .. hourKey()] = { v = g.visits, f = g.favoritedCount, up = up, dn = down }
end

------------------------------------------------------------------------
-- Détection des mises à jour (nouvelle version publiée)
------------------------------------------------------------------------
local function registerVersion()
	local key = "upd/v" .. tostring(game.PlaceVersion)
	local ok, raw = request("GET", key, nil)
	if ok and (raw == "null" or raw == nil) then
		request("PUT", key, { v = game.PlaceVersion, t = { [".sv"] = "timestamp" } })
	end
end

------------------------------------------------------------------------
-- Ménage : supprime les données minute > 3 jours et le fil > 2 jours
------------------------------------------------------------------------
local function cleanup()
	local now = os.time()
	local function shallowKeys(node)
		local ok, raw = request("GET", node, nil, "shallow=true")
		if not ok or not raw then return {} end
		local okD, data = pcall(function() return HttpService:JSONDecode(raw) end)
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

-- Fiche du jeu (nom, identifiants) : le site s'en sert pour lister tous tes jeux
task.spawn(function()
	local okI, info = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
	if okI and info and info.Name then GAME_NAME = info.Name end
	pendingSet["meta"] = { name = GAME_NAME, place = game.PlaceId, universe = game.GameId, t = { [".sv"] = "timestamp" } }
end)

task.spawn(function()
	task.wait(3)
	registerVersion()
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
	while true do
		loadNotify() -- relit les réglages de notifications toutes les minutes
		task.wait(60)
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

print("[Studio Stats] 📊 Statistiques en direct activées (serveur " .. JOB_KEY .. ")")
