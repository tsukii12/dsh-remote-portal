package cn.tsukii.drp

import android.content.Context
import android.graphics.Canvas
import android.graphics.Typeface
import android.util.TypedValue
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.termux.terminal.*
import com.termux.view.TerminalRenderer
import kotlinx.coroutines.launch

data class TerminalViewport(val cols: Int, val rows: Int) {
    companion object {
        fun measured(width: Int, height: Int, fontWidth: Float, lineSpacing: Int): TerminalViewport? {
            if (width <= 0 || height <= 0 || !fontWidth.isFinite() || fontWidth <= 0 || lineSpacing <= 0) return null
            return TerminalViewport((width / fontWidth).toInt().coerceIn(2, 500), (height / lineSpacing - 1).coerceIn(1, 200))
        }
    }
}

class TerminalEngine(private val send: (String, Boolean) -> Unit) {
    private val client = object : TerminalSessionClient {
        override fun onTextChanged(session: TerminalSession?) {}
        override fun onTitleChanged(session: TerminalSession?) {}
        override fun onSessionFinished(session: TerminalSession?) {}
        override fun onCopyTextToClipboard(session: TerminalSession?, text: String?) {}
        override fun onPasteTextFromClipboard(session: TerminalSession?) {}
        override fun onBell(session: TerminalSession?) {}
        override fun onColorsChanged(session: TerminalSession?) {}
        override fun onTerminalCursorStateChange(state: Boolean) {}
        override fun getTerminalCursorStyle(): Int = 0
        override fun logError(tag: String?, message: String?) {}
        override fun logWarn(tag: String?, message: String?) {}
        override fun logInfo(tag: String?, message: String?) {}
        override fun logDebug(tag: String?, message: String?) {}
        override fun logVerbose(tag: String?, message: String?) {}
        override fun logStackTraceWithMessage(tag: String?, message: String?, error: Exception?) {}
        override fun logStackTrace(tag: String?, error: Exception?) {}
    }
    private var pasting = false
    private val output = object : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) { send(String(data, offset, count, Charsets.UTF_8), pasting) }
        override fun titleChanged(oldTitle: String?, newTitle: String?) {}
        override fun onCopyTextToClipboard(text: String?) {}
        override fun onPasteTextFromClipboard() {}
        override fun onBell() {}
        override fun onColorsChanged() {}
    }
    var emulator = TerminalEmulator(output, 80, 24, 1000, client); private set
    var changed: () -> Unit = {}
    fun apply(frame: J, scrollback: Int = 1000) {
        when (frame["type"].text) {
            "snapshot" -> {
                emulator = TerminalEmulator(output, frame["info"]["cols"].int!!, frame["info"]["rows"].int!!, scrollback.coerceIn(100, 50000), client)
                append(frame["screen"].text)
            }
            "output" -> append(frame["data"].text)
            "state" -> {
                val cols = frame["info"]["cols"].int; val rows = frame["info"]["rows"].int
                if (cols != null && rows != null && cols in 2..500 && rows in 1..200) emulator.resize(cols, rows)
            }
        }
        changed()
    }
    private fun append(text: String) { val bytes = text.toByteArray(Charsets.UTF_8); emulator.append(bytes, bytes.size) }
    fun fit(viewport: TerminalViewport) {
        if (emulator.mColumns != viewport.cols || emulator.mRows != viewport.rows) emulator.resize(viewport.cols, viewport.rows)
    }
    fun key(code: Int, ctrl: Boolean = false): String? = KeyHandler.getCode(code, if (ctrl) KeyHandler.KEYMOD_CTRL else 0, emulator.isCursorKeysApplicationMode, emulator.isKeypadApplicationMode)
    fun paste(text: String) { pasting = true; try { emulator.paste(text) } finally { pasting = false } }
    fun text(): String = emulator.screen.transcriptText
}

