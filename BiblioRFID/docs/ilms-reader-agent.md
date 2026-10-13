# Agent lecteur ILMS, protocole 1

Cet agent est une premiere extraction du lecteur BIBLIORFID pour ILMS.
Il reutilise `ReaderService` et le pont C# existant. Il ne charge ni la base
SQLite, ni `SyncService`, ni les identifiants de l'ancien backend Render.
Le catalogue, les cartes et les prets restent des operations du backend ILMS.

## Etat actuel

- Registre natif disponible sous
  `/api/v1/libraries/{library_id}/rfid/devices` dans `library-service`.
- `GET` collection et `GET /{device_id}` : role operateur et autorisation
  explicite dans la bibliotheque, ou super-administrateur.
- `PUT /{device_id}` : super-administrateur uniquement. Corps :
  `{"name":"Lecteur accueil","transport":"usb","enabled":true}`.
  Transports : `usb`, `serial`, `tcp`. `enabled` est obligatoire.
- Meme `PUT` avec `enabled:false` pour desactiver ; avec `true` pour reactiver.
  L'UUID global n'est pas transferable a une autre bibliotheque, meme desactive.
  Les informations de creation sont conservees ; l'auteur de modification
  et les dates sont fournis par le serveur, jamais par le navigateur.
- L'UUID identifie la station, **ce n'est pas un secret ni une autorisation**.
- Dans Angular, l'onglet `Appareils RFID` de `Ma bibliotheque` permet au
  super-administrateur de creer/modifier la fiche et de confirmer un changement
  de statut. Aucun secret d'agent n'est enregistre dans cette fiche.
- La station `Circulation RFID` propose le choix d'appareil, l'appairage local,
  la connexion explicite et les scans recents. Le consommateur recontrole
  la fiche au moins toutes les cinq secondes et avant chaque choix de tag.
  Une fiche desactivee coupe la consommation des scans dans la page, pas le
  pont physique : aucune attestation materielle ni commande distante n'est
  promise. Les parcours manuels RFID ne sont pas bloques par ce registre.

## Demarrage local

Depuis `BiblioRFID`, dans un terminal local prive, definir :

```powershell
$env:ILMS_AGENT_ORIGIN = 'http://127.0.0.1:4200'
$env:ILMS_AGENT_LIBRARY_ID = '<UUID de la bibliotheque ILMS>'
$env:ILMS_AGENT_DEVICE_ID = '<UUID de la station enregistree dans ILMS>'
$env:ILMS_AGENT_TOKEN = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
npm.cmd run agent:ilms
```

La cle reste dans l'environnement du terminal ; ne pas la mettre dans Git,
une URL, un journal ni le chat. Une nouvelle cle exige un nouvel appairage
du client. Il n'y a pas de conservation automatique de cette cle dans le
navigateur. L'agent ne genere ni n'affiche de cle.

Origine HTTPS exacte pour un ILMS distant ; HTTP uniquement pour localhost,
127.0.0.1 ou ::1. Aucun chemin, joker, identifiant ou origine `null` accepte.
Le navigateur doit utiliser exactement cette origine, port compris.
Le serveur ecoute uniquement `127.0.0.1`, port 4316 par defaut
(`ILMS_AGENT_PORT` permet un port libre entre 1024 et 65535).
`BIBLIORFID_BRIDGE_DIR` permet de choisir le dossier du pont natif.

Le demarrage de l'agent n'ouvre pas le lecteur. Fermer la connexion de
l'ancien logiciel avant une connexion explicite de l'agent : le lecteur
ne doit pas etre pilote par les deux logiciels simultanement.

## Appairage Dans ILMS

Dans `Circulation RFID`, selectionner l'appareil actif, l'adresse HTTP
`127.0.0.1:<port>` exacte de l'agent et la cle dans le champ masque.
L'appairage controle d'abord la fiche ILMS, puis l'identite et la version
du protocole annoncees par l'agent, sans ouvrir le lecteur. La cle est
retiree du formulaire apres succes, gardee seulement en memoire et n'est
pas transmise aux services ILMS. Un `HttpClient` construit sur `HttpBackend`
contourne les intercepteurs ILMS : aucun JWT ILMS ni refresh d'identite
ne passe par l'agent local.

La connexion se fait ensuite explicitement, avec un endpoint USB optionnel,
un port COM ou une IP privee avec port selon le transport de la fiche.
Une connexion existante annoncee lors de l'appairage n'est pas adoptee :
il faut creer une nouvelle session de scans depuis cette page.

Les tags recents sont affiches separement (au plus 16 identifiants distincts).
Choisir explicitement `carte` ou `exemplaire` pour lancer l'identification
native ; aucun pret/retour n'est declenche par le polling. En mode retour,
le choix `carte` n'est pas propose. La confirmation metier reste separee.

Une selection expire 30 secondes apres son scan. Une perte de curseur,
session invalide, refus ILMS ou erreur reseau vide les scans et les selections
issues du lecteur. Les saisies manuelles sont conservees. Une nouvelle
connexion et une nouvelle selection sont requises ; pas de reprise
automatique des scans. Une demande de circulation deja confirmee est
conservee dans le journal IndexedDB de la station, avec son contenu et son
UUID d'origine. Sa reprise est explicite et passe par ILMS ; elle ne
restaure ni une session de scans ni la cle de l'agent. Voir la tranche 7
de `migration-bibliorfid-ilms.md` pour les limites de stockage/offline.

