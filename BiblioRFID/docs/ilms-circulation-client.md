# Clients de circulation native ILMS

## Perimetre

Le client desktop `lib/ilms-circulation-client.js` et la commande
`ilms-sync.js` utilisent uniquement les quatre routes natives de circulation
RFID. Leur journal SQLite `lib/ilms-circulation-journal.js` est distinct du
catalogue BIBLIORFID et des mutations de synchronisation Render.

Le service mobile `Reader/myscankey_flutter/lib/services/ilms_circulation_client.dart`
fournit le meme transport HTTP et le meme format de demande. Le journal
`lib/data/ilms_circulation_journal.dart` et le service
`lib/services/ilms_circulation_sync.dart` ajoutent la sauvegarde avant envoi
et la reprise explicite. Une entree mobile distincte `lib/main_ilms.dart`
branche maintenant connexion native, selection de bibliotheque, prets,
retours et journal. **L'interface Electron historique n'est pas branchee.**
Utiliser `IlmsCirculationSync` pour les
operations metier ; le transport seul ne fournit aucune durabilite.

Les entrees historiques desktop/mobile et leurs services de synchronisation
ne sont pas bascules. Modifier simplement leur URL provoquerait notamment
des tentatives de renvoi de l'ancien catalogue, incompatibles avec la
decision de ne pas importer les donnees Render. Aucune reprise automatique
de l'ancienne base, inscription d'appareil ou synchronisation globale n'est
ajoutee par ces nouveaux clients.

## Session et gateway

La session fournit une origine gateway exacte, un UUID de compte ILMS, un
UUID de bibliotheque et le jeton Bearer courant. Les identifiants numeriques
Render et `X-Device-Key` ne sont jamais utilises. Le jeton n'est ni persiste
dans le journal, ni inclus dans les erreurs, ni transmis a l'agent lecteur.

HTTPS est obligatoire, sauf HTTP explicite vers `localhost`, `127.0.0.1`
ou `[::1]` pour une recette locale. Refus des identifiants dans l'URL,
chemins de service, query et fragment. Les redirections ne sont pas suivies.
L'URL HTTP construite est :

```text
{gateway}/library-service/api/v1/libraries/{library_uuid}/circulation/rfid/{route}
```

Routes POST : `members/resolve`, `copies/resolve`, `checkouts`, `returns`.
Le prefixe `/api` des appels Angular est local au portail : son proxy le
retire avant de contacter le gateway (`src/proxy.conf.json`, `pathRewrite`).
Les clients natifs ne passent pas par ce proxy et ne doivent pas l'ajouter.
Delai total maximal de 30 secondes, reponses JSON limitees a 64 Ko.
Un changement de compte, bibliotheque, gateway ou une fermeture de session
pendant l'appel interdit d'exposer/acquitter sa reponse tardive.

Les transports ne verifient pas localement la signature du JWT ni le lien
entre un jeton et un UUID de compte fourni par leur appelant. L'entree mobile
obtient maintenant le compte et le jeton dans la meme reponse de connexion
native ; le desktop doit encore etre branche a une telle session.
Le serveur valide le JWT et les droits
natifs dans la bibliotheque ; un filtrage local n'est pas une autorisation.

Origine fournie par l'utilisateur : `https://gateway.bibliotheque-ztf.org`.
Le 12 octobre 2026, une requete HEAD anonyme sur `/` a retourne 404 avec
verification TLS reussie, sans redirection. Cela ne valide ni les nouvelles
routes deployees, ni l'authentification, ni un environnement de test.
Aucun jeton ou appel metier n'a ete envoye a ce serveur.

Correction de routage du 12 octobre 2026 : les GET anonymes directs sur
OAuth, login et bibliotheques repondent 404 avec le prefixe local `/api`,
et 401 sans ce prefixe. Le proxy du portail retire bien ce prefixe.
Cela ne valide pas encore une connexion authentifiee ou les extensions RFID.
Les clients natifs utilisent uniquement les routes directes, sans essai
automatique d'une autre route apres erreur ni redirection de credentials.

## Entree mobile ILMS

`main_ilms.dart` construit uniquement `IlmsApp`, pas `LibraryController`,
`SyncService`, `LogShipper` ou les anciens controles de borne/portail.
L'entree historique `main.dart` reste intacte et n'est pas la recette ILMS.
L'activite Android `IlmsActivity` utilise les plugins Flutter natifs sans
initialiser les anciens ponts lecteur, logs ou boussole de `MainActivity`.

