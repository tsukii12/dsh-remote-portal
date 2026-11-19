package cn.tsukii.drp

import android.content.Intent
import androidx.core.content.FileProvider
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.File

@Composable
fun ChatScreen(chat: ChatStore) {
    val state by chat.state.collectAsState()
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var text by rememberSaveable { mutableStateOf("") }
    var models by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var steer by remember { mutableStateOf(false) }
    var editingQueue by remember { mutableStateOf<String?>(null) }
    var queuedText by remember { mutableStateOf("") }
    var exported by remember { mutableStateOf<ByteArray?>(null) }
    val context = LocalContext.current
    var loadingOlder by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    var follow by remember { mutableStateOf(true) }
    val bottom by remember { derivedStateOf { !list.canScrollForward } }
    fun perform(action: suspend () -> Unit) { scope.launch { try { action() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message } } }
    LaunchedEffect(chat) { try { chat.start(); chat.loadModels(); chat.loadControls() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message } }
    DisposableEffect(chat) { onDispose { chat.stop() } }
    LaunchedEffect(list.isScrollInProgress, bottom) { if (list.isScrollInProgress) follow = bottom }
    val progress = state.inProgress
    LaunchedEffect(state.transcript, progress) {
        withFrameNanos { }
        if (follow && list.layoutInfo.totalItemsCount > 0) list.scrollToItem(list.layoutInfo.totalItemsCount - 1)
    }
    Column(Modifier.fillMaxSize().imePadding()) {
        (error ?: state.error ?: ErrorPresentation.catalogError(state.catalog))?.let { ErrorBanner(it) { error = null } }
        Box(Modifier.weight(1f)) {
            LazyColumn(state = list, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                item(key = "older") {
                    if (state.hasMore) TextButton(onClick = { perform { loadingOlder = true; follow = false; try { chat.loadOlder() } finally { loadingOlder = false } } }, enabled = !loadingOlder) { Text(if (loadingOlder) L("Loading…", "加载中…") else L("Load older messages", "加载更早消息")) }
                }
                if (!state.loaded) item(key = "loading") { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                if (state.loaded && state.transcript.isEmpty() && progress == null) item(key = "empty") {
                    Text(L("What would you like to work on?", "今天想做些什么？"), style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(vertical = 28.dp))
                }
                items(state.transcript, key = { it.id }) { MessageView(it) }
                if (progress != null) item(key = "in-progress:${progress.id}") { MessageView(progress) }
                else if (state.running) item(key = "working") { Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)); Text(L("Working…", "处理中…"), style = MaterialTheme.typography.bodySmall)
                } }
                item(key = "bottom") { Spacer(Modifier.height(4.dp)) }
            }
            if (!bottom) SmallFloatingActionButton(onClick = { follow = true; scope.launch { list.animateScrollToItem((list.layoutInfo.totalItemsCount - 1).coerceAtLeast(0)) } }, modifier = Modifier.align(Alignment.BottomCenter).padding(12.dp)) {
                Icon(Icons.Default.KeyboardArrowDown, L("Jump to bottom", "跳到底部"))
            }
        }
        HorizontalDivider()
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
            if (state.queue.isNotEmpty()) Column(Modifier.fillMaxWidth().heightIn(max = 140.dp).verticalScroll(rememberScrollState())) {
                Text(L("Queued messages", "排队消息"), style = MaterialTheme.typography.labelMedium)
                state.queue.forEach { item ->
                    var menu by remember(item["id"].text) { mutableStateOf(false) }
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(if (item["placement"].text == "steering") L("Steering", "引导中") else L("Queued", "排队中"), style = MaterialTheme.typography.labelSmall)
                            Text(item["content"].array.joinToString("\n") { it["text"].text }, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                        Box {
                            TextButton(onClick = { menu = true }) { Text(L("Actions", "操作")) }
                            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(text = { Text(L("Edit", "编辑")) }, enabled = item["content"].array.all { it["type"].text == "text" }, onClick = {
                                    menu = false; queuedText = item["content"].array.joinToString("\n") { it["text"].text }; editingQueue = item["id"].text
                                })
                                DropdownMenuItem(text = { Text(L("Steer now", "立即引导")) }, onClick = { menu = false; perform { chat.updateQueue(item["id"].text, "steer") } })
                                DropdownMenuItem(text = { Text(L("Remove", "移除")) }, onClick = { menu = false; perform { chat.updateQueue(item["id"].text, "remove") } })
                            }
                        }
                    }
                }
            }
            state.commandNotice?.let { Text(it, maxLines = 3, style = MaterialTheme.typography.bodySmall) }
            exported?.let { bytes -> TextButton(onClick = { perform {
                val directory = File(context.cacheDir, "exports").apply { mkdirs() }
                val file = File.createTempFile("DRP-session-", ".zip", directory).apply { writeBytes(bytes) }
                val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = "application/zip"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }, L("Share session log", "分享会话日志")))
            } }) { Text(L("Share session log", "分享会话日志")) } }
            if (text.startsWith("/")) Column(Modifier.fillMaxWidth().heightIn(max = 150.dp).verticalScroll(rememberScrollState())) {
                val query = text.drop(1).substringBefore(' ')
                val suggestions = (listOf(o("name" to "model", "description" to L("Choose model and thinking effort", "选择模型与思考强度"))) + state.commands).filter { query.isEmpty() || it["name"].text.startsWith(query) }
                suggestions.forEach { command -> TextButton(onClick = {
                    if (command["name"].text == "model") { text = ""; models = true }
                    else text = "/" + command["name"].text + if (command["input"] == kotlinx.serialization.json.JsonNull) "" else " "
                }, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.fillMaxWidth()) {
                        Text("/" + command["name"].text + " " + command["input"]["hint"].text)
                        Text(command["description"].text, style = MaterialTheme.typography.bodySmall, maxLines = 2)
                    }
                } }
                if (suggestions.isEmpty()) Text(L("No matching commands", "没有匹配的命令"), style = MaterialTheme.typography.bodySmall)
            }
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = { models = true }, label = { Text(L("Model: ", "模型：") + state.modelName + " · " + state.effortName) })
                AssistChip(onClick = { models = true }, label = { Text(ChatLabels.permission(state.projections["permissions"]["currentValue"].text).ifEmpty { L("Access mode", "访问模式") }) })
                AssistChip(onClick = { models = true }, label = { Text(if (state.planEnabled) L("Plan mode", "计划模式") else ChatLabels.preset(state.projections["agentPreset"].string ?: "standard")) })
            }
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(text, { text = it }, Modifier.weight(1f), placeholder = { Text(L("Message…", "输入消息…")) }, minLines = 1, maxLines = 6, shape = MaterialTheme.shapes.large)
                if (state.running) FilledTonalButton(onClick = { perform { chat.cancel() } }, contentPadding = PaddingValues(14.dp)) { Text("■"); Text(L(" Stop", " 停止")) }
                FilledIconButton(onClick = {
                    val message = text.trim(); text = ""; follow = true
                    perform { sending = true; try {
                        if (message == "/model") models = true
                        else if (message.startsWith("/")) { exported = null; exported = chat.executeCommand(message) }
                        else chat.send(message, steer)
                    } catch (e: Exception) { if (text.isEmpty()) text = message; throw e } finally { sending = false } }
                }, enabled = text.isNotBlank() && !sending) { Icon(Icons.AutoMirrored.Filled.Send, if (state.running) { if (steer) L("Steer", "立即引导") else L("Queue message", "消息排队") } else L("Send", "发送")) }
            }
            if (state.running) Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(steer, { steer = it }); Spacer(Modifier.width(8.dp)); Text(L("Steer immediately instead of queue", "立即引导而不是排队"), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
    if (models) ChatOptionsSheet(chat) { models = false }
    editingQueue?.let { id -> AlertDialog(onDismissRequest = { editingQueue = null }, title = { Text(L("Edit queued message", "编辑排队消息")) },
        text = { OutlinedTextField(queuedText, { queuedText = it }, label = { Text(L("Message", "消息")) }) },
        confirmButton = { TextButton(enabled = queuedText.isNotBlank(), onClick = { perform { chat.updateQueue(id, "edit", queuedText); editingQueue = null } }) { Text(L("Save", "保存")) } },
        dismissButton = { TextButton(onClick = { editingQueue = null }) { Text(L("Cancel", "取消")) } }) }
}

