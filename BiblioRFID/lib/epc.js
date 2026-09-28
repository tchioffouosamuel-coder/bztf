const PREFIX_HEX = "42434D01"; // ASCII "BCM" + format version 1

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

export function generateEpc(year, sequence) {
  if (!Number.isInteger(year) || year < 0 || year > 0xffff) throw new Error("Année EPC invalide");
  if (!Number.isInteger(sequence) || sequence < 1 || sequence > 0xffffffff) throw new Error("Séquence EPC invalide");

  const payload = Buffer.alloc(10);
  Buffer.from(PREFIX_HEX, "hex").copy(payload, 0);
  payload.writeUInt16BE(year, 4);
  payload.writeUInt32BE(sequence, 6);
  const crc = crc16Ccitt(payload);
  return `${payload.toString("hex")}${crc.toString(16).padStart(4, "0")}`.toUpperCase();
}

export function formatAccession(year, sequence) {
  return `BCM-${year}-${String(sequence).padStart(6, "0")}`;
}

export function isValidEpc(value) {
  if (!/^[0-9A-F]{24}$/i.test(value || "")) return false;
  const bytes = Buffer.from(value, "hex");
  if (bytes.subarray(0, 4).toString("hex").toUpperCase() !== PREFIX_HEX) return false;
  return bytes.readUInt16BE(10) === crc16Ccitt(bytes.subarray(0, 10));
}
