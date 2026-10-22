use hbb_common::{
    anyhow::anyhow,
    bail,
    config::Config,
    get_time, log,
    password_security::{decrypt_vec_or_original, encrypt_vec_or_original},
    sodiumoxide::crypto::sign,
    tokio, ResultType,
};
use serde_derive::{Deserialize, Serialize};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::Duration,
};
use totp_rs::{Algorithm, Secret, TOTP};

lazy_static::lazy_static! {
    static ref CURRENT_2FA: Mutex<Option<(TOTPInfo, TOTP)>> = Mutex::new(None);
}

const ISSUER: &str = "Olidesk";
const TAG_LOGIN: &str = "Connection";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TOTPInfo {
    pub name: String,
    pub secret: Vec<u8>,
    pub digits: usize,
    pub created_at: i64,
}

impl TOTPInfo {
    fn new_totp(&self) -> ResultType<TOTP> {
        let totp = TOTP::new(
            Algorithm::SHA1,
            self.digits,
            60,
            30,
            self.secret.clone(),
            Some(format!("{} {}", ISSUER, TAG_LOGIN)),
            self.name.clone(),
        )?;
        Ok(totp)
    }

    fn gen_totp_info(name: String, digits: usize) -> ResultType<TOTPInfo> {
        let secret = Secret::generate_secret();
        let totp = TOTPInfo {
            secret: secret.to_bytes()?,
            name,
            digits,
            created_at: get_time(),
            ..Default::default()
        };
        Ok(totp)
    }

    pub fn into_string(&self) -> ResultType<String> {
        let secret = encrypt_vec_or_original(self.secret.as_slice(), "00", 1024);
        let totp_info = TOTPInfo {
            secret,
            ..self.clone()
        };
        let s = serde_json::to_string(&totp_info)?;
        Ok(s)
    }

    pub fn from_str(data: &str) -> ResultType<TOTP> {
        let mut totp_info = serde_json::from_str::<TOTPInfo>(data)?;
        let (secret, success, _) = decrypt_vec_or_original(&totp_info.secret, "00");
        if success {
            totp_info.secret = secret;
            return Ok(totp_info.new_totp()?);
        } else {
            bail!("decrypt_vec_or_original 2fa secret failed")
        }
    }
}

pub fn generate2fa() -> String {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let id = crate::ipc::get_id();
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let id = Config::get_id();
    if let Ok(info) = TOTPInfo::gen_totp_info(id, 6) {
        if let Ok(totp) = info.new_totp() {
            let code = totp.get_url();
            *CURRENT_2FA.lock().unwrap() = Some((info, totp));
            return code;
        }
    }
    "".to_owned()
}

pub fn verify2fa(code: String) -> bool {
    if let Some((info, totp)) = CURRENT_2FA.lock().unwrap().as_ref() {
        if let Ok(res) = totp.check_current(&code) {
            if res {
                if let Ok(v) = info.into_string() {
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    crate::ipc::set_option("2fa", &v);
                    #[cfg(any(target_os = "android", target_os = "ios"))]
                    Config::set_option("2fa".to_owned(), v);
                    return res;
                }
            }
        }
    }
    false
}

pub fn get_2fa(raw: Option<String>) -> Option<TOTP> {
    TOTPInfo::from_str(&raw.unwrap_or(Config::get_option("2fa")))
        .map(|x| Some(x))
        .unwrap_or_default()
}

// Admin-issued 2FA reset: olidesk-api's reset_client_2fa signs a payload for one
// device ID, and the service polls check_2fa_reset for it. Signed rather than
// trusted over TLS because post_request falls back to accepting invalid
// certificates, so anyone in the path could otherwise strip 2FA.

/// Public half of `reset_signing_key` in olidesk-api's config.json.
const TFA_RESET_PUB_KEY: &str = "U5HKoZ4QDjuZDGbq5nxPlQ+k2i8bDTf+8ZfiTq9Z13Q=";
const TFA_RESET_API: &str = "https://olidesk.olisys.co.il";
const TFA_RESET_POLL_INTERVAL: Duration = Duration::from_secs(120);
/// Matches TFA_RESET_TTL in olidesk-api/app.py.
const TFA_RESET_MAX_AGE_SECS: i64 = 7 * 24 * 3600;
const TFA_RESET_MAX_SKEW_SECS: i64 = 600;
/// Nonce of the last reset applied, so a reset whose ack was lost is acked
/// again instead of rejected once 2FA has been set up anew.
const OPTION_TFA_RESET_NONCE: &str = "2fa-reset-nonce";

