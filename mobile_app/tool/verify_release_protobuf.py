"""Check actual release DEX fields needed for MediaPipe's reflective startup.

Run after a minified release build. Mapping resolves the class name; actual
class declarations in the APK prove the field survived. R8 mapping alone may
omit unchanged fields. This does not replace physical-device verification.
"""

from __future__ import annotations

import argparse
import re
import struct
import zipfile
from pathlib import Path

MESSAGE = "com.google.mediapipe.proto.MediaPipeLoggingProto$SystemInfo"
LOGGER = "com.google.common.flogger.FluentLogger"


def read_uleb(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 35, 7):
        item = data[offset]
        offset += 1
        value |= (item & 127) << shift
        if not item & 128:
            return value, offset
    raise ValueError("Invalid DEX integer")


def declared_fields(
    data: bytes, descriptor: str, *, methods: bool = False
) -> set[str] | None:
    if not data.startswith(b"dex\n"):
        raise ValueError("Expected standard Android DEX")
    string_count, string_offset = struct.unpack_from("<II", data, 56)
    strings = []
    for index in range(string_count):
        start = struct.unpack_from("<I", data, string_offset + 4 * index)[0]
        _, start = read_uleb(data, start)
        strings.append(
            data[start : data.index(b"\0", start)].decode("utf-8", "replace")
        )
    type_count, type_offset = struct.unpack_from("<II", data, 64)
    types = [
        strings[struct.unpack_from("<I", data, type_offset + 4 * index)[0]]
        for index in range(type_count)
    ]
    if descriptor not in types:
        return None
    type_index = types.index(descriptor)
    _, proto_offset = struct.unpack_from("<II", data, 72)
    _, field_offset = struct.unpack_from("<II", data, 80)
    _, method_offset = struct.unpack_from("<II", data, 88)
    class_count, class_offset = struct.unpack_from("<II", data, 96)
    for index in range(class_count):
        entry = class_offset + index * 32
        if struct.unpack_from("<I", data, entry)[0] != type_index:
            continue
        offset = struct.unpack_from("<I", data, entry + 24)[0]
        if not offset:
            return set()
        sizes = []
        for _ in range(4):
            size, offset = read_uleb(data, offset)
            sizes.append(size)
        names = set()
        for count in sizes[:2]:
            field_index = 0
            for _ in range(count):
                delta, offset = read_uleb(data, offset)
                _, offset = read_uleb(data, offset)
                field_index += delta
                name_index = struct.unpack_from(
                    "<I", data, field_offset + field_index * 8 + 4
                )[0]
                names.add(strings[name_index])
                value_type = struct.unpack_from(
                    "<H", data, field_offset + field_index * 8 + 2
                )[0]
                names.add(strings[name_index] + ":" + types[value_type])
        if methods:
            names = set()
            for count in sizes[2:]:
                method_index = 0
                for _ in range(count):
                    delta, offset = read_uleb(data, offset)
                    _, offset = read_uleb(data, offset)
                    _, offset = read_uleb(data, offset)
                    method_index += delta
                    name_index = struct.unpack_from(
                        "<I", data, method_offset + method_index * 8 + 4
                    )[0]
                    names.add(strings[name_index])
                    proto_index = struct.unpack_from(
                        "<H", data, method_offset + method_index * 8 + 2
                    )[0]
                    _, result_type, params = struct.unpack_from(
                        "<III", data, proto_offset + proto_index * 12
                    )
                    arguments = []
                    if params:
                        length = struct.unpack_from("<I", data, params)[0]
                        arguments = [
                            types[
                                struct.unpack_from("<H", data, params + 4 + 2 * item)[0]
                            ]
                            for item in range(length)
                        ]
                    names.add(
                        strings[name_index]
                        + "("
                        + "".join(arguments)
                        + ")"
                        + types[result_type]
                    )
        return names
    return None


def verify_member(
    apk: Path,
    mapping: Path,
    original: str,
    member: str,
    *,
    methods: bool = False,
    jni_class: bool = False,
) -> None:
    name = original
    with mapping.open(encoding="utf-8") as source:
        for line in source:
            if line.startswith(original + " -> "):
                name = line.split(" -> ", 1)[1].strip().rstrip(":")
                break
    if jni_class and name != original:
        raise ValueError(f"JNI class {original} was renamed by R8")
    descriptor = "L" + name.replace(".", "/") + ";"
    with zipfile.ZipFile(apk) as archive:
        for entry in archive.namelist():
            if re.fullmatch(r"classes\d*\.dex", entry):
                fields = declared_fields(
                    archive.read(entry), descriptor, methods=methods
                )
                if fields is not None:
                    if member in fields:
                        return
                    break
    raise ValueError(
        f"Required dependency member {original}.{member} is absent from actual release DEX; "
        "the release can fail during camera startup or native inference."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    build = Path(__file__).resolve().parents[1] / "build/app/outputs"
    parser.add_argument(
        "--apk", type=Path, default=build / "flutter-apk/app-release.apk"
    )
    parser.add_argument(
        "--mapping", type=Path, default=build / "mapping/release/mapping.txt"
    )
    args = parser.parse_args()
    verify_member(args.apk, args.mapping, MESSAGE, "platform_")
    verify_member(args.apk, args.mapping, LOGGER, "forEnclosingClass", methods=True)
    verify_member(
        args.apk,
        args.mapping,
        "com.google.common.flogger.backend.system.StackBasedCallerFinder",
        "findLoggingClass",
        methods=True,
    )
    verify_member(
        args.apk,
        args.mapping,
        "com.google.common.flogger.util.CallerFinder",
        "findCallerOf",
        methods=True,
    )
    for original, member, is_method in [
        (
            "com.google.mediapipe.framework.ProtoUtil$SerializedMessage",
            "typeName:Ljava/lang/String;",
            False,
        ),
        (
            "com.google.mediapipe.framework.ProtoUtil$SerializedMessage",
            "value:[B",
            False,
        ),
        (
            "com.google.mediapipe.framework.Packet",
            "create(J)Lcom/google/mediapipe/framework/Packet;",
            True,
        ),
        ("com.google.mediapipe.framework.Packet", "getNativeHandle()J", True),
        ("com.google.mediapipe.framework.Packet", "release()V", True),
        (
            "com.google.mediapipe.framework.PacketCallback",
            "process(Lcom/google/mediapipe/framework/Packet;)V",
            True,
        ),
        (
            "com.google.mediapipe.framework.PacketListCallback",
            "process(Ljava/util/List;)V",
            True,
        ),
        ("com.google.mediapipe.framework.MediaPipeException", "<init>(I[B)V", True),
        (
            "com.google.mediapipe.framework.PacketCreator",
            "releaseWithSyncToken(JLcom/google/mediapipe/framework/TextureReleaseCallback;)V",
            True,
        ),
        ("ai.onnxruntime.TensorInfo", "<init>([J[Ljava/lang/String;I)V", True),
        ("ai.onnxruntime.OnnxTensor", "<init>(JJLai/onnxruntime/TensorInfo;)V", True),
        ("ai.onnxruntime.OrtException", "<init>(ILjava/lang/String;)V", True),
    ]:
        verify_member(
            args.apk, args.mapping, original, member, methods=is_method, jni_class=True
        )
    print(
        "PASS: actual release DEX preserves MediaPipe, Flogger and ONNX JNI contracts"
    )


if __name__ == "__main__":
    main()
