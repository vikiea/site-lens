package dev.vikiea.site_lens

import org.junit.Assert.*
import org.junit.Test

class NativeFilterInstallationTest {
    @Test fun rejectedRegistrationPreservesPreviousStateAndHook() {
        val removed = mutableListOf<String>()
        val installation = NativeFilterInstallation<String, String>("empty") { removed.add(it) }
        installation.replace("old") { "old-hook" }

        assertThrows(IllegalStateException::class.java) {
            installation.replace("new") { throw IllegalStateException("provider rejected hook") }
        }
        assertEquals("old", installation.state)
        assertTrue(removed.isEmpty())

        installation.replace("new") { "new-hook" }
        assertEquals("new", installation.state)
        assertEquals(listOf("old-hook"), removed)
    }

    @Test fun registrationPrecedesCommitAndRetirementObservesCommittedState() {
        val events = mutableListOf<String>()
        lateinit var installation: NativeFilterInstallation<String, String>
        installation = NativeFilterInstallation("empty") {
            events.add("remove:$it:${installation.state}")
        }
        installation.replace("old") { "old-hook" }
        installation.replace("new") {
            events.add("register:${installation.state}")
            "new-hook"
        }
        assertEquals(listOf("register:old", "remove:old-hook:new"), events)
    }

    @Test fun disablingRemovesTheHookAndDeadProviderForgetNeverCallsRemove() {
        val removed = mutableListOf<String>()
        val installation = NativeFilterInstallation<String, String>("empty") { removed.add(it) }
        installation.replace("old") { "old-hook" }
        installation.replace("disabled") { null }
        assertEquals(listOf("old-hook"), removed)
        installation.replace("new") { "new-hook" }
        installation.forget()
        installation.replace("disabled") { null }
        assertEquals(listOf("old-hook"), removed)
    }
}
