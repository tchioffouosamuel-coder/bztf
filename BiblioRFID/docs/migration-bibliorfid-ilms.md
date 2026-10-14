# Migration BIBLIORFID vers ILMS

Decision utilisateur du 11 octobre 2026 : remplacer le backend OnRender par
le backend ILMS et integrer toutes les fonctionnalites BIBLIORFID dans ILMS.
Les anciennes donnees OnRender ne sont PAS a importer.

Derniere tranche locale : [clients de circulation native](ilms-circulation-client.md).
Le client desktop et son journal sont disponibles en commande ; le mobile
dispose maintenant d'une entree native distincte avec connexion ILMS,
choix de bibliotheque, prets/retours et journal durable a reprise explicite.
La session/interface Electron et le lecteur mobile restent a brancher ;
les entrees historiques ne sont pas basculees. Aucun deploiement ou import.

## Ce qui est annule

- Les modifications de la branche de travail `codex/ilms-auth-contract` ont
  ete restaurees a leur etat initial. Les tests et documents ajoutes pour
  cette approche ont ete supprimes.
- La station temporaire sur le port 4315 est arretee. Sa base de test est
  conservee, sans afficher ni effacer les identifiants saisis par l'utilisateur.
- Aucun commit, push ou changement de production n'avait ete effectue.
- La branche preexistante `ilms-embarque` est conservee : elle ne constitue
  pas la cible de cette migration et ses commits n'ont pas ete annules.

## Architecture cible

- `apps/ilms` devient l'interface metier, avec les fonctions RFID ajoutees
  aux modules Angular existants. Pas d'iframe BIBLIORFID dans ILMS, ni l'inverse.
- `services/library-service` porte les fonctions de catalogue, exemplaires,
  adherents et circulation en reutilisant ses entites et sa base PostgreSQL.
- Les services ILMS existants assurent l'authentification, les medias et
  l'acheminement par la passerelle. Les extensions RFID suivent cette architecture.
- Un agent local reste necessaire pour le lecteur USB/serie, sa DLL Windows,
  la selection TID, l'ecriture et la relecture. Le lecteur n'est pas pilote
  depuis le serveur distant. Les ecrans de pilotage et les resultats sont dans ILMS.
- Le fonctionnement hors ligne doit etre conserve au niveau des appareils :
  file d'operations, identifiants idempotents, conflits et reprise. Changer
  seulement l'URL OnRender ne fournit pas ce contrat.
- Les donnees natives ILMS sont la reference. Les statuts RFID, de circulation
  et d'adhesion sont distincts ; ne pas les fusionner dans un unique statut.

## Inventaire de couverture

| Fonction BIBLIORFID | Base ILMS examinee | Travail a realiser |
| --- | --- | --- |
| Catalogue, exemplaires, recherche, localisation | DocumentController, DocumentCopyController, modules cataloguing | Reutiliser les notices/exemplaires ILMS, ajouter filtres et suivi d'encodage |
| Import XLSX et prevention des doublons | Import et catalogage ILMS a comparer au convertisseur xlsx-import.js | Porter le format BIBLIORFID et son controle de doublons |
| Lecture EPC/TID et reconnaissance | DocumentCopyRfidController, getDocumentCopyByRfid | Raccorder la station et le portail, garantir la portee bibliotheque |
| Encodage/verifications RFID des livres | Champs rfid_code/rfid_tid et index uniques existants | Endpoint dedie, ecran Angular, agent local et reprise des erreurs |
| Abonnes et cartes RFID | MemberController, MembershipCardService, MembershipCard | Reutiliser les adherents, ajouter l'identite RFID de carte et les regles de reattribution |
| Abonnements, expiration, suspension | MembershipCard.registrationDate/expirationDate/status | Comparer les periodes d'abonnement BIBLIORFID aux cartes ILMS ; preserver plusieurs periodes et leurs liens aux prets |
| Prets, retours, retards, registres | LoanController, LoanService, LoanLineDto | Reutiliser la circulation ILMS et porter les parcours au lecteur, regles et filtres |
| Personnel, badges et presence | Gestion employee cote Angular ; equivalent backend RFID non trouve dans library-service | Identifier le service responsable puis ajouter badges et presence |
| Portails, passages, frequentation et alarmes | RfidController actuellement vide, infrastructure WebSocket RFID | Ajouter modeles persistants, evenements, regles antivol et tableaux Angular |
| Appareils, rapports et journal d'activite | DeviceSessionFilter n'est pas un registre BIBLIORFID d'appareils | Ajouter enregistrement, supervision et audit tenant-scopes |
| Synchronisation/offline et notifications | Services ILMS non compatibles avec /api/v1/sync/push et curseurs Ktor | Definir et implementer le nouveau contrat, puis adapter desktop/mobile |
| Catalogage par photos, OCR, notices et UNIMARC | Modules cataloguing et Z3950 existants | Porter photo/lot/brouillons, extraction ISBN, sources BnF/SUDOC et validation |
| Assistance IA facultative et cles | lib/cataloguing/ai.js et reglages locaux | Integrer les cinq roles et le consentement sans exposer les cles aux clients |
| Comptes, roles, historique et parametres | Auth-service, session Angular, securite JWT | Utiliser les roles ILMS et separer autorisations, journal et reglages du lecteur |
| USB/serie/simulation, buzzer et recompilation | ReaderBridge.cs, reader-service.js, reader-timing.js | Conserver le protocole materiel dans l'agent et proposer les commandes dans ILMS |
| Inventaire RFID et rapprochement des livres observes | Mobile inventory_screen.dart ; registration-inventory.service.ts cote ILMS a examiner | Porter les sessions d'inventaire et les resultats de comparaison |
| Localisation par signal/direction RFID | Mobile locator_screen.dart, locator_signal.dart, locator_direction.dart | Conserver les mesures sur l'appareil et integrer recherche/suivi dans ILMS |
| Borne de pret/retour autonome et PIN operateur | Mobile kiosk_controller.dart et kiosk_screen.dart | Porter les parcours et politiques de borne sur la circulation ILMS |
| Import ISBN/CSV, exports CSV et etiquettes de cote PDF | Mobile isbn_csv_import.dart, catalog_exporter.dart, cote_label.dart | Reprendre les formats et les actions dans les ecrans ILMS |
| Logs techniques des appareils | LogRoutes.kt et mobile log_shipper.dart | Ajouter supervision et retention ; proteger la lecture au lieu de recopier les logs publics |

Sources BIBLIORFID : `BiblioRFID/public/index.html`, `BiblioRFID/server.js`,
`BiblioRFID/lib/`, `BiblioRFID/bridge/`, et `BiblioRFID-Sync-API/src/main/`.
Sources mobiles : `Reader/myscankey_flutter/lib/`. Leur synchronisation actuelle
utilise aussi `/api/v1/sync/push`, les curseurs et `X-Device-Key` : elle doit
etre adaptee, pas simplement redirigee vers une URL ILMS.
Le backend OnRender actuel a sept types d'entites synchronisees : book,
subscriber, subscription, loan, staff, gate_day et staff_passage ; il expose
aussi les appareils, leurs comptes sans mots de passe, leur activite et
l'historique des changements.

## Depots de travail

Les changements commencent sur `codex/bibliorfid-to-ilms` :

- SDK : `C:/laragon/www/sdk`.
- Backend : `C:/laragon/www/ilms-migration/services/library-service`.
- Angular : `C:/laragon/www/ilms-migration/apps/ilms`.

Versions de depart : SDK main `90004f7e`, library-service `83a7f3df`,
apps/ilms `9bff4e35`. Les depots GitLab ont ete recopies localement sans
dependance au clone temporaire ; leurs remotes pointent sur GitLab.

## Premier increment backend

Ajout de `PUT /api/v1/libraries/{library_id}/copies/{copy_id}/rfid` dans
library-service (derriere `/api/library-service` depuis Angular).

Corps JSON : `{"rfid_code":"...","rfid_tid":"..."}`.
Les deux identifiants sont obligatoires, hexadecimaux et de longueur paire.
La route cible un exemplaire de la bibliotheque et ne change que son EPC/TID.
Les autres champs et les callbacks de persistance ILMS sont conserves.
Un verrou de ligne PostgreSQL et une transaction protegent la mise a jour
des modifications concurrentes de l'exemplaire.
Une affectation repetee au meme exemplaire est acceptee. Les conflits de tags
retournent 409, l'exemplaire hors bibliotheque retourne 404.
L'ecriture exige un role operateur/admin, pas un simple scope de lecture.
La recherche par TID ne retourne plus un exemplaire d'une autre bibliotheque.

Cet increment n'est pas la migration complete : les appareils parlent encore
a l'ancienne API Ktor jusqu'a l'implementation et la validation du nouveau
contrat. Aucun simple remplacement d'URL ni basculement de production n'a
ete effectue. Aucun paquet Angular embarque n'est installe pour cette approche.

## Ordre de realisation et recette

1. Backend : identite RFID des exemplaires puis cartes/personnel, portails,
   appareils/audit et contrat offline, avec tests d'isolation par bibliotheque.
2. Angular : raccorder les modules existants et ajouter les fonctions manquees
   de station, encodage, portail, suivi et catalogage assiste.
3. Agent/appareils : exposer le protocole materiel local avec acces restreint,
   connecter ILMS et adapter les clients mobiles au nouveau backend.
4. Recette locale : tag livre/carte/badge, pret/retour, alarme, reattribution,
   double ecriture, panne reseau/reprise, droits et absence de doublons.
5. Deploiement ILMS et configuration des appareils uniquement apres recette.
   Ne pas importer les donnees Render ni vider les bases locales implicitement.
   L'arret du service Render en production fera l'objet d'une confirmation.

## Verification du premier increment

`scripts/test-rfid.ps1` dans library-service lance les tests avec Java 21
et Maven. Il utilise les identifiants GitLab deja enregistres sur le poste,
ou les variables `ILMS_MAVEN_USER` et `ILMS_MAVEN_PASSWORD` fournies dans
l'environnement local. Il ne les affiche pas et ne les ecrit pas dans un fichier.
Le fichier Maven versionne ne contient que des references aux variables.
L'environnement du processus appelant est restaure apres l'execution.

Le premier essai sans authentification n'a pas resolu le parent Maven prive.
Son acces a ensuite ete confirme avec la connexion GitLab locale (HTTP 200),
et le telechargement Java a fonctionne en TLS 1.2 sans desactiver la verification
des certificats.

Resultats du 11 octobre 2026 : compilation des 1000 fichiers Java du backend
reussie ; neuf nouveaux tests RFID passes via `scripts/test-rfid.ps1` ; puis
suite complete executee par Surefire, dix tests passes sur dix (dont le test
AppTest preexistant). `git diff --check` et la syntaxe du script PowerShell
sont valides.

Les tests RFID utilisent un repository simule. Ils ne valident pas encore
la transaction/verrou sur PostgreSQL reel, les droits HTTP avec un vrai JWT,
les callbacks Elasticsearch ni le lecteur physique. Ces verifications et
les autres fonctions du tableau restent necessaires avant un basculement.
Le POM existant avertit aussi que la version du plugin Spring Boot n'est
pas fixee ; ce point preexistant doit etre traite avant la livraison.

