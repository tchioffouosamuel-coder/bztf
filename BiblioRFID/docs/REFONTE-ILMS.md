# Refonte ILMS — spécification de référence

> État : spécification arrêtée le 18 octobre 2026. Elle fige l'inventaire des
> trois sources **avant** la purge de la couche ILMS de BiblioRFID, pour
> qu'aucune fonction ni aucun contrat ne se perde en route.

## La cible en une page

```
   ┌─────────────────────────────────────────────────────────────────┐
   │  FRONTEND ILMS  (C:\laragon\www\ilms — Angular 19, réécrit)     │
   │  catalogue · circulation · lecteurs · récolement · qualité      │
   │  kiosque · étiquettes · tableau de bord · comptes · matériel    │
   └───────────────────────────┬─────────────────────────────────────┘
                               │ HTTPS + WebSocket
                               ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  gateway.bibliotheque-ztf.org                                   │
   │  gateway-service → auth-service · library-service               │
   │  Spring Boot 3 / Java 21 · PostgreSQL · Elasticsearch · RabbitMQ│
   │  cœur métier = Nouveau dossier (3.0) + cœur BiblioRFID          │
   └───────────────────────────┬─────────────────────────────────────┘
                               │ HTTP local + SSE  (contrat natif)
                               ▼
   ┌──────────────────────┐          ┌───────────────────────────────┐
   │  BiblioRFID (poste)  │          │  myscankey_flutter (Android)  │
   │  pur service matériel│          │  lecteur UHF Seuic · portail  │
   │  USB/série/TCP · OTA │          │  N01 · scanner optique        │
   └──────────────────────┘          └───────────────────────────────┘
```

Trois chantiers, dans cet ordre :

| # | Chantier | Dépôt | État |
|---|---|---|---|
| 1 | Purge de la couche ILMS | `sdk/BiblioRFID` | à faire |
| 2 | Nouveau cœur métier sur le socle | `library-service`, `gateway-service`, `auth-service` | à faire |
| 3 | Frontend réécrit de zéro | `C:\laragon\www\ilms` | à faire |

Décisions arrêtées :

- L'ILMS actuel **n'est pas** une référence fonctionnelle. Il est vidé et refait.
  La référence, c'est `Nouveau dossier` (version POSTGRES 3.0) plus la couche
  matériel de BiblioRFID et de `Reader/myscankey_flutter`.
- Le nouveau backend garde **le socle et l'architecture déjà posés sur GitLab** :
  mêmes services, même découpage hexagonal, mêmes conventions. On remplace le
  cœur métier, pas la fondation.
- Plus aucun paramétrage de passerelle côté poste : `gateway.bibliotheque-ztf.org`
  est la seule adresse, câblée en dur.

---

## 1. Source A — `Nouveau dossier` (VERSION POSTGRES 3.0)

Application Python/tkinter, ~14 400 lignes dans `DEVELOPPEUR/src/`, archive du
25 septembre 2026, 18 suites de tests toutes réussies. Base de référence :
**73 223 exemplaires** (`BASE/bztf catalogue migre 2026-09-25.dump`), mesurée
jusqu'à **1 025 122 exemplaires** (703 752 œuvres).

### 1.1 Le modèle de données

22 tables (`schema.py`) :

| Domaine | Tables |
|---|---|
| Catalogue | `exemplaire`, `oeuvre`, `oeuvre_sale`, `oeuvre_stat`, `theme`, `auteur`, `vocabulaire` |
| Circulation | `pret`, `lecteur`, `mouvement` |
| Récolement | `recolement`, `recolement_scan` |
| Poste public | `consultation_recherche`, `consultation_vue`, `suggestion`, `selection` |
| Exploitation | `parametre`, `poste`, `import_lot` |
| Sécurité | `utilisateur`, `connexion`, `secours` |

Trois notions à ne jamais confondre, et c'est structurant pour l'API :

- **exemplaire** — un livre physique, identifié par son `code_barre` ;
- **œuvre** — un titre + un auteur ; plusieurs exemplaires la partagent ;
- **couverture** — attachée à l'**œuvre**, jamais à l'exemplaire.

La cote et le code-barres ne jouent pas le même rôle :

```
A - E44 - B3 - S13 - 0007
│    │     │     │     └─ rang dans le bloc
│    │     │     └─────── série (numéro de bloc)
│    │     └───────────── bloc (emplacement sur l'étagère)
│    └─────────────────── étagère
└──────────────────────── bâtiment
```

