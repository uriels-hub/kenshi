# Historique des plantages

Sources : `save.log`, `kenshi_info.log`, le journal Application de Windows (événements 1000/1001, et 1002 pour les gels) et les dumps de `%LOCALAPPDATA%\CrashDumps`. Les dumps ne sont pas publiés.

| # | Session | Mods actifs | « Exit. » dans save.log | Plantage | Module fautif | Code | Offset |
|---|---|---|---|---|---|---|---|
| 1 | 05/10 21:25 → 21:31 | 0 | 21:30:56 | 21:30:56 | `PhysXCore64.dll` 2.8.4.6 | `0xc0000005` (violation d'accès) | `0x2c5460` |
| 2 | 05/10 22:06 → 22:43 | 0 | 22:43:50 | 22:43:50 | `kenshi_x64.exe` | `0xc0000005` | `0xf44ae3` |
| 3 | 06/10 00:30 → 00:36 | 1 075 | 00:36:22 | 00:36:22 | `kenshi_x64.exe` | `0xc0000005` | `0xf44ae3` |
| 4 | 06/10 00:44 → 01:03 | 1 040 | 01:03:52 | 01:03:56 | `ntdll.dll` 10.0.26100.9444 | `0xc0000374` (corruption du tas) | `0x117eb5` |
| 5 | 06/10 01:10 → 01:27 | 1 040 | 01:27:04 | 01:27:50 | `ntdll.dll` | `0xc000041d` (exception dans un callback) | `0x26706` |
| 6 | 06/10 21:10 → 21:31 | 677 (liste de l'auteur) | 21:31:30 | 21:31:31 | `kenshi_x64.exe` | `0xc0000005` | `0xf44ae3` |
| 7 | 06/10 21:44 → 22:01 | 677 + RE_Kenshi (jeu en 1.0.65) | 22:01:32 | non enregistré par Windows | — | `kenshi.log` : « something is corrupt in purecall » | — |
| 8 | 07/10 00:26 → 00:30 | 676 + RE_Kenshi | aucun | gel : fermé par Windows à 00:30:26 | — | sortie `0xcfffffff` (programme figé fermé), événement 1002 « Application Hang » | — |
| 9 | 21/10 19:05 → 19:10 | 676 + RE_Kenshi | aucun | 19:10:10, ≈ 35 s après le chargement d'UR12 | `OgreMain_x64.dll` (thread d'animation) | `0xc0000005` (écriture invalide) | `+0x3413a` |
| 10 | 21/10 19:11 → 19:13 | 676 + RE_Kenshi | aucun | 19:13:59, ≈ 70 s après le rechargement d'UR12 | `msvcr100.dll` (`abort`), appelé par `OgreMain_x64.dll` (thread d'animation) | `0x40000015` (arrêt fatal sur corruption mémoire ; sortie 3) | — |
| 11 | 21/10 19:15 → 21:49, sans moniteur | 676 + RE_Kenshi | 21:49:47 | 21:49:47, en jeu, à l'apparition d'une bête de somme | `OgreMain_x64.dll` (création d'un objet 3D) | `0xc0000005` (lecture à `0xffffffffffffffff`) | `+0x19fded` |
| 12 | 21/10 22:12 → 22:51, sans Vital Sense | 675 + RE_Kenshi | aucun | 22:49:07, en jeu ; puis gel jusqu'à la fermeture par Windows (22:51:03) | `nvwgf2umx.dll` (pilote DirectX 11 NVIDIA 596.08, thread du pilote) | `0xc0000005` (lecture à `0xffffffffffffffff`) | `+0x9978cf` |
| 13 | 21/10 22:54 → 22/10 03:15, sans Vital Sense ni Dust | 674 + RE_Kenshi | 03:15:33 | 03:15:33, en quittant (après la sauvegarde UR26) | `PhysXCore64.dll` (fermeture du programme, `doexit`) | `0xc0000005` | `0x2c5460` |
| 14 | 22/10 20:19 → 20:45, sans Vital Sense ni Dust | 674 + RE_Kenshi | 20:45:34 | 20:45:36, en quittant (après autosave1) | non enregistré (ni événement, ni dump, ni rapport Dust) | sortie `0xc000041d` (exception dans un callback, comme le n° 5) | — |
| 15 | 06/11 23:50 → 07/11 02:17, sans Dust (Vital Sense réactivé) | 675 + RE_Kenshi | aucun | 02:17:47, 4 s après le rechargement d'UR28 en cours de partie | `msvcr100.dll` (`abort`), appelé par `OgreMain_x64.dll` (thread d'animation), pile identique au n° 10 | `0x40000015` (arrêt fatal sur corruption mémoire ; sortie 3) | — |
| 16 | 07/11 02:35 → 02:48, sans Vital Sense ni Dust | 674 + RE_Kenshi | aucun | 02:48:42, 3 s après le rechargement d'UR28 en cours de partie | `msvcr100.dll` (`abort`), appelé par `OgreMain_x64.dll` en déchargeant squelettes et animations (`Skeleton::unloadImpl` → `Animation::~Animation`) | `0x40000015` (arrêt fatal sur corruption mémoire ; sortie 3) | — |
| 17 | 08/11 17:33 → 17:47, sans Dust | 675 + RE_Kenshi | aucun | 17:47:19, gel de la carte NVIDIA réinitialisée par Windows (`nvlddmkm` 153), puis le jeu perd l'accès au GPU (`DXGI_ERROR_DEVICE_REMOVED`, raison `DEVICE_HUNG`) et plante à 17:47:37 | pilote `nvlddmkm` (gel du GPU), puis Ogre/D3D11 | sortie `0xc0000374` (corruption du tas) | — |
| 18 | 08/11 17:56 → 18:39, sans Dust | 675 + RE_Kenshi | 18:39:39 | sortie après la sauvegarde UR29 ; résumé non écrit (moniteur interrompu par le redémarrage de Windows de 19:13) | — | — | — |
| 19 | 08/11 18:43 → 18:58, sans Dust | 675 + RE_Kenshi | 18:58:14 | 18:58:14, en quittant | `PhysXCore64.dll` (fermeture du programme) | `0xc0000005` | `0x2c5460` |
| 20 | 08/11 19:14 → 21:23, sans Dust | 675 + RE_Kenshi | aucun | 21:23:13, 10 s après le rechargement d'UR29 en cours de partie | `msvcr100.dll` (`abort`), appelé par `OgreMain_x64.dll` (thread d'animation), pile identique au n° 10 | `0x40000015` (sortie 3) | — |
| 21 | 08/11 21:30 → 21:39, sans Dust | 675 + RE_Kenshi | aucun | 21:39:05, 8 s après le rechargement d'UR29 en cours de partie | `msvcr100.dll` (`abort`), appelé par `OgreMain_x64.dll` (thread d'animation), pile identique au n° 10 | `0x40000015` (sortie 3) | — |

