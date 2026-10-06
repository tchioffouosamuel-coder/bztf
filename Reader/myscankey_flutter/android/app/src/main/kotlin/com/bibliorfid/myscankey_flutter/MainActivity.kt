package com.bibliorfid.myscankey_flutter

import Interface.TagReadDataEventCallback
import Tool.BankData
import Tool.N01AntPwr
import Tool.TagBackData
import Tool.TagFilter
import ZAO_API.N01_Api
import com.seuic.uhf.UHFService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.media.AudioAttributes
import android.media.SoundPool
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class MainActivity : FlutterActivity() {
	private val methodChannelName = "com.bibliorfid.myscankey_flutter/reader"
	private val eventChannelName = "com.bibliorfid.myscankey_flutter/reader-events"
	private val keyEventChannelName = "com.bibliorfid.myscankey_flutter/rfid-key-events"
	private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
	private val mainHandler = Handler(Looper.getMainLooper())
	@Volatile private var integratedReader: UHFService? = null
	@Volatile private var networkReader: N01_Api? = null
	@Volatile private var integratedInventoryJob: ScheduledFuture<*>? = null
	@Volatile private var eventSink: EventChannel.EventSink? = null
	@Volatile private var keyEventSink: EventChannel.EventSink? = null
	@Volatile private var rfidKey: SeuicRfidKey? = null
	@Volatile private var scanSoundLoaded = false
	@Volatile private var configuredReadPower = 15
	@Volatile private var configuredWritePower = 25
	@Volatile private var activeTargetEpc: String? = null
	private var soundPool: SoundPool? = null
	private var scanSoundId = 0
	private val rfidKeyHeld = AtomicBoolean(false)
	private val lastRfidKeyPressAt = AtomicLong(0L)
	private val tidCache = ConcurrentHashMap<String, String>()
	private val tidAttemptAt = ConcurrentHashMap<String, Long>()
	/** Échecs de lecture du TID par EPC, remis à zéro à chaque lecture. */
	private val tidFailures = ConcurrentHashMap<String, Int>()
	private val tagEventAt = ConcurrentHashMap<String, Long>()
	private var deskReader: DeskReaderBridge? = null
	private var gate: GateBridge? = null
	private var heading: HeadingBridge? = null
	private var logs: LogBridge? = null
	private var barcodeScanner: BarcodeScannerBridge? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		initializeScanSound()
		barcodeScanner = BarcodeScannerBridge(
			flutterEngine.dartExecutor.binaryMessenger, applicationContext, mainHandler,
		)
		// Lecteur de bureau du poste d'emprunt : son SDK (reader.jar) ne doit
		// jamais empêcher l'application de démarrer, notamment sur un terminal
		// Seuic dont les bibliothèques système partagent des classes avec lui.
		deskReader = try {
			DeskReaderBridge(flutterEngine.dartExecutor.binaryMessenger, mainHandler) { enabled ->
				if (enabled) {
					window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
				} else {
					window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
				}
			}
		} catch (error: Throwable) {
			Log.e("BiblioRFID", "Desk reader bridge unavailable", error)
			null
		}
		logs = runCatching { LogBridge(flutterEngine.dartExecutor.binaryMessenger, mainHandler) }
			.onFailure { Log.e("BiblioRFID", "Log bridge unavailable", it) }
			.getOrNull()
		heading = runCatching { HeadingBridge(flutterEngine.dartExecutor.binaryMessenger, applicationContext) }
			.onFailure { Log.e("BiblioRFID", "Compass unavailable", it) }
			.getOrNull()
		// Portail antivol N01 : même garde, son SDK ne doit jamais bloquer le
		// démarrage de l'application.
		gate = try {
			GateBridge(flutterEngine.dartExecutor.binaryMessenger, applicationContext, mainHandler) { enabled ->
				if (enabled) {
					window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
				} else {
					window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
				}
			}
		} catch (error: Throwable) {
			Log.e("BiblioRFID", "Gate bridge unavailable", error)
			null
		}
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"connect" -> connect(call.argument<String>("transport") ?: "serial", call.argument<String>("endpoint") ?: "dev/ttyS5", result)
					"disconnect" -> disconnect(result)
					"startInventory" -> startInventory(
						call.argument<Int>("power") ?: configuredReadPower,
						call.argument<String>("targetEpc"),
						result,
					)
					"stopInventory" -> stopInventory(result)
					"resolveTid" -> resolveTid(call.argument<String>("epc") ?: "", result)
					"configurePower" -> configurePower(call.argument<Int>("readPower") ?: configuredReadPower, call.argument<Int>("writePower") ?: configuredWritePower, result)
					"playScanBeep" -> playScanBeep(result)
					"writeEpc" -> writeEpc(call.argument<String>("epc") ?: "", call.argument<String>("tid") ?: "", call.argument<String>("currentEpc") ?: "", call.argument<Int>("writePower") ?: configuredWritePower, call.argument<Int>("restorePower") ?: configuredReadPower, result)
					else -> result.notImplemented()
				}
			}
		EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					eventSink = events
				}

				override fun onCancel(arguments: Any?) {
					eventSink = null
				}
			})
		EventChannel(flutterEngine.dartExecutor.binaryMessenger, keyEventChannelName)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					keyEventSink = events
				}

				override fun onCancel(arguments: Any?) {
					keyEventSink = null
				}
			})
	}

	private fun initializeScanSound() {
		if (soundPool != null) return
		val attributes = AudioAttributes.Builder()
			.setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
			.setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
			.build()
		val pool = SoundPool.Builder()
			.setMaxStreams(1)
			.setAudioAttributes(attributes)
			.build()
		soundPool = pool
		pool.setOnLoadCompleteListener { _, sampleId, status ->
			if (sampleId == scanSoundId) scanSoundLoaded = status == 0
		}
		scanSoundId = pool.load(this, R.raw.scan_beep, 1)
	}

	private fun playScanBeep(result: MethodChannel.Result) {
		mainHandler.post {
			val pool = soundPool
			if (pool == null || !scanSoundLoaded || scanSoundId == 0) {
				result.error("SCAN_SOUND", "Le bip de lecture n'est pas encore disponible.", null)
				return@post
			}
			val streamId = pool.play(scanSoundId, 1f, 1f, 1, 0, 1f)
			if (streamId == 0) {
				result.error("SCAN_SOUND", "Le bip de lecture n'a pas pu être joué.", null)
			} else {
				result.success(null)
			}
		}
	}

	private fun registerRfidKey() {
		if (rfidKey != null || !SeuicRfidKey.isAvailable()) return
		val key = SeuicRfidKey(
			RFID_HANDLE_KEY_CODE,
			onKeyDown = down@{ keyCode ->
				if (keyCode != RFID_HANDLE_KEY_CODE) return@down
				if (barcodeScanner?.active == true) {
					rfidKeyHeld.set(false)
					barcodeScanner?.trigger(true)
					return@down
				}
				val now = SystemClock.elapsedRealtime()
				if (!rfidKeyHeld.compareAndSet(false, true)) return@down
				if (now - lastRfidKeyPressAt.get() < RFID_KEY_DEBOUNCE_MS) {
					rfidKeyHeld.set(false)
					return@down
				}
				lastRfidKeyPressAt.set(now)
				mainHandler.post {
					keyEventSink?.success(mapOf("action" to "down", "scanCode" to keyCode))
				}
			},
			onKeyUp = up@{ keyCode ->
				if (keyCode != RFID_HANDLE_KEY_CODE) return@up
				if (barcodeScanner?.active == true) {
					rfidKeyHeld.set(false)
					barcodeScanner?.trigger(false)
					return@up
				}
				if (!rfidKeyHeld.compareAndSet(true, false)) return@up
				mainHandler.post {
					keyEventSink?.success(mapOf("action" to "up", "scanCode" to keyCode))
				}
			},
		)
		try {
			key.register()
			rfidKey = key
		} catch (error: Throwable) {
			Log.e("BiblioRFID", "Unable to register the Seuic RFID key callback", error)
			mainHandler.post { keyEventSink?.error("RFID_KEY_SERVICE", error.message, null) }
		}
	}

	private fun unregisterRfidKey() {
		val key = rfidKey ?: return
		rfidKey = null
		rfidKeyHeld.set(false)
		runCatching { key.unregister() }
	}

	override fun onResume() {
		super.onResume()
		registerRfidKey()
		barcodeScanner?.resume()
	}

	override fun onPause() {
		unregisterRfidKey()
		barcodeScanner?.pause()
		super.onPause()
	}

	private fun connect(transport: String, endpoint: String, result: MethodChannel.Result) {
		executor.execute {
			try {
				closeReader()
				if (transport == "tcp") {
					val candidate = N01_Api()
					val status = candidate.N01_Connect(0, endpoint)
					if (status != N01_Api.RET_ERRNO.RET_OK) {
						postError(result, "READER_CONNECT", "Connexion TCP RFID refusée: $status")
						return@execute
					}
					networkReader = candidate
					mainHandler.post {
						result.success(mapOf("connected" to true, "readerId" to candidate.N01_GetReaderId(), "version" to (candidate.N01_GetHardWareVersion().getOrNull(1) ?: "")))
					}
				} else {
					val candidate = UHFService.getInstance()
					if (!candidate.isOpen() && !candidate.open()) {
						postError(result, "READER_CONNECT", "Le service UHF Seuic du terminal n’a pas pu ouvrir le lecteur intégré.")
						return@execute
					}
					integratedReader = candidate
					tidCache.clear()
					tidAttemptAt.clear()
					tagEventAt.clear()
					mainHandler.post {
						result.success(mapOf("connected" to true, "readerId" to "SEUIC-UHF", "version" to candidate.firmwareVersion.orEmpty()))
					}
				}
			} catch (error: Throwable) {
				postError(result, "READER_CONNECT", error.message ?: "Connexion RFID impossible.")
			}
		}
	}

	private fun configurePower(readPower: Int, writePower: Int, result: MethodChannel.Result) {
		if (!isValidPower(readPower) || !isValidPower(writePower)) {
			result.error("INVALID_POWER", "La puissance UHF doit être comprise entre 5 et 33 dBm.", null)
			return
		}
		val currentIntegratedReader = integratedReader
		val currentNetworkReader = networkReader
		if (currentIntegratedReader == null && currentNetworkReader == null) {
			result.error("READER_OFFLINE", "Connectez le lecteur RFID avant d'appliquer la puissance.", null)
			return
		}
		executor.execute {
			val applied = currentIntegratedReader?.setPower(readPower)
				?: applyNetworkPowers(currentNetworkReader!!, readPower, writePower)
			if (!applied) {
				postError(result, "POWER_SET", "Le lecteur a refusé le réglage de puissance.")
				return@execute
			}
			configuredReadPower = readPower
			configuredWritePower = writePower
			mainHandler.post { result.success(mapOf("readPower" to readPower, "writePower" to writePower)) }
		}
	}

	private fun startInventory(power: Int, targetEpcInput: String?, result: MethodChannel.Result) {
		if (!isValidPower(power)) {
			result.error("INVALID_POWER", "La puissance UHF doit être comprise entre 5 et 33 dBm.", null)
			return
		}
		val currentIntegratedReader = integratedReader
		val currentNetworkReader = networkReader
		val targetEpc = targetEpcInput?.trim()?.uppercase(Locale.ROOT)?.takeIf { it.isNotEmpty() }
		if (targetEpc != null && (!targetEpc.matches(Regex("^[0-9A-F]+$")) || targetEpc.length % 2 != 0)) {
			result.error("INVALID_TAG", "L'EPC du livre recherché est invalide.", null)
			return
		}
		if (currentIntegratedReader == null && currentNetworkReader == null) {
			result.error("READER_OFFLINE", "Connectez le lecteur RFID avant de lancer la lecture.", null)
			return
		}
		executor.execute {
			try {
				activeTargetEpc = targetEpc
				tagEventAt.clear()
				tidFailures.clear()
				if (currentIntegratedReader != null) {
					if (!currentIntegratedReader.setPower(power)) {
						postError(result, "POWER_SET", "Le lecteur Seuic a refusé la puissance de $power dBm.")
						return@execute
					}
					// Seuic firmwares disagree on the byte/word offset used by TAG_FILTER.
					// Always clear it and filter the polled EPC list below instead.
					runCatching {
						currentIntegratedReader.setParamBytes(UHFService.PARAMETER_TAG_FILTER, null)
					}
					if (!currentIntegratedReader.inventoryStart()) {
						activeTargetEpc = null
						postError(result, "INVENTORY_START", "Le lecteur Seuic a refusé le démarrage de l’inventaire.")
						return@execute
					}
					startIntegratedPolling(currentIntegratedReader)
				} else {
					if (!applyNetworkPowers(currentNetworkReader!!, power, configuredWritePower)) {
						postError(result, "POWER_SET", "Le lecteur réseau a refusé la puissance de $power dBm.")
						return@execute
					}
					currentNetworkReader!!.AsyncInvStartThread(object : TagReadDataEventCallback {
						override fun GetAsync(data: TagBackData) {
							val epc = data.epc.orEmpty().trim().uppercase(Locale.ROOT)
							val target = activeTargetEpc
							if (target != null && epc != target) return
							val tid = data.bank_data.orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
							val tag = mapOf("epc" to epc, "tid" to tid, "rssi" to data.rssi, "antenna" to data.antid, "count" to data.counts, "timestamp" to data.timestamp)
							mainHandler.post { eventSink?.success(tag) }
						}
					})
					val status = currentNetworkReader.N01_StartReadingBank(TagFilter(1, 32, "", true), BankData(2, 0, 6))
					if (status != N01_Api.RET_ERRNO.RET_OK) {
						postError(result, "INVENTORY_START", "Lecture EPC/TID refusée: $status")
						return@execute
					}
				}
				mainHandler.post { result.success(mapOf("started" to true)) }
			} catch (error: Exception) {
				activeTargetEpc = null
				postError(result, "INVENTORY_START", error.message ?: "Démarrage de la lecture impossible.")
			}
		}
	}

	private fun stopInventory(result: MethodChannel.Result) {
		integratedInventoryJob?.cancel(false)
		integratedInventoryJob = null
		val currentIntegratedReader = integratedReader
		val currentNetworkReader = networkReader
		if (currentIntegratedReader == null && currentNetworkReader == null) {
			activeTargetEpc = null
			result.success(mapOf("stopped" to true))
			return
		}
		executor.execute {
			val stopped = currentIntegratedReader?.inventoryStop()
				?: (currentNetworkReader?.N01_StopReading() == N01_Api.RET_ERRNO.RET_OK)
			if (currentIntegratedReader != null) {
				runCatching {
					currentIntegratedReader.setParamBytes(UHFService.PARAMETER_TAG_FILTER, null)
				}
			}
			activeTargetEpc = null
			if (stopped) {
				mainHandler.post { result.success(mapOf("stopped" to true)) }
			} else {
				postError(result, "INVENTORY_STOP", "Le lecteur a refusé l’arrêt de l’inventaire.")
			}
		}
	}

	private fun resolveTid(epcInput: String, result: MethodChannel.Result) {
		val currentReader = integratedReader
		val epc = epcInput.trim().uppercase(Locale.ROOT)
		if (currentReader == null) {
			result.error("READER_OFFLINE", "Connectez le lecteur RFID avant de relire le TID.", null)
			return
		}
		if (!epc.matches(Regex("^[0-9A-F]+$")) || epc.length % 2 != 0) {
			result.error("INVALID_TAG", "L'EPC du tag est invalide.", null)
			return
		}
		executor.execute {
			try {
				var tid = ""
				for (attempt in 0..2) {
					tid = readTid(currentReader, epc, force = true)
					if (tid.isNotEmpty()) break
					if (attempt < 2) Thread.sleep(80)
				}
				mainHandler.post { result.success(mapOf("tid" to tid)) }
			} catch (error: Exception) {
				postError(result, "TID_READ", error.message ?: "Lecture du TID impossible.")
			}
		}
	}

	private fun writeEpc(epcInput: String, tidInput: String, currentEpcInput: String, writePower: Int, restorePower: Int, result: MethodChannel.Result) {
		val currentIntegratedReader = integratedReader
		val currentNetworkReader = networkReader
		val epc = epcInput.trim().uppercase(Locale.ROOT)
		val tid = tidInput.trim().uppercase(Locale.ROOT)
		val currentEpc = currentEpcInput.trim().uppercase(Locale.ROOT)
		if (currentIntegratedReader == null && currentNetworkReader == null) {
			result.error("READER_OFFLINE", "Connectez le lecteur RFID avant l’écriture.", null)
			return
		}
		if (!epc.matches(Regex("^[0-9A-F]{24}$")) || !currentEpc.matches(Regex("^[0-9A-F]{24}$")) || tid.isBlank()) {
			result.error("INVALID_TAG", "Un EPC de 24 caractères et le TID du tag sont obligatoires.", null)
			return
		}
		if (!isValidPower(writePower) || !isValidPower(restorePower)) {
			result.error("INVALID_POWER", "La puissance UHF doit être comprise entre 5 et 33 dBm.", null)
			return
		}
		executor.execute {
			try {
				if (currentIntegratedReader != null) {
					val resumeInventory = integratedInventoryJob != null
					integratedInventoryJob?.cancel(false)
					integratedInventoryJob = null
					try {
						currentIntegratedReader.inventoryStop()
						if (!currentIntegratedReader.setPower(writePower)) {
							postError(result, "POWER_SET", "La puissance d'écriture n'a pas pu être appliquée.")
							return@execute
						}
						val accessPassword = ByteArray(16)
						val currentEpcBytes = currentEpc.hexToBytes()
						val currentTid = readTid(currentIntegratedReader, currentEpc, force = true)
						if (currentTid.isEmpty() || currentTid != tid) {
							postError(result, "TAG_MISMATCH", "Le TID lu ne correspond pas au tag sélectionné.")
							return@execute
						}
						val targetEpcBytes = epc.hexToBytes()
						var written = false
						for (attempt in 0..2) {
							written = currentIntegratedReader.writeTagData(
								currentEpcBytes,
								accessPassword,
								EPC_BANK,
								EPC_DATA_OFFSET_BYTES,
								targetEpcBytes.size,
								targetEpcBytes,
							)
							if (written) break
							if (attempt < 2) Thread.sleep(100)
						}
						if (!written) {
							postError(result, "TAG_WRITE", "Le tag a refusé l’écriture après 3 tentatives. Vérifiez qu’il est inscriptible et qu’un seul tag est présent.")
							return@execute
						}
						Thread.sleep(100)
						val verifiedTid = readTid(currentIntegratedReader, epc, force = true)
						if (verifiedTid != tid) {
							postError(result, "TAG_VERIFY", "La relecture de l’EPC après écriture a échoué.")
							return@execute
						}
						tidCache.remove(currentEpc)
						tidCache[epc] = tid
						mainHandler.post { result.success(mapOf("verified" to true, "epc" to epc, "tid" to tid)) }
					} finally {
						currentIntegratedReader.setPower(restorePower)
						if (resumeInventory && integratedReader === currentIntegratedReader && currentIntegratedReader.inventoryStart()) {
							startIntegratedPolling(currentIntegratedReader)
						}
					}
				} else {
					val network = currentNetworkReader!!
					network.N01_StopReading()
					try {
						if (!applyNetworkPowers(network, restorePower, writePower)) {
							postError(result, "POWER_SET", "La puissance d'écriture n'a pas pu être appliquée.")
							return@execute
						}
						val filter = TagFilter(2, 0, tid, true)
						val status = network.N01_WriteTagEpc(1, epc, filter)
						if (status != N01_Api.RET_ERRNO.RET_OK) {
							postError(result, "TAG_WRITE", "Écriture EPC refusée: $status")
							return@execute
						}
						val readBack = network.N01_GetBankData(1, 1, 6, filter).orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
						if (readBack != epc) {
							postError(result, "TAG_VERIFY", "Relecture EPC différente après écriture.")
							return@execute
						}
						mainHandler.post { result.success(mapOf("verified" to true, "epc" to readBack, "tid" to tid)) }
					} finally {
						applyNetworkPowers(network, restorePower, configuredWritePower)
						network.N01_StartReadingBank(TagFilter(1, 32, "", true), BankData(2, 0, 6))
					}
				}
			} catch (error: Exception) {
				postError(result, "TAG_WRITE", error.message ?: "Écriture du tag impossible.")
			}
		}
	}

	private fun disconnect(result: MethodChannel.Result) {
		executor.execute {
			closeReader()
			mainHandler.post { result.success(mapOf("connected" to false)) }
		}
	}

	private fun startIntegratedPolling(currentReader: UHFService) {
		integratedInventoryJob = executor.scheduleAtFixedRate({
			if (integratedReader !== currentReader) return@scheduleAtFixedRate
			try {
				currentReader.tagIDs.orEmpty().forEach { epc ->
					val epcId = epc.getId().orEmpty().uppercase(Locale.ROOT)
					val targetEpc = activeTargetEpc
					if (targetEpc != null && epcId != targetEpc) return@forEach
					val now = SystemClock.elapsedRealtime()
					val lastEventAt = tagEventAt[epcId]
					val debounceMs = if (targetEpc == null) TAG_EVENT_DEBOUNCE_MS else LOCATOR_EVENT_DEBOUNCE_MS
					if (lastEventAt != null && now - lastEventAt < debounceMs) {
						return@forEach
					}
					tagEventAt[epcId] = now
					val tid = if (targetEpc == null) readTid(currentReader, epcId) else tidCache[epcId].orEmpty()
					val tag = mapOf("epc" to epcId, "tid" to tid, "rssi" to epc.rssi, "antenna" to 0, "count" to epc.count, "timestamp" to System.currentTimeMillis())
					mainHandler.post { eventSink?.success(tag) }
				}
			} catch (error: Exception) {
				mainHandler.post { eventSink?.error("INVENTORY_READ", error.message, null) }
			}
		}, 0, 100, TimeUnit.MILLISECONDS)
	}

	private fun readTid(currentReader: UHFService, epc: String, force: Boolean = false): String {
		val cached = tidCache[epc]
		if (!force && !cached.isNullOrEmpty()) return cached
		val now = System.currentTimeMillis()
		if (!force && now - (tidAttemptAt[epc] ?: 0L) < 1000) return ""
		// Un tag dont le TID ne se lit pas ne doit pas ralentir la boucle de
		// lecture : trois essais par session, puis il remonte sans TID.
		if (!force && (tidFailures[epc] ?: 0) >= MAX_TID_ATTEMPTS) return ""
		tidAttemptAt[epc] = now
		val epcBytes = epc.hexToBytes()
		for (length in TID_LENGTHS_BYTES) {
			val data = ByteArray(length)
			if (!currentReader.readTagData(epcBytes, ByteArray(16), TID_BANK, 0, length, data)) continue
			val tid = data.toHexString()
			if (tid.isEmpty() || tid.all { it == '0' }) continue
			tidCache[epc] = tid
			tidFailures.remove(epc)
			return tid
		}
		tidFailures.merge(epc, 1, Int::plus)
		return ""
	}

	private fun applyNetworkPowers(reader: N01_Api, readPower: Int, writePower: Int): Boolean {
		val antennas = reader.N01_GetMultiAntPwr() ?: return false
		if (antennas.isEmpty()) return false
		antennas.forEach { antenna: N01AntPwr ->
			antenna.setRead(readPower)
			antenna.setWrite(writePower)
		}
		return reader.N01_SetMultiAntPwr(antennas) == N01_Api.RET_ERRNO.RET_OK
	}

	private fun isValidPower(power: Int): Boolean = power in MIN_POWER..MAX_POWER

	private fun closeReader() {
		integratedInventoryJob?.cancel(false)
		integratedInventoryJob = null
		integratedReader?.let {
			runCatching { it.inventoryStop() }
			runCatching { it.setParamBytes(UHFService.PARAMETER_TAG_FILTER, null) }
			runCatching { it.close() }
		}
		integratedReader = null
		activeTargetEpc = null
		tidCache.clear()
		tidAttemptAt.clear()
		tidFailures.clear()
		tagEventAt.clear()
		networkReader?.let { runCatching { it.N01_StopReading() }; runCatching { it.N01_Close() } }
		networkReader = null
	}

	private fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
	private fun ByteArray.toHexString(): String = joinToString("") { "%02X".format(it) }

	private fun postError(result: MethodChannel.Result, code: String, message: String) {
		mainHandler.post { result.error(code, message, null) }
	}

	override fun onDestroy() {
		unregisterRfidKey()
		barcodeScanner?.dispose()
		barcodeScanner = null
		closeReader()
		runCatching { deskReader?.dispose() }
		deskReader = null
		runCatching { gate?.dispose() }
		gate = null
		runCatching { heading?.dispose() }
		heading = null
		runCatching { logs?.dispose() }
		logs = null
		executor.shutdownNow()
		soundPool?.release()
		soundPool = null
		scanSoundLoaded = false
		super.onDestroy()
	}

	private companion object {
		const val MIN_POWER = 5
		const val MAX_POWER = 33
		const val EPC_BANK = 1
		const val TID_BANK = 2
		const val EPC_DATA_OFFSET_BYTES = 4
		val TID_LENGTHS_BYTES = intArrayOf(12, 8, 6)
		const val RFID_HANDLE_KEY_CODE = 250
		const val RFID_KEY_DEBOUNCE_MS = 450L
		const val TAG_EVENT_DEBOUNCE_MS = 350L
		const val LOCATOR_EVENT_DEBOUNCE_MS = 100L
		const val MAX_TID_ATTEMPTS = 3
	}
}
