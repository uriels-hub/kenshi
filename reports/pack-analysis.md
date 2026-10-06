# Analyse du pack (677 mods) : conflits, mémoire, réglages, GPU

Analyse du 06/10/2026, faite sur les fichiers installés et les journaux des sessions du 05 et 06/10, sans lancer le jeu. Chaque partie a été revérifiée par un agent indépendant ; les points contestés sont signalés. **Le pack seul n'a encore jamais tourné** : les mesures réelles (journaux, mémoire) viennent de la session à 1 040 mods.

## 1. Conflits entre mods

**Méthode.** Un lecteur du format `.mod` (FCS), écrit d'après OpenConstructionSet et plusieurs analyses publiques du format, a lu les 4 fichiers de base et les 676 mods de la collection : 262 348 enregistrements, 198 318 objets distincts. Validation : chaque fichier est lu jusqu'au dernier octet, un balayage brut des chaînes retrouve tous les identifiants, et le lecteur d'OpenConstructionSet, compilé sans modification, donne les mêmes comptes pour 680 fichiers sur 680. Les règles de chargement ont ensuite été reconstituées à partir du code de `kenshi_x64.exe` 1.0.68 : elles reproduisent exactement les 1 346 avertissements « does not exist » de la session à 1 040 mods.

**Résultat : aucun conflit susceptible de faire planter le jeu dans le pack.** 23 157 objets sont modifiés par au moins deux mods, dont 17 604 avec des valeurs différentes : c'est l'essentiel du travail des patchs du pack. Après fusion dans l'ordre de chargement, aucune escouade, ville, faction, biome, paquet d'IA, modèle de personnage ou départ de partie ne pointe vers un objet absent ou supprimé.

Problèmes réels relevés, tous à faible impact :

| Domaine | Constat | Effet |
|---|---|---|
| Dialogues | 4 répliques liées par Kaizo et supprimées par Strategic Ambiguity ; 5 conditions « possède l'objet » de *The Mysterious Wanderer* vers des objets absents | Répliques ou conditions ignorées |
| Monde | *The Mysterious Wanderer* modifie 3 villes issues d'UWE avant qu'UWE ne se charge | Le personnage n'apparaît pas dans ces 3 bars |
| Monde | *Shower in the bar* remplace l'aménagement des bars de *Lively Bars* | Perte de la fonction principale de Lively Bars dans 15 bars |
| Économie | UWE écrase les listes d'achats des PNJ de *Enhanced Shopping Economy* sans patch | Rééquilibrage partiellement annulé |
| Recherche | Unofficial Patches supprime la recherche vanilla « Composite Runners », qu'UWE exige pour les tourelles à harpon | Conditionnel ; contesté par le vérificateur |
| Races | La race jouable *South Hive Scout Drone* n'a ni modèle ni textures | Visible dans l'éditeur de personnage seulement ; aucun PNJ ne l'utilise |
| Races | Les plugins de naissance de Dark Hive et Radiant Hive se chargent avant le pack qui renomme les reines | La naissance des reines Dark Hive ne se déclenche pas (plugins actifs seulement avec RE_Kenshi) |
| Textures | Normal map *.ddss* mal nommée (Dark Hive Prince), textures de *Project Weapon Sharpening* absentes du pack, une texture RXGB illisible (*Wakigawa's Animation Overhaul*) | Visuel uniquement |

Avec la liste de 1 040 mods, en revanche : *Great Frontiers* (hors pack) a un fichier `interiors.level` corrompu, et la référence cassée dans les marchandises des villes fait planter les sauvegardes (voir `crash-history.md`).

**Limites.** 14,6 % des chevauchements n'ont pas été classés à la main (surtout des catégories de bâtiments). La fusion des fichiers de zones et de niveaux (`leveldata`) n'est pas connue. 41 squelettes d'animation se trouvent hors du groupe « Characters » : le guide de KCF annonce un plantage dans ce cas, mais la session à 1 040 mods les a chargés sans erreur.

## 2. Mémoire

- Fichiers du pack : **21,5 Go** sur le disque, contre 11,2 Go pour les données du jeu de base. C'est un majorant : les textures et modèles se chargent à la demande.
- **Signal réel : le plantage 1 coïncide avec un manque de mémoire virtuelle.** Le journal Système de Windows affiche « Mémoire virtuelle minimale insuffisante… Windows augmente la taille du fichier d'échange » 125 ms avant l'erreur de `kenshi_x64.exe` (05/10, 21:30:56). 44 s plus tôt, Windows avait nommé ce processus comme gros consommateur de mémoire. Le fichier d'échange est géré automatiquement (environ 5 Go au départ) et a dû grossir en pleine partie.
- Mods les plus lourds :

| Position | Mod | Taille | Retirable ? |
|---|---|---|---|
| 510 | Universal Wasteland Expansion | 5,7 Go | Non (17 mods en dépendent) |
| 42 | Compressed Textures Project | 1,3 Go | Non : il **réduit** la mémoire (remplace des textures vanilla plus lourdes) |
| 477 | More Variations Of Robotic Limbs | 0,9 Go | Seulement avec le patch #620 |
| 138 | Tribal Hiver Face Paint | 0,8 Go | **Oui** : aucun mod n'en dépend, purement visuel |
| 289 | Forgotten Buildings | 0,8 Go | Non sans ses dépendants |
| 25 | Heightmap Fix (RE_Kenshi) | 0,7 Go | **Oui** : sans effet tant que RE_Kenshi n'est pas installé |

## 3. Réglages proposés (non appliqués)

| Fichier | Réglage | Actuel → proposé | Avis |
|---|---|---|---|
| `settings.cfg` | `texture resolution gimping` (qualité des textures) | 1 (Haute) → 2 (Moyenne) | Effet vérifié dans le code : divise par 4 la mémoire des textures ordinaires. Le besoin n'est pas démontré (aucune erreur de mémoire vidéo dans les journaux), mais c'est le principal levier mémoire. |
| `settings.cfg` | `water reflection` | 2 → 1 | Chaleur et performances, pas stabilité. |
| `kenshi.cfg` | `Full Screen` / `Border` | Yes / Default → No / None | Fenêtre sans bordure, recommandée par les développeurs. Évite le changement de mode d'affichage qui a déclenché le plantage secondaire de la session 5. |
| `kenshi.cfg` | `VSync` / `VSync Interval` | No / 1 → Yes / 4 | **Contesté** : l'intervalle dépend de la fréquence de l'écran (environ 60 FPS à 240 Hz, mais 15 FPS si l'écran passe à 60 Hz). Préférer une limite de FPS dans l'application NVIDIA. |

Hors du jeu : fixer le fichier d'échange (par exemple 16 Go minimum, 24 Go maximum) pour qu'il ne grossisse plus pendant une partie, et fermer les applications lourdes avant de jouer.

## 4. GPU, pilotes, overlays

- Pilote NVIDIA 596.08 (RTX 5060 Laptop, Alienware 16X Aurora) ; le plus récent est le 617.14 (22/09/2026). Aucune réinitialisation GPU (TDR), erreur WHEA ou plantage du pilote n'a été journalisé : rien n'impose de le mettre à jour.
- L'overlay Steam et les modules de capture de l'application NVIDIA étaient chargés dans les 5 plantages, mais n'apparaissent sur aucune pile d'appels. Les désactiver est un test facultatif, un changement à la fois.
- PhysX sur processeur, sortie du plein écran exclusif, mode GPU dédié (MUX) ou affinité processeur (cœurs P du Core Ultra 7 270HX) : pistes à faible probabilité, à ne tester qu'une par une, après les points ci-dessus.
