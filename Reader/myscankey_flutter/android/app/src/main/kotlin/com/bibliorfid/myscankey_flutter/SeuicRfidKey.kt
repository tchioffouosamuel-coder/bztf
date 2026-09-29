package com.bibliorfid.myscankey_flutter

import com.seuic.scankey.IKeyEventCallback
import com.seuic.scankey.ScanKeyService

// Isolé de MainActivity : scankey.jar n'est fourni que par le système des
// terminaux Seuic. Sur un autre appareil (poste RK3568), charger une classe qui
// y fait référence ferait planter l'application dès son lancement.
class SeuicRfidKey(
	private val keyCode: Int,
	private val onKeyDown: (Int) -> Unit,
	private val onKeyUp: (Int) -> Unit,
) {
	private val callback = object : IKeyEventCallback.Stub() {
		override fun onKeyDown(keyCode: Int) = this@SeuicRfidKey.onKeyDown(keyCode)
		override fun onKeyUp(keyCode: Int) = this@SeuicRfidKey.onKeyUp(keyCode)
	}

	fun register() {
		ScanKeyService.getInstance().registerCallback(callback, keyCode.toString())
	}

	fun unregister() {
		ScanKeyService.getInstance().unregisterCallback(callback)
	}

	companion object {
		fun isAvailable(): Boolean = try {
			Class.forName("com.seuic.scankey.ScanKeyService")
			Class.forName("com.seuic.scankey.IKeyEventCallback\$Stub")
			true
		} catch (_: Throwable) {
			false
		}
	}
}
