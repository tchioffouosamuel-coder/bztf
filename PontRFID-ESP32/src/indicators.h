// Buzzer et LED RGB : machine a etats non bloquante, aucun delay().
#pragma once

#include <Arduino.h>
#include "config.h"

enum class LedState : uint8_t {
  Boot,         // bleu respirant : demarrage, aucun lien
  LinkWaiting,  // bleu clignotant : lien en cours (WiFi, appairage)
  LinkReady,    // bleu fixe faible : lien ouvert, lecteur au repos
  Scanning,     // vert fixe faible : inventaire en cours
  TagAccepted,  // vert vif bref : nouveau tag retenu
  TagIgnored,   // bleu vif bref : tag deja signale (verrou sonore actif)
  Busy,         // violet : ecriture / desencodage en cours
  Error         // rouge : module muet, commande refusee
};

class Indicators {
 public:
  void begin();
  void loop(uint32_t now);

  // Etat de fond : conserve jusqu'au prochain appel.
  void setState(LedState state);
  LedState state() const { return base_; }

  // Impulsions ponctuelles, superposees a l'etat de fond.
  void pulse(LedState state, uint32_t durationMs);
  void beep(uint32_t durationMs);
  void beepTwice(uint32_t durationMs);

  bool buzzerBusy() const { return beepUntil_ != 0 || pendingBeeps_ > 0; }

 private:
  void applyColor(uint8_t r, uint8_t g, uint8_t b);
  void writeChannel(uint8_t channel, uint8_t value);
  void buzzerOn();
  void buzzerOff();
  void renderBase(uint32_t now);

  LedState base_ = LedState::Boot;
  LedState overlay_ = LedState::Boot;
  uint32_t overlayUntil_ = 0;
  uint32_t beepUntil_ = 0;
  uint32_t beepGapUntil_ = 0;
  uint32_t pendingBeepMs_ = 0;
  uint8_t pendingBeeps_ = 0;
  bool buzzerIsOn_ = false;
};
