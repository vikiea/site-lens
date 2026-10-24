package dev.vikiea.site_lens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FlutterRendererPolicyTest {
    @Test fun android15KeepsDefaultRendererSelection() {
        assertFalse(FlutterRendererPolicy.shouldDisableImpeller(35, "QTI", "qcom"))
    }

    @Test fun android16UsesTheVulkanTeardownGuard() {
        assertTrue(FlutterRendererPolicy.shouldDisableImpeller(36, "QTI", "qcom"))
    }

    @Test fun android16OtherGpuKeepsDefaultRendererSelection() {
        assertFalse(FlutterRendererPolicy.shouldDisableImpeller(36, "MediaTek", "mt6895"))
    }

    @Test fun guardRemovesConflictingImpellerArguments() {
        val args = FlutterRendererPolicy.shellArgs(
            arrayOf("--enable-impeller=true", "--route=/home"),
            36,
            "QTI",
            "qcom",
        ).toArray().toSet()
        assertFalse(args.contains("--enable-impeller=true"))
        assertTrue(args.contains("--enable-impeller=false"))
        assertTrue(args.contains("--route=/home"))
    }
}
