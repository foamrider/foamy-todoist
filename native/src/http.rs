//! HTTPS to the Todoist API: the kit's TLS (Graviola, system roots), proxies
//! from the environment, response bodies capped while they are read, and one
//! absolute deadline per request for every socket read and write (the
//! connector below is foamy-zendesk's, which closes ureq's CONNECT-reply gap).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use foamy_helper::{Failure, tls};
use serde_json::Value;
use ureq::config::AutoHeaderValue;
use ureq::tls::{Certificate, RootCerts, TlsConfig, TlsProvider};
use ureq::unversioned::resolver::DefaultResolver;
use ureq::unversioned::transport::{
    Buffers, ConnectProxyConnector, ConnectionDetails, Connector, NextTimeout, RustlsConnector,
    TcpConnector, Transport,
};
use ureq::{Agent, Proxy, Timeout};

/// The Todoist API. Nothing else is ever contacted.
pub const API: &str = "https://api.todoist.com/api/v1";
/// Test-only override of [`API`]: a loopback `http://` base URL.
pub const BASE_ENV: &str = "FOAMY_TODOIST_BASE_URL";
const USER_AGENT: &str = "foamy-todoist-helper";
/// A full sync of a large account stays far below this; anything bigger is
/// refused while it is read, before it is parsed.
pub const MAX_BYTES: u64 = 16 << 20;
/// Todoist's own processing limit for a standard request is 15 seconds.
pub const TIMEOUT: Duration = Duration::from_secs(15);

pub fn network() -> Failure {
    Failure::coded("NETWORK", "Can't reach Todoist. Check your connection.")
}

fn timed_out() -> Failure {
    Failure::coded("TIMEOUT", "Todoist didn't answer in time.")
}

fn oversized() -> Failure {
    Failure::coded("HTTP", "Todoist sent an oversized reply.")
}

/// Where requests go: [`API`], or a loopback test server.
pub fn base() -> Result<String, Failure> {
    match std::env::var(BASE_ENV) {
        Err(_) => Ok(API.to_string()),
        Ok(value) => loopback(&value).ok_or_else(|| {
            Failure::coded(
                "INVALID_ARGUMENT",
                "FOAMY_TODOIST_BASE_URL must be a loopback http:// address.",
            )
        }),
    }
}

/// `http://127.0.0.1:<port>` (or `localhost`), nothing else.
pub fn loopback(text: &str) -> Option<String> {
    let rest = text.strip_prefix("http://")?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let port = rest
        .strip_prefix("127.0.0.1:")
        .or_else(|| rest.strip_prefix("localhost:"))?;
    port.parse::<u16>().ok().filter(|&p| p != 0)?;
    Some(format!("http://{rest}"))
}

fn roots() -> Arc<Vec<Certificate<'static>>> {
    static ROOTS: OnceLock<Arc<Vec<Certificate<'static>>>> = OnceLock::new();
    ROOTS
        .get_or_init(|| {
            Arc::new(
                tls::system_roots_der()
                    .iter()
                    .map(|der| Certificate::from_der(der.as_ref()).to_owned())
                    .collect(),
            )
        })
        .clone()
}

#[derive(Debug, Clone, Default)]
struct Deadline(Arc<Mutex<Option<Instant>>>);

impl Deadline {
    fn set(&self, at: Instant) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Some(at);
    }
    fn get(&self) -> Option<Instant> {
        *self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[derive(Debug)]
struct DeadlineConnector(Deadline);

impl<In: Transport> Connector<In> for DeadlineConnector {
    type Out = DeadlineTransport<In>;

    fn connect(
        &self,
        _details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        Ok(chained.map(|inner| DeadlineTransport {
            inner,
            deadline: self.0.clone(),
        }))
    }
}

/// Every read and write capped at the time left before the request's deadline.
#[derive(Debug)]
struct DeadlineTransport<T> {
    inner: T,
    deadline: Deadline,
}

impl<T> DeadlineTransport<T> {
    fn cap(&self, timeout: NextTimeout) -> Result<NextTimeout, ureq::Error> {
        let Some(at) = self.deadline.get() else {
            return Ok(timeout);
        };
        let left = at.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(ureq::Error::Timeout(Timeout::Global));
        }
        let left = left.into();
        Ok(if left < timeout.after {
            NextTimeout {
                after: left,
                reason: Timeout::Global,
                ..timeout
            }
        } else {
            timeout
        })
    }
}

impl<T: Transport> Transport for DeadlineTransport<T> {
    fn buffers(&mut self) -> &mut dyn Buffers {
        self.inner.buffers()
    }
    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), ureq::Error> {
        let timeout = self.cap(timeout)?;
        self.inner.transmit_output(amount, timeout)
    }
    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
        let timeout = self.cap(timeout)?;
        self.inner.await_input(timeout)
    }
    fn is_open(&mut self) -> bool {
        self.inner.is_open()
    }
    fn is_tls(&self) -> bool {
        self.inner.is_tls()
    }
}