**La cote suit l'emplacement** (elle change si le livre change de rayon) ; le
**code-barres ne change jamais** (c'est l'identité du livre). À l'import, les
codes-barres d'un fichier sont conservés ; une cote déjà prise est réattribuée
dans le même bloc.

### 1.2 Les garanties que la base doit tenir elle-même

Ce sont des invariants mesurés, à reproduire tels quels :

- **Un livre ne peut pas être prêté deux fois** : index unique sur les prêts
  ouverts (`idx_pret_ouvert`). Mesuré : 4 comptoirs prêtent le même livre à la
  même seconde, 5 fois de suite → un seul prêt accepté, 3 refus propres
  (« déjà emprunté »). Retours simultanés : un seul compté.
- **Codes-barres et cartes de lecteur** tirés de séquences communes : 4 postes
  créent 100 livres en même temps → 100 codes différents. La séquence se cale
  sur les codes existants (migration, codes venus d'un fichier).
- **Tout ou rien** : chaque prêt, retour, modification, paquet d'import est une
  transaction ; un poste ne voit jamais une opération à moitié faite.
- Principe directeur : **la base garantit, le code vérifie en plus**. Le code
  donne le message clair, l'index tranche la course. Une erreur d'intégrité
  redevient « déjà emprunté ».

### 1.3 Fonctions à porter, écran par écran

Dix onglets dans l'application d'origine. Chacun devient une zone du frontend
et un ensemble d'endpoints.

| Onglet | Ce qu'il fait | Points durs |
|---|---|---|
| **Catalogue** | recherche, fiche, vignette | recherche différée de 250 ms |
| **Ajouter** | saisie, cote calculée en direct | séquence de code-barres partagée |
| **Prêts** | comptoir : modes F2/F3, lecteur par carte ou par nom, prolongation, annulation | **jamais de fenêtre bloquante** : la douchette taperait dedans. Message dans le bandeau + bip |
| **Lecteurs** | comptes lecteurs, cartes | |
| **Récolement** | étagère entière **ou un seul bloc** ; quatre verdicts ; campagnes archivées | un livre de la même étagère mais d'un autre bloc est « déplacé (même étagère, mais bloc C1) », pas « inconnu » |
| **Outils** | doublons, couvertures, étiquettes, catégories, contrôle qualité | étiquettes : un seul PDF pour tout le fonds, ou un PDF par étagère |
| **Import / Export** | lecture en arrière-plan → correspondance des colonnes → contrôle qualité → import ; vidage protégé | toute colonne utile doit figurer dans l'export **et** ses alias, sinon un cycle export→réimport la perd |
| **Tableau de bord** | chiffres, thèmes, nouveautés | `statistiques()` mémorisée, sinon 3 × 0,5 s après chaque prêt |
| **Consultation** | fréquentation du poste public, suggestions, coups de cœur, réglages | |
| **Comptes** | comptes, clé de secours, connexions, journal d'activité, **Postes** | administrateurs seulement |

### 1.4 Le moteur de recherche

C'est le cœur de l'expérience et la partie la plus facile à rater.

- **Normalisation** — `nz("L'Église  Primitive ")` → `"l eglise primitive"`.
  Chaque exemplaire porte trois colonnes calculées : `titre_cle`, `auteur_cle`,
  et `recherche` (titre + auteur + cote + codes-barres + ISBN, normalisés).
  **Toute écriture touchant `titre`, `auteur`, `cote` ou `isbn` doit les
  reconstruire.**
- **Index plein texte PostgreSQL** : `tsvector` pondéré (titre, auteur, codes,
  résumé), `ts_rank`. Sur le fonds réel, « prayer » → 2 740 livres.
- **Un morceau de mot se trouve** (« christ » trouve « antichrist ») *avant*
  qu'on parle de faute. Les fautes de frappe se corrigent ensuite par les
  trigrammes (`pg_trgm`) du vocabulaire des titres et auteurs, et la correction
  n'est annoncée que si elle trouve des livres.
- **Scores** : titre exact 60, équivalent anglais 50, début de mot 45,
  sous-chaîne 25 ; auteur 50/20 ; thème 12 ; code 30 ; résumé 4. Bonus
  d'expression : titre exact sans article +1000, commence par la recherche
  +500, la contient +250, plus la part du titre couverte.
- **Synonymes anglais en mot entier** : fonds anglophone, interface française.
  « priere » seul → 3 livres ; avec les synonymes → 1 281 œuvres.
- **Signature d'auteur** (mots triés) : réunit « Nee, Watchman » et
  « Watchman Nee ».
- **Disponibilité** relue à chaque recherche (prêts ouverts), sans reconstruire.
- **Accès direct** : code-barres, cote ou ISBN exacts par index.
  Attention : `WHERE code_barre=? OR cote=?` rend l'index partiel inutilisable
  (58 ms de parcours complet) → **deux requêtes** (0,02 ms).

Le socle a déjà Elasticsearch ; le choix index PG vs Elasticsearch est à
trancher au chantier 2 (voir §5).

### 1.5 Le contrôle qualité d'un catalogue

Chaîne : `lire_classeur()` → correspondance des colonnes → `controler_contenu()`
→ écran de contrôle → import avec corrections, **ou** écriture d'une copie
corrigée.

Règles à ne pas trahir :

- **On contrôle tout, on ne corrige que ce qui est coché**, et seulement sans
  ambiguïté. Le contrôle ne modifie rien : il note des *actions*, rejouées
  ensuite sur une **copie** des lignes, dans un ordre fixe (l'inversion
  titre/auteur passe après le nettoyage des espaces).
- Le numéro de ligne est celui **dans le fichier Excel** : c'est ce qui permet de
  dire « ligne 245 » et d'écrire la copie corrigée cellule par cellule.
- Une ligne compte **une fois par contrôle**, même si deux de ses cases sont en
  cause.
- Les en-têtes ne sont pas supposés en ligne 1 : on cherche la ligne qui porte
  les champs parmi les 20 premières.
- Contrôler en « ajout » un catalogue déjà en place produit 73 223 signalements
  « déjà utilisé » qui noient le reste → une mise en garde claire en tête.
- Les images sont cherchées en lisant chaque dossier **une seule fois** :
  60 000 lignes passent de 13 s à moins d'une seconde.

### 1.6 Couvertures : le chemin fait foi

Le chemin enregistré fait foi, quel que soit le nom du fichier ou du dossier ;
aucune nomenclature n'est exigée. La résolution essaie, dans l'ordre : chemin
absolu, puis relatif au dossier du dernier Excel importé, à la racine des
images, à l'application, à la base, puis à leurs dossiers parents niveau par
niveau — la dernière base qui a servi en premier.

- Un chemin se nettoie avec un nettoyeur **dédié aux chemins** : le nettoyeur
  général fusionne les espaces intérieurs et rend introuvable un fichier dont le
  nom en contient deux de suite.
- Le rattachement par nom ne tourne **que si le fichier n'a aucune colonne
  d'image** : sinon une case laissée vide exprès serait remplie d'office.
- Une case vide ne retire jamais une image par défaut : un fichier incomplet ne
  doit pas effacer en silence.
- Rattachement automatique de secours, par nom de fichier
  (`OEU-xxxxx__titre-slug__auteur-slug.jpg`) : par identifiant d'œuvre (sûr),
  par titre + auteur (préfixes 40 et 20 caractères), et **titre seul désactivé
  par défaut** — mesuré sur le fonds réel, il se trompait une fois sur deux.
- Les images pèsent ~1 Mo : jamais chargées en pleine taille, vignette
  fabriquée une fois et gardée en cache (80 entrées).

### 1.7 Sécurité et comptes

- Deux rôles. `administrateur` : `comptes`, `import`, `remplacer`, `vider`,
  `restaurer`, `parametres`, `consultation_reglages`. `bibliothecaire` : la
  gestion courante du catalogue, rien de plus.
- Empreintes **PBKDF2-HMAC-SHA256**, jamais de mot de passe en clair. Blocage
  après échecs répétés, limité aussi **par appareil**.
- **Clé de secours** : 20 caractères sans ambiguïté (ni O/0 ni I/1), soit
  100 bits, remise **une seule fois**, à noter sur papier ; seule son empreinte
  est gardée.
- Message d'échec **générique** (« Identifiant ou mot de passe incorrect »).
- Les droits sont vérifiés **deux fois** : les boutons sont grisés *et* chaque
  action revérifie le droit.
- L'opérateur connecté est tracé (`mouvement.qui`) : l'historique dit qui a
  modifié quoi. Les prêts, recherches et suggestions notent aussi le poste.
- Toute action destructrice : confirmation **puis un mot à taper**, et
  sauvegarde automatique avant.
- Verrouillage automatique après N minutes sans activité — **jamais** pendant
  une tâche longue.

### 1.8 Le service mobile (déjà une application web)

C'est la pièce la plus directement transposable : l'application mobile de la 3.0
est **déjà** une application web servie en HTTPS, sans store.

| Pour qui | Fonctions |
|---|---|
| Tout le monde | chercher (mêmes règles que le poste public : fautes, français ↔ anglais, thèmes), couverture, disponibilité, **où le livre se range** ; scanner un ISBN pour le trouver |
| Le personnel | fiche d'un livre scanné (emprunteur, échéance, historique) ; prêt (carte puis livres à la suite) ; retour (dit où ranger) ; prolongation ; annulation ; **récolement** d'une étagère ou d'un bloc |

- La caméra sert de douchette ; une douchette Bluetooth et le clavier marchent
  aussi. Lecteur intégré sur Android, ZXing sur iPhone.
- **Récolement hors réseau** : dans un rayon sans Wi-Fi, les scans attendent
  dans le téléphone et partent seuls au retour du réseau, **avec leur heure
  d'origine**. À reproduire impérativement (PWA + file d'attente locale).
