package com.example.offline_trucking_attendance

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class LivenessSignalMathTest {
    @Test
    fun columnMajorMatrixProducesSignedYaw() {
        val radians = Math.toRadians(30.0)
        val matrix = floatArrayOf(
            cos(radians).toFloat(), 0f, -sin(radians).toFloat(), 0f,
            0f, 1f, 0f, 0f,
            sin(radians).toFloat(), 0f, cos(radians).toFloat(), 0f,
            0f, 0f, 0f, 1f,
        )
        assertEquals(30.0, LivenessSignalMath.yawDegrees(matrix)!!, 1e-5)
        assertNull(LivenessSignalMath.yawDegrees(floatArrayOf(1f)))
    }

    @Test
    fun timestampsMustIncreaseStrictly() {
        LivenessSignalMath.requireIncreasingTimestamp(10, 11)
        assertThrows(IllegalArgumentException::class.java) {
            LivenessSignalMath.requireIncreasingTimestamp(10, 10)
        }
    }

    @Test
    fun bgrConversionTargetIsOpaqueArgb() {
        assertEquals(0xff030201.toInt(), LivenessSignalMath.argb(3, 2, 1))
    }
}
