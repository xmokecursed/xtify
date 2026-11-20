package com.xmokecursed.xtify

import android.annotation.TargetApi
import android.app.ActivityManager
import android.app.Application
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class XtifyApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val dir = File(filesDir, "logs")
        try {
            CrashRecords.watch(dir)
        } catch (e: Throwable) {
        }
        Thread {
            try {
                CrashRecords.save(this, dir)
            } catch (e: Throwable) {
            }
        }.start()
    }
}

object CrashRecords {
    private const val KEEP_CRASHES = 5
    private val urlQuery = Regex("""(https?://[^\s?]+)\?\S{20,}""")
    private val secret =
        Regex("""(cookie|authorization|sapisid|sid|token|key)(=|:)\s*\S+""", RegexOption.IGNORE_CASE)

    fun watch(dir: File) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                writeCrash(dir, thread, error)
            } catch (e: Throwable) {
            }
            previous?.uncaughtException(thread, error)
        }
    }

    fun save(context: Context, dir: File) {
        dir.mkdirs()
        val crashes = crashFiles(dir)
        try {
            crashes.drop(KEEP_CRASHES).forEach { it.delete() }
        } catch (e: Throwable) {
        }
        val out = StringBuilder()
        out.appendLine(
            "Device: ${Build.MANUFACTURER} ${Build.MODEL}, " +
                "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
        )
        try {
            val recent = crashes.take(2)
            if (recent.isNotEmpty()) {
                out.appendLine("Java crashes, newest first:")
                for (file in recent) out.appendLine(file.readText().trimEnd())
            }
        } catch (e: Throwable) {
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                ExitRecords.append(context, out)
            } catch (e: Throwable) {
            }
        }
        File(dir, "android-records.txt").writeText(out.toString())
    }

    internal fun stamp(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(millis))

    internal fun redact(text: String): String =
        text.replace(urlQuery) { it.groupValues[1] + "?..." }
            .replace(secret) { it.groupValues[1] + it.groupValues[2] + "..." }

    private fun writeCrash(dir: File, thread: Thread, error: Throwable) {
        dir.mkdirs()
        val pid = android.os.Process.myPid()
        val out = StringBuilder()
        out.appendLine("${stamp(System.currentTimeMillis())}  pid $pid  thread ${thread.name}")
        for (line in redact(error.stackTraceToString().take(4000)).take(3500).lines()) {
            out.appendLine("  $line")
        }
        File(dir, "crash-$pid.txt").writeText(out.toString())
    }

    private fun crashFiles(dir: File): List<File> {
        val found = dir.listFiles { _, name -> name.startsWith("crash-") && name.endsWith(".txt") }
        return found?.sortedByDescending { it.lastModified() } ?: emptyList()
    }
}

@TargetApi(Build.VERSION_CODES.R)
object ExitRecords {
    private val libraryPath =
        Regex("""/[A-Za-z0-9_.@=~+-]+(?:/[A-Za-z0-9_.@=~+-]+)*\.(?:so|apk|oat|odex|vdex|jar|art)""")
    private val symbol = Regex("""_Z[A-Za-z0-9_$]{3,}""")

    fun append(context: Context, out: StringBuilder) {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val records = manager.getHistoricalProcessExitReasons(null, 0, 8)
        if (records.isEmpty()) {
            out.appendLine("Android has no record of earlier runs yet.")
            return
        }
        out.appendLine("How Android says earlier runs ended, newest first:")
        var traces = 0
        for (info in records) {
            val reason = info.reason
            out.appendLine(
                "${CrashRecords.stamp(info.timestamp)}  pid ${info.pid}  ${reasonName(reason)}  " +
                    "${importanceName(info.importance)}  memory ${info.rss / 1024} MB"
            )
            out.appendLine("  ${exitDetail(reason, info.status)}")
            val note = info.description
            if (!note.isNullOrBlank()) out.appendLine("  note: ${CrashRecords.redact(note)}")
            val native = reason == ApplicationExitInfo.REASON_CRASH_NATIVE
            val stuck = reason == ApplicationExitInfo.REASON_ANR
            if (traces < 2 && (native || stuck)) {
                val trace = traceText(info, stuck)
                if (trace.isNotEmpty()) {
                    traces++
                    out.appendLine("  from Android's report:")
                    for (line in trace.lines()) out.appendLine("    $line")
                }
            }
        }
    }

