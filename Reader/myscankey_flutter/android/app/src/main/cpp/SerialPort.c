/*
 * Implémentation JNI de com.gxwl.device.reader.dal.SerialPort, la classe
 * native attendue par reader.jar (SDK « RFID Desktop Reader ») pour la
 * connexion RS232 Android. Le SDK ne fournit qu'une bibliothèque 32 bits ;
 * celle-ci est compilée pour toutes les ABI de l'application.
 *
 * Le FileDescriptor Java est obtenu par l'API publique ParcelFileDescriptor
 * (aucun accès au champ caché FileDescriptor.descriptor). Une référence
 * globale au ParcelFileDescriptor est conservée jusqu'à close() pour que le
 * ramasse-miettes ne ferme pas le port.
 */
#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <pthread.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include <android/log.h>

#define TAG "BiblioSerialPort"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define MAX_PORTS 8

static jobject open_ports[MAX_PORTS];
static pthread_mutex_t ports_lock = PTHREAD_MUTEX_INITIALIZER;

static speed_t to_speed(jint baudrate) {
    switch (baudrate) {
        case 9600: return B9600;
        case 19200: return B19200;
        case 38400: return B38400;
        case 57600: return B57600;
        case 115200: return B115200;
        case 230400: return B230400;
        case 460800: return B460800;
        case 921600: return B921600;
        default: return B0;
    }
}

static void throw_new(JNIEnv *env, const char *class_name, const char *message) {
    jclass error = (*env)->FindClass(env, class_name);
    if (error != NULL) (*env)->ThrowNew(env, error, message);
}

JNIEXPORT jobject JNICALL
Java_com_gxwl_device_reader_dal_SerialPort_open(JNIEnv *env, jclass clazz, jstring path, jint baudrate, jint flags) {
    (void) clazz;
    speed_t speed = to_speed(baudrate);
    if (speed == B0) {
        LOGE("Unsupported baud rate %d", baudrate);
        return NULL;
    }
    const char *device = (*env)->GetStringUTFChars(env, path, NULL);
    if (device == NULL) return NULL;
    int fd = open(device, O_RDWR | O_NOCTTY | flags);
    if (fd < 0) {
        LOGE("Cannot open %s: %s", device, strerror(errno));
        (*env)->ReleaseStringUTFChars(env, path, device);
        return NULL;
    }
    (*env)->ReleaseStringUTFChars(env, path, device);

    struct termios config;
    if (tcgetattr(fd, &config) != 0) {
        LOGE("tcgetattr failed: %s", strerror(errno));
        close(fd);
        return NULL;
    }
    cfmakeraw(&config);
    cfsetispeed(&config, speed);
    cfsetospeed(&config, speed);
    if (tcsetattr(fd, TCSANOW, &config) != 0) {
        LOGE("tcsetattr failed: %s", strerror(errno));
        close(fd);
        return NULL;
    }

    jclass pfd_class = (*env)->FindClass(env, "android/os/ParcelFileDescriptor");
    jmethodID adopt = (*env)->GetStaticMethodID(env, pfd_class, "adoptFd", "(I)Landroid/os/ParcelFileDescriptor;");
    jmethodID get_fd = (*env)->GetMethodID(env, pfd_class, "getFileDescriptor", "()Ljava/io/FileDescriptor;");
    jobject pfd = (*env)->CallStaticObjectMethod(env, pfd_class, adopt, fd);
    if ((*env)->ExceptionCheck(env) || pfd == NULL) {
        close(fd);
        return NULL;
    }
    jobject descriptor = (*env)->CallObjectMethod(env, pfd, get_fd);

    pthread_mutex_lock(&ports_lock);
    int slot = -1;
    for (int index = 0; index < MAX_PORTS; index++) {
        if (open_ports[index] == NULL) {
            slot = index;
            break;
        }
    }
    if (slot >= 0) open_ports[slot] = (*env)->NewGlobalRef(env, pfd);
    pthread_mutex_unlock(&ports_lock);
    if (slot < 0) {
        LOGE("Too many serial ports open");
        jmethodID close_pfd = (*env)->GetMethodID(env, pfd_class, "close", "()V");
        (*env)->CallVoidMethod(env, pfd, close_pfd);
        (*env)->ExceptionClear(env);
        return NULL;
    }
    return descriptor;
}

JNIEXPORT void JNICALL
Java_com_gxwl_device_reader_dal_SerialPort_close(JNIEnv *env, jobject thiz) {
    jclass port_class = (*env)->GetObjectClass(env, thiz);
    jfieldID fd_field = (*env)->GetFieldID(env, port_class, "mFd", "Ljava/io/FileDescriptor;");
    jobject descriptor = (*env)->GetObjectField(env, thiz, fd_field);
    if (descriptor == NULL) return;

    jclass pfd_class = (*env)->FindClass(env, "android/os/ParcelFileDescriptor");
    jmethodID get_fd = (*env)->GetMethodID(env, pfd_class, "getFileDescriptor", "()Ljava/io/FileDescriptor;");
    jmethodID close_pfd = (*env)->GetMethodID(env, pfd_class, "close", "()V");

    jobject owner = NULL;
    pthread_mutex_lock(&ports_lock);
    for (int index = 0; index < MAX_PORTS; index++) {
        if (open_ports[index] == NULL) continue;
        jobject candidate = (*env)->CallObjectMethod(env, open_ports[index], get_fd);
        if ((*env)->IsSameObject(env, candidate, descriptor)) {
            owner = open_ports[index];
            open_ports[index] = NULL;
            break;
        }
    }
    pthread_mutex_unlock(&ports_lock);
    if (owner == NULL) return;
    (*env)->CallVoidMethod(env, owner, close_pfd);
    (*env)->ExceptionClear(env);
    (*env)->DeleteGlobalRef(env, owner);
}

JNIEXPORT void JNICALL
Java_com_gxwl_device_reader_dal_SerialPort_setParity(JNIEnv *env, jobject thiz, jint fd, jint data_bits, jint stop_bits, jint parity) {
    (void) thiz;
    (void) fd;
    (void) data_bits;
    (void) stop_bits;
    (void) parity;
    // Le client série du SDK n'utilise pas la parité : 8N1 est appliqué à
    // l'ouverture.
    throw_new(env, "java/lang/UnsupportedOperationException", "Parité série non prise en charge.");
}
