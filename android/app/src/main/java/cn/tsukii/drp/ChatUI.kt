package cn.tsukii.drp

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
fun ChatScreen(chat: ChatStore) {
    val state by chat.state.collectAsState()
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var text by rememberSaveable { mutableStateOf("") }
    var models by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var loadingOlder by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    var follow by remember { mutableStateOf(true) }
    val bottom by remember { derivedStateOf { !list.canScrollForward } }
    fun perform(action: suspend () -> Unit) { scope.launch { try { action() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message } } }
    LaunchedEffect(chat) { try { chat.start(); chat.loadModels() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message } }
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
            Box {
                val selection = state.selectedModel
                val label = selection["selected"]["model"].string ?: selection["next"]["model"].string ?: selection["lastUsed"]["model"].string ?: state.catalog["default"]["model"].string ?: L("Model", "模型")
                TextButton(onClick = { models = true }) { Text(label); Icon(Icons.Default.KeyboardArrowDown, null) }
                DropdownMenu(models, onDismissRequest = { models = false }) {
                    state.catalog["groups"].array.forEach { group ->
                        Text(group["name"].string ?: group["id"].text, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                        group["models"].array.forEach { model -> DropdownMenuItem(text = { Text(model["name"].string ?: model["id"].text) }, onClick = { models = false; perform { chat.selectModel(group["id"].text, model["id"].text) } }) }
                    }
                    ErrorPresentation.catalogError(state.catalog)?.let { ErrorBanner(it) }
                    DropdownMenuItem(text = { Text(L("Refresh models", "刷新模型")) }, onClick = { models = false; perform { chat.loadModels() } })
                }
            }
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(text, { text = it }, Modifier.weight(1f), placeholder = { Text(L("Message…", "输入消息…")) }, minLines = 1, maxLines = 6, shape = MaterialTheme.shapes.large)
                if (state.running) FilledTonalButton(onClick = { perform { chat.cancel() } }, contentPadding = PaddingValues(14.dp)) { Text("■"); Text(L(" Stop", " 停止")) }
                FilledIconButton(onClick = {
                    val message = text.trim(); text = ""; follow = true
                    perform { sending = true; try { chat.send(message) } finally { sending = false } }
                }, enabled = text.isNotBlank() && !sending) { Icon(Icons.AutoMirrored.Filled.Send, L("Send", "发送")) }
            }
        }
    }
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
