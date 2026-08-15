package com.example.offline_trucking_attendance

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class ConnectivityBridge(
    private val activity: MainActivity,
    flutterEngine: FlutterEngine,
) : EventChannel.StreamHandler {
    private val manager =
        activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val channel = EventChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "thesis.connectivity/events",
    )
    private var events: EventChannel.EventSink? = null
    private var registered = false
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = emit(isOnline())

        override fun onLost(network: Network) = emit(isOnline())

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) = emit(isOnline())
    }

    init {
        channel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        events = sink
        if (!registered) {
            manager.registerNetworkCallback(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build(),
                callback,
            )
            registered = true
        }
        emit(isOnline())
    }

    override fun onCancel(arguments: Any?) {
        events = null
        unregister()
    }

    fun shutdown() {
        events = null
        unregister()
        channel.setStreamHandler(null)
    }

    private fun unregister() {
        if (!registered) return
        manager.unregisterNetworkCallback(callback)
        registered = false
    }

    private fun isOnline(): Boolean {
        val network = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun emit(value: Boolean) {
        activity.runOnUiThread { events?.success(value) }
    }
}
