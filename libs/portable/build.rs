fn main() {
    #[cfg(windows)]
    {
        use std::io::Write;
        // This crate's own version is the packer tool's, not the product's, so
        // take the version Explorer shows from the workspace root instead. That
        // keeps a release bump to the version files we already bump.
        println!("cargo:rerun-if-changed=../../Cargo.toml");
        let version = workspace_version();
        let version_number = version_as_number(&version);
        let mut res = winres::WindowsResource::new();
        res.set_icon("../../res/icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("../../res/manifest.xml")
            .set("FileVersion", &version)
            .set("ProductVersion", &version)
            .set_version_info(winres::VersionInfo::FILEVERSION, version_number)
            .set_version_info(winres::VersionInfo::PRODUCTVERSION, version_number);
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}

/// `version` from the `[package]` section of the workspace root manifest.
#[cfg(windows)]
fn workspace_version() -> String {
    let manifest = std::fs::read_to_string("../../Cargo.toml")
        .expect("failed to read the workspace root Cargo.toml");
    let mut in_package = false;
    for line in manifest.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_package = line == "[package]";
        } else if in_package {
            if let Some(rest) = line.strip_prefix("version") {
                if let Some(value) = rest.trim_start().strip_prefix('=') {
                    if let Some(version) = value.split('"').nth(1) {
                        return version.to_owned();
                    }
                }
            }
        }
    }
    panic!("no [package] version in the workspace root Cargo.toml");
}

/// winres packs the four parts of a version into one u64, 16 bits each.
#[cfg(windows)]
fn version_as_number(version: &str) -> u64 {
    let mut parts = version.split('.').map(|p| p.parse::<u64>().unwrap_or(0));
    let major = parts.next().unwrap_or(0);
    let minor = parts.next().unwrap_or(0);
    let patch = parts.next().unwrap_or(0);
    (major << 48) | (minor << 32) | (patch << 16)
}
