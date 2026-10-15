#include "tag_tracker.h"

TagTracker::Entry* TagTracker::find(const String& key) {
  for (size_t i = 0; i < TAG_TABLE_SIZE; i++) {
    if (table_[i].used && key.equals(table_[i].key)) return &table_[i];
  }
  return nullptr;
}

TagTracker::Entry* TagTracker::allocate(const String& key, uint32_t now) {
  Entry* slot = nullptr;
  for (size_t i = 0; i < TAG_TABLE_SIZE; i++) {
    if (!table_[i].used) { slot = &table_[i]; break; }
  }
  if (slot == nullptr) {
    // Table pleine : on sacrifie l'entree absente la plus ancienne. Un tag
    // encore present n'est jamais evince, sinon il rebiperait aussitot.
    uint32_t oldest = 0;
    for (size_t i = 0; i < TAG_TABLE_SIZE; i++) {
      if (table_[i].present) continue;
      uint32_t age = now - table_[i].lastSeen;
      if (slot == nullptr || age > oldest) { slot = &table_[i]; oldest = age; }
    }
  }
  if (slot == nullptr) return nullptr;

  *slot = Entry();
  slot->used = true;
  strncpy(slot->key, key.c_str(), sizeof(slot->key) - 1);
  slot->firstSeen = now;
  slot->lastSeen = now;
  slot->lastEmit = 0;
  return slot;
}

TagDecision TagTracker::observe(const String& key, uint32_t now) {
  TagDecision decision;
  if (key.length() == 0) return decision;

  Entry* entry = find(key);
  if (entry == nullptr) {
    entry = allocate(key, now);
    if (entry == nullptr) return decision;  // table saturee : on ignore ce tag
    decision.firstSight = true;
  }

  entry->lastSeen = now;
  entry->present = true;

  if (decision.firstSight || entry->lastEmit == 0 ||
      (now - entry->lastEmit) >= TAG_EMIT_THROTTLE_MS) {
    decision.emit = true;
    entry->lastEmit = now;
  }

  if (!entry->beepLocked) {
    entry->beepLocked = true;
    decision.notify = true;
  }
  return decision;
}

size_t TagTracker::sweep(uint32_t now) {
  size_t present = 0;
  const uint32_t released = TAG_PRESENCE_TIMEOUT_MS + TAG_VISUAL_RELEASE_MS;
  for (size_t i = 0; i < TAG_TABLE_SIZE; i++) {
    Entry& entry = table_[i];
    if (!entry.used) continue;
    uint32_t silence = now - entry.lastSeen;
    if (entry.present && silence >= TAG_PRESENCE_TIMEOUT_MS) entry.present = false;
    if (entry.present) { present++; continue; }
    // Le compteur de rearmement ne demarre qu'apres la disparition confirmee
    // et l'anti-rebond visuel.
    if (silence >= released + timing_.rearmDelayMs) entry = Entry();
  }
  return present;
}

size_t TagTracker::presentCount() const {
  size_t present = 0;
  for (size_t i = 0; i < TAG_TABLE_SIZE; i++) {
    if (table_[i].used && table_[i].present) present++;
  }
  return present;
}

void TagTracker::clear() {
  for (size_t i = 0; i < TAG_TABLE_SIZE; i++) table_[i] = Entry();
}
