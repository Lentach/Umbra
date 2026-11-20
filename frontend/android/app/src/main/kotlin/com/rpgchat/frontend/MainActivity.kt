package com.fireplace.app

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // (lxxvii) clause 4: the fp-link fragment of a VIEW intent
    // (https://fireplace.ignorelist.com/link#fp-link.…), parked until Dart
    // asks for it. One-shot: consumeLinkFragment clears it, so a resumed
    // activity never replays a stale code. The fragment never left the
    // device — Android hands us the full URI, but fragments are not part of
    // any HTTP request.
    private var pendingLinkFragment: String? = null
    private var linkChannel: MethodChannel? = null
    private val galleryPicker = GalleryPicker(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Screen security (Signal parity): FLAG_SECURE blocks screenshots,
        // screen recording, and — critically — the recents-screen thumbnail,
        // which otherwise persists decrypted chat content in the system's
        // snapshot cache outside our sealed store.
        // Gated on debuggable, NOT BuildConfig (buildConfig generation is off
        // by default under AGP 8): debug builds keep screenshots for emulator
        // work; every shippable build (release/profile) is protected.
        val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        // Cold start via the /link intent-filter.
        pendingLinkFragment = linkFragmentOf(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        linkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fireplace/link",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeLinkFragment" -> {
                        val fragment = pendingLinkFragment
                        pendingLinkFragment = null
                        result.success(fragment)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fireplace/gallery",
        ).setMethodCallHandler(galleryPicker)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (galleryPicker.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm start (launchMode singleTop): the app was already running when
        // the link was tapped. Park the fragment AND push it to Dart — a live
        // session has long passed its boot-time consumeLinkFragment call.
        val fragment = linkFragmentOf(intent) ?: return
        pendingLinkFragment = fragment
        linkChannel?.invokeMethod("linkFragment", fragment)
    }

    private fun linkFragmentOf(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val fragment = intent.data?.fragment ?: return null
        return if (fragment.startsWith("fp-link.")) fragment else null
    }
}
