# Studio Stats

Tableau de bord en temps réel de mon jeu Roblox : joueurs connectés, serveurs, audience, rétention, Robux, appareils, pays, événements perso.

- Site : https://noevandeponseele-blip.github.io/studio-stats/
- Le jeu envoie ses chiffres toutes les 15 s dans une base Firebase (gratuite) ; le site les lit toutes les 5 s.
- Pour connecter le jeu : onglet **Connecter mon jeu** du site.

Fichiers :
- `index.html` : le site (un seul fichier)
- `Analytics.server.lua` : Script à mettre dans ServerScriptService
- `AnalyticsDevice.client.lua` : LocalScript à mettre dans StarterPlayer > StarterPlayerScripts
