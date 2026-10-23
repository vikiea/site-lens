package dev.vikiea.site_lens

import kotlin.math.roundToInt

/** Bounds decoded frames without stretching them or enlarging small images. */
internal object MediaThumbnailGeometry {
    data class Size(val width: Int, val height: Int)

    fun fit(width: Int, height: Int): Size {
        require(width > 0 && height > 0)
        val scale = minOf(1.0, 320.0 / width, 180.0 / height)
        return Size(
            (width * scale).roundToInt().coerceAtLeast(1),
            (height * scale).roundToInt().coerceAtLeast(1),
        )
    }
}
