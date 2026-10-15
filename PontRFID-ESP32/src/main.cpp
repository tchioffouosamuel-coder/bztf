// Pont RFID ESP32 pour BiblioRFID / ILMS.
//
// Le pont parle le meme dialecte que ReaderBridge.exe : une ligne de texte par
// message, prefixee par PONT_JSON_MARKER, et le meme vocabulaire d'actions
// (connect, disconnect, status, beep, write, shutdown). Un consommateur Node
// peut donc reutiliser tel quel le decodage de BiblioRFID/lib/reader-service.js.
//
//   requete   {"id":1,"action":"connect","connectionType":"tcp","endpoint":""}
//   reponse   __RFID_JSON__{"type":"response","id":1,"ok":true,...}
//   evenement __RFID_JSON__{"type":"tag","tag":{"epc":"...","tid":"...",...}}
//
// Extensions propres au pont, ignorees par un client qui ne les connait pas :
// actions led / readTid / scan / config / moduleInfo / ping, evenements
// tagReleased, diagnostic, state.

#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <functional>
#include <time.h>

#include "config.h"
#include "indicators.h"
#include "links.h"
#include "ota.h"
#include "tag_tracker.h"
#include "uhf_reader.h"

#ifndef PONT_LINK_UART
#define PONT_LINK_UART 1
#endif

