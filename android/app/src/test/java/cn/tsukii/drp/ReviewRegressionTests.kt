package cn.tsukii.drp

import org.junit.Assert.*
import org.junit.Test

class ReviewRegressionTests {
    @Test fun malformedLinksRemainTextAndValidLinksKeepTheirTargets() {
        listOf("", "[docs]https://example.com", "[docs](", "[](https://example.com)", "[docs](javascript:alert)").forEach {
            assertEquals(it, MarkdownParser.inline(it).joinToString("") { token -> token.text })
            assertTrue(MarkdownParser.inline(it).all { token -> token.url == null })
        }
        val tokens = MarkdownParser.inline("[docs](https://example.com)[other](http://example.org) **bold** `code` *italic*")
        assertEquals(listOf("https://example.com", "http://example.org"), tokens.mapNotNull { it.url })
        assertEquals("docsother bold code italic", tokens.joinToString("") { it.text })
        assertEquals(listOf("bold", "code", "italic"), tokens.map { it.style }.filter { it.isNotEmpty() })
    }
    @Test fun ungroupedSortUsesEpochMillisecondsAndUpdatesRecency() {
        fun row(id: String, time: J) = SessionRow(id, id, false, time, EMPTY)
        val rows = linkedMapOf("old" to row("old", j(1795115076073L)), "new" to row("new", j(1795115076074L)), "missing" to row("missing", j(null)))
        val state = SidebarState(sessions = rows)
        assertEquals(listOf("new", "old", "missing"), state.groups.last().sessions.map { it.id })
        rows["old"] = row("old", j(1795115076075L))
        assertEquals(listOf("old", "new", "missing"), state.groups.last().sessions.map { it.id })
        assertTrue(SidebarState().groups.last().sessions.isEmpty())
        assertNull(j("1795115076075").long)
    }
}
