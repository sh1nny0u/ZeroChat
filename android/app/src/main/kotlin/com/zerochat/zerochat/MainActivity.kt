package com.zerochat.zerochat

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build

class MainActivity : FlutterActivity() {
    private var deliveryChannel: MethodChannel? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zerochat/session").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(SessionVault.read(this, call.argument<String>("server")!!))
                    "write" -> {
                        val value = listOf("server", "token", "identity", "session_id").associateWith { call.argument<String>(it)!! }
                        SessionVault.write(this, value)
                        result.success(null)
                    }
                    "clear" -> { SessionVault.clear(this); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("session_vault", "安全登录凭证操作失败，请重试或重新登录", null) }
        }
        deliveryChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zerochat/delivery").apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "enable" -> {
                            DeliveryService.configure(this@MainActivity, call.argument<String>("server")!!, call.argument<String>("authorization")!!)
                            val service = Intent(this@MainActivity, DeliveryService::class.java)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                            result.success(null)
                        }
                        "disable" -> { DeliveryService.disable(this@MainActivity); result.success(null) }
                        "status" -> result.success(DeliveryService.running)
                        "cancelChat" -> { DeliveryService.cancelChat(this@MainActivity, call.argument<String>("chat")!!); result.success(null) }
                        "claim" -> result.success(DeliveryService.claim(this@MainActivity, call.argument<String>("chat")!!, call.argument<List<String>>("ids")!!))
                        "launchChat" -> { val id = intent.getStringExtra("delivery_chat"); intent.removeExtra("delivery_chat"); result.success(id) }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { result.error("delivery", "后台接收未启动，请检查系统权限", null) }
            }
        }
    }
    override fun onResume() { super.onResume(); DeliveryService.visible = true }
    override fun onPause() { DeliveryService.visible = false; super.onPause() }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent)
        intent.getStringExtra("delivery_chat")?.let {
            intent.removeExtra("delivery_chat")
            deliveryChannel?.invokeMethod("openChat", it)
        }
    }
}
