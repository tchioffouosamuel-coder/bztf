# Câblage du pont RFID ESP32

Brochage de référence pour une carte **ESP32-WROOM-32 DevKit v1**. Toute
modification doit être reportée dans `src/config.h` : ce fichier est la seule
source des numéros de broches du firmware.

## 1. Table de câblage

### Module UHF (famille M100 / QM100 / R200)

| Broche module | Broche ESP32 | Remarque |
|---|---|---|
| `RXD` (entrée données) | **GPIO 17** (TX2) | Croisement obligatoire : TX du pont → RX du module |
| `TXD` (sortie données) | **GPIO 16** (RX2) | TX du module → RX du pont |
| `EN` / `PWR` | **GPIO 4** | Actif haut. Non câblé : mettre `PIN_UHF_EN = -1` |
| `VCC` (3,3 V) | **Régulateur 3,3 V dédié**, pas la broche 3V3 de la carte | Voir section 3 |
| `GND` | **GND** | Masse commune impérative avec l'ESP32 |
| `ANT` | Antenne UHF | Ne jamais émettre sans antenne |

### Indicateurs

| Signal | Broche ESP32 | Composant | Résistance série |
|---|---|---|---|
| LED rouge | **GPIO 26** | Anode LED rouge | 220 Ω vers GND |
| LED verte | **GPIO 27** | Anode LED verte | 150 Ω vers GND |
| LED bleue | **GPIO 14** | Anode LED bleue | 150 Ω vers GND |
| Buzzer | **GPIO 25** | Entrée `I/O` du buzzer actif, ou borne + du buzzer passif | 1 kΩ en base si transistor |
| Bouton configuration | **GPIO 0** | Bouton BOOT de la carte | Résistance de tirage interne, appui = niveau bas |

Les trois LED sont en **cathode commune** vers GND dans ce schéma
(`LED_ACTIVE_HIGH = true`). Avec une LED RGB à anode commune, relier l'anode au
3V3 et passer `LED_ACTIVE_HIGH` à `false`.

### Broches à ne pas utiliser

| Broches | Raison |
|---|---|
| GPIO 6 à 11 | Reliées à la mémoire flash interne : la carte ne démarre plus |
| GPIO 34 à 39 | Entrées seules, aucune sortie possible |
| GPIO 1 / GPIO 3 | UART0, utilisé par le lien USB et le flashage |
| GPIO 12 / GPIO 15 | Broches de configuration de démarrage, sensibles à l'état au reset |

## 2. Schéma d'ensemble

```
        Alimentation 5 V / 2 A
                 │
      ┌──────────┴──────────┐
      │                     │
      │             ┌───────┴────────────────────┐
      │             │ Régulateur 3,3 V  ≥ 1,5 A  │
      │             │ (AMS1117-3.3 / MP1584)     │
      │             └───────┬────────────────────┘
      │                     │ 3,3 V            ┌── 470 µF ──┐
      │                     ├──────────────────┤            ├── GND
      │                     │                  └── 100 nF ──┘
      │                     │
┌─────┴───────────────┐     │        ┌──────────────────────────────┐
│   ESP32-WROOM-32    │     │        │   Module UHF M100 / R200     │
│      DevKit v1      │     └───────►│ VCC                          │
│                     │              │                              │
│  VIN (5V) ◄─────────┤              │                              │
│  GND ───────────────┼──── GND ─────┤ GND                          │
│                     │              │                              │
│  GPIO17 (TX2) ──────┼─────────────►│ RXD                          │
│  GPIO16 (RX2) ◄─────┼──────────────┤ TXD                          │
│  GPIO4  ────────────┼─────────────►│ EN                           │
│                     │              │                          ANT ├──► antenne UHF
│                     │              └──────────────────────────────┘
│                     │
│  GPIO26 ──[220 Ω]───┼──►|◄── LED rouge ──── GND
│  GPIO27 ──[150 Ω]───┼──►|◄── LED verte ──── GND
│  GPIO14 ──[150 Ω]───┼──►|◄── LED bleue ──── GND
│                     │
│  GPIO25 ────────────┼──► buzzer (voir section 4)
│  GPIO0  ────────────┼──► bouton BOOT (intégré à la carte)
│                     │
│  micro-USB ◄────────┼──► poste de travail (flashage + lien UART)
└─────────────────────┘
```