- Les téléphones ne touchent jamais la base : le service passe par les mêmes
  fonctions que les postes. Une règle de prêt vaut donc partout à l'identique.
  Mesuré : 12 prêts simultanés sur 3 connexions, tous passés ; 5 téléphones
  prêtant le même livre, un seul prêt.
- Session : cookie HttpOnly / Secure / SameSite=Strict ; compte désactivé coupé
  aussitôt.

### 1.9 Multi-postes et temps réel

- **Avis du serveur** (LISTEN/NOTIFY) : un livre ajouté, un prêt, un index remis
  à jour sur un poste sont aussitôt connus des autres. Canaux `catalogue`,
  `index`, `prets`. → dans la cible, c'est le WebSocket de la passerelle
  (`infrastructure/ws`) et/ou RabbitMQ.
- **Jamais d'état partagé en mémoire entre postes** : tout cache est invalidé
  par les avis.
- **Un seul poste met l'index à jour** à la fois (verrou serveur
  `pg_try_advisory_lock`) ; les autres passent leur tour ; rien n'est perdu si un
  poste écrit pendant la mise à jour.
- **Comptes › Postes** : qui utilise la base, depuis quand, avec quelle version
  (en orange : à mettre à jour). Chaque poste se signale toutes les minutes.
- Coupure réseau ou redémarrage serveur : reconnexion seule, la lecture en cours
  est rejouée, une écriture interrompue n'est **jamais** rejouée à moitié,
  message clair, jamais de plantage.

