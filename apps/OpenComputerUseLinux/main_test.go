package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestToolDefinitionCount(t *testing.T) {
	if got := len(toolDefinitions()); got != 9 {
		t.Fatalf("toolDefinitions() count = %d, want 9", got)
	}
}

func TestActionReadBackEnabled(t *testing.T) {
	for _, value := range []string{"", "1", "true", "yes", "on", "unexpected"} {
		t.Setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", value)
		if !actionReadBackEnabled() {
			t.Errorf("read-back should be enabled for %q", value)
		}
	}
	for _, value := range []string{"0", "false", "no", "off", " OFF ", "False"} {
		t.Setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", value)
		if actionReadBackEnabled() {
			t.Errorf("read-back should be disabled for %q", value)
		}
	}
}

// Exercise the Go/bridge JSON boundary without requiring a live AT-SPI desktop.
func fakePythonResponse(t *testing.T, response string) string {
	t.Helper()
	dir := t.TempDir()
	requestPath := filepath.Join(dir, "request.json")
	script := "#!/bin/sh\ncat \"$2\" > \"$OCU_TEST_REQUEST\"\nprintf '%s\\n' \"$OCU_TEST_PYTHON_RESPONSE\"\n"
	if err := os.WriteFile(filepath.Join(dir, "python3"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("OCU_TEST_REQUEST", requestPath)
	t.Setenv("OCU_TEST_PYTHON_RESPONSE", response)
	return requestPath
}

func TestActionWithoutReadBackPreservesObservedSnapshot(t *testing.T) {
	t.Setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0")
	requestPath := fakePythonResponse(t, `{"ok":true}`)
	s := newService()
	observed := &appSnapshot{App: appDescriptor{Name: "Editor", PID: 42}, Elements: []elementRecord{{Index: 7}}}
	s.rememberSnapshot("Editor", observed)
	result := s.pressKey("Editor", "Return", "auto")
	if result.IsError || len(result.Content) != 1 || result.Content[0].Text != "ok" {
		t.Fatalf("action result = %#v", result)
	}
	for _, alias := range []string{"Editor", "42"} {
		if s.currentSnapshot(alias) != observed {
			t.Fatalf("action replaced the observed snapshot for %s", alias)
		}
	}
	data, err := os.ReadFile(requestPath)
	if err != nil {
		t.Fatal(err)
	}
	var request linuxRequest
	if err := json.Unmarshal(data, &request); err != nil {
		t.Fatal(err)
	}
	if !request.SkipReadBack || request.Tool != "press_key" || request.Key != "Return" {
		t.Fatalf("bridge request = %#v", request)
	}
}

func TestActionReadBackStillRefreshesSnapshotByDefault(t *testing.T) {
	t.Setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "")
	requestPath := fakePythonResponse(t, `{"ok":true,"snapshot":{"app":{"name":"Editor","pid":42},"treeLines":["updated"],"screenshotPngBase64":"aW1hZ2U="}}`)
	s := newService()
	s.rememberSnapshot("Editor", &appSnapshot{App: appDescriptor{Name: "Editor", PID: 42}})
	result := s.pressKey("Editor", "Return", "auto")
	if result.IsError || len(result.Content) != 2 || result.Content[1].Type != "image" {
		t.Fatalf("default action result = %#v", result)
	}
	if got := s.currentSnapshot("Editor").TreeLines; len(got) != 1 || got[0] != "updated" {
		t.Fatalf("snapshot was not refreshed: %#v", got)
	}
	data, err := os.ReadFile(requestPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "skip_read_back") {
		t.Fatalf("default action unexpectedly requested no read-back: %s", data)
	}
}

func TestReadBackFlagDoesNotSuppressExplicitObservation(t *testing.T) {
	t.Setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0")
	fakePythonResponse(t, `{"ok":true,"snapshot":{"app":{"name":"Editor","pid":42}}}`)
	s := newService()
	_, result := s.refreshSnapshot("Editor", linuxRequest{Tool: "get_app_state", App: "Editor"})
	if result.IsError || s.currentSnapshot("Editor") == nil {
		t.Fatalf("explicit observation failed: %#v", result)
	}
}

func TestActionWithoutReadBackPropagatesBridgeErrors(t *testing.T) {
	for _, response := range []string{`{"ok":false,"error":"input failed"}`, `not json`} {
		t.Run(response, func(t *testing.T) {
			t.Setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0")
			fakePythonResponse(t, response)
			s := newService()
			if result := s.actionResult("Editor", linuxRequest{Tool: "press_key"}); !result.IsError {
				t.Fatalf("bridge failure reported as success: %#v", result)
			}
		})
	}
}

func observationPythonResponse(t *testing.T, response string) string {
	t.Helper()
	dir := t.TempDir()
	requestPath := filepath.Join(dir, "request.json")
	script := "#!/bin/sh\ncat \"$2\" > \"$OCU_TEST_OBSERVATION_REQUEST\"\nprintf '%s\\n' \"$OCU_TEST_OBSERVATION_RESPONSE\"\n"
	if err := os.WriteFile(filepath.Join(dir, "python3"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("OCU_TEST_OBSERVATION_REQUEST", requestPath)
	t.Setenv("OCU_TEST_OBSERVATION_RESPONSE", response)
	return requestPath
}

func TestSelectiveObservationRequestAndDefaultCompatibility(t *testing.T) {
	for _, flags := range []map[string]any{{}, {"include_ax": false}, {"include_screenshot": false}, {"include_ax": true, "include_screenshot": true}} {
		t.Run(fmt.Sprint(flags), func(t *testing.T) {
			path := observationPythonResponse(t, `{"ok":true,"snapshot":{"app":{"name":"Editor","pid":42}}}`)
			args := map[string]any{"app": "Editor"}
			for key, value := range flags {
				args[key] = value
			}
			if result := newService().callTool("get_app_state", args); result.IsError {
				t.Fatalf("observation failed: %#v", result)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var request map[string]any
			if err := json.Unmarshal(data, &request); err != nil {
				t.Fatal(err)
			}
			for _, key := range []string{"include_ax", "include_screenshot"} {
				want, present := flags[key]
				got, sent := request[key]
				if present != sent || got != want {
					t.Fatalf("%s serialized as %#v (%v), want %#v (%v)", key, got, sent, want, present)
				}
			}
		})
	}
}

func TestSelectiveObservationRejectsInvalidOptions(t *testing.T) {
	for _, args := range []map[string]any{
		{"app": "Editor", "include_ax": "false"},
		{"app": "Editor", "include_screenshot": nil},
		{"app": "Editor", "include_ax": false, "include_screenshot": false},
	} {
		if result := newService().callTool("get_app_state", args); !result.IsError {
			t.Fatalf("invalid options accepted: %#v", args)
		}
	}
}

func TestSelectiveObservationSchemaKeepsFullDefaults(t *testing.T) {
	tool := findToolDefinition(t, "get_app_state")
	properties := tool.InputSchema["properties"].(map[string]any)
	for _, name := range []string{"include_ax", "include_screenshot"} {
		property := properties[name].(map[string]any)
		if property["type"] != "boolean" || property["default"] != true {
			t.Fatalf("%s schema = %#v", name, property)
		}
	}
	if required := tool.InputSchema["required"].([]string); len(required) != 1 || required[0] != "app" {
		t.Fatalf("observation options should be optional: %#v", required)
	}
}

func TestScreenshotOnlyInvalidatesIndexesAcrossWindowAndProcessChanges(t *testing.T) {
	for _, pid := range []int{42, 43} {
		t.Run(strconv.Itoa(pid), func(t *testing.T) {
			path := observationPythonResponse(t, fmt.Sprintf(`{"ok":true,"snapshot":{"app":{"name":"Editor","pid":%d},"windowTitle":"New Window","windowBounds":{"width":300,"height":200},"screenshotPngBase64":"cG5n"}}`, pid))
			s := newService()
			old := &appSnapshot{App: appDescriptor{Name: "Editor", PID: 42}, WindowTitle: "Old Window", Elements: []elementRecord{{Index: 7}}}
			s.rememberSnapshot("old-window-query", old)
			s.snapshots["editor"] = old
			other := &appSnapshot{App: appDescriptor{Name: "Other", PID: 99}}
			s.rememberSnapshot("Other", other)
			result := s.callTool("get_app_state", map[string]any{"app": "Editor", "include_ax": false})
			if result.IsError || len(result.Content) != 2 || !strings.Contains(result.Content[0].Text, "indexes invalidated") {
				t.Fatalf("screenshot-only result = %#v", result)
			}
			if s.currentSnapshot("old-window-query") != nil || s.currentSnapshot("Other") != other {
				t.Fatal("old alias retained or unrelated app modified")
			}
			if pid != 42 && s.currentSnapshot("42") != nil {
				t.Fatal("old PID alias retained across process change")
			}
			if _, err := lookupElement(s.currentSnapshot("Editor"), "7"); err == nil {
				t.Fatal("stale index remains usable")
			}
			if result := s.setValue("Editor", "7", "bad"); !result.IsError {
				t.Fatal("stale element action accepted")
			}
			x, y := 10.0, 20.0
			if result := s.click("Editor", "", &x, &y, 1, "left", "auto"); result.IsError {
				t.Fatalf("coordinate action unavailable: %#v", result)
			}
			data, err := os.ReadFile(path)
			if err != nil || !strings.Contains(string(data), `"tool":"click"`) {
				t.Fatalf("coordinate click not sent: %s, %v", data, err)
			}
			t.Setenv("OCU_TEST_OBSERVATION_RESPONSE", fmt.Sprintf(`{"ok":true,"snapshot":{"app":{"name":"Editor","pid":%d},"elements":[{"index":8}]}}`, pid))
			if result := s.callTool("get_app_state", map[string]any{"app": "Editor"}); result.IsError {
				t.Fatalf("AX refresh failed: %#v", result)
			}
			if _, err := lookupElement(s.currentSnapshot("Editor"), "8"); err != nil {
				t.Fatal("explicit AX did not restore indexes")
			}
		})
	}
}

func TestScreenshotOnlyInvalidatesOlderAliasesWhenProcessChanges(t *testing.T) {
	observationPythonResponse(t, `{"ok":true,"snapshot":{"app":{"name":"Editor","pid":43},"windowBounds":{"width":300,"height":200},"screenshotPngBase64":"cG5n"}}`)
	s := newService()
	older := &appSnapshot{App: appDescriptor{Name: "Editor", PID: 42}, Elements: []elementRecord{{Index: 6}}}
	s.rememberSnapshot("older-query", older)
	s.rememberSnapshot("Editor", &appSnapshot{App: appDescriptor{Name: "Editor", PID: 42}, Elements: []elementRecord{{Index: 7}}})
	unrelated := &appSnapshot{App: appDescriptor{Name: "Other", PID: 99}}
	s.rememberSnapshot("Other", unrelated)
	result := s.callTool("get_app_state", map[string]any{"app": "Editor", "include_ax": false})
	if result.IsError {
		t.Fatalf("screenshot-only observation failed: %#v", result)
	}
	for _, alias := range []string{"older-query", "42"} {
		if s.currentSnapshot(alias) != nil {
			t.Fatalf("stale AX alias %q survived process replacement", alias)
		}
	}
	if s.currentSnapshot("Other") != unrelated {
		t.Fatal("unrelated app observation invalidated")
	}
}

func TestClickMethodSchemaAndParser(t *testing.T) {
	tool := findToolDefinition(t, "click")
	properties := tool.InputSchema["properties"].(map[string]any)
	method := properties["click_method"].(map[string]any)
	values := method["enum"].([]string)
	if strings.Join(values, ",") != "auto,accessibility,app_post,sky_click,global" {
		t.Fatalf("click_method enum = %#v", values)
	}

	for input, want := range map[string]string{
		"":              "auto",
		" AUTO ":        "auto",
		"Accessibility": "accessibility",
		"app_post":      "app_post",
		"SKY_CLICK":     "sky_click",
		"GLOBAL":        "global",
	} {
		got, err := parseClickMethod(input)
		if err != nil {
			t.Fatalf("parseClickMethod(%q): %v", input, err)
		}
		if got != want {
			t.Fatalf("parseClickMethod(%q) = %q, want %q", input, got, want)
		}
	}

	for _, input := range []string{"physical", "targeted"} {
		if _, err := parseClickMethod(input); err == nil || !strings.Contains(err.Error(), "Expected one of: auto, accessibility, app_post, sky_click, global") {
			t.Fatalf("parseClickMethod(%s) error = %v", input, err)
		}
	}
}

func TestLinuxClickMethodSafetyAndPlatformSupport(t *testing.T) {
	x, y := 10.0, 20.0
	service := newService()

	result := service.click("Text Editor", "", &x, &y, 1, "left", "app_post")
	if !result.IsError || result.Content[0].Text != "click_method 'app_post' is not supported on Linux" {
		t.Fatalf("app_post click result = %#v", result)
	}

	result = service.click("Text Editor", "", &x, &y, 1, "left", "sky_click")
	if !result.IsError || result.Content[0].Text != "click_method 'sky_click' is not supported on Linux" {
		t.Fatalf("sky_click result = %#v", result)
	}

	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "")
	result = service.click("Text Editor", "", &x, &y, 1, "left", "global")
	if !result.IsError || !strings.Contains(result.Content[0].Text, "requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1") {
		t.Fatalf("unauthorized global click result = %#v", result)
	}

	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "yes")
	if !globalPointerFallbacksEnabled() {
		t.Fatal("global pointer authorization should accept yes")
	}
}

func TestGetAppStateSchemaIncludesTextLimit(t *testing.T) {
	tool := findToolDefinition(t, "get_app_state")
	properties := tool.InputSchema["properties"].(map[string]any)
	if _, ok := properties["show_full_text"]; ok {
		t.Fatal("get_app_state schema should not expose show_full_text")
	}
	textLimit := properties["text_limit"].(map[string]any)
	anyOf := textLimit["anyOf"].([]any)
	integerLimit := anyOf[0].(map[string]any)
	if got := integerLimit["type"]; got != "integer" {
		t.Fatalf("text_limit integer type = %v, want integer", got)
	}
	if got := integerLimit["minimum"]; got != 1 {
		t.Fatalf("text_limit integer minimum = %v, want 1", got)
	}
	maxLimit := anyOf[1].(map[string]any)
	if got := maxLimit["type"]; got != "string" {
		t.Fatalf("text_limit max type = %v, want string", got)
	}
	enum := maxLimit["enum"].([]string)
	if len(enum) != 1 || enum[0] != "max" {
		t.Fatalf("text_limit enum = %#v, want [max]", enum)
	}
	maxTreeNodes := properties["max_tree_nodes"].(map[string]any)
	if got := maxTreeNodes["type"]; got != "integer" {
		t.Fatalf("max_tree_nodes type = %v, want integer", got)
	}
	if got := maxTreeNodes["minimum"]; got != 1 {
		t.Fatalf("max_tree_nodes minimum = %v, want 1", got)
	}
	maxTreeDepth := properties["max_tree_depth"].(map[string]any)
	if got := maxTreeDepth["type"]; got != "integer" {
		t.Fatalf("max_tree_depth type = %v, want integer", got)
	}
	if got := maxTreeDepth["minimum"]; got != 1 {
		t.Fatalf("max_tree_depth minimum = %v, want 1", got)
	}
	required := tool.InputSchema["required"].([]string)
	if len(required) != 1 || required[0] != "app" {
		t.Fatalf("required = %#v, want [app]", required)
	}
}

func TestParseSnapshotArgsSupportsTextLimit(t *testing.T) {
	app, textLimit, maxTreeNodes, maxTreeDepth, err := parseSnapshotArgs([]string{"--text-limit", "1000", "Text Editor"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Text Editor" || textLimit == nil || textLimit.runtimeValue() != 1000 || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs = (%q, %#v, %v, %v), want (Text Editor, 1000, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Text Editor", "--text-limit", "max"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Text Editor" || textLimit == nil || textLimit.runtimeValue() != "max" || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs max = (%q, %#v, %v, %v), want (Text Editor, max, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Text Editor"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Text Editor" || textLimit != nil || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs default = (%q, %#v, %v, %v), want (Text Editor, nil, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"--max-tree-nodes", "3000", "--max-tree-depth", "96", "Text Editor"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Text Editor" || textLimit != nil || maxTreeNodes == nil || *maxTreeNodes != 3000 || maxTreeDepth == nil || *maxTreeDepth != 96 {
		t.Fatalf("parseSnapshotArgs custom tree budget = (%q, %#v, %v, %v), want (Text Editor, nil, 3000, 96)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}
}

func TestParseSnapshotArgsRejectsInvalidTextLimit(t *testing.T) {
	for _, value := range []string{"0", "-1", "1.5", "full"} {
		if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit", value, "Text Editor"}); err == nil || err.Error() != "--text-limit must be a positive integer or max" {
			t.Fatalf("invalid text_limit %q error = %v", value, err)
		}
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit"}); err == nil || err.Error() != "--text-limit requires a positive integer or max value" {
		t.Fatalf("missing text_limit error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--show-full-text", "Text Editor"}); err == nil || err.Error() != "unknown snapshot option: --show-full-text" {
		t.Fatalf("old show_full_text flag error = %v", err)
	}
}

func TestParseSnapshotArgsRejectsInvalidTreeBudget(t *testing.T) {
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes", "0", "Text Editor"}); err == nil || err.Error() != "--max-tree-nodes must be a positive integer" {
		t.Fatalf("invalid max_tree_nodes error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-depth", "1.5", "Text Editor"}); err == nil || err.Error() != "--max-tree-depth must be a positive integer" {
		t.Fatalf("invalid max_tree_depth error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes"}); err == nil || err.Error() != "--max-tree-nodes requires a positive integer value" {
		t.Fatalf("missing max_tree_nodes error = %v", err)
	}
}

func TestCallSequenceStopsAfterFirstToolError(t *testing.T) {
	output, hasError, err := runCallCommand([]string{
		"--calls",
		`[{"tool":"not_a_tool"},{"tool":"list_apps"}]`,
	}, newService())
	if err != nil {
		t.Fatal(err)
	}
	if !hasError {
		t.Fatal("expected hasError")
	}
	items, ok := output.([]map[string]any)
	if !ok {
		t.Fatalf("output type = %T", output)
	}
	if len(items) != 1 {
		t.Fatalf("sequence output count = %d, want 1", len(items))
	}
}

func TestReadArgumentsAcceptsJSONObject(t *testing.T) {
	args, err := readArguments(`{"app":"Text Editor","pages":2}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if args["app"] != "Text Editor" {
		t.Fatalf("app = %v", args["app"])
	}
	if args["pages"].(json.Number).String() != "2" {
		t.Fatalf("pages = %v", args["pages"])
	}
}

func TestElementIndexAcceptsStringAndJSONNumber(t *testing.T) {
	args, err := readArguments(`{"app":"Text Editor","element_index":0}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := optionalElementIndex(args); got != "0" {
		t.Fatalf("numeric element_index = %q, want 0", got)
	}
	if got := optionalElementIndex(map[string]any{"element_index": "14"}); got != "14" {
		t.Fatalf("string element_index = %q, want 14", got)
	}
	if got := optionalElementIndex(map[string]any{"element_index": json.Number("1.5")}); got != "" {
		t.Fatalf("fractional element_index = %q, want empty", got)
	}
}

func TestMCPInitializeResponseContainsToolsCapability(t *testing.T) {
	request := map[string]any{
		"jsonrpc": "2.0",
		"id":      float64(1),
		"method":  "initialize",
		"params":  map[string]any{},
	}
	response := handleMCPRequest(request, newService())
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatalf("missing result: %#v", response)
	}
	capabilities := result["capabilities"].(map[string]any)
	if _, ok := capabilities["tools"]; !ok {
		t.Fatalf("missing tools capability: %#v", capabilities)
	}
}

func TestCLIHelpMentionsLinuxRuntime(t *testing.T) {
	var out bytes.Buffer
	if err := runCLI([]string{"--help"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Open Computer Use for Linux") {
		t.Fatalf("help text did not mention Linux runtime:\n%s", out.String())
	}
}

func TestLinuxRuntimeDocumentsATSPIAndFallbackBoundary(t *testing.T) {
	if !strings.Contains(linuxRuntimeScript, "Atspi") {
		t.Fatal("Linux runtime must use AT-SPI")
	}
	if !strings.Contains(linuxRuntimeScript, "generate_mouse_event") {
		t.Fatal("Linux runtime should keep coordinate input explicit and visible in the bridge")
	}
	if !strings.Contains(serverInstructions, "not a universal Wayland background input model") {
		t.Fatal("MCP instructions must document the Linux background-input boundary")
	}
}

func TestLinuxRuntimeTextLimitSupportsMaxMode(t *testing.T) {
	if !strings.Contains(linuxRuntimeScript, "DEFAULT_TEXT_LIMIT = 500") {
		t.Fatal("Linux runtime should define the shared 500 character text limit")
	}
	if !strings.Contains(linuxRuntimeScript, "text_limit=parse_text_limit(operation.get(\"text_limit\"), DEFAULT_TEXT_LIMIT)") {
		t.Fatal("Linux get_app_state should pass text_limit into snapshot rendering")
	}
	if !strings.Contains(linuxRuntimeScript, "if isinstance(value, str) and value.lower() == \"max\"") {
		t.Fatal("Linux runtime should support max text limit mode")
	}
	if !strings.Contains(linuxRuntimeScript, "max_tree_nodes=positive_int(operation.get(\"max_tree_nodes\"), MAX_ELEMENTS)") {
		t.Fatal("Linux get_app_state should pass max_tree_nodes into snapshot rendering")
	}
	if !strings.Contains(linuxRuntimeScript, "max_tree_depth=positive_int(operation.get(\"max_tree_depth\"), MAX_DEPTH)") {
		t.Fatal("Linux get_app_state should pass max_tree_depth into snapshot rendering")
	}
	if !strings.Contains(linuxRuntimeScript, "text_limit + 1") {
		t.Fatal("Linux default truncation should read one extra character so it can append ellipsis")
	}
}

func TestLinuxRuntimeTreeBudgetDefaultsMatchMacOS(t *testing.T) {
	if !strings.Contains(linuxRuntimeScript, "MAX_ELEMENTS = 1200") {
		t.Fatal("Linux runtime should default to the shared 1200 node tree budget")
	}
	if !strings.Contains(linuxRuntimeScript, "MAX_DEPTH = 64") {
		t.Fatal("Linux runtime should default to the shared 64 level tree depth")
	}
}

func TestLinuxRuntimeEnvironmentDiscoversDesktopSession(t *testing.T) {
	runtimeDir := shortTempDir(t)
	listenUnixSocket(t, filepath.Join(runtimeDir, "bus"))
	listenUnixSocket(t, filepath.Join(runtimeDir, "wayland-0"))

	env := envSliceToMap(linuxRuntimeEnvironmentFrom(
		[]string{"PATH=/usr/bin"},
		os.Getuid(),
		[]map[string]string{{
			"XDG_RUNTIME_DIR":     runtimeDir,
			"DISPLAY":             ":1",
			"XAUTHORITY":          "/tmp/open-computer-use-xauth",
			"XDG_SESSION_TYPE":    "wayland",
			"XDG_CURRENT_DESKTOP": "GNOME",
		}},
	))

	if got := env["XDG_RUNTIME_DIR"]; got != runtimeDir {
		t.Fatalf("XDG_RUNTIME_DIR = %q, want %q", got, runtimeDir)
	}
	if got, want := env["DBUS_SESSION_BUS_ADDRESS"], "unix:path="+filepath.Join(runtimeDir, "bus"); got != want {
		t.Fatalf("DBUS_SESSION_BUS_ADDRESS = %q, want %q", got, want)
	}
	if got := env["WAYLAND_DISPLAY"]; got != "wayland-0" {
		t.Fatalf("WAYLAND_DISPLAY = %q, want wayland-0", got)
	}
	if got := env["DISPLAY"]; got != ":1" {
		t.Fatalf("DISPLAY = %q, want :1", got)
	}
	if got := env["XDG_CURRENT_DESKTOP"]; got != "GNOME" {
		t.Fatalf("XDG_CURRENT_DESKTOP = %q, want GNOME", got)
	}
}

func TestLinuxRuntimeEnvironmentCanonicalizesRuntimeBus(t *testing.T) {
	runtimeDir := shortTempDir(t)
	listenUnixSocket(t, filepath.Join(runtimeDir, "bus"))

	env := envSliceToMap(linuxRuntimeEnvironmentFrom(
		[]string{
			"XDG_RUNTIME_DIR=" + runtimeDir,
			"DBUS_SESSION_BUS_ADDRESS=unix:path=" + filepath.Join(runtimeDir, "bus") + ",guid=stale",
		},
		os.Getuid(),
		nil,
	))

	if got, want := env["DBUS_SESSION_BUS_ADDRESS"], "unix:path="+filepath.Join(runtimeDir, "bus"); got != want {
		t.Fatalf("DBUS_SESSION_BUS_ADDRESS = %q, want %q", got, want)
	}
}

func listenUnixSocket(t *testing.T, path string) {
	t.Helper()
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen unix socket %s: %v", path, err)
	}
	t.Cleanup(func() {
		_ = listener.Close()
		_ = os.Remove(path)
	})
}

func findToolDefinition(t *testing.T, name string) toolDefinition {
	t.Helper()
	for _, tool := range toolDefinitions() {
		if tool.Name == name {
			return tool
		}
	}
	t.Fatalf("missing tool definition %q", name)
	return toolDefinition{}
}

func shortTempDir(t *testing.T) string {
	t.Helper()
	path, err := os.MkdirTemp("/tmp", "ocu-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(path)
	})
	return path
}

func TestLinuxKeyMethodSchemaAndUnsupportedSkyKey(t *testing.T) {
	for _, name := range []string{"type_text", "press_key"} {
		tool := findToolDefinition(t, name)
		properties := tool.InputSchema["properties"].(map[string]any)
		method := properties["key_method"].(map[string]any)
		values := method["enum"].([]string)
		if strings.Join(values, ",") != "auto,sky_key" {
			t.Fatalf("%s key_method enum = %#v", name, values)
		}
	}

	for input, want := range map[string]string{"": "auto", " SKY_KEY ": "sky_key"} {
		got, err := parseKeyMethod(input)
		if err != nil || got != want {
			t.Fatalf("parseKeyMethod(%q) = %q, %v", input, got, err)
		}
	}
	if _, err := parseKeyMethod("global"); err == nil || !strings.Contains(err.Error(), "Expected one of: auto, sky_key") {
		t.Fatalf("parseKeyMethod(global) error = %v", err)
	}

	service := newService()
	result := service.typeText("Text Editor", "hello", "sky_key")
	if !result.IsError || result.Content[0].Text != "key_method 'sky_key' is not supported on Linux" {
		t.Fatalf("type_text sky_key result = %#v", result)
	}
	result = service.pressKey("Text Editor", "Return", "sky_key")
	if !result.IsError || result.Content[0].Text != "key_method 'sky_key' is not supported on Linux" {
		t.Fatalf("press_key sky_key result = %#v", result)
	}
}

func TestLinuxWindowPlacementSchemaAndUnsupportedAgentDisplay(t *testing.T) {
	tool := findToolDefinition(t, "get_app_state")
	properties := tool.InputSchema["properties"].(map[string]any)
	if _, exposed := properties["window_placement"]; exposed {
		t.Fatal("unsupported window_placement must not be advertised")
	}

	if got, err := parseWindowPlacement(" AGENT_DISPLAY "); err != nil || got != "agent_display" {
		t.Fatalf("parseWindowPlacement = %q, %v", got, err)
	}
	if _, err := parseWindowPlacement("park"); err == nil {
		t.Fatal("parseWindowPlacement(park) should fail")
	}
	result := newService().callTool("get_app_state", map[string]any{"app": "Text Editor", "window_placement": "agent_display"})
	if !result.IsError || result.Content[0].Text != "window_placement 'agent_display' is not supported on Linux" {
		t.Fatalf("agent_display result = %#v", result)
	}
}

func TestDoctorJSONRejectsUnsupportedPermissionDiagnostics(t *testing.T) {
	var out bytes.Buffer
	if err := runCLI([]string{"doctor", "--json"}, &out); err == nil {
		t.Fatal("expected unsupported permission diagnostics error")
	}
	if out.Len() != 0 {
		t.Fatal("unsupported JSON mode must not emit text on stdout")
	}
}
