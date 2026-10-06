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

Sessions 6 et 7 : tests de la liste de l'auteur, sans puis avec RE_Kenshi. Aucun plantage en jeu ; toutes les sauvegardes ont abouti (6 : UR2 manuelle, autosave2 automatique ; 7 : autosave2 chargée, UR2 et UR3 manuelles, autosave0 automatique). Seul reste le plantage en quittant, identique au bug vanilla (session 6 : même offset que les sessions 2 et 3).

Session 8 : un gel, pas un plantage, juste après « Complete All Research » dans les outils de développement. Les journaux du jeu (`kenshi.log`, `RE_Kenshi_log.txt`) s'arrêtent vers 00:29:00, puis la mémoire privée reste figée à 8 279 Mo et le nombre de threads ne bouge plus ; Windows ferme le jeu, qui ne répond plus, à 00:30:26 (événement 1002, rapport `AppHang` sans dump). Impossible de dire s'il était bloqué ou s'il calculait encore, l'activité du processeur n'étant pas mesurée : débloquer toutes les recherches d'un coup est à éviter avec ce pack. Le `summary.json` de cette session a été écrit par le moniteur d'avant l'enregistrement des gels : il indique `crashed: false` et `exit_code: -805306369` (`0xCFFFFFFF`), sans le champ `hung`.

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