### 1.10 Sauvegardes

- `.dump` (pg_dump) : chaque soir par le serveur (tâche planifiée), une par jour
  par le premier poste de gestion (verrou serveur).
- Restaurer demande le mot de passe du propriétaire et **garde les comptes
  actuels** : un instantané des comptes est pris avant, réinstallé après —
  sinon la restauration ramène les comptes d'alors, ou aucun.

### 1.11 Performances mesurées (à tenir)

Sur 1 025 122 exemplaires, base de 1,6 Go, PC de développement bridé à 800 MHz :

| Opération | À chaud |
|---|---|
| accueil du poste (chiffres, thèmes, nouveautés) | 4 à 70 ms |
| « normal christian life » | 65 ms |
| recherche plein texte sur 73 000 lignes | ~60 ms |
| recherche poste public, 50 000 œuvres en mémoire | 5 à 90 ms |
| accès direct par code (deux requêtes) | 0,02 ms |

---

## 2. Source B — BiblioRFID : la chaîne matériel

Service Node.js. Après le chantier 1, il ne garde que le matériel. Le contrat
ci-dessous est ce que le nouveau backend et le nouveau frontend doivent parler.

### 2.1 Le lecteur UHF de bureau

Repose sur `GReaderApi.dll` du *RFID Desktop Reader SDK-EN*.

**Connexion** — une seule instance persistante de `GClient`, gardée tant que
l'application tourne :

- USB HID : `GetUsbHidList()` puis `OpenUsbHid(path, …, 3500, out status)` ;
- série : `OpenSerial("COMx:115200", 3500, out status)` ;
- TCP : `OpenTcp("adresse:6180", 3500, out status)`.

**Lecture** — la séquence exacte :

1. `MsgBaseStop` pour remettre le lecteur au repos à la connexion ;
2. buzzer sous contrôle logiciel (`MsgAppSetBeepOnOff`) ;
3. abonnement **unique** à `OnEncapedTagEpcLog` ;
4. `MsgBaseInventoryEpc` sur l'antenne 1, mode continu, EPC + TID ;
5. déduplication par TID, une notification par tag maximum toutes les 100 ms ;
6. regroupement des nouveaux tags pendant 140 ms, recherche des correspondances,
   publication de l'état vers l'interface **par SSE** ;
7. si un nouveau TID apparaît : mode **natif** (sonnerie unique gérée par le
   firmware) ou **contrôlé** (marche, maintien configuré, arrêt explicite), puis
   verrou du bip pour ce TID ;
