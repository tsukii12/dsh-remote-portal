package cn.tsukii.drp

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.File

data class ServerDraft(val server: Server, val token: String)
fun serverDraft(name: String, addresses: String, existing: Server? = null): ServerDraft {
    val lines = addresses.lines().map { it.trim() }.filter { it.isNotEmpty() }
    if (lines.isEmpty()) throw PortalError(L("Add at least one address.", "请添加至少一个地址。"))
    var token = ""
    val urls = lines.map { line -> PortalURL.pairing(line)?.let { token = it.second; it.first } ?: PortalURL.normalize(line) }
    return ServerDraft(Server(id = existing?.id ?: java.util.UUID.randomUUID().toString(), name = name.ifBlank { urls.first().host }, addresses = urls), token)
}

@Composable
fun DRPApp() {
    val context = LocalContext.current.applicationContext
    val store = remember { ServerStore(context) }
    val servers by store.servers.collectAsState()
    val client = remember { PortalClient(CookieVault(File(context.filesDir, "PortalCookies"))) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var pairToken by remember { mutableStateOf("") }
    val server = servers.find { it.id == selected }
    Surface(Modifier.fillMaxSize()) {
        if (server == null) ServersScreen(servers, onConnect = { selected = it.id; pairToken = "" },
            onSave = { draft ->
                store.save(if (servers.any { it.id == draft.server.id }) servers.map { if (it.id == draft.server.id) draft.server else it } else servers + draft.server)
                if (draft.token.isNotEmpty()) { pairToken = draft.token; selected = draft.server.id }
            }, onDelete = { row -> store.save(servers.filterNot { it.id == row.id }) })
        else key(server.id) { ConnectionScreen(server, pairToken, client) { selected = null; pairToken = "" } }
    }
}

@Composable
fun GlyphButton(icon: ImageVector, label: String, enabled: Boolean = true, onClick: () -> Unit) {
    IconButton(onClick = onClick, enabled = enabled) { Icon(icon, contentDescription = label) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ServersScreen(servers: List<Server>, onConnect: (Server) -> Unit, onSave: (ServerDraft) -> Unit, onDelete: (Server) -> Unit) {
    var editing by remember { mutableStateOf<Server?>(null) }
    var editor by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<Server?>(null) }
    Scaffold(topBar = {
        TopAppBar(title = { Text("DeepSeek Remote", fontWeight = FontWeight.SemiBold) }, actions = {
            GlyphButton(Icons.Default.Add, L("Add server", "添加服务器")) { editing = null; editor = true }
        })
    }, floatingActionButton = {
        ExtendedFloatingActionButton(onClick = { editing = null; editor = true }, icon = { Icon(Icons.Default.Add, null) }, text = { Text(L("Add server", "添加服务器")) })
    }) { padding ->
        if (servers.isEmpty()) Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.weight(0.7f))
            Image(painterResource(R.mipmap.ic_launcher), null, Modifier.size(100.dp).clip(RoundedCornerShape(26.dp)))
            Spacer(Modifier.height(28.dp))
            Text(L("Your workspace, anywhere", "随时连接你的工作区"), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(12.dp))
            Text(L("Connect to DeepSeek Harness on your computer. Add a portal address or paste a pairing link to get started.", "连接电脑上的 DeepSeek Harness。添加门户地址或粘贴配对链接，即可开始。"),
                style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Spacer(Modifier.height(24.dp))
            Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = RoundedCornerShape(12.dp)) {
                Text(L("Native. Private. Connected.", "原生体验 · 私密连接"), Modifier.padding(horizontal = 16.dp, vertical = 10.dp), color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.labelLarge)
            }
            Spacer(Modifier.weight(1.3f))
        } else LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 100.dp, top = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Text(L("YOUR SERVERS", "我的服务器"), Modifier.padding(8.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            items(servers, key = { it.id }) { row ->
                var menu by remember { mutableStateOf(false) }
                Card(onClick = { onConnect(row) }, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
                    Row(Modifier.fillMaxWidth().padding(start = 20.dp, top = 16.dp, bottom = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(row.name, style = MaterialTheme.typography.titleMedium)
                            Text(row.addresses.joinToString("\n"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3, overflow = TextOverflow.Ellipsis)
                        }
                        Box {
                            GlyphButton(Icons.Default.MoreVert, L("Server options", "服务器选项")) { menu = true }
                            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(text = { Text(L("Edit", "编辑")) }, onClick = { menu = false; editing = row; editor = true })
                                DropdownMenuItem(text = { Text(L("Delete", "删除")) }, onClick = { menu = false; deleting = row })
                            }
                        }
                        GlyphButton(Icons.AutoMirrored.Filled.ArrowForward, L("Connect", "连接")) { onConnect(row) }
                    }
                }
            }
        }
    }
    if (editor) ServerEditor(editing, onDismiss = { editor = false }, onSave = { onSave(it); editor = false })
    deleting?.let { row -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text(L("Delete server?", "删除服务器？")) },
        text = { Text(L("Remove ${row.name} from this device? This does not log out the remote session.", "从此设备移除 ${row.name}？这不会退出远程会话。")) },
        confirmButton = { TextButton(onClick = { onDelete(row); deleting = null }) { Text(L("Delete", "删除")) } },
        dismissButton = { TextButton(onClick = { deleting = null }) { Text(L("Cancel", "取消")) } }) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ServerEditor(server: Server?, onDismiss: () -> Unit, onSave: (ServerDraft) -> Unit) {
    var name by rememberSaveable { mutableStateOf(server?.name.orEmpty()) }
    var addresses by rememberSaveable { mutableStateOf(server?.addresses?.joinToString("\n").orEmpty()) }
    var error by remember { mutableStateOf<String?>(null) }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(modifier = Modifier.fillMaxSize().imePadding(), topBar = {
            TopAppBar(title = { Text(if (server == null) L("Add server", "添加服务器") else L("Edit server", "编辑服务器")) },
                navigationIcon = { GlyphButton(Icons.Default.Close, L("Cancel", "取消"), onClick = onDismiss) }, actions = {
                    TextButton(onClick = { try { onSave(serverDraft(name, addresses, server)) } catch (e: Exception) { error = e.message } }) { Text(L("Save", "保存")) }
                })
        }) { padding ->
            Column(Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text(L("Name", "名称")) }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                OutlinedTextField(addresses, { addresses = it }, label = { Text(L("Addresses or pairing link", "地址或配对链接")) }, modifier = Modifier.fillMaxWidth(), minLines = 5,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), supportingText = { Text(L("One address per line. Keep relay prefixes, e.g. https://relay.example/__t/id/", "每行一个地址。保留中继路径前缀，例如 https://relay.example/__t/id/")) })
                error?.let { ErrorBanner(it) }
                Text(L("Pairing links open a native confirmation screen. Passwords and pairing codes are never saved.", "配对链接将打开原生确认界面。密码和配对码不会保存。"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionScreen(server: Server, initialToken: String, client: PortalClient, onSwitch: () -> Unit) {
    var result by remember { mutableStateOf<HealthResult?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(attempt) {
        error = null
        try { result = client.connect(server.addresses) }
        catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
    }
    BackHandler(onBack = onSwitch)
    val winner = result
    if (winner == null) Scaffold(topBar = { TopAppBar(title = { Text(server.name) }, navigationIcon = {
        GlyphButton(Icons.AutoMirrored.Filled.ArrowBack, L("Servers", "服务器"), onClick = onSwitch)
    }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            if (error == null) { CircularProgressIndicator(); Spacer(Modifier.height(20.dp)); Text(L("Finding fastest address…", "正在寻找最快地址…")) }
            error?.let { ErrorBanner(it); TextButton(onClick = { attempt++ }) { Text(L("Retry", "重试")) } }
        }
    } else {
        val api = remember(winner.base) { PortalAPI(winner.base, client, scope) }
        ConnectionGate(api, initialToken, server.name.ifBlank { winner.base.host }, winner.label, onSwitch)
    }
}

@Composable
private fun ConnectionGate(api: PortalAPI, initialToken: String, serverName: String, addressLabel: String, onSwitch: () -> Unit) {
    val connection = remember(api) { NativeConnection(api) }
    val expired by api.sessionExpired.collectAsState()
    var signedIn by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun resume() {
        busy = true; error = null
        try { connection.start(); signedIn = true }
        catch (e: CancellationException) { throw e }
        catch (_: APIError.SessionExpired) { signedIn = false }
        catch (e: Exception) { error = e.message }
        finally { busy = false }
    }
    LaunchedEffect(api) { if (initialToken.isEmpty()) resume() }
    LaunchedEffect(expired) { if (expired) { signedIn = false; connection.stop() } }
    DisposableEffect(connection) { onDispose { connection.stop() } }
    if (signedIn) WorkspaceScreen(connection, serverName, addressLabel, onSwitch, onLogout = {
        api.logout(); connection.stop(); signedIn = false
    }) else LoginScreen(serverName, addressLabel, initialToken, busy, error, onSwitch, onLogin = { secret, pairing ->
        scope.launch {
            busy = true; error = null
            try { api.login(secret, pairing); resume() }
            catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
            finally { busy = false }
        }
    })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LoginScreen(serverName: String, address: String, initialToken: String, busy: Boolean, error: String?, onSwitch: () -> Unit, onLogin: (String, Boolean) -> Unit) {
    var pairing by remember { mutableStateOf(initialToken.isNotEmpty()) }
    var secret by remember { mutableStateOf(initialToken) }
    Scaffold(topBar = { TopAppBar(title = { Text("DRP") }, navigationIcon = { GlyphButton(Icons.AutoMirrored.Filled.ArrowBack, L("Servers", "服务器"), onClick = onSwitch) }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(28.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Spacer(Modifier.height(12.dp))
            Text(serverName, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.titleMedium)
            Text(L("Verify this device", "验证这台设备"), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            Text(if (pairing) L("Confirm the pairing code generated on your computer to connect this device to DeepSeek Harness.", "确认电脑生成的配对码，将这台设备接入 DeepSeek Harness。")
                else L("Enter your computer’s access password to continue to your workspace.", "输入电脑端的访问密码，进入你的工作区。"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(12.dp)) {
                Text(address, Modifier.padding(14.dp), style = MaterialTheme.typography.bodySmall)
            }
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf(false, true).forEachIndexed { index, value -> SegmentedButton(selected = pairing == value, onClick = { if (pairing != value) { pairing = value; secret = "" } },
                    shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(if (value) L("Pairing code", "配对码") else L("Password", "密码")) } }
            }
            OutlinedTextField(secret, { secret = it }, modifier = Modifier.fillMaxWidth(), singleLine = true, enabled = !busy, label = { Text(if (pairing) L("Pairing code", "配对码") else L("Access password", "访问密码")) },
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
            error?.let { ErrorBanner(it) }
            Button(onClick = { onLogin(secret, pairing); secret = "" }, enabled = !busy && secret.isNotEmpty(), modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                if (busy) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(12.dp)) }
                Text(if (pairing) L("Confirm pairing", "确认配对") else L("Continue", "继续"))
            }
        }
    }
}

@Composable
fun ErrorBanner(message: String, onDismiss: (() -> Unit)? = null) {
    var details by remember(message) { mutableStateOf(false) }
    var dismissed by remember(message) { mutableStateOf(false) }
    if (dismissed) return
    Surface(color = MaterialTheme.colorScheme.errorContainer, shape = RoundedCornerShape(12.dp)) {
        Column(Modifier.fillMaxWidth().padding(start = 14.dp, top = 8.dp, bottom = 8.dp, end = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(ErrorPresentation.headline(message), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onErrorContainer)
                if (onDismiss != null) GlyphButton(Icons.Default.Close, L("Dismiss", "关闭")) { dismissed = true; onDismiss() }
            }
            TextButton(onClick = { details = !details }) { Text((if (details) "▾ " else "▸ ") + L("Details", "详情")) }
            if (details) Text(message, Modifier.heightIn(max = 160.dp).verticalScroll(rememberScrollState()).padding(end = 10.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onErrorContainer)
        }
    }
}