Contrat observe dans le portail, y compris `C:/laragon/www/ilms`, apres
retrait du prefixe local par son proxy (routes directes du gateway) :

1. POST `/auth-service/oauth/token`, Basic client OAuth, formulaire
   `grant_type=client_credentials&scope=read+write`.
2. POST `/auth-service/api/v1/auth/login`, Bearer applicatif, JSON
   `username` et `password`. Compte UUID lu depuis `user.id`, jeton depuis
   `access_token.token`, type `Bearer` uniquement.
3. GET `/library-service/api/v1/libraries`, Bearer utilisateur.
   Une seule bibliotheque est selectionnee automatiquement ; plusieurs
   exigent une selection explicite. Aucune portee synthetique `all`.

Le client mobile OAuth existe selon l'utilisateur, mais son grant n'a pas
encore ete confirme dans la configuration de l'auth-service. Le dossier
indique est le portail Angular, pas ce serveur. La compatibilite du client
mobile avec `client_credentials` reste donc a valider avant connexion reelle.
Les identifiants OAuth sont saisis localement pour la recette, jamais copies
des environnements Angular ni embarques avec `--dart-define`. Aucune cle,
mot de passe, jeton OAuth ou JWT n'est persiste. Ne pas traiter une app mobile
comme un coffre-fort pour un secret confidentiel ; un parcours public PKCE
ou un relais serveur devra etre utilise si le client mobile l'exige.

Le service refuse les reponses incompletes, les UUID numeriques, les jetons
de changement de mot de passe ou de deuxieme facteur, et les JWT sans
expiration valide. Il lit `exp` pour limiter les appels, sans pretendre
verifier une signature. Apres expiration, les metadonnees du contexte
restent disponibles pour consulter le journal, mais le jeton utilisable
devient vide ; aucune reprise automatique ni rafraichissement implicite.
Deconnexion ou nouvelle tentative invalide les reponses tardives.
Reponses de connexion JSON bornees a 1 Mo, delai total de 30 secondes
par appel, HTTPS sauf loopback, aucune redirection ni cookie volontaire.

Les refus HTTP de connexion portent leur etape : OAuth application,
connexion utilisateur ou liste des bibliotheques. Pour une redirection,
`Location` est uniquement classee en enum sans conserver/afficher l'URL :
page de connexion connue du meme gateway, autre route, autre origine,
destination manquante ou non validee. Query, fragment, userinfo, chemins
arbitraires et corps serveur restent absents des messages. Ces informations
ne constituent pas une autorisation de suivre la redirection. Un 302 ne
prouve pas que le mot de passe est incorrect.

La liste de bibliotheques n'est pas une autorisation RFID. Les droits sont
recontroles par le serveur sur chaque recherche et operation metier.
Le changement de bibliotheque detruit les selections et le transport de
l'ancien ecran, sans effacer ses demandes durables. Les lectures EPC/TID
sont actuellement saisies manuellement : aucun lecteur physique n'est
raccorde a cette nouvelle entree mobile.

Pret : recherche explicite de carte/exemplaire, eligibilite et disponibilite,
date de retour choisie, recapitulatif puis confirmation. Les trois UUID
natifs attendus sont lies a la demande. Retour : recherche d'exemplaire,
pret actif natif d'origine et confirmation, sans carte d'adherent.
Apres sauvegarde durable, les selections sont effacees ; toute reprise
passe par la meme entree du journal. Une erreur n'est jamais affichee comme
un pret accepte. Reprise et suppression locale ont leur confirmation.

Construction Android isolee (pas de secret dans cette commande) :

```powershell
cd C:/laragon/www/sdk/Reader/myscankey_flutter
$env:ORG_GRADLE_PROJECT_ILMS_STANDALONE = 'true'
flutter.bat build apk --debug --target lib/main_ilms.dart
Remove-Item Env:ORG_GRADLE_PROJECT_ILMS_STANDALONE
```

L'APK utilise `com.bibliorfid.myscankey_flutter.ilms`, distinct du package
historique, et le libelle `BIBLIORFID ILMS`. Le build refuse un melange entre
entree ILMS et package historique, dans les deux sens. La version est de
recette, non signee pour distribution en production. Ne pas l'installer
par-dessus une app ILMS existante sans verifier son origine et ses donnees.
Le journal reste non chiffre ; les politiques de sauvegarde Android/iOS
et de retention ne sont pas validees par cette tranche.

## Journal desktop