Cette premiere tranche a ete suivie du volet cartes d'abonne ci-dessous.

## Deuxieme tranche : cartes d'abonne natives ILMS

### Backend

- `MembershipCard` conserve les champs `code`, `number`, les dates et le
  statut existants. Deux nouveaux champs independants, `rfid_code` et
  `rfid_tid`, accueillent l'EPC et le TID. Aucune ancienne valeur n'est
  importee ou convertie automatiquement.
- La nouvelle migration Liquibase ajoute uniquement ces colonnes et leurs
  contraintes : EPC unique par bibliotheque, TID unique entre cartes.
  Elle inclut un rollback de schema, mais n'a pas ete appliquee a une base.
- `GET /api/v1/libraries/{library_id}/members/{member_id}/membership-card`
  lit la carte actuellement rattachee au membre directement en PostgreSQL,
  sans dependre d'un ancien index Elasticsearch.
- `GET /api/v1/libraries/{library_id}/membership-cards/by-rfid?epc=...&tid=...`
  cherche par TID puis EPC dans la bibliotheque. Les cartes supprimees sont
  exclues. Un tag inconnu renvoie un corps vide.
- `PUT /api/v1/libraries/{library_id}/membership-cards/{card_id}/rfid`
  exige deux identifiants hexadecimaux, normalise leur casse, verrouille la
  carte et ne modifie que les champs RFID. Les conflits deviennent des 409.
- Les modifications ordinaires d'adhesion preservent les champs RFID.
- Les trois routes exigent un role operateur. Une carte inactive ou expiree
  reste identifiable, mais cette recherche n'autorise jamais un emprunt.
- Le gestionnaire d'erreurs ILMS preserve maintenant les statuts explicites
  des `ResponseStatusException` et traduit les refus de methode en 403.
  Cela corrige aussi les reponses d'erreur de l'API RFID des exemplaires.

### Angular

- La fiche lecteur contient une section native "Carte RFID" : numero,
  statut, expiration, EPC et TID, actualisation et enregistrement.
- Le formulaire valide les identifiants, bloque les doubles envois,
  conserve la saisie apres un conflit et annule les requetes obsoletes
  quand le lecteur change. Les erreurs utilisent le type `ApiError` ILMS.
- Le service ne lance aucune requete sans bibliotheque selectionnee ni
  depuis la vue globale `all`. Il utilise les routes du gateway ILMS.
- Cette section enregistre une association en base, pas une ecriture
  physique sur la puce. Le raccordement du lecteur reste a developper.
- `npm run start:local` sert l'application sur `http://127.0.0.1:4200/`
  avec un proxy vers un gateway local sur le port 8081. Ce demarrage
  n'utilise pas le proxy de production. Aucun gateway local n'est lance
  dans cette tranche : la connexion reelle n'est donc pas encore testable.
- `npm run test:rfid` utilise une configuration TypeScript ciblee.
  La suite Angular generale est bloquee par un test deja present dans
  `_services/svg-pipe/safe-html-svg.pipe.spec.ts`, qui omet son
  `DomSanitizer`. Ce fichier n'a pas ete modifie.

### Verifications Et Limites

Resultats du 11 octobre 2026 :

- Compilation Java reussie ; suite complete de 41 tests passee : neuf tests
  exemplaires, seize cartes, onze routes HTTP, quatre autorisations
  reactives et le test `AppTest` preexistant.
- Les tests WebFlux controlent les vrais mappings HTTP, la validation des
  corps et les statuts 400/404/409/403/500 avec le gestionnaire ILMS.
  Les tests de securite activent les intercepteurs Spring de methode :
  un simple scope `read` ne peut ni affecter un tag ni lire une identite
  d'abonne ; le role `librarian` peut atteindre le service.
- Compilation Angular de developpement et de production reussie.
  Les avertissements existants Sass, CommonJS et certains templates restent.
  Le build signale aussi une feuille `/assets/css/style.css` a controler
  dans l'environnement de deploiement.
- Les 17 tests Angular RFID passent dans Edge headless, avec
  l'intercepteur de reponse ILMS inclus dans les tests du service.
- Playwright a controle la vraie fiche lecteur avec des reponses API
  simulees, un compte fictif local et toutes les sorties reseau externes
  bloquees : affichage desktop 1440x1000, mobile 390x844 et 320x844,
  enregistrement, conflit, conservation de saisie, absence de debordement
  du panneau et chargement de la photo par defaut.
- Captures et script de verification locale :
  `C:\laragon\www\ilms-migration\.tools\rfid-desktop.png`,
  `rfid-mobile-390.png`, `rfid-mobile-320.png`, `verify-rfid-ui.cjs`.
  Ce script depend du Playwright deja installe dans le SDK local.
- Le XML de migration et `git diff --check` sont valides. Les tests Java
  utilisent des repositories/services simules : ils ne remplacent pas une
  recette de transaction/verrou sur PostgreSQL ni l'application Liquibase.
- Les contraintes d'unicite des exemplaires et des cartes sont encore
  separees : l'exclusivite d'une meme puce entre livre, carte et badge doit
  etre traitee avant une mise en production.
- Le filtrage des entites par bibliotheque et les roles operateur sont
  controles. L'autorisation d'un compte pour une bibliotheque precise,
  les JWT reels, PostgreSQL/Liquibase et le materiel restent a verifier
  ensemble dans un environnement ILMS isole.
- A ce stade, la bascule des clients desktop/mobile, les emprunts par lecteur,
  abonnements multiples, badges/presences, portail, agent materiel,
  import/catalogage assiste et synchronisation native ne sont pas encore
  livres. Aucune URL OnRender n'a ete remplacee dans les clients existants.

La migration globale reste en cours. Aucun push, deploiement ni changement
sur les donnees de production n'a ete effectue. Le SDK conserve son code
de depart, avec seulement ce document ajoute ; les changements fonctionnels
sont dans les deux depots ILMS de la branche `codex/bibliorfid-to-ilms`.

## Troisieme tranche : prets et retours RFID natifs ILMS

### Backend

Base des quatre nouvelles routes POST :
`/api/v1/libraries/{library_id}/circulation/rfid`.
Elles exigent les memes roles operateur que les associations RFID.

| Route | Corps JSON | Resultat |
| --- | --- | --- |
| `/members/resolve` | `{"epc":"AA12"}` ou `{"tid":"BB34"}` | Identite minimale, eligibilite et raison de refus |
| `/copies/resolve` | Meme format EPC/TID | Exemplaire exact, titre, couverture, disponibilite et pret actif |
| `/checkouts` | `operation_id` UUID, `card` et `copy` au format EPC/TID, `preferred_return_date` ISO UTC | Pret natif confirme, HTTP 201 |
| `/returns` | `copy` au format EPC/TID et `loan_id` UUID confirme | Pret natif retourne, HTTP 200 |

- EPC et TID peuvent etre fournis ensemble ; chaque identifiant fourni doit
  correspondre au tag enregistre. Un TID incorrect ne peut pas etre ignore
  au profit d'un EPC correspondant. La recherche reste dans la bibliotheque.
- Le pret exige la carte actuelle du membre, un membre et une carte actifs,
  des dates d'adhesion valides et une echeance future. Un exemplaire doit
  etre libre, active, publie, circulable et sans pret actif ou en attente.
- Le parcours utilise `LoanServiceHelper` et `LoanStatusService` pour creer
  puis confirmer le pret de l'exemplaire scanne, et non le premier exemplaire
  disponible de la notice. Il ne cree pas une seconde table de circulation.
- Carte, membre, exemplaire et pret sont verrouilles dans la transaction.
  La transition interne rejoint cette transaction au lieu de vider un
  tampon d'evenements Elasticsearch dans une transaction imbriquee.
- Un UUID d'operation et une empreinte SHA-256 du corps sont conserves sur
  le pret. Une reprise avec le meme UUID et le meme corps retrouve le pret
  sans le recreer ni republier l'evenement d'interaction. Un corps different
  avec le meme UUID renvoie 409. Les conflits concurrents demandent une
  reprise avec la meme demande ; l'interface conserve son UUID en memoire.
- Un retour accepte les prets confirmes, renouveles et en retard. Il
  n'exige ni carte ni adhesion active. Il confirme l'UUID du pret affiche,
  pas seulement l'exemplaire : rejouer un ancien retour ne doit jamais
  restituer un nouveau pret de cet exemplaire.
- Deux erreurs du chemin natif partage sont corrigees : la disponibilite
  utilise maintenant `loan.copyId` au lieu de `loan.id`, et l'historique
  conserve le statut precedent avant mutation. Les reservations restent
  traitees par le service existant lors de la liberation d'un exemplaire.

### Schema Et Recette

La migration `V1__2026_10_11_0002_add_rfid_loan_operations.xml` ajoute
`rfid_operation_id` et `rfid_request_hash` a `loans`, une contrainte unique
par bibliotheque/operation et un index PostgreSQL empechant plusieurs prets
actifs d'un meme exemplaire (statuts 0, 1, 5 et 6, hors lignes supprimees).
Ces champs restent nuls pour les prets ILMS existants.

Une precondition arrete la migration si des doublons actifs existent deja
dans ILMS. Les lignes sans exemplaire ne sont pas des doublons de copies.
Elle ne supprime ni ne corrige les anciennes lignes. Auditer et
resoudre ces cas avant application ; ne pas appliquer le schema en production
sans sauvegarde et recette. Le rollback de schema est fourni. Aucun import
OnRender n'est prevu, et cette migration n'a pas encore ete appliquee.

### Angular

- Nouvelle entree "Circulation RFID" dans le menu Circulation, avec route
  `/admin/libraries/{library_id}/circulation/rfid` reservee aux operateurs.
- Modes pret/retour, recherche EPC ou TID, identite et statut d'adhesion,
  exemplaire, couverture, pret actif, echeance et confirmation explicite.
- Les saisies modifiees invalident les resultats precedents et annulent
  les recherches obsoletes. Le changement de bibliotheque vide le poste.
  Une bibliotheque selectionnee differente de celle de la route bloque
  les operations. Les doubles clics sont bloques pendant l'envoi.
- L'erreur reseau conserve les identifiants et l'UUID d'operation pour
  reessayer la meme demande. Un changement de corps cree un nouvel UUID.
  L'UUID n'est pas encore persiste apres fermeture/rechargement du navigateur :
  la file durable et le contrat offline des appareils restent a construire.
- Le retour n'affiche pas le formulaire de carte et reste independant de
  l'echeance de pret masquee. Le recu confirme le numero de pret ILMS.
- Les identifiants sont saisis dans le poste ; le lecteur physique et les
  fonctions de borne autonome/PIN ne sont pas raccordes dans cette tranche.

### Verifications

Resultats du 11 octobre 2026 :

- Compilation des 1009 fichiers Java reussie et suite complete de 82 tests
  passee, dont 22 tests du service RFID, huit tests du chemin de statut natif,
  huit tests HTTP de circulation et sept tests d'autorisation reactive.
- Les tests HTTP utilisent les vrais mappings, la validation imbriquee,
  le gestionnaire d'erreurs ILMS et les DTO natifs. Ils couvrent notamment
  les identifiants absents/non hexadecimaux, le pret sans UUID et le retour
  sans UUID de pret, ainsi que les statuts 201/200/400/404/409.
