# PontRFID-ESP32

Firmware du pont RFID autonome auquel le poste desktop se connecte. Un ESP32
pilote un module lecteur UHF, un buzzer et trois LED (rouge, verte, bleue), et
expose le lecteur au poste par **Wi-Fi, Bluetooth ou UART**.

- Matériel et nomenclature : [MATERIEL.md](MATERIEL.md)
- Brochage et schéma de câblage : [CABLAGE.md](CABLAGE.md)

## 1. Pourquoi ce pont

Le poste desktop BiblioRFID parle aujourd'hui à `ReaderBridge.exe`, qui pilote
un lecteur N01 par `GReaderApi.dll` sur USB HID, port série ou TCP. Ce pont
ESP32 reprend **le même dialecte de messages**, de façon qu'un consommateur
côté poste n'ait pas à réapprendre un protocole : une ligne de texte par
message, préfixée par `__RFID_JSON__`, le même vocabulaire d'actions
(`connect`, `disconnect`, `status`, `beep`, `write`, `shutdown`) et le même
événement `tag`.

Ce que le pont apporte en plus du pont C# : il tient lui-même le buzzer et les
LED, et il applique localement les règles de déduplication de
`BiblioRFID/PROTOCOL.md` (anti-rebond 100 ms, présence 700 ms, verrou sonore
avec réarmement). Le retour sonore et lumineux reste donc immédiat même si le
poste est lent, occupé ou momentanément déconnecté. Son firmware se met aussi
à jour à distance (§7), sur le modèle de la borne
`auditron-qr/saas/hardware/borne`.

## 2. Liens de transport

Les trois liens peuvent être actifs simultanément. Les réponses repartent sur
le lien qui a émis la commande ; les événements sont diffusés à tous les liens
ouverts.

| Lien | Mise en œuvre | Adresse |
|---|---|---|
| **UART / USB** | UART0, 115200 bauds, toujours actif | port COM de la carte |
| **Wi-Fi** | serveur TCP, lignes NDJSON | `<ip de la carte>:6180` |
| **Bluetooth** | SPP (Bluetooth classique), lignes NDJSON | appareil `PontRFID-XXXX` |

Le port 6180 reprend celui des lecteurs N01 en TCP, pour ne pas multiplier les
conventions.

**Deux clients TCP au maximum** (`LINK_MAX_CLIENTS`). Un troisième est refusé
franchement plutôt que mis en file d'attente. Le lecteur physique ne doit de
toute façon être piloté que par un poste à la fois : la limite autorise un
poste et un outil de diagnostic, pas deux stations de circulation.

### Pas d'authentification sur le lien

Le pont n'authentifie ni le client TCP ni le client Bluetooth : quiconque
atteint le port 6180 peut déclencher une lecture ou une écriture de tag. Le
pont doit donc rester sur un réseau de desserte maîtrisé, jamais exposé à
Internet ni à un Wi-Fi ouvert aux lecteurs de la bibliothèque. La couche
d'autorisation du système reste celle d'ILMS : c'est l'agent local
(`BiblioRFID/ilms-agent.js`, clé partagée, écoute sur `127.0.0.1`) qui porte
l'identité, pas ce pont.

## 3. Compilation et flashage

PlatformIO :

```powershell
# depuis PontRFID-ESP32
pio run                       # compilation
pio run --target upload       # flashage
pio device monitor -b 115200  # observation des lignes NDJSON
```

Variante sans radio, lecteur relié au poste par USB uniquement :

```powershell
pio run -e esp32dev-uart-only --target upload
```

Le premier flashage doit passer par l'USB : il installe la table de
partitions à deux slots ([partitions.csv](partitions.csv)). Les mises à jour
suivantes peuvent se faire à distance (§7). Repasser plus tard à une autre
table de partitions imposerait de nouveau un flash USB.

Avec l'IDE Arduino : copier le contenu de `src/` dans un croquis, installer
**ArduinoJson 7**, choisir la carte « ESP32 Dev Module » et renommer
`main.cpp` en `<nom du croquis>.ino`.

## 4. Configuration

Aucun identifiant Wi-Fi n'est inscrit dans le code ni dans ce dépôt. La
configuration est écrite en NVS depuis n'importe quel lien, par l'action
`config` :

```json
{"id":1,"action":"config","ssid":"reseau-desserte","password":"<secret>"}
{"id":2,"action":"config","beepDurationMs":75,"rearmDelayMs":30000}
{"id":3,"action":"config","txPowerCdBm":2000}
```

Le mot de passe n'est jamais relu ni renvoyé par le pont. Il est donc naturel
de configurer le Wi-Fi par le lien UART, en local, puis d'utiliser le réseau.

