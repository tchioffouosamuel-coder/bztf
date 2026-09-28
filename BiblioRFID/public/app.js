import createElement from "/vendor/lucide/createElement.js";
import Activity from "/vendor/lucide/icons/activity.js";
import ArrowRight from "/vendor/lucide/icons/arrow-right.js";
import BadgeCheck from "/vendor/lucide/icons/badge-check.js";
import BadgeMinus from "/vendor/lucide/icons/badge-minus.js";
import BookCheck from "/vendor/lucide/icons/book-check.js";
import BookCopy from "/vendor/lucide/icons/book-copy.js";
import BookDashed from "/vendor/lucide/icons/book-dashed.js";
import BookOpen from "/vendor/lucide/icons/book-open.js";
import BookPlus from "/vendor/lucide/icons/book-plus.js";
import Cable from "/vendor/lucide/icons/cable.js";
import CalendarPlus from "/vendor/lucide/icons/calendar-plus.js";
import CircleAlert from "/vendor/lucide/icons/circle-alert.js";
import CircleCheck from "/vendor/lucide/icons/circle-check.js";
import Clock3 from "/vendor/lucide/icons/clock-3.js";
import Download from "/vendor/lucide/icons/download.js";
import FlaskConical from "/vendor/lucide/icons/flask-conical.js";
import HistoryIcon from "/vendor/lucide/icons/history.js";
import Inbox from "/vendor/lucide/icons/inbox.js";
import LayoutDashboard from "/vendor/lucide/icons/layout-dashboard.js";
import Library from "/vendor/lucide/icons/library.js";
import LibraryBig from "/vendor/lucide/icons/library-big.js";
import LogOut from "/vendor/lucide/icons/log-out.js";
import Menu from "/vendor/lucide/icons/menu.js";
import Moon from "/vendor/lucide/icons/moon.js";
import Network from "/vendor/lucide/icons/network.js";
import Pause from "/vendor/lucide/icons/pause.js";
import Pencil from "/vendor/lucide/icons/pencil.js";
import Play from "/vendor/lucide/icons/play.js";
import PlugZap from "/vendor/lucide/icons/plug-zap.js";
import Radio from "/vendor/lucide/icons/radio.js";
import RadioTower from "/vendor/lucide/icons/radio-tower.js";
import RefreshCw from "/vendor/lucide/icons/refresh-cw.js";
import Save from "/vendor/lucide/icons/save.js";
import ScanLine from "/vendor/lucide/icons/scan-line.js";
import Search from "/vendor/lucide/icons/search.js";
import Settings2 from "/vendor/lucide/icons/settings-2.js";
import ShieldCheck from "/vendor/lucide/icons/shield-check.js";
import Sun from "/vendor/lucide/icons/sun.js";
import Trash2 from "/vendor/lucide/icons/trash-2.js";
import TriangleAlert from "/vendor/lucide/icons/triangle-alert.js";
import Upload from "/vendor/lucide/icons/upload.js";
import Usb from "/vendor/lucide/icons/usb.js";
import X from "/vendor/lucide/icons/x.js";

const lucideIcons = {
  activity: Activity,
  "arrow-right": ArrowRight,
  "badge-check": BadgeCheck,
  "badge-minus": BadgeMinus,
  "book-check": BookCheck,
  "book-copy": BookCopy,
  "book-dashed": BookDashed,
  "book-open": BookOpen,
  "book-plus": BookPlus,
  cable: Cable,
  "calendar-plus": CalendarPlus,
  "circle-alert": CircleAlert,
  "circle-check": CircleCheck,
  "clock-3": Clock3,
  download: Download,
  "flask-conical": FlaskConical,
  history: HistoryIcon,
  inbox: Inbox,
  "layout-dashboard": LayoutDashboard,
  library: Library,
  "library-big": LibraryBig,
  "log-out": LogOut,
  menu: Menu,
  moon: Moon,
  network: Network,
  pause: Pause,
  pencil: Pencil,
  play: Play,
  "plug-zap": PlugZap,
  radio: Radio,
  "radio-tower": RadioTower,
  "refresh-cw": RefreshCw,
  save: Save,
  "scan-line": ScanLine,
  search: Search,
  "settings-2": Settings2,
  "shield-check": ShieldCheck,
  sun: Sun,
  "trash-2": Trash2,
  "triangle-alert": TriangleAlert,
  upload: Upload,
  usb: Usb,
  x: X,
};

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const VISUAL_RELEASE_DELAY_MS = 100;
const BOOK_PAGE_SIZE = 200;

const state = {
  user: null,
  setupRequired: false,
  books: [],
  bookTotal: 0,
  bookStatus: "tous",
  bookSearch: "",
  selectedBook: null,
  settings: { connection_type: "usb", connection_endpoint: "" },
  readerTiming: {
    beepMode: "controlled",
    beepDurationMs: 75,
    rearmDelayMs: 30000,
  },
  connected: false,
  activeView: "",
  autoReadEnabled: true,
  readerStream: null,
  readerStreamKey: "",
  visualTags: new Map(),
  visualTagTimers: new Map(),
  visualSessionAnnounced: false,
  presenceSessionId: null,
  registrationOpen: false,
  currentTagKey: null,
  pendingBook: null,
  lastScanError: "",
};

const viewMeta = {
  dashboard: ["Vue d’ensemble", "Tableau de bord"],
  catalogue: ["Gestion du fonds", "Catalogue"],
  station: ["Opérations RFID", "Station RFID"],
  history: ["Traçabilité", "Historique"],
  settings: ["Configuration", "Paramètres"],
};

function icons() {
  $$("i[data-lucide]").forEach((element) => {
    const name = element.dataset.lucide;
    const iconNode = lucideIcons[name];
    if (!iconNode) return;
    const svg = createElement(iconNode, {
      "aria-hidden": "true",
      "data-lucide": name,
      class: `lucide lucide-${name}`,
    });
    element.replaceWith(svg);
  });
}

function escapeHtml(value) {
  return String(value ?? "").replace(
    /[&<>'"]/g,
    (character) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        "'": "&#39;",
        '"': "&quot;",
      })[character],
  );
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
  });
  const payload = await response.json();
  if (response.status === 401 && !path.startsWith("/api/auth/")) {
    showAuth({ setupRequired: false, message: "Votre session a expiré." });
  }
  if (!response.ok) throw new Error(payload.error || "Opération impossible.");
  return payload;
}