class NativeTerminalView(context: Context, private val engine: TerminalEngine, private val resize: (Int, Int) -> Unit,
    private val send: (String) -> Unit) : View(context) {
    private val renderer = TerminalRenderer(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 14f, resources.displayMetrics).toInt(), Typeface.MONOSPACE)
    private var top = 0
    private var touchY = 0f
    init { isFocusableInTouchMode = true; setBackgroundColor(android.graphics.Color.BLACK) }
    fun refresh() {
        TerminalViewport.measured(width, height, renderer.fontWidth, renderer.fontLineSpacing)?.let { viewport ->
            engine.fit(viewport)
            resize(viewport.cols, viewport.rows)
        }
        top = top.coerceIn(-engine.emulator.screen.activeTranscriptRows, 0)
        invalidate()
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        refresh()
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (width <= 0 || height <= 0) return
        val saved = canvas.save()
        try { canvas.clipRect(0, 0, width, height); renderer.render(engine.emulator, canvas, top, -1, -1, -1, -1) }
        finally { canvas.restoreToCount(saved) }
    }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.action) {
            MotionEvent.ACTION_DOWN -> { touchY = event.y; requestFocus(); parent.requestDisallowInterceptTouchEvent(true) }
            MotionEvent.ACTION_MOVE -> {
                val lines = ((touchY - event.y) / renderer.fontLineSpacing).toInt()
                if (lines != 0) { top = (top + lines).coerceIn(-engine.emulator.screen.activeTranscriptRows, 0); touchY = event.y; invalidate() }
            }
            MotionEvent.ACTION_UP -> performClick()
        }
        return true
    }
    override fun performClick(): Boolean { super.performClick(); return true }
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        engine.key(keyCode, event.isCtrlPressed)?.let { send(it); return true }
        if (event.unicodeChar > 0) {
            val char = event.unicodeChar
            send(if (event.isCtrlPressed && char in 64..127) (char and 31).toChar().toString() else String(Character.toChars(char)))
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}

