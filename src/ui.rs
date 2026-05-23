use std::{
    collections::HashMap,
    iter::FromIterator,
    sync::{Arc, Mutex},
};

use sciter::Value;

use hbb_common::{
    allow_err,
    config::{LocalConfig, PeerConfig},
    log,
};

#[cfg(not(any(feature = "flutter", feature = "cli")))]
use crate::ui_session_interface::Session;
use crate::{common::get_app_name, ipc, ui_interface::*};

mod cm;
#[cfg(feature = "inline")]
pub mod inline;
pub mod remote;

#[allow(dead_code)]
type Status = (i32, bool, i64, String);

lazy_static::lazy_static! {
    // stupid workaround for https://sciter.com/forums/topic/crash-on-latest-tis-mac-sdk-sometimes/
    static ref STUPID_VALUES: Mutex<Vec<Arc<Vec<Value>>>> = Default::default();
}

#[cfg(not(any(feature = "flutter", feature = "cli")))]
lazy_static::lazy_static! {
    pub static ref CUR_SESSION: Arc<Mutex<Option<Session<remote::SciterHandler>>>> = Default::default();
}

struct UIHostHandler;

pub fn start(args: &mut [String]) {
    #[cfg(target_os = "macos")]
    crate::platform::delegate::show_dock();
    #[cfg(all(target_os = "linux", feature = "inline"))]
    {
        let app_dir = std::env::var("APPDIR").unwrap_or("".to_string());
        let mut so_path = "/usr/share/rustdesk/libsciter-gtk.so".to_owned();
        for (prefix, dir) in [
            ("", "/usr"),
            ("", "/app"),
            (&app_dir, "/usr"),
            (&app_dir, "/app"),
        ]
        .iter()
        {
            let path = format!("{prefix}{dir}/share/rustdesk/libsciter-gtk.so");
            if std::path::Path::new(&path).exists() {
                so_path = path;
                break;
            }
        }
        sciter::set_library(&so_path).ok();
    }
    #[cfg(windows)]
    // Check if there is a sciter.dll nearby.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let sciter_dll_path = parent.join("sciter.dll");
            if sciter_dll_path.exists() {
                // Try to set the sciter dll.
                let p = sciter_dll_path.to_string_lossy().to_string();
                log::debug!("Found dll:{}, \n {:?}", p, sciter::set_library(&p));
            }
        }
    }
    // https://github.com/c-smile/sciter-sdk/blob/master/include/sciter-x-types.h
    // https://github.com/rustdesk/rustdesk/issues/132#issuecomment-886069737
    #[cfg(windows)]
    allow_err!(sciter::set_options(sciter::RuntimeOptions::GfxLayer(
        sciter::GFX_LAYER::WARP
    )));
    use sciter::SCRIPT_RUNTIME_FEATURES::*;
    allow_err!(sciter::set_options(sciter::RuntimeOptions::ScriptFeatures(
        ALLOW_FILE_IO as u8 | ALLOW_SOCKET_IO as u8 | ALLOW_EVAL as u8 | ALLOW_SYSINFO as u8
    )));
    let mut frame = sciter::WindowBuilder::main_window().create();
    #[cfg(windows)]
    allow_err!(sciter::set_options(sciter::RuntimeOptions::UxTheming(true)));
    frame.set_title(&crate::get_app_name());
    #[cfg(target_os = "macos")]
    crate::platform::delegate::make_menubar(frame.get_host(), args.is_empty());
    #[cfg(windows)]
    crate::platform::try_set_window_foreground(frame.get_hwnd() as _);
    let page;
    if args.len() > 1 && args[0] == "--play" {
        args[0] = "--connect".to_owned();
        let path: std::path::PathBuf = (&args[1]).into();
        let id = path
            .file_stem()
            .map(|p| p.to_str().unwrap_or(""))
            .unwrap_or("")
            .to_owned();
        args[1] = id;
    }
    if args.is_empty() {
        std::thread::spawn(move || check_zombie());
        crate::common::check_software_update();
        frame.event_handler(UI {});
        frame.sciter_handler(UIHostHandler {});
        page = "index.html";
        // Start pulse audio local server.
        #[cfg(target_os = "linux")]
        std::thread::spawn(crate::ipc::start_pa);
    } else if args[0] == "--install" {
        frame.event_handler(UI {});
        frame.sciter_handler(UIHostHandler {});
        page = "install.html";
    } else if args[0] == "--cm" {
        frame.register_behavior("connection-manager", move || {
            Box::new(cm::SciterConnectionManager::new())
        });
        page = "cm.html";
        *cm::HIDE_CM.lock().unwrap() = crate::ipc::get_config("hide_cm")
            .ok()
            .flatten()
            .unwrap_or_default()
            == "true";
    } else if (args[0] == "--connect"
        || args[0] == "--file-transfer"
        || args[0] == "--port-forward"
        || args[0] == "--rdp")
        && args.len() > 1
    {
        #[cfg(windows)]
        {
            let hw = frame.get_host().get_hwnd();
            crate::platform::windows::enable_lowlevel_keyboard(hw as _);
        }
        let mut iter = args.iter();
        let Some(cmd) = iter.next() else {
            log::error!("Failed to get cmd arg");
            return;
        };
        let cmd = cmd.to_owned();
        let Some(id) = iter.next() else {
            log::error!("Failed to get id arg");
            return;
        };
        let id = id.to_owned();
        let pass = iter.next().unwrap_or(&"".to_owned()).clone();
        let args: Vec<String> = iter.map(|x| x.clone()).collect();
        frame.set_title(&id);
        frame.register_behavior("native-remote", move || {
            let handler =
                remote::SciterSession::new(cmd.clone(), id.clone(), pass.clone(), args.clone());
            #[cfg(not(any(feature = "flutter", feature = "cli")))]
            {
                *CUR_SESSION.lock().unwrap() = Some(handler.inner());
            }
            Box::new(handler)
        });
        page = "remote.html";
    } else {
        log::error!("Wrong command: {:?}", args);
        return;
    }
    #[cfg(feature = "inline")]
    {
        let html = if page == "index.html" {
            inline::get_index()
        } else if page == "cm.html" {
            inline::get_cm()
        } else if page == "install.html" {
            inline::get_install()
        } else {
            inline::get_remote()
        };
        frame.load_html(html.as_bytes(), Some(page));
    }
    #[cfg(not(feature = "inline"))]
    frame.load_file(&format!(
        "file://{}/src/ui/{}",
        std::env::current_dir()
            .map(|c| c.display().to_string())
            .unwrap_or("".to_owned()),
        page
    ));
    let hide_cm = *cm::HIDE_CM.lock().unwrap();
    if !args.is_empty() && args[0] == "--cm" && hide_cm {
        // run_app calls expand(show) + run_loop, we use collapse(hide) + run_loop instead to create a hidden window
        frame.collapse(true);
        frame.run_loop();
        return;
    }
    frame.run_app();
}

struct UI {}

impl UI {
    fn recent_sessions_updated(&self) -> bool {
        recent_sessions_updated()
    }

    fn get_id(&self) -> String {
        ipc::get_id()
    }

    fn temporary_password(&mut self) -> String {
        temporary_password()
    }

    fn update_temporary_password(&self) {
        update_temporary_password()
    }

    fn set_permanent_password(&self, password: String) {
        let _ = set_permanent_password_with_result(password);
    }

    fn is_local_permanent_password_set(&self) -> bool {
        is_local_permanent_password_set()
    }

    fn is_permanent_password_set(&self) -> bool {
        is_permanent_password_set()
    }

    fn get_remote_id(&mut self) -> String {
        LocalConfig::get_remote_id()
    }

    fn set_remote_id(&mut self, id: String) {
        LocalConfig::set_remote_id(&id);
    }

    fn goto_install(&mut self) {
        goto_install();
    }

    fn install_me(&mut self, _options: String, _path: String) {
        install_me(_options, _path, false, false);
    }

    fn update_me(&self, _path: String) {
        update_me(_path);
    }

    fn run_without_install(&self) {
        run_without_install();
    }

    fn show_run_without_install(&self) -> bool {
        show_run_without_install()
    }

    fn get_license(&self) -> String {
        get_license()
    }

    fn get_option(&self, key: String) -> String {
        get_option(key)
    }

    fn get_local_option(&self, key: String) -> String {
        get_local_option(key)
    }

    fn set_local_option(&self, key: String, value: String) {
        set_local_option(key, value);
    }

    fn peer_has_password(&self, id: String) -> bool {
        peer_has_password(id)
    }

    fn forget_password(&self, id: String) {
        forget_password(id)
    }

    fn get_peer_option(&self, id: String, name: String) -> String {
        get_peer_option(id, name)
    }

    fn set_peer_option(&self, id: String, name: String, value: String) {
        set_peer_option(id, name, value)
    }

    fn using_public_server(&self) -> bool {
        crate::using_public_server()
    }

    fn is_incoming_only(&self) -> bool {
        hbb_common::config::is_incoming_only()
    }

    pub fn is_outgoing_only(&self) -> bool {
        hbb_common::config::is_outgoing_only()
    }

