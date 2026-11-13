//go:build windows

package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

//go:embed testdata/integrity-fixture.ps1
var integrityFixtureScript string

//go:embed testdata/low-integrity-dispatch.ps1
var lowIntegrityDispatchScript string

func TestRealCrossIntegrityInputIsRefused(t *testing.T) {
	dir, fixture := startWindowsFixture(t, integrityFixtureScript)
	var state struct {
		Keys       int   `json:"keys"`
		Characters int   `json:"characters"`
		HWND       int64 `json:"hwnd"`
	}
	read := func() { readWindowsFixtureJSON(t, filepath.Join(dir, "state.json"), &state) }
	read()
	operation := psRequest{Tool: "press_key", App: strconv.Itoa(fixture.Process.Pid), ExpectedPID: fixture.Process.Pid, WindowHandle: state.HWND, Key: "Return"}
	// Equal-level input is an actual positive control, independently counted by the form.
	response, err := runPowerShell(operation)
	if err != nil || !response.OK {
		t.Fatalf("same-level control: %#v, %v", response, err)
	}
	read()
	if state.Keys != 1 {
		t.Fatalf("same-level key not delivered: %d", state.Keys)
	}
	charactersBefore := state.Characters
	helper := filepath.Join(dir, "low.ps1")
	if err := os.WriteFile(helper, []byte(lowIntegrityDispatchScript), 0600); err != nil {
		t.Fatal(err)
	}
	runtime, err := filepath.Abs("runtime.ps1")
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"auto", "global", "text"} {
		operation.KeyMethod = mode
		if mode == "text" {
			operation.Tool = "type_text"
			operation.Text = "fixture-only"
		}
		data, err := json.Marshal(operation)
		if err != nil {
			t.Fatal(err)
		}
		request := filepath.Join(dir, "request.json")
		if err := os.WriteFile(request, data, 0600); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-File", helper, runtime, request)
		output, err := cmd.CombinedOutput()
		cancel()
		if err != nil {
			t.Fatalf("low child: %v\n%s", err, output)
		}
		var result struct {
			Own, Target int
			Response    psResponse
		}
		if err := json.Unmarshal(output, &result); err != nil {
			t.Fatalf("low child JSON: %v\n%s", err, output)
		}
		if result.Own != 0x1000 || result.Target <= result.Own {
			t.Fatalf("not a cross-integrity test: %+v", result)
		}
		if result.Response.OK || !strings.Contains(result.Response.Error, "runs elevated") {
			t.Fatalf("%s not refused by integrity guard: %+v", mode, result)
		}
		read()
		if state.Keys != 1 || state.Characters != charactersBefore {
			t.Fatalf("%s delivered input to the protected target: %d", mode, state.Keys)
		}
	}
	t.Log("Real low-integrity runtime refused auto/global/text input to higher-integrity fixture; equal-level key delivered once.")
}
