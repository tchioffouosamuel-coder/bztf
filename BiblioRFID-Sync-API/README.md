# BiblioRFID Sync API

API Kotlin/Ktor de synchronisation des catalogues BiblioRFID. Les terminaux poussent
leurs mutations de manière idempotente, récupèrent les changements par curseur et
reçoivent un signal WebSocket lorsqu'un autre appareil modifie le catalogue.

## Lancer

```powershell
$env:BIBLIORFID_API_KEY = "une-cle-longue-et-secrete"
$env:BIBLIORFID_DATABASE_URL = "jdbc:sqlite:data/bibliorfid-sync.db"
java -jar .\dist\bibliorfid-sync-api.jar
```

Le serveur écoute sur `0.0.0.0:8080` par défaut. Définissez `PORT` pour changer le port.
En production, placez-le derrière un proxy HTTPS et remplacez impérativement la clé
de développement par défaut.

## Routes de synchronisation (postes)

- `GET /health`
- `POST /api/v1/devices/register`
- `POST /api/v1/sync/push`
- `GET /api/v1/sync?since=0`
- `POST /api/v1/devices/{deviceId}/report` : rapport d'appareil (comptes et activité)
- `WS /api/v1/events?apiKey=...`

Ces routes attendent l'en-tête `X-Device-Key`.

## API de données (systèmes externes)

Lecture seule de toutes les données, pour un tableau de bord, un ERP, un entrepôt de
données, etc.

### Accès

Définissez une clé de lecture distincte de la clé des appareils :

```powershell
$env:BIBLIORFID_READ_API_KEY = "une-autre-cle-longue"
```

Envoyez-la par `X-Api-Key: <clé>` ou `Authorization: Bearer <clé>`. Elle ne donne accès
qu'aux routes `GET` ci-dessous : elle ne peut ni pousser de modification, ni envoyer
de rapport. La clé d'appareil (`X-Device-Key`) fonctionne aussi en lecture.

### Conventions

- Les listes renvoient un tableau JSON ; le nombre total de résultats est dans
  l'en-tête `X-Total-Count` (exposé en CORS).
- Pagination : `limit` (1 à 10 000) et `offset`. Sans `limit`, tout est renvoyé, sauf
  pour `/activity` et `/history` (100 par défaut).
- Dates au format ISO 8601 UTC (`2026-09-30T08:00:00Z`) ; `from`, `to` et
  `updatedSince` les comparent telles quelles.
- Booléens : `true`/`false`. Une valeur invalide renvoie `400`, un identifiant inconnu
  `404`.

### Routes