    pub fn is_custom_client(&self) -> bool {
        crate::common::is_custom_client()
    }

    pub fn is_disable_settings(&self) -> bool {
        hbb_common::config::is_disable_settings()
    }

    pub fn is_disable_account(&self) -> bool {
        hbb_common::config::is_disable_account()
    }

    pub fn is_disable_installation(&self) -> bool {
        hbb_common::config::is_disable_installation()
    }

    pub fn is_disable_ab(&self) -> bool {
        hbb_common::config::is_disable_ab()
    }

    fn get_options(&self) -> Value {
        let hashmap: HashMap<String, String> =
            serde_json::from_str(&get_options()).unwrap_or_default();
        let mut m = Value::map();
        for (k, v) in hashmap {
            m.set_item(k, v);
        }
        m
    }

    fn test_if_valid_server(&self, host: String, test_with_proxy: bool) -> String {
        test_if_valid_server(host, test_with_proxy)
    }

    fn get_sound_inputs(&self) -> Value {
        Value::from_iter(get_sound_inputs())
    }

    fn set_options(&self, v: Value) {
        let mut m = HashMap::new();
        for (k, v) in v.items() {
            if let Some(k) = k.as_string() {
                if let Some(v) = v.as_string() {
                    if !v.is_empty() {
                        m.insert(k, v);
                    }
                }
            }
        }
        set_options(m);
    }

    fn set_option(&self, key: String, value: String) {
        set_option(key, value);
    }

    fn install_path(&mut self) -> String {
        install_path()
    }

    fn install_options(&self) -> String {
        install_options()
    }

    fn get_socks(&self) -> Value {
        Value::from_iter(get_socks())
    }

    fn set_socks(&self, proxy: String, username: String, password: String) {
        set_socks(proxy, username, password)
    }

    fn is_installed(&self) -> bool {
        is_installed()
    }

    fn get_supported_privacy_mode_impls(&self) -> String {
        serde_json::to_string(&crate::privacy_mode::get_supported_privacy_mode_impl())
            .unwrap_or_default()
    }

    fn is_root(&self) -> bool {
        is_root()
    }

    fn is_release(&self) -> bool {
        #[cfg(not(debug_assertions))]
        return true;
        #[cfg(debug_assertions)]
        return false;
    }

    fn is_share_rdp(&self) -> bool {
        is_share_rdp()
    }

    fn set_share_rdp(&self, _enable: bool) {
        set_share_rdp(_enable);
    }

    fn is_installed_lower_version(&self) -> bool {
        is_installed_lower_version()
    }

    fn closing(&mut self, x: i32, y: i32, w: i32, h: i32) {
        crate::server::input_service::fix_key_down_timeout_at_exit();
        LocalConfig::set_size(x, y, w, h);
    }

    fn get_size(&mut self) -> Value {
        let s = LocalConfig::get_size();
        let mut v = Vec::new();
        v.push(s.0);
        v.push(s.1);
        v.push(s.2);
        v.push(s.3);
        Value::from_iter(v)
    }

    fn get_mouse_time(&self) -> f64 {
        get_mouse_time()
    }

    fn check_mouse_time(&self) {
        check_mouse_time()
    }

    fn get_connect_status(&mut self) -> Value {
        let mut v = Value::array(0);
        let x = get_connect_status();
        v.push(x.status_num);
        v.push(x.key_confirmed);
        v.push(x.id);
        v
    }

    #[inline]
    fn get_peer_value(id: String, p: PeerConfig) -> Value {
        let values = vec![
            id,
            p.info.username.clone(),
            p.info.hostname.clone(),
            p.info.platform.clone(),
            p.options.get("alias").unwrap_or(&"".to_owned()).to_owned(),
        ];
        Value::from_iter(values)
    }

    fn get_peer(&self, id: String) -> Value {
        let c = get_peer(id.clone());
        Self::get_peer_value(id, c)
    }

    fn get_fav(&self) -> Value {
        Value::from_iter(get_fav())
    }

    fn store_fav(&self, fav: Value) {
        let mut tmp = vec![];
        fav.values().for_each(|v| {
            if let Some(v) = v.as_string() {
                if !v.is_empty() {
                    tmp.push(v);
                }
            }
        });
        store_fav(tmp);
    }

    fn get_recent_sessions(&mut self) -> Value {
        // to-do: limit number of recent sessions, and remove old peer file
        let peers: Vec<Value> = PeerConfig::peers(None)
            .drain(..)
            .map(|p| Self::get_peer_value(p.0, p.2))
            .collect();
        Value::from_iter(peers)
    }

    fn get_icon(&mut self) -> String {
        get_icon()
    }

    fn remove_peer(&mut self, id: String) {
        PeerConfig::remove(&id);
    }

    fn remove_discovered(&mut self, id: String) {
        remove_discovered(id);
    }

    fn send_wol(&mut self, id: String) {
        crate::lan::send_wol(id)
    }

    fn new_remote(&mut self, id: String, remote_type: String, force_relay: bool) {
        new_remote(id, remote_type, force_relay)
    }

    fn is_process_trusted(&mut self, _prompt: bool) -> bool {
        is_process_trusted(_prompt)
    }

    fn is_can_screen_recording(&mut self, _prompt: bool) -> bool {
        is_can_screen_recording(_prompt)
    }

    fn is_installed_daemon(&mut self, _prompt: bool) -> bool {
        is_installed_daemon(_prompt)
    }

    fn get_error(&mut self) -> String {
        get_error()
    }

    fn is_login_wayland(&mut self) -> bool {
        is_login_wayland()
    }

    fn current_is_wayland(&mut self) -> bool {
        current_is_wayland()
    }

    fn get_software_update_url(&self) -> String {
        crate::SOFTWARE_UPDATE_URL.lock().unwrap().clone()
    }

    fn get_new_version(&self) -> String {
        get_new_version()
    }

    fn get_version(&self) -> String {
        get_version()
    }

    fn get_fingerprint(&self) -> String {
        get_fingerprint()
    }

    fn get_app_name(&self) -> String {
        get_app_name()
    }

    fn get_software_ext(&self) -> String {
        #[cfg(windows)]
        let p = "exe";
        #[cfg(target_os = "macos")]
        let p = "dmg";
        #[cfg(target_os = "linux")]
        let p = "deb";
        p.to_owned()
    }

    fn get_software_store_path(&self) -> String {
        let mut p = std::env::temp_dir();
        let name = crate::SOFTWARE_UPDATE_URL
            .lock()
            .unwrap()
            .split("/")
            .last()
            .map(|x| x.to_owned())
            .unwrap_or(crate::get_app_name());
        p.push(name);
        format!("{}.{}", p.to_string_lossy(), self.get_software_ext())
    }

    fn create_shortcut(&self, _id: String) {
        #[cfg(windows)]
        create_shortcut(_id)
    }

    fn discover(&self) {
        std::thread::spawn(move || {
            allow_err!(crate::lan::discover());
        });
    }

    fn get_lan_peers(&self) -> String {
        // let peers = get_lan_peers()
        //     .into_iter()
        //     .map(|mut peer| {
        //         (
        //             peer.remove("id").unwrap_or_default(),
        //             peer.remove("username").unwrap_or_default(),
        //             peer.remove("hostname").unwrap_or_default(),
        //             peer.remove("platform").unwrap_or_default(),
        //         )
        //     })
        //     .collect::<Vec<(String, String, String, String)>>();
        serde_json::to_string(&get_lan_peers()).unwrap_or_default()
    }

    fn get_uuid(&self) -> String {
        get_uuid()
    }

    fn open_url(&self, url: String) {
        #[cfg(windows)]
        let p = "explorer";
        #[cfg(target_os = "macos")]
        let p = "open";
        #[cfg(target_os = "linux")]
        let p = if std::path::Path::new("/usr/bin/firefox").exists() {
            "firefox"
        } else {
            "xdg-open"
        };
        allow_err!(std::process::Command::new(p).arg(url).spawn());
    }

    fn change_id(&self, id: String) {
        reset_async_job_status();
        let old_id = self.get_id();
        change_id_shared(id, old_id);
    }

    fn http_request(&self, url: String, method: String, body: Option<String>, header: String) {
        http_request(url, method, body, header)
    }

    fn post_request(&self, url: String, body: String, header: String) {
        post_request(url, body, header)
    }

    fn is_ok_change_id(&self) -> bool {
        hbb_common::machine_uid::get().is_ok()
    }

    fn get_async_job_status(&self) -> String {
        get_async_job_status()
    }

    fn get_http_status(&self, url: String) -> Option<String> {
        get_async_http_status(url)
    }

    fn t(&self, name: String) -> String {
        crate::client::translate(name)
    }

    fn is_xfce(&self) -> bool {
        crate::platform::is_xfce()
    }

    fn get_api_server(&self) -> String {
        get_api_server()
    }

    fn has_hwcodec(&self) -> bool {
        has_hwcodec()
    }

    fn has_vram(&self) -> bool {
        has_vram()
    }

