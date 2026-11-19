package cn.tsukii.drp

import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.geometry.Rect
import java.util.Base64

val LocalAttachmentViewport = compositionLocalOf<Rect?> { null }

object AttachmentPreview {
    const val maximumBytes = 20 * 1024 * 1024
    const val thumbnailPixels = 640
    fun validateSize(bytes: Long?) {
        if (bytes != null && bytes < 0) throw APIError.InvalidResponse
        if (bytes != null && bytes > maximumBytes) throw PortalError(L("Image is too large to preview.", "图片过大，无法预览。"))
    }
    fun bytes(value: J): ByteArray {
        val encoded = value["data"].string ?: throw APIError.InvalidResponse
        if (encoded.length > (maximumBytes + 2) / 3 * 4) throw APIError.InvalidResponse
        val bytes = try { Base64.getDecoder().decode(encoded) } catch (_: IllegalArgumentException) { throw APIError.InvalidResponse }
        if (bytes.isEmpty() || bytes.size > maximumBytes) throw APIError.InvalidResponse
        return bytes
    }
    fun sample(width: Int, height: Int): Int {
        if (width <= 0 || height <= 0) throw APIError.InvalidResponse
        var sample = 1
        while (width / sample > thumbnailPixels || height / sample > thumbnailPixels) sample *= 2
        return sample
    }
    fun visible(bounds: Rect, viewport: Rect): Boolean = !bounds.isEmpty && !viewport.isEmpty && bounds.overlaps(viewport)
}

object ChatScrollFollowing {
    data class Layout(val count: Int, val height: Int, val lastIndex: Int?, val lastOffset: Int?, val lastSize: Int?,
        val following: Boolean, val loadingOlder: Boolean, val scrolling: Boolean, val canScrollForward: Boolean) {
        val shouldScroll get() = count > 0 && height > 0 && following && !loadingOlder && !scrolling && canScrollForward
    }
    fun update(following: Boolean, dragging: Boolean, atBottom: Boolean, loadingOlder: Boolean): Boolean = when {
        loadingOlder -> false
        dragging -> atBottom
        else -> following || atBottom
    }
}
