package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The properties worth holding are the ones whose breakage is silent: a key
// that crosses when it should not, an operation that is forwarded when it
// should be refused, and a substitution that reads as an extra device.

func TestGetIsForwardedAndTheKeysAreExact(t *testing.T) {
	for _, tc := range []struct {
		name string
		body []string
		ok   bool
	}{
		{"get", []string{"get=1"}, true},
		{"get with extra keys", []string{"get=1", "public_key=aa"}, false},
		{"issue a device", []string{"set=1", "public_key=aa", "replace_allowed_ips=true", "allowed_ip=10.9.0.2/32"}, true},
		{"revoke a device", []string{"set=1", "public_key=aa", "remove=true"}, true},
		{"nothing at all", []string{}, false},
		{"not an operation", []string{"quit=1"}, false},
		{"a line that is not key=value", []string{"set=1", "garbage"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validate(tc.body)
			if tc.ok && err != nil {
				t.Fatalf("expected forwarded, refused with: %v", err)
			}
			if !tc.ok && err == nil {
				t.Fatal("expected refused, was forwarded")
			}
		})
	}
}

func TestTheFourWaysToTakeTheTunnelAwayAreRefusedByName(t *testing.T) {
	// Each of these is a single call that either revokes everyone or changes
	// what every already-issued config points at. The test asserts the message
	// names the key, because "invalid request" sends the reader nowhere.
	for key, body := range map[string][]string{
		"replace_peers": {"set=1", "replace_peers=true"},
		"private_key":   {"set=1", "private_key=" + strings.Repeat("a", 64)},
		"listen_port":   {"set=1", "listen_port=51821"},
		"fwmark":        {"set=1", "fwmark=1"},
	} {
		err := validate(body)
		if err == nil {
			t.Fatalf("%s was forwarded", key)
		}
		if !strings.Contains(err.Error(), key) {
			t.Fatalf("%s refused without naming itself: %v", key, err)
		}
	}
}

func TestThePrivateKeyIsSwappedForThePublicHalfAndNotReadAsAPeer(t *testing.T) {
	const pub = "7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13"
	reply := "private_key=" + strings.Repeat("1", 64) + "\n" +
		"listen_port=31820\n" +
		"public_key=" + strings.Repeat("a", 64) + "\n" +
		"allowed_ip=10.9.0.2/32\n" +
		"errno=0\n"

	out := substitutePublicKey(reply, pub)

	if strings.Contains(out, "private_key=") {
		t.Fatal("the private key survived into the reply")
	}
	if !strings.Contains(out, "interface_public_key="+pub) {
		t.Fatalf("the public half is not there: %q", out)
	}
	// One `public_key=` line, the real peer. A second would be a device nobody
	// holds appearing in every listing.
	if n := strings.Count(out, "\npublic_key="); n != 1 {
		t.Fatalf("expected exactly one peer line, got %d: %q", n, out)
	}
	if !strings.Contains(out, "listen_port=31820") || !strings.Contains(out, "errno=0") {
		t.Fatal("the rest of the reply must pass through unchanged")
	}
}

func TestARequestStopsAtTheBlankLineAndIsBounded(t *testing.T) {
	lines, err := readRequest(strings.NewReader("bearer=t\nget=1\n\nSHOULD NOT BE READ\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 || lines[0] != "bearer=t" || lines[1] != "get=1" {
		t.Fatalf("stopped in the wrong place: %q", lines)
	}

	// A listener that reads unbounded input is a memory exhaustion primitive.
	flood := strings.Repeat("set=1\n", maxLines+10)
	if _, err := readRequest(strings.NewReader(flood)); err == nil {
		t.Fatal("an unbounded request was accepted")
	}
}

func TestTheBearerIsCheckedAndNeverReachesTheDaemon(t *testing.T) {
	// NOT t.TempDir(): a unix socket path is capped at about 104 bytes on
	// macOS and 108 on Linux, and Go's per-test temp directory is long enough
	// to blow that, failing with a bare "bind: invalid argument" that says
	// nothing about length.
	sock := filepath.Join(os.TempDir(), fmt.Sprintf("uapi-t%d.sock", os.Getpid()))
	_ = os.Remove(sock)
	defer os.Remove(sock)
	seen := make(chan string, 1)

	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		buf := make([]byte, 4096)
		n, _ := c.Read(buf)
		seen <- string(buf[:n])
		_, _ = c.Write([]byte("private_key=" + strings.Repeat("1", 64) + "\nerrno=0\n"))
	}()

	cfg := config{uapiSocket: sock, token: "correct-horse", pubKeyHex: strings.Repeat("b", 64)}

	// Wrong bearer: refused, and the daemon is never dialled.
	client, server := net.Pipe()
	go func() {
		_, _ = client.Write([]byte("bearer=wrong\nget=1\n\n"))
	}()
	if err := serve(server, cfg); err == nil {
		t.Fatal("a wrong bearer was accepted")
	}
	_ = client.Close()
	_ = server.Close()

	// Right bearer: forwarded, and what the daemon received carries no bearer.
	client2, server2 := net.Pipe()
	go func() {
		_, _ = client2.Write([]byte("bearer=correct-horse\nget=1\n\n"))
		buf := make([]byte, 4096)
		_, _ = client2.Read(buf)
		_ = client2.Close()
	}()
	if err := serve(server2, cfg); err != nil {
		t.Fatalf("the right bearer was refused: %v", err)
	}

	select {
	case got := <-seen:
		if strings.Contains(got, "bearer") {
			t.Fatalf("the bearer reached the daemon: %q", got)
		}
		if !strings.Contains(got, "get=1") {
			t.Fatalf("the operation did not reach the daemon: %q", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the daemon was never dialled")
	}
}

func TestAnEmptyBearerFileIsRefusedRatherThanAuthenticatingEveryone(t *testing.T) {
	dir := t.TempDir()
	tok := filepath.Join(dir, "token")
	if err := os.WriteFile(tok, []byte("   \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PROXY_TOKEN_FILE", tok)
	t.Setenv("UAPI_SOCKET", "/tmp/x.sock")
	t.Setenv("SERVER_PUBKEY_B64", "e06NCbvn/kTEZaIgA31gjuNYl9Me+XLwf3SJLLD3PxM=")

	if _, err := loadConfig(); err == nil {
		t.Fatal("an empty bearer was accepted")
	}
}

func TestAMissingServerPublicKeyIsRefusedBecauseThePrivateOneWouldHaveToCross(t *testing.T) {
	dir := t.TempDir()
	tok := filepath.Join(dir, "token")
	if err := os.WriteFile(tok, []byte("t"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PROXY_TOKEN_FILE", tok)
	t.Setenv("UAPI_SOCKET", "/tmp/x.sock")
	t.Setenv("SERVER_PUBKEY_B64", "")

	if _, err := loadConfig(); err == nil {
		t.Fatal("a proxy with no public key to substitute was accepted")
	}
}
