// Pilote du module UHF serie de la famille M100 / QM100 / R200 (MagicRF).
//
// Trame : BB <type> <cmd> <lenH> <lenL> <param...> <checksum> 7E
//   checksum = somme de <type> jusqu'au dernier <param>, tronquee a 8 bits.
//   type : 0x00 commande, 0x01 reponse, 0x02 notification.
//
// ATTENTION : la table d'opcodes ci-dessous suit la documentation publique du
// module. Elle n'a pas pu etre confrontee a un module physique dans ce depot.
// Avant la premiere mise en service, verifier chaque valeur dans le manuel du
// module livre, puis corriger uniquement ce bloc : le reste du firmware ne
// contient aucun opcode en dur. L'action JSON "moduleInfo" renvoie la reponse
// brute du module, ce qui permet de confirmer le dialogue des la premiere trame.
#pragma once

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

namespace uhf {

static const uint8_t FRAME_HEADER = 0xBB;
static const uint8_t FRAME_END = 0x7E;

static const uint8_t TYPE_COMMAND = 0x00;
static const uint8_t TYPE_RESPONSE = 0x01;
static const uint8_t TYPE_NOTIFY = 0x02;

static const uint8_t CMD_MODULE_INFO = 0x03;      // param : 0x00 HW, 0x01 SW, 0x02 fabricant
static const uint8_t CMD_SINGLE_POLL = 0x22;      // un inventaire
static const uint8_t CMD_MULTI_POLL = 0x27;       // param : 0x22, cntH, cntL
static const uint8_t CMD_STOP_POLL = 0x28;
static const uint8_t CMD_SET_SELECT_PARAM = 0x0C;
static const uint8_t CMD_SET_SELECT_MODE = 0x12;  // param : 0x00 applique le Select
static const uint8_t CMD_READ_DATA = 0x39;
static const uint8_t CMD_WRITE_DATA = 0x49;
static const uint8_t CMD_SET_POWER = 0xB6;
static const uint8_t CMD_GET_POWER = 0xB7;
static const uint8_t CMD_SET_REGION = 0x07;
static const uint8_t CMD_ERROR = 0xFF;            // notification d'erreur du module

// Banques memoire EPC Gen2.
static const uint8_t BANK_RESERVED = 0x00;
static const uint8_t BANK_EPC = 0x01;
static const uint8_t BANK_TID = 0x02;
static const uint8_t BANK_USER = 0x03;

static const size_t FRAME_PARAM_MAX = 256;

struct Frame {
  uint8_t type = 0;
  uint8_t cmd = 0;
  uint16_t length = 0;
  uint8_t param[FRAME_PARAM_MAX] = {0};
};

// Un tag remonte par une notification d'inventaire.
struct TagRead {
  char epc[49] = {0};  // 24 octets EPC max, en hexadecimal majuscule
  char tid[33] = {0};  // renseigne seulement apres lecture explicite de la banque TID
  int16_t rssi = 0;
  uint8_t antenna = 1;  // le module est mono-antenne : toujours 1
  uint16_t pc = 0;
};

class Reader {
 public:
  Reader(HardwareSerial& port) : port_(port) {}

  // Met le module sous tension, ouvre l'UART et le replace au repos.
  bool begin(String& error);
  void end();
  bool ready() const { return ready_; }

  // A appeler en boucle : consomme l'UART et remplit `out` pour chaque tag.
  // Retourne true tant qu'un tag a ete decode pendant cet appel.
  bool poll(TagRead& out);

  bool startInventory(String& error);
  bool stopInventory(String& error);
  bool inventoryRunning() const { return inventory_; }

  bool setTxPower(uint16_t centiDbm, String& error);
  bool moduleInfo(uint8_t kind, String& text, String& error);

  // Ecriture verifiee : selectionne le TID, ecrit PC+EPC, puis relit.
  bool writeEpc(const String& tidHex, const String& epcHex, String& error);
  // Lit la banque TID du seul tag present et la renvoie en hexadecimal.
  bool readTid(String& tidHex, String& error);

  uint32_t framesIn() const { return framesIn_; }
  uint32_t errorsIn() const { return errorsIn_; }

 private:
  bool sendCommand(uint8_t cmd, const uint8_t* param, uint16_t length);
  // Attend une trame de type reponse pour `cmd`. Les notifications de tag
  // recues entre-temps sont mises de cote dans `deferred_`.
  bool awaitResponse(uint8_t cmd, Frame& out, uint32_t timeoutMs, String& error);
  bool readFrame(Frame& out, uint32_t timeoutMs);
  bool applySelect(const String& tidHex, String& error);
  bool clearSelect(String& error);
  void drain();

  HardwareSerial& port_;
  bool ready_ = false;
  bool inventory_ = false;
  bool hasDeferred_ = false;
  Frame deferred_;
  uint32_t framesIn_ = 0;
  uint32_t errorsIn_ = 0;
};

// Utilitaires hexadecimaux partages avec le protocole JSON.
bool hexToBytes(const String& hex, uint8_t* out, size_t outSize, size_t& written);
void bytesToHex(const uint8_t* data, size_t length, char* out, size_t outSize);

}  // namespace uhf
