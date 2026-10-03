package com.bibliorfid.myscankey_flutter

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Logs de l'application (Flutter, portail, lecteur de bureau, erreurs des
 * SDK sur System.out) lus avec logcat, qui ne donne à une application que
 * ses propres lignes, et transmis à Flutter pour l'envoi au serveur.
 */
class LogBridge(messenger: BinaryMessenger, private val mainHandler: Handler) {
	@Volatile private var process: Process? = null
	@Volatile private var eventSink: EventChannel.EventSink? = null

	init {
		EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
			override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
				eventSink = events
				start()
			}

			override fun onCancel(arguments: Any?) {
				eventSink = null
				stop()
			}
		})
	}

	private fun start() {
		if (process != null) return
		val started = runCatching { ProcessBuilder(COMMAND).redirectErrorStream(true).start() }
			.onFailure { Log.w(TAG, "logcat unavailable", it) }
			.getOrNull() ?: return
		process = started
		Thread({
			runCatching {
				started.inputStream.bufferedReader().useLines { lines ->
					lines.forEach { line ->
						if (line.isNotBlank()) mainHandler.post { eventSink?.success(line) }
					}
				}
			}
			if (process === started) process = null
		}, "app-log-reader").apply { isDaemon = true }.start()
	}

	private fun stop() {
		process?.destroy()
		process = null
	}

	fun dispose() = stop()

	private companion object {
		const val TAG = "BiblioRFID"
		const val EVENT_CHANNEL = "com.bibliorfid.myscankey_flutter/app-logs"

		/** Lignes nouvelles seulement (-T 1), des seuls tags utiles. */
		val COMMAND = listOf(
			"logcat", "-v", "time", "-T", "1",
			"flutter:V", "BiblioGate:V", "BiblioDeskReader:V", "BiblioRFID:V",
			"System.out:V", "AndroidRuntime:E", "*:S",
		)
	}
}
