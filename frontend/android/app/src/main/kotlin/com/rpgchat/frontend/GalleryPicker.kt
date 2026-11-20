package com.fireplace.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.ext.SdkExtensions
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * The chat's Gallery door where Android has no system photo picker (Android 12
 * and older without the Google Play services backport, owner report
 * 2026-11-21: on such a phone image_picker opens the document browser, "a
 * file picker, not a gallery"). Opens the device's gallery apps (an app
 * that answers ACTION_PICK for both photos and videos but not audio: MIUI
 * Gallery, Google Photos, …) with several items allowed, copies each pick into
 * `cacheDir/<uuid>/<name>` (the launch sweep's image_picker pattern deletes
 * it) and returns the paths.
 *
 * Channel `fireplace/gallery`:
 *  - `systemPhotoPickerAvailable` → Boolean: image_picker's photo picker
 *    will show a real gallery grid.
 *  - `pickFromGalleryApp` → null when no gallery app exists (the caller
 *    falls back), else the picked file paths (empty: cancelled).
 */
class GalleryPicker(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null
    private val io = Executors.newSingleThreadExecutor()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "systemPhotoPickerAvailable" -> result.success(systemPhotoPickerAvailable())
            "pickFromGalleryApp" -> pickFromGalleryApp(result)
            else -> result.notImplemented()
        }
    }

    /** Mirrors androidx.activity's PickVisualMedia availability check. */
    private fun systemPhotoPickerAvailable(): Boolean =
        Build.VERSION.SDK_INT >= 33 ||
            (Build.VERSION.SDK_INT >= 30 &&
                SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2) ||
            activity.packageManager.resolveActivity(
                Intent("androidx.activity.result.contract.action.PICK_IMAGES"),
                0,
            ) != null

    private fun galleryApps(): List<String> {
        val pm = activity.packageManager
        fun handlers(type: String) =
            pm.queryIntentActivities(Intent(Intent.ACTION_PICK).setType(type), 0)
                .map { it.activityInfo.packageName }
                .toSet()
        // A file manager answers for audio too (MIUI lists it twice, as
        // "Audio files" and "File Manager"): galleries only.
        return (handlers("image/*") intersect handlers("video/*") - handlers("audio/*")).toList()
    }

    private fun pickIntent(packageName: String): Intent =
        Intent(Intent.ACTION_PICK)
            .setType("*/*")
            .setPackage(packageName)
            .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)

    private fun pickFromGalleryApp(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "a gallery pick is already open", null)
            return
        }
        val apps = galleryApps()
        if (apps.isEmpty()) {
            result.success(null)
            return
        }
        val first = pickIntent(apps.first())
        val launch = if (apps.size == 1) {
            first
        } else {
            Intent.createChooser(first, null).putExtra(
                Intent.EXTRA_INITIAL_INTENTS,
                apps.drop(1).map(::pickIntent).toTypedArray(),
            )
        }
        pending = result
        try {
            activity.startActivityForResult(launch, REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            pending = null
            result.success(null)
        }
    }

    /** True when [requestCode] was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<String>())
            return true
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        }
        if (uris.isEmpty()) data.data?.let(uris::add)
        io.execute {
            val paths = uris.mapNotNull(::copyToCache)
            activity.runOnUiThread { result.success(paths) }
        }
        return true
    }

    private fun copyToCache(uri: Uri): String? = try {
        val dir = File(activity.cacheDir, UUID.randomUUID().toString()).apply { mkdirs() }
        val out = File(dir, File(displayName(uri)).name)
        activity.contentResolver.openInputStream(uri)?.use { input ->
            out.outputStream().use { input.copyTo(it) }
        } ?: throw IllegalStateException("no stream")
        out.absolutePath
    } catch (e: Exception) {
        null
    }

    private fun displayName(uri: Uri): String {
        activity.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0)?.let { return it } }
        val ext = MimeTypeMap.getSingleton()
            .getExtensionFromMimeType(activity.contentResolver.getType(uri))
        return if (ext == null) "media" else "media.$ext"
    }

    companion object {
        private const val REQUEST_CODE = 0x6A11
    }
}
