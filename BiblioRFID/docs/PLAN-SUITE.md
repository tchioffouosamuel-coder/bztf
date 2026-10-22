# Plan d'action — ce qui reste après les huit zones

> État arrêté le 21 octobre 2026, après la livraison des huit zones qui
> restaient en coquille. Ce document dit **ce qui manque encore de la version
> 3.0**, dans quel ordre le prendre, et pourquoi cet ordre.
>
> Lire d'abord [`REFONTE-ILMS.md`](REFONTE-ILMS.md) — l'inventaire des trois
> sources, les invariants mesurés et les 30 pièges hérités — puis
> [`REPRISE-REFONTE.md`](REPRISE-REFONTE.md) pour les règles de travail et
> l'outillage (JDK 21, Maven de `.tools`, cluster PostgreSQL jetable,
> `mvn test` impossible).

---

## 1. Où on en est

Les dix onglets de la 3.0 ont tous une zone à l'écran. Huit viennent d'être
branchées ; deux l'étaient déjà.

| Zone | État | Livré par |
|---|---|---|
| Catalogue | branché | chantier précédent |
| Prêts et retours | branché | chantier précédent |
| Tableau de bord | branché | lot 1 |
| Lecteurs | branché | lot 2 |
| Matériel RFID | branché | lot 3 |
| Récolement | branché | lot 4 |
| Outils | branché | lot 5 |
| Import et export | branché | lot 6 |
| Poste public | branché | lot 7, complété au lot C |
| Comptes | **partiel** | lot 8 |

En ligne, non fusionné :