function showAuth({ setupRequired = false, message = "" } = {}) {
  state.setupRequired = setupRequired;
  state.user = null;
  state.readerStream?.close();
  state.readerStream = null;
  $("#app-shell").classList.add("hidden");
  $("#auth-screen").classList.remove("hidden");
  $("#auth-name-field").classList.toggle("hidden", !setupRequired);
  $("#auth-form").elements.name.required = setupRequired;
  $("#auth-form").elements.password.autocomplete = setupRequired
    ? "new-password"
    : "current-password";
  $("#auth-eyebrow").textContent = setupRequired
    ? "Première configuration"
    : "Accès sécurisé";
  $("#auth-title").textContent = setupRequired
    ? "Créer l’administrateur"
    : "Connexion";
  $("#auth-copy").textContent = setupRequired
    ? "Ce compte administrera la station et protégera les données locales."
    : "Identifiez-vous pour accéder à la station RFID.";
  $("#auth-submit span").textContent = setupRequired
    ? "Créer et continuer"
    : "Se connecter";
  $("#auth-error").textContent = message;
  $("#auth-error").classList.toggle("hidden", !message);
  $("#auth-form").elements.email.focus();
}

async function activateSession(user) {
  state.user = user;
  $("#user-name").textContent = user.name;
  $("#user-role").textContent = user.role === "admin" ? "Administrateur" : "Opérateur";
  $("#user-avatar").textContent = user.name.trim().charAt(0).toUpperCase() || "U";
  $("#auth-screen").classList.add("hidden");
  $("#app-shell").classList.remove("hidden");
  await loadSettings();
  setView(location.hash.slice(1) || "station");
}

async function submitAuth(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const submit = $("#auth-submit");
  const error = $("#auth-error");
  submit.disabled = true;
  error.classList.add("hidden");
  try {
    const body = Object.fromEntries(new FormData(form));
    const result = await api(
      state.setupRequired ? "/api/auth/setup" : "/api/auth/login",
      { method: "POST", body: JSON.stringify(body) },
    );
    form.reset();
    await activateSession(result.user);
  } catch (exception) {
    error.textContent = exception.message;
    error.classList.remove("hidden");
  } finally {
    submit.disabled = false;
  }
}

async function logout() {
  try {
    await api("/api/auth/logout", { method: "POST", body: "{}" });
  } finally {
    showAuth();
  }
}

function toast(message, type = "success") {
  const item = document.createElement("div");
  item.className = `toast ${type}`;
  item.innerHTML = `<i data-lucide="${type === "error" ? "circle-alert" : "circle-check"}"></i><span>${escapeHtml(message)}</span>`;
  $("#toast-region").append(item);
  icons();
  setTimeout(() => item.remove(), 4200);
}

async function confirmAction({
  title,
  text,
  confirmButtonText,
  confirmButtonClass = "button primary",
}) {
  const result = await Swal.fire({
    title,
    text,
    icon: "warning",
    showCancelButton: true,
    reverseButtons: true,
    buttonsStyling: false,
    confirmButtonText,
    cancelButtonText: "Annuler",
    customClass: {
      popup: "app-alert",
      title: "app-alert-title",
      htmlContainer: "app-alert-copy",
      actions: "app-alert-actions",
      confirmButton: confirmButtonClass,
      cancelButton: "button secondary",
    },
  });
  return result.isConfirmed;
}

