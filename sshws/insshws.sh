#!/bin/bash
# WS-Stunnel + WS-Dropbear setup (SSL/SNI + path routing handled by gomux)

set -e
clear
cd

echo "========================================="
echo "Installing WS-Stunnel + WS-Dropbear"
echo "========================================="

# ========== PART 1: Install WS-Stunnel & WS-SSH ==========


echo "[1/6] Installing WS-Stunnel & WS-Dropbear (Go)..."

# ---- Go source embedded in this script (sshws/main.go), built locally on the VPS ----
BUILD_DIR=/tmp/wsgo-build
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/main.go" <<'GOEOF'
// ws-dropbear (Go) - WebSocket/HTTP(101) -> TCP proxy
// Same behavior as the Python ws-dropbear in aaa-main:
//   - reads the first packet (HTTP payload), answers 101, relays to target
//   - X-Real-Host header selects the target (default 127.0.0.1:22)
//   - X-Split: reads one more packet and discards it
//   - PASS empty: only 127.0.0.1 / localhost targets allowed (else 403)
//   - PASS set: X-Pass header must match (else 400 WrongPass!)
//   - idle timeout 180s (Python: 60 x 3s)
//   - listens on bind:port, port can be positional ("ws-dropbear 2095") or -p
//
// Build:  GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o ws-dropbear .
// Usage:  ws-dropbear 2095
//         ws-dropbear -b 0.0.0.0 -p 2095 -t 127.0.0.1:22

package main

import (
	"bytes"
	"errors"
	"flag"
	"log"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	bufLen      = 4096 * 4
	idleTimeout = 180 * time.Second
	pass        = "" // X-Pass password (empty = only localhost targets allowed)
	response    = "HTTP/1.1 101 Switching Protocols\r\nContent-Length: 104857600000\r\n\r\n"
)

var defaultHost = "127.0.0.1:22"

// findHeader returns the value of "Name: value\r\n", or "" if missing.
func findHeader(head []byte, name string) string {
	s := string(head)
	i := strings.Index(s, name+": ")
	if i == -1 {
		return ""
	}
	s = s[i+len(name)+2:]
	j := strings.Index(s, "\r\n")
	if j == -1 {
		return ""
	}
	return s[:j]
}

