package cn.tsukii.drp

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.util.Locale

sealed interface MarkdownBlock {
    data class Paragraph(val text: String) : MarkdownBlock
    data class Heading(val level: Int, val text: String) : MarkdownBlock
    data class ListItem(val bullet: String, val text: String) : MarkdownBlock
    data class Code(val language: String, val text: String) : MarkdownBlock
}
object MarkdownParser {
    data class Inline(val text: String, val style: String = "", val url: String? = null)
    fun inline(text: String): List<Inline> {
        val pattern = Regex("(`[^`]+`|\\*\\*[^*]+\\*\\*|__[^_]+__|\\*[^*]+\\*|_[^_]+_|\\[[^]\\n]+\\]\\(https?://[^)\\s]+\\))")
        val result = mutableListOf<Inline>()
        var offset = 0
        for (match in pattern.findAll(text)) {
            if (match.range.first > offset) result.add(Inline(text.substring(offset, match.range.first)))
            val value = match.value
            result.add(when {
                value.startsWith("`") -> Inline(value.drop(1).dropLast(1), "code")
                value.startsWith("**") || value.startsWith("__") -> Inline(value.drop(2).dropLast(2), "bold")
                value.startsWith("[") -> {
                    val end = value.indexOf("](")
                    if (end < 1 || end + 3 >= value.length) Inline(value)
                    else Inline(value.substring(1, end), url = value.substring(end + 2, value.length - 1))
                }
                else -> Inline(value.drop(1).dropLast(1), "italic")
            })
            offset = match.range.last + 1
        }
        if (offset < text.length) result.add(Inline(text.substring(offset)))
        return result
    }
    fun blocks(text: String): List<MarkdownBlock> {
        if (text.isEmpty()) return emptyList()
        val result = mutableListOf<MarkdownBlock>()
        val paragraph = mutableListOf<String>(); val code = mutableListOf<String>()
        var fence: Char? = null; var fenceLength = 0; var language = ""
        fun flush() { if (paragraph.isNotEmpty()) { result.add(MarkdownBlock.Paragraph(paragraph.joinToString("\n"))); paragraph.clear() } }
        for (line in text.split(Regex("\\r\\n|\\n|\\r"))) {
            val trimmed = line.trim()
            if (fence != null) {
                val count = trimmed.takeWhile { it == fence }.length
                if (count >= fenceLength && trimmed.drop(count).isBlank()) {
                    result.add(MarkdownBlock.Code(language, code.joinToString("\n"))); code.clear(); fence = null
                } else code.add(line)
                continue
            }
            val marker = trimmed.firstOrNull()
            if (marker == '`' || marker == '~') {
                val count = trimmed.takeWhile { it == marker }.length
                if (count >= 3) { flush(); fence = marker; fenceLength = count; language = trimmed.drop(count).trim(); continue }
            }
            if (trimmed.isEmpty()) { flush(); continue }
            val hashes = trimmed.takeWhile { it == '#' }.length
            if (hashes in 1..6 && trimmed.drop(hashes).startsWith(" ")) {
                flush(); result.add(MarkdownBlock.Heading(hashes, trimmed.drop(hashes + 1))); continue
            }
            if (listOf("- ", "* ", "+ ").any { trimmed.startsWith(it) }) {
                flush(); result.add(MarkdownBlock.ListItem("•", trimmed.drop(2))); continue
            }
            val digits = trimmed.takeWhile { it.isDigit() }
            if (digits.isNotEmpty() && trimmed.drop(digits.length).startsWith(". ")) {
                flush(); result.add(MarkdownBlock.ListItem("$digits.", trimmed.drop(digits.length + 2))); continue
            }
            paragraph.add(line)
        }
        if (fence != null) result.add(MarkdownBlock.Code(language, code.joinToString("\n")))
        flush(); return result
    }
}
object ToolPresentation {
    fun summary(arguments: String): String = runCatching {
        val value = parse(arguments)
        value["command"].string ?: value.obj.values.firstOrNull()?.let { it.string ?: it.toString() } ?: ""
    }.getOrDefault(arguments).lineSequence().firstOrNull().orEmpty()
    fun status(result: J?): String = when {
        result == null -> "running"
        result["message"]["isError"].boolean || result["error"] != j(null) -> "error"
        else -> "ok"
    }
    fun result(value: J): String = value["message"]["content"].array.mapNotNull { it["text"].string }.joinToString("\n")
        .ifEmpty { value["error"]["message"].string ?: L("Completed", "已完成") }
}
object InteractionPresentation {
    private fun sorted(value: J): J = when (value) {
        is JsonObject -> JsonObject(value.toSortedMap().mapValues { sorted(it.value) })
        is JsonArray -> JsonArray(value.map(::sorted))
        else -> value
    }
    fun input(request: J, records: List<J>): String? {
        val callID = request["callId"].string?.takeIf { it.isNotEmpty() } ?: return null
        val call = records.map { it["event"] }.lastOrNull { it["type"].text == "tool/call" && it["data"]["callId"].string == callID } ?: return null
        val arguments = call["data"]["arguments"].string ?: return null
        val value = runCatching { parse(arguments) }.getOrNull() ?: return arguments
        if (request["toolName"].text == "bash") value["command"].string?.let { return it }
        return sorted(value).toString()
    }
    fun reason(request: J, languages: List<String> = listOf(Locale.getDefault().toLanguageTag())): String {
        val locale = languages.firstOrNull()?.substringBefore('-') ?: "en"
        return request["displayReason"][locale].string ?: request["displayReason"]["en"].string ?: request["reason"].text
    }
}
class QuestionDraft {
    val selected = mutableMapOf<String, Set<String>>()
    val custom = mutableMapOf<String, String>()
    fun toggle(option: String, question: J) {
        val id = question["id"].text
        if (question["multiSelect"].boolean) {
            val old = selected[id].orEmpty(); selected[id] = if (option in old) old - option else old + option
        } else { selected[id] = setOf(option); custom[id] = "" }
    }
    fun setCustom(text: String, question: J) {
        val id = question["id"].text; custom[id] = text
        if (!question["multiSelect"].boolean && text.isNotEmpty()) selected[id] = emptySet()
    }
    fun answers(questions: List<J>): List<J> = questions.map { question ->
        val id = question["id"].text
        val labels = question["options"].array.map { it["label"].text }.filter { it in selected[id].orEmpty() }
        var answer = o("id" to id, "selected" to labels)
        val text = custom[id].orEmpty().trim()
        if (text.isNotEmpty() && question["intent"]["kind"].text != "approval") answer = answer.with("custom", text)
        answer
    }
    fun canSubmit(questions: List<J>): Boolean = questions.isNotEmpty() && answers(questions).all { it["selected"].array.isNotEmpty() || it["custom"].text.isNotEmpty() }
}
data class ApprovalInputState(val input: String? = null, val error: String? = null, val isLoading: Boolean = false) {
    val canAllow get() = !isLoading && input != null
}
class ApprovalInputLoader(private val api: RPCServing, private val item: PendingInteraction) {
    private val mutable = MutableStateFlow(ApprovalInputState())
    val state = mutable.asStateFlow()
    suspend fun load() {
        if (state.value.isLoading) return
        mutable.value = ApprovalInputState(isLoading = true)
        try {
            val page = api.rpc("session/events", o("request" to o("address" to o("kind" to "session", "sessionId" to item.agentID), "maxMessages" to 50)))
            val input = InteractionPresentation.input(item.request, page["records"].array)
            mutable.value = ApprovalInputState(input, if (input == null) L("Tool input is unavailable. Retry before allowing this operation.", "无法获取工具输入。请重试后再允许此操作。") else null)
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutable.value = ApprovalInputState(error = e.message) }
        finally { mutable.value = state.value.copy(isLoading = false) }
    }
}