8. tag considéré retiré après **700 ms** sans nouvelle remontée.

Anti-rebond : 700 ms de présence serveur, puis **1,5 s** d'anti-rebond visuel
par TID, puis le délai de réarmement configuré. Tant que le tag est présent, le
verrou sonore ne peut pas expirer. Conséquence à respecter dans l'UI : **la
disparition transitoire d'un tag ne modifie pas la liste, ne change pas le
bandeau et ne rejoue pas les notifications** si le tag revient dans ce délai.

> Mesure utile : la durée audible du buzzer n'est **pas** modulable sur ce
> firmware, même si la commande est acquittée (21 ms demandé → 21 ms mesuré,
> 203 ms pour 200 ms, enveloppe sonore physiquement identique). Ne pas exposer
> de réglage qui ne produit rien.

**Écriture sûre** — jamais raccourcir :

1. lire la zone et exiger **exactement un TID distinct** ;
2. arrêter l'inventaire continu ;
3. filtre `ParamEpcFilter` sur la zone TID (`Area = 2`, `BitStart = 0`) ;
4. mot PC = nombre de mots EPC décalé de 11 bits ;
5. `MsgBaseWriteEpc` zone EPC à partir du mot 1, avec `PC + EPC` ;
6. relire en filtrant le même TID ;
7. valider **uniquement** si l'EPC relu correspond exactement à l'attendu.

Aucune commande de verrouillage ni de destruction n'est utilisée. **Une écriture
échouée ou non vérifiée n'associe jamais le TID au livre.**

**Désencodage** — exige le tag unique déjà associé (EPC et TID concordants),
écrit 24 zéros dans la zone EPC, relit en filtrant par TID, et ne retire
l'association qu'après confirmation de l'EPC nul. Le tag reste réutilisable.

### 2.2 Le format EPC local

96 bits, 24 caractères hexadécimaux :

| Octets | Contenu |
|---|---|
| 0–2 | signature ASCII `BCM` |
| 3 | version du format (`01`) |
| 4–5 | année du catalogage |
| 6–9 | numéro séquentiel du livre |
| 10–11 | CRC-16/CCITT du contenu précédent |

Numéro visible : `BCM-AAAA-NNNNNN`. Référence : `lib/epc.js`,
`myscankey_flutter/lib/core/epc.dart`.

### 2.3 Le contrat natif de circulation

Déjà spécifié et testé (`tests/fixtures/ilms-circulation-contract.json`). Il est
**à reprendre tel quel** côté nouveau backend.

Normalisations exigées :

- tout identifiant est un **UUID** validé, **ramené en minuscules** ;
- un tag est `{epc?, tid?}`, hexadécimal, **mis en majuscules**, 254 caractères
  au plus, et **au moins un des deux** doit être présent ;
- `preferred_return_date` doit porter un fuseau explicite (`Z` ou `±hh:mm`) et
  est converti en ISO UTC ;
- les champs de passage (`password`, `token`) ne sont **jamais** persistés.

Vérifications de cohérence de la réponse, qui doivent rester des erreurs dures :

- `library_id` de la réponse = bibliothèque de la portée ;
- sur un prêt : `member_id` et `copy_id` = ceux attendus par la demande ;
- sur un retour : `id` = le prêt demandé, et `status` = 2 ;
- `status` entier entre 0 et 8, `number` non vide, 255 caractères au plus.

Portée (`nativeScope`) — règles de sécurité à conserver : HTTPS exigé, HTTP
toléré **uniquement** sur `localhost`/`127.0.0.1`/`[::1]` ; ni identifiant ni
mot de passe dans l'URL ; l'URL doit être exactement une origine ; aucun
caractère de contrôle.

### 2.4 L'idempotence et le journal durable

C'est le point le plus important de tout le document.

- **Le poste reste maître** : le prêt local est déjà enregistré quand le report
  part vers le serveur, et **rien ne peut l'annuler**. Une bibliothèque qui prête
  pendant une coupure doit pouvoir continuer.
- Le report ne lève donc **jamais** d'exception : il renvoie un **état** —
  `refused`, `skipped`, `queued`. `queued` n'est pas un échec : la demande est
  enregistrée durablement et partira. Le distinguer d'un refus évite d'alarmer
  pour une simple coupure.
- L'identifiant d'opération est l'identifiant durable du prêt local : le
  réutiliser rend l'envoi **idempotent**, donc rejouer après une coupure ne crée
  pas un second prêt.
