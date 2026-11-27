//! HTTPS to the Todoist API: the kit's TLS (Graviola, system roots), proxies
//! from the environment, response bodies capped while they are read, and one
//! absolute deadline per request for every socket read and write (the
//! connector below is foamy-zendesk's, which closes ureq's CONNECT-reply gap),
//! and a connect that falls back between IPv6 and IPv4 addresses.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use foamy_helper::{Failure, tls};
use serde_json::Value;
use ureq::config::AutoHeaderValue;
use ureq::tls::{Certificate, RootCerts, TlsConfig, TlsProvider};
use ureq::unversioned::resolver::{DefaultResolver, Resolver};
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

/// How long a connect to one address may take while other addresses are
/// left to try. A healthy route answers well within it, and it leaves room
/// for one lost SYN (Linux resends it after 1 s).
const ATTEMPT: Duration = Duration::from_millis(2500);

/// Opens the TCP connection like ureq's `TcpConnector`, one address at a
/// time, but each attempt except the last gets at most [`ATTEMPT`] and the
/// addresses alternate between IPv6 and IPv4 (RFC 8305). ureq alone splits
/// the budget geometrically, so a host that lists eight AAAA records first
/// (CloudFront) left its IPv4 addresses a few milliseconds when the IPv6
/// route drops packets.
#[derive(Debug, Default)]
struct FallbackConnector(TcpConnector);

impl<In: Transport> Connector<In> for FallbackConnector {
    type Out = <TcpConnector as Connector<In>>::Out;

    fn connect(
        &self,
        details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        if chained.is_some() {
            return self.0.connect(details, chained);
        }
        let started = Instant::now();
        let budget = *details.timeout.after;
        let addrs = interleave(&details.addrs);
        let mut last = None;
        for (index, &addr) in addrs.iter().enumerate() {
            let left = budget.saturating_sub(started.elapsed());
            if left.is_zero() {
                break;
            }
            // The last address keeps the whole remaining budget, so a host
            // with one address waits as long as before.
            let attempt = if index + 1 == addrs.len() {
                left
            } else {
                left.min(ATTEMPT)
            };
            let mut one = details.resolver.empty();
            one.push(addr);
            let single = ConnectionDetails {
                uri: details.uri,
                addrs: one,
                config: details.config,
                request_level: details.request_level,
                resolver: details.resolver,
                now: (details.current_time)(),
                timeout: NextTimeout {
                    after: attempt.into(),
                    ..details.timeout
                },
                current_time: details.current_time.clone(),
                run_connector: details.run_connector.clone(),
                register_shutdown: details.register_shutdown.clone(),
            };
            match self.0.connect(&single, None) {
                Err(error @ ureq::Error::Timeout(_)) => last = Some(error),
                Err(ureq::Error::Io(error)) if elsewhere(&error) => {
                    last = Some(ureq::Error::Io(error));
                }
                done => return done,
            }
        }
        if started.elapsed() >= budget {
            return Err(ureq::Error::Timeout(details.timeout.reason));
        }
        Err(last
            .unwrap_or_else(|| std::io::Error::from(std::io::ErrorKind::ConnectionRefused).into()))
    }
}

/// A failure of this address only: another one may still connect. The same
/// kinds ureq moves on for.
fn elsewhere(error: &std::io::Error) -> bool {
    use std::io::ErrorKind::*;
    matches!(
        error.kind(),
        ConnectionRefused | HostUnreachable | NetworkUnreachable | AddrNotAvailable
    )
}

