package dev.vikiea.site_lens

import java.io.File
import java.nio.file.Files

/** Removes task bookkeeping after transport and file leases have stopped. */
internal object NativeDownloadCleanup {
    private val lockPattern = Regex("^\\.([A-Za-z0-9._-]{1,128})\\.lock$")

    fun reconcile(root: File, canRemoveLock: (String) -> Boolean) {
        val entries = root.listFiles() ?: return
        entries.forEach { entry ->
            val taskId = lockPattern.matchEntire(entry.name)?.groupValues?.get(1)
            if (taskId != null && taskId !in listOf(".", "..") &&
                entry.isFile && !Files.isSymbolicLink(entry.toPath()) && canRemoveLock(taskId)
            ) {
                entry.delete()
            }
            removeEmptyDirectory(entry)
        }
    }

    fun taskDeleted(root: File, taskId: String, seriesDirectory: String) {
        require(taskId.matches(Regex("[A-Za-z0-9._-]{1,128}")) && taskId !in listOf(".", ".."))
        File(root, ".$taskId.lock").delete()
        val directory = File(root, seriesDirectory)
        val canonicalRoot = root.canonicalFile
        if (directory.canonicalFile.parentFile == canonicalRoot) {
            removeEmptyDirectory(directory)
        }
    }

    private fun removeEmptyDirectory(directory: File) {
        if (!Files.isSymbolicLink(directory.toPath()) && directory.isDirectory &&
            directory.listFiles()?.isEmpty() == true
        ) {
            directory.delete()
        }
    }
}