- Journal plafonné à **100 demandes** par compte et par bibliothèque ; une même
  demande ne peut pas être en cours dans deux processus à la fois ; un résultat
  réseau inconnu exige une reprise **explicite** avec la demande d'origine.

### 2.5 L'agent lecteur local

Expose le lecteur à une page servie par une autre origine. Garde-fous à
conserver :

- origine autorisée : HTTPS exacte, ou HTTP **locale** seulement ;
- corps JSON obligatoire, **4 Ko** au plus, 256 événements, TTL 30 s ;
- connexion TCP restreinte aux **IP littérales privées** (10/8, 172.16/12,
  192.168/16) : l'agent ne doit jamais devenir un relais HTTP ou DNS ;
- série limitée au motif `COM1`–`COM9999`.

### 2.6 Autres pièces à garder

`lib/reader-service.js`, `lib/reader-timing.js`, `lib/epc.js`,
`lib/cataloguing/`, `lib/xlsx-import.js`, `lib/sync-service.js`, le pont
`bridge/` (`BridgeSettings.cs`, `build.ps1`), le `launcher/`, et la mise à jour
**OTA** du firmware.

---

## 3. Source C — `Reader/myscankey_flutter`

Application Flutter Android pour terminal à lecteur UHF intégré. Elle apporte
trois rôles d'appareil et un modèle d'authentification à reprendre dans le
frontend.

### 3.1 Trois rôles d'appareil

| Rôle | Comportement |
|---|---|
| **Poste d'emprunt** | tablette fixe + lecteur de bureau ; s'ouvre directement en libre-service ; seul le code administrateur permet d'en sortir |
| **Lecteur mobile** | terminal du personnel : catalogue, station, inventaire, localisation, prêts au comptoir |
| **Portail antivol** | tablette + portail N01 de la sortie ; plein écran sur la surveillance ; sortie par code administrateur |

### 3.2 Matériel supplémentaire

- **Lecteur UHF intégré** : service Seuic `UHFService` (`uhf.jar`,
  `com.seuic.uhf`), ouvert par `UHFService.open()` — aucun chemin `/dev/ttyS*` à
  saisir. Flux EPC + TID en continu ; toute écriture exige un seul tag détecté et
  le TID correspondant ; **l'EPC est relu avant de modifier le catalogue**.
- **Scanner optique** (CRUISE2 Seuic) : `android.scanner.library`
  (`ScannerAPI.jar`) via `BarcodeScannerBridge.kt` ; touches **250** (gâchette
  RFID) et **249** (scan optique) ; codes reçus par `DecodeInfoCallBack`,
  indépendamment du mode clavier. Ouvert automatiquement à l'étape ISBN du
  catalogage, fermé en sortie d'étape ou en arrière-plan, réactivé au retour.
  Les lectures RFID sont **suspendues** pendant une session de scan. EAN-13,
  chiffre de contrôle, viseur et éclairage activés pour la session puis
  restaurés. SDK **facultatif**, pour que l'application démarre sur les autres
  postes.
- **Portail antivol N01** (`N01_1.3.1.6.jar`, `GateBridge.kt`) : TCP/IP, adresse
  IP seule, le SDK impose le port **8080**.

### 3.3 Authentification locale

- Premier lancement : création du compte **administrateur** de l'appareil (nom,
  e-mail, mot de passe de 8 caractères minimum).
- Ensuite e-mail + mot de passe ; après **5 échecs**, essais bloqués **30 s**.
- Un administrateur ajoute, active ou désactive les comptes ; **le dernier
  administrateur ne peut pas être désactivé**.
- **PBKDF2-HMAC-SHA256, 60 000 itérations, sel aléatoire**, jamais en clair.
- Sur un poste d'emprunt, le personnel se connecte au démarrage puis le poste
  reste ouvert aux abonnés, qui n'ont pas de compte.

### 3.4 Écrans existants (inventaire)

`catalogue`, `dashboard`, `station`, `inventory`, `locator`, `kiosk`, `gate`,
`history`, `admin`, `settings`, `login`, `device_role`. Noyau réutilisable :
`core/cote.dart`, `core/epc.dart`, `core/isbn.dart`, `core/unimarc.dart`,
`core/catalogue_text.dart`, `core/password.dart`.

---

## 4. Ce que le socle backend offre déjà

`library-service` — Spring Boot 3, **Java 21**, découpage
`api / application / infrastructure / commons / shared`, avec
`starter-core`, `openapi-docs`, `datatable`, `media-client`,
`auth-service-client`, `postgresql-support`, `elasticsearch`, `rabbitmq`,
WebFlux, Spring Cloud Config, Eureka, OAuth2 resource server, POI, OpenPDF,
commons-csv, slugify.

