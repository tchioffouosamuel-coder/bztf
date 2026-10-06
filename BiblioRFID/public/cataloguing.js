/**
 * Catalogage assisté côté interface.
 *
 * Les photos sont réduites dans le navigateur (1600 px pour l'OCR, 320 px pour
 * la vignette) avant d'être envoyées : le poste n'a pas besoin d'une
 * bibliothèque de traitement d'image côté serveur et les fichiers restent
 * légers.
 *
 * Le module reçoit les utilitaires de `app.js` plutôt que de les redéfinir.
 */

const CAPTURE_KINDS = {
  front: "1re de couverture",
  back: "4e de couverture",
  title: "Page de titre",
  other: "Autre vue",
};

const FORM_FIELDS = [
  { name: "title", label: "Titre", required: true, wide: true, maxlength: 240 },
  { name: "subtitle", label: "Sous-titre", wide: true, maxlength: 240 },
  { name: "author", label: "Auteur(s)", maxlength: 240 },
  { name: "isbn", label: "ISBN", maxlength: 32 },
  { name: "publisher", label: "Éditeur", maxlength: 240 },
  { name: "publication_year", label: "Année", maxlength: 4 },
  { name: "edition", label: "Édition", maxlength: 120 },
  { name: "collection", label: "Collection", maxlength: 240 },
  { name: "collection_number", label: "N° de collection", maxlength: 60 },
  { name: "page_count", label: "Pages", maxlength: 60 },
  { name: "language", label: "Langue", maxlength: 60 },
  { name: "document_type", label: "Type de document", maxlength: 60 },
  { name: "category", label: "Catégorie", maxlength: 120 },
  { name: "shelf", label: "Rayon / cote", maxlength: 120 },
  { name: "dewey", label: "Indice Dewey", maxlength: 60 },
  { name: "subjects", label: "Vedettes matière", wide: true, maxlength: 1000 },
  { name: "summary", label: "Résumé", wide: true, multiline: true, maxlength: 4000 },
  { name: "notes", label: "Notes internes", wide: true, multiline: true, maxlength: 2000 },
];

const BATCH_STATUS = {
  capture: ["À photographier", "pending"],
  ocr: ["Lecture OCR…", "pending"],
  recherche: ["Recherche de notice…", "pending"],
  pret: ["Prêt à enregistrer", "ready"],
  enregistre: ["Enregistré en brouillon", "saved"],
  echec: ["À compléter à la main", "failed"],
  ignore: ["Ignoré", "pending"],
};

const AI_ROLE_LABELS = {
  structure: "structuration OCR",
  arbitrate: "arbitrage des notices",
  complete: "complétion",
  quality: "contrôle qualité",
  vision: "lecture des photos",
};

/** Mappe une notice (format serveur) vers les champs du formulaire. */
function fieldsFromNotice(notice, fallbackIsbn = "") {
  const authors = (notice.authors || [])
    .filter((author) => author.role === "auteur")
    .map((author) => author.name)
    .join("; ");
  const year = /(1[0-9]{3}|20[0-9]{2})/.exec(String(notice.publicationDate || ""));
  return {
    title: notice.title || "",
    subtitle: notice.subtitle || "",
    author: authors,
    isbn: notice.isbn || fallbackIsbn,
    publisher: notice.publisher || "",
    publication_year: year ? year[1] : "",
    collection: notice.collection || "",
    collection_number: notice.collectionNumber || "",
    language: notice.language || "",
    edition: notice.edition || "",
    page_count: notice.pageCount || "",
    summary: notice.summary || "",
    subjects: (notice.subjects || []).join("; "),
    dewey: notice.classification || "",
    source_notice: notice.sourceNotice || "",
    source_identifier: notice.sourceIdentifier || "",
    retrieved_at: notice.retrievedAt || "",
  };
}

async function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error("Lecture de l’image impossible."));
    reader.readAsDataURL(blob);
  });
}

/** Réduit une image en conservant ses proportions. */
async function scaleToDataUrl(bitmap, maxSide, quality) {
  const ratio = Math.min(1, maxSide / Math.max(bitmap.width, bitmap.height));
  const width = Math.max(1, Math.round(bitmap.width * ratio));
  const height = Math.max(1, Math.round(bitmap.height * ratio));
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  context.drawImage(bitmap, 0, 0, width, height);
  const blob = await new Promise((resolve) =>
    canvas.toBlob(resolve, "image/jpeg", quality),
  );
  if (!blob) throw new Error("Conversion de l’image impossible.");
  return blobToDataUrl(blob);
}

async function prepareImage(source) {
  const bitmap =
    source instanceof Blob
      ? await createImageBitmap(source, { imageOrientation: "from-image" })
      : await createImageBitmap(source);
  try {
    return {
      image: await scaleToDataUrl(bitmap, 1600, 0.85),
      thumb: await scaleToDataUrl(bitmap, 320, 0.7),
    };
  } finally {
    bitmap.close?.();
  }
}

