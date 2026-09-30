# Bibliothèque ZTF

Version Flutter Android de Bibliothèque ZTF, prévue pour le lecteur UHF intégré au terminal Android.

## Démarrage

Depuis ce dossier :

```powershell
flutter pub get
flutter run
```

Pour produire l’APK debug :

```powershell
flutter build apk --debug
```

L’APK est produit dans `build/app/outputs/flutter-apk/app-debug.apk`.

## Lecteur RFID

Le lecteur intégré utilise le service Seuic `UHFService` du démonstrateur `Android/Android原生开发/src/UHFDemo2` (`uhf.jar` et la bibliothèque système `com.seuic.uhf`). Il s’ouvre avec `UHFService.open()`; aucun chemin `/dev/ttyS*` n’est à saisir. Le mode TCP utilise le SDK N01 et la station conserve le mode Simulation.

Le flux RFID lit l’EPC et le TID en continu. Toute écriture ou désécriture exige un seul tag détecté et le TID correspondant; l’EPC est relu avant de modifier le catalogue.

## Connexion

L’application ne s’ouvre qu’après identification, comme l’application Windows :

- à la toute première ouverture, on crée le compte **administrateur** de l’appareil (nom, e-mail, mot de passe de 8 caractères minimum) ;
- ensuite, chaque ouverture demande l’e-mail et le mot de passe. Après 5 échecs, les essais sont bloqués 30 secondes ;
- un administrateur ajoute, active ou désactive les comptes (administrateur ou opérateur) dans *Réglages › Compte* ou dans l’onglet *Poste* du terminal admin. Le dernier administrateur ne peut pas être désactivé.

Les mots de passe sont stockés en PBKDF2-HMAC-SHA256 (60 000 itérations, sel aléatoire), jamais en clair. Les comptes sont propres à l’appareil et ne sont pas synchronisés.

Sur un poste d’emprunt, le personnel se connecte au démarrage ; le poste reste ensuite ouvert pour les abonnés, qui n’ont pas de compte. La déconnexion se fait depuis le menu protégé par le code administrateur du poste.

## Type d’appareil

Après la première connexion, l’application demande le rôle de l’appareil :

- **Poste d’emprunt** : tablette fixe reliée au lecteur RFID de bureau. L’application s’ouvre directement sur le poste en libre-service ; seul le code administrateur permet d’en sortir.
- **Lecteur mobile** : terminal du personnel (catalogue, station, inventaire, localisation, prêts au comptoir).
- **Portail antivol** : tablette reliée au portail RFID N01 de la sortie. L’application s’ouvre en plein écran sur la surveillance ; seul le code administrateur permet d’en sortir.

Le rôle se change ensuite dans le terminal admin (onglet *Poste*, bouton *Changer*).

## Portail antivol

Le portail utilise le SDK « N01RFID » (`android/app/libs/N01_1.3.1.6.jar`) via `GateBridge.kt` :

- **TCP/IP** : adresse IP seule, le SDK impose le port **8080** ;
- **Série RS232** : `dev/ttyS5` (115 200 bauds imposés par le SDK) ;
- **Simulation** : barre de test (entrée, sortie, livre, badge du personnel).

Fonctions :

- **Alarme antivol** : un livre signé « BCM » qui passe sans emprunt en cours déclenche le message vocal *« Attention ! Ne sortez pas avec un livre non emprunté. Redirigez-vous vers le poste d’emprunt. Si vous avez des difficultés, allez au poste d’emprunt assisté. »* sur fond de sirène douce, joué par la tablette (flux « alarme », volume réglable), et allume le voyant rouge du portail (GPO1). **Le buzzer du portail n’est jamais utilisé** : à la connexion, l’application le retire des sorties que le portail déclenche seul (indicateur de lecture et GPO après lecture). L’écran affiche le livre en cause ; l’alarme s’arrête seule ou avec le code administrateur. Un livre resté près du portail ne réalarme qu’après un délai d’absence réglable. Livres empruntés, cartes d’abonné et badges ne déclenchent rien.
- **Entrées et sorties du jour** : comptées d’après l’ordre de coupure des deux barrières infrarouges (entrées GPI) : extérieure puis intérieure = entrée. Le terminal admin affiche l’état des barrières en direct et permet d’inverser le sens. Les compteurs (entrées, sorties, alarmes) sont synchronisés par jour et par portail.
- **Personnel** : un badge du personnel (EPC « BCM » 3, encodé sur le poste Windows, module *Personnel*) enregistre une entrée ou une sortie. Le sens vient des barrières quand une coupure est mesurée autour de la lecture ; sans barrière, les passages alternent (premier passage du jour = entrée). Les passages sont synchronisés vers Windows.