**47 contrôleurs déjà en place**, dont une couche RFID complète :

- `RfidController`, `CirculationRfidController`, `DocumentCopyRfidController`,
  `LibraryRfidController` ;
- `infrastructure/rfid/` : `RfidMessage`, `RfidWebSocketHandler` ;
- `infrastructure/ws/` : `core`, `handlers`.

Et le socle métier : `DocumentController`, `DocumentCopyController`,
`LoanController`, `MemberController`, `ReservationController`, `CoteController`,
`ShelfController`, `SectionController`, `BuildingController`, `RoomController`,
`CategoryController`, `CollectionController`, `AuthorController`,
`EditorController`, `ClassificationCodeController`, `CustomFieldController`,
`DocumentImageController`, `CatalogEnrichmentController`,
`RecommendationController`, `SearchAnalyticsController`, `StatisticsController`,
`CirculationExportController`, `DocumentExportController`,
`EntitySequenceController`, `Z3950ServerController`, `LibrarySettingsController`,
`PickupLocationController`, `TablePreferenceController`, `CartController`,
`FavoriteController`, `CommentController`, `NewsController`, `EventController`,
`LibraryPublicationController`, `GroupController`, `AuthorityController`…

**Infrastructure présente** : `audit`, `authority`, `cache`, `datatable`,
`elastic`, `exports`, `imports`, `managers`, `persistence`, `rabbitmq`,
`recommendation`, `schedulers`, `yaz4j` (Z39.50).

Conclusion : **le socle couvre déjà une grande partie du catalogage et de la
circulation**. Le chantier 2 n'est donc pas une réécriture à blanc, c'est un
alignement du cœur métier sur les règles de la 3.0 et l'absorption du cœur
BiblioRFID.

---

## 5. Décisions à prendre au chantier 2

Ces points ne sont pas tranchés par les sources ; ils le seront en ouvrant le
chantier, et sont listés ici pour ne pas les découvrir trop tard.

1. ~~**Recherche** — Elasticsearch ou `tsvector` + `pg_trgm` ?~~
   **Tranché le 18 octobre 2026 : `tsvector` + `pg_trgm`.** La recherche vit
   donc dans PostgreSQL, et les scores, synonymes anglais, signatures d'auteur
   et corrections par trigrammes de la 3.0 sont portés tels quels. Les mesures
   du §1.11 restent à rejouer sur le schéma cible. L'`@AutoElastic` du socle
   garde sa place pour ce qu'Elasticsearch fait mieux (agrégats,
   recommandation), mais **il ne sert plus la recherche du catalogue** : deux
   moteurs pour la même question, c'est deux classements à expliquer.
2. ~~**Modèle** — faire correspondre `exemplaire` / `oeuvre` / `couverture`
   aux entités existantes.~~
   **Mesuré le 18 octobre 2026 : l'écart est faible.** `DocumentCopy` porte
   déjà `rfidCode` (EPC), `rfidTid`, `barcode`, `quote` (la cote), `series`,
   `buildingId`, `roomId`, `shelfId`, `sectionId`, `shelfRow`, `shelfColumn`.
   Et surtout : **la couverture est déjà portée par `Document`**
   (`coverImage`, `images`), pas par l'exemplaire — exactement la règle de la
   3.0. Reste à confirmer la correspondance exacte bloc/série/rang.
3. **Temps réel** — `LISTEN/NOTIFY` devient le `RfidWebSocketHandler` existant,
   ou un échange RabbitMQ ? Les trois canaux (`catalogue`, `index`, `prets`)
   doivent exister d'une façon ou d'une autre.
4. **Migration des données** — reprise du `.dump` des 73 223 exemplaires vers le
   schéma cible, avec contrôle du nombre de lignes table par table, comme le
   faisait `migrer_depuis_sqlite.py` (154 s pour le fonds réel).
5. ~~**Hors ligne** — il faut la clé d'idempotence côté serveur.~~
   **Déjà en place.** `loans.operation_id`, avec un index unique
   (`idx_loans_operation_id`) : deux rejeux simultanés se départagent dans la
   base, pas dans le service. Et depuis le 18 octobre 2026,
   **`uq_loans_open_copy`** tient l'invariant « un livre ne peut pas être
   prêté deux fois » — index unique **partiel**, limité aux prêts ouverts,
   pour que l'historique d'un livre puisse s'accumuler. Vérifié avec deux
   sessions concurrentes : un prêt accepté, un refus propre, exactement un
   prêt ouvert en base.
6. **Sauvegardes et restauration** — qui les porte, maintenant que le serveur
   est en ligne, et comment garder la règle « la restauration conserve les
   comptes actuels ».

