package com.bibliorfid.myscankey_flutter

import Interface.ListenGPI
import Interface.TagReadDataEventCallback
import Tool.BankData
import Tool.Epc_Filter
import Tool.GPIState
import Tool.N01AntPwr
import Tool.TagBackData
import ZAO_API.N01_Api
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Portail antivol N01 (SDK « N01RFID », N01_1.3.1.6.jar) : lecture continue
 * EPC + TID sur toutes les antennes, remontée des barrières infrarouges
 * (GPI) sur la connexion en cours, voyant rouge (GPO) et message d'alarme
 * joué par la tablette. Le buzzer du portail n'est jamais utilisé.
 */
class GateBridge(
	messenger: BinaryMessenger,
	private val context: Context,
	private val mainHandler: Handler,
	private val keepScreenOn: (Boolean) -> Unit,
) {
	private val executor = Executors.newSingleThreadExecutor()
	private val tagEventAt = ConcurrentHashMap<String, Long>()
	@Volatile private var reader: N01_Api? = null
	@Volatile private var transport = "tcp"
	@Volatile private var eventSink: EventChannel.EventSink? = null
	private var alarmPlayer: MediaPlayer? = null

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
			"connect" -> connect(
				call.argument<String>("transport") ?: "tcp",
				call.argument<String>("endpoint") ?: "",
				call.argument<List<Int>>("sensors") ?: emptyList(),
				result,
			)
			"disconnect" -> executor.execute {
				closeReader()
				mainHandler.post { result.success(mapOf("connected" to false)) }
			}
			"startInventory" -> startInventory(call.argument<Int>("power"), result)
			"stopInventory" -> stopInventory(result)
			"ping" -> ping(result)
			"pulseLight" -> pulseLight(call.argument<Int>("gpo") ?: RED_LIGHT_GPO, call.argument<Int>("durationMs") ?: 3000, result)
			"playAlarm" -> playAlarm(call.argument<Double>("volume") ?: 0.8, result)
			"stopAlarm" -> {
				stopAlarm()
				result.success(null)
			}
			"keepScreenOn" -> {
				keepScreenOn(call.argument<Boolean>("enabled") == true)
				result.success(null)
			}
			else -> result.notImplemented()
		}
	}

	private fun connect(transportInput: String, endpoint: String, sensors: List<Int>, result: MethodChannel.Result) {
		executor.execute {
			try {
				closeReader()
				val mode = if (transportInput == "serial") 1 else 0
				val candidate = N01_Api()
				val status = candidate.N01_Connect(mode, endpoint)
				if (status != N01_Api.RET_ERRNO.RET_OK) {
					runCatching { candidate.N01_Close() }
					val hint = if (mode == 1) " Vérifiez le port série." else " Vérifiez l'adresse IP (port 8080) et le réseau."
					postError(result, "GATE_CONNECT", "Le portail ne répond pas sur $endpoint ($status).$hint")
					return@execute
				}
				transport = transportInput
				// Barrières infrarouges : changements d'état remontés sur la
				// connexion en cours (2 : TCP, 3 : série).
				candidate.addReadListener(ListenGPI { state: GPIState -> onGpi(state) })
				val gpiReport = runCatching {
					candidate.N01_SetExGet(intArrayOf(0, if (mode == 1) 3 else 2, 0, 0, 0)) == N01_Api.RET_ERRNO.RET_OK
				}.getOrDefault(false)
				val levels = sensors.filter { it in 1..4 }.associate { gpi ->
					gpi.toString() to runCatching { candidate.N01_GetGpi(gpi) }.getOrDefault(-1)
				}
				val buzzerSilenced = silenceBuzzer(candidate)
				reader = candidate
				tagEventAt.clear()
				val version = runCatching { candidate.N01_GetHardWareVersion()?.getOrNull(1) }.getOrNull().orEmpty()
				val readerId = runCatching { candidate.N01_GetReaderId() }.getOrNull().orEmpty()
				mainHandler.post {
					result.success(mapOf(
						"connected" to true,
						"readerId" to readerId,
						"version" to version,
						"gpiLevels" to levels,
						"gpiReport" to gpiReport,
						"buzzerSilenced" to buzzerSilenced,
					))
				}
			} catch (error: Throwable) {
				Log.e(TAG, "Gate connection failed", error)
				postError(result, "GATE_CONNECT", error.message ?: "Connexion au portail impossible.")
			}
		}
	}

	/**
	 * Retire le buzzer (GPO3, bit 4) des sorties déclenchées par le portail
	 * lui-même : indicateur de lecture et GPO après lecture d'un tag (EAS).
	 * Voyants et autres réglages sont conservés. `true` si rien ne sonne plus.
	 */
	private fun silenceBuzzer(api: N01_Api): Boolean {
		var silent = true
		runCatching {
			val indicator = api.N01_IndicatorGpoGet()
			if (indicator != null && indicator.size >= 6 && indicator[3] and BUZZER_MASK != 0) {
				indicator[3] = indicator[3] and BUZZER_MASK.inv()
				silent = api.N01_IndicatorGpoSet(indicator) == N01_Api.RET_ERRNO.RET_OK && silent
			}
		}.onFailure { Log.w(TAG, "Indicator GPO unavailable", it) }
		runCatching {
			val tagGpo = api.N01_GetTagGpo()
			val gpo = (tagGpo?.getOrNull(0) as? Number)?.toInt() ?: 0
			if (gpo and BUZZER_MASK != 0) {
				val level = (tagGpo?.getOrNull(1) as? Number)?.toInt() ?: 1
				val duration = (tagGpo?.getOrNull(2) as? Number)?.toInt() ?: 1
				val remaining = gpo and BUZZER_MASK.inv()
				val status = if (tagGpo != null && tagGpo.size >= 6) {
					api.N01_SetTagGpo(
						remaining,
						level,
						duration,
						Epc_Filter((tagGpo[3] as? Number)?.toInt() ?: 0, tagGpo[4]?.toString().orEmpty(), tagGpo[5] == true),
					)
				} else {
					api.N01_SetTagGpo(intArrayOf(remaining, level, duration))
				}
				silent = status == N01_Api.RET_ERRNO.RET_OK && silent
			}
		}.onFailure { Log.w(TAG, "Tag GPO unavailable", it) }
		runCatching { api.N01_SetGpo(BUZZER_GPO, 0) }
		return silent
	}

	private fun startInventory(power: Int?, result: MethodChannel.Result) {
		if (power != null && power !in MIN_POWER..MAX_POWER) {
			result.error("INVALID_POWER", "La puissance UHF doit être comprise entre $MIN_POWER et $MAX_POWER dBm.", null)
			return
		}
		val current = reader
		if (current == null) {
			result.error("READER_OFFLINE", "Connectez le portail avant de lancer la lecture.", null)
			return
		}
		executor.execute {
			try {
				runCatching { current.N01_StopReading() }
				if (power != null && !applyPower(current, power)) {
					postError(result, "POWER_SET", "Le portail a refusé la puissance de $power dBm.")
					return@execute
				}
				tagEventAt.clear()
				current.AsyncInvStartThread(TagReadDataEventCallback { data -> onTag(data) })
				// EPC et TID (6 mots) : le TID authentifie cartes et badges.
				val status = current.N01_StartReadingBank(null, BankData(2, 0, 6))
				if (status != N01_Api.RET_ERRNO.RET_OK) {
					postError(result, "INVENTORY_START", "Le portail a refusé la lecture ($status).")
					return@execute
				}
				mainHandler.post { result.success(mapOf("started" to true)) }
			} catch (error: Throwable) {
				postError(result, "INVENTORY_START", error.message ?: "Démarrage de la lecture impossible.")
			}
		}
	}

	private fun stopInventory(result: MethodChannel.Result) {
		val current = reader
		if (current == null) {
			result.success(mapOf("stopped" to true))
			return
		}
		executor.execute {
			runCatching { current.N01_StopReading() }
			mainHandler.post { result.success(mapOf("stopped" to true)) }
		}
	}

	/** Contrôle de liaison : le SDK N01 ne signale pas une coupure réseau. */
	private fun ping(result: MethodChannel.Result) {
		val current = reader
		if (current == null) {
			result.success(false)
			return
		}
		executor.execute {
			val alive = runCatching { !current.N01_GetReaderId().isNullOrEmpty() }.getOrDefault(false)
			mainHandler.post { result.success(alive) }
		}
	}

	private fun applyPower(api: N01_Api, power: Int): Boolean {
		val antennas = api.N01_GetMultiAntPwr() ?: return false
		if (antennas.isEmpty()) return false
		antennas.forEach { antenna: N01AntPwr -> antenna.setRead(power) }
		return api.N01_SetMultiAntPwr(antennas) == N01_Api.RET_ERRNO.RET_OK
	}

	/** Voyant (rouge par défaut) allumé pendant [durationMs], puis éteint. */
	private fun pulseLight(gpo: Int, durationMs: Int, result: MethodChannel.Result) {
		val current = reader
		if (current == null || gpo !in 1..4 || gpo == BUZZER_GPO) {
			result.success(false)
			return
		}
		executor.execute {
			val lit = runCatching { current.N01_SetGpo(gpo, 1) == N01_Api.RET_ERRNO.RET_OK }.getOrDefault(false)
			mainHandler.post { result.success(lit) }
			mainHandler.postDelayed({
				executor.execute { if (reader === current) runCatching { current.N01_SetGpo(gpo, 0) } }
			}, durationMs.coerceIn(200, 60_000).toLong())
		}
	}

	/**
	 * Message vocal d'alarme sur fond de sirène douce (res/raw/gate_alarm),
	 * joué sur le flux « alarme » de la tablette. Un message en cours n'est
	 * pas relancé. Renvoie la durée restante en millisecondes.
	 */
	private fun playAlarm(volume: Double, result: MethodChannel.Result) {
		mainHandler.post {
			try {
				val playing = alarmPlayer
				if (playing != null && playing.isPlaying) {
					result.success(mapOf("started" to false, "remainingMs" to (playing.duration - playing.currentPosition)))
					return@post
				}
				playing?.release()
				val attributes = AudioAttributes.Builder()
					.setUsage(AudioAttributes.USAGE_ALARM)
					.setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
					.build()
				val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
				val player = MediaPlayer.create(context, R.raw.gate_alarm, attributes, audioManager.generateAudioSessionId())
				if (player == null) {
					result.error("ALARM_SOUND", "Le message d'alarme n'a pas pu être chargé.", null)
					return@post
				}
				val level = volume.toFloat().coerceIn(0f, 1f)
				player.setVolume(level, level)
				player.setOnCompletionListener { finished ->
					finished.release()
					if (alarmPlayer === finished) alarmPlayer = null
				}
				alarmPlayer = player
				player.start()
				result.success(mapOf("started" to true, "remainingMs" to player.duration))
			} catch (error: Throwable) {
				Log.e(TAG, "Alarm playback failed", error)
				result.error("ALARM_SOUND", error.message ?: "Lecture du message d'alarme impossible.", null)
			}
		}
	}

	private fun stopAlarm() {
		mainHandler.post {
			alarmPlayer?.let { runCatching { it.stop() }; it.release() }
			alarmPlayer = null
		}
	}

	/** Appelé par le fil de réception du SDK : aucun traitement bloquant ici. */
	private fun onTag(data: TagBackData?) = runCatching {
		if (data == null) return@runCatching
		val epc = data.epc.orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
		if (epc.isEmpty()) return@runCatching
		val tid = data.bank_data.orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
		// Plusieurs antennes lisent le même tag : une remontée par intervalle,
		// en gardant celles qui apportent le TID.
		val key = if (tid.isEmpty()) "$epc:" else "$epc:$tid"
		val now = SystemClock.elapsedRealtime()
		val last = tagEventAt[key]
		if (last != null && now - last < TAG_EVENT_DEBOUNCE_MS) return@runCatching
		tagEventAt[key] = now
		if (tagEventAt.size > 2000) tagEventAt.entries.removeIf { now - it.value > 60_000 }
		val tag = mapOf("type" to "tag", "epc" to epc, "tid" to tid, "rssi" to data.rssi, "antenna" to data.antid)
		mainHandler.post { eventSink?.success(tag) }
	}

	private fun onGpi(state: GPIState?) = runCatching {
		if (state == null) return@runCatching
		val event = mapOf("type" to "gpi", "gpi" to state.gpinum, "level" to state.level)
		mainHandler.post { eventSink?.success(event) }
	}

	private fun closeReader() {
		val current = reader ?: return
		reader = null
		runCatching { current.N01_StopReading() }
		runCatching { current.N01_SetGpo(RED_LIGHT_GPO, 0) }
		runCatching { current.N01_Close() }
		tagEventAt.clear()
	}

	private fun postError(result: MethodChannel.Result, code: String, message: String) {
		mainHandler.post { result.error(code, message, null) }
	}

	fun dispose() {
		stopAlarm()
		executor.execute { closeReader() }
		executor.shutdown()
	}

	private companion object {
		const val TAG = "BiblioGate"
		const val METHOD_CHANNEL = "com.bibliorfid.myscankey_flutter/gate"
		const val EVENT_CHANNEL = "com.bibliorfid.myscankey_flutter/gate-events"
		const val MIN_POWER = 5
		const val MAX_POWER = 33
		const val RED_LIGHT_GPO = 1
		const val BUZZER_GPO = 3
		const val BUZZER_MASK = 4
		const val TAG_EVENT_DEBOUNCE_MS = 250L
	}
}
