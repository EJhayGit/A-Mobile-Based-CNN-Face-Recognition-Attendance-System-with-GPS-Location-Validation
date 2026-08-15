package com.example.offline_trucking_attendance

import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.components.containers.NormalizedLandmark
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarkerResult
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

class MediaPipeLivenessBridge(
    private val activity: FlutterActivity,
    flutterEngine: FlutterEngine,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val inferenceInFlight = AtomicBoolean(false)
    private val assetKey = FlutterInjector.instance().flutterLoader()
        .getLookupKeyForAsset("assets/models/face_landmarker.task")

    private var faceLandmarker: FaceLandmarker? = null
    private var activeSessionId: String? = null
    private var lastTimestampMs = Long.MIN_VALUE
    @Volatile
    private var shuttingDown = false

    init {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "thesis.liveness/runtime",
        ).setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startSession" -> startSession(call, result)
            "analyzeFrame" -> analyzeFrame(call, result)
            "closeSession" -> closeSession(result)
            else -> result.notImplemented()
        }
    }

    private fun startSession(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId.isNullOrBlank()) {
            result.error("mediapipe_session", "Missing liveness session identifier.", null)
            return
        }
        submit(result, "mediapipe_initialization") {
            closeLandmarker()
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath(assetKey)
                .build()
            val options = FaceLandmarker.FaceLandmarkerOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.VIDEO)
                .setNumFaces(1)
                .setMinFaceDetectionConfidence(0.5f)
                .setMinFacePresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .setOutputFacialTransformationMatrixes(true)
                .build()
            faceLandmarker = FaceLandmarker.createFromOptions(activity, options)
            activeSessionId = sessionId
            lastTimestampMs = Long.MIN_VALUE
            mapOf(
                "sessionId" to sessionId,
                "runningMode" to "VIDEO",
                "maxFaces" to 1,
                "transformationMatrices" to true,
            )
        }
    }

    private fun analyzeFrame(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        val timestampMs = call.argument<Number>("timestampMs")?.toLong()
        val width = call.argument<Number>("width")?.toInt()
        val height = call.argument<Number>("height")?.toInt()
        val bgrBytes = call.argument<ByteArray>("bgrBytes")
        if (sessionId.isNullOrBlank() || timestampMs == null || width == null ||
            height == null || bgrBytes == null
        ) {
            result.error("mediapipe_frame", "Incomplete liveness frame arguments.", null)
            return
        }
        if (width <= 0 || height <= 0 || bgrBytes.size != width * height * 3) {
            result.error("mediapipe_frame", "Invalid owned BGR frame dimensions.", null)
            return
        }
        if (!inferenceInFlight.compareAndSet(false, true)) {
            result.error("mediapipe_busy", "A liveness frame is already in progress.", null)
            return
        }
        submit(result, "mediapipe_inference", finallyAction = {
            inferenceInFlight.set(false)
        }) {
            require(sessionId == activeSessionId) { "Stale liveness session." }
            LivenessSignalMath.requireIncreasingTimestamp(lastTimestampMs, timestampMs)
            val landmarker = checkNotNull(faceLandmarker) {
                "The Face Landmarker session is not initialized."
            }
            lastTimestampMs = timestampMs
            val bitmap = bgrBitmap(bgrBytes, width, height)
            val mpImage = BitmapImageBuilder(bitmap).build()
            try {
                val startedAt = SystemClock.elapsedRealtime()
                val detection = landmarker.detectForVideo(
                    mpImage,
                    timestampMs,
                )
                val elapsedMs = SystemClock.elapsedRealtime() - startedAt
                summarize(sessionId, timestampMs, elapsedMs, bitmap, detection)
            } finally {
                mpImage.close()
                bitmap.recycle()
            }
        }
    }

    private fun closeSession(result: MethodChannel.Result) {
        submit(result, "mediapipe_close") {
            closeLandmarker()
            null
        }
    }

    fun cancelSession() {
        if (shuttingDown) return
        try {
            executor.execute { closeLandmarker() }
        } catch (_: RejectedExecutionException) {
            // Activity teardown already owns cleanup.
        }
    }

    fun shutdown() {
        if (shuttingDown) return
        shuttingDown = true
        try {
            executor.execute { closeLandmarker() }
        } catch (_: RejectedExecutionException) {
            // The executor has already stopped.
        }
        executor.shutdown()
    }

    private fun closeLandmarker() {
        faceLandmarker?.close()
        faceLandmarker = null
        activeSessionId = null
        lastTimestampMs = Long.MIN_VALUE
        inferenceInFlight.set(false)
    }

    private fun submit(
        result: MethodChannel.Result,
        errorCode: String,
        finallyAction: () -> Unit = {},
        operation: () -> Any?,
    ) {
        if (shuttingDown) {
            result.error(errorCode, "The liveness runtime is closing.", null)
            finallyAction()
            return
        }
        try {
            executor.execute {
                try {
                    val value = operation()
                    mainHandler.post { result.success(value) }
                } catch (error: Exception) {
                    val message = error.message ?: error.javaClass.simpleName
                    mainHandler.post { result.error(errorCode, message, null) }
                } finally {
                    finallyAction()
                }
            }
        } catch (_: RejectedExecutionException) {
            finallyAction()
            result.error(errorCode, "The liveness runtime is unavailable.", null)
        }
    }

    private fun bgrBitmap(bytes: ByteArray, width: Int, height: Int): Bitmap {
        val pixels = IntArray(width * height)
        var source = 0
        for (index in pixels.indices) {
            val blue = bytes[source].toInt() and 0xff
            val green = bytes[source + 1].toInt() and 0xff
            val red = bytes[source + 2].toInt() and 0xff
            pixels[index] = LivenessSignalMath.argb(red, green, blue)
            source += 3
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun summarize(
        sessionId: String,
        timestampMs: Long,
        inferenceMs: Long,
        bitmap: Bitmap,
        result: FaceLandmarkerResult,
    ): Map<String, Any?> {
        val faces = result.faceLandmarks()
        val landmarks = faces.firstOrNull()
        val matrix = result.facialTransformationMatrixes()
            .orElse(emptyList())
            .firstOrNull()
        val yaw = LivenessSignalMath.yawDegrees(matrix)
        val geometry = landmarks?.let { geometrySignals(it) }
        val regions = landmarks?.let { sampleSkinRegions(bitmap, it) }.orEmpty()
        return mapOf(
            "sessionId" to sessionId,
            "timestampMs" to timestampMs,
            "resultTimestampMs" to result.timestampMs(),
            "inferenceMs" to inferenceMs,
            "faceCount" to faces.size,
            "landmarkCount" to (landmarks?.size ?: 0),
            "transformationAvailable" to (matrix != null),
            "yawDegrees" to yaw,
            "centerX" to geometry?.get("centerX"),
            "centerY" to geometry?.get("centerY"),
            "faceWidth" to geometry?.get("faceWidth"),
            "skinRegions" to regions,
        )
    }

    private fun geometrySignals(
        landmarks: List<NormalizedLandmark>,
    ): Map<String, Double>? {
        if (landmarks.size < 478) return null
        val xs = landmarks.map { it.x().toDouble() }
        val ys = landmarks.map { it.y().toDouble() }
        return mapOf(
            "centerX" to (xs.minOrNull()!! + xs.maxOrNull()!!) / 2.0,
            "centerY" to (ys.minOrNull()!! + ys.maxOrNull()!!) / 2.0,
            "faceWidth" to (xs.maxOrNull()!! - xs.minOrNull()!!),
        )
    }

    private fun sampleSkinRegions(
        bitmap: Bitmap,
        landmarks: List<NormalizedLandmark>,
    ): Map<String, Map<String, Double>> {
        if (landmarks.size < 478) return emptyMap()
        val eyeDistance = hypot(
            ((landmarks[33].x() - landmarks[263].x()) * bitmap.width).toDouble(),
            ((landmarks[33].y() - landmarks[263].y()) * bitmap.height).toDouble(),
        )
        val radius = max(2, (eyeDistance * 0.06).roundToInt())
        return mapOf(
            "forehead" to sampleRegion(bitmap, landmarks[10], radius),
            "leftCheek" to sampleRegion(bitmap, landmarks[205], radius),
            "rightCheek" to sampleRegion(bitmap, landmarks[425], radius),
            "noseBridge" to sampleRegion(bitmap, landmarks[168], radius),
        )
    }

    private fun sampleRegion(
        bitmap: Bitmap,
        landmark: NormalizedLandmark,
        radius: Int,
    ): Map<String, Double> {
        val centerX = (landmark.x() * bitmap.width).roundToInt()
        val centerY = (landmark.y() * bitmap.height).roundToInt()
        var red = 0L
        var green = 0L
        var blue = 0L
        var count = 0L
        for (y in (centerY - radius)..(centerY + radius)) {
            if (y !in 0 until bitmap.height) continue
            for (x in (centerX - radius)..(centerX + radius)) {
                if (x !in 0 until bitmap.width) continue
                val dx = x - centerX
                val dy = y - centerY
                if (dx * dx + dy * dy > radius * radius) continue
                val pixel = bitmap.getPixel(x, y)
                red += Color.red(pixel)
                green += Color.green(pixel)
                blue += Color.blue(pixel)
                count++
            }
        }
        if (count == 0L) return emptyMap()
        return mapOf(
            "red" to red.toDouble() / count,
            "green" to green.toDouble() / count,
            "blue" to blue.toDouble() / count,
        )
    }
}
