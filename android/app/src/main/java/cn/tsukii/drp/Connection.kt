package cn.tsukii.drp

import android.content.Context
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import java.io.IOException
import java.net.URI
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

object PortalURL {
    fun normalize(input: String): HttpUrl {
        try {
            val uri = URI(input.trim())
            require(uri.scheme?.lowercase() in listOf("http", "https") && uri.rawUserInfo == null)
            val url = input.trim().toHttpUrl()
            require(url.host.isNotEmpty() && url.username.isEmpty() && url.password.isEmpty())
            return url.newBuilder().query(null).fragment(null)
                .encodedPath(url.encodedPath.let { if (it.endsWith('/')) it else "$it/" }).build()
        } catch (_: Exception) { throw PortalError(L("Enter a valid HTTP(S) address.", "请输入有效的 HTTP(S) 地址。")) }
    }
    fun pairing(input: String): Pair<HttpUrl, String>? {
        val url = runCatching { input.trim().toHttpUrl() }.getOrNull() ?: return null
        if (!url.encodedPath.endsWith("/__portal/pair")) return null
        val token = url.queryParameter("t")?.takeIf { it.isNotEmpty() }
            ?: throw PortalError(L("Pairing link has no token.", "配对链接缺少令牌。"))
        return normalize(url.newBuilder().encodedPath(url.encodedPath.removeSuffix("__portal/pair"))
            .query(null).fragment(null).build().toString()) to token
    }
    fun origin(base: HttpUrl): String = base.newBuilder().encodedPath("/").query(null).fragment(null).build().toString().removeSuffix("/")
    fun form(fields: Map<String, String>): String = fields.toSortedMap().entries.joinToString("&") {
        "${it.key}=${URLEncoder.encode(it.value, "UTF-8").replace("+", "%20").replace("%7E", "~").replace("*", "%2A")}"
    }
}

data class Server(val id: String = UUID.randomUUID().toString(), val name: String, val addresses: List<HttpUrl>)

class ServerStore(context: Context) {
    private val preferences = context.getSharedPreferences("drp.servers", Context.MODE_PRIVATE)
    private val mutable = MutableStateFlow(runCatching {
        parse(preferences.getString("servers", "[]")!!).array.map { row ->
            Server(row["id"].text, row["name"].text, row["addresses"].array.map { PortalURL.normalize(it.text) })
        }
    }.getOrDefault(emptyList()))
    val servers = mutable.asStateFlow()
    fun save(servers: List<Server>) {
        val value = j(servers.map { o("id" to it.id, "name" to it.name, "addresses" to it.addresses.map(HttpUrl::toString)) })
        preferences.edit().putString("servers", value.toString()).apply()
        mutable.value = servers.toList()
    }
}

data class HealthResult(val base: HttpUrl, val milliseconds: Int) {
    val label: String get() {
        val host = base.host
        val lan = host == "localhost" || host == "::1" || host.startsWith("192.168.") || host.startsWith("10.") ||
            host.startsWith("127.") || host.endsWith(".local") ||
            (host.startsWith("172.") && (host.split('.').getOrNull(1)?.toIntOrNull() ?: 0) in 16..31)
        return "${if (lan) "LAN" else L("Public", "公网")} · $milliseconds ms · $base"
    }
}

suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) { if (continuation.isActive) continuation.resumeWithException(e) }
        override fun onResponse(call: Call, response: Response) {
            continuation.resume(response) { _, value, _ -> value.close() }
        }
    })
}

class PortalClient(val cookies: CookieVault, http: OkHttpClient = OkHttpClient()) {
    val http = http.newBuilder().followRedirects(false).followSslRedirects(false).cookieJar(CookieJar.NO_COOKIES).build()
    fun request(base: HttpUrl, path: String): Request.Builder {
        val url = base.resolve(path) ?: throw APIError.InvalidResponse
        return Request.Builder().url(url).header("User-Agent", USER_AGENT).header("Origin", PortalURL.origin(base))
            .apply { cookies.cookies(base, url).takeIf { it.isNotEmpty() }?.let { list -> header("Cookie", list.joinToString("; ") { "${it.name}=${it.value}" }) } }
    }
    suspend fun connect(addresses: List<HttpUrl>): HealthResult = race(addresses) { base ->
        val start = System.nanoTime()
        val probe = http.newBuilder().callTimeout(3, TimeUnit.SECONDS).build()
        probe.newCall(request(base, "__portal/health").cacheControl(CacheControl.FORCE_NETWORK).build()).await().use {
            cookies.ingest(it, base)
            if (it.code != 200) throw PortalError(L("Server is unavailable.", "服务器不可用。"))
        }
        ((System.nanoTime() - start) / 1_000_000).toInt()
    }
    suspend fun post(base: HttpUrl, endpoint: String, fields: Map<String, String>) {
        val request = request(base, "__portal/$endpoint")
            .header("Accept", "application/json").header("Accept-Language", L("en", "zh"))
            .post(PortalURL.form(fields).toRequestBody("application/x-www-form-urlencoded".toMediaType())).build()
        http.newBuilder().callTimeout(15, TimeUnit.SECONDS).build().newCall(request).await().use { response ->
            cookies.ingest(response, base)
            val text = withContext(Dispatchers.IO) { response.body?.string().orEmpty() }
            if (response.code == 429) {
                val retry = response.header("Retry-After") ?: L("a few", "若干")
                throw PortalError(L("Too many attempts. Try again after $retry seconds.", "尝试次数过多，请稍后重试（${retry}秒）。"))
            }
            if (response.code != 303 && !(endpoint == "logout" && response.isSuccessful)) {
                val json = runCatching { parse(text) }.getOrDefault(EMPTY)
                val message = listOf(json["error"].string, json["message"].string).firstOrNull { !it.isNullOrBlank() }
                throw PortalError(message ?: if (endpoint == "logout") L("Sign-out failed. Please try again.", "退出登录失败，请重试。")
                    else L("Sign-in failed. Check your password or pairing code.", "登录失败，请检查密码或配对码。"))
            }
        }
    }
    companion object {
        const val USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 DSHRemote/1.0"
        suspend fun race(addresses: List<HttpUrl>, probe: suspend (HttpUrl) -> Int): HealthResult = coroutineScope {
            val results = Channel<HealthResult?>(Channel.UNLIMITED)
            val jobs = addresses.map { base -> launch {
                val result = try { HealthResult(base, probe(base)) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                results.send(result)
            } }
            try {
                repeat(addresses.size) { results.receive()?.let { return@coroutineScope it } }
                throw PortalError(L("No address responded. Check your server and network.", "所有地址均无法连接，请检查服务器和网络。"))
            } finally { jobs.forEach { it.cancel() }; results.close() }
        }
    }
}
