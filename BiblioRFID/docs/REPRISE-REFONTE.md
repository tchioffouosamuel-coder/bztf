# Prompt de reprise — refonte ILMS

> À coller tel quel dans une session neuve. Il suppose zéro contexte.

---

Tu reprends une refonte en cours sur trois dépôts Git distincts, tous sous
`C:\laragon\www\`. Rien n'est poussé : tout vit sur des branches locales.

| Dépôt | Branche | Rôle |
|---|---|---|
| `sdk` | `refonte-ilms` | le poste BiblioRFID (Node.js) et la spécification |
| `library-service` | `refonte-recherche-catalogue` | le backend (Spring Boot 3 / Java 21 / R2DBC) |
| `ilms` | `refonte-frontend` | le frontend (Angular 19, autonome) |

**Lis d'abord `sdk/BiblioRFID/docs/REFONTE-ILMS.md`.** C'est la spécification de
référence : l'inventaire complet des trois sources, les invariants mesurés, le
contrat matériel, et 21 pièges hérités qui ont chacun coûté un bogue réel. Tout
ce qui suit s'y appuie.

## La cible

Un backend 100 % en ligne sur `gateway.bibliotheque-ztf.org`, bâti sur le socle
GitLab existant, dont le cœur métier fusionne l'application Python
`sdk/Nouveau dossier` (VERSION POSTGRES 3.0, 73 223 exemplaires) et la chaîne
matérielle de BiblioRFID. Un frontend ILMS réécrit de zéro. Le poste BiblioRFID
réduit à un pur service matériel.

L'ILMS précédent n'est **pas** une référence fonctionnelle : il a été vidé. La
référence est `sdk/Nouveau dossier` plus la couche matériel de
`sdk/BiblioRFID` et `sdk/Reader/myscankey_flutter`.

## Ce qui est fait

**BiblioRFID** — toute la couche ILMS retirée (7 418 lignes). 75 tests passent
(`npm test`). C'est maintenant un pur service matériel : RFID/UHF, pont, OTA,
catalogue local, synchronisation.

**Backend** — la recherche du catalogue est portée en PostgreSQL
(`tsvector` + `pg_trgm`), avec le barème mesuré de la 3.0 :
`db/functions/library_normalize.sql`, `library_search_refresh.sql`,
`library_search_documents.sql`, migration
`V1__2026_10_18_0001_create_catalog_search.xml`. Exposée par
`CatalogSearchController` (`GET /catalog/search` et `/catalog/by-identifier`),
`CatalogSearchService`, `CatalogSearchRepository`.

L'invariant « un livre ne peut pas être prêté deux fois » est posé
(`V1__2026_10_18_0002_enforce_single_open_loan.xml`) : index unique **partiel**
`uq_loans_open_copy`, et `CirculationRfidServiceImpl` traduit la violation en
« Cet exemplaire est déjà emprunté ».

**Frontend** — ossature autonome (`bootstrapApplication`, pas de NgModule),
dix zones en chargement différé, passerelle figée dans `core/gateway`, droits
de la 3.0 dans `core/auth/rights`, service du lecteur RFID avec son anti-rebond
dans `core/rfid`. **La zone Catalogue est la seule branchée** et fonctionne.

## Ce qui reste

1. **Prêts et retours** — la prochaine étape. Les endpoints existent déjà
   (`/api/v1/libraries/{id}/circulation/rfid/checkouts`, `/returns`,
   `/members/resolve`, `/copies/resolve`), l'invariant est posé. Il reste
   l'écran. C'est celui où les règles héritées sont les plus exigeantes.
2. **Les huit autres zones** : tableau de bord, lecteurs, récolement, matériel
   RFID, outils, import/export, poste public, comptes. Chacune est une coquille
   qui rappelle en commentaire les règles qu'elle devra tenir.
3. **L'authentification** et la session opérateur. `LibraryContext` lit la
   bibliothèque dans `?library=` puis la retient — provisoire, assumé, et à
   coiffer par la session.
4. **Les fonctions de la 3.0 absentes du backend** : contrôle qualité d'un
   catalogue Excel, récolement par bloc, étiquettes PDF, sauvegardes.
5. **La migration des données** : reprendre le `.dump` de
   `sdk/Nouveau dossier/BASE/` vers le schéma cible, avec contrôle du nombre de
   lignes table par table.

## Règles de travail, non négociables

**Exécute ce que tu écris.** Trois bogues réels n'ont été trouvés qu'en lançant
le code, jamais en le relisant : une prime de classement qui ne jouait jamais,
un `unaccent` qui échouait seulement à l'inlining dans un index, et un `NG0600`
qui laissait l'écran bloqué sans aucun résultat. Compiler ne prouve rien.

- **SQL** : monte un cluster jetable dans le scratchpad.
  `initdb` et `psql` sont dans
  `C:\Users\SAMUEL TCHIOFFOUO\scoop\apps\postgresql\current\bin` (PostgreSQL
  18.6, avec `unaccent` et `pg_trgm`). Bancs d'essai rejouables dans
  `library-service/src/test/resources/db/` : `catalog_search_fixtures.sql`,
  `catalog_search_checks.sql` (11 essais), `circulation_invariants_checks.sql`.
- **Java** : JDK 21 obligatoire
  (`C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot`, le défaut est
  17). Maven hors ligne :
  ```
  mvn -o -s C:/laragon/www/ilms-migration/.tools/maven-settings.xml \
      -Dmaven.repo.local=C:/laragon/www/ilms-migration/.tools/maven-repository \
      compile -DskipTests
  ```
  Si un artefact est « présent mais indisponible », supprime son
  `_remote.repositories`.
- **Frontend** : `npx ng build --configuration development`, puis pilote
  l'écran. `e2e/catalogue.spec.mjs` montre comment — il sert le build, intercepte
  les appels à la passerelle et vérifie le comportement réel :
  ```
  PLAYWRIGHT=C:/laragon/www/sdk/BiblioRFID/node_modules/playwright-core/index.mjs \
    node e2e/catalogue.spec.mjs
  ```

**Ne commite jamais le travail d'autrui.** `library-service` porte du travail
non committé préexistant (toute la fonctionnalité `LibraryRfid*`, plus
`DatabaseTable.java`). Laisse-le exactement comme tu le trouves. Quand tu dois
modifier `master.xml`, que les deux se partagent : écris dans l'index la version
`HEAD` + ta seule ligne, puis restaure le fichier complet dans l'arbre de
travail.

**N'écris pas de patch par heredoc.** Une barre oblique inverse suivie d'un `n`
y devient un vrai retour à la ligne. Utilise l'outil d'édition.

**Corrige la justification, pas seulement le code.** Si une règle héritée ne
transpose pas — comme « jamais de `OR` sur les identifiants », qui venait de
SQLite et d'un index partiel, alors que PostgreSQL sert le `OR` par un
`BitmapOr` — mets la spécification à jour plutôt que de propager une raison
fausse.

**Commits en français**, corps explicatif, et termine par :

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

## Les règles que l'écran Prêts et retours devra tenir

Elles viennent de la 3.0 et du matériel. Chacune a une raison.

- **Jamais de fenêtre modale.** La douchette taperait dedans. Message dans le
  bandeau et bip, rien de bloquant.
- **Carte du lecteur, puis les livres à la suite.** C'est le geste réel du
  comptoir, pas un formulaire par prêt.
- **Un refus est une réponse ordinaire.** « Déjà emprunté » vient de la base et
  s'affiche tel quel, sans dramatisation.
- **Le poste reste maître.** Un prêt enregistré localement ne peut pas être
  annulé par une coupure réseau. Le report renvoie un *état* — `refused`,
  `skipped`, `queued` — jamais une exception. `queued` n'est pas un échec.
- **L'idempotence passe par `operation_id`.** Rejouer après une coupure ne crée
  pas un second prêt.
- **La disponibilité se relit, ne se mémorise pas.** Promettre un livre qui
  vient de partir est pire qu'une jointure de plus.
- **Un tag qui disparaît une fraction de seconde reste affiché** : 700 ms côté
  agent, puis 1,5 s d'anti-rebond visuel. Sinon la liste clignote et les
  notifications se rejouent.