- Les 40 tests Angular RFID passent dans Edge headless : cartes et nouveau
  poste, avec intercepteur ILMS dans les tests des services.
- Deux passages complets de ces 40 tests ont reussi. Une relance supplementaire,
  apres ajout d'une assertion sur la methode POST et simplification de la
  commande npm vers un seul motif, a ete arretee pendant le demarrage sur
  un poste ayant moins de 500 Mo de memoire libre. Le dernier changement du
  test et cette commande npm ont ensuite ete rerun avec succes dans la
  quatrieme tranche ; le meme motif avait deja reussi avec la CLI Angular directe.
- Les builds Angular de developpement et de production passent. Les
  avertissements preexistants Sass/CommonJS/templates et la feuille
  `/assets/css/style.css` restent a traiter pour le deploiement.
- Le XML des migrations et `git diff --check` sont valides ; la lecture XML
  n'est pas une application ni une validation du schema sur PostgreSQL.
- Playwright a teste la vraie route Angular avec des API simulees, un
  compte local fictif et les sorties reseau externes bloquees : desktop
  1440x1000, mobiles 390x844 et 320x844, couverture chargee, controles sans
  debordement, premier envoi en erreur puis reprise avec corps/UUID identiques,
  retour sans recherche d'adherent et pret bloque pour adhesion expiree.
- Captures locales : `C:/laragon/www/ilms-migration/.tools/circulation-desktop.png`,
  `circulation-mobile-390.png`, `circulation-mobile-320.png`,
  `circulation-return.png`. Script : `.tools/verify-circulation-ui.cjs`.

Les repositories et les API de la recette sont simules. PostgreSQL reel,
application Liquibase, concurrence et rollback, callbacks Elasticsearch,
droits d'un compte sur une bibliotheque precise, JWT reels et lecteur
physique restent a valider avant livraison. Le poste Angular est servi sur
`http://127.0.0.1:4200/`, mais aucun backend/gateway local n'est lance :
la connexion metier reelle n'est pas encore disponible.

Cette tranche ne livre pas encore toutes les fonctions BIBLIORFID : agent
materiel/encodage, exclusivite des tags entre entites, contrats appareils
et offline, badges/presences, portails/alarmes, inventaires/localisation,
imports/catalogage assiste et bascule desktop/mobile restent au tableau
de migration. Aucun push, deploiement, remplacement d'URL OnRender ou
changement sur les donnees de production n'a ete effectue.

## Quatrieme tranche : droits par bibliotheque et exclusivite des tags

### Autorisations Natives

- Toutes les routes RFID des exemplaires, des cartes et de circulation
  exigent maintenant une autorisation explicite du compte sur la bibliotheque.
  Le role operateur reste necessaire : un scope de lecture ou une autorisation
  seule ne suffit pas. L'identite UUID vient du JWT authentifie, pas du corps
  envoye par le client. Un compte sans identite exploitable est refuse.
- Les roles operateur acceptes restent ceux d'ILMS : `ADMIN`, `SUPER_ADMIN`,
  `administrator` et `librarian`. Seul `SUPER_ADMIN` peut gerer les autorisations
  et agir sans affectation explicite, sur une bibliotheque existante non supprimee.
- La migration `V1__2026_10_11_0003_create_library_rfid_operators.xml`
  ajoute `library_rfid_operators`, avec unicite bibliotheque/compte, auteur et
  date d'octroi. Aucune autorisation n'est accordee automatiquement.
- L'API de gestion est sous `/api/v1/libraries/{library_id}/rfid/operators` :
  `GET` liste les autorisations, `PUT /{user_id}` accorde l'acces et
  `DELETE /{user_id}` le retire. Le PUT sans corps est idempotent et conserve
  l'auteur et la date de l'octroi initial ; le DELETE repete renvoie 204.
- Pour preparer la recette ILMS, un super-administrateur doit accorder
  l'acces a l'UUID du compte operateur deja existant, dans chaque bibliotheque
  concernee. Les appels Angular utilisent `/api/library-service`, prefixe
  local du portail ; le proxy le traduit en `/library-service` sur le gateway.
  Aucun mot de passe ni JWT ne doit etre ajoute au depot ou au chat.
- Ce registre ne duplique pas l'IAM : il ne cree pas de compte, ne change
  pas ses roles et ne verifie pas son existence dans auth-service.
  L'UUID cible doit donc etre celui d'un compte ILMS connu. La gestion
  graphique est maintenant ajoutee ci-dessous. Un historique des revocations
  reste a ajouter ; les controles serveur sont actifs.

### Protection Des Ecritures

- La creation/import, la modification RFID et la suppression d'un exemplaire
  tague via le catalogue ordinaire exigent aussi l'autorisation RFID.
  Une route generique ne permet donc pas de contourner la route dediee.
  La creation et la suppression d'un exemplaire sans tag restent natives.
- Une modification de metadonnees conserve les champs RFID omis ou nuls.
  Une chaine vide demande explicitement leur effacement et exige l'autorisation.
  L'EPC et le TID non modifies restent conserves independamment.
- Le mapper de mise a jour ne recopie plus les champs RFID implicitement.
  Les modifications et suppressions d'exemplaires verrouillent leur ligne,
  de meme que les changements natifs de disponibilite, pour ne pas restaurer
  des tags obsoletes lors d'une ecriture concurrente.
- La migration `V1__2026_10_11_0004_share_rfid_tag_ownership.xml` ajoute
  un registre technique `rfid_tag_owners` maintenu par des triggers PostgreSQL
  sur les deux tables natives. Les exemplaires et cartes restent les entites
  metier : ce registre ne les remplace pas.
- Un TID ne peut appartenir qu'a un livre OU une carte, toutes bibliotheques
  confondues. Un EPC est exclusif entre ces deux types dans une bibliotheque.
  Les contraintes couvrent aussi les ecritures concurrentes et les imports SQL.
- Les nouvelles ecritures normalisent casse/espaces et refusent les tags
  non hexadecimaux ou de longueur impaire. Les recherches et leurs index
  normalisent aussi les anciennes valeurs ILMS conservees dans les tables.
- Une suppression logique conserve la reservation du tag. Une suppression
  physique, un effacement explicite ou une reaffectation libere les anciens
  identifiants dans la meme transaction ; un rollback restaure l'ensemble.
- Les tags deja presents dans ILMS sont references sans importer Render.
  Les preconditions arretent la migration si ces donnees sont invalides ou
  en conflit, y compris apres normalisation. Aucun doublon n'est supprime
  automatiquement. Les badges du personnel ne sont pas encore couverts.

### Recette PostgreSQL Et Limites

Resultats du 11 octobre 2026 :

- Compilation Java reussie et suite complete de 121 tests passee sans
  echec, apres le correctif de verrou sur les changements de disponibilite.
- La commande `npm run test:rfid` passe maintenant ses 62 tests dans Edge
  headless : les 40 tests de cartes/circulation precedents et 22 tests
  supplementaires de gestion des autorisations. La relance precedemment
  interrompue est donc terminee, avec l'assertion POST et le motif npm actuels.
- Le build Angular de production est relance et reussit apres les derniers
  correctifs de formulaire et de mise en page. Les avertissements preexistants
  Sass/CommonJS/templates et la feuille `/assets/css/style.css` restent a traiter.
  La suite Angular generale n'a pas ete validee ; son ancien test de pipe
  incomplet reste hors du perimetre de cette tranche.
- Vingt tests d'integration passent sur PostgreSQL 17.6 reel, dans une
  instance portable temporaire liee seulement a `127.0.0.1:55432`.
  Elle a ete arretee apres la recette. Les bases existantes n'ont pas ete
  ouvertes ou modifiees ; les schemas de test utilisent des donnees fictives.
- Liquibase applique les quatre migrations RFID sur des tables de fixture
  representant les colonnes concernees : cartes, operations de pret,
  autorisations et registre partage. Les rollbacks sont executes aussi.
  Cela n'est pas une application du changelog ILMS complet en production.
- La recette verifie les conflits livre/carte, les anciens doublons bloquants,
  la normalisation, les tags invalides, la concurrence entre deux connexions,
  le verrou d'un exemplaire et la restauration transactionnelle des tags.
- Elle verifie aussi l'unicite des autorisations, leur retrait par bibliotheque,
  l'unicite des UUID d'operation, les quatre statuts de pret actif, la liberation
  apres retour et l'absence de blocage pour les prets sans exemplaire.
- Les tests de service et HTTP ajoutent des refus avant acces aux donnees,
  l'isolation des comptes/bibliotheques, l'absence d'identite JWT, la gestion
  reservee au super-administrateur et la protection du catalogue ordinaire.
- `scripts/test-rfid.ps1 -Offline` permet de reutiliser le cache Maven sans
  demander les identifiants GitLab. `-Postgres` lance uniquement
  `RfidPostgresIT`, exclu de la suite ordinaire, apres preparation d'une
  base de test isolee. Le script ne demarre pas PostgreSQL lui-meme.
- `RFID_TEST_DATABASE_URL` doit avoir la forme
  `jdbc:postgresql://127.0.0.1:PORT/nom_rfid_test` ou utiliser `localhost`.
  Les URL distantes, avec parametres ou credentials, et les noms sans ce
  suffixe sont refuses. Utiliser seulement une base jetable reservee aux tests.
  `RFID_TEST_DATABASE_USER` et `RFID_TEST_DATABASE_PASSWORD` restent dans
  l'environnement local. Java 21 est requis ; le cache Maven peut etre fourni
  via `-MavenRepository` et l'executable via `-MavenCommand`.

### Administration Angular

- L'ecran existant "Ma bibliotheque", route
  `/admin/libraries/{library_id}/management/my-library`, contient maintenant
  un onglet "Acces RFID" visible seulement pour `SUPER_ADMIN`.
- La liste affiche l'UUID du compte, celui de l'auteur de l'autorisation
  et la date d'octroi. L'ajout normalise et valide un UUID de compte ILMS
  connu ; il n'affiche ni ne modifie les mots de passe ou les roles IAM.
- Une confirmation explicite precede le retrait. Les requetes doubles sont
  bloquees, les erreurs conservent la saisie ou la confirmation pour reprise,
  et une autorisation repetee ne cree pas de ligne en double dans la liste.
- Le changement de bibliotheque annule les demandes precedentes, vide les
  resultats et la saisie, puis recharge apres la navigation. La vue globale
  `all`, une route differente de la bibliotheque courante et les autres roles
  ne lancent aucune demande de gestion. Les controles serveur restent requis.
- Les 22 nouveaux tests couvrent ces etats, les methodes HTTP natives
  GET/PUT/DELETE, le PUT sans corps et le statut 403 preserve par
  l'intercepteur ILMS, ainsi que la soumission du formulaire depuis le DOM.
  Aucune nouvelle API de compte n'a ete inventee.
- Playwright a controle le vrai onglet Angular avec des comptes fictifs,
  des reponses API simulees et les sorties reseau externes bloquees :
  desktop 1440x1000, mobiles 390x844 et 320x844, UUID invalide, ajout puis
  erreur/reprise sur le meme compte, confirmation et annulation du retrait,
  suppression d'une seule ligne et onglet absent pour un bibliothecaire.
  Les controles et la confirmation restent dans leur conteneur, sans
  debordement. Aucune erreur JavaScript n'a ete relevee dans ce parcours.
