package com.bibliorfid.myscankey_flutter

import Interface.ListenGPI
import Interface.TagReadDataEventCallback
import Tool.Epc_Filter
import Tool.N01AntPwr
import Tool.TagFilter
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
import org.json.JSONObject

/**
 * Portail antivol N01 (SDK « N01RFID », N01_1.3.1.6.jar) : lecture continue
 * EPC + TID sur toutes les antennes, remontée des barrières infrarouges
 * (GPI) sur la connexion en cours, voyant rouge (GPO) et message d'alarme
 * joué par la tablette. Le buzzer du portail ne sonne que si les réglages
 * l'autorisent.
 */
class GateBridge(
	messenger: BinaryMessenger,
	private val context: Context,
	private val mainHandler: Handler,
	private val keepScreenOn: (Boolean) -> Unit,
) {
	private val executor = Executors.newSingleThreadExecutor()
	private val tagEventAt = ConcurrentHashMap<String, Long>()

	/** Dernière lecture de chaque EPC (diagnostic) et TID déjà relus. */
	private val lastReadAt = ConcurrentHashMap<String, Long>()
	private val tidCache = ConcurrentHashMap<String, String>()
	@Volatile private var reading = false

	/** Barrières qui déclenchent la lecture (GPI 1 à 3), relevées à la connexion. */
	@Volatile private var triggerSensors = listOf(1, 2)
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
				call.argument<Int>("buzzerGpo") ?: DEFAULT_BUZZER_GPO,
				call.argument<Boolean>("silenceBuzzer") ?: true,
				result,
			)
			"disconnect" -> executor.execute {
				closeReader()
				mainHandler.post { result.success(mapOf("connected" to false)) }
			}
			"startInventory" -> startInventory(call.argument<Int>("power"), result)
			"stopInventory" -> stopInventory(result)
			"readTid" -> readTid(call.argument<String>("epc") ?: "", result)
			"ping" -> ping(result)
			"pulseGpo" -> pulseGpo(call.argument<Int>("gpo") ?: RED_LIGHT_GPO, call.argument<Int>("durationMs") ?: 3000, result)
			"silenceBuzzer" -> {
				val current = reader
				val gpo = call.argument<Int>("gpo") ?: DEFAULT_BUZZER_GPO
				if (current == null) {
					result.success(false)
				} else {
					executor.execute {
						val silent = silenceBuzzer(current, gpo)
						mainHandler.post { result.success(silent) }
					}
				}
			}
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

	private fun connect(
		transportInput: String,
		endpoint: String,
		sensors: List<Int>,
		buzzerGpo: Int,
		silence: Boolean,
		result: MethodChannel.Result,
	) {
		executor.execute {
			try {
				closeReader()
				val mode = if (transportInput == "serial") 1 else 0
				val candidate = GateApi(::onTag, ::onGpi)
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
				// Décodés par GateApi : écouteurs du SDK jamais appelés, mais
				// présents pour qu'il ne rencontre pas de référence nulle.
				candidate.addReadListener(ListenGPI { })
				val gpiReport = runCatching {
					candidate.N01_SetExGet(intArrayOf(0, if (mode == 1) 3 else 2, 0, 0, 0)) == N01_Api.RET_ERRNO.RET_OK
				}.getOrDefault(false)
				// Relevé pour le diagnostic seulement : GpiGet renvoie 1 pour une
				// barrière libre, à l'inverse du masque « gpis » (0 = libre) qui
				// alimente le comptage. Le repos est donc laissé à 0.
				val levels = sensors.filter { it in 1..4 }.associate { gpi ->
					gpi.toString() to runCatching { candidate.N01_GetGpi(gpi) }.getOrDefault(-1)
				}
				val reportsFixed = routeReportsToNetwork(candidate)
				val buzzerSilenced = if (silence) silenceBuzzer(candidate, buzzerGpo) else null
				triggerSensors = sensors.filter { it in 1..3 }.ifEmpty { listOf(1, 2) }
				reader = candidate
				tagEventAt.clear()
				tidCache.clear()
				Log.i(TAG, "Gate connected: $transportInput $endpoint, GPI report=$gpiReport, levels=$levels, reports=$reportsFixed, buzzer silenced=$buzzerSilenced")
				val version = runCatching { candidate.N01_GetHardWareVersion()?.getOrNull(1) }.getOrNull().orEmpty()
				val readerId = runCatching { candidate.N01_GetReaderId() }.getOrNull().orEmpty()
				mainHandler.post {
					result.success(mapOf(
						"connected" to true,
						"readerId" to readerId,
						"version" to version,
						"gpiLevels" to emptyMap<String, Int>(),
						"gpiReport" to gpiReport,
						"buzzerSilenced" to buzzerSilenced,
					))
				}
				logSettings(candidate)
			} catch (error: Throwable) {
				Log.e(TAG, "Gate connection failed", error)
				postError(result, "GATE_CONNECT", error.message ?: "Connexion au portail impossible.")
			}
		}
	}

	/**
	 * Les tags lus sont envoyés par le chemin « router » de la configuration
	 * des rapports (0 : Ethernet/Wi-Fi, 1 : 4G), au format « jsontype »
	 * (0 : par défaut). Ce portail était réglé sur la 4G au format
	 * personnalisé 1 : aucun tag n'arrivait sur la connexion réseau. Son
	 * cache de doublons (« clearcache ») est ramené à quelques secondes. Les
	 * autres paramètres sont conservés. Renvoie l'état pour les logs.
	 */
	private fun routeReportsToNetwork(api: N01_Api): String {
		val current = runCatching { api.N01_GetReportCfg() }.getOrNull()
		if (current == null || current.size < 6) return "inconnu"
		if (current[0] == 0 && current[4] in 1..CLEAR_CACHE_SECONDS && current[5] == 0) return "réseau"
		val fixed = current.copyOf().apply {
			this[0] = 0
			// Cache des tags déjà signalés : à 0, un livre vu une fois n'est
			// plus jamais renvoyé. L'application filtre elle-même les doublons.
			this[4] = CLEAR_CACHE_SECONDS
			this[5] = 0
		}
		val status = runCatching { api.N01_SetReportCfg(fixed) }.getOrNull()
		Log.w(TAG, "Gate reports rerouted: ${current.toList()} -> ${fixed.toList()}, status=$status")
		return if (status == N01_Api.RET_ERRNO.RET_OK) "réseau (corrigé)" else "échec $status"
	}

	/**
	 * Réglages du portail qui décident des tags remontés (région, antennes,
	 * session Gen2, filtres, inventaire automatique, licence) : leurs
	 * réponses brutes apparaissent dans les logs (« Gate message »).
	 */
	private fun logSettings(api: N01_Api) {
		val queries = listOf<Pair<String, () -> Any?>>(
			"region" to { api.N01_GetFreqRegion() },
			"antennas" to { api.N01_GetInvingAnt() },
			"session" to { api.N01_GetSession() },
			"q" to { api.N01_GetQValue() },
			"target" to { api.N01_GetTarget() },
			"uniByAnt" to { api.N01_GetUniByAnt() },
			"uniByBank" to { api.N01_GetUniByBank() },
			"tagInfoEx" to { api.N01_GetTagInfoEx()?.toList() },
			"reportCfg" to { api.N01_GetReportCfg()?.toList() },
			"autoInv" to { api.N01_GetAutoInv()?.toList() },
			"autoInvCfg" to { api.N01_GetAutoInvCfg() },
			"license" to { api.N01_GetLicense()?.toList() },
		)
		for ((name, query) in queries) {
			if (reader !== api) return
			val value = runCatching { query() }.getOrElse { "erreur ${it.javaClass.simpleName}" }
			Log.i(TAG, "Gate setting $name=$value")
		}
	}

	/**
	 * Retire la sortie du buzzer ([gpo], GPO3 d'après le manuel du portail)
	 * des sorties que le portail déclenche lui-même : indicateur de lecture et
	 * GPO après lecture d'un tag (EAS). Les autres sorties sont conservées.
	 * `true` si rien ne fait plus sonner le buzzer.
	 */
	private fun silenceBuzzer(api: N01_Api, gpo: Int): Boolean {
		if (gpo !in 1..4) return true
		val buzzerMask = 1 shl (gpo - 1)
		var silent = true
		runCatching {
			val indicator = api.N01_IndicatorGpoGet()
			if (indicator != null && indicator.size >= 6 && indicator[3] and buzzerMask != 0) {
				indicator[3] = indicator[3] and buzzerMask.inv()
				silent = api.N01_IndicatorGpoSet(indicator) == N01_Api.RET_ERRNO.RET_OK && silent
			}
		}.onFailure { Log.w(TAG, "Indicator GPO unavailable", it) }
		runCatching {
			val tagGpo = api.N01_GetTagGpo()
			val outputs = (tagGpo?.getOrNull(0) as? Number)?.toInt() ?: 0
			if (outputs and buzzerMask != 0) {
				val level = (tagGpo?.getOrNull(1) as? Number)?.toInt() ?: 1
				val duration = (tagGpo?.getOrNull(2) as? Number)?.toInt() ?: 1
				val remaining = outputs and buzzerMask.inv()
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
		runCatching { api.N01_SetGpo(gpo, 0) }
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
		Log.i(TAG, "Gate inventory starting: power=${power ?: "reader"} dBm")
		executor.execute {
			try {
				haltReading(current)
				if (power != null && !applyPower(current, power)) {
					Log.w(TAG, "Gate power $power dBm refused")
					postError(result, "POWER_SET", "Le portail a refusé la puissance de $power dBm.")
					return@execute
				}
				tagEventAt.clear()
				lastReadAt.clear()
				current.AsyncInvStartThread(TagReadDataEventCallback { })
				val status = beginReading(current)
				Log.i(TAG, "Gate inventory started: power=${power ?: "reader"} dBm, triggers=$triggerSensors, status=$status")
				if (status != N01_Api.RET_ERRNO.RET_OK) {
					postError(result, "INVENTORY_START", "Le portail a refusé la lecture ($status).")
					return@execute
				}
				reading = true
				mainHandler.post { result.success(mapOf("started" to true)) }
			} catch (error: Throwable) {
				Log.e(TAG, "Gate inventory start failed", error)
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
			reading = false
			haltReading(current)
			mainHandler.post { result.success(mapOf("stopped" to true)) }
		}
	}

	/**
	 * Lecture déclenchée par les barrières, comme le réglage d'usine du
	 * portail (firmware V1.3.6.6) : chaque coupure d'une barrière lance une
	 * lecture de [AUTO_INVENTORY_SECONDS] s dont les tags arrivent sur cette
	 * connexion (mode TCP_FAST). La lecture continue (AsyncInvStart) est
	 * acceptée par ce firmware mais ne remonte aucun tag.
	 */
	private fun beginReading(api: N01_Api): N01_Api.RET_ERRNO {
		val triggers = hashMapOf(
			"start1" to "GPI${triggerSensors[0]}",
			"stop1" to "NONE",
			"start2" to (triggerSensors.getOrNull(1)?.let { "GPI$it" } ?: "NONE"),
			"stop2" to "NONE",
		)
		return api.N01_AutoInvStar("TCP_FAST", AUTO_INVENTORY_SECONDS, triggers)
	}

	private fun haltReading(api: N01_Api) {
		runCatching { api.N01_AutoInvStop() }
		runCatching { api.N01_StopReading() }
	}

	/**
	 * TID (6 mots) du tag [epcInput], lu par une commande ciblée sur son EPC :
	 * la lecture du portail est suspendue le temps de la lecture. Gardé en
	 * cache pour la connexion. Chaîne vide si le tag n'a pas répondu.
	 */
	private fun readTid(epcInput: String, result: MethodChannel.Result) {
		val epc = epcInput.filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
		val current = reader
		if (current == null || epc.isEmpty()) {
			result.success("")
			return
		}
		tidCache[epc]?.let {
			result.success(it)
			return
		}
		executor.execute {
			val resume = reading
			var tid = ""
			try {
				if (resume) haltReading(current)
				val filter = TagFilter(1, EPC_FILTER_START_BIT, epc, true)
				for (attempt in 0 until TID_ATTEMPTS) {
					tid = runCatching { current.N01_GetBankData(2, 0, TID_WORDS, filter) }
						.getOrNull().orEmpty().filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
					if (tid.isNotEmpty() && !tid.all { it == '0' }) break
					tid = ""
				}
				if (tid.isNotEmpty()) tidCache[epc] = tid
				Log.i(TAG, "Gate TID read: epc=$epc tid=${if (tid.isEmpty()) "none" else tid}")
			} catch (error: Throwable) {
				Log.w(TAG, "Gate TID read failed for $epc", error)
			} finally {
				if (resume && reader === current) {
					val status = runCatching { beginReading(current) }.getOrNull()
					if (status != N01_Api.RET_ERRNO.RET_OK) Log.w(TAG, "Gate inventory restart: $status")
				}
			}
			mainHandler.post { result.success(tid) }
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

	/** Sortie [gpo] (voyant ou buzzer) activée pendant [durationMs], puis coupée. */
	private fun pulseGpo(gpo: Int, durationMs: Int, result: MethodChannel.Result) {
		val current = reader
		if (current == null || gpo !in 1..4) {
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
	/** Appelé par le fil de réception du SDK : aucun traitement bloquant ici. */
	private fun onTag(epcInput: String, tidInput: String, rssi: Int, antenna: Int) = runCatching {
		val epc = epcInput.filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
		if (epc.isEmpty()) return@runCatching
		val tid = tidInput.filter { it.isLetterOrDigit() }.uppercase(Locale.ROOT)
			.ifEmpty { tidCache[epc].orEmpty() }
		// Plusieurs antennes lisent le même tag : une remontée par intervalle,
		// en gardant celles qui apportent le TID.
		val key = if (tid.isEmpty()) "$epc:" else "$epc:$tid"
		val now = SystemClock.elapsedRealtime()
		// Diagnostic : première lecture d'un tag (ou après une absence).
		val previousRead = lastReadAt.put(epc, now)
		if (previousRead == null || now - previousRead > FIRST_READ_GAP_MS) {
			Log.i(TAG, "Gate tag seen: epc=$epc ant=$antenna rssi=$rssi tid=${if (tid.isEmpty()) "none" else "yes"}")
		}
		val last = tagEventAt[key]
		if (last != null && now - last < TAG_EVENT_DEBOUNCE_MS) return@runCatching
		tagEventAt[key] = now
		if (tagEventAt.size > 2000) tagEventAt.entries.removeIf { now - it.value > 60_000 }
		val tag = mapOf("type" to "tag", "epc" to epc, "tid" to tid, "rssi" to rssi, "antenna" to antenna)
		mainHandler.post { eventSink?.success(tag) }
	}

	private fun onGpi(gpi: Int, level: Int) = runCatching {
		Log.i(TAG, "Gate GPI$gpi level=$level")
		val event = mapOf("type" to "gpi", "gpi" to gpi, "level" to level)
		mainHandler.post { eventSink?.success(event) }
	}

	/**
	 * Le SDK décode lui-même les messages du portail, mais lit sur chaque tag
	 * des champs (counts, freq, timestamp, phase) que le portail n'envoie pas :
	 * le tag lève une erreur et est perdu sans bruit. Il ignore aussi le TID
	 * (bank_data) et ne lit que le premier de plusieurs messages collés. Tags
	 * et barrières sont donc décodés ici ; les réponses aux commandes (qui
	 * portent toutes « RES ») restent au SDK.
	 */
	private class GateApi(
		private val onTag: (String, String, Int, Int) -> Unit,
		private val onGpi: (Int, Int) -> Unit,
	) : N01_Api() {
		/** Dernier masque des entrées GPI reçu (« gpis »). */
		private var lastGpis: String? = null

		override fun SetClass(message: String?) {
			if (message.isNullOrBlank()) return
			for (part in splitObjects(message)) {
				val json = runCatching { JSONObject(part) }.getOrNull()
				when {
					json == null -> {
						Log.w(TAG, "Gate message unreadable: ${part.oneLine()}")
					}
					json.has("epc") && !json.has("RES") -> onTag(
						json.optString("epc"),
						json.optString("bank_data").ifEmpty { json.optString("tid") },
						json.optInt("rssi"),
						json.optInt("antid"),
					)
					json.optString("RES") == "Report" && json.has("gpinum") -> onGpi(
						json.optInt("gpinum"),
						json.optInt("level"),
					)
					json.has("gpis") && !json.has("RES") -> onGpis(json.optString("gpis"))
					else -> {
						Log.i(TAG, "Gate message: ${part.oneLine()}")
						super.SetClass(part)
					}
				}
			}
		}

		/**
		 * Firmware V1.3.6.6 : les barrières remontent en masque, un caractère
		 * par entrée (« 0100000 » : GPI2 à 1). Seules les entrées qui changent
		 * sont signalées, dans l'ordre des entrées.
		 */
		private fun onGpis(mask: String) {
			val previous = lastGpis
			lastGpis = mask
			for ((index, char) in mask.withIndex()) {
				if (char != '0' && char != '1') continue
				if (previous != null && previous.getOrNull(index) == char) continue
				// Premier masque : seules les entrées actives sont signalées.
				if (previous == null && char == '0') continue
				onGpi(index + 1, if (char == '1') 1 else 0)
			}
		}

		/** Objets JSON de premier niveau d'un bloc reçu (« }{ » collés). */
		private fun splitObjects(text: String): List<String> {
			val parts = mutableListOf<String>()
			var depth = 0
			var start = -1
			var inString = false
			var escaped = false
			for ((index, char) in text.withIndex()) {
				if (inString) {
					when {
						escaped -> escaped = false
						char == '\\' -> escaped = true
						char == '"' -> inString = false
					}
					continue
				}
				when (char) {
					'"' -> inString = true
					'{' -> if (depth++ == 0) start = index
					'}' -> if (depth > 0 && --depth == 0 && start >= 0) {
						parts += text.substring(start, index + 1)
						start = -1
					}
				}
			}
			return parts.ifEmpty { listOf(text) }
		}

		private fun String.oneLine() = replace(Regex("\\s+"), " ").take(300)
	}

	private fun closeReader() {
		val current = reader ?: return
		reader = null
		reading = false
		haltReading(current)
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
		const val DEFAULT_BUZZER_GPO = 3
		const val TAG_EVENT_DEBOUNCE_MS = 250L
		const val FIRST_READ_GAP_MS = 2000L
		/** Filtre sur l'EPC : la zone EPC commence après CRC et PC (32 bits). */
		const val EPC_FILTER_START_BIT = 32
		const val TID_WORDS = 6
		const val TID_ATTEMPTS = 3
		const val AUTO_INVENTORY_SECONDS = 3
		const val CLEAR_CACHE_SECONDS = 1
	}
}
