/**
 * Une recherche par presence, pas par mesure RFID : le flux envoie le meme
 * tag plusieurs fois par seconde. Les reponses ne survivent ni au retrait
 * du tag ni a une nouvelle session de lecture.
 */
export class StationCatalogue {
  constructor({ lookup, changed }) {
    this.lookup = lookup;
    this.changed = changed;
    this.entries = new Map();
  }

  key(tag) {
    return JSON.stringify([tag.epc || "", tag.tid || ""]);
  }

  get(tag) {
    return this.entries.get(this.key(tag));
  }

  sync(tags) {
    const candidates = tags.filter(tag => !tag.subscriber && !tag.staff
      && tag.kind !== "card" && tag.kind !== "badge"
      && (tag.tid || tag.epc));
    const present = new Set(candidates.map(tag => this.key(tag)));
    for (const [key, entry] of this.entries) {
      if (!present.has(key)) {
        entry.controller.abort();
        this.entries.delete(key);
      }
    }
    for (const tag of candidates) {
      const key = this.key(tag);
      if (this.entries.has(key)) continue;
      const entry = { tag, state: "loading", copy: null, controller: new AbortController() };
      this.entries.set(key, entry);
      const query = new URLSearchParams();
      if (tag.epc) query.set("epc", tag.epc);
      if (tag.tid) query.set("tid", tag.tid);
      Promise.resolve().then(() => this.lookup(`/api/ilms/copies/by-tag?${query}`, { signal: entry.controller.signal }))
        .then(result => {
          entry.copy = result.copy;
          entry.state = result.configured === false ? "unconfigured" : result.copy ? "found" : "unknown";
        })
        .catch(error => {
          entry.state = "error";
          entry.message = error.message;
        })
        .finally(() => {
          // Le serveur peut finir une requete deja annulee : l'identite de
          // l'entree, et pas seulement le tag, protege aussi A -> B -> A.
          if (this.entries.get(key) === entry) this.changed();
        });
    }
    return [...this.entries.values()];
  }

  reset() {
    for (const entry of this.entries.values()) entry.controller.abort();
    this.entries.clear();
  }
}