@Composable
private fun MessageView(item: TranscriptItem) {
    val user = item.role == "user"
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (user) Alignment.End else Alignment.Start) {
        Surface(color = if (user) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface, shape = if (user) MaterialTheme.shapes.large else RectangleShape) {
            Column(if (user) Modifier.padding(14.dp) else Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item.blocks.forEach { block -> when (block.kind) {
                    "text" -> MarkdownView(block.text)
                    "reasoning" -> ExpandableBlock(L("Thinking", "思考过程")) { MarkdownView(block.text) }
                    "tool-call" -> ToolCard(block)
                    else -> if (block.text.isNotEmpty()) MarkdownView(block.text)
                } }
                if (item.inProgress) Text(L("Generating…", "正在生成…"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
            }
        }
        item.deliveryError?.let { ErrorBanner(it) }
    }
}

@Composable
fun ExpandableBlock(title: String, status: String? = null, content: @Composable () -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    OutlinedCard(Modifier.fillMaxWidth()) {
        TextButton(onClick = { expanded = !expanded }, modifier = Modifier.fillMaxWidth()) {
            if (status != null) {
                Icon(when (status) { "running" -> Icons.Default.Refresh; "error" -> Icons.Default.Warning; else -> Icons.Default.CheckCircle },
                    when (status) { "running" -> L("Running", "运行中"); "error" -> L("Failed", "失败"); else -> L("Completed", "已完成") },
                    Modifier.size(18.dp), tint = if (status == "error") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(8.dp))
            }
            Text((if (expanded) "▾ " else "▸ ") + title, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (expanded) Column(Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, bottom = 14.dp)) { content() }
    }
}

@Composable
private fun ToolCard(block: TranscriptBlock) {
    val summary = ToolPresentation.summary(block.arguments)
    ExpandableBlock(block.name + if (summary.isBlank()) "" else " · $summary", ToolPresentation.status(block.result)) {
        CodeView("", block.arguments)
        block.result?.let { MarkdownView(ToolPresentation.result(it)) }
    }
}

@Composable
fun MarkdownView(text: String) {
    val blocks = remember(text) { MarkdownParser.blocks(text) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        blocks.forEach { block -> when (block) {
            is MarkdownBlock.Code -> CodeView(block.language, block.text)
            is MarkdownBlock.Paragraph -> SelectionContainer { Text(inlineMarkdown(block.text), style = MaterialTheme.typography.bodyLarge) }
            is MarkdownBlock.Heading -> Text(inlineMarkdown(block.text), style = when (block.level) { 1 -> MaterialTheme.typography.headlineMedium; 2 -> MaterialTheme.typography.headlineSmall; else -> MaterialTheme.typography.titleLarge }, fontWeight = FontWeight.Bold)
            is MarkdownBlock.ListItem -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { Text(block.bullet); Text(inlineMarkdown(block.text), Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge) }
        } }
    }
}

@Composable
private fun inlineMarkdown(text: String): AnnotatedString {
    val codeColor = MaterialTheme.colorScheme.surfaceContainerHighest
    return remember(text, codeColor) {
        buildAnnotatedString {
            val pattern = Regex("(`[^`]+`|\\*\\*[^*]+\\*\\*|__[^_]+__|\\*[^*]+\\*|_[^_]+_|\\[[^]]+](https?://[^)]+))")
            var offset = 0
            pattern.findAll(text).forEach { match ->
                append(text.substring(offset, match.range.first))
                val value = match.value
                when {
                    value.startsWith("`") -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = codeColor)) { append(value.drop(1).dropLast(1)) }
                    value.startsWith("**") || value.startsWith("__") -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(value.drop(2).dropLast(2)) }
                    value.startsWith("[") -> {
                        val end = value.indexOf("](")
                        val url = value.substring(end + 2, value.length - 1)
                        withLink(LinkAnnotation.Url(url)) { append(value.substring(1, end)) }
                    }
                    else -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(value.drop(1).dropLast(1)) }
                }
                offset = match.range.last + 1
            }
            append(text.substring(offset))
        }
    }
}

@Composable
fun CodeView(language: String, text: String) {
    val clipboard = LocalClipboardManager.current
    var copied by remember(text) { mutableStateOf(false) }
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().padding(start = 14.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(language.ifBlank { L("Code", "代码") }, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { clipboard.setText(AnnotatedString(text)); copied = true }) { Text(if (copied) L("Copied", "已复制") else L("Copy", "复制")) }
            }
            SelectionContainer(Modifier.fillMaxWidth().clipToBounds()) { Text(text, Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 14.dp, end = 14.dp, bottom = 14.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, softWrap = false) }
        }
    }
}
