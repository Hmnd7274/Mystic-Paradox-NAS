OUTILS DE PUBLICATION DU RUNTIME MYSTIC PARADOX

Contenu
- Publish-Runtime.ps1 : génération/vérification des feeds client et server, ajout forcé de tous les artefacts ignorés par Git (*.dll inclus), puis commit/push optionnel.
- Verify-Runtime-NAS.sh : fetch/pull sur le NAS, vérification des manifests et artefacts du dépôt, test des URL HTTP, puis comparaison avec les fichiers installés dans le dossier du jeu. Ne modifie aucun fichier du jeu et ne redémarre aucun service.

INSTALLATION DES SCRIPTS DANS LE REPO (à faire une seule fois)
Depuis la racine du dépôt, placer les deux scripts dans :
  tools/runtime-publishing/Publish-Runtime.ps1
  tools/runtime-publishing/Verify-Runtime-NAS.sh

Puis les versionner une fois :
  git add tools/runtime-publishing/Publish-Runtime.ps1 tools/runtime-publishing/Verify-Runtime-NAS.sh tools/runtime-publishing/README-FR.txt
  git commit -m "Add runtime publishing and NAS verification scripts"
  git push origin main

REPARER LA PUBLICATION 0.1.5 ACTUELLE (Windows PowerShell 5.1)
Depuis la racine du dépôt :
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\runtime-publishing\Publish-Runtime.ps1 -RepoRoot "$PWD" -Version 0.1.5 -Changelist 647472 -SkipGenerate -CommitAndPush

-SkipGenerate réutilise les artefacts déjà produits localement pour 0.1.5. Le script vérifie les hashes et tailles avant de toucher à Git. Il utilise git add -A -f sur les deux dossiers versionnés : cela force l'ajout des DLL malgré la règle *.dll du .gitignore. Il vérifie ensuite que chaque fichier présent est bien suivi par Git. Il ne stage aucun fichier en dehors des feeds runtime.

Si les DLL/extraFiles ne sont plus présents dans les dossiers de sortie Windows, relancer sans -SkipGenerate pour appeler le script Node existant de génération/signature.

POUR LES PROCHAINES VERSIONS
Exemple pour une future version :
  .\tools\runtime-publishing\Publish-Runtime.ps1 -RepoRoot "$PWD" -Version 0.1.6 -Changelist 647472 -CommitAndPush

Le script prend par défaut :
- DLL : ParadoxRuntime\x64\Release\MysticParadox.dll
- winmm.dll : tools\RuntimeLoader\target\release\winmm.dll
- clé : ParadoxLauncher\.secrets\selfhost-runtime-update.private.pem

VERIFICATION SUR LE NAS APRES PUBLICATION
Depuis le NAS :
  chmod +x tools/runtime-publishing/Verify-Runtime-NAS.sh
  ./tools/runtime-publishing/Verify-Runtime-NAS.sh

Le script fait fetch + pull --ff-only origin main, vérifie les artefacts client/server dans le dépôt, télécharge les éléments du feed server via leurs URL pour confirmer qu'ils répondent avec le bon contenu, puis compare MysticParadox.dll et les extraFiles (dont winmm.dll) du dossier installé du jeu avec le manifest server.

Code retour 0 : toutes les vérifications passent.
Code retour 1 : au moins une vérification échoue. Les erreurs distinguent artefacts absents du dépôt, URL HTTP en erreur et DLL installée différente du manifest.

Options NAS :
  --no-pull  : ne fait pas fetch/pull (vérifie l'état local uniquement).
  --no-http  : saute le test des URL HTTP.

Le script NAS est volontairement non destructif : il ne copie pas de DLL, ne modifie pas les permissions, n'arrête pas dauntless et ne redémarre aucun service.
