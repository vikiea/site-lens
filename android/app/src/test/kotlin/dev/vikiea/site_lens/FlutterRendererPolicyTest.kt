package dev.vikiea.site_lens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FlutterRendererPolicyTest {
    @Test fun deviceIdentityDoesNotForceASkiaDowngrade() {
        assertFalse(FlutterRendererPolicy.shouldDisableImpeller(false))
    }

    @Test fun explicitCompatibilityBuildCanRequestSkia() {
        assertTrue(FlutterRendererPolicy.shouldDisableImpeller(true))
    }

    @Test fun compatibilityBuildRemovesConflictingImpellerArguments() {
        val args = FlutterRendererPolicy.shellArgs(
            arrayOf("--enable-impeller=true", "--route=/home"),
            true,
        ).toArray().toSet()
        assertFalse(args.contains("--enable-impeller=true"))
        assertTrue(args.contains("--enable-impeller=false"))
        assertTrue(args.contains("--route=/home"))
    }

    @Test fun defaultBuildPreservesTheEngineRendererChoice() {
        val args = FlutterRendererPolicy.shellArgs(
            arrayOf("--enable-impeller=true", "--route=/home"),
            false,
        ).toArray().toSet()
        assertTrue(args.contains("--enable-impeller=true"))
        assertFalse(args.contains("--enable-impeller=false"))
        assertTrue(args.contains("--route=/home"))
    }
}