/// Notes when the HTTP request starts to go out. It sits above TLS, so only
/// the request's own bytes count (not a handshake or a proxy's CONNECT):
/// once set, the server may have the request, whatever happens after.
#[derive(Debug)]
struct SentConnector(Arc<AtomicBool>);

impl<In: Transport> Connector<In> for SentConnector {
    type Out = SentTransport<In>;

    fn connect(
        &self,
        _details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        Ok(chained.map(|inner| SentTransport {
            inner,
            sent: self.0.clone(),
        }))
    }
}

#[derive(Debug)]
struct SentTransport<T> {
    inner: T,
    sent: Arc<AtomicBool>,
}

impl<T: Transport> Transport for SentTransport<T> {
    fn buffers(&mut self) -> &mut dyn Buffers {
        self.inner.buffers()
    }
    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), ureq::Error> {
        if amount > 0 {
            self.sent.store(true, Ordering::SeqCst);
        }
        self.inner.transmit_output(amount, timeout)
    }
    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
        self.inner.await_input(timeout)
    }
    fn is_open(&mut self) -> bool {
        self.inner.is_open()
    }
    fn is_tls(&self) -> bool {
        self.inner.is_tls()
    }
}

/// A reply: HTTP status, the JSON body (`Value::Null` when empty or not
/// JSON) and the `Retry-After` header in seconds, when there is one.
#[derive(Debug)]
pub struct Reply {
    pub status: u16,
    pub body: Value,
    pub retry_after: Option<u64>,
}

/// A request body: form fields (the Sync endpoint) or JSON (the REST ones).
pub enum Body<'a> {
    Form(&'a [(&'a str, String)]),
    Json(&'a Value),
}

pub struct Client {
    base: String,
    agent: Agent,
    deadline: Deadline,
    sent: Arc<AtomicBool>,
    timeout: Duration,
    max_bytes: u64,
}

impl Client {
    pub fn new(base: String, timeout: Duration) -> Client {
        let deadline = Deadline::default();
        let https = base.starts_with("https://");
        let mut config = Agent::config_builder()
            .http_status_as_error(false)
            .max_redirects(0)
            .user_agent(USER_AGENT)
            .accept_encoding(AutoHeaderValue::None)
            .proxy(if https { Proxy::try_from_env() } else { None });
        if https {
            config = config.tls_config(
                TlsConfig::builder()
                    .provider(TlsProvider::Rustls)
                    .root_certs(RootCerts::Specific(roots()))
                    .unversioned_rustls_crypto_provider(tls::provider())
                    .build(),
            );
        }
        let sent = Arc::new(AtomicBool::new(false));
        let connector =
            ().chain(ConnectProxyConnector::default())
                .chain(TcpConnector::default())
                .chain(DeadlineConnector(deadline.clone()))
                .chain(RustlsConnector::default())
                .chain(SentConnector(sent.clone()));
        Client {
            base,
            agent: Agent::with_parts(config.build(), connector, DefaultResolver::default()),
            deadline,
            sent,
            timeout,
            max_bytes: MAX_BYTES,
        }
    }

    #[cfg(test)]
    fn with_max_bytes(mut self, max_bytes: u64) -> Client {
        self.max_bytes = max_bytes;
        self
    }

    /// The request's deadline: its own timeout, but never past the run's.
    fn deadline(&self) -> Instant {
        let own = Instant::now() + self.timeout;
        foamy_helper::process::run_deadline().map_or(own, |run| run.min(own))
    }

    /// Whether the last request's bytes started to go out: after that, a
    /// failure (a timeout, a closed connection) leaves its outcome unknown.
    pub fn request_sent(&self) -> bool {
        self.sent.load(Ordering::SeqCst)
    }

    /// POST `body` to `path` with the token as a bearer.
    pub fn post(&self, path: &str, token: &str, body: Body) -> Result<Reply, Failure> {
        if self.base.starts_with("https://") && !tls::cpu_supported() {
            return Err(Failure::coded("TLS_UNSUPPORTED", tls::UNSUPPORTED));
        }
        let deadline = self.deadline();
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(timed_out());
        }
        self.deadline.set(deadline);
        self.sent.store(false, Ordering::SeqCst);
        let (content_type, data) = match body {
            Body::Form(fields) => ("application/x-www-form-urlencoded", form(fields)),
            Body::Json(value) => ("application/json", value.to_string()),
        };
        // Todoist refuses request bodies over 1 MiB; callers stay well below.
        if data.len() >= 1 << 20 {
            return Err(Failure::coded(
                "INVALID_ARGUMENT",
                "The request to Todoist is too large.",
            ));
        }
        let response = self
            .agent
            .post(format!("{}{path}", self.base))
            .header("Accept", "application/json")
            .header("Content-Type", content_type)
            .header("Authorization", format!("Bearer {token}"))
            .config()
            .timeout_global(Some(left))
            .build()
            .send(data.as_bytes());
        let mut response = response.map_err(classify)?;
        let status = response.status().as_u16();
        let retry_after = response
            .headers()
            .get("retry-after")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.trim().parse::<u64>().ok());
        // The limit stops the read one byte past the cap: nothing bigger is
        // ever held in memory or parsed.
        let data = response
            .body_mut()
            .with_config()
            .limit(self.max_bytes + 1)
            .read_to_vec()
            .map_err(classify)?;
        if data.len() as u64 > self.max_bytes {
            return Err(oversized());
        }
        Ok(Reply {
            status,
            body: serde_json::from_slice(&data).unwrap_or(Value::Null),
            retry_after,
        })
    }
}

