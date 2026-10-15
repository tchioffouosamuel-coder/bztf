#include "ota.h"

#if PONT_LINK_WIFI

#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <Update.h>
#include <WiFiClient.h>
#include <WiFiClientSecure.h>
#include <esp_ota_ops.h>
#include <mbedtls/md.h>

#include <algorithm>

namespace ota {

namespace {

Hooks hooks;
bool appValidated = false;
Result last = Result::Disabled;
uint32_t lastCheck = 0;

String otaBaseUrl;
String otaToken;
String otaCaPem;
bool otaInsecure = false;

WiFiClient plainClient;
WiFiClientSecure secureClient;

void say(const String& message) {
  if (hooks.log) hooks.log(message);
}

void loadFromPrefs() {
  Preferences prefs;
  prefs.begin("pontota", true);
  otaBaseUrl = prefs.getString("url", "");
  otaToken = prefs.getString("token", "");
  otaCaPem = prefs.getString("ca", "");
  otaInsecure = prefs.getBool("insecure", false);
  prefs.end();
}

String setAside() {
  Preferences prefs;
  prefs.begin("pontota", true);
  String value = prefs.getString("bad", "");
  prefs.end();
  return value;
}

void setAside(const String& version) {
  Preferences prefs;
  prefs.begin("pontota", false);
  if (version.length() == 0) prefs.remove("bad");
  else prefs.putString("bad", version);
  prefs.end();
}

bool urlIsHttps(const String& url) { return url.startsWith("https://"); }

// Renvoie le client reseau adapte au schema de l'URL, ou nullptr si l'URL
// demande du TLS sans que la confiance ait ete etablie.
WiFiClient* clientFor(const String& url, String& error) {
  if (!urlIsHttps(url)) {
    if (!url.startsWith("http://")) {
      error = "URL de mise a jour invalide : http:// ou https:// attendu.";
      return nullptr;
    }
    // En clair : seule la signature SHA256 du manifest protege encore
    // l'integrite de l'image. Reserve a un reseau de desserte maitrise.
    return &plainClient;
  }
  if (otaCaPem.length() > 0) {
    secureClient.setCACert(otaCaPem.c_str());
  } else if (otaInsecure) {
    // Choix explicite de l'exploitant : le certificat du serveur n'est pas
    // verifie. Un intercepteur peut alors servir son propre manifest, donc sa
    // propre image : le SHA256 ne protege que contre la corruption, pas contre
    // une substitution complete.
    secureClient.setInsecure();
  } else {
    error = "HTTPS sans autorite de certification : fournir otaCaPem, ou "
            "accepter explicitement otaInsecure.";
    return nullptr;
  }
  secureClient.setTimeout(OTA_STALL_TIMEOUT_MS / 1000);
  return &secureClient;
}

void addHeaders(HTTPClient& http) {
  http.addHeader("X-Firmware-Version", PONT_FIRMWARE_VERSION);
  http.addHeader("X-Firmware-Name", PONT_FIRMWARE_NAME);
  if (otaToken.length() > 0) http.addHeader("Authorization", String("Bearer ") + otaToken);
}

bool sha256Matches(const uint8_t digest[32], const String& expectedHex) {
  if (expectedHex.length() != 64) return false;
  char computed[65];
  for (int i = 0; i < 32; i++) sprintf(computed + i * 2, "%02x", digest[i]);
  computed[64] = '\0';
  return expectedHex.equalsIgnoreCase(String(computed));
}

// Resout une URL de binaire eventuellement relative au manifest.
String resolveUrl(const String& candidate) {
  if (candidate.startsWith("http://") || candidate.startsWith("https://")) return candidate;
  String base = otaBaseUrl;
  int slash = base.lastIndexOf('/');
  if (slash > static_cast<int>(base.indexOf("://")) + 2) base.remove(slash + 1);
  else base += "/";
  String relative = candidate;
  while (relative.startsWith("/")) relative.remove(0, 1);
  return base + relative;
}

bool fetchManifest(Manifest& out, String& error) {
  WiFiClient* client = clientFor(otaBaseUrl, error);
  if (client == nullptr) return false;

  HTTPClient http;
  http.setConnectTimeout(OTA_CONNECT_TIMEOUT_MS);
  http.setTimeout(10000);
  if (!http.begin(*client, otaBaseUrl)) {
    error = "URL de manifest refusee.";
    return false;
  }
  http.setReuse(false);
  http.addHeader("Accept", "application/json");
  addHeaders(http);

  int code = http.GET();
  if (code == 200 || code == 204) markAppValidOnce();
  if (code == 204) {
    http.end();
    error = "";
    return false;  // aucune version publiee : ce n'est pas une anomalie
  }
  if (code != 200) {
    error = String("manifest HTTP ") + code;
    http.end();
    return false;
  }

  JsonDocument doc;
  DeserializationError parsed = deserializeJson(doc, http.getString());
  http.end();
  if (parsed) {
    error = String("manifest JSON invalide : ") + parsed.c_str();
    return false;
  }

  out.version = doc["version"] | "";
  out.url = resolveUrl(String(doc["url"] | ""));
  out.sha256 = doc["sha256"] | "";
  out.sizeBytes = doc["size_bytes"] | static_cast<size_t>(0);
  if (out.version.length() == 0 || out.url.length() == 0 ||
      out.sha256.length() != 64 || out.sizeBytes == 0) {
    error = "manifest incomplet (version, url, sha256, size_bytes attendus).";
    return false;
  }
  return true;
}

Result downloadAndFlash(const Manifest& manifest, String& error) {
  WiFiClient* client = clientFor(manifest.url, error);
  if (client == nullptr) return Result::Corrupt;

  HTTPClient http;
  http.setConnectTimeout(OTA_CONNECT_TIMEOUT_MS);
  http.setTimeout(OTA_STALL_TIMEOUT_MS);
  if (!http.begin(*client, manifest.url)) {
    error = "URL de binaire refusee.";
    return Result::Corrupt;
  }
  http.setReuse(false);
  addHeaders(http);

  int code = http.GET();
  if (code != 200) {
    error = String("telechargement HTTP ") + code;
    http.end();
    return Result::NetworkError;
  }

  if (!Update.begin(manifest.sizeBytes, U_FLASH)) {
    error = String("Update.begin() refuse : ") + Update.errorString();
    http.end();
    // Image trop grande pour le slot : la retenter ne changera rien.
    return Result::Corrupt;
  }

  mbedtls_md_context_t ctx;
  mbedtls_md_init(&ctx);
  mbedtls_md_setup(&ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), 0);
  mbedtls_md_starts(&ctx);

