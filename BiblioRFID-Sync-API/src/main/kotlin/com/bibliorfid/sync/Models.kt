package com.bibliorfid.sync

import kotlinx.serialization.Serializable

@Serializable
data class SyncBook(
    val serverId: String,
    val accession: String,
    val epc: String,
    val tid: String? = null,
    val title: String,
    val author: String = "",
    val isbn: String = "",
    val publisher: String = "",
    val publicationYear: String = "",
    val category: String = "",
    val shelf: String = "",
    val notes: String = "",
    val status: String = "a_encoder",
    val createdAt: String,
    val updatedAt: String,
    val taggedAt: String? = null,
    val revision: Long = 0,
)

/** Abonné synchronisé. Son identifiant d'entité est le numéro d'abonné. */
@Serializable
data class SyncSubscriber(
    val memberNumber: String,
    val name: String,
    val email: String = "",
    val phone: String = "",
    val active: Boolean = true,
    val cardEpc: String? = null,
    val cardTid: String? = null,
    val cardTaggedAt: String? = null,
    val createdAt: String,
    val updatedAt: String,
    val revision: Long = 0,
)

/** Période d'abonnement d'un abonné (identifiant global UUID). */
@Serializable
data class SyncSubscription(
    val serverId: String,
    val memberNumber: String,
    val startsAt: String,
    val endsAt: String,
    val status: String = "active",
    val createdAt: String,
    val updatedAt: String,
    val revision: Long = 0,
)

/**
 * Emprunt d'un livre (identifiant global UUID). Le livre est désigné par son
 * `serverId`, l'abonné par son numéro.
 */
@Serializable
data class SyncLoan(
    val serverId: String,
    val bookServerId: String,
    val memberNumber: String,
    val subscriptionServerId: String? = null,
    val borrowedAt: String,
    val dueAt: String,
    val returnedAt: String? = null,
    val status: String = "active",
    val notes: String = "",
    val createdAt: String,
    val updatedAt: String,
    val revision: Long = 0,
)

/**
 * Membre du personnel (identifiant global UUID). Son badge RFID (EPC
 * « BCM » 3) est distinct des livres et des cartes d'abonné.
 */
@Serializable
data class SyncStaff(
    val serverId: String,
    val staffNumber: String,
    val name: String,
    val position: String = "",
    val email: String = "",
    val phone: String = "",
    val active: Boolean = true,
    val badgeEpc: String? = null,
    val badgeTid: String? = null,
    val badgeTaggedAt: String? = null,
    val createdAt: String,
    val updatedAt: String,
    val revision: Long = 0,
)

/**
 * Compteurs d'un portail antivol pour un jour (date locale du portail).
 * Identifiant : `<gateId>:<AAAA-MM-JJ>`. Seul le portail les écrit.
 */
@Serializable
data class SyncGateDay(
    val serverId: String,
    val gateId: String,
    val gateName: String = "",
    val day: String,
    val entries: Int = 0,
    val exits: Int = 0,
    val alarms: Int = 0,
    val updatedAt: String,
    val revision: Long = 0,
)

/** Passage d'un membre du personnel au portail (identifiant global UUID). */
@Serializable
data class SyncStaffPassage(
    val serverId: String,
    val staffServerId: String,
    val staffNumber: String = "",
    val staffName: String = "",
    /** `in` (entrée) ou `out` (sortie). */
    val direction: String,
    val passedAt: String,
    val gateId: String = "",
    val gateName: String = "",
    val createdAt: String,
    val revision: Long = 0,
)

object EntityType {
    const val BOOK = "book"
    const val SUBSCRIBER = "subscriber"
    const val SUBSCRIPTION = "subscription"
    const val LOAN = "loan"
    const val STAFF = "staff"
    const val GATE_DAY = "gate_day"
    const val STAFF_PASSAGE = "staff_passage"

    /** Ordre d'application : les références avant ce qui les utilise. */
    fun priority(type: String): Int = when (type) {
        BOOK -> 0
        SUBSCRIBER, STAFF -> 1
        SUBSCRIPTION -> 2
        LOAN, STAFF_PASSAGE, GATE_DAY -> 3
        else -> 4
    }
}

@Serializable
data class Mutation(
    val mutationId: String,
    val operation: String,
    val entityId: String,
    val book: SyncBook? = null,
    val entityType: String = EntityType.BOOK,
    val subscriber: SyncSubscriber? = null,
    val subscription: SyncSubscription? = null,
    val loan: SyncLoan? = null,
    val staff: SyncStaff? = null,
    val gateDay: SyncGateDay? = null,
    val staffPassage: SyncStaffPassage? = null,
)

@Serializable
data class PushRequest(val deviceId: String, val mutations: List<Mutation>)

@Serializable
data class PushResponse(
    val acknowledgedMutationIds: List<String>,
    val cursor: Long,
)

@Serializable
data class Change(
    val sequence: Long,
    val operation: String,
    val entityId: String,
    val entityType: String = EntityType.BOOK,
    val book: SyncBook? = null,
    val subscriber: SyncSubscriber? = null,
    val subscription: SyncSubscription? = null,
    val loan: SyncLoan? = null,
    val staff: SyncStaff? = null,
    val gateDay: SyncGateDay? = null,
    val staffPassage: SyncStaffPassage? = null,
    val deviceId: String,
    val createdAt: String,
)

@Serializable
data class PullResponse(val cursor: Long, val changes: List<Change>, val hasMore: Boolean)

@Serializable
data class DeviceRegistration(val deviceId: String, val name: String = "")

@Serializable
data class DeviceResponse(val deviceId: String, val registered: Boolean, val serverTime: String)

@Serializable
data class HealthResponse(val status: String, val service: String, val time: String)

@Serializable
data class EventSignal(val type: String = "changes", val cursor: Long)

@Serializable
data class ErrorResponse(val error: String)
