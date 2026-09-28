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

object EntityType {
    const val BOOK = "book"
    const val SUBSCRIBER = "subscriber"
}

@Serializable
data class Mutation(
    val mutationId: String,
    val operation: String,
    val entityId: String,
    val book: SyncBook? = null,
    val entityType: String = EntityType.BOOK,
    val subscriber: SyncSubscriber? = null,
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
