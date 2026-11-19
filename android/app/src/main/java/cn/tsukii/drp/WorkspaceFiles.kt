package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.ByteArrayOutputStream
import java.util.Locale

data class DirectoryListing(val loading: Boolean = true, val entries: List<J> = emptyList(), val truncated: Boolean = false, val error: String? = null)
data class WorkspaceFilesState(val directories: Map<String, DirectoryListing> = emptyMap(), val expanded: Set<String> = setOf("."),
    val query: String = "", val searching: Boolean = false, val results: List<J> = emptyList(), val truncated: Boolean = false, val incomplete: Boolean = false,
    val searchError: String? = null, val watchError: String? = null)

class WorkspaceFilesStore(val sessionID: String, private val api: RPCServing, private val scope: CoroutineScope) {
    private val mutable = MutableStateFlow(WorkspaceFilesState())
    val state = mutable.asStateFlow()
    private val loads = mutableMapOf<String, Job>()
    private val tickets = mutableMapOf<String, Any>()
    private var search: Job? = null
    private var searchTicket: Any? = null
    private var watch: Job? = null
    private var reload: Job? = null
    private var closed = false
    fun start() {
        if (closed) return
        refresh()
    }
    private fun watch() {
        if (watch?.isActive == true) return
        watch = scope.launch {
            try {
                api.stream("workspaceFiles/changes", o("workspaceFileScopeId" to sessionID, "path" to ".")).collect { event ->
                    if (event["kind"].text == "change" || event["type"].text == "connection-reset") {
                        reload?.cancel(); reload = scope.launch { delay(150); refresh() }
                    }
                }
                if (isActive && !closed) mutable.value = state.value.copy(watchError = L("File watching stopped. Refresh to reload.", "文件监视已停止，请刷新。"))
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (!closed) mutable.value = state.value.copy(watchError = e.message ?: L("File watching failed.", "文件监视失败。")) }
        }
    }
    fun refresh() {
        if (closed) return
        loads.values.forEach { it.cancel() }; loads.clear(); tickets.clear()
        mutable.value = state.value.copy(directories = emptyMap(), watchError = null)
        state.value.expanded.forEach(::load)
        if (state.value.query.isNotBlank()) search(state.value.query)
        watch()
    }
    fun toggle(path: String) {
        if (closed) return
        if (path in state.value.expanded) mutable.value = state.value.copy(expanded = state.value.expanded - path)
        else { mutable.value = state.value.copy(expanded = state.value.expanded + path); load(path) }
    }
    fun openDirectory(path: String) {
        if (closed) return
        search("")
        val parts = path.split('/')
        val parents = parts.indices.map { parts.take(it + 1).joinToString("/") }
        mutable.value = state.value.copy(expanded = state.value.expanded + parents)
        parents.forEach(::load)
    }
    fun load(path: String) {
        if (closed || !WorkspacePaths.visible(path)) return
        loads.remove(path)?.cancel()
        val ticket = Any(); tickets[path] = ticket
        mutable.value = state.value.copy(directories = state.value.directories + (path to DirectoryListing()))
        loads[path] = scope.launch {
            try {
                val result = api.rpc("workspaceFiles/list", o("workspaceFileScopeId" to sessionID, "path" to path))
                ensureActive()
                if (!closed && tickets[path] === ticket) mutable.value = state.value.copy(directories = state.value.directories + (path to DirectoryListing(false, result["entries"].array.filter { WorkspacePaths.visible(it["path"].string ?: child(path, it["name"].text)) }, result["truncated"].boolean)))
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (!closed && tickets[path] === ticket) mutable.value = state.value.copy(directories = state.value.directories + (path to DirectoryListing(false, error = e.message ?: L("Cannot list folder.", "无法列出文件夹。")))) }
        }
    }
    fun search(query: String) {
        if (closed) return
        search?.cancel(); val ticket = Any(); searchTicket = ticket
        mutable.value = state.value.copy(query = query, searching = query.isNotBlank(), results = emptyList(), searchError = null, truncated = false, incomplete = false)
        if (query.isBlank()) return
        search = scope.launch {
            try {
                delay(250)
                val value = api.rpc("workspaceFiles/search", o("workspaceFileScopeId" to sessionID, "request" to o("query" to query, "excludedPaths" to emptyList<String>(), "includeHidden" to false, "respectGitignore" to true)))
                ensureActive()
                if (!closed && searchTicket === ticket) mutable.value = state.value.copy(searching = false, results = value["matches"].array.filter { WorkspacePaths.visible(it["path"].text) }, truncated = value["truncated"].boolean, incomplete = value["incomplete"].boolean)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (!closed && searchTicket === ticket) mutable.value = state.value.copy(searching = false, searchError = e.message ?: L("Search failed.", "搜索失败。")) }
        }
    }
    fun preview(path: String) = WorkspacePreviewStore(sessionID, api, path)
    fun close() { closed = true; tickets.clear(); searchTicket = null; loads.values.forEach { it.cancel() }; search?.cancel(); reload?.cancel(); watch?.cancel() }
    companion object { fun child(parent: String, name: String) = if (parent == ".") name else "$parent/$name" }
}