// isLocalTarget: true only if the host part is exactly "localhost" or a
// loopback IP (127.0.0.0/8, ::1). Prefix matching let hosts like
// "127.0.0.1.1.2.3.4.nip.io" through (open proxy).
func isLocalTarget(hostPort string) bool {
	host := hostPort
	if h, _, err := net.SplitHostPort(hostPort); err == nil {
		host = h
	} else {
		host = strings.Trim(hostPort, "[]")
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// pipe copies src -> dst. Idle time is tracked across BOTH directions
// (shared "last"), so a download with a quiet upload is not cut.
func pipe(dst, src net.Conn, last *int64, done chan<- struct{}) {
	defer func() { done <- struct{}{} }()
	buf := make([]byte, bufLen)
	for {
		src.SetReadDeadline(time.Now().Add(5 * time.Second))
		n, err := src.Read(buf)
		if n > 0 {
			atomic.StoreInt64(last, time.Now().UnixNano())
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			if isTimeout(err) {
				idle := time.Since(time.Unix(0, atomic.LoadInt64(last)))
				if idle < idleTimeout {
					continue
				}
			}
			return
		}
	}
}

func handle(c net.Conn) {
	defer c.Close()

	c.SetReadDeadline(time.Now().Add(15 * time.Second))
	buf := make([]byte, bufLen)
	n, err := c.Read(buf)
	if err != nil {
		return
	}
	first := buf[:n]

	hostPort := findHeader(first, "X-Real-Host")
	if hostPort == "" {
		hostPort = defaultHost
	}

	if findHeader(first, "X-Split") != "" {
		c.Read(buf) // discard the second packet, like the Python version
	}

	if pass != "" {
		if findHeader(first, "X-Pass") != pass {
			c.Write([]byte("HTTP/1.1 400 WrongPass!\r\n\r\n"))
			return
		}
	} else if !isLocalTarget(hostPort) {
		c.Write([]byte("HTTP/1.1 403 Forbidden!\r\n\r\n"))
		return
	}

	if !strings.Contains(hostPort, ":") {
		hostPort += ":443" // Python default
	}

	d, err := net.DialTimeout("tcp", hostPort, 10*time.Second)
	if err != nil {
		log.Println("dial", hostPort, err)
		return
	}
	defer d.Close()

	if bytes.HasPrefix(first, []byte("SSH-")) {
		// Client sent SSH directly (no HTTP payload): pass it through.
		d.Write(first)
	} else if _, err := c.Write([]byte(response)); err != nil {
		return
	}
	c.SetReadDeadline(time.Time{})

	var last int64
	atomic.StoreInt64(&last, time.Now().UnixNano())
	done := make(chan struct{}, 2)
	go pipe(d, c, &last, done)
	go pipe(c, d, &last, done)
	<-done // either side ended -> defers close both
}

func main() {
	bind := flag.String("b", "0.0.0.0", "bind address")
	port := flag.Int("p", 2095, "listen port")
	flag.StringVar(&defaultHost, "t", defaultHost, "default target host:port (used when no X-Real-Host)")
	flag.Parse()

	// positional port, e.g. "ws-dropbear 2095" (as used by ws-dropbear.service)
	if flag.NArg() > 0 {
		p, err := strconv.Atoi(flag.Arg(0))
		if err != nil {
			log.Fatal("invalid port: ", flag.Arg(0))
		}
		*port = p
	}

	addr := net.JoinHostPort(*bind, strconv.Itoa(*port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	defer ln.Close()
	log.Printf("ws-dropbear listening on %s (default target %s)", addr, defaultHost)

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Println(err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go handle(c)
	}
}
GOEOF

GO_OK=0

# ---- Go compiler: tarball hosted in the gitlab project (no apt, no fallback) ----
# Intel/AMD (x86_64)
GO_TGZ_URL_AMD64="https://gitlab.com/-/project/84844354/uploads/8b4f7af1af02f10a2c8d3792379bdcbc/go1.27.2.linux-amd64.tar.gz"
GO_TGZ_SHA256_AMD64="ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5"   # sha256 of go1.27.2.linux-amd64.tar.gz (https://go.dev/dl/) - REQUIRED
# ARM (aarch64)
GO_TGZ_URL_ARM64="https://gitlab.com/-/project/84844354/uploads/b399eb6ba478e9cd3f1ab2321b521380/go1.27.2.linux-arm64.tar.gz"
GO_TGZ_SHA256_ARM64="94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8"   # sha256 of go1.27.2.linux-arm64.tar.gz - REQUIRED for ARM
GO_TMP=/tmp/go-toolchain

go_fail() {
    echo "[ ERROR ] $1"
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
wget -q -O "$GO_TMP/go.tgz" "$GO_TGZ_URL" || go_fail "Cannot download the Go tarball from gitlab."
echo "$GO_TGZ_SHA256  $GO_TMP/go.tgz" | sha256sum -c - >/dev/null 2>&1 || go_fail "Go tarball sha256 mismatch - refusing to use it."
tar -C "$GO_TMP" -xzf "$GO_TMP/go.tgz" || go_fail "Cannot extract the Go tarball."
GO_BIN="$GO_TMP/go/bin/go"
[ -x "$GO_BIN" ] || go_fail "go binary not found inside the tarball."

# go.mod build (works on every Go version; GOPATH mode is not needed)
export HOME=/root GOCACHE=/tmp/gocache GOPATH=/tmp/gopath GOTOOLCHAIN=local GOPROXY=off GO111MODULE=on CGO_ENABLED=0
if (cd "$BUILD_DIR" && "$GO_BIN" mod init wsgo >/dev/null 2>&1 \
    && "$GO_BIN" build -ldflags "-s -w" -o ws-go .); then
    GO_OK=1
fi
# the toolchain is only needed for the build
rm -rf "$GO_TMP" /tmp/gocache /tmp/gopath

if [ "$GO_OK" != "1" ]; then
    echo "[ ERROR ] Go build failed (see the error above)."
    exit 1
fi

echo "[ OK ] Go proxy built"
systemctl stop ws-dropbear ws-stunnel 2>/dev/null || true
install -m 755 "$BUILD_DIR/ws-go" /usr/local/bin/ws-dropbear
install -m 755 "$BUILD_DIR/ws-go" /usr/local/bin/ws-stunnel
DROP_EXEC="/usr/local/bin/ws-dropbear 2095"
STUN_EXEC="/usr/local/bin/ws-stunnel -b 127.0.0.1 -p 700"

rm -rf "$BUILD_DIR" /tmp/gocache /tmp/gopath

# ---- systemd services (non-TLS ws-dropbear :2095, ws-stunnel :700) ----
cat > /etc/systemd/system/ws-dropbear.service <<EOF
[Unit]
Description=Websocket-Dropbear
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$DROP_EXEC
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ws-stunnel.service <<EOF
[Unit]
Description=SSH Over Websocket
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
ExecStart=$STUN_EXEC

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

#Diagnostic script
wget -O /usr/local/bin/check-sshws.sh https://gitlab.com/babayega143/sshonly/-/raw/main/sshws/check-sshws.sh
chmod +x /usr/local/bin/check-sshws.sh

# ========== PART 3: Start services ==========

echo "[5/6] Enabling and starting services..."
systemctl enable --now ws-dropbear >/dev/null 2>&1 || echo "[!] ws-dropbear failed to start - check: journalctl -u ws-dropbear -e"
systemctl enable --now ws-stunnel >/dev/null 2>&1  || echo "[!] ws-stunnel failed to start - check: journalctl -u ws-stunnel -e"

# ========== PART 4: Start All Services ==========

echo "[6/6] Starting services..."
systemctl daemon-reload


sleep 2

# ========== Verification ==========

echo ""
echo "========================================="
echo "✅ Installation Complete!"
echo "========================================="
echo ""
echo "Services:"
for svc in ws-dropbear ws-stunnel gomux; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        if systemctl is-active --quiet "$svc"; then
            echo "  ✓ $svc: RUNNING"
        else
            echo "  ✗ $svc: FAILED"
        fi
    fi
done

echo ""
echo "Ports:"
ss -tlnp 2>/dev/null | grep -E ":(80|443|2095|700)" || echo "  (checking...)"


echo ""
echo "Full diagnostic:"
echo "  bash /usr/local/bin/check-sshws.sh"
echo ""
