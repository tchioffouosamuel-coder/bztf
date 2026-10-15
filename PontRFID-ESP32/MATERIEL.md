# Matériel du pont RFID ESP32

Liste de référence pour une station. Les désignations correspondent à des
composants couramment disponibles ; toute substitution doit respecter les
contraintes de la colonne **Pourquoi ce choix**.

## 1. Nomenclature

| # | Composant | Caractéristiques exigées | Qté | Pourquoi ce choix |
|---|---|---|---|---|
| 1 | Carte ESP32-WROOM-32 (DevKit v1, 30 ou 38 broches) | 2 UART libres, Wi-Fi 2,4 GHz, **Bluetooth classique (SPP)**, **4 Mo de flash au minimum** | 1 | Le firmware utilise le SPP : les ESP32-S3 / C3 / C6 n'ont que le BLE, il faudrait réécrire `links.cpp` avec un service BLE NUS. Les 4 Mo sont imposés par les deux slots de mise à jour OTA (voir `partitions.csv`) ; un module 8 Mo laisse plus de marge. |
| 2 | Module lecteur UHF série, famille M100 / QM100 / R200 (MagicRF) | UART 3,3 V à 115200 bauds, EPC Gen2 / ISO 18000-6C, 860–960 MHz, puissance réglable jusqu'à 26 dBm | 1 | Niveaux logiques 3,3 V directement compatibles ESP32, trame documentée `BB … 7E` déjà implémentée dans `src/uhf_reader.cpp`. |
| 3 | Antenne UHF externe | Bande de la région d'exploitation (865–868 MHz en Europe / zone UE), connecteur conforme au module (SMA ou IPEX/U.FL selon la version) | 1 | La portée vient de l'antenne, pas du module. Ne jamais émettre sans antenne raccordée : l'étage de puissance peut être détruit. |
| 4 | Câble adaptateur IPEX/U.FL → SMA femelle | Si l'antenne est en SMA et le module en U.FL | 1 | Évite de contraindre mécaniquement le connecteur du module. |
| 5 | Alimentation 5 V régulée, ≥ 2 A | 5 V / 2 A minimum, prise secteur ou alimentation USB de qualité | 1 | Le module UHF tire des pointes de courant à chaque salve d'émission : une alimentation faible provoque des redémarrages de l'ESP32. |
| 6 | Régulateur 3,3 V dédié au module UHF (type AMS1117-3.3 sur platine, ou convertisseur abaisseur MP1584 réglé à 3,3 V) | ≥ 1,5 A en continu | 1 | Le régulateur embarqué des DevKit ne tient pas les pointes du module UHF. Voir `CABLAGE.md`, section alimentation. |
| 7 | Condensateur électrolytique 470 µF / 16 V (ou 1000 µF) | Faible ESR | 1 | Réservoir d'énergie au plus près de l'alimentation du module UHF. |
| 8 | Condensateur céramique 100 nF | — | 2 | Découplage haute fréquence (un par rail 3,3 V). |
| 9 | Buzzer | **Actif** 3,3–5 V (module 3 broches) ou **passif** piloté en PWM | 1 | Le firmware gère les deux cas via `BUZZER_IS_PASSIVE` dans `src/config.h`. |
| 10 | Transistor NPN 2N2222 / BC547 + résistance 1 kΩ | Si le buzzer dépasse 20 mA | 1 | Une sortie GPIO ESP32 ne doit pas dépasser ~20 mA en service continu. |
| 11 | LED 5 mm rouge, verte, bleue (ou une LED RGB à cathode commune) | — | 3 (ou 1) | Trois canaux séparés : le firmware mélange les couleurs en PWM. |
| 12 | Résistances de limitation | 220 Ω pour le rouge, 150 Ω pour le vert et le bleu | 3 | Tensions de seuil différentes : sans ajustement, le rouge écrase les deux autres. |
| 13 | Platine d'essai + fils Dupont, ou plaque à bandes | — | 1 lot | Prototype. Pour une station en production, préférer une carte soudée. |
| 14 | Câble USB-A vers micro-USB (ou USB-C selon la carte) | Données, pas seulement charge | 1 | Flashage du firmware **et** liaison UART avec le poste. |
| 15 | Boîtier non métallique (ABS / PLA imprimé) | — | 1 | Un boîtier métallique devant l'antenne détruit la portée. |

## 2. Options utiles

| Composant | Usage |
|---|---|
| Interrupteur d'alimentation sur le rail 5 V | Coupure franche du module UHF sans débrancher l'USB |
| Bouton poussoir supplémentaire sur GPIO 0 | Réinitialisation de la configuration si le bouton BOOT est inaccessible dans le boîtier |
| Dissipateur adhésif sur le module UHF | Lecture continue prolongée (le module chauffe à pleine puissance) |
| Ferrite sur le câble d'antenne | Réduit la remontée HF vers l'électronique numérique |

## 3. Ce que le pont n'embarque pas

- **Pas de batterie** : la station est alimentée en permanence. Un
  fonctionnement sur accumulateur demanderait un circuit de charge et une
  gestion de la coupure d'émission sous tension basse, non traités ici.
- **Pas d'écran** : le retour utilisateur passe par les trois LED et le buzzer.
- **Pas de lecteur de carte agent** : l'identification des agents reste du
  ressort d'ILMS.
- **Pas de portique antivol** : ce pont est un lecteur de table. Le suivi de
  direction d'un portique (`GateDirectionTracker` côté BiblioRFID) suppose
  deux antennes et des entrées GPI, absentes de ce montage.

## 4. Conformité radio

La puissance d'émission et la bande sont réglementées. En zone UE, la bande
865–868 MHz et une PIRE limitée s'appliquent ; d'autres régions utilisent
902–928 MHz. Le firmware démarre à 20 dBm (`DEFAULT_TX_POWER_CDBM` dans
`src/config.h`) et la région doit être réglée conformément au manuel du module
avant toute mise en service. Vérifier la réglementation locale avant
d'augmenter la puissance : ce dépôt ne fournit aucune homologation.

## 5. Point de vigilance avant la première mise sous tension

La table d'opcodes du module (`src/uhf_reader.h`) suit la documentation
publique de la famille M100/R200 mais **n'a pas été confrontée à un module
physique**. Vérifier chaque valeur dans le manuel livré avec le module, puis
corriger uniquement ce bloc : aucun opcode n'est écrit ailleurs dans le
firmware. L'action JSON `moduleInfo` renvoie la réponse brute du module et
permet de confirmer le dialogue dès la première trame.
