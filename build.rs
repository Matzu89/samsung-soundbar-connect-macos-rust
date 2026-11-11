use std::env;
use std::path::PathBuf;

fn main() {
    cc::Build::new()
        .file("src/connect.m")
        .flag("-fno-objc-arc")
        .compile("soundbar_connect");

    for framework in [
        "Foundation",
        "CoreBluetooth",
        "IOBluetooth",
        "CoreAudio",
        "CoreFoundation",
        "AppKit",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    println!("cargo:rustc-link-lib=objc");

    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let plist = manifest.join("Info.plist");
    println!(
        "cargo:rustc-link-arg=-Wl,-sectcreate,__TEXT,__info_plist,{}",
        plist.display()
    );

    println!("cargo:rerun-if-changed=src/connect.m");
    println!("cargo:rerun-if-changed=Info.plist");
}
