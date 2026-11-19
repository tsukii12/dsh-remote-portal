package cn.tsukii.drp

import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class ConnectionTests {
    @Test fun normalizationKeepsPrefix() {
        assertEquals("https://relay.example/__t/abc/", PortalURL.normalize(" https://relay.example/__t/abc?x=1 ").toString())
        assertEquals("http://192.168.1.5:3081/", PortalURL.normalize("http://192.168.1.5:3081").toString())
        listOf("", "file:///etc/passwd", "https://user:pass@host/", "https://@host/").forEach { fails<PortalError> { PortalURL.normalize(it) } }
    }
    @Test fun pairing() {
        val pair = PortalURL.pairing("https://relay.example/__t/id/__portal/pair?t=a%2Bb")!!
        assertEquals("https://relay.example/__t/id/", pair.first.toString()); assertEquals("a+b", pair.second)
        assertNull(PortalURL.pairing("https://host/")); fails<PortalError> { PortalURL.pairing("https://host/__portal/pair?t=") }
        assertEquals("password=a%2Bb%20%26%E4%B8%AD", PortalURL.form(mapOf("password" to "a+b &中")))
        assertEquals("", PortalURL.form(emptyMap()))
    }
    @Test fun raceSkipsFailureAndPicksFastestOK() = runTest {
        val urls = listOf("http://fail/", "http://slow/", "http://fast/").map { it.toHttpUrl() }
        val result = PortalClient.race(urls) {
            if (it.host == "fail") throw java.io.IOException()
            delay(if (it.host == "fast") 10 else 500); if (it.host == "fast") 10 else 500
        }
        assertEquals("fast", result.base.host); assertEquals(10, result.milliseconds)
    }
    @Test fun emptyAndFailedRace() = runTest {
        for (urls in listOf(emptyList(), listOf("http://fail/".toHttpUrl()))) {
            val error = fails<PortalError> { PortalClient.race(urls) { throw java.io.IOException() } }
            assertFalse(error.message.isNullOrEmpty())
        }
    }
    @Test fun healthLabels() {
        listOf("localhost", "127.0.0.1", "10.1.2.3", "192.168.2.3", "172.16.1.2", "172.31.2.3", "host.local", "[::1]").forEach {
            assertTrue(HealthResult("http://$it/".toHttpUrl(), 4).label.startsWith("LAN · 4 ms"))
        }
        assertTrue(HealthResult("https://172.32.1.1/".toHttpUrl(), 1).label.startsWith(L("Public", "公网")))
    }
}
