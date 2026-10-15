#include "indicators.h"

namespace {
// Echelle de luminosite appliquee a toutes les couleurs.
uint8_t scaled(uint8_t value) {
  return static_cast<uint8_t>((static_cast<uint32_t>(value) * LED_MAX_DUTY) / 255u);
}
}  // namespace

void Indicators::begin() {
  ledcSetup(LEDC_CH_R, LEDC_LED_HZ, LEDC_RESOLUTION_BITS);
  ledcSetup(LEDC_CH_G, LEDC_LED_HZ, LEDC_RESOLUTION_BITS);
  ledcSetup(LEDC_CH_B, LEDC_LED_HZ, LEDC_RESOLUTION_BITS);
  ledcAttachPin(PIN_LED_R, LEDC_CH_R);
  ledcAttachPin(PIN_LED_G, LEDC_CH_G);
  ledcAttachPin(PIN_LED_B, LEDC_CH_B);
  applyColor(0, 0, 0);

  if (BUZZER_IS_PASSIVE) {
    ledcSetup(LEDC_CH_BUZZER, BUZZER_TONE_HZ, LEDC_RESOLUTION_BITS);
    ledcAttachPin(PIN_BUZZER, LEDC_CH_BUZZER);
    ledcWrite(LEDC_CH_BUZZER, 0);
  } else {
    pinMode(PIN_BUZZER, OUTPUT);
    digitalWrite(PIN_BUZZER, BUZZER_ACTIVE_HIGH ? LOW : HIGH);
  }
}

void Indicators::writeChannel(uint8_t channel, uint8_t value) {
  ledcWrite(channel, LED_ACTIVE_HIGH ? value : static_cast<uint8_t>(255u - value));
}

void Indicators::applyColor(uint8_t r, uint8_t g, uint8_t b) {
  writeChannel(LEDC_CH_R, scaled(r));
  writeChannel(LEDC_CH_G, scaled(g));
  writeChannel(LEDC_CH_B, scaled(b));
}

void Indicators::buzzerOn() {
  if (buzzerIsOn_) return;
  buzzerIsOn_ = true;
  if (BUZZER_IS_PASSIVE) {
    ledcWriteTone(LEDC_CH_BUZZER, BUZZER_TONE_HZ);
  } else {
    digitalWrite(PIN_BUZZER, BUZZER_ACTIVE_HIGH ? HIGH : LOW);
  }
}

void Indicators::buzzerOff() {
  if (!buzzerIsOn_) return;
  buzzerIsOn_ = false;
  if (BUZZER_IS_PASSIVE) {
    ledcWriteTone(LEDC_CH_BUZZER, 0);
  } else {
    digitalWrite(PIN_BUZZER, BUZZER_ACTIVE_HIGH ? LOW : HIGH);
  }
}

void Indicators::setState(LedState state) { base_ = state; }

void Indicators::pulse(LedState state, uint32_t durationMs) {
  overlay_ = state;
  overlayUntil_ = millis() + durationMs;
}

void Indicators::beep(uint32_t durationMs) {
  if (durationMs < BEEP_DURATION_MIN_MS) durationMs = BEEP_DURATION_MIN_MS;
  if (durationMs > BEEP_DURATION_MAX_MS) durationMs = BEEP_DURATION_MAX_MS;
  buzzerOn();
  beepUntil_ = millis() + durationMs;
}

void Indicators::beepTwice(uint32_t durationMs) {
  beep(durationMs);
  pendingBeepMs_ = durationMs;
  pendingBeeps_ = 1;
}

void Indicators::renderBase(uint32_t now) {
  switch (base_) {
    case LedState::Boot: {
      // Respiration lente sur 2 s, sans flottant.
      uint32_t phase = now % 2000u;
      uint32_t level = phase < 1000u ? phase : 2000u - phase;  // 0..1000
      applyColor(0, 0, static_cast<uint8_t>((level * 255u) / 1000u));
      break;
    }
    case LedState::LinkWaiting:
      applyColor(0, 0, (now % 400u) < 200u ? 255 : 0);
      break;
    case LedState::LinkReady:
      applyColor(0, 0, 40);
      break;
    case LedState::Scanning:
      applyColor(0, 40, 0);
      break;
    case LedState::Busy:
      applyColor(90, 0, 120);
      break;
    case LedState::Error:
      applyColor((now % 600u) < 300u ? 255 : 30, 0, 0);
      break;
    case LedState::TagAccepted:
      applyColor(0, 255, 0);
      break;
    case LedState::TagIgnored:
      applyColor(0, 0, 255);
      break;
  }
}

void Indicators::loop(uint32_t now) {
  if (beepUntil_ != 0 && static_cast<int32_t>(now - beepUntil_) >= 0) {
    beepUntil_ = 0;
    buzzerOff();
    if (pendingBeeps_ > 0) beepGapUntil_ = now + 60;
  }
  if (pendingBeeps_ > 0 && beepUntil_ == 0 && static_cast<int32_t>(now - beepGapUntil_) >= 0) {
    pendingBeeps_--;
    beep(pendingBeepMs_);
  }

  if (overlayUntil_ != 0) {
    if (static_cast<int32_t>(now - overlayUntil_) >= 0) {
      overlayUntil_ = 0;
    } else {
      LedState saved = base_;
      base_ = overlay_;
      renderBase(now);
      base_ = saved;
      return;
    }
  }
  renderBase(now);
}
