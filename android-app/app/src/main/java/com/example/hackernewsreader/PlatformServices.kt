package com.example.hackernewsreader

import android.os.LocaleList
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.text.DateFormat
import java.util.Date
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

object PlatformServices {
    private external fun initialize(type: Class<*>)
    init { initialize(PlatformServices::class.java) }

    private val client = OkHttpClient.Builder().callTimeout(10, TimeUnit.SECONDS).build()
    private val requests = ConcurrentHashMap<Long, Call>()
    private external fun complete(id: Long, status: Int, bytes: ByteArray?, error: String?)
    external fun setupMainLooper()

    @JvmStatic fun start(id: Long, url: String) {
        val call = client.newCall(Request.Builder().url(url).build())
        requests[id] = call
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                requests.remove(id)
                complete(id, 0, null, e.message ?: "Network request failed")
            }
            override fun onResponse(call: Call, response: Response) {
                try {
                    response.use { complete(id, it.code, it.body.bytes(), null) }
                } catch (error: IOException) {
                    complete(id, 0, null, error.message ?: "Reading response failed")
                } finally {
                    requests.remove(id)
                }
            }
        })
    }

    @JvmStatic fun cancel(id: Long) { requests.remove(id)?.cancel() }
    @JvmStatic fun languages(): String = LocaleList.getDefault().toLanguageTags()
    @JvmStatic fun formatTime(seconds: Double): String =
        DateFormat.getTimeInstance(DateFormat.MEDIUM).format(Date((seconds * 1000).toLong()))
}