/// The resolver's addresses with the families alternating, starting with
/// the family of its first: v6 v6 v4 v4 becomes v6 v4 v6 v4.
fn interleave(addrs: &[SocketAddr]) -> Vec<SocketAddr> {
    let first_v6 = addrs.first().is_some_and(SocketAddr::is_ipv6);
    let (first, other): (Vec<SocketAddr>, Vec<SocketAddr>) =
        addrs.iter().partition(|addr| addr.is_ipv6() == first_v6);
    let mut out = Vec::with_capacity(addrs.len());
    for index in 0..first.len().max(other.len()) {
        out.extend(first.get(index));
        out.extend(other.get(index));
    }
    out
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
        Client::with_resolver(base, timeout, DefaultResolver::default())
    }

    /// [`Client::new`] with another resolver: tests give fixed addresses.
    fn with_resolver(base: String, timeout: Duration, resolver: impl Resolver) -> Client {
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
                .chain(FallbackConnector::default())
                .chain(DeadlineConnector(deadline.clone()))
                .chain(RustlsConnector::default())
                .chain(SentConnector(sent.clone()));
        Client {
            base,
            agent: Agent::with_parts(config.build(), connector, resolver),
            deadline,
            sent,
            timeout,
            max_bytes: MAX_BYTES,
        }
    }

    /// A smaller cap on reply bodies than [`MAX_BYTES`], for a reply that
    /// holds one record.
    pub fn with_max_bytes(mut self, max_bytes: u64) -> Client {
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

    /// Starts a request: the time it may take, its deadline set and
    /// `request_sent` cleared.
    fn start(&self) -> Result<Duration, Failure> {
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
        Ok(left)
    }

    /// GET `path` with the token as a bearer.
    pub fn get(&self, path: &str, token: &str) -> Result<Reply, Failure> {
        let left = self.start()?;
        let response = self
            .agent
            .get(format!("{}{path}", self.base))
            .header("Accept", "application/json")
            .header("Authorization", format!("Bearer {token}"))
            .config()
            .timeout_global(Some(left))
            .build()
            .call();
        self.finish(response)
    }

    /// POST `body` to `path` with the token as a bearer.
    pub fn post(&self, path: &str, token: &str, body: Body) -> Result<Reply, Failure> {
        let left = self.start()?;
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
        self.finish(response)
    }

    /// The reply: status, `Retry-After`, and the body read up to the cap.
    fn finish(
        &self,
        response: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
    ) -> Result<Reply, Failure> {
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
    use std::io::{ErrorKind, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use ureq::unversioned::resolver::ResolvedSocketAddrs;

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
    /// of `chunk` bytes `pause` apart. Its thread returns how many body
    /// bytes it managed to write.
    fn server(
        head: &'static str,
        chunk: usize,
        chunks: usize,
        pause: Duration,
    ) -> (String, std::thread::JoinHandle<usize>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let thread = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            // A client that stops reading must not block this thread for ever.
            stream
                .set_write_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut buffer = [0u8; 4096];
            let _ = stream.read(&mut buffer);
            let _ = stream.write_all(head.as_bytes());
            let block = vec![b' '; chunk];
            let mut written = 0;
            for _ in 0..chunks {
                if stream.write_all(&block).is_err() {
                    break;
                }
                written += chunk;
                std::thread::sleep(pause);
            }
            written
        });
        (format!("http://127.0.0.1:{port}"), thread)
    }

    #[test]
    fn a_trickling_server_cannot_outlast_the_deadline() {
        let (base, _server) = server(
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
    fn a_redirect_is_the_reply_and_never_followed() {
        // Following it would send a request to another host.
        for code in [302, 307] {
            // The other host answers at once, so a followed redirect ends
            // in its 200 instead of a timeout. Its thread returns whether
            // a request reached it.
            let elsewhere = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = elsewhere.local_addr().unwrap().port();
            let contacted = std::thread::spawn(move || {
                let (mut stream, _) = elsewhere.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut buffer = [0u8; 4096];
                let requested = stream.read(&mut buffer).is_ok_and(|read| read > 0);
                if requested {
                    let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
                }
                requested
            });
            let head = format!(
                "HTTP/1.1 {code} Redirect\r\nLocation: http://127.0.0.1:{port}/sync\r\nContent-Length: 0\r\n\r\n"
            );
            let (base, server) = server(Box::leak(head.into_boxed_str()), 0, 0, Duration::ZERO);
            let reply = Client::new(base, Duration::from_secs(5))
                .post("/sync", "t", Body::Json(&Value::Null))
                .unwrap_or_else(|failure| panic!("{code}: not the reply: {failure:?}"));
            server.join().unwrap();
            assert_eq!(reply.status, code, "{code}: the redirect was followed");
            // An empty connection ends the other host's wait. It sends no
            // request, so only a request from `post` counts.
            let _ = std::net::TcpStream::connect(("127.0.0.1", port));
            assert!(
                !contacted.join().unwrap(),
                "{code}: the other host got a request"
            );
        }
    }

    #[test]
    fn an_oversized_body_is_cut_while_it_is_read() {
        // 64 MiB announced, more than the socket buffers hold; the client
        // stops after 1 KiB + 1 and closes, so the server can't finish.
        let (base, server) = server(
            "HTTP/1.1 200 OK\r\nContent-Length: 67108864\r\n\r\n",
            1 << 20,
            64,
            Duration::ZERO,
        );
        let client = Client::new(base, Duration::from_secs(5)).with_max_bytes(1024);
        let failure = client
            .post("/sync", "t", Body::Json(&Value::Null))
            .unwrap_err();
        // Dropping the client closes the socket: the server's next write fails.
        drop(client);
        let written = server.join().unwrap();
        assert!(written < 64 << 20, "the whole body was taken");
        assert_eq!(failure.code, "HTTP");
        assert_eq!(failure.message, "Todoist sent an oversized reply.");
    }

    /// The addresses the test chooses, whatever the URL's host.
    #[derive(Debug)]
    struct Fixed(Vec<SocketAddr>);

    impl Resolver for Fixed {
        fn resolve(
            &self,
            _uri: &ureq::http::Uri,
            _config: &ureq::config::Config,
            _timeout: NextTimeout,
        ) -> Result<ResolvedSocketAddrs, ureq::Error> {
            let mut addrs = self.empty();
            for &addr in &self.0 {
                addrs.push(addr);
            }
            Ok(addrs)
        }
    }

    /// An address that never answers a connect, like a route that drops
    /// packets: a listener whose accept queue is full, so the kernel drops
    /// every new SYN. Keep the returned listener and streams alive.
    fn silent(ip: &str) -> (SocketAddr, TcpListener, Vec<TcpStream>) {
        let listener = TcpListener::bind((ip, 0)).unwrap();
        let addr = listener.local_addr().unwrap();
        let mut queued = Vec::new();
        loop {
            match TcpStream::connect_timeout(&addr, Duration::from_millis(200)) {
                Ok(stream) => queued.push(stream),
                Err(error) if error.kind() == ErrorKind::TimedOut => {
                    return (addr, listener, queued);
                }
                Err(error) => panic!("filling the accept queue: {error}"),
            }
            assert!(queued.len() < 8192, "the accept queue never filled");
        }
    }

    /// An address that refuses at once: nothing listens there any more.
    fn refusing() -> SocketAddr {
        TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
    }

    #[test]
    fn a_silent_ipv6_route_falls_back_to_ipv4() {
        // api.todoist.com's shape: AAAA records first. The IPv6 ones never
        // answer; the IPv4 one is a working server.
        let (v6, _listener, _queued) = silent("::1");
        let (base, server) = server(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
            0,
            0,
            Duration::ZERO,
        );
        let v4 = base.strip_prefix("http://").unwrap().parse().unwrap();
        let client = Client::with_resolver(base, TIMEOUT, Fixed(vec![v6, v6, v6, v4]));
        let started = Instant::now();
        let reply = client
            .get("/user", "t")
            .unwrap_or_else(|failure| panic!("no fallback: {failure:?}"));
        assert_eq!(reply.status, 200);
        server.join().unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "IPv4 was reached only after {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn a_host_that_never_answers_times_out_at_the_deadline() {
        let (v4, _listener4, _queued4) = silent("127.0.0.1");
        let (v6, _listener6, _queued6) = silent("::1");
        let limit = Duration::from_secs(3);
        let client = Client::with_resolver(
            "http://127.0.0.1:9".to_string(),
            limit,
            Fixed(vec![v6, v4, v6, v4]),
        );
        let started = Instant::now();
        let failure = client.get("/user", "t").unwrap_err();
        assert_eq!(failure.code, "TIMEOUT");
        assert!(
            started.elapsed() < limit + Duration::from_millis(500),
            "the connect outlasted the request's limit: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn a_host_that_refuses_everywhere_is_a_network_failure() {
        let client = Client::with_resolver(
            "http://127.0.0.1:9".to_string(),
            TIMEOUT,
            Fixed(vec![refusing(), refusing()]),
        );
        let started = Instant::now();
        let failure = client.get("/user", "t").unwrap_err();
        assert_eq!(failure.code, "NETWORK");
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn the_address_families_alternate() {
        let v6: SocketAddr = "[2001:db8::1]:443".parse().unwrap();
        let v4: SocketAddr = "192.0.2.1:443".parse().unwrap();
        for (given, expected) in [
            (vec![v6, v6, v4, v4], vec![v6, v4, v6, v4]),
            (vec![v4, v6, v6, v6], vec![v4, v6, v6, v6]),
            (vec![v6, v6], vec![v6, v6]),
            (vec![], vec![]),
        ] {
            assert_eq!(interleave(&given), expected, "{given:?}");
        }
    }
}