Sessions 6 et 7 : tests de la liste de l'auteur, sans puis avec RE_Kenshi. Aucun plantage en jeu ; toutes les sauvegardes ont abouti (6 : UR2 manuelle, autosave2 automatique ; 7 : autosave2 chargée, UR2 et UR3 manuelles, autosave0 automatique). Seul reste le plantage en quittant, identique au bug vanilla (session 6 : même offset que les sessions 2 et 3).

Session 8 : un gel, pas un plantage, juste après « Complete All Research » dans les outils de développement. Les journaux du jeu (`kenshi.log`, `RE_Kenshi_log.txt`) s'arrêtent vers 00:29:00, puis la mémoire privée reste figée à 8 279 Mo et le nombre de threads ne bouge plus ; Windows ferme le jeu, qui ne répond plus, à 00:30:26 (événement 1002, rapport `AppHang` sans dump). Impossible de dire s'il était bloqué ou s'il calculait encore, l'activité du processeur n'étant pas mesurée : débloquer toutes les recherches d'un coup est à éviter avec ce pack. Le `summary.json` de cette session a été écrit par le moniteur d'avant l'enregistrement des gels : il indique `crashed: false` et `exit_code: -805306369` (`0xCFFFFFFF`), sans le champ `hung`.

Sessions 9 à 11 : trois plantages en jeu en une soirée, analysés avec cdb (minidumps Dust pour 9 et 10, dump écrit par Kenshi pour 11). Tous ont lieu dans `OgreMain_x64.dll` : 9 et 10 dans le thread d'animation (`Entity::updateAnimation` → `Skeleton::setAnimationState` → `Animation::apply`), 11 dans `SceneManager::createEntity` → `Entity::_initialise`, quand une bête de somme apparaît (`pack_beast.mesh`, modèle du jeu de base), avec les plugins `Sparring` (n° 504) et `Vital_Sense` (n° 12) dans la pile. Le 10 est une corruption de la mémoire du jeu détectée par l'allocateur (`abort`) : une corruption antérieure, causée ailleurs, peut expliquer les trois. Pistes :
- les plugins RE_Kenshi mis à jour par Steam depuis les tests du 07/10 : *Vital Sense* et *Squad Autonomy* le 16/10, *Return to Main Menu* le 12/10 ;
- *Animation Overhaul Mod - Crafting* (n° 82, non mis à jour depuis 2019), dont `AOM_MESH_Remotecontrol.mesh` se chargeait à la seconde des plantages 9 et 10, mais 21 fois sans plantage pendant la session 11 ;
- la RAM libre, tombée à 59 Mo pendant la session 9.

