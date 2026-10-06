/**
 * Stockage des photos de couverture.
 * Les images vivent en fichiers (`<données>/covers/AAAA/MM/`) et la base ne
 * garde que leur chemin relatif : `library.db` reste léger et la sauvegarde du
 * catalogue n'emporte pas des mégaoctets de JPEG.
 */
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

const ALLOWED_TYPES = new Map([
  ["image/jpeg", ".jpg"],
  ["image/png", ".png"],
  ["image/webp", ".webp"],
]);

export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

export function captureImageUrl(capture, { thumb = false } = {}) {
  const version = encodeURIComponent(capture.uuid);
  return `/api/cataloguing/captures/${capture.id}/image?v=${version}${thumb && capture.thumb_path ? "&thumb=1" : ""}`;
}

export function imageExtension(contentType) {
  return ALLOWED_TYPES.get(String(contentType || "").toLowerCase()) || "";
}

/** Type réel déduit des premiers octets : l'en-tête HTTP ne suffit pas. */
export function sniffImageType(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) return "";
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff)
    return "image/jpeg";
  if (buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])))
    return "image/png";
  if (
    buffer.subarray(0, 4).toString("ascii") === "RIFF" &&
    buffer.subarray(8, 12).toString("ascii") === "WEBP"
  )
    return "image/webp";
  return "";
}

export class CaptureStore {
  constructor(rootDirectory) {
    this.root = rootDirectory;
  }

  /** @returns {{ uuid: string, relativePath: string, thumbRelativePath: string, bytes: number, contentType: string }} */
  save({ buffer, thumbBuffer = null, contentType = "" }) {
    // Seuls les octets décident : un en-tête HTTP peut annoncer n'importe quoi.
    const detected = sniffImageType(buffer);
    const extension = imageExtension(detected);
    if (!extension)
      throw new Error(
        contentType && !imageExtension(contentType)
          ? "Format d’image non pris en charge (JPEG, PNG ou WebP)."
          : "Le fichier reçu n’est pas une image JPEG, PNG ou WebP.",
      );
    if (buffer.length > MAX_IMAGE_BYTES)
      throw new Error("L’image dépasse 8 Mo.");

    const now = new Date();
    const folder = path.join(
      String(now.getFullYear()),
      String(now.getMonth() + 1).padStart(2, "0"),
    );
    fs.mkdirSync(path.join(this.root, folder), { recursive: true });
    const uuid = randomUUID();
    const relativePath = path.join(folder, `${uuid}${extension}`);
    fs.writeFileSync(path.join(this.root, relativePath), buffer);

    let thumbRelativePath = "";
    if (thumbBuffer?.length) {
      const thumbType = sniffImageType(thumbBuffer);
      const thumbExtension = imageExtension(thumbType);
      if (thumbExtension) {
        thumbRelativePath = path.join(folder, `${uuid}.thumb${thumbExtension}`);
        fs.writeFileSync(path.join(this.root, thumbRelativePath), thumbBuffer);
      }
    }

    return {
      uuid,
      relativePath: relativePath.split(path.sep).join("/"),
      thumbRelativePath: thumbRelativePath.split(path.sep).join("/"),
      bytes: buffer.length,
      contentType: detected,
    };
  }

  /** Chemin absolu si et seulement si le chemin reste sous la racine. */
  resolve(relativePath) {
    const clean = String(relativePath || "").replace(/\\/g, "/");
    if (!clean || clean.includes("..")) return "";
    const absolute = path.resolve(this.root, clean);
    const root = path.resolve(this.root);
    return absolute === root || absolute.startsWith(root + path.sep)
      ? absolute
      : "";
  }

  read(relativePath) {
    const absolute = this.resolve(relativePath);
    if (!absolute || !fs.existsSync(absolute)) return null;
    return fs.readFileSync(absolute);
  }

  remove(relativePath) {
    const absolute = this.resolve(relativePath);
    if (!absolute) return false;
    try {
      fs.rmSync(absolute, { force: true });
      return true;
    } catch {
      return false;
    }
  }
}

export function contentTypeFor(relativePath) {
  const extension = path.extname(String(relativePath || "")).toLowerCase();
  if (extension === ".png") return "image/png";
  if (extension === ".webp") return "image/webp";
  return "image/jpeg";
}
