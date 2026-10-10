package com.bibliorfid.myscankey_flutter

/** Frames N01 JSON objects across arbitrary TCP/serial read boundaries. */
internal class N01JsonStream {
    private val pending = StringBuilder()
    private var depth = 0
    private var inString = false
    private var escaped = false

    @Synchronized
    fun accept(chunk: String): List<String> {
        val messages = mutableListOf<String>()
        for (char in chunk) {
            if (depth == 0 && char != '{') continue
            pending.append(char)
            if (inString) {
                when {
                    escaped -> escaped = false
                    char == '\\' -> escaped = true
                    char == '"' -> inString = false
                }
            } else {
                when (char) {
                    '"' -> inString = true
                    '{' -> depth++
                    '}' -> if (--depth == 0) {
                        messages.add(pending.toString())
                        pending.setLength(0)
                    }
                }
            }
        }
        return messages
    }
}