Sessions 12 et 13 : tests par élimination avec `modlist\disabled.cfg` (le journal de RE_Kenshi confirme que les plugins retirés ne sont plus chargés ; seul `DustBoot.dll`, module de préchargement et rapporteur de plantage de Dust, reste chargé).
- Sans *Vital Sense* (session 12) : plantage en jeu après 37 min, cette fois dans le pilote NVIDIA, avec les effets de Dust actifs. Le pilote n'a pas changé depuis les tests du 07/10. *Vital Sense* n'est donc pas (seul) en cause.
- Sans *Vital Sense* ni *Dust* (session 13) : **4 h 20 sans plantage en jeu**, contre un plantage toutes les une à deux heures auparavant. Seul le plantage connu en quittant (PhysX, même décalage que le n° 1, avant tout mod) a eu lieu, après la sauvegarde UR26.

- Sans *Vital Sense* ni *Dust* (session 14) : 26 min sans plantage en jeu, puis un plantage en quittant, après la sauvegarde automatique. Au total, environ 4 h 45 de jeu sans plantage en jeu sans *Dust*.

- *Vital Sense* réactivé, *Dust* toujours désactivé (session 15) : 2 h 27 de jeu, puis le plantage d'animation d'Ogre est revenu, pile identique au n° 10, 4 s après le rechargement d'une sauvegarde en cours de partie (12,3 Go de mémoire privée, 262 Mo de RAM libre).

Bilan : les quatre plantages du moteur Ogre (9, 10, 11, 15) ont eu lieu avec *Vital Sense* actif, présent dans la pile du n° 11 ; le seul plantage sans lui (12) était dans le pilote NVIDIA, avec *Dust* actif ; les seules longues parties sans plantage (13, 14) avaient les deux désactivés. Hypothèse la plus cohérente, encore à confirmer sur la durée : *Vital Sense* (n° 12) pour les plantages d'Ogre, *Dust* (n° 23) pour celui du pilote. Les deux restent désactivés. Après le plantage 15, le processus du jeu est resté bloqué en fin de fermeture (1 thread, 10,6 Go encore alloués, impossible à arrêter) : redémarrage du PC nécessaire. Trois des quatre plantages d'Ogre ont suivi de près le chargement d'une sauvegarde : relancer le jeu plutôt que recharger en cours de partie, surtout après une longue session.

Session 16 : **cette hypothèse ne tient plus**. Avec *Vital Sense* et *Dust* désactivés, le même `abort` est survenu 3 s après le rechargement d'UR28 en cours de partie, comme le n° 15 ; la même sauvegarde s'était chargée sans problème au lancement. La pile montre le moment exact : en déchargeant les squelettes et animations de la partie en cours (`ResourceGroupManager::unloadUnreferencedResourcesInGroup` → `Skeleton::unloadImpl` → `Animation::~Animation`), le jeu trouve la mémoire déjà corrompue. Les plantages d'Ogre viennent donc d'une corruption antérieure de données d'animation, que *Vital Sense* et *Dust* ne suffisent pas à expliquer.

Piste corrigée le 07/11 : à chaque session, `[preprocessSkeleton] Failed to load skeleton file: Hive_Princess.skeleton`. Le mod *Princess of The Hive ver.0.6* (n° 659, `Hive_Princess.mod`, Workshop 2230597382, non mis à jour depuis 2020) indique pour les animations de sa race (« female animation », « male animation ») `.\mods\Hive_Princess\Hive_Princess.skeleton`, un fichier resté sur le disque de son auteur et jamais publié. Son modèle (`Hive_Princess.mesh`) utilise le squelette féminin du jeu de base (`female_skeleton.skeleton`), celui que le jeu de base indique aussi pour ce champ : une copie de ce squelette a d'abord été placée au chemin indiqué (`<jeu>\mods\Hive_Princess\`), sans effet : le jeu cherche le fichier par son seul nom dans les dossiers des mods actifs, et l'erreur est réapparue le 08/11. La copie est désormais dans le dossier Workshop du mod (`workshop\content\233860\2230597382\Hive_Princess.skeleton`), à côté de son modèle. Lien avec les plantages non prouvé : l'erreur doit disparaître de `errors-summary.txt` à partir de la session suivante. Pour annuler : supprimer ce fichier.

