package cn.tsukii.drp

import java.util.Locale

object ErrorPresentation {
    fun isModelConfiguration(message: String): Boolean {
        val text = message.lowercase(Locale.ROOT)
        return listOf("no api key", "missing api key", "missing_credential", "invalid_credential", "unknown_model", "no models available", "no model is configured", "provider route", "provider configuration", "context window").any { it in text }
    }

    fun headline(message: String, languages: List<String> = listOf(Locale.getDefault().toLanguageTag())): String =
        if ("does not support image" in message.lowercase(Locale.ROOT)) L("This model cannot read images. Choose an image-capable model or remove the image.", "此模型不支持图片。请选择支持图片的模型或移除图片。", languages)
        else if (isModelConfiguration(message)) L(
            "No model is set up on this computer. Add an API key on dsh's Models page.",
            "这台电脑上还没有可用的模型，请在 dsh 的模型页面添加 API Key。", languages)
        else L("Something went wrong. Please try again.", "操作未成功，请重试。", languages)

    fun catalogError(catalog: J): String? {
        if (catalog == EMPTY) return null
        val failures = catalog["failures"].array
        return when {
            failures.isNotEmpty() -> "Provider configuration failures: ${j(failures)}"
            catalog["groups"].array.isEmpty() -> "No models available. Model catalog: $catalog"
            else -> null
        }
    }
}
