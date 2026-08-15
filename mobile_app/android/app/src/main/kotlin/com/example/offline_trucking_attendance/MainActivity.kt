package com.example.offline_trucking_attendance

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.FloatBuffer
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    private val channelName = "thesis.embedding/runtime"
    private val navigationChannelName = "thesis.navigation/runtime"
    private val modelAsset = "assets/models/final_face_embedding_fp32_opset18.onnx"
    private val environment: OrtEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private var session: OrtSession? = null
    private var provider = "uninitialized"
    private var livenessBridge: MediaPipeLivenessBridge? = null
    private var brightnessBridge: WindowBrightnessBridge? = null
    private var connectivityBridge: ConnectivityBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "loadModel" -> {
                            ensureSession(flutterEngine)
                            result.success(provider)
                        }
                        "inferAlignedImage" -> {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("Missing aligned image path.")
                            result.success(inferAlignedImage(flutterEngine, path))
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("embedding_runtime", error.message, null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, navigationChannelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "openDirections" -> {
                            val latitude = call.argument<Double>("latitude")
                                ?: throw IllegalArgumentException("Missing latitude.")
                            val longitude = call.argument<Double>("longitude")
                                ?: throw IllegalArgumentException("Missing longitude.")
                            val label = call.argument<String>("label") ?: "Destination"
                            openDirections(latitude, longitude, label)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("navigation_runtime", error.message, null)
                }
            }
        livenessBridge = MediaPipeLivenessBridge(this, flutterEngine)
        brightnessBridge = WindowBrightnessBridge(this, flutterEngine)
        connectivityBridge = ConnectivityBridge(this, flutterEngine)
    }

    private fun openDirections(latitude: Double, longitude: Double, label: String) {
        require(latitude.isFinite() && latitude in -90.0..90.0) { "Invalid latitude." }
        require(longitude.isFinite() && longitude in -180.0..180.0) { "Invalid longitude." }
        val query = Uri.encode("$latitude,$longitude($label)")
        val mapsIntent = Intent(Intent.ACTION_VIEW, Uri.parse("geo:$latitude,$longitude?q=$query"))
            .setPackage("com.google.android.apps.maps")
        try {
            startActivity(mapsIntent)
        } catch (_: ActivityNotFoundException) {
            val webUrl = Uri.parse(
                "https://www.google.com/maps/dir/?api=1&destination=$latitude,$longitude",
            )
            startActivity(Intent(Intent.ACTION_VIEW, webUrl))
        }
    }

    private fun ensureSession(flutterEngine: FlutterEngine): OrtSession {
        session?.let { return it }
        val assetKey =
            FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(modelAsset)
        val modelBytes = assets.open(assetKey).use { it.readBytes() }
        val xnnOptions = OrtSession.SessionOptions()
        try {
            xnnOptions.addXnnpack(mapOf("intra_op_num_threads" to "1"))
            session = environment.createSession(modelBytes, xnnOptions)
            provider = "XNNPACK"
        } catch (_: Exception) {
            xnnOptions.close()
            val cpuOptions = OrtSession.SessionOptions()
            session = environment.createSession(modelBytes, cpuOptions)
            provider = "CPU"
        }
        return checkNotNull(session)
    }

    private fun inferAlignedImage(
        flutterEngine: FlutterEngine,
        imagePath: String,
    ): List<Double> {
        val bitmap = BitmapFactory.decodeFile(imagePath)
            ?: throw IllegalArgumentException("Aligned image could not be decoded.")
        require(bitmap.width == 224 && bitmap.height == 224) {
            "Expected a 224x224 aligned image, got ${bitmap.width}x${bitmap.height}."
        }
        val pixels = IntArray(224 * 224)
        bitmap.getPixels(pixels, 0, 224, 0, 0, 224, 224)
        bitmap.recycle()

        val input = FloatArray(3 * 224 * 224)
        val plane = 224 * 224
        for (index in pixels.indices) {
            val pixel = pixels[index]
            val red = ((pixel shr 16) and 0xff) / 255.0f
            val green = ((pixel shr 8) and 0xff) / 255.0f
            val blue = (pixel and 0xff) / 255.0f
            input[index] = (red - 0.485f) / 0.229f
            input[plane + index] = (green - 0.456f) / 0.224f
            input[2 * plane + index] = (blue - 0.406f) / 0.225f
        }

        val runtime = ensureSession(flutterEngine)
        val inputName = runtime.inputNames.first()
        OnnxTensor.createTensor(
            environment,
            FloatBuffer.wrap(input),
            longArrayOf(1, 3, 224, 224),
        ).use { tensor ->
            runtime.run(mapOf(inputName to tensor)).use { outputs ->
                @Suppress("UNCHECKED_CAST")
                val values = (outputs[0].value as Array<FloatArray>)[0]
                require(values.size == 128) {
                    "Expected 128 embedding values, got ${values.size}."
                }
                require(values.all { it.isFinite() }) {
                    "Embedding contains a non-finite value."
                }
                val norm = sqrt(values.sumOf { (it * it).toDouble() })
                require(kotlin.math.abs(norm - 1.0) <= 1e-3) {
                    "Embedding norm $norm is outside the frozen tolerance."
                }
                return values.map { it.toDouble() }
            }
        }
    }

    override fun onDestroy() {
        brightnessBridge?.restore()
        brightnessBridge = null
        connectivityBridge?.shutdown()
        connectivityBridge = null
        livenessBridge?.shutdown()
        livenessBridge = null
        session?.close()
        session = null
        super.onDestroy()
    }

    override fun onPause() {
        brightnessBridge?.restore()
        livenessBridge?.cancelSession()
        super.onPause()
    }
}