@Composable
fun TerminalScreen(api: PortalAPI, sessionID: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val preferences = remember { context.getSharedPreferences("terminals", Context.MODE_PRIVATE) }
    val savedKey = remember(api, sessionID) { api.base.toString() + ":" + sessionID }
    var selected by rememberSaveable(savedKey) { mutableStateOf(preferences.getString(savedKey, null)) }
    fun select(id: String?) { selected = id; preferences.edit().putString(savedKey, id).apply() }
    val inventory = remember(api, sessionID) { TerminalInventory(api, sessionID, scope, preferences.getString(savedKey + ":allocation", null)) { preferences.edit().putString(savedKey + ":allocation", it).commit() } }
    val state by inventory.state.collectAsState()
    var renaming by remember { mutableStateOf(false) }
    var closing by remember { mutableStateOf(false) }
    var title by remember { mutableStateOf("") }
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(inventory) { focus.clearFocus(); keyboard?.hide(); inventory.start() }
    DisposableEffect(inventory) { onDispose { inventory.stop() } }
    BackHandler(onBack = onDismiss)
    Surface(Modifier.fillMaxSize()) { BoxWithConstraints(Modifier.fillMaxSize().padding(8.dp)) {
        val compact = maxWidth > maxHeight
        val headerHeight = maxHeight * 0.4f
        val info = state.entries.firstOrNull { it["id"].text == selected }
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Column(Modifier.fillMaxWidth().heightIn(max = headerHeight).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth()) {
            TextButton(onClick = onDismiss) { Text(L("Back", "返回")) }
            Text(L("Terminal", "终端"), Modifier.weight(1f).padding(top = 12.dp), style = MaterialTheme.typography.titleLarge)
            TextButton(enabled = !state.busy, onClick = { scope.launch { inventory.create()?.let(::select) } }) { Text(L("New", "新建")) }
            TextButton(onClick = { inventory.stop(); inventory.start() }) { Text(L("Refresh", "刷新")) }
        }
        Text(L("Shells use your host account's permissions, not agent approvals. Leaving this screen keeps them running.", "终端以主机账户权限运行，不受智能体审批限制。离开此页面不会结束进程。"), style = MaterialTheme.typography.bodySmall)
        state.error?.let { ErrorBanner(it) }
        if (!state.loaded) LinearProgressIndicator(Modifier.fillMaxWidth())
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically) {
                state.entries.forEach { info -> FilterChip(selected == info["id"].text, onClick = { select(info["id"].text) }, label = { Text(info["title"].text.ifBlank { info["shell"]["name"].text }) }) }
                if (compact && info != null) Text(info["cwd"].text, Modifier.padding(start = 8.dp), maxLines = 1, style = MaterialTheme.typography.bodySmall)
            }
            if (compact && info != null) {
                TextButton(enabled = !state.busy, onClick = { title = info["title"].text; renaming = true }) { Text(L("Rename", "重命名")) }
                TextButton(enabled = !state.busy, onClick = { closing = true }) { Text(L("Close", "结束")) }
            }
        }
        if (info != null && !compact) {
            Row {
                Text(info["cwd"].text, Modifier.weight(1f), maxLines = 1, style = MaterialTheme.typography.bodySmall)
                TextButton(enabled = !state.busy, onClick = { title = info["title"].text; renaming = true }) { Text(L("Rename", "重命名")) }
                TextButton(enabled = !state.busy, onClick = { closing = true }) { Text(L("Close", "结束")) }
            }
        }
        }
        if (info != null) key(info["id"].text) { TerminalPane(api, sessionID, info, Modifier.weight(1f), compact) }
        else if (state.loaded) Text(if (selected != null) L("Saved terminal unavailable. Select a listed terminal or explicitly create a new one.", "保存的终端不可用，请选择已有终端或手动新建。") else L("No terminal selected. Choose one or create a new shell.", "未选择终端，请选择已有终端或新建。"))
        }
        if (renaming && selected != null) AlertDialog(onDismissRequest = { renaming = false }, title = { Text(L("Rename terminal", "重命名终端")) },
            text = { OutlinedTextField(title, { title = it }, singleLine = true, label = { Text(L("Title", "标题")) }) },
            confirmButton = { TextButton(enabled = title.isNotBlank() && title.trim().length <= 120 && !state.busy, onClick = { val id = selected!!; scope.launch { if (inventory.rename(id, title)) renaming = false } }) { Text(L("Save", "保存")) } },
            dismissButton = { TextButton(onClick = { renaming = false }) { Text(L("Cancel", "取消")) } })
        if (closing && selected != null) AlertDialog(onDismissRequest = { closing = false }, title = { Text(L("Close terminal?", "结束终端？")) },
            text = { Text(L("This ends the shell and its processes on the host. Leaving the screen does not.", "这会结束主机上的终端及其进程。仅离开页面不会结束进程。")) },
            confirmButton = { TextButton(enabled = !state.busy, onClick = { val id = selected!!; scope.launch { if (inventory.close(id)) { select(null); closing = false } } }) { Text(L("Close terminal", "结束终端")) } },
            dismissButton = { TextButton(onClick = { closing = false }) { Text(L("Cancel", "取消")) } })
    } }
}

