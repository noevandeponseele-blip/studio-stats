# Studio Stats

Tableau de bord en temps réel de mon jeu Roblox, en thème sombre.

- Site : https://noevandeponseele-blip.github.io/studio-stats/
- Le jeu envoie ses chiffres toutes les 15 s dans une base Firebase (gratuite) ; le site les lit toutes les 5 s.
- Pour connecter le jeu : page **Connecter mon jeu** du site.

Pages : Résumé (parcours du joueur), Maintenant, La première fois, Le retour (cohortes J1–J14, J30), La boucle (DAU/WAU/MAU, heures), Ton public, Entonnoirs, Événements, L'économie, L'argent, Les mises à jour, La machine, Page du jeu.

Fichiers :
- `index.html` : le site (un seul fichier)
- `Analytics.server.lua` : Script à mettre dans ServerScriptService
- `AnalyticsDevice.client.lua` : LocalScript à mettre dans StarterPlayer > StarterPlayerScripts
