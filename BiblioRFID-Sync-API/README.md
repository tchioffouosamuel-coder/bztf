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

## Routes

- `GET /health`
- `POST /api/v1/devices/register`
- `POST /api/v1/sync/push`
- `GET /api/v1/sync?since=0`
- `GET /api/v1/books`
- `GET /api/v1/subscribers`
- `GET /api/v1/subscriptions`
- `GET /api/v1/loans`
- `WS /api/v1/events?apiKey=...`

Les routes `/api/v1` attendent l'en-tête `X-Device-Key`.

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
