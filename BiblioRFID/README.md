# Bibliotèque ZTF

Application locale de catalogage et d’encodage RFID UHF pour le lecteur de bureau fourni dans ce workspace.

## Démarrage

Depuis PowerShell :

```powershell
cd "C:\Données\STAGE BCM\sdks\BiblioRFID"
.\start.ps1
```

L’application est ensuite disponible sur `http://127.0.0.1:4310`. Les données restent dans `data/library.db` sur le poste.

Au premier lancement, Bibliotèque ZTF demande de créer le compte administrateur. Toutes
les routes de catalogue, RFID, historique et paramètres exigent ensuite une session
valide. Les mots de passe sont dérivés avec `scrypt` et les cookies de session sont
`HttpOnly` et `SameSite=Strict`.

## Application Windows

La version Windows utilise une fenêtre Electron autonome : elle ne lance pas le
navigateur par défaut. Le serveur RFID reste local et invisible, tandis que la base
active est conservée dans le profil Windows de l’utilisateur.

```powershell
npm run desktop
npm run build:desktop
```

L’exécutable portable est produit dans `dist-desktop`.

## Personnel et portail antivol

- **Personnel** : fiche (matricule, nom, fonction, contact) et **encodage du badge** RFID
  comme pour une carte d’abonné (un seul tag posé, écriture vérifiée par relecture du
  TID). Le badge a son propre format EPC « BCM » 3 : il n’est jamais pris pour un livre
  ni pour une carte, et un tag déjà livre, carte ou badge d’un autre est refusé. Un
  membre désactivé n’est plus reconnu au portail.
- **Portail antivol** : entrées, sorties et alarmes du jour (ou d’un jour choisi),
  passages du personnel, présence (arrivée, dernier passage, présent/parti) et
  fréquentation des 30 derniers jours. Ces données viennent des portails (application
  Android, rôle « Portail antivol ») par la synchronisation.

## Synchronisation distante

La version desktop partage désormais son catalogue avec l’application mobile par
l’API Kotlin. Dans **Paramètres > Synchronisation distante**, renseignez :

- l’adresse `https://bztf.onrender.com` ;
- la même clé que la variable `BIBLIORFID_API_KEY` configurée sur Render ;
- un nom permettant d’identifier le poste.

Le bouton **Enregistrer** teste la connexion et lance la première synchronisation.
Les créations, modifications, encodages et suppressions sont ensuite envoyés en
arrière-plan. Une file SQLite locale conserve les opérations pendant les coupures
Internet, avec reprise automatique toutes les 60 secondes et notification en temps
réel par WebSocket lorsqu’un autre appareil modifie le catalogue.

Dans l’application Windows empaquetée, la recompilation du pont utilise la copie
native extraite dans le profil `%APPDATA%\biblio-rfid\native`. Le contenu de
`app.asar` reste ainsi en lecture seule.

## Premier essai

1. Ouvrir **Paramètres**, choisir **Simulation**, puis enregistrer.
2. Revenir dans **Station RFID** : la lecture est automatique.
3. Un tag connu affiche immédiatement son livre. Pour un tag inconnu, choisir **Enregistrer le livre**.
4. Sélectionner un titre proposé pour écrire immédiatement le tag, ou compléter le formulaire d’un nouveau livre avant validation.
5. Pour le lecteur réel, fermer d’abord le logiciel `GReaderDemo`, sélectionner **USB HID**, rechercher les lecteurs et tester la connexion.

## Lecture permanente

La station garde une seule connexion ouverte avec le lecteur et reçoit les tags en continu. Le navigateur est alimenté par un flux local SSE : aucune relance du pilote ni fenêtre de lecture de deux secondes n'est nécessaire entre deux livres. Un nouveau tag est regroupé pendant environ 140 ms pour permettre l'identification multiple, puis affiché et signalé par un bip unique.

Le mode **Suspendre** ferme seulement le flux d'affichage de la page. Le service RFID local reste prêt, sauf lorsque l'application est arrêtée ou que le type de connexion change.

## Catalogage assisté (OCR, notices, IA)

L'onglet **Catalogage** remplace la saisie manuelle d'une fiche par une chaîne
photo → OCR → recherche de notice → vérification → encodage du tag.

### Un livre à la fois

1. Photographier la première de couverture, puis la quatrième (et la page de
   titre si besoin) : webcam, import de fichiers ou glisser-déposer. Chaque
   photo est réduite dans le navigateur avant envoi (1600 px pour l'OCR,
   320 px pour la vignette).
2. L'OCR s'exécute automatiquement sur chaque photo et affiche son taux de
   confiance.
3. **Identifier ce livre** cherche l'ISBN dans le texte reconnu — clé de
   contrôle vérifiée — puis interroge, dans l'ordre, la BnF (SRU, UNIMARC), le
   SUDOC, Open Library et Google Books. Sans ISBN lisible, la recherche se fait
   par titre et auteur. Un ISBN déjà présent au catalogue est signalé avant
   toute création.
4. La fiche proposée reste modifiable, et une autre notice candidate peut être
   choisie : la cote, la catégorie et les notes saisies par le catalogueur sont
   conservées.
5. **Enregistrer puis encoder le tag** crée la fiche, bascule sur la station et
   écrit le tag dès qu'un seul tag est posé sur le lecteur. L'écriture reste
   celle de la station : ciblage du TID et contrôle par relecture.