---

## 6. Pièges hérités, à ne pas réintroduire

Relevés sur les trois sources. Chacun a coûté un bogue réel.

| Piège | Ce qui se passe | La règle |
|---|---|---|
| Fenêtre modale pendant un scan | la douchette tape dans la boîte de dialogue | message dans le bandeau + bip, **jamais** de fenêtre bloquante |
| `WHERE code_barre=? OR cote=?` | sous SQLite, l'index **partiel** devenait inutilisable : parcours complet (58 ms). **Vérifié le 18/10/2026 : ne transpose pas.** Sous PostgreSQL, avec deux index d'**expression**, le `OR` est servi par un `BitmapOr` | interroger le chemin que l'on connaît — on sait presque toujours si l'on tient un code-barres ou une cote. Préférable (un parcours d'index au lieu de deux plus une revalidation), mais plus un écart d'un facteur mille |
| Colonne absente de l'export | un cycle export → réimport la perd | toute colonne utile dans l'export **et** ses alias |
| Insertion positionnelle | casse dès qu'une colonne est ajoutée | toujours nommer les colonnes |
| Insertion « ignorer les doublons » | les lignes refusées sont comptées comme importées | compter les insertions réelles (avant/après) |
| Date calculée en SQL | le serveur est en UTC, le client en heure locale | passer la date du jour en paramètre |
| Modification en masse d'un champ unique | `code_barre` et `cote` provoquent des collisions | liste blanche des champs modifiables en masse |
| Rapprochement de couverture trop lâche | le titre seul attribue la mauvaise image | niveaux sûrs par défaut, le reste en option |
| Nettoyeur général sur un chemin | fusionne les espaces : fichier introuvable | nettoyeur dédié aux chemins |
| Rattacher par nom après un import | remplit les cases image vidées exprès | seulement si le fichier n'a aucune colonne d'image |
| Statistiques recalculées partout | 3 × 0,5 s après chaque prêt sur le fonds réel | mémoriser sur (compteur de changements, date) |
| En-têtes supposés en ligne 1 | un catalogue qui commence par un titre est illisible | chercher la ligne des champs parmi les 20 premières |
| Ligne repérée par sa position | après un tri, la case cochée n'est plus la bonne | repérer par identifiant |
| Recherche en français sur un fonds anglais | « priere » : 3 livres | synonymes anglais en **mot entier** |
| Restaurer une sauvegarde | ramène les comptes d'alors, ou aucun | instantané des comptes avant, réinstallation après |
| Écriture RFID non relue | un TID se retrouve associé au mauvais livre | relire en filtrant le TID, valider sur égalité exacte |
| Disparition transitoire d'un tag | la liste clignote, les notifications se rejouent | 700 ms serveur + 1,5 s d'anti-rebond visuel par TID |
| Réglage de durée du buzzer | le firmware produit la même enveloppe sonore | ne pas exposer un réglage sans effet |
| Agent lecteur ouvert sur une IP quelconque | il devient un relais HTTP/DNS | IP littérales privées seulement |
| Report de prêt qui lève une exception | une coupure réseau annule un prêt déjà enregistré | renvoyer un **état** (`refused`/`skipped`/`queued`) |
| Report rejoué sans clé d'idempotence | un second prêt est créé chez le serveur | réutiliser l'identifiant durable du prêt local |

---

## 7. Suite

Chantier 1 — purge de la couche ILMS de BiblioRFID. Périmètre :

| À supprimer | Lignes |
|---|---|
| `lib/ilms-circulation-bridge.js` | 175 |
| `lib/ilms-circulation-client.js` | 166 |
| `lib/ilms-circulation-journal.js` | 110 |
| `lib/ilms-client.js` | 273 |
| `lib/ilms-reader-agent.js` | 204 |
| `lib/ilms-routes.js` | 167 |
| `lib/ilms-session.js` | 279 |
| `lib/ilms.js` | 375 |
| `ilms-agent.js`, `ilms-sync.js` | 64 |
| `ilms/` (paquet compilé) | — |
| 8 suites de tests + la fixture de contrat | — |
| `docs/ilms-*.md`, `docs/migration-bibliorfid-ilms.md` | — |

À nettoyer : `server.js` (~40 points d'accroche), `public/app.js`
(125 occurrences), `public/index.html` (45), `lib/database.js` (réglages
`ilms_*`), `package.json` (9), `README.md` (13), `public/station-catalogue.js`.

Le travail se fait sur une branche : l'historique Git reste la source de vérité
si un détail du contrat doit être relu après coup.
