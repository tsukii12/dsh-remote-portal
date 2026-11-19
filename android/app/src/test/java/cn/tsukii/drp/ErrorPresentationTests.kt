package cn.tsukii.drp

import org.junit.Assert.*
import org.junit.Test

class ErrorPresentationTests {
    @Test fun classifiesProviderErrorsAndLocalizesWithoutExposingDetails() {
        listOf("llm-deepseek: no API key for provider route deepseek-official", "MISSING_CREDENTIAL", "UNKNOWN_MODEL", "Provider configuration failures: timeout").forEach {
            assertTrue(ErrorPresentation.isModelConfiguration(it))
            assertEquals("No model is set up on this computer. Add an API key on dsh's Models page.", ErrorPresentation.headline(it, listOf("en")))
            assertEquals("这台电脑上还没有可用的模型，请在 dsh 的模型页面添加 API Key。", ErrorPresentation.headline(it, listOf("zh-CN")))
        }
    }
    @Test fun unknownAndEmptyErrorsHaveShortGenericHeadline() {
        listOf("", "Network reset", "HTTP 500").forEach {
            assertFalse(ErrorPresentation.isModelConfiguration(it))
            assertEquals("Something went wrong. Please try again.", ErrorPresentation.headline(it, listOf("en")))
        }
    }
    @Test fun catalogDistinguishesNotLoadedEmptyFailedAndUsable() {
        assertNull(ErrorPresentation.catalogError(EMPTY))
        assertTrue(ErrorPresentation.isModelConfiguration(ErrorPresentation.catalogError(o("groups" to emptyList<J>()))!!))
        val failed = ErrorPresentation.catalogError(o("groups" to listOf(o("id" to "valid")), "failures" to listOf(o("message" to "raw failure"))))!!
        assertTrue(ErrorPresentation.isModelConfiguration(failed))
        assertTrue(failed.contains("raw failure"))
        assertNull(ErrorPresentation.catalogError(o("groups" to listOf(o("id" to "valid")))))
    }
}
