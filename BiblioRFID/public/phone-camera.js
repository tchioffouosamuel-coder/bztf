const token = new URLSearchParams(location.search).get("token") || "";
const kinds = {
  front: "1re couverture",
  back: "4e couverture",
  title: "Page de titre",
  other: "Autre vue",
};

let currentKind = "front";
let busy = false;

const $ = (selector) => document.querySelector(selector);

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
      char
    ],
  );
}

async function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error("Lecture de l'image impossible."));
    reader.readAsDataURL(blob);
  });
}

async function scaleToDataUrl(bitmap, maxSide, quality) {
  const sourceWidth = bitmap.videoWidth || bitmap.naturalWidth || bitmap.width;
  const sourceHeight = bitmap.videoHeight || bitmap.naturalHeight || bitmap.height;
  const ratio = Math.min(1, maxSide / Math.max(sourceWidth, sourceHeight));
  const width = Math.max(1, Math.round(sourceWidth * ratio));
  const height = Math.max(1, Math.round(sourceHeight * ratio));
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  context.drawImage(bitmap, 0, 0, width, height);
  const blob = await new Promise((resolve) =>
    canvas.toBlob(resolve, "image/jpeg", quality),
  );
  if (!blob) throw new Error("Conversion de l'image impossible.");
  return blobToDataUrl(blob);
}

async function bitmapFromFile(file) {
  if ("createImageBitmap" in window) {
    try {
      return await createImageBitmap(file, { imageOrientation: "from-image" });
    } catch {
      return createImageBitmap(file);
    }
  }
  const image = new Image();
  image.src = URL.createObjectURL(file);
  await image.decode();
  image.close = () => URL.revokeObjectURL(image.src);
  return image;
}

async function prepareImage(file) {
  const bitmap = await bitmapFromFile(file);
  try {
    return {
      image: await scaleToDataUrl(bitmap, 1600, 0.85),
      thumb: await scaleToDataUrl(bitmap, 320, 0.7),
    };
  } finally {
    bitmap.close?.();
  }
}

function setStatus(message, tone = "") {
  const status = $("#status");
  status.textContent = message;
  status.className = `status ${tone}`.trim();
}

function setBusy(nextBusy) {
  busy = nextBusy;
  $("#capture-button").disabled = busy || !token;
}

function renderPreview({ thumb, name, kind }) {
  const item = document.createElement("article");
  item.className = "preview-item";
  item.innerHTML = `
    <img src="${thumb}" alt="" />
    <div>
      <strong>${escapeHtml(kinds[kind] || kinds.front)}</strong>
      <span>${escapeHtml(name)}</span>
    </div>`;
  $("#preview-list").prepend(item);
}

async function uploadFile(file) {
  if (!/^image\/(jpeg|png|webp)$/.test(file.type))
    throw new Error(`${file.name} n'est pas une image JPEG, PNG ou WebP.`);
  const prepared = await prepareImage(file);
  const response = await fetch(
    `/api/cataloguing/phone-camera/${encodeURIComponent(token)}/uploads`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...prepared,
        kind: currentKind,
        name: file.name || "photo-telephone.jpg",
      }),
    },
  );
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || "Envoi impossible.");
  renderPreview({ ...prepared, name: file.name || "Photo", kind: currentKind });
}

async function uploadFiles(files) {
  if (busy) return;
  setBusy(true);
  let sent = 0;
  try {
    for (const file of files) {
      setStatus(`Envoi de ${file.name || "la photo"}...`);
      await uploadFile(file);
      sent += 1;
    }
    setStatus(`${sent} photo(s) envoyée(s). Vous pouvez continuer.`);
  } catch (error) {
    setStatus(error.message, "error");
  } finally {
    setBusy(false);
  }
}

function bind() {
  for (const button of document.querySelectorAll("[data-kind]")) {
    button.addEventListener("click", () => {
      currentKind = button.dataset.kind;
      for (const entry of document.querySelectorAll("[data-kind]"))
        entry.classList.toggle("active", entry === button);
    });
  }
  $("#capture-button").addEventListener("click", () => $("#capture-input").click());
  $("#capture-input").addEventListener("change", async (event) => {
    await uploadFiles([...event.target.files]);
    event.target.value = "";
  });
}

if (!token) {
  setStatus("Lien caméra invalide. Rouvrez un lien depuis le poste.", "error");
  $("#capture-button").disabled = true;
} else {
  bind();
}
