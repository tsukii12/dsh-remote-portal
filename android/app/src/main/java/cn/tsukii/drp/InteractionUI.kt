package cn.tsukii.drp

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InteractionSheet(item: PendingInteraction, api: RPCServing, events: RemoteEvents, onLater: () -> Unit) {
    val approval = item.kind == "approval/request"
    val loader = remember(item.id) { ApprovalInputLoader(api, item) }
    val input by loader.state.collectAsState()
    val draft = remember(item.id) { QuestionDraft() }
    var revision by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val questions = item.request["questions"].array
    LaunchedEffect(item.id) { if (approval) loader.load() }
    fun perform(action: suspend () -> Unit) { scope.launch {
        busy = true; error = null
        try { action() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message } finally { busy = false }
    } }
    ModalBottomSheet(onDismissRequest = onLater, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            TextButton(onClick = onLater, modifier = Modifier.align(Alignment.End)) { Text(L("Later", "稍后")) }
            Text(if (approval) L("Approval required", "需要审批") else L("Your input is needed", "需要你的回答"), style = MaterialTheme.typography.headlineSmall)
            if (approval) {
                Text(item.request["toolName"].text, style = MaterialTheme.typography.titleMedium)
                val reason = InteractionPresentation.reason(item.request)
                if (reason.isNotEmpty()) Text(reason)
                Text(L("Exact command / arguments", "完整命令 / 参数"), style = MaterialTheme.typography.labelLarge)
                if (input.isLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
                input.input?.let { CodeView(if (item.request["toolName"].text == "bash") "sh" else "json", it) }
                input.error?.let { ErrorBanner(it); TextButton(onClick = { scope.launch { loader.load() } }) { Text(L("Retry loading input", "重新加载输入")) } }
                error?.let { ErrorBanner(it) }
                Button(onClick = { perform { events.answerApproval(item.id, true) } }, enabled = !busy && input.canAllow, modifier = Modifier.fillMaxWidth()) { Text(L("Allow once", "允许一次")) }
                OutlinedButton(onClick = { perform { events.answerApproval(item.id, false) } }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text(L("Reject", "拒绝")) }
            } else {
                val canSubmit = remember(revision) { draft.canSubmit(questions) }
                    questions.forEach { question ->
                        Text(question["header"].text, style = MaterialTheme.typography.titleSmall)
                        Text(question["question"].text, style = MaterialTheme.typography.bodyLarge)
                        question["options"].array.forEach { option ->
                            val label = option["label"].text
                            val checked = label in draft.selected[question["id"].text].orEmpty()
                            Row(Modifier.fillMaxWidth().clickable(enabled = !busy) { draft.toggle(label, question); revision++ }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                if (question["multiSelect"].boolean) Checkbox(checked, onCheckedChange = null) else RadioButton(checked, onClick = null)
                                Spacer(Modifier.width(12.dp))
                                Column { Text(label); option["description"].string?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
                            }
                        }
                        if (question["intent"]["kind"].text != "approval") {
                            OutlinedTextField(draft.custom[question["id"].text].orEmpty(), { draft.setCustom(it, question); revision++ }, modifier = Modifier.fillMaxWidth(), minLines = 2, maxLines = 5, enabled = !busy, label = { Text(L("Or write your answer…", "或输入你的回答…")) })
                        }
                        if (question["multiSelect"].boolean) Text(L("Choose one or more options.", "可选择多个选项。"), style = MaterialTheme.typography.bodySmall)
                        HorizontalDivider()
                    }
                error?.let { ErrorBanner(it) }
                Button(onClick = { perform { events.answerQuestions(item.id, draft.answers(questions)) } }, enabled = !busy && canSubmit, modifier = Modifier.fillMaxWidth()) { Text(L("Submit answers", "提交回答")) }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}
