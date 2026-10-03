package com.bibliorfid.myscankey_flutter

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
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
import com.gg.reader.api.protocol.gx.MsgAppSetBeep
import com.gg.reader.api.protocol.gx.MsgAppSetBeepOnOff
import com.gg.reader.api.protocol.gx.MsgBaseGetBaseband
import com.gg.reader.api.protocol.gx.MsgBaseGetPower
import com.gg.reader.api.protocol.gx.MsgBaseGetTagLog
import com.gg.reader.api.protocol.gx.MsgBaseInventoryEpc
import com.gg.reader.api.protocol.gx.MsgBaseSetPower
import com.gg.reader.api.protocol.gx.MsgBaseStop
import com.gg.reader.api.protocol.gx.MsgBaseWriteEpc
import com.gg.reader.api.protocol.gx.ParamEpcFilter
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

	/** Début de la lecture continue et dernière lecture de chaque EPC (diagnostic). */
	@Volatile private var inventoryStartedAt = 0L
	private val lastReadAt = ConcurrentHashMap<String, Long>()

	/** Relecture de contrôle en cours : TID → EPC lus, non transmis à Flutter. */
	@Volatile private var verification: ConcurrentHashMap<String, String>? = null

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
			"beep" -> beep(result)
			"removalTone" -> {
				playRemovalTone(call.argument<String>("kind") ?: "book")
				result.success(null)
			}
			"writeEpc" -> writeEpc(call.argument<String>("epc") ?: "", call.argument<String>("tid") ?: "", result)
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
				// Buzzer piloté par l'application, comme sur le poste Windows : la
				// plaque ne sonne plus à chaque lecture, seulement sur demande.
				val buzzer = MsgAppSetBeepOnOff().apply { beepSwitch = 1 }
				runCatching { candidate.sendSynMsg(buzzer) }
				if (transport == "tcp") {
					candidate.onDisconnected = HandlerTcpDisconnected { _ -> onDisconnected(candidate) }
					candidate.setSendHeartBeat(true)
				}
				val info = MsgAppGetReaderInfo()
				candidate.sendSynMsg(info)
				logReaderSettings(candidate)
				client = candidate
				tagEventAt.clear()
				mainHandler.post {
					result.success(mapOf(
						"connected" to true,
						"readerId" to (if (info.succeeded()) info.readerSerialNumber.orEmpty() else ""),
						"version" to (if (info.succeeded()) info.appVersions.orEmpty() else ""),
						"buzzerControlled" to buzzer.succeeded(),
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
				lastReadAt.clear()
				inventoryStartedAt = SystemClock.elapsedRealtime()
				current.sendSynMsg(inventory)
				Log.i(TAG, "Inventory started: power=${power ?: "reader"} dBm, antenna 1, TID ${TID_WORDS} words, rt=${inventory.rtCode}")
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

	/** Bip unique du buzzer de la plaque (MID 0x1F : sonner, une fois). */
	private fun beep(result: MethodChannel.Result) {
		val current = client
		if (current == null) {
			result.success(false)
			return
		}
		executor.execute {
			val beep = MsgAppSetBeep().apply {
				beepStatus = 1
				beepMode = 0
			}
			val accepted = runCatching { current.sendSynMsg(beep, BEEP_TIMEOUT_MS) }.isSuccess && beep.succeeded()
			mainHandler.post { result.success(accepted) }
		}
	}

	/**
	 * Son de retrait joué par la tablette, distinct du bip de lecture :
	 * deux notes descendantes pour un livre, trois plus graves pour la carte.
	 */
	private fun playRemovalTone(kind: String) {
		val notes = if (kind == "card") CARD_REMOVED_NOTES else BOOK_REMOVED_NOTES
		Thread {
			runCatching {
				val pcm = synthesize(notes)
				val track = AudioTrack.Builder()
					.setAudioAttributes(
						AudioAttributes.Builder()
							.setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
							.setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
							.build(),
					)
					.setAudioFormat(
						AudioFormat.Builder()
							.setEncoding(AudioFormat.ENCODING_PCM_16BIT)
							.setSampleRate(TONE_SAMPLE_RATE)
							.setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
							.build(),
					)
					.setTransferMode(AudioTrack.MODE_STATIC)
					.setBufferSizeInBytes(pcm.size * 2)
					.build()
				try {
					track.write(pcm, 0, pcm.size)
					track.play()
					Thread.sleep(pcm.size * 1000L / TONE_SAMPLE_RATE + 50)
				} finally {
					track.release()
				}
			}.onFailure { Log.w(TAG, "Removal tone unavailable", it) }
		}.start()
	}

	/** Notes (fréquence en Hz, durée en ms) en sinusoïdes avec fondu court. */
	private fun synthesize(notes: List<Pair<Double, Int>>): ShortArray {
		val samples = ArrayList<Short>()
		for ((frequency, durationMs) in notes) {
			val count = TONE_SAMPLE_RATE * durationMs / 1000
			val fade = minOf(count / 4, TONE_SAMPLE_RATE * 8 / 1000)
			for (i in 0 until count) {
				val envelope = minOf(1.0, i / fade.toDouble(), (count - i) / fade.toDouble())
				val value = Math.sin(2 * Math.PI * frequency * i / TONE_SAMPLE_RATE) * envelope * 0.8
				samples.add((value * Short.MAX_VALUE).toInt().toShort())
			}
		}
		return samples.toShortArray()
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

	/**
	 * Écriture sûre, comme la démo du SDK (WriteFragment) : lecture arrêtée,
	 * PC + EPC écrits dans la zone EPC à partir du mot 1 en filtrant le TID,
	 * puis relecture filtrée sur ce TID. La lecture continue reste arrêtée.
	 */
	private fun writeEpc(epcInput: String, tidInput: String, result: MethodChannel.Result) {
		val epc = epcInput.trim().uppercase(Locale.ROOT)
		val tid = tidInput.trim().uppercase(Locale.ROOT)
		if (epc.isEmpty() || epc.length % 4 != 0 || !epc.all { it in HEX }) {
			result.error("INVALID_EPC", "L'EPC doit être hexadécimal et contenir un nombre entier de mots de 16 bits.", null)
			return
		}
		if (tid.isEmpty() || !tid.all { it in HEX }) {
			result.error("INVALID_TID", "Le TID du tag est obligatoire pour une écriture sécurisée.", null)
			return
		}
		val current = client
		if (current == null) {
			result.error("READER_OFFLINE", "Connectez le lecteur de bureau avant l'écriture.", null)
			return
		}
		executor.execute {
			try {
				current.sendSynMsg(MsgBaseStop())
				val write = MsgBaseWriteEpc()
				write.antennaEnable = EnumG.AntennaNo_1
				write.area = EnumG.WriteArea_Epc
				write.start = 1
				write.hexWriteData = "%04X".format((epc.length / 4) shl 11) + epc
				write.filter = tidFilter(tid)
				current.sendSynMsg(write)
				if (!write.succeeded()) {
					postError(result, "WRITE_FAILED", "Le lecteur de bureau a refusé l'écriture${write.detail()}.")
					return@execute
				}
				Thread.sleep(VERIFY_SETTLE_MS)
				val seen = ConcurrentHashMap<String, String>()
				verification = seen
				try {
					val inventory = MsgBaseInventoryEpc()
					inventory.antennaEnable = EnumG.AntennaNo_1
					inventory.inventoryMode = EnumG.InventoryMode_Inventory
					inventory.filter = tidFilter(tid)
					inventory.readTid = ParamEpcReadTid().apply {
						mode = EnumG.ParamTidMode_Auto
						len = TID_WORDS
					}
					current.sendSynMsg(inventory)
					if (inventory.succeeded()) {
						val deadline = SystemClock.elapsedRealtime() + VERIFY_TIMEOUT_MS
						while (SystemClock.elapsedRealtime() < deadline && seen.values.none { it == epc }) {
							Thread.sleep(50)
						}
					}
					current.sendSynMsg(MsgBaseStop())
				} finally {
					verification = null
				}
				val readBack = seen.entries.firstOrNull { (seenTid, seenEpc) -> seenEpc == epc && sameChip(seenTid, tid) }
				if (readBack == null) {
					postError(result, "WRITE_UNVERIFIED", "Écriture envoyée, mais la relecture de contrôle ne correspond pas.")
					return@execute
				}
				tagEventAt.clear()
				mainHandler.post { result.success(mapOf("verified" to true, "epc" to epc, "tid" to readBack.key)) }
			} catch (error: Throwable) {
				Log.e(TAG, "Desk reader write failed", error)
				postError(result, "WRITE_FAILED", error.message ?: "Écriture impossible.")
			}
		}
	}

	/** Réglages stockés dans le lecteur : puissance, bande de base, filtre des tags. */
	private fun logReaderSettings(client: GClient) = runCatching {
		val power = MsgBaseGetPower().also { client.sendSynMsg(it) }
		val baseband = MsgBaseGetBaseband().also { client.sendSynMsg(it) }
		val tagLog = MsgBaseGetTagLog().also { client.sendSynMsg(it) }
		Log.i(
			TAG,
			"Reader settings: power=${power.dicPower} " +
				"baseband(speed=${baseband.baseSpeed}, q=${baseband.getqValue()}, session=${baseband.session}, flag=${baseband.inventoryFlag}) " +
				"tagFilter(repeat=${tagLog.repeatedTime}x10ms, rssiThreshold=${tagLog.rssiTV})",
		)
	}.onFailure { Log.w(TAG, "Reader settings unavailable", it) }

	private fun tidFilter(tid: String) = ParamEpcFilter().apply {
		area = EnumG.ParamFilterArea_TID
		bitStart = 0
		bitLength = tid.length * 4
		hexData = tid
	}

	/** Deux lectures d'une même puce peuvent renvoyer des TID de longueurs différentes. */
	private fun sameChip(read: String, expected: String): Boolean {
		val common = minOf(read.length, expected.length)
		return read == expected || (common >= 16 && read.take(common) == expected.take(common))
	}

	/** Appelé par le fil de réception du SDK : aucun traitement bloquant ici. */
	private fun onTag(info: LogBaseEpcInfo?) = runCatching {
		if (info == null || info.result != 0) return@runCatching
		val epc = info.epc.orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
		if (epc.isEmpty()) return@runCatching
		verification?.let { seen ->
			seen[info.tid.orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)] = epc
			return@runCatching
		}
		val now = SystemClock.elapsedRealtime()
		// Diagnostic : première lecture d'un tag (ou après une absence).
		val previousRead = lastReadAt.put(epc, now)
		if (previousRead == null || now - previousRead > FIRST_READ_GAP_MS) {
			Log.i(TAG, "Tag seen: epc=$epc rssi=${info.rssi} tid=${if (info.tid.isNullOrEmpty()) "none" else "yes"} " +
				"sinceInventory=${now - inventoryStartedAt}ms gap=${previousRead?.let { now - it } ?: -1}ms")
		}
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
		const val BEEP_TIMEOUT_MS = 1000
		const val MIN_POWER = 5
		const val MAX_POWER = 33
		const val TID_WORDS = 6
		const val TAG_EVENT_DEBOUNCE_MS = 100L
		const val FIRST_READ_GAP_MS = 2000L
		const val VERIFY_SETTLE_MS = 180L
		const val VERIFY_TIMEOUT_MS = 1800L
		const val HEX = "0123456789ABCDEF"
		const val TONE_SAMPLE_RATE = 44100
		val BOOK_REMOVED_NOTES = listOf(1318.5 to 70, 880.0 to 110)
		val CARD_REMOVED_NOTES = listOf(784.0 to 90, 587.3 to 90, 392.0 to 200)
	}
}
