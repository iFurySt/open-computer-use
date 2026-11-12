//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// createNoWindow is the CREATE_NO_WINDOW process creation flag. Without it a
// console child (powershell.exe) of a parent that has no console, such as an
// MCP server started with DETACHED_PROCESS, gets a new visible console that
// briefly takes the foreground.
const createNoWindow = 0x08000000

func hideConsoleWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}
