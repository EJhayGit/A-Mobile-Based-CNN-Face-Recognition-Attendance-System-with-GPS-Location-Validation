package com.example.offline_trucking_attendance

import kotlin.math.atan2

internal object LivenessSignalMath {
    fun requireIncreasingTimestamp(previous: Long, current: Long) {
        require(current > previous) {
            "Liveness timestamps must increase monotonically."
        }
    }

    fun yawDegrees(columnMajorMatrix: FloatArray?): Double? {
        if (columnMajorMatrix == null || columnMajorMatrix.size != 16) return null
        return Math.toDegrees(
            atan2(
                columnMajorMatrix[8].toDouble(),
                columnMajorMatrix[10].toDouble(),
            ),
        )
    }

    fun argb(red: Int, green: Int, blue: Int): Int {
        require(red in 0..255 && green in 0..255 && blue in 0..255)
        return (0xff shl 24) or (red shl 16) or (green shl 8) or blue
    }
}
