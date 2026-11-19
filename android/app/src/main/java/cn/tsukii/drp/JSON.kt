package cn.tsukii.drp

import kotlinx.serialization.json.*
import java.util.Locale

typealias J = JsonElement
val EMPTY: J = JsonObject(emptyMap())
operator fun J.get(key: String): J = (this as? JsonObject)?.get(key) ?: JsonNull
val J.obj: Map<String, J> get() = (this as? JsonObject) ?: emptyMap()
val J.array: List<J> get() = (this as? JsonArray)?.toList() ?: emptyList()
val J.string: String? get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
val J.text: String get() = string ?: ""
val J.int: Int? get() = (this as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
val J.long: Long? get() = (this as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull
val J.boolean: Boolean get() = this == JsonPrimitive(true)
fun J.with(key: String, value: Any?): J = JsonObject(obj + (key to j(value)))
fun j(value: Any?): J = when (value) {
    null -> JsonNull
    is J -> value
    is String -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { it.key.toString() to j(it.value) })
    is Iterable<*> -> JsonArray(value.map(::j))
    else -> error("Unsupported JSON value")
}
fun o(vararg pairs: Pair<String, Any?>): J = j(mapOf(*pairs))
fun parse(text: String): J = Json.parseToJsonElement(text)
fun L(en: String, zh: String, languages: List<String> = listOf(Locale.getDefault().toLanguageTag())): String =
    if (languages.firstOrNull()?.startsWith("zh") == true) zh else en

sealed class APIError(message: String) : Exception(message) {
    data object SessionExpired : APIError(L("Please sign in again.", "请重新登录。"))
    data object InvalidResponse : APIError(L("Invalid server response.", "服务器响应无效。"))
    data object Disconnected : APIError(L("Connection closed.", "连接已关闭。"))
    data class Http(val status: Int) : APIError(L("Server request failed (HTTP $status).", "服务器请求失败（HTTP $status）。"))
    data class Remote(val code: String, val detail: String) : APIError(detail)
}
class PortalError(message: String) : Exception(message)