namespace {

Indicators indicators;
TagTracker tracker;
uhf::Reader reader(Serial2);
Preferences prefs;

UartLink uartLink;
#if PONT_LINK_WIFI
WifiLink wifiLink;
#endif
#if PONT_LINK_BT
BluetoothLink btLink;
#endif

Link* links[3] = {nullptr, nullptr, nullptr};
uint8_t linkCount = 0;
bool linkWasConnected[3] = {false, false, false};

String deviceName;
bool readerOpen = false;
String connectionType = "";
String connectionEndpoint = "";
uint32_t lastSweep = 0;
uint32_t lastStateEvent = 0;
uint32_t buttonDownSince = 0;
uint32_t tagsEmitted = 0;
#if PONT_LINK_WIFI
uint32_t lastOtaCheck = 0;
bool otaCheckedOnce = false;
#endif

// ----------------------------------------------------------------- Sortie

void emit(const JsonDocument& doc, Link* only = nullptr) {
  String line = PONT_JSON_MARKER;
  serializeJson(doc, line);
  if (only != nullptr) {
    only->send(line);
    return;
  }
  for (uint8_t i = 0; i < linkCount; i++) {
    if (links[i]->connected()) links[i]->send(line);
  }
}

void diagnostic(const String& message) {
  JsonDocument doc;
  doc["type"] = "diagnostic";
  doc["message"] = message;
  doc["uptimeMs"] = millis();
  emit(doc);
}

// Horodatage ISO 8601 quand l'heure reseau est connue, chaine vide sinon.
String isoNow() {
  time_t now = time(nullptr);
  if (now < 1600000000) return String("");
  struct tm utc;
  gmtime_r(&now, &utc);
  char buffer[32];
  strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
  return String(buffer);
}

void fillStatus(JsonObject target) {
  target["device"] = deviceName;
  target["firmware"] = PONT_FIRMWARE_NAME;
  target["version"] = PONT_FIRMWARE_VERSION;
  target["protocol"] = PONT_PROTOCOL_VERSION;
  target["connected"] = readerOpen;
  target["inventory"] = reader.inventoryRunning();
  target["connectionType"] = connectionType;
  target["endpoint"] = connectionEndpoint;
  target["tagsPresent"] = tracker.presentCount();
  target["tagsEmitted"] = tagsEmitted;
  target["beepDurationMs"] = tracker.timing().beepDurationMs;
  target["rearmDelayMs"] = tracker.timing().rearmDelayMs;
  target["framesIn"] = reader.framesIn();
  target["framesInvalid"] = reader.errorsIn();
  target["uptimeMs"] = millis();
  target["freeHeap"] = ESP.getFreeHeap();

  JsonObject transports = target["transports"].to<JsonObject>();
  transports["uart"] = true;
#if PONT_LINK_WIFI
  JsonObject wifi = transports["wifi"].to<JsonObject>();
  wifi["associated"] = wifiLink.active();
  wifi["clients"] = wifiLink.connected();
  wifi["ip"] = wifiLink.ipAddress();
  wifi["port"] = WIFI_TCP_PORT;
#else
  transports["wifi"] = false;
#endif
#if PONT_LINK_BT
  JsonObject bt = transports["bluetooth"].to<JsonObject>();
  bt["name"] = deviceName;
  bt["client"] = btLink.connected();
#else
  transports["bluetooth"] = false;
#endif

  JsonObject update = target["ota"].to<JsonObject>();
#if PONT_LINK_WIFI
  update["supported"] = true;
  update["configured"] = ota::configured();
  update["manifestUrl"] = ota::baseUrl();
  update["lastResult"] = ota::resultText(ota::lastResult());
  update["lastCheckUptimeMs"] = ota::lastCheckUptimeMs();
  update["setAsideVersion"] = ota::setAsideVersion();
  update["checkIntervalMs"] = OTA_CHECK_INTERVAL_MS;
#else
  // Sans Wi-Fi, la mise a jour passe par USB.
  update["supported"] = false;
#endif
}

void sendReady(Link* target) {
  JsonDocument doc;
  doc["type"] = "ready";
  doc["link"] = target->name();
  fillStatus(doc.to<JsonObject>());
  emit(doc, target);
}

void respond(Link* origin, long id, bool ok, const String& error,
             const std::function<void(JsonObject)>& fill = nullptr) {
  JsonDocument doc;
  doc["type"] = "response";
  doc["id"] = id;
  doc["ok"] = ok;
  if (!ok) doc["error"] = error.length() > 0 ? error : String("Commande refusee.");
  if (fill) fill(doc.to<JsonObject>());
  emit(doc, origin);
}

void emitState(const char* reason) {
  JsonDocument doc;
  doc["type"] = "state";
  doc["reason"] = reason;
  fillStatus(doc.to<JsonObject>());
  emit(doc);
}

// --------------------------------------------------------- Etat lumineux

bool anyLinkConnected() {
  for (uint8_t i = 0; i < linkCount; i++) {
    if (links[i]->kind() != LinkKind::Uart && links[i]->connected()) return true;
  }
  return false;
}

void refreshIdleState() {
  if (indicators.state() == LedState::Error) return;
  if (readerOpen && reader.inventoryRunning()) {
    indicators.setState(LedState::Scanning);
    return;
  }
#if PONT_LINK_WIFI
  if (wifiLink.associating()) {
    indicators.setState(LedState::LinkWaiting);
    return;
  }
#endif
  indicators.setState(anyLinkConnected() ? LedState::LinkReady : LedState::Boot);
}

void raiseError(const String& message) {
  indicators.setState(LedState::Error);
  indicators.beepTwice(tracker.timing().beepDurationMs);
  diagnostic(message);
}

void clearError() {
  if (indicators.state() == LedState::Error) refreshIdleState();
}

// ------------------------------------------------------------ Lecteur UHF

bool openReader(String& error) {
  if (readerOpen) return true;
  if (!reader.begin(error)) return false;
  tracker.clear();
  if (!reader.startInventory(error)) {
    reader.end();
    return false;
  }
  readerOpen = true;
  clearError();
  refreshIdleState();
  return true;
}

void closeReader() {
  if (!readerOpen) return;
  reader.end();
  readerOpen = false;
  connectionType = "";
  connectionEndpoint = "";
  tracker.clear();
  refreshIdleState();
}

void publishTag(const uhf::TagRead& tag, const String& key) {
  JsonDocument doc;
  doc["type"] = "tag";
  JsonObject payload = doc["tag"].to<JsonObject>();
  payload["epc"] = tag.epc;
  payload["tid"] = tag.tid;
  payload["rssi"] = tag.rssi;
  payload["antenna"] = tag.antenna;
  payload["key"] = key;
  String stamp = isoNow();
  if (stamp.length() > 0) doc["receivedAt"] = stamp;
  doc["uptimeMs"] = millis();
  emit(doc);
  tagsEmitted++;
}

void pumpReader(uint32_t now) {
  if (!readerOpen) return;
  uhf::TagRead tag;
  uint8_t budget = 16;  // on ne monopolise pas la boucle si le champ est dense
  while (budget-- > 0 && reader.poll(tag)) {
    String key = tag.tid[0] != '\0' ? String(tag.tid) : String(tag.epc);
    TagDecision decision = tracker.observe(key, now);
    if (decision.emit) publishTag(tag, key);
    if (decision.notify) {
      indicators.pulse(LedState::TagAccepted, 180);
      indicators.beep(tracker.timing().beepDurationMs);
    } else if (decision.firstSight) {
      indicators.pulse(LedState::TagIgnored, 120);
    }
  }
}

// --------------------------------------------------------- Configuration

void loadConfig() {
  prefs.begin("pontrfid", true);
  uint32_t beep = prefs.getUInt("beepMs", DEFAULT_BEEP_DURATION_MS);
  uint32_t rearm = prefs.getUInt("rearmMs", DEFAULT_REARM_DELAY_MS);
  String ssid = prefs.getString("ssid", "");
  String password = prefs.getString("pass", "");
  prefs.end();

  TagTiming timing;
  timing.beepDurationMs = constrain(beep, BEEP_DURATION_MIN_MS, BEEP_DURATION_MAX_MS);
  timing.rearmDelayMs = constrain(rearm, REARM_DELAY_MIN_MS, REARM_DELAY_MAX_MS);
  tracker.setTiming(timing);

#if PONT_LINK_WIFI
  if (ssid.length() > 0) wifiLink.configure(ssid, password);
#else
  (void)ssid;
  (void)password;
#endif
}

void forgetConfig() {
  prefs.begin("pontrfid", false);
  prefs.clear();
  prefs.end();
}

// ----------------------------------------------------------- Mises a jour

#if PONT_LINK_WIFI
// Pas de mise a jour tant que le lecteur est ouvert ou qu'un tag est dans le
// champ : le telechargement monopolise la boucle plusieurs secondes et se
// termine par un redemarrage, ce qui couperait une operation de circulation.
// Le poste doit donc avoir rendu le lecteur (`disconnect`) pour qu'une version
// publiee soit prise. C'est volontaire : la station se met a jour entre deux
// seances, pas pendant.
bool otaSafeToRun() {
  return !readerOpen && tracker.presentCount() == 0 && !indicators.buzzerBusy();
}

// La poignee de main TLS de mbedTLS demande plus que les 8 Ko de pile de
// loop() (le define CONFIG_ARDUINO_LOOP_STACK_SIZE est redefini par le
// sdkconfig du coeur, donc inoperant depuis platformio.ini). La verification
// s'execute donc dans une tache dediee de 16 Ko.
volatile bool otaTaskDone = false;
ota::Result otaTaskResult = ota::Result::Disabled;

void otaTask(void*) {
  otaTaskResult = ota::check();
  otaTaskDone = true;
  vTaskDelete(nullptr);
}

void runOtaCheck(const char* reason) {
  LedState previous = indicators.state();
  indicators.setState(LedState::Busy);
  indicators.loop(millis());

  otaTaskDone = false;
  otaTaskResult = ota::Result::NetworkError;
  TaskHandle_t handle = nullptr;
  if (xTaskCreate(otaTask, "ota", 16384, nullptr, 1, &handle) != pdPASS) {
    indicators.setState(previous);
    diagnostic("OTA : creation de la tache impossible (memoire).");
    return;
  }
  // Pendant ce temps la boucle principale n'ecrit ni sur les liens ni sur les
  // indicateurs : la tache OTA est seule a les utiliser. Le lecteur est ferme
  // (voir otaSafeToRun), il n'y a donc aucune lecture a manquer.
  while (!otaTaskDone) vTaskDelay(pdMS_TO_TICKS(50));
  ota::Result result = otaTaskResult;

  indicators.setState(previous);
  refreshIdleState();

  JsonDocument doc;
  doc["type"] = "ota";
  doc["phase"] = "checked";
  doc["reason"] = reason;
  doc["result"] = ota::resultText(result);
  doc["version"] = PONT_FIRMWARE_VERSION;
  doc["uptimeMs"] = millis();
  emit(doc);

  if (result == ota::Result::Corrupt) raiseError("Image de mise a jour refusee.");
}
#endif

// ------------------------------------------------------------- Commandes

void handleCommand(Link* origin, const String& line) {
  JsonDocument request;
  DeserializationError parsed = deserializeJson(request, line);
  if (parsed) {
    respond(origin, 0, false, String("JSON invalide : ") + parsed.c_str());
    return;
  }
  long id = request["id"] | 0L;
  String action = request["action"] | "";
  action.toLowerCase();
  String error;

  if (action == "connect") {
    connectionType = request["connectionType"] | "uhf";
    connectionEndpoint = request["endpoint"] | "";
    if (!openReader(error)) {
      connectionType = "";
      connectionEndpoint = "";
      raiseError(error);
      respond(origin, id, false, error);
      return;
    }
    respond(origin, id, true, "", [](JsonObject target) { fillStatus(target); });
    emitState("connect");
    return;
  }

  if (action == "disconnect") {
    closeReader();
    respond(origin, id, true, "", [](JsonObject target) { fillStatus(target); });
    emitState("disconnect");
    return;
  }

  if (action == "status" || action == "ping") {
    respond(origin, id, true, "", [](JsonObject target) { fillStatus(target); });
    return;
  }

  if (action == "beep") {
    uint32_t duration = request["durationMs"] | tracker.timing().beepDurationMs;
    duration = constrain(duration, BEEP_DURATION_MIN_MS, BEEP_DURATION_MAX_MS);
    indicators.beep(duration);
    respond(origin, id, true, "", [duration](JsonObject target) {
      target["beeped"] = true;
      target["durationMs"] = duration;
    });
    return;
  }

  if (action == "led") {
    String state = request["state"] | "";
    state.toLowerCase();
    uint32_t duration = request["durationMs"] | 400;
    LedState wanted;
    if (state == "accepted" || state == "green") wanted = LedState::TagAccepted;
    else if (state == "ignored" || state == "blue") wanted = LedState::TagIgnored;
    else if (state == "busy" || state == "violet") wanted = LedState::Busy;
    else if (state == "error" || state == "red") wanted = LedState::Error;
    else if (state == "idle" || state == "off") wanted = LedState::LinkReady;
    else {
      respond(origin, id, false, "Etat de LED inconnu.");
      return;
    }
    if (state == "error") indicators.setState(LedState::Error);
    else if (state == "idle" || state == "off") { clearError(); refreshIdleState(); }
    else indicators.pulse(wanted, duration);
    respond(origin, id, true, "", [](JsonObject target) { target["led"] = true; });
    return;
  }

  if (action == "write") {
    if (!readerOpen) {
      respond(origin, id, false, "Le lecteur n'est pas connecte.");
      return;
    }
    String epc = request["epc"] | "";
    String tid = request["tid"] | "";
    epc.trim();
    tid.trim();
    epc.toUpperCase();
    tid.toUpperCase();
    if (epc.length() == 0 || tid.length() == 0) {
      respond(origin, id, false, "EPC et TID sont requis.");
      return;
    }
    indicators.setState(LedState::Busy);
    bool ok = reader.writeEpc(tid, epc, error);
    refreshIdleState();
    if (!ok) {
      raiseError(error);
      respond(origin, id, false, error);
      return;
    }
    indicators.beep(tracker.timing().beepDurationMs);
    respond(origin, id, true, "", [epc, tid](JsonObject target) {
      JsonObject tag = target["tag"].to<JsonObject>();
      tag["epc"] = epc;
      tag["tid"] = tid;
      target["verified"] = true;
    });
    return;
  }

  if (action == "readtid") {
    if (!readerOpen) {
      respond(origin, id, false, "Le lecteur n'est pas connecte.");
      return;
    }
    String tid;
    if (!reader.readTid(tid, error)) {
      respond(origin, id, false, error);
      return;
    }
    respond(origin, id, true, "", [tid](JsonObject target) { target["tid"] = tid; });
    return;
  }

  if (action == "moduleinfo") {
    if (!readerOpen) {
      respond(origin, id, false, "Le lecteur n'est pas connecte.");
      return;
    }
    String hardware;
    String software;
    reader.moduleInfo(0x00, hardware, error);
    reader.moduleInfo(0x01, software, error);
    respond(origin, id, true, "", [hardware, software](JsonObject target) {
      target["hardware"] = hardware;
      target["software"] = software;
    });
    return;
  }

  if (action == "config") {
    prefs.begin("pontrfid", false);
    if (request["beepDurationMs"].is<uint32_t>()) {
      uint32_t value = request["beepDurationMs"];
      if (value < BEEP_DURATION_MIN_MS || value > BEEP_DURATION_MAX_MS) {
        prefs.end();
        respond(origin, id, false, "La duree du bip doit etre comprise entre 20 et 1000 ms.");
        return;
      }
      prefs.putUInt("beepMs", value);
    }
    if (request["rearmDelayMs"].is<uint32_t>()) {
      uint32_t value = request["rearmDelayMs"];
      if (value < REARM_DELAY_MIN_MS || value > REARM_DELAY_MAX_MS) {
        prefs.end();
        respond(origin, id, false, "Le delai de rearmement doit etre comprise entre 1 et 3600 s.");
        return;
      }
      prefs.putUInt("rearmMs", value);
    }
    bool wifiChanged = false;
    if (request["ssid"].is<const char*>()) {
      prefs.putString("ssid", String(request["ssid"] | ""));
      prefs.putString("pass", String(request["password"] | ""));
      wifiChanged = true;
    }
#if PONT_LINK_WIFI
    if (request["otaManifestUrl"].is<const char*>()) {
      String url = request["otaManifestUrl"] | "";
      if (url.length() > 0 && !url.startsWith("http://") && !url.startsWith("https://")) {
        prefs.end();
        respond(origin, id, false, "URL de manifest invalide : http:// ou https:// attendu.");
        return;
      }
      // Les secrets de mise a jour vivent dans leur propre espace NVS et ne
      // sont jamais relus ni renvoyes par le pont.
      ota::configure(url, String(request["otaToken"] | ""),
                     request["otaInsecure"] | false,
                     String(request["otaCaPem"] | ""));
    }
#endif
    if (request["txPowerCdBm"].is<uint16_t>()) {
      uint16_t value = request["txPowerCdBm"];
      if (readerOpen && !reader.setTxPower(value, error)) {
        prefs.end();
        respond(origin, id, false, error);
        return;
      }
      prefs.putUShort("txPower", value);
    }
    prefs.end();
    loadConfig();
#if PONT_LINK_WIFI
    if (wifiChanged) refreshIdleState();
#else
    (void)wifiChanged;
#endif
    respond(origin, id, true, "", [](JsonObject target) { fillStatus(target); });
    return;
  }

  if (action == "update") {
#if PONT_LINK_WIFI
    if (!ota::configured()) {
      respond(origin, id, false, "Aucune source de mise a jour configuree.");
      return;
    }
    if (!wifiLink.active()) {
      respond(origin, id, false, "Wi-Fi non associe : mise a jour impossible.");
      return;
    }
    if (!otaSafeToRun()) {
      respond(origin, id, false,
              "Lecteur ouvert ou tag present : fermer la session avant une mise a jour.");
      return;
    }
    if (request["forget"] | false) ota::clearSetAsideVersion();
    // La reponse part avant le telechargement : en cas de succes la carte
    // redemarre et ne repondrait plus.
    respond(origin, id, true, "", [](JsonObject target) {
      target["started"] = true;
      target["manifestUrl"] = ota::baseUrl();
    });
    lastOtaCheck = millis();
    otaCheckedOnce = true;
    runOtaCheck("manuel");
#else
    respond(origin, id, false, "Firmware compile sans Wi-Fi : mise a jour par USB.");
#endif
    return;
  }

  if (action == "shutdown") {
    closeReader();
    respond(origin, id, true, "", [](JsonObject target) {
      target["shutdown"] = true;
      target["reboot"] = false;
    });
    return;
  }

  if (action == "reboot") {
    respond(origin, id, true, "", [](JsonObject target) { target["reboot"] = true; });
    delay(50);  // laisse partir la reponse avant la coupure
    ESP.restart();
    return;
  }

  respond(origin, id, false, String("Action inconnue : ") + action);
}

// ------------------------------------------------------------------ Bouton

void pumpButton(uint32_t now) {
  if (PIN_BUTTON < 0) return;
  bool pressed = digitalRead(PIN_BUTTON) == LOW;
  if (!pressed) {
    buttonDownSince = 0;
    return;
  }
  if (buttonDownSince == 0) {
    buttonDownSince = now;
    return;
  }
  if (now - buttonDownSince < BUTTON_HOLD_RESET_MS) return;
  buttonDownSince = 0;
  forgetConfig();
  diagnostic("Configuration effacee, redemarrage.");
  indicators.beepTwice(120);
  indicators.setState(LedState::Error);
  delay(400);
  ESP.restart();
}

}  // namespace