- Fichier SQLite dedie, marqueur `application_id = 0x494c4d53`, schema 1.
  Refus d'adopter une base existante d'un autre type ou une version inconnue.
  Transactions SQLite, WAL et `synchronous = FULL` avant toute transmission.
- Isolation par origine gateway, compte et bibliotheque. Au maximum 100
  demandes par contexte, sans eviction d'une demande non acquittee.
- Intentions minimales : type, UUID d'operation/pret et d'entites natives,
  EPC/TID et echeance. Aucun nom, titre, mot de passe, jeton ou corps
  d'erreur serveur. Etats, nombre d'essais et statut HTTP numerique locaux.
- Un pret conserve son UUID `operation_id`, les UUID attendus de carte,
  adherent et exemplaire, les tags et l'echeance UTC a la milliseconde.
  Une intention identique encore en attente reutilise sa premiere demande.
  Une identite changee ne remplace pas silencieusement l'ancienne demande.
- Un retour conserve l'UUID du pret confirme d'origine. Il n'utilise ni
  carte d'adherent ni recherche implicite d'un nouveau pret pendant la reprise.
- Verrou de 120 secondes entre processus. Seul son proprietaire acquitte
  ou libere sa demande. Une erreur, un delai depasse ou une reponse invalide
  conserve l'intention ; un refus HTTP conserve aussi son statut, sans
  enregistrer de contenu d'erreur potentiellement personnel.
- Acquittement uniquement apres validation des UUID du pret, bibliotheque,
  adherent/exemplaire attendus ou pret retourne et statut de retour 2.
  Un echec local de suppression garde la demande pour reprise idempotente.
- Aucune minuterie ni reprise au demarrage/retour reseau. Le retrait local
  est explicite et ne signifie jamais l'annulation d'un pret sur ILMS.

Le fichier n'est pas chiffre. L'isolation par compte concerne les appels du
client, pas une protection contre un utilisateur du meme OS ou un script
ayant acces au fichier. Proteger le poste, le disque et les sauvegardes.
Ne pas effacer/deplacer le journal avant traitement des demandes en attente.
Une sauvegarde SQLite doit tenir compte du WAL et des connexions actives.

## Journal mobile

`IlmsCirculationJournal.open()` ouvre par defaut `ilms_circulation.db` dans
le repertoire de bases de l'application, jamais `biblio_rfid.db`. Un chemin
explicite permet une recette avec base dediee. Un chemin vide ou en memoire
est refuse. Aucun singleton ne l'ouvre au lancement de l'ancienne application.

Android initialise sa table systeme `android_metadata` dans une base neuve.
Seule cette table, de structure exacte `locale TEXT`, est exemptee du
controle de base vide sur Android. Des tables de catalogue, une vue ou
une version/propriete inconnue restent bloquees. Le meme nom n'est jamais
exempte sur Windows. Le PRAGMA de timeout passe par `rawQuery`, compatible
avec les requetes SQLite natives Android qui retournent une ligne.
SQLite, `crypto` et `path` etaient deja des dependances du projet.

Le journal reutilise le schema 1 et le marqueur natifs du desktop : scopes
origine/compte/bibliotheque, intentions minimales et empreinte SHA-256,
limite 100 sans eviction, transactions exclusives, WAL et synchronisation
FULL. Les versions/proprietaires inconnus et toute base non marquee non vide
(y compris une vue seule) sont refuses sans conversion. Les entrees aux
formats/empreintes invalides ne sont ni rejouees ni supprimees implicitement.
L'empreinte detecte une incoherence, ce n'est pas une signature de securite.

`IlmsCirculationSync` propose `resolveMember`, `resolveCopy`, `enqueue`,
`list`, `checkout`, `returnCopy`, `retry` et `discard`. Il ne lit aucune
preference Render, n'enregistre pas d'appareil et ne lance ni minuteur ni
reprise automatique. Les commandes locales fonctionnent avec une session
native identifiee meme si le jeton est temporairement absent ; une reprise
HTTP exige un jeton courant valide dans le meme contexte.

- `enqueue` ne fait aucun HTTP et ne signifie pas une acceptation du pret.
  `checkout`/`returnCopy` sauvegardent aussi avant de tenter l'envoi.
- Verrou de 120 secondes et delai HTTP de 30 secondes. Une autre connexion
  SQLite ne peut envoyer/retirer une intention en cours. Apres expiration,
  un nouveau proprietaire peut la reprendre ; l'ancien ne peut acquitter
  ni liberer son verrou. Le serveur reste responsable de l'idempotence.