| Route | Filtres | Contenu |
|---|---|---|
| `GET /api/v1/stats` | — | Synthèse : livres, prêts en cours et en retard, abonnés, abonnements en cours, retours du jour, appareils |
| `GET /api/v1/books` | `search` (titre, auteur, cote, ISBN, EPC, rayon, catégorie), `status`, `updatedSince` | Livres |
| `GET /api/v1/books/{serverId}` | — | Un livre |
| `GET /api/v1/books/{serverId}/loans` | `status` | Emprunts d'un livre |
| `GET /api/v1/subscribers` | `search`, `active`, `hasCard`, `updatedSince` | Abonnés et carte RFID |
| `GET /api/v1/subscribers/{memberNumber}` | — | Un abonné |
| `GET /api/v1/subscribers/{memberNumber}/subscriptions` | `status`, `current` | Abonnements d'un abonné |
| `GET /api/v1/subscribers/{memberNumber}/loans` | `status` | Emprunts d'un abonné |
| `GET /api/v1/subscriptions` | `memberNumber`, `status` (`active`, `expired`, `suspended`), `current`, `updatedSince` | Abonnements, avec le nom de l'abonné et `current` (valide aujourd'hui) |
| `GET /api/v1/subscriptions/{serverId}` | — | Un abonnement |
| `GET /api/v1/loans` | `status` (`active`, `overdue`, `returned`), `memberNumber`, `bookServerId`, `from`/`to` (date d'emprunt), `updatedSince` | Emprunts, avec titre et cote du livre, nom de l'abonné, `overdue`, `returnedLate` |
| `GET /api/v1/loans/{serverId}` | — | Un emprunt |
| `GET /api/v1/returns` | `memberNumber`, `bookServerId`, `from`/`to` (date de retour), `late` | Remises de livres (emprunts rendus), du plus récent au plus ancien |
| `GET /api/v1/devices` | — | Appareils : nom, plateforme, version, dernière activité, nombres de comptes, d'entrées d'activité et de modifications |
| `GET /api/v1/devices/{deviceId}` | — | Un appareil |
| `GET /api/v1/devices/{deviceId}/users` | `search`, `role`, `active` | Comptes d'un appareil |
| `GET /api/v1/users` | `deviceId`, `search`, `role` (`admin`, `operateur`), `active` | Comptes utilisateurs de tous les postes, **sans mot de passe** |
| `GET /api/v1/activity` | `deviceId`, `type`, `result`, `bookServerId`, `from`/`to` | Journal d'activité des postes (lectures, encodages, prêts, connexions…) |
| `GET /api/v1/history` | `entityType` (`book`, `subscriber`, `subscription`, `loan`), `entityId`, `deviceId`, `from`/`to`, `since` | Historique des modifications synchronisées, avec l'état complet de l'entité |

`/history` est trié du plus récent au plus ancien. Avec `since=<séquence>`, il est trié
dans l'ordre croissant à partir de cette séquence : un système externe peut ainsi
suivre les modifications au fil de l'eau en mémorisant la dernière séquence reçue.

### Exemples

```powershell
$h = @{ "X-Api-Key" = $env:BIBLIORFID_READ_API_KEY }
Invoke-RestMethod "https://bztf.onrender.com/api/v1/loans?status=overdue" -Headers $h
Invoke-RestMethod "https://bztf.onrender.com/api/v1/returns?from=2026-09-01T00:00:00Z&late=true" -Headers $h
Invoke-RestMethod "https://bztf.onrender.com/api/v1/history?since=1200&limit=500" -Headers $h
```

### Comptes et activité

Les comptes et le journal d'activité restent propres à chaque poste. Ils sont
remontés par `POST /api/v1/devices/{deviceId}/report` après chaque synchronisation :
instantané des comptes (un compte supprimé sur le poste disparaît de l'API) et
entrées d'activité nouvelles, sans doublon. Ils ne sont pas redistribués aux autres
postes. Les empreintes de mot de passe ne quittent jamais l'appareil.

Déployez ce serveur avant de mettre à jour les postes : un poste récent qui parle à
un serveur plus ancien continue de synchroniser le catalogue, seul son rapport
échoue (et sera renvoyé ensuite).

## Entités synchronisées

Chaque mutation et chaque changement portent un `entityType` :

- `book` (valeur par défaut, compatible avec les anciens clients) : champ `book`,
  identifiant `serverId`.
- `subscriber` : champ `subscriber`, identifiant = numéro d'abonné en majuscules.
  L'abonné transporte sa carte RFID (`cardEpc`, `cardTid`, `cardTaggedAt`). Si un
  même tag physique (`cardTid`) est encodé pour un autre abonné, l'ancien
  titulaire perd la carte et un changement est émis pour lui.

- `subscription` : champ `subscription`, identifiant UUID `serverId`, abonné désigné
  par `memberNumber`.
- `loan` : champ `loan`, identifiant UUID `serverId`, livre désigné par
  `bookServerId`, abonné par `memberNumber`, abonnement par `subscriptionServerId`.
  Règles de conflit : un retour enregistré n'est jamais annulé par une copie plus
  ancienne ; si deux emprunts d'un même livre sont en cours, le plus récent reste
  actif et l'autre est clôturé à sa date d'emprunt (un changement est émis).

Dans un lot, le serveur applique les livres, puis les abonnés, les abonnements et
enfin les emprunts, pour que les clients reçoivent les références avant leur usage.

Les bases existantes sont migrées au démarrage (colonne `events.entity_type`, tables
`subscriptions` et `loans`).

## Compiler

```powershell
.\gradlew.bat test deliver
```

Le JAR autonome est produit dans `dist\bibliorfid-sync-api.jar`.
