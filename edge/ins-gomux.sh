#!/bin/bash
###############################################################################
# gomux edge installer for aaa-main
#
#   :80   raw SSH -> 22 | HTTP payload -> router
#   :443  raw SSH -> 22 | plain HTTP -> router
#         TLS(any SNI) -> SSH -> 22, else router
#   router: /dropbear-ws -> 2095,
#           everything else -> ws-stunnel (700)
#
# The Go source is embedded below and built on the VPS. The build happens
# BEFORE anything is stopped, so a failed build leaves the old edge untouched.
###############################################################################

set -e

red='\033[0;31m'; green='\033[0;32m'; blue='\033[0;34m'; NC='\033[0m'

echo -e "${blue}[*] Installing gomux edge layer${NC}"

if [ ! -f /etc/aaa/server.crt ] || [ ! -f /etc/aaa/server.key ]; then
    echo -e "${red}[-] Error: /etc/aaa/server.crt or server.key not found${NC}"
    exit 1
fi

# ---- Go source embedded in this script (edge/gomux.go), built locally on the VPS ----
BUILD_DIR=/tmp/gomux-build
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/gomux.go" <<'GOEOF'
// gomux - Go edge multiplexer for aaa-main (ports 80 and 443).
//
//   :80   raw SSH            -> 22
//         HTTP payload       -> router (below)
//   :443  raw SSH            -> 22
//         plain HTTP         -> router
//         TLS (any SNI)      -> TLS terminate -> SSH- -> 22, else router
//
//   router:
//         " /dropbear-ws"                                -> ws-dropbear (2095)
//         everything else                                -> ws-stunnel  (700)
//
// Build:  go mod init gomux && go build -ldflags "-s -w" -o gomux .
// Test on other ports:  ./gomux -http :9080 -tls :9443
// Normal run uses the defaults (:80 / :443).

package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"path/filepath"
	"sync"
	"strings"
	"time"
)

var (
	sshAddr     = "127.0.0.1:22"
	stunnelAddr = "127.0.0.1:700"
	dbwsAddr    = "127.0.0.1:2095"


	tlsCfg *tls.Config

	// Let's Encrypt HTTP-01 webroot (files are written by acme.sh; gomux only serves them)
	acmeRoot = "/var/www/acme"
)

// ---------------------------------------------------------------- helpers

// bconn: a connection whose first bytes can be peeked without being lost.
type bconn struct {
	net.Conn
	r *bufio.Reader
}

func newB(c net.Conn) *bconn { return &bconn{Conn: c, r: bufio.NewReaderSize(c, 16384)} }

func (b *bconn) Read(p []byte) (int, error) { return b.r.Read(p) }

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

type kind int

const (
	kUnknown kind = iota // nothing arrived within 2s
	kTLS
	kSSH
	kHTTP // anything else (first line / first packet in data)
)

// classify peeks at the first bytes (waits up to 2s for the client).
func classify(b *bconn, allowTLS bool) (kind, []byte, error) {
	b.SetReadDeadline(time.Now().Add(2 * time.Second))
	defer b.SetReadDeadline(time.Time{})

	first, err := b.r.Peek(1)
	if err != nil {
		if isTimeout(err) {
			return kUnknown, nil, nil
		}
		return kUnknown, nil, err
	}
	if allowTLS && first[0] == 0x16 {
		return kTLS, nil, nil
	}
	head, _ := b.r.Peek(7)
	if string(head) == "SSH-2.0" {
		return kSSH, nil, nil
	}
	// wait for the end of the first line (or timeout / 8 KB)
	for {
		n := b.r.Buffered()
		data, _ := b.r.Peek(n)
		if bytes.IndexByte(data, '\n') >= 0 || n >= 8192 {
			return kHTTP, data, nil
		}
		if _, err := b.r.Peek(n + 1); err != nil {
			return kHTTP, data, nil
		}
	}
}

// ---------------------------------------------------------------- Let's Encrypt support
// gomux is the only component that touches the certificate:
//  - it answers HTTP-01 challenges on :80 from acmeRoot (no downtime, nothing stops)
//  - it hot-reloads the certificate files, so a renewal needs no restart

const acmePrefix = "/.well-known/acme-challenge/"

func isACME(data []byte) bool {
	return bytes.HasPrefix(data, []byte("GET "+acmePrefix))
}

