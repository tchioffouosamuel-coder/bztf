#include "links.h"

bool feedLineBuffer(String& buffer, int incoming, String& line) {
  if (incoming < 0) return false;
  char c = static_cast<char>(incoming);
  if (c == '\n' || c == '\r') {
    if (buffer.length() == 0) return false;
    line = buffer;
    buffer = "";
    line.trim();
    return line.length() > 0;
  }
  if (buffer.length() >= LINK_LINE_MAX) {
    // Ligne aberrante : on jette le tampon plutot que de saturer la RAM.
    buffer = "";
    return false;
  }
  buffer += c;
  return false;
}

// ----------------------------------------------------------------- UART/USB
void UartLink::begin() {
  Serial.begin(115200);
  buffer_.reserve(128);
}

void UartLink::loop(uint32_t) {}

bool UartLink::readLine(String& line) {
  while (Serial.available() > 0) {
    if (feedLineBuffer(buffer_, Serial.read(), line)) return true;
  }
  return false;
}

void UartLink::send(const String& line) {
  Serial.print(line);
  Serial.print('\n');
}

// ------------------------------------------------------------------- WiFi
#if PONT_LINK_WIFI
void WifiLink::configure(const String& ssid, const String& password) {
  ssid_ = ssid;
  password_ = password;
  credentials_ = ssid_.length() > 0;
  nextRetry_ = 0;
  if (credentials_) {
    WiFi.disconnect(true, false);
    WiFi.begin(ssid_.c_str(), password_.c_str());
  }
}

void WifiLink::begin() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // la latence de lecture passe avant la consommation
  if (credentials_) WiFi.begin(ssid_.c_str(), password_.c_str());
}

String WifiLink::ipAddress() const {
  if (WiFi.status() != WL_CONNECTED) return String("");
  return WiFi.localIP().toString();
}

void WifiLink::loop(uint32_t now) {
  if (!credentials_) return;
  if (WiFi.status() != WL_CONNECTED) {
    if (serverStarted_) {
      server_.end();
      serverStarted_ = false;
      for (uint8_t i = 0; i < LINK_MAX_CLIENTS; i++) {
        clients_[i].socket.stop();
        clients_[i].buffer = "";
      }
    }
    if (nextRetry_ == 0 || static_cast<int32_t>(now - nextRetry_) >= 0) {
      nextRetry_ = now + WIFI_RETRY_MS;
      WiFi.reconnect();
    }
    return;
  }
  if (!serverStarted_) {
    server_.begin();
    server_.setNoDelay(true);  // un tag ne doit pas attendre Nagle
    serverStarted_ = true;
  }
  if (server_.hasClient()) {
    WiFiClient incoming = server_.available();
    int8_t slot = -1;
    for (uint8_t i = 0; i < LINK_MAX_CLIENTS; i++) {
      if (!clients_[i].socket.connected()) { slot = static_cast<int8_t>(i); break; }
    }
    if (slot < 0) {
      incoming.stop();  // places occupees : refus net plutot que file d'attente
    } else {
      clients_[slot].socket.stop();
      clients_[slot].socket = incoming;
      clients_[slot].socket.setNoDelay(true);
      clients_[slot].buffer = "";
    }
  }
  for (uint8_t i = 0; i < LINK_MAX_CLIENTS; i++) {
    if (!clients_[i].socket.connected() && clients_[i].buffer.length() > 0) {
      clients_[i].buffer = "";
    }
  }
}

bool WifiLink::connected() const {
  for (uint8_t i = 0; i < LINK_MAX_CLIENTS; i++) {
    if (const_cast<WiFiClient&>(clients_[i].socket).connected()) return true;
  }
  return false;
}

bool WifiLink::readLine(String& line) {
  for (uint8_t i = 0; i < LINK_MAX_CLIENTS; i++) {
    WiFiClient& socket = clients_[i].socket;
    while (socket.connected() && socket.available() > 0) {
      if (feedLineBuffer(clients_[i].buffer, socket.read(), line)) return true;
    }
  }
  return false;
}

void WifiLink::send(const String& line) {
  for (uint8_t i = 0; i < LINK_MAX_CLIENTS; i++) {
    WiFiClient& socket = clients_[i].socket;
    if (!socket.connected()) continue;
    socket.print(line);
    socket.print('\n');
  }
}
#endif

// -------------------------------------------------------------- Bluetooth
#if PONT_LINK_BT
void BluetoothLink::begin() {
  buffer_.reserve(128);
  serial_.begin(deviceName_);
}

void BluetoothLink::loop(uint32_t) {
  if (!serial_.hasClient() && buffer_.length() > 0) buffer_ = "";
}

bool BluetoothLink::readLine(String& line) {
  while (serial_.available() > 0) {
    if (feedLineBuffer(buffer_, serial_.read(), line)) return true;
  }
  return false;
}

void BluetoothLink::send(const String& line) {
  if (!serial_.hasClient()) return;
  serial_.print(line);
  serial_.print('\n');
}
#endif
