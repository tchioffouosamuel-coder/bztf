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

### Lot D — Le service mobile

`mobile.py` + `service_mobile.py`, 1 284 lignes. C'est la pièce la plus
directement transposable : **c'est déjà une application web**, servie en
HTTPS, sans magasin d'applications.

- pour tous : chercher, voir la couverture, la disponibilité, et **où le livre
  se range** ; scanner un ISBN ;
- pour le personnel : fiche d'un livre scanné, prêt, retour, prolongation,
  annulation, **récolement** d'une étagère ou d'un bloc ;
- caméra en guise de douchette, douchette Bluetooth et clavier acceptés.

**Le récolement hors réseau du lot 4 est réutilisable tel quel** : la file
d'attente, l'horodatage par l'appareil et la clé d'idempotence sont déjà dans
`ilms/src/app/core/inventory/inventory.service.ts`, et les routes
`/inventory/campaigns/{id}/scans` acceptent déjà un lot.

Ce qu'il reste : en faire une PWA (manifeste, service worker), et brancher la
caméra.

### Lot E — Multi-postes et temps réel

Les trois canaux de la 3.0 — `catalogue`, `index`, `prets` — n'existent sous
aucune forme. **Deux postes ne se voient pas encore travailler.**

Le choix du transport reste à trancher (§5.3 de la spécification) :
`RfidWebSocketHandler`, déjà présent dans `infrastructure/rfid/`, ou un
échange RabbitMQ. Ce qui ne se négocie pas :

- aucun état partagé en mémoire entre postes ; tout cache est invalidé par les
  avis ;
- un seul poste met l'index à jour à la fois ;
- coupure réseau ou redémarrage : reconnexion seule, lecture rejouée, écriture
  interrompue **jamais** rejouée à moitié.

À faire **avant** d'ouvrir une deuxième station de circulation.

### Lot F — Migration des données

Reprendre `sdk/Nouveau dossier/BASE/bztf catalogue migre 2026-09-25.dump`
(73 223 exemplaires) vers le schéma cible, **avec contrôle du nombre de lignes
table par table**, comme le faisait `migrer_depuis_sqlite.py` (154 s sur le
fonds réel).

Deux points mesurés à rejouer après migration : les temps du §1.11 de la
spécification, et les empreintes PBKDF2 des comptes — elles ne sont pas des
mots de passe à remettre à BCrypt, elles demandent un adaptateur de
vérification ou une réinitialisation explicite.

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
| 3 | Transport des avis temps réel : WebSocket existant ou RabbitMQ ? | Bloque le lot E, et donc l'exploitation à deux postes. |
| 4 | Les comptes PBKDF2 du dump : adaptateur de vérification ou réinitialisation ? | Bloque le lot F. |

---

## 5. Ce qui est déjà éprouvé, et comment le rejouer

Rien de ce qui suit ne demande de connexion au serveur de production.

```bash
# Frontend : 15 suites, 144 essais pilotés au navigateur
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

**Exécute ce que tu écris.** Sur ce chantier, quatre défauts n'ont été trouvés
qu'en lançant le code : un écran de récolement qui ne reprenait pas sa
campagne après rechargement, un typage qui ne cassait que le build complet,
une planche d'étiquettes au mauvais format — et un contrôle qui comptait mal
parce que `"re\s"` vaut « re + espace » en Java depuis la version 15. Aucun ne
se voyait à la relecture.
