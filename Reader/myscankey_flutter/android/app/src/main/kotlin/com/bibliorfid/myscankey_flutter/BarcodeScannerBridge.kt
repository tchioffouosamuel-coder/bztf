package com.bibliorfid.myscankey_flutter

import android.content.Context
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.util.concurrent.Executors

class BarcodeScannerBridge(
    messenger: BinaryMessenger,
    private val context: Context,
    private val mainHandler: Handler,
) {
    private val executor = Executors.newSingleThreadExecutor()
    private var scanner: Any? = null
    private var scannerKey: SeuicRfidKey? = null
    private var decoding = false
    private val savedParams = mutableMapOf<Int, Int>()
    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile var active = false
        private set

    init {
        EventChannel(messenger, "com.bibliorfid.myscankey_flutter/barcode-events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        MethodChannel(messenger, "com.bibliorfid.myscankey_flutter/barcode")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        active = true
                        execute(result) { openScanner() }
                    }
                    "close" -> {
                        active = false
                        execute(result) { closeScanner() }
                    }
                    "startScan" -> execute(result) { startScan() }
                    "stopScan" -> execute(result) { stopScan() }
                    else -> result.notImplemented()
                }
            }
    }

    // ScannerAPI is a device system library, loaded lazily so other readers
    // can still start the app without the Seuic optical scanner SDK.
    private fun openScanner() {
        if (!active || scanner != null) return
        val factory = Class.forName("com.seuic.scanner.ScannerFactory")
        val device = factory.getMethod("getScanner", Context::class.java)
            .invoke(null, context) ?: error("Scanner optique indisponible.")
        scanner = device
        try {
            check(invoke("open") == true) { "Impossible d'ouvrir le scanner optique." }
            val callbackClass = Class.forName("com.seuic.scanner.DecodeInfoCallBack")
            val callback = Proxy.newProxyInstance(
                callbackClass.classLoader, arrayOf(callbackClass),
            ) { proxy, method, args ->
                when (method.name) {
                    "onDecodeComplete" -> {
                        val info = args?.firstOrNull()
                        val barcode = info?.javaClass?.getField("barcode")?.get(info) as? String
                        if (active && !barcode.isNullOrBlank()) {
                            executor.execute { runCatching { stopScan() }.onFailure(::reportError) }
                            emit(mapOf("barcode" to barcode))
                        }
                        null
                    }
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === args?.firstOrNull()
                    "toString" -> "BiblioRFID barcode callback"
                    else -> null
                }
            }
            device.javaClass.getMethod("setDecodeInfoCallBack", callbackClass).invoke(device, callback)
            val statusClass = Class.forName("com.seuic.scanner.StatusCallBack")
            val statusCallback = Proxy.newProxyInstance(
                statusClass.classLoader, arrayOf(statusClass),
            ) { proxy, method, args ->
                when (method.name) {
                    "onStatusCallBack" -> {
                        val status = args?.firstOrNull() as? Int
                        if (status != null && status in 0..3 && active) {
                            executor.execute {
                                decoding = false
                                if (status == 3) reportError(IllegalStateException("Erreur de lecture optique."))
                                else emit(mapOf("state" to "ready"))
                            }
                        }
                        null
                    }
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === args?.firstOrNull()
                    "toString" -> "BiblioRFID scanner status callback"
                    else -> null
                }
            }
            device.javaClass.getMethod("setStatusCallBack", statusClass).invoke(device, statusCallback)
            // Enable ISBN/EAN-13 including its check digit, aiming and lighting.
            for (param in intArrayOf(PARAM_EAN13, PARAM_EAN13_CHECK_DIGIT, PARAM_AIMER, PARAM_ILLUMINATION)) {
                val previous = device.javaClass.getMethod("getParams", Int::class.javaPrimitiveType)
                    .invoke(device, param) as Int
                if (previous >= 0) {
                    savedParams[param] = previous
                    setParam(param, 1)
                }
            }
            invoke("enable")
            scannerKey = SeuicRfidKey(
                249,
                onKeyDown = { trigger(true) },
                onKeyUp = { trigger(false) },
            ).also { it.register() }
            Log.i("BiblioRFID", "Optical scanner opened")
            emit(mapOf("state" to "ready"))
        } catch (error: Throwable) {
            closeScanner()
            throw error
        }
    }

    fun trigger(down: Boolean) {
        if (!active) return
        executor.execute {
            runCatching { if (down) startScan() else stopScan() }.onFailure(::reportError)
        }
    }

    private fun startScan() {
        if (!active || decoding) return
        check(scanner != null) { "Scanner optique indisponible." }
        invoke("startScan")
        decoding = true
        Log.i("BiblioRFID", "Optical scanner startScan")
        emit(mapOf("state" to "scanning"))
    }

    private fun stopScan() {
        if (scanner == null) return
        invoke("stopScan")
        decoding = false
        Log.i("BiblioRFID", "Optical scanner stopScan")
        emit(mapOf("state" to "ready"))
    }

    private fun closeScanner() {
        scannerKey?.let { runCatching { it.unregister() } }
        scannerKey = null
        val device = scanner ?: return
        runCatching { invoke("stopScan") }
        runCatching {
            val callbackClass = Class.forName("com.seuic.scanner.DecodeInfoCallBack")
            device.javaClass.getMethod("setDecodeInfoCallBack", callbackClass).invoke(device, null)
        }
        runCatching {
            val statusClass = Class.forName("com.seuic.scanner.StatusCallBack")
            device.javaClass.getMethod("setStatusCallBack", statusClass).invoke(device, null)
        }
        savedParams.forEach { (id, value) -> runCatching { setParam(id, value) } }
        savedParams.clear()
        runCatching { invoke("close") }
        scanner = null
        decoding = false
        Log.i("BiblioRFID", "Optical scanner closed")
    }

    private fun invoke(name: String): Any? = scanner?.let { it.javaClass.getMethod(name).invoke(it) }

    private fun setParam(id: Int, value: Int) {
        scanner?.let {
            it.javaClass.getMethod("setParams", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
                .invoke(it, id, value)
        }
    }

    fun pause() {
        executor.execute { closeScanner() }
    }

    fun resume() {
        if (active) executor.execute { runCatching { openScanner() }.onFailure(::reportError) }
    }

    fun dispose() {
        active = false
        executor.execute { closeScanner() }
        executor.shutdown()
    }

    private fun execute(result: MethodChannel.Result, operation: () -> Unit) {
        executor.execute {
            try {
                operation()
                mainHandler.post { result.success(null) }
            } catch (error: Throwable) {
                Log.e("BiblioRFID", "Optical scanner command failed", error)
                mainHandler.post { result.error("BARCODE_SCANNER", message(error), null) }
            }
        }
    }

    private fun emit(event: Map<String, String>) {
        mainHandler.post { if (active) eventSink?.success(event) }
    }

    private fun reportError(error: Throwable) {
        Log.e("BiblioRFID", "Optical scanner failed", error)
        mainHandler.post { if (active) eventSink?.error("BARCODE_SCANNER", message(error), null) }
    }

    private fun message(error: Throwable): String = when (error) {
        is ClassNotFoundException -> "Scanner optique Seuic indisponible sur cet appareil."
        is InvocationTargetException -> error.targetException.message ?: "Erreur du scanner optique."
        else -> error.message ?: "Erreur du scanner optique."
    }

    private companion object {
        const val PARAM_EAN13 = 261
        const val PARAM_EAN13_CHECK_DIGIT = 266
        const val PARAM_AIMER = 21
        const val PARAM_ILLUMINATION = 906
    }
}
