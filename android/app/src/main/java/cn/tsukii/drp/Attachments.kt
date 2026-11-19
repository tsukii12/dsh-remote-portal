package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.InputStream
import java.io.File
import java.util.UUID

object CameraCaptures {
    fun create(cache: File, activeNames: Set<String> = emptySet(), now: Long = System.currentTimeMillis()): File {
        val directory = File(cache, "exports").apply { mkdirs() }
        directory.listFiles()?.filter { it.isFile && it.name.startsWith("camera-") && it.name !in activeNames && it.lastModified() < now - 86_400_000L }?.forEach { it.delete() }
        return File.createTempFile("camera-", ".jpg", directory)
    }
}

data class UploadSource(val name: String, val mediaType: String?, val size: Long?, val open: () -> InputStream) {
    val image get() = mediaType?.startsWith("image/") == true
}
data class DraftAttachment(val id: String, val source: UploadSource, val sent: Long = 0, val receipt: J? = null, val error: String? = null) {
    val reference: J get() = receipt?.let { if (it["image"] != j(null)) it["image"] else it["file"] } ?: EMPTY
}
class AttachmentDraft(private val sessionID: String, private val api: RPCServing, private val scope: CoroutineScope, private val limits: () -> J) {
    private val mutable = MutableStateFlow<List<DraftAttachment>>(emptyList())
    val items = mutable.asStateFlow()
    private val jobs = mutableMapOf<String, Job>()
    private val attempts = mutableMapOf<String, Any>()
    private var closed = false
    var requestID: String = UUID.randomUUID().toString()
        private set
    val ready get() = items.value.all { it.receipt != null && it.error == null }
    fun add(source: UploadSource) {
        if (closed) return
        val item = DraftAttachment(UUID.randomUUID().toString(), source)
        mutable.value += item
        retry(item.id)
    }
    fun retry(id: String) {
        val item = items.value.find { it.id == id } ?: return
        if (closed) return
        jobs.remove(id)?.cancel()
        val attempt = Any(); attempts[id] = attempt
        update(id) { it.copy(sent = 0, receipt = null, error = null) }
        jobs[id] = scope.launch {
            try {
                validateImages()
                val cap = if (item.source.image) limits()["maxImageBytes"].long ?: throw APIError.InvalidResponse else Long.MAX_VALUE
                val receipt = api.upload(sessionID, item.source, cap) { bytes -> scope.launch { update(id, attempt) { it.copy(sent = bytes) } } }
                if (receipt["receiptId"].string.isNullOrEmpty() || (receipt["image"] == j(null) && receipt["file"] == j(null))) throw APIError.InvalidResponse
                update(id, attempt) { it.copy(receipt = receipt) }
                validateImages()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { update(id, attempt) { it.copy(error = e.message ?: L("Upload failed", "上传失败")) } }
        }
    }
    fun validateImages() {
        val images = items.value.filter { it.source.image }
        if (images.isEmpty()) return
        val policy = limits()
        val count = policy["maxImagesPerMessage"].long ?: throw PortalError(L("Image limits are not available yet.", "尚未获取图片限制。"))
        val maxBytes = policy["maxImageBytes"].long ?: throw APIError.InvalidResponse
        val totalBytes = policy["maxMessageImageBytes"].long ?: throw APIError.InvalidResponse
        var total = 0L
        if (images.size > count) throw PortalError(L("Too many images for one message.", "单条消息的图片数量过多。"))
        images.forEach { item ->
            if (policy["mediaTypes"].array.none { it.text == item.source.mediaType }) throw PortalError(L("This image type is not supported.", "不支持此图片格式。"))
            val size = item.reference["bytes"].long ?: item.source.size
            if (size != null) {
                if (size < 0 || size > maxBytes || size > totalBytes - total) throw PortalError(L("Images exceed the host's size limit.", "图片超过主机的大小限制。"))
                total += size
            }
            val width = item.reference["width"].long; val height = item.reference["height"].long
            if (width != null && height != null) {
                val dimension = policy["maxImageDimension"].long ?: throw APIError.InvalidResponse
                val pixels = policy["maxImagePixels"].long ?: throw APIError.InvalidResponse
                if (width <= 0 || height <= 0 || width > dimension || height > dimension || width > pixels / height)
                    throw PortalError(L("Image dimensions exceed the host's limit.", "图片尺寸超过主机限制。"))
            }
        }
    }
    fun remove(id: String) { attempts.remove(id); jobs.remove(id)?.cancel(); mutable.value = items.value.filterNot { it.id == id } }
    fun clear() { items.value.map { it.id }.forEach(::remove); requestID = UUID.randomUUID().toString() }
    fun close() { closed = true; clear() }
    private fun update(id: String, attempt: Any? = null, transform: (DraftAttachment) -> DraftAttachment) {
        if (!closed && (attempt == null || attempts[id] === attempt)) mutable.value = items.value.map { if (it.id == id) transform(it) else it }
    }
}

data class AtToken(val start: Int, val end: Int, val query: String, val quoted: Boolean)
data class MentionCandidate(val label: String, val insertion: String, val directory: Boolean = false)
object Mentions {
    fun insertFile(text: String, start: Int, end: Int, path: String): Pair<String, Int>? {
        if (path.isEmpty() || start !in 0..text.length || end !in start..text.length) return null
        val token = if (start == end) active(text, start) else null
        val mention = file(path, false, token?.quoted == true) ?: return null
        val from = token?.start ?: start
        return text.replaceRange(from, end, "$mention ") to (from + mention.length + 1)
    }
    fun active(text: String, cursor: Int): AtToken? {
        val position = cursor.coerceIn(0, text.length)
        val before = text.take(position).substringAfterLast('\n')
        val quoted = Regex("(?:^|\\s)(@\"([^\"]*))$").find(before)
        val match = quoted
            ?: Regex("(?:^|\\s)(@([^\\s]*))$").find(before) ?: return null
        return AtToken(position - match.groupValues[1].length, position, match.groupValues[2], quoted != null)
    }
    fun file(path: String, directory: Boolean, quoted: Boolean): String? {
        val value = path + if (directory) "/" else ""
        if (value.any { it.code in 0..31 || it.code in 127..159 || it == '"' }) return null
        return if (quoted || value.any(Char::isWhitespace)) "@\"" + value + if (directory) "" else "\"" else "@$value"
    }
    suspend fun candidates(api: RPCServing, sessionID: String, token: AtToken): List<MentionCandidate> = coroutineScope {
        suspend fun lookup(method: String): List<J> = try { api.rpc(method, o("agentId" to sessionID, "query" to token.query)).array }
        catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
        val files = async { lookup("fileReferences/list").mapNotNull { item ->
            val directory = item["kind"].text == "directory"
            file(item["path"].text, directory, token.quoted)?.let { MentionCandidate(item["path"].text + if (directory) "/" else "", it, directory) }
        } }
        val sessions = async { if (token.quoted) emptyList() else lookup("sessionReferenceResolver/candidates").mapNotNull {
            it["mention"].string?.let { mention -> MentionCandidate(it["displayTitle"].string ?: it["label"].text, mention) }
        } }
        files.await() + sessions.await()
    }
}
