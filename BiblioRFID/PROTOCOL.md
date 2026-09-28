# Procédure RFID retenue

L’intégration repose sur `GReaderApi.dll` du SDK **RFID Desktop Reader SDK-EN** et sur les classes documentées dans `RFID Reader Development Guide-C#.pdf`.

## Connexion

- USB HID : `GClient.GetUsbHidList()` puis `OpenUsbHid(path, IntPtr.Zero, 3500, out status)`.
- Série : `OpenSerial("COMx:115200", 3500, out status)`.
- TCP : `OpenTcp("adresse:6180", 3500, out status)`.
- Le serveur ouvre une seule instance persistante de `GClient`. Elle reste active tant que l'application fonctionne ou jusqu'à un changement de connexion, puis se termine par `GClient.Close()`.

## Lecture

1. Envoyer `MsgBaseStop` pour replacer le lecteur au repos lors de la connexion.
2. Placer le buzzer sous contrôle logiciel avec `MsgAppSetBeepOnOff`.
3. S’abonner une fois à `OnEncapedTagEpcLog`.
4. Envoyer `MsgBaseInventoryEpc` sur l’antenne 1 en mode continu, en demandant EPC et TID.
5. Dédupliquer les remontées par TID et limiter les notifications d'un même tag à une toutes les 100 ms.
6. Regrouper les nouveaux tags pendant 140 ms, rechercher leurs correspondances SQLite puis publier l'état vers l'interface par SSE.
7. Si au moins un nouveau TID est apparu, appliquer le mode compilé : **natif** avec une sonnerie unique gérée par le firmware, ou **contrôlé** avec marche, maintien configuré et arrêt explicite. Verrouiller ensuite le bip pour ce TID.
8. Considérer un tag retiré après 700 ms sans nouvelle remontée.

Le verrou sonore est distinct de l'affichage, mais son compteur ne commence qu'après la disparition confirmée du tag : 700 ms de présence serveur, puis 1,5 seconde d'anti-rebond visuel. Le délai de réarmement configuré en millisecondes s'ajoute ensuite. Tant que le tag est considéré présent, le verrou sonore ne peut pas expirer.

L'interface applique en plus un anti-rebond visuel de 1,5 seconde par TID. En lecture simple comme multiple, la disparition transitoire d'un tag ne modifie donc pas la liste, ne change pas le bandeau et ne rejoue pas les notifications si le tag revient pendant ce délai.

Les deux valeurs sont générées dans `bridge/BridgeSettings.cs` depuis la page **Paramètres**, puis intégrées à `ReaderBridge.exe` par `bridge/build.ps1`.

Le pont mesure séparément l'envoi de la commande de marche, le maintien logiciel et la commande d'arrêt. Sur le lecteur USB actuellement raccordé, les maintiens mesurés sont bien distincts (`21 ms` pour une demande de `20 ms`, `203 ms` pour `200 ms`), mais le firmware produit une enveloppe sonore physiquement identique. La durée audible du buzzer matériel n'est donc pas modulable sur ce firmware, même si la commande est acquittée.

Il n'existe donc plus de temporisation fixe de 1,8 seconde pour une lecture normale. L'inventaire n'est arrêté que pendant une écriture contrôlée, puis redémarre immédiatement.

## Écriture sûre

1. Lire la zone et exiger exactement un TID distinct.
2. Arrêter l’inventaire continu.
3. Construire un filtre `ParamEpcFilter` sur la zone TID (`Area = 2`, `BitStart = 0`).
4. Construire le mot PC : nombre de mots EPC décalé de 11 bits.
5. Envoyer `MsgBaseWriteEpc` dans la zone EPC, à partir du mot 1, avec `PC + EPC`.
6. Relire en filtrant le même TID.
7. Valider uniquement si l’EPC relu correspond exactement à la valeur attendue.

L’application n’utilise pas les commandes de verrouillage ou de destruction. Une écriture échouée ou non vérifiée n’associe jamais le TID au livre dans le catalogue.

## Désencodage

Depuis le catalogue, l’action **Désencoder le tag** exige le tag unique déjà associé au livre (EPC et TID concordants). Le pont écrit 24 zéros dans la zone EPC, puis relit le tag en le filtrant par TID. Le catalogue retire l’association TID et repasse le livre à **À encoder** uniquement si la relecture confirme l’EPC nul. Le tag reste réutilisable; aucune commande de destruction n’est envoyée.

## Format EPC local

L’EPC contient 96 bits, soit 24 caractères hexadécimaux :

| Octets | Contenu |
|---|---|
| 0–2 | Signature ASCII `BCM` |
| 3 | Version du format (`01`) |
| 4–5 | Année du catalogage |
| 6–9 | Numéro séquentiel du livre |
| 10–11 | CRC-16/CCITT du contenu précédent |

Le numéro visible correspondant est `BCM-AAAA-NNNNNN`.