Le message d’alarme (`android/app/src/main/res/raw/gate_alarm.wav`) se régénère avec `tool/gate_alarm/generate.ps1` (voix Windows fr-FR, Python et numpy).

À valider sur site avec le portail réel : sens des barrières (bouton *Inverser*), puissance des antennes (ne pas lire les livres rangés à proximité) et coupure effective du buzzer (un avertissement s’affiche si le portail la refuse).

## Poste d’emprunt

Le poste utilise le SDK « RFID Desktop Reader » (`android/app/libs/reader.jar`, classe `GClient`) via `DeskReaderBridge.kt`, indépendamment du lecteur Seuic intégré :

- **TCP/IP** : `192.168.1.168` ou `192.168.1.168:8160` (port 8160 par défaut) ;
- **Série RS232** : `/dev/ttyS1` ou `/dev/ttyS1:115200`. Le port doit être accessible à l’application (le SDK tente `su chmod 666` sinon). La bibliothèque JNI `libSerialPort.so` attendue par le SDK est compilée depuis `android/app/src/main/cpp` pour arm64-v8a et armeabi-v7a (le SDK ne fournit qu’une version 32 bits) ;
- **Simulation** : barre de test pour poser des cartes et des livres virtuels.

Le SDK Android ne gère pas la connexion USB directe du lecteur de bureau : utilisez l’Ethernet (TCP) ou un port série.

Parcours abonné :

- **Emprunter** : l’abonné pose sa carte et ses livres. L’emprunt est autorisé si le compte est actif, l’abonnement valide, aucun livre n’est en retard et le nombre d’emprunts simultanés reste sous la limite. Un reçu indique la date de retour.
- **Rendre** : les livres seuls, sans carte. Un livre emprunté posé sur l’accueil ouvre directement le retour.

Les cartes sont reconnues par leur EPC « BCM 2 » et leur TID (un préfixe commun de 8 octets suffit, les lecteurs ne lisant pas tous la même longueur de TID).

## Terminal admin

Accessible depuis le poste (icône cadenas + code, **1234** par défaut, à changer) ou depuis l’accueil du lecteur mobile :

- **Emprunts** : historique filtrable (en cours, en retard, rendus), recherche, retour manuel et export CSV ;
- **Abonnés** : éligibilité, emprunts en cours, renouvellement ou suspension de l’abonnement ;
- **Poste** : type d’appareil, connexion et puissance du lecteur de bureau, règles de prêt (livres par abonné, durée), code administrateur.

Tout est synchronisé avec le serveur : livres, abonnés et cartes, abonnements et emprunts. Un livre emprunté sur un appareil (poste, mobile ou Windows) peut être rendu sur n’importe quel autre. Un emprunt reçu avant son livre ou son abonné est mis de côté puis appliqué dès que la référence arrive.

## Fonctions

- Tableau de bord et compteurs du catalogue;
- catalogue local SQLite, recherche, filtres, création, modification et suppression;
- import XLSX, sans doublons, et export CSV;
- lecture RFID, association d’un tag à un livre, encodage et désencodage vérifiés;
- localisation d’un livre sur radar : la boussole du terminal associe chaque lecture du tag au cap visé ; en tournant lentement sur soi-même, le point jaune se place vers le livre, plus près du centre quand le signal augmente, avec la consigne « Tournez de 40° à droite » (sans boussole : force du signal seule);
- historique des connexions et opérations;
- poste d’emprunt en libre-service et terminal admin des emprunts ;
- mode Simulation pour essayer le parcours sans matériel.

Les données restent dans la base SQLite privée de l’application. L’import prend le classeur fourni par le sélecteur de fichiers Android.

## Vérification

```powershell
flutter analyze
flutter test
```

Un terminal Seuic compatible doit être connecté pour valider l’ouverture du service UHF, la lecture réelle et l’écriture physique des tags.
