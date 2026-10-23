package dev.vikiea.site_lens

internal class MediaMoveRollbackFailure(val target: String, cause: Exception) : Exception(cause)

/** The newly published target stays recoverable if both deletes fail. */
internal fun completeMediaMove(target: String, deleteSource: () -> Unit, rollbackTarget: () -> Unit) {
    try {
        deleteSource()
    } catch (sourceError: Exception) {
        try {
            rollbackTarget()
        } catch (_: Exception) {
            throw MediaMoveRollbackFailure(target, sourceError)
        }
        throw sourceError
    }
}
