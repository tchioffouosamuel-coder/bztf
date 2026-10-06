/**
 * ISBN : normalisation, validation et conversion 10 <-> 13.
 * Port de `lib/core/isbn.dart` (application mobile) pour que les deux
 * applications acceptent et rejettent exactement les mêmes saisies.
 */

export function normalizeIsbn(value) {
  const compact = String(value ?? "")
    .replace(/[-\s ]/g, "")
    .trim();
  return compact.endsWith("x")
    ? `${compact.slice(0, -1)}X`
    : compact.toUpperCase();
}

export function isValidIsbn10(value) {
  const normalized = normalizeIsbn(value);
  if (!/^\d{9}[\dX]$/.test(normalized)) return false;
  let sum = 0;
  for (let index = 0; index < 10; index += 1) {
    const char = normalized[index];
    sum += (10 - index) * (char === "X" ? 10 : Number(char));
  }
  return sum % 11 === 0;
}

export function isValidIsbn13(value) {
  const normalized = normalizeIsbn(value);
  if (!/^\d{13}$/.test(normalized)) return false;
  let sum = 0;
  for (let index = 0; index < 12; index += 1) {
    const digit = Number(normalized[index]);
    sum += index % 2 === 0 ? digit : digit * 3;
  }
  return (10 - (sum % 10)) % 10 === Number(normalized[12]);
}

export function isValidIsbn(value) {
  const normalized = normalizeIsbn(value);
  if (normalized.length === 10) return isValidIsbn10(normalized);
  if (normalized.length === 13) return isValidIsbn13(normalized);
  return false;
}

function checkDigit13(twelveDigits) {
  let sum = 0;
  for (let index = 0; index < 12; index += 1) {
    const digit = Number(twelveDigits[index]);
    sum += index % 2 === 0 ? digit : digit * 3;
  }
  return (10 - (sum % 10)) % 10;
}

function checkDigit10(nineDigits) {
  let sum = 0;
  for (let index = 0; index < 9; index += 1)
    sum += (10 - index) * Number(nineDigits[index]);
  const check = (11 - (sum % 11)) % 11;
  return check === 10 ? "X" : String(check);
}

/** Lève une erreur sur un ISBN invalide : jamais de clé de recherche fausse. */
export function toIsbn13(value) {
  const normalized = normalizeIsbn(value);
  if (normalized.length === 13 && isValidIsbn13(normalized)) return normalized;
  if (normalized.length !== 10 || !isValidIsbn10(normalized))
    throw new Error("ISBN invalide.");
  const body = `978${normalized.slice(0, 9)}`;
  return `${body}${checkDigit13(body)}`;
}

/** `null` quand l'ISBN-13 n'a pas d'équivalent ISBN-10 (préfixe 979). */
export function toIsbn10(value) {
  const normalized = normalizeIsbn(value);
  if (normalized.length === 10 && isValidIsbn10(normalized)) return normalized;
  if (
    normalized.length !== 13 ||
    !normalized.startsWith("978") ||
    !isValidIsbn13(normalized)
  )
    return null;
  const body = normalized.slice(3, 12);
  return `${body}${checkDigit10(body)}`;
}
