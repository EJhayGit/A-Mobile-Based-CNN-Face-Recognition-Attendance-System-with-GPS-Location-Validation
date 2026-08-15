package com.example.offline_trucking_attendance

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WindowBrightnessBridge(
    private val activity: FlutterActivity,
    flutterEngine: FlutterEngine,
) {
    private var previousBrightness: Float? = null

    init {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "thesis.liveness/brightness",
        ).setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setBrightness" -> {
                    val level = call.argument<Double>("level")
                        ?: throw IllegalArgumentException("Missing brightness level.")
                    require(level in 0.0..1.0) { "Brightness must be between 0 and 1." }
                    if (previousBrightness == null) {
                        previousBrightness = activity.window.attributes.screenBrightness
                    }
                    val attributes = activity.window.attributes
                    attributes.screenBrightness = level.toFloat()
                    activity.window.attributes = attributes
                    result.success(null)
                }
                "restoreBrightness" -> {
                    restore()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("window_brightness", error.message, null)
        }
    }

    fun restore() {
        val previous = previousBrightness ?: return
        val attributes = activity.window.attributes
        attributes.screenBrightness = previous
        activity.window.attributes = attributes
        previousBrightness = null
    }
}