    fn get_langs(&self) -> String {
        get_langs()
    }

    fn video_save_directory(&self, root: bool) -> String {
        video_save_directory(root)
    }

    fn handle_relay_id(&self, id: String) -> String {
        handle_relay_id(&id).to_owned()
    }

    fn get_login_device_info(&self) -> String {
        get_login_device_info_json()
    }

    fn support_remove_wallpaper(&self) -> bool {
        support_remove_wallpaper()
    }

    fn has_valid_2fa(&self) -> bool {
        has_valid_2fa()
    }

    fn generate2fa(&self) -> String {
        generate2fa()
    }

    pub fn verify2fa(&self, code: String) -> bool {
        verify2fa(code)
    }

    fn verify_login(&self, raw: String, id: String) -> bool {
        crate::verify_login(&raw, &id)
    }

    fn generate_2fa_img_src(&self, data: String) -> String {
        let v = qrcode_generator::to_png_to_vec(data, qrcode_generator::QrCodeEcc::Low, 128)
            .unwrap_or_default();
        let s = hbb_common::sodiumoxide::base64::encode(
            v,
            hbb_common::sodiumoxide::base64::Variant::Original,
        );
        format!("data:image/png;base64,{s}")
    }

    pub fn check_hwcodec(&self) {
        check_hwcodec()
    }

    fn is_option_fixed(&self, key: String) -> bool {
        crate::ui_interface::is_option_fixed(&key)
    }

    fn get_builtin_option(&self, key: String) -> String {
        crate::ui_interface::get_builtin_option(&key)
    }

    fn is_remote_modify_enabled_by_control_permissions(&self) -> String {
        match crate::ui_interface::is_remote_modify_enabled_by_control_permissions() {
            Some(true) => "true",
            Some(false) => "false",
            None => "",
        }
        .to_string()
    }
}

impl sciter::EventHandler for UI {
    sciter::dispatch_script_call! {
        fn t(String);
        fn get_api_server();
        fn is_xfce();
        fn using_public_server();
        fn is_custom_client();
        fn is_outgoing_only();
        fn is_incoming_only();
        fn is_disable_settings();
        fn is_disable_account();
        fn is_disable_installation();
        fn is_disable_ab();
        fn get_id();
        fn temporary_password();
        fn update_temporary_password();
        fn set_permanent_password(String);
        fn is_local_permanent_password_set();
        fn is_permanent_password_set();
        fn get_remote_id();
        fn set_remote_id(String);
        fn closing(i32, i32, i32, i32);
        fn get_size();
        fn new_remote(String, String, bool);
        fn send_wol(String);
        fn remove_peer(String);
        fn remove_discovered(String);
        fn get_connect_status();
        fn get_mouse_time();
        fn check_mouse_time();
        fn get_recent_sessions();
        fn get_peer(String);
        fn get_fav();
        fn store_fav(Value);
        fn recent_sessions_updated();
        fn get_icon();
        fn install_me(String, String);
        fn is_installed();
        fn get_supported_privacy_mode_impls();
        fn is_root();
        fn is_release();
        fn set_socks(String, String, String);
        fn get_socks();
        fn is_share_rdp();
        fn set_share_rdp(bool);
        fn is_installed_lower_version();
        fn install_path();
        fn install_options();
        fn goto_install();
        fn is_process_trusted(bool);
        fn is_can_screen_recording(bool);
        fn is_installed_daemon(bool);
        fn get_error();
        fn is_login_wayland();
        fn current_is_wayland();
        fn get_options();
        fn get_option(String);
        fn get_local_option(String);
        fn set_local_option(String, String);
        fn get_peer_option(String, String);
        fn peer_has_password(String);
        fn forget_password(String);
        fn set_peer_option(String, String, String);
        fn get_license();
        fn test_if_valid_server(String, bool);
        fn get_sound_inputs();
        fn set_options(Value);
        fn set_option(String, String);
        fn get_software_update_url();
        fn get_new_version();
        fn get_version();
        fn get_fingerprint();
        fn update_me(String);
        fn show_run_without_install();
        fn run_without_install();
        fn get_app_name();
        fn get_software_store_path();
        fn get_software_ext();
        fn open_url(String);
        fn change_id(String);
        fn get_async_job_status();
        fn post_request(String, String, String);
        fn is_ok_change_id();
        fn create_shortcut(String);
        fn discover();
        fn get_lan_peers();
        fn get_uuid();
        fn has_hwcodec();
        fn has_vram();
        fn get_langs();
        fn video_save_directory(bool);
        fn handle_relay_id(String);
        fn get_login_device_info();
        fn support_remove_wallpaper();
        fn has_valid_2fa();
        fn generate2fa();
        fn generate_2fa_img_src(String);
        fn verify2fa(String);
        fn check_hwcodec();
        fn verify_login(String, String);
        fn is_option_fixed(String);
        fn get_builtin_option(String);
        fn is_remote_modify_enabled_by_control_permissions();
    }
}

impl sciter::host::HostHandler for UIHostHandler {
    fn on_graphics_critical_failure(&mut self) {
        log::error!("Critical rendering error: e.g. DirectX gfx driver error. Most probably bad gfx drivers.");
    }
}

#[cfg(not(target_os = "linux"))]
fn get_sound_inputs() -> Vec<String> {
    let mut out = Vec::new();
    use cpal::traits::{DeviceTrait, HostTrait};
    let host = cpal::default_host();
    if let Ok(devices) = host.devices() {
        for device in devices {
            if device.default_input_config().is_err() {
                continue;
            }
            if let Ok(name) = device.name() {
                out.push(name);
            }
        }
    }
    out
}

#[cfg(target_os = "linux")]
fn get_sound_inputs() -> Vec<String> {
    crate::platform::linux::get_pa_sources()
        .drain(..)
        .map(|x| x.1)
        .collect()
}

// sacrifice some memory
pub fn value_crash_workaround(values: &[Value]) -> Arc<Vec<Value>> {
    let persist = Arc::new(values.to_vec());
    STUPID_VALUES.lock().unwrap().push(persist.clone());
    persist
}

