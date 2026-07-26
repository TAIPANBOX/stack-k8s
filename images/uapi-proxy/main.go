// uapi-proxy: the console's way to a WireGuard daemon that is not in its pod.
//
// # WHY THIS EXISTS
//
// The console manages peers over the WireGuard userspace API, which is a unix
// socket. A unix socket cannot cross a pod boundary, so without this the
// daemon has to share the console's pod, and the daemon needs CAP_NET_ADMIN
// and a /dev/net/tun hostPath, so that pod is privileged, so it cannot live in
// a namespace enforcing PodSecurity `restricted`. Everything that costs is
// downstream of one sentence. See stack-k8s/tunnel/DESIGN-uapi-transport.md.
//
// # WHY IT IS NOT socat
//
// The relay this replaces is one socat line, and socat can even do mTLS
// natively. It cannot look inside the protocol, and three of the four things
// below are decisions about content:
//
//  1. authenticate the caller
//  2. never let the server's PRIVATE key cross a network
//  3. refuse operations the console has no business sending
//  4. forward the rest unchanged
//
// The socat line it replaces carried a comment predicting this: "the forwarder
// is a place a future version can log or restrict what crosses it".
//
// # WHY A FILE RATHER THAN A HEREDOC
//
// wg.Dockerfile writes its entrypoint inline "so the image is one
// self-contained artifact". That is right for a shell script. This guards the
// root of the tunnel, so it gets tests, and tests need a file that `go test`
// can see.
package main

import (
	"bufio"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"time"
)

// A UAPI exchange is local I/O against a live daemon: it answers at once or
// something is wrong. A hung read here would hang a console request.
const ioTimeout = 5 * time.Second

// A request is a handful of short lines. Anything larger is not a request this
// proxy should be forwarding, and reading it unbounded is how a listener
// becomes a memory exhaustion primitive.
const (
	maxLines   = 64
	maxLineLen = 4096
)

// What a `set=1` may carry. Everything else is refused rather than ignored,
// because a key this proxy does not understand is a key it cannot reason about.
var allowedSetKeys = map[string]bool{
	"public_key":          true, // which peer
	"replace_allowed_ips": true, // scoped to THIS peer, makes re-issue idempotent
	"allowed_ip":          true, // the tunnel address being granted
	"remove":              true, // revocation
	"protocol_version":    true, // the daemon echoes it; harmless and sometimes sent
}

// Refused by name so the error can say which one, rather than "unknown key".
// Each of these is a way to take the tunnel away from everyone at once, or to
// change what every already-issued config points at.
var refusedKeys = map[string]string{
	"replace_peers": "would revoke every issued device in one call",
	"private_key":   "would rotate the server identity, stranding every issued config",
	"listen_port":   "would move the port every issued config names",
	"fwmark":        "would change routing for traffic this proxy does not own",
}

type config struct {
	listen     string
	certFile   string
	keyFile    string
	token      string
	uapiSocket string
	// The interface's public key in lowercase hex, derived once by whoever
	// started this from `wg show <iface> public-key`. Substituted for the
	// private key the daemon reports, so the private half never crosses.
	pubKeyHex string
}

func main() {
	log.SetFlags(0)
	log.SetPrefix(">> uapi-proxy: ")

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("!! %v", err)
	}

	cert, err := tls.LoadX509KeyPair(cfg.certFile, cfg.keyFile)
	if err != nil {
		log.Fatalf("!! certificate: %v", err)
	}
	// TLS 1.3 only. Both ends are ours and shipped together, so there is no
	// old client to accommodate and no reason to offer a weaker suite.
	ln, err := tls.Listen("tcp", cfg.listen, &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	})
	if err != nil {
		log.Fatalf("!! listen %s: %v", cfg.listen, err)
	}
	log.Printf("listening on %s, forwarding to %s", cfg.listen, cfg.uapiSocket)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("!! accept: %v", err)
			continue
		}
		go func() {
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(ioTimeout))
			if err := serve(conn, cfg); err != nil {
				// Nothing was asked, so there is nothing to refuse and nobody
				// to tell. A Kubernetes readiness probe opens this port every
				// few seconds forever and says nothing; logging that as a
				// refusal put ten identical lines a minute in front of every
				// real one, which is how a log stops being read.
				if errors.Is(err, errNothingSaid) {
					return
				}
				// The caller gets the same shape a daemon refusal has, so a
				// client parsing UAPI does not also need to parse prose.
				fmt.Fprintf(conn, "errno=1\n\n")
				log.Printf("refused: %v", err)
			}
		}()
	}
}

func loadConfig() (config, error) {
	c := config{
		listen:     env("PROXY_LISTEN", ":9090"),
		certFile:   env("PROXY_CERT", "/etc/wg-proxy/tls.crt"),
		keyFile:    env("PROXY_KEY", "/etc/wg-proxy/tls.key"),
		uapiSocket: env("UAPI_SOCKET", ""),
	}
	tokenFile := env("PROXY_TOKEN_FILE", "/etc/wg-proxy/token")
	raw, err := os.ReadFile(tokenFile)
	if err != nil {
		return c, fmt.Errorf("cannot read the bearer at %s: %w", tokenFile, err)
	}
	c.token = strings.TrimSpace(string(raw))
	if c.token == "" {
		return c, fmt.Errorf("%s is empty: an empty bearer would authenticate everyone", tokenFile)
	}
	if c.uapiSocket == "" {
		return c, errors.New("UAPI_SOCKET is not set, so there is nothing to forward to")
	}
	// Supplied in the base64 `wg show` prints; the wire wants lowercase hex.
	b64 := strings.TrimSpace(os.Getenv("SERVER_PUBKEY_B64"))
	if b64 == "" {
		return c, errors.New(
			"SERVER_PUBKEY_B64 is not set. Without it the private key would have to cross " +
				"the network for the console to derive the server identity, which is the one " +
				"thing this proxy exists to prevent")
	}
	raw2, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw2) != 32 {
		return c, fmt.Errorf("SERVER_PUBKEY_B64 is not a 32-byte base64 key: %q", b64)
	}
	c.pubKeyHex = hex.EncodeToString(raw2)
	return c, nil
}

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

