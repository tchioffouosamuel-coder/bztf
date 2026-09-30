package com.bibliorfid.sync

import kotlinx.serialization.Serializable

/**
 * Compte d'un poste tel que remonté par son rapport. Les mots de passe
 * (empreintes et sels) ne quittent jamais l'appareil.
 */
@Serializable
data class ReportedUser(
    val localId: Long,
    val name: String,
    val email: String,
    val role: String = "operateur",
    val active: Boolean = true,
    val createdAt: String,
    val updatedAt: String,
)

/** Entrée du journal d'activité d'un poste (lecture, encodage, prêt…). */
@Serializable
data class ReportedActivity(
    val localId: Long,
    val type: String,
    val result: String = "",
    val message: String = "",
    val epc: String? = null,
    val tid: String? = null,
    val bookServerId: String? = null,
    val createdAt: String,
)

/**
 * Rapport périodique d'un appareil : description, liste complète de ses
 * comptes (instantané) et entrées d'activité nouvelles depuis le dernier
 * rapport accepté.
 */
@Serializable
data class DeviceReport(
    val deviceId: String,
    val name: String = "",
    val platform: String = "",
    val appVersion: String = "",
    val users: List<ReportedUser>? = null,
    val activity: List<ReportedActivity> = emptyList(),
)

@Serializable
data class DeviceReportResponse(
    val usersStored: Int,
    /** Plus grand `localId` d'activité enregistré : reprise du prochain envoi. */
    val activityAcknowledgedUntil: Long?,
)

@Serializable
data class DeviceView(
    val deviceId: String,
    val name: String,
    val platform: String?,
    val appVersion: String?,
    val lastSeenAt: String,
    val lastReportAt: String?,
    val userCount: Int,
    val activityCount: Int,
    val changeCount: Int,
)

@Serializable
data class UserAccountView(
    val deviceId: String,
    val deviceName: String,
    val localId: Long,
    val name: String,
    val email: String,
    val role: String,
    val active: Boolean,
    val createdAt: String,
    val updatedAt: String,
    val reportedAt: String,
)

@Serializable
data class ActivityView(
    val id: Long,
    val deviceId: String,
    val deviceName: String,
    val localId: Long,
    val type: String,
    val result: String,
    val message: String,
    val epc: String?,
    val tid: String?,
    val bookServerId: String?,
    val bookTitle: String?,
    val createdAt: String,
    val receivedAt: String,
)

/** Emprunt enrichi du livre et de l'abonné, pour l'exploitation externe. */
@Serializable
data class LoanView(
    val serverId: String,
    val bookServerId: String,
    val bookTitle: String?,
    val bookAccession: String?,
    val memberNumber: String,
    val subscriberName: String?,
    val subscriptionServerId: String?,
    val borrowedAt: String,
    val dueAt: String,
    val returnedAt: String?,
    val status: String,
    /** En cours et échéance dépassée. */
    val overdue: Boolean,
    /** Rendu après l'échéance. */
    val returnedLate: Boolean,
    val notes: String,
    val createdAt: String,
    val updatedAt: String,
    val revision: Long,
)

@Serializable
data class SubscriptionView(
    val serverId: String,
    val memberNumber: String,
    val subscriberName: String?,
    val startsAt: String,
    val endsAt: String,
    val status: String,
    /** Actif aujourd'hui : statut actif et date du jour dans la période. */
    val current: Boolean,
    val createdAt: String,
    val updatedAt: String,
    val revision: Long,
)

/** Entrée du journal des modifications synchronisées. */
@Serializable
data class HistoryEntry(
    val sequence: Long,
    val entityType: String,
    val entityId: String,
    val operation: String,
    val deviceId: String,
    val deviceName: String?,
    val createdAt: String,
    val change: Change,
)

@Serializable
data class StatsView(
    val books: Int,
    val booksOnLoan: Int,
    val subscribers: Int,
    val activeSubscribers: Int,
    val currentSubscriptions: Int,
    val activeLoans: Int,
    val overdueLoans: Int,
    val returnsToday: Int,
    val devices: Int,
    val generatedAt: String,
)
