package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"sync"
)

// Read independently of the serial tool dispatcher: cancellation must not wait
// for the action it cancels. A running action finishes once; it is never replayed.
type mcpPending struct {
	request   map[string]any
	key       string
	malformed bool
}

type mcpRequests struct {
	cond      *sync.Cond
	waiting   []mcpPending
	running   string
	cancelled bool
	ended     bool
	readErr   error
}

func newMCPRequests(stdin io.Reader) *mcpRequests {
	q := &mcpRequests{cond: sync.NewCond(&sync.Mutex{})}
	go func() {
		scanner := bufio.NewScanner(stdin)
		scanner.Buffer(make([]byte, 4096), 16*1024*1024)
		for scanner.Scan() {
			line := bytes.TrimSpace(scanner.Bytes())
			if len(line) == 0 {
				continue
			}
			var request map[string]any
			decoder := json.NewDecoder(bytes.NewReader(line))
			decoder.UseNumber()
			err := decoder.Decode(&request)
			var extra any
			malformed := err != nil || request == nil || decoder.Decode(&extra) != io.EOF
			q.add(mcpPending{request: request, malformed: malformed})
		}
		q.cond.L.Lock()
		q.ended, q.readErr = true, scanner.Err()
		q.cond.Broadcast()
		q.cond.L.Unlock()
	}()
	return q
}

func mcpRequestKey(id any) string {
	switch v := id.(type) {
	case string:
		return "s:" + v
	case json.Number:
		return "n:" + string(v)
	default:
		return ""
	}
}

func (q *mcpRequests) add(p mcpPending) {
	q.cond.L.Lock()
	defer q.cond.L.Unlock()
	method, _ := p.request["method"].(string)
	_, hasID := p.request["id"]
	if !p.malformed && method == "notifications/cancelled" && !hasID {
		if p.request["jsonrpc"] != "2.0" {
			return
		}
		params, _ := p.request["params"].(map[string]any)
		key := mcpRequestKey(params["requestId"])
		if key == "" {
			return
		}
		for i, pending := range q.waiting {
			if pending.key == key {
				copy(q.waiting[i:], q.waiting[i+1:])
				q.waiting[len(q.waiting)-1] = mcpPending{}
				q.waiting = q.waiting[:len(q.waiting)-1]
				return
			}
		}
		if key == q.running {
			q.cancelled = true
		}
		return
	}
	if !p.malformed && method != "initialize" {
		p.key = mcpRequestKey(p.request["id"])
	}
	q.waiting = append(q.waiting, p)
	q.cond.Signal()
}

func (q *mcpRequests) next() (mcpPending, bool) {
	q.cond.L.Lock()
	defer q.cond.L.Unlock()
	for len(q.waiting) == 0 && !q.ended {
		q.cond.Wait()
	}
	if len(q.waiting) == 0 {
		return mcpPending{}, false
	}
	p := q.waiting[0]
	q.waiting[0] = mcpPending{}
	q.waiting = q.waiting[1:]
	q.running, q.cancelled = p.key, false
	return p, true
}

func (q *mcpRequests) finish() bool {
	q.cond.L.Lock()
	defer q.cond.L.Unlock()
	q.running = ""
	return !q.cancelled
}

func runMCPTransport(stdin io.Reader, stdout io.Writer, handle func(map[string]any) map[string]any) error {
	q := newMCPRequests(stdin)
	encoder := json.NewEncoder(stdout)
	for {
		p, ok := q.next()
		if !ok {
			return q.readErr
		}
		var response map[string]any
		if p.malformed {
			response = jsonRPCError(nil, -32700, "Invalid JSON-RPC payload")
		} else {
			response = handle(p.request)
		}
		if q.finish() && response != nil {
			if err := encoder.Encode(response); err != nil {
				return err
			}
		}
	}
}
