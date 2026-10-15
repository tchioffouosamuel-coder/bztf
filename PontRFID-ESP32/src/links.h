// Liens de transport : UART (USB), WiFi (TCP) et Bluetooth classique (SPP).
//
// Les trois liens peuvent etre actifs en meme temps. Chaque ligne recue est une
// commande JSON ; chaque reponse repart sur le lien qui l'a demandee, tandis
// que les evenements (tags, etat) sont diffuses a tous les liens ouverts.
#pragma once

#include <Arduino.h>

#include "config.h"

enum class LinkKind : uint8_t { Uart, Wifi, Bluetooth };

class Link {
 public:
  virtual ~Link() {}
  virtual LinkKind kind() const = 0;
  virtual const char* name() const = 0;
  virtual void begin() = 0;
  virtual void loop(uint32_t now) = 0;
  // Extrait une ligne complete si elle est disponible.
  virtual bool readLine(String& line) = 0;
  virtual void send(const String& line) = 0;
  virtual bool connected() const = 0;
  // Vrai des que le lien est utilisable (UART toujours, radio une fois ouverte).
  virtual bool active() const { return connected(); }
};

// ----------------------------------------------------------------- UART/USB
class UartLink : public Link {
 public:
  LinkKind kind() const override { return LinkKind::Uart; }
  const char* name() const override { return "uart"; }
  void begin() override;
  void loop(uint32_t now) override;
  bool readLine(String& line) override;
  void send(const String& line) override;
  bool connected() const override { return true; }

 private:
  String buffer_;
};

// ------------------------------------------------------------------- WiFi
#if PONT_LINK_WIFI
#include <WiFi.h>

class WifiLink : public Link {
 public:
  LinkKind kind() const override { return LinkKind::Wifi; }
  const char* name() const override { return "wifi"; }
  void begin() override;
  void loop(uint32_t now) override;
  bool readLine(String& line) override;
  void send(const String& line) override;
  bool connected() const override;
  bool active() const override { return WiFi.status() == WL_CONNECTED; }

  void configure(const String& ssid, const String& password);
  String ipAddress() const;
  bool associating() const { return !active() && credentials_; }

 private:
  struct Client {
    WiFiClient socket;
    String buffer;
  };

  WiFiServer server_{WIFI_TCP_PORT};
  Client clients_[LINK_MAX_CLIENTS];
  bool credentials_ = false;
  bool serverStarted_ = false;
  uint32_t nextRetry_ = 0;
  String ssid_;
  String password_;
};
#endif

// -------------------------------------------------------------- Bluetooth
#if PONT_LINK_BT
#include <BluetoothSerial.h>

class BluetoothLink : public Link {
 public:
  LinkKind kind() const override { return LinkKind::Bluetooth; }
  const char* name() const override { return "bluetooth"; }
  void begin() override;
  void loop(uint32_t now) override;
  bool readLine(String& line) override;
  void send(const String& line) override;
  // hasClient() n'est pas const dans le coeur Arduino : le lien reste logiquement
  // inchange, on leve donc la qualification sur cet appel seulement.
  bool connected() const override {
    return const_cast<BluetoothSerial&>(serial_).hasClient();
  }

  void setDeviceName(const String& name) { deviceName_ = name; }

 private:
  BluetoothSerial serial_;
  String buffer_;
  String deviceName_ = PONT_DEVICE_PREFIX;
};
#endif

// Ajoute une ligne au tampon de reception en bornant sa taille.
// Retourne true quand une ligne complete est prete dans `line`.
bool feedLineBuffer(String& buffer, int incoming, String& line);
