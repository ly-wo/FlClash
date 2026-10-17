#!/usr/bin/env python3
"""Package the Android APKs, gomobile core archive, and checksums."""

import hashlib
import os
import pathlib
import sys
import tempfile
import zipfile

APK_SOURCES = {
    "app-armeabi-v7a-release.apk": "android-armeabi-v7a.apk",
    "app-arm64-v8a-release.apk": "android-arm64-v8a.apk",
    "app-x86_64-release.apk": "android-x86_64.apk",
}

ABI_LIBRARIES = {
    "android-armeabi-v7a.apk": ("armeabi-v7a", "lib/armeabi-v7a/libclash.so"),
    "android-arm64-v8a.apk": ("arm64-v8a", "lib/arm64-v8a/libclash.so"),
    "android-x86_64.apk": ("x86_64", "lib/x86_64/libclash.so"),
}


def artifact_version(workspace):
    ref = os.environ.get("GITHUB_REF", "")
    name = os.environ.get("GITHUB_REF_NAME", "")
    if ref.startswith("refs/tags/"):
        if not name.startswith("v") or "/" in name:
            raise SystemExit(f"unexpected release tag: {name}")
        return name[1:]
    pubspec = (workspace / "pubspec.yaml").read_text(encoding="utf-8")
    for line in pubspec.splitlines():
        if line.startswith("version:"):
            version = line.split(":", 1)[1].strip().split("+", 1)[0]
            if version and "/" not in version:
                return version
            raise SystemExit(f"unexpected pubspec version: {version}")
    raise SystemExit("pubspec version is missing")


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def assert_patched_classes(path):
    with zipfile.ZipFile(path) as jar:
        try:
            seq = jar.read("go/Seq.class")
        except KeyError as error:
            raise SystemExit("classes.jar is missing go/Seq.class") from error
    if b"gojni" in seq:
        raise SystemExit("classes.jar still loads libgojni.so")
    if b"clash" not in seq:
        raise SystemExit("classes.jar is missing the clash library name")


def package(workspace):
    version = artifact_version(workspace)
    apk_dir = workspace / "build" / "app" / "outputs" / "flutter-apk"
    gomobile = workspace / "build" / "core" / "gomobile"
    aar = gomobile / "core.aar"
    classes = gomobile / "classes.jar"
    for path in (aar, classes):
        if not path.is_file():
            raise SystemExit(f"missing gomobile output: {path}")
    assert_patched_classes(classes)

    dist = workspace / "dist"
    dist.mkdir(exist_ok=True)
    packaged = []
    for source_name, suffix in APK_SOURCES.items():
        source = apk_dir / source_name
        if not source.is_file():
            raise SystemExit(f"missing apk: {source}")
        target = dist / f"FlClash-{version}-{suffix}"
        target.write_bytes(source.read_bytes())
        packaged.append(target)

    with tempfile.TemporaryDirectory() as stage:
        root = pathlib.Path(stage) / "flclash-android-core"
        found = set()
        for apk in packaged:
            for suffix, (abi, library) in ABI_LIBRARIES.items():
                if not apk.name.endswith(suffix):
                    continue
                with zipfile.ZipFile(apk) as archive:
                    data = archive.read(library)
                if b"shanlian" not in data:
                    raise SystemExit(f"{abi} libclash.so is missing the shanlian marker")
                destination = root / "jniLibs" / abi
                destination.mkdir(parents=True, exist_ok=True)
                (destination / "libclash.so").write_bytes(data)
                found.add(abi)
        expected = {abi for abi, _library in ABI_LIBRARIES.values()}
        if found != expected:
            raise SystemExit(f"packaged ABIs {sorted(found)} != {sorted(expected)}")
        (root / "core.aar").write_bytes(aar.read_bytes())
        (root / "classes.jar").write_bytes(classes.read_bytes())
        archive_path = dist / f"flclash-android-core-{version}.zip"
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(root.parent).as_posix())
        packaged.append(archive_path)

    sums = dist / "SHA256SUMS"
    lines = [f"{sha256_file(path)}  {path.name}" for path in sorted(packaged, key=lambda item: item.name)]
    if len(lines) != 4:
        raise SystemExit(f"expected 4 checksum lines, got {len(lines)}")
    sums.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return version


def main():
    workspace = pathlib.Path(os.environ.get("GITHUB_WORKSPACE", ".")).resolve()
    version = package(workspace)
    print(f"packaged Android artifacts for {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
