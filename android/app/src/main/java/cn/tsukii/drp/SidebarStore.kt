package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

data class WorkspaceRow(val id: String, val title: String, val path: String, val sessionIDs: List<String>) {
    constructor(json: J) : this(json["workspaceId"].text, json["title"].text, json["path"].text, json["sessionIds"].array.map { it.text })
}
data class SessionRow(val id: String, val title: String, val running: Boolean, val updatedAt: J, val projections: J) {
    constructor(json: J) : this(json["sessionId"].text, json["projections"]["values"]["title"].string ?: L("New conversation", "新对话"),
        json["running"].boolean, json["updatedAt"], json["projections"]["values"])
}
data class SessionGroup(val id: String, val title: String, val sessions: List<SessionRow>)
data class SidebarState(val workspaces: List<WorkspaceRow> = emptyList(), val sessions: Map<String, SessionRow> = emptyMap(),
    val archivedIDs: List<String> = emptyList(), val pinnedIDs: List<String> = emptyList(), val loaded: Boolean = false, val error: String? = null,
    val searchText: String = "", val archivedOnly: Boolean = false, val searchResults: List<J> = emptyList()) {
    val groups: List<SessionGroup> get() {
        val query = searchText.trim()
        val found = searchResults.mapNotNull { it["sessionId"].string }.toSet()
        val visible = sessions.values.filter { (it.id in archivedIDs) == archivedOnly && (query.isEmpty() || it.title.contains(query, ignoreCase = true) || it.id in found) }
        val assigned = (workspaces.flatMap { it.sessionIDs } + pinnedIDs).toSet()
        return listOf(SessionGroup("pinned", L("Pinned", "置顶"), pinnedIDs.mapNotNull { id -> visible.find { it.id == id } })) +
            workspaces.map { workspace -> SessionGroup(workspace.id, workspace.title, workspace.sessionIDs.mapNotNull { id -> visible.find { it.id == id && id !in pinnedIDs } }) } +
            SessionGroup("ungrouped", L("Ungrouped", "未分组"), visible.filter { it.id !in assigned }.sortedByDescending { it.updatedAt.int ?: 0 })
    }
}
class SidebarStore(private val api: RPCServing, private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)) {
    private val mutable = MutableStateFlow(SidebarState())
    val state = mutable.asStateFlow()
    private var tasks = listOf<Job>()
    fun applyWorkspace(frame: J) {
        val s = state.value
        mutable.value = when (frame["type"].text) {
            "connection-reset" -> s.copy(loaded = false)
            "baseline", "replace" -> frame["value"].let { s.copy(workspaces = it["items"].array.map(::WorkspaceRow),
                archivedIDs = it["archivedSessionIds"].array.map { it.text }, pinnedIDs = it["pinnedSessionIds"].array.map { it.text }, loaded = true) }
            "upsert" -> WorkspaceRow(frame["workspace"]).let { row -> s.copy(workspaces = if (s.workspaces.any { it.id == row.id }) s.workspaces.map { if (it.id == row.id) row else it } else s.workspaces + row) }
            "remove" -> s.copy(workspaces = s.workspaces.filterNot { it.id == frame["workspaceId"].text })
            "order" -> frame["workspaceIds"].array.map { it.text }.let { ids -> s.copy(workspaces = ids.mapNotNull { id -> s.workspaces.find { it.id == id } } + s.workspaces.filter { it.id !in ids }) }
            "archived" -> s.copy(archivedIDs = frame["archivedSessionIds"].array.map { it.text })
            "pinned" -> s.copy(pinnedIDs = frame["pinnedSessionIds"].array.map { it.text })
            else -> s
        }
    }
    fun applySessions(value: J) { mutable.value = state.value.copy(sessions = value["items"].array.map(::SessionRow).associateBy { it.id }) }
    fun applyEvent(frame: J) {
        if (frame["type"].text != "emit") return
        val args = frame["args"].array
        val first = args.firstOrNull() ?: return
        val s = state.value
        val row = s.sessions[first.text]
        mutable.value = when (frame["event"].text) {
            "api-session/added" -> SessionRow(first).let { s.copy(sessions = s.sessions + (it.id to it)) }
            "api-session/removed" -> s.copy(sessions = s.sessions - first.text)
            "api-session/status" -> if (args.size > 1 && row != null) s.copy(sessions = s.sessions + (row.id to row.copy(running = args[1].boolean))) else s
            "api-session/activity" -> if (args.size > 1 && row != null) s.copy(sessions = s.sessions + (row.id to row.copy(updatedAt = args[1]))) else s
            "api-session/error" -> if (args.size > 1) s.copy(error = args[1].string) else s
            else -> s
        }
    }
    fun applyControl(frame: J) {
        when (frame["type"].text) {
            "baseline" -> (if (frame["value"] == kotlinx.serialization.json.JsonNull) frame else frame["value"])["projections"].obj.forEach { (id, value) -> updateProjections(id, value["values"]) }
            "projection" -> {
                val id = frame["sessionId"].text
                var values = state.value.sessions[id]?.projections ?: EMPTY
                frame["changes"].array.forEach { values = values.with(it["key"].text, it["val"]) }
                updateProjections(id, values)
            }
        }
    }
    private fun updateProjections(id: String, values: J) {
        val s = state.value; val row = s.sessions[id] ?: return
        mutable.value = s.copy(sessions = s.sessions + (id to row.copy(projections = values, title = values["title"].string ?: L("New conversation", "新对话"))))
    }
    suspend fun refresh() { applySessions(api.rpc("session/list", o("_request" to EMPTY))) }
    fun start() {
        if (tasks.isNotEmpty()) return
        tasks = listOf("workspace/follow", "session/control").map { endpoint -> scope.launch {
            try { api.stream(endpoint).collect { if (endpoint == "workspace/follow") applyWorkspace(it) else applyControl(it) } }
            catch (e: CancellationException) { throw e } catch (e: Exception) { mutable.value = state.value.copy(error = e.message) }
        } }
    }
    fun stop() { tasks.forEach { it.cancel() }; tasks = emptyList() }
    suspend fun createSession(workspaceID: String? = null, cwd: String? = null): String {
        var request = o("agentPreset" to "standard")
        if (workspaceID != null) request = request.with("workspaceId", workspaceID) else if (cwd != null) request = request.with("cwd", cwd)
        val value = api.rpc("session/create", o("request" to request)); refresh(); return value["sessionId"].text
    }
    suspend fun rename(id: String, title: String) {
        val value = api.rpc("session/rename", o("request" to o("sessionId" to id, "title" to title)))
        state.value.sessions[id]?.let { row -> mutable.value = state.value.copy(sessions = state.value.sessions + (id to row.copy(title = value["title"].text))) }
    }
    suspend fun archive(id: String) {
        val value = api.rpc("workspace/archiveSession", o("request" to o("sessionId" to id)))
        mutable.value = state.value.copy(archivedIDs = value["archivedSessionIds"].array.map { it.text })
    }
    suspend fun pin(id: String, pinned: Boolean) {
        val value = api.rpc(if (pinned) "workspace/pinSession" else "workspace/unpinSession", o("request" to o("sessionId" to id)))
        mutable.value = state.value.copy(pinnedIDs = value["pinnedSessionIds"].array.map { it.text })
    }
    fun setSearchText(text: String) { if (text != state.value.searchText) mutable.value = state.value.copy(searchText = text, searchResults = emptyList()) }
    fun setArchivedOnly(value: Boolean) { mutable.value = state.value.copy(archivedOnly = value) }
    fun clearSearchResults() { mutable.value = state.value.copy(searchResults = emptyList()) }
    suspend fun search(query: String) {
        clearSearchResults()
        if (query.isBlank()) return
        val value = api.rpc("session/search", o("request" to o("query" to query)))
        if (state.value.searchText == query) mutable.value = state.value.copy(searchResults = value["items"].array)
    }
    suspend fun unarchive(id: String) {
        val value = api.rpc("workspace/unarchiveSession", o("request" to o("sessionId" to id)))
        mutable.value = state.value.copy(archivedIDs = value["archivedSessionIds"].array.map { it.text })
    }
    suspend fun createWorkspace(path: String) {
        val value = api.rpc("workspace/create", o("request" to o("path" to path)))
        applyWorkspace(o("type" to "upsert", "workspace" to value["workspace"]))
    }
    suspend fun renameWorkspace(id: String, title: String) {
        val value = api.rpc("workspace/rename", o("request" to o("workspaceId" to id, "title" to title)))
        applyWorkspace(o("type" to "upsert", "workspace" to value["workspace"]))
    }
    suspend fun deleteWorkspace(id: String) {
        api.rpc("workspace/delete", o("request" to o("workspaceId" to id)))
        mutable.value = state.value.copy(workspaces = state.value.workspaces.filterNot { it.id == id })
    }
    suspend fun folders(path: String = ""): J = api.portal("fs", if (path.isEmpty()) emptyMap() else mapOf("path" to path))["listing"]
    suspend fun makeFolder(parent: String, name: String): J = api.portal("fs/mkdir", body = o("parent" to parent, "name" to name))["created"]
}
