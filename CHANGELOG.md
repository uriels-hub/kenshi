# Historique des changements

Du plus récent au plus ancien.

## Gels enregistrés par le moniteur

### Ajouté

- `KenshiTools.psm1` : `Get-KenshiHangEvents` lit les événements Windows 1002 « Application Hang » de `kenshi_x64.exe` (PID, date de création du processus, chemin, ID de rapport), avec les mêmes noms de champs que `Get-KenshiCrashEvents`.
- `kenshi-monitor.ps1` : `summary.json` gagne `hung` (gel du processus suivi, ou code de sortie `0xCFFFFFFF` que Windows donne à un programme figé qu'il ferme) et `hang_time` ; les dossiers de rapport `AppHang_kenshi_x64*` sont copiés comme les `AppCrash_kenshi_x64*` (`.gitignore` : `AppHang_*/`). Un gel n'est pas compté comme plantage (`crashed`).
- `tests/monitor-regressions.ps1` : gel du processus suivi, gel d'un autre processus, code `0xCFFFFFFF` sans événement.
- `logs/sessions/` : session lancée par `play-kenshi.ps1` après les corrections de la revue ; `RE_Kenshi\kenshi_x64.exe` suivi directement, 676 mods chargés, gel après « Complete All Research » (`reports/crash-history.md`, session 8).

### Modifié

- Préférence GPU « Hautes performances » ajoutée dans Windows pour `RE_Kenshi\kenshi_x64.exe`, l'exécutable qui fait tourner le jeu avec RE_Kenshi (seul `kenshi_x64.exe` l'avait) ; `health-check.ps1` la signalait.

## Corrections de la revue de code

### Corrigé

- `KenshiTools.psm1` : un verrou sans date de création valide n'est plus accepté comme vivant ; `kenshi-monitor.ps1 -Stop` ne peut plus arrêter un autre PowerShell à partir d'un ancien verrou contenant seulement son PID.
- `update-pack.ps1` : les objets Workshop dont les `.mod` sont seulement en sous-dossier sont exclus de la liste générée, y compris leurs anciennes entrées. Les noms connus d'objets non téléchargés restent conservés.
- `kenshi-monitor.ps1` : copie des journaux à la sortie du processus avant l'attente de relance ; seuls les enfants RE_Kenshi vérifiés prolongent la session. Les événements Windows sont rattachés aux processus suivis, pour ne pas attribuer le plantage d'un nouveau lancement à la session précédente.
- `health-check.ps1` : la préférence GPU correspond au processus réel, ou à l'exécutable RE_Kenshi activé lorsque le jeu est fermé. Un ancien journal et une entrée plugin sans `RE_Kenshi.dll` ne suffisent plus à déclarer RE_Kenshi installé.

### Ajouté

- `Get-KenshiCrashEvents` : champ `ProcessStartTime`, lu dans la date de création Windows du processus fautif, pour distinguer les PID réattribués tout en acceptant les rapports retardés.
- Tests de régression sur dossiers temporaires : anciens verrous et arrêt d'un PowerShell non identifié, GPU et installation RE_Kenshi, mises à jour Steam simulées, redémarrages rapides, relance RE_Kenshi et attribution des plantages.

### Revue contradictoire de ces corrections

10 constats, 5 corrigés ; tests : 90 réussis sous PowerShell 5.1 et 7.

