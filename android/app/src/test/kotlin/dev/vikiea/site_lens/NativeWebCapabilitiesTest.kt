package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Test

class NativeWebCapabilitiesTest {
    @Test
    fun mediaGateIsIndependentOfPrivilegedScriptsAndRequiresEveryMediaFeature() {
        for (mute in listOf(false, true)) {
            for (start in listOf(false, true)) {
                for (messages in listOf(false, true)) {
                    val facts = NativeWebCapabilityFacts(
                        provider = null,
                        hasWorld = false,
                        hasNavigation = false,
                        hasStart = start,
                        hasProfiles = false,
                        enhanced = false,
                        hasMuteAudio = mute,
                        hasDocumentStartScript = start,
                        hasWebMessageListener = messages,
                    )
                    assertEquals(mute && start && messages, facts.mediaControlSupported)
                }
            }
        }
    }
}