enum class FilePreviewKind { TEXT, IMAGE, BINARY }
data class WorkspacePreviewState(val loading: Boolean = false, val loaded: Boolean = false, val text: String = "", val data: ByteArray? = null,
    val eof: Boolean = false, val truncated: Boolean = false, val error: String? = null, val kind: FilePreviewKind = FilePreviewKind.TEXT)
class WorkspacePreviewStore(private val sessionID: String, private val api: RPCServing, val path: String) {
    private val initialKind = when (path.substringAfterLast('.', "").lowercase(Locale.ROOT)) {
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff" -> FilePreviewKind.IMAGE
        "pdf", "zip", "bin", "gz", "7z", "tar", "mp3", "mp4", "wasm" -> FilePreviewKind.BINARY
        else -> FilePreviewKind.TEXT
    }
    private val mutable = MutableStateFlow(WorkspacePreviewState(kind = initialKind))
    val state = mutable.asStateFlow()
    private var nextLine = 1
    private var version: J? = null
    private fun args() = o("workspaceFileScopeId" to sessionID, "path" to path)
    suspend fun load(reload: Boolean = false) {
        if (state.value.loading) return
        if (!WorkspacePaths.visible(path)) { fail(PortalError(L("Private dsh files are hidden.", "已隐藏 dsh 私密文件。"))); return }
        if (!reload && state.value.loaded && (state.value.eof || state.value.truncated)) return
        if (reload) { nextLine = 1; version = null; mutable.value = WorkspacePreviewState(kind = initialKind) }
        if (state.value.kind == FilePreviewKind.BINARY) { mutable.value = state.value.copy(loaded = true); return }
        mutable.value = state.value.copy(loading = true, error = null)
        try {
            if (!state.value.loaded && state.value.kind == FilePreviewKind.TEXT && path.substringAfterLast('/').substringAfterLast('.', "").isEmpty()) {
                val probe = api.rpcBinary("workspaceFiles/readBytes", args().with("options", o("range" to o("offset" to 0, "length" to 32))))
                currentCoroutineContext().ensureActive()
                val bytes = probe.bytes("data") ?: throw APIError.InvalidResponse
                if (bytes.size > 32 || probe.value["offset"].long != 0L) throw APIError.InvalidResponse
                if (ImageSignatures.detected(bytes)) mutable.value = state.value.copy(kind = FilePreviewKind.IMAGE)
            }
            if (state.value.kind == FilePreviewKind.IMAGE) { val data = readBytes(); mutable.value = state.value.copy(data = data, eof = true, loaded = true) }
            else {
                val page = api.rpc("workspaceFiles/read", args().with("range", o("offset" to nextLine, "limit" to 200)))
                currentCoroutineContext().ensureActive()
                val text = page["text"].string ?: throw APIError.InvalidResponse
                val lines = page["lines"].int?.takeIf { it in 0..200 } ?: throw APIError.InvalidResponse
                if (page["version"].string == null || lines == 0 && !page["eof"].boolean) throw APIError.InvalidResponse
                if (version != null && version != page["version"]) throw PortalError(L("The file changed. Reload it before continuing.", "文件已更改，请重新加载后继续。"))
                version = page["version"]
                val combined = state.value.text + (if (nextLine > 1 && lines > 0) "\n" else "") + text
                nextLine += lines
                mutable.value = state.value.copy(text = combined.take(MAX_TEXT_CHARS), loaded = true, eof = page["eof"].boolean, truncated = combined.length > MAX_TEXT_CHARS || combined.length == MAX_TEXT_CHARS && !page["eof"].boolean)
            }
        } catch (e: CancellationException) { throw e }
        catch (e: APIError.Remote) {
            if (e.code == "workspace-file/not-text") {
                mutable.value = state.value.copy(kind = FilePreviewKind.BINARY, loaded = true)
                try {
                    val data = readBytes()
                    mutable.value = state.value.copy(kind = if (ImageSignatures.detected(data)) FilePreviewKind.IMAGE else FilePreviewKind.BINARY, data = data, eof = true)
                } catch (cancel: CancellationException) { throw cancel } catch (failure: Exception) { fail(failure) }
            } else fail(e)
        }
        catch (e: Exception) { fail(e) }
        finally { mutable.value = state.value.copy(loading = false) }
    }
    suspend fun download(): ByteArray? {
        if (state.value.loading) return null
        if (!WorkspacePaths.visible(path)) { fail(PortalError(L("Private dsh files are hidden.", "已隐藏 dsh 私密文件。"))); return null }
        mutable.value = state.value.copy(loading = true, error = null)
        return try { state.value.data ?: readBytes() }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { fail(e); null }
        finally { mutable.value = state.value.copy(loading = false) }
    }
    private fun fail(e: Exception) { mutable.value = state.value.copy(error = e.message ?: L("Cannot read file.", "无法读取文件。")) }
    private suspend fun readBytes(): ByteArray {
        val stat = api.rpc("workspaceFiles/stat", args()); currentCoroutineContext().ensureActive()
        val size = stat["bytes"].long?.takeIf { it in 0..MAX_DOWNLOAD_BYTES } ?: throw PortalError(L("File exceeds the 8 MiB download/preview limit.", "文件超过 8 MiB 下载/预览限制。"))
        if (stat["version"].string == null) throw APIError.InvalidResponse
        if (size == 0L) return byteArrayOf()
        val output = ByteArrayOutputStream()
        do {
            val offset = output.size(); val length = minOf(CHUNK_BYTES.toLong(), size - offset).toInt()
            val part = api.rpcBinary("workspaceFiles/readBytes", args().with("options", o("range" to o("offset" to offset, "length" to length))))
            currentCoroutineContext().ensureActive()
            val bytes = part.bytes("data") ?: throw APIError.InvalidResponse
            if (part.value["version"] != stat["version"]) throw PortalError(L("The file changed. Reload it before continuing.", "文件已更改，请重新加载后继续。"))
            if (part.value["offset"].long != offset.toLong() || part.value["bytes"].long != size || bytes.size > length || bytes.isEmpty() && output.size().toLong() != size) throw APIError.InvalidResponse
            output.write(bytes)
            if (part.value["eof"].boolean) { if (output.size().toLong() != size) throw APIError.InvalidResponse; break }
            if (output.size().toLong() >= size) throw APIError.InvalidResponse
        } while (true)
        return output.toByteArray()
    }
    companion object { const val MAX_DOWNLOAD_BYTES = 8L * 1024 * 1024; const val MAX_TEXT_CHARS = 1024 * 1024; const val CHUNK_BYTES = 256 * 1024 }
}
