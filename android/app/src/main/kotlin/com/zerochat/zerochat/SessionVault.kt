package com.zerochat.zerochat

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** App-private ciphertext only; the non-exportable key remains in Keystore. */
object SessionVault {
    private const val ALIAS = "zerochat_login"
    private fun prefs(context: Context) = context.getSharedPreferences("session_private", Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(ALIAS)) return store.getKey(ALIAS, null) as SecretKey
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    @Synchronized fun write(context: Context, value: Map<String, String>) {
        require(listOf("server", "token", "identity", "session_id").all { !value[it].isNullOrBlank() })
        val plain = JSONObject()
        for (field in listOf("server", "token", "identity", "session_id")) plain.put(field, value[field])
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        check(prefs(context).edit().clear()
            .putString("cipher", Base64.encodeToString(cipher.doFinal(plain.toString().toByteArray(Charsets.UTF_8)), Base64.NO_WRAP))
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).commit())
    }

    @Synchronized fun read(context: Context, server: String): Map<String, String>? {
        val pref = prefs(context)
        val encoded = pref.getString("cipher", null) ?: return null
        val value = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(pref.getString("iv", ""), Base64.NO_WRAP)))
            }
            JSONObject(String(cipher.doFinal(Base64.decode(encoded, Base64.NO_WRAP)), Charsets.UTF_8))
        } catch (_: Exception) {
            // Lost Keystore keys or damaged ciphertext must never become a login.
            clear(context)
            throw IllegalStateException("本机安全登录凭证不可读取，请重新登录")
        }
        if (value.optString("server") != server) { clear(context); return null }
        return listOf("server", "token", "identity", "session_id").associateWith { value.getString(it) }
    }

    @Synchronized fun clear(context: Context) { check(prefs(context).edit().clear().commit()) }
}
