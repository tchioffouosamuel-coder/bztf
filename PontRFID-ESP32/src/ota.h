// Mises a jour OTA du firmware.
//
// Meme principe que la borne auditron-qr (saas/hardware/borne) : manifest ->
// telechargement en flux -> SHA256 verifie avant d'activer le nouveau slot ->
// redemarrage, avec mise de cote de la version dont l'image est corrompue.
//
// Deux differences tiennent a la nature du pont :
//  - il n'a pas d'API de rattachement ni d'identite propre : l'URL du manifest
//    et le jeton eventuel sont de la configuration locale (NVS), jamais du
//    code ni du depot ;
//  - une mise a jour n'est tentee que lecteur ferme (voir safeToRun() dans
//    main.cpp) : un redemarrage en pleine circulation couperait une operation.
#pragma once

#include <Arduino.h>

#include "config.h"

#if PONT_LINK_WIFI

#include <functional>

namespace ota {

struct Manifest {
  String version;
  String url;
  String sha256;  // hexadecimal, 64 caracteres
  size_t sizeBytes = 0;
};

enum class Result : uint8_t {
  Disabled,      // aucune URL de manifest configuree
  UpToDate,      // le serveur annonce la version deja installee
  NoRelease,     // le serveur ne publie aucune version (204)
  NetworkError,  // transitoire : nouvel essai au prochain cycle
  Corrupt,       // SHA256 incorrect ou image refusee : version mise de cote
  Success        // n'est jamais observe : la carte redemarre
};

const char* resultText(Result result);

struct Hooks {
  std::function<void(const String&)> log;        // diagnostic lisible
  std::function<void(uint8_t)> progress;         // avancement en pourcents
  std::function<void()> beforeRestart;           // dernier souffle avant reboot
};

void begin(const Hooks& hooks);

// Configuration persistee en NVS. Un `baseUrl` vide desactive l'OTA.
void configure(const String& baseUrl, const String& token, bool insecure,
               const String& caPem);
bool configured();
String baseUrl();

// Valide le slot courant (annule le rollback du bootloader) des que ce
// firmware a prouve qu'il joint le serveur de mise a jour.
void markAppValidOnce();

// Verifie le manifest et applique la mise a jour si besoin. Ne retourne pas
// en cas de succes (redemarrage).
Result check();

// Derniers resultats, pour l'action `status`.
Result lastResult();
uint32_t lastCheckUptimeMs();
String setAsideVersion();
void clearSetAsideVersion();

}  // namespace ota

#endif  // PONT_LINK_WIFI