- `Set-KenshiMonitorLock` n'écrit plus de verrou sans date quand WMI ne répond pas (repli sur la date de démarrage du processus) : avec la nouvelle règle, un tel verrou passait pour périmé et un second moniteur pouvait démarrer.
- `kenshi-monitor.ps1` : un événement de plantage sans PID lisible était ignoré, alors qu'il comptait avant ; il est de nouveau retenu s'il tombe dans la fenêtre de la session (jusqu'à 60 s après la fermeture d'un processus suivi). Test ajouté.
- `kenshi-monitor.ps1` : l'attente de 20 s d'un enfant RE_Kenshi n'a plus lieu quand `RE_Kenshi\kenshi_x64.exe` n'existe pas ; paramètre `$Event` (variable automatique de PowerShell) renommé `$CrashEvent` ; liste des processus construite une fois, conditions redondantes retirées.
- Non corrigé : les dumps, archives et rapports WER restent choisis par date, sans borne de fin (un plantage du lancement suivant pendant les 60 s d'attente serait copié dans la session précédente, sans `crashed`) ; une requête WMI de plus au début de chaque session ; chemin de `RE_Kenshi\kenshi_x64.exe` écrit en dur dans deux scripts ; seules les entrées `Plugin=RE_Kenshi` et `Plugin=RE_Kenshi.dll` exactes sont reconnues dans `Plugins_x64.cfg`.

## Visuels du README

### Ajouté

- `screenshots/shem-arrivee.jpg` : deuxième capture (arrivée à Shem, nom de la ville affiché), à côté de la première en haut du README.
- `reports/memoire-sessions.svg` et `reports/memoire-sessions-sombre.svg` : graphique de la mémoire privée du jeu et de la RAM libre pendant les sessions de 21:09, 22:23 et 23:28, tiré de leurs `memory.csv`. Le README, section « Machine », affiche la version claire ou sombre selon le thème de GitHub.
- README, `play-kenshi.ps1` : schéma Mermaid des étapes du lancement (vérification, restauration, moniteur, mémoire, Steam) et des arrêts avec leur code de sortie.

## Capture d'écran et session avec la liste mise à jour

### Ajouté

- `screenshots/shem.jpg` : capture en jeu (début de partie à Shem), affichée en haut du README.
- `logs/sessions/2026-10-06_23-28-58/` : première session avec la liste du pack mise à jour, lancée par `play-kenshi.ps1`. 676 mods chargés, aucun mod hors pack, liste non réécrite par le lanceur ; mêmes erreurs qu'à la session précédente (24). Le jeu s'est arrêté après 3 min sans « Exit. » dans `save.log`, avec le code de sortie 1 et sans plantage enregistré (ni événement Windows, ni dump, ni rapport de RE_Kenshi).

## Un seul parcours du Workshop au lancement

### Corrigé

- `play-kenshi.ps1` parcourait deux fois le dossier Workshop quand la liste devait être restaurée : une fois pour la vérification, une fois dans `restore-modlist.ps1`. L'index des fichiers `.mod` est maintenant construit une fois et passé aux deux. Gain mesuré : environ 0,4 s par lancement, avec le dossier déjà en cache de Windows (non mesuré juste après un redémarrage). Dernier constat de la revue de code des outils.

### Ajouté

- `Test-KenshiModList -ModIndex` et `restore-modlist.ps1 -ModIndex` : index déjà construit par `Get-ModFileIndex`, utilisé tel quel au lieu de parcourir de nouveau le Workshop.
- `tests/run-tests.ps1` : 3 tests (`-ModIndex` du module et de `restore-modlist.ps1`, `play-kenshi.ps1 -DryRun` jusqu'à la restauration simulée, chemin jamais couvert jusqu'ici) ; `Invoke-Tool -RawArguments` pour passer un argument qui n'est pas du texte. 70 réussis sous PowerShell 5.1 et 7.

## Mise à jour du pack

### Modifié

- `modlist/mods.cfg` et `modlist/pack-modlist.csv` suivent la dernière version du fil « Load Order » de l'auteur (`update-pack.ps1 -Apply`) : 676 mods au lieu de 677.
  - Retiré : *Fog Hunters wear gas masks* (3769899307, n° 234). Il reste abonné dans Steam : c'est désormais un mod hors pack.
  - Déplacés : *Strangers N' Freaks - Hive Princesses* (n° 663 → 658), *UWE Hive Queen Birth* (677 → 663), *Dark Hive Queen Birthing* (675 → 664) et *Radiant Primordial Hive Queen Birthing* (676 → 665).
  - Dépendances de *MEGA - Item Integration Patch* (3013917505), mis à jour par son auteur : ajout de `Wandering Swordmen.mod` et `Ally Mongrel.mod` (déjà dans le pack), retrait de `Boop.mod`, `Blood Carrier.mod`, `Porta-Medicrate.mod` et `Aquarium.mod`.
  - Vérifié avec `scan-mods.ps1` : 0 fichier manquant, 0 dépendance manquante ou chargée trop tard, 0 doublon ; références présentes et dans l'ordre.

### Documentation

- README : 676 mods (675 de la collection plus *Beam Thing*), ordre de la collection différent sur 14 mods, 95 dépendances pour *UWE - Items Integration Patch*, nouvelles positions des mods indisponibles sur le Workshop (n° 294 et 297).

## Revue de code des outils

Revue de `tools/` (10 constats, 9 corrigés ; tests : 67 réussis sous PowerShell 5.1 et 7).

### Corrigé

- `kenshi-monitor.ps1` : sans plantage, les champs `crash_*` de `summary.json` valaient `{}` sous PowerShell 5.1 au lieu de `null` ; `exit_code` était toujours `null` faute de handle gardé ouvert sur le processus du jeu (y compris après la relance par RE_Kenshi) ; un `mods.cfg` vide au lancement passait pour absent, si bien qu'une réécriture de la liste par le lanceur n'était pas signalée.
- `play-kenshi.ps1` : un moniteur lancé sans `-Once` qui terminait la session précédente puis se remettait en attente n'était jamais réutilisé (150 s d'attente, puis session non enregistrée).
- `KenshiTools.psm1` : la lecture de `monitor.lock` (partage en lecture seule, une seule tentative) pouvait prendre un verrou en cours de réécriture pour un verrou périmé ; lecture partagée et nouvelles tentatives, écriture retentée.
- `update-pack.ps1 -Apply` : `mods.cfg` était écrit avant la sauvegarde de `pack-modlist.csv` (fichiers incohérents si cette sauvegarde échouait) ; les comparaisons ignoraient la casse (un mod renommé seulement en casse n'était jamais écrit) ; l'ID retenu pour un `.mod` présent dans deux objets Workshop variait d'une exécution à l'autre (le plus petit ID l'emporte désormais).
- `errors-summary.txt` : la liste « Mods du pack non chargés » était coupée sans la ligne « ... et N autres ».

### Non corrigé

- `play-kenshi.ps1` parcourt deux fois le dossier Workshop quand la liste doit être restaurée (une fois pour la vérification, une fois dans `restore-modlist.ps1`) : lenteur seulement. Corrigé depuis (voir plus haut).

## Mémoire

### Ajouté

- `play-kenshi.ps1` affiche avant le lancement la RAM libre, la marge d'allocation de mémoire et les applications gourmandes ouvertes, avec un avertissement sous 6 Go de RAM libre ou 12 Go de marge (information seulement, ne bloque jamais).

### Documentation

- README, « Machine » : fichier d'échange porté à 32–48 Go, services Dell en démarrage manuel, barrettes de RAM installées et possibilité de passer à 2 × 16 Go (première session avec RE_Kenshi : 8,5 Go de mémoire privée en 3 minutes, mémoire allouée du système à 26 Go).

## Tests en jeu et RE_Kenshi

### Ajouté

- `kenshi-monitor.ps1` suit la relance du jeu par RE_Kenshi : si `kenshi_x64.exe` se ferme et réapparaît dans les 20 s, la session continue sur le nouveau processus (`relaunches` dans `summary.json`) ; `RE_Kenshi_log.txt` est copié avec les autres journaux (jamais publié : ajouté au `.gitignore`).
- `summarize-logs.ps1 -SkipWindowsCrashReports` : n'examine ni le journal des événements Windows ni les dumps WER de la machine.
- `logs/sessions/` : résumés des deux premières sessions de test (liste de l'auteur sans puis avec RE_Kenshi).

### Corrigé

- Le test « lanceur resté ouvert 20 min avant Play » échouait dès qu'un vrai plantage de Kenshi récent figurait dans le journal Windows de la machine : les tests de `summarize-logs.ps1` passent maintenant `-SkipWindowsCrashReports`.

### Documentation

- README, « Machine » et « État connu » : résultats des tests en jeu (677 mods chargés, sauvegardes réussies, seul reste le plantage en quittant), contournement du lanceur par `__mods.list` en lecture seule, fausse alerte « mods manquants » du lanceur, RE_Kenshi installé (jeu en 1.0.65), réglages Windows et du jeu.
- `reports/crash-history.md` : sessions 6 et 7.

## Ordre de l'auteur et diagnostic des plantages

### Modifié

- `modlist/mods.cfg` et `modlist/pack-modlist.csv` suivent maintenant l'ordre du fil « Load Order » de l'auteur du pack (son `mods.cfg` officiel) et non plus l'ordre de la collection : 677 mods (les 676 de la collection plus *Beam Thing*, n° 654), 13 mods déplacés. Les 5 mods hors Steam du fil sont exclus. Vérifié avec `scan-mods.ps1` : aucun problème.
- `update-pack.ps1` lit ce fil (`-LoadOrderTopic`, par défaut 3417684283218879155) et range la liste dans son ordre ; il signale les mods ajoutés par l'auteur hors collection, ceux du fil non installés et ceux de la collection absents du fil. Fil illisible : arrêt avec le code 1 plutôt qu'un retour silencieux à l'ordre de la collection.
- `modlist/extras-400.csv` : *Beam Thing* (3168124217) passe de « retirer » à « garder ».
- `reports/pack-analysis.md` : analyse du pack (conflits objet par objet, poids en mémoire, réglages proposés, GPU et overlays).
- README : restaurer la liste ne suffit pas tant que plus de 1 000 mods sont installés (le lanceur recoche les extras à son démarrage).
- `reports/crash-history.md` : diagnostic des 5 plantages (WinDbg, vérifié par deux relecteurs indépendants) ; README, « État connu » mis à jour.

### Corrigé

- `errors-summary.txt` (publié) et le rapport de `summarize-logs.ps1 -OutFile` contenaient le chemin du profil Windows (nom d'utilisateur) : il est remplacé par `%USERPROFILE%`.

## Revue, correctifs et suite de tests

### Ajouté

- `tests/run-tests.ps1` : suite de tests autonome (ni Pester, ni dépendance) du module et de tous les scripts, sur de faux dossiers sous `%TEMP%` supprimés à la fin ; `-Filter`, `-Keep` ; code 0 si tout passe. Documentée dans le README (« Tester les outils »).
- `KenshiTools.psm1` : `Backup-File` (copie `.bak` à nom unique, erreur si la copie échoue) ; `Get-ModFileIndex` distingue les `.mod` en sous-dossier d'un objet Workshop (`NestedPaths`, `IsNestedOnly`), que `Test-KenshiModList` compte comme introuvables (`NestedFiles`) comme le fait déjà `update-pack.ps1` ; `Get-KenshiPaths` renvoie `Detected` et des chemins absolus à la casse réelle du disque.
- `kenshi-monitor.ps1` : `-WaitTimeoutSec` (fin si Kenshi n'apparaît pas), verrou `monitor.lock` (un seul moniteur), `mods.cfg.at-exit`, `mods_loaded`, `mods_at_exit`, `mods_outside_pack` et `mods_list_rewritten` dans `summary.json`, dossier de session à nom unique.
- `health-check.ps1` : `-Workshop` ; `-PackCfg ''` désactive la comparaison comme dans les autres scripts.
- Deuxième revue : `KenshiTools.psm1` : `Open-KenshiLogReader`, `Read-KenshiMonitorLock`, `Set-KenshiMonitorLock` ; `kenshi-monitor.ps1 -Stop` ; phases du moniteur dans `monitor.lock`.

### Corrigé (deuxième revue)

- `Get-KenshiLogSummary` et `summarize-logs.ps1` lisaient `kenshi_info.log` et `kenshi.log` avec `[IO.File]::ReadLines` (partage lecture seule) : pendant une session, ou tant que WER écrit son rapport, le jeu tient ces fichiers ouverts en écriture et la lecture échouait (« being used by another process ») : rapport sans mods ni erreurs, « 0 lignes » et « ne s'est pas fermé proprement ». Nouvelle fonction `Open-KenshiLogReader` (partage lecture/écriture, lecture en flux).
- `monitor.lock` n'était vérifié que par l'existence du PID : après un `Stop-Process` (qui saute le `finally`) ou un arrêt de Windows, un PID réattribué bloquait `kenshi-monitor.ps1` et faisait croire à `play-kenshi.ps1` qu'un moniteur enregistrerait la session, avec un conseil `Stop-Process` visant un processus quelconque. Le verrou contient maintenant `PID;date de création du processus;phase;fin d'attente` (`Set-KenshiMonitorLock`) et n'est vivant que si ce PID est encore un `powershell.exe`/`pwsh.exe` créé à cette date (`Read-KenshiMonitorLock`) ; `kenshi-monitor.ps1 -Stop` arrête le moniteur après cette vérification et supprime le verrou.
- `play-kenshi.ps1` réutilisait tout moniteur vivant, y compris un moniteur `-Once` en train de terminer la session précédente (copie des journaux, 60 s d'attente des rapports) ou au bout de son délai, qui se serait arrêté sans voir la nouvelle session : il ne réutilise qu'un moniteur en phase `waiting` avec au moins 2 min d'attente devant lui, sinon attend qu'il se retire (au plus 150 s) et en démarre un nouveau, ou dit clairement que la session ne sera pas enregistrée.
- `play-kenshi.ps1` : un `-Workshop` différent du Workshop Steam est refusé sans `-DryRun`, comme `-Game` (la liste aurait été vérifiée contre un dossier que le jeu ne lit pas, puis écrite dans le vrai `data\mods.cfg` et le jeu lancé).
- `summarize-logs.ps1` : « Passages différents » était signalé à tort quand le lanceur restait ouvert plus de 15 min avant le clic sur Play (l'écart était mesuré depuis « Kenshi start ») ; il est mesuré depuis « [Launcher] Launching game » (2 min de marge), et le rapport dit lequel des deux passages est le plus récent.
- `kenshi-monitor.ps1` : `mods_list_rewritten` ne comparait que les nombres d'entrées ; les deux listes sont comparées entrée par entrée et dans l'ordre.

### Corrigé

- `Get-ActiveModList` donne une chaîne pour un fichier d'une ligne et rien pour un fichier vide (déroulement normal du pipeline) : `Test-KenshiModList`, `Get-KenshiLogSummary`, `restore-modlist.ps1`, `play-kenshi.ps1` et `health-check.ps1` l'utilisaient sans `@()`, échouaient sur `.Count` et, pour `Test-KenshiModList`, rendaient un résultat `IsClean` sans compteurs que `scan-mods.ps1` et `play-kenshi.ps1` prenaient pour « aucun problème ». Tous les appelants enveloppent maintenant le résultat dans `@()`, et `Test-KenshiModList` lève ses erreurs internes au lieu de continuer. (Renvoyer un tableau non déroulé n'est pas une option : `@()` l'imbriquerait, vérifié sous 5.1 et 7.)
- `Write-ModList` ignorait un échec de la copie `.bak` ou de l'écriture (fichier en lecture seule, dossier inaccessible) et `restore-modlist.ps1` annonçait quand même « restauré » avec le code 0 ; `play-kenshi.ps1` vérifiait ensuite la copie du dépôt et non le fichier écrit. La copie et l'écriture lèvent désormais une erreur, le fichier est relu et comparé, `restore-modlist.ps1` sort avec le code 1, et `play-kenshi.ps1` relit `data\mods.cfg` avant de lancer le jeu. Les chemins relatifs sont résolus sur le dossier courant de PowerShell et non sur celui du processus (idem pour `-OutFile` de `summarize-logs.ps1`, qui sort maintenant avec le code 1 si le rapport n'a pas pu être écrit).
- `play-kenshi.ps1` : refuse un `-Game` différent de l'installation Steam sans `-DryRun` (Steam aurait lancé le vrai jeu avec sa liste non restaurée) ; vérifie la liste du pack avant toute écriture (code 2 sans rien écrire) ; hôte du moniteur choisi d'après l'édition (`$PSHOME`) et non d'après le processus courant (l'ISE n'acceptait pas les options) ; ne démarre pas de second moniteur ; rappelle que le lanceur peut réécrire la liste.
- `kenshi-monitor.ps1` : attendait sans limite si Steam ne lançait pas le jeu ; copie maintenant les journaux dès la sortie du jeu (avant les 60 s d'attente, pendant lesquelles un nouveau lancement les écrasait) ; tous ses fichiers passent par `-LiteralPath` ou .NET (un `[` dans le chemin les faisait échouer en silence) et sont écrits en UTF-8 sans BOM sous les deux hôtes.
- `summarize-logs.ps1` : quand `kenshi_info.log` décrit un passage plus récent que la dernière session de `save.log` (passage arrêté au lanceur), la recherche de plantages commençait après le plantage et l'heure « Exit. » recevait la mauvaise date ; les deux passages sont maintenant distingués. Note si les journaux ont moins d'une minute et demie.
- `restore-modlist.ps1` : refuse une liste source vide et un dossier de jeu sans `data\` (`-Game` mal tapé créait une arborescence) ; la liste des absents est limitée à 15 ; codes de sortie documentés.
- `update-pack.ps1` : la sauvegarde de `pack-modlist.csv` n'était pas vérifiée ; les mods sans titre sont nommés par leur fichier `.mod` ; deux nouvelles tentatives sur une erreur Steam 5xx.
- `Get-KenshiPaths` : un chemin UNC passé à `-Game`/`-Workshop` perdait son `\\` initial (seules les valeurs de `libraryfolders.vdf` sont désormais désechappées) ; les chemins sont affichés avec la casse réelle du disque.
- `Get-KenshiLogSummary` : une liste de pack introuvable donnait une comparaison vide affichée comme propre ; avertissement et comparaison désactivée.
- `health-check.ps1` : conseil Workshop obsolète (« 2 mods retirés ») remplacé ; le conseil « Plantages 24 h » renvoie à `play-kenshi.ps1`.
- `.gitignore` : `crashDump*.zip`, `AppCrash_*/`, `*.wer`, `*.hdmp`, `*.mdmp`, `*.log` et `monitor.lock` exclus partout dans le dépôt, pas seulement sous `logs/sessions/` (deuxième revue : les `.log` et le verrou n'étaient exclus que sous `logs/`, contrairement à ce que disaient les README).
- `README.md` : commande du dernier dossier de session (`-Directory`, la transcription `monitor-*.log` passait devant), codes de sortie, attente d'une minute avant `summarize-logs.ps1`, comment arrêter un moniteur caché. `reports/crash-history.md` : session 2 commencée à 22:06, offset du plantage 1 (`0x2c5460`). `logs/README.md` : moment d'écriture de chaque fichier, contenu de `crash_info`, encodages.

## Refonte des outils (non encore commité)

### Ajouté

- `tools/KenshiTools.psm1` : module commun aux scripts, 10 fonctions (`Get-KenshiPaths`, `Read-ModHeader`, `Get-ModFileIndex`, `Get-ActiveModList`, `Test-KenshiModList`, `Write-ModList`, `Get-KenshiLogSummary`, `Format-KenshiLogSummary`, `Get-KenshiCrashEvents`, `Get-KenshiSessions`), chacune avec son aide en français.
- `tools/health-check.ps1` : bilan de santé en lecture seule (`OK` / `ATTENTION` / `ECHEC` / `MANUEL`, conseil par point, `-Json`) : jeu ouvert, version, liste de mods et dépendances, Workshop, préférence GPU, RE_Kenshi, Smart App Control, mémoire, fichier d'échange, espace disque, plantages des 24 h, cartes graphiques, réglage PhysX à vérifier à la main.
- `tools/play-kenshi.ps1` : lancement en une commande : refus si le jeu tourne, restauration de la liste du pack si elle diffère, vérification de la liste chargée, moniteur `-Once` dans un PowerShell caché (transcription `logs\sessions\monitor-<date>.log`), lancement via `steam://rungameid/233860`. `-DryRun` simule tout sans rien écrire ni lancer.
- `tools/summarize-logs.ps1` : rapport Markdown des journaux actuels (dernière session de `save.log`, mods chargés et écart avec le pack, erreurs et avertissements, journal OGRE, plantages depuis le début de la session, conclusion), avec `-Top` et `-OutFile`.
- `tools/update-pack.ps1` : comparaison de `modlist/` avec la collection Steam via l'API Web publique (ajoutés, retirés, déplacés, modifiés, non téléchargés, indisponibles, sous-collections ignorées) ; `-Apply` réécrit `mods.cfg` et `pack-modlist.csv` dans le dépôt après copie `.bak`.
- `CHANGELOG.md` (ce fichier).

### Modifié

- `tools/scan-mods.ps1` : repose sur le module ; nouveaux contrôles (en-têtes illisibles détaillés, fichiers en double sur le disque, écart avec `modlist\mods.cfg`) ; `-PackCfg` (`''` pour ne pas comparer), `-Json` ; code 1 si la liste est introuvable.
- `tools/restore-modlist.ps1` : vérifie que chaque `.mod` existe avant d'écrire et s'arrête en listant les absents (sauf `-Force`) ; `-WhatIf` (ni copie ni écriture) ; `-Source` et `-Workshop`.
- `tools/kenshi-monitor.ps1` : copie en plus le `crashDump*.zip` écrit par Kenshi et les dossiers de rapport WER `AppCrash_kenshi_x64*` ; `summary.json` gagne `samples`, `crash_module`, `crash_exception_code`, `crash_fault_offset`, `wer_dumps`, `kenshi_crash_zips`, `wer_reports` ; `last_exit_in_save_log` est pris dans la session copiée ; `errors-summary.txt` ajoute les mods du pack non chargés.
- Tous les scripts : détection de Steam, de la bibliothèque et du Workshop par le registre et `libraryfolders.vdf` au lieu de chemins codés en dur ; aide intégrée (`Get-Help`) ; compatibilité Windows PowerShell 5.1 et PowerShell 7 ; fichiers en UTF-8 avec BOM, lectures de texte avec `-Encoding UTF8` explicite.
- `.gitignore` : sous `logs/sessions/`, exclusion de tous les `.dmp`, `crashDump*.zip`, dossiers `AppCrash_*`, fichiers `.wer` et `.log` (y compris les transcriptions du moniteur).
- `README.md` : documentation de chaque outil (paramètres, exemples, ce qu'il ne fait jamais), déroulement recommandé, commandes de vérification, état connu mis à jour. `logs/README.md` : nouveaux fichiers de session et ce qui est publié ou non.

### Corrigé

- Lecture des en-têtes `.mod` : seul l'en-tête est lu (plus tout le fichier), chaque champ est borné par la taille du fichier, et un en-tête tronqué ou d'un type inconnu produit un message clair avec le chemin du fichier.
- Index des fichiers `.mod` : `-Filter *.mod` acceptait aussi `.model` et consorts ; seule l'extension exacte compte désormais. Un même nom présent à plusieurs endroits (`OroborosArmor.mod` dans deux objets Workshop) est maintenant signalé au lieu d'être silencieusement résolu sur le premier trouvé.
- Moniteur : le pic de mémoire privée et le minimum de RAM libre sont calculés sur des nombres (les valeurs lues par `Import-Csv` sont des chaînes) ; les champs du plantage (module, code, offset, PID) sont lus dans les propriétés de l'événement Windows, indépendamment de la langue du système, au lieu d'être extraits du texte anglais du message.
- `save.log` : les heures non complétées par des zéros (`1:3:52`) et le passage de minuit sont pris en compte dans la durée des sessions.
- État connu du README : les IDs 2989338777 et 2912426942 ne sont pas des mods retirés mais des sous-collections liées dans la collection ; les mods réellement indisponibles sur le Workshop sont 1999745738, 3004525738 et 3645025556, tous encore téléchargés localement.

### Vérifié

- Syntaxe de tous les scripts et du module : 0 erreur sous Windows PowerShell 5.1.26100 et PowerShell 7.6.6.
- `scan-mods.ps1 -ModsCfg modlist\mods.cfg` : 676 mods, 0 problème (code 0). La liste active du jeu (1 040 mods) : 364 hors pack, 11 dépendances introuvables, 1 doublon (code 2).
- `update-pack.ps1` : la collection compte 678 éléments, 676 mods et 2 sous-collections ; le pack du dépôt est à jour.
- Chemins d'écriture exercés sur de faux dossiers de jeu sous `%TEMP%` (supprimés ensuite) : `restore-modlist.ps1` (`-WhatIf`, absents, `-Force`, `.bak`), `play-kenshi.ps1 -DryRun` (restauration simulée, blocage sur fichiers absents, `-NoRestore`, `-Force`), `update-pack.ps1 -Apply` sur une copie de `modlist/`, `health-check.ps1` avec version 1.0.65 et faux RE_Kenshi.
- Le jeu, les sauvegardes, le Workshop et `data\mods.cfg` du jeu n'ont pas été modifiés par cette refonte.

### Non fait, à surveiller

- `play-kenshi.ps1` n'a jamais été exécuté sans `-DryRun` : la première exécution réelle (restauration, moniteur caché, lancement Steam) est à observer.
- La boucle de capture du moniteur n'a pas tourné de bout en bout (elle attend un vrai `kenshi_x64.exe`) ; chacune de ses briques a été exercée séparément sur les journaux réels.
- Sous Windows PowerShell 5.1, la transcription `monitor-*.log` est écrite dans la page de code ANSI : les accents y paraissent mal si on l'ouvre en UTF-8 (les fichiers de session eux-mêmes ne sont pas concernés).
- RE_Kenshi n'est pas installé (installateur graphique seulement pour la 1.0.68).

## Première publication

- Liste des 676 mods du pack MEGA Kaizo/UWE+ (`modlist/mods.cfg`, `modlist/pack-modlist.csv`) et verdicts sur les 400 abonnements hors pack (`modlist/extras-400.csv`).
- Premiers scripts : `tools/restore-modlist.ps1`, `tools/scan-mods.ps1`, `tools/kenshi-monitor.ps1`, avec chemins Steam codés en dur.
- Copie de `settings.cfg` et `kenshi.cfg`, plan de tri des mods (`reports/mod-plan.html`), historique des 5 plantages (`reports/crash-history.md`), `.gitignore` excluant dumps, sauvegardes, journaux bruts et `.bak`.
