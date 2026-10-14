package com.bibliorfid.myscankey_flutter

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Waits for the current command's reply without blocking the receiver thread. */
internal class N01CommandReply(private val timeoutMs: Long = 2000) {
    private class Pending(val operation: String) {
        val received = CountDownLatch(1)
        @Volatile var response: String? = null
    }

    @Volatile private var pending: Pending? = null

    @Synchronized
    fun send(operation: String, send: () -> Unit): String? {
        val command = Pending(operation)
        pending = command
        try {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
            send()
            command.received.await(
                (deadline - System.nanoTime()).coerceAtLeast(0),
                TimeUnit.NANOSECONDS,
            )
            return command.response
        } finally {
            pending = null
        }
    }

    fun accept(response: String) {
        val command = pending ?: return
        val operation = response.substringBefore(':').substringBefore(' ')
        if (operation != command.operation && !response.startsWith("ERR=")) return
        command.response = response
        command.received.countDown()
    }
}
