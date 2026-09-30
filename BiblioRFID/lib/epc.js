import { randomBytes } from "node:crypto";

const PREFIX_HEX = "42434D01"; // ASCII "BCM" + format version 1
const CARD_PREFIX_HEX = "42434D02"; // ASCII "BCM" + format 2 : carte d'abonné
const BADGE_PREFIX_HEX = "42434D03"; // ASCII "BCM" + format 3 : badge du personnel

export function crc16Ccitt(buffer) {
  let crc = 0xffff;
  for (const byte of buffer) {
    crc ^= byte << 8;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 0x8000) !== 0 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc;
}

function encodeEpc(prefix, year, sequence) {
  if (!Number.isInteger(year) || year < 0 || year > 0xffff) throw new Error("Année EPC invalide");
  if (!Number.isInteger(sequence) || sequence < 1 || sequence > 0xffffffff) throw new Error("Séquence EPC invalide");

  const payload = Buffer.alloc(10);
  Buffer.from(prefix, "hex").copy(payload, 0);
  payload.writeUInt16BE(year, 4);
  payload.writeUInt32BE(sequence, 6);
  const crc = crc16Ccitt(payload);
  return `${payload.toString("hex")}${crc.toString(16).padStart(4, "0")}`.toUpperCase();
}

export function generateEpc(year, sequence) {
  return encodeEpc(PREFIX_HEX, year, sequence);
}

/**
 * EPC de carte d'abonné : préfixe + 48 bits aléatoires + CRC. L'aléa (et non
 * un identifiant local) évite les collisions entre postes synchronisés.
 */
export function generateCardEpc(random = randomBytes(6)) {
  return randomEpc(CARD_PREFIX_HEX, random);
}

/** EPC de badge du personnel : même construction, préfixe « BCM » 3. */
export function generateBadgeEpc(random = randomBytes(6)) {
  return randomEpc(BADGE_PREFIX_HEX, random);
}

function randomEpc(prefix, random) {
  if (!Buffer.isBuffer(random) || random.length !== 6)
    throw new Error("Aléa de carte invalide");
  const payload = Buffer.concat([Buffer.from(prefix, "hex"), random]);
  const crc = crc16Ccitt(payload);
  return `${payload.toString("hex")}${crc.toString(16).padStart(4, "0")}`.toUpperCase();
}

export function formatAccession(year, sequence) {
  return `BCM-${year}-${String(sequence).padStart(6, "0")}`;
}

function hasPrefixAndCrc(value, prefix) {
  if (!/^[0-9A-F]{24}$/i.test(value || "")) return false;
  const bytes = Buffer.from(value, "hex");
  if (bytes.subarray(0, 4).toString("hex").toUpperCase() !== prefix) return false;
  return bytes.readUInt16BE(10) === crc16Ccitt(bytes.subarray(0, 10));
}

export function isValidEpc(value) {
  return hasPrefixAndCrc(value, PREFIX_HEX);
}

export function isCardEpc(value) {
  return hasPrefixAndCrc(value, CARD_PREFIX_HEX);
}

export function isBadgeEpc(value) {
  return hasPrefixAndCrc(value, BADGE_PREFIX_HEX);
}
