package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeFilterInjectionTest {
    @Test
    fun payloadKeepsFrameDomainRulesAndDefersExceptionsToTheFrameRuntime() {
        assertEquals(4 * 1024 * 1024, MAX_FILTER_INJECTION_BYTES)
        val rules = buildList {
            repeat(128) { index ->
                add(NativeFilterRule(pattern = ".unrelated$index", cosmetic = true, domains = listOf("other.example")))
            }
            add(NativeFilterRule(pattern = ".current", cosmetic = true, domains = listOf("example.com")))
            add(NativeFilterRule(pattern = ".iframe", cosmetic = true, domains = listOf("frame.example")))
            add(NativeFilterRule(pattern = ".global", cosmetic = true))
            add(NativeFilterRule(pattern = ".exception", cosmetic = true, domains = listOf("example.com"), exception = true, block = false))
        }

        val selected = selectFilterInjectionRules(rules)

        assertTrue(selected.cosmetic.any { it.pattern == ".current" })
        assertTrue(selected.cosmetic.any { it.pattern == ".iframe" })
        assertTrue(selected.cosmetic.any { it.pattern == ".exception" })
        assertEquals(132, selected.cosmetic.size)
    }

    @Test
    fun scriptletsForAllFramesReachTheRuntimeBeforeItsBudget() {
        val rules = buildList {
            repeat(32) { index ->
                add(NativeFilterRule(pattern = "*", scriptlet = "set-constant", domains = listOf("other.example"), scriptletArgs = listOf("x$index")))
            }
            add(NativeFilterRule(pattern = "example.com", scriptlet = "set-constant", domains = listOf("example.com"), scriptletArgs = listOf("current")))
        }

        val selected = selectFilterInjectionRules(rules)

        assertEquals(33, selected.scriptlets.size)
        assertEquals("current", selected.scriptlets.last().scriptletArgs.single())
    }
}
