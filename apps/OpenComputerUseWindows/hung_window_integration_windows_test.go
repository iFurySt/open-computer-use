//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The fixture stops its actual UI message pump until the test releases it.
// Requests use the production PowerShell bridge, not Win32/UIA doubles.
func TestHungWindowRefusesInputAndRecovers(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "fixture.ps1")
	source := `param([string]$Directory)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;
public class HangFixture : Form {
 public string DirectoryPath;
 public int Keys;
 public HangFixture() { Text="OCU hung window fixture"; Width=500; Height=300; }
 protected override void WndProc(ref Message m) {
  if (m.Msg == 0x100) { Keys++; File.WriteAllText(Path.Combine(DirectoryPath,"keys"),Keys.ToString()); }
  base.WndProc(ref m);
 }
}
'@
$form=New-Object HangFixture
$form.DirectoryPath=$Directory
$timer=New-Object Windows.Forms.Timer
$timer.Interval=50
$timer.Add_Tick({
 if ((Test-Path (Join-Path $Directory 'hang')) -and -not (Test-Path (Join-Path $Directory 'resumed'))) {
  [IO.File]::WriteAllText((Join-Path $Directory 'hung'),'1')
  while (-not (Test-Path (Join-Path $Directory 'resume'))) { [Threading.Thread]::Sleep(50) }
  [IO.File]::WriteAllText((Join-Path $Directory 'resumed'),'1')
 }
})
$form.Add_Shown({
 [IO.File]::WriteAllText((Join-Path $Directory 'keys'),'0')
 [IO.File]::WriteAllText((Join-Path $Directory 'ready'),(@{pid=$PID;hwnd=$form.Handle.ToInt64()}|ConvertTo-Json -Compress))
})
$timer.Start()
try { [Windows.Forms.Application]::Run($form) } finally { $timer.Dispose();$form.Dispose() }
`
	if err := os.WriteFile(script, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	fixture := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", script, dir)
	fixture.Stdout = &output
	fixture.Stderr = &output
	if err := fixture.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.WriteFile(filepath.Join(dir, "resume"), []byte("1"), 0600)
		_ = fixture.Process.Kill()
		_ = fixture.Wait()
		if t.Failed() {
			t.Log(output.String())
		}
	})
	waitFile := func(name string) []byte {
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			data, err := os.ReadFile(filepath.Join(dir, name))
			if err == nil && len(data) > 0 {
				return data
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatalf("fixture did not write %s", name)
		return nil
	}
	var state struct {
		PID  int   `json:"pid"`
		HWND int64 `json:"hwnd"`
	}
	if err := json.Unmarshal(waitFile("ready"), &state); err != nil {
		t.Fatal(err)
	}
	screenshot := false
	observe := psRequest{Tool: "get_app_state", App: strconv.Itoa(state.PID), IncludeScreenshot: &screenshot}
	key := psRequest{Tool: "press_key", App: strconv.Itoa(state.PID), ExpectedPID: state.PID, WindowHandle: state.HWND, Key: "Return"}
	response, err := runPowerShell(observe)
	if err != nil || !response.OK {
		t.Fatalf("responsive fixture: %#v, %v", response, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "hang"), []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	waitFile("hung")
	for _, request := range []psRequest{observe, key} {
		start := time.Now()
		response, err := runPowerShell(request)
		elapsed := time.Since(start)
		if err != nil || response.OK || !strings.Contains(response.Error, "not responding") {
			t.Fatalf("hung %s: %#v, %v", request.Tool, response, err)
		}
		if elapsed > 12*time.Second {
			t.Fatalf("hung %s took %s (includes PowerShell startup)", request.Tool, elapsed)
		}
		t.Logf("hung %s refused in %s", request.Tool, elapsed)
	}
	if err := os.WriteFile(filepath.Join(dir, "resume"), []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	waitFile("resumed")
	time.Sleep(300 * time.Millisecond)
	if value := strings.TrimSpace(string(waitFile("keys"))); value != "0" {
		t.Fatalf("queued input arrived after recovery: %s", value)
	}
	response, err = runPowerShell(observe)
	if err != nil || !response.OK {
		t.Fatalf("recovered observation: %#v, %v", response, err)
	}
	response, err = runPowerShell(key)
	if err != nil || !response.OK {
		t.Fatalf("recovered input: %#v, %v", response, err)
	}
	if value := strings.TrimSpace(string(waitFile("keys"))); value != "1" {
		t.Fatalf("positive-control input count: %s", value)
	}
}
