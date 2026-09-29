package com.bibliorfid.myscankey_flutter

import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.gg.reader.api.dal.GClient
import com.gg.reader.api.dal.HandlerTagEpcLog
import com.gg.reader.api.dal.HandlerTcpDisconnected
import com.gg.reader.api.protocol.gx.EnumG
import com.gg.reader.api.protocol.gx.LogBaseEpcInfo
import com.gg.reader.api.protocol.gx.Message
import com.gg.reader.api.protocol.gx.MsgAppGetReaderInfo
import com.gg.reader.api.protocol.gx.MsgBaseInventoryEpc
import com.gg.reader.api.protocol.gx.MsgBaseSetPower
import com.gg.reader.api.protocol.gx.MsgBaseStop
import com.gg.reader.api.protocol.gx.ParamEpcReadTid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Hashtable
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Lecteur de bureau du poste d'emprunt, piloté par le SDK « RFID Desktop
 * Reader » (reader.jar, GClient). Indépendant du lecteur Seuic intégré :
 * canaux Flutter et fil d'exécution propres.
 */
class DeskReaderBridge(
	messenger: BinaryMessenger,
	private val mainHandler: Handler,
	private val keepScreenOn: (Boolean) -> Unit,
) {
	private val executor = Executors.newSingleThreadExecutor()
	private val tagEventAt = ConcurrentHashMap<String, Long>()
	@Volatile private var client: GClient? = null
	@Volatile private var eventSink: EventChannel.EventSink? = null

	init {
		MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(::handle)
		EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
			override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
				eventSink = events
			}

			override fun onCancel(arguments: Any?) {
				eventSink = null
			}
		})
	}

	private fun handle(call: MethodCall, result: MethodChannel.Result) {
		when (call.method) {
			"connect" -> connect(call.argument<String>("transport") ?: "tcp", call.argument<String>("endpoint") ?: "", result)
			"disconnect" -> executor.execute {
				runCatching { closeClient() }
				mainHandler.post { result.success(mapOf("connected" to false)) }
			}
			"startInventory" -> startInventory(call.argument<Int>("power"), result)
			"stopInventory" -> stopInventory(result)
			"keepScreenOn" -> {
				keepScreenOn(call.argument<Boolean>("enabled") == true)
				result.success(null)
			}
			else -> result.notImplemented()
		}
	}

	private fun connect(transport: String, endpoint: String, result: MethodChannel.Result) {
		executor.execute {
			try {
				closeClient()
				val candidate = GClient()
				val opened = when (transport) {
					"tcp" -> candidate.openTcp(endpoint, CONNECT_TIMEOUT_MS)
					"serial" -> candidate.openAndroidSerial(endpoint, CONNECT_TIMEOUT_MS)
					else -> false
				}
				if (!opened) {
					runCatching { candidate.close() }
					val hint = if (transport == "serial") " Vérifiez le port, le débit et les droits d'accès au port série." else " Vérifiez l'adresse IP, le port et le réseau."
					postError(result, "DESK_CONNECT", "Le lecteur de bureau ne répond pas sur $endpoint.$hint")
					return@execute
				}
				candidate.onTagEpcLog = HandlerTagEpcLog { _, info -> onTag(info) }
				val stop = MsgBaseStop()
				candidate.sendSynMsg(stop)
				if (!stop.succeeded()) {
					runCatching { candidate.close() }
					postError(result, "DESK_CONNECT", "Le lecteur de bureau n'a pas répondu à la commande d'arrêt${stop.detail()}.")
					return@execute
				}
				if (transport == "tcp") {
					candidate.onDisconnected = HandlerTcpDisconnected { _ -> onDisconnected(candidate) }
					candidate.setSendHeartBeat(true)
				}
				val info = MsgAppGetReaderInfo()
				candidate.sendSynMsg(info)
				client = candidate
				tagEventAt.clear()
				mainHandler.post {
					result.success(mapOf(
						"connected" to true,
						"readerId" to (if (info.succeeded()) info.readerSerialNumber.orEmpty() else ""),
						"version" to (if (info.succeeded()) info.appVersions.orEmpty() else ""),
					))
				}
			} catch (error: Throwable) {
				// UnsatisfiedLinkError ou SecurityException pour le port série.
				Log.e(TAG, "Desk reader connection failed", error)
				postError(result, "DESK_CONNECT", error.message ?: "Connexion au lecteur de bureau impossible.")
			}
		}
	}

	private fun startInventory(power: Int?, result: MethodChannel.Result) {
		if (power != null && power !in MIN_POWER..MAX_POWER) {
			result.error("INVALID_POWER", "La puissance UHF doit être comprise entre $MIN_POWER et $MAX_POWER dBm.", null)
			return
		}
		val current = client
		if (current == null) {
			result.error("READER_OFFLINE", "Connectez le lecteur de bureau avant de lancer la lecture.", null)
			return
		}
		executor.execute {
			try {
				current.sendSynMsg(MsgBaseStop())
				if (power != null) {
					val setPower = MsgBaseSetPower()
					setPower.dicPower = Hashtable<Int, Int>().apply { put(1, power) }
					current.sendSynMsg(setPower)
					if (!setPower.succeeded()) {
						postError(result, "POWER_SET", "Le lecteur de bureau a refusé la puissance de $power dBm${setPower.detail()}.")
						return@execute
					}
				}
				val inventory = MsgBaseInventoryEpc()
				inventory.antennaEnable = EnumG.AntennaNo_1
				inventory.inventoryMode = EnumG.InventoryMode_Inventory
				inventory.readTid = ParamEpcReadTid().apply {
					mode = EnumG.ParamTidMode_Auto
					len = TID_WORDS
				}
				tagEventAt.clear()
				current.sendSynMsg(inventory)
				if (!inventory.succeeded()) {
					postError(result, "INVENTORY_START", "Le lecteur de bureau a refusé le démarrage de la lecture${inventory.detail()}.")
					return@execute
				}
				mainHandler.post { result.success(mapOf("started" to true)) }
			} catch (error: Throwable) {
				postError(result, "INVENTORY_START", error.message ?: "Démarrage de la lecture impossible.")
			}
		}
	}

	private fun stopInventory(result: MethodChannel.Result) {
		val current = client
		if (current == null) {
			result.success(mapOf("stopped" to true))
			return
		}
		executor.execute {
			val stop = runCatching { MsgBaseStop().also { current.sendSynMsg(it) } }.getOrNull()
			if (stop?.succeeded() == true) {
				mainHandler.post { result.success(mapOf("stopped" to true)) }
			} else {
				postError(result, "INVENTORY_STOP", "Le lecteur de bureau a refusé l'arrêt de la lecture${stop?.detail().orEmpty()}.")
			}
		}
	}

	/** Appelé par le fil de réception du SDK : aucun traitement bloquant ici. */
	private fun onTag(info: LogBaseEpcInfo?) = runCatching {
		if (info == null || info.result != 0) return@runCatching
		val epc = info.epc.orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
		if (epc.isEmpty()) return@runCatching
		val now = SystemClock.elapsedRealtime()
		val last = tagEventAt[epc]
		if (last != null && now - last < TAG_EVENT_DEBOUNCE_MS) return@runCatching
		tagEventAt[epc] = now
		val tid = info.tid.orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
		val tag = mapOf("epc" to epc, "tid" to tid, "rssi" to info.rssi, "antenna" to info.antId)
		mainHandler.post { eventSink?.success(tag) }
	}

	private fun onDisconnected(disconnected: GClient) {
		runCatching { executor.execute {
			if (client !== disconnected) return@execute
			client = null
			runCatching { disconnected.close() }
			mainHandler.post { eventSink?.error("DESK_DISCONNECTED", "Connexion au lecteur de bureau perdue.", null) }
		} }
	}

	private fun closeClient() {
		val current = client ?: return
		client = null
		runCatching { current.sendSynMsg(MsgBaseStop(), CLOSE_TIMEOUT_MS) }
		runCatching { current.close() }
		tagEventAt.clear()
	}

	private fun Message.succeeded(): Boolean = rtCode.toInt() == 0

	private fun Message.detail(): String {
		val message = rtMsg.orEmpty().trim()
		return if (message.isEmpty()) " (code ${rtCode.toInt()})" else " ($message)"
	}

	private fun postError(result: MethodChannel.Result, code: String, message: String) {
		mainHandler.post { result.error(code, message, null) }
	}

	fun dispose() {
		executor.execute { closeClient() }
		executor.shutdown()
	}

	private companion object {
		const val TAG = "BiblioDeskReader"
		const val METHOD_CHANNEL = "com.bibliorfid.myscankey_flutter/desk-reader"
		const val EVENT_CHANNEL = "com.bibliorfid.myscankey_flutter/desk-reader-events"
		const val CONNECT_TIMEOUT_MS = 3000
		const val CLOSE_TIMEOUT_MS = 800
		const val MIN_POWER = 5
		const val MAX_POWER = 33
		const val TID_WORDS = 6
		const val TAG_EVENT_DEBOUNCE_MS = 300L
	}
}