- La recette a permis de corriger le raccordement du formulaire a un
  `FormGroup` et la largeur minimale des boutons imposee par le theme ILMS.
  Les correctifs sont verifies par les tests et le navigateur.
- Captures locales : `C:/laragon/www/ilms-migration/.tools/rfid-operators-desktop.png`,
  `rfid-operators-mobile-390.png`, `rfid-operators-mobile-320.png` et
  `rfid-operators-confirmation-mobile-320.png`. Script :
  `.tools/verify-rfid-operators-ui.cjs` (Playwright du SDK local).

Les limites des tranches precedentes restent historiques : l'autorisation
par bibliotheque et l'exclusivite livre/carte sont maintenant implementees,
et les migrations RFID ont une recette PostgreSQL reelle. Restent a valider
les JWT signes et roles en bout en bout via le gateway, les transactions
reactives et callbacks Elasticsearch avec les services ILMS complets,
ainsi que le lecteur physique. Aucun backend/gateway local n'est demarre.

La tranche suivante ci-dessous commence l'extraction de l'agent materiel
et le registre des appareils. Badges/presences, portails/alarmes,
inventaires/localisation, imports et catalogage assiste restent dans
l'inventaire. La migration complete et la bascule des clients ne sont pas
terminees. Aucun push, deploiement ni remplacement d'URL Render n'a ete
effectue.

## Tranche 5 : registre ILMS et agent local de lecture

### Backend natif

- Nouveau registre `library_rfid_devices`, migration 0005 incluse dans le
  master. Aucune donnee du backend Render n'est reprise.
- API `/api/v1/libraries/{library_id}/rfid/devices` : GET collection/fiche
  avec les permissions RFID existantes ; PUT fiche par SUPER_ADMIN.
  Nom, transport USB/serie/TCP et statut actif requis. Auteur et dates de
  creation/modification issus de l'identite ILMS, pas du corps HTTP.
- UUID station global, reserve a une bibliotheque, meme quand desactive.
  UPSERT atomique refuse le changement de bibliotheque sans divulguer
  laquelle detient l'identifiant. PUT garde l'audit de creation.
- Pas de nouvelle IAM, mot de passe, cle partagee Render, ni assimilation
  du cookie DeviceSession au droit de piloter un lecteur.

### Agent extrait du SDK

- `npm run agent:ilms` lance `ilms-agent.js`, separe de `server.js` : aucune
  base catalogue locale ni initialisation de synchronisation Render.
- Reutilise le pont C# et `ReaderService` ; n'ouvre pas le lecteur au
  demarrage. Connexion explicite USB, port COM ou IP TCP privee.
- HTTP loopback IPv4 uniquement, Host exact, origine navigateur exacte et
  cle locale 32 octets obligatoire. Comparaison constante de la cle ;
  aucune cle en URL, cookie, reponse ou journal. CORS et preflight restreints.
- Capacite lecture uniquement, commandes connect/disconnect et polling des
  tags. Session changee a chaque connexion ; tampon borne 256 scans/30 s,
  curseur avec perte explicite et filtre de doublons. Plusieurs tags ne
  deviennent pas une selection automatique.
- Pas d'encodage/effacement ni d'operation de circulation exposee par cet
  agent. Les details des erreurs natives restent locaux.
- `ReaderService` a maintenant un delai de demarrage borne, rejette une
  sortie avant le message ready et ignore un ancien processus apres une
  reprise. Le protocole C# et les appels existants sont conserves.
- Contrat, securite, demarrage et limites : `docs/ilms-reader-agent.md`.

### Verification

- 135 tests Java passes, dont 13 nouveaux tests HTTP pour les appareils et
  le parsing Liquibase de la migration 0005.
- 23 tests PostgreSQL passes sur la base locale isolee (20 precedents +
  3 appareils). Le vrai repository R2DBC a execute les UPSERT, lectures et
  deux creations concurrentes dans des bibliotheques distinctes : un seul
  proprietaire final. Audit de creation conserve, desactivation/reprise,
  contraintes SQL et rollback verifies.
- 96 tests Node passes, dont 26 pour l'agent et le cycle de vie du pont.
- Edge a effectue de vrais appels inter-origines vers l'agent loopback avec
  lecteur simule et reseau externe bloque : preflight, lecture, rejet d'une
  cle invalide et d'une origine hostile, absence de route d'ecriture.
- Le vrai `ReaderBridge.exe` Windows a confirme ready, statut deconnecte
  et arret. Aucune connexion materielle ni ecriture effectuee.
- Journaux locaux `.tools/rfid-devices-java-tests.log`,
  `rfid-devices-postgres-tests.log` et `rfid-agent-sdk-final-tests.log`.
  Base PostgreSQL de recette arretee apres verification.
- Aucun code Angular n'a ete modifie dans cette tranche. L'ancien apercu
  a ete suspendu pendant les tests pour liberer la memoire. Un premier
  redemarrage a echoue avec `The service was stopped` alors que la memoire
  libre restait faible. Une relance a un worker, heap Node 1024 Mo et limite
  de memoire Go a finalement abouti ; HTTP 200 confirme sur
  `http://127.0.0.1:4200/`. Le gateway local reste a demarrer. Journaux :
  `.tools/angular-agent-lowmem-preview.out.log` et `.err.log`.

### Limites et suite

Ce bilan est celui de la tranche 5 ; le raccordement Angular decrit comme
restant ci-dessous est maintenant traite dans la tranche 6.

Le registre et l'agent sont un socle teste, pas encore une connexion
complete de l'interface Angular au lecteur. Restent le formulaire
d'appairage local, le choix d'appareil autorise, les controles de connexion
et l'utilisation explicite des scans dans la station ILMS. Une fiche
desactivee ne coupe pas encore l'agent ; l'UUID ne prouve pas une identite
materielle. Les parcours RFID manuels actuels restent independants.

La prochaine etape raccorde ces controles dans Angular, puis la reprise
durable/offline et les fonctions restantes de l'inventaire. Le gateway et
les services complets ne sont pas demarres ; JWT signe et lecteur physique
restent a valider. Aucun push, deploiement, import Render ou basculement
des clients existants n'a ete effectue.

## Tranche 6 : appareils et lecture dans Angular ILMS

### Administration et appairage

- Onglet natif `Appareils RFID` reserve au SUPER_ADMIN : liste, creation,
  modification du nom/transport et activation/desactivation avec
  confirmation. Seules les metadonnees sont envoyees a l'API ILMS.
  L'UUID reste celui du registre ; aucune cle locale n'y est stockee.
- La station de circulation propose les appareils actifs de la
  bibliotheque courante. L'operateur saisit une adresse loopback IPv4
  avec port explicite et une cle locale masquee de 32 octets.
- Verification de la fiche ILMS et de l'identite declaree par l'agent avant
  appairage. La cle est retiree du formulaire apres validation et conservee
  seulement en memoire. Les appels locaux passent directement par
  `HttpBackend` : ni JWT ILMS, ni cookies, ni intercepteurs de session.
- Connexion materielle explicite apres appairage. Une session deja ouverte
  par un autre client n'est pas adoptee. Le transport vient du registre ;
  l'endpoint USB/COM/TCP reste local et n'est pas envoye au backend.
- Statut actif et permissions recontroles toutes les cinq secondes et
  avant chaque utilisation d'un tag. Desactivation, changement de
  transport, perte de curseur, erreur de lecture ou changement de
  bibliotheque invalident l'appairage et les scans. Les requetes en attente
  et le polling sont annules ; la cle est oubliee a la sortie de page ou
  lors de la fermeture de la session ILMS.

### Circulation

- Au plus 16 tags recents affiches, sans selection automatique. Choix
  explicite comme carte ou exemplaire, resolution par les API natives,
  puis confirmation distincte du pret/retour. Le mode retour ne propose
  pas de choix de carte.
- Les selections issues du lecteur expirent apres 30 secondes. La perte
  de session efface ces selections, sans toucher aux champs manuels ni
  annuler une operation de circulation deja envoyee.
- Apres un resultat de pret incertain, une nouvelle lecture du meme
  contenu conserve l'UUID d'operation en memoire, pour utiliser
  l'idempotence du backend. Ce mecanisme n'est pas une file offline durable.

### Verification

- 115 tests Angular RFID passes, dont 53 nouveaux tests : services
  appareils/agent, administration, cycles d'appairage et interaction avec
  la station. La verification TypeScript ciblee passe aussi.
- Compilation Angular de production reussie. Les avertissements existants
  Sass/CommonJS/templates et la feuille `/assets/css/style.css` manquante
  restent hors du perimetre. La suite generale ILMS n'a pas ete revalidee.
- Journal : `.tools/rfid-angular-agent-final-tests.log`. Les avertissements
  Karma sur l'image de couverture concernent l'environnement de test ; la
  recette navigateur verifie separement le chargement de cet asset.
- Journal de compilation : `.tools/rfid-angular-agent-production-build.log`.
- Recette Edge/Playwright du vrai Angular et du vrai agent HTTP loopback,
  avec lecteur simule, donnees ILMS fictives et reseau externe bloque :
  creation d'appareil, confirmation/annulation de desactivation, reprise,
  appairage sans connexion automatique, connexion explicite et scans
  multiples sans resolution ni pret automatiques. Les appels locaux ne
  portent que la cle locale ; aucune cle en URL ou stockage navigateur.
- Pret : premiere reponse simulee incertaine (500), perte de session,
  appairage/relecture puis reprise avec le meme UUID et le meme contenu.
  Retour : carte non proposee, exemplaire et UUID du pret confirmes,
  statut actif 6 accepte. Desactivation du registre detectee par polling,
  scans et cle effaces, appareil retire des choix actifs.
- Desktop 1440x1000 et mobiles 390x1000/320x1000 controles dans le navigateur,
  sans debordement des nouveaux panneaux/controles. Couverture de livre
  chargee et decodee ; aucune erreur JavaScript dans ce parcours.
  L'onglet d'administration est absent pour le compte bibliothecaire.
- Script `.tools/verify-rfid-agent-ilms-ui.cjs`, journal
  `rfid-angular-agent-browser.log`, captures `rfid-devices-{largeur}.png`
  et `rfid-agent-station-{largeur}.png`. Le test attend le rendu Angular
  lors du passage pret/retour avant de verifier la disparition des cartes.
- Apercu local redemarre, HTTP 200 confirme : `http://127.0.0.1:4200/`.
  Proxy local conserve ; aucun gateway/backend ILMS n'est demarre par
  cette recette. Journaux `rfid-agent-ui-preview.out.log` et `.err.log`.

### Limites

La desactivation bloque la consommation de scans par cette interface,
mais ne coupe pas physiquement un agent deja connecte. Quitter la page
efface la cle sans envoyer de commande materielle en arriere-plan ; la
deconnexion du lecteur est une action explicite, qui conserve l'appairage
pour une reconnexion. Oublier l'appairage efface la cle. L'UUID declare par
l'agent ne constitue pas une attestation materielle.

