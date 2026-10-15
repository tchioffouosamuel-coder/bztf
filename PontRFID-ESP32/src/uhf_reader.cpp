#include "uhf_reader.h"

#include "config.h"

namespace uhf {

namespace {
uint8_t checksum(uint8_t type, uint8_t cmd, uint16_t length, const uint8_t* param) {
  uint32_t sum = type + cmd + ((length >> 8) & 0xFF) + (length & 0xFF);
  for (uint16_t i = 0; i < length; i++) sum += param[i];
  return static_cast<uint8_t>(sum & 0xFF);
}

const char* errorText(uint8_t code) {
  switch (code) {
    case 0x15: return "aucun tag dans le champ";
    case 0x16: return "echec d'acces au tag";
    case 0x17: return "commande refusee par le tag";
    case 0xA0: return "parametre invalide";
    default: return "erreur module";
  }
}
}  // namespace

bool hexToBytes(const String& hex, uint8_t* out, size_t outSize, size_t& written) {
  written = 0;
  size_t length = hex.length();
  if (length == 0 || (length % 2) != 0 || length / 2 > outSize) return false;
  for (size_t i = 0; i < length; i += 2) {
    uint8_t value = 0;
    for (size_t j = 0; j < 2; j++) {
      char c = hex.charAt(i + j);
      uint8_t nibble;
      if (c >= '0' && c <= '9') nibble = static_cast<uint8_t>(c - '0');
      else if (c >= 'A' && c <= 'F') nibble = static_cast<uint8_t>(c - 'A' + 10);
      else if (c >= 'a' && c <= 'f') nibble = static_cast<uint8_t>(c - 'a' + 10);
      else return false;
      value = static_cast<uint8_t>((value << 4) | nibble);
    }
    out[written++] = value;
  }
  return true;
}

void bytesToHex(const uint8_t* data, size_t length, char* out, size_t outSize) {
  static const char kDigits[] = "0123456789ABCDEF";
  size_t limit = (outSize == 0) ? 0 : (outSize - 1) / 2;
  if (length > limit) length = limit;
  size_t pos = 0;
  for (size_t i = 0; i < length; i++) {
    out[pos++] = kDigits[(data[i] >> 4) & 0x0F];
    out[pos++] = kDigits[data[i] & 0x0F];
  }
  out[pos] = '\0';
}

bool Reader::begin(String& error) {
  if (PIN_UHF_EN >= 0) {
    pinMode(PIN_UHF_EN, OUTPUT);
    digitalWrite(PIN_UHF_EN, HIGH);
    delay(50);  // reveil du module, une seule fois a la connexion
  }
  port_.begin(UHF_BAUD, SERIAL_8N1, PIN_UHF_RX, PIN_UHF_TX);
  port_.setTimeout(10);
  drain();
  ready_ = true;
  inventory_ = false;

  String ignored;
  stopInventory(ignored);  // le module peut encore inventorier apres un reset chaud

  String info;
  if (!moduleInfo(0x01, info, error)) {
    ready_ = false;
    if (error.length() == 0) error = "Le module UHF ne repond pas.";
    return false;
  }
  if (!setTxPower(DEFAULT_TX_POWER_CDBM, error)) {
    // Puissance refusee : le module dialogue quand meme, on n'echoue pas.
    error = "";
  }
  return true;
}

void Reader::end() {
  if (ready_) {
    String ignored;
    stopInventory(ignored);
  }
  port_.end();
  if (PIN_UHF_EN >= 0) digitalWrite(PIN_UHF_EN, LOW);
  ready_ = false;
  inventory_ = false;
  hasDeferred_ = false;
}

void Reader::drain() {
  while (port_.available() > 0) port_.read();
}

bool Reader::sendCommand(uint8_t cmd, const uint8_t* param, uint16_t length) {
  if (!ready_) return false;
  uint8_t head[5] = {FRAME_HEADER, TYPE_COMMAND, cmd,
                     static_cast<uint8_t>((length >> 8) & 0xFF),
                     static_cast<uint8_t>(length & 0xFF)};
  port_.write(head, sizeof(head));
  if (length > 0 && param != nullptr) port_.write(param, length);
  uint8_t tail[2] = {checksum(TYPE_COMMAND, cmd, length, param), FRAME_END};
  port_.write(tail, sizeof(tail));
  port_.flush();
  return true;
}

bool Reader::readFrame(Frame& out, uint32_t timeoutMs) {
  uint32_t deadline = millis() + timeoutMs;
  while (true) {
    if (static_cast<int32_t>(millis() - deadline) >= 0) return false;
    if (port_.available() <= 0) { delay(1); continue; }
    if (static_cast<uint8_t>(port_.read()) == FRAME_HEADER) break;
  }
  uint8_t header[4];
  for (uint8_t i = 0; i < 4; i++) {
    while (port_.available() <= 0) {
      if (static_cast<int32_t>(millis() - deadline) >= 0) return false;
      delay(1);
    }
    header[i] = static_cast<uint8_t>(port_.read());
  }
  out.type = header[0];
  out.cmd = header[1];
  out.length = static_cast<uint16_t>((header[2] << 8) | header[3]);
  if (out.length > FRAME_PARAM_MAX) { errorsIn_++; return false; }
  for (uint16_t i = 0; i < out.length; i++) {
    while (port_.available() <= 0) {
      if (static_cast<int32_t>(millis() - deadline) >= 0) return false;
      delay(1);
    }
    out.param[i] = static_cast<uint8_t>(port_.read());
  }
  uint8_t tail[2];
  for (uint8_t i = 0; i < 2; i++) {
    while (port_.available() <= 0) {
      if (static_cast<int32_t>(millis() - deadline) >= 0) return false;
      delay(1);
    }
    tail[i] = static_cast<uint8_t>(port_.read());
  }
  if (tail[1] != FRAME_END) { errorsIn_++; return false; }
  if (tail[0] != checksum(out.type, out.cmd, out.length, out.param)) { errorsIn_++; return false; }
  framesIn_++;
  return true;
}

bool Reader::awaitResponse(uint8_t cmd, Frame& out, uint32_t timeoutMs, String& error) {
  uint32_t deadline = millis() + timeoutMs;
  while (static_cast<int32_t>(millis() - deadline) < 0) {
    Frame frame;
    if (!readFrame(frame, timeoutMs)) continue;
    if (frame.cmd == CMD_ERROR && frame.length >= 1) {
      error = errorText(frame.param[0]);
      return false;
    }
    if (frame.type == TYPE_NOTIFY && frame.cmd == CMD_SINGLE_POLL && cmd != CMD_SINGLE_POLL) {
      // Tag remonte pendant l'attente : conserve pour le prochain poll().
      if (!hasDeferred_) { deferred_ = frame; hasDeferred_ = true; }
      continue;
    }
    if (frame.cmd == cmd) { out = frame; return true; }
  }
  error = "Pas de reponse du module UHF.";
  return false;
}

bool Reader::startInventory(String& error) {
  if (!ready_) { error = "Module UHF ferme."; return false; }
  if (inventory_) return true;
  // 0xFFFF : inventaire continu jusqu'a l'ordre d'arret.
  uint8_t param[3] = {0x22, 0xFF, 0xFF};
  if (!sendCommand(CMD_MULTI_POLL, param, sizeof(param))) {
    error = "Envoi de l'inventaire impossible.";
    return false;
  }
  inventory_ = true;
  return true;
}

bool Reader::stopInventory(String& error) {
  if (!ready_) { error = "Module UHF ferme."; return false; }
  if (!sendCommand(CMD_STOP_POLL, nullptr, 0)) {
    error = "Envoi de l'arret impossible.";
    return false;
  }
  inventory_ = false;
  Frame response;
  String ignored;
  awaitResponse(CMD_STOP_POLL, response, 150, ignored);  // acquittement facultatif
  delay(10);
  drain();
  hasDeferred_ = false;
  return true;
}

bool Reader::poll(TagRead& out) {
  Frame frame;
  if (hasDeferred_) {
    frame = deferred_;
    hasDeferred_ = false;
  } else {
    if (port_.available() <= 0) return false;
    if (!readFrame(frame, 20)) return false;
  }
  if (frame.cmd != CMD_SINGLE_POLL) return false;
  // Charge utile : RSSI(1) PC(2) EPC(n) CRC(2)
  if (frame.length < 1 + 2 + 2 + 2) return false;
  out.rssi = static_cast<int8_t>(frame.param[0]);
  out.pc = static_cast<uint16_t>((frame.param[1] << 8) | frame.param[2]);
  size_t epcLength = frame.length - 5;
  bytesToHex(&frame.param[3], epcLength, out.epc, sizeof(out.epc));
  out.tid[0] = '\0';
  out.antenna = 1;
  return out.epc[0] != '\0';
}

bool Reader::setTxPower(uint16_t centiDbm, String& error) {
  if (centiDbm < TX_POWER_MIN_CDBM || centiDbm > TX_POWER_MAX_CDBM) {
    error = "Puissance hors plage.";
    return false;
  }
  uint8_t param[2] = {static_cast<uint8_t>((centiDbm >> 8) & 0xFF),
                      static_cast<uint8_t>(centiDbm & 0xFF)};
  if (!sendCommand(CMD_SET_POWER, param, sizeof(param))) {
    error = "Envoi de la puissance impossible.";
    return false;
  }
  Frame response;
  return awaitResponse(CMD_SET_POWER, response, 500, error);
}

bool Reader::moduleInfo(uint8_t kind, String& text, String& error) {
  uint8_t param[1] = {kind};
  if (!sendCommand(CMD_MODULE_INFO, param, sizeof(param))) {
    error = "Envoi de la requete d'identification impossible.";
    return false;
  }
  Frame response;
  if (!awaitResponse(CMD_MODULE_INFO, response, 800, error)) return false;
  text = "";
  // La reponse contient le type demande puis une chaine ASCII.
  for (uint16_t i = 1; i < response.length; i++) {
    char c = static_cast<char>(response.param[i]);
    text += (c >= 32 && c < 127) ? c : '.';
  }
  if (text.length() == 0) {
    char hex[2 * FRAME_PARAM_MAX + 1];
    bytesToHex(response.param, response.length, hex, sizeof(hex));
    text = hex;
  }
  return true;
}

bool Reader::applySelect(const String& tidHex, String& error) {
  uint8_t tid[16];
  size_t tidLength = 0;
  if (!hexToBytes(tidHex, tid, sizeof(tid), tidLength) || tidLength == 0) {
    error = "TID invalide.";
    return false;
  }
  // SelectParam : target(1) action(1) bank(1) pointeur(4) longueur bits(1)
  //               truncate(1) masque(n)
  uint8_t param[11 + sizeof(tid)];
  size_t pos = 0;
  param[pos++] = 0x00;  // target S0
  param[pos++] = 0x00;  // action 000
  param[pos++] = BANK_TID;
  param[pos++] = 0x00;  // pointeur sur 32 bits, bit 0
  param[pos++] = 0x00;
  param[pos++] = 0x00;
  param[pos++] = 0x00;
  param[pos++] = static_cast<uint8_t>(tidLength * 8);
  param[pos++] = 0x00;  // pas de troncature
  for (size_t i = 0; i < tidLength; i++) param[pos++] = tid[i];

  if (!sendCommand(CMD_SET_SELECT_PARAM, param, static_cast<uint16_t>(pos))) {
    error = "Envoi du filtre impossible.";
    return false;
  }
  Frame response;
  if (!awaitResponse(CMD_SET_SELECT_PARAM, response, 500, error)) return false;

  uint8_t mode[1] = {0x00};  // toutes les commandes respectent le Select
  if (!sendCommand(CMD_SET_SELECT_MODE, mode, sizeof(mode))) {
    error = "Envoi du mode de filtre impossible.";
    return false;
  }
  return awaitResponse(CMD_SET_SELECT_MODE, response, 500, error);
}

bool Reader::clearSelect(String& error) {
  uint8_t mode[1] = {0x01};  // le Select ne s'applique plus a l'inventaire
  if (!sendCommand(CMD_SET_SELECT_MODE, mode, sizeof(mode))) {
    error = "Reinitialisation du filtre impossible.";
    return false;
  }
  Frame response;
  return awaitResponse(CMD_SET_SELECT_MODE, response, 500, error);
}

bool Reader::readTid(String& tidHex, String& error) {
  bool wasRunning = inventory_;
  if (wasRunning && !stopInventory(error)) return false;

  // Un seul tag doit etre present : on l'inventorie puis on lit sa banque TID.
  if (!sendCommand(CMD_SINGLE_POLL, nullptr, 0)) {
    error = "Envoi de l'inventaire unitaire impossible.";
    return false;
  }
  Frame poll;
  if (!awaitResponse(CMD_SINGLE_POLL, poll, 500, error)) {
    if (error.length() == 0) error = "Aucun tag dans le champ.";
    return false;
  }

  // ReadData : mot de passe(4) banque(1) adresse mot(2) longueur mots(2)
  uint8_t param[9] = {0, 0, 0, 0, BANK_TID, 0x00, 0x00, 0x00, 0x06};
  if (!sendCommand(CMD_READ_DATA, param, sizeof(param))) {
    error = "Envoi de la lecture TID impossible.";
    return false;
  }
  Frame response;
  if (!awaitResponse(CMD_READ_DATA, response, 1200, error)) return false;
  // Charge utile : PC(2) EPC(n) longueur donnees(1) donnees(n). La banque TID
  // demandee fait 6 mots, soit les 12 derniers octets de la trame.
  if (response.length < 12) { error = "Reponse TID trop courte."; return false; }
  char hex[33];
  bytesToHex(&response.param[response.length - 12], 12, hex, sizeof(hex));
  tidHex = hex;
  if (wasRunning) {
    String ignored;
    startInventory(ignored);
  }
  return true;
}

bool Reader::writeEpc(const String& tidHex, const String& epcHex, String& error) {
  uint8_t epc[24];
  size_t epcLength = 0;
  if (!hexToBytes(epcHex, epc, sizeof(epc), epcLength) || (epcLength % 2) != 0) {
    error = "EPC invalide : longueur hexadecimale paire attendue.";
    return false;
  }
  bool wasRunning = inventory_;
  if (!stopInventory(error)) return false;
  if (!applySelect(tidHex, error)) return false;

  // Mot PC : nombre de mots EPC decale de 11 bits (BiblioRFID/PROTOCOL.md).
  uint16_t words = static_cast<uint16_t>(epcLength / 2);
  uint16_t pc = static_cast<uint16_t>(words << 11);

  uint8_t param[9 + 2 + sizeof(epc)];
  size_t pos = 0;
  for (uint8_t i = 0; i < 4; i++) param[pos++] = 0x00;  // mot de passe d'acces
  param[pos++] = BANK_EPC;
  param[pos++] = 0x00;  // adresse mot, octet haut
  param[pos++] = 0x01;  // on ecrit a partir du mot 1 : PC puis EPC
  uint16_t totalWords = static_cast<uint16_t>(words + 1);
  param[pos++] = static_cast<uint8_t>((totalWords >> 8) & 0xFF);
  param[pos++] = static_cast<uint8_t>(totalWords & 0xFF);
  param[pos++] = static_cast<uint8_t>((pc >> 8) & 0xFF);
  param[pos++] = static_cast<uint8_t>(pc & 0xFF);
  for (size_t i = 0; i < epcLength; i++) param[pos++] = epc[i];

  if (!sendCommand(CMD_WRITE_DATA, param, static_cast<uint16_t>(pos))) {
    error = "Envoi de l'ecriture impossible.";
    String ignored;
    clearSelect(ignored);
    return false;
  }
  Frame response;
  if (!awaitResponse(CMD_WRITE_DATA, response, 2000, error)) {
    String ignored;
    clearSelect(ignored);
    return false;
  }

  // Relecture du meme tag, toujours filtre sur son TID.
  bool verified = false;
  if (sendCommand(CMD_SINGLE_POLL, nullptr, 0)) {
    Frame verify;
    if (awaitResponse(CMD_SINGLE_POLL, verify, 800, error) && verify.length >= 7) {
      char readBack[49];
      bytesToHex(&verify.param[3], verify.length - 5, readBack, sizeof(readBack));
      String expected = epcHex;
      expected.toUpperCase();
      verified = expected.equals(String(readBack));
      if (!verified) error = "L'EPC relu ne correspond pas a la valeur attendue.";
    } else if (error.length() == 0) {
      error = "Le tag n'a pas repondu a la relecture.";
    }
  } else {
    error = "Relecture impossible.";
  }

  String ignored;
  clearSelect(ignored);
  if (wasRunning) startInventory(ignored);
  return verified;
}

}  // namespace uhf