/// `application/x-www-form-urlencoded`: every byte but the unreserved ones
/// percent-encoded.
fn form(fields: &[(&str, String)]) -> String {
    fn encode(out: &mut String, text: &str) {
        for byte in text.bytes() {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
                out.push(byte as char);
            } else {
                out.push_str(&format!("%{byte:02X}"));
            }
        }
    }
    let mut out = String::new();
    for (index, (name, value)) in fields.iter().enumerate() {
        if index > 0 {
            out.push('&');
        }
        encode(&mut out, name);
        out.push('=');
        encode(&mut out, value);
    }
    out
}

fn classify(error: ureq::Error) -> Failure {
    match error {
        ureq::Error::Timeout(_) => timed_out(),
        ureq::Error::Io(ref io) if foamy_helper::net::is_deadline(io) => timed_out(),
        ureq::Error::Io(ref io) if io.kind() == std::io::ErrorKind::TimedOut => timed_out(),
        ureq::Error::BodyExceedsLimit(_) => oversized(),
        _ => network(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn only_loopback_overrides_are_accepted() {
        assert_eq!(
            loopback("http://127.0.0.1:8080/").unwrap(),
            "http://127.0.0.1:8080"
        );
        assert_eq!(
            loopback("http://localhost:9").unwrap(),
            "http://localhost:9"
        );
        for bad in [
            "https://127.0.0.1:1",
            "http://evil.com:80",
            "http://127.0.0.1",
            "http://127.0.0.1:0",
            "http://127.0.0.1.evil.com:80",
        ] {
            assert!(loopback(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn form_fields_are_percent_encoded() {
        let fields = [
            ("sync_token", "*".to_string()),
            ("resource_types", r#"["items","user"]"#.to_string()),
        ];
        assert_eq!(
            form(&fields),
            "sync_token=%2A&resource_types=%5B%22items%22%2C%22user%22%5D"
        );
        assert_eq!(form(&[("a b", "é&=".to_string())]), "a%20b=%C3%A9%26%3D");
    }

    /// A server that answers one request with `head`, then writes `chunks`
    /// of `chunk` bytes `pause` apart; it counts what it managed to write.
    fn server(
        head: &'static str,
        chunk: usize,
        chunks: usize,
        pause: Duration,
    ) -> (String, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let written = Arc::new(AtomicUsize::new(0));
        let count = written.clone();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0u8; 4096];
            let _ = stream.read(&mut buffer);
            let _ = stream.write_all(head.as_bytes());
            let block = vec![b' '; chunk];
            for _ in 0..chunks {
                if stream.write_all(&block).is_err() {
                    break;
                }
                count.fetch_add(chunk, Ordering::SeqCst);
                std::thread::sleep(pause);
            }
        });
        (format!("http://127.0.0.1:{port}"), written)
    }

    #[test]
    fn a_trickling_server_cannot_outlast_the_deadline() {
        let (base, _) = server(
            "HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n",
            1,
            100,
            Duration::from_millis(100),
        );
        let client = Client::new(base, Duration::from_millis(600));
        let started = Instant::now();
        let failure = client
            .post("/sync", "t", Body::Json(&Value::Null))
            .unwrap_err();
        assert_eq!(failure.code, "TIMEOUT");
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn an_oversized_body_is_cut_while_it_is_read() {
        // 64 MiB announced, more than the socket buffers hold; the client
        // stops after 1 KiB + 1 and closes, so the server can't finish.
        let (base, written) = server(
            "HTTP/1.1 200 OK\r\nContent-Length: 67108864\r\n\r\n",
            1 << 20,
            64,
            Duration::ZERO,
        );
        let client = Client::new(base, Duration::from_secs(5)).with_max_bytes(1024);
        let failure = client
            .post("/sync", "t", Body::Json(&Value::Null))
            .unwrap_err();
        assert_eq!(failure.code, "HTTP");
        assert_eq!(failure.message, "Todoist sent an oversized reply.");
        std::thread::sleep(Duration::from_millis(200));
        assert!(
            written.load(Ordering::SeqCst) < 64 << 20,
            "the whole body was taken"
        );
    }

    #[test]
    fn a_closed_port_is_a_network_failure() {
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let client = Client::new(format!("http://127.0.0.1:{port}"), TIMEOUT);
        let failure = client
            .post("/sync", "t", Body::Json(&Value::Null))
            .unwrap_err();
        assert_eq!(failure.code, "NETWORK");
    }
}
