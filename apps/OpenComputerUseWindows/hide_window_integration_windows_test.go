//go:build windows

package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Exercise the production launch path from the same kind of console-less parent
// used by desktop MCP hosts. No real application receives input.
func TestPowerShellFromDetachedParent(t *testing.T) {
	const helperEnv = "OCU_TEST_DETACHED_POWERSHELL"
	if os.Getenv(helperEnv) != "1" {
		executable, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, executable, "-test.run=^TestPowerShellFromDetachedParent$", "-test.v")
		cmd.Env = append(os.Environ(), helperEnv+"=1")
		const detachedProcess = 0x00000008
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: detachedProcess}
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("detached process: %v\n%s", err, output)
		}
		t.Logf("detached process checks:\n%s", output)
		return
	}

	getConsoleWindow := syscall.NewLazyDLL("kernel32.dll").NewProc("GetConsoleWindow")
	window, _, _ := getConsoleWindow.Call()
	if window != 0 {
		t.Fatalf("test parent has a console window: %x", window)
	}

	// Replace only the embedded script in this isolated test process. The actual
	// request files, PowerShell process flags, pipes and response parser are used.
	original := windowsRuntimeScript
	t.Cleanup(func() { windowsRuntimeScript = original })
	windowsRuntimeScript = `param([string]$OperationPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$request = [IO.File]::ReadAllText($OperationPath) | ConvertFrom-Json
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleProbe {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
'@
if ([ConsoleProbe]::GetConsoleWindow() -ne [IntPtr]::Zero) {
    [Console]::Error.WriteLine('unexpected console window')
    exit 9
}
if ($request.text -eq 'fail') {
    [Console]::Error.WriteLine('ocu-test-stderr')
    exit 7
}
@{ ok = $true; text = $request.text } | ConvertTo-Json -Compress
`
	for i := 0; i < 2; i++ {
		const message = "console-free pipes: 中文 π"
		response, err := runPowerShell(psRequest{Tool: "list_apps", Text: message})
		if err != nil {
			t.Fatalf("probe %d: %v", i, err)
		}
		if !response.OK || response.Text != message {
			t.Fatalf("probe %d: unexpected response %#v", i, response)
		}
	}
	if _, err := runPowerShell(psRequest{Tool: "list_apps", Text: "fail"}); err == nil || !strings.Contains(err.Error(), "ocu-test-stderr") {
		t.Fatalf("missing stderr/exit failure: %v", err)
	}

	// Also run the unmodified runtime, so the console fix is exercised alongside
	// its real PowerShell initialization and read-only desktop inventory.
	windowsRuntimeScript = original
	response, err := runPowerShell(psRequest{Tool: "list_apps"})
	if err != nil {
		t.Fatal(err)
	}
	if !response.OK {
		t.Fatalf("real runtime rejected list_apps: %s", response.Error)
	}
}
