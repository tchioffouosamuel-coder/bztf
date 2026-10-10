# SDK « RFID Desktop Reader » (reader.jar) : réflexion interne et classe
# JNI SerialPort (champ mFd lu par libSerialPort, constructeur utilisé tel
# quel). R8 ne doit ni renommer ni simplifier ces classes.
-keep class com.gg.reader.** { *; }
-keep class com.gxwl.device.reader.** { *; }
-keep class cn.pda.serialport.** { *; }

# N01 SDK: Gson reflects on enum constants and protocol model fields.
# The serial JNI library also looks up SerialPort.mFd by its original name.
-keep class ZAO_API.** { *; }
-keep class Tool.** { *; }
-keep class Interface.** { *; }
-keep class android_serialport_api.** { *; }

-dontwarn gnu.io.**
-dontwarn com.sun.crypto.provider.**