  WiFiClient* stream = http.getStreamPtr();
  static uint8_t buffer[1460];  // hors pile : la poignee de main TLS la charge deja
  size_t written = 0;
  size_t nextReport = manifest.sizeBytes / 10;
  bool failed = false;
  stream->setTimeout(1);
  uint32_t lastData = millis();

  while (written < manifest.sizeBytes) {
    size_t wanted = std::min(manifest.sizeBytes - written, sizeof(buffer));
    size_t n = stream->readBytes(buffer, wanted);
    if (n == 0) {
      // Timeout d'INACTIVITE, pas un plafond global : un lien lent mais vivant
      // va au bout du telechargement.
      if (!http.connected() || millis() - lastData > OTA_STALL_TIMEOUT_MS) {
        error = String("flux interrompu (") + written + "/" + manifest.sizeBytes + " octets)";
        failed = true;
        break;
      }
      continue;
    }
    lastData = millis();
    if (Update.write(buffer, n) != n) {
      error = String("Update.write() : ") + Update.errorString();
      failed = true;
      break;
    }
    mbedtls_md_update(&ctx, buffer, n);
    written += n;
    if (written >= nextReport) {
      if (hooks.progress) {
        hooks.progress(static_cast<uint8_t>((100ULL * written) / manifest.sizeBytes));
      }
      nextReport += manifest.sizeBytes / 10;
    }
  }
  http.end();

