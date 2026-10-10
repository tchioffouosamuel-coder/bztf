# Commandes serie N01

Source : document constructeur `01-json Protocol Development SDK_V1.3.6.1.docx`,
dans `N01RFID_SDK-EN(2)/N01RFID_SDK-EN/JSON protocol`.
Cette liste couvre les commandes de ce document, pas d'eventuelles commandes
non documentees. Leur disponibilite depend du firmware et des options de la carte.
Le controleur observe sur COM18 annonce le firmware V1.3.6.6.

## Utilisation

- Moniteur PC : COM18, 115200 bauds, 8 bits, sans parite, 1 bit de stop, sans controle de flux.
- Copier UN objet JSON sur UNE ligne, puis appuyer sur Entree.
- Respecter la casse des noms et les types : `1`, `"1"` et `true` sont differents.
- Dans notre moniteur, Entree envoie le JSON sans ajouter de fin de ligne, comme le SDK.
- Ctrl+C ferme le moniteur et libere COM18. Une seule application doit utiliser ce port.
- Les exemples `Set` modifient des reglages : lire le `Get` correspondant et conserver sa reponse avant toute modification.
- Les valeurs des exemples ne sont pas des recommandations pour ce portail.
- Ne pas modifier la region, les frequences, la licence, les debits internes ou les niveaux de reset pour diagnostiquer le cable RS232.

## Diagnostic sans modification de configuration

| Fonction | Commande |
| --- | --- |
| Identifiant | `{"OP":"ReaderIdGet"}` |
| Version logicielle | `{"OP":"VersionGet"}` |
| Informations materielles | `{"OP":"HwInfoGet"}` |
| Licence de la carte | `{"OP":"LicenseGet"}` |
| Antennes selectionnees | `{"OP":"AntennasGet"}` |
| Puissances des antennes | `{"OP":"PowersGet"}` |
| Region RFID | `{"OP":"RegionGet"}` |
| Configuration de l'inventaire automatique | `{"OP":"AutoInvGet"}` |

Ne pas diffuser la cle retournee par LicenseGet. Une reponse valide prouve la
communication avec la carte, pas a elle seule la lecture radio des etiquettes.

## Systeme, heure et licence

| Fonction | Commande / exemple |
| --- | --- |
| Lire le fuseau horaire | `{"OP":"TimezoneGet"}` |
| Modifier le fuseau | `{"OP":"TimezoneSet","timezone":"GMT-8"}` |
| Lire la date et l'heure | `{"OP":"TimeGet"}` |
| Regler la date et l'heure | `{"OP":"TimeSet","year":2026,"month":10,"day":9,"hour":14,"minute":35,"seconds":2}` |
| Lire la version | `{"OP":"VersionGet"}` |
| Lire les informations materielles | `{"OP":"HwInfoGet"}` |
| Lire l'identifiant | `{"OP":"ReaderIdGet"}` |
| Modifier l'identifiant ; affecte aussi le nom Bluetooth selon le document | `{"OP":"ReaderIdSet","readerid":"88990022"}` |
| Redemarrer la carte ; interrompt son fonctionnement | `{"OP":"DeviceReboot"}` |
| Lire la licence | `{"OP":"LicenseGet"}` |
| Installer une licence constructeur ; ne pas utiliser une cle d'exemple | `{"OP":"LicenseSet","license":"<CLE_FOURNIE_PAR_LE_CONSTRUCTEUR>"}` |

## Ethernet, Wi-Fi et Bluetooth

Les changements reseau peuvent interrompre une connexion reseau existante.

| Fonction | Commande / exemple |
| --- | --- |
| Lire la configuration Ethernet | `{"OP":"EthConfigGet"}` |
| Ethernet statique | `{"OP":"EthConfigSet","dhcp":"0","ip":"192.168.0.101","nmask":"255.255.255.0","gw":"192.168.0.1"}` |
| Ethernet DHCP | `{"OP":"EthConfigSet","dhcp":"1"}` |
| Lire la MAC Ethernet | `{"OP":"EthMacGet"}` |
| Lire la configuration Wi-Fi | `{"OP":"WifiConfigGet"}` |
| Wi-Fi statique | `{"OP":"WifiConfigSet","dhcp":"0","ip":"192.168.1.254","nmask":"255.255.255.0","gw":"192.168.1.1"}` |
| Wi-Fi DHCP | `{"OP":"WifiConfigSet","dhcp":"1"}` |
| Lire le SSID et le mot de passe ; reponse sensible | `{"OP":"WifiSsidPasswGet"}` |
| Modifier le SSID et le mot de passe | `{"OP":"WifiSsidPasswSet","ssid":"<SSID>","passw":"<MOT_DE_PASSE>"}` |
| Lire la MAC Wi-Fi | `{"OP":"WifiMacGet"}` |
| Lire le port du serveur TCP | `{"OP":"LocalTcpPortGet"}` |
| Modifier le port TCP | `{"OP":"LocalTcpPortSet","tcpport":8080}` |
| Lire le port WebSocket ; nom normalise, voir les reserves en fin de fichier | `{"OP":"WebsocketPortGet"}` |
| Modifier le port WebSocket | `{"OP":"WebsocketPortSet","wsport":8090}` |
| Lire la configuration Bluetooth | `{"OP":"BleConfigGet"}` |
| Configurer le code Bluetooth ; 0 = sans appairage selon le document | `{"OP":"BleConfigSet","blekey":123456}` |

