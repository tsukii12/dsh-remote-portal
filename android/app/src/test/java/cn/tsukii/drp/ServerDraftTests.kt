package cn.tsukii.drp

import org.junit.Assert.*
import org.junit.Test

class ServerDraftTests {
    @Test fun normalizesMultipleAddressesAndPreservesIdentity() {
        val original = Server(name = "Old", addresses = listOf(PortalURL.normalize("https://example.com")))
        val draft = serverDraft("Office", "http://192.168.1.2:8080\n\nhttps://relay.example/prefix?unused=yes", original)
        assertEquals(original.id, draft.server.id)
        assertEquals("Office", draft.server.name)
        assertEquals(listOf("http://192.168.1.2:8080/", "https://relay.example/prefix/"), draft.server.addresses.map { it.toString() })
        assertEquals("", draft.token)
    }
    @Test fun pairingRemovesTokenFromPersistedServerAndUsesHostForEmptyName() {
        val draft = serverDraft("", "https://relay.example/prefix/__portal/pair?t=pair-secret")
        assertEquals("pair-secret", draft.token)
        assertEquals("relay.example", draft.server.name)
        assertEquals("https://relay.example/prefix/", draft.server.addresses.single().toString())
        assertFalse(draft.server.toString().contains("pair-secret"))
    }
    @Test fun emptyAddressesAreRejected() {
        assertThrows(PortalError::class.java) { serverDraft("Office", " \n ") }
    }
    @Test fun invalidAddressIsRejected() {
        assertThrows(Exception::class.java) { serverDraft("Office", "ftp://example.com") }
    }
}