func serveACME(c net.Conn, data []byte) {
	defer c.Close()
	line := data
	if i := bytes.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	f := strings.Fields(string(line)) // GET /path HTTP/1.1
	body := []byte(nil)
	if len(f) >= 2 && strings.HasPrefix(f[1], acmePrefix) {
		tok := strings.TrimPrefix(f[1], acmePrefix)
		ok := len(tok) > 0 && len(tok) <= 256
		for _, r := range tok {
			if !(r == '-' || r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')) {
				ok = false
			}
		}
		if ok {
			body, _ = os.ReadFile(filepath.Join(acmeRoot, acmePrefix, tok))
		}
	}
	if body == nil {
		c.Write([]byte("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
		return
	}
	c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " + strconv.Itoa(len(body)) + "\r\nConnection: close\r\n\r\n"))
	c.Write(body)
}

type certStore struct {
	mu        sync.Mutex
	crt, key  string
	cert      *tls.Certificate
	mtime     time.Time
	lastCheck time.Time
}

func (s *certStore) load() error {
	st, err := os.Stat(s.crt)
	if err != nil {
		return err
	}
	c, err := tls.LoadX509KeyPair(s.crt, s.key)
	if err != nil {
		return err
	}
	s.cert, s.mtime = &c, st.ModTime()
	return nil
}

// get is used as tls.Config.GetCertificate; it re-checks the file at most every 30s.
func (s *certStore) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.lastCheck) > 30*time.Second {
		s.lastCheck = time.Now()
		if st, err := os.Stat(s.crt); err == nil && !st.ModTime().Equal(s.mtime) {
			if err := s.load(); err != nil {
				log.Println("cert reload:", err) // keep serving the old one
			} else {
				log.Println("cert reloaded")
			}
		}
	}
	return s.cert, nil
}

func relay(c net.Conn, addr string) {
	d, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		log.Println("dial", addr, err)
		c.Close()
		return
	}
	done := make(chan struct{}, 2)
	go func() { io.Copy(d, c); done <- struct{}{} }()
	go func() { io.Copy(c, d); done <- struct{}{} }()
	<-done
	c.Close()
	d.Close()
}

// router decides where an HTTP payload goes (ws-dropbear, ws-stunnel).
func router(c net.Conn, k kind, data []byte) {
	switch {
	case k == kSSH:
		relay(c, sshAddr)
	case k == kHTTP && isACME(data):
		serveACME(c, data)
	case k == kHTTP && bytes.Contains(bytes.ToLower(data), []byte(" /dropbear-ws")):
		relay(c, dbwsAddr)
	default:
		relay(c, stunnelAddr)
	}
}

// ---------------------------------------------------------------- entry points

func handle80(c net.Conn) {
	b := newB(c)
	k, data, err := classify(b, false)
	if err != nil {
		c.Close()
		return
	}
	router(b, k, data)
}

func handle443(c net.Conn) {
	b := newB(c)
	k, data, err := classify(b, true)
	if err != nil {
		c.Close()
		return
	}
	switch k {
	case kSSH:
		relay(b, sshAddr)
	case kHTTP:
		router(b, k, data)
	case kTLS:
		handleTLS(b)
	default:
		c.Close()
	}
}

// handleTLS terminates TLS: the decrypted stream is classified again.
func handleTLS(b *bconn) {
	tc := tls.Server(b, tlsCfg)
	tc.SetDeadline(time.Now().Add(10 * time.Second))
	if err := tc.Handshake(); err != nil {
		tc.Close()
		return
	}
	tc.SetDeadline(time.Time{})

	nb := newB(tc)
	k, data, err := classify(nb, false)
	if err != nil {
		tc.Close()
		return
	}
	router(nb, k, data)
}

func listen(addr string, h func(net.Conn)) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Println("listening on", addr)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Println(err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go h(c)
	}
}

func main() {
	httpAddr := flag.String("http", ":80", "cleartext listen address")
	tlsAddr := flag.String("tls", ":443", "TLS listen address")
	certFile := flag.String("cert", "/etc/aaa/server.crt", "TLS certificate")
	keyFile := flag.String("key", "/etc/aaa/server.key", "TLS private key")
	flag.StringVar(&acmeRoot, "acme-root", acmeRoot, "webroot for Let's Encrypt HTTP-01 challenges")
	flag.StringVar(&sshAddr, "ssh", sshAddr, "OpenSSH target")
	flag.StringVar(&stunnelAddr, "stunnel", stunnelAddr, "ws-stunnel target (default route)")
	flag.StringVar(&dbwsAddr, "dbws", dbwsAddr, "ws-dropbear target (/dropbear-ws)")
	flag.Parse()

	store := &certStore{crt: *certFile, key: *keyFile}
	if err := store.load(); err != nil {
		log.Fatal("cert: ", err)
	}
	store.lastCheck = time.Now()
	tlsCfg = &tls.Config{
		GetCertificate: store.get,
		MinVersion:     tls.VersionTLS10,
	}

	go listen(*httpAddr, handle80)
	listen(*tlsAddr, handle443)
}
GOEOF

GO_OK=0