## HTTP et MQTT

| Fonction | Commande / exemple |
| --- | --- |
| Lire l'URL HTTP de remontee | `{"OP":"HttpUrlGet"}` |
| Modifier l'URL HTTP | `{"OP":"HttpUrlSet","httpurl":"http://192.168.0.111:5460"}` |
| Lire la connexion MQTT ; peut contenir des identifiants | `{"OP":"MqttConGet"}` |
| Modifier la connexion MQTT | `{"OP":"MqttConSet","version":3,"mqtturl":"mqtt://192.168.0.6","port":1883,"user":"<UTILISATEUR>","passw":"<MOT_DE_PASSE>","cleansession":1}` |
| Lire le topic de publication | `{"OP":"MqttPubGet"}` |
| Modifier la publication | `{"OP":"MqttPubSet","pubtopic":"pubtopic","pubqos":0,"pubretain":0}` |
| Lire le topic d'abonnement | `{"OP":"MqttSubGet"}` |
| Modifier l'abonnement et le topic de reponse | `{"OP":"MqttSubSet","subtopic":"subtopic","subqos":2,"restopic":"restopic"}` |

## Format et periodicite des remontees

| Fonction | Commande / exemple |
| --- | --- |
| Lire la configuration des remontees | `{"OP":"ReportCfgGet"}` |
| Modifier les remontees | `{"OP":"ReportCfgSet","router":0,"timer":10,"rptime":1,"rpmaxnum":1,"clearcache":30,"jsontype":2}` |
| Lire les options supplementaires | `{"OP":"ReportCfgExGet"}` |
| Modifier les options supplementaires | `{"OP":"ReportCfgExSet","devid":0,"gpistatus":0,"heartbeat":0,"posttime":1,"gpostatus":0}` |

- `router` : 0 = Wi-Fi/Ethernet, 1 = 4G.
- `timer` et `clearcache` : secondes ; `rpmaxnum` : maximum 100 EPC selon le document.
- `jsontype` : 0 = defaut, 1 et 2 = formats personnalises.
- `gpistatus` : 0 = aucun, 1 = connexion de l'inventaire automatique, 2 = TCP, 3 = RS232.
- `heartbeat` : intervalle annonce superieur a 30 secondes pour activer les remontees.

## Reglages RFID et antennes

| Fonction | Commande / exemple |
| --- | --- |
| Lire la region | `{"OP":"RegionGet"}` |
| Modifier la region ; ne pas changer pour le diagnostic | `{"OP":"RegionSet","region":"NA"}` |
| Lire les puissances | `{"OP":"PowersGet"}` |
| Modifier les puissances ; echelle brute du protocole | `{"OP":"PowersSet","powers":[{"ant":1,"read":2300,"write":2300}]}` |
| Lire les antennes actives | `{"OP":"AntennasGet"}` |
| Selectionner les antennes | `{"OP":"AntennasSet","ants":[1,4]}` |
| Lire la session Gen2 | `{"OP":"Gen2SessionGet"}` |
| Modifier la session ; 0 a 3 | `{"OP":"Gen2SessionSet","value":1}` |
| Lire le mode RF | `{"OP":"Gen2RfModeGet"}` |
| Modifier le mode RF | `{"OP":"Gen2RfModeSet","value":107}` |
| Lire la valeur Q | `{"OP":"Gen2QvalueGet"}` |
| Modifier la valeur Q | `{"OP":"Gen2QvalueSet","value":3}` |
| Lire la cible Gen2 | `{"OP":"Gen2TargetGet"}` |
| Modifier la cible ; nom confirme dans le SDK Android | `{"OP":"Gen2TargetSet","value":"B"}` |
| Lire la table de frequences | `{"OP":"HopTableGet"}` |
| Modifier la table ; exemple constructeur, ne pas envoyer pour le diagnostic | `{"OP":"HopTableSet","value":[915750,915250,903250]}` |
| Lire l'unicite par antenne | `{"OP":"UniByAntGet"}` |
| Modifier l'unicite par antenne | `{"OP":"UniByAntSet","value":false}` |
| Lire l'unicite par banque memoire | `{"OP":"UniByBankGet"}` |
| Modifier l'unicite par banque | `{"OP":"UniByBankSet","value":true}` |
| Lire la conservation du RSSI maximum | `{"OP":"MaxRssiGet"}` |
| Modifier la conservation du RSSI maximum | `{"OP":"MaxRssiSet","value":true}` |
| Lire les champs retournes pour les etiquettes | `{"OP":"TagInfoGet"}` |
| Modifier les champs retournes | `{"OP":"TagInfoSet","counts":1,"rssi":1,"antid":1,"freq":1,"timestamp":1,"phase":0}` |
| Lire les champs supplementaires | `{"OP":"TagInfoExGet"}` |
| Modifier les champs supplementaires | `{"OP":"TagInfoExSet","vascii":0,"time":1,"uniantid":0}` |

