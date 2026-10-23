package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Test

class MediaThumbnailGeometryTest {
    @Test fun landscapeRetainsWidescreenRatio() {
        assertEquals(MediaThumbnailGeometry.Size(320, 180), MediaThumbnailGeometry.fit(1920, 1080))
    }

    @Test fun nonWidescreenFrameDoesNotStretchToSixteenByNine() {
        assertEquals(MediaThumbnailGeometry.Size(300, 180), MediaThumbnailGeometry.fit(1920, 1152))
        assertEquals(MediaThumbnailGeometry.Size(160, 96), MediaThumbnailGeometry.fit(160, 96))
    }

    @Test fun portraitUsesHeightLimit() {
        assertEquals(MediaThumbnailGeometry.Size(101, 180), MediaThumbnailGeometry.fit(1080, 1920))
    }

    @Test fun squareRemainsSquare() {
        assertEquals(MediaThumbnailGeometry.Size(180, 180), MediaThumbnailGeometry.fit(2048, 2048))
    }

    @Test fun panoramaKeepsItsShortEdge() {
        assertEquals(MediaThumbnailGeometry.Size(320, 16), MediaThumbnailGeometry.fit(4000, 200))
    }

    @Test fun smallImagesAreNotEnlarged() {
        assertEquals(MediaThumbnailGeometry.Size(80, 120), MediaThumbnailGeometry.fit(80, 120))
    }

    @Test fun extremeRatiosStillHaveNonzeroPixels() {
        assertEquals(MediaThumbnailGeometry.Size(1, 180), MediaThumbnailGeometry.fit(1, Int.MAX_VALUE))
        assertEquals(MediaThumbnailGeometry.Size(320, 1), MediaThumbnailGeometry.fit(Int.MAX_VALUE, 1))
    }

    @Test(expected = IllegalArgumentException::class)
    fun emptyFrameIsRejected() { MediaThumbnailGeometry.fit(0, 180) }
}
