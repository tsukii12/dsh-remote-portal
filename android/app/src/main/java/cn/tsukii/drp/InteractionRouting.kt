package cn.tsukii.drp

object InteractionRouting {
    fun sessionID(item: PendingInteraction, knownSessionIDs: Set<String>): String? =
        item.agentID.takeIf { it.isNotBlank() && it in knownSessionIDs }

    fun automatic(pending: List<PendingInteraction>, openSessionID: String?, deferred: Set<String>): PendingInteraction? =
        pending.firstOrNull { openSessionID != null && openSessionID.isNotBlank() && it.agentID == openSessionID && it.id !in deferred }

    fun forSession(pending: List<PendingInteraction>, sessionID: String): List<PendingInteraction> =
        pending.filter { sessionID.isNotBlank() && it.agentID == sessionID }

    fun label(pending: List<PendingInteraction>, languages: List<String> = listOf(java.util.Locale.getDefault().toLanguageTag())): String {
        val count = pending.size
        return if (pending.all { it.kind == "approval/request" })
            L("$count pending approval${if (count == 1) "" else "s"}", "$count 个待处理授权", languages)
        else if (pending.all { it.kind == "user-questions/request" })
            L("$count pending question${if (count == 1) "" else "s"}", "$count 个待回答问题", languages)
        else L("$count pending request${if (count == 1) "" else "s"}", "$count 个待处理请求", languages)
    }
}