La source des mises à jour se configure de la même façon (§7) :

```json
{"id":4,"action":"config","otaManifestUrl":"https://exemple/firmware/manifest","otaToken":"<secret>"}
```

Ni le mot de passe Wi-Fi ni le jeton de mise à jour ne sont relus ou renvoyés
par le pont, et ils vivent dans deux espaces NVS distincts.

Un appui de **5 secondes sur le bouton BOOT** efface la configuration et
redémarre la carte. Cela efface aussi la source des mises à jour.

Les paramètres de brochage et de temporisation qui ne changent pas en
exploitation sont dans [src/config.h](src/config.h).

## 5. Protocole

Chaque message est une ligne complète, préfixée par `__RFID_JSON__`. Un client
qui ne reconnaît pas un type de message doit l'ignorer : c'est ce que fait
déjà `BiblioRFID/lib/reader-service.js`.

### Actions

| Action | Charge utile | Réponse |
|---|---|---|
| `connect` | `connectionType`, `endpoint` (acceptés et rapportés, le pont n'a qu'un module) | état complet |
| `disconnect` | — | état complet |
| `status` / `ping` | — | état complet |
| `beep` | `durationMs` (20–1000) | `beeped`, `durationMs` |
| `led` | `state` (`accepted`, `ignored`, `busy`, `error`, `idle`), `durationMs` | `led` |
| `write` | `epc`, `tid` | `tag`, `verified` — échoue si la relecture ne confirme pas |
| `readTid` | — | `tid` du tag unique présent |
| `moduleInfo` | — | `hardware`, `software` |
| `config` | `ssid`, `password`, `beepDurationMs`, `rearmDelayMs`, `txPowerCdBm`, `otaManifestUrl`, `otaToken`, `otaInsecure`, `otaCaPem` | état complet |
| `update` | `forget` (rejoue une version mise de côté) | déclenche une vérification OTA immédiate (§7) |
| `shutdown` | — | ferme le lecteur, **ne redémarre pas** la carte |
| `reboot` | — | redémarre la carte |

### Événements

| Type | Sens |
|---|---|
| `ready` | émis à l'ouverture d'un lien, avec l'état courant |
| `tag` | `{epc, tid, rssi, antenna, key}` — au plus un par tag par 100 ms |
| `tagReleased` | le champ s'est vidé (extension, absente du pont C#) |
| `state` | battement de cœur toutes les 5 s et à chaque changement |
| `ota` | avancement d'une mise à jour : `phase` vaut `download` (avec `percent`), `checked` (avec `result`) ou `restart` |
| `diagnostic` | message d'anomalie, non structuré |
| `response` | réponse à une action, portant l'`id` de la requête |

### Sur le champ `tid`

Le module ne remonte pas le TID dans ses notifications d'inventaire : seuls
l'EPC, le PC et le RSSI y figurent. Le champ `tid` d'un événement `tag` est
donc **vide pendant l'inventaire continu**, et le champ `key` vaut alors l'EPC.
Le TID s'obtient par l'action `readTid`, qui interrompt l'inventaire, lit la
banque TID du tag unique présent, puis reprend l'inventaire.

C'est une différence de comportement avec le pont C#, qui demande le TID dans
l'inventaire lui-même et déduplique dessus. Un consommateur qui a besoin du
TID pour chaque lecture doit appeler `readTid` tag par tag, ou l'inventaire
doit être enrichi d'une lecture de banque — à traiter au moment du
raccordement au poste, en fonction de ce que le module livré sait faire.

## 6. Raccordement au poste desktop

Côté Node, le décodage est déjà écrit : `ReaderService.handleLine` reconnaît le
préfixe `__RFID_JSON__` et les types `ready`, `tag` et `response`. Ce qui
manque est le **transport** : `ReaderService` lance aujourd'hui un processus
(`ReaderBridge.exe`) et écrit sur son `stdin`, alors que le pont ESP32 est au
bout d'une socket TCP, d'un port série ou d'un lien Bluetooth.

Un adaptateur côté poste doit donc remplacer le couple `spawn` / `stdio` par
une `net.Socket` (ou un `SerialPort`), en conservant le reste de la classe —
file des commandes en attente par `id`, délais d'expiration, `connect`,
`beep`, `write`, `shutdown`. **Cet adaptateur ne fait pas partie de ce
dossier** : il touche au poste, pas au firmware, et il devra décider comment
l'agent ILMS choisit entre le pont C# et le pont ESP32.

En attendant, le pont se pilote à la main pour la recette :

