import createElement from "/vendor/lucide/createElement.js";
import Activity from "/vendor/lucide/icons/activity.js";
import AppWindow from "/vendor/lucide/icons/app-window.js";
import ArrowRight from "/vendor/lucide/icons/arrow-right.js";
import BadgeCheck from "/vendor/lucide/icons/badge-check.js";
import BadgeMinus from "/vendor/lucide/icons/badge-minus.js";
import BookCheck from "/vendor/lucide/icons/book-check.js";
import BookCopy from "/vendor/lucide/icons/book-copy.js";
import BookDashed from "/vendor/lucide/icons/book-dashed.js";
import BookOpen from "/vendor/lucide/icons/book-open.js";
import BookPlus from "/vendor/lucide/icons/book-plus.js";
import Cable from "/vendor/lucide/icons/cable.js";
import Camera from "/vendor/lucide/icons/camera.js";
import CalendarPlus from "/vendor/lucide/icons/calendar-plus.js";
import CircleAlert from "/vendor/lucide/icons/circle-alert.js";
import CircleCheck from "/vendor/lucide/icons/circle-check.js";
import CircleX from "/vendor/lucide/icons/circle-x.js";
import Cloud from "/vendor/lucide/icons/cloud.js";
import Cpu from "/vendor/lucide/icons/cpu.js";
import Clock3 from "/vendor/lucide/icons/clock-3.js";
import Download from "/vendor/lucide/icons/download.js";
import FlaskConical from "/vendor/lucide/icons/flask-conical.js";
import HandHelping from "/vendor/lucide/icons/hand-helping.js";
import HistoryIcon from "/vendor/lucide/icons/history.js";
import DoorOpen from "/vendor/lucide/icons/door-open.js";
import IdCard from "/vendor/lucide/icons/id-card.js";
import ImagePlus from "/vendor/lucide/icons/image-plus.js";
import IdCardLanyard from "/vendor/lucide/icons/id-card-lanyard.js";
import Inbox from "/vendor/lucide/icons/inbox.js";
import Layers from "/vendor/lucide/icons/layers.js";
import LayoutDashboard from "/vendor/lucide/icons/layout-dashboard.js";
import Library from "/vendor/lucide/icons/library.js";
import LibraryBig from "/vendor/lucide/icons/library-big.js";
import LogIn from "/vendor/lucide/icons/log-in.js";
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
import ScanText from "/vendor/lucide/icons/scan-text.js";
import Search from "/vendor/lucide/icons/search.js";
import Settings2 from "/vendor/lucide/icons/settings-2.js";
import ShieldCheck from "/vendor/lucide/icons/shield-check.js";
import Sparkles from "/vendor/lucide/icons/sparkles.js";
import Siren from "/vendor/lucide/icons/siren.js";
import Sun from "/vendor/lucide/icons/sun.js";
import Trash2 from "/vendor/lucide/icons/trash-2.js";
import TriangleAlert from "/vendor/lucide/icons/triangle-alert.js";
import Undo2 from "/vendor/lucide/icons/undo-2.js";
import Upload from "/vendor/lucide/icons/upload.js";
import Usb from "/vendor/lucide/icons/usb.js";
import UserPen from "/vendor/lucide/icons/user-pen.js";
import UserPlus from "/vendor/lucide/icons/user-plus.js";
import UserRound from "/vendor/lucide/icons/user-round.js";
import Users from "/vendor/lucide/icons/users.js";
import UsersRound from "/vendor/lucide/icons/users-round.js";
import WifiOff from "/vendor/lucide/icons/wifi-off.js";
import X from "/vendor/lucide/icons/x.js";
import { initCataloguing } from "/cataloguing.js";

const lucideIcons = {
  activity: Activity,
  "app-window": AppWindow,
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
  camera: Camera,
  "circle-alert": CircleAlert,
  "circle-check": CircleCheck,
  "circle-x": CircleX,
  cloud: Cloud,
  cpu: Cpu,
  "clock-3": Clock3,
  "door-open": DoorOpen,
  download: Download,
  "flask-conical": FlaskConical,
  "hand-helping": HandHelping,
  history: HistoryIcon,
  "id-card": IdCard,
  "id-card-lanyard": IdCardLanyard,
  "image-plus": ImagePlus,
  inbox: Inbox,
  layers: Layers,
  "layout-dashboard": LayoutDashboard,
  library: Library,
  "library-big": LibraryBig,
  "log-in": LogIn,
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
  "scan-text": ScanText,
  search: Search,
  "settings-2": Settings2,
  "shield-check": ShieldCheck,
  siren: Siren,
  sparkles: Sparkles,
  sun: Sun,
  "trash-2": Trash2,
  "triangle-alert": TriangleAlert,
  "undo-2": Undo2,
  upload: Upload,
  usb: Usb,
  "user-pen": UserPen,
  "user-plus": UserPlus,
  "user-round": UserRound,
  users: Users,
  "users-round": UsersRound,
  "wifi-off": WifiOff,
  x: X,
};

let cataloguing = null;

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const VISUAL_RELEASE_DELAY_MS =
  Number(globalThis.BIBLIORFID_VISUAL_RELEASE_DELAY_MS) || 800;
const BOOK_PAGE_SIZE = 200;

const state = {
  user: null,
  setupRequired: false,
  books: [],
  bookTotal: 0,
  bookStatus: "tous",
  bookSearch: "",
  selectedBookIds: new Set(),
  selectedBook: null,
  detailBook: null,
  detailLoan: null,
  subscribers: [],
  subscriberRows: [],
  subscriberFilter: "tous",
  subscriberSearch: "",
  detailSubscriber: null,
  loanRows: [],
  loanFilter: "active",
  loanSearch: "",
  subscriptionRows: [],
  subscriptionFilter: "tous",
  subscriptionSearch: "",
  staffRows: [],
  staffFilter: "tous",
  staffSearch: "",
  detailStaff: null,
  cardScanActive: false,
  cardScanTimer: null,
  cardTagKey: null,
  settings: { connection_type: "usb", connection_endpoint: "" },
  readerTiming: {
    beepMode: "controlled",
    beepDurationMs: 75,
    rearmDelayMs: 30000,
  },
  sync: null,
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
  cataloguing: ["Gestion du fonds", "Catalogage assisté"],
  subscribers: ["Lecteurs inscrits", "Abonnés"],
  subscriptions: ["Lecteurs inscrits", "Abonnements"],
  loans: ["Circulation", "Emprunts"],
  staff: ["Équipe", "Personnel"],
  gate: ["Sécurité et fréquentation", "Portail antivol"],
  station: ["Opérations RFID", "Station RFID"],
  ilms: ["Catalogue partagé", "Interface ILMS"],
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
      personnel: "id-card-lanyard",
      badge: "id-card-lanyard",
      portail: "siren",
    }[type] || "activity"
  );
}