- Retour avec l'UUID du pret original seulement. Pas de recherche implicite
  d'un nouveau pret pendant la reprise. Les identites confirmees du pret,
  tags et echeance ne sont jamais remplacees par une nouvelle consultation.
- Apres un refus, une reponse invalide ou un timeout : intention conservee,
  verrou libere si possible et seulement statut HTTP numerique enregistre.
  Si le fichier est ferme/indisponible pendant l'acquittement, aucun succes
  n'est retourne. La demande persiste et reste reprenable apres expiration
  de son verrou, avec le meme UUID et contenu.
- Changement de session pendant une sauvegarde/liste/verrou ou pendant HTTP :
  aucune reponse de l'ancien contexte n'est exposee au nouveau compte.
  Une sauvegarde deja commencee peut rester dans l'ancien contexte, sans
  reprise automatique. Un acquittement deja valide peut avoir termine sa
  transaction avant le changement ; il n'est pas expose a la nouvelle session.
- `discard(id, confirmed: true)` demande une confirmation locale explicite.
  Cela ne fait aucun HTTP et n'annule jamais un pret sur le serveur.
- Fermer le service arrete son transport, pas le journal appartenant a
  l'appelant. Le fichier et ses demandes restent presents apres logout.
  L'appelant ferme la connexion SQLite lorsqu'elle n'est plus necessaire.

Le fichier mobile n'est pas chiffre par ces services. Protection de l'OS,
sauvegarde, retention et politique d'effacement des appareils restent a
definir avant exploitation. Ne pas effacer les donnees de l'application ou
son journal tant que des demandes sont en attente. Le filtrage par compte
ne protege pas contre un utilisateur ou code ayant acces au fichier.
Un demarrage offline, des fiches/catalogue offline et une autorisation de
lecteur hors ligne ne sont pas fournis par ce journal.

La regression locale utilise SQLite FFI sur le poste Windows. La recette
Android de tranche 11 utilise aussi le plugin SQLite natif sur CRUISE2 :
fermeture/reouverture du fichier verifiee, sans arret brutal du processus,
de l'OS ou perte d'alimentation. Ces controles, iOS et le cycle de vie complet
de l'application restent requis.

## Commande desktop

Depuis `BiblioRFID`, `npm.cmd run sync:ilms -- help` affiche l'aide sans
ouvrir de base ni contacter de serveur. Configuration du processus :

| Variable | Valeur attendue |
| --- | --- |
| `ILMS_GATEWAY_URL` | Origine HTTPS complete du gateway cible |
| `ILMS_ACCOUNT_ID` | UUID de la session ILMS courante |
| `ILMS_LIBRARY_ID` | UUID de la bibliotheque cible |
| `ILMS_JOURNAL_PATH` | Chemin explicite d'un fichier dedie ; jamais `library.db` |
| `ILMS_ACCESS_TOKEN` | Jeton courant, uniquement pour les commandes HTTP |

Faire fournir le jeton par le mecanisme local de session/gestion de secrets,
pas par un fichier versionne, une option de commande ou le chat. Cette
commande ne remplace pas encore un ecran de connexion ILMS.

| Commande | Entree et effet |
| --- | --- |
| `resolve-member` | Tags JSON sur stdin ; recherche native en ligne |
| `resolve-copy` | Tags JSON sur stdin ; exemplaire et pret actif natifs |
| `enqueue` | Intention JSON sur stdin ; sauvegarde seulement, aucun HTTP |
| `list` | Liste du contexte courant ; aucun HTTP |
| `retry <UUID>` | Envoi explicite du contenu sauvegarde ; meme UUID |
| `discard <UUID> --confirm-local-discard` | Retrait local seulement, aucun HTTP |

Entrees limitees a 4 Ko. Les tags contiennent EPC et/ou TID hexadecimaux
de longueur paire. Les recherches en ligne fournissent les UUID natifs a
conserver ; ne pas les deduire des identifiants Render. Exemple de forme
de demande, avec des identifiants **fictifs, inutilisables en recette reelle** :

```json
{
  "kind": "checkout",
  "payload": {
    "operation_id": "22222222-2222-4222-8222-222222222222",
    "card": {"epc": "AA12"},
    "copy": {"tid": "BB34"},
    "preferred_return_date": "2030-12-01T12:00:00.000Z",
    "expected_card_id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    "expected_member_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    "expected_copy_id": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
  }
}
```

