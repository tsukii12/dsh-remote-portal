package cn.tsukii.drp

import android.content.Intent
import android.graphics.BitmapFactory
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.*
import java.io.File
import java.util.UUID

@Composable
fun WorkspaceFilesPanel(store: WorkspaceFilesStore, onMention: (String) -> Unit, onDismiss: () -> Unit) {
    val state by store.state.collectAsState()
    var path by remember(store) { mutableStateOf<String?>(null) }
    val preview = remember(store, path) { path?.let(store::preview) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(store) { store.start() }
    DisposableEffect(store) { onDispose { store.close() } }
    Dialog(onDismissRequest = { if (path != null) path = null else onDismiss() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().navigationBarsPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (preview != null) TextButton(onClick = { path = null }) { Text(L("Back", "返回")) }
                    Text(path?.substringAfterLast('/') ?: L("Files", "文件"), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    TextButton(onClick = { if (preview == null) store.refresh() else scope.launch { preview.load(true) } }) { Text(L("Refresh", "刷新")) }
                    TextButton(onClick = onDismiss) { Text(L("Done", "完成")) }
                }
                if (preview != null) WorkspaceFilePreview(preview, onMention)
                else {
                    Text(L("Session workspace", "会话工作区") + " · .", style = MaterialTheme.typography.labelMedium)
                    OutlinedTextField(state.query, store::search, label = { Text(L("Search names or paths", "搜索名称或路径")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    state.watchError?.let { ErrorBanner(it) }
                    LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (state.query.isBlank()) directory(".", 0, state, store, { path = it }, onMention)
                        else {
                            if (state.searching) item { FilesLoading(L("Searching…", "正在搜索…")) }
                            state.searchError?.let { message -> item { ErrorBanner(message); TextButton(onClick = { store.search(state.query) }) { Text(L("Retry", "重试")) } } }
                            if (!state.searching && state.searchError == null && state.results.isEmpty()) item { Text(L("No matching files.", "没有匹配的文件。")) }
                            state.results.forEachIndexed { index, entry -> item(key = "search:$index") {
                                FileEntry(entry, entry["path"].text, 0, false, { if (entry["type"].text == "directory") store.openDirectory(entry["path"].text) else path = entry["path"].text }, onMention)
                            } }
                            if (state.truncated || state.incomplete) item { Text(L("The host limited this search. Narrow the query or refresh.", "主机限制了搜索结果，请缩小搜索范围或刷新。"), style = MaterialTheme.typography.bodySmall) }
                        }
                    }
                }
            }
        }
    }
}

private fun LazyListScope.directory(path: String, depth: Int, state: WorkspaceFilesState, store: WorkspaceFilesStore, open: (String) -> Unit, mention: (String) -> Unit) {
    val listing = state.directories[path]
    when {
        listing == null || listing.loading -> item(key = "loading:$path") { FilesLoading(L("Loading files…", "正在加载文件…")) }
        listing.error != null -> item(key = "error:$path") { ErrorBanner(listing.error); TextButton(onClick = { store.load(path) }) { Text(L("Retry", "重试")) } }
        else -> {
            if (listing.entries.isEmpty()) item(key = "empty:$path") { Text(L("This folder is empty.", "此文件夹为空。"), Modifier.padding(start = (depth * 14).dp)) }
            listing.entries.forEach { entry ->
                val child = WorkspaceFilesStore.child(path, entry["name"].text)
                val dir = entry["type"].text == "directory"
                item(key = "entry:$child") { FileEntry(entry, child, depth, child in state.expanded, { if (dir) store.toggle(child) else open(child) }, mention) }
                if (dir && child in state.expanded) directory(child, depth + 1, state, store, open, mention)
            }
            if (listing.truncated) item(key = "truncated:$path") { Text(L("The host limited this directory listing. Open a subfolder to see more.", "主机限制了此目录的列表数量，请打开子文件夹查看更多内容。"), style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
private fun FileEntry(entry: J, path: String, depth: Int, expanded: Boolean, open: () -> Unit, mention: (String) -> Unit) {
    val directory = entry["type"].text == "directory"
    val enabled = entry["type"].text in listOf("file", "directory")
    Row(Modifier.fillMaxWidth().padding(start = minOf(depth * 14, 112).dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(enabled = enabled, onClick = open, modifier = Modifier.weight(1f)) {
            Text(if (directory) { if (expanded) "▾ " else "▸ " } else "▤ ")
            Column(Modifier.weight(1f)) {
                Text(entry["name"].string ?: path, Modifier.fillMaxWidth(), maxLines = 2, overflow = TextOverflow.Ellipsis)
                entry["size"].long?.let { Text(Usage.number(it) + L(" bytes", " 字节"), style = MaterialTheme.typography.labelSmall) }
            }
        }
        if (!directory && enabled) TextButton(enabled = Mentions.file(path, false, false) != null, onClick = { mention(path) }) { Text("@") }
    }
}

@Composable
private fun FilesLoading(text: String) { Row(verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(text) } }

@Composable
private fun WorkspaceFilePreview(store: WorkspacePreviewStore, mention: (String) -> Unit) {
    val state by store.state.collectAsState()
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    var image by remember(store) { mutableStateOf<ImageBitmap?>(null) }
    var error by remember(store) { mutableStateOf<String?>(null) }
    LaunchedEffect(store) { store.load() }
    LaunchedEffect(store, state.data) {
        image = null; error = null
        state.data?.let { bytes ->
            try { image = withContext(Dispatchers.IO) {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                var sample = 1
                while (bounds.outWidth / sample > 1536 || bounds.outHeight / sample > 1536) sample *= 2
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
                    ?: throw PortalError(L("This image format cannot be previewed. You can still share the file.", "无法预览此图片格式，仍可分享该文件。"))
            } } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
        }
    }
    SelectionContainer { Text(store.path, style = MaterialTheme.typography.bodySmall) }
    Row {
        TextButton(enabled = Mentions.file(store.path, false, false) != null, onClick = { mention(store.path) }) { Text(L("@ Mention", "@ 提及")) }
        if (state.kind == FilePreviewKind.TEXT) TextButton(enabled = state.loaded, onClick = { clipboard.setText(AnnotatedString(state.text)) }) { Text(L("Copy text", "复制文本")) }
        TextButton(enabled = !state.loading, onClick = { scope.launch {
            error = null
            try {
                val bytes = store.download() ?: return@launch
                val file = withContext(Dispatchers.IO) {
                    val dir = File(context.cacheDir, "exports/workspace").apply { mkdirs() }
                    File(dir, UUID.randomUUID().toString() + "-" + File(store.path).name.takeLast(100)).apply { writeBytes(bytes) }
                }
                ensureActive()
                val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
                    putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }, L("Share file", "分享文件")))
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
        } }) { Text(L("Share file", "分享文件")) }
    }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        (state.error ?: error)?.let { ErrorBanner(it) }
        if (state.loading) FilesLoading(L("Loading preview…", "正在加载预览…"))
        image?.let { Image(it, store.path, Modifier.fillMaxWidth().heightIn(max = 420.dp)) }
        if (state.kind == FilePreviewKind.TEXT && state.loaded) {
            if (state.text.isEmpty()) Text(L("Empty file", "空文件"))
            else SelectionContainer { Text(state.text, Modifier.horizontalScroll(rememberScrollState()), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
            if (state.truncated) Text(L("Preview limited to 1 MiB of text. Share the file for more.", "文本预览限制为 1 MiB，可分享文件查看更多内容。"))
            else if (!state.eof) TextButton(enabled = !state.loading, onClick = { scope.launch { store.load() } }) { Text(L("Load more lines", "加载更多行")) }
        }
        if (state.kind == FilePreviewKind.BINARY) Text(L("No text preview. Share a bounded download (up to 8 MiB).", "无文本预览。可下载并分享文件（最多 8 MiB）。"))
        if (state.error != null) TextButton(enabled = !state.loading, onClick = { scope.launch { store.load(true) } }) { Text(L("Reload file", "重新加载文件")) }
    }
}
