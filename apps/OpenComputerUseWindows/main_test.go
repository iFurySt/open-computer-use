package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"strings"
	"testing"
)

func TestToolDefinitionCount(t *testing.T) {
	if got := len(toolDefinitions()); got != 9 {
		t.Fatalf("toolDefinitions() count = %d, want 9", got)
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

func TestWindowsGlobalClickRequiresGlobalPointerFallbackOptIn(t *testing.T) {
	x, y := 10.0, 20.0
	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "")
	result := newService().click("Notepad", "", &x, &y, 1, "left", "global")
	if !result.IsError || !strings.Contains(result.Content[0].Text, "requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1") {
		t.Fatalf("unauthorized global click result = %#v", result)
	}

	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "yes")
	if !globalPointerFallbacksEnabled() {
		t.Fatal("global pointer authorization should accept yes")
	}
	result = newService().click("Notepad", "", &x, &y, 1, "left", "global")
	if !result.IsError || !strings.Contains(result.Content[0].Text, "No app state is available") {
		t.Fatalf("authorized global click result = %#v", result)
	}
}

func TestScrollRequestIncludesWindowBounds(t *testing.T) {
	svc := newService()
	svc.snapshots["fixture"] = &appSnapshot{
		App:          appDescriptor{Name: "fixture", PID: 42},
		WindowBounds: &frame{X: 100, Y: 200, Width: 800, Height: 600},
		Elements:     []elementRecord{{Index: 0, Name: "document"}},
	}

	var captured psRequest
	svc.runBridge = func(request psRequest) (*psResponse, error) {
		captured = request
		return &psResponse{OK: true, Snapshot: &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}}}, nil
	}

	result := svc.scroll("fixture", "down", "0", 1)
	if result.IsError {
		t.Fatalf("scroll result = %#v", result)
	}
	if captured.Tool != "scroll" || captured.Element == nil || captured.Direction != "down" {
		t.Fatalf("scroll request = %#v", captured)
	}
	if captured.WindowBounds == nil || captured.WindowBounds.X != 100 || captured.WindowBounds.Y != 200 || captured.WindowBounds.Width != 800 || captured.WindowBounds.Height != 600 {
		t.Fatalf("scroll request must carry the snapshot window bounds, got %#v", captured.WindowBounds)
	}
}

