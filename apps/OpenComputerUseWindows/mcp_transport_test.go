package main

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"
)

func TestMCPNotificationsDoNotDispatch(t *testing.T) {
	svc := newService()
	for _, method := range []string{"notifications/initialized", "notifications/cancelled", "notifications/unknown", "tools/call", "ping", "initialize"} {
		if got := handleMCPRequest(map[string]any{"jsonrpc": "2.0", "method": method}, svc); got != nil {
			t.Fatalf("notification %s answered: %v", method, got)
		}
	}
}

func waitMCPEnd(t *testing.T, q *mcpRequests) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		q.cond.L.Lock()
		ended := q.ended
		q.cond.L.Unlock()
		if ended {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("reader did not reach EOF")
}

func TestMCPCancellationQueueAndRunning(t *testing.T) {
	r, w := io.Pipe()
	defer r.Close()
	defer w.Close()
	q := newMCPRequests(r)
	first := make(chan struct{})
	go func() {
		_, _ = io.WriteString(w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}\n")
		close(first)
	}()
	p, ok := q.next()
	if !ok || p.key != "n:1" {
		t.Fatal(p, ok)
	}
	<-first
	_, err := io.WriteString(w, `{"jsonrpc":"2.0","id":"1","method":"tools/call"}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"1"}}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":999}}
{"jsonrpc":"2.0","id":2,"method":"ping"}
`)
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	waitMCPEnd(t, q)
	if q.finish() {
		t.Fatal("running result was not suppressed")
	}
	p, ok = q.next()
	if !ok || p.key != "n:2" {
		t.Fatalf("cancelled queued request survived: %+v", p)
	}
	if !q.finish() {
		t.Fatal("unrelated request cancelled")
	}
	if _, ok = q.next(); ok {
		t.Fatal("unexpected request")
	}
}

func TestMCPCancellationProtectsInitializeAndIgnoresMalformed(t *testing.T) {
	q := newMCPRequests(strings.NewReader(`{"jsonrpc":"2.0","id":0,"method":"initialize"}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":0}}
{"jsonrpc":"2.0","id":1,"method":"ping"}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":true}}
{"method":"notifications/cancelled","params":{"requestId":1}}
{"jsonrpc":"2.0","id":2,"method":"notifications/cancelled","params":{"requestId":1}}
`))
	waitMCPEnd(t, q)
	for _, method := range []string{"initialize", "ping", "notifications/cancelled"} {
		p, ok := q.next()
		if !ok || p.request["method"] != method {
			t.Fatal(p, method)
		}
		if !q.finish() {
			t.Fatal("invalid cancellation took effect")
		}
	}
	if _, ok := q.next(); ok {
		t.Fatal("unexpected request")
	}
}

func TestMCPTransportRecoversAfterMalformedLine(t *testing.T) {
	var output bytes.Buffer
	input := "{broken\n" + `{"jsonrpc":"2.0","method":"unknown"}` + "\n" + `{"jsonrpc":"2.0","id":9007199254740993,"method":"ping"}` + "\n"
	if err := runMCP(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatal(output.String())
	}
	if !strings.Contains(lines[0], "-32700") || !strings.Contains(lines[1], "9007199254740993") {
		t.Fatal(output.String())
	}
}

func TestMCPCancelledTransportDoesNotReplayOrExecuteQueuedAction(t *testing.T) {
	r, w := io.Pipe()
	defer r.Close()
	defer w.Close()
	var output bytes.Buffer
	started, release, done := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	var executed []string
	go func() {
		done <- runMCPTransport(r, &output, func(p map[string]any) map[string]any {
			id := p["id"].(string)
			executed = append(executed, id)
			if id == "running" {
				close(started)
				<-release
			}
			return jsonRPCResult(id, map[string]any{})
		})
	}()
	_, _ = io.WriteString(w, "{\"jsonrpc\":\"2.0\",\"id\":\"running\",\"method\":\"tools/call\"}\n")
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("dispatcher did not start")
	}
	// Feed cancellation while dispatch is blocked. A final barrier line ensures
	// both cancellations have been consumed before the running call can finish.
	_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":"queued","method":"tools/call"}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"queued"}}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"running"}}
`)
	_, _ = io.WriteString(w, "{\"jsonrpc\":\"2.0\",\"id\":\"after\",\"method\":\"ping\"}\n")
	close(release)
	w.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("transport did not stop")
	}
	if strings.Join(executed, ",") != "running,after" {
		t.Fatal(executed)
	}
	var response map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(output.Bytes()), &response); err != nil {
		t.Fatal(output.String(), err)
	}
	if response["id"] != "after" {
		t.Fatal(response)
	}
}