JWT signes et permissions via le gateway complet, lecteur physique et
reprise durable/offline restent a valider ou implementer. Badges/presences,
portails/alarmes, inventaires/localisation, imports et catalogage assiste
restent dans l'inventaire. Aucun push, deploiement, import Render ni
basculement des clients existants n'est effectue dans cette tranche.

## Tranche 7 : journal durable de circulation Angular

### Perimetre

Cette tranche remplace la seule reprise en memoire de la station par un
journal local de demandes de pret/retour. Elle reutilise les routes natives
et leur idempotence, sans creer une seconde base de prets ni recopier le
contrat Ktor `/sync/push`. Le backend ajoute les identites attendues au
contrat de pret ; les anciens clients ne sont pas modifies. Aucune donnee
Render n'est importee.

- Avant tout envoi, la demande confirmee est ecrite dans IndexedDB
  (`ilms-rfid-outbox-v1`, store `operations`) et la transaction read/write
  a durabilite stricte doit avoir termine. Un echec du journal bloque le
  nouvel envoi. Pas de fallback silencieux vers la memoire ou localStorage.
- Cle de portee compte ILMS + bibliotheque : UUID valides, session ouverte
  et role operateur requis. Ces controles sont repetes apres les etapes
  asynchrones, avant HTTP. Une lecture locale tardive ne revient pas au
  compte suivant. Le serveur reste l'autorite pour les permissions.
- Donnees minimales : UUID local, portee, type, EPC/TID necessaires, UUID
  d'operation de pret et UUID de carte/adherent/exemplaire confirmes, ou
  UUID du pret a restituer, echeance d'origine,
  dates/compteur/statut de reprise et verrou. Aucun nom, titre, mot de
  passe, JWT, corps d'erreur serveur ni cle d'agent n'est conserve.
- L'UUID et le contenu du pret restent identiques apres rechargement.
  Reconfirmer les memes tags/echeance retrouve la demande existante au
  lieu de generer une nouvelle operation. Le retour garde exclusivement
  le tag et l'UUID du pret confirme : il ne vise pas un pret plus recent.
- Une date d'echeance devenue passee n'est pas corrigee pendant la reprise.
  Le backend peut reconnaitre un pret deja cree avant de verifier cette
  date ; si la creation n'a pas eu lieu, il refuse la demande devenue
  invalide. Une autre demande exige une decision de l'operateur.
- Les champs `expected_card_id`, `expected_member_id` et `expected_copy_id`
  lient le pret aux entites vues lors de la confirmation. Le backend
  controle ces UUID sur les lignes verrouillees avant creation : une puce
  reattribuee ne peut pas faire emprunter un autre exemplaire ni affecter
  le pret a un autre adherent. Les trois champs sont fournis ensemble et
  entrent dans l'empreinte d'idempotence. Le client controle aussi les
  UUID adherent/exemplaire de la reponse avant acquittement local.
- Les appels historiques sans ces champs conservent leur empreinte native.
  En revanche, le journal Angular refuse tout nouveau pret sans les trois
  UUID. Une ancienne demande locale tag-only reste visible/retirable mais
  son renvoi est bloque, sans lui attribuer les identites actuelles du tag.
  Deployer le backend supportant ce contrat avant d'activer le journal
  sur les clients ; aucun deploiement n'est effectue par cette tranche.

### Reprise et concurrence

- Apres coupure, erreur reseau, resultat inconnu ou rechargement, la liste
  native `Operations a reprendre` affiche le contenu et l'etat local.
  Identifiants de carte/exemplaire et echeance d'origine sont consultables
  avant reprise. Aucun pret/retour n'est declare reussi sans reponse ILMS.
- Pas de renvoi automatique au demarrage ni sur l'evenement online :
  chaque demande est reprise explicitement. Les erreurs 4xx definitives
  restent visibles comme refus ; erreurs reseau, 408/425/429 et 5xx restent
  des demandes en attente. Les corps d'erreur ne sont pas persistes.
- Verrou de 120 secondes acquis par transaction IndexedDB atomique : deux
  onglets/connexions ne peuvent pas envoyer simultanement la meme demande.
  L'appel HTTP est borne a 30 secondes. Un arret brutal laisse le verrou
  jusqu'a expiration, puis la meme demande peut etre reprise. Les garanties
  finales contre les doublons restent celles du backend natif.
- Suppression du journal uniquement apres une reponse de pret correctement
  identifiee dans la bibliotheque, ou retour confirme du meme pret. Un echec
  d'enregistrement de cet acquittement laisse la demande a reprendre.
- Retrait local possible avec confirmation, mais ne constitue ni une
  annulation du pret/retour serveur ni un acquittement. Le retrait est
  refuse pendant un verrou actif. Aucune expiration/purge silencieuse de
  demande non resolue ; maximum 100 demandes par compte/bibliotheque.
- Changement de bibliotheque, fermeture de session ou sortie de page
  annulent les abonnements HTTP et cachent les donnees de l'ancienne portee,
  sans effacer les demandes persistantes. L'operateur retrouve ses demandes
  lorsqu'il revient avec le meme compte/bibliotheque sur la meme origine.

### Verification de la tranche 7

- Verification TypeScript ciblee reussie et 165 tests Angular RFID passes,
  dont 50 nouveaux tests. Le vrai IndexedDB Edge est utilise pour les
  transactions, le rechargement des connexions, l'isolation, les conflits,
  la concurrence, les verrous, les acquittements et la capacite maximale.
- Tests du service : ecriture avant HTTP, sauvegarde hors ligne sans
  succes fictif, absence de renvoi automatique, reprise du meme contenu,
  retour sur le pret d'origine, controle du compte apres les etapes locales,
  coupure d'abonnement, delai HTTP borne et echec du journal/acquittement.
- Tests de station : affichage, reprise explicite, double clic, etat
  offline/verrou, confirmation et annulation du retrait, changement de
  bibliotheque et fermeture de session sans effacement du journal.
- Tests additionnels : identites d'origine requises avant sauvegarde,
  anciennes demandes tag-only bloquees sans effacement, identites
  differentes distinguees dans le journal et reponse d'un autre
  adherent/exemplaire non acquittee.
- Compilation Angular de production reussie ; avertissements existants
  Sass/CommonJS/templates et `/assets/css/style.css` manquante conserves.
  Suite generale Angular ILMS non revalidee ; SDK executables inchanges
  dans cette tranche. Les tests backend sont relances pour le nouveau
  contrat d'identites attendues ; aucune migration de schema n'est ajoutee.
- Journaux `.tools/rfid-outbox-types.log`, `rfid-outbox-angular-tests.log`
  et `rfid-outbox-production-build.log`. Une erreur de syntaxe dans l'ajout
  du controle de liste tardive a ete corrigee avant ces resultats finaux.
- 144 tests backend RFID puis suite Java complete de 145 tests passes,
  dont 10 nouveaux tests sur les identites confirmees, les reattributions,
  leur verrouillage, l'empreinte et le parsing/validation HTTP. Les appels
  historiques tag-only gardent une empreinte identique. Journaux :
  `.tools/rfid-outbox-java-tests.log` et `rfid-outbox-java-full-tests.log`.
  Les tests PostgreSQL precedents ne sont pas relances : aucun schema ni
  repository n'est modifie ; la recette complete avec services reels et
  JWT signe reste necessaire avant basculement.
- Recette Edge/Playwright du vrai Angular et du vrai IndexedDB, avec API
  ILMS simulee et reseau externe bloque : resultat incertain puis
  fermeture/redemarrage complet d'Edge avec un profil disque isole,
  restauration de session et reprise avec UUID, contenu, echeance et identites d'origine
  identiques ; sauvegarde offline sans HTTP ni succes fictif ; absence de
  reprise automatique au retour reseau ; second onglet bloque pendant le
  verrou ; page fermee pendant l'envoi puis reprise apres expiration du
  verrou ; retour sur le pret d'origine ; isolation compte/bibliotheque ;
  refus 409 conserve ; annulation et confirmation du retrait sans HTTP.
- Desktop 1440x1000 et mobiles 390x1000/320x1000 controles, nouveaux
  panneaux/boutons sans debordement ; aucune erreur JavaScript dans le
  parcours. Donnees locales inspectees : identites et tags minimaux,
  sans noms, titres ou secrets. Script `.tools/verify-rfid-outbox-ilms-ui.cjs`,
  journal `rfid-outbox-browser.log`, captures `rfid-outbox-{largeur}.png`.
  Profil genere `.tools/rfid-outbox-browser-profile-*` : compte et donnees
  uniquement fictifs, aucun profil personnel ni identifiant reel utilise.
- Regression du vrai Angular avec le vrai agent loopback HTTP/CORS et
  lecteur simule reussie : appairage, connexion, scans explicites,
  resultat de pret incertain/reappairage/reprise avec le meme identifiant,
  retour sans carte et desactivation du lecteur. Journal
  `.tools/rfid-outbox-agent-regression.log`. Pas de lecture physique.
- Apercu local redemarre et HTTP 200 confirme : `http://127.0.0.1:4200/`,
  proxy local vers 8081 conserve. Gateway et backend ILMS ne sont pas
  demarres par ces tests. Journaux `rfid-outbox-preview.out.log` et `.err.log`.

### Limites et protection du poste

Ce journal n'est pas une station completement utilisable hors ligne : une
nouvelle identification de carte/exemplaire depend encore des API ILMS.
Cette limite de la tranche 7 est reduite par le cache facultatif de la
tranche 8 ci-dessous, sans remplacer les controles serveur.
Il conserve une operation deja preparee/explicitement confirmee, y compris
si la connexion tombe avant son envoi. Ni catalogue offline, ni nouvelle
regle d'acceptation locale, ni PWA precachee n'est ajoutee. Adhesion,
disponibilite, autorisations et conflits sont revalides par ILMS a la reprise.

Les donnees minimales RFID sont stockees localement, sans chiffrement
applicatif presente comme une protection contre un utilisateur du poste
ou du code de la meme origine. Le filtrage par compte concerne l'interface,
pas une isolation cryptographique. La protection OS du poste et du disque
reste necessaire. Le journal ne persiste jamais la cle d'appairage : un
lecteur doit toujours etre appaire de nouveau apres sortie de page.

La durabilite IndexedDB reste soumise au navigateur, a ses quotas et a sa
politique d'eviction. Navigation privee, effacement des donnees, changement
d'origine/port ou destruction du profil peuvent faire perdre ce journal.
Ne pas changer l'origine ni effacer les donnees avant traitement des
demandes. La sauvegarde et la politique de retention/stockage persistant
des postes restent a definir avant une exploitation hors ligne generalisee.

Synchronisation des clients desktop/mobile, catalogue offline, inventaires,
badges/presences, portails/alarmes, encodage et autres fonctions de
l'inventaire restent a traiter. Gateway complet avec JWT signe et lecteur
physique restent a valider. Aucun push, deploiement ou basculement Render
n'est effectue.

## Tranche 8 - Fiches consultees et preparation hors ligne

### Perimetre

- Cache IndexedDB natif separe `ilms-rfid-cache-v1`, facultatif et desactive
  par defaut. Consentement par compte et bibliotheque depuis la station.
  Les recherches explicites en ligne alimentent seulement ce cache ;
  aucune aspiration globale du catalogue ni reprise des donnees Render.
