"""Builds the Rust core (native/) for the requested target platforms and
copies the artifacts where each platform's build expects them.

Usage: python3 pre_build.py [android|linux|windows|host|all]

- android: x86_64 + aarch64 .so into android/app/src/main/jniLibs/ (needs
  ANDROID_NDK_HOME).
- linux:   host-target .so into native/prebuilt/linux/libtsclient.so
           (picked up by linux/CMakeLists.txt when bundling).
- windows: x86_64 MSVC tsclient.dll into native/prebuilt/windows/ (picked up
           by windows/CMakeLists.txt). Windows host only — cross-compiling
           to MSVC from Linux/macOS is not supported here.
- host:    the native platform's target (linux on Linux, windows on Windows).
- all:     every target buildable on this host.

Default with no argument: "android" when ANDROID_NDK_HOME is set, otherwise
"host" (matches the historical single-platform behavior).
"""

import subprocess, os, shutil, sys

REPO = os.path.dirname(os.path.abspath(__file__))


def detect_ndk_host():
    """Detect the NDK host tag from OS and architecture."""
    system = sys.platform
    if system == "win32":
        return "windows-x86_64"
    elif system == "darwin":
        return "darwin-x86_64"  # Apple Silicon can also run x86_64 binaries via Rosetta
    else:
        # linux
        import platform
        machine = platform.machine()
        if machine == "aarch64":
            return "linux-aarch64"
        return "linux-x86_64"


def setup_ndk_env():
    """Set CC/CXX/AR env vars from ANDROID_NDK_HOME for cc crate and Cargo."""
    ndk = os.environ.get("ANDROID_NDK_HOME")
    if not ndk:
        print("ERROR: ANDROID_NDK_HOME is not set. Set it before building.")
        print('  e.g.: $env:ANDROID_NDK_HOME = "D:/android/SDK/ndk/29.0.13599879"')
        sys.exit(1)

    host = detect_ndk_host()
    bin_dir = os.path.join(ndk, "toolchains", "llvm", "prebuilt", host, "bin")

    if not os.path.isdir(bin_dir):
        print(f"ERROR: NDK bin directory not found: {bin_dir}")
        print(f"  Check that ANDROID_NDK_HOME points to a valid NDK installation.")
        sys.exit(1)

    # Add NDK bin to PATH so cc crate can find compilers by name
    os.environ["PATH"] = f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"

    # Target → NDK compiler prefix
    targets = {
        "aarch64-linux-android":    "aarch64-linux-android",
        "x86_64-linux-android":     "x86_64-linux-android",
        "i686-linux-android":       "i686-linux-android",
        "armv7-linux-androideabi":  "armv7a-linux-androideabi",
    }

    api = 21  # minimum API level for 64-bit; guaranteed to exist

    for rust_target, ndk_prefix in targets.items():
        # .cmd extension required on Windows
        ext = ".cmd" if sys.platform == "win32" else ""
        clang = os.path.join(bin_dir, f"{ndk_prefix}{api}-clang{ext}")

        if not os.path.exists(clang):
            continue  # skip targets not in this NDK

        # Normalize target name for env var (replace - with _)
        prefix = rust_target.replace("-", "_")
        os.environ[f"CC_{prefix}"] = clang
        os.environ[f"CXX_{prefix}"] = clang  # NDK clang auto-detects C++ by extension
        os.environ[f"AR_{prefix}"] = os.path.join(bin_dir, f"llvm-ar{'.exe' if sys.platform == 'win32' else ''}")
        # Cargo linker — uppercase target with _ separators
        cargo_target = prefix.upper()
        os.environ[f"CARGO_TARGET_{cargo_target}_LINKER"] = clang

    print(f"NDK toolchain configured from: {ndk}")
    print(f"  Host: {host}")
    print(f"  Bin:  {bin_dir}")


def cargo_build(args):
    print(f"cargo build --release {' '.join(args)}")
    subprocess.run(["cargo", "build", "--release", *args], check=True)


def build_android():
    os.chdir(os.path.join(REPO, "native"))
    setup_ndk_env()
    # Build both Android targets in parallel
    process1 = subprocess.Popen("cargo build --release --target x86_64-linux-android", shell=True)
    process2 = subprocess.Popen("cargo build --release --target aarch64-linux-android", shell=True)
    process1.wait()
    process2.wait()
    for proc in (process1, process2):
        if proc.returncode != 0:
            sys.exit(proc.returncode)

    os.chdir(REPO)
    shutil.copy("native/target/x86_64-linux-android/release/libtsclient.so",
                "android/app/src/main/jniLibs/x86_64/libtsclient.so")
    shutil.copy("native/target/aarch64-linux-android/release/libtsclient.so",
                "android/app/src/main/jniLibs/arm64-v8a/libtsclient.so")
    print("Android .so files copied into jniLibs")


def build_linux():
    os.chdir(os.path.join(REPO, "native"))
    cargo_build([])
    os.chdir(REPO)
    out_dir = "native/prebuilt/linux"
    os.makedirs(out_dir, exist_ok=True)
    shutil.copy("native/target/release/libtsclient.so", f"{out_dir}/libtsclient.so")
    print(f"Linux .so copied into {out_dir}/")


def build_windows():
    if sys.platform != "win32":
        print("ERROR: windows target requires a Windows host (MSVC toolchain).")
        sys.exit(1)
    os.chdir(os.path.join(REPO, "native"))
    cargo_build(["--target", "x86_64-pc-windows-msvc"])
    os.chdir(REPO)
    out_dir = "native/prebuilt/windows"
    os.makedirs(out_dir, exist_ok=True)
    shutil.copy("native/target/x86_64-pc-windows-msvc/release/tsclient.dll",
                f"{out_dir}/tsclient.dll")
    print(f"Windows .dll copied into {out_dir}/")


def main():
    requested = sys.argv[1].lower() if len(sys.argv) > 1 else None
    if requested is None:
        requested = "android" if os.environ.get("ANDROID_NDK_HOME") else "host"

    is_linux = sys.platform.startswith("linux")
    is_windows = sys.platform == "win32"

    if requested == "android":
        build_android()
    elif requested == "linux":
        build_linux()
    elif requested == "windows":
        build_windows()
    elif requested == "host":
        if is_linux:
            build_linux()
        elif is_windows:
            build_windows()
        else:
            print(f"ERROR: unsupported host platform: {sys.platform}")
            sys.exit(1)
    elif requested == "all":
        if is_linux:
            build_linux()
        elif is_windows:
            build_windows()
        else:
            print(f"ERROR: unsupported host platform: {sys.platform}")
            sys.exit(1)
        if os.environ.get("ANDROID_NDK_HOME"):
            build_android()
    else:
        print(f"ERROR: unknown platform '{requested}' "
              "(expected android|linux|windows|host|all)")
        sys.exit(1)


if __name__ == "__main__":
    main()
