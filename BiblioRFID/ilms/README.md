# Paquet ILMS embarqué

Ce dossier reçoit l'interface ILMS compilée. Il est volontairement vide dans le
dépôt : le contenu est produit par le projet
[`bibliotheque-ztf/apps/ilms`](https://gitlab.com/bibliotheque-ztf/apps/ilms) et
n'est pas versionné ici.

## Produire le paquet

Dans une copie du dépôt ILMS :

```powershell
npm install --legacy-peer-deps
npx ng build --base-href /ilms/ --configuration production
```

Puis copier le contenu de `dist/wcl/browser/` dans ce dossier, de sorte que
`ilms/index.html` existe.

Deux réglages sont indispensables côté ILMS :

- `--base-href /ilms/` : le poste sert l'application sous ce préfixe, et non à
  la racine (le dépôt ILMS a `<base href="/">` pour son déploiement nginx) ;
- `apiUrl: "/gateway"` dans l'environnement utilisé pour cette compilation, au
  lieu de l'adresse absolue de la passerelle. Les appels passent alors par le
  relais du poste, restent sur son origine — donc sans CORS — et bénéficient du
  message d'indisponibilité quand Internet est coupé. Prévoir pour cela un
  `src/environments/environment.desktop.ts` et une configuration `desktop` dans
  `angular.json`.

## Sans ce paquet

L'exécutable se construit et fonctionne normalement : l'onglet ILMS affiche
alors « Module ILMS absent de cette version », et toutes les fonctions RFID du
poste restent disponibles.

## WebSocket

Le relais `/gateway/` ne transporte que HTTP. Les canaux WebSocket de la
passerelle (`/library-service/ws/**`, `/notification-service/ws/**`) doivent
être contactés directement à leur adresse publique.