function setView(name) {
  if (!viewMeta[name]) return;
  if (state.activeView === "station" && name !== "station")
    stopAutoReading(false);
  if (state.activeView === "cataloguing" && name !== "cataloguing")
    cataloguing?.deactivate();
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
  if (name === "subscribers") loadSubscribers();
  if (name === "subscriptions") loadSubscriptionRegister();
  if (name === "loans") loadLoans();
  if (name === "staff") loadStaff();
  if (name === "gate") loadGate();
  if (name === "station") startAutoReading();
  if (name === "history") loadHistory();
  if (name === "cataloguing") cataloguing?.activate();
  if (name === "ilms") openIlms();
  if (name === "settings") {
    loadSyncStatus(false);
    loadIlmsStatus(false);
    cataloguing?.loadSettingsForm();
  }
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
      (book) => `<tr data-id="${book.id}" class="${state.selectedBookIds.has(book.id) ? "selected" : ""}">
    <td class="select-column"><input class="selection-checkbox book-select" type="checkbox" data-id="${book.id}" aria-label="Sélectionner ${escapeHtml(book.title)}" ${state.selectedBookIds.has(book.id) ? "checked" : ""}></td>
    <td><div class="table-book"><span class="book-glyph"><i data-lucide="book-open"></i></span><div><strong>${escapeHtml(book.title)}</strong><small>${escapeHtml(book.author || "Auteur non renseigné")}</small></div></div></td>
    <td><div class="mono">${escapeHtml(book.accession)}</div><div class="cell-subtle">${escapeHtml(book.isbn || "Sans ISBN")}</div></td>
    <td>${escapeHtml(book.shelf || "—")}<div class="cell-subtle">${escapeHtml(book.category || "Non classé")}</div></td>
    <td><span class="status-badge ${book.status}">${statusLabel(book.status)}</span>${book.catalog_draft ? `<div class="cell-subtle">Brouillon de catalogage</div>` : ""}</td>
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

function renderBookSelection() {
  const visibleIds = state.books.map((book) => book.id);
  const selectedVisible = visibleIds.filter((id) =>
    state.selectedBookIds.has(id),
  ).length;
  const selectedCount = state.selectedBookIds.size;
  const selectAll = $("#select-all-books");
  selectAll.checked =
    visibleIds.length > 0 && selectedVisible === visibleIds.length;
  selectAll.indeterminate =
    selectedVisible > 0 && selectedVisible < visibleIds.length;
  selectAll.disabled = visibleIds.length === 0;
  $("#book-selection-bar").classList.toggle("hidden", selectedCount === 0);
  $("#book-selection-count").textContent = `${selectedCount} livre${selectedCount > 1 ? "s" : ""} sélectionné${selectedCount > 1 ? "s" : ""}`;
  $("#delete-selected-books").disabled = selectedCount === 0;
  $$(".book-select", $("#books-table")).forEach((checkbox) => {
    const selected = state.selectedBookIds.has(Number(checkbox.dataset.id));
    checkbox.checked = selected;
    checkbox.closest("tr").classList.toggle("selected", selected);
  });
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
    if (!append) {
      const visibleIds = new Set(state.books.map((book) => book.id));
      state.selectedBookIds = new Set(
        [...state.selectedBookIds].filter((id) => visibleIds.has(id)),
      );
    }
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
    renderBookSelection();
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
  if (!button) {
    const row = event.target.closest("tr[data-id]");
    if (row && !event.target.closest(".select-column"))
      openBookDetails(Number(row.dataset.id));
    return;
  }
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

const DETAIL_FIELDS = [
  { name: "title", label: "Titre", maxlength: 240, wide: true },
  { name: "subtitle", label: "Sous-titre", maxlength: 240, wide: true },
  { name: "author", label: "Auteur", maxlength: 240 },
  { name: "isbn", label: "ISBN", maxlength: 32 },
  { name: "publisher", label: "Éditeur", maxlength: 240 },
  { name: "publication_year", label: "Année de publication", maxlength: 4 },
  { name: "collection", label: "Collection", maxlength: 240 },
  { name: "collection_number", label: "N° de collection", maxlength: 60 },
  { name: "edition", label: "Édition", maxlength: 120 },
  { name: "page_count", label: "Pages", maxlength: 60 },
  { name: "language", label: "Langue", maxlength: 60 },
  { name: "dewey", label: "Indice Dewey", maxlength: 60 },
  { name: "category", label: "Catégorie", maxlength: 120 },
  { name: "shelf", label: "Rayon / cote", maxlength: 120 },
  { name: "subjects", label: "Vedettes matière", maxlength: 1000, wide: true },
  {
    name: "summary",
    label: "Résumé",
    maxlength: 4000,
    wide: true,
    multiline: true,
  },
  {
    name: "notes",
    label: "Notes",
    maxlength: 2000,
    wide: true,
    multiline: true,
  },
];

async function openBookDetails(id) {
  try {
    const details = await api(`/api/books/${id}/details`);
    state.detailBook = details.book;
    state.detailLoan = details.activeLoan;
    renderBookDetails();
    cataloguing?.renderCovers(details.book.id);
    const dialog = $("#book-detail-dialog");
    if (!dialog.open) dialog.showModal();
  } catch (error) {
    toast(error.message, "error");
  }
}

function renderBookDetails() {
  const book = state.detailBook;
  const loan = state.detailLoan;
  $("#book-detail-title").textContent = book.title;
  $("#book-detail-summary").innerHTML = `<span class="book-glyph"><i data-lucide="book-open"></i></span>
    <div><strong>${escapeHtml(book.author || "Auteur non renseigné")}</strong><span class="mono">${escapeHtml(book.accession)}</span></div>
    <span class="status-badge ${book.status}">${statusLabel(book.status)}</span>`;
  const editable = DETAIL_FIELDS.map((field) => {
    const value = escapeHtml(book[field.name] || "");
    const control = field.multiline
      ? `<textarea name="${field.name}" rows="3" maxlength="${field.maxlength}" placeholder="Non renseigné" readonly>${value}</textarea>`
      : `<input name="${field.name}" maxlength="${field.maxlength}" value="${value}" placeholder="Non renseigné" autocomplete="off" readonly />`;
    return `<label class="book-detail-field${field.wide ? " wide" : ""}" data-field="${field.name}" title="Double-cliquez pour modifier"><span>${field.label}</span>${control}</label>`;
  });
  const readOnly = [
    ["EPC", book.epc],
    ["TID", book.tid || "—"],
    ["Ajouté le", formatDate(book.created_at)],
    ["Encodé le", formatDate(book.tagged_at)],
  ].map(
    ([label, value]) =>
      `<div class="book-detail-field"><span>${label}</span><code>${escapeHtml(value)}</code></div>`,
  );
  $("#book-detail-fields").innerHTML = [
    `<p class="book-detail-hint">Double-cliquez sur une information pour la modifier.</p>`,
    ...editable,
    ...readOnly,
  ].join("");

  const loanSummary = $("#book-loan-summary");
  loanSummary.classList.toggle("hidden", !loan);
  if (loan) {
    const overdue = new Date(loan.due_at) < new Date();
    const contact = [loan.subscriber_phone, loan.subscriber_email]
      .filter(Boolean)
      .map(escapeHtml)
      .join(" · ");
    loanSummary.innerHTML = `<i data-lucide="user-round"></i><div>
      <strong>Emprunté par ${escapeHtml(loan.subscriber_name)} (${escapeHtml(loan.member_number)})</strong>
      <span>Depuis le ${formatDate(loan.borrowed_at, false)} · ${overdue ? "en retard, attendu" : "retour prévu"} le ${formatDate(loan.due_at, false)}${contact ? ` · ${contact}` : ""}</span>
    </div>`;
  }
  $("#detail-borrow-book").classList.toggle("hidden", Boolean(loan));
  $("#detail-return-book").classList.toggle("hidden", !loan);
  $("#save-book-details").classList.add("hidden");
  icons();
}

function editBookDetailField(event) {
  const field = event.target.closest(".book-detail-field[data-field]");
  if (!field) return;
  const control = $("input, textarea", field);
  control.readOnly = false;
  field.classList.add("editing");
  field.removeAttribute("title");
  $("#save-book-details").classList.remove("hidden");
  control.focus();
}

async function saveBookDetails(event) {
  if (event.submitter?.value === "cancel") return;
  event.preventDefault();
  const book = state.detailBook;
  const fields = $("#book-detail-fields");
  if (!book || !$(".book-detail-field.editing", fields)) return;
  const input = Object.fromEntries(
    DETAIL_FIELDS.map(({ name }) => [name, $(`[name="${name}"]`, fields).value]),
  );
  if (!input.title.trim()) {
    toast("Le titre est obligatoire.", "error");
    return;
  }
  const button = $("#save-book-details");
  button.disabled = true;
  try {
    state.detailBook = await api(`/api/books/${book.id}`, {
      method: "PUT",
      body: JSON.stringify(input),
    });
    renderBookDetails();
    toast("Livre mis à jour.");
    await Promise.all([loadBooks(), loadDashboard()]);
  } catch (error) {
    toast(error.message, "error");
  } finally {
    button.disabled = false;
  }
}

// SweetAlert s'affiche sous une <dialog> modale : on la masque le temps de
// la confirmation, puis on la rouvre (avec ses modifications) si besoin.
async function confirmOverDialog(dialog, options) {
  dialog.close();
  const confirmed = await confirmAction(options);
  if (!confirmed) dialog.showModal();
  return confirmed;
}

async function deleteDetailBook() {
  const book = state.detailBook;
  const dialog = $("#book-detail-dialog");
  const confirmed = await confirmOverDialog(dialog, {
    title: "Supprimer ce livre ?",
    text: `« ${book.title} » sera retiré du catalogue.`,
    confirmButtonText: "Supprimer",
    confirmButtonClass: "button danger",
  });
  if (!confirmed) return;
  try {
    await api(`/api/books/${book.id}`, { method: "DELETE" });
    state.selectedBookIds.delete(book.id);
    toast("Livre supprimé.");
    await Promise.all([loadBooks(), loadDashboard()]);
  } catch (error) {
    toast(error.message, "error");
    dialog.showModal();
  }
}

// ---------------------------------------------------------------------------
// Abonnés et abonnements

function subscriptionBadge(subscriber) {
  if (!subscriber.active)
    return { css: "indisponible", label: "Compte désactivé" };
  const ends = subscriber.subscription_ends_at;
  if (ends && new Date(ends) >= new Date())
    return { css: "encode", label: `Jusqu’au ${formatDate(ends, false)}` };
  if (subscriber.latest_subscription_status === "suspended")
    return { css: "indisponible", label: "Abonnement suspendu" };
  if (!ends && !subscriber.latest_subscription_status)
    return { css: "a_encoder", label: "Aucun abonnement" };
  return {
    css: "a_encoder",
    label: ends ? `Expiré le ${formatDate(ends, false)}` : "Abonnement expiré",
  };
}

function subscriptionStatusLabel(subscription) {
  if (subscription.status === "suspended")
    return { css: "indisponible", label: "Suspendu" };
  if (
    subscription.status === "expired" ||
    new Date(subscription.ends_at) < new Date()
  )
    return { css: "a_encoder", label: "Expiré" };
  if (new Date(subscription.starts_at) > new Date())
    return { css: "a_encoder", label: "À venir" };
  return { css: "encode", label: "Actif" };
}

function subscriberMatchesFilter(subscriber) {
  const badge = subscriptionBadge(subscriber);
  switch (state.subscriberFilter) {
    case "valides":
      return badge.css === "encode";
    case "sans":
      return subscriber.active && badge.css !== "encode";
    case "retard":
      return Number(subscriber.overdue_loans) > 0;
    case "inactifs":
      return !subscriber.active;
    default:
      return true;
  }
}

async function loadSubscribers() {
  try {
    state.subscriberRows = await api(
      `/api/subscribers?search=${encodeURIComponent(state.subscriberSearch)}`,
    );
    renderSubscribers();
  } catch (error) {
    toast(error.message, "error");
  }
}

function renderSubscribers() {
  const rows = state.subscriberRows.filter(subscriberMatchesFilter);
  $("#subscribers-count").textContent =
    `${rows.length} abonné${rows.length > 1 ? "s" : ""}`;
  $("#subscribers-empty").classList.toggle("hidden", rows.length > 0);
  $("#subscribers-table").innerHTML = rows
    .map((subscriber) => {
      const badge = subscriptionBadge(subscriber);
      const overdue = Number(subscriber.overdue_loans) || 0;
      return `<tr data-subscriber-id="${subscriber.id}">
    <td><div class="table-book"><span class="book-glyph"><i data-lucide="user-round"></i></span><div><strong>${escapeHtml(subscriber.name)}</strong><small class="mono">${escapeHtml(subscriber.member_number)}</small></div></div></td>
    <td>${escapeHtml(subscriber.phone || "—")}<div class="cell-subtle">${escapeHtml(subscriber.email || "")}</div></td>
    <td><span class="status-badge ${badge.css}">${escapeHtml(badge.label)}</span></td>
    <td>${Number(subscriber.active_loans) || 0} en cours${overdue ? `<div class="cell-subtle danger-text">${overdue} en retard</div>` : ""}</td>
    <td>${subscriber.card_tid ? `<span class="status-badge encode">Encodée</span>` : `<span class="cell-subtle">Non encodée</span>`}</td>
    <td><div class="table-actions">
      <button class="icon-button" data-subscriber-action="card" data-id="${subscriber.id}" title="Encoder la carte" aria-label="Encoder la carte"><i data-lucide="id-card"></i></button>
      <button class="icon-button" data-subscriber-action="edit" data-id="${subscriber.id}" title="Modifier" aria-label="Modifier"><i data-lucide="pencil"></i></button>
      <button class="icon-button danger" data-subscriber-action="delete" data-id="${subscriber.id}" title="Supprimer" aria-label="Supprimer"><i data-lucide="trash-2"></i></button>
    </div></td>
  </tr>`;
    })
    .join("");
  icons();
}

function openSubscriberDialog(subscriber = null) {
  const form = $("#subscriber-form");
  form.reset();
  form.elements.id.value = subscriber?.id || "";
  form.elements.member_number.value = subscriber?.member_number || "";
  form.elements.member_number.readOnly = Boolean(subscriber);
  form.elements.name.value = subscriber?.name || "";
  form.elements.phone.value = subscriber?.phone || "";
  form.elements.email.value = subscriber?.email || "";
  form.elements.active.checked = subscriber ? Boolean(subscriber.active) : true;
  $("#subscriber-active-field").classList.toggle("hidden", !subscriber);
  $("#subscriber-number-hint").classList.toggle("hidden", Boolean(subscriber));
  $("#subscriber-dialog-title").textContent = subscriber
    ? "Modifier l’abonné"
    : "Nouvel abonné";
  $("#subscriber-dialog").showModal();
  setTimeout(
    () =>
      (subscriber ? form.elements.name : form.elements.member_number).focus(),
    50,
  );
}

async function saveSubscriber(event) {
  if (event.submitter?.value === "cancel") return;
  event.preventDefault();
  const form = event.currentTarget;
  const id = form.elements.id.value;
  const input = {
    member_number: form.elements.member_number.value,
    name: form.elements.name.value,
    phone: form.elements.phone.value,
    email: form.elements.email.value,
  };
  if (id) input.active = form.elements.active.checked;
  try {
    const saved = await api(id ? `/api/subscribers/${id}` : "/api/subscribers", {
      method: id ? "PUT" : "POST",
      body: JSON.stringify(input),
    });
    $("#subscriber-dialog").close();
    toast(id ? "Abonné mis à jour." : `Abonné ${saved.member_number} créé.`);
    await loadSubscribers();
    if (state.detailSubscriber?.subscriber.id === saved.id)
      await openSubscriberDetails(saved.id);
  } catch (error) {
    toast(error.message, "error");
  }
}

async function openSubscriberDetails(id) {
  try {
    state.detailSubscriber = await api(`/api/subscribers/${id}`);
    renderSubscriberDetails();
    const dialog = $("#subscriber-detail-dialog");
    if (!dialog.open) dialog.showModal();
  } catch (error) {
    toast(error.message, "error");
  }
}

function renderSubscriberDetails() {
  const { subscriber, subscriptions, loans } = state.detailSubscriber;
  // Les abonnements arrivent triés par date de fin décroissante.
  const badge = subscriptionBadge({
    ...subscriber,
    subscription_ends_at: subscriptions.find((item) => item.status === "active")
      ?.ends_at,
    latest_subscription_status: subscriptions[0]?.status,
  });
  $("#subscriber-detail-title").textContent = subscriber.name;
  $("#subscriber-detail-summary").innerHTML = `
    <div><small>N° d’abonné</small><strong class="mono">${escapeHtml(subscriber.member_number)}</strong></div>
    <div><small>Contact</small><strong>${escapeHtml(subscriber.phone || "—")}</strong><span>${escapeHtml(subscriber.email || "")}</span></div>
    <div><small>Abonnement</small><span class="status-badge ${badge.css}">${escapeHtml(badge.label)}</span></div>
    <div><small>Carte RFID</small><strong>${subscriber.card_tid ? `Encodée le ${formatDate(subscriber.card_tagged_at, false)}` : "Non encodée"}</strong></div>`;
  $("#subscriptions-table").innerHTML = subscriptions.length
    ? subscriptions
        .map((subscription) => {
          const status = subscriptionStatusLabel(subscription);
          return `<tr>
      <td>${formatDate(subscription.starts_at, false)}</td>
      <td>${formatDate(subscription.ends_at, false)}</td>
      <td><span class="status-badge ${status.css}">${status.label}</span></td>
      <td>${Number(subscription.loan_count) || 0}</td>
      <td><div class="table-actions">
        <button class="icon-button" type="button" data-subscription-action="edit" data-id="${subscription.id}" title="Modifier" aria-label="Modifier"><i data-lucide="pencil"></i></button>
        <button class="icon-button danger" type="button" data-subscription-action="delete" data-id="${subscription.id}" title="Supprimer" aria-label="Supprimer"><i data-lucide="trash-2"></i></button>
      </div></td>
    </tr>`;
        })
        .join("")
    : `<tr><td colspan="5">Aucun abonnement : l’abonné ne peut pas emprunter.</td></tr>`;
  $("#subscriber-loans-table").innerHTML = loans.length
    ? loans
        .map(
          (loan) => `<tr>
      <td>${escapeHtml(loan.book_title || "Livre supprimé")}<div class="cell-subtle mono">${escapeHtml(loan.book_accession || "")}</div></td>
      <td>${formatDate(loan.borrowed_at, false)}</td>
      <td>${formatDate(loan.due_at, false)}</td>
      <td>${loan.returned_at ? formatDate(loan.returned_at, false) : new Date(loan.due_at) < new Date() ? `<span class="status-badge indisponible">En retard</span>` : `<span class="status-badge encode">En cours</span>`}</td>
    </tr>`,
        )
        .join("")
    : `<tr><td colspan="4">Aucun emprunt.</td></tr>`;
  icons();
}

async function deleteSubscriber(subscriber, dialog = null) {
  const options = {
    title: "Supprimer cet abonné ?",
    text: `${subscriber.name} (${subscriber.member_number}) et ses abonnements seront supprimés. Un abonné ayant déjà emprunté doit être désactivé à la place.`,
    confirmButtonText: "Supprimer",
    confirmButtonClass: "button danger",
  };
  const confirmed = dialog
    ? await confirmOverDialog(dialog, options)
    : await confirmAction(options);
  if (!confirmed) return;
  try {
    await api(`/api/subscribers/${subscriber.id}`, { method: "DELETE" });
    state.detailSubscriber = null;
    toast("Abonné supprimé.");
    await loadSubscribers();
  } catch (error) {
    toast(error.message, "error");
    if (dialog) dialog.showModal();
  }
}

async function handleSubscriberTable(event) {
  const button = event.target.closest("button[data-subscriber-action]");
  const id = Number(
    button?.dataset.id || event.target.closest("tr[data-subscriber-id]")?.dataset.subscriberId,
  );
  if (!id) return;
  const subscriber = state.subscriberRows.find((row) => row.id === id);
  if (button?.dataset.subscriberAction === "edit") openSubscriberDialog(subscriber);
  else if (button?.dataset.subscriberAction === "card") encodeCardFor(subscriber);
  else if (button?.dataset.subscriberAction === "delete") deleteSubscriber(subscriber);
  else openSubscriberDetails(id);
}

/**
 * Encode la carte RFID d'un abonné existant : le serveur exige un seul tag,
 * refuse un livre ou la carte d'un autre abonné, puis vérifie l'écriture.
 */
async function encodeCardFor(subscriber, dialog = null) {
  const replacing = Boolean(subscriber.card_tid);
  const options = {
    title: replacing ? "Réencoder la carte ?" : "Encoder la carte ?",
    text: `Posez ${replacing ? "la nouvelle carte" : "une carte vierge"} de ${subscriber.name}, seule, sur le lecteur, puis confirmez.${replacing ? " L’ancienne carte ne sera plus reconnue." : ""}`,
    confirmButtonText: "Encoder",
  };
  const confirmed = dialog
    ? await confirmOverDialog(dialog, options)
    : await confirmAction(options);
  if (!confirmed) return;
  try {
    const result = await api("/api/subscribers/card", {
      method: "POST",
      body: JSON.stringify({
        member_number: subscriber.member_number,
        name: subscriber.name,
        phone: subscriber.phone,
        email: subscriber.email,
        ...getConnection(),
      }),
    });
    toast(`Carte encodée pour ${result.subscriber.name}.`);
    await loadSubscribers();
  } catch (error) {
    toast(error.message, "error");
  }
  if (dialog) await openSubscriberDetails(subscriber.id);
}

// --- Personnel et portail antivol ----------------------------------------

function isToday(value) {
  return Boolean(value) && new Date(value).toDateString() === new Date().toDateString();
}

function localDayValue(date = new Date()) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function directionBadge(direction) {
  return direction === "in"
    ? `<span class="direction-badge in"><i data-lucide="log-in"></i>Entrée</span>`
    : `<span class="direction-badge out"><i data-lucide="log-out"></i>Sortie</span>`;
}

function formatTime(value) {
  return new Intl.DateTimeFormat("fr-FR", {
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

function staffIsPresent(staff) {
  return staff.last_direction === "in" && isToday(staff.last_passed_at);
}

function staffMatchesFilter(staff) {
  switch (state.staffFilter) {
    case "presents":
      return Boolean(staff.active) && staffIsPresent(staff);
    case "sans-badge":
      return !staff.badge_tid;
    case "inactifs":
      return !staff.active;
    default:
      return true;
  }
}

async function loadStaff() {
  try {
    state.staffRows = await api(
      `/api/staff?search=${encodeURIComponent(state.staffSearch)}`,
    );
    renderStaff();
  } catch (error) {
    toast(error.message, "error");
  }
}

function renderStaff() {
  const rows = state.staffRows.filter(staffMatchesFilter);
  $("#staff-count").textContent =
    `${rows.length} membre${rows.length > 1 ? "s" : ""}`;
  $("#staff-empty").classList.toggle("hidden", rows.length > 0);
  $("#staff-table").innerHTML = rows
    .map(
      (staff) => `<tr data-staff-id="${staff.id}">
    <td><div class="table-book"><span class="book-glyph"><i data-lucide="user-round"></i></span><div><strong>${escapeHtml(staff.name)}</strong><small class="mono">${escapeHtml(staff.staff_number)}</small></div></div>${staff.active ? "" : `<div class="cell-subtle danger-text">Désactivé</div>`}</td>
    <td>${escapeHtml(staff.position || "—")}</td>
    <td>${escapeHtml(staff.phone || "—")}<div class="cell-subtle">${escapeHtml(staff.email || "")}</div></td>
    <td>${staff.badge_tid ? `<span class="status-badge encode">Encodé</span>` : `<span class="cell-subtle">Non encodé</span>`}</td>
    <td>${staff.last_passed_at ? `${directionBadge(staff.last_direction)}<div class="cell-subtle">${formatDate(staff.last_passed_at)}</div>` : `<span class="cell-subtle">Aucun</span>`}</td>
    <td><div class="table-actions">
      <button class="icon-button" data-staff-action="badge" data-id="${staff.id}" title="Encoder le badge" aria-label="Encoder le badge"><i data-lucide="id-card-lanyard"></i></button>
      <button class="icon-button" data-staff-action="edit" data-id="${staff.id}" title="Modifier" aria-label="Modifier"><i data-lucide="pencil"></i></button>
      <button class="icon-button danger" data-staff-action="delete" data-id="${staff.id}" title="Supprimer" aria-label="Supprimer"><i data-lucide="trash-2"></i></button>
    </div></td>
  </tr>`,
    )
    .join("");
  icons();
}

function openStaffDialog(staff = null) {
  const form = $("#staff-form");
  form.reset();
  form.elements.id.value = staff?.id || "";
  form.elements.staff_number.value = staff?.staff_number || "";
  form.elements.name.value = staff?.name || "";
  form.elements.position.value = staff?.position || "";
  form.elements.phone.value = staff?.phone || "";
  form.elements.email.value = staff?.email || "";
  form.elements.active.checked = staff ? Boolean(staff.active) : true;
  $("#staff-active-field").classList.toggle("hidden", !staff);
  $("#staff-dialog-title").textContent = staff
    ? `Modifier ${staff.name}`
    : "Nouveau membre";
  $("#staff-dialog").showModal();
  setTimeout(
    () => (staff ? form.elements.name : form.elements.staff_number).focus(),
    50,
  );
}

async function saveStaff(event) {
  if (event.submitter?.value === "cancel") return;
  event.preventDefault();
  const form = event.currentTarget;
  const id = form.elements.id.value;
  const input = {
    staff_number: form.elements.staff_number.value,
    name: form.elements.name.value,
    position: form.elements.position.value,
    phone: form.elements.phone.value,
    email: form.elements.email.value,
  };
  if (id) input.active = form.elements.active.checked;
  try {
    const saved = await api(id ? `/api/staff/${id}` : "/api/staff", {
      method: id ? "PUT" : "POST",
      body: JSON.stringify(input),
    });
    $("#staff-dialog").close();
    toast(id ? "Fiche mise à jour." : `${saved.name} ajouté(e) au personnel.`);
    await loadStaff();
    if (state.detailStaff?.staff.id === saved.id)
      await openStaffDetails(saved.id);
  } catch (error) {
    toast(error.message, "error");
  }
}

async function openStaffDetails(id) {
  try {
    state.detailStaff = await api(`/api/staff/${id}`);
    renderStaffDetails();
    const dialog = $("#staff-detail-dialog");
    if (!dialog.open) dialog.showModal();
  } catch (error) {
    toast(error.message, "error");
  }
}

function renderStaffDetails() {
  const { staff, passages } = state.detailStaff;
  $("#staff-detail-title").textContent = staff.name;
  $("#staff-detail-summary").innerHTML = `
    <div><small>Matricule</small><strong class="mono">${escapeHtml(staff.staff_number)}</strong></div>
    <div><small>Fonction</small><strong>${escapeHtml(staff.position || "—")}</strong>${staff.active ? "" : `<span class="danger-text">Désactivé</span>`}</div>
    <div><small>Contact</small><strong>${escapeHtml(staff.phone || "—")}</strong><span>${escapeHtml(staff.email || "")}</span></div>
    <div><small>Badge RFID</small><strong>${staff.badge_tid ? `Encodé le ${formatDate(staff.badge_tagged_at, false)}` : "Non encodé"}</strong></div>`;
  $("#staff-passages-table").innerHTML = passages.length
    ? passages
        .map(
          (passage) => `<tr>
      <td>${formatDate(passage.passed_at)}</td>
      <td>${directionBadge(passage.direction)}</td>
      <td>${escapeHtml(passage.gate_name || "Portail")}</td>
    </tr>`,
        )
        .join("")
    : `<tr><td colspan="3">Aucun passage enregistré au portail.</td></tr>`;
  $("#detail-encode-badge span").textContent = staff.badge_tid
    ? "Réencoder le badge"
    : "Encoder le badge";
  icons();
}

async function deleteStaff(staff, dialog = null) {
  const options = {
    title: "Supprimer ce membre ?",
    text: `${staff.name} (${staff.staff_number}) sera retiré du personnel. Son badge ne sera plus reconnu ; ses passages déjà enregistrés restent dans l’historique.`,
    confirmButtonText: "Supprimer",
    confirmButtonClass: "button danger",
  };
  const confirmed = dialog
    ? await confirmOverDialog(dialog, options)
    : await confirmAction(options);
  if (!confirmed) return;
  try {
    await api(`/api/staff/${staff.id}`, { method: "DELETE" });
    state.detailStaff = null;
    toast("Membre du personnel supprimé.");
    await loadStaff();
  } catch (error) {
    toast(error.message, "error");
    if (dialog) dialog.showModal();
  }
}

/**
 * Encode le badge d'un membre du personnel : le serveur exige un seul tag,
 * refuse un livre, une carte d'abonné ou le badge d'un autre, puis vérifie
 * l'écriture par relecture.
 */
async function encodeBadgeFor(staff, dialog = null) {
  const replacing = Boolean(staff.badge_tid);
  const options = {
    title: replacing ? "Réencoder le badge ?" : "Encoder le badge ?",
    text: `Posez ${replacing ? "le nouveau badge" : "un badge vierge"} de ${staff.name}, seul, sur le lecteur, puis confirmez.${replacing ? " L’ancien badge ne sera plus reconnu au portail." : ""}`,
    confirmButtonText: "Encoder",
  };
  const confirmed = dialog
    ? await confirmOverDialog(dialog, options)
    : await confirmAction(options);
  if (!confirmed) return;
  try {
    const result = await api(`/api/staff/${staff.id}/badge`, {
      method: "POST",
      body: JSON.stringify(getConnection()),
    });
    toast(`Badge encodé pour ${result.staff.name}.`);
    await loadStaff();
  } catch (error) {
    toast(error.message, "error");
  }
  if (dialog) await openStaffDetails(staff.id);
}

async function handleStaffTable(event) {
  const button = event.target.closest("button[data-staff-action]");
  const id = Number(
    button?.dataset.id || event.target.closest("tr[data-staff-id]")?.dataset.staffId,
  );
  if (!id) return;
  const staff = state.staffRows.find((row) => row.id === id);
  if (button?.dataset.staffAction === "edit") openStaffDialog(staff);
  else if (button?.dataset.staffAction === "badge") encodeBadgeFor(staff);
  else if (button?.dataset.staffAction === "delete") deleteStaff(staff);
  else openStaffDetails(id);
}

async function loadGate() {
  const input = $("#gate-day");
  if (!input.value) input.value = localDayValue();
  const day = input.value;
  try {
    const [stats, dayStats, passages] = await Promise.all([
      api("/api/gate/stats"),
      api(`/api/gate/stats?from=${day}&to=${day}`),
      api(`/api/staff-passages?day=${day}`),
    ]);
    const selected = dayStats.days[0] || { entries: 0, exits: 0, alarms: 0, gates: [] };
    const present = passages.presence.filter((row) => row.last_direction === "in");
    $("#gate-entries").textContent = selected.entries;
    $("#gate-exits").textContent = selected.exits;
    $("#gate-alarms").textContent = selected.alarms;
    $("#gate-staff-present").textContent = present.length;
    const today = day === localDayValue();
    $("#gate-subtitle").textContent = today
      ? "Aujourd’hui · synchronisé depuis les portails"
      : `Journée du ${formatDate(`${day}T12:00:00`, false)}`;
    $("#gate-passages-caption").textContent =
      `${passages.passages.length} passage${passages.passages.length > 1 ? "s" : ""} de badge`;
    $("#gate-passages-table").innerHTML = passages.passages.length
      ? passages.passages
          .map(
            (passage) => `<tr${passage.staff_id ? ` data-staff-id="${passage.staff_id}"` : ""}>
        <td class="mono">${formatTime(passage.passed_at)}</td>
        <td><strong>${escapeHtml(passage.staff_name || "Membre supprimé")}</strong><div class="cell-subtle mono">${escapeHtml(passage.staff_number)}</div></td>
        <td>${directionBadge(passage.direction)}</td>
        <td>${escapeHtml(passage.gate_name || "Portail")}</td>
      </tr>`,
          )
          .join("")
      : `<tr><td colspan="4">Aucun badge du personnel détecté ce jour-là.</td></tr>`;
    $("#gate-presence-table").innerHTML = passages.presence.length
      ? passages.presence
          .map(
            (row) => `<tr>
        <td><strong>${escapeHtml(row.staff_name || "—")}</strong><div class="cell-subtle mono">${escapeHtml(row.staff_number)}</div></td>
        <td class="mono">${formatTime(row.first_passed_at)}</td>
        <td class="mono">${formatTime(row.last_passed_at)}</td>
        <td>${row.last_direction === "in" ? `<span class="status-badge encode">Présent</span>` : `<span class="status-badge a_encoder">Parti</span>`}</td>
      </tr>`,
          )
          .join("")
      : `<tr><td colspan="4">Aucun passage.</td></tr>`;
    $("#gate-history-caption").textContent =
      `Du ${formatDate(`${stats.from}T12:00:00`, false)} au ${formatDate(`${stats.to}T12:00:00`, false)} · ${stats.totals.entries} entrées, ${stats.totals.exits} sorties, ${stats.totals.alarms} alarmes`;
    $("#gate-history-table").innerHTML = stats.days.length
      ? stats.days
          .map(
            (row) => `<tr>
        <td>${formatDate(`${row.day}T12:00:00`, false)}</td>
        <td>${row.entries}</td>
        <td>${row.exits}</td>
        <td>${row.alarms ? `<span class="danger-text">${row.alarms}</span>` : "0"}</td>
        <td class="cell-subtle">${row.gates.map((gate) => escapeHtml(gate.gateName)).join(", ")}</td>
      </tr>`,
          )
          .join("")
      : `<tr><td colspan="5">Aucune donnée : configurez un portail antivol (application Android, rôle « Portail antivol ») et la synchronisation.</td></tr>`;
    icons();
  } catch (error) {
    toast(error.message, "error");
  }
}

function loanStatusBadge(loan) {
  if (loan.returned_at)
    return new Date(loan.returned_at) > new Date(loan.due_at)
      ? { css: "a_encoder", label: "Rendu en retard" }
      : { css: "encode", label: "Rendu" };
  return new Date(loan.due_at) < new Date()
    ? { css: "indisponible", label: "En retard" }
    : { css: "encode", label: "En cours" };
}

async function loadLoans() {
  try {
    state.loanRows = await api(
      `/api/loans?filter=${encodeURIComponent(state.loanFilter)}&search=${encodeURIComponent(state.loanSearch)}`,
    );
    renderLoans();
  } catch (error) {
    toast(error.message, "error");
  }
}

function renderLoans() {
  const rows = state.loanRows;
  $("#loans-count").textContent =
    `${rows.length} emprunt${rows.length > 1 ? "s" : ""}`;
  $("#loans-empty").classList.toggle("hidden", rows.length > 0);
  $("#loan-register").innerHTML = rows
    .map((loan) => {
      const badge = loanStatusBadge(loan);
      return `<tr data-loan-id="${loan.id}">
    <td><div class="table-book"><span class="book-glyph"><i data-lucide="book-open"></i></span><div><strong>${escapeHtml(loan.book_title || "Livre supprimé")}</strong><small class="mono">${escapeHtml(loan.book_accession || "")}</small></div></div></td>
    <td>${escapeHtml(loan.subscriber_name)}<div class="cell-subtle mono">${escapeHtml(loan.member_number)}</div></td>
    <td>${formatDate(loan.borrowed_at, false)}</td>
    <td>${formatDate(loan.due_at, false)}</td>
    <td><span class="status-badge ${badge.css}">${badge.label}</span>${loan.returned_at ? `<div class="cell-subtle">le ${formatDate(loan.returned_at, false)}</div>` : ""}</td>
    <td><div class="table-actions">
      ${loan.returned_at ? "" : `<button class="icon-button" data-loan-action="return" data-id="${loan.id}" title="Enregistrer le retour" aria-label="Enregistrer le retour"><i data-lucide="undo-2"></i></button>`}
      <button class="icon-button" data-loan-action="subscriber" data-id="${loan.id}" title="Fiche abonné" aria-label="Fiche abonné"><i data-lucide="user-round"></i></button>
    </div></td>
  </tr>`;
    })
    .join("");
  icons();
}

async function handleLoanRegister(event) {
  const button = event.target.closest("button[data-loan-action]");
  if (!button) return;
  const loan = state.loanRows.find((row) => row.id === Number(button.dataset.id));
  if (!loan) return;
  if (button.dataset.loanAction === "subscriber") {
    openSubscriberDetails(loan.subscriber_id);
    return;
  }
  const confirmed = await confirmAction({
    title: "Enregistrer le retour ?",
    text: `« ${loan.book_title} » rendu par ${loan.subscriber_name}.`,
    confirmButtonText: "Retour",
  });
  if (!confirmed) return;
  try {
    await api(`/api/books/${loan.book_id}/return`, { method: "POST", body: "{}" });
    toast("Retour enregistré.");
    await Promise.all([loadLoans(), loadDashboard()]);
  } catch (error) {
    toast(error.message, "error");
  }
}

async function loadSubscriptionRegister() {
  try {
    state.subscriptionRows = await api(
      `/api/subscriptions?filter=${encodeURIComponent(state.subscriptionFilter)}&search=${encodeURIComponent(state.subscriptionSearch)}`,
    );
    renderSubscriptionRegister();
  } catch (error) {
    toast(error.message, "error");
  }
}

function renderSubscriptionRegister() {
  const rows = state.subscriptionRows;
  $("#subscriptions-count").textContent =
    `${rows.length} abonnement${rows.length > 1 ? "s" : ""}`;
  $("#subscriptions-empty").classList.toggle("hidden", rows.length > 0);
  $("#subscription-register").innerHTML = rows
    .map((subscription) => {
      const status = subscriptionStatusLabel(subscription);
      return `<tr data-subscriber-id="${subscription.subscriber_id}">
    <td><div class="table-book"><span class="book-glyph"><i data-lucide="user-round"></i></span><div><strong>${escapeHtml(subscription.subscriber_name)}</strong><small class="mono">${escapeHtml(subscription.member_number)}</small></div></div></td>
    <td>${formatDate(subscription.starts_at, false)}</td>
    <td>${formatDate(subscription.ends_at, false)}</td>
    <td><span class="status-badge ${status.css}">${status.label}</span>${subscription.subscriber_active ? "" : `<div class="cell-subtle danger-text">Compte désactivé</div>`}</td>
    <td>${Number(subscription.loan_count) || 0}</td>
    <td><div class="table-actions">
      <button class="icon-button" data-subscriber-id="${subscription.subscriber_id}" title="Fiche abonné" aria-label="Fiche abonné"><i data-lucide="pencil"></i></button>
    </div></td>
  </tr>`;
    })
    .join("");
  icons();
}

function handleSubscriptionRegister(event) {
  const id = Number(
    event.target.closest("[data-subscriber-id]")?.dataset.subscriberId,
  );
  if (id) openSubscriberDetails(id);
}

/** Recherche et filtres d'un registre : saisie temporisée, boutons exclusifs. */
function bindRegisterControls(searchSelector, filterSelector, stateKey, load) {
  $(searchSelector).addEventListener("input", (event) => {
    state[`${stateKey}Search`] = event.target.value;
    clearTimeout(event.target.timer);
    event.target.timer = setTimeout(load, 180);
  });
  $$(`${filterSelector} button`).forEach((button) =>
    button.addEventListener("click", () => {
      state[`${stateKey}Filter`] = button.dataset.filter;
      $$(`${filterSelector} button`).forEach((item) =>
        item.classList.toggle("active", item === button),
      );
      load();
    }),
  );
}

function openSubscriptionDialog(subscription = null) {
  const subscriber = state.detailSubscriber.subscriber;
  const form = $("#subscription-form");
  form.reset();
  const start = subscription ? new Date(subscription.starts_at) : new Date();
  const end = subscription
    ? new Date(subscription.ends_at)
    : new Date(start.getFullYear() + 1, start.getMonth(), start.getDate());
  form.elements.id.value = subscription?.id || "";
  form.elements.starts_at.value = localDateValue(start);
  form.elements.ends_at.value = localDateValue(end);
  form.elements.status.value = subscription?.status || "active";
  $("#subscription-dialog-eyebrow").textContent = subscriber.name;
  $("#subscription-dialog-title").textContent = subscription
    ? "Modifier l’abonnement"
    : "Nouvel abonnement";
  $("#subscription-dialog").showModal();
}

async function saveSubscription(event) {
  if (event.submitter?.value === "cancel") return;
  event.preventDefault();
  const form = event.currentTarget;
  const id = form.elements.id.value;
  const subscriberId = state.detailSubscriber.subscriber.id;
  // Du début de la première journée à la fin de la dernière, heure locale.
  const input = {
    starts_at: new Date(`${form.elements.starts_at.value}T00:00:00`).toISOString(),
    ends_at: new Date(`${form.elements.ends_at.value}T23:59:00`).toISOString(),
    status: form.elements.status.value,
  };
  try {
    await api(
      id ? `/api/subscriptions/${id}` : `/api/subscribers/${subscriberId}/subscriptions`,
      { method: id ? "PUT" : "POST", body: JSON.stringify(input) },
    );
    $("#subscription-dialog").close();
    toast(id ? "Abonnement mis à jour." : "Abonnement enregistré.");
    await Promise.all([openSubscriberDetails(subscriberId), loadSubscribers()]);
  } catch (error) {
    toast(error.message, "error");
  }
}

async function handleSubscriptionTable(event) {
  const button = event.target.closest("button[data-subscription-action]");
  if (!button) return;
  const subscription = state.detailSubscriber.subscriptions.find(
    (item) => item.id === Number(button.dataset.id),
  );
  if (button.dataset.subscriptionAction === "edit") {
    openSubscriptionDialog(subscription);
    return;
  }
  const dialog = $("#subscriber-detail-dialog");
  const confirmed = await confirmOverDialog(dialog, {
    title: "Supprimer cet abonnement ?",
    text: `Du ${formatDate(subscription.starts_at, false)} au ${formatDate(subscription.ends_at, false)}. Les emprunts déjà faits sont conservés.`,
    confirmButtonText: "Supprimer",
    confirmButtonClass: "button danger",
  });
  if (!confirmed) return;
  try {
    await api(`/api/subscriptions/${subscription.id}`, { method: "DELETE" });
    toast("Abonnement supprimé.");
    await loadSubscribers();
  } catch (error) {
    toast(error.message, "error");
  }
  await openSubscriberDetails(state.detailSubscriber.subscriber.id);
}

function localDateValue(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

async function openLoanDialog() {
  const form = $("#loan-form");
  form.reset();
  const dueDate = new Date();
  dueDate.setDate(dueDate.getDate() + 14);
  const tomorrow = new Date();
  tomorrow.setDate(tomorrow.getDate() + 1);
  form.elements.due_date.value = localDateValue(dueDate);
  form.elements.due_date.min = localDateValue(tomorrow);
  $("#loan-dialog-title").textContent = state.detailBook.title;
  $("#loan-dialog").showModal();
  startCardScan();
  setTimeout(() => form.elements.member_number.focus(), 50);
  try {
    state.subscribers = await api("/api/subscribers");
    $("#subscriber-options").innerHTML = state.subscribers
      .map(
        (subscriber) =>
          `<option value="${escapeHtml(subscriber.member_number)}">${escapeHtml(subscriber.name)}</option>`,
      )
      .join("");
  } catch (error) {
    toast(error.message, "error");
  }
}

function fillLoanSubscriber(event) {
  const number = event.target.value.trim().toUpperCase();
  const subscriber = state.subscribers.find(
    (item) => item.member_number.toUpperCase() === number,
  );
  if (!subscriber) return;
  const form = $("#loan-form");
  form.elements.name.value = subscriber.name;
  form.elements.phone.value = subscriber.phone || "";
  form.elements.email.value = subscriber.email || "";
}

async function submitLoan(event) {
  if (event.submitter?.value === "cancel") return;
  event.preventDefault();
  const book = state.detailBook;
  const input = Object.fromEntries(new FormData(event.currentTarget));
  // Retour attendu en fin de journée, heure locale.
  input.due_at = new Date(`${input.due_date}T23:59:00`).toISOString();
  delete input.due_date;
  try {
    const result = await api(`/api/books/${book.id}/borrow`, {
      method: "POST",
      body: JSON.stringify(input),
    });
    $("#loan-dialog").close();
    state.detailBook = result.book;
    state.detailLoan = result.activeLoan;
    renderBookDetails();
    toast(`Emprunt enregistré pour ${result.activeLoan.subscriber_name}.`);
    await Promise.all([loadBooks(), loadDashboard()]);
  } catch (error) {
    toast(error.message, "error");
  }
}

function setCardStatus(title, detail, type = "") {
  const element = $("#loan-card-status");
  element.className = `card-scan-status ${type}`;
  $("strong", element).textContent = title;
  $("span", element).textContent = detail;
}

// La lecture continue (flux SSE) est réservée à la station : pendant un
// emprunt, on interroge le lecteur pour reconnaître la carte de l'abonné.
function startCardScan() {
  stopCardScan();
  state.cardScanActive = true;
  state.cardTagKey = null;
  setCardStatus(
    "Carte d’abonné",
    "Posez la carte sur le lecteur pour identifier l’abonné.",
  );
  const poll = async () => {
    if (!state.cardScanActive) return;
    try {
      const snapshot = await api("/api/reader/scan", {
        method: "POST",
        body: JSON.stringify(getConnection()),
      });
      if (state.cardScanActive) applyCardSnapshot(snapshot);
    } catch (error) {
      if (state.cardScanActive)
        setCardStatus("Lecteur indisponible", error.message, "error");
    }
    if (state.cardScanActive) state.cardScanTimer = setTimeout(poll, 900);
  };
  poll();
}

function stopCardScan() {
  state.cardScanActive = false;
  clearTimeout(state.cardScanTimer);
  state.cardScanTimer = null;
}

function applyCardSnapshot(snapshot) {
  const tags = snapshot.tags || [];
  if (tags.length === 0) {
    state.cardTagKey = null;
    setCardStatus(
      "Carte d’abonné",
      "Posez la carte sur le lecteur pour identifier l’abonné.",
    );
    return;
  }
  if (tags.length > 1) {
    state.cardTagKey = null;
    setCardStatus(
      `${tags.length} tags détectés`,
      "Ne laissez que la carte de l’abonné sur le lecteur.",
      "warning",
    );
    return;
  }
  const [tag] = tags;
  const key = `${tag.tid}:${tag.epc}`;
  const changed = key !== state.cardTagKey;
  state.cardTagKey = key;
  if (tag.subscriber) {
    const { subscriber } = tag;
    if (changed) {
      const form = $("#loan-form");
      form.elements.member_number.value = subscriber.member_number;
      form.elements.name.value = subscriber.name;
      form.elements.phone.value = subscriber.phone || "";
      form.elements.email.value = subscriber.email || "";
    }
    setCardStatus(
      "Carte reconnue",
      `${subscriber.name} · ${subscriber.member_number}`,
      "success",
    );
    return;
  }
  if (tag.staff || tag.kind === "badge") {
    setCardStatus(
      "Ce tag est un badge du personnel",
      tag.staff
        ? `${tag.staff.name} · ${tag.staff.staff_number}. Posez la carte de l’abonné.`
        : "Posez la carte de l’abonné.",
      "error",
    );
    return;
  }
  if (tag.book || tag.kind === "book") {
    setCardStatus(
      "Ce tag est un livre",
      tag.book
        ? `${tag.book.accession} · ${tag.book.title}. Posez la carte de l’abonné.`
        : "Livre encodé sur un autre poste. Posez la carte de l’abonné.",
      "error",
    );
    return;
  }
  if (tag.kind === "card") {
    setCardStatus(
      "Carte non reconnue",
      "Carte encodée sur un autre poste : synchronisez ce poste.",
      "warning",
    );
    return;
  }
  setCardStatus(
    "Carte vierge ou inconnue",
    "Renseignez l’abonné puis cliquez sur « Encoder la carte ».",
    "warning",
  );
}

async function encodeSubscriberCard() {
  const form = $("#loan-form");
  if (
    !form.elements.member_number.reportValidity() ||
    !form.elements.name.reportValidity()
  )
    return;
  const button = $("#encode-subscriber-card");
  button.disabled = true;
  stopCardScan();
  setCardStatus("Encodage en cours", "Ne retirez pas la carte du lecteur.");
  try {
    const { member_number, name, phone, email } = Object.fromEntries(
      new FormData(form),
    );
    const result = await api("/api/subscribers/card", {
      method: "POST",
      body: JSON.stringify({
        member_number,
        name,
        phone,
        email,
        ...getConnection(),
      }),
    });
    form.elements.member_number.value = result.subscriber.member_number;
    toast(`Carte encodée pour ${result.subscriber.name}.`);
  } catch (error) {
    toast(error.message, "error");
  } finally {
    button.disabled = false;
    if ($("#loan-dialog").open) startCardScan();
  }
}

async function returnDetailBook() {
  const book = state.detailBook;
  const loan = state.detailLoan;
  const dialog = $("#book-detail-dialog");
  const confirmed = await confirmOverDialog(dialog, {
    title: "Enregistrer le retour ?",
    text: `« ${book.title} » rendu par ${loan.subscriber_name}.`,
    confirmButtonText: "Retour",
  });
  if (!confirmed) return;
  try {
    const result = await api(`/api/books/${book.id}/return`, {
      method: "POST",
      body: "{}",
    });
    state.detailBook = result.book;
    state.detailLoan = result.activeLoan;
    renderBookDetails();
    toast("Retour enregistré.");
    await Promise.all([loadBooks(), loadDashboard()]);
  } catch (error) {
    toast(error.message, "error");
  } finally {
    dialog.showModal();
  }
}

function handleBookSelection(event) {
  const checkbox = event.target.closest(".book-select");
  if (!checkbox) return;
  const id = Number(checkbox.dataset.id);
  if (checkbox.checked) state.selectedBookIds.add(id);
  else state.selectedBookIds.delete(id);
  renderBookSelection();
}

function toggleAllVisibleBooks(event) {
  for (const book of state.books) {
    if (event.currentTarget.checked) state.selectedBookIds.add(book.id);
    else state.selectedBookIds.delete(book.id);
  }
  renderBookSelection();
}

async function deleteSelectedBooks() {
  const ids = [...state.selectedBookIds];
  if (!ids.length) return;
  const count = ids.length;
  if (
    !(await confirmAction({
      title: `Supprimer ${count} livre${count > 1 ? "s" : ""} ?`,
      text: `Les ${count} livres sélectionnés seront retirés du catalogue.`,
      confirmButtonText: "Supprimer",
      confirmButtonClass: "button danger",
    }))
  )
    return;

  const button = $("#delete-selected-books");
  button.disabled = true;
  try {
    const result = await api("/api/books", {
      method: "DELETE",
      body: JSON.stringify({ ids }),
    });
    state.selectedBookIds.clear();
    toast(
      `${result.deleted} livre${result.deleted > 1 ? "s" : ""} supprimé${result.deleted > 1 ? "s" : ""}.`,
    );
    await Promise.all([loadBooks(), loadDashboard(), loadStationBooks()]);
  } catch (error) {
    toast(error.message, "error");
    renderBookSelection();
  } finally {
    button.disabled = state.selectedBookIds.size === 0;
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
    const [settings, readerTiming, sync] = await Promise.all([
      api("/api/settings"),
      api("/api/reader/timing"),
      api("/api/sync/status"),
    ]);
    state.settings = {
      connection_type: "usb",
      connection_endpoint: "",
      ...settings,
    };
    state.readerTiming = readerTiming;
    renderSyncStatus(sync, true);
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
    $("#beep-rearm-seconds").value = readerTiming.rearmDelayMs / 1000;
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

function renderSyncStatus(sync, updateFields = false) {
  state.sync = sync;
  const status = $("#sync-status");
  status.className = "sync-status";
  if (sync.syncing) status.classList.add("syncing");
  else if (sync.error) status.classList.add("error");
  else if (sync.connected) status.classList.add("connected");

  if (updateFields) {
    $("#sync-server-url").value = sync.serverUrl || "";
    $("#sync-device-name").value = sync.deviceName || "";
    $("#sync-api-key").value = "";
  }
  $("#sync-api-key").placeholder = sync.apiKeyConfigured
    ? "Clé déjà enregistrée"
    : "Clé API Render";

  let title = "Non configurée";
  let detail = "Aucun serveur distant configuré.";
  if (sync.syncing) {
    title = "Synchronisation en cours";
    detail = `${sync.pendingCount} modification(s) en attente.`;
  } else if (sync.error) {
    title = "Connexion impossible";
    detail = sync.error;
  } else if (sync.connected) {
    title = "Synchronisation active";
    detail = `${sync.pendingCount} en attente · dernière synchronisation ${formatDate(sync.lastSyncAt)}.`;
  } else if (sync.configured) {
    title = "Serveur configuré";
    detail = `${sync.pendingCount} modification(s) en attente d’envoi.`;
  }
  $("#sync-status-title").textContent = title;
  $("#sync-status-detail").textContent = detail;
  $("#sync-now").disabled = !sync.configured || sync.syncing;
}

async function loadSyncStatus(showError = true) {
  try {
    renderSyncStatus(await api("/api/sync/status"));
  } catch (error) {
    if (showError) toast(error.message, "error");
  }
}

/**
 * Onglet ILMS. L'interface tourne sur son propre serveur local, sur la boucle
 * locale : elle y retrouve les chemins d'API relatifs qu'elle attend. Le cadre
 * n'est chargé qu'à la première ouverture.
 */
async function openIlms() {
  const frame = $("#ilms-frame");
  let status = { available: true, gatewayUrl: "", origin: "" };
  try {
    status = await api("/api/ilms/status");
  } catch {
    // Statut indisponible : le cadre affichera lui-même le motif.
  }
  const notice = $("#ilms-notice");
  const problem = !status.origin
    ? "Le service local de l’interface ILMS n’a pas pu démarrer."
    : status.available && !status.gatewayUrl
      ? "Renseignez l’adresse de la passerelle ILMS dans Paramètres pour utiliser cet onglet."
      : "";
  notice.hidden = !problem;
  if (problem) $("#ilms-notice-text").textContent = problem;
  icons();
  if (status.origin && !frame.dataset.loaded) {
    frame.src = `${status.origin}/`;
    frame.dataset.loaded = "1";
  }
}

function renderIlmsStatus(status) {
  const configured = Boolean(status.configured);
  $("#ilms-status").classList.toggle("connected", configured);
  $("#ilms-status-title").textContent = configured
    ? "Interface disponible"
    : "Non configurée";
  $("#ilms-status-detail").textContent = !status.available
    ? "Module ILMS absent de cette version de l’application."
    : !status.origin
      ? "Le service local de l’interface ILMS n’a pas démarré."
      : !status.gatewayUrl
        ? "Aucune passerelle ILMS renseignée."
        : status.clientReady
          ? `Passerelle : ${status.gatewayUrl} · compte ${status.username}`
          : `Passerelle : ${status.gatewayUrl} · compte du poste incomplet`;
  if (status.gatewayUrl) $("#ilms-gateway-url").value = status.gatewayUrl;
  $("#ilms-username").value = status.username || "";
  $("#ilms-library-id").value = status.libraryId || "";
  // Le mot de passe enregistré n'est jamais renvoyé : le champ reste vide et
  // le laisser vide conserve celui déjà en place.
  $("#ilms-password").value = "";
  $("#ilms-password").placeholder = status.passwordSet
    ? "Inchangé si laissé vide"
    : "Mot de passe du compte";
}

async function loadIlmsStatus(showError = true) {
  try {
    renderIlmsStatus(await api("/api/ilms/status"));
  } catch (error) {
    if (showError) toast(error.message, "error");
  }
}

async function saveIlmsSettings(event) {
  event.preventDefault();
  const button = $("#save-ilms");
  button.disabled = true;
  try {
    const status = await api("/api/ilms/settings", {
      method: "PUT",
      body: JSON.stringify({
        gatewayUrl: $("#ilms-gateway-url").value,
        username: $("#ilms-username").value,
        password: $("#ilms-password").value,
        libraryId: $("#ilms-library-id").value,
      }),
    });
    renderIlmsStatus(status);
    // Le cadre doit repartir de l'adresse enregistrée.
    const frame = $("#ilms-frame");
    delete frame.dataset.loaded;
    frame.removeAttribute("src");
    toast(
      status.gatewayUrl
        ? "Passerelle ILMS enregistrée."
        : "Passerelle ILMS effacée.",
    );
  } catch (error) {
    toast(error.message, "error");
  } finally {
    button.disabled = false;
  }
}

async function saveSyncSettings(event) {
  event.preventDefault();
  const button = $("#save-sync");
  button.disabled = true;
  try {
    const result = await api("/api/sync/settings", {
      method: "PUT",
      body: JSON.stringify({
        serverUrl: $("#sync-server-url").value,
        apiKey: $("#sync-api-key").value,
        deviceName: $("#sync-device-name").value,
      }),
    });
    $("#sync-api-key").value = "";
    renderSyncStatus(result, true);
    if (result.error)
      toast(`Paramètres enregistrés. ${result.error}`, "error");
    else toast("Serveur distant connecté et catalogue synchronisé.");
  } catch (error) {
    toast(error.message, "error");
  } finally {
    button.disabled = false;
  }
}

async function runSyncNow() {
  const button = $("#sync-now");
  button.disabled = true;
  renderSyncStatus({ ...state.sync, syncing: true });
  try {
    const result = await api("/api/sync/run", {
      method: "POST",
      body: "{}",
    });
    renderSyncStatus(result);
    if (result.error) toast(result.error, "error");
    else toast("Catalogue synchronisé.");
  } catch (error) {
    toast(error.message, "error");
    await loadSyncStatus(false);
  }
}

function timingStatus(timing, prefix) {
  const mode =
    timing.beepMode === "native"
      ? "buzzer natif"
      : `impulsion ${timing.beepDurationMs} ms`;
  return `${prefix} : ${mode} · réarmement ${timing.rearmDelayMs / 1000} s.`;
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
    rearmDelayMs: Number($("#beep-rearm-seconds").value) * 1000,
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

function showSubscriberCard(subscriber) {
  state.selectedBook = null;
  $("#multiple-identification").classList.add("hidden");
  $("#unknown-panel").classList.add("hidden");
  $("#quick-register-form").classList.add("hidden");
  const container = $("#selected-book");
  container.classList.remove("hidden");
  container.className = "selected-book recognized";
  container.innerHTML = `<i data-lucide="id-card"></i><div class="selected-book-copy">
    <span class="selection-label">Carte d’abonné</span><h3>${escapeHtml(subscriber.name)}</h3>
    <p>${escapeHtml([subscriber.phone, subscriber.email].filter(Boolean).join(" · ") || "Coordonnées non renseignées")}</p>
    <div class="selected-identifiers"><strong>${escapeHtml(subscriber.member_number)}</strong></div>
  </div>`;
  setWriteStatus(
    "Carte d’abonné reconnue",
    `${subscriber.member_number} · ${subscriber.name}`,
    "success",
  );
  icons();
}

function showStaffBadge(staff) {
  state.selectedBook = null;
  $("#multiple-identification").classList.add("hidden");
  $("#unknown-panel").classList.add("hidden");
  $("#quick-register-form").classList.add("hidden");
  const container = $("#selected-book");
  container.classList.remove("hidden");
  container.className = "selected-book recognized";
  container.innerHTML = `<i data-lucide="id-card-lanyard"></i><div class="selected-book-copy">
    <span class="selection-label">Badge du personnel</span><h3>${escapeHtml(staff.name)}</h3>
    <p>${escapeHtml(staff.position || "Fonction non renseignée")}</p>
    <div class="selected-identifiers"><strong>${escapeHtml(staff.staff_number)}</strong></div>
  </div>`;
  setWriteStatus(
    "Badge du personnel reconnu",
    `${staff.staff_number} · ${staff.name}`,
    "success",
  );
  icons();
}

function foreignEraseButton(tag) {
  if (!tag.tid) return "";
  return `<div class="selected-actions"><button class="button danger" type="button" id="erase-foreign-tag"><i data-lucide="badge-minus"></i><span>Désencoder le tag</span></button></div>`;
}

/**
 * Désencode un tag encodé sur un autre poste : EPC effacé (24 zéros) après
 * contrôle du TID, écriture vérifiée par relecture. Le tag redevient vierge.
 */
function bindForeignErase(tag) {
  $("#erase-foreign-tag")?.addEventListener("click", async (event) => {
    // currentTarget n'est plus défini après l'attente de la confirmation.
    const button = event.currentTarget;
    const what =
      { card: "cette carte d’abonné", badge: "ce badge du personnel" }[
        tag.kind
      ] || "ce livre";
    if (
      !(await confirmAction({
        title: "Désencoder ce tag ?",
        text: `Ce tag vient d’un autre poste. Son EPC sera effacé et ${what} ne sera plus reconnu nulle part tant qu’il n’aura pas été réencodé. Laissez-le seul sur le lecteur.`,
        confirmButtonText: "Désencoder",
        confirmButtonClass: "button danger",
      }))
    )
      return;
    button.disabled = true;
    try {
      await api("/api/reader/erase-foreign", {
        method: "POST",
        body: JSON.stringify({ epc: tag.epc, tid: tag.tid, ...getConnection() }),
      });
      toast("Tag désencodé et vérifié : il est de nouveau vierge.");
    } catch (error) {
      toast(error.message, "error");
      button.disabled = false;
    }
  });
}

/** Tag au format carte, badge ou livre, mais inconnu de ce poste : jamais réécrit. */
function showForeignTag(tag) {
  if (tag.kind === "badge") {
    state.selectedBook = null;
    $("#multiple-identification").classList.add("hidden");
    $("#unknown-panel").classList.add("hidden");
    $("#quick-register-form").classList.add("hidden");
    const container = $("#selected-book");
    container.classList.remove("hidden");
    container.className = "selected-book";
    container.innerHTML = `<i data-lucide="id-card-lanyard"></i><div class="selected-book-copy">
    <span class="selection-label">Badge du personnel non reconnu</span><h3>Badge d’un autre poste ou désactivé</h3>
    <p>Synchronisez ce poste pour l’identifier, ou désencodez-le pour le réutiliser.</p>
    <div class="selected-identifiers"><strong>EPC</strong><code>${escapeHtml(tag.epc || "—")}</code></div>
    ${foreignEraseButton(tag)}
  </div>`;
    bindForeignErase(tag);
    setWriteStatus("Badge non reconnu", "Synchronisation nécessaire", "warning");
    setReaderBanner(
      "Badge du personnel détecté",
      "Un badge du personnel ne peut pas être encodé comme livre.",
    );
    icons();
    return;
  }
  const card = tag.kind === "card";
  state.selectedBook = null;
  $("#multiple-identification").classList.add("hidden");
  $("#unknown-panel").classList.add("hidden");
  $("#quick-register-form").classList.add("hidden");
  const container = $("#selected-book");
  container.classList.remove("hidden");
  container.className = "selected-book";
  container.innerHTML = `<i data-lucide="${card ? "id-card" : "book-dashed"}"></i><div class="selected-book-copy">
    <span class="selection-label">${card ? "Carte d’abonné" : "Livre"} non reconnu</span><h3>${card ? "Carte d’un autre poste" : "Livre d’un autre poste"}</h3>
    <p>Ce tag a été encodé ailleurs. Synchronisez ce poste pour l’identifier, ou désencodez-le pour le réutiliser.</p>
    <div class="selected-identifiers"><strong>EPC</strong><code>${escapeHtml(tag.epc || "—")}</code></div>
    ${foreignEraseButton(tag)}
  </div>`;
  bindForeignErase(tag);
  setWriteStatus(
    card ? "Carte non reconnue" : "Livre non reconnu",
    "Synchronisation nécessaire",
    "warning",
  );
  setReaderBanner(
    card ? "Carte d’abonné détectée" : "Livre détecté",
    "Tag encodé sur un autre poste, absent du catalogue local.",
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
  const cards = tags.filter((tag) => tag.subscriber || tag.staff).length;
  const unknown = tags.length - recognized - cards;
  panel.classList.remove("hidden");
  $("#multiple-count").textContent = tags.length;
  $("#multiple-title").textContent =
    `${recognized} livre${recognized > 1 ? "s" : ""} reconnu${recognized > 1 ? "s" : ""}${unknown ? ` · ${unknown} inconnu${unknown > 1 ? "s" : ""}` : ""}`;
  $("#multiple-book-list").innerHTML = tags
    .map((tag) =>
      tag.staff
        ? `<div class="multiple-book-item">
        <i data-lucide="id-card-lanyard"></i>
        <div><strong>${escapeHtml(tag.staff.name)}</strong><small>Badge du personnel · ${escapeHtml(tag.staff.staff_number)}</small><code>${escapeHtml(tag.tid || tag.epc)}</code></div>
        <span class="multiple-signal">Signal<b>${tag.rssi ?? "—"}</b></span>
      </div>`
        : tag.subscriber
        ? `<div class="multiple-book-item">
        <i data-lucide="id-card"></i>
        <div><strong>${escapeHtml(tag.subscriber.name)}</strong><small>Carte d’abonné · ${escapeHtml(tag.subscriber.member_number)}</small><code>${escapeHtml(tag.tid || tag.epc)}</code></div>
        <span class="multiple-signal">Signal<b>${tag.rssi ?? "—"}</b></span>
      </div>`
        : tag.book
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

  if (tag.subscriber) {
    showSubscriberCard(tag.subscriber);
    setReaderBanner(
      "Carte d’abonné détectée",
      "Une carte d’abonné ne peut pas être encodée comme livre.",
    );
    return;
  }

  if (tag.staff) {
    showStaffBadge(tag.staff);
    setReaderBanner(
      "Badge du personnel détecté",
      "Un badge du personnel ne peut pas être encodé comme livre.",
    );
    return;
  }

  if (tag.kind === "card" || tag.kind === "book" || tag.kind === "badge") {
    showForeignTag(tag);
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

  if (incoming.size > 0 && state.visualTags.size > 0) {
    const sameReading = [...incoming.keys()].some((key) =>
      state.visualTags.has(key),
    );
    if (!sameReading) {
      for (const timer of state.visualTagTimers.values()) clearTimeout(timer);
      state.visualTagTimers.clear();
      state.visualTags.clear();
      shouldRender = true;
    }
  }

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

/**
 * Enchaîne le catalogage et l'encodage : la station attend qu'un seul tag soit
 * posé, puis écrit la fiche qui vient d'être créée.
 */
async function encodeTagForBook(book) {
  setView("station");
  selectBook(book);
  setWriteStatus(
    "En attente du tag",
    `Posez « ${book.title} » seul sur le lecteur pour l'encoder.`,
  );
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    if (state.activeView !== "station") return;
    if (state.visualTags.size === 1) {
      await writeBookToTag(book);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  setWriteStatus(
    "Encodage à reprendre",
    `${book.accession} est au catalogue : encodez-le depuis la station dès que le tag est posé.`,
  );
}