Regions listees par le constructeur : `NA`, `CN`, `EUR`, `KOR`, `ALL`.
Cibles Gen2 : `A`, `B`, `A-B`, `B-A`.
Modes RF listes : 0, 1, 2, 3, 101, 103, 105, 107, 111, 112, 113, 115, 203, 220, 45.
Ces possibilites ne garantissent pas que le module RFID monte les accepte toutes.

## Lecture des etiquettes

Les commandes ci-dessous demarrent une operation radio. Utiliser les antennes
effectivement raccordees. Ne pas lancer un deuxieme inventaire si un autre tourne deja.

| Fonction | Commande / exemple |
| --- | --- |
| Inventaire synchrone limite dans le temps | `{"OP":"SyncInventory","timeout":200}` |
| Inventaire synchrone sur des antennes choisies | `{"OP":"SyncInventory","timeout":200,"ants":[1,3]}` |
| Demarrer un inventaire asynchrone | `{"OP":"AsyncInvStart"}` |
| Demarrer sur des antennes choisies | `{"OP":"AsyncInvStart","ants":[1,2,3]}` |
| Arreter l'inventaire asynchrone | `{"OP":"AsyncInvStop"}` |
| Inventaire avec filtre EPC | `{"OP":"SyncInventory","tag_filter":{"bank":1,"start_bit":32,"mask":"E280","match":true}}` |
| Inventaire avec lecture TID | `{"OP":"SyncInventory","bank_data":{"bank":2,"start_word":0,"word_count":6}}` |
| Inventaire asynchrone avec filtre | `{"OP":"AsyncInvStart","tag_filter":{"bank":1,"start_bit":32,"mask":"E280","match":false}}` |
| Inventaire asynchrone avec lecture TID | `{"OP":"AsyncInvStart","bank_data":{"bank":2,"start_word":0,"word_count":6}}` |
| Lire une banque memoire | `{"OP":"BankDataGet","bank":1,"start_word":2,"word_count":6}` |
| Lire une banque avec filtre | `{"OP":"BankDataGet","bank":1,"start_word":2,"word_count":4,"tag_filter":{"bank":1,"start_bit":32,"mask":"1111","match":true}}` |

`tag_filter` : `bank`, position `start_bit` en bits, `mask` hexadecimal,
`match:true` pour inclure les correspondances, `false` pour les exclure.
`bank_data` : `bank`, position `start_word`, nombre `word_count`, et mot de passe
optionnel `password` (exemple de syntaxe : `"12345678"`).
Banques : 0 = reservee/mots de passe, 1 = EPC, 2 = TID, 3 = utilisateur.
Le document JSON ne precise pas clairement l'unite de `timeout` ; 200 est son exemple,
pas une garantie d'une duree en secondes.

## Inventaire automatique et declencheurs

Ces commandes peuvent changer le comportement permanent du portail et ses sorties.