Changer de bibliotheque, se deconnecter d'ILMS ou quitter la page efface
l'appairage en memoire et annule les requetes et le polling. Cela ne coupe
pas automatiquement le pont physique. Le bouton de deconnexion arrete
explicitement le lecteur ; `Oublier l'appairage` oublie seulement la cle et
la session de la page, sans commande materielle en arriere-plan.

## Contrat HTTP Local

Chaque appel exige l'en-tete `Origin` configure et
`Authorization: Bearer <cle locale>`. La cle n'est jamais un JWT ILMS et
ne permet pas d'appeler le backend. Le `Host` attendu est
`127.0.0.1:<port>` et le client doit etre sur le loopback IPv4.
Pas de cookies, pas d'authentification via parametre d'URL.

Les preflights OPTIONS sont limites a l'origine configuree, GET/POST,
Authorization et Content-Type. La demande Private Network Access est
acceptee uniquement dans ce cadre. Le navigateur peut imposer sa propre
permission d'acces au reseau local ; ne pas desactiver sa securite.

- `GET /v1/status` : version, UUID appareil/bibliotheque, capacite `read`,
  connexion, `session_id`, `cursor`, `busy`. Pas de secret ni de chemin USB.
- `POST /v1/reader/connect`, JSON : `{"type":"usb","endpoint":""}`
  pour la selection USB native ; endpoint USB explicite possible.
  Serie : `{"type":"serial","endpoint":"COM3"}`.
  TCP : `{"type":"tcp","endpoint":"192.168.1.10:6000"}`.
  TCP limite aux IP litterales des reseaux prives 10/8, 172.16/12,
  192.168/16 ; aucune resolution DNS ni adresse publique/link-local.
  L'endpoint reste local, il n'est pas enregistre dans ILMS.
- `POST /v1/reader/disconnect`, JSON `{}` : deconnexion et invalidation
  des scans. Pas de corps supplementaire accepte.
- `GET /v1/reader/tags?session_id=<session>&after=<cursor>` : lectures
  apres ce curseur, nouveau curseur et meme session. Chaque tag contient
  `sequence`, `received_at` UTC, EPC/TID normalises, RSSI/antenne si valides.
  Plusieurs tags restent plusieurs tags ; aucun choix implicite du premier.

Chaque connexion explicite cree une nouvelle session, meme si le pont
reutilise la meme connexion. Commencer au curseur renvoye par cette
connexion. Les lectures sont rejouables pendant une fenetre de 30 secondes,
limitee a 256 evenements. Doublons EPC+TID filtres pendant 750 ms.
Les scans malformes sont ignores. Une perte de curseur, session changee,
deconnexion ou commandes concurrentes donne 409, sans scan de substitution.

Le client doit alors invalider sa selection, relire le statut et demander
une nouvelle lecture explicite. Ne pas reutiliser un ancien tag, le traiter
comme un pret confirme ni le soumettre automatiquement au retour reseau.
Les commandes metier restent des confirmations distinctes dans ILMS.

Autres erreurs : 400 entree invalide, 401 cle absente/incorrecte,
403 origine/Host refuse, 404 route inconnue, 413 corps trop volumineux,
415 corps non JSON, 503 pont indisponible. Les diagnostics natifs ne sont
pas transmis au navigateur. Le corps JSON est limite a 4 Ko.

Aucune route d'encodage, effacement, bip, pret/retour, configuration distante
ou arret du processus n'est exposee. SIGINT/SIGTERM ferme seulement cet
agent et son pont. Le journal durable de circulation est dans Angular,
pas dans cet agent. Le cache facultatif des fiches consultees (tranche 8)
est egalement dans Angular, sans pret actif ni nom d'adherent et sans cle
d'agent. Le nouveau client desktop et son journal SQLite sont separes de
cet agent, comme le transport et le journal mobiles natifs (voir
[clients de circulation](ilms-circulation-client.md)). La nouvelle entree
mobile ILMS branche session et circulation manuelle sans charger les anciens
ponts materiels. La session/interface Electron, la lecture mobile physique
et le catalogue complet offline/PWA restent a realiser.

## Recette

```powershell
npm.cmd test
npm.cmd run test:agent:browser
npm.cmd run test:agent:bridge
```

Le premier teste l'agent HTTP avec un pont simule et les regressions SDK.
Le second utilise Edge et des serveurs loopback isoles, avec lecteur simule
et reseau externe bloque : origine autorisee, preflight, scans, cle invalide,
origine hostile et absence de route d'ecriture.
Le troisieme demarre le vrai pont Windows et lui demande son statut puis
son arret, **sans connexion au lecteur**. Il ne valide pas USB, serie,
TCP materiel, encodage, buzzer ni presence physique.

Les tests PostgreSQL opt-in de `library-service` appliquent la migration
0005 sur une base locale isolee, utilisent le vrai repository R2DBC et
verifient l'affectation concurrente, les contraintes et le rollback.
Les JWT signes via le gateway et une lecture physique restent a valider.