function bindEvents() {
  cataloguing = initCataloguing({
    $,
    $$,
    api,
    toast,
    icons,
    escapeHtml,
    confirmAction,
    encodeTagForBook,
    afterBookSaved: () => Promise.all([loadDashboard(), loadBooks()]),
    goToView: setView,
  });
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
  $("#book-detail-fields").addEventListener("dblclick", editBookDetailField);
  $("#book-detail-fields").addEventListener("keydown", (event) => {
    // Entrée enregistre au lieu de déclencher le bouton de fermeture.
    if (event.key === "Enter" && event.target.matches("input")) {
      event.preventDefault();
      $("#book-detail-form").requestSubmit($("#save-book-details"));
    }
  });
  $("#book-detail-form").addEventListener("submit", saveBookDetails);
  $("#detail-delete-book").addEventListener("click", deleteDetailBook);
  $("#detail-borrow-book").addEventListener("click", openLoanDialog);
  $("#detail-return-book").addEventListener("click", returnDetailBook);
  $("#loan-form").addEventListener("submit", submitLoan);
  $("#loan-dialog").addEventListener("close", stopCardScan);
  $("#encode-subscriber-card").addEventListener("click", encodeSubscriberCard);
  $("#loan-form").elements.member_number.addEventListener(
    "change",
    fillLoanSubscriber,
  );
  $("#books-table").addEventListener("change", handleBookSelection);
  $("#select-all-books").addEventListener("change", toggleAllVisibleBooks);
  $("#delete-selected-books").addEventListener("click", deleteSelectedBooks);
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
  $("#new-subscriber").addEventListener("click", () => openSubscriberDialog());
  $("#subscriber-form").addEventListener("submit", saveSubscriber);
  $("#subscribers-table").addEventListener("click", handleSubscriberTable);
  $("#subscriber-search").addEventListener("input", (event) => {
    state.subscriberSearch = event.target.value;
    clearTimeout(event.target.timer);
    event.target.timer = setTimeout(loadSubscribers, 180);
  });
  $$("#subscriber-filter button").forEach((button) =>
    button.addEventListener("click", () => {
      state.subscriberFilter = button.dataset.filter;
      $$("#subscriber-filter button").forEach((item) =>
        item.classList.toggle("active", item === button),
      );
      renderSubscribers();
    }),
  );
  $("#new-staff").addEventListener("click", () => openStaffDialog());
  $("#staff-form").addEventListener("submit", saveStaff);
  $("#staff-table").addEventListener("click", handleStaffTable);
  bindRegisterControls("#staff-search", "#staff-filter", "staff", loadStaff);
  $("#detail-edit-staff").addEventListener("click", () =>
    openStaffDialog(state.detailStaff.staff),
  );
  $("#detail-encode-badge").addEventListener("click", () =>
    encodeBadgeFor(state.detailStaff.staff, $("#staff-detail-dialog")),
  );
  $("#detail-delete-staff").addEventListener("click", () =>
    deleteStaff(state.detailStaff.staff, $("#staff-detail-dialog")),
  );
  $("#staff-detail-dialog").addEventListener("close", () => {
    if (state.activeView === "staff") loadStaff();
  });
  $("#gate-day").addEventListener("change", loadGate);
  $("#refresh-gate").addEventListener("click", loadGate);
  $("#gate-passages-table").addEventListener("click", (event) => {
    const id = Number(event.target.closest("tr[data-staff-id]")?.dataset.staffId);
    if (id) openStaffDetails(id);
  });
  $("#new-subscription").addEventListener("click", () => openSubscriptionDialog());
  $("#subscription-form").addEventListener("submit", saveSubscription);
  $("#subscriptions-table").addEventListener("click", handleSubscriptionTable);
  $("#detail-encode-card").addEventListener("click", () =>
    encodeCardFor(
      state.detailSubscriber.subscriber,
      $("#subscriber-detail-dialog"),
    ),
  );
  // Une fiche ouverte depuis un registre peut l'avoir modifié.
  $("#subscriber-detail-dialog").addEventListener("close", () => {
    if (state.activeView === "loans") loadLoans();
    if (state.activeView === "subscriptions") loadSubscriptionRegister();
  });
  $("#loan-register").addEventListener("click", handleLoanRegister);
  $("#subscription-register").addEventListener("click", handleSubscriptionRegister);
  bindRegisterControls("#loan-search", "#loan-filter", "loan", loadLoans);
  bindRegisterControls(
    "#subscription-search",
    "#subscription-filter",
    "subscription",
    loadSubscriptionRegister,
  );
  $("#detail-edit-subscriber").addEventListener("click", () =>
    openSubscriberDialog(state.detailSubscriber.subscriber),
  );
  $("#detail-delete-subscriber").addEventListener("click", () =>
    deleteSubscriber(
      state.detailSubscriber.subscriber,
      $("#subscriber-detail-dialog"),
    ),
  );
  $$("input[name=connection_type]").forEach((input) =>
    input.addEventListener("change", updateConnectionFields),
  );
  $("#refresh-devices").addEventListener("click", () => refreshDevices(true));
  $("#test-connection").addEventListener("click", () => probeConnection());
  $("#settings-form").addEventListener("submit", saveSettings);
  $("#sync-settings-form").addEventListener("submit", saveSyncSettings);
  $("#ilms-settings-form").addEventListener("submit", saveIlmsSettings);
  $("#sync-now").addEventListener("click", runSyncNow);
  $("#reader-timing-form").addEventListener("submit", saveReaderTiming);
  $("#test-buzzer").addEventListener("click", testBuzzer);
  $$("input[name=beepMode]").forEach((input) =>
    input.addEventListener("change", () => {
      updateBuzzerModeFields();
      $("#bridge-compile-status").textContent = "Modifications non appliquées.";
    }),
  );
  [$("#beep-duration-ms"), $("#beep-rearm-seconds")].forEach((input) =>
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
