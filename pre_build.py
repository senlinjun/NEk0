import subprocess,os,shutil
os.chdir("native")
process1 = subprocess.Popen("cargo build --release --target x86_64-linux-android",shell=True)
process2 = subprocess.Popen("cargo build --release --target aarch64-linux-android",shell=True)
process1.wait()
process2.wait()
os.chdir("..")
shutil.copy("native/target/x86_64-linux-android/release/libtsclient.so","android/app/src/main/jniLibs/x86_64/libtsclient.so")
shutil.copy("native/target/aarch64-linux-android/release/libtsclient.so","android/app/src/main/jniLibs/arm64-v8a/libtsclient.so")