package studio.encore.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Receives songs sent from other apps (IMP-05).
 *
 * Android hands a share or an "open with" to the activity as an intent
 * carrying a `content://` URI, which is a handle to another app's data rather
 * than a path — Encore cannot decode it directly, and the permission to read
 * it lasts only as long as this intent. So each incoming URI is copied into
 * our own cache directory straight away and the copy's path is what Dart sees.
 *
 * Delivery is pull-then-push. An intent that started the app arrives before
 * Dart is listening, so it is held in [pending] until Dart asks for it with
 * `takePending`; intents that arrive while the app is already running are
 * pushed over the same channel. Without the pull half, sharing to a cold app
 * silently does nothing.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** Paths received before Dart was ready to be told about them. */
    private val pending = mutableListOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The launch intent is consumed here, before any engine exists.
        pending += extractPaths(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> {
                    val paths = pending.toList()
                    pending.clear()
                    result.success(paths)
                }

                else -> result.notImplemented()
            }
        }
        channel = methodChannel
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // singleTop, so a share into a running app lands here rather than
        // creating a second activity.
        setIntent(intent)
        val paths = extractPaths(intent)
        if (paths.isEmpty()) return
        val open = channel
        if (open == null) {
            pending += paths
        } else {
            open.invokeMethod("onFiles", paths)
        }
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }

    /** Copies every audio URI an intent carries, returning the local paths. */
    private fun extractPaths(intent: Intent?): List<String> {
        if (intent == null) return emptyList()
        val uris = when (intent.action) {
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            Intent.ACTION_SEND -> listOfNotNull(
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM),
            )
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            else -> emptyList()
        }
        return uris.mapNotNull { copyToCache(it) }
    }

    /**
     * Copies [uri] into the app's cache and returns the path, or null if it
     * cannot be read.
     *
     * A failed copy is not worth crashing over — the user simply sees nothing
     * arrive, and can still import the file with the picker.
     */
    private fun copyToCache(uri: Uri): String? = try {
        val directory = File(cacheDir, SHARED_DIRECTORY).apply { mkdirs() }
        val target = File(directory, uniqueName(displayName(uri)))
        contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
            target.absolutePath
        }
    } catch (_: Exception) {
        // Includes SecurityException (the grant expired) and IOException.
        null
    }

    /** The file's own name where the provider offers one, so titles survive. */
    private fun displayName(uri: Uri): String {
        if (uri.scheme == "file") {
            uri.lastPathSegment?.let { return it }
        }
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0 && cursor.moveToFirst()) {
                        cursor.getString(column)?.let { return it }
                    }
                }
        } catch (_: Exception) {
            // Fall through to the generic name.
        }
        return uri.lastPathSegment ?: "shared-audio"
    }

    /**
     * Prefixes the name so two shares of "track.mp3" cannot overwrite each
     * other before either has been imported.
     */
    private fun uniqueName(name: String): String {
        val safe = name.replace(Regex("[\\\\/:*?\"<>|]"), "-").ifBlank { "shared-audio" }
        return "${System.currentTimeMillis()}-$safe"
    }

    private companion object {
        const val CHANNEL_NAME = "com.encore/incoming"
        const val SHARED_DIRECTORY = "shared"
    }
}