@Composable
private fun TerminalPane(api: PortalAPI, sessionID: String, info: J, modifier: Modifier, compact: Boolean) {
    val scope = rememberCoroutineScope()
    val store = remember { TerminalStore(api, sessionID, info, scope) { MuxTerminalChannel(api.mux.openDuplex("terminal/attach", o("agentId" to sessionID, "id" to info["id"]))) } }
    val state by store.state.collectAsState()
    val engine = remember { TerminalEngine { text, typed -> store.write(text, typed) } }
    var editor by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var control by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    fun send(key: String) {
        val committed = TerminalInput.returnText(editor, key)
        if (store.write(committed)) editor = TextFieldValue()
    }
    DisposableEffect(store) {
        store.render = { engine.apply(it, store.environment["scrollback"].int ?: 1000) }
        val lifecycle = (context as? LifecycleOwner)?.lifecycle
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) store.foreground(true)
            if (event == Lifecycle.Event.ON_STOP) store.foreground(false)
        }
        lifecycle?.addObserver(observer)
        if (lifecycle == null || lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) store.start() else store.foreground(false)
        onDispose { lifecycle?.removeObserver(observer); store.stop(); store.render = {}; engine.changed = {} }
    }
    Column(modifier.imePadding(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row {
            Text((if (!state.ready) L("Attaching…", "正在连接…") else if (state.writable) L("Writable", "可写") else L("Read-only", "只读")) + " · ${state.info["cols"].int}×${state.info["rows"].int} · " + L("ack ", "确认 ") + state.acknowledged + " · " + L("snapshot ", "快照 ") + state.snapshots,
                Modifier.weight(1f), style = MaterialTheme.typography.labelSmall)
            TextButton(onClick = { store.reconnect() }) { Text(L("Reconnect", "重新连接")) }
            TextButton(onClick = { clipboard.setText(AnnotatedString(engine.text())) }) { Text(L("Copy", "复制")) }
        }
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        state.notice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        AndroidView(factory = { ctx -> NativeTerminalView(ctx, engine, store::resize) { store.write(it) }.also { view -> engine.changed = { view.refresh() } } }, modifier = Modifier.fillMaxWidth().weight(1f).clipToBounds())
        val keys: @Composable (Modifier) -> Unit = { keyModifier -> Row(keyModifier.horizontalScroll(rememberScrollState())) {
            FilterChip(control, onClick = { if (!control && editor.text.isNotEmpty()) { store.write(editor.text); editor = TextFieldValue() }; control = !control }, label = { Text("Ctrl") })
            listOf("Esc" to "\u001b", "Tab" to "\t", "←" to "left", "↑" to "up", "↓" to "down", "→" to "right").forEach { (label, key) ->
                TextButton(enabled = state.writable, onClick = {
                    val code = when (key) { "left" -> KeyEvent.KEYCODE_DPAD_LEFT; "up" -> KeyEvent.KEYCODE_DPAD_UP; "down" -> KeyEvent.KEYCODE_DPAD_DOWN; "right" -> KeyEvent.KEYCODE_DPAD_RIGHT; else -> null }
                    send(if (code == null) key else engine.key(code, control) ?: ""); control = false
                }) { Text(label) }
            }
            TextButton(enabled = state.writable, onClick = { clipboard.getText()?.text?.let(engine::paste) }) { Text(L("Paste", "粘贴")) }
        } }
        val input: @Composable (Modifier) -> Unit = { inputModifier -> Row(inputModifier) {
            OutlinedTextField(editor, { value ->
                if (control && value.text.isNotEmpty()) { val code = value.text.last().uppercaseChar().code; if (code in 64..95) store.write((code and 31).toChar().toString()); control = false; editor = TextFieldValue() }
                else editor = value
            }, Modifier.weight(1f), enabled = state.writable, singleLine = true, label = { Text(L("Terminal input", "终端输入")) },
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Send), keyboardActions = KeyboardActions(onSend = { send("\r") }))
            TextButton(enabled = state.writable, onClick = { send("\r") }) { Text(L("Return", "回车")) }
        } }
        if (compact) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            keys(Modifier.weight(1f)); input(Modifier.weight(1f))
        } else { keys(Modifier.fillMaxWidth()); input(Modifier.fillMaxWidth()) }
    }
}

object TerminalInput {
    fun returnText(value: TextFieldValue, key: String = "\r"): String = value.copy(composition = null, selection = TextRange(value.text.length)).text + key
}
