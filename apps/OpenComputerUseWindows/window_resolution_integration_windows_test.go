//go:build windows

package main

import (
	_ "embed"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

//go:embed testdata/modal-fixture.ps1
var modalFixtureScript string

//go:embed testdata/hosted-window-fixture.ps1
var hostedWindowFixtureScript string

func observeWindowFixture(t *testing.T, app string) *appSnapshot {
	t.Helper()
	screenshot := false
	response, err := runPowerShell(psRequest{Tool: "get_app_state", App: app, IncludeScreenshot: &screenshot})
	if err != nil || !response.OK || response.Snapshot == nil {
		t.Fatalf("observe %s: %#v, %v", app, response, err)
	}
	return response.Snapshot
}

func TestRealSecondaryAndNestedModalWindows(t *testing.T) {
	dir, fixture := startWindowsFixture(t, modalFixtureScript)
	var state struct {
		Main, Second, Outer, Inner              int64
		MainEnabled, OuterVisible, InnerVisible bool
		InnerClicks, OuterClicks                int
	}
	read := func() { readWindowsFixtureJSON(t, filepath.Join(dir, "state.json"), &state) }
	wait := func(test func() bool) {
		t.Helper()
		deadline := time.Now().Add(15 * time.Second)
		for {
			read()
			if test() {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("modal fixture state timeout: %+v", state)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	read()
	main := observeWindowFixture(t, "OCU resolution main")
	secondary := observeWindowFixture(t, "OCU resolution secondary")
	if main.WindowHandle != state.Main || secondary.WindowHandle != state.Second || main.WindowHandle == secondary.WindowHandle {
		t.Fatalf("secondary window not resolved: %+v", state)
	}
	if err := os.WriteFile(filepath.Join(dir, "modal"), []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	wait(func() bool { return state.InnerVisible && !state.MainEnabled })
	nested := observeWindowFixture(t, "OCU resolution main")
	if nested.WindowHandle != state.Inner {
		t.Fatalf("nested dialog not root: %d vs %d", nested.WindowHandle, state.Inner)
	}
	click := func(s *appSnapshot, name string) psRequest {
		for _, e := range s.Elements {
			if e.Name == name {
				return psRequest{Tool: "click", App: "OCU resolution main", ExpectedPID: fixture.Process.Pid, WindowHandle: s.WindowHandle, Element: &e, WindowBounds: s.WindowBounds, ClickMethod: "app_post", MouseButton: "left", ClickCount: 1}
			}
		}
		t.Fatalf("missing %s: %#v", name, s.Elements)
		return psRequest{}
	}
	old := click(nested, "Close inner")
	response, err := runPowerShell(old)
	if err != nil || !response.OK {
		t.Fatalf("close inner: %#v %v", response, err)
	}
	wait(func() bool { return state.InnerClicks == 1 && !state.InnerVisible })
	response, err = runPowerShell(old)
	if err != nil || response.OK || !strings.Contains(response.Error, "Target process/window changed") {
		t.Fatalf("stale modal input not refused: %#v %v", response, err)
	}
	outer := observeWindowFixture(t, "OCU resolution main")
	if outer.WindowHandle != state.Outer {
		t.Fatal("outer dialog not restored")
	}
	response, err = runPowerShell(click(outer, "Close outer"))
	if err != nil || !response.OK {
		t.Fatalf("close outer: %#v %v", response, err)
	}
	wait(func() bool { return state.OuterClicks == 1 && state.MainEnabled })
	if observeWindowFixture(t, "OCU resolution main").WindowHandle != state.Main {
		t.Fatal("main window not restored")
	}
}

func TestRealCrossProcessHostedWindowMapping(t *testing.T) {
	source := func(mode string, first, second int64) string {
		return strings.NewReplacer("__MODE__", mode, "__FIRST__", strconv.FormatInt(first, 10), "__SECOND__", strconv.FormatInt(second, 10)).Replace(hostedWindowFixtureScript)
	}
	hostDir, host := startWindowsFixture(t, source("host", 0, 0))
	var hostState, coreState struct {
		First, Second int64
		Keys          int
	}
	readWindowsFixtureJSON(t, filepath.Join(hostDir, "state.json"), &hostState)
	coreDir, core := startWindowsFixture(t, source("core", hostState.First, hostState.Second))
	readWindowsFixtureJSON(t, filepath.Join(coreDir, "state.json"), &coreState)
	hosted := observeWindowFixture(t, strconv.Itoa(core.Process.Pid))
	if hosted.WindowHandle != hostState.First || hosted.App.PID != core.Process.Pid {
		t.Fatalf("frame did not map to content process: %#v", hosted)
	}
	ordinary := observeWindowFixture(t, "OCU ordinary frame")
	if ordinary.WindowHandle != hostState.Second || ordinary.App.PID != host.Process.Pid {
		t.Fatalf("ordinary frame was incorrectly remapped: %#v", ordinary)
	}
	response, err := runPowerShell(psRequest{Tool: "press_key", App: strconv.Itoa(core.Process.Pid), ExpectedPID: core.Process.Pid, WindowHandle: hosted.WindowHandle, Key: "Return", KeyMethod: "auto"})
	if err != nil || response.OK || !strings.Contains(response.Error, "hosted app frame") {
		t.Fatalf("posted input reached host: %#v %v", response, err)
	}
	readWindowsFixtureJSON(t, filepath.Join(hostDir, "state.json"), &hostState)
	readWindowsFixtureJSON(t, filepath.Join(coreDir, "state.json"), &coreState)
	if hostState.Keys != 0 || coreState.Keys != 0 {
		t.Fatal("refused input was delivered")
	}
	// A responsive frame must not conceal a hung content process.
	if err := os.WriteFile(filepath.Join(coreDir, "hang"), []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	var hung bool
	readWindowsFixtureJSON(t, filepath.Join(coreDir, "hung"), &hung)
	screenshot := false
	for _, request := range []psRequest{
		{Tool: "get_app_state", App: strconv.Itoa(core.Process.Pid), IncludeScreenshot: &screenshot},
		{Tool: "press_key", App: strconv.Itoa(core.Process.Pid), ExpectedPID: core.Process.Pid, WindowHandle: hosted.WindowHandle, Key: "Return", KeyMethod: "global"},
	} {
		started := time.Now()
		r, err := runPowerShell(request)
		if err != nil || r.OK || !strings.Contains(r.Error, "not responding") {
			t.Fatalf("hung content %s: %#v, %v", request.Tool, r, err)
		}
		if time.Since(started) > 12*time.Second {
			t.Fatal("hung hosted content did not fail promptly")
		}
	}
	if err := os.WriteFile(filepath.Join(coreDir, "resume"), []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	readWindowsFixtureJSON(t, filepath.Join(coreDir, "resumed"), &hung)
	if observeWindowFixture(t, strconv.Itoa(core.Process.Pid)).WindowHandle != hostState.First {
		t.Fatal("hosted content did not recover")
	}
	readWindowsFixtureJSON(t, filepath.Join(coreDir, "state.json"), &coreState)
	if coreState.Keys != 0 {
		t.Fatal("input was queued while hosted content was hung")
	}
	t.Log("Real EnumWindows/child HWND mapping passed; fixture reproduces hosted topology, not a packaged UWP application.")
}