Un retour a la forme `{"kind":"return","payload":{"copy":{"tid":"BB34"},"loan_id":"11111111-1111-4111-8111-111111111111"}}`.
`enqueue` annonce `accepted_by_ilms: false`. Seul `retry` avec une reponse
native valide annonce `accepted_by_ilms: true`. Une demande conservee
n'est pas un pret accepte hors ligne.

## Recette

Fixtures partagees dans `tests/fixtures/ilms-circulation-contract.json` :
UUID, tags, donnees minimales et dates UTC a la milliseconde identiques
entre JavaScript et Dart, y compris une entree a precision microseconde.
Les tests ne contactent que des serveurs loopback simules et utilisent
uniquement des comptes/jetons fictifs.

Tranche 9 : 134 tests Node SDK passes (38 nouveaux), 44 tests mobiles
passes (30 natifs et 14 regressions), analyse Dart ciblee sans probleme.
Ces tests Node ne sont pas relances lors de l'ajout du journal mobile.
Tranche 10 : 85 tests mobiles passent sur le code final, dont 41 du journal
et de la reprise, 30 du transport natif et les 14 regressions precedentes.
Journaux dans `C:/laragon/www/ilms-migration/.tools` :
`rfid-native-client-full-tests.log`, `rfid-native-mobile-regression-tests.log`
et `rfid-native-mobile-analyze.log` pour la tranche 9 ;
`rfid-mobile-journal-regression-final.log` et
`rfid-mobile-journal-analyze-final.log` pour la tranche 10.
Aucun build de distribution Electron
ou mobile ni authentification distante n'est valide par ces resultats.

Tranche 11 : 135 tests mobiles cibles passent sur le code final (35 connexion,
14 interface, 42 journal, 30 transport et 14 regressions), analyse Dart
sans probleme. Logs `rfid-mobile-native-ui-regression.log` et
`rfid-mobile-native-ui-analyze.log` ; captures
`rfid-mobile-ilms-login.png` et `rfid-mobile-ilms-station.png` dans `.tools`.
Le premier APK de tests a ete compile et installe, avec accord, sur CRUISE2
Android 11 avec le package distinct. La recette a revele le blocage lie a
la table systeme Android ; le code corrige passe la regression Windows.
Apres une tentative interrompue par la deconnexion USB, les trois tests
physiques passent sur CRUISE2 Android 11 avec le plugin SQLite natif.
Log `rfid-mobile-android-recipe.log` : catalogue fictif refuse et conserve,
commit avant HTTP/reouverture/reprise explicite du meme UUID, ouverture de
connexion/station sans appel metier automatique. Donnees et HTTP simules :
ce n'est pas une connexion OAuth reelle, un test de lecteur, une preuve de
resistance a une coupure brutale ou une validation de distribution mobile.

L'APK final sans lanceur de tests est compile depuis `main_ilms.dart`, avec
le code corrige : `.tools/bibliorfid-ilms-native-20261012.apk` dans le dossier
de migration. Son package et son activite ILMS ont ete verifies avec `aapt`.
Cette version est reinstallee avec succes apres les tests dans le seul
package `.ilms`, puis ouverte sans saisie d'identifiants. Activite au premier
plan verifiee avant la capture physique `rfid-mobile-cruise2-login.png`
(720 x 1440, sans debordement visible). L'application historique n'est pas
remplacee et ses donnees ne sont pas lues.
Les trois gardes Gradle contre un melange de cible/package/recette passent.
Log de build `rfid-mobile-ilms-apk-build.log` et gardes
`rfid-mobile-package-guard-*.log`. Les binaires restent des artefacts locaux
de recette, pas des fichiers a ajouter au depot Git.

Tranche 12 : correction du prefixe local Angular qui provoquait le 404 sur
le gateway direct. 136 tests mobiles cibles et 135 tests SDK passent, analyse
Dart ciblee sans probleme ; HTTP loopback avec routes exactes et 404 pour
les chemins inconnus. Logs `rfid-mobile-gateway-prefix-tests.log`,
`rfid-native-gateway-prefix-tests.log`, `rfid-mobile-gateway-prefix-analyze.log`.
L'ancien APK de tranche 11 conserve le prefixe incorrect : ne pas l'utiliser
pour retester la connexion distante. Le build corrige compile depuis
`main_ilms.dart` est `.tools/bibliorfid-ilms-gateway-20261012.apk` dans le
dossier de migration (log `rfid-mobile-gateway-prefix-apk-build.log`).
Manifest verifie, installation reussie dans le seul package `.ilms` sur
CRUISE2, demarrage a froid et activite au premier plan confirmes. Aucun
effacement du journal, aucune saisie ou lecture d'identifiants, aucune
tentative de connexion authentifiee au gateway. La connexion reelle reste
a retester par l'utilisateur. Debug de recette, pas distribution de production.
Les trois tests SQLite Android de tranche 11 ne sont pas relances ici.

