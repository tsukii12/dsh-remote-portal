package cn.tsukii.drp

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun WorkspaceScreen(connection: NativeConnection, serverName: String, addressLabel: String, onSwitch: () -> Unit, onLogout: suspend () -> Unit) {
    val sidebar by connection.sidebar.state.collectAsState()
    val events by connection.events.state.collectAsState()
    val connectionError by connection.error.collectAsState()
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    var rename by remember { mutableStateOf<SessionRow?>(null) }
    var renameText by remember { mutableStateOf("") }
    var renameWorkspace by remember { mutableStateOf<WorkspaceRow?>(null) }
    var deleteWorkspace by remember { mutableStateOf<WorkspaceRow?>(null) }
    var folders by remember { mutableStateOf(false) }
    var viewOptions by remember { mutableStateOf(false) }
    var contentSearch by rememberSaveable { mutableStateOf(false) }
    var interactionID by remember { mutableStateOf<String?>(null) }
    var deferred by rememberSaveable { mutableStateOf(emptyList<String>()) }
    LaunchedEffect(events.pending, selected) {
        if (events.pending.none { it.id == interactionID }) {
            interactionID = InteractionRouting.automatic(events.pending, selected, deferred.toSet())?.id
        }
    }
    fun perform(action: suspend () -> Unit) { scope.launch { try { action() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message } } }
    fun open(id: String) { selected = id; scope.launch { drawer.close() } }
    fun review(item: PendingInteraction) {
        interactionID = item.id
        InteractionRouting.sessionID(item, sidebar.sessions.keys)?.let { open(it) }
        scope.launch { drawer.close() }
    }
    fun create(workspace: String? = null) { perform { open(connection.sidebar.createSession(workspace)) } }
    LaunchedEffect(sidebar.searchText, contentSearch) {
        connection.sidebar.clearSearchResults()
        delay(300)
        if (contentSearch) try { connection.sidebar.search(sidebar.searchText) }
        catch (e: CancellationException) { throw e } catch (e: Exception) { error = L("Content search unavailable; showing name matches. ", "内容搜索不可用，正在显示名称匹配。") + e.message }
    }
    ModalNavigationDrawer(drawerState = drawer, drawerContent = {
        ModalDrawerSheet(Modifier.widthIn(max = 340.dp)) {
            Text("DeepSeek Remote", Modifier.padding(start = 20.dp, top = 12.dp), style = MaterialTheme.typography.titleLarge)
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, top = 12.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(serverName, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                GlyphButton(Icons.Default.Add, L("New chat", "新对话")) { create() }
            }
            Text(addressLabel, Modifier.padding(horizontal = 20.dp, vertical = 8.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
            OutlinedTextField(sidebar.searchText, { connection.sidebar.setSearchText(it) }, label = { Text(L("Search sessions", "搜索会话")) }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
            Box {
                TextButton(onClick = { viewOptions = true }, modifier = Modifier.padding(horizontal = 12.dp)) { Text(if (sidebar.archivedOnly) L("Archived · View options", "已归档 · 视图选项") else L("View options", "视图选项")) }
                DropdownMenu(viewOptions, onDismissRequest = { viewOptions = false }) {
                    DropdownMenuItem(text = { Text((if (sidebar.archivedOnly) "✓ " else "") + L("Archived sessions", "已归档会话")) }, onClick = { connection.sidebar.setArchivedOnly(!sidebar.archivedOnly); viewOptions = false })
                    DropdownMenuItem(text = { Text((if (contentSearch) "✓ " else "") + L("Search message content", "搜索消息内容")) }, onClick = { contentSearch = !contentSearch; viewOptions = false })
                    DropdownMenuItem(text = { Text(L("Add workspace", "添加工作区")) }, onClick = { folders = true; viewOptions = false })
                }
            }
            PullToRefreshBox(isRefreshing = refreshing, onRefresh = {
                perform { refreshing = true; try { connection.sidebar.refresh() } finally { refreshing = false } }
            }, modifier = Modifier.weight(1f)) {
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp)) {
                    error?.let { message -> item(key = "action-error") { ErrorBanner(message) { error = null } } }
                    if (!sidebar.loaded) item(key = "workspace-loading") {
                        Row(Modifier.fillMaxWidth().padding(24.dp), verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(12.dp))
                            Text(L("Loading workspaces…", "正在加载工作区…"))
                        }
                    }
                    sidebar.displayGroups.forEach { group ->
                        if (group.sessions.isNotEmpty() || group.id !in listOf("pinned", "ungrouped")) {
                            item(key = "group:${group.id}") {
                                Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Text(group.title, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                                    if (group.id !in listOf("pinned", "ungrouped")) GlyphButton(Icons.Default.Add, L("New chat in ${group.title}", "在 ${group.title} 中新建对话")) { create(group.id) }
                                    sidebar.workspaces.find { it.id == group.id }?.let { workspace ->
                                        var menu by remember { mutableStateOf(false) }
                                        Box {
                                            TextButton(onClick = { menu = true }, contentPadding = PaddingValues(4.dp)) { Text("⋯") }
                                            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                                                DropdownMenuItem(text = { Text(L("Rename workspace", "重命名工作区")) }, onClick = { menu = false; renameWorkspace = workspace; renameText = workspace.title })
                                                DropdownMenuItem(text = { Text(L("Remove workspace", "移除工作区")) }, onClick = { menu = false; deleteWorkspace = workspace })
                                            }
                                        }
                                    }
                                }
                            }
                            items(group.sessions, key = { "${group.id}:${it.id}" }) { row ->
                                var menu by remember { mutableStateOf(false) }
                                Box(Modifier.padding(horizontal = 12.dp, vertical = 2.dp)) {
                                    Surface(color = if (selected == row.id) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface, shape = MaterialTheme.shapes.medium) {
                                        Row(Modifier.fillMaxWidth().combinedClickable(onClick = { open(row.id) }, onLongClick = { menu = true }).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                                            if (row.running) { CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 2.dp); Spacer(Modifier.width(10.dp)) }
                                            Column(Modifier.weight(1f)) {
                                                Text(row.title, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                                                val pending = InteractionRouting.forSession(events.pending, row.id)
                                                if (pending.isNotEmpty()) TextButton(onClick = { review(pending.first()) }, contentPadding = PaddingValues(0.dp)) {
                                                    Text(InteractionRouting.label(pending), style = MaterialTheme.typography.labelSmall)
                                                }
                                            }
                                        }
                                    }
                                    DropdownMenu(menu, onDismissRequest = { menu = false }) {
                                        DropdownMenuItem(text = { Text(L("Rename", "重命名")) }, onClick = { menu = false; rename = row; renameText = row.title })
                                        val pinned = row.id in sidebar.pinnedIDs
                                        DropdownMenuItem(text = { Text(if (pinned) L("Unpin", "取消置顶") else L("Pin", "置顶")) }, onClick = { menu = false; perform { connection.sidebar.pin(row.id, !pinned) } })
                                        DropdownMenuItem(text = { Text(if (sidebar.archivedOnly) L("Unarchive", "取消归档") else L("Archive", "归档")) }, onClick = { menu = false; perform {
                                            if (sidebar.archivedOnly) connection.sidebar.unarchive(row.id) else connection.sidebar.archive(row.id)
                                            if (selected == row.id) selected = null
                                        } })
                                    }
                                }
                            }
                        }
                    }
                    if (sidebar.loaded && sidebar.sessions.isEmpty()) item { Text(L("No conversations yet", "还没有对话"), Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    else if (sidebar.loaded && sidebar.displayGroups.all { it.sessions.isEmpty() }) item { Text(L("No matching sessions", "没有匹配的会话"), Modifier.padding(24.dp)) }
                }
            }
            HorizontalDivider()
            TextButton(onClick = onSwitch, modifier = Modifier.fillMaxWidth()) { Text(L("Switch server", "切换服务器")) }
            TextButton(onClick = { perform { onLogout() } }, modifier = Modifier.fillMaxWidth()) { Text(L("Log out", "退出登录")) }
        }
    }) {
        Scaffold(topBar = {
            TopAppBar(title = { Text(sidebar.sessions[selected]?.title ?: L("New conversation", "新对话"), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { GlyphButton(Icons.Default.Menu, L("Sessions", "会话")) { scope.launch { drawer.open() } } },
                actions = { GlyphButton(Icons.Default.Add, L("New chat", "新对话")) { create() } })
        }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding)) {
                if (events.clientID == null || !sidebar.loaded) Surface(color = MaterialTheme.colorScheme.secondaryContainer) {
                    Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp); Spacer(Modifier.width(10.dp))
                        Text(L("Connecting / reconnecting…", "正在连接 / 重新连接…"), style = MaterialTheme.typography.labelMedium)
                    }
                }
                (error ?: connectionError ?: sidebar.error ?: events.error)?.let { ErrorBanner(it) { error = null } }
                if (events.pending.isNotEmpty()) Surface(color = MaterialTheme.colorScheme.secondaryContainer) {
                    TextButton(onClick = { review(events.pending.first()) }, modifier = Modifier.fillMaxWidth()) {
                        Text(InteractionRouting.label(events.pending))
                    }
                }
                val id = selected
                if (id != null) key(id) { ChatScreen(remember(id) { connection.chat(id) }) }
                else Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Text(L("Ready when you are", "随时开始"), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(12.dp))
                    Text(L("Choose a conversation from the sidebar or start a new chat.", "从侧栏选择对话，或开始新对话。"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(24.dp))
                    Button(onClick = { create() }) { Text(L("New chat", "新对话")) }
                }
            }
        }
    }
    rename?.let { row -> AlertDialog(onDismissRequest = { rename = null }, title = { Text(L("Rename conversation", "重命名对话")) },
        text = { OutlinedTextField(renameText, { renameText = it }, label = { Text(L("Title", "标题")) }, singleLine = true) },
        confirmButton = { TextButton(enabled = renameText.isNotBlank(), onClick = { perform { connection.sidebar.rename(row.id, renameText.trim()); rename = null } }) { Text(L("Save", "保存")) } },
        dismissButton = { TextButton(onClick = { rename = null }) { Text(L("Cancel", "取消")) } }) }
    renameWorkspace?.let { workspace -> AlertDialog(onDismissRequest = { renameWorkspace = null }, title = { Text(L("Rename workspace", "重命名工作区")) },
        text = { OutlinedTextField(renameText, { renameText = it }, label = { Text(L("Title", "标题")) }, singleLine = true) },
        confirmButton = { TextButton(enabled = renameText.isNotBlank(), onClick = { perform { connection.sidebar.renameWorkspace(workspace.id, renameText.trim()); renameWorkspace = null } }) { Text(L("Save", "保存")) } },
        dismissButton = { TextButton(onClick = { renameWorkspace = null }) { Text(L("Cancel", "取消")) } }) }
    deleteWorkspace?.let { workspace -> AlertDialog(onDismissRequest = { deleteWorkspace = null }, title = { Text(L("Remove workspace?", "移除工作区？")) },
        text = { Text(L("Removes the workspace registration, not the host folder or its files.", "仅移除工作区记录，不会删除主机文件夹或其中的文件。")) },
        confirmButton = { TextButton(onClick = { perform { connection.sidebar.deleteWorkspace(workspace.id); deleteWorkspace = null } }) { Text(L("Remove workspace", "移除工作区")) } },
        dismissButton = { TextButton(onClick = { deleteWorkspace = null }) { Text(L("Cancel", "取消")) } }) }
    if (folders) HostFolderSheet(connection.sidebar) { folders = false }
    events.pending.find { it.id == interactionID }?.let { item -> key(item.id) {
        InteractionSheet(item, connection.api, connection.events, onLater = {
            deferred = (deferred + item.id).distinct()
            interactionID = null
        })
    } }
}
