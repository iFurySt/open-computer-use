//go:build !windows

package main

import "os/exec"

func hideConsoleWindow(cmd *exec.Cmd) {}
