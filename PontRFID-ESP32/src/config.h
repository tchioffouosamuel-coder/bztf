// Pont RFID ESP32 : brochage, temporisations et options de compilation.
// Toute valeur modifiee ici doit rester coherente avec CABLAGE.md.
#pragma once

#include <stdint.h>

// ---------------------------------------------------------------- Identite
#define PONT_FIRMWARE_NAME "PontRFID-ESP32"
#define PONT_FIRMWARE_VERSION "1.0.0"
#define PONT_PROTOCOL_VERSION 1
// Prefixe de ligne attendu par ReaderService (BiblioRFID/lib/reader-service.js).
#define PONT_JSON_MARKER "__RFID_JSON__"

// --------------------------------------------------------------- Brochage
// UART2 vers le module UHF. Croise : TX du pont -> RX du module.
static const int PIN_UHF_TX = 17;   // ESP32 TX2 -> module RX
static const int PIN_UHF_RX = 16;   // ESP32 RX2 <- module TX
static const int PIN_UHF_EN = 4;    // Module EN/PWR (actif haut), -1 si non cable
static const uint32_t UHF_BAUD = 115200;

// Buzzer actif (module 3 broches) ou passif pilote en LEDC.
static const int PIN_BUZZER = 25;
static const bool BUZZER_ACTIVE_HIGH = true;
// true : buzzer passif, le firmware genere la frequence. false : buzzer actif.
static const bool BUZZER_IS_PASSIVE = false;
static const uint32_t BUZZER_TONE_HZ = 2700;

// LED RGB discrete (3 LED separees ou une RGB a cathode commune).
static const int PIN_LED_R = 26;
static const int PIN_LED_G = 27;
static const int PIN_LED_B = 14;
// Cathode commune / LED vers GND = true. Anode commune / LED vers 3V3 = false.
static const bool LED_ACTIVE_HIGH = true;
static const uint8_t LED_MAX_DUTY = 160;  // 0-255, limite la luminosite

// Bouton BOOT de la carte : appui long = effacement de la configuration.
static const int PIN_BUTTON = 0;
static const uint32_t BUTTON_HOLD_RESET_MS = 5000;

// ------------------------------------------------------- Canaux LEDC (PWM)
static const uint8_t LEDC_CH_R = 0;
static const uint8_t LEDC_CH_G = 1;
static const uint8_t LEDC_CH_B = 2;
static const uint8_t LEDC_CH_BUZZER = 3;
static const uint32_t LEDC_LED_HZ = 5000;
static const uint8_t LEDC_RESOLUTION_BITS = 8;

// --------------------------------------------------------- Temporisations
// Alignees sur BiblioRFID/PROTOCOL.md et lib/reader-timing.js.
static const uint32_t TAG_EMIT_THROTTLE_MS = 100;    // 1 evenement / tag / 100 ms
static const uint32_t TAG_PRESENCE_TIMEOUT_MS = 700; // tag considere retire
static const uint32_t TAG_VISUAL_RELEASE_MS = 1500;  // anti-rebond visuel
static const uint32_t DEFAULT_BEEP_DURATION_MS = 75;
static const uint32_t DEFAULT_REARM_DELAY_MS = 30000;
static const uint32_t BEEP_DURATION_MIN_MS = 20;
static const uint32_t BEEP_DURATION_MAX_MS = 1000;
static const uint32_t REARM_DELAY_MIN_MS = 1000;
static const uint32_t REARM_DELAY_MAX_MS = 3600000;

// Puissance d'emission par defaut, en dBm x 100 (2000 = 20 dBm).
static const uint16_t DEFAULT_TX_POWER_CDBM = 2000;
static const uint16_t TX_POWER_MIN_CDBM = 500;
static const uint16_t TX_POWER_MAX_CDBM = 2600;

// ------------------------------------------------------------- Liens
static const uint16_t WIFI_TCP_PORT = 6180;  // meme port que les lecteurs N01 TCP
static const uint32_t WIFI_RETRY_MS = 15000;
static const uint8_t LINK_MAX_CLIENTS = 2;
static const size_t LINK_LINE_MAX = 1024;    // garde-fou anti-saturation memoire

// Nom Bluetooth / mDNS : le suffixe est derive de l'adresse MAC.
#define PONT_DEVICE_PREFIX "PontRFID"

// --------------------------------------------------------- Mises a jour OTA
// Version de CE binaire : PONT_FIRMWARE_VERSION, plus haut dans ce fichier.
// A incrementer avant chaque build destine a l'OTA, et a publier a l'identique
// dans le manifest : le pont flashe des que la version annoncee par le serveur
// differe de celle-ci (publier une version plus ancienne fait donc un retour
// en arriere volontaire).
//
// L'URL du manifest, le jeton eventuel et l'autorite de certification sont de
// la configuration locale (action JSON `config`), jamais du code : rien de
// tout cela n'a sa place dans ce depot.
//
// Cadence de verification, en plus d'une verification des la premiere
// association Wi-Fi. Il n'y a pas de canal push : c'est le delai maximal entre
// la publication d'une version et sa prise en compte.
static const uint32_t OTA_CHECK_INTERVAL_MS = 15UL * 60UL * 1000UL;
static const uint32_t OTA_CONNECT_TIMEOUT_MS = 6000;
// Timeout d'INACTIVITE du telechargement (le chrono repart a chaque paquet
// recu), pas un plafond global : un lien lent mais vivant va au bout.
static const uint32_t OTA_STALL_TIMEOUT_MS = 15000;

// Capacite du suivi de tags simultanes.
static const size_t TAG_TABLE_SIZE = 64;