Les photos sont conservées dans `<données>/covers` et affichées dans la fiche du
livre. Les photos d'un catalogage abandonné sont purgées après 48 heures.

### En lot

Un lot regroupe plusieurs livres photographiés à la chaîne : on ajoute un livre,
on le sélectionne, on le photographie, puis on passe au suivant. **Analyser le
lot** déroule l'OCR, la recherche et l'IA pour chaque livre, livre après livre.

**Aucun tag n'est écrit en lot** : l'écriture suppose un tag unique posé sur le
lecteur, ce qui ne peut se vérifier que livre par livre. Les fiches rejoignent
donc le catalogue en **brouillon « à encoder »**, repérées dans la liste du
catalogue, et sont encodées ensuite à la station.

### Moteur OCR

Dans **Paramètres > Reconnaissance de texte** :

- **Tesseract** (par défaut) : moteur WebAssembly embarqué, données de langue
  dans `vendor/tessdata`. Fonctionne sans Internet et sans installation.
- **Google Vision** : plus précis sur les couvertures stylisées ; nécessite une
  clé API et envoie les photos à Google.

Les langues reconnues se règlent par codes ISO 639-2 séparés par `+`
(`fra+eng` par défaut). Une seule reconnaissance s'exécute à la fois pour que la
station RFID reste réactive pendant un catalogage en lot.

### Assistance IA

Désactivée par défaut. Une fois activée dans **Paramètres > Assistance IA**
(fournisseur Claude, DeepSeek ou ChatGPT, modèle et clé), cinq rôles s'activent
séparément :

| Rôle | Ce qu'il fait |
| --- | --- |
| Structuration OCR | transforme le texte reconnu en champs bibliographiques |
| Arbitrage | choisit la notice correspondant à l'exemplaire en main |
| Complétion | propose catégorie, cote, indice Dewey et vedettes matière |
| Contrôle qualité | signale les incohérences avant enregistrement |
| Lecture des photos | lit les images quand l'OCR ne rend rien (Claude ou ChatGPT) |

Rien n'est envoyé tant qu'un rôle n'est pas coché : le texte OCR part pour les
quatre premiers rôles, les photos uniquement pour le dernier. L'IA ne décide
jamais seule — elle remplit des champs vides et justifie ses choix, la
validation reste celle du catalogueur. Une panne ou un quota dépassé n'arrête
pas le catalogage : le rôle concerné est signalé et la chaîne continue.

Les préfixes de cote par genre, utilisés par le rôle de complétion, se règlent
dans le même écran (`Roman=R`, une ligne par genre).

### Clés et données

Les clés API Google Vision et IA sont stockées dans la base locale et ne sont
jamais renvoyées au navigateur ni à la synchronisation distante : l'interface
n'affiche que leur présence. Les champs bibliographiques ajoutés (sous-titre,
collection, langue, résumé, vedettes matière, Dewey, édition, pagination,
source de la notice) restent locaux au poste ; le contrat de synchronisation
avec l'application mobile est inchangé.

### À venir

Le dépôt des photos depuis l'application mobile, puis le pilotage d'un scanner
à plat (TWAIN/WIA), sont prévus après cette première étape.

## Import du catalogue XLSX

Dans **Catalogue**, choisir **Importer XLSX**, puis sélectionner le classeur. L'import accepte le format fourni avec les colonnes `BATIMENT`, `SALLE`, `SECTION`, `ETAGERE`, `NUMERO DE BLOC`, `CATEGORIE`, `TITRE`, `AUTEURS`, `SOUS_CATEGORIE`, `DATE_PUBLICATION`, `EDITEUR`, `PAGES`, `ISBN`, `IMAGE`, `TYPE DE DOC`, `LANGUE`, `RESUME` et `RFID`.

La localisation combine le bâtiment, la salle, l'étagère et le bloc. La sous-catégorie devient la catégorie principale; les informations complémentaires sont conservées dans les notes. Pour les lignes historiques de la section Bible où `TITRE` contient seulement un numéro, la valeur de `AUTEURS` est automatiquement utilisée comme titre. Une seconde importation du même classeur ignore les notices déjà importées.

Le catalogue charge 200 lignes à la fois afin de rester fluide avec les 11 000 notices du fichier fourni. Le bouton **Charger plus** affiche la suite.

## Prérequis

- Windows avec Node.js 22 ou ultérieur pour le mode développement ;
- .NET Framework 4.x présent sur Windows pour compiler le pont ;
- `GReaderApi.dll` conservée à son emplacement dans `RFID Desktop Reader SDK-EN`.

Le script `start.ps1` installe les icônes locales si nécessaire, compile `bridge/ReaderBridge.cs`, puis démarre le serveur local.

## Configuration du buzzer

La page **Paramètres** permet de choisir entre le **Buzzer natif** du firmware et une **Impulsion contrôlée** par commandes marche/arrêt. Elle permet aussi de modifier le maintien de l'impulsion en millisecondes et le délai de réarmement en secondes. Le bouton **Recompiler et appliquer** valide les valeurs, génère `bridge/BridgeSettings.cs`, recompile le pont puis reconnecte automatiquement le lecteur.

La commande de compilation équivalente, à exécuter depuis le dossier `BiblioRFID`, est :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\build.ps1
```

## Sécurité d’écriture

Le pont impose un seul tag dans la zone, cible son TID lors de l’écriture et vérifie l’EPC par relecture. Le détail du flux est consigné dans [PROTOCOL.md](./PROTOCOL.md).
