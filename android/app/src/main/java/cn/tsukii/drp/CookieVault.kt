package cn.tsukii.drp

import okhttp3.Cookie
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.Response
import java.io.File
import java.security.MessageDigest
import java.nio.file.Files
import java.nio.file.StandardCopyOption

class CookieVault(private val root: File) {
    private val jars = mutableMapOf<String, List<Cookie>>()
    private fun file(base: HttpUrl) = File(root, MessageDigest.getInstance("SHA-256")
        .digest(base.toString().toByteArray()).joinToString("") { "%02x".format(it) } + ".json")
    private fun load(base: HttpUrl): List<Cookie> = jars.getOrPut(base.toString()) {
        val file = file(base)
        if (!file.exists()) emptyList() else parse(file.readText()).array.map { row ->
            Cookie.Builder().name(row["name"].text).value(row["value"].text).path(row["path"].text).apply {
                if (row["hostOnly"].boolean) hostOnlyDomain(row["domain"].text) else domain(row["domain"].text)
                row["expiresAt"].text.toLongOrNull()?.let { expiresAt(it) }
                if (row["secure"].boolean) secure()
                if (row["httpOnly"].boolean) httpOnly()
            }.build()
        }
    }
    @Synchronized fun cookies(base: HttpUrl, at: HttpUrl): List<Cookie> =
        load(base).filter { it.expiresAt > System.currentTimeMillis() && it.matches(at) }
    fun ingest(response: Response, base: HttpUrl) = ingest(base, response.request.url, response.headers)
    @Synchronized fun ingest(base: HttpUrl, at: HttpUrl, headers: Headers) {
        val incoming = headers.values("Set-Cookie").flatMap { header ->
            header.split(Regex(",(?=\\s*[^\\s=;,]+\\s*=)"))
                .mapNotNull { Cookie.parse(at, it.trim()) }
        }
        if (incoming.isEmpty()) return
        val jar = load(base).toMutableList()
        incoming.forEach { cookie ->
            jar.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
            if (cookie.expiresAt > System.currentTimeMillis()) jar.add(cookie)
        }
        root.mkdirs()
        val rows = j(jar.map { cookie -> o("name" to cookie.name, "value" to cookie.value, "domain" to cookie.domain,
            "path" to cookie.path, "hostOnly" to cookie.hostOnly, "secure" to cookie.secure,
            "httpOnly" to cookie.httpOnly, "expiresAt" to cookie.expiresAt.toString()) })
        val target = file(base)
        val temporary = File(root, target.name + ".tmp")
        temporary.writeText(rows.toString())
        Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        jars[base.toString()] = jar
    }
    @Synchronized fun clear(base: HttpUrl) {
        val file = file(base)
        if (file.exists() && !file.delete()) throw java.io.IOException("Cannot clear cookie jar")
        jars[base.toString()] = emptyList()
    }
}