Session 17 : un autre type de plantage. À 17:47:19, Windows réinitialise le pilote NVIDIA (`nvlddmkm`, événement 153 : le GPU ne répondait plus dans le délai de 2 s), le premier depuis le 06/10 ; dix secondes plus tard, chaque rendu d'Ogre échoue (`0x887A0005` `DXGI_ERROR_DEVICE_REMOVED`, raison `0x887A0006` `DXGI_ERROR_DEVICE_HUNG`, « Failed to create sampler state ») et le jeu plante sur une corruption du tas. La RAM était saturée : 10,2 Go de mémoire privée en 14 min, **134 Mo de RAM libre** au plus bas, avec VS Code, les pages web de Steam et Claude ouverts (environ 3,5 Go). Le plantage n° 12, dans le pilote NVIDIA, avait lui aussi eu lieu RAM presque pleine. Cause la plus probable : la pagination massive de la RAM ralentit le GPU jusqu'au délai de Windows. Mesures prises : réglages allégés (distance de vue, portée des PNJ et des objets, reflets de l'eau, effet de chaleur), raccourci Bureau pour jouer avec VS Code fermé, mise à jour du pilote NVIDIA 596.08 proposée.

Sessions 18 à 21 (réglages allégés) : aucune réinitialisation du pilote NVIDIA, et l'erreur `Hive_Princess.skeleton` a disparu dès la session 19 : le correctif fonctionne, mais ce squelette n'était pas la cause des plantages. Deux plantages d'animation d'Ogre, identiques aux n° 10, 15 et 16, sont survenus 8 à 10 s après le rechargement d'une sauvegarde en cours de partie. **Bilan : les quatre derniers rechargements en cours de partie (15, 16, 20, 21) ont tous planté dans les 3 à 10 s ; sur la même période, les parties lancées puis quittées normalement n'ont eu que le plantage connu en quittant.** Pour changer de sauvegarde : quitter le jeu et le relancer. Le pilote NVIDIA est resté en 596.08 et la RAM libre est descendue à 171–306 Mo à chaque session.

Le `summary.json` de la session 14 a été écrit le 06/11, au réveil du PC : la veille moderne de Windows a gelé le moniteur caché pendant son attente de 60 s, 20 s après la fermeture du jeu. Les journaux avaient été copiés dès la sortie du jeu ; le résumé ne fait que les relire.

Les `summary.json` des sessions 9 et 10 ont été écrits avant que le moniteur ne reconnaisse un plantage par le rapport Dust ou le code de sortie : ils indiquent `crashed: false`. La session 11 a été archivée à la main (`logs/sessions/2026-10-21_19-15_sans-moniteur`). Aucune sauvegarde perdue : UR13 à UR19 et les sauvegardes automatiques ont abouti ; le plantage 11 a fait perdre environ 6 minutes de jeu.

## Diagnostic (06/10/2026)

Analyse des 5 dumps WER et du minidump écrit par Kenshi (`crashDump1.0.68_x64.zip`) avec WinDbg (cdb), lecture du code de `kenshi_x64.exe` aux adresses en cause, puis vérification de chaque hypothèse par deux relecteurs indépendants qui ont relancé cdb eux-mêmes. « Confirmé » = aucun des deux n'a pu la réfuter.

Deux mécanismes distincts :

**A. Plantage en quittant le jeu (sessions 1, 2, 3) : bug de Kenshi 1.0.68. Confirmé.**
Après la fin de `WinMain`, le runtime C (`msvcr100!doexit`) appelle le destructeur statique d'un objet global du jeu (`kenshi_x64+0x86d650`), qui lit un pointeur nul ou invalide en libérant ses membres : maillages des villes lointaines (sessions 2 et 3, `+0xf44ae3`) ou objet PhysX (session 1, `PhysXCore64+0x2c5460`). Les sessions 2 (0 mod) et 3 (1 075 mods) ont **la même pile de 13 appels** : les mods n'y sont pour rien. Aucun overlay, pilote ou DLL tierce n'apparaît sur les piles. Le plantage survient après les sauvegardes, qui restent intactes ; il n'existe pas de correctif. Le mécanisme exact (ordre de destruction) n'est pas démontré : on sait où ça plante, pas pourquoi.

**B. Plantage en pleine partie, pendant une sauvegarde (session 5, probablement 4) : causé par la liste de 1 040 mods. Confirmé pour la session 5.**
Dans `SaveManager::saveGame`, l'écriture de l'état des villes lit un objet NULL (`kenshi_x64+0x69bd4`) : la table des marchandises d'une ville contient une clé d'objet NULL. Cette table est remplie au démarrage, pour chaque ville, à partir de la liste globale « all trade goods », sans test de NULL : une seule référence cassée fait planter **toute** sauvegarde. Source la plus probable (non reproduite en jeu) : l'objet `123-CBT Faction Furniture.mod`, ajouté à cette liste par Universal Wasteland Expansion puis supprimé par l'extra hors pack 3292696625 « Faction Furniture Reasearch Books Removed (+Hive Gossamer Bundle Removed) ». Avec la liste de l'auteur (677 mods), aucune référence orpheline n'a été trouvée dans cette liste.

Les erreurs que Windows a enregistrées pour les sessions 4 et 5 ne sont que des conséquences du premier plantage, capté par le gestionnaire de Kenshi (fenêtre « Kenshi has crashed », écriture de « Exit. », archive `crashDump1.0.68_x64.zip`) :

- session 4 (`0xc0000374`) : le gestionnaire a supprimé l'objet de journal de sauvegarde sans remettre son pointeur global à zéro ; le runtime C l'a supprimé une seconde fois à la fermeture (double libération) ;
- session 5 (`0xc000041d`) : le gestionnaire a détruit le journal de MyGUI ; la sortie du plein écran à la fermeture de la fenêtre a provoqué un redimensionnement, MyGUI a voulu écrire dans son journal et s'est appelé lui-même jusqu'à épuiser la pile.

Conséquence pour le joueur : en session moddée, aucune sauvegarde n'a jamais abouti (aucune ligne « Saving » dans `save.log`), d'où la perte de toute la progression. Les sauvegardes antérieures (UR1, autosave1, autosave2, faites sans mods) passent une lecture complète de leur structure.

**Autres constats**

- Le lanceur de Kenshi 1.0.68 garde dans `data\__mods.list` les mods qu'il connaît et coche automatiquement les autres, mais il remet sa liste à zéro au-delà de 1 001 noms : avec 1 075 mods installés, il en oublie 1 001 à chaque démarrage et réactive les 364 extras (déduit du code et vérifié sur les fichiers, sans test en jeu). Rester sous 1 000 mods installés règle le problème.
- `data\rebirth.mod` (fichier de base du jeu) a été réécrit par le Forgotten Construction Set le 06/10 à 00:29:44 : les sessions 3 à 5 n'ont pas tourné sur les données d'origine. « Vérifier l'intégrité des fichiers » dans Steam le restaure.
- Mémoire : 125 ms avant le plantage 1, Windows a affiché « Mémoire virtuelle minimale insuffisante » (journal Système, fichier d'échange en train de grossir) ; 44 s plus tôt, il avait signalé `kenshi_x64.exe` comme gros consommateur. Le manque de mémoire virtuelle a donc accompagné au moins ce plantage, sans être établi comme sa cause (voir `pack-analysis.md`).
- Erreurs de contexte corrigées : la session 2 a commencé à 22:06 (et non 22:36) ; les sessions 4 et 5 n'ont pas planté en quittant mais en jeu.

## Ce qui reste à établir

- La cause primaire du plantage de la session 4 (son minidump a été écrasé par celui de la session 5) : les dates des fichiers temporaires évoquent aussi une sauvegarde.
- Que l'extra 3292696625 est bien la source de la référence NULL : test A/B en jeu à faire.
- Que le plantage en quittant ne dépend pas de la machine (une seule machine observée ; il s'est produit à toutes les fermetures normales : sessions 1, 2, 3, 6 et 7).
- Si RE_Kenshi masque seulement le rapport Windows de ce plantage ou modifie son déroulement (session 7 : aucun événement ni dump, mais une erreur « purecall » dans `kenshi.log`).