Tranche 13 : l'utilisateur confirme le bon gateway et le portail
`https://ilms.bibliotheque-ztf.org`, mais signale encore HTTP 302. Les essais
anonymes repondent 401 ; un unique client OAuth fictif aleatoire repond 500
(Location `/oauth/token`, non suivie). Aucun essai avec les vrais secrets et
aucune reproduction du 302. Le diagnostic ajoute l'etape et la categorie de
redirection, sans changer le flux de connexion. 145 tests mobiles passes,
dont les 41 auth relances apres le dernier controle d'URL, analyse sans probleme.
Logs `rfid-mobile-auth-redirect-tests.log`, `rfid-mobile-auth-redirect-auth-final.log`
et `rfid-mobile-auth-redirect-analyze.log`. APK de diagnostic compile et
manifest verifie : `.tools/bibliorfid-ilms-auth-diagnostic-20261012.apk`
dans le dossier de migration, log `rfid-mobile-auth-redirect-apk-build.log`.
Mise a jour dans le seul package `.ilms` sur CRUISE2 reussie, demarrage a
froid et activite au premier plan confirmes, sans lecture/saisie de credentials.
Le message exact du prochain essai est demande a l'utilisateur. La cause
du 302 et la connexion reelle restent a valider ; ne pas presenter le
diagnostic comme un correctif serveur ou une distribution de production.

Recette Android avec donnees fictives, sans aucun appel au vrai gateway :

```powershell
$env:ORG_GRADLE_PROJECT_ILMS_STANDALONE = 'true'
$env:ORG_GRADLE_PROJECT_ILMS_RECIPE = 'true'
flutter.bat test integration_test/ilms_device_test.dart -d <id-du-telephone>
Remove-Item Env:ORG_GRADLE_PROJECT_ILMS_RECIPE
Remove-Item Env:ORG_GRADLE_PROJECT_ILMS_STANDALONE
```

Le second drapeau autorise le lanceur `listener.dart` genere par Flutter
uniquement en recette explicite. Le build refuse ce lanceur sans ce drapeau,
pour ne jamais installer silencieusement les tests sur le package historique.
Trois scenarios : refus d'un faux ancien catalogue sans alteration,
sauvegarde avant HTTP/reouverture/reprise manuelle avec plugin SQLite natif,
et ouverture de connexion/station sans appel metier automatique. Les bases
de recette aleatoires `ilms_recipe_<UUID>.db` sont distinctes du journal reel.

```powershell
# Depuis BiblioRFID
npm.cmd test
# Depuis Reader/myscankey_flutter
flutter.bat test --no-pub test/ilms_circulation_client_test.dart
flutter.bat test --no-pub test/ilms_circulation_journal_test.dart
dart.bat analyze lib/services/ilms_circulation_client.dart lib/data/ilms_circulation_journal.dart lib/services/ilms_circulation_sync.dart test/ilms_circulation_client_test.dart test/ilms_circulation_journal_test.dart
```

Sont couverts : journal reel entre connexions/processus distincts,
persistance avant HTTP, refus de la base historique, scope et verrous,
echecs reseau/serveur, identites divergentes, reponses mal formees,
retour sur le pret original, reprise explicite et absence de redirection
du Bearer. Le transport mobile est aussi teste sur du vrai HTTP loopback.
Le journal mobile est teste sur deux connexions SQLite reelles, avec
expiration/propriete du verrou, limite sous sauvegardes concurrentes,
refus d'une base historique, corruption et perte locale d'acquittement.
Les changements de contexte pendant le stockage et la perte locale de
jeton sont couverts : pas de reponse tardive ni de faux refus HTTP persiste.

Restent : session et interface Electron,
recette du gateway complet avec JWT signe, deploiement des extensions et
lecteur physique, recette OAuth distante, iOS et cycle de vie mobile complet.
Le catalogue offline, les inventaires, badges/presences,
portails, encodage et autres fonctions de l'inventaire de migration restent
des chantiers distincts. Aucun deploiement, import ou basculement Render.