- Au maximum 200 fiches par compte/bibliotheque. Validite 24 heures depuis
  la consultation en ligne, sans prolongation lors d'une lecture locale.
  Une horloge revenue avant la date de sauvegarde invalide aussi la fiche.
  Les fiches expirees sont exclues puis purgees au prochain acces au cache,
  pas par un effacement garanti lorsque le navigateur est ferme.
- Adherents : UUID natifs carte/adherent et dernier etat d'eligibilite,
  sans nom, numero d'adherent ni motif personnel. Affichage local generique
  `Adherent`. Exemplaires : UUID exemplaire/document, numero, titre et
  dernier indicateur de disponibilite, sans image ni pret actif/historique.
  Aucune cle de lecteur, aucun mot de passe ni JWT dans ce cache.
- EPC/TID normalises et strictement concordants si les deux sont saisis.
  Une nouvelle consultation remplace l'ancienne association de la meme
  identite ou d'un identifiant reattribue ; les alias non reverifies ne
  sont pas reutilises. Les types carte/exemplaire ne sont pas confondus.
- Hors ligne, ou apres une erreur de transport HTTP 0/delai de 15 secondes,
  une fiche recente peut preparer un pret. Aucun repli sur un refus HTTP
  400/401/403/404/409 ni une erreur serveur 5xx. Un refus 404/409 retire
  les associations correspondantes. Si un refus 401/403 atteint le service
  de recherche avec son compte toujours actif, il desactive et vide le cache
  concerne. L'intercepteur natif ILMS ferme aussi la session sur ces refus
  et peut annuler la recherche avant ce traitement : les fiches sont alors
  masquees, sans garantie d'effacement automatique.
- Fiches locales datees, adhesion/disponibilite explicitement a revalider.
  Une fiche ayant expire pendant l'ouverture de la station bloque aussi
  la confirmation. La confirmation sans reseau dit `Conserver la demande`
  et sauvegarde uniquement le journal de tranche 7 : aucun pret accepte
  localement et aucun renvoi automatique au retour de connexion.
- Les UUID natifs d'origine restent dans la demande. ILMS valide les droits,
  l'adhesion, la disponibilite et toute reattribution a la reprise explicite.
  Une ancienne fiche ne choisit jamais un pret a restituer : nouvelle
  identification en ligne du pret actif requise pour preparer un retour.
  Un retour deja identifie en ligne reste sauvegardable dans le journal.
- Effacer les fiches ne touche pas les operations a reprendre. Desactiver
  le cache retire ses fiches dans la meme transaction et bloque les
  sauvegardes suivantes, y compris depuis un autre onglet.

### Limites

Il ne s'agit pas du catalogue complet hors ligne ni d'une PWA precachee.
La station doit etre chargee avant la coupure ; demarrer ILMS sans reseau
avec ses pages/assets/routes/authentification reste un chantier distinct.
Le lecteur conserve les controles ILMS d'autorisation et d'activation
avant l'utilisation d'un scan : une panne reseau invalide son contexte.
Ce cache ne donne donc pas une autorisation de lecteur hors ligne ; la
preparation sans reseau utilise la saisie manuelle des tags connus.
Les anciennes fiches sont des indications, jamais une autorisation locale
de pret. Les garanties serveur et la recette avec JWT signe/gateway/lecteur
physique restent necessaires avant exploitation.
Une revocation serveur des droits pendant une coupure ne peut pas etre
detectee localement. Les roles de session ne remplacent pas les droits
RFID natifs verifies a la reprise.

Comme le journal, le cache n'offre pas d'isolation cryptographique entre
utilisateurs du meme poste ou scripts de la meme origine. Les identifiants
et titres restent des donnees locales a proteger par l'OS. La fermeture de
session masque les fiches, sans effacement automatique du cache consenti.
L'eviction du navigateur peut supprimer les fiches ; un effacement global
des donnees du site peut aussi detruire le journal et doit etre evite tant
que des demandes restent a traiter.

### Verification locale

- 205 tests RFID Angular passent, dont 17 tests du vrai IndexedDB pour le
  cache, 17 tests du service de recherche et 6 tests additionnels de station.
  Isolation compte/bibliotheque, consentement, expiration, recul d'horloge,
  concordance EPC/TID, reattribution, remplacement des alias, limite 200,
  refus serveur, absence de noms/prets/images et reponses tardives couverts.
  La compilation de production reussit apres la correction de la
  couverture indisponible ; les avertissements ILMS existants sont conserves.
- Recette du vrai Angular/IndexedDB dans Edge avec API ILMS simulee et
  reseau externe bloque : consentement, consultation, fermeture complete
  puis redemarrage d'Edge, resolution offline sans HTTP, demande liee aux
  UUID d'origine sans succes fictif, effacement des fiches sans perte du
  journal et reprise explicite avec le meme UUID d'operation. Refus 404
  sans repli puis isolation d'un autre compte controles. La premiere
  tentative du script a ete interrompue pour corriger une variable masquee
  dans son lecteur IndexedDB ; elle n'est pas comptee comme validation.
- Captures desktop 1440 et mobiles 390/320, verification des dimensions
  des zones de saisie/confirmation. Les fiches locales n'essaient pas de
  telecharger une couverture : icone de remplacement de dimensions fixes,
  egalement utilisee si image et bitmap de secours sont indisponibles.
- Journaux `.tools/rfid-cache-angular-tests.log`,
  `rfid-cache-production-build.log` et `rfid-cache-browser.log` ; script
  `verify-rfid-cache-ilms-ui.cjs`, captures `rfid-cache-{largeur}.png`.
  Profils Edge isoles `rfid-cache-browser-profile-*` avec comptes et JWT
  uniquement fictifs. Aucun compte reel ni donnees de production utilises.
- Regression du journal durable reussie sur le code final : fermeture
  complete/redemarrage d'Edge, meme contenu, sauvegarde offline, absence de
  reprise automatique, verrou inter-onglets, envoi interrompu, retour sur
  le pret d'origine, isolation et retrait local confirme. Journal
  `.tools/rfid-cache-outbox-regression.log`, aucune erreur JavaScript.
- Regression de l'agent local reussie : vrai HTTP/CORS et Angular avec
  lecteur simule, administration des appareils, appairage/connexion,
  scans explicites, meme operation apres perte de session du lecteur,
  retour sans carte et appareil desactive bloque. Journal
  `.tools/rfid-cache-agent-regression.log`, aucune lecture physique.
- Apercu final HTTP 200 confirme a `http://127.0.0.1:4200/` ; journaux
  `.tools/rfid-cache-preview-final.out.log` et `.err.log`. Le proxy local
  vers 8081 est conserve ; gateway/backend ILMS non demarres ici.
- Aucun changement backend/SQL dans cette tranche : les 145 tests Java
  et tests PostgreSQL precedents ne sont pas relances. Recette reelle
  gateway/JWT signe/lecteur physique, PWA et synchronisation des clients
  desktop/mobile restent a faire. Aucun deploiement/basculement Render.

## Tranche 9 - Premiers clients de circulation native

### Perimetre

- Client desktop natif avec commande `npm.cmd run sync:ilms`, recherches,
  sauvegarde locale et reprise explicite de prets/retours. Journal SQLite
  dedie, sans modification du catalogue historique ni conversion de ses
  mutations. Garantie d'ecriture avant HTTP, limites, verrous inter-processus
  et acquittement sur identites natives seulement.
- Transport mobile Dart natif, sans nouvelle dependance. Contrat partage
  avec le desktop : memes UUID, EPC/TID et dates UTC a la milliseconde.
  Aucun journal mobile ou branchement d'interface n'est presente comme
  termine. L'appelant devra sauvegarder durablement avant l'envoi.
- Origine gateway/compte/bibliotheque separes ; Bearer de la session ILMS
  courant, sans persistance dans le journal ni transfert au lecteur.
  Redirections interdites, delai total et taille de reponse bornes,
  invalidation des reponses tardives apres changement de contexte/session.
- Les anciens clients Render sont conserves sans changement : leur
  inscription d'appareil, curseur, `X-Device-Key` et renvoi initial de toutes
  les entites ne sont pas compatibles avec la decision de ne pas importer.
  Ni ancienne cle ni catalogue Render ne sont repris par le nouveau client.
- La session authentifiee et les interfaces des deux clients, puis le
  journal durable mobile, restent a brancher avant un basculement.
  Details, commandes et limites : [clients natifs](ilms-circulation-client.md).

### Gateway indique par l'utilisateur

`https://gateway.bibliotheque-ztf.org` est joignable et authentifie. Le
14 octobre 2026, avec un compte administrateur fourni par l'utilisateur, les
trois etapes de connexion passent (OAuth 200, login 200, bibliotheques 200,
une seule bibliotheque). Les routes `circulation/rfid/*` repondaient en
revanche 500 enveloppant `404 NOT_FOUND`. Verifie par comparaison avec une
route inventee sous le meme prefixe, qui donnait la meme erreur, alors que
`GET /libraries/{UUID}` repondait 200 dans la meme session.

Lecture corrigee du 14 octobre 2026, apres examen du code : ces routes
n'etaient pas en attente de deploiement, elles n'existaient pas. Elles ont
depuis ete ecrites et poussees sur le `master` du `library-service` et
attendent un deploiement. Voir [clients natifs](ilms-circulation-client.md)
pour les prealables de recette.
Le gateway convertit les 404 amont en 500 et un mot de passe errone en 500
au lieu de 401 ; a corriger avant la recette. Les ecritures `checkouts` et
`returns` n'ont pas ete essayees. Le constat anonyme du 12 octobre (HEAD 404)
est remplace par cette verification. Le proxy Angular local vers 8081 reste
inchange.

### Verification locale

- Suite Node SDK complete : 134 tests passes, dont 38 tests du nouveau
  client/journal/CLI. Persistance SQLite entre connexions et processus,
  ecriture avant HTTP, refus d'une base historique, capacite, corruption,
  scopes, verrous, identites divergentes et reponses mal formees couverts.
  Serveurs HTTP loopback reels avec API ILMS simulee, reprise du contenu
  original et absence de transfert du Bearer apres une redirection verifies.
- 44 tests mobiles passes : 30 tests du transport ILMS, plus 3 tests de
  rapport/synchronisation historique et 11 tests de bibliotheque, circulation,
  cartes, inventaire et localisation. Analyse Dart ciblee finale : aucun
  probleme. Fixtures partagees, meme normalisation a la milliseconde,
  timeout, scopes, refus serveur, acquittement et vrai HTTP loopback couverts.
- Les 28 premiers tests mobiles ont aussi passe avant le dernier renforcement
  de validation. Les resultats finaux ci-dessus couvrent le code final.
  La machine a ralenti considerablement cette passe ; aucune application
  ou service preexistant n'a ete ferme pour l'accelerer. Seul notre propre
  apercu Angular a ete suspendu pendant les tests, puis redemarre.
- Journaux : `.tools/rfid-native-client-full-tests.log`,
  `rfid-native-mobile-regression-tests.log`, `rfid-native-mobile-analyze.log`.
  Aide desktop et recette detaillee dans [clients natifs](ilms-circulation-client.md).
