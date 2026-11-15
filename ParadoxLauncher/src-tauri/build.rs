use std::path::Path;

fn main() {
    println!("cargo:rerun-if-env-changed=MYSTICPARADOX_USERNAME_AUTH");
    println!("cargo:rerun-if-env-changed=MYSTICPARADOX_EMAIL_VERIFICATION");

    // Embed the self-host authentication policy in this launcher build.
    // The server's live configuration remains authoritative when available.
    if let (Ok(username_auth), Ok(email_verification)) = (
        std::env::var("MYSTICPARADOX_USERNAME_AUTH"),
        std::env::var("MYSTICPARADOX_EMAIL_VERIFICATION"),
    ) {
        println!("cargo:rustc-env=MYSTICPARADOX_USERNAME_AUTH={}", username_auth);
        println!("cargo:rustc-env=MYSTICPARADOX_EMAIL_VERIFICATION={}", email_verification);
    }
    // The optional P2P module is compiled in when its folder is present (src/p2p). Whether co-op is used is decided at
    // runtime (p2p/mod.rs); without the folder the launcher is dedicated-only. Guard's integrity measurements are
    // public code (launch/guard_checks.rs) and need no folder of their own.
    println!("cargo:rustc-check-cfg=cfg(mystic_p2p)");
    let p2p = Path::new("src/p2p/mod.rs").exists();
    // Watch the module when present, otherwise the source tree, so adding or removing it reruns this.
    println!(
        "cargo:rerun-if-changed={}",
        if p2p { "src/p2p" } else { "src" }
    );
    if p2p {
        println!("cargo:rustc-cfg=mystic_p2p");
    }
    tauri_build::build()
}
