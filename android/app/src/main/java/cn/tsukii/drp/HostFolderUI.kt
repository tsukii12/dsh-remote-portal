package cn.tsukii.drp

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HostFolderSheet(store: SidebarStore, onDismiss: () -> Unit) {
    var listing by remember { mutableStateOf(EMPTY) }
    var path by remember { mutableStateOf("") }
    var folderName by remember { mutableStateOf("") }
    var newFolder by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    fun perform(action: suspend () -> Unit) { scope.launch {
        busy = true; error = null
        try { action() } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message } finally { busy = false }
    } }
    fun browse(value: String) { perform { listing = store.folders(value); path = listing["path"].text } }
    LaunchedEffect(store) { browse("") }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f).imePadding().padding(20.dp)) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(L("Add workspace", "添加工作区"), style = MaterialTheme.typography.titleLarge)
            Text(L("Folders are on the dsh host, not this phone.", "文件夹位于 dsh 主机上，而非此手机。"), style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(path, { path = it }, label = { Text(L("Absolute host path", "主机绝对路径")) }, singleLine = true, modifier = Modifier.fillMaxWidth(), enabled = !busy,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
            Row {
                TextButton(onClick = { browse(path) }, enabled = !busy) { Text(L("Browse path", "浏览路径")) }
                TextButton(onClick = { browse("") }, enabled = !busy) { Text(L("Roots", "根目录")) }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            error?.let { ErrorBanner(it) { error = null }; Text(L("Older portal? Enter an explicit host path and use the folder.", "旧版门户可输入主机绝对路径，再使用此文件夹。"), style = MaterialTheme.typography.bodySmall) }
            listing["parent"].string?.let { parent -> TextButton(onClick = { browse(parent) }, enabled = !busy) { Text(L("↑ Parent folder", "↑ 上一级文件夹")) } }
            listing["roots"].array.forEach { root -> TextButton(onClick = { browse(root["path"].text) }, enabled = !busy) { Text(root["name"].text) } }
            Text(listing["path"].string ?: L("Host folders", "主机文件夹"), style = MaterialTheme.typography.titleSmall)
            listing["entries"].array.forEach { entry -> TextButton(onClick = { browse(entry["path"].text) }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("▸ " + entry["name"].text, Modifier.fillMaxWidth()) } }
            if (listing["entries"].array.isEmpty() && !busy && listing != EMPTY) Text(L("No subfolders", "没有子文件夹"))
            if (listing["truncated"].boolean) Text(L("Only some folders are shown. Enter a path to browse further.", "仅显示部分文件夹，请输入路径以继续浏览。"))
            TextButton(onClick = { newFolder = true }, enabled = !busy && listing["path"].string != null) { Text(L("New folder", "新建文件夹")) }
            }
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text(L("Cancel", "取消")) }
                Button(onClick = { perform { store.createWorkspace(path); onDismiss() } }, enabled = !busy && path.isNotBlank()) { Text(L("Use folder", "使用此文件夹")) }
            }
        }
    }
    if (newFolder) AlertDialog(onDismissRequest = { newFolder = false }, title = { Text(L("New host folder", "新建主机文件夹")) },
        text = { OutlinedTextField(folderName, { folderName = it }, label = { Text(L("Folder name", "文件夹名称")) }, singleLine = true) },
        confirmButton = { TextButton(enabled = folderName.isNotBlank(), onClick = {
            val name = folderName; folderName = ""; newFolder = false
            perform { val created = store.makeFolder(listing["path"].text, name); listing = store.folders(created["path"].text); path = listing["path"].text }
        }) { Text(L("Create", "创建")) } }, dismissButton = { TextButton(onClick = { newFolder = false }) { Text(L("Cancel", "取消")) } })
}