- `node ilms-sync.js help` verifie sans ouvrir de base ni contacter ILMS.
  Apercu Angular redemarre, HTTP 200 confirme : `http://127.0.0.1:4200/`.
  La premiere verification de trois minutes a expire pendant la compilation ;
  la verification suivante confirme la disponibilite. Journaux
  `.tools/rfid-native-client-preview.out.log` et `.err.log`.
- Pas de changement Angular, backend Java ou schema SQL dans cette tranche ;
  les compilations Angular, tests Java/PostgreSQL et captures precedentes
  ne sont pas relances. Aucun build de distribution Electron ou mobile,
  test physique ou appel authentifie au gateway distant n'est revendique.
- Les tests ne configurent pas les anciens clients ni ne les basculent.
  Aucun import, commit, push ou deploiement ; aucun changement OnRender.

## Tranche 10 - Journal durable de circulation mobile

### Perimetre

- `lib/data/ilms_circulation_journal.dart` : fichier SQLite dedie
  `ilms_circulation.db`, marqueur/schema natifs, transactions exclusives,
  WAL et synchronisation FULL effectivement verifies a l'ouverture.
  Aucune adoption/migration de `biblio_rfid.db`, reprise des mutations
  Render ou modification de `LibraryDatabase`/`SyncService`.
- Intentions minimales separees par gateway/compte/bibliotheque, empreinte
  canonique et limite 100 sans eviction. UUID v4 avec le meme modele de
  generation securisee deja utilise dans le projet. Le jeton, les noms,
  titres et contenus d'erreur HTTP ne sont jamais conserves dans ce journal.
- `lib/services/ilms_circulation_sync.dart` : sauvegarde avant HTTP,
  recherches natives, conservation offline, liste, reprise et retrait local
  confirme. Le pret conserve les UUID d'operation, carte, adherent et exemplaire, tags et echeance
  d'origine ; le retour conserve seulement son pret d'origine et ses tags.
- Verrous de 120 secondes entre connexions SQLite et HTTP borne a 30 secondes.
  Seul le proprietaire acquitte/libere son verrou. Reponse native invalide,
  erreur ou timeout ne supprime pas une demande. Un echec d'acquittement local
  laisse l'intention pour reprise idempotente apres expiration de son verrou.
- Controles de contexte pendant la sauvegarde, la liste, le verrou et HTTP :
  pas d'exposition tardive des donnees a une autre session. Fermeture du
  service sans effacement du journal. Perte locale de jeton distinguee d'un
  refus HTTP : elle ne persiste pas un statut serveur 401 fictif.
- Aucune inscription d'appareil, preference Render, minuterie, reprise au
  demarrage/retour reseau ou envoi automatique du catalogue. Les interfaces
  historiques ne sont pas branchees sur ce service. Les fonctions de session
  et normalisation sont partagees avec le transport natif de tranche 9.
- Aucune nouvelle dependance ni modification de `pubspec.yaml`/lockfile.
  La connexion ILMS et les ecrans des deux clients restent a integrer.
  Details et limites : [clients natifs](ilms-circulation-client.md).

### Verification locale

- Premiere passe : 40 tests du journal/service mobile passes ; derniere passe
  sur le code final : 85 tests passes, soit 41 du journal/reprise, 30 du
  transport ILMS et 14 regressions de rapports/synchronisation, circulation,
  cartes, inventaire, localisation et catalogue. Bases et comptes fictifs.
- Analyse Dart ciblee finale : aucun probleme.
- SQLite FFI reel sur Windows : schema/marqueur, persistance apres fermeture
  et reouverture, corruption sans suppression, refus d'une base historique
  sans changement de ses lignes/version/mode, proprietaire/version/vue
  inconnus, capacite sous appels concurrents et verrous sur deux connexions.
- API ILMS simulee : commit avant HTTP, refus 4xx/5xx, echec JSON/identites,
  UUID d'origine de l'operation et du pret retourne, timeout, perte du jeton, changement de
  contexte pendant stockage/HTTP, fermeture de session et panne locale
  pendant l'acquittement. Aucun succes fictif ni nouveau pret de substitution.
- Vrai HTTP loopback avec vrai client Dart : contenu identique apres
  fermeture/reouverture, aucun renvoi a la creation du service, aucune route
  Render ni cle d'appareil, refus d'une redirection sans fuite du Bearer.
- Journaux `.tools/rfid-mobile-journal-tests.log`,
  `rfid-mobile-journal-regression-final.log` et
  `rfid-mobile-journal-analyze-final.log`. Les premiers avertissements
  d'analyse etaient cinq remarques de style, corrigees avant le code final.
- Aucun changement Angular, Java, PostgreSQL ou client desktop dans cette
  tranche ; leurs compilations/tests/captures precedents ne sont pas
  relances. Le service d'apercu local Angular est conserve.
- Aucun test Android/iOS physique, arret brutal du vrai mobile, perte
  d'alimentation, build APK/distribution ou appel authentifie au gateway
  distant. Session, interface, cycle de vie mobile et lecteur physique
  restent a valider. Le fichier n'est pas chiffre ; protection OS,
  sauvegarde/retention et politique d'effacement restent necessaires.
- Aucun import, commit, push, deploiement ou basculement Render.
 
## Tranche 11 - Session et interface mobile natives

- Entree `Reader/myscankey_flutter/lib/main_ilms.dart`, independante de
  l'entree historique : aucune construction de `LibraryController`,
  synchronisation Render, inscription d'appareil ou reprise de catalogue.
- Connexion OAuth applicative puis utilisateur et liste de bibliotheques,
  selon le contrat du portail Angular. Compte UUID et jeton de la meme
  reponse ; choix explicite si plusieurs bibliotheques, jamais `all`.
- Grant confirme par relecture du portail Angular `C:/laragon/www/ilms` :
  `OAuthTokenService` envoie `Basic base64(clientId:clientSecret)`,
  `grant_type=client_credentials` et `scope=read write` sur
  `/auth-service/oauth/token`, puis `BearerHttpClientService` prefixe le login
  utilisateur avec ce jeton applicatif. Les bibliotheques passent par le jeton
  utilisateur. Contrat identique cote mobile, au prefixe proxy `/api` pres.
- Le couple client/secret du portail est code en dur dans ses deux
  `src/environments/environment*.ts` et part donc dans son bundle JS public :
  c'est un reglage de deploiement, pas un secret. Il devient un defaut de
  build mobile (`--dart-define=ILMS_GATEWAY_URL/ILMS_CLIENT_ID/
  ILMS_CLIENT_SECRET`), avec les memes valeurs de recette que le portail.
  `shared/.../app-auth.service.ts` et `shared/.../auth.service.ts` du portail
  sont du code mort (corps JSON sans `grant_type`, route hors proxy,
  `https://votre-api.com/login`) et ne servent pas de reference.
- Champs client/secret replies derriere « Parametres avances », ouverts
  d'office si le build ne fournit pas de client utilisable. Saisie locale des
  mots de passe et d'un client de session, memoire uniquement : le mot de passe
  est efface et le secret ramene au defaut de build apres chaque tentative.
  Refus des JWT expires/incomplets et des jetons de changement de mot de
  passe/second facteur. Pas de verification locale de signature ni
  d'autorisation RFID deduite de la liste des bibliotheques.
- Recherche manuelle EPC/TID, previsualisation adherent/exemplaire, date
  choisie, confirmation de pret ou retour lie au pret natif d'origine.
  Edition des tags ou changement de contexte invalide les selections.
- Sauvegarde dans le journal avant envoi, effacement des selections apres
  commit, reprises manuelles du meme UUID et suppression locale confirmee.
  Une erreur/expiration/deconnexion n'est jamais un acquittement ILMS.
- Package Android de recette distinct
  `com.bibliorfid.myscankey_flutter.ilms`, activite `IlmsActivity` sans
  initialisation des anciens ponts materiels/logs. Les builds refusent
  un melange entre cible ILMS et package historique. L'entree existante,
  son package et ses donnees restent intacts.
- 135 tests mobiles cibles passent sur le code corrige : 35 connexion (dont vrai HTTP loopback
  et refus des redirections), 14 interface (SQLite FFI, confirmation/reprise,
  edition des tags, changement de bibliotheque et deconnexion pendant HTTP),
  42 journal/reprise, 30 transport natif et 14 regressions historiques.
  Log `rfid-mobile-native-ui-regression.log`. Captures login/station rendues
  avec Montserrat et Material Icons, sans overflow a 320/390/1280 px.
- Ajout du seul SDK de test `integration_test` et de ses dependances de
  developpement, sans mise a niveau des dependances metier existantes.
  Recette Android dediee dans `integration_test/ilms_device_test.dart` :
  donnees fictives et bases `ilms_recipe_<UUID>.db`, jamais gateway reel.
  Le premier APK de tests est compile puis installe, avec accord utilisateur,
  sur CRUISE2 Android 11 sans remplacer le package historique. Les deux tests
  initiaux echouent a l'ouverture du journal : Android cree `android_metadata`
  meme dans une base neuve. La correction limite l'exemption a cette table
  systeme de structure exacte sur Android et utilise `rawQuery` pour le
  PRAGMA de timeout. Les bases metier restent refusees. Une troisieme recette
  physique ajoute le refus/conservation d'un catalogue historique fictif.
  Les tests Windows finaux et l'analyse Dart passent apres correction.
  Une tentative de reprise n'a pas demarre car le telephone avait disparu
  d'ADB ; apres reconnexion, les trois tests passent sur CRUISE2 Android 11
  avec le plugin SQLite natif : refus du catalogue fictif sans alteration,
  commit avant HTTP, conservation apres fermeture/reouverture, reprise
  explicite du meme UUID, connexion/station simulees sans appel metier
  automatique. Build de tests 333,5 s, installation 5,1 s, tests 8 s.
  Log `rfid-mobile-android-recipe.log`, analyse finale sans probleme dans
  `rfid-mobile-native-ui-analyze.log`. Ce n'est pas une recette OAuth distante,
  de lecteur RFID, d'arret brutal du processus ou de perte d'alimentation.
- APK utilisable, distinct du lanceur de tests, compile avec `main_ilms.dart`
  apres correction. Copie locale dans
  `C:/laragon/www/ilms-migration/.tools/bibliorfid-ilms-native-20261012.apk`.
  Inspection `aapt` : package `.ilms`, libelle `BIBLIORFID ILMS`, activite
  `com.bibliorfid.myscankey_flutter.IlmsActivity`. Build debug de recette,
  reinstalle avec succes apres les tests dans le seul package `.ilms`, puis
  ouvert sur l'ecran de connexion sans saisie d'identifiants. Activite au
  premier plan verifiee avant capture physique 720 x 1440 :
  `.tools/rfid-mobile-cruise2-login.png`, sans debordement visible.
  Aucun acces aux donnees ni remplacement du package historique ; pas une
  distribution de production. Log `rfid-mobile-ilms-apk-build.log`.
- Trois tests Gradle de garde passent : entree native sans isolation, entree
  historique avec isolation et lanceur de tests sans drapeau de recette
  sont tous bloques avant toute construction/installation. Logs
  `rfid-mobile-package-guard-*.log`. Les controles positifs sont les APK
  natifs compiles et leurs manifestes effectivement inspectes.
