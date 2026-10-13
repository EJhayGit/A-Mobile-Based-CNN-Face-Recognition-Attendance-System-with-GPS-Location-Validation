package com.example.offline_trucking_attendance

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class DeviceIdentityBridge(flutterEngine: FlutterEngine) {
    private val alias = "agila_authorized_device_v1"
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    init {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "thesis.device_identity/runtime",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getIdentity" -> result.success(identity())
                    "sign" -> {
                        val challenge = call.argument<String>("challenge")
                            ?: throw IllegalArgumentException("Missing device challenge.")
                        result.success(sign(challenge))
                    }
                    "clear" -> {
                        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("device_identity", "Device authorization is unavailable.", null)
            }
        }
    }

    private fun keyEntry(): KeyStore.PrivateKeyEntry {
        val existing = keyStore.getEntry(alias, null) as? KeyStore.PrivateKeyEntry
        if (existing != null) return existing
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore",
        )
        generator.initialize(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .build(),
        )
        generator.generateKeyPair()
        return keyStore.getEntry(alias, null) as KeyStore.PrivateKeyEntry
    }

    private fun identity(): Map<String, String> {
        val publicKey = keyEntry().certificate.publicKey.encoded
        val fingerprint = MessageDigest.getInstance("SHA-256")
            .digest(publicKey)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val label = listOf(Build.MANUFACTURER, Build.MODEL)
            .joinToString(" ")
            .trim()
            .take(120)
        return mapOf(
            "publicKey" to Base64.encodeToString(publicKey, Base64.NO_WRAP),
            "fingerprint" to fingerprint,
            "label" to label,
        )
    }

    private fun sign(challenge: String): String {
        require(challenge.isNotBlank() && challenge.length <= 2048) {
            "Invalid device challenge."
        }
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(keyEntry().privateKey)
            update(challenge.toByteArray(Charsets.UTF_8))
            sign()
        }
        return Base64.encodeToString(signature, Base64.NO_WRAP)
    }
}