// serve handles one exchange: authenticate, validate, forward, transform.
func serve(conn net.Conn, cfg config) error {
	lines, err := readRequest(conn)
	if err != nil {
		return err
	}
	// readRequest turns this into errNothingSaid, which the accept loop drops
	// without a word. Kept so a future change there cannot make an empty
	// request fall through into the bearer check below with no lines to read.
	if len(lines) == 0 {
		return errNothingSaid
	}

	// The bearer comes first, on its own line, and never reaches the daemon.
	head := lines[0]
	presented, ok := strings.CutPrefix(head, "bearer=")
	if !ok {
		return errors.New("first line is not a bearer")
	}
	// Constant time: a length-varying compare on a secret is a timing oracle,
	// and this one is reachable by anything that can open a connection.
	if subtle.ConstantTimeCompare([]byte(presented), []byte(cfg.token)) != 1 {
		return errors.New("bearer rejected")
	}

	body := lines[1:]
	if err := validate(body); err != nil {
		return err
	}

	reply, err := forward(cfg.uapiSocket, body)
	if err != nil {
		return err
	}
	_, err = io.WriteString(conn, substitutePublicKey(reply, cfg.pubKeyHex))
	return err
}

// errNothingSaid marks a connection that opened and closed without sending a
// single byte. That is what a TCP health check is, and what a connect-scan is,
// and neither is a refusal: no operation was attempted, so none was denied.
//
// The trade is deliberate. A bare connect from an unauthorised source goes
// unlogged, and what actually keeps such a source away is the NetworkPolicy in
// front of this port, not a line in this file. What is bought is a log where
// every "refused" is a real attempt to do something.
var errNothingSaid = errors.New("connection opened and said nothing")

// readRequest reads UAPI lines up to the blank line that terminates an
// operation. Bounded in both directions: this is a listener, and an unbounded
// read on a listener is a denial of service waiting to be found.
func readRequest(r io.Reader) ([]string, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 1024), maxLineLen)
	var out []string
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" {
			// A bare terminator with no operation before it: the caller spoke
			// the protocol and asked for nothing. Same rule as a silent
			// connection, so the rule stays one rule rather than two that can
			// drift: nothing attempted, nothing to log.
			if len(out) == 0 {
				return nil, errNothingSaid
			}
			return out, nil
		}
		out = append(out, line)
		if len(out) > maxLines {
			return nil, fmt.Errorf("more than %d lines, which no UAPI operation needs", maxLines)
		}
	}
	// A read error before a single line arrived is the same event as a clean
	// close before a single line arrived: a probe that resets rather than
	// closes gets here instead of below, and it is no more a refusal.
	if err := sc.Err(); err != nil {
		if len(out) == 0 {
			return nil, errNothingSaid
		}
		return nil, fmt.Errorf("read: %w", err)
	}
	if len(out) == 0 {
		return nil, errNothingSaid
	}
	// EOF without a blank line: the caller went away mid-request.
	return out, nil
}

// validate refuses anything outside the two operations the console performs.
func validate(body []string) error {
	if len(body) == 0 {
		return errors.New("no operation")
	}
	switch body[0] {
	case "get=1":
		if len(body) > 1 {
			return errors.New("get=1 takes no further keys")
		}
		return nil
	case "set=1":
		for _, line := range body[1:] {
			key, _, ok := strings.Cut(line, "=")
			if !ok {
				return fmt.Errorf("not a key=value line: %q", line)
			}
			if why, refused := refusedKeys[key]; refused {
				return fmt.Errorf("%s is refused here: it %s", key, why)
			}
			if !allowedSetKeys[key] {
				return fmt.Errorf("%s is not a key this proxy forwards", key)
			}
		}
		return nil
	default:
		return fmt.Errorf("%q is not an operation this proxy forwards", body[0])
	}
}

// forward runs the validated operation against the real UAPI socket.
func forward(socket string, body []string) (string, error) {
	c, err := net.DialTimeout("unix", socket, ioTimeout)
	if err != nil {
		return "", fmt.Errorf("dial %s: %w", socket, err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(ioTimeout))

	if _, err := io.WriteString(c, strings.Join(body, "\n")+"\n\n"); err != nil {
		return "", fmt.Errorf("write to daemon: %w", err)
	}
	// Half-close, because the daemon reads an operation until the peer stops
	// writing. Without this it waits and the read below times out instead of
	// returning the reply that was never sent.
	if u, ok := c.(*net.UnixConn); ok {
		_ = u.CloseWrite()
	}
	out, err := io.ReadAll(c)
	if err != nil {
		return "", fmt.Errorf("read from daemon: %w", err)
	}
	return string(out), nil
}

// substitutePublicKey replaces the line carrying the interface's private key
// with one carrying its public half.
//
// A plain strip would be wrong, and not obviously: the daemon reports ONLY its
// private key and never its public one, so the console derives the public half
// and puts it in every client config. Remove the line and every issued config
// names no server. Rename it to `public_key` and it is read as the start of a
// peer, so every listing grows a device nobody holds.
func substitutePublicKey(reply, pubKeyHex string) string {
	lines := strings.Split(reply, "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "private_key=") {
			lines[i] = "interface_public_key=" + pubKeyHex
		}
	}
	return strings.Join(lines, "\n")
}
