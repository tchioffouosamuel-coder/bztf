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

## Fonctions

- Tableau de bord et compteurs du catalogue;
- catalogue local SQLite, recherche, filtres, création, modification et suppression;
- import XLSX, sans doublons, et export CSV;
- lecture RFID, association d’un tag à un livre, encodage et désencodage vérifiés;
- historique des connexions et opérations;
- mode Simulation pour essayer le parcours sans matériel.

Les données restent dans la base SQLite privée de l’application. L’import prend le classeur fourni par le sélecteur de fichiers Android.

## Vérification

```powershell
flutter analyze
flutter test
```

Un terminal Seuic compatible doit être connecté pour valider l’ouverture du service UHF, la lecture réelle et l’écriture physique des tags.