void setup() {
  uint64_t chip = ESP.getEfuseMac();
  char suffix[5];
  snprintf(suffix, sizeof(suffix), "%02X%02X",
           static_cast<uint8_t>((chip >> 32) & 0xFF), static_cast<uint8_t>((chip >> 40) & 0xFF));
  deviceName = String(PONT_DEVICE_PREFIX) + "-" + suffix;

  indicators.begin();
  indicators.setState(LedState::Boot);
  if (PIN_BUTTON >= 0) pinMode(PIN_BUTTON, INPUT_PULLUP);

  loadConfig();

#if PONT_LINK_UART
  links[linkCount++] = &uartLink;
#endif
#if PONT_LINK_WIFI
  links[linkCount++] = &wifiLink;
#endif
#if PONT_LINK_BT
  btLink.setDeviceName(deviceName);
  links[linkCount++] = &btLink;
#endif
  for (uint8_t i = 0; i < linkCount; i++) links[i]->begin();

#if PONT_LINK_WIFI
  // L'heure n'est utile qu'a l'horodatage des evenements ; son absence
  // n'empeche aucune lecture.
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");

  ota::Hooks hooks;
  hooks.log = [](const String& message) { diagnostic(message); };
  hooks.progress = [](uint8_t percent) {
    JsonDocument doc;
    doc["type"] = "ota";
    doc["phase"] = "download";
    doc["percent"] = percent;
    emit(doc);
    indicators.loop(millis());  // la boucle principale est suspendue ici
  };
  hooks.beforeRestart = []() {
    JsonDocument doc;
    doc["type"] = "ota";
    doc["phase"] = "restart";
    doc["uptimeMs"] = millis();
    emit(doc);
    indicators.beepTwice(120);
    uint32_t until = millis() + 400;
    while (static_cast<int32_t>(millis() - until) < 0) indicators.loop(millis());
  };
  ota::begin(hooks);
#endif

  sendReady(&uartLink);
  refreshIdleState();
}

