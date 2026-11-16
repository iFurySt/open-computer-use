//go:build windows

package main

import (
	"os/exec"
	"testing"
)

func TestHideConsoleWindowSetsNoWindowFlags(t *testing.T) {
	cmd := exec.Command("powershell.exe")
	hideConsoleWindow(cmd)
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.HideWindow || cmd.SysProcAttr.CreationFlags&createNoWindow == 0 {
		t.Fatalf("SysProcAttr = %#v, want HideWindow and CREATE_NO_WINDOW", cmd.SysProcAttr)
	}
}