- Aucun changement Java, schema PostgreSQL, Angular ou client desktop
  dans cette tranche ; leurs tests precedents ne sont pas relances.
- Restent notamment : contrat OAuth mobile distant, connexion avec le vrai
  compte, deploiement des routes, lecteur physique, session/interface
  Electron, autres fonctions de l'inventaire, iOS et cycle de vie complet.
- Aucun import, commit, push, deploiement serveur ou basculement Render.

## Tranche 12 - Correction des routes directes du gateway

- L'utilisateur peut se connecter au portail web mais la recette mobile
  affiche `Element introuvable dans ILMS` (HTTP 404). Le raccordement natif
  avait copie les chemins Angular sans tenir compte du proxy du portail.
- `C:/laragon/www/ilms/src/proxy.conf.json` retire `^/api` avant de contacter
  `https://gateway.bibliotheque-ztf.org`. Ce prefixe n'appartient pas aux
  chemins directs utilises par les applications natives.
- Verification distante du 12 octobre 2026, sans credentials, cookies,
  redirections ni appels metier : GET sur OAuth, login et bibliotheques
  avec `/api/{service}/...` retourne 404 ; GET sur les memes chemins
  `/{service}/...` retourne 401. Cela confirme la difference de routage,
  pas la validite du client OAuth, des JWT ni le deploiement des extensions.
- Suppression du seul prefixe local : OAuth `/auth-service/oauth/token`,
  login `/auth-service/api/v1/auth/login`, bibliotheques
  `/library-service/api/v1/libraries`, circulation
  `/library-service/api/v1/libraries/{UUID}/circulation/rfid/{route}`.
  Connexion et transport mobile ainsi que transport desktop/CLI corriges.
  Aucun changement des routes Angular, du backend ou du schema SQL.
- Les serveurs HTTP locaux de tests refusent les chemins inconnus au lieu
  d'accepter seulement un suffixe de route. Tests exacts des trois etapes
  d'authentification et des quatre routes natives, sur Dart et Node.
  La recette Android existante utilise egalement les chemins exacts.
- 136 tests mobiles cibles passent, 135 tests SDK Node passent, analyse
  Dart ciblee sans probleme. Logs `rfid-mobile-gateway-prefix-tests.log`,
  `rfid-native-gateway-prefix-tests.log` et
  `rfid-mobile-gateway-prefix-analyze.log` dans `.tools`.
  La recette physique SQLite precedente reste celle de la tranche 11 ;
  elle n'est pas relancee pour cette correction HTTP.
- APK corrige compile depuis `main_ilms.dart` en 292,7 s. Inspection `aapt` :
  package `com.bibliorfid.myscankey_flutter.ilms`, libelle `BIBLIORFID ILMS`,
  activite `com.bibliorfid.myscankey_flutter.IlmsActivity`. Copie locale
  `C:/laragon/www/ilms-migration/.tools/bibliorfid-ilms-gateway-20261012.apk`.
  Installation `adb install -r` reussie sur CRUISE2 puis demarrage a froid
  et activite au premier plan confirmes. Aucune saisie, lecture de champs
  ou capture de credentials. Journal non efface, application historique
  non remplacee. Debug de recette uniquement, pas livraison de production.
  Log `rfid-mobile-gateway-prefix-apk-build.log`. Ne pas utiliser l'ancien
  APK de tranche 11 pour verifier la connexion au gateway distant.
- La connexion reelle reste a retester localement par l'utilisateur,
  sans transmettre de mots de passe/jetons au chat. Le contrat OAuth mobile,
  le lecteur physique et les autres fonctions de migration restent a valider.
- Aucun import, effacement de journal, commit, push, deploiement ni
  basculement Render. Aucune tentative de connexion distante avec secrets.

## Tranche 13 - Diagnostic de redirection pendant la connexion mobile

- Apres correction des chemins, l'utilisateur signale HTTP 302. Il confirme
  utiliser `https://gateway.bibliotheque-ztf.org` dans le mobile et se connecter
  au portail `https://ilms.bibliotheque-ztf.org`. La cause precise du 302
  n'est pas encore identifiee ; la connexion reelle n'est pas declaree corrigee.
- Le portail repond 200 sur `/`. Les appels anonymes a ses routes `/api/...`
  et aux routes directes du gateway repondent 401 sans redirection, notamment
  POST OAuth sans Authorization. Une seule requete OAuth supplementaire avec
  client fictif aleatoire non enregistre, sans compte/mot de passe utilisateur,
  repond 500 et indique `/oauth/token` dans Location. Pas de suivi, de lecture
  du corps ou de valeurs secretes. Ce resultat ne reproduit pas le 302 et
  ne permet pas de conclure que le vrai client OAuth est incorrect.
- `IlmsAuthHttpException` distingue OAuth applicatif, connexion utilisateur
  et liste des bibliotheques. Chaque refus HTTP affiche son etape. Un 302
  est affiche comme redirection bloquee, jamais comme un succes ou une
  preuve de mauvais mot de passe ; 401/403 et 404 sont egalement contextualises.
- Diagnostic de Location reduit a un enum : page de connexion connue du
  meme gateway, autre route du gateway, autre origine, destination manquante
  ou non validee. Aucun hostname/chemin arbitraire, query, fragment, userinfo,
  corps serveur ou credential conserve dans l'exception ou affiche dans l'UI.
  Refus des destinations avec userinfo, downgrade HTTPS, controles ou taille
  excessive. Aucune redirection suivie, route de secours, cookie, nouveau
  stockage de secrets, connexion automatique ou modification serveur.
- 145 tests mobiles cibles passent : 41 auth, 17 interface, 42 journal,
  31 transport natif, 14 regressions historiques. Les 41 tests auth sont
  relances apres le dernier controle d'URL. Vrai HTTP loopback 302 vers une
  autre origine : aucune requete a destination. Etapes, URLs adverses, absence
  de fuite de secrets et messages sans overflow a 320/390/1280 px couverts.
  Analyse Dart ciblee sans probleme. Logs `rfid-mobile-auth-redirect-tests.log`,
  `rfid-mobile-auth-redirect-auth-final.log` et
  `rfid-mobile-auth-redirect-analyze.log` dans `.tools`.
- APK de diagnostic compile depuis `main_ilms.dart` en 147,7 s. Package
  `.ilms`, libelle `BIBLIORFID ILMS` et `IlmsActivity` verifies avec `aapt`.
  Copie `.tools/bibliorfid-ilms-auth-diagnostic-20261012.apk` dans le dossier
  de migration. Mise a jour `adb install -r` reussie sur CRUISE2, demarrage
  a froid et activite au premier plan confirmes. Aucune lecture/capture
  des champs et aucune saisie a la place de l'utilisateur. Debug de recette,
  pas distribution de production. Log `rfid-mobile-auth-redirect-apk-build.log`.
  Le nouveau message exact est demande a l'utilisateur pour identifier
  l'etape et la categorie de destination du 302 reel.
- Aucun changement Node SDK, Java, SQL, Angular ou auth-service/gateway.
  Leurs suites et la recette physique SQLite precedente ne sont pas relancees.
- Aucun import, effacement du journal, commit, push, deploiement ou basculement
  Render. Aucun identifiant reel saisi/lu ni pret/retour distant execute.

## Tranche 14 - Verification authentifiee et origine par defaut du desktop

- Recette distante du 14 octobre 2026 avec un compte administrateur et le
  mot de passe fournis par l'utilisateur, et le client OAuth public du
  portail (`test-client`, present en clair dans `environment.prod.ts` et
  dans le bundle JS servi). Chaine complete : OAuth 200, login 200 avec
  `user.id` et `access_token.token` de type `Bearer`, `GET /libraries` 200
  avec une seule bibliotheque, `GET /libraries/{UUID}` 200.
- Les quatre routes RFID ne sont pas deployees : `members/resolve` et
  `copies/resolve` repondent 500 enveloppant `404 NOT_FOUND`, comme une
  route inventee sous le meme prefixe. `checkouts` et `returns` ne sont pas
  essayees, ce sont des ecritures sur la base de l'utilisateur.
- Deux anomalies serveur a corriger, hors de ce depot : le gateway renvoie
  500 au lieu de 404 pour une route absente et au lieu de 401 pour un mot de
  passe errone ; `/auth-service/actuator/health` repond 500. Le client natif
  traduit ces 500 en `denied`, donc en panne reessayable, alors qu'une route
  absente ne le sera jamais.
- Le compte administrateur utilise un mot de passe trivial sur un serveur
  public ; son changement est recommande a l'utilisateur. Aucun secret n'est
  ecrit dans ce depot.
- Desktop branche sur le gateway : `ILMS_DEFAULT_GATEWAY_URL` est exporte par
  `lib/ilms-circulation-client.js` et sert de defaut a `ILMS_GATEWAY_URL` dans
  `ilms-sync.js`, aligne sur `ilmsDefaultGatewayUrl` du mobile et sur
  `apiUrl` du portail. Une origine explicite reste prioritaire.
- `nativeScope` n'est pas modifie et reste un validateur strict : le defaut
  s'applique a la lecture de la configuration, jamais a une origine fournie
  par un appelant. Le compte, la bibliotheque et le jeton du desktop restent
  a brancher sur une vraie session ; l'UI Electron n'appelle toujours pas
  ILMS.
- 136 tests Node SDK passent, dont un nouveau test du defaut : sans
  `ILMS_GATEWAY_URL` le CLI vise le gateway deploye et la portee change, avec
  l'origine explicite le journal de test reste visible.
- Aucun import, effacement de journal, commit, push, deploiement ni
  basculement Render. Aucun pret ou retour distant execute.

## Tranche 15 - Correction d'une lecture erronee et suite backend

- La tranche 14 concluait que les extensions RFID n'etaient "pas deployees".
  La lecture etait fausse : apres examen du `library-service`, elles
  n'existaient pas. Le depot ne portait aucun controleur de circulation,
  seulement un `GET .../copies/by-rfid` et les routes `loans` classiques.
  Dire "pas deployees" laissait croire a un retard de livraison alors qu'il
  manquait le code.
- Les quatre routes ont ete ecrites cote backend, au contrat exact que ces
  clients implementent deja : tags EPC/TID, idempotence par `operation_id`
  garantie par un index unique, refus quand un tag ne designe plus l'objet
  attendu. Rien n'a change dans ce depot, les clients natifs n'avaient pas a
  bouger.
- Prealables avant recette, aucun n'etant du code : deployer le
  `library-service`, verifier la presence de pgvector sur la base visee, et
  encoder les cartes de lecteur. Les colonnes `rfid_code` et `rfid_tid` ont
  ete ajoutees aux cartes, mais aucune n'est encodee : `members/resolve`
  repondra qu'aucune carte ne porte le tag.
- Le `library-service` rend desormais 400 et 404 sur ses propres refus. Le
  `gateway-service` n'est pas corrige et continue de convertir les 404 amont
  en 500 : c'est lui qui compte pour un poste hors ligne, puisque ces clients
  traduisent un 500 en panne reessayable et rejoueraient indefiniment.
- Aucun import, effacement de journal, deploiement ni basculement Render.
