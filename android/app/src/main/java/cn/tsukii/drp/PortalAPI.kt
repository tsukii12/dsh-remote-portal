package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

interface RPCServing {
    suspend fun rpc(method: String, args: J = EMPTY): J
    fun stream(endpoint: String, args: J = EMPTY): Flow<J>
}

class PortalAPI(val base: HttpUrl, val client: PortalClient,
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)) : RPCServing {
    private val expired = MutableStateFlow(false)
    val sessionExpired = expired.asStateFlow()
    val mux = PortalMux(this, scope)
    fun request(path: String) = client.request(base, path)
    override suspend fun rpc(method: String, args: J): J {
        val request = request("api/$method").post(envelope(method, args).toString()
            .toRequestBody("application/json".toMediaType())).build()
        return client.http.newCall(request).await().use {
            client.cookies.ingest(it, base)
            val data = withContext(Dispatchers.IO) { it.body?.string().orEmpty() }
            try { decode(data, it.code) }
            catch (e: APIError.SessionExpired) { expire(); throw e }
        }
    }
    suspend fun login(secret: String, pairing: Boolean = false) {
        client.post(base, "login", mapOf((if (pairing) "token" else "password") to secret))
        expired.value = false
    }
    suspend fun logout() { client.post(base, "logout", emptyMap()); client.cookies.clear(base); expire() }
    fun expire() { expired.value = true; mux.close() }
    override fun stream(endpoint: String, args: J): Flow<J> = mux.open(endpoint, args)
    companion object {
        fun envelope(method: String, args: J, id: String = UUID.randomUUID().toString()): J =
            o("type" to "client-request", "rpcId" to id, "method" to method, "payload" to o("args" to args))
        fun decode(data: String, status: Int): J {
            if (status == 401) throw APIError.SessionExpired
            if (status !in 200..299) throw APIError.Http(status)
            val body = runCatching { parse(data) }.getOrElse { throw APIError.InvalidResponse }
            val ok = body["result"]["ok"]
            if (body["type"].text != "server-response" || (ok != JsonPrimitive(true) && ok != JsonPrimitive(false))) throw APIError.InvalidResponse
            if (!ok.boolean) {
                val error = body["result"]["error"]
                throw APIError.Remote(error["code"].text, error["message"].string ?: L("Request failed.", "请求失败。"))
            }
            return body["result"]["value"]
        }
    }
}
