package com.bibliorfid.myscankey_flutter

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class N01CommandReplyTest {
    @Test
    fun acceptsAReplyReceivedDuringSend() {
        val replies = N01CommandReply()
        assertEquals("GpoSet:OK", replies.send("GpoSet") { replies.accept("GpoSet:OK") })
    }

    @Test
    fun waitsForRepliesBeyondTheSdkDelay() {
        val receiver = Executors.newSingleThreadScheduledExecutor()
        try {
            for (operation in listOf("AutoInvSet", "GpoSet")) {
                val replies = N01CommandReply(1000)
                assertEquals("$operation:OK", replies.send(operation) {
                    receiver.schedule({ replies.accept("$operation:OK") }, 250, TimeUnit.MILLISECONDS)
                })
            }
        } finally {
            receiver.shutdownNow()
        }
    }

    @Test
    fun unrelatedReportsCannotAcknowledgeACommand() {
        val replies = N01CommandReply(20)
        assertNull(replies.send("AutoInvSet") {
            replies.accept("Report")
            replies.accept("SyncInvStop:TIMEOUT")
            replies.accept("GpoSet:OK")
        })
    }

    @Test
    fun preservesFirmwareErrors() {
        val replies = N01CommandReply()
        assertEquals("AutoInvSet:ERR=203", replies.send("AutoInvSet") {
            replies.accept("AutoInvSet:ERR=203")
        })
        assertEquals("ERR=201", replies.send("GpoSet") { replies.accept("ERR=201") })
    }

    @Test
    fun timedOutRepliesDoNotSatisfyADifferentCommand() {
        val replies = N01CommandReply(20)
        assertNull(replies.send("AutoInvSet") {})
        replies.accept("AutoInvSet:OK")
        assertNull(replies.send("GpoSet") { replies.accept("AutoInvSet:OK") })
        assertEquals("GpoSet:OK", replies.send("GpoSet") { replies.accept("GpoSet:OK") })
    }

    @Test
    fun sendFailuresReleaseThePendingCommand() {
        val replies = N01CommandReply()
        try {
            replies.send("GpoSet") { throw IllegalStateException("Disconnected") }
        } catch (_: IllegalStateException) {
            // A subsequent command can still register and receive its own reply.
        }
        assertEquals("AutoInvSet:OK", replies.send("AutoInvSet") {
            replies.accept("AutoInvSet:OK")
        })
    }
}
