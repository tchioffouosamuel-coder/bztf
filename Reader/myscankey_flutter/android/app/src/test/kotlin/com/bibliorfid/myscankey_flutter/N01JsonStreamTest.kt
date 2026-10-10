package com.bibliorfid.myscankey_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class N01JsonStreamTest {
    private val tag = """{"epc":"42434D0107EA000000010123","rssi":-48,"antid":1}"""
    private val gpi = """{"gpis":"0100000"}"""

    @Test
    fun retainsATagAtEveryPossiblePacketBoundary() {
        for (boundary in 1 until tag.length) {
            val stream = N01JsonStream()
            assertTrue(stream.accept(tag.substring(0, boundary)).isEmpty())
            assertEquals(listOf(tag), stream.accept(tag.substring(boundary)))
        }
    }

    @Test
    fun handlesSingleCharacterSerialReads() {
        val stream = N01JsonStream()
        assertEquals(listOf(tag, gpi), (tag + gpi).flatMap { stream.accept(it.toString()) })
    }

    @Test
    fun keepsAnIncompleteTrailingMessageAfterACompleteOne() {
        val stream = N01JsonStream()
        assertEquals(listOf(gpi), stream.accept(gpi + tag.take(30)))
        assertEquals(listOf(tag, gpi), stream.accept(tag.drop(30) + gpi))
    }

    @Test
    fun preservesNestedCommandResponsesContainingRssi() {
        val response = """{"RES":"AutoInvCfgGet:OK","rssi":1,"tag_filter":{"mask":"E280","match":false},"bank_data":{"bank":2}}"""
        val stream = N01JsonStream()
        assertEquals(listOf(response, tag), stream.accept(response + tag))
    }

    @Test
    fun ignoresBracesAndEscapedQuotesInStringsAcrossPackets() {
        val response = """{"RES":"ReaderIdGet:OK","readerid":"gate { \"x\" } \\"}"""
        for (boundary in 1 until response.length) {
            val stream = N01JsonStream()
            assertTrue(stream.accept(response.take(boundary)).isEmpty())
            assertEquals(listOf(response, tag), stream.accept(response.drop(boundary) + tag))
        }
    }

    @Test
    fun acceptsMinimalTagsWithoutOptionalSdkFields() {
        val minimalTag = """{"epc":"42434D0107EA000000010123"}"""
        assertEquals(listOf(minimalTag), N01JsonStream().accept(minimalTag))
    }

    @Test
    fun ignoresTransportWhitespaceAndNullPadding() {
        assertEquals(listOf(tag, gpi), N01JsonStream().accept("\u0000\r\n" + tag + "\r\n\u0000" + gpi))
    }
}
