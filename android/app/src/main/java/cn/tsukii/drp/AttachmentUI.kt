package cn.tsukii.drp

import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import java.util.Base64

@Composable
fun AttachmentPicker(draft: AttachmentDraft, enabled: Boolean) {
    val resolver = LocalContext.current.contentResolver
    val scope = rememberCoroutineScope()
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
            draft.add(source)
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { draft.add(UploadSource(L("Unavailable attachment", "附件不可用"), null, null) { throw java.io.IOException(e.message) }) }
    } } }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments(), ::picked)
    val images = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments(), ::picked)
    Row {
        TextButton(enabled = enabled, onClick = { files.launch(arrayOf("*/*")) }) { Text(L("+ File", "+ 文件")) }
        TextButton(enabled = enabled, onClick = { images.launch(arrayOf("image/*")) }) { Text(L("+ Image", "+ 图片")) }
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
                    if (item.error != null) TextButton(enabled = enabled, onClick = { draft.retry(item.id) }) { Text(L("Retry", "重试")) }
                    TextButton(enabled = enabled, onClick = { draft.remove(item.id) }) { Text(L("Remove", "移除")) }
                }
            }
        } }
    }
}

@Composable
fun AttachmentBlock(chat: ChatStore, block: TranscriptBlock, previewOnly: Boolean = false) {
    val reference = block.attachment
    Column(Modifier.widthIn(max = 300.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (!previewOnly) {
            Text(reference["name"].string ?: if (block.kind == "file") L("File", "文件") else L("Image", "图片"), style = MaterialTheme.typography.titleSmall)
            Text(Usage.number(reference["bytes"].long) + L(" bytes", " 字节"), style = MaterialTheme.typography.bodySmall)
        }
        if (block.kind == "image") {
            var image by remember(chat.sessionID, reference) { mutableStateOf<ImageBitmap?>(null) }
            var error by remember(chat.sessionID, reference) { mutableStateOf<String?>(null) }
            var retry by remember { mutableIntStateOf(0) }
            LaunchedEffect(chat, reference, retry) {
                error = null
                try {
                    if ((reference["bytes"].long ?: Long.MAX_VALUE) > 8 * 1024 * 1024) throw PortalError(L("Image is too large for an inline preview.", "图片过大，无法在消息中预览。"))
                    val result = chat.attachment(reference)
                    image = withContext(Dispatchers.IO) {
                        val bytes = Base64.getDecoder().decode(result["data"].text)
                        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                        var sample = 1
                        while (bounds.outWidth / sample > 1024 || bounds.outHeight / sample > 1024) sample *= 2
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap() ?: throw APIError.InvalidResponse
                    }
                } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message ?: L("Preview unavailable", "无法预览") }
            }
            image?.let { Image(it, reference["name"].string ?: L("Attached image", "附加图片"), Modifier.fillMaxWidth().heightIn(max = if (previewOnly) 72.dp else 240.dp)) }
                ?: if (error == null) LinearProgressIndicator() else TextButton(onClick = { retry++ }) { Text(L("Retry image preview", "重试图片预览")) }
            error?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
    }
}