- `library-service` — branche `zones-restantes`,
  [MR !5](https://gitlab.com/bibliotheque-ztf/services/library-service/-/merge_requests/5),
  pipeline vert ;
- `ilms` — branche `zones-restantes`,
  [MR !6](https://gitlab.com/bibliotheque-ztf/apps/ilms/-/merge_requests/6) ;
- `sdk` — branche `refonte-session-operateur` (écriture de l'agent lecteur).

**Rien n'est déployé.** `docker-build`, `migrate` et `deploy` ne tournent que
sur `master`, et `migrate` est manuel avec `allow_failure: false` : il bloque
le pipeline tant que personne ne le joue. L'ordre des stages
(`docker-build → migrate → deploy`) est voulu — « une image déployée avant sa
migration sélectionne des colonnes qui n'existent pas encore ».

---

## 2. Ce qui manque, par ordre de nécessité

L'ordre n'est pas celui des onglets de la 3.0 : c'est celui de
l'**exploitation**. Sans le lot A on ne peut pas cataloguer, sans le lot B on
ne peut pas exploiter, sans le lot C on ne peut pas ouvrir au public.

### Lot A — Ajouter un livre

**Pourquoi d'abord.** C'est le deuxième onglet de la 3.0 et il n'a aucune
zone dans l'ILMS. Sans lui, un fonds ne s'enrichit que par import de
classeur : on ne peut pas cataloguer le livre qu'on a dans la main.

Ce que la 3.0 fait (`app.py`, section 2) :

- saisie d'un exemplaire, **cote calculée en direct** pendant la frappe ;
- code-barres tiré de la **séquence commune** — invariant mesuré : quatre
  postes créant 100 livres en même temps obtiennent 100 codes différents ;
- la séquence se cale sur les codes existants, pour un catalogue migré ou
  importé.

Ce qui existe déjà côté passerelle : `DocumentController`,
`DocumentCopyController`, `CoteController`, `EntitySequenceController`, et
`EntitySequenceService.generateNextNumber`. **Le travail est surtout un
écran**, plus la cote calculée si `CoteController` ne la rend pas déjà sous la
forme attendue.

Pièges à relire avant d'écrire : la cote suit l'emplacement et change si le
livre change de rayon ; le code-barres, lui, ne change jamais. Toute écriture
touchant titre, auteur, cote ou ISBN doit reconstruire les colonnes de
recherche — c'est tenu par un déclencheur depuis le chantier 2, donc **ne pas
le refaire dans le code**.

### Lot B — Sauvegardes, restauration, vidage — **fait**

Les quatre pièces sont écrites, et l'onglet Maintenance les porte.

- **sauvegarde `.dump`** : `pg_dump` lancé par le service lui-même, chaque
  soir à 23 h. La règle « une par jour » est portée par un `INSERT`
  conditionnel, pas par `pg_try_advisory_lock` : avec un pool R2DBC la
  connexion peut être recyclée entre deux requêtes, et le verrou partirait
  avec elle. Déclenchement manuel depuis l'écran, réservé aux administrateurs.
- **annulation d'un import par son étiquette** : colonne `import_lot` ajoutée,
  retrait doux (la notice n'est jamais touchée), **refusée si un livre du lot
  est encore prêté** — la règle de la 3.0.
- **restauration** : `pg_restore --clean --if-exists --no-owner
  --no-privileges --single-transaction`, sous le compte **propriétaire** de la
  base, dont le mot de passe est saisi à chaque fois. Dans l'ordre : le mot
  `RESTAURER`, la vérification du compte (un `pg_dump -s` jeté aussitôt), une
  copie de sécurité qui doit réussir, l'instantané de ce qui ne doit pas
  voyager dans le temps, puis `pg_restore`, puis la réinstallation.
- **vidage protégé** : le mot `SUPPRIMER`, une sauvegarde forcée qui doit
  réussir, puis **une seule instruction** (CTE modifiantes) qui supprime les
  notices de la bibliothèque — les exemplaires et les prêts partent par
  cascade.

Trois décisions prises en chemin, qui ne sont pas dans la 3.0 :

1. **Le vidage porte une bibliothèque, pas la base.** Le schéma cible en sert
   plusieurs là où la 3.0 n'en servait qu'une ; vider « le catalogue » sans
   dire lequel effacerait le fonds des voisines.
2. **L'instantané couvre trois tables** : les habilitations
   (`library_rfid_operators` — l'équivalent ici des comptes de la 3.0 ;
   l'annuaire lui-même vit dans `auth-service`, que la restauration ne touche
   pas), les postes RFID déclarés, et le **journal des sauvegardes**, parce
   qu'il contient la copie de sécurité prise une minute plus tôt. Seules les
   lignes vivantes sont prises, et chaque table est **vidée** avant d'être
   réécrite : une habilitation retirée ne revient pas. Les sessions opérateur
   ne sont pas reprises — une reconnexion vaut mieux qu'une session périmée.
3. **Le journal d'activité n'est jamais effacé**, même avec « aussi
   l'historique » : il porte la trace du vidage, et une suppression qui
   effacerait son propre enregistrement serait exactement ce qu'un journal est
   là pour empêcher.

Question tranchée (§5.6) : **les sauvegardes sont portées par le service
lui-même**, pas par un job GitLab ni un `cron` d'hôte. Un planificateur
interne, protégé par ShedLock, tient la nuit ; la règle « une par jour » vaut
aussi pour un clic manuel.

Deux limites à connaître, dites dans l'écran :

- **le service doit être redémarré après une restauration** : la base restaurée
  porte le `databasechangelog` de la sauvegarde, donc peut-être un schéma plus
  ancien que celui que le code interroge. Seul un redémarrage rejoue les
  migrations manquantes ;
- **les prêts partent avec les exemplaires**. `fk_loans_copy_id` est en
  `ON DELETE CASCADE` : on ne peut pas proposer de les garder, seulement
  demander à l'opérateur de dire qu'il l'a compris.

Éprouvé : `src/test/manual/run-pure-checks.ps1` (23 contrôles : le mot à taper,
la lecture de l'URL JDBC), `src/test/resources/db/maintenance_checks.sql`
(7 bancs sur cluster jetable : portée du vidage, cascades, comptes rendus,
refus d'annuler un import prêté), `src/test/manual/run-restore-smoke.ps1`
(18 contrôles de bout en bout, cluster compris : `pg_restore` réel, une
habilitation accordée après la sauvegarde qui survit, une habilitation retirée
qui ne revient pas), et `ilms/e2e/maintenance.spec.mjs` (12 essais).

### Lot C — Le kiosque (poste public) — **fait**

L'écran que voit le lecteur existe : `/kiosque?library=<id>`, à ouvrir en
plein écran sur l'ordinateur du hall. Recherche, fiche avec **où trouver le
livre**, coups de cœur, nouveautés, « à découvrir », thèmes.

**Une route de l'ILMS, pas une application à part.** Une seconde application
aurait dupliqué la configuration de la passerelle, les jetons de thème et la
chaîne de construction, pour un seul écran. La coquille s'efface d'elle-même
sur cette adresse (`AppComponent.plein`) : ni barre, ni bandeau, ni demande de
connexion.

**Sans session, et c'est le propos.** Les lectures passent par
`/api/v1/online/kiosk/**`, déjà `permitAll` côté service. Il a fallu ouvrir la
même porte côté navigateur : l'intercepteur de session refusait toute adresse
finissant par `/libraries/<id>/…` quand aucune session n'était ouverte —
**avant même de partir**. L'exemption est nommée, et testée sur le *chemin*
seul : une recherche dont le terme contiendrait `/api/v1/online/` ne doit pas
désarmer le contrôle de portée.

Deux tables ont été créées, comme prévu : `kiosk_settings` (un réglage d'écran
par bibliothèque) et `kiosk_picks` (les coups de cœur). Trois décisions prises
en chemin :

1. **Un coup de cœur porte une NOTICE, pas un exemplaire.** La 3.0
   enregistrait un code-barres et devait ensuite vérifier à chaque lecture
   qu'un autre exemplaire de la même œuvre n'était pas déjà en vitrine — tout
   son `dans_selection` ne fait que cela. Ici l'œuvre est une ligne : un index
   unique partiel suffit, et la question ne se pose plus.
2. **Les réglages ont leur table plutôt que six colonnes sur `libraries`.**
   Ce sont les réglages d'un *écran*, pas des propriétés de la bibliothèque ;
   une bibliothèque sans poste public n'a pas de ligne, et c'est la bonne
   façon de le dire.
3. **« En rayon » se calcule avec la même expression qu'au comptoir.** Si le
   poste public et la circulation comptaient différemment, un lecteur verrait
   « disponible » sur un livre que l'opérateur sait sorti.

**La règle tenue : le poste public ne jamais figer.** Elle se traduit par
quatre choses, chacune éprouvée au navigateur :

- l'accueil part en **un seul appel** — six requêtes, c'est six occasions de
  laisser l'écran à moitié rempli devant un lecteur ;
- chaque vitrine a **son propre délai et son propre filet** : celle qui
  n'aboutit pas revient vide, les autres s'affichent ;
- le **dernier accueil connu est gardé dans l'appareil**. Passerelle coupée,
  l'écran continue de montrer le fonds et dit seulement depuis quand ;
- la recherche part **après** la frappe et ne bloque jamais le clavier ; le
  journal des recherches attend son tour et repart par lots.

Côté administration, la zone « Poste public » ne se contente plus de regarder
la fréquentation : elle règle l'écran (titre, mot d'accueil, retour à
l'accueil, vitrines allumées, fenêtre des nouveautés) et tient la vitrine des
coups de cœur. Elle affiche aussi **l'adresse à ouvrir sur le poste de hall**,
pour qu'on n'ait pas à la reconstituer.

Un détail qui n'est pas cosmétique : l'écran de réglage réaffiche **ce que la
passerelle a retenu**, pas ce qui a été tapé. Angular ne retouche pas un champ
dont l'expression liée n'a pas changé — taper `0` dans une durée qui valait
déjà 120 laissait `0` affiché comme s'il avait été accepté. Le champ est donc
réécrit explicitement.

Éprouvé : `run-pure-checks.ps1` (26 contrôles de plus : défauts et bornes des
réglages), `src/test/resources/db/kiosk_checks.sql` (10 bancs sur cluster
jetable), `src/test/manual/run-kiosk-queries.ps1` — qui va **chercher les
requêtes dans les annotations compilées** et les joue telles quelles, parce
que les requêtes du kiosque sont composées et qu'une concaténation fautive ne
se voit pas dans les morceaux — et `ilms/e2e/kiosque.spec.mjs` (16 essais,
dont passerelle coupée, passerelle lente, et absence de session) plus
`consultation.spec.mjs` porté de 6 à 13 essais.

**Ce qui reste du kiosque.** La 3.0 proposait au lecteur de **suggérer un
achat** quand un livre manque (`kiosque.py`, `suggerer`), et dessinait le
**plan de l'étagère** avec le bloc en surbrillance. Ni l'un ni l'autre n'est
repris ici : la suggestion demande une table et un écran de traitement côté
administration, et le plan dépend de la maille « bloc » — la décision n° 1
ci-dessous, toujours ouverte.

### Lot D — Le service mobile — **fait**

Le plan avait vu juste : il ne restait qu'à en faire une PWA et à brancher la
caméra. La 3.0 servait son propre serveur web aux téléphones du Wi-Fi, avec
son autorité de certification à poser sur chaque appareil ; l'ILMS est déjà
une application web en HTTPS derrière la passerelle, avec sa session et ses
droits. Rien de cela n'était à refaire.

**L'installation** se fait depuis le navigateur — « Ajouter à l'écran
d'accueil », pas de magasin, pas de certificat à poser. Le service worker
garde la coquille pour que l'application s'ouvre au fond d'un magasin sans
Wi-Fi ; il **ne met jamais une réponse de la passerelle en cache**, parce
qu'une disponibilité ou un prêt périmés font agir sur un état qui n'existe
plus. Écrit à la main plutôt que produit par `@angular/pwa` : cette règle est
la seule qui compte, et elle doit tenir sur un écran.

**La caméra** est un seul composant pour les quatre écrans qui prennent un
code — comptoir, récolement, catalogue, poste public. `BarcodeDetector` quand
le navigateur l'a ; `zxing.min.js` (336 ko, celui de la 3.0) chargé seulement
s'il manque, et seulement à l'ouverture de la caméra. Deux modes : simple, et
**continu** pour récoler une étagère ou poser une pile de retours. Le même
code ne compte qu'une fois par seconde et demie — une caméra voit vingt fois
le même code-barres pendant qu'une main tient le livre.

**Le clavier reste ouvert sous la vidéo.** Ce n'est pas un repli : c'est le
chemin d'une douchette Bluetooth, et le seul quand la caméra est refusée.

**Ce qu'il a fallu ajouter au service.** Le comptoir est entièrement piloté
par les tags RFID ; un téléphone n'a pas d'antenne. `RfidTagRequest` accepte
donc un `code` — l'étiquette imprimée — et deux recherches le prennent après
le tag : code-barres puis cote pour un exemplaire, numéro pour une carte. Le
tag d'abord, toujours. **Et rien d'autre ne change** : une fois l'exemplaire
retrouvé, c'est le même prêt, les mêmes invariants, la même idempotence.

**Un défaut attrapé par les essais, et il valait le banc.** Le premier
nettoyage d'un code *supprimait* les espaces intérieures. Or
`library_normalize` transforme toute ponctuation en espace puis fusionne :
`A-E44-R1-0001` et `A-E44 R1-0001` sont le même code pour la base, mais
`A-E44R1-0001` ne l'est pas. Un nettoyage plus zélé que celui de la base est
un nettoyage qui casse la comparaison. Les espaces sont donc fusionnées, pas
supprimées.

**Ce qui n'a pas eu besoin d'être ajouté.** Scanner un ISBN marche déjà :
`search_text` contient `isbn`, `isbn13`, `issn`, `ddc`, `oclc` et `upc`. Le
code entre par la barre de recherche, comme un mot — lui donner une route
séparée aurait voulu dire deux façons de trouver un livre. Et le récolement
hors réseau du lot 4 a servi tel quel : la caméra alimente la file existante,
qui horodate sur l'appareil et rejoue avec sa clé d'idempotence.

Éprouvé : `run-pure-checks.ps1` (24 contrôles de plus : le nettoyage d'un code
lu), `src/test/resources/db/scan_checks.sql` (7 bancs — la rencontre des deux
nettoyages, la portée par bibliothèque, l'exemplaire retiré), et
`ilms/e2e/mobile.spec.mjs` (12 essais, avec une fausse caméra et un
`BarcodeDetector` simulé : on y éprouve l'anti-rebond, le mode continu, et le
fait que le comptoir envoie `code` et jamais un EPC inventé).

**Ce qui reste du service mobile.** La **fiche d'un livre scanné** côté
personnel, telle que `mobile.py` la montrait : aujourd'hui un code scanné
ouvre une ligne de circulation au comptoir, une recherche au catalogue — ce
qui couvre l'essentiel sans l'écran dédié. Et le mode continu n'affiche pas de
compteur de session (« 14 livres depuis l'ouverture »), utile sur un
récolement long.

### Lot E — Multi-postes et temps réel — **fait**

Deux postes se voient désormais travailler. **La décision n° 3 est tranchée, et
la réponse n'est aucune des deux options proposées.**

| | Source des avis | Livraison aux postes |
|---|---|---|
| **Retenu** | Déclencheur PostgreSQL → `NOTIFY` | Évènements envoyés par le serveur |
| Écarté | RabbitMQ | WebSocket |

**Pourquoi la base, et pas un courtier.** Les deux options du plan partagent le
même défaut : c'est le *code* qui doit penser à publier. Ce chantier a déjà payé
cette leçon — les colonnes de recherche étaient reconstruites par le code en
3.0, et l'oubli était le bogue le plus courant. Un avis émis par un déclencheur
ne peut pas être oublié : il part sur un import, une correction à la main en
`psql`, une restauration. Et il ne part **que si la transaction est validée**,
ce qu'aucun appel applicatif ne donne gratuitement. C'est d'ailleurs ce que
faisait la 3.0 ; on reprend le mécanisme, pas l'architecture.

**Pourquoi SSE, et pas un WebSocket.** Le flux va dans un seul sens ; un canal
de retour ne sert à personne — et le `LibraryWebSocketHandler` déjà présent
montre ce qui arrive quand il existe : il rediffuse à toute la bibliothèque ce
qu'un navigateur lui envoie. Surtout, `EventSource` se reconnecte seul : la
règle « coupure réseau ou redémarrage : reconnexion seule » est tenue **sans
une ligne de code**, et l'essai 6 le vérifie en coupant le flux pour de bon.

**Un seul avis par transaction, mesuré.** PostgreSQL replie les avis dont le
couple (canal, contenu) est identique dans une même transaction : 2 000 lignes
insérées d'un coup sur deux bibliothèques produisent exactement **deux** avis.
Un import de 73 223 exemplaires en émet un par bibliothèque. C'est pour cela
que le contenu ne porte que la bibliothèque et le genre — y mettre
l'identifiant de la ligne ferait un avis par ligne.

**Trois genres** : `catalogue`, `prets`, `vitrine`. Le canal `index` de la 3.0
n'est pas repris : il servait à son index d'œuvres côté poste, et ici
`search_text` est tenu par un déclencheur dans la transaction de l'écriture.
Reproduire un canal qui n'a rien derrière aurait été du mimétisme.

**Qui se rafraîchit, et qui se contente de le dire** — la décision la plus
discutable du lot :

- le **poste public** se rafraîchit tout seul. Personne ne le tient, aucun
  geste à interrompre, et un hall qui dormirait sur les chiffres d'hier serait
  un écran qui ment. Il diffère sa mise à jour si un lecteur regarde une fiche,
  et l'applique à son retour ;
- le **catalogue** affiche « le catalogue a changé — relire ». Voir sa liste se
  réordonner pendant qu'on la lit est pire qu'une liste d'il y a dix secondes ;
- le **comptoir** pose un bandeau et ne touche à rien, jamais pendant qu'une
  ligne est en cours. Une ligne qui disparaîtrait pendant qu'un opérateur pose
  un livre serait un accident.

Les trois invariants du plan :

- *aucun état partagé en mémoire entre postes* — tenu par construction : chaque
  instance du service écoute la même base et relaie à ses propres postes. Rien
  à synchroniser, et le nombre d'instances n'a plus d'importance ;
- *un seul poste met l'index à jour à la fois* — tenu **structurellement**, pas
  par un verrou : il n'y a plus d'index côté poste. Ajouter un verrou aurait
  été protéger quelque chose qui n'existe plus ;
- *reconnexion seule, écriture jamais rejouée à moitié* — la reconnexion est
  celle du navigateur ; rien n'est rejoué parce qu'un avis ne porte aucune
  écriture. Un avis perdu pendant une coupure n'a pas besoin d'être rattrapé :
  un poste qui se reconnecte relit.

Éprouvé : `run-pure-checks.ps1` (22 contrôles de plus : la lecture d'un avis,
qui arrive par un canal PostgreSQL **ouvert** et n'est donc pas digne de
confiance), `run-notices-checks.ps1` (7 contrôles sur cluster jetable, avec les
déclencheurs **extraits de la migration** plutôt que recopiés), et
`ilms/e2e/temps-reel.spec.mjs` (9 essais avec un vrai flux `text/event-stream`,
dont la coupure et la reconnexion).

**Ce qui reste, et qui n'est pas de ce lot.** `WebSocketConfig` et
`RfidWebSocketConfig` déclarent toutes deux un bean nommé `handlerAdapter` ;
`allow-bean-definition-overriding` étant à `true`, l'une des deux gagne en
silence. Ce lot n'utilise ni l'une ni l'autre, mais le défaut reste à trancher
avant qu'une de ces routes serve vraiment.

### Lot F — Migration des données — **fait**

Le fonds réel est repris : **50 268 notices, 73 223 exemplaires, 30 936
mouvements d'historique**, avec contrôle du nombre de lignes table par table.
Programme dans `library-service/src/main/resources/db/reprise-3.0/`, banc dans
`src/test/manual/run-reprise-3.0.ps1`, et
`library-service/docs/REPRISE-FONDS-3.0.md`.

**Le dump est du PostgreSQL, pas du SQLite.** La 3.0 avait déjà fait sa propre
migration ; `migrer_depuis_sqlite.py` ne servait donc pas de modèle de code,
seulement de modèle de **discipline** — déclencheurs coupés pendant la copie,
index reconstruit en une passe, compteurs réavancés, et la fin qui ne pardonne
pas : « chaque table a le même nombre de lignes des deux côtés ».

**Les quatre décisions, et le relevé qui les a dictées.** Rien ici ne vient
d'une supposition : le dump a été restauré et mesuré avant d'écrire une ligne.

| Mesure sur le fonds réel | Ce qu'elle décide |
|---|---|
| 1 946 œuvres portent **plusieurs titres** parmi leurs exemplaires, 568 plusieurs auteurs, 1 313 plusieurs catégories | la notice est l'**œuvre de la 3.0**, pas un regroupement par titre : regrouper nous-mêmes refait un arbitrage déjà rendu, et le rend autrement |
| 8 506 œuvres portent un `auteur_sig` **absent** de la table des auteurs, et le champ auteur est une **liste** (36 noms, 672 caractères) | les auteurs sont **dérivés de la liste**, pas repris de la table `auteur` — s'y fier aurait perdu les auteurs de 8 506 œuvres sans rien signaler |
| 10 465 exemplaires **sans étagère** | ils arrivent hors circulation, donc hors du compte « en rayon » du hall. Presque un livre sur sept : la décision la plus discutable du lot, et c'est pour cela qu'elle est écrite trois fois |
| **un seul compte** dans tout le dump (`bztf`, PBKDF2, 200 000 itérations) | **la décision n° 4 est tranchée : réinitialisation.** Voir plus bas |

Les identifiants sont **calculés** (`md5(bibliothèque‖genre‖clé)::uuid`), pas
tirés au hasard : aucune table de correspondance à tenir entre les étapes, et
la reprise est **rejouable** — relancée, elle réécrit les mêmes lignes au lieu
d'en créer un second jeu.

**Trois valeurs mesurées ne tiennent pas dans leur colonne cible**, et dans
les trois cas la valeur complète est conservée ailleurs plutôt que coupée : un
ISBN de 59 caractères (colonne de 50) partirait dans `general_note`, dix noms
d'auteur de plus de 150 caractères dans `biography`, une date de publication
de 42 caractères dans `mention`. Un ISBN tronqué est un ISBN faux, et un ISBN
faux est pire qu'un ISBN absent.

Sur ce fonds, **deux de ces trois gardes n'ont pas eu à jouer** — le bilan
rend `0` et `0` — et c'est écrit ainsi exprès. Une garde qui ne se déclenche
pas n'est pas inutile : c'est une garde dont le bilan prouve qu'elle n'a pas
eu besoin de mentir.

**Le contrôle, durci.** La 3.0 comparait ce qu'elle avait **lu** à ce qu'elle
avait **écrit** — deux comptes tenus par le même programme. Ici l'attendu est
relu de la **source** et l'obtenu de la **cible**, après validation de la
transaction : un déclencheur qui aurait mangé des lignes se verrait. Trois
verdicts, un seul fait échouer :

- `EXACT` — le compte attendu, à l'unité ;
- `ECARTE` — un écart **attendu, avec sa raison écrite** (la raison est
  obligatoire : un écart sans raison serait un échec déguisé) ;
- `ECHEC` — un écart non expliqué, et la reprise est déclarée ratée.

**Chaque table source est soit reprise avec son compte, soit déclarée non
reprise avec sa raison.** Aucune ne disparaît en silence — y compris les
25 425 mots de vocabulaire, qui sont **reconstruits** et non copiés : copier un
index, c'est se donner deux vérités dont l'une se taira. C'est le même
raisonnement qui a fait choisir un déclencheur plutôt qu'un courtier au lot E.

**Ce que le fonds réel a trouvé, et qu'aucun échantillon n'aurait trouvé.**
La première course du banc **ne finissait pas** :
`library_document_search_refresh()` interroge
`document_copies WHERE document_id = NEW.id` à chaque écriture de notice, et
**aucun index n'existait sur cette colonne** — seulement la clé étrangère
`fk_document_copy_document`, qui n'en crée pas. Reconstruire l'index de
50 268 notices demandait 50 268 parcours de 73 223 exemplaires. Corrigé par
`V1__2026_10_22_0002_index_document_copies_document.xml`, qui pose aussi
l'index manquant sous `fk_loans_document_id` — en `ON DELETE CASCADE`, lui
aussi sans index.

C'est la justification de tout le lot : sur un catalogue d'essai de quelques
dizaines de lignes, ce défaut est **invisible**.

**Décision n° 4 — les empreintes PBKDF2 : réinitialisation.** Le relevé
tranche la question à la place de l'architecture. Il y a **un** compte dans
tout le dump. Écrire un adaptateur de vérification PBKDF2 à côté de BCrypt
pour un unique administrateur, c'est ajouter un second chemin
d'authentification — « exactement le genre de chemin parallèle où une
vérification se perd » — et l'y laisser pour toujours. Les empreintes ne sont
donc pas reprises, et le bilan le **dit** (rang 35) plutôt que de les laisser
disparaître. C'est de toute façon un geste à faire : le mot de passe 3.0 était
celui d'une application de bureau, pas d'un service exposé.

**La course réelle du 22 octobre 2026**, cluster jetable, poste de
développement : **reprise en 104 s** (repère 3.0 : 154 s), chargement du dump
en 28 s, pose du schéma cible en 10 s. Tous les comptes `EXACT` — 50 268
notices, 73 223 exemplaires, 30 936 mouvements, 40 729 éditions, 27 802
auteurs découpés de la liste, 8 125 éditeurs, 107 catégories, 59 étagères — et
les neuf cohérences à `0` : aucun orphelin, aucun code-barres en double,
aucune notice sans colonnes de recherche, aucun compteur resté en arrière.

Deux chiffres qu'on relit deux fois : **29 142 mots de vocabulaire**
reconstruits contre 25 425 en 3.0 — écart attendu, le vocabulaire cible porte
deux genres (`TITLE` et `AUTHOR`) quand la 3.0 n'en avait qu'un ; et **10 464
exemplaires hors circulation**, exactement le nombre d'exemplaires sans
étagère dans la source. Une décision assumée doit se compter.

**Les temps du §1.11 rejoués**, et ils tiennent — `04-chronometrer.sql`, ou le
banc avec `-Chronometrer` :

| Opération | Plan | Mesuré | Repère 3.0 |
|---|---|---|---|
| accès direct par code-barres | index | **0,12 ms** | 0,02 ms |
| accès direct par cote | index | **0,17 ms** | — |
| « normal christian life » | fonction du service | **62 / 68 / 64 ms** à chaud | 65 ms |
| plein texte pondéré | index GIN | **14 ms** | ~60 ms |
| accueil du poste public | parcours de 73 223 | **97 ms** | 4 à 70 ms |

La recherche complète **tombe sur son repère**, et c'est le chiffre qui compte
puisque c'est le chemin que l'application emprunte vraiment. Ce qu'on regarde
n'est d'ailleurs pas la milliseconde — ni la machine ni le volume ne sont ceux
de la 3.0 — mais le **plan** : c'est ainsi que l'index manquant a été trouvé.

**Un seul écart est un sujet, et il est documenté comme tel.** L'accueil du
poste public parcourt les 73 223 exemplaires : compter tout en lit forcément
tout. C'est le **prix mesuré d'une décision du lot C** — « la disponibilité est
recalculée à chaque lecture, jamais lue d'une colonne », parce que cet écran
envoie quelqu'un marcher jusqu'au rayon. La 3.0 tenait 4 à 70 ms en lisant sa
table `theme` pré-calculée, précisément celle que la reprise refuse de
reprendre. Le chiffre manquait ; il ne manque plus. Trancher entre le cache
déjà présent côté hall et des compteurs dans `document_metrics` demande de
savoir combien de postes publics tournent — ce n'est pas de ce lot.

Le second parcours, celui du `LIKE '%christ%'`, **n'est pas un défaut** : le
GIN trigramme existe et le planeur préfère le parcours à 8,6 % de sélectivité,
à raison. Et ce n'est pas le chemin de l'application.

**Ce que le lot n'a pas fait.** Les couvertures portées par 41 323 exemplaires ne sont
pas transportées : `cover_image` reçoit le chemin relatif de la 3.0, et le passage
au service de médias appartient au lot G, qui porte déjà le rattachement des
couvertures. L'éditeur, la date et la pagination sont **repris tels quels,
sans nettoyage** — le fonds contient un ISBN dans la colonne « pages » et un
nombre à douze chiffres dans « éditeur » ; les corriger ici en silence les
rendrait introuvables.

### Lot G — Finitions d'Outils et de Comptes

Plus petits, et sans dépendance entre eux.

**Outils** :

- rattachement des couvertures. En 3.0 il lisait des dossiers d'images sur le
  disque du poste ; la passerelle n'a pas ce disque et les images passent par
  le service de médias. Les règles à reprendre : le chemin fait foi, un
  nettoyeur **dédié aux chemins** (le général fusionne les espaces et rend un
  fichier introuvable), rattachement par nom **seulement si le fichier n'a
  aucune colonne d'image**, et **titre seul désactivé par défaut** — mesuré
  sur le fonds réel, il se trompait une fois sur deux ;
- renommage d'une catégorie dans tout le catalogue ;
- corrections de masse des inversions titre/auteur et des auteurs factices.
  Écartées au lot 5 parce qu'ici **l'auteur est une entité, pas un texte** :
  l'échange demanderait de créer ou de détruire des fiches d'auteur. À
  concevoir, pas à improviser.

**Comptes** :

- créer, modifier, désactiver un compte. Relève de `auth-service`, qui tient
  l'annuaire — en tenir un second dans l'ILMS ferait diverger les deux ;
- **clé de secours** : 20 caractères sans ambiguïté (ni O/0 ni I/1, soit
  100 bits), remise **une seule fois**, seule son empreinte gardée. Le même
  mécanisme vient d'être écrit pour la clé d'appairage de l'agent
  (`BiblioRFID/lib/reader-agent.js`, `generateAgentKey`) : s'en inspirer ;
- historique des connexions, et **liste des postes avec leur version**, en
  orange quand une mise à jour est disponible. Chaque poste se signalait
  toutes les minutes en 3.0.

---

## 3. Avant tout déploiement

1. **Fusionner les deux MR** dans `master`.
2. **Jouer `migrate:preview`**, lire le SQL produit : on ne doit y trouver que
   des `CREATE TABLE`, des `CREATE INDEX` et des `ALTER TABLE … ADD`. Un
   `DROP` ou un `ALTER COLUMN` demande de s'arrêter.
3. **Vérifier les doublons de tags avant `migrate:apply`.** Les deux index
   uniques partiels du lot 3 refuseront la migration si le fonds en porte :

   ```sql
   SELECT rfid_tid, count(*) FROM document_copies
   WHERE rfid_tid IS NOT NULL AND rfid_tid <> '' AND deleted_at IS NULL
   GROUP BY rfid_tid HAVING count(*) > 1;
   ```

4. **Activer la session opérateur en ligne** — point ouvert depuis le chantier
   précédent : client OAuth serveur, origines HTTPS exactes du frontend. Les
   huit zones s'appuient toutes dessus.
5. **Créer la clé d'appairage sur chaque poste** (`POST /api/agent/key`), la
   noter, la coller dans l'écran Matériel RFID. Sans clé, l'encodage reste
   fermé — c'est le défaut voulu.

---

## 4. Décisions à prendre

| # | Question | Pourquoi elle bloque |
|---|---|---|
| 1 | Le « bloc » de la 3.0 est porté par `shelf_row` : est-ce la bonne maille ? | Le récolement et les étiquettes en dépendent. La spécification laissait la correspondance bloc/série/rang à confirmer. |
| 2 | ~~Qui porte les sauvegardes ?~~ **Tranché : le service lui-même**, par un planificateur interne protégé par ShedLock. Ni job GitLab, ni `cron` d'hôte. | — |
| 3 | ~~Transport des avis temps réel ?~~ **Tranché : ni l'un ni l'autre.** Déclencheur PostgreSQL `NOTIFY` pour la source, évènements envoyés par le serveur pour la livraison. Voir le lot E. | — |
| 4 | Les comptes PBKDF2 du dump : adaptateur de vérification ou réinitialisation ? | Bloque le lot F. |

---

## 5. Ce qui est déjà éprouvé, et comment le rejouer

Rien de ce qui suit ne demande de connexion au serveur de production.

```bash
# Frontend : 17 suites, 165 essais pilotés au navigateur
cd ilms && npx ng build --configuration development
PLAYWRIGHT=C:/laragon/www/sdk/BiblioRFID/node_modules/playwright-core/index.mjs \
  node e2e/<zone>.spec.mjs

# Poste : 87 tests unitaires, plus un banc contre un vrai poste
cd sdk/BiblioRFID && npm test && node tests/agent-write-smoke.mjs

# Règles pures : verdicts du récolement, EPC, étiquettes, contrôle d'un
# classeur, mot à taper avant une opération irréversible, URL JDBC
library-service\src\test\manual\run-pure-checks.ps1

# Restauration, de bout en bout : le script monte son propre cluster, prend un
# vrai pg_dump, le rejoue avec pg_restore --clean --single-transaction, et
# vérifie que les habilitations d'aujourd'hui ont survécu au voyage.
library-service\src\test\manual\run-restore-smoke.ps1

# Base : un cluster jetable, puis les recettes
psql -f db/functions/library_normalize.sql -f db/functions/library_quality.sql
psql -f src/test/resources/db/<zone>_fixtures.sql \
     -f src/test/resources/db/<zone>_checks.sql
```

```powershell
# Les requetes du poste public, lues dans les annotations compilees et jouees
# telles quelles. Le script monte son propre cluster.
library-service\src\test\manual\run-kiosk-queries.ps1
```

```bash
# Le service mobile : la rencontre des deux nettoyages d'un code lu.
psql -f src/main/resources/db/functions/library_normalize.sql \
     -f src/test/resources/db/scan_fixtures.sql \
     -f src/test/resources/db/scan_checks.sql
```

```powershell
# Les avis de changement : combien en part-il vraiment ? Le script monte son
# cluster et extrait les declencheurs de la migration.
library-service\src\test\manual\run-notices-checks.ps1

# Et la garde qui manquait : compile TOUS les bancs manuels sans les lancer.
# « mvn compile » ne couvre pas src/test/manual, et un banc casse n'apparait
# qu'en CI — c'est arrive une fois.
library-service\src\test\manual\run-compile-checks.ps1

# La reprise du fonds REEL, de bout en bout : cluster jetable, schema cible
# pose par la vraie migration, dump 3.0 charge, reprise, puis le controle du
# nombre de lignes table par table. 12 controles, ~3 minutes, 1,5 Go de place.
# C'est ce banc qui a trouve l'index manquant sous le declencheur de
# recherche : sur un catalogue d'essai, ce defaut est invisible.
library-service\src\test\manual\run-reprise-3.0.ps1 [-Chronometrer]
```

**Exécute ce que tu écris.** Sur ce chantier, cinq défauts n'ont été trouvés
qu'en lançant le code : un écran de récolement qui ne reprenait pas sa
campagne après rechargement, un typage qui ne cassait que le build complet,
une planche d'étiquettes au mauvais format — et un contrôle qui comptait mal
parce que `"re\s"` vaut « re + espace » en Java depuis la version 15 — et
une reprise de fonds qui ne finissait pas, parce qu'une colonne de clé
étrangère n'avait pas d'index. Aucun ne se voyait à la relecture.