func TestWindowsRejectsUnsupportedSkyClickBeforeSnapshotLookup(t *testing.T) {
	x, y := 10.0, 20.0
	result := newService().click("Notepad", "", &x, &y, 1, "left", "sky_click")
	if !result.IsError || result.Content[0].Text != "click_method 'sky_click' is not supported on Windows" {
		t.Fatalf("sky_click result = %#v", result)
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
	app, textLimit, maxTreeNodes, maxTreeDepth, err := parseSnapshotArgs([]string{"--text-limit", "1000", "Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit == nil || textLimit.runtimeValue() != 1000 || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs = (%q, %#v, %v, %v), want (Notepad, 1000, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Notepad", "--text-limit", "max"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit == nil || textLimit.runtimeValue() != "max" || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs max = (%q, %#v, %v, %v), want (Notepad, max, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit != nil || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs default = (%q, %#v, %v, %v), want (Notepad, nil, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"--max-tree-nodes", "3000", "--max-tree-depth", "96", "Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit != nil || maxTreeNodes == nil || *maxTreeNodes != 3000 || maxTreeDepth == nil || *maxTreeDepth != 96 {
		t.Fatalf("parseSnapshotArgs custom tree budget = (%q, %#v, %v, %v), want (Notepad, nil, 3000, 96)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}
}

func TestParseSnapshotArgsRejectsInvalidTextLimit(t *testing.T) {
	for _, value := range []string{"0", "-1", "1.5", "full"} {
		if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit", value, "Notepad"}); err == nil || err.Error() != "--text-limit must be a positive integer or max" {
			t.Fatalf("invalid text_limit %q error = %v", value, err)
		}
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit"}); err == nil || err.Error() != "--text-limit requires a positive integer or max value" {
		t.Fatalf("missing text_limit error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--show-full-text", "Notepad"}); err == nil || err.Error() != "unknown snapshot option: --show-full-text" {
		t.Fatalf("old show_full_text flag error = %v", err)
	}
}

func TestParseSnapshotArgsRejectsInvalidTreeBudget(t *testing.T) {
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes", "0", "Notepad"}); err == nil || err.Error() != "--max-tree-nodes must be a positive integer" {
		t.Fatalf("invalid max_tree_nodes error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-depth", "1.5", "Notepad"}); err == nil || err.Error() != "--max-tree-depth must be a positive integer" {
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
	args, err := readArguments(`{"app":"Notepad","pages":2}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if args["app"] != "Notepad" {
		t.Fatalf("app = %v", args["app"])
	}
	if args["pages"].(json.Number).String() != "2" {
		t.Fatalf("pages = %v", args["pages"])
	}
}

func TestElementIndexAcceptsStringAndJSONNumber(t *testing.T) {
	args, err := readArguments(`{"app":"Notepad","element_index":0}`, "")
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

func TestCLIHelpMentionsWindowsRuntime(t *testing.T) {
	var out bytes.Buffer
	if err := runCLI([]string{"--help"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Open Computer Use for Windows") {
		t.Fatalf("help text did not mention Windows runtime:\n%s", out.String())
	}
}

func TestWindowsRuntimeForegroundActionsRequireOptIn(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
		t.Fatal("Windows app launch fallback must remain opt-in")
	}
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS") {
		t.Fatal("Windows SetFocus action must remain opt-in")
	}
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK") {
		t.Fatal("Windows UIA text fallback must remain opt-in")
	}
	if !strings.Contains(serverInstructions, "does not auto-launch apps, perform SetFocus, or use UIA text fallback by default") {
		t.Fatal("MCP instructions must document the Windows background-focus policy")
	}
}

func TestUTF8EncodingInPowerShellScript(t *testing.T) {
	// Verify that the PowerShell script sets UTF-8 encoding
	if !strings.Contains(windowsRuntimeScript, "$OutputEncoding = [System.Text.Encoding]::UTF8") {
		t.Fatal("PowerShell script must set $OutputEncoding to UTF-8 for proper non-ASCII character handling")
	}
	if !strings.Contains(windowsRuntimeScript, "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8") {
		t.Fatal("PowerShell script must set [Console]::OutputEncoding to UTF-8 for proper non-ASCII character handling")
	}
}

func TestWindowsRuntimeTextLimitSupportsMaxMode(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$DefaultTextLimit = 500") {
		t.Fatal("Windows runtime should define the shared 500 character text limit")
	}
	if !strings.Contains(windowsRuntimeScript, "Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit)") {
		t.Fatal("Windows get_app_state should pass text_limit into snapshot rendering")
	}
	if !strings.Contains(windowsRuntimeScript, "$Value -is [string] -and $Value.Trim().ToLowerInvariant() -eq \"max\"") {
		t.Fatal("Windows runtime should support max text limit mode")
	}
	if !strings.Contains(windowsRuntimeScript, "([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth)") {
		t.Fatal("Windows get_app_state should pass tree budget into snapshot rendering")
	}
	if !strings.Contains(windowsRuntimeScript, "$maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }") {
		t.Fatal("Windows selected text should use full UIA text only in max text mode")
	}
}

func TestWindowsRuntimeTreeBudgetDefaultsMatchMacOS(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$AccessibilityTreeMaxNodeCount = 1200") {
		t.Fatal("Windows runtime should default to the shared 1200 node tree budget")
	}
	if !strings.Contains(windowsRuntimeScript, "$AccessibilityTreeMaxDepth = 64") {
		t.Fatal("Windows runtime should default to the shared 64 level tree depth")
	}
	if !strings.Contains(windowsRuntimeScript, "$script:nextIndex -ge $script:MaxTreeNodes -or $depth -gt $script:MaxTreeDepth") {
		t.Fatal("Windows runtime should use shared tree budget constants while rendering")
	}
}

func TestWindowsScreenshotValidationRejectsDegenerateImages(t *testing.T) {
	for name, encoded := range map[string]string{
		"one pixel":        pngBase64(t, 1, 1),
		"narrow":           pngBase64(t, minimumScreenshotDimension-1, 400),
		"small area":       pngBase64(t, 100, 100),
		"invalid base64":   "not base64",
		"invalid PNG data": base64.StdEncoding.EncodeToString([]byte("not a png")),
	} {
		t.Run(name, func(t *testing.T) {
			if got := validateScreenshotPNGBase64(encoded); got != "" {
				t.Fatalf("validateScreenshotPNGBase64() = %q, want empty", got)
			}
		})
	}

	valid := pngBase64(t, 100, 200)
	if got := validateScreenshotPNGBase64(valid); got != valid {
		t.Fatal("a screenshot at the minimum area should remain available")
	}
}

func TestWindowsSnapshotOmitsUnusableScreenshot(t *testing.T) {
	snapshot := &appSnapshot{
		App:                 appDescriptor{Name: "fixture", BundleIdentifier: "fixture", PID: 42},
		WindowBounds:        &frame{Width: 1, Height: 1},
		ScreenshotPNGBase64: pngBase64(t, 1, 1),
	}
	result := snapshot.result()
	if result.IsError || len(result.Content) != 1 || result.Content[0].Type != "text" {
		t.Fatalf("degenerate screenshot result = %#v", result)
	}
	if snapshot.ScreenshotPNGBase64 != "" {
		t.Fatal("degenerate screenshot should be removed from the remembered snapshot")
	}
	if !strings.Contains(result.Content[0].Text, "Screenshot unavailable") {
		t.Fatalf("missing screenshot guidance: %q", result.Content[0].Text)
	}

	snapshot.WindowBounds = &frame{Width: 100, Height: 200}
	snapshot.ScreenshotPNGBase64 = pngBase64(t, 100, 200)
	result = snapshot.result()
	if result.IsError || len(result.Content) != 2 || result.Content[1].Type != "image" {
		t.Fatalf("valid screenshot result = %#v", result)
	}
}

func TestWindowsCoordinateActionsRequireUsableScreenshot(t *testing.T) {
	svc := newService()
	svc.snapshots["fixture"] = &appSnapshot{
		App:          appDescriptor{Name: "fixture", PID: 42},
		WindowBounds: &frame{Width: 1, Height: 1},
		Elements:     []elementRecord{{Index: 0}},
	}
	x, y := 1.0, 1.0
	clickResult := svc.click("fixture", "", &x, &y, 1, "left", "auto")
	if !clickResult.IsError || !strings.Contains(clickResult.Content[0].Text, "No usable screenshot is available") {
		t.Fatalf("coordinate click result = %#v", clickResult)
	}
	appPostResult := svc.click("fixture", "0", nil, nil, 1, "left", "app_post")
	if !appPostResult.IsError || !strings.Contains(appPostResult.Content[0].Text, "No usable screenshot is available") {
		t.Fatalf("app_post click result = %#v", appPostResult)
	}
	dragResult := svc.drag("fixture", &x, &y, &x, &y)
	if !dragResult.IsError || !strings.Contains(dragResult.Content[0].Text, "No usable screenshot is available") {
		t.Fatalf("coordinate drag result = %#v", dragResult)
	}
}

func TestWindowsRuntimeFiltersUncapturableWindows(t *testing.T) {
	for _, snippet := range []string{
		"$MinimumScreenshotDimension = 64",
		"$MinimumScreenshotArea = 20000",
		"[OCUWin32]::IsWindowVisible($hwnd)",
		"[OCUWin32]::IsIconic($hwnd)",
		"[OCUWin32]::DwmGetWindowAttribute($hwnd, 14",
		"Test-FrameIntersectsVirtualScreen $frame",
		"if (-not (Test-CapturableFrame $bounds))",
		"Get-CapturableWindowFrame ([IntPtr]$process.MainWindowHandle)",
	} {
		if !strings.Contains(windowsRuntimeScript, snippet) {
			t.Fatalf("Windows runtime missing screenshot guard %q", snippet)
		}
	}
}

func pngBase64(t *testing.T, width, height int) string {
	t.Helper()
	var buffer bytes.Buffer
	if err := png.Encode(&buffer, image.NewRGBA(image.Rect(0, 0, width, height))); err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(buffer.Bytes())
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

func TestWindowsKeyMethodSchemaAndUnsupportedSkyKey(t *testing.T) {
	for _, name := range []string{"type_text", "press_key"} {
		tool := findToolDefinition(t, name)
		properties := tool.InputSchema["properties"].(map[string]any)
		method := properties["key_method"].(map[string]any)
		values := method["enum"].([]string)
		expected := "auto,sky_key"
		if name == "press_key" {
			expected += ",global"
		}
		if strings.Join(values, ",") != expected {
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
	result := service.typeText("Notepad", "hello", "sky_key")
	if !result.IsError || result.Content[0].Text != "key_method 'sky_key' is not supported on Windows" {
		t.Fatalf("type_text sky_key result = %#v", result)
	}
	result = service.pressKey("Notepad", "Return", "sky_key")
	if !result.IsError || result.Content[0].Text != "key_method 'sky_key' is not supported on Windows" {
		t.Fatalf("press_key sky_key result = %#v", result)
	}
}

func TestWindowsWindowPlacementSchemaAndUnsupportedAgentDisplay(t *testing.T) {
	tool := findToolDefinition(t, "get_app_state")
	properties := tool.InputSchema["properties"].(map[string]any)
	placement := properties["window_placement"].(map[string]any)
	if strings.Join(placement["enum"].([]string), ",") != "keep,agent_display,restore" {
		t.Fatalf("window_placement enum = %#v", placement["enum"])
	}
	if got, err := parseWindowPlacement(" AGENT_DISPLAY "); err != nil || got != "agent_display" {
		t.Fatalf("parseWindowPlacement = %q, %v", got, err)
	}
	if _, err := parseWindowPlacement("park"); err == nil {
		t.Fatal("parseWindowPlacement(park) should fail")
	}
	result := newService().callTool("get_app_state", map[string]any{"app": "Notepad", "window_placement": "agent_display"})
	if !result.IsError || result.Content[0].Text != "window_placement 'agent_display' is not supported on Windows" {
		t.Fatalf("agent_display result = %#v", result)
	}
	result = newService().callTool("get_app_state", map[string]any{"app": "Notepad", "settle_ms": 300})
	if !result.IsError || result.Content[0].Text != "settle_ms is not supported on Windows" {
		t.Fatalf("settle_ms result = %#v", result)
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
