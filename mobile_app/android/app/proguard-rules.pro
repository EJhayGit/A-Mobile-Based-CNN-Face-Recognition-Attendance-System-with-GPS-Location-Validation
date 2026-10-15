# Protobuf Lite reflects over generated message fields during MediaPipe startup.
# R8 otherwise removes/renames fields such as SystemInfo.platform_, preventing
# the liveness task from initializing before the camera opens.
# Official rule: https://github.com/protocolbuffers/protobuf/blob/main/java/lite.md
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }

# MediaPipe Graph creates this logger using stack-based caller discovery.
# Factory and caller-discovery helpers use fixed stack-frame offsets; preserving
# only the factory is insufficient when R8 inlines those helpers.
-keep class com.google.common.flogger.** { *; }

# MediaPipe's native framework calls these Java members by literal name/signature.
# Upstream JNI contract (keep all blocks together):
# https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/java/com/google/mediapipe/framework/proguard.pgcfg
-keep public interface com.google.mediapipe.framework.* {
    public *;
}
-keep public class com.google.mediapipe.framework.Packet {
    public static *** create(***);
    public long getNativeHandle();
    public void release();
}
-keep public class com.google.mediapipe.framework.PacketCreator {
    *** releaseWithSyncToken(...);
}
-keep public class com.google.mediapipe.framework.MediaPipeException {
    <init>(int, byte[]);
}
-keep class com.google.mediapipe.framework.ProtoUtil$SerializedMessage { *; }

# ONNX Runtime's JNI code constructs Java tensor metadata/results by name.
# https://onnxruntime.ai/docs/build/android.html#note-proguard-rules-for-r8-minimization-android-app-builds-to-work
-keep class ai.onnxruntime.** { *; }
