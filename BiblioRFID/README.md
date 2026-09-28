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

## Premier essai

1. Ouvrir **Paramètres**, choisir **Simulation**, puis enregistrer.
2. Revenir dans **Station RFID** : la lecture est automatique.
3. Un tag connu affiche immédiatement son livre. Pour un tag inconnu, choisir **Enregistrer le livre**.
4. Sélectionner un titre proposé pour écrire immédiatement le tag, ou compléter le formulaire d’un nouveau livre avant validation.
5. Pour le lecteur réel, fermer d’abord le logiciel `GReaderDemo`, sélectionner **USB HID**, rechercher les lecteurs et tester la connexion.

## Lecture permanente

La station garde une seule connexion ouverte avec le lecteur et reçoit les tags en continu. Le navigateur est alimenté par un flux local SSE : aucune relance du pilote ni fenêtre de lecture de deux secondes n'est nécessaire entre deux livres. Un nouveau tag est regroupé pendant environ 140 ms pour permettre l'identification multiple, puis affiché et signalé par un bip unique.

Le mode **Suspendre** ferme seulement le flux d'affichage de la page. Le service RFID local reste prêt, sauf lorsque l'application est arrêtée ou que le type de connexion change.

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

La page **Paramètres** permet de choisir entre le **Buzzer natif** du firmware et une **Impulsion contrôlée** par commandes marche/arrêt. Elle permet aussi de modifier le maintien de l'impulsion et le délai de réarmement en millisecondes. Le bouton **Recompiler et appliquer** valide les valeurs, génère `bridge/BridgeSettings.cs`, recompile le pont puis reconnecte automatiquement le lecteur.

La commande de compilation équivalente, à exécuter depuis le dossier `BiblioRFID`, est :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bridge\build.ps1
```

## Sécurité d’écriture

Le pont impose un seul tag dans la zone, cible son TID lors de l’écriture et vérifie l’EPC par relecture. Le détail du flux est consigné dans [PROTOCOL.md](./PROTOCOL.md).