void loop() {
  uint32_t now = millis();

  for (uint8_t i = 0; i < linkCount; i++) {
    links[i]->loop(now);
    bool isConnected = links[i]->connected();
    if (isConnected && !linkWasConnected[i] && links[i]->kind() != LinkKind::Uart) {
      sendReady(links[i]);  // un nouveau client doit voir l'etat courant
      refreshIdleState();
    }
    linkWasConnected[i] = isConnected;

    String line;
    uint8_t budget = 4;  // plusieurs commandes par tour, sans famine du lecteur
    while (budget-- > 0 && links[i]->readLine(line)) handleCommand(links[i], line);
  }

  pumpReader(now);

  if (now - lastSweep >= 50) {
    lastSweep = now;
    size_t before = tracker.presentCount();
    size_t after = tracker.sweep(now);
    if (before > 0 && after == 0) {
      JsonDocument doc;
      doc["type"] = "tagReleased";
      doc["uptimeMs"] = now;
      emit(doc);
    }
  }

#if PONT_LINK_WIFI
  // Une verification des la premiere association, puis au rythme de
  // OTA_CHECK_INTERVAL_MS, et seulement lecteur ferme.
  if (ota::configured() && wifiLink.active() && otaSafeToRun() &&
      (!otaCheckedOnce || now - lastOtaCheck >= OTA_CHECK_INTERVAL_MS)) {
    const char* reason = otaCheckedOnce ? "periodique" : "demarrage";
    otaCheckedOnce = true;
    lastOtaCheck = now;
    runOtaCheck(reason);
  }
#endif

  if (now - lastStateEvent >= 5000) {
    lastStateEvent = now;
    refreshIdleState();
    if (anyLinkConnected()) emitState("heartbeat");
  }

  pumpButton(now);
  indicators.loop(now);
}
