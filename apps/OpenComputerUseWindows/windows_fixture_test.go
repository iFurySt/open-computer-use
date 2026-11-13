//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func startWindowsFixture(t *testing.T, source string) (string, *exec.Cmd) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "fixture.ps1")
	if err := os.WriteFile(script, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	cmd := exec.Command("powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", script, dir)
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		if t.Failed() {
			t.Log(output.String())
		}
	})
	return dir, cmd
}

func readWindowsFixtureJSON(t *testing.T, path string, value any) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(path); err == nil && json.Unmarshal(data, value) == nil {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("fixture state unavailable: %s", filepath.Base(path))
}