```powershell
# Wi-Fi
# Chaque ligne envoyee est une commande ; les evenements arrivent en continu.
ncat 192.168.1.42 6180

# UART
pio device monitor -b 115200
```

```json
{"id":1,"action":"connect"}
{"id":2,"action":"status"}
{"id":3,"action":"beep","durationMs":120}
{"id":4,"action":"disconnect"}
```

## 7. Mises à jour OTA

Le mécanisme reprend celui de la borne `auditron-qr/saas/hardware/borne` :
**manifest → téléchargement en flux → SHA256 vérifié avant d'activer le
nouveau slot → redémarrage**, avec mise de côté de la version dont l'image
s'avère corrompue. Le code est dans [src/ota.cpp](src/ota.cpp).

### Déroulé

1. Le pont interroge l'URL de manifest configurée, en annonçant sa version
   dans l'en-tête `X-Firmware-Version` (et son jeton en `Authorization:
   Bearer` s'il y en a un). Un `204` signifie « aucune version publiée ».
2. Dès que le serveur répond (`200` ou `204`), le slot courant est validé par
   `esp_ota_mark_app_valid_cancel_rollback()`. Un firmware OTA incapable de
   joindre son serveur n'est donc jamais validé : le bootloader revient de
   lui-même à l'image précédente au redémarrage suivant.
3. Si la version annoncée diffère de celle du binaire, l'image est téléchargée
   en flux de 1460 octets, écrite au fur et à mesure dans le slot inactif, et
   hachée en SHA256 au passage.
4. Le hachage est comparé au manifest **avant** `Update.end()` : une image qui
   ne correspond pas n'est jamais activée.
5. Succès : la carte redémarre sur le nouveau slot. Image corrompue : la
   version est inscrite en NVS et n'est plus retentée, jusqu'à ce qu'une autre
   version soit publiée (ou que `{"action":"update","forget":true}` la rejoue).
   Erreur réseau : nouvel essai au cycle suivant, sans rien mettre de côté.

### Format du manifest

```json
{
  "version": "1.1.0",
  "url": "https://exemple/firmware/pontrfid-1.1.0.bin",
  "sha256": "9f2c…64 caractères hexadécimaux",
  "size_bytes": 1744769
}
```

`url` peut être relative au manifest. Le SHA256 est celui de
`.pio/build/esp32dev/firmware.bin` :

```powershell
(Get-FileHash .pio\build\esp32dev\firmware.bin -Algorithm SHA256).Hash.ToLower()
(Get-Item .pio\build\esp32dev\firmware.bin).Length
```

La version publiée doit être exactement celle de `PONT_FIRMWARE_VERSION`
([src/config.h](src/config.h)), à incrémenter avant chaque build destiné à
l'OTA. Le pont flashe dès que la version annoncée **diffère** de la sienne :
publier une version plus ancienne fait donc un retour en arrière volontaire.

### Quand la mise à jour se déclenche

Une vérification a lieu dès la première association Wi-Fi, puis toutes les
15 minutes (`OTA_CHECK_INTERVAL_MS`), et à la demande par l'action `update`.

Elle est **refusée tant que le lecteur est ouvert ou qu'un tag est dans le
champ** : le téléchargement monopolise plusieurs secondes et se termine par un
redémarrage, ce qui couperait une opération de circulation. Le poste doit donc
avoir rendu le lecteur (`disconnect`) pour qu'une version publiée soit prise.
C'est volontaire : la station se met à jour entre deux séances, pas pendant.

Pendant le téléchargement, la LED passe au violet et les événements `ota`
portent l'avancement. Le téléchargement s'exécute dans une tâche dédiée de
16 Ko : la poignée de main TLS de mbedTLS dépasse les 8 Ko de pile de `loop()`,
et le define `CONFIG_ARDUINO_LOOP_STACK_SIZE` est redéfini par le `sdkconfig`
du cœur Arduino, donc inopérant depuis `platformio.ini`.

### Transport et confiance

| Configuration | Ce qui est garanti |
|---|---|
| `https://` + `otaCaPem` (PEM de l'autorité) | Le serveur est authentifié, l'image est vérifiée. **Configuration à retenir.** |
| `https://` + `otaInsecure: true` | Chiffré mais le certificat n'est pas vérifié : un intercepteur peut servir son propre manifest, donc sa propre image. Le SHA256 ne protège alors que contre la corruption, pas contre la substitution. |
| `http://` | Aucune authentification du serveur, mêmes conséquences. |
| `https://` sans l'un ni l'autre | **Refusé** : le pont ne télécharge pas plutôt que de faire semblant de vérifier. |

