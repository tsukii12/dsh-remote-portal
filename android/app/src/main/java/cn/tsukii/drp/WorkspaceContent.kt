package cn.tsukii.drp

object WorkspacePaths {
    fun visible(path: String): Boolean = path.replace('\\', '/').split('/').none { it == ".dsh" }
}

object ImageSignatures {
    fun detected(bytes: ByteArray): Boolean {
        fun at(offset: Int, vararg values: Int) = bytes.size >= offset + values.size && values.indices.all { bytes[offset + it].toInt() and 255 == values[it] }
        fun text(offset: Int, value: String) = at(offset, *value.map(Char::code).toIntArray())
        return at(0, 137, 80, 78, 71, 13, 10, 26, 10) || at(0, 255, 216, 255) ||
            text(0, "GIF87a") || text(0, "GIF89a") || text(0, "RIFF") && text(8, "WEBP") ||
            text(0, "BM") || at(0, 73, 73, 42, 0) || at(0, 77, 77, 0, 42) ||
            text(4, "ftyp") && listOf("heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis").any { text(8, it) }
    }
}
