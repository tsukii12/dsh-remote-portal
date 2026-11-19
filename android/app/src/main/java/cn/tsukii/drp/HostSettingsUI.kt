package cn.tsukii.drp

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostSettingsSheet(store: HostSettingsStore, onDismiss: () -> Unit) {
    val state by store.state.collectAsState()
    val scope = rememberCoroutineScope()
    var models by remember { mutableStateOf(false) }
    var efforts by remember { mutableStateOf(false) }
    var access by remember { mutableStateOf(false) }
    var fullAccess by remember { mutableStateOf(false) }
    var revoking by remember { mutableStateOf<J?>(null) }
    val context = LocalContext.current
    val version = remember(context) { context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "?" }
    LaunchedEffect(store) { store.load() }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f).padding(horizontal = 20.dp)) {
            Row(Modifier.fillMaxWidth()) {
                Text(L("Settings", "设置"), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                TextButton(enabled = !state.busy && !state.loading, onClick = { scope.launch { store.load() } }) { Text(L("Refresh", "刷新")) }
                TextButton(onClick = onDismiss) { Text(L("Done", "完成")) }
            }
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(bottom = 24.dp)) {
                if (state.loading || state.busy || state.devicesLoading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                state.error?.let { message -> item { Text(message, color = MaterialTheme.colorScheme.error); TextButton(onClick = { scope.launch { store.load() } }, enabled = !state.loading && !state.busy) { Text(L("Reload settings", "重新加载设置")) } } }
                if (state.loaded) {
                    item { Text(L("New conversation defaults", "新对话默认设置"), style = MaterialTheme.typography.titleMedium) }
                    item {
                        Text(L("Saved on the host. Existing conversations keep their own selections.", "保存在主机上；已有对话保留各自的选择。"), style = MaterialTheme.typography.bodySmall)
                        if (!state.descriptor["writable"].boolean) Text(L("Host settings are read-only.", "主机设置为只读。"))
                        TextButton(enabled = state.writable && state.namespace("agent-default-model")["revision"].long != null, onClick = { models = !models }) { Text(L("Default model", "默认模型") + ": " + (state.definition["name"].string ?: state.model["model"].text)) }
                        TextButton(enabled = state.writable && state.namespace("agent-default-model")["revision"].long != null, onClick = { efforts = !efforts }) { Text(L("Thinking effort", "思考强度") + ": " + (state.model["reasoningEffort"].string ?: L("Default", "默认"))) }
                        if (efforts) {
                            TextButton(enabled = state.writable, onClick = { efforts = false; scope.launch { store.setModel(state.model["provider"].text, state.model["model"].text, null) } }) { Text(L("Default", "默认")) }
                            state.definition["reasoning"]["efforts"].array.forEach { effort -> TextButton(enabled = state.writable, onClick = { efforts = false; scope.launch { store.setModel(state.model["provider"].text, state.model["model"].text, effort["id"].text) } }) { Text(effort["name"].string ?: effort["id"].text) } }
                        }
                        TextButton(enabled = state.writable && state.namespace("permission")["revision"].long != null, onClick = { access = !access }) { Text(L("Default access", "默认访问权限") + ": " + ChatLabels.permission(state.permission)) }
                        if (access) state.permissions["defaultOptions"].array.forEach { option ->
                            TextButton(enabled = state.writable, onClick = { access = false; val value = option["value"].text; if (value == "danger-full-access") fullAccess = true else scope.launch { store.setPermission(value) } }) { Text(ChatLabels.permission(option["value"].text)) }
                        }
                    }
                    if (models) state.catalog["groups"].array.forEach { group ->
                        item { Text(group["name"].string ?: group["id"].text, style = MaterialTheme.typography.titleSmall) }
                        group["models"].array.forEach { model -> item {
                            TextButton(enabled = state.writable, onClick = {
                                models = false
                                val effort = if (state.model["provider"] == group["id"] && state.model["model"] == model["id"]) state.model["reasoningEffort"].string else model["reasoning"]["defaultEffort"].string
                                scope.launch { store.setModel(group["id"].text, model["id"].text, effort) }
                            }) { Text(model["name"].string ?: model["id"].text) }
                        } }
                    }
                    item { HorizontalDivider(); Text(L("Providers", "模型提供方"), style = MaterialTheme.typography.titleMedium); Text(L("Host catalog status, not a paid generation test. Credentials are never displayed or edited here.", "状态来自主机目录，并非付费生成测试；此处不会显示或编辑凭据。"), style = MaterialTheme.typography.bodySmall) }
                    if (state.catalog["groups"].array.isEmpty()) item { Text(L("No provider models are available.", "没有可用的提供方模型。")) }
                    state.catalog["groups"].array.forEach { group -> item {
                        Text((group["name"].string ?: group["id"].text) + " · " + if (group["id"] in state.catalog["routableProviders"].array) L("Routable", "可路由") else L("Not routable", "不可路由"))
                        Text(group["models"].array.joinToString(", ") { it["name"].string ?: it["id"].text }, style = MaterialTheme.typography.bodySmall)
                    } }
                    state.catalog["failures"].array.forEach { failure -> item { ErrorBanner(failure["message"].string ?: failure["error"]["message"].string ?: failure["provider"].text) } }
                }
                item { HorizontalDivider(); Text(L("Authorized devices", "已授权设备"), style = MaterialTheme.typography.titleMedium); Text(L("The portal does not identify the current device. Revoke only a device you select and confirm; revoking this phone may sign this app out.", "门户未标识当前设备。仅撤销你选中并确认的设备；撤销本机可能使此应用退出登录。"), style = MaterialTheme.typography.bodySmall) }
                state.portalError?.let { message -> item { ErrorBanner(message); TextButton(enabled = !state.busy && !state.devicesLoading, onClick = { scope.launch { store.loadDevices() } }) { Text(L("Retry devices", "重试设备列表")) } } }
                if (state.devices.isEmpty() && !state.loading && state.portalError == null) item { Text(L("No authorized devices.", "没有已授权设备。")) }
                state.devices.forEach { device -> item {
                    Text(device["label"].string?.takeIf { it.isNotBlank() } ?: L("Device", "设备"))
                    Text(device["id"].text.take(8) + " · " + L("Last seen: ", "最近活动：") + (device["lastSeenAt"].long?.let { java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it)) } ?: L("Unknown", "未知")), style = MaterialTheme.typography.bodySmall)
                    TextButton(enabled = !state.busy && !state.loading && !state.devicesLoading, onClick = { revoking = device }) { Text(L("Revoke device", "撤销设备"), color = MaterialTheme.colorScheme.error) }
                } }
                item { HorizontalDivider(); Text(L("App version", "应用版本") + ": DeepSeek Remote " + version) }
            }
        }
    }
    if (fullAccess) AlertDialog(onDismissRequest = { fullAccess = false }, title = { Text(L("Default to full access?", "默认使用完全访问？")) }, text = { Text(L("Future conversations can run commands without normal sandbox restrictions.", "今后的对话将可在常规沙盒限制之外运行命令。")) },
        confirmButton = { TextButton(onClick = { fullAccess = false; scope.launch { store.setPermission("danger-full-access") } }) { Text(L("Use full access", "使用完全访问")) } }, dismissButton = { TextButton(onClick = { fullAccess = false }) { Text(L("Cancel", "取消")) } })
    revoking?.let { device -> AlertDialog(onDismissRequest = { revoking = null }, title = { Text(L("Revoke this device?", "撤销此设备？")) }, text = { Text((device["label"].string ?: L("Device", "设备")) + "\n" + L("Its sessions will be signed out. If this is your current device, you may lose this connection.", "其会话将退出登录；如果这是当前设备，你可能会断开连接。")) },
        confirmButton = { TextButton(onClick = { revoking = null; scope.launch { store.revokeConfirmed(device["id"].text) } }) { Text(L("Revoke device", "撤销设备")) } }, dismissButton = { TextButton(onClick = { revoking = null }) { Text(L("Cancel", "取消")) } }) }
}
