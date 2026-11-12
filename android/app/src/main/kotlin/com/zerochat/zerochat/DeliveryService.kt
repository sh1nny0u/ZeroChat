package com.zerochat.zerochat

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Explicit, read-only delivery. No provider calls, message text, or plaintext token on disk. */
class DeliveryService : Service() {
    companion object {
        @Volatile var visible = false
        @Volatile var running = false
        @Volatile private var generation = 0
        private const val STATUS = 90009
        private fun prefs(c: Context) = c.getSharedPreferences("delivery_private", Context.MODE_PRIVATE)
        private fun key(): SecretKey {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (store.containsAlias("zerochat_delivery")) return store.getKey("zerochat_delivery", null) as SecretKey
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder("zerochat_delivery", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            }.generateKey()
        }
        @Synchronized fun configure(c: Context, server: String, authorization: String) {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
            val plain = JSONObject().put("server", server).put("authorization", authorization).toString()
            val encoded = Base64.encodeToString(cipher.doFinal(plain.toByteArray()), Base64.NO_WRAP)
            generation++
            prefs(c).edit().clear().putString("cipher", encoded).putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).commit()
        }
        @Synchronized fun disable(c: Context) {
            generation++
            running = false
            prefs(c).edit().clear().commit()
            c.stopService(Intent(c, DeliveryService::class.java))
            (c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancelAll()
        }
        fun cancelChat(c: Context, chat: String) {
            (c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(chat.hashCode())
        }
        @Synchronized fun claim(c: Context, chat: String, ids: List<String>): Boolean {
            val values = prefs(c).getStringSet("seen:$chat", emptySet())!!.toMutableSet()
            val fresh = ids.any { !values.contains(it) }
            values.addAll(ids)
            // Cursor prevents replay after bounded receipt compaction.
            prefs(c).edit().putStringSet("seen:$chat", values.toList().takeLast(1000).toSet()).commit()
            return fresh
        }
    }
    private val executor = Executors.newSingleThreadScheduledExecutor()
    private var started = false
    override fun onBind(intent: Intent?): IBinder? = null
    private fun builder(channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("delivery_status", "后台接收状态", NotificationManager.IMPORTANCE_LOW))
            nm.createNotificationChannel(NotificationChannel("delivery_messages", "后台新消息", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val launch = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val status = builder("delivery_status").setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("ZeroChat 后台接收中").setContentText("只查询新消息；点此打开应用，可在账号与设备关闭")
            .setContentIntent(launch).setOngoing(true).build()
        startForeground(STATUS, status)
        running = true
        if (!started) { started = true; executor.scheduleWithFixedDelay({ poll() }, 0, 15, TimeUnit.SECONDS) }
        return START_STICKY
    }
    private fun poll() {
        val expected = generation
        try {
            val pref = prefs(this)
            val encrypted = pref.getString("cipher", null) ?: run { stopSelf(); return }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(pref.getString("iv", ""), Base64.NO_WRAP)))
            }
            val config = JSONObject(String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP))))
            val cursors = JSONObject(pref.getString("cursors", "{}")!!)
            val connection = URL(config.getString("server").trimEnd('/') + "/api/notifications/poll").openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 8000; connection.readTimeout = 8000
                connection.requestMethod = "POST"; connection.doOutput = true
                connection.setRequestProperty("Authorization", config.getString("authorization"))
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(JSONObject().put("cursors", cursors).put("epoch", pref.getString("epoch", null)).toString().toByteArray()) }
                if (connection.responseCode == 401) { if (expected == generation) disable(this); return }
                if (connection.responseCode != 200) return
                val result = connection.inputStream.bufferedReader().use { reader ->
                    val chars = CharArray(1024 * 1024 + 1); var size = 0
                    while (size < chars.size) { val n = reader.read(chars, size, chars.size - size); if (n < 0) break; size += n }
                    if (size > 1024 * 1024) return
                    JSONObject(String(chars, 0, size))
                }
                synchronized(Companion) {
                    if (expected != generation || pref.getString("cipher", null) != encrypted) return
                    val chats = result.getJSONArray("chats")
                    for (i in 0 until chats.length()) {
                        val chat = chats.getJSONObject(i); val id = chat.getString("id")
                        cursors.put(id, chat.getLong("cursor"))
                        val incoming = chat.getJSONArray("incoming_ids")
                        val ids = (0 until incoming.length()).map { incoming.getString(it) }
                        if (!visible && ids.isNotEmpty() && claim(this, id, ids) && !result.optBoolean("quiet")) {
                            val target = Intent(this, MainActivity::class.java).putExtra("delivery_chat", id)
                                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            val pending = PendingIntent.getActivity(this, id.hashCode(), target, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                            val notification = builder("delivery_messages").setSmallIcon(R.mipmap.ic_launcher)
                                .setContentTitle("ZeroChat 新消息").setContentText("收到新的聊天消息，点击查看")
                                .setVisibility(Notification.VISIBILITY_PRIVATE).setContentIntent(pending).setAutoCancel(true).build()
                            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(id.hashCode(), notification)
                        }
                    }
                    pref.edit().putString("cursors", cursors.toString()).putString("epoch", result.getString("epoch")).commit()
                }
            } finally { connection.disconnect() }
        } catch (_: Exception) { /* Keep cursor and session on temporary network loss; never replay AI. */ }
    }
    override fun onTimeout(startId: Int, fgsType: Int) { disable(this); stopSelf() }
    override fun onDestroy() { running = false; executor.shutdownNow(); super.onDestroy() }
}
