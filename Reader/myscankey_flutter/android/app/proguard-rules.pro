# SDK « RFID Desktop Reader » (reader.jar) : réflexion interne et classe
# JNI SerialPort (champ mFd lu par libSerialPort, constructeur utilisé tel
# quel). R8 ne doit ni renommer ni simplifier ces classes.
-keep class com.gg.reader.** { *; }
-keep class com.gxwl.device.reader.** { *; }
-keep class cn.pda.serialport.** { *; }
-dontwarn gnu.io.**
-dontwarn com.sun.crypto.provider.**