export function initCataloguing({
  $,
  $$,
  api,
  toast,
  icons,
  escapeHtml,
  confirmAction,
  encodeTagForBook,
  afterBookSaved,
  goToView,
}) {
  const local = {
    mode: "single",
    kind: "front",
    captures: [],
    fields: {},
    notices: [],
    selected: -1,
    ai: null,
    settings: null,
    stream: null,
    session: null,
    activeItemId: null,
    busy: false,
  };

  // --- Paramètres et état --------------------------------------------------

  async function loadSettings() {
    try {
      local.settings = await api("/api/cataloguing/settings");
    } catch (error) {
      local.settings = null;
      toast(error.message, "error");
    }
    renderStatus();
    return local.settings;
  }

  function renderStatus() {
    const title = $("#cataloguing-status-title");
    const detail = $("#cataloguing-status-detail");
    const banner = $("#cataloguing-status");
    if (!title || !local.settings) return;
    const { ocr, ai } = local.settings;
    const engine = ocr.engine === "google_vision" ? "Google Vision" : "Tesseract";
    const parts = [];
    if (!ocr.enabled) parts.push("OCR désactivé");
    else if (!ocr.available) parts.push(ocr.unavailableReason || "OCR indisponible");
    else parts.push(`OCR ${engine} (${ocr.languages.replace("+", ", ")})`);
    if (ai.enabled && ai.configured) {
      const roles = Object.entries(ai.roles)
        .filter(([, active]) => active)
        .map(([role]) => AI_ROLE_LABELS[role] || role);
      parts.push(
        roles.length
          ? `IA ${ai.provider} : ${roles.join(", ")}`
          : `IA ${ai.provider} sans rôle actif`,
      );
    } else parts.push("IA désactivée");
    title.textContent = ocr.available || !ocr.enabled ? "Catalogage prêt" : "Catalogage limité";
    detail.textContent = parts.join(" · ");
    banner.classList.toggle("warn", ocr.enabled && !ocr.available);
  }

  // --- Capture -------------------------------------------------------------

  async function listDevices() {
    const select = $("#capture-device");
    if (!select) return;
    try {
      const devices = (await navigator.mediaDevices.enumerateDevices()).filter(
        (device) => device.kind === "videoinput",
      );
      select.innerHTML = devices.length
        ? devices
            .map(
              (device, index) =>
                `<option value="${escapeHtml(device.deviceId)}">${escapeHtml(
                  device.label || `Caméra ${index + 1}`,
                )}</option>`,
            )
            .join("")
        : `<option value="">Aucune caméra détectée</option>`;
    } catch {
      select.innerHTML = `<option value="">Caméras inaccessibles</option>`;
    }
  }

  async function startCamera() {
    const video = $("#capture-video");
    stopCamera();
    const deviceId = $("#capture-device").value;
    try {
      local.stream = await navigator.mediaDevices.getUserMedia({
        video: deviceId
          ? { deviceId: { exact: deviceId }, width: { ideal: 1920 } }
          : { facingMode: "environment", width: { ideal: 1920 } },
        audio: false,
      });
    } catch (error) {
      toast(`Webcam indisponible : ${error.message}`, "error");
      return;
    }
    video.srcObject = local.stream;
    await video.play().catch(() => {});
    video.classList.add("live");
    $("#capture-placeholder").classList.add("hidden");
    $("#capture-shoot").disabled = false;
    // Les libellés des caméras ne sont connus qu'après autorisation.
    await listDevices();
  }

  function stopCamera() {
    const video = $("#capture-video");
    if (local.stream) {
      for (const track of local.stream.getTracks()) track.stop();
      local.stream = null;
    }
    if (video) {
      video.srcObject = null;
      video.classList.remove("live");
    }
    const placeholder = $("#capture-placeholder");
    if (placeholder) placeholder.classList.remove("hidden");
    const shoot = $("#capture-shoot");
    if (shoot) shoot.disabled = true;
  }

  async function shoot() {
    const video = $("#capture-video");
    if (!local.stream || !video.videoWidth) {
      toast("Activez d’abord la webcam.", "error");
      return;
    }
    await addImages([{ source: video, name: "webcam" }], "webcam");
  }

  async function importFiles(files) {
    const images = [...files]
      .filter((file) => /^image\/(jpeg|png|webp)$/.test(file.type))
      .map((file) => ({ source: file, name: file.name }));
    if (!images.length) {
      toast("Seules les images JPEG, PNG ou WebP sont acceptées.", "error");
      return;
    }
    await addImages(images, "fichier");
  }

  /** Envoie les images, puis lance l'OCR de chacune si le moteur est prêt. */
  async function addImages(sources, origin) {
    if (local.busy) return;
    local.busy = true;
    setCaptureBusy(true);
    try {
      for (const entry of sources) {
        let prepared;
        try {
          prepared = await prepareImage(entry.source);
        } catch (error) {
          toast(`${entry.name} : ${error.message}`, "error");
          continue;
        }
        let capture;
        try {
          const payload = await api("/api/cataloguing/captures", {
            method: "POST",
            body: JSON.stringify({
              image: prepared.image,
              thumb: prepared.thumb,
              kind: local.kind,
              source: origin,
              itemId: local.mode === "batch" ? local.activeItemId : null,
            }),
          });
          capture = payload.capture;
        } catch (error) {
          toast(error.message, "error");
          continue;
        }
        if (local.mode === "single") {
          local.captures.push(capture);
          renderStrip();
        }
        if (local.settings?.ocr?.available) await runOcr(capture);
      }
      if (local.mode === "batch" && local.session) await reloadSession();
    } finally {
      local.busy = false;
      setCaptureBusy(false);
    }
  }

  function setCaptureBusy(busy) {
    for (const selector of ["#capture-shoot", "#capture-import", "#capture-start"]) {
      const button = $(selector);
      if (button) button.disabled = busy || (selector === "#capture-shoot" && !local.stream);
    }
  }

  async function runOcr(capture) {
    const target = local.captures.find((item) => item.id === capture.id);
    if (target) {
      target.ocrState = "running";
      renderStrip();
    }
    try {
      const result = await api(`/api/cataloguing/captures/${capture.id}/ocr`, {
        method: "POST",
      });
      if (target) {
        Object.assign(target, result.capture, {
          ocrText: result.text,
          ocrEngine: result.engine,
          ocrConfidence: result.confidence,
          ocrState: "done",
        });
        renderStrip();
      }
      return result;
    } catch (error) {
      if (target) {
        target.ocrState = "failed";
        target.ocrError = error.message;
        renderStrip();
      }
      toast(`OCR : ${error.message}`, "error");
      return null;
    }
  }

  function renderStrip() {
    const strip = $("#capture-strip");
    if (!strip) return;
    if (local.mode === "batch") {
      strip.innerHTML = local.activeItemId
        ? `<p class="catalog-hint">Les photos sont rattachées au livre sélectionné dans le lot.</p>`
        : `<p class="catalog-hint">Sélectionnez un livre du lot avant de photographier.</p>`;
      return;
    }
    if (!local.captures.length) {
      strip.innerHTML = `<p class="catalog-hint">Aucune photo pour ce livre.</p>`;
      return;
    }
    strip.innerHTML = local.captures
      .map((capture) => {
        const ocr =
          capture.ocrState === "running"
            ? "OCR en cours…"
            : capture.ocrState === "failed"
              ? `OCR : ${escapeHtml(capture.ocrError || "échec")}`
              : capture.ocrText
                ? `${Math.round(capture.ocrConfidence || 0)} % · ${escapeHtml(
                    String(capture.ocrText).slice(0, 60),
                  )}…`
                : "Pas de texte reconnu";
        return `<figure class="capture-thumb" data-capture="${capture.id}">
          <img src="${capture.thumbUrl}" alt="${escapeHtml(CAPTURE_KINDS[capture.kind] || capture.kind)}" />
          <figcaption>
            <strong>${escapeHtml(CAPTURE_KINDS[capture.kind] || capture.kind)}</strong>
            <small>${ocr}</small>
          </figcaption>
          <button class="icon-button" type="button" data-remove="${capture.id}" title="Retirer cette photo" aria-label="Retirer cette photo">
            <i data-lucide="trash-2"></i>
          </button>
        </figure>`;
      })
      .join("");
    icons();
  }

  async function removeCapture(id) {
    try {
      await api(`/api/cataloguing/captures/${id}`, { method: "DELETE" });
    } catch (error) {
      toast(error.message, "error");
      return;
    }
    local.captures = local.captures.filter((capture) => capture.id !== id);
    renderStrip();
    if (local.mode === "batch" && local.session) await reloadSession();
  }

  // --- Identification ------------------------------------------------------

  async function identify() {
    const button = $("#catalog-identify");
    button.disabled = true;
    $("#catalog-search-hint").textContent = "Recherche en cours…";
    try {
      const result = await api("/api/cataloguing/identify", {
        method: "POST",
        body: JSON.stringify({
          captureIds: local.captures.map((capture) => capture.id),
          isbn: $("#catalog-isbn").value.trim(),
          title: $("#catalog-search-title").value.trim(),
          author: $("#catalog-search-author").value.trim(),
        }),
      });
      applyIdentification(result);
    } catch (error) {
      $("#catalog-search-hint").textContent = error.message;
      toast(error.message, "error");
    } finally {
      button.disabled = false;
    }
  }

  function applyIdentification(result) {
    local.notices = result.notices || [];
    local.selected = typeof result.selected === "number" ? result.selected : -1;
    local.ai = result.ai || null;

    if (result.alreadyCatalogued) {
      const titles = (result.books || [])
        .map((book) => `${book.accession} — ${book.title}`)
        .join(", ");
      $("#catalog-search-hint").textContent = `Déjà au catalogue : ${titles}`;
      renderCandidates();
      renderAiNotes();
      toast("Cet ISBN est déjà au catalogue.", "error");
      return;
    }

    local.fields = { ...result.fields };
    if (result.isbn && !$("#catalog-isbn").value.trim())
      $("#catalog-isbn").value = result.isbn;
    renderForm();
    renderCandidates();
    renderAiNotes();

    const unavailable = result.unavailableSources || [];
    const messages = [];
    if (local.notices.length)
      messages.push(
        `${local.notices.length} notice${local.notices.length > 1 ? "s" : ""} trouvée${local.notices.length > 1 ? "s" : ""}`,
      );
    else messages.push("Aucune notice trouvée : complétez la fiche à la main");
    if (result.searchError) messages.push(result.searchError);
    if (unavailable.length) messages.push(`Sources injoignables : ${unavailable.join(", ")}`);
    $("#catalog-search-hint").textContent = messages.join(" · ");
  }

  function renderCandidates() {
    const container = $("#catalog-candidates");
    if (!local.notices.length) {
      container.classList.add("hidden");
      container.innerHTML = "";
      return;
    }
    container.classList.remove("hidden");
    container.innerHTML = local.notices
      .map((notice, index) => {
        const authors = (notice.authors || []).map((author) => author.name).join(", ");
        const details = [notice.publisher, notice.publicationDate, notice.collection]
          .filter(Boolean)
          .join(" · ");
        return `<button class="catalog-candidate${index === local.selected ? " selected" : ""}" type="button" data-notice="${index}">
          <div>
            <strong>${escapeHtml(notice.title)}</strong>
            <small>${escapeHtml(authors || "Auteur non précisé")}</small>
            <small>${escapeHtml(details)}</small>
          </div>
          <span class="source-badge">${escapeHtml(notice.sourceNotice || "source inconnue")}</span>
        </button>`;
      })
      .join("");
  }

  function renderAiNotes() {
    const container = $("#catalog-ai-notes");
    const ai = local.ai;
    if (!ai || (!ai.used?.length && !ai.warnings?.length)) {
      container.classList.add("hidden");
      container.innerHTML = "";
      return;
    }
    const blocks = [];
    if (ai.arbitrate?.reason)
      blocks.push(
        `<p><i data-lucide="sparkles"></i> Notice retenue par l’IA (${ai.arbitrate.confidence} %) : ${escapeHtml(ai.arbitrate.reason)}</p>`,
      );
    if (ai.structure?.notes)
      blocks.push(`<p><i data-lucide="sparkles"></i> ${escapeHtml(ai.structure.notes)}</p>`);
    if (ai.complete?.notes)
      blocks.push(`<p><i data-lucide="sparkles"></i> ${escapeHtml(ai.complete.notes)}</p>`);
    for (const issue of ai.quality?.issues || [])
      blocks.push(
        `<p class="issue ${escapeHtml(issue.severity)}"><i data-lucide="triangle-alert"></i> ${escapeHtml(
          issue.field ? `${issue.field} : ` : "",
        )}${escapeHtml(issue.message)}</p>`,
      );
    for (const warning of ai.warnings || [])
      blocks.push(
        `<p class="issue avertissement"><i data-lucide="circle-x"></i> ${escapeHtml(warning.message)}</p>`,
      );
    container.classList.toggle("hidden", !blocks.length);
    container.innerHTML = blocks.join("");
    icons();
  }

  function renderForm() {
    const form = $("#catalog-form");
    form.innerHTML = FORM_FIELDS.map((field) => {
      const value = escapeHtml(local.fields[field.name] || "");
      const control = field.multiline
        ? `<textarea name="${field.name}" rows="3" maxlength="${field.maxlength}">${value}</textarea>`
        : `<input name="${field.name}" maxlength="${field.maxlength}" value="${value}"${
            field.required ? " required" : ""
          } autocomplete="off" />`;
      return `<label class="field${field.wide ? " wide" : ""}"><span>${field.label}${
        field.required ? " *" : ""
      }</span>${control}</label>`;
    }).join("");
    const source = local.fields.source_notice
      ? `Notice ${local.fields.source_notice}${
          local.fields.source_identifier ? ` · ${local.fields.source_identifier}` : ""
        }`
      : "Saisie manuelle";
    $("#catalog-source-hint").textContent = source;
  }

  function collectFields() {
    const form = $("#catalog-form");
    const fields = { ...local.fields };
    for (const element of form.elements) {
      if (!element.name) continue;
      fields[element.name] = element.value.trim();
    }
    return fields;
  }

  function pickNotice(index) {
    const notice = local.notices[index];
    if (!notice) return;
    local.selected = index;
    const current = collectFields();
    // La notice choisie remplace la description bibliographique ; les choix
    // propres à la bibliothèque (cote, catégorie, notes) sont conservés.
    local.fields = {
      ...current,
      ...fieldsFromNotice(notice, $("#catalog-isbn").value.trim()),
      category: current.category || "",
      shelf: current.shelf || "",
      notes: current.notes || "",
      document_type: current.document_type || "",
    };
    renderForm();
    renderCandidates();
  }

  async function save({ encode }) {
    const fields = collectFields();
    if (!fields.title) {
      toast("Le titre est obligatoire.", "error");
      return;
    }
    let payload;
    try {
      payload = await api("/api/cataloguing/commit", {
        method: "POST",
        body: JSON.stringify({
          fields,
          captureIds: local.captures.map((capture) => capture.id),
          draft: false,
        }),
      });
    } catch (error) {
      toast(error.message, "error");
      return;
    }
    toast(`${payload.book.accession} · ${payload.book.title} enregistré.`);
    await afterBookSaved();
    resetSingle();
    if (encode) encodeTagForBook(payload.book);
  }

  function resetSingle() {
    local.captures = [];
    local.notices = [];
    local.fields = {};
    local.selected = -1;
    local.ai = null;
    $("#catalog-isbn").value = "";
    $("#catalog-search-title").value = "";
    $("#catalog-search-author").value = "";
    $("#catalog-search-hint").textContent = "";
    renderStrip();
    renderCandidates();
    renderAiNotes();
    renderForm();
  }

  // --- Catalogage en lot ---------------------------------------------------

  async function loadSessions({ preferred = null } = {}) {
    let sessions = [];
    try {
      sessions = (await api("/api/cataloguing/sessions")).sessions || [];
    } catch (error) {
      toast(error.message, "error");
    }
    const select = $("#batch-session");
    select.innerHTML = sessions.length
      ? sessions
          .map(
            (session) =>
              `<option value="${session.id}">${escapeHtml(
                session.label || `Lot ${session.id}`,
              )} — ${session.items} livre(s), ${session.saved} enregistré(s)${
                session.status === "terminee" ? " · clôturé" : ""
              }</option>`,
          )
          .join("")
      : `<option value="">Aucun lot</option>`;
    const target = preferred || local.session?.id || sessions[0]?.id || null;
    if (target) {
      select.value = String(target);
      await loadSession(target);
    } else {
      local.session = null;
      renderBatch();
    }
  }

  async function loadSession(id) {
    try {
      local.session = (await api(`/api/cataloguing/sessions/${id}`)).session;
    } catch (error) {
      local.session = null;
      toast(error.message, "error");
    }
    if (local.session && !local.session.items.some((item) => item.id === local.activeItemId))
      local.activeItemId = local.session.items[0]?.id || null;
    renderBatch();
  }

  async function reloadSession() {
    if (local.session) await loadSession(local.session.id);
  }

  async function newSession() {
    const label = $("#batch-label").value.trim();
    try {
      const payload = await api("/api/cataloguing/sessions", {
        method: "POST",
        body: JSON.stringify({ label }),
      });
      $("#batch-label").value = "";
      local.activeItemId = null;
      await loadSessions({ preferred: payload.session.id });
      toast("Lot créé. Ajoutez un livre puis photographiez-le.");
    } catch (error) {
      toast(error.message, "error");
    }
  }

  async function addItem() {
    if (!local.session) {
      toast("Créez d’abord un lot.", "error");
      return;
    }
    try {
      const payload = await api(
        `/api/cataloguing/sessions/${local.session.id}/items`,
        { method: "POST" },
      );
      local.activeItemId = payload.item.id;
      // La liste des lots affiche le nombre de livres : elle doit suivre.
      await loadSessions({ preferred: local.session.id });
    } catch (error) {
      toast(error.message, "error");
    }
  }

  async function processSession() {
    if (!local.session) return;
    const button = $("#batch-process");
    button.disabled = true;
    $("#batch-progress").textContent =
      "Analyse du lot en cours : OCR, recherche de notices puis IA. Cela peut prendre une minute par livre.";
    try {
      const payload = await api(
        `/api/cataloguing/sessions/${local.session.id}/process`,
        { method: "POST" },
      );
      local.session = payload.session;
      renderBatch();
      const ready = local.session.items.filter((item) => item.status === "pret").length;
      $("#batch-progress").textContent = `${ready} livre(s) prêt(s) à enregistrer.`;
    } catch (error) {
      $("#batch-progress").textContent = error.message;
      toast(error.message, "error");
    } finally {
      button.disabled = false;
    }
  }

  async function processItem(id) {
    $("#batch-progress").textContent = "Analyse du livre en cours…";
    try {
      await api(`/api/cataloguing/items/${id}/process`, { method: "POST" });
      await reloadSession();
      $("#batch-progress").textContent = "";
    } catch (error) {
      $("#batch-progress").textContent = error.message;
      toast(error.message, "error");
    }
  }

  async function commitBatch() {
    if (!local.session) return;
    if (
      !(await confirmAction({
        title: "Enregistrer les brouillons ?",
        text: "Les fiches prêtes rejoignent le catalogue en « à encoder ». Aucun tag n’est écrit : l’encodage se fait livre par livre à la station.",
        confirmButtonText: "Enregistrer",
      }))
    )
      return;
    try {
      const payload = await api(
        `/api/cataloguing/sessions/${local.session.id}/commit`,
        { method: "POST" },
      );
      local.session = payload.session;
      renderBatch();
      await afterBookSaved();
      const skipped = payload.skipped.length
        ? ` ${payload.skipped.length} fiche(s) incomplète(s) laissée(s) de côté.`
        : "";
      toast(`${payload.saved.length} brouillon(s) enregistré(s).${skipped}`);
    } catch (error) {
      toast(error.message, "error");
    }
  }

  async function removeItem(id) {
    if (
      !(await confirmAction({
        title: "Retirer ce livre du lot ?",
        text: "Ses photos non enregistrées seront supprimées.",
        confirmButtonText: "Retirer",
        confirmButtonClass: "button danger",
      }))
    )
      return;
    try {
      await api(`/api/cataloguing/items/${id}`, { method: "DELETE" });
      if (local.activeItemId === id) local.activeItemId = null;
      await reloadSession();
    } catch (error) {
      toast(error.message, "error");
    }
  }

  async function saveItemField(id, name, value) {
    const item = local.session?.items.find((entry) => entry.id === Number(id));
    if (!item) return;
    const fields = { ...item.fields, [name]: value };
    // Une fiche qui porte un titre est prête, qu'il vienne de la recherche ou
    // de la saisie du catalogueur.
    const ready = Boolean(fields.title) && item.status !== "enregistre";
    try {
      const payload = await api(`/api/cataloguing/items/${id}`, {
        method: "PUT",
        body: JSON.stringify({ fields, status: ready ? "pret" : undefined }),
      });
      Object.assign(item, payload.item);
      renderBatchStatus(item);
    } catch (error) {
      toast(error.message, "error");
    }
  }

  function renderBatchStatus(item) {
    const card = $(`.batch-card[data-item="${item.id}"]`);
    if (!card) return;
    const [label, tone] = BATCH_STATUS[item.status] || [item.status, "pending"];
    const badge = card.querySelector(".batch-badge");
    badge.textContent = label;
    badge.className = `batch-badge ${tone}`;
  }

  function renderBatch() {
    const grid = $("#batch-grid");
    const empty = $("#batch-empty");
    if (!local.session) {
      grid.innerHTML = "";
      empty.classList.remove("hidden");
      renderStrip();
      return;
    }
    empty.classList.toggle("hidden", local.session.items.length > 0);
    grid.innerHTML = local.session.items
      .map((item) => {
        const [label, tone] = BATCH_STATUS[item.status] || [item.status, "pending"];
        const photos = item.captures.length
          ? item.captures
              .map(
                (capture) =>
                  `<img src="/api/cataloguing/captures/${capture.id}/image?thumb=1" alt="${escapeHtml(
                    CAPTURE_KINDS[capture.kind] || capture.kind,
                  )}" title="${escapeHtml(CAPTURE_KINDS[capture.kind] || capture.kind)}" />`,
              )
              .join("")
          : `<span class="catalog-hint">Aucune photo</span>`;
        const saved = item.status === "enregistre";
        const fields = item.fields || {};
        return `<article class="batch-card${item.id === local.activeItemId ? " active" : ""}" data-item="${item.id}">
          <header>
            <strong>Livre ${item.position}</strong>
            <span class="batch-badge ${tone}">${escapeHtml(label)}</span>
          </header>
          <div class="batch-photos">${photos}</div>
          <div class="batch-fields">
            <label class="field"><span>Titre</span><input data-field="title" value="${escapeHtml(
              fields.title || "",
            )}" maxlength="240" ${saved ? "disabled" : ""} /></label>
            <label class="field"><span>Auteur</span><input data-field="author" value="${escapeHtml(
              fields.author || "",
            )}" maxlength="240" ${saved ? "disabled" : ""} /></label>
            <label class="field"><span>ISBN</span><input data-field="isbn" value="${escapeHtml(
              fields.isbn || "",
            )}" maxlength="32" ${saved ? "disabled" : ""} /></label>
          </div>
          ${item.message ? `<p class="batch-message">${escapeHtml(item.message)}</p>` : ""}
          <footer>
            <button class="button secondary" type="button" data-select="${item.id}" ${
              saved ? "disabled" : ""
            }>
              <i data-lucide="camera"></i><span>${
                item.id === local.activeItemId ? "Livre actif" : "Photographier"
              }</span>
            </button>
            <button class="button secondary" type="button" data-process="${item.id}" ${
              saved ? "disabled" : ""
            }>
              <i data-lucide="scan-text"></i><span>Analyser</span>
            </button>
            <button class="icon-button" type="button" data-remove-item="${item.id}" title="Retirer du lot" aria-label="Retirer du lot">
              <i data-lucide="trash-2"></i>
            </button>
          </footer>
        </article>`;
      })
      .join("");
    icons();
    renderStrip();
    const active = local.session.items.find((item) => item.id === local.activeItemId);
    $("#capture-target-hint").textContent = active
      ? `Les photos vont au livre ${active.position} du lot.`
      : "";
  }

  // --- Couvertures d'une fiche --------------------------------------------

  async function renderCovers(bookId) {
    const container = $("#book-detail-covers");
    if (!container) return;
    container.classList.add("hidden");
    container.innerHTML = "";
    try {
      const payload = await api(`/api/cataloguing/books/${bookId}/covers`);
      if (!payload.covers.length) return;
      container.innerHTML = payload.covers
        .map(
          (cover) =>
            `<a href="${cover.url}" target="_blank" rel="noreferrer" title="${escapeHtml(
              CAPTURE_KINDS[cover.kind] || cover.kind,
            )}"><img src="${cover.thumbUrl}" alt="${escapeHtml(
              CAPTURE_KINDS[cover.kind] || cover.kind,
            )}" /></a>`,
        )
        .join("");
      container.classList.remove("hidden");
    } catch {
      // Une fiche sans photo n'est pas une erreur à signaler.
    }
  }

  // --- Paramètres ----------------------------------------------------------

  function prefixesToText(prefixes = {}) {
    return Object.entries(prefixes)
      .map(([genre, prefix]) => `${genre}=${prefix}`)
      .join("\n");
  }

  function textToPrefixes(text) {
    const prefixes = {};
    for (const line of String(text || "").split(/\r?\n/)) {
      const [genre, prefix] = line.split("=");
      if (!genre?.trim() || !prefix?.trim()) continue;
      prefixes[genre.trim()] = prefix.trim();
    }
    return prefixes;
  }

  async function loadSettingsForm() {
    const settings = await loadSettings();
    if (!settings) return;
    $("#ocr-enabled").checked = settings.ocr.enabled;
    $("#ocr-languages").value = settings.ocr.languages;
    const engine = $$("input[name=ocrEngine]").find(
      (input) => input.value === settings.ocr.engine,
    );
    if (engine) engine.checked = true;
    $("#vision-api-key").value = "";
    $("#vision-api-key").placeholder = settings.ocr.visionKeySet
      ? "Clé enregistrée — laisser vide pour la conserver"
      : "Clé API Google Vision";
    $("#ai-enabled").checked = settings.ai.enabled;
    $("#ai-provider").value = settings.ai.provider;
    $("#ai-model").value = settings.ai.model === settings.ai.defaultModels[settings.ai.provider]
      ? ""
      : settings.ai.model;
    $("#ai-model").placeholder = settings.ai.defaultModels[settings.ai.provider] || "";
    $("#ai-key").value = "";
    $("#ai-key").placeholder = settings.ai.keySet
      ? "Clé enregistrée — laisser vide pour la conserver"
      : "Clé API du fournisseur";
    for (const input of $$("input[name=aiRole]"))
      input.checked = Boolean(settings.ai.roles[input.value]);
    $("#cote-prefixes").value = prefixesToText(settings.cotePrefixes);
    updateSettingsHints();
  }

  function updateSettingsHints() {
    const settings = local.settings;
    const engine =
      $$("input[name=ocrEngine]").find((input) => input.checked)?.value || "tesseract";
    $("#vision-key-field").classList.toggle("hidden", engine !== "google_vision");
    const ocrHint = $("#ocr-settings-hint");
    if (settings && settings.ocr.enabled && !settings.ocr.available)
      ocrHint.textContent = settings.ocr.unavailableReason;
    else
      ocrHint.textContent =
        engine === "google_vision"
          ? "Les photos sont envoyées à Google pour la reconnaissance."
          : "Reconnaissance locale, sans connexion Internet.";
    const provider = $("#ai-provider").value;
    $("#ai-model").placeholder = settings?.ai?.defaultModels?.[provider] || "";
    const visionRole = $$("input[name=aiRole]").find((input) => input.value === "vision");
    const supportsVision = provider !== "deepseek";
    visionRole.disabled = !supportsVision;
    if (!supportsVision) visionRole.checked = false;
    $("#ai-settings-hint").textContent = $("#ai-enabled").checked
      ? "Le texte OCR, et les photos pour le rôle de lecture, sont envoyés au fournisseur choisi."
      : "Désactivée : aucune donnée ne quitte le poste.";
  }

  async function saveSettingsForm(event) {
    event.preventDefault();
    const payload = {
      ocrEnabled: $("#ocr-enabled").checked,
      ocrEngine: $$("input[name=ocrEngine]").find((input) => input.checked)?.value,
      ocrLanguages: $("#ocr-languages").value.trim(),
      aiEnabled: $("#ai-enabled").checked,
      aiProvider: $("#ai-provider").value,
      aiModel: $("#ai-model").value.trim(),
      aiRoles: $$("input[name=aiRole]")
        .filter((input) => input.checked)
        .map((input) => input.value),
      cotePrefixes: textToPrefixes($("#cote-prefixes").value),
    };
    // Une clé vide signifie « conserver celle déjà enregistrée ».
    if ($("#vision-api-key").value.trim())
      payload.visionApiKey = $("#vision-api-key").value.trim();
    if ($("#ai-key").value.trim()) payload.aiKey = $("#ai-key").value.trim();
    try {
      local.settings = await api("/api/cataloguing/settings", {
        method: "PUT",
        body: JSON.stringify(payload),
      });
      renderStatus();
      await loadSettingsForm();
      toast("Paramètres de catalogage enregistrés.");
    } catch (error) {
      toast(error.message, "error");
    }
  }

  async function testAi() {
    const button = $("#ai-test");
    button.disabled = true;
    try {
      const result = await api("/api/cataloguing/ai/test", { method: "POST" });
      toast(`${result.provider} répond (${result.model}).`);
    } catch (error) {
      toast(error.message, "error");
    } finally {
      button.disabled = false;
    }
  }

  // --- Mode et liaisons ----------------------------------------------------

  function setMode(mode) {
    local.mode = mode === "batch" ? "batch" : "single";
    $$("#cataloguing-mode button").forEach((button) =>
      button.classList.toggle("active", button.dataset.mode === local.mode),
    );
    $("#catalog-pane-single").classList.toggle("hidden", local.mode !== "single");
    $("#catalog-pane-batch").classList.toggle("hidden", local.mode !== "batch");
    $("#cataloguing-subtitle").textContent =
      local.mode === "batch"
        ? "Lot de livres : photos à la chaîne, fiches enregistrées en brouillon."
        : "Photo, OCR, recherche de notice puis encodage du tag.";
    $("#capture-target-hint").textContent = "";
    renderStrip();
    if (local.mode === "batch") loadSessions();
  }

  async function activate() {
    await loadSettings();
    renderForm();
    renderStrip();
    if (local.mode === "batch") await loadSessions();
  }

  function deactivate() {
    stopCamera();
  }

  function bind() {
    $$("#cataloguing-mode button").forEach((button) =>
      button.addEventListener("click", () => setMode(button.dataset.mode)),
    );
    $$("#capture-kind button").forEach((button) =>
      button.addEventListener("click", () => {
        local.kind = button.dataset.kind;
        $$("#capture-kind button").forEach((entry) =>
          entry.classList.toggle("active", entry.dataset.kind === local.kind),
        );
      }),
    );
    $("#capture-start").addEventListener("click", startCamera);
    $("#capture-device").addEventListener("change", () => {
      if (local.stream) startCamera();
    });
    $("#capture-shoot").addEventListener("click", shoot);
    $("#capture-import").addEventListener("click", () =>
      $("#capture-file-input").click(),
    );
    $("#capture-file-input").addEventListener("change", async (event) => {
      await importFiles(event.target.files);
      event.target.value = "";
    });
    const dropzone = $("#capture-dropzone");
    dropzone.addEventListener("dragover", (event) => {
      event.preventDefault();
      dropzone.classList.add("dragging");
    });
    dropzone.addEventListener("dragleave", () => dropzone.classList.remove("dragging"));
    dropzone.addEventListener("drop", async (event) => {
      event.preventDefault();
      dropzone.classList.remove("dragging");
      await importFiles(event.dataTransfer.files);
    });
    $("#capture-strip").addEventListener("click", (event) => {
      const id = Number(event.target.closest("[data-remove]")?.dataset.remove);
      if (id) removeCapture(id);
    });

    $("#catalog-identify").addEventListener("click", identify);
    $("#catalog-reset").addEventListener("click", resetSingle);
    $("#catalog-candidates").addEventListener("click", (event) => {
      const index = event.target.closest("[data-notice]")?.dataset.notice;
      if (index !== undefined) pickNotice(Number(index));
    });
    $("#catalog-save").addEventListener("click", () => save({ encode: false }));
    $("#catalog-save-and-encode").addEventListener("click", () =>
      save({ encode: true }),
    );
    $("#catalog-isbn").addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        identify();
      }
    });

    $("#batch-new").addEventListener("click", newSession);
    $("#batch-add-item").addEventListener("click", addItem);
    $("#batch-process").addEventListener("click", processSession);
    $("#batch-commit").addEventListener("click", commitBatch);
    $("#batch-session").addEventListener("change", (event) => {
      if (event.target.value) loadSession(Number(event.target.value));
    });
    $("#batch-grid").addEventListener("click", (event) => {
      const select = event.target.closest("[data-select]");
      if (select) {
        local.activeItemId = Number(select.dataset.select);
        renderBatch();
        return;
      }
      const process = event.target.closest("[data-process]");
      if (process) {
        processItem(Number(process.dataset.process));
        return;
      }
      const remove = event.target.closest("[data-remove-item]");
      if (remove) removeItem(Number(remove.dataset.removeItem));
    });
    $("#batch-grid").addEventListener("change", (event) => {
      const input = event.target.closest("[data-field]");
      if (!input) return;
      const card = input.closest(".batch-card");
      saveItemField(card.dataset.item, input.dataset.field, input.value.trim());
    });

    $("#cataloguing-settings-form").addEventListener("submit", saveSettingsForm);
    $("#ai-test").addEventListener("click", testAi);
    $("#ai-provider").addEventListener("change", updateSettingsHints);
    $("#ai-enabled").addEventListener("change", updateSettingsHints);
    $$("input[name=ocrEngine]").forEach((input) =>
      input.addEventListener("change", updateSettingsHints),
    );
    for (const button of $$("#view-cataloguing [data-view-link]"))
      button.addEventListener("click", () => goToView(button.dataset.viewLink));
  }

  bind();
  return { activate, deactivate, loadSettingsForm, renderCovers, setMode };
}