pub fn get_icon() -> String {
    // 128x128
    #[cfg(target_os = "macos")]
    // 128x128 on 160x160 canvas, then shrink to 128, mac looks better with padding
    {
        "data:image/png;base64,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".into()
    }
    #[cfg(not(target_os = "macos"))] // 128x128 no padding
    {
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAA72UlEQVR4nO19B7hdVZX/bqfc8mrKe+mNFEIMhBJCdwARpIxlHFQUxjYwKA720Q/869jBgoKAIoMFaTMgMChNQQggnYSQENIryUt59ZZzT9n7/6219z73vCQvBBIQh7s0vOS+c8/ZZ++1V/mtsglpUIMa1KAGNahBDWpQgxrUoAY1qEENalCDGtSgBjWoQQ1qUIMa1KAGNahBDWpQg/acKCGUNSZsV0QpeTMQfV1fUCn9V7/NczunH+APnzg3DNR+iosCkYQQrihRVOEoVGY0ihBGCZFqh5EqYKjMhzv9foeJhecP+YbK3C9zr+zf7T13fM4u33Wo6xLzuQw9l6yP+rY8Veta/lzSv7F/xzn6v8UA5sWo1+I2zTzx486YOf8Z5UcOV1wQShShihIJT6aKKAnrbxaDUQL/U+mkKHOvzGjhUnyEvQ6+DwsJd9H31tfBd/X38fdmWBK5ykw8zT5Cj0HzmZkWfK65Pz5DfwfGPOhV8UJGlJLps/Rz9W/0cBQhiSQi6I3jrsWXV1f85Ztx99oe8jcm+notvjd61kR/5ukP0GFTJsUyJjKOK7ixKWG46HAdMAAIAZg4s8Mpg3/DrxRRoD1wrqlecAliw2zclDFggWDyQdvA/dIpT5kEfuKLCkpUrDlIZX9P7EwwfAbeAZgRxkYkjlEzmSIMl1WiasNnGQbCkXBFULIZSYSjMO+Kv4Gbc+5z7jI37I0rC247JVjz1z+90ZIA2RmnL2XXfbz4Yw6aVjz87JdqTpHIKKwQRV1KFdMLp1dVr5PZ+WZHW5ISGILuJPE16QVOr9aTSyisCQe1Afc0OgQWB3YrM7uTMSLhJz4zK1303zUzGGYzfwcNZYeqtz+O0Ky6HYtCdQVMk51lfD28NQNO0K8qmVRUxpQy4dJEVJ679YPhigdvej2ZwC64lUlZ1brvGMC8gGif0NZ63Kc3B04rS2QoKaUCfw2TgTvY7gg7Q1a1w8QbUZkZnp5m85kV++mu1otvb2Xfpi7dze6G/1qjAu8hM/aCMs/STJlKFsOsmhntIhoVYJijzsgZ3YQMZO+YmWLDyfBo/K5CZRT6LM6Xn/rdYeG6p57eV0ywuwUHKgpKJ7bkmvOFvIOLs08IJoUJ6s847deRO9yVUSVgnLowDJhwmDRJSMgoh13IUNRLKvVAM3o3NajqKgJ2nFYNiuHCo+1AUUVYMQsLrOzioOgGiY6MJi0LaKlgdD06J5RIySQx90nXPrstQNTbgVldYa5DRjKqQ/8KmYCB1IDPLAsoSiV+JJVgjDCt8oC7lKgRP/ZnnnJnsm3FxKTSE9at2b1bcM1H+j5NgtAJzbniwR3FqTPbc8cfOCJ30rRhTe+4ZFH3u/YNAxgRR4fvvz/vmHp6HFYCwpSrlTiIXBiWkL7HfRJW9cTZUcLy2IlneiL12NFiGyx1M4utd5GRGHgvvTBGqNStfNy0xibITi3ej2mGkdZYs4sLdkBdzeDGt7o83aFwYUZHWcMTKAHmtPJJMwNzCiSME9z5jFMiE3gPIpSKQ9I8apQ36Yj3Vxb/8Xd7sv7ZBYeRWq1nv1hghE5qKxRmD/OmvW1E8/GHjPBOnuHGJ7T5ghAZEd8XZJNwu+ev3PzwPmAAFGc4OblJc89PRE7SODKDignDn1R6TizilY99Pdrw7PVRUK0qvR8Hid6syNbvYydd7y4wy9LFTRfVMEJGTQy2E/R+NCyVcSjS51kZVPcgUlVUFwX6X+bplqnSb+orzBONbYimI96Jcc68kTPewfc7+pdSFEkSEQk2ETA8oYol1CHOmIM+S1564EYSB5bV93jB85zQKW3FwqxWd9qBo9tOOLiZvHP/AjuhNScIT2KSyIgkURIHlSDmuXzs5Yv+gvW9f1zeG5T3mQpQPO/w5lHvVZyzJI6F3YpSqdhhkVt74d7TKy/eexd5C1JCCIm2LL/O610z3zvoQ4uV08KIorBrUA2QJIlprm2OKI5ojXvXd1u1qBdcc1R2wX1G6NRhxcL+Lc60Q8cMO/6QQnTatGb3uCYHREpCVCJJHAcyLKnQuMHgHwm/uc2lridj4Ym/bN52YwRu6V6/nWFW0TK8mRebR4VJEhNBUVcTqWLm5Vzy8oKb08U3XsBbiyj+t7Zh0Qra+uTnnFmnXiHjMCBSuah+kihkjpPPDR89dqB3fTcuOMksOKd0anuhOKPZmX74uPZ/mOPVTps+rHBskRPigsJKOImjqoxDGSYoVXD+BSHgfcEySOIWmgn1c0TKxC/FUj66dtsTcO99JgGcfFORCUGA/cDgMmJdwjjKm5Zdn7UV3nqkDONTUtvw4h+caSdeASoQfoNmKqMM9qJymobBZx7ndEZ7rml6e27a4WNaj5vjhe+eNqx4dBNNCAcDOJJERhUZ12RY1qoBF5wJ7lrjU6soieYRLD7LFUgk4zjPhbtoa/8ji7eVul87A2TNZPN3xjmvG03G3YK/JzWSVCvlXX73LUXKuMBJLGhCJHGYAsGMC0YJcxxSS0h06PhR475/8PCHpnq1MXmuXM/lhEWcJGE/iRUNQyklMAwhSjAhXIYGMLi1BghBvEMbq4lUxC02EZ7Lk1AlhCZKqpxPHtnc87tSmCiQ0q+OAayfmvVVLd6vZEi5Q2RsjCUQYxJcEjDdNLqWvf4tS0r7GNbgRWcHPpOgOZWzZPO2Dfd3+V+fPUn8mie1oFqKY064b4xbQQXTHgzKD5QeRHtbxgU2BixMs1MoEp4vkihJ0NygnLBKQshfNvTfB9fDt/aQATL4OlBhZLHQMWGq0zpqv5ry2ohMItY+9pBIAdZPjHULro52p+wX4fPClCNPUoXOiTJJapRTkGiI1GUMe+2joXNu/YSkDvfu6CbZazKMpeMJYHqxwaBMBvyrI4mkHjrI4jnpcIzKyjgZiCdlh6ihikGxJa3uFMAb3JVh0L/s4RujSp9eCWvYITBmBiQoYYyxchip7/119W+WdbU/94MjRj020qkVq0EQCMZceCLAiGjSAT4B3zeeEgIQZtTgYfJ8gbB8gYChp70aKn3B3Q0D0fIFL/et06+k9oQB6rPiDt9vjDP1uK86I6f+C/Ob8opy4iG3wUMlSeIEoiEM/4NuLiWCgy0C/9K3cUfN+jwZe9hJcRTW8XbjqIFk01ysoVuLygAbQRBB7xqL5ZuYQdZZH+SX4besV1dfVAbgj3ZbgTT0S0iCANLgi+0ORYL3hECGDfEY1zONDaQQsvmuHS+lxIt6CF/7zK1Rpa+qb2UXDd1A8AQlZRzmEcOHnDFy26ruRV2V2n4/OXr8o1NFPKUWhoHgzMXrDB6C82UAEmtaAb4oCk2EFwokBuzCbC6lkpi5OfHkyu03bCrXYuRZMN7Jnoh87tLi2874tDPxyJ8mfhOJpJQyTiqIxWl3DxhTUM3H6IYggmaCN1m4NY7jTTKOwziJQxZToRE7cxvQU4gOGJ1mADU0acBaxvHoiJtG4oy/jx631HIDcX+LwOlrLQBokQBUSEwzqV5MY6Sh9W2Y0UQsgfHsou0YOk75BRgKQSzDPTgQlEKSMSbCMO4yWBPeyYZAGG4ARCqYkgAS6UtwB1NKHt1c7vrwn9fM/sGRY249fqR/clANQpxjC44lJl4BzyeUQJzLKTQRlgNrX0sHgFpR/BNFaswhf95Uuj1lUIDud7P6ZvF91nToR/5LTDn8nFoYBySuMQqvxZSfRsOQkTXHG5jT7Aor5ur3VEQBPOwyxHEVMI1hX2216hWv60gdotWTj/atDfLALuI2Imd/b0EpGx+wY8rEfRikIdTxfGpQFpQKaRRRY8No1SIcrRnBRiFVAhvVwDyEEg7jsLGHFLRCoQxvL5S2tTKyAUYKY0/qgBPOQV2NgUSC5y/tqVY+fP+qU793+KiLPzAx/zUZhTFVBCwBnGEctyIkhvcqFInI59H4Y+n4UHVKl3F3Yynsfmzd9qXZTTlEuo5hde6QpkP/+Yds4txzqtWgRKQUBPw6GH0a5MBRpIEQi+rpcK9ViqkghUXBf+CGM+hWXeDoXZROihmdvjUsgGEmYzLY3+pNmonw4errL6c7mHD9E7ZiBhpUJj8gRfZgDDvYFZqJtLWN4WLzakaC63viFjfQbyodAO7kmu0zNgrKIKkXH0ME9ejTIBfJfqM/lLI80F9itRqTcYILDPZVqtIYI06hmTj5ok5BgagnbBQLmRMpHcdhL2zqvX1tXxDAJTZAtGsJYKwiZ8xBR9Dxcy+MoqjCKM2DzLSiUCUqBomOi4G7DS1ALZ6suEQPJ5MWpicmUlIFiVIhfKceqcqEWFHcqx2QXYusa46v5wMY/ZwymHk23BgNM2Ml4042UsmAyoprEYyTiX+pb0a7FkliVYJZYCMVMJaXaKmjrXojwLLRQQo3xiyYoL628N30eVJxyTAnAnZRhktg98OjWzzOfnTk2B+fOdb9TK1UCSmnQiYJUdxYI2bxieuR2GyietwDJJNW0ZGXIw9vfvkmlA4g8cyjdsEAJpvHKXBv2vG/TBSPlQJoFyZVs76UKuaO4zImXGt94KBkhPk9evPXQ2s2QAp/48KZKIXn84T5WhJkw6zGgjcMiK9IdwjV2l1vAzfmc0C7tPwFe8Ii91rZwuLpobt1T8AYdUhp/oB2q3SWkgk3m2uNGavDRObd8PPUEUmD02kkAl+Dwa7wJmloVG9Z5gBSDj57ApAwbNCYKAauXi5dfElIZ9Fzfnr0hF+dNop/KKhWAuY5LmplChJEESkc4hSbiWICmaXuxZg1MF6nEMLtCRP5yMa+p80L6x+7ZAAb1x85fRZrnTgzkTJgjLkS3Cotr6QDiNPWpU8kXUu+ndTKW2UShX7n1OPo2Lk/iiWL4bW1ataTmQKbSpFg5fzz6KYXO5SSEaVMZwhljBI9BLP7rIZRiCakOscm22RCdgrI/HpQ2EdPAkW9owa9IuxhqwFNUChj5O3obeJYKASiM+6kTvMxcid7NTKswk8VJSUS1KJKX2h/xUAdobELPj0NHZcVef/aJdUtLz4CE5JISaa05XOXHzH67mNbk+NKA+VACMfVWkLPK3EF8ZrbSKIoWvtoUNp3sVFSnfsgPUrFiu2l+1/aOtBr+X1oBjA72mmfeDrjQiYk0harRPcj5oy4yYZnbqg+e9PZKiyZrEdCPFXe4o0/7EdxAqa3QssjtdTBvsK/SxJsfAGMEGOIvAVJJVLGkWEAGgjPyfPupQ+Wn7zh1LDnZXQTZ48oNF/99onzZ7Py7Eq1FgDip+LY5DeACBDEaWomCYp4QgTDHIvU7bQGMK6kVDIWgjyybsv1gP5lxf+QNgBzPJrrGDcvkpJB+BpkkhbFnNGkGtdeuv8CXHymDSsthx0PdaxGI42tm9WJhlLk5K1EyvwwHouKCUlY4DiiGK954sbyglvOkdW+CC6ZOyI38pp3Tn16Mi2Nq9ZUAKoWJhRtpVgS6rrEaWohMeHobmOCTQZus2CUNSwpI6xfCfLgxtKfdzWyHRjA+smCxjQ3Wu9gY9yAsOJMBL3dy5LS1l681iRsaDTKvKOx6myyJQrNQancNkniLUbUajAQp27sClasLf3zd6tL7rqIJDWc4ZPHFKf98JhxT42nleYgDEPGmcsgawryp0BbMEHc5haSIFCWqjLQNTEsuOBcWCQT8JBEKllwXXd5f7jguY09m+AZg1XVUF4AYhVM50fATjawLsA8NInLBECLwYCqsTm1VW3jXFpXGiOvQUjgMOY9JUqL7/u36qI7r9afEnLW1La53z54xBMtskyCsgy5YAI2GODqqGddj7jFZlx83HB1EEr6rovWbS2MY4asYp4F6J/jisfXd13fU0vQM9wxP3A3OIDJv0vTmtJ8uiziPeg7+CtuAhPmfwYpeqvJ/CGJUelES+76YCldfEo+O3f8qT88YtQTzbIaxnESQ5AOXEX4E0F2FWMI7UrGjVetYxxKqTDX0ix+v27gh39cO/BTx/dElMQxrDL8oCRhA1KQhzcOYC7GrpLAdwsFW9tWW/IGWRpiLbVNawo9LGJm3DvwBchbnZTeerJvw7rtPWvWwr8cSsjXj5107qdntFwd9XUHijHBOGU6UAT4uiLc9RHhi8EPihPCIK1Pr0Xgt7Tkb1ne/YNP3rXkiyMLrnvA2LnvH+u6I8IQo3DEpcxd3VPd+MSG3lU4hF2o3t0X7hlRA7i0DcLsVn+ncHld/FuUrEGGVIysUOCU/vDIzm9+Zop/ddi7PcDAHOp6jlJUcoaWvtPSin6+jnlA9hAYg3HIXS//28VbvnnenQu/BBG/Df1B+JMn157Jim2Cciop57Hv+2Th1tL1GwdqUTaYu4cMoBcdgiImBmdioUNdb8HPermUTptuSH9LAPDAIowuuu41bx/7609MLl5U7e+tQGoYA1AEXWaALxnxi81ENDUjIxDOCYOfjEmpktDzC/4vFm760gV3v/C1aizRtQOJ++sFG+ffu6b75kI+7ypC45rIkQfXdd+KZplBUveYATQur6FESOioZ8q+AuGONzi1Rcfe4jxAjRQFtO5tI5uafnvyfg+9Z0zuI5VarcKF4wOIYwNrANUKv0CImyMxuH3gNIBrrS3C2Gsb5v/4uU2f+I8HV14aGpgaQ9mEkCCOyffmL/u3zbUkzNHIfbkclh7dVHphKPG/WwbQhRwW2gTxY4ofdkMIRtgcZuPuvdUdAGqmAxbpmFGFsb87ceLieYVkXjlEgMdHuckBGVQEgHSWzxPq+yQGWQ/CICEkCdEijHmxxf/WI2v++aKHV14LoV8tFPQSgr0Au/ypjb09v3hm/dl5z3df7Oq9dVV3yeQg7Hp8Q6sAYwCCyoEMNh1IGdoEsAE8LPVB2WEjbGn57F4TGpqmygvEKeyq+h/9+ZtJ2DADP4MJ9KGpbYf/6u1jV09k5XGVajVkEJgwxSZSJgCyELe1lYhCswZOIYAFGypMJLr5frP/tYdXnvy9R1b8N9zbEYKMmHnsWdxv9vXT6oWwVzyz4ZZH+8XSZ7dW7kdGGUL8794LsLnp+JMRaZIrdohY1i83RTIQAcexm0SMvV0QOwb4G3D5YE4eQqyZqMjf0vbkJprnUEq+ctSEsz+1X+HXTrUUQ9o8Z1xgrgImvSgCMTXw8aUDrr+eNNTZMomdnOMOMJ9c/Mi6edc+vRpTublwSdPB7/0POWK/78bLF9xin2lDYP1hor7x2KozStUQ+xDszgXbLQPYHzZuj4GrV9jMtnYPrsMAymtE/vTCZxdd67kJbQVvrE+GjfTFyPZiYZgQzK3WosqWgcqmTSHZvHx7ZaAcG+VomCGLfb+Ri9+Rd5xvzh19yVnTWi6s9PVWJHhmXDAtroFBJVHcIR5Au5SRJIbPjSSVSex7nttFvP7P/mn5YXcs3rBM39yhzQd/4Ntq4ryvlHs3rtzRwrLR8PuXblxe/0y9egagkHUI/8c4nA4s7BrFTwP2Nt9Rp2FZ2+FVYv+DF14RhzNy0LDciLdPGn78sa3qn/dvL55Y4LLZIwkGQWxoNlJtpEKEXNNfeW5+d3zdXat6b310Y/9mPdkGwyJvlL4n5ODO5vYfHNF5x7wWcnSpryeghPgA4KRpZLD4jkucgl58O0As7oyTMOe5/uqyXH/e/QvnPrK2ezPen7m8+dAPX80mH/GJWhjFgkIhxhAF9IPqGIem3QBBOq5er1IxL7kTEJRmZWSCHjYRCMKUJttzD8hClfDMVpezU6cMm/uhycWvHtTmnd7sAAwdEhkOEFmDsAiJIUfesiXlRDRT4h7U5BxyUHvhkI9OKl7x4IbSNVcs7fnaoy8P4ATuCgrdV1QfO+j79nnfOKzjwU4W+uVSGHBoBQAxfCUx9g12EnNzxM0ZdE+XdiDyl8g4KOTy+We3157617uXnLCkuzqAD3AKbmHOB28Ukw9/bxjUSsxxi8zgA7uiPfLYdscAiqI2wjiz3o2Go/ZgBtEYMYketlJyd9dbcBlu7XFG3zd12KHnz2i9amYrP0REIUnCUlyryVBB/TngonjzxIWwKOgljIYxRsJExiqICAlqsUuZOH2098ljRo395G9Wlz996TMbrxoKD997wxRcPGBaxr82b9znzp6Uv0QE1bgWJSGFXAqjviCxNaGUOJCy7eV1Bg+YfFDQgQYUC5qa2/P3b6re/Om7lpy9tq8aggHHmjqa3QPffy/rmDkvqFYDRpivYkjASaPxr5mGTAnDGnysw9dgjs5+yWRVDEWw3hA+Nl6DiU/TV9w5hJB5o5s6vzx7+GXHjcqf6YYVEpSDoIYOBRMUiiN0NgWaNZBUYQUA7CHMxkJJAzi5cGFBqrUg9EnIPjO9eMXBbeP/8fN/3fxPi7ur/don33susGOHex0xurnjW4d23HJ4Kz02qJaCGBoiMRi3htFgChLGEdZlHrh5JuMJkizQ4ZehX2zO/+6l7u984b4lF/dUQwnp4ZAckpty/CXu2DnzwnKlQhn1IR8IBfE+0GtDS4A0BlTvrmF63QxJaYJrBvwxm5/uTte3epx//tAxH//IpMLPR7CIBOW+oKK4UIy5mDaMdogOLsH1Wr/VU86xBCRN6dZjZQy8ESZAlFVKfZWj2rx33HDS+GUXPLrl4IfX97zMM4y3N7s+53D6rzNHnHHBrLbbOmjIgmqtohjzdcGOrm/ANC7HI16xiCFdnV2kYyyQrwHqQfj5/GVPbzjv6/NX/RxcN5sZBJTQHKSNY5AIYjGAzmKYHThkL9v8DBEOBnHFWBoA0ikmmWZOQ0yMWSTdDAh0nUntxnyyXev64ye0jb94zojbD2njc+JKOaygGStcRM902AMzFHTyLiPUcTHj1XW91B4BKRWGNeg+RUgUYQKDjkqj+8oodfxKGAUThey45u1jX7rgUX7Afau2rQNJgOrtNSw8/Dm4o9h+8ZyOK08Y5Z+ZVEoykDIkTPgMcROTMg+q03UIAzfPFkChpwT4CpTOe6Lm5dlX/7L8HT97Zt2f6vOTySJWia67YARUCiTk7qJEah+rAAVzB+XrwGQm99yk+Q55s2xRKKo0rTqgRt2kDllIVFv3F7xt5HsunD38trakQmoDlQrlHHcOehw2CwXmUQjC3RwuPoPKGCuJbO8emRDP8zSOniRE1gIiw9BICUjNxnRUN4pU2KkG8lcfM+alzwl24O3LtizbEybYceELLqfnzuo449wD2m8YS4N8UOqrMC5cBjl0uHAmXItVOkVCvBwWbTDI4QLm4FTKRIU5P+9vSNzeL9+37PDbFq1bZku8drRRqCJcZw7XIb16RsDe0dBuoA0BmdRq3SJvcH77Tt8x68xsD59Exo4viowlkSmWQax7TF543z96wk9OH+Odm5T7QsAqBdc63k4Ceh/CxcpW5kDVM0/1rV0UHFEidc9BNFU43IgI4RDphKRWKhGuYoSxdXoUFbFM4vZan7j8qM6XiiSed/2ybg2umFKuQR6PkT+w4SzTnjGpbea5+7dfNW+Ed2xc6ZcVqUJgXJ0PYULiwHjMISKXI8TzsGxOdzKBraSICmXQlMvnn+mOnvr3Py08+amNfd07prfvuBq6dCzjdO/s/b0m2m1lkBZjCWFUmKRDzQRDkU2HBolNGYsdhxXjlX/5Bt2yCLNdwWg7akxr5/fnjrz/oCY5Kyj3B0QxV0OmmqfRsOOC8BxYyj6B+kM0mMy2SBN3UX2avoFa8KCAhTFHgEO4eeI2cRJX+4mKYg286IIREcdKFiu98aXzOh6f0pr7xGULu67rq4FnueP76GfmBaPvHN8y7ewZw75x1HDvzHxSIcFANaBUCEoVzmGi88S19PJ8BHcgl1nXgUFPJJ2JDG/o+035OzdWfv7v9zx/wctl0FmE5NrHdAi/edjAyy8u2SknGXeU6VNpvDFc/33AA0PaALYGT4t9Uw2D2O4um/elq6IUhZkUPon80oK7Phgt/9NN1mA7a/rwud88YvT8kWHJrQRRQCk0NND30ztNEeb6ROQKRAkHJ1VLHtOwUUL5gYyhFEsw6sNPkBhQq5gkMiSKCsZNVBXGLwTmzSeVMomDKoGUOVMDwJJESbdaDj43s/WXx40qfOKGZdu+/Pi26NnN5RpWzhQ8h+9X5COO6sgfd8zo5vMObHGObkqqpBKUwhomPglfYvmgkRwIgUORRhMyLqZumYWEvyYqiR1XiNgpikufWnP2pU+svb4SacTS75wxrjjnfQuCVY+dTciLS3bKSTergIl4qU39OqsASxbTQwwrFVF0KKbBxNE8rbr9f73p2HDD4/PxIZyRL8zp+MiFM9t/41f74xqRIWcUixw0bIwZp8QtFgl1PRAfWhKkLylht8cOF35zzhM1wslm6YY9oeqC+3e6ZFynF/lBUCORTKDsWECNsq4gFrgoOMSgpnsogBXNAZNhblQuh3MLbN4hh498aJvyyPZKvAn4J5/jw9o58YcnAZFJTKphGJakxMRLKEOVSkm4jwZ2AKhxiePnMWtXVxqDGjCFWYkKC4WCv0Hmer/256XH3Pj8OgzRArnjDj/an/PuhyKvFUq/TSONHTjApHzr/aiTQvYVur2bWIAdhC3cfMUAMvQ/Y07YHVeev21ObcNTS+DTtpzLvn/0+O+cOc75clweqESSuo5gWBKGXoNNe/LzhDiOrnBB6aNfWCYydAT1Ha8g1lZZaf7y7h/cv3LLfy/pqa3tKtew5GpC0Wk6ZcqIk885cNy1o3ktX42ikBImMKSNMDYlolhE4EWGVcQQwB6jYNswJaqxDElSla2k6o502Shk9EhBR7t4gBFwv8AjEgxLMvV2YKZQBpA8nvfRzQN0AmycFBJOoOJHyXxTi//I1uCeL973xAcWbOrrw4l3fervf8qn/OnvuLyqWMlhKo/943a5FtoG0b2IdV4gIqz7IPT5yuXhtjTLNl0eIrQkBPe92qZSz9O3z6i+vHQjfNbpc+eqEybd8I7h7J9qpTKCGBD61gkMUM4MezBHXCxyqLdW1uVY4EWquKmQ99eFIrh54cZP/Wbhhpte2l6p7PjsLQPV3qc29d9058ptd//o+Om/P2pk4R9K1UooODCaLl/GyFyxmUBTnaRa1dnOSoe6GRa8Yv4TCWNI2tfvC20doQ+TLjvTZeh6PQCQcgjzXBT3RECjLwP4mMHHYRzmfccvCZdc+XzX5749f/lPuqtoCxPqt/pNc8+6lo+d86EgigPYOsxB7trlvgZeAwNXJ+iYz7D/wuvMAAhiwFbFMmxdVj0U7iCD0kD/EzftX+1ag4s/rcUrXnHsuLuPbldHl8qlgHPq42zrLHNE9KCFCXXzBKYFXk37xvDCSZxzXDd08+LmNX2XXfrIsv/3/JYBDG3aghOTboLPttWHsLs+9PsF77zm1Fk3nTSu6b3lSrnCwUI3ZWrQFUHkm1A/JzVoWIlywNSq6HQsCILpQiZYUKjgNW1ATFVwTAVhrtDi3oGQlG0Yre8DrROAcQtNBf+lMln5ncdW/OMtL3YthnGiO5przxXnnbNQDd9/alANAkqJSygLwZsZakNjFnAq823dol6fvaXdIIH1AkzcAZmQ7A4X4o++Dcs32AU5rLNp+M+OGfv4AW40BUqbOKcu7gxAZlBsMuIWW0gC8W/bChYqXRAvj8O85/qrIm/td+5/6d2/e+HlBRhUSn1kjfwNGoJZBM4o2VwJo4/d9fyZ17xr9g2nTmx+f6lUrjCET/WVoBI4NE5yfWheRWQMeEGiCxTNHKdbEbOhgTshL08Q6jnEcXxChYPMkEjo+KJFMpZkJ3Hou66f5IvithXdP734z4u/vKoHvAUNYoFdw/y2YaJ53NRaBGXaUHNpwsISN9nQQt32J7BJNql9tnc0dHm4XW7D2VrmmHLjHSSVBkq0v/z28W1jLz+qc+EUXmuv1BLdL9igYgjqcI5GmXQc07tfo4uJUhKYxC22+net6fn5Vx98/rPLuyvVVxPTt6XPW6tx/PE/LPzgL06ZVTltYss5pUq5xLiT14EKqcW1cIhoaiHQtjMOa0RJKLayxqeBm01pu+OBswLZuhqLQPvF1EnodjMqhordXM73V9ec9Zfc8+L7f7NwwxOY1p3GHdLxx9ihmIIxme1Evhu/DrvZok7UMDAGwKA/i+2W/HpAwQpbEWmVbyu9h1gEi5K9c8qISZfP63hhtCrlg1CGggsXG7dgQ0xFmO8RkQc8XHf2ALAZAN8kieOcw90+5pHvPr7uPZc9vup2SG23KN2rSeiwuXHbgyQ5565FH7vi1NldH5g+4ktBqT+E/rzQsgUZDho0UIquIrRow41ueg/g2yKzm3wGEzNAlZiCVdq1g9Zr+Zzvl6hLblq69ZuX/HXtd1f2WMatA1eDppcJrFjHw1IsqrmbzVzfdDryCXAbxkQMs74+KgCAdWsAmrYt9Qy3OlkOP31657SfHtGxqD3sF0GsQs7AANNYAqh+ns/pDhYmBgA+sy4ZkUEhl8uvjtyuL9695Kg/LO9aubvJezVMUIqk/Ne7Fn15Tf/0RecfNOq3zUlIKkFQoZS52K1b6aAKMDZMJcC1aVuDQa3wrDTEeCh4gJIpIvNe3o8cnzz0cs/tP3lq1WfvXrFlDc4JxvaHSEmjFDOCdKw902hIp70NuZ2txIFgEOIjWLL3eqkAfGOKIEfaF0uPTSqsXMimPinynv07Z/74sM6FrdVeEioZM8LRBYOvxJAEkcvrfnW2GZNxLpJEBsVCLj9/U+WPFz7wwpmLu/pKJn6w1zF7HTUk2KH76w8suf7Zl3sf/+oRE2+ZPawwR1arJIxlBeLGuu2i6VKlVXW92RPmIeqtD20XiSQxejt+TpS5T57uKv3h2gXLv3L7ixtfqEbQeFF/F1TRbiltmpY50gag8yGWP21UYZZGf/bKdTp77QVoLrVhZ9BbTHBZrYBrYHfou2d0zrhsXueilmqPjAm0hoXOX7pFAGLgOR/FPlrLZuj44okMiy0t+Ztf2vLjC+998Qs9QSz3VZzeksXOYWHuXPryikfXbj3sY4dMOOMjMzt/OLm5OEmA+x/WSBTLEKr2QelJaHpDpUTrX3v8rmBKCGjBwl23J5TxE2sHrrl+6aof3bds03JY+KydsgexRRNVqRtxaWs50/Bx5y+Yplm29xKsB4SFX18cQBs4GuZUMReuSwc2dMVLbj+DyggdkNOmdUy77PCRi5qrPQhyQ7xa24uAkSrCvBymOVu/X+e7QfIDicHYu/KFbRd89b7FVwQx+uL7dPHrb2HRX0q2V6Pk0kdW/P63C9bfdcr0UYecNqn142/raD693aMdruDYWNmeKsIEJJwoEoSSbAvllhc39D744KYt1/95ZdfDz3dplxSoLrH2bOzmeIK0DY7+DBYXBOvQ98AcKNOxzLqlSPR1lACYkRLLmAvmi2Bbb/Xp3x4UbVu9FX534uThE396xMiFbeEAiRSE6AEnM3ltcON8Tu986yMDA0DHCch8dov+f/513bsvfWz5HbuKf78eZFUCjGNzqRZd98yax697hjw+qa3gTWj2RkzqHDaxsynXWXB4EzBzKZJ9m/orm9Z2da9f3x9sW91T1i1eXuPCp3EBxDFsX0RbOmcTXIa6WSYd3sj+NDtrKL2xLxgALGXCqfCigbj63A0HBl0rMLnyuAnDxl51zJhFI5KSGxIVg0uj5S3kvCkM5vBcDoI0xqAGLyCJheeKCs+Jrz68/Mj/em79X+3Q36j8fZueaBlBKkVW95Rrq3vKG/6ytnvDK33ftpx7tZ7J4EHoH/bcJFtEhRU+Qxh16PJhvyXwRut4yOuqAvQLSunGZREsuHlmecNi7C87d3Rzx5VHdSwcGZfzYQwNCSA1VVt1UM4kcnmMg+sGT1qcJkkYe8IVPcqRF96zaPZtL21d/Ealau+KsnmqLJOyuONY6l23tFG6r6SUdetSu8HWPgzlZpvK4JRZwDzHStO68fpaaagOIdh7xqWSlZ6+5aBg3TMvwcez2vOtVx016qnxpNYe1OKQcwoHVJjiMYLJG06ugJmv2JwG0wmUzLmOu1W6pXP/sOige9f0rNzXxt7ekNydKb1Ph5haegZXyXQ1Nc2fzLmVO38T+QOwE5OaZ1PhBmfa7UskkKocD0f3P3nTqcG6pxfCRxOKInf1caMemu4l44JaEnIO39XdO1G/+jnsUK1TnS1WrSR3BdlIC+vP+99njnxgbc8GtCts9uibqZBvT8j67HtJADFhBpI9kSyTO5CCAvZkFVh9LzdCd0K29pT+yTnkCA4Fz+0FA3AhRGnJ/WdV1z2HSYojfeH84h8m/e+cFjq7Ug1CwaibgKGvs1rxNAoBLUxsKlfaIk7G23Pj/M/e8eRZD6zt3gAQXJztHfzmEAKvjl7rmDOMo41HCC4ZJA+EAmSRK1XV/67vbK9jv05v9KR3hXEYw5FzWnBg8IDwpLyZqxAayO2UQvAaGUDfIakNhBWz+C2+w35+0pTfHjWMnFCpVgMO7e8RtzceU66Ap1Kg2DcNN21odHNxEvvZxk7y4MtxD+o7qIJxizmFFR07QRo7z9QO48pACdnksME7c9Auze6qzHU2q4buYFqnkFx2PJlrUsm1m5ne6ZbGt6wNVDDJIG2dq0vpwPrHcxVYQmKneX/iD3sew3+M0uLoqTPY1BNvIF6TyxJIH4fOmroRD2VMVresfywOytaXJPtMAmBJGMQpOSWXHD3++ye2kTPL/aUK55AGpY0X2MnQlhx2PoZw01M5dbx3W+tkcuXmMeTmnnZSc9scqTYRz82z9iPPeqiSG3eYzhbGzuG6DRpiDja2Yc8GMG3iDWdhW3SN4JpKm3pCoF1Tm1OAnU1sY4tsQMu2lzXl1xLfBxIu9b3TcwHsWcX4b72Q9hhae0CwPlNYr7o+ENsYc9gGXvt5jLuMVrdVeh75ZQcJtpdgcYUQJIJ+CyZ5FoKjsZTSnXzMtbnxh1yD788Fc3J5ElEXYiWQJAXQj+lsz6CfDIu6V5mzmOi+YwCrX0BMXTSn89Mf6ORfCAbKFYaZr/pcmgSOG8vn8ESKenRau3zwve7mieRnW8aS321pJ7R5eBrpQITQb0pIYTimWSlm4GaqJYo9QjbNCtZwox4XBpB2QMVSXzrTq99Y2YkZkk5xr0sVvTDwGRw0bIAuI73QlrGN7u398dka27e9i3Wip+FVTHfWQS2dFm/azev7SQVukgqhzWeK+iTQbt4GyKw/D+Px8lJCZhTmHrC4hpOEfZqxcRS+YSJjJlyh+ta+UNu8FO2zvaGdGMBCvJ86YNgZn96/9fKoAvn6zMdJRPGeEOEDyANi33aW1TsCXqi/eQK5atsY8quuVhIV26VXd17xPZMkgpfCgAqcnQQ7EXoP4PRA1rzNfsVr0xPgzaHQZnktYge7HKWprr7RTaFt9pKecv0V01tPZRYvPc5Gpj2Q6A7nDqRNiSGKiJJHp8mDQYaSHAWEjRZC9pdZYzj4w5x+AqLNRG81KUJhDilzTMul+rkFGhAzBfj68CfX5kZyeAdomixVKGRYrCy55yMq6IeEhL1KEBzEANY9+8DU9sMuPrTjDhKWAxiEPqQBoGFIt3YxqgcNiu0ZK+bEbllpGs2u2jyCXLu1jdSa2gnHXCaAOOsIB4NuR4yD7Yq9L9NkDHM0TFooalrN2ZNCcNejYWwkArR6N7seaxgxomfVQ+Y0EHt4gy6m04xjCl4pVBJCW+M00ILHt+Dn1lRNm2TpI4BMnrSWkNDwO3tyrGYYLX0wqCQZdOuC+tp680acaP0Am+hpnw2Nnw1UZbxojf1rnoUCB2gQzouVBXecH6x7esHeLv4gBrCLf/Lk9onfP2rs426tP4TCFmaSDrTo48QFnZ8eqGBfScmwqUNcvblDXru1k4RNIwmH9vFmF2RHCWXd0G4eDpVMX97oeezfn6RnjRh7Sx+yqZ0nI9NhMfBcFdO3Hz8zqsGc84tHsiEOjVs4PUotPXdIJ5wSzHiD9HL8jnZrVaylTF2p2CPwzJhQJWiVxg0Umzm+uB4QgnMdQHrgC5gsHtDfXJBaOjcWcMLx6RMpdNAZuBwTpqEwg3LXzdOIDDx35yeC5fdduy8WP2UAK/YPHJFvu3RexxNtQb8E2B5Baz1TCDr5TUUs0wLDBQ980isq43xe/GotufG63hHvC1rGuBxBf1tDYONxeiIdxxvJXE8oKTBkbFucpTvCNfColTBwsBFup8zU2uNebKpYetaAWSosyID+1Vrk14+mJ0bdGHmrMsdEW5TNxOigMLN+mLQ9/8CGxe1hUQaVw1SzelMtB5lNG6EYaY55a8YQslVKYP6mPRTRneaeAHEB2x8PiIxjfB4nEYk3L7qnb+VD/x6sf053CtnLGEDKALZQc0yOeZcfNeovk0kwspokIeS/Y3UqyFIOO7+IHS2Qo404VEQF+bZh+R8+veH9V66QT6gjTv2gilSoKIeKGd0ksp7vhHqttOKp38R81X6KklCf+rMzmZOD9N8ZZMDofEHkNszc2TXZc8Ky37eFLXrakSEolugZtay0laevgEXI4vH65Dl9eJRxwM05McZogOQM6zVp2wATH83WhmIGSDaIwv6EJDWsAMIHmuNeLJ4P5YzcYUxuXflEsn39M5IqF+7r5Jw+FfQu6Nu0fL7ctmydSqJMcdi+AVEwP7/V4+yq48bffFgTmV2qRoHg3EWrF9w9pbCsWblQ46YbRsDD4SCJpuaW/K9e3Pb1i+5f/D/DJuw/DuKpKEaNxWzqt6CRASIbUa0qexff813yViRqGAssezQCgdngA0UYp7HveH6167kvlpbcM3/oe+wbsZ8l5glOLjl28jdOHpP7x0oYBhAXt9k8yKFejiju6lp1/BwNvrC5WMzfsbrvms/f9ex/wo0gLyKs1SCrF1UGotecY+o0a27HM3Hfql1DaaoK8TAGP2Ee1ommHVfgTxxAk34NAZref+bLdeZ5HeIn7OLDRn3qfaOdi0qlcgC5cjZ+jzoJ3T2dxGnNc2hglHdd/9Gu2kMX/PGF88sxOkKk3NfbF1YG4HQJHR3UNhCaZvnJh32JCA96zpO3IilcaP3uuSlzz1G5vPZKoOIXai5AlcQ1EpW70yrhzJdf1wO3xb8c0HkF7dtcUZT5xt3QGTFejjBI37YqFM/Lk3HO9fylNbH+/HsXnLqlAvi0SYAsd5dYVH1BCjGb1JJYYqI7FVTGMR826aTmw8++rLrk3otIradsDprYEf8dnDOWwW72TOHtW/GidglK77wFB6HTOwzIXIC6NFGu60w84ix3/MFfj8MgxtRRXY0khSdcWuoPK1vWY1HNG0ni1tX9X/nohLbvJv09AWHcBXcwZhwbG+hqVHMkakKk63hsK/NL59/7wiFLtw6U0XU0bpiSoYy6Vt7A2ybNAvsVK39NqCshTswnHPmZ4siZ57vx1uc4Hi2qnTr018HyAlRWVx4DRKaRFg0OMYXHgtriFKMKwdaAY9usS5pJqMsuRv2Y1vQTm2NLLG4IZDsL6mYSGXjd6F3jxGHln/ZezM7IcErqFmunRlf6KVD2hASkOEXmRw6HDCsJOTTG2tc2JmeytO1uEvQMvNFBMgouy/eOnnDhufsVfhxC52rH9XmxBaoX6/44bGdG4tAp+J+8e/H+dyzftnRQTN9MktM2saP5+M9sDkVTQBJsaaLPxENUDc8VFwz+b2IuKFjSnj8WAsaCzXRGEftHwztzAqjpwoGPtmM0LlpaM5dZczTaDSxovR4LTUpzAvfg5gvGAzXFMAZP0odd2rgHegOQ/JrtgjQ4dTd7zJ3+ngzg5FSbH4nH3EoS+pz6/U/8Zl5t1SNP6Ie8cccrCGhQ/OX5ay6Tcjw/b0b7D2KiKspx/XqTKLDk41B4zflvPbL6ZFx8yE3P5nGZKFnUs6YrWvf0V7wZp3w3qFYqikisy9OTTbFhk1RRDEegW7hXn0Ooc4b1qaH1c4cQEYTyKyjENzg7Vl2D82ghU1MtY8PQOKl2WMYN5Qjt6WswRjAoE4mac3btYc9Yzl1/Ph69bmIUNvBkGcC6kjq4kGLPNmZvGc38Hna9i5cYpk/iJHRdz082LvxjtP7pJ+sRxzeOLL6BiNCPj5960bkHj/1m/0B/hWGnK0riKA5zTUX/50u2f+4L9y75sV7vXSU/61flXpEXD/vo3XTsQe+Ia7USUcSHWnwNHEFI2CRHWhVpsVR7+rVF82xkVl+U1ipaMasjqvYCc8804qt3p16mwcYGPi/WEoGaIJFmUA0g4bc0sJjiCen3bY5GdnfbVQYGs8fYpmlmphm0VUMmTK5PBCEB99y86tnYNTD/ymmy3NX/moP6e0F2E+L7e5TQn75z5vfOntXxpVJ/fwBh0mIh7//v2v7rzrlz4cfLpvjhFZlUFNy2uR/9Hz7h4NNrMgJ8JJAqEViBgQmidpF11ZAVx6gFDPiicXmD6Fn1brqQ4Rxjgwe9G7G0FIWCRt7SZgrm+DqrOuoMZlQLrasC3M+ZCzFXT0J3JigWNhCPqReEf9kDstJEU8ut9qRRU8xpYV0DQqEuBCXncOYm21au7HvqxiNV39otf4vFN6MzfzELm+eU/uSUmZecNaPjC0kYyoV9yZPvv/XZYzeVatEeFWlao8nNs8L0Ez+Wm378z5Tf7CaKY5YxHoaEsKeN0ME9QczqBqDYasWctW6OmdZ192AnmsCOMRZxxdP4gMkN0LEns/uwhwsslu7aZcMGWAaeRfyUjeMbZkObFANZ9ljwetd79NEzCSo7+DKoMrB9nw1v22lhxBGccJoQGlZJuO6Zb/U/e9u3Za0v+FstvhlynayBlBeU/vy02VccMWXMJ953w2MjF27q7Xt1XbfrLySaRzUVJh/6rqR58gd588i5juM1QU0ZVpipxMboBmfr1PV0/WBtXaIEIDmeSRLHnCTMK6Jxl9oPmFyRDkEfYJVNFTI7VleKEL04xssxh1dbyYRFmHFQElpCYTqGHVQa9JHgsdhWMCZWAMrAxEF0Rw+tgqJarRL2bFngVDb8d7D+uTvCLSu2vl7o3quhndxXmwwyPO/xScOa2p5av23ba+uvWz+92BLPNXHuFgSrH3T7iv53/eupx02JihPZPmued+iHHsICfzBhjLgFD8LW0mlDLNtQwehfIyG4Tca09kYauFQxdXJusPgP56mVD/wX5S7XGUPWtR/MqztP5+DJgnONkzBIkkofdh8ZfP3fbvF3mRBiY97bKrVkW6W2LRWdr5pSa8nemCTVgQT+7P2wCWk5YL/TwVVNggRzA3QUtd5yXW9uw2cmVQsEM1bW1kdIMCiYpqsYdYBZGzHx2sZ9uL+/5xfYRGBfUWY+/taLD7TLwJpdN13+tJdP0DLX/CMTIt6jP6C7TcUMZm/owmR3wtyDeOesLyRBBdKiofebbiCe5imYSCRWLNaTQW2rO2tZEDTM4Wwec63NCKJMKBmHzuiZRxdmvessHDk8G/5kx2PD1HvyJ4sWvUlqIoDenNGZ3ejF3Lg5+3mz/+m52GvNKyhhh0ID/I7V8QZRQJTNxPttVk26BlqcKyMtsCzLuHOmjaC5Hw89FvnlZ/7nhMqyBx54tWP9e6A3HwNkJtTJNYHnCOFzSr3mltzkeWc6k4++MqLQuAvMe2gEbSpmbDqGid3rzWx7Gxo0IEUgjdum6m5b6m8YHz5jnEpBYxFvWPCD2oqHfxT3d23j2COOkLg6oCN6f8f0JmMAk23TOrEjf8BJ38i1jz4YsioTxZqIyM8kXgupRdB7D/x9XWKrcQXbvqV+lx1PMk2xgUz2EEmTRK2tXvflUaxAOppOQo1d13VpdYCosH85o3I7VZSHA9vXlF988P/FXc+/+GYw6P6+GcDsfHfEfp3FeR9dmxRHu7ZfvslAimUSxUxRgc2RTOs0q9Fh6sF31+4gVhhosAdukDZz0iurSxjMUaxWe9QREZ3LYOMDBqomikJTaEY55EuYIhhBiVMrkd5Hrzs4fvnZ5/4e1cG+6DW4b8igcP6Mky4lrWPcJK6UqAxDpqJQJXEM520wRl2A5mCt7FFE2u7TcQKbhWQhYYvU6OILu/110xtr7RO8mRX6g6PUtpgEnsM4c6mSAo73oCoMKQnDuAbdKH3p73/y9dTJ68KFN9Ge2ie9gt9Q0e8VeeKPPFgGYQV3siSYOayzgA3kmkZ6dnGCiD3XCBNNMcKcIncqsZ1ILTRnGkobRDDV5baZBWr5bMyjHiDCYJ05FT2JZOAPGzU5aesoVres7v970wRvDgYwk8a4YF4hN1PB2bkQPU6DNeYEM1v4lSnTE1aMWz2Pu9nm3VtrPwUU06aSeCoeAcoARWY4WIKGbqUN6mQ8hyzcg0ifQzw6QGpCpM2z/p7ozcEAtqImCmK57J7jiVvMY2Mu46vbk2cs2SBsliC9xpZ5WQtfI4F6u9qoYz1cnyb2WkWRDsVCwTZuWX+uNh8tG+i2LpRUVURq/dtNMsff0fZvUIMa1KAGNahBDWpQgxrUoAY1qEENalCDGtSgBjWoQQ1qUIMa1KAGNahBDWpQgxrUoAb9X6L/Dwi7aG5wRLkSAAAAAElFTkSuQmCC".into()
    }
}
