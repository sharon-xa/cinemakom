package io.github.sharon_xa.cinemakom

import android.Manifest
import android.app.UiModeManager
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.view.Display
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The phone and tablet entry, declared portrait in the manifest. TVs launch
 * [TvActivity] (landscape, LEANBACK_LAUNCHER), which is this same activity.
 */
open class MainActivity : FlutterActivity() {
    private val isTv: Boolean by lazy { isTvDevice() }

    override fun onCreate(savedInstanceState: Bundle?) {
        // A TV that opens this entry anyway (`flutter run`, a launcher that
        // lists LAUNCHER apps) gets landscape. Phones keep the manifest's
        // portrait.
        if (isTv) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        super.onCreate(savedInstanceState)
        requestHighestRefreshRate()
    }

    // TVs draw with Skia, not Impeller: on the TCL (MediaTek MT5896) Impeller
    // on Vulkan showed a 4K video frame too long every 1-2 s, Skia almost
    // never; 1080p was smooth on both (docs/TV.md §9, 2026-11-21). Flutter
    // plans to remove this opt-out: re-measure with tool/tv_cadence.sh when
    // upgrading Flutter. Phones keep Impeller.
    override fun getFlutterShellArgs(): FlutterShellArgs =
        super.getFlutterShellArgs().apply {
            if (isTv) add(FlutterShellArgs.ARG_DISABLE_IMPELLER)
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLATFORM_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> result.success(isTv)
                // Free bytes where downloads go (docs/TV.md §7.4). The folder
                // may not exist yet (Movies/Cinemakom before the first
                // download): ask its nearest existing parent, same volume.
                "freeBytes" -> result.success(
                    try {
                        var dir: File? = File(call.argument<String>("path")!!)
                        while (dir != null && !dir.exists()) dir = dir.parentFile
                        dir?.let { StatFs(it.path).availableBytes }
                    } catch (e: Exception) {
                        null
                    },
                )
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                // The app's memory as `dumpsys meminfo` sums it (Java heap,
                // native, graphics…), in kB, for the memory test
                // (docs/MEMORY.md §4.1).
                "memoryStats" -> result.success(
                    Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.memoryStats,
                )
                // The memory test only (docs/MEMORY.md §4.4): what Java keeps
                // once its garbage is collected. The app never calls it.
                "collectGarbage" -> {
                    Runtime.getRuntime().gc()
                    result.success(null)
                }
                "publicMoviesDir" -> result.success(
                    try {
                        @Suppress("DEPRECATION")
                        val movies = Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_MOVIES,
                        )
                        File(movies, "Cinemakom").absolutePath
                    } catch (e: Exception) {
                        null
                    },
                )
                "hasLegacyStoragePermission" -> result.success(
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
                        ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.WRITE_EXTERNAL_STORAGE,
                        ) == PackageManager.PERMISSION_GRANTED,
                )
                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        MediaScannerConnection.scanFile(
                            applicationContext,
                            arrayOf(path),
                            null,
                            null,
                        )
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CONNECTIVITY_CHANNEL,
        ).setStreamHandler(ConnectivityStreamHandler(applicationContext))
    }

    private fun isTvDevice(): Boolean {
        val uiMode = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }
        return packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // The resolution can change without a restart (configChanges), and
        // the preferred mode must have the current one.
        requestHighestRefreshRate()
    }

    /**
     * Asks for the display's fastest mode at the current resolution.
     *
     * Some vendors (OnePlus/OPPO ColorOS among them) run every app that isn't
     * on their allowlist at 60 Hz, even on a 120 Hz panel with the system set
     * to 120 Hz. Flutter draws at whatever rate the display runs, so the app
     * looked half as smooth as the rest of the phone. This is a preference,
     * not a lock: battery saver, thermal limits and the user's own refresh
     * setting still win, and it only applies while this window is in front.
     *
     * Not on TVs: there a display mode is an HDMI output mode, and switching
     * it blanks the screen or leaves 4K60 (docs/TV.md §3).
     */
    private fun requestHighestRefreshRate() {
        if (isTv) return
        @Suppress("DEPRECATION")
        val display: Display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else null)
            ?: windowManager.defaultDisplay
        val current = display.mode
        val best = display.supportedModes
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .maxByOrNull { it.refreshRate } ?: return
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId == best.modeId) return
        attributes.preferredDisplayModeId = best.modeId
        window.attributes = attributes
    }

    companion object {
        private const val PLATFORM_CHANNEL = "io.github.sharon_xa.cinemakom/platform"
        private const val CONNECTIVITY_CHANNEL = "io.github.sharon_xa.cinemakom/connectivity"
    }
}

/**
 * Emits `true` when the default network offers internet, `false` when there
 * is none (docs/DOWNLOADS.md §5.5: pause downloads while offline so their
 * resume data is kept, and resume when the network returns).
 *
 * Internet, not *validated* internet: validation is Google's connectivity
 * probe, which fails on networks that reach the Cinemana CDN fine (local ISP
 * routing without international access, VPNs). A wrong "offline" would pause
 * every download for nothing; a wrong "online" only lets the engine retry.
 *
 * Callbacks arrive on a binder thread: everything is handled on the main
 * thread, and each change is debounced so a network switch (Wi-Fi to mobile)
 * or `onLost` reading the network it just lost doesn't flap.
 */
private class ConnectivityStreamHandler(
    private val context: Context,
) : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var sink: EventChannel.EventSink? = null
    private var lastOnline: Boolean? = null
    private val check = Runnable { checkNow() }

    private fun checkNow() {
        val events = sink ?: return
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        val online = try {
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } catch (_: Exception) {
            true
        }
        if (online == lastOnline) return
        lastOnline = online
        events.success(online)
    }

    /** Checks again once things settle (main thread, debounced). */
    private fun schedule() {
        mainHandler.removeCallbacks(check)
        mainHandler.postDelayed(check, DEBOUNCE_MS)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        sink = events
        checkNow()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = schedule()
            override fun onLost(network: Network) = schedule()
            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) = schedule()
            override fun onUnavailable() = schedule()
        }
        callback = cb
        try {
            cm.registerDefaultNetworkCallback(cb)
        } catch (_: Exception) {
            // Permission or OS quirk; the first answer stays.
        }
    }

    override fun onCancel(arguments: Any?) {
        mainHandler.removeCallbacks(check)
        sink = null
        lastOnline = null
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val cb = callback
        callback = null
        if (cm != null && cb != null) {
            try {
                cm.unregisterNetworkCallback(cb)
            } catch (_: Exception) {
                // Already unregistered.
            }
        }
    }

    companion object {
        private const val DEBOUNCE_MS = 1500L
    }
}
