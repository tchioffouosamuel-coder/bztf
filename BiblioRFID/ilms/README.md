# Paquet ILMS embarqué

Ce dossier reçoit l'interface ILMS compilée. Il est volontairement vide dans le
dépôt : le contenu est produit par le projet
[`bibliotheque-ztf/apps/ilms`](https://gitlab.com/bibliotheque-ztf/apps/ilms) et
n'est pas versionné ici.

## Produire le paquet

Dans une copie du dépôt ILMS :

```powershell
npm ci --force
npm run build:desktop
```

Puis copier le contenu de `dist/wcl/browser/` dans ce dossier, de sorte que
`ilms/index.html` existe.

La configuration `desktop` de l'ILMS produit exactement le même paquet que la
production : **aucune adaptation n'est nécessaire**. L'application appelle son
API par des chemins relatifs à son origine, et le poste la sert à la racine
d'un port local dédié, où il relaie `/api/**` vers la passerelle — le même
montage que le proxy de production. Ni `--base-href`, ni variable d'API à
changer.

## Sans ce paquet

L'exécutable se construit et fonctionne normalement : l'onglet ILMS affiche
alors « Module ILMS absent de cette version », et toutes les fonctions RFID du
poste restent disponibles.

## WebSocket

Le relais ne transporte que HTTP. Les canaux WebSocket de la passerelle
(`/library-service/ws/**`, `/notification-service/ws/**`) doivent être
contactés directement à leur adresse publique.
