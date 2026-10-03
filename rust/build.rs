fn main() {
    // The oboe C++ objects linked through sas_engine need a C++ runtime for
    // __cxa_* symbols (pure_virtual, guard, exceptions). The APK does not ship
    // libc++_shared.so, so link the STL statically — the cdylib stays
    // self-contained. Passed as raw link-args: rustc-side -l resolution
    // can't see the NDK sysroot, but the NDK clang driver can.
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("android") {
        println!("cargo:rustc-link-arg-cdylib=-lc++_static");
        println!("cargo:rustc-link-arg-cdylib=-lc++abi");
    }
}