| Fonction | Commande / exemple |
| --- | --- |
| Lire le mode automatique | `{"OP":"AutoInvGet"}` |
| Configurer le mode automatique | `{"OP":"AutoInvSet","mode":"TCP_FAST","duration":5,"start1":"GPI1","stop1":"GPI2","start2":"GPI2","stop2":"GPI1"}` |
| Desactiver le mode automatique | `{"OP":"AutoInvSet","mode":"NONE","duration":10,"start1":"NONE","stop1":"NONE","start2":"NONE","stop2":"NONE"}` |
| Lire la configuration avancee | `{"OP":"AutoInvCfgGet"}` |
| Modifier la configuration avancee | `{"OP":"AutoInvCfgSet","stopdelay":0,"syncinterv":1000,"synctimeout":200,"ingpi":1,"outgpi":2,"ingpidur":1,"outgpidur":5}` |
| Lire les declencheurs GPIO | `{"OP":"AutoInvGpioGet"}` |
| Modifier les declencheurs GPIO | `{"OP":"AutoInvGpioSet","gpisstart":1,"gpisstop":2}` |

- Modes : `NONE`, `HTTP`, `MQTT`, `TCP`, `RS232`, `TCP_FAST`, `RS232_FAST`,
  `MQTT_DB`, `HTTP_DB`, `MQTT_SG`, `HTTP_SG`, `WEBSOCKET`.
- `duration` : secondes, 0 = continu.
- Declencheurs listes : `NONE`, `GPI1`, `GPI2`, `GPI3`, `GPI12HIGH`, `GPI12LOW`, `OTHER`.
- `OTHER` permet d'utiliser la configuration AutoInvGpioSet selon les conditions du document.
- AutoInvCfgSet accepte aussi `triggpo`, `epc0gpo`, `epc1gpo`, `gpodur`,
  `tag_filter`, `bank_data`, `legalgpo`, `illegalgpo` (ces deux derniers pour HTTP).
- AutoInvGpioSet montre aussi `allstop`, `gpiants`, `gpi1triggpo` a `gpi7triggpo`.
- Masques GPIO en decimal : 1 = premiere sortie/entree, 2 = deuxieme, 4 = troisieme,
  7 = les trois. Le document est ambigu sur certaines correspondances de `gpiants`.

## Entrees et sorties GPIO

GpoSet et les reglages associes peuvent actionner les equipements raccordes.

| Fonction | Commande / exemple |
| --- | --- |
| Lire les sorties | `{"OP":"GpoGet"}` |
| Modifier une sortie | `{"OP":"GpoSet","num":2,"level":1}` |
| Lire une entree | `{"OP":"GpiGet","num":1}` |
| Lire les sorties declenchees par une etiquette | `{"OP":"TagGpoGet"}` |
| Modifier ces sorties | `{"OP":"TagGpoSet","tgpo":1,"tlevel":1,"tduration":2}` |
| Modifier ces sorties avec filtre EPC | `{"OP":"TagGpoSet","tgpo":2,"tlevel":1,"tduration":1,"epc_filter":{"start_byte":0,"mask":"E280","match":true}}` |
| Lire les sorties d'indication d'etat | `{"OP":"IndicatorGpoGet"}` |
| Modifier les sorties d'indication | `{"OP":"IndicatorGpoSet","initgpo":2,"ethgpo":1,"wifigpo":0,"rfidgpo":3,"gpodur":1,"resetgpo":0}` |

## Base interne des etiquettes

| Fonction | Commande |
| --- | --- |
| Compter les enregistrements | `{"OP":"DbGetCount"}` |
| Recuperer plusieurs enregistrements | `{"OP":"DbGetMulti"}` |
| EFFACER la base | `{"OP":"DbClear"}` |
| SUPPRIMER le fichier de base | `{"OP":"DbFileDel"}` |

## Maintenance et liaisons internes

Ne pas modifier les debits ou le niveau de reset sans connaitre le module installe.
RfidBaudSet concerne la liaison carte-module RFID, pas un reglage du moniteur COM18.

| Fonction | Commande / exemple |
| --- | --- |
| Reinitialiser le module RFID ; syntaxe normalisee a confirmer, voir reserves | `{"OP":"RfidReset"}` |
| Lire le niveau de reset RFID | `{"OP":"RfidRstLevelGet"}` |
| Modifier le niveau de reset | `{"OP":"RfidRstLevelSet","rstlevel":1}` |
| Lire le debit interne RFID | `{"OP":"RfidBaudGet"}` |
| Modifier le debit interne RFID | `{"OP":"RfidBaudSet","rfidbuad":115200}` |
| Lire le debit et l'adresse RS485 | `{"OP":"Rs485CfgGet"}` |
| Modifier la liaison RS485 | `{"OP":"Rs485CfgSet","rs485buad":115200,"rs485addr":1}` |
| Exemple adresse sur RS485 uniquement | `{"addr":1,"OP":"Rs485CfgGet"}` |
| Lire l'activation des logs | `{"OP":"DebugLogGet"}` |
| Envoyer les logs sur RS232 | `{"OP":"DebugLogSet","debugl":2}` |
| Desactiver les logs | `{"OP":"DebugLogSet","debugl":0}` |
| Lire l'URL de mise a jour OTA | `{"OP":"OtaURLGet"}` |
| Modifier l'URL OTA ; uniquement un paquet valide pour cette carte | `{"OP":"OtaURLSet","otaURL":"<URL_PAQUET_CONSTRUCTEUR>"}` |
| RETABLIR les reglages d'usine | `{"OP":"FactoryRst"}` |