    private fun traceText(info: ApplicationExitInfo, stuck: Boolean): String {
        return try {
            val stream = info.traceInputStream ?: return ""
            val bytes = stream.use { readUpTo(it, 65536) }
            if (stuck) stackLines(bytes) else nativeParts(bytes)
        } catch (e: Throwable) {
            ""
        }
    }

    private fun readUpTo(stream: InputStream, limit: Int): ByteArray {
        val buffer = ByteArray(limit)
        var filled = 0
        while (filled < limit) {
            val count = stream.read(buffer, filled, limit - filled)
            if (count < 0) break
            filled += count
        }
        return buffer.copyOf(filled)
    }

    private fun stackLines(bytes: ByteArray): String {
        val out = StringBuilder()
        for (line in String(bytes, Charsets.UTF_8).lines()) {
            val clean = line.trimEnd()
            if (clean.length < 4) continue
            out.appendLine(clean)
            if (out.length >= 2500) break
        }
        return CrashRecords.redact(out.toString()).take(2500).trimEnd()
    }

    private fun nativeParts(bytes: ByteArray): String {
        val found = LinkedHashSet<String>()
        val run = StringBuilder()
        fun closeRun() {
            if (run.length >= 5) {
                val text = run.toString()
                libraryPath.findAll(text).forEach { found.add(it.value) }
                symbol.findAll(text).forEach { found.add(it.value) }
            }
            run.setLength(0)
        }
        for (b in bytes) {
            val code = b.toInt() and 0xFF
            if (code !in 32..126) {
                closeRun()
            } else if (run.length < 400) {
                run.append(code.toChar())
            }
        }
        closeRun()
        val out = StringBuilder()
        for (item in found) {
            if (out.length + item.length > 2500) break
            out.appendLine(item)
        }
        return out.toString().trimEnd()
    }

    private fun exitDetail(reason: Int, status: Int): String =
        if (reason == ApplicationExitInfo.REASON_SIGNALED ||
            reason == ApplicationExitInfo.REASON_CRASH_NATIVE
        ) {
            "signal ${signalName(status)}"
        } else {
            "exit status $status"
        }

    private fun signalName(number: Int): String = when (number) {
        1 -> "SIGHUP (1)"
        2 -> "SIGINT (2)"
        3 -> "SIGQUIT (3)"
        4 -> "SIGILL (4)"
        5 -> "SIGTRAP (5)"
        6 -> "SIGABRT (6)"
        7 -> "SIGBUS (7)"
        8 -> "SIGFPE (8)"
        9 -> "SIGKILL (9)"
        11 -> "SIGSEGV (11)"
        13 -> "SIGPIPE (13)"
        15 -> "SIGTERM (15)"
        else -> "$number"
    }

    private fun reasonName(reason: Int): String {
        val name = when (reason) {
            ApplicationExitInfo.REASON_EXIT_SELF -> "the app closed itself"
            ApplicationExitInfo.REASON_SIGNALED -> "killed by a signal"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "killed because the phone ran low on memory"
            ApplicationExitInfo.REASON_CRASH -> "crashed (Java or Kotlin exception)"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "crashed in native code"
            ApplicationExitInfo.REASON_ANR -> "stopped responding (ANR)"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "failed to start"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "closed after a permission change"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "killed for using too many resources"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "closed by the user"
            ApplicationExitInfo.REASON_USER_STOPPED -> "stopped by the user"
            ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "killed because something it depends on died"
            ApplicationExitInfo.REASON_OTHER -> "closed for another reason"
            14 -> "frozen and killed by Android"
            15 -> "closed after a package state change"
            16 -> "closed because the app was updated"
            else -> "ended for an unknown reason"
        }
        return "$name [$reason]"
    }

    private fun importanceName(value: Int): String = when {
        value <= 100 -> "in the foreground"
        value <= 125 -> "running a foreground service"
        value <= 230 -> "visible or audible"
        value <= 300 -> "running a background service"
        value < 1000 -> "in the background"
        else -> "already gone"
    }
}
