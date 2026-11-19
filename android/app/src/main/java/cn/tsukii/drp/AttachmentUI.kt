package cn.tsukii.drp

import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.PickVisualMediaRequest
import androidx.core.content.FileProvider
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import java.io.File

@Composable
fun AttachmentPicker(draft: AttachmentDraft, enabled: Boolean, imageError: String? = null) {
    val context = LocalContext.current
    val resolver = context.contentResolver
    val scope = rememberCoroutineScope()
    var cameraPath by rememberSaveable { mutableStateOf<String?>(null) }
    var preparingCamera by remember { mutableStateOf(false) }
    var pickerError by remember { mutableStateOf<String?>(null) }
    fun picked(uris: List<Uri>) { uris.forEach { uri -> scope.launch {
        try {
            val source = withContext(Dispatchers.IO) {
                var name = L("Attachment", "附件"); var size: Long? = null
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val n = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME); val s = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (n >= 0) name = cursor.getString(n) ?: name
                        if (s >= 0 && !cursor.isNull(s)) size = cursor.getLong(s).takeIf { it >= 0 }
                    }
                }
                UploadSource(name, resolver.getType(uri), size) { resolver.openInputStream(uri) ?: throw java.io.IOException(L("Cannot open attachment.", "无法打开附件。")) }
            }
            if (source.image && imageError != null) pickerError = imageError else draft.add(source)
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { draft.add(UploadSource(L("Unavailable attachment", "附件不可用"), null, null) { throw java.io.IOException(e.message) }) }
    } } }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments(), ::picked)
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(), ::picked)
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        val path = cameraPath
        cameraPath = null
        if (path != null) {
            val file = File(path)
            if (success) picked(listOf(FileProvider.getUriForFile(context, context.packageName + ".files", file)))
            else file.delete()
        }
    }
    Column {
    Row {
        TextButton(modifier = Modifier.heightIn(min = 48.dp), enabled = enabled, onClick = { files.launch(arrayOf("*/*")) }) { Text(L("+ File", "+ 文件")) }
        TextButton(modifier = Modifier.heightIn(min = 48.dp), enabled = enabled && imageError == null, onClick = {
            pickerError = null
            try { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
            catch (_: Exception) { pickerError = L("Photos are unavailable. Choose Files instead.", "照片选择器不可用，请选择文件。") }
        }) { Text(L("+ Photos", "+ 照片")) }
        TextButton(modifier = Modifier.heightIn(min = 48.dp), enabled = enabled && imageError == null && cameraPath == null && !preparingCamera, onClick = {
            pickerError = null; preparingCamera = true
            scope.launch {
                try {
                    val active = draft.items.value.map { it.source.name }.toSet()
                    val file = withContext(Dispatchers.IO) { CameraCaptures.create(context.cacheDir, active) }
                    cameraPath = file.path
                    camera.launch(FileProvider.getUriForFile(context, context.packageName + ".files", file))
                } catch (e: CancellationException) { throw e }
                catch (_: Exception) {
                    cameraPath?.let { File(it).delete() }; cameraPath = null
                    pickerError = L("Camera is unavailable. Choose Photos or Files instead.", "相机不可用，请选择照片或文件。")
                } finally { preparingCamera = false }
            }
        }) { Text(L("+ Camera", "+ 拍照")) }
    }
    pickerError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    imageError?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
fun AttachmentRail(chat: ChatStore, draft: AttachmentDraft, enabled: Boolean) {
    val items by draft.items.collectAsState()
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items.forEach { item -> OutlinedCard(Modifier.width(230.dp)) {
            Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(item.source.name, maxLines = 2, style = MaterialTheme.typography.labelLarge)
                Text(Usage.number(item.source.size) + L(" bytes", " 字节"), style = MaterialTheme.typography.labelSmall)
                if (item.receipt?.get("image")?.takeIf { it != j(null) } != null)
                    AttachmentBlock(chat, TranscriptBlock("image", attachment = item.reference), previewOnly = true)
                when {
                    item.error != null -> { Text(L("Upload failed", "上传失败"), color = MaterialTheme.colorScheme.error); ErrorBanner(item.error) }
                    item.receipt != null -> Text(L("Ready", "已就绪"), color = MaterialTheme.colorScheme.primary)
                    else -> {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                        Text(Usage.number(item.sent) + L(" bytes uploaded", " 字节已上传"), style = MaterialTheme.typography.labelSmall)
                    }
                }
                Row {
                    if (item.error != null) TextButton(modifier = Modifier.heightIn(min = 48.dp), enabled = enabled, onClick = { draft.retry(item.id) }) { Text(L("Retry", "重试")) }
                    TextButton(modifier = Modifier.heightIn(min = 48.dp), enabled = enabled, onClick = { draft.remove(item.id) }) { Text(L("Remove", "移除")) }
                }
            }
        } }
    }
}

@Composable
fun AttachmentBlock(chat: ChatStore, block: TranscriptBlock, previewOnly: Boolean = false) {
    val reference = block.attachment
    val viewport = LocalAttachmentViewport.current
    var bounds by remember { mutableStateOf(Rect.Zero) }
    val visible = viewport == null || AttachmentPreview.visible(bounds, viewport)
    Column(Modifier.widthIn(max = 300.dp).onGloballyPositioned { bounds = it.boundsInWindow() }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (!previewOnly) {
            Text(reference["name"].string ?: if (block.kind == "file") L("File", "文件") else L("Image", "图片"), style = MaterialTheme.typography.titleSmall)
            Text(Usage.number(reference["bytes"].long) + L(" bytes", " 字节"), style = MaterialTheme.typography.bodySmall)
        }
        if (block.kind == "image") {
            var image by remember(chat.sessionID, reference) { mutableStateOf<ImageBitmap?>(null) }
            var error by remember(chat.sessionID, reference) { mutableStateOf<String?>(null) }
            var retry by remember { mutableIntStateOf(0) }
            LaunchedEffect(chat, reference, retry, visible) {
                if (!visible) { image = null; return@LaunchedEffect }
                if (image != null || error != null) return@LaunchedEffect
                try {
                    AttachmentPreview.validateSize(reference["bytes"].long)
                    val result = chat.attachment(reference)
                    image = withContext(Dispatchers.IO) {
                        val bytes = AttachmentPreview.bytes(result)
                        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                        val sample = AttachmentPreview.sample(bounds.outWidth, bounds.outHeight)
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap() ?: throw APIError.InvalidResponse
                    }
                } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message ?: L("Preview unavailable", "无法预览") }
            }
            image?.let { Image(it, reference["name"].string ?: L("Attached image", "附加图片"), Modifier.fillMaxWidth().heightIn(max = if (previewOnly) 72.dp else 240.dp)) }
                ?: if (error == null) LinearProgressIndicator() else TextButton(modifier = Modifier.heightIn(min = 48.dp), onClick = { error = null; retry++ }) { Text(L("Retry image preview", "重试图片预览")) }
            error?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
    }
}