`debugl` : 0 = arret, 1 = TCP, 2 = RS232, 3 = TCP prioritaire puis RS232.
Les noms `rfidbuad` et `rs485buad` sont ceux du document, meme si leur orthographe surprend.
Le document presente OtaURLSet comme un reglage d'URL, sans commande distincte
de lancement de mise a jour : ne pas lui attribuer d'autre effet sans verification.

## Ecriture, verrouillage et destruction d'etiquettes

Ne pas envoyer ces exemples pendant le diagnostic. Isoler une seule etiquette de test
et utiliser un filtre adapte avant toute ecriture. Les exemples du constructeur sans
filtre peuvent toucher une etiquette autre que celle souhaitee.

| Fonction | Commande / exemple constructeur |
| --- | --- |
| ECRIRE un nouvel EPC | `{"OP":"WriteTagEpc","ant":1,"epc":"111111112222222233333333"}` |
| ECRIRE un EPC avec filtre | `{"OP":"WriteTagEpc","ant":1,"epc":"113311112222222233333333","tag_filter":{"bank":1,"start_bit":32,"mask":"1111","match":true}}` |
| ECRIRE une banque | `{"OP":"WriteTagBank","ant":1,"bank":1,"start_word":2,"bank_data":"221111112222222233333333"}` |
| VERROUILLER une zone | `{"OP":"LockTag","ant":1,"area":2,"action":1,"password":"00000000"}` |
| DESACTIVER DEFINITIVEMENT une etiquette | `{"OP":"KillTag","ant":1,"password":"00000000"}` |

LockTag : `area` 0 = mot de passe kill, 1 = mot de passe d'acces, 2 = EPC,
3 = TID, 4 = utilisateur. `action` 0 = deverrouiller, 1 = verrouiller,
2 = deverrouiller definitivement, 3 = verrouiller definitivement.
L'acceptation depend aussi de l'etiquette et de ses mots de passe.

## Reponses et erreurs

Une reponse de commande ressemble a `{"RES":"ReaderIdGet:OK",...}`.
Un arret d'inventaire synchrone peut annoncer `SyncInvStop:TIMEOUT`,
`SyncInvStop:STOP1` ou `SyncInvStop:STOP2`.

| Code | Signification annoncee |
| --- | --- |
| 160 | NOT_LICENSE : carte non autorisee |
| 161 | LICENSE_FAIL : erreur d'autorisation |
| 201 | Instruction inconnue / incorrecte |
| 202 | Operation incorrecte |
| 203 | Parametre incorrect |
| 220 | Erreur d'ouverture de base |
| 221 | Erreur de lecture de base |
| 222 | Aucun enregistrement |
| 223 | Autre erreur de base |
| 224 | Code nomme DATABASEE_CLEAR_OK dans le document |
| 301 | NVS_NOT_FOUND |
| 302 | NVS_OPEN |
| 303 | NVS_GET_KEY |
| 304 | NVS_SET_VALUE |
| 305 | NVS_COMMIT |

Un message Java contenant le nom NOT_LICENSE n'est pas a lui seul une reponse
protocole ERR=160 : distinguer une exception de l'application d'un refus de la carte.

## Reserves sur le document constructeur

- L'exemple de modification de cible porte `Gen2TargetGet` ; le nom
  `Gen2TargetSet` est confirme par le bytecode du SDK Android N01_1.3.1.6.jar.
- RfidReset et WebsocketPortGet portent `ON` au lieu de `OP` dans le document.
  Les exemples ci-dessus normalisent cette cle par coherence avec le protocole,
  mais ces deux corrections n'ont pas ete confirmees par un essai materiel.
- Certains exemples AutoInvGpioSet portent aussi `ON` ; d'autres exemples de la
  meme commande utilisent bien `OP`, qui est conserve ici.
- Les guillemets typographiques du document sont remplaces par des guillemets JSON.
- Les commandes de cette liste n'ont pas toutes ete testees sur ce controleur.
  Un ERR=201 peut signaler une commande non prise en charge par son firmware.
