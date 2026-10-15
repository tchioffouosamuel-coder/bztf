// Suivi local des tags : deduplication, limitation de debit, verrou sonore.
// Les regles reprennent BiblioRFID/PROTOCOL.md et lib/reader-timing.js, de
// facon que le pont ESP32 se comporte comme le pont C# existant.
#pragma once

#include <Arduino.h>

#include "config.h"

struct TagDecision {
  bool emit = false;        // publier un evenement "tag" sur les liens
  bool notify = false;      // declencher buzzer + LED verte
  bool firstSight = false;  // tag absent de la table avant cet appel
};

struct TagTiming {
  uint32_t beepDurationMs = DEFAULT_BEEP_DURATION_MS;
  uint32_t rearmDelayMs = DEFAULT_REARM_DELAY_MS;
};

class TagTracker {
 public:
  // `key` identifie le tag : TID s'il est connu, sinon EPC.
  TagDecision observe(const String& key, uint32_t now);

  // Retire les tags silencieux depuis TAG_PRESENCE_TIMEOUT_MS et renvoie le
  // nombre de tags encore presents.
  size_t sweep(uint32_t now);

  size_t presentCount() const;
  void clear();

  void setTiming(const TagTiming& timing) { timing_ = timing; }
  const TagTiming& timing() const { return timing_; }

 private:
  struct Entry {
    bool used = false;
    char key[49] = {0};
    uint32_t firstSeen = 0;
    uint32_t lastSeen = 0;
    uint32_t lastEmit = 0;
    bool beepLocked = false;
    bool present = false;
  };

  Entry* find(const String& key);
  Entry* allocate(const String& key, uint32_t now);

  Entry table_[TAG_TABLE_SIZE];
  TagTiming timing_;
};
