package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import okhttp3.MultipartReader
import okhttp3.Response
import okio.Buffer
import okio.BufferedSink
import java.util.UUID

data class BinaryRPCResult(val value: J, val binaries: Map<List<String>, ByteArray> = emptyMap()) {
    fun bytes(vararg path: String): ByteArray? = binaries[path.toList()]
}

interface RPCServing {
    suspend fun rpc(method: String, args: J = EMPTY): J
    suspend fun rpcBinary(method: String, args: J = EMPTY): BinaryRPCResult = BinaryRPCResult(rpc(method, args))
    fun stream(endpoint: String, args: J = EMPTY): Flow<J>
    suspend fun portal(path: String, query: Map<String, String> = emptyMap(), body: J? = null): J = throw APIError.InvalidResponse
    suspend fun exportSession(id: String): ByteArray = throw APIError.InvalidResponse
    suspend fun upload(sessionID: String, source: UploadSource, maxBytes: Long, progress: (Long) -> Unit): J = throw APIError.InvalidResponse
}

class PortalAPI(val base: HttpUrl, val client: PortalClient,
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)) : RPCServing {
    private val expired = MutableStateFlow(false)
    val sessionExpired = expired.asStateFlow()
    val mux = PortalMux(this, scope)
    fun request(path: String) = client.request(base, path)
    override suspend fun upload(sessionID: String, source: UploadSource, maxBytes: Long, progress: (Long) -> Unit): J {
        val job = currentCoroutineContext().job
        val body = object : okhttp3.RequestBody() {
            override fun contentType() = "application/octet-stream".toMediaType()
            override fun contentLength() = source.size ?: -1L
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) {
                try { source.open().use { input ->
                    val bytes = ByteArray(8192); var total = 0L
                    while (true) {
                        if (!job.isActive) throw java.io.IOException("Upload cancelled")
                        val count = input.read(bytes)
                        if (count < 0) break
                        if (count.toLong() > maxBytes - total) throw java.io.IOException(L("Upload exceeds the host's size limit.", "上传内容超过主机大小限制。"))
                        sink.write(bytes, 0, count); total += count; progress(total)
                    }
                } } catch (e: java.io.IOException) { throw e }
                catch (e: Exception) { throw java.io.IOException(e.message, e) }
            }
        }
        val builder = request("api/session/uploadFileBinary")
        builder.url(builder.build().url.newBuilder().addQueryParameter("sessionId", sessionID).addQueryParameter("name", source.name)
            .apply { if (source.image) addQueryParameter("mediaType", source.mediaType) }.build())
        return client.http.newCall(builder.post(body).build()).await().use {
            client.cookies.ingest(it, base)
            if (it.code == 401) { expire(); throw APIError.SessionExpired }
            if (!it.isSuccessful) throw APIError.Http(it.code)
            val result = withContext(Dispatchers.IO) { parse(it.body?.string().orEmpty()) }
            if (!result["ok"].boolean) throw APIError.Remote(result["error"]["code"].text, result["error"]["message"].text)
            result["value"]
        }
    }
    override suspend fun portal(path: String, query: Map<String, String>, body: J?): J {
        val builder = request("dsh-remote-portal/$path")
        val url = builder.build().url.newBuilder().apply { query.forEach { (key, value) -> addQueryParameter(key, value) } }.build()
        builder.url(url)
        if (body != null) builder.post(body.toString().toRequestBody("application/json".toMediaType()))
        return client.http.newCall(builder.build()).await().use {
            client.cookies.ingest(it, base)
            if (it.code == 401) { expire(); throw APIError.SessionExpired }
            val data = withContext(Dispatchers.IO) { it.body?.string().orEmpty() }
            val value = runCatching { parse(data) }.getOrDefault(EMPTY)
            if (!it.isSuccessful || !value["ok"].boolean) throw APIError.Remote(value["code"].string ?: "portal/http-${it.code}", value["error"].string ?: L("Host folder request failed.", "主机文件夹请求失败。"))
            value
        }
    }
    override suspend fun exportSession(id: String): ByteArray {
        val builder = request("api/session.export")
        builder.url(builder.build().url.newBuilder().addQueryParameter("sessionId", id).build())
        return client.http.newCall(builder.build()).await().use {
            client.cookies.ingest(it, base)
            if (it.code == 401) { expire(); throw APIError.SessionExpired }
            if (!it.isSuccessful) throw APIError.Http(it.code)
            val data = withContext(Dispatchers.IO) { it.body?.bytes() } ?: throw APIError.InvalidResponse
            if (data.size < 2 || data[0] != 0x50.toByte() || data[1] != 0x4b.toByte()) throw APIError.InvalidResponse
            data
        }
    }
    override suspend fun rpc(method: String, args: J): J {
        val result = rpcBinary(method, args)
        if (result.binaries.isNotEmpty()) throw APIError.InvalidResponse
        return result.value
    }
    override suspend fun rpcBinary(method: String, args: J): BinaryRPCResult {
        val request = request("api/$method").post(envelope(method, args).toString()
            .toRequestBody("application/json".toMediaType())).build()
        return client.http.newCall(request).await().use {
            client.cookies.ingest(it, base)
            try { withContext(Dispatchers.IO) { decodeResponse(it) } }
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
        private const val MAX_RPC_BYTES = 64L * 1024 * 1024
        fun decodeResponse(response: Response): BinaryRPCResult {
            if (response.code == 401) throw APIError.SessionExpired
            if (!response.isSuccessful) throw APIError.Http(response.code)
            val body = response.body ?: throw APIError.InvalidResponse
            if (body.contentType()?.let { it.type == "multipart" && it.subtype == "form-data" } != true)
                return BinaryRPCResult(decode(body.string(), response.code))
            try {
                val parts = linkedMapOf<String, ByteArray>()
                var total = 0L
                MultipartReader(body).use { reader ->
                    while (true) {
                        val part = reader.nextPart() ?: break
                        part.use {
                            val disposition = it.headers.values("Content-Disposition").singleOrNull() ?: throw APIError.InvalidResponse
                            val names = Regex("(?:^|;)\\s*name=(?:\"([^\"]+)\"|([^;\\s]+))").findAll(disposition).toList()
                            if (names.size != 1) throw APIError.InvalidResponse
                            val name = names.single().let { match -> match.groups[1]?.value ?: match.groups[2]!!.value }
                            if (parts.containsKey(name) || parts.size >= 128) throw APIError.InvalidResponse
                            val buffer = Buffer()
                            while (!it.body.exhausted()) {
                                val count = it.body.read(buffer, minOf(8192L, MAX_RPC_BYTES - total + 1))
                                if (count < 0) break
                                total += count
                                if (total > MAX_RPC_BYTES) throw APIError.InvalidResponse
                            }
                            parts[name] = buffer.readByteArray()
                        }
                    }
                }
                val metadata = parts.remove("metadata") ?: throw APIError.InvalidResponse
                val document = parse(metadata.toString(Charsets.UTF_8))
                val value = decode(document.toString(), response.code)
                if (document["attachments"] !is JsonArray) throw APIError.InvalidResponse
                val binaries = linkedMapOf<List<String>, ByteArray>()
                val used = mutableSetOf<String>()
                for (attachment in document["attachments"].array) {
                    val rawPath = attachment["path"] as? JsonArray ?: throw APIError.InvalidResponse
                    var target = value
                    val path = rawPath.map { key ->
                        when (target) {
                            is JsonObject -> {
                                val name = key.string ?: throw APIError.InvalidResponse
                                target = (target as JsonObject)[name] ?: throw APIError.InvalidResponse
                                name
                            }
                            is JsonArray -> {
                                val index = key.int?.takeIf { it >= 0 } ?: throw APIError.InvalidResponse
                                target = (target as JsonArray).getOrNull(index) ?: throw APIError.InvalidResponse
                                index.toString()
                            }
                            else -> throw APIError.InvalidResponse
                        }
                    }
                    val name = attachment["part"].text
                    if (attachment["codec"].text != "bytes" || target != JsonNull || binaries.containsKey(path) || !used.add(name)) throw APIError.InvalidResponse
                    binaries[path] = parts[name] ?: throw APIError.InvalidResponse
                }
                if (used != parts.keys) throw APIError.InvalidResponse
                return BinaryRPCResult(value, binaries)
            } catch (e: APIError) { throw e }
            catch (_: Exception) { throw APIError.InvalidResponse }
        }
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