#[derive(Deserialize)]
struct TfaResetCheck {
    signed: Option<String>,
}

#[derive(Deserialize)]
struct TfaResetPayload {
    olidesk_id: String,
    nonce: String,
    issued_ts: i64,
}

/// A reset applied (or found already applied) that the server has not been told about yet.
struct PendingAck {
    id: String,
    nonce: String,
    issued_ts: i64,
}

/// Starts the background poll for admin-issued 2FA resets. Runs in the service, so a
/// reset takes effect for the next incoming connection without a restart; the first
/// check happens immediately, which covers a reset issued while the service was down.
pub fn start_reset_poll() {
    static STARTED: AtomicBool = AtomicBool::new(false);
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    tokio::spawn(async {
        let mut pending_ack: Option<PendingAck> = None;
        loop {
            // Acked one round after applying, and only once the clear has stuck: the UI
            // pushes its whole cached option map back to the service on any option write,
            // which could restore the old secret if it lands right after the clear.
            if let Some(p) = pending_ack.as_ref() {
                if enrolled_before(p.issued_ts) {
                    log::warn!("2FA reset {} was reverted, clearing again", p.nonce);
                    clear_2fa();
                } else {
                    match ack_reset(&p.id, &p.nonce).await {
                        Ok(()) => pending_ack = None,
                        Err(e) => log::debug!("2FA reset ack failed: {}", e),
                    }
                }
            }
            match check_reset().await {
                Ok(Some(p)) => pending_ack = Some(p),
                Ok(None) => {}
                Err(e) => log::warn!("2FA reset check failed: {}", e),
            }
            tokio::time::sleep(TFA_RESET_POLL_INTERVAL).await;
        }
    });
}

fn current_2fa_created_at() -> Option<i64> {
    serde_json::from_str::<TOTPInfo>(&Config::get_option("2fa"))
        .ok()
        .map(|info| info.created_at)
}

/// Whether 2FA is currently set up with a secret older than `issued_ts` (seconds).
fn enrolled_before(issued_ts: i64) -> bool {
    current_2fa_created_at().map_or(false, |created_at| created_at < issued_ts * 1000)
}

fn clear_2fa() {
    Config::set_option("2fa".to_owned(), "".to_owned());
    Config::clear_trusted_devices();
}

async fn check_reset() -> ResultType<Option<PendingAck>> {
    // Nothing to reset without 2FA, and it keeps such clients from polling at all.
    let Some(created_at) = current_2fa_created_at() else {
        return Ok(None);
    };
    let id = Config::get_id();
    let url = format!("{}/api/clients/2fa-reset/check", TFA_RESET_API);
    let body = serde_json::json!({ "olidesk_id": id }).to_string();
    let resp = crate::post_request(url, body, "").await?;
    let Some(signed) = serde_json::from_str::<TfaResetCheck>(&resp)?.signed else {
        return Ok(None);
    };
    let reset = verify_reset(&signed, &id)?;
    if reset.issued_ts * 1000 <= created_at {
        if Config::get_option(OPTION_TFA_RESET_NONCE) == reset.nonce {
            return Ok(Some(PendingAck {
                id,
                nonce: reset.nonce,
                issued_ts: reset.issued_ts,
            }));
        }
        bail!("2FA reset {} predates the current 2FA setup", reset.nonce);
    }
    let age = get_time() / 1000 - reset.issued_ts;
    if age > TFA_RESET_MAX_AGE_SECS || age < -TFA_RESET_MAX_SKEW_SECS {
        bail!("2FA reset {} is outside its validity window", reset.nonce);
    }
    clear_2fa();
    Config::set_option(OPTION_TFA_RESET_NONCE.to_owned(), reset.nonce.clone());
    log::warn!("2FA cleared by admin reset {}", reset.nonce);
    Ok(Some(PendingAck {
        id,
        nonce: reset.nonce,
        issued_ts: reset.issued_ts,
    }))
}

