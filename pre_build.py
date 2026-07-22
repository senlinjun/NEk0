import subprocess, os, shutil, sys

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

def main():
    os.chdir("native")

    # Set up NDK env vars from ANDROID_NDK_HOME before cargo builds
    setup_ndk_env()

    # Build both Android targets in parallel
    process1 = subprocess.Popen("cargo build --release --target x86_64-linux-android", shell=True)
    process2 = subprocess.Popen("cargo build --release --target aarch64-linux-android", shell=True)
    process1.wait()
    process2.wait()

    os.chdir("..")
    shutil.copy("native/target/x86_64-linux-android/release/libtsclient.so",
                "android/app/src/main/jniLibs/x86_64/libtsclient.so")
    shutil.copy("native/target/aarch64-linux-android/release/libtsclient.so",
                "android/app/src/main/jniLibs/arm64-v8a/libtsclient.so")

if __name__ == "__main__":
    main()