function formatDate(value, includeTime = true) {
  if (!value) return "—";
  const options = includeTime
    ? { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" }
    : { day: "2-digit", month: "short", year: "numeric" };
  return new Intl.DateTimeFormat("fr-FR", options).format(new Date(value));
}

function statusLabel(status) {
  return (
    { encode: "Encodé", a_encoder: "À encoder", indisponible: "Indisponible" }[
      status
    ] || status
  );
}

function operationIcon(type) {
  return (
    {
      ecriture: "badge-check",
      lecture: "scan-line",
      connexion: "plug-zap",
      catalogue: "book-plus",
    }[type] || "activity"
  );
}

function setView(name) {
  if (!viewMeta[name]) return;
  if (state.activeView === "station" && name !== "station")
    stopAutoReading(false);
  state.activeView = name;
  $$(".view").forEach((view) =>
    view.classList.toggle("active", view.id === `view-${name}`),
  );
  $$(".nav-item").forEach((item) =>
    item.classList.toggle("active", item.dataset.view === name),
  );
  $("#page-eyebrow").textContent = viewMeta[name][0];
  $("#page-title").textContent = viewMeta[name][1];
  $("#sidebar").classList.remove("open");
  history.replaceState(null, "", `#${name}`);
  if (name === "dashboard") loadDashboard();
  if (name === "catalogue") loadBooks();
  if (name === "station") startAutoReading();
  if (name === "history") loadHistory();
}

function emptyBlock(text) {
  return `<div class="empty-state"><i data-lucide="inbox"></i><p>${escapeHtml(text)}</p></div>`;
}

function bookRow(book) {
  return `<div class="book-row">
    <span class="book-glyph"><i data-lucide="book-open"></i></span>
    <div><strong>${escapeHtml(book.title)}</strong><small>${escapeHtml(book.author || "Auteur non renseigné")} · ${escapeHtml(book.accession)}</small></div>
    <span class="status-badge ${book.status}">${statusLabel(book.status)}</span>
  </div>`;
}

function activityItem(item) {
  return `<div class="activity-item">
    <span class="activity-icon"><i data-lucide="${operationIcon(item.type)}"></i></span>
    <div><strong>${escapeHtml(item.message)}</strong><small>${escapeHtml(item.title || item.accession || item.type)}</small></div>
    <time>${formatDate(item.created_at)}</time>
  </div>`;
}

async function loadDashboard() {
  try {
    const data = await api("/api/dashboard");
    $("#stat-total").textContent = data.counts.total || 0;
    $("#stat-tagged").textContent = data.counts.tagged || 0;
    $("#stat-pending").textContent = data.counts.pending || 0;
    $("#stat-today").textContent = data.counts.today || 0;
    $("#recent-books").innerHTML = data.recentBooks.length
      ? data.recentBooks.map(bookRow).join("")
      : emptyBlock("Le catalogue est vide.");
    $("#recent-activity").innerHTML = data.recentActivity.length
      ? data.recentActivity.map(activityItem).join("")
      : emptyBlock("Aucune opération enregistrée.");
    icons();
  } catch (error) {
    toast(error.message, "error");
  }
}

function bookTableRows(books) {
  return books
    .map(
      (book) => `<tr>
    <td><div class="table-book"><span class="book-glyph"><i data-lucide="book-open"></i></span><div><strong>${escapeHtml(book.title)}</strong><small>${escapeHtml(book.author || "Auteur non renseigné")}</small></div></div></td>
    <td><div class="mono">${escapeHtml(book.accession)}</div><div class="cell-subtle">${escapeHtml(book.isbn || "Sans ISBN")}</div></td>
    <td>${escapeHtml(book.shelf || "—")}<div class="cell-subtle">${escapeHtml(book.category || "Non classé")}</div></td>
    <td><span class="status-badge ${book.status}">${statusLabel(book.status)}</span></td>
    <td><div class="table-actions">
      <button class="icon-button" data-action="encode" data-id="${book.id}" title="Ouvrir dans la station" aria-label="Ouvrir dans la station"><i data-lucide="radio-tower"></i></button>
      ${book.status === "encode" ? `<button class="icon-button" data-action="unencode" data-id="${book.id}" title="Désencoder le tag" aria-label="Désencoder le tag"><i data-lucide="badge-minus"></i></button>` : ""}
      <button class="icon-button" data-action="edit" data-id="${book.id}" title="Modifier" aria-label="Modifier"><i data-lucide="pencil"></i></button>
      <button class="icon-button danger" data-action="delete" data-id="${book.id}" title="Supprimer" aria-label="Supprimer"><i data-lucide="trash-2"></i></button>
    </div></td>
  </tr>`,
    )
    .join("");
}

async function loadBooks({ append = false } = {}) {
  try {
    const offset = append ? state.books.length : 0;
    const params = new URLSearchParams({
      search: state.bookSearch,
      status: state.bookStatus,
      limit: String(BOOK_PAGE_SIZE),
      offset: String(offset),
      paged: "1",
    });
    const result = await api(`/api/books?${params}`);
    state.books = append ? [...state.books, ...result.books] : result.books;
    state.bookTotal = result.total;
    const loadedText =
      state.books.length < state.bookTotal
        ? ` · ${state.books.length} affichés`
        : "";
    $("#catalogue-count").textContent =
      `${state.bookTotal} livre${state.bookTotal > 1 ? "s" : ""}${loadedText}`;
    const tbody = $("#books-table");
    if (append)
      tbody.insertAdjacentHTML("beforeend", bookTableRows(result.books));
    else tbody.innerHTML = bookTableRows(state.books);
    $("#books-empty").classList.toggle("hidden", state.bookTotal > 0);
    $("#books-pagination").classList.toggle(
      "hidden",
      state.books.length >= state.bookTotal,
    );
    icons();
  } catch (error) {
    toast(error.message, "error");
  }
}

async function importXlsx(event) {
  const input = event.currentTarget;
  const file = input.files?.[0];
  if (!file) return;
  if (!file.name.toLowerCase().endsWith(".xlsx")) {
    toast("Sélectionnez un fichier Excel au format .xlsx.", "error");
    input.value = "";
    return;
  }
  if (file.size > 25 * 1024 * 1024) {
    toast("Le fichier XLSX dépasse la limite de 25 Mo.", "error");
    input.value = "";
    return;
  }

  const button = $("#import-xlsx");
  button.disabled = true;
  button.setAttribute("aria-busy", "true");
  try {
    const result = await api("/api/import/xlsx", {
      method: "POST",
      headers: {
        "Content-Type":
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      },
      body: file,
    });
    const details = [
      `${result.imported} importé(s)`,
      `${result.duplicates} déjà présent(s)`,
    ];
    if (result.skipped || result.rejected)
      details.push(`${result.skipped + result.rejected} ignoré(s)`);
    toast(`Import terminé : ${details.join(", ")}.`);
    await Promise.all([loadBooks(), loadDashboard()]);
  } catch (error) {
    toast(error.message, "error");
  } finally {
    button.disabled = false;
    button.removeAttribute("aria-busy");
    input.value = "";
  }
}

async function loadStationBooks() {
  return Promise.resolve();
}

function selectBook(book, { fromScan = false } = {}) {
  state.selectedBook = book;
  const container = $("#selected-book");
  container.classList.remove("hidden");
  $("#multiple-identification").classList.add("hidden");
  container.classList.remove("empty");
  container.classList.toggle("recognized", fromScan);
  container.innerHTML = `<i data-lucide="${fromScan ? "scan-line" : "book-check"}"></i>
    <div class="selected-book-copy">
      <span class="selection-label">${fromScan ? "Livre reconnu par le tag" : "Livre sélectionné"}</span>
      <h3>${escapeHtml(book.title)}</h3>
      <p>${escapeHtml(book.author || "Auteur non renseigné")}</p>
      <div class="selected-identifiers"><strong>${escapeHtml(book.accession)}</strong><code>${escapeHtml(book.epc)}</code></div>
    </div>`;
  icons();
}

function setWriteStatus(title, detail, type = "") {
  const element = $("#write-status");
  element.className = `write-status ${type}`;
  element.innerHTML = `<span class="status-orbit"><i data-lucide="${type === "error" ? "triangle-alert" : type === "success" ? "circle-check" : "radio"}"></i></span><div><strong>${escapeHtml(title)}</strong><p>${escapeHtml(detail)}</p></div>`;
  icons();
}

async function loadHistory() {
  try {
    const items = await api("/api/activity?limit=250");
    $("#history-table").innerHTML = items.length
      ? items
          .map(
            (item) => `<tr>
      <td>${formatDate(item.created_at)}</td><td>${escapeHtml(item.type)}</td>
      <td><span class="result-badge ${item.result}">${item.result === "succes" ? "Succès" : "Échec"}</span></td>
      <td>${escapeHtml(item.title || item.accession || "—")}</td><td>${escapeHtml(item.message)}</td>
    </tr>`,
          )
          .join("")
      : `<tr><td colspan="5">Aucune opération enregistrée.</td></tr>`;
  } catch (error) {
    toast(error.message, "error");
  }
}

function openBookDialog(book = null) {
  const form = $("#book-form");
  form.reset();
  form.elements.id.value = book?.id || "";
  for (const name of [
    "title",
    "author",
    "isbn",
    "publisher",
    "publication_year",
    "category",
    "shelf",
    "notes",
  ]) {
    form.elements[name].value = book?.[name] || "";
  }
  $("#book-dialog-title").textContent = book
    ? "Modifier le livre"
    : "Nouveau livre";
  $("#book-dialog").showModal();
  setTimeout(() => form.elements.title.focus(), 50);
}

async function saveBook(event) {
  if (event.submitter?.value === "cancel") return;
  event.preventDefault();
  const form = event.currentTarget;
  const input = Object.fromEntries(new FormData(form));
  const id = input.id;
  delete input.id;
  try {
    await api(id ? `/api/books/${id}` : "/api/books", {
      method: id ? "PUT" : "POST",
      body: JSON.stringify(input),
    });
    $("#book-dialog").close();
    toast(id ? "Livre mis à jour." : "Livre ajouté et numéro EPC généré.");
    await Promise.all([loadBooks(), loadDashboard(), loadStationBooks()]);
  } catch (error) {
    toast(error.message, "error");
  }
}

async function handleTableAction(event) {
  const button = event.target.closest("button[data-action]");
  if (!button) return;
  const book = state.books.find(
    (item) => item.id === Number(button.dataset.id),
  );
  if (!book) return;
  if (button.dataset.action === "edit") openBookDialog(book);
  if (button.dataset.action === "encode") {
    state.pendingBook = book;
    selectBook(book);
    setWriteStatus(
      "Livre prêt à encoder",
      "Posez maintenant son tag sur le lecteur.",
    );
    setView("station");
  }
  if (button.dataset.action === "unencode") {
    if (
      !(await confirmAction({
        title: "Désencoder ce tag ?",
        text: `Posez uniquement le tag de « ${book.title} » sur le lecteur. Son EPC sera effacé.`,
        confirmButtonText: "Désencoder",
      }))
    )
      return;
    try {
      await api(`/api/books/${book.id}/erase-tag`, {
        method: "POST",
        body: JSON.stringify(getConnection()),
      });
      toast("Tag désencodé et vérifié.");
      await Promise.all([loadBooks(), loadDashboard(), loadStationBooks()]);
    } catch (error) {
      toast(error.message, "error");
    }
  }
  if (button.dataset.action === "delete") {
    if (
      !(await confirmAction({
        title: "Supprimer ce livre ?",
        text: `« ${book.title} » sera retiré du catalogue.`,
        confirmButtonText: "Supprimer",
        confirmButtonClass: "button danger",
      }))
    )
      return;
    try {
      await api(`/api/books/${book.id}`, { method: "DELETE" });
      toast("Livre supprimé.");
      await loadBooks();
    } catch (error) {
      toast(error.message, "error");
    }
  }
}

function getConnection() {
  const type =
    $("input[name=connection_type]:checked")?.value ||
    state.settings.connection_type ||
    "usb";
  const endpoint =
    type === "usb"
      ? $("#endpoint-select").value
      : type === "simulation"
        ? ""
        : $("#endpoint-input").value.trim();
  return { type, endpoint };
}

function setReaderState(online, title, detail) {
  state.connected = online;
  const element = $("#reader-state");
  element.classList.toggle("online", online);
  $("strong", element).textContent = title;
  $("#reader-state-detail").textContent = detail;
}

function connectionLabel(type) {
  return (
    {
      usb: "USB HID",
      serial: "Port série",
      tcp: "Réseau TCP",
      simulation: "Simulation",
    }[type] || String(type || "RFID").toUpperCase()
  );
}

function readerDisplayName(value, type) {
  const name = String(value || "");
  const isTechnicalPath = name.startsWith("\\\\?\\") || /hid#vid_/i.test(name);
  if (isTechnicalPath || !name)
    return type === "simulation" ? "Lecteur virtuel" : "Lecteur RFID de bureau";
  return name;
}

function readerDisplayDetail(status, type) {
  const label = connectionLabel(type);
  return !status || status === "OK"
    ? `${label} · Connecté`
    : `${label} · ${status}`;
}

async function probeConnection(showToast = true) {
  const connection = getConnection();
  setReaderState(false, "Connexion…", connection.type.toUpperCase());
  try {
    const result = await api("/api/reader/probe", {
      method: "POST",
      body: JSON.stringify(connection),
    });
    setReaderState(
      true,
      readerDisplayName(result.reader, connection.type),
      readerDisplayDetail(result.status, connection.type),
    );
    if (showToast) toast("Connexion au lecteur réussie.");
    return true;
  } catch (error) {
    setReaderState(false, "Lecteur hors ligne", error.message);
    if (showToast) toast(error.message, "error");
    return false;
  }
}

async function refreshDevices(showToast = true) {
  const button = $("#refresh-devices");
  button.disabled = true;
  try {
    const result = await api("/api/devices");
    const select = $("#endpoint-select");
    const current = state.settings.connection_endpoint || select.value;
    select.innerHTML = `<option value="">Détection automatique</option>${(result.usb || []).map((device, index) => `<option value="${escapeHtml(device)}">Lecteur USB ${index + 1}</option>`).join("")}`;
    select.value = (result.usb || []).includes(current) ? current : "";
    if (showToast)
      toast(`${result.usb?.length || 0} lecteur(s) USB détecté(s).`);
  } catch (error) {
    toast(error.message, "error");
  } finally {
    button.disabled = false;
  }
}

function updateConnectionFields() {
  const type = $("input[name=connection_type]:checked").value;
  const isUsb = type === "usb";
  const isSimulation = type === "simulation";
  $("#endpoint-select").classList.toggle("hidden", !isUsb);
  $("#endpoint-input").classList.toggle("hidden", isUsb || isSimulation);
  $("#refresh-devices").classList.toggle("hidden", !isUsb);
  const help = {
    usb: "Détection automatique du premier lecteur USB.",
    serial: "Port et débit, par exemple COM3:115200.",
    tcp: "Adresse et port, par exemple 192.168.1.168:6180.",
    simulation: "Aucun matériel n’est utilisé.",
  };
  $("#endpoint-help").textContent = help[type];
  $("#endpoint-input").placeholder =
    type === "tcp" ? "192.168.1.168:6180" : "COM3:115200";
}

async function loadSettings() {
  try {
    const [settings, readerTiming] = await Promise.all([
      api("/api/settings"),
      api("/api/reader/timing"),
    ]);
    state.settings = {
      connection_type: "usb",
      connection_endpoint: "",
      ...settings,
    };
    state.readerTiming = readerTiming;
    const radio =
      $(
        `input[name=connection_type][value="${state.settings.connection_type}"]`,
      ) || $("input[name=connection_type][value=usb]");
    radio.checked = true;
    $("#endpoint-input").value = state.settings.connection_endpoint || "";
    const buzzerMode =
      $(`input[name=beepMode][value="${readerTiming.beepMode}"]`) ||
      $("input[name=beepMode][value=controlled]");
    buzzerMode.checked = true;
    $("#beep-duration-ms").value = readerTiming.beepDurationMs;
    $("#beep-rearm-ms").value = readerTiming.rearmDelayMs;
    updateBuzzerModeFields();
    $("#bridge-compile-status").textContent = timingStatus(
      readerTiming,
      "Pont configuré",
    );
    updateConnectionFields();
    await refreshDevices(false);
    if (state.settings.connection_type === "usb")
      $("#endpoint-select").value = state.settings.connection_endpoint || "";
  } catch (error) {
    toast(error.message, "error");
  }
}

function timingStatus(timing, prefix) {
  const mode =
    timing.beepMode === "native"
      ? "buzzer natif"
      : `impulsion ${timing.beepDurationMs} ms`;
  return `${prefix} : ${mode} · réarmement ${timing.rearmDelayMs} ms.`;
}

function updateBuzzerModeFields() {
  const nativeMode = $("input[name=beepMode]:checked")?.value === "native";
  $("#beep-duration-ms").disabled = nativeMode;
}

async function saveReaderTiming(event) {
  event.preventDefault();
  const button = $("#compile-bridge");
  const status = $("#bridge-compile-status");
  const timing = {
    beepMode: $("input[name=beepMode]:checked")?.value || "controlled",
    beepDurationMs: Number($("#beep-duration-ms").value),
    rearmDelayMs: Number($("#beep-rearm-ms").value),
  };
  button.disabled = true;
  status.textContent = "Compilation du pont et reconnexion du lecteur…";
  try {
    const result = await api("/api/reader/timing", {
      method: "PUT",
      body: JSON.stringify(timing),
    });
    state.readerTiming = result;
    status.textContent = timingStatus(result, "Pont compilé");
    if (result.reconnectError)
      toast(
        `Pont compilé, mais reconnexion impossible : ${result.reconnectError}`,
        "error",
      );
    else toast("Pont RFID recompilé et configuration appliquée.");
  } catch (error) {
    status.textContent = `Compilation échouée : ${error.message}`;
    toast(error.message, "error");
  } finally {
    button.disabled = false;
  }
}

async function testBuzzer() {
  const button = $("#test-buzzer");
  button.disabled = true;
  try {
    const result = await api("/api/reader/beep-test", {
      method: "POST",
      body: JSON.stringify(getConnection()),
    });
    if (!result.beeped)
      throw new Error("Le lecteur a refusé la commande du buzzer.");
    const detail =
      result.mode === "native"
        ? "buzzer natif"
        : `maintien mesuré : ${result.holdMs} ms`;
    toast(`Commande sonore envoyée (${detail}).`);
  } catch (error) {
    toast(error.message, "error");
  } finally {
    button.disabled = false;
  }
}

async function saveSettings(event) {
  event.preventDefault();
  const connection = getConnection();
  try {
    state.settings = await api("/api/settings", {
      method: "PUT",
      body: JSON.stringify(connection),
    });
    toast("Paramètres enregistrés.");
    await probeConnection(false);
  } catch (error) {
    toast(error.message, "error");
  }
}

function setReaderBanner(title, detail, mode = "") {
  const banner = $("#reader-banner");
  banner.className = `reader-banner ${mode}`;
  $("strong", banner).textContent = title;
  $("p", banner).textContent = detail;
}

function setAutoMode(
  active,
  label = active ? "Lecture automatique" : "Lecture suspendue",
) {
  const indicator = $("#auto-mode-indicator");
  indicator.classList.toggle("active", active);
  indicator.lastChild.textContent = label;
  const button = $("#auto-read-toggle");
  button.innerHTML = active
    ? '<i data-lucide="pause"></i><span>Suspendre</span>'
    : '<i data-lucide="play"></i><span>Reprendre</span>';
  icons();
}

function stopAutoReading(disable = true) {
  state.readerStream?.close();
  state.readerStream = null;
  state.readerStreamKey = "";
  for (const timer of state.visualTagTimers.values()) clearTimeout(timer);
  state.visualTagTimers.clear();
  state.visualTags.clear();
  if (disable) {
    state.autoReadEnabled = false;
    setAutoMode(false);
    setReaderBanner(
      "Lecture suspendue",
      "Cliquez sur Reprendre pour surveiller le lecteur.",
      "paused",
    );
  }
}

function startAutoReading(force = false) {
  if (force) state.autoReadEnabled = true;
  if (
    !state.autoReadEnabled ||
    state.registrationOpen ||
    state.activeView !== "station"
  )
    return;
  const connection = getConnection();
  const streamKey = `${connection.type}:${connection.endpoint || ""}`;
  if (state.readerStream && state.readerStreamKey === streamKey) return;
  state.readerStream?.close();

  const query = new URLSearchParams(connection);
  const stream = new EventSource(`/api/reader/events?${query}`);
  state.readerStream = stream;
  state.readerStreamKey = streamKey;
  setAutoMode(true);
  setReaderBanner(
    "Connexion au lecteur",
    "Ouverture de la lecture RFID continue.",
    "busy",
  );

  stream.addEventListener("snapshot", (event) => {
    if (stream !== state.readerStream) return;
    try {
      const result = JSON.parse(event.data);
      const readerInfo = result.reader || {};
      if (readerInfo.connected) {
        setReaderState(
          true,
          readerDisplayName(readerInfo.reader, connection.type),
          readerDisplayDetail(readerInfo.status, connection.type),
        );
        state.lastScanError = "";
      }
      Promise.resolve(handleScanResult(result)).catch((error) =>
        toast(error.message, "error"),
      );
    } catch {
      setReaderBanner(
        "Réponse invalide",
        "Le flux du lecteur n'a pas pu être interprété.",
        "error",
      );
    }
  });

  stream.addEventListener("reader-error", (event) => {
    if (stream !== state.readerStream) return;
    let message = "Le lecteur RFID est indisponible.";
    try {
      message = JSON.parse(event.data).error || message;
    } catch {}
    setReaderBanner("Lecteur indisponible", message, "error");
    setWriteStatus("Lecture impossible", message, "error");
    setReaderState(false, "Lecteur hors ligne", message);
    if (state.lastScanError !== message) toast(message, "error");
    state.lastScanError = message;
  });

  stream.onopen = () => {
    if (stream !== state.readerStream) return;
    setAutoMode(true);
    setReaderBanner(
      "Mode lecture actif",
      "Posez un ou plusieurs livres sur le lecteur.",
    );
  };
  stream.onerror = () => {
    if (
      stream !== state.readerStream ||
      stream.readyState !== EventSource.CLOSED
    )
      return;
    setReaderState(
      false,
      "Connexion interrompue",
      "Reconnexion au lecteur en cours",
    );
  };
}

function toggleAutoReading() {
  if (state.autoReadEnabled) stopAutoReading(true);
  else startAutoReading(true);
}

function updateTagPreview(tag) {
  $("#tag-preview").classList.remove("hidden");
  $("#scan-epc").textContent = tag.epc || "—";
  $("#scan-tid").textContent = tag.tid || "—";
  $("#scan-rssi").textContent = `${tag.rssi ?? "—"}`;
}

function resetStationDisplay() {
  state.selectedBook = null;
  state.currentTagKey = null;
  $("#tag-preview").classList.add("hidden");
  $("#unknown-panel").classList.add("hidden");
  $("#quick-register-form").classList.add("hidden");
  $("#multiple-identification").classList.add("hidden");
  const container = $("#selected-book");
  container.className = "selected-book empty";
  container.innerHTML =
    '<i data-lucide="book-dashed"></i><h3>En attente d’un livre</h3><p>La détection démarre automatiquement.</p>';
  setWriteStatus(
    "Recherche en cours",
    "Le poste surveille automatiquement la zone de lecture.",
  );
  icons();
}

function showUnknownTag(tag) {
  state.selectedBook = null;
  $("#multiple-identification").classList.add("hidden");
  const container = $("#selected-book");
  container.classList.remove("hidden");
  container.className = "selected-book";
  container.innerHTML = `<i data-lucide="circle-alert"></i><div class="selected-book-copy">
    <span class="selection-label">Tag non enregistré</span><h3>Livre inconnu</h3>
    <p>Le tag peut être associé à un livre existant ou à un nouveau livre.</p>
    <div class="selected-identifiers"><strong>TID</strong><code>${escapeHtml(tag.tid || "Non disponible")}</code></div>
  </div>`;
  $("#unknown-panel").classList.remove("hidden");
  setWriteStatus(
    "Tag inconnu",
    "Enregistrez le livre pour programmer automatiquement ce tag.",
    "error",
  );
  icons();
}

function showMultipleIdentification(tags, changed) {
  state.selectedBook = null;
  $("#selected-book").classList.add("hidden");
  $("#tag-preview").classList.add("hidden");
  $("#unknown-panel").classList.add("hidden");
  $("#quick-register-form").classList.add("hidden");
  const panel = $("#multiple-identification");
  const recognized = tags.filter((tag) => tag.book).length;
  const unknown = tags.length - recognized;
  panel.classList.remove("hidden");
  $("#multiple-count").textContent = tags.length;
  $("#multiple-title").textContent =
    `${recognized} livre${recognized > 1 ? "s" : ""} reconnu${recognized > 1 ? "s" : ""}${unknown ? ` · ${unknown} inconnu${unknown > 1 ? "s" : ""}` : ""}`;
  $("#multiple-book-list").innerHTML = tags
    .map((tag) =>
      tag.book
        ? `<div class="multiple-book-item">
        <i data-lucide="book-check"></i>
        <div><strong>${escapeHtml(tag.book.title)}</strong><small>${escapeHtml(tag.book.author || tag.book.accession)} · ${escapeHtml(tag.book.accession)}</small><code>${escapeHtml(tag.tid || tag.epc)}</code></div>
        <span class="multiple-signal">Signal<b>${tag.rssi ?? "—"}</b></span>
      </div>`
        : `<div class="multiple-book-item unknown">
        <i data-lucide="circle-alert"></i>
        <div><strong>Livre inconnu</strong><small>Aucune correspondance dans le catalogue</small><code>${escapeHtml(tag.tid || tag.epc)}</code></div>
        <span class="multiple-signal">Signal<b>${tag.rssi ?? "—"}</b></span>
      </div>`,
    )
    .join("");
  const detail = unknown
    ? `${recognized} livre(s) identifié(s), ${unknown} tag(s) sans correspondance.`
    : `Tous les ${tags.length} livres ont été identifiés.`;
  setWriteStatus(
    unknown ? "Identification partielle" : "Identification terminée",
    detail,
    unknown ? "error" : "success",
  );
  setReaderBanner(
    `${tags.length} tags détectés`,
    "La lecture multiple est active; l’écriture reste protégée.",
  );
  if (changed && !state.visualSessionAnnounced) {
    state.visualSessionAnnounced = true;
    toast(`${recognized} livre(s) reconnu(s) sur ${tags.length} tag(s).`);
  }
  icons();
}

function beginRegistration() {
  state.registrationOpen = true;
  stopAutoReading(false);
  $("#unknown-panel").classList.add("hidden");
  $("#quick-register-form").classList.remove("hidden");
  $("#quick-register-form").reset();
  $("#quick-book-fields").classList.add("hidden");
  $("#title-suggestions").classList.add("hidden");
  $("#new-title-button").classList.add("hidden");
  $("#auto-read-toggle").disabled = true;
  setAutoMode(false, "Enregistrement en cours");
  setReaderBanner(
    "Lecture mise en pause",
    "Le tag reste réservé pendant l’enregistrement.",
    "paused",
  );
  setTimeout(() => $("#quick-title").focus(), 50);
}

function cancelRegistration() {
  state.registrationOpen = false;
  $("#quick-register-form").classList.add("hidden");
  $("#unknown-panel").classList.remove("hidden");
  $("#auto-read-toggle").disabled = false;
  if (state.autoReadEnabled) startAutoReading();
}

function revealNewBookFields() {
  $("#quick-book-fields").classList.remove("hidden");
  $("#new-title-button").classList.add("hidden");
  icons();
}

async function searchQuickTitles() {
  const query = $("#quick-title").value.trim();
  const suggestions = $("#title-suggestions");
  const createButton = $("#new-title-button");
  if (query.length < 2) {
    suggestions.classList.add("hidden");
    createButton.classList.add("hidden");
    return;
  }
  try {
    const books = await api(
      `/api/books?search=${encodeURIComponent(query)}&status=tous&limit=6`,
    );
    suggestions.innerHTML = books
      .map(
        (
          book,
        ) => `<button type="button" class="title-suggestion" data-id="${book.id}" ${book.status === "encode" ? "disabled" : ""}>
      <span><strong>${escapeHtml(book.title)}</strong><small>${escapeHtml(book.author || book.accession)}</small></span>
      <span class="status-badge ${book.status}">${statusLabel(book.status)}</span>
    </button>`,
      )
      .join("");
    suggestions.classList.toggle("hidden", books.length === 0);
    suggestions.querySelectorAll("button:not(:disabled)").forEach((button) =>
      button.addEventListener("click", () => {
        const book = books.find(
          (item) => item.id === Number(button.dataset.id),
        );
        if (book) writeBookToTag(book);
      }),
    );
    createButton.innerHTML = `<i data-lucide="book-plus"></i><span>Créer « ${escapeHtml(query)} » comme nouveau livre</span>`;
    createButton.classList.remove("hidden");
    if (!books.some((book) => book.status !== "encode")) revealNewBookFields();
    icons();
  } catch (error) {
    toast(error.message, "error");
  }
}

async function writeBookToTag(book) {
  state.registrationOpen = true;
  stopAutoReading(false);
  $("#auto-read-toggle").disabled = true;
  setAutoMode(false, "Écriture en cours");
  setReaderBanner(
    "Programmation du tag",
    `Écriture de ${book.accession} et contrôle par relecture.`,
    "busy",
  );
  setWriteStatus(
    "Écriture en cours",
    `${book.title} sera associé au tag présent.`,
  );
  try {
    const result = await api(`/api/books/${book.id}/write-tag`, {
      method: "POST",
      body: JSON.stringify(getConnection()),
    });
    state.selectedBook = result.book;
    state.pendingBook = null;
    state.currentTagKey = `${result.tag.tid}:${result.tag.epc}`;
    updateTagPreview(result.tag);
    selectBook(result.book, { fromScan: true });
    $("#unknown-panel").classList.add("hidden");
    $("#quick-register-form").classList.add("hidden");
    setWriteStatus(
      "Tag écrit et vérifié",
      `${result.book.accession} · ${result.book.title}`,
      "success",
    );
    setReaderBanner(
      "Livre enregistré",
      "Retirez le livre pour traiter le suivant.",
    );
    toast(`Tag associé à ${result.book.title}.`);
    await Promise.all([loadDashboard(), loadBooks()]);
    state.registrationOpen = false;
    $("#auto-read-toggle").disabled = false;
    if (state.autoReadEnabled) setTimeout(startAutoReading, 250);
  } catch (error) {
    setWriteStatus("Écriture interrompue", error.message, "error");
    setReaderBanner(
      "Écriture impossible",
      "Corrigez le problème puis relancez l’association.",
      "error",
    );
    toast(error.message, "error");
    state.registrationOpen = $("#quick-register-form").classList.contains(
      "hidden",
    )
      ? false
      : true;
    $("#auto-read-toggle").disabled = state.registrationOpen;
    if (!state.registrationOpen && state.autoReadEnabled)
      setTimeout(startAutoReading, 500);
  }
}

async function submitQuickBook(event) {
  event.preventDefault();
  const form = event.currentTarget;
  if ($("#quick-book-fields").classList.contains("hidden")) {
    revealNewBookFields();
    return;
  }
  const input = Object.fromEntries(new FormData(form));
  try {
    setWriteStatus(
      "Création du livre",
      "Génération de son numéro d’inventaire.",
    );
    const book = await api("/api/books", {
      method: "POST",
      body: JSON.stringify(input),
    });
    await writeBookToTag(book);
  } catch (error) {
    setWriteStatus("Enregistrement impossible", error.message, "error");
    toast(error.message, "error");
  }
}

function visualTagKey(tag) {
  return tag.tid || tag.epc;
}

async function renderVisualTags(notify = true) {
  if (state.registrationOpen || state.activeView !== "station") return;
  const tags = [...state.visualTags.values()];
  if (tags.length === 0) {
    if (state.presenceSessionId == null) state.visualSessionAnnounced = false;
    resetStationDisplay();
    setReaderBanner(
      "Mode lecture actif",
      "Posez un ou plusieurs livres sur le lecteur.",
    );
    return;
  }

  if (tags.length > 1) {
    const key = tags
      .map((tag) => `${tag.tid}:${tag.epc}`)
      .sort()
      .join("|");
    const changed = key !== state.currentTagKey;
    state.currentTagKey = key;
    showMultipleIdentification(tags, notify && changed);
    return;
  }

  const tag = tags[0];
  $("#multiple-identification").classList.add("hidden");
  updateTagPreview(tag);
  const key = `${tag.tid}:${tag.epc}`;
  const changed = key !== state.currentTagKey;
  state.currentTagKey = key;
  if (tag.book) {
    state.pendingBook = null;
    $("#unknown-panel").classList.add("hidden");
    $("#quick-register-form").classList.add("hidden");
    if (changed || state.selectedBook?.id !== tag.book.id) {
      selectBook(tag.book, { fromScan: true });
      if (notify && !state.visualSessionAnnounced) {
        state.visualSessionAnnounced = true;
        toast(`Livre reconnu : ${tag.book.title}`);
      }
    }
    setWriteStatus(
      "Livre reconnu",
      `${tag.book.accession} · ${tag.book.title}`,
      "success",
    );
    setReaderBanner(
      "Lecture confirmée",
      "Retirez le livre pour traiter le suivant.",
    );
    return;
  }

  showUnknownTag(tag);
  setReaderBanner(
    "Nouveau tag détecté",
    "Aucune correspondance trouvée dans le catalogue.",
  );
  if (state.pendingBook) await writeBookToTag(state.pendingBook);
}

async function handleScanResult(result) {
  if (
    Number.isInteger(result.presenceSessionId) &&
    result.presenceSessionId !== state.presenceSessionId
  ) {
    state.presenceSessionId = result.presenceSessionId;
    state.visualSessionAnnounced = false;
  }
  const incoming = new Map(
    (result.tags || [])
      .map((tag) => {
        const book = tag.book || (result.count === 1 ? result.book : null);
        const normalized = { ...tag, book };
        return [visualTagKey(normalized), normalized];
      })
      .filter(([key]) => key),
  );
  let shouldRender = incoming.size === 0 && state.visualTags.size === 0;

  for (const [key, tag] of incoming) {
    const timer = state.visualTagTimers.get(key);
    if (timer) clearTimeout(timer);
    state.visualTagTimers.delete(key);
    const previous = state.visualTags.get(key);
    if (!previous || previous.book?.id !== tag.book?.id) shouldRender = true;
    state.visualTags.set(key, tag);
  }

  for (const key of state.visualTags.keys()) {
    if (incoming.has(key) || state.visualTagTimers.has(key)) continue;
    const timer = setTimeout(() => {
      state.visualTagTimers.delete(key);
      state.visualTags.delete(key);
      Promise.resolve(renderVisualTags(false)).catch((error) =>
        toast(error.message, "error"),
      );
    }, VISUAL_RELEASE_DELAY_MS);
    state.visualTagTimers.set(key, timer);
  }

  if (shouldRender) await renderVisualTags(true);
}

function bindEvents() {
  $("#auth-form").addEventListener("submit", submitAuth);
  $("#logout-button").addEventListener("click", logout);
  $$(".nav-item").forEach((button) =>
    button.addEventListener("click", () => setView(button.dataset.view)),
  );
  $$("[data-view-link]").forEach((button) =>
    button.addEventListener("click", () => setView(button.dataset.viewLink)),
  );
  $$('[data-action="new-book"]').forEach((button) =>
    button.addEventListener("click", () => openBookDialog()),
  );
  $("#menu-button").addEventListener("click", () =>
    $("#sidebar").classList.toggle("open"),
  );
  $("#connect-button").addEventListener("click", () => probeConnection());
  $("#book-form").addEventListener("submit", saveBook);
  $("#books-table").addEventListener("click", handleTableAction);
  $("#import-xlsx").addEventListener("click", () =>
    $("#xlsx-file-input").click(),
  );
  $("#xlsx-file-input").addEventListener("change", importXlsx);
  $("#load-more-books").addEventListener("click", () =>
    loadBooks({ append: true }),
  );
  $("#book-search").addEventListener("input", (event) => {
    state.bookSearch = event.target.value;
    clearTimeout(event.target.timer);
    event.target.timer = setTimeout(loadBooks, 180);
  });
  $$("#status-filter button").forEach((button) =>
    button.addEventListener("click", () => {
      state.bookStatus = button.dataset.status;
      $$("#status-filter button").forEach((item) =>
        item.classList.toggle("active", item === button),
      );
      loadBooks();
    }),
  );
  $("#auto-read-toggle").addEventListener("click", toggleAutoReading);
  $("#register-tag-button").addEventListener("click", beginRegistration);
  $("#cancel-registration").addEventListener("click", cancelRegistration);
  $("#quick-title").addEventListener("input", (event) => {
    clearTimeout(event.target.timer);
    event.target.timer = setTimeout(searchQuickTitles, 220);
  });
  $("#new-title-button").addEventListener("click", revealNewBookFields);
  $("#quick-register-form").addEventListener("submit", submitQuickBook);
  $("#refresh-history").addEventListener("click", loadHistory);
  $$("input[name=connection_type]").forEach((input) =>
    input.addEventListener("change", updateConnectionFields),
  );
  $("#refresh-devices").addEventListener("click", () => refreshDevices(true));
  $("#test-connection").addEventListener("click", () => probeConnection());
  $("#settings-form").addEventListener("submit", saveSettings);
  $("#reader-timing-form").addEventListener("submit", saveReaderTiming);
  $("#test-buzzer").addEventListener("click", testBuzzer);
  $$("input[name=beepMode]").forEach((input) =>
    input.addEventListener("change", () => {
      updateBuzzerModeFields();
      $("#bridge-compile-status").textContent = "Modifications non appliquées.";
    }),
  );
  [$("#beep-duration-ms"), $("#beep-rearm-ms")].forEach((input) =>
    input.addEventListener("input", () => {
      $("#bridge-compile-status").textContent = "Modifications non appliquées.";
    }),
  );
  $("#theme-button").addEventListener("click", () => {
    const dark = document.documentElement.dataset.theme !== "dark";
    document.documentElement.dataset.theme = dark ? "dark" : "light";
    localStorage.setItem("biblio-theme", dark ? "dark" : "light");
    $("#theme-button").innerHTML =
      `<i data-lucide="${dark ? "sun" : "moon"}"></i>`;
    icons();
  });
  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      setView("catalogue");
      $("#book-search").focus();
    }
  });
}

async function initialize() {
  if (new URLSearchParams(location.search).get("desktop") === "1")
    document.documentElement.classList.add("desktop");
  const theme = localStorage.getItem("biblio-theme") || "light";
  document.documentElement.dataset.theme = theme;
  $("#theme-button").innerHTML =
    `<i data-lucide="${theme === "dark" ? "sun" : "moon"}"></i>`;
  bindEvents();
  icons();
  try {
    const auth = await api("/api/auth/status");
    if (auth.authenticated) await activateSession(auth.user);
    else showAuth({ setupRequired: auth.setupRequired });
  } catch (error) {
    showAuth({ message: error.message });
  }
}

initialize();
