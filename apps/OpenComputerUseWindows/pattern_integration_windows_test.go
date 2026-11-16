//go:build windows

package main

import (
	_ "embed"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

//go:embed testdata/pattern-fixture.ps1
var patternFixtureScript string

func TestRealPatternActionsVerifyStateWithoutResending(t *testing.T) {
	dir, fixture := startWindowsFixture(t, patternFixtureScript)
	type value struct {
		Value bool `json:"value"`
		Calls int  `json:"calls"`
	}
	state := map[string]value{}
	read := func() { readWindowsFixtureJSON(t, filepath.Join(dir, "state.json"), &state) }
	read()
	screenshot := false
	observe := psRequest{Tool: "get_app_state", App: strconv.Itoa(fixture.Process.Pid), IncludeScreenshot: &screenshot}
	find := func(name string) (*elementRecord, int64) {
		response, err := runPowerShell(observe)
		if err != nil || !response.OK || response.Snapshot == nil {
			t.Fatalf("observe: %#v, %v", response, err)
		}
		for _, element := range response.Snapshot.Elements {
			if element.AutomationID == name {
				return &element, response.Snapshot.WindowHandle
			}
		}
		t.Fatalf("missing %s in %#v", name, response.Snapshot.Elements)
		return nil, 0
	}
	act := func(name, tool, action string, want bool) {
		t.Helper()
		element, window := find(name)
		read()
		before := state[name]
		response, err := runPowerShell(psRequest{Tool: tool, App: observe.App, ExpectedPID: fixture.Process.Pid, WindowHandle: window, Element: element, Action: action, ClickMethod: "accessibility", ClickCount: 1, MouseButton: "left"})
		if err != nil || response.OK != want {
			t.Fatalf("%s %s: %#v, %v", name, action, response, err)
		}
		if !want && !strings.Contains(response.Error, "could not be verified") {
			t.Fatalf("unexpected refusal: %s", response.Error)
		}
		read()
		if state[name].Calls != before.Calls+1 {
			t.Fatalf("%s was resent: before=%#v after=%#v", name, before, state[name])
		}
		if want && state[name].Value != (action != "collapse") {
			t.Fatalf("%s state mismatch: %#v", name, state[name])
		}
		if !want && state[name].Value != before.Value {
			t.Fatalf("ignored action changed state: %s", name)
		}
	}
	for _, mode := range []string{"normal", "ignore"} {
		want := mode == "normal"
		act("toggle_"+mode, "click", "", want)
		act("select_"+mode, "click", "", want)
		act("disclosure_"+mode, "perform_secondary_action", "expand", want)
	}
	act("disclosure_normal", "perform_secondary_action", "collapse", true)
	// Already-selected is still a valid idempotent request, and is sent only once.
	act("select_normal", "perform_secondary_action", "select", true)
}