## 3. Alimentation : le point critique

Le module UHF consomme peu au repos mais appelle des pointes de courant à
chaque salve d'émission. Deux erreurs se traduisent par des redémarrages
inexpliqués de l'ESP32 ou par un module qui ne répond plus après quelques
lectures :

1. **Alimenter le module depuis la broche 3V3 du DevKit.** Le régulateur
   embarqué de la carte ne délivre pas le courant nécessaire. Il faut un
   régulateur 3,3 V séparé, alimenté par le même 5 V.
2. **Omettre le condensateur réservoir.** Placer les 470 µF (ou 1000 µF) le
   plus près possible de la broche `VCC` du module, avec un 100 nF en
   parallèle.

La masse doit être commune entre l'ESP32, le régulateur et le module : sans
cela, l'UART ne décode rien.

Pendant la mise au point, alimenter la carte par l'USB du poste **et** le
module par le régulateur 5 V externe est acceptable, à condition que les
masses soient reliées. Ne jamais relier deux sorties 5 V (USB et alimentation
externe) entre elles.

## 4. Buzzer : les deux montages

**Buzzer actif, module 3 broches** (`BUZZER_IS_PASSIVE = false`) :

```
GPIO25 ──► I/O        VCC ──► 3,3 V        GND ──► GND
```

**Buzzer passif ou consommation supérieure à 20 mA** — un transistor est
nécessaire, l'ESP32 ne doit pas fournir le courant du buzzer :

```
                       5 V
                        │
                    ┌───┴───┐
                    │buzzer │
                    └───┬───┘
                        │          ┌───── diode 1N4148 en inverse
                        ├──────────┤      aux bornes du buzzer
                        │          └───── (si buzzer électromagnétique)
                   collecteur
GPIO25 ──[1 kΩ]── base  2N2222
                   émetteur
                        │
                       GND
```

Avec un buzzer passif, passer `BUZZER_IS_PASSIVE` à `true` dans
`src/config.h` : le firmware génère alors la fréquence (2,7 kHz par défaut)
en PWM. Avec un buzzer actif, la fréquence est fixée par le composant et le
firmware ne fait que l'activer.

## 5. Vérifications avant la première mise sous tension

1. L'antenne est raccordée au module. **Aucune émission sans antenne.**
2. Les masses ESP32 / régulateur / module sont bien reliées entre elles.
3. Mesurer 3,3 V ± 0,1 V sur la broche `VCC` du module, module au repos.
4. `GPIO17` va vers `RXD` et `GPIO16` vers `TXD` : le croisement est la
   première cause de silence complet du module.
5. Aucune des broches interdites (section 1) n'est utilisée.
6. Après flashage, ouvrir le moniteur série à **115200 bauds** : une ligne
   `__RFID_JSON__{"type":"ready",…}` doit apparaître, puis la réponse à
   l'action `moduleInfo` doit contenir la version du module. Si cette réponse
   est vide, c'est le dialogue UART ou la table d'opcodes qu'il faut reprendre,
   pas l'antenne.

## 6. Signification des indicateurs

| Indicateur | Signification |
|---|---|
| Bleu respirant | Démarrage, aucun lien réseau ou Bluetooth ouvert |
| Bleu clignotant rapide | Association Wi-Fi en cours |
| Bleu fixe faible | Lien ouvert, lecteur au repos (pas d'inventaire) |
| Vert fixe faible | Inventaire en cours |
| Vert vif bref + un bip | Nouveau tag retenu et publié |
| Bleu vif bref, sans bip | Tag déjà signalé, verrou sonore encore actif |
| Violet | Écriture ou désencodage en cours |
| Rouge clignotant + deux bips | Module muet, commande refusée, écriture non vérifiée |