# ---- Go compiler: tarball hosted in the GitHub release (assets) (no apt, no fallback) ----
# Intel/AMD (x86_64)
GO_TGZ_URL_AMD64="https://github.com/noelrubio143/sshonly/releases/download/assets/go1.27.2.linux-amd64.tar.gz"
GO_TGZ_SHA256_AMD64="ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5"   # sha256 of go1.27.2.linux-amd64.tar.gz (https://go.dev/dl/) - REQUIRED
# ARM (aarch64)
GO_TGZ_URL_ARM64="https://github.com/noelrubio143/sshonly/releases/download/assets/go1.27.2.linux-arm64.tar.gz"
GO_TGZ_SHA256_ARM64="94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8"   # sha256 of go1.27.2.linux-arm64.tar.gz - REQUIRED for ARM
GO_TMP=/tmp/go-toolchain

go_fail() {
    echo -e "${red}[x] $1 Nothing was changed.${NC}"
    rm -rf "$GO_TMP" "$BUILD_DIR" /tmp/gocache /tmp/gopath
    exit 1
}

case "$(uname -m)" in
    x86_64)        GO_TGZ_URL="$GO_TGZ_URL_AMD64"; GO_TGZ_SHA256="$GO_TGZ_SHA256_AMD64" ;;
    aarch64|arm64) GO_TGZ_URL="$GO_TGZ_URL_ARM64"; GO_TGZ_SHA256="$GO_TGZ_SHA256_ARM64" ;;
    *) go_fail "Unsupported CPU: $(uname -m) (only x86_64 and aarch64)." ;;
esac
[ -n "$GO_TGZ_URL" ] || go_fail "Go tarball URL is empty for $(uname -m) - set it in this script."
[ -n "$GO_TGZ_SHA256" ] || go_fail "Go tarball sha256 is empty for $(uname -m) - set it in this script."

rm -rf "$GO_TMP"; mkdir -p "$GO_TMP"
wget -q -O "$GO_TMP/go.tgz" "$GO_TGZ_URL" || go_fail "Cannot download the Go tarball from GitHub."
echo "$GO_TGZ_SHA256  $GO_TMP/go.tgz" | sha256sum -c - >/dev/null 2>&1 || go_fail "Go tarball sha256 mismatch - refusing to use it."
tar -C "$GO_TMP" -xzf "$GO_TMP/go.tgz" || go_fail "Cannot extract the Go tarball."
GO_BIN="$GO_TMP/go/bin/go"
[ -x "$GO_BIN" ] || go_fail "go binary not found inside the tarball."

# go.mod build (works on every Go version; GOPATH mode is not needed)
export HOME=/root GOCACHE=/tmp/gocache GOPATH=/tmp/gopath GOTOOLCHAIN=local GOPROXY=off GO111MODULE=on CGO_ENABLED=0
if (cd "$BUILD_DIR" && "$GO_BIN" mod init wsgo >/dev/null 2>&1 \
    && "$GO_BIN" build -ldflags "-s -w" -o gomux .); then
    GO_OK=1
fi
# the toolchain is only needed for the build
rm -rf "$GO_TMP" /tmp/gocache /tmp/gopath

if [ "$GO_OK" != "1" ]; then
    echo -e "${red}[-] gomux build failed. Old edge layer (if any) was NOT touched.${NC}"
    rm -rf "$BUILD_DIR" /tmp/gocache /tmp/gopath
    exit 1
fi
echo -e "${green}[+] gomux built${NC}"

systemctl stop gomux 2>/dev/null || true

# webroot that gomux serves for Let's Encrypt HTTP-01 challenges (written by acme.sh / m-ssl)
mkdir -p /var/www/acme/.well-known/acme-challenge
chmod -R 755 /var/www/acme

install -m 755 "$BUILD_DIR/gomux" /usr/local/bin/gomux
rm -rf "$BUILD_DIR" /tmp/gocache /tmp/gopath

cat > /etc/systemd/system/gomux.service <<'EOF'
[Unit]
Description=gomux edge layer (80/443 multiplexer)
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gomux
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gomux >/dev/null 2>&1 || true
sleep 1

if systemctl is-active --quiet gomux; then
    echo -e "${green}[+] gomux is running${NC}"
else
    echo -e "${red}[-] gomux failed to start - check: journalctl -u gomux -e${NC}"
    systemctl status gomux --no-pager || true
    exit 1
fi

echo -e "${blue}[*] Architecture Summary:${NC}"
echo -e "    Port 80/443 (gomux)"
echo -e "      ├─ SSH detection  -> OpenSSH (22)"
echo -e "      ├─ /dropbear-ws   -> ws-dropbear (2095)"
echo -e "      ├─ /.well-known/acme-challenge/ -> Let's Encrypt webroot (m-ssl)"
echo -e "      └─ everything else -> ws-stunnel (700)"
