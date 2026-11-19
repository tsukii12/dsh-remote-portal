package cn.tsukii.drp

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

object ChatLabels {
    fun permission(id: String): String = when (id) {
        "read-only" -> L("Read Only", "只读")
        "workspace-write" -> L("Workspace Write", "工作区写入")
        "danger-full-access" -> L("Full access", "完全访问")
        else -> id
    }
    fun preset(id: String): String = when (id) {
        "standard" -> L("Standard", "标准")
        "ptc" -> "PTC"
        "minimal" -> L("Minimal", "精简")
        "cordis" -> L("Creator", "创造者")
        else -> id
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatOptionsSheet(chat: ChatStore, onDismiss: () -> Unit) {
    val state by chat.state.collectAsState()
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmAccess by remember { mutableStateOf(false) }
    fun perform(action: suspend () -> Unit) { scope.launch {
        busy = true; error = null
        try { action() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message } finally { busy = false }
    } }
    LaunchedEffect(chat) { perform { chat.loadModels(); chat.loadControls() } }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(L("Chat options", "聊天选项"), style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = onDismiss) { Text(L("Done", "完成")) }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            error?.let { ErrorBanner(it) { error = null } }
            ErrorPresentation.catalogError(state.catalog)?.let { ErrorBanner(it) }
            state.catalog["groups"].array.forEach { group ->
                OptionsHeading(group["name"].string ?: group["id"].text)
                group["models"].array.forEach { model ->
                    OptionButton(model["name"].string ?: model["id"].text,
                        state.currentModel["provider"] == group["id"] && state.currentModel["model"] == model["id"], !busy,
                        model["description"].string) { perform { chat.selectModel(group["id"].text, model["id"].text) } }
                }
            }
            val efforts = state.modelDefinition["reasoning"]["efforts"].array
            if (efforts.isNotEmpty()) {
                OptionsHeading(L("Thinking effort", "思考强度"))
                OptionButton(L("Default", "默认"), state.currentModel["reasoningEffort"].string == null, !busy) {
                    perform { chat.selectModel(state.currentModel["provider"].text, state.currentModel["model"].text, useDefaultEffort = true) }
                }
                efforts.forEach { effort -> OptionButton(effort["name"].string ?: effort["id"].text, effort["id"] == state.currentModel["reasoningEffort"], !busy) {
                    perform { chat.selectModel(state.currentModel["provider"].text, state.currentModel["model"].text, effort["id"].text) }
                } }
            }
            OptionsHeading(L("Access mode", "访问模式"))
            state.permissionCatalog["options"].array.forEach { option ->
                val id = option["value"].text
                OptionButton(ChatLabels.permission(id), state.projections["permissions"]["currentValue"].text == id, !busy) {
                    if (id == "danger-full-access") confirmAccess = true else perform { chat.selectPermission(id) }
                }
            }
            Text(L("Applies to this session, not the default for new sessions.", "仅适用于当前会话，不影响新会话的默认设置。"), style = MaterialTheme.typography.bodySmall)
            OptionsHeading(L("Plan & agent preset", "计划与代理预设"))
            OptionButton(L("Plan mode", "计划模式"), state.planEnabled, !busy && state.canChangePlan) {
                perform { chat.executeCommand(if (state.planEnabled) "/plan off" else "/plan") }
            }
            state.presetCatalog["presets"].array.forEach { preset ->
                OptionButton(ChatLabels.preset(preset["id"].text), state.projections["agentPreset"] == preset["id"], !busy && !state.sessionStarted && preset["broken"].string == null) {
                    perform { chat.selectPreset(preset["id"].text) }
                }
            }
            Text(if (state.sessionStarted) L("Plan mode and agent preset are locked after the first message.", "发送第一条消息后，计划模式和代理预设已锁定。")
                else L("Choose plan mode and agent preset before the first message.", "请在发送第一条消息前选择计划模式和代理预设。"), style = MaterialTheme.typography.bodySmall)
            TextButton(enabled = !busy, onClick = { perform { chat.loadModels(); chat.loadControls() } }) { Text(L("Refresh options", "刷新选项")) }
        }
    }
    if (confirmAccess) AlertDialog(onDismissRequest = { confirmAccess = false }, title = { Text(L("Allow full host access?", "允许完全访问主机？")) },
        text = { Text(L("Tools may run outside the workspace without the usual sandbox restrictions.", "工具可在工作区之外运行，不受通常的沙箱限制。")) },
        confirmButton = { TextButton(onClick = { confirmAccess = false; perform { chat.selectPermission("danger-full-access") } }) { Text(L("Full access", "完全访问")) } },
        dismissButton = { TextButton(onClick = { confirmAccess = false }) { Text(L("Cancel", "取消")) } })
}

@Composable
private fun OptionsHeading(text: String) {
    HorizontalDivider(Modifier.padding(top = 12.dp, bottom = 8.dp))
    Text(text, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.titleSmall)
}

@Composable
private fun OptionButton(label: String, selected: Boolean, enabled: Boolean, description: String? = null, onClick: () -> Unit) {
    TextButton(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth(), contentPadding = PaddingValues(vertical = 8.dp)) {
        Column(Modifier.weight(1f)) {
            Text(label, modifier = Modifier.fillMaxWidth())
            description?.let { Text(it, modifier = Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall) }
        }
        if (selected) Text("✓", Modifier.padding(start = 12.dp))
    }
}
