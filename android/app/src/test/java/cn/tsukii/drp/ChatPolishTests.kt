package cn.tsukii.drp

import androidx.compose.ui.geometry.Rect
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class ChatPolishTests {
    @Test fun strippedUnknownAndNonListModalitiesAllowImagesButExplicitListsStillGate() {
        fun state(model: J) = ChatState(catalog = o("default" to o("provider" to "P", "model" to "M"), "groups" to listOf(o("id" to "P", "models" to listOf(model.with("id", j("M")))))))
        assertNull(state(EMPTY).imageInputError)
        for (value in listOf(j(null), j("unknown"), EMPTY, j(listOf("text", "image")))) assertNull(state(o("inputModalities" to value)).imageInputError)
        for (value in listOf(j(emptyList<String>()), j(listOf("text")))) assertNotNull(state(o("inputModalities" to value)).imageInputError)
    }
    @Test fun previewsAllowUnknownSizesAndBoundBothAdvertisedAndDecodedBytes() {
        AttachmentPreview.validateSize(null); AttachmentPreview.validateSize(0); AttachmentPreview.validateSize(AttachmentPreview.maximumBytes.toLong())
        fails<APIError.InvalidResponse> { AttachmentPreview.validateSize(-1) }
        fails<PortalError> { AttachmentPreview.validateSize(AttachmentPreview.maximumBytes + 1L) }
        assertArrayEquals(byteArrayOf(1, 2, 3), AttachmentPreview.bytes(o("data" to "AQID")))
        for (value in listOf(EMPTY, o("data" to ""), o("data" to "not base64!"))) fails<APIError.InvalidResponse> { AttachmentPreview.bytes(value) }
        val tooLarge = Base64.getEncoder().encodeToString(ByteArray(AttachmentPreview.maximumBytes + 1))
        fails<APIError.InvalidResponse> { AttachmentPreview.bytes(o("data" to tooLarge)) }
        fails<APIError.InvalidResponse> { AttachmentPreview.bytes(o("data" to (tooLarge + "AAAA"))) }
    }
    @Test fun thumbnailsStayWithin640PixelsAndInvalidDimensionsFail() {
        assertEquals(1, AttachmentPreview.sample(640, 480))
        assertEquals(2, AttachmentPreview.sample(1280, 640))
        assertEquals(4, AttachmentPreview.sample(640, 2560))
        for ((width, height) in listOf(641 to 20, 2048 to 4096, Int.MAX_VALUE to 1)) {
            val sample = AttachmentPreview.sample(width, height)
            assertTrue(width / sample <= 640 && height / sample <= 640)
        }
        fails<APIError.InvalidResponse> { AttachmentPreview.sample(0, 640) }
        fails<APIError.InvalidResponse> { AttachmentPreview.sample(640, -1) }
    }
    @Test fun imagesOnlyLoadWhenTheirBoundsIntersectTheTranscriptViewport() {
        val viewport = Rect(0f, 100f, 400f, 500f)
        assertTrue(AttachmentPreview.visible(Rect(20f, 110f, 300f, 200f), viewport))
        assertTrue(AttachmentPreview.visible(Rect(20f, 450f, 300f, 550f), viewport))
        assertFalse(AttachmentPreview.visible(Rect(20f, 500f, 300f, 600f), viewport))
        assertFalse(AttachmentPreview.visible(Rect(20f, 10f, 300f, 100f), viewport))
        assertFalse(AttachmentPreview.visible(Rect.Zero, viewport))
        assertFalse(AttachmentPreview.visible(viewport, Rect.Zero))
    }
    @Test fun streamingAndKeyboardLayoutDoNotDisableFollowingButUserScrollingAndOlderPagesDo() {
        assertTrue(ChatScrollFollowing.update(true, false, false, false))
        assertTrue(ChatScrollFollowing.update(true, false, true, false))
        assertFalse(ChatScrollFollowing.update(true, true, false, false))
        assertFalse(ChatScrollFollowing.update(false, false, false, false))
        assertTrue(ChatScrollFollowing.update(false, true, true, false))
        assertTrue(ChatScrollFollowing.update(false, false, true, false))
        assertFalse(ChatScrollFollowing.update(true, false, true, true))
    }
    @Test fun bottomFollowUsesStableGeometryAndDoesNotSpinInAZeroHeightKeyboardViewport() {
        val layout = ChatScrollFollowing.Layout(3, 400, 2, 350, 100, true, false, false, true)
        assertEquals(layout, layout.copy())
        assertTrue(layout.shouldScroll)
        assertFalse(layout.copy(height = 0).shouldScroll)
        assertFalse(layout.copy(count = 0).shouldScroll)
        assertFalse(layout.copy(following = false).shouldScroll)
        assertFalse(layout.copy(loadingOlder = true).shouldScroll)
        assertFalse(layout.copy(scrolling = true).shouldScroll)
        assertFalse(layout.copy(canScrollForward = false).shouldScroll)
        assertNotEquals(layout, layout.copy(lastSize = 200))
    }
}