Le pont n'a pas de table d'autorités de certification embarquée : en HTTPS, il
faut fournir le PEM de l'autorité du serveur de mise à jour. Et comme le pont
n'authentifie pas ses propres clients (§2), quiconque atteint le port 6180 peut
reconfigurer cette source : le réseau de desserte doit rester maîtrisé.

### Partitions

[partitions.csv](partitions.csv) donne deux slots applicatifs de 1,9375 Mo
(les 1,25 Mo de `default.csv` sont trop petits, et `huge_app.csv` n'a pas de
second slot). Le binaire complet occupe **85,9 %** d'un slot : la marge
d'évolution est réelle mais pas confortable. S'il devenait trop gros, deux
leviers avant de toucher à la table : compiler sans Bluetooth
(`-DPONT_LINK_BT=0`) ou passer à un module à 8 Mo de flash.

`nvs` garde l'offset et la taille de `huge_app.csv` : la configuration déjà
enregistrée survit au changement de table.

## 8. État de la mise au point

Les deux cibles compilent et se lient ici avec PlatformIO 6.13 et
Arduino-ESP32 3.20017 (`esp32dev` : 1,74 Mo de flash — 85,9 % d'un slot OTA —
et 20,7 % de RAM ; `esp32dev-uart-only` : 335 ko). Le
firmware n'a en revanche **jamais été exécuté** : aucune carte ESP32 ni aucun
module UHF n'est raccordé à ce poste. Deux points sont donc à vérifier à la
première mise en service, dans cet ordre :

1. **La table d'opcodes du module** (`src/uhf_reader.h`) suit la documentation
   publique de la famille M100 / QM100 / R200 sans avoir été confrontée à un
   module physique. Les numéros de commande, et notamment ceux d'identification
   du module et de réglage de puissance, doivent être confrontés au manuel
   livré. Tous les opcodes sont regroupés dans ce seul bloc ; le reste du
   firmware n'en contient aucun.
2. **La forme exacte des charges utiles** de lecture et d'écriture de banque
   mémoire (`readTid`, `writeEpc`) dépend aussi de ce manuel. Le découpage de
   la réponse de lecture TID suppose que les 12 derniers octets de la trame
   sont les 6 mots demandés.

L'action `moduleInfo` est faite pour cette étape : elle renvoie la réponse
brute du module, ce qui confirme le dialogue UART avant toute tentative de
lecture de tag.

## 9. Limites assumées

- **Un seul module, une seule antenne.** Le champ `antenna` vaut toujours 1. Un
  portique antivol demande deux antennes et des entrées GPI : ce montage n'y
  répond pas.
- **Pas de verrouillage ni de destruction de tag.** Comme le pont C#, le
  firmware n'envoie aucune commande `Lock` ni `Kill`. Une écriture non
  confirmée par relecture est rapportée en échec et n'associe rien.
- **Horodatage facultatif.** `receivedAt` n'est présent que si l'heure réseau a
  été obtenue par Wi-Fi ; `uptimeMs` est toujours là. L'horloge de référence
  d'une opération de circulation reste celle d'ILMS.
- **Mise à jour hors séance.** Une version publiée n'est prise que lecteur
  fermé (§7). Une station laissée connectée en permanence ne se mettra jamais à
  jour d'elle-même : il faut un `disconnect`, ou un `update` explicite entre
  deux séances.
- **Bluetooth classique uniquement.** Le SPP n'existe pas sur ESP32-S3 / C3 /
  C6 : ces cartes demanderaient un lien BLE, à écrire dans `src/links.cpp`.

## 10. Organisation des sources

| Fichier | Rôle |
|---|---|
| [src/main.cpp](src/main.cpp) | boucle principale, décodage des actions, publication des événements |
| [src/config.h](src/config.h) | brochage, temporisations, options de compilation |
| [src/uhf_reader.h](src/uhf_reader.h) / [.cpp](src/uhf_reader.cpp) | trames du module UHF, inventaire, lecture TID, écriture vérifiée |
| [src/tag_tracker.h](src/tag_tracker.h) / [.cpp](src/tag_tracker.cpp) | déduplication, limitation de débit, verrou sonore et réarmement |
| [src/indicators.h](src/indicators.h) / [.cpp](src/indicators.cpp) | buzzer et LED RGB, machine à états sans `delay()` |
| [src/links.h](src/links.h) / [.cpp](src/links.cpp) | liens UART, Wi-Fi (TCP) et Bluetooth (SPP) |
| [src/ota.h](src/ota.h) / [.cpp](src/ota.cpp) | manifest, téléchargement vérifié en SHA256, bascule de slot |
| [partitions.csv](partitions.csv) | deux slots applicatifs pour l'OTA |
| [platformio.ini](platformio.ini) | cibles de compilation |
