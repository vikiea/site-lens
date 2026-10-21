package dev.vikiea.site_lens

/** UI-thread-owned installation; request threads only read the committed state. */
internal class NativeFilterInstallation<State, Handle>(
    initial: State,
    private val remove: (Handle) -> Unit,
) {
    @Volatile var state: State = initial
        private set
    private var handle: Handle? = null

    fun replace(nextState: State, register: (State) -> Handle?) {
        // Nothing is committed or retired when provider registration throws.
        val nextHandle = register(nextState)
        val previous = handle
        state = nextState
        handle = nextHandle
        if (previous != null && previous !== nextHandle) {
            runCatching { remove(previous) }
        }
    }

    /** The WebView is already destroyed; do not call its provider again. */
    fun forget() { handle = null }
}