fn verify_reset(signed: &str, id: &str) -> ResultType<TfaResetPayload> {
    let pk = crate::common::get_rs_pk(TFA_RESET_PUB_KEY)
        .ok_or_else(|| anyhow!("invalid 2FA reset public key"))?;
    let signed = crate::common::decode64(signed)?;
    let payload =
        sign::verify(&signed, &pk).map_err(|_| anyhow!("2FA reset signature mismatch"))?;
    let reset = serde_json::from_slice::<TfaResetPayload>(&payload)?;
    if reset.olidesk_id != id {
        bail!("2FA reset is for {}, not this device", reset.olidesk_id);
    }
    Ok(reset)
}

async fn ack_reset(id: &str, nonce: &str) -> ResultType<()> {
    let url = format!("{}/api/clients/2fa-reset/ack", TFA_RESET_API);
    let body = serde_json::json!({ "olidesk_id": id, "nonce": nonce }).to_string();
    crate::post_request(url, body, "").await?;
    Ok(())
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TelegramBot {
    #[serde(skip)]
    pub token_str: String,
    pub token: Vec<u8>,
    pub chat_id: String,
}

impl TelegramBot {
    fn into_string(&self) -> ResultType<String> {
        let token = encrypt_vec_or_original(self.token_str.as_bytes(), "00", 1024);
        let bot = TelegramBot {
            token,
            ..self.clone()
        };
        let s = serde_json::to_string(&bot)?;
        Ok(s)
    }

    fn save(&self) -> ResultType<()> {
        let s = self.into_string()?;
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        crate::ipc::set_option("bot", &s);
        #[cfg(any(target_os = "android", target_os = "ios"))]
        Config::set_option("bot".to_owned(), s);
        Ok(())
    }

    pub fn get() -> ResultType<Option<TelegramBot>> {
        let data = Config::get_option("bot");
        if data.is_empty() {
            return Ok(None);
        }
        let mut bot = serde_json::from_str::<TelegramBot>(&data)?;
        let (token, success, _) = decrypt_vec_or_original(&bot.token, "00");
        if success {
            bot.token_str = String::from_utf8(token)?;
            return Ok(Some(bot));
        }
        bail!("decrypt_vec_or_original telegram bot token failed")
    }
}

// https://gist.github.com/dideler/85de4d64f66c1966788c1b2304b9caf1
pub async fn send_2fa_code_to_telegram(text: &str, bot: TelegramBot) -> ResultType<()> {
    let url = format!("https://api.telegram.org/bot{}/sendMessage", bot.token_str);
    let params = serde_json::json!({"chat_id": bot.chat_id, "text": text});
    crate::post_request(url, params.to_string(), "").await?;
    Ok(())
}

pub fn get_chatid_telegram(bot_token: &str) -> ResultType<Option<String>> {
    let url = format!("https://api.telegram.org/bot{}/getUpdates", bot_token);
    // because caller is in tokio runtime, so we must call post_request_sync in new thread.
    let handle = std::thread::spawn(move || crate::post_request_sync(url, "".to_owned(), ""));
    let resp = handle.join().map_err(|_| anyhow!("Thread panicked"))??;
    let value = serde_json::from_str::<serde_json::Value>(&resp).map_err(|e| anyhow!(e))?;

    // Check for an error_code in the response
    if let Some(error_code) = value.get("error_code").and_then(|code| code.as_i64()) {
        // If there's an error_code, try to use the description for the error message
        let description = value["description"]
            .as_str()
            .unwrap_or("Unknown error occurred");
        return Err(anyhow!(
            "Telegram API error: {} (error_code: {})",
            description,
            error_code
        ));
    }

    let chat_id = &value["result"][0]["message"]["chat"]["id"];
    let chat_id = if let Some(id) = chat_id.as_i64() {
        Some(id.to_string())
    } else if let Some(id) = chat_id.as_str() {
        Some(id.to_owned())
    } else {
        None
    };

    if let Some(chat_id) = chat_id.as_ref() {
        let bot = TelegramBot {
            token_str: bot_token.to_owned(),
            chat_id: chat_id.to_owned(),
            ..Default::default()
        };
        bot.save()?;
    }

    Ok(chat_id)
}
