package com.bibliorfid.myscankey_flutter

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/**
 * Boussole du terminal pour le radar de localisation : cap, en degrés depuis
 * le nord, de la direction visée par le lecteur. Terminal tenu à plat
 * (poignée), c'est le bord supérieur ; tenu debout, c'est le dos. Les
 * capteurs ne tournent que pendant l'écoute du flux.
 */
class HeadingBridge(messenger: BinaryMessenger, context: Context) : SensorEventListener {
	private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
	private val rotationSensor: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
	private val accelerometer: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
	private val magnetometer: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)
	private var sink: EventChannel.EventSink? = null
	private val rotation = FloatArray(9)
	private var gravity: FloatArray? = null
	private var geomagnetic: FloatArray? = null
	private var smoothedSin = 0.0
	private var smoothedCos = 1.0
	private var hasValue = false
	private var lastEmitAt = 0L

	init {
		EventChannel(messenger, CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
			override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
				sink = events
				start(events)
			}

			override fun onCancel(arguments: Any?) {
				stop()
				sink = null
			}
		})
	}

	private fun start(events: EventChannel.EventSink?) {
		hasValue = false
		val registered = if (rotationSensor != null) {
			sensors.registerListener(this, rotationSensor, SensorManager.SENSOR_DELAY_UI)
		} else if (accelerometer != null && magnetometer != null) {
			sensors.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_UI) &&
				sensors.registerListener(this, magnetometer, SensorManager.SENSOR_DELAY_UI)
		} else {
			false
		}
		if (!registered) events?.error("NO_COMPASS", "Ce terminal n'a pas de boussole.", null)
	}

	private fun stop() {
		sensors.unregisterListener(this)
		gravity = null
		geomagnetic = null
	}

	override fun onSensorChanged(event: SensorEvent) {
		when (event.sensor.type) {
			Sensor.TYPE_ROTATION_VECTOR -> SensorManager.getRotationMatrixFromVector(rotation, event.values)
			Sensor.TYPE_ACCELEROMETER -> {
				gravity = event.values.clone()
				if (!fromAccelerometerAndMagnetometer()) return
			}
			Sensor.TYPE_MAGNETIC_FIELD -> {
				geomagnetic = event.values.clone()
				if (!fromAccelerometerAndMagnetometer()) return
			}
			else -> return
		}
		// Matrice appareil -> monde (x : est, y : nord, z : ciel). On vise
		// selon l'axe le plus horizontal : bord supérieur (Y) ou dos (-Z).
		val topVertical = abs(rotation[7])
		val backVertical = abs(rotation[8])
		val (east, north) = if (topVertical <= backVertical) {
			rotation[1] to rotation[4]
		} else {
			-rotation[2] to -rotation[5]
		}
		val angle = atan2(east.toDouble(), north.toDouble())
		// Lissage circulaire : pas de saut entre 359° et 0°.
		if (!hasValue) {
			smoothedSin = sin(angle)
			smoothedCos = cos(angle)
			hasValue = true
		} else {
			smoothedSin += (sin(angle) - smoothedSin) * SMOOTHING
			smoothedCos += (cos(angle) - smoothedCos) * SMOOTHING
		}
		val now = SystemClock.elapsedRealtime()
		if (now - lastEmitAt < EMIT_INTERVAL_MS) return
		lastEmitAt = now
		val degrees = (Math.toDegrees(atan2(smoothedSin, smoothedCos)) + 360.0) % 360.0
		sink?.success(degrees)
	}

	private fun fromAccelerometerAndMagnetometer(): Boolean {
		val g = gravity ?: return false
		val m = geomagnetic ?: return false
		return SensorManager.getRotationMatrix(rotation, null, g, m)
	}

	override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

	fun dispose() = stop()

	private companion object {
		const val CHANNEL = "com.bibliorfid.myscankey_flutter/heading"
		const val SMOOTHING = 0.25
		const val EMIT_INTERVAL_MS = 60L
	}
}