  uint8_t digest[32];
  mbedtls_md_finish(&ctx, digest);
  mbedtls_md_free(&ctx);

  if (failed) {
    Update.abort();
    return Result::NetworkError;
  }
  if (!sha256Matches(digest, manifest.sha256)) {
    error = "SHA256 incorrect, mise a jour annulee.";
    Update.abort();
    return Result::Corrupt;
  }
  if (!Update.end(true)) {
    error = String("Update.end() : ") + Update.errorString();
    return Result::Corrupt;
  }
  return Result::Success;
}

}  // namespace

const char* resultText(Result result) {
  switch (result) {
    case Result::Disabled: return "disabled";
    case Result::UpToDate: return "upToDate";
    case Result::NoRelease: return "noRelease";
    case Result::NetworkError: return "networkError";
    case Result::Corrupt: return "corrupt";
    case Result::Success: return "success";
  }
  return "unknown";
}

void begin(const Hooks& newHooks) {
  hooks = newHooks;
  loadFromPrefs();
}

void configure(const String& url, const String& token, bool insecure, const String& caPem) {
  Preferences prefs;
  prefs.begin("pontota", false);
  prefs.putString("url", url);
  prefs.putString("token", token);
  prefs.putBool("insecure", insecure);
  prefs.putString("ca", caPem);
  // Une nouvelle source de mise a jour efface la version mise de cote :
  // l'image jugee corrompue venait peut-etre de l'ancienne.
  prefs.remove("bad");
  prefs.end();
  loadFromPrefs();
}

bool configured() { return otaBaseUrl.length() > 0; }
String baseUrl() { return otaBaseUrl; }
Result lastResult() { return last; }
uint32_t lastCheckUptimeMs() { return lastCheck; }
String setAsideVersion() { return setAside(); }
void clearSetAsideVersion() { setAside(""); }

void markAppValidOnce() {
  if (appValidated) return;
  appValidated = true;
  // Le slot courant n'est confirme qu'une fois le serveur joint : un firmware
  // OTA incapable de dialoguer ne serait jamais valide, et le bootloader
  // reviendrait de lui-meme a l'image precedente au redemarrage suivant.
  if (esp_ota_mark_app_valid_cancel_rollback() == ESP_OK) {
    say("Slot OTA courant valide.");
  }
}

Result check() {
  lastCheck = millis();
  if (!configured()) {
    last = Result::Disabled;
    return last;
  }

  Manifest manifest;
  String error;
  if (!fetchManifest(manifest, error)) {
    if (error.length() == 0) {
      last = Result::NoRelease;
    } else {
      say(String("OTA : ") + error);
      last = Result::NetworkError;
    }
    return last;
  }

  if (manifest.version == PONT_FIRMWARE_VERSION) {
    last = Result::UpToDate;
    return last;
  }
  if (manifest.version == setAside()) {
    // Image deja refusee une fois : on attend qu'une autre version soit
    // publiee plutot que de boucler sur le meme telechargement.
    say(String("OTA : version ") + manifest.version + " deja mise de cote.");
    last = Result::Corrupt;
    return last;
  }

  say(String("OTA : ") + PONT_FIRMWARE_VERSION + " -> " + manifest.version + " (" +
      manifest.sizeBytes + " octets)");
  Result result = downloadAndFlash(manifest, error);

  if (result == Result::Success) {
    setAside("");
    say("OTA : flash termine, redemarrage.");
    if (hooks.beforeRestart) hooks.beforeRestart();
    last = result;
    delay(200);  // laisse partir la derniere ligne sur les liens ouverts
    ESP.restart();
    return last;
  }

  if (result == Result::Corrupt) {
    setAside(manifest.version);
    say(String("OTA : ") + error + " Version " + manifest.version + " mise de cote.");
  } else {
    say(String("OTA : ") + error + " Nouvel essai au prochain cycle.");
  }
  last = result;
  return last;
}

}  // namespace ota

#endif  // PONT_LINK_WIFI
