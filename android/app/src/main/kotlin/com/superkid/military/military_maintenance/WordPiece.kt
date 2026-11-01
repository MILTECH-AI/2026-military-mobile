package com.superkid.military.military_maintenance

import java.io.File

/** Cased BERT BasicTokenizer + WordPiece, matching the provisioned tokenizer.json. */
class WordPiece(file: File) {
    private val vocab = file.readLines(Charsets.UTF_8).withIndex().associate { it.value to it.index }
    private val special = Regex("\\[CLS\\]|\\[SEP\\]|\\[PAD\\]|\\[MASK\\]|\\[UNK\\]")
    init { require(vocab.size == 119547 && vocab["[CLS]"] == 101 && vocab["[SEP]"] == 102) }
    private fun chinese(c: Int) = c in 0x4E00..0x9FFF || c in 0x3400..0x4DBF ||
        c in 0x20000..0x2A6DF || c in 0x2A700..0x2B73F || c in 0x2B740..0x2B81F ||
        c in 0x2B820..0x2CEAF || c in 0xF900..0xFAFF || c in 0x2F800..0x2FA1F
    private fun punctuation(c: Int): Boolean = c in 33..47 || c in 58..64 || c in 91..96 || c in 123..126 ||
        Character.getType(c) in listOf(Character.CONNECTOR_PUNCTUATION.toInt(), Character.DASH_PUNCTUATION.toInt(),
            Character.START_PUNCTUATION.toInt(), Character.END_PUNCTUATION.toInt(), Character.INITIAL_QUOTE_PUNCTUATION.toInt(),
            Character.FINAL_QUOTE_PUNCTUATION.toInt(), Character.OTHER_PUNCTUATION.toInt())
    private fun pieces(text: String): List<Int> {
        val basic = mutableListOf<String>()
        val word = StringBuilder()
        fun flush() { if (word.isNotEmpty()) { basic.add(word.toString()); word.setLength(0) } }
        for (c in text.codePoints().toArray()) {
            val type = Character.getType(c)
            when {
                c == 0 || c == 0xfffd -> Unit
                c == 9 || c == 10 || c == 13 || Character.isWhitespace(c) || type == Character.SPACE_SEPARATOR.toInt() -> flush()
                type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt() -> Unit
                chinese(c) || punctuation(c) -> { flush(); basic.add(String(Character.toChars(c))) }
                else -> word.appendCodePoint(c)
            }
        }
        flush()
        return basic.flatMap { token ->
            val chars = token.codePoints().toArray()
            if (chars.size > 100) listOf(100) else {
                val found = mutableListOf<Int>()
                var start = 0
                while (start < chars.size) {
                    var end = chars.size
                    var id: Int? = null
                    while (end > start) {
                        id = vocab[(if (start == 0) "" else "##") + String(chars, start, end - start)]
                        if (id != null) break
                        end--
                    }
                    if (id == null) { found.clear(); found.add(100); break }
                    found.add(id); start = end
                }
                found
            }
        }
    }
    fun encode(text: String): LongArray {
        require(text.length <= 16000)
        val ids = mutableListOf<Int>()
        var cursor = 0
        for (match in special.findAll(text)) {
            ids.addAll(pieces(text.substring(cursor, match.range.first)))
            ids.add(vocab.getValue(match.value)); cursor = match.range.last + 1
        }
        ids.addAll(pieces(text.substring(cursor)))
        return (listOf(101) + ids.take(126) + listOf(102)).map { it.toLong() }.toLongArray()
    }
}
