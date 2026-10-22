package main

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var version = "1.1.2"

var clickMethodValues = []string{"auto", "accessibility", "app_post", "sky_click", "global"}

var keyMethodValues = []string{"auto", "sky_key"}

var windowPlacementValues = []string{"keep", "agent_display", "restore"}

//go:embed runtime.py
var linuxRuntimeScript string

const serverInstructions = "Computer Use tools let you interact with Linux desktop apps by performing UI actions.\n\nBegin by calling `get_app_state` every turn you want to use Computer Use to get the latest state before acting. The available tools are list_apps, get_app_state, click, perform_secondary_action, scroll, drag, type_text, press_key, and set_value.\n\nPrefer element-targeted interactions over coordinate clicks when an index for the targeted element is available. Linux actions use AT-SPI2 semantic actions and editable text APIs first. Coordinate mouse and key synthesis are best-effort fallbacks and are not a universal Wayland background input model."

type toolDefinition struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Annotations map[string]any `json:"annotations,omitempty"`
	InputSchema map[string]any `json:"inputSchema"`
}

type contentItem struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	Data     string `json:"data,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
}

type toolCallResult struct {
	Content []contentItem `json:"content"`
	IsError bool          `json:"isError"`
}

func textResult(text string, isError bool) toolCallResult {
	return toolCallResult{Content: []contentItem{{Type: "text", Text: text}}, IsError: isError}
}

type appDescriptor struct {
	Name             string `json:"name"`
	BundleIdentifier string `json:"bundleIdentifier,omitempty"`
	PID              int    `json:"pid"`
}

type frame struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

func (f frame) renderedLocalFrame() string {
	return fmt.Sprintf("{{x: %.0f, y: %.0f, width: %.0f, height: %.0f}}", f.X, f.Y, f.Width, f.Height)
}

type elementRecord struct {
	Index                int      `json:"index"`
	RuntimeID            []int    `json:"runtimeId,omitempty"`
	AutomationID         string   `json:"automationId,omitempty"`
	Name                 string   `json:"name,omitempty"`
	ControlType          string   `json:"controlType,omitempty"`
	LocalizedControlType string   `json:"localizedControlType,omitempty"`
	ClassName            string   `json:"className,omitempty"`
	Value                string   `json:"value,omitempty"`
	NativeWindowHandle   int64    `json:"nativeWindowHandle,omitempty"`
	Frame                *frame   `json:"frame,omitempty"`
	Actions              []string `json:"actions,omitempty"`
}

type appSnapshot struct {
	ScreenshotOmitted   bool            `json:"-"`
	App                 appDescriptor   `json:"app"`
	WindowTitle         string          `json:"windowTitle,omitempty"`
	WindowBounds        *frame          `json:"windowBounds,omitempty"`
	ScreenshotPNGBase64 string          `json:"screenshotPngBase64,omitempty"`
	TreeLines           []string        `json:"treeLines,omitempty"`
	FocusedSummary      string          `json:"focusedSummary,omitempty"`
	SelectedText        string          `json:"selectedText,omitempty"`
	Elements            []elementRecord `json:"elements,omitempty"`
}

func (s *appSnapshot) renderedText() string {
	if s == nil {
		return ""
	}
	appRef := s.App.BundleIdentifier
	if appRef == "" {
		appRef = s.App.Name
	}
	title := s.WindowTitle
	if strings.TrimSpace(title) == "" {
		title = s.App.Name
	}

	lines := []string{
		fmt.Sprintf("App=%s (pid %d)", appRef, s.App.PID),
		fmt.Sprintf("Window: %q, App: %s.", title, s.App.Name),
	}
	lines = append(lines, s.TreeLines...)
	if s.ScreenshotOmitted {
		lines = append(lines, "Screenshot omitted by include_screenshot=false")
	}
	if strings.TrimSpace(s.SelectedText) != "" {
		lines = append(lines, "", fmt.Sprintf("Selected text: [%s]", s.SelectedText))
	} else if strings.TrimSpace(s.FocusedSummary) != "" {
		lines = append(lines, "", fmt.Sprintf("The focused UI element is %s.", s.FocusedSummary))
	}
	return strings.Join(lines, "\n")
}

func (s *appSnapshot) result() toolCallResult {
	result := toolCallResult{
		Content: []contentItem{{Type: "text", Text: s.renderedText()}},
	}
	if s != nil && s.ScreenshotPNGBase64 != "" {
		result.Content = append(result.Content, contentItem{
			Type:     "image",
			Data:     s.ScreenshotPNGBase64,
			MimeType: "image/png",
		})
	}
	return result
}

type linuxRequest struct {
	IncludeAX         *bool `json:"include_ax,omitempty"`
	IncludeScreenshot *bool `json:"include_screenshot,omitempty"`

	Tool         string         `json:"tool"`
	App          string         `json:"app,omitempty"`
	Element      *elementRecord `json:"element,omitempty"`
	X            *float64       `json:"x,omitempty"`
	Y            *float64       `json:"y,omitempty"`
	FromX        *float64       `json:"from_x,omitempty"`
	FromY        *float64       `json:"from_y,omitempty"`
	ToX          *float64       `json:"to_x,omitempty"`
	ToY          *float64       `json:"to_y,omitempty"`
	ClickCount   int            `json:"click_count,omitempty"`
	MouseButton  string         `json:"mouse_button,omitempty"`
	ClickMethod  string         `json:"click_method,omitempty"`
	Action       string         `json:"action,omitempty"`
	Direction    string         `json:"direction,omitempty"`
	Pages        float64        `json:"pages,omitempty"`
	Text         string         `json:"text,omitempty"`
	Key          string         `json:"key,omitempty"`
	Value        string         `json:"value,omitempty"`
	WindowBounds *frame         `json:"windowBounds,omitempty"`
	TextLimit    any            `json:"text_limit,omitempty"`
	MaxTreeNodes int            `json:"max_tree_nodes,omitempty"`
	MaxTreeDepth int            `json:"max_tree_depth,omitempty"`
	SkipReadBack bool           `json:"skip_read_back,omitempty"`
}

type textLimit struct {
	max   bool
	count int
}

func (limit textLimit) runtimeValue() any {
	if limit.max {
		return "max"
	}
	return limit.count
}

type linuxResponse struct {
	OK       bool         `json:"ok"`
	Text     string       `json:"text,omitempty"`
	Error    string       `json:"error,omitempty"`
	Snapshot *appSnapshot `json:"snapshot,omitempty"`
}

type service struct {
	snapshots map[string]*appSnapshot
}

func newService() *service {
	return &service{snapshots: map[string]*appSnapshot{}}
}

func (s *service) callTool(name string, args map[string]any) toolCallResult {
	switch name {
	case "list_apps":
		return s.listApps()
	case "get_app_state":
		maxTreeNodes, err := optionalPositiveInt(args, "max_tree_nodes")
		if err != nil {
			return textResult(err.Error(), true)
		}
		maxTreeDepth, err := optionalPositiveInt(args, "max_tree_depth")
		if err != nil {
			return textResult(err.Error(), true)
		}
		textLimit, err := optionalTextLimit(args, "text_limit")
		if err != nil {
			return textResult(err.Error(), true)
		}
		windowPlacement, err := parseWindowPlacement(optionalString(args, "window_placement"))
		if err != nil {
			return textResult(err.Error(), true)
		}
		if windowPlacement != "keep" {
			return textResult("window_placement '"+windowPlacement+"' is not supported on Linux", true)
		}
		if _, ok := args["settle_ms"]; ok {
			return textResult("settle_ms is not supported on Linux", true)
		}
		includeAX, err := optionalBool(args, "include_ax")
		if err != nil {
			return textResult(err.Error(), true)
		}
		includeScreenshot, err := optionalBool(args, "include_screenshot")
		if err != nil {
			return textResult(err.Error(), true)
		}
		if includeAX != nil && !*includeAX && includeScreenshot != nil && !*includeScreenshot {
			return textResult("At least one of include_ax or include_screenshot must be true", true)
		}
		return s.getAppState(requiredString(args, "app"), textLimit, maxTreeNodes, maxTreeDepth, includeAX, includeScreenshot)
	case "click":
		clickMethod, err := parseClickMethod(optionalString(args, "click_method"))
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.click(
			requiredString(args, "app"),
			optionalElementIndex(args),
			optionalFloat(args, "x"),
			optionalFloat(args, "y"),
			intValue(optionalFloat(args, "click_count"), 1),
			defaultString(optionalString(args, "mouse_button"), "left"),
			clickMethod,
		)
	case "perform_secondary_action":
		return s.performSecondaryAction(
			requiredString(args, "app"),
			requiredElementIndex(args),
			requiredString(args, "action"),
		)
	case "scroll":
		return s.scroll(
			requiredString(args, "app"),
			requiredString(args, "direction"),
			requiredElementIndex(args),
			floatValue(optionalFloat(args, "pages"), 1),
		)
	case "drag":
		return s.drag(
			requiredString(args, "app"),
			requiredFloat(args, "from_x"),
			requiredFloat(args, "from_y"),
			requiredFloat(args, "to_x"),
			requiredFloat(args, "to_y"),
		)
	case "type_text":
		keyMethod, err := parseKeyMethod(optionalString(args, "key_method"))
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.typeText(requiredString(args, "app"), requiredString(args, "text"), keyMethod)
	case "press_key":
		keyMethod, err := parseKeyMethod(optionalString(args, "key_method"))
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.pressKey(requiredString(args, "app"), requiredString(args, "key"), keyMethod)
	case "set_value":
		return s.setValue(requiredString(args, "app"), requiredElementIndex(args), requiredString(args, "value"))
	default:
		return textResult(fmt.Sprintf("unsupportedTool(%q)", name), true)
	}
}

func (s *service) listApps() toolCallResult {
	response, err := runPython(linuxRequest{Tool: "list_apps"})
	if err != nil {
		return textResult(err.Error(), true)
	}
	if !response.OK {
		return textResult(response.Error, true)
	}
	if strings.TrimSpace(response.Text) == "" {
		response.Text = "No running top-level apps are visible to this Linux runtime."
	}
	return textResult(response.Text, false)
}

func (s *service) getAppState(app string, textLimit *textLimit, maxTreeNodes, maxTreeDepth *int, includeAX, includeScreenshot *bool) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	request := linuxRequest{Tool: "get_app_state", App: app, IncludeAX: includeAX, IncludeScreenshot: includeScreenshot}
	if textLimit != nil {
		request.TextLimit = textLimit.runtimeValue()
	}
	if maxTreeNodes != nil {
		request.MaxTreeNodes = *maxTreeNodes
	}
	if maxTreeDepth != nil {
		request.MaxTreeDepth = *maxTreeDepth
	}
	snapshot, result := s.refreshSnapshot(app, request)
	if result.IsError {
		return result
	}
	result = snapshot.result()
	if includeAX != nil && !*includeAX {
		result.Content[0].Text += "\nAccessibility omitted; previous element indexes invalidated. Read AX before element-targeted actions."
	}
	return result
}

func (s *service) click(app, elementIndex string, x, y *float64, clickCount int, mouseButton, clickMethod string) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if elementIndex == "" && (x == nil || y == nil) {
		return textResult("click requires either element_index or x/y", true)
	}
	if clickMethod == "accessibility" && elementIndex == "" {
		return textResult("click_method 'accessibility' requires element_index", true)
	}
	if clickMethod == "app_post" {
		return textResult("click_method 'app_post' is not supported on Linux", true)
	}
	if clickMethod == "sky_click" {
		return textResult("click_method 'sky_click' is not supported on Linux", true)
	}
	if clickMethod == "global" && !globalPointerFallbacksEnabled() {
		return textResult("click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus", true)
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return textResult("No app state is available for "+app+". Run get_app_state before action tools.", true)
	}
	if elementIndex == "" && snapshot.ScreenshotOmitted {
		return textResult("Screenshot omitted by include_screenshot=false; request a screenshot before screenshot-coordinate actions.", true)
	}
	request := linuxRequest{
		Tool:         "click",
		App:          app,
		X:            x,
		Y:            y,
		ClickCount:   clickCount,
		MouseButton:  mouseButton,
		ClickMethod:  clickMethod,
		WindowBounds: snapshot.WindowBounds,
	}
	if elementIndex != "" {
		record, err := lookupElement(snapshot, elementIndex)
		if err != nil {
			return textResult(err.Error(), true)
		}
		request.Element = record
	}
	return s.actionResult(app, request)
}

func (s *service) performSecondaryAction(app, elementIndex, action string) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	if action == "" {
		return textResult("Missing required argument: action", true)
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return textResult("No app state is available for "+app+". Run get_app_state before action tools.", true)
	}
	record, err := lookupElement(snapshot, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(app, linuxRequest{Tool: "perform_secondary_action", App: app, Element: record, Action: action})
}

func (s *service) scroll(app, direction, elementIndex string, pages float64) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	normalized := strings.ToLower(direction)
	if normalized != "up" && normalized != "down" && normalized != "left" && normalized != "right" {
		return textResult("Invalid scroll direction: "+direction, true)
	}
	if pages <= 0 {
		return textResult("pages must be > 0", true)
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return textResult("No app state is available for "+app+". Run get_app_state before action tools.", true)
	}
	record, err := lookupElement(snapshot, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(app, linuxRequest{Tool: "scroll", App: app, Element: record, Direction: normalized, Pages: pages})
}

func (s *service) drag(app string, fromX, fromY, toX, toY *float64) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if fromX == nil {
		return textResult("Missing required argument: from_x", true)
	}
	if fromY == nil {
		return textResult("Missing required argument: from_y", true)
	}
	if toX == nil {
		return textResult("Missing required argument: to_x", true)
	}
	if toY == nil {
		return textResult("Missing required argument: to_y", true)
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return textResult("No app state is available for "+app+". Run get_app_state before action tools.", true)
	}
	if snapshot.ScreenshotOmitted {
		return textResult("Screenshot omitted by include_screenshot=false; request a screenshot before screenshot-coordinate actions.", true)
	}
	return s.actionResult(app, linuxRequest{Tool: "drag", App: app, FromX: fromX, FromY: fromY, ToX: toX, ToY: toY, WindowBounds: snapshot.WindowBounds})
}

func (s *service) typeText(app, text, keyMethod string) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if text == "" {
		return textResult("Missing required argument: text", true)
	}
	if keyMethod == "sky_key" {
		return textResult("key_method 'sky_key' is not supported on Linux", true)
	}
	if s.currentSnapshot(app) == nil {
		return textResult("No app state is available for "+app+". Run get_app_state before action tools.", true)
	}
	return s.actionResult(app, linuxRequest{Tool: "type_text", App: app, Text: text})
}

func (s *service) pressKey(app, key, keyMethod string) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if key == "" {
		return textResult("Missing required argument: key", true)
	}
	if keyMethod == "sky_key" {
		return textResult("key_method 'sky_key' is not supported on Linux", true)
	}
	if s.currentSnapshot(app) == nil {
		return textResult("No app state is available for "+app+". Run get_app_state before action tools.", true)
	}
	return s.actionResult(app, linuxRequest{Tool: "press_key", App: app, Key: key})
}

func (s *service) setValue(app, elementIndex, value string) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		return textResult("No app state is available for "+app+". Run get_app_state before action tools.", true)
	}
	record, err := lookupElement(snapshot, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(app, linuxRequest{Tool: "set_value", App: app, Element: record, Value: value})
}

func (s *service) actionResult(app string, request linuxRequest) toolCallResult {
	if !actionReadBackEnabled() {
		request.SkipReadBack = true
		response, err := runPython(request)
		if err != nil {
			return textResult(err.Error(), true)
		}
		if !response.OK {
			return textResult(response.Error, true)
		}
		// Keep the last explicitly observed indexes until get_app_state refreshes them.
		return textResult("ok", false)
	}
	snapshot, result := s.refreshSnapshot(app, request)
	if result.IsError {
		return result
	}
	return snapshot.result()
}

// Match the macOS runtime: only explicit false values disable action read-back.
func actionReadBackEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("OPEN_COMPUTER_USE_ACTION_READ_BACK"))) {
	case "0", "false", "no", "off":
		return false
	default:
		return true
	}
}

func (s *service) currentSnapshot(app string) *appSnapshot {
	return s.snapshots[strings.ToLower(app)]
}

func (s *service) refreshSnapshot(app string, request linuxRequest) (*appSnapshot, toolCallResult) {
	response, err := runPython(request)
	if err != nil {
		return nil, textResult(err.Error(), true)
	}
	if !response.OK {
		return nil, textResult(response.Error, true)
	}
	if response.Snapshot == nil {
		return nil, textResult("Linux runtime did not return an app snapshot.", true)
	}
	if request.IncludeScreenshot != nil && !*request.IncludeScreenshot {
		response.Snapshot.ScreenshotPNGBase64 = ""
		response.Snapshot.ScreenshotOmitted = true
	}
	if request.IncludeAX != nil && !*request.IncludeAX {
		// A screenshot cannot validate AX indexes, even if the window title matches.
		// Invalidate every alias of the prior observation, including PID queries.
		previous := s.currentSnapshot(app)
		for alias, cached := range s.snapshots {
			if cached == previous || cached.App.PID == response.Snapshot.App.PID ||
				(previous != nil && cached.App.PID == previous.App.PID) {
				delete(s.snapshots, alias)
			}
		}
		response.Snapshot.Elements = nil
		response.Snapshot.TreeLines = nil
		response.Snapshot.FocusedSummary = ""
		response.Snapshot.SelectedText = ""
	}
	s.rememberSnapshot(app, response.Snapshot)
	return response.Snapshot, toolCallResult{}
}

func (s *service) rememberSnapshot(query string, snapshot *appSnapshot) {
	keys := []string{query, snapshot.App.Name, snapshot.App.BundleIdentifier, strconv.Itoa(snapshot.App.PID)}
	for _, key := range keys {
		key = strings.ToLower(strings.TrimSpace(key))
		if key != "" {
			s.snapshots[key] = snapshot
		}
	}
}

func lookupElement(snapshot *appSnapshot, elementIndex string) (*elementRecord, error) {
	index, err := strconv.Atoi(elementIndex)
	if err != nil {
		return nil, fmt.Errorf("unknown element_index %q", elementIndex)
	}
	for _, record := range snapshot.Elements {
		if record.Index == index {
			copy := record
			return &copy, nil
		}
	}
	return nil, fmt.Errorf("unknown element_index %q", elementIndex)
}

func runPython(request linuxRequest) (*linuxResponse, error) {
	if runtime.GOOS != "linux" {
		return nil, errors.New("Linux Computer Use runtime requires python3 on Linux")
	}

	tempDir, err := os.MkdirTemp("", "open-computer-use-linux-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tempDir)

	scriptPath := filepath.Join(tempDir, "runtime.py")
	operationPath := filepath.Join(tempDir, "operation.json")
	if err := os.WriteFile(scriptPath, []byte(linuxRuntimeScript), 0o600); err != nil {
		return nil, err
	}
	operationData, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(operationPath, operationData, 0o600); err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "python3", scriptPath, operationPath)
	cmd.Env = linuxRuntimeEnvironment(os.Environ())
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, errors.New("Linux runtime timed out after 30s")
	}
	if err != nil {
		text := strings.TrimSpace(stderr.String())
		if text == "" {
			text = strings.TrimSpace(string(output))
		}
		if text == "" {
			text = err.Error()
		}
		return nil, fmt.Errorf("Linux runtime failed: %s", text)
	}

	var response linuxResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, fmt.Errorf("Linux runtime returned invalid JSON: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return &response, nil
}

func linuxRuntimeEnvironment(base []string) []string {
	uid := os.Getuid()
	return linuxRuntimeEnvironmentFrom(base, uid, desktopProcessEnvironments(uid))
}

func linuxRuntimeEnvironmentFrom(base []string, uid int, processEnvs []map[string]string) []string {
	env := envSliceToMap(base)
	runtimeDir := chooseRuntimeDir(env, processEnvs, uid)
	if runtimeDir != "" {
		env["XDG_RUNTIME_DIR"] = runtimeDir
	}

	if value := sessionBusAddress(env["DBUS_SESSION_BUS_ADDRESS"], runtimeDir, processEnvs); value != "" {
		env["DBUS_SESSION_BUS_ADDRESS"] = value
	}
	if value := waylandDisplay(env["WAYLAND_DISPLAY"], runtimeDir, processEnvs); value != "" {
		env["WAYLAND_DISPLAY"] = value
	}

	for _, key := range []string{
		"DISPLAY",
		"XAUTHORITY",
		"XDG_CURRENT_DESKTOP",
		"XDG_SESSION_DESKTOP",
		"XDG_SESSION_TYPE",
		"DESKTOP_SESSION",
		"GDK_BACKEND",
		"QT_QPA_PLATFORMTHEME",
		"AT_SPI_BUS_ADDRESS",
	} {
		if strings.TrimSpace(env[key]) == "" {
			if value := firstSessionValue(processEnvs, key); value != "" {
				env[key] = value
			}
		}
	}

	return envMapToSlice(base, env)
}

func chooseRuntimeDir(env map[string]string, processEnvs []map[string]string, uid int) string {
	candidates := []string{env["XDG_RUNTIME_DIR"]}
	for _, processEnv := range processEnvs {
		candidates = append(candidates, processEnv["XDG_RUNTIME_DIR"])
	}
	candidates = append(candidates, fmt.Sprintf("/run/user/%d", uid))

	seen := map[string]bool{}
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		candidate = filepath.Clean(candidate)
		if seen[candidate] {
			continue
		}
		seen[candidate] = true
		if validRuntimeDir(candidate, uid) {
			return candidate
		}
	}
	return ""
}

func sessionBusAddress(current, runtimeDir string, processEnvs []map[string]string) string {
	current = strings.TrimSpace(current)
	if runtimeDir != "" {
		busPath := filepath.Join(runtimeDir, "bus")
		if isSocket(busPath) && shouldUseRuntimeBus(current, runtimeDir) {
			return "unix:path=" + busPath
		}
	}
	if current != "" {
		return current
	}
	for _, processEnv := range processEnvs {
		value := strings.TrimSpace(processEnv["DBUS_SESSION_BUS_ADDRESS"])
		if value == "" {
			continue
		}
		if runtimeDir != "" {
			busPath := filepath.Join(runtimeDir, "bus")
			if isSocket(busPath) && strings.Contains(value, busPath) {
				return "unix:path=" + busPath
			}
		}
		return value
	}
	if runtimeDir != "" {
		busPath := filepath.Join(runtimeDir, "bus")
		if isSocket(busPath) {
			return "unix:path=" + busPath
		}
	}
	return ""
}

func shouldUseRuntimeBus(current, runtimeDir string) bool {
	current = strings.TrimSpace(current)
	if current == "" {
		return true
	}
	busPath := filepath.Join(runtimeDir, "bus")
	if strings.Contains(current, busPath) {
		return true
	}
	return strings.Contains(current, "/run/user/") && !strings.Contains(current, runtimeDir)
}

func waylandDisplay(current, runtimeDir string, processEnvs []map[string]string) string {
	if value := normalizeWaylandDisplay(current, runtimeDir); value != "" {
		return value
	}
	for _, processEnv := range processEnvs {
		if value := normalizeWaylandDisplay(processEnv["WAYLAND_DISPLAY"], runtimeDir); value != "" {
			return value
		}
	}
	if runtimeDir == "" {
		return ""
	}
	return firstWaylandSocket(runtimeDir)
}

func normalizeWaylandDisplay(value, runtimeDir string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if runtimeDir == "" {
		return value
	}
	if filepath.IsAbs(value) {
		if isSocket(value) {
			return value
		}
		return ""
	}
	if isSocket(filepath.Join(runtimeDir, value)) {
		return value
	}
	return ""
}

func firstWaylandSocket(runtimeDir string) string {
	for _, name := range []string{"wayland-0", "wayland-1"} {
		if isSocket(filepath.Join(runtimeDir, name)) {
			return name
		}
	}
	matches, err := filepath.Glob(filepath.Join(runtimeDir, "wayland-*"))
	if err != nil {
		return ""
	}
	sort.Strings(matches)
	for _, match := range matches {
		if strings.HasSuffix(match, ".lock") {
			continue
		}
		if isSocket(match) {
			return filepath.Base(match)
		}
	}
	return ""
}

func firstSessionValue(processEnvs []map[string]string, key string) string {
	for _, processEnv := range processEnvs {
		if value := strings.TrimSpace(processEnv[key]); value != "" {
			return value
		}
	}
	return ""
}

type rankedProcessEnv struct {
	env  map[string]string
	rank int
	pid  int
}

func desktopProcessEnvironments(uid int) []map[string]string {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}

	var candidates []rankedProcessEnv
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		procDir := filepath.Join("/proc", entry.Name())
		if !pathOwnedByUID(procDir, uid) {
			continue
		}
		rank := desktopProcessRank(processSearchText(procDir))
		if rank == 0 {
			continue
		}
		processEnv := readProcEnviron(procDir)
		if !hasSessionEnvSignal(processEnv) {
			continue
		}
		candidates = append(candidates, rankedProcessEnv{
			env:  processEnv,
			rank: rank + sessionEnvRank(processEnv),
			pid:  pid,
		})
	}

	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].rank != candidates[j].rank {
			return candidates[i].rank > candidates[j].rank
		}
		return candidates[i].pid < candidates[j].pid
	})

	results := make([]map[string]string, 0, len(candidates))
	for _, candidate := range candidates {
		results = append(results, candidate.env)
	}
	return results
}

func processSearchText(procDir string) string {
	var parts []string
	if data, err := os.ReadFile(filepath.Join(procDir, "comm")); err == nil {
		parts = append(parts, string(bytes.TrimSpace(data)))
	}
	if data, err := os.ReadFile(filepath.Join(procDir, "cmdline")); err == nil {
		data = bytes.Trim(data, "\x00")
		parts = append(parts, strings.ReplaceAll(string(data), "\x00", " "))
	}
	return strings.ToLower(strings.Join(parts, " "))
}

func desktopProcessRank(text string) int {
	patterns := []struct {
		needle string
		rank   int
	}{
		{"gnome-session", 100},
		{"gnome-shell", 95},
		{"plasmashell", 95},
		{"kwin_wayland", 95},
		{"kwin_x11", 95},
		{"startplasma", 95},
		{"cinnamon-session", 95},
		{"mate-session", 95},
		{"xfce4-session", 95},
		{"lxqt-session", 95},
		{"sway", 95},
		{"wayfire", 95},
		{"xorg", 80},
		{"xwayland", 75},
		{"gnome-terminal-server", 65},
		{"ptyxis", 65},
		{"kgx", 65},
		{"konsole", 65},
		{"xfce4-terminal", 65},
		{"alacritty", 65},
		{"wezterm", 65},
		{"kitty", 65},
		{"tilix", 65},
		{"codex", 50},
		{"dbus-daemon", 45},
		{"systemd --user", 40},
	}

	rank := 0
	for _, pattern := range patterns {
		if strings.Contains(text, pattern.needle) && pattern.rank > rank {
			rank = pattern.rank
		}
	}
	return rank
}

func sessionEnvRank(env map[string]string) int {
	rank := 0
	for _, key := range []string{"XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"} {
		if strings.TrimSpace(env[key]) != "" {
			rank += 20
		}
	}
	for _, key := range []string{"DISPLAY", "WAYLAND_DISPLAY"} {
		if strings.TrimSpace(env[key]) != "" {
			rank += 10
		}
	}
	if strings.TrimSpace(env["XAUTHORITY"]) != "" {
		rank += 5
	}
	return rank
}

func hasSessionEnvSignal(env map[string]string) bool {
	for _, key := range []string{
		"XDG_RUNTIME_DIR",
		"DBUS_SESSION_BUS_ADDRESS",
		"DISPLAY",
		"WAYLAND_DISPLAY",
		"XAUTHORITY",
		"AT_SPI_BUS_ADDRESS",
	} {
		if strings.TrimSpace(env[key]) != "" {
			return true
		}
	}
	return false
}

func readProcEnviron(procDir string) map[string]string {
	data, err := os.ReadFile(filepath.Join(procDir, "environ"))
	if err != nil {
		return nil
	}
	return parseNullEnv(data)
}

func parseNullEnv(data []byte) map[string]string {
	env := map[string]string{}
	for _, entry := range bytes.Split(data, []byte{0}) {
		if len(entry) == 0 {
			continue
		}
		key, value, ok := strings.Cut(string(entry), "=")
		if ok && key != "" {
			env[key] = value
		}
	}
	return env
}

func envSliceToMap(items []string) map[string]string {
	env := map[string]string{}
	for _, item := range items {
		key, value, ok := strings.Cut(item, "=")
		if ok && key != "" {
			env[key] = value
		}
	}
	return env
}

func envMapToSlice(base []string, env map[string]string) []string {
	items := make([]string, 0, len(env))
	seen := map[string]bool{}
	for _, item := range base {
		key, _, ok := strings.Cut(item, "=")
		if !ok || key == "" {
			items = append(items, item)
			continue
		}
		if value, ok := env[key]; ok {
			items = append(items, key+"="+value)
			seen[key] = true
		}
	}

	var added []string
	for key := range env {
		if !seen[key] {
			added = append(added, key)
		}
	}
	sort.Strings(added)
	for _, key := range added {
		items = append(items, key+"="+env[key])
	}
	return items
}

func validRuntimeDir(path string, uid int) bool {
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	return int(stat.Uid) == uid
}

func pathOwnedByUID(path string, uid int) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	return int(stat.Uid) == uid
}

func isSocket(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode()&os.ModeSocket != 0
}

func requiredString(args map[string]any, key string) string {
	value, _ := args[key].(string)
	return strings.TrimSpace(value)
}

func optionalString(args map[string]any, key string) string {
	value, _ := args[key].(string)
	return value
}

func optionalBool(args map[string]any, key string) (*bool, error) {
	value, exists := args[key]
	if !exists {
		return nil, nil
	}
	boolean, ok := value.(bool)
	if !ok {
		return nil, fmt.Errorf("%s must be a boolean", key)
	}
	return &boolean, nil
}

func requiredElementIndex(args map[string]any) string {
	return strings.TrimSpace(optionalElementIndex(args))
}

func optionalElementIndex(args map[string]any) string {
	return elementIndexString(args["element_index"])
}

func elementIndexString(value any) string {
	switch value := value.(type) {
	case string:
		return value
	case json.Number:
		if integer, err := value.Int64(); err == nil {
			return strconv.FormatInt(integer, 10)
		}
		if float, err := value.Float64(); err == nil {
			return integerElementIndexFloat(float)
		}
	case float64:
		return integerElementIndexFloat(value)
	case int:
		return strconv.Itoa(value)
	case int64:
		return strconv.FormatInt(value, 10)
	}
	return ""
}

func integerElementIndexFloat(value float64) string {
	if math.IsNaN(value) || math.IsInf(value, 0) || math.Trunc(value) != value {
		return ""
	}
	return strconv.FormatInt(int64(value), 10)
}

func requiredFloat(args map[string]any, key string) *float64 {
	return optionalFloat(args, key)
}

func optionalFloat(args map[string]any, key string) *float64 {
	switch value := args[key].(type) {
	case float64:
		return &value
	case int:
		float := float64(value)
		return &float
	case json.Number:
		float, err := value.Float64()
		if err == nil {
			return &float
		}
	}
	return nil
}

func optionalTextLimit(args map[string]any, key string) (*textLimit, error) {
	value, ok := args[key]
	if !ok {
		return nil, nil
	}
	return textLimitFromValue(value, key)
}

func textLimitFromValue(value any, key string) (*textLimit, error) {
	if stringValue, ok := value.(string); ok {
		if strings.EqualFold(stringValue, "max") {
			return &textLimit{max: true}, nil
		}
		return nil, fmt.Errorf("%s must be a positive integer or max", key)
	}
	integer, err := positiveIntFromValue(value, key)
	if err != nil {
		return nil, fmt.Errorf("%s must be a positive integer or max", key)
	}
	return &textLimit{count: *integer}, nil
}

func optionalPositiveInt(args map[string]any, key string) (*int, error) {
	value, ok := args[key]
	if !ok {
		return nil, nil
	}
	return positiveIntFromValue(value, key)
}

func positiveIntFromValue(value any, key string) (*int, error) {
	switch typed := value.(type) {
	case int:
		return positiveIntFromInt64(int64(typed), key)
	case float64:
		if !isWholeNumber(typed) {
			return nil, fmt.Errorf("%s must be a positive integer", key)
		}
		return positiveIntFromFloat64(typed, key)
	case json.Number:
		integer, err := typed.Int64()
		if err != nil {
			return nil, fmt.Errorf("%s must be a positive integer", key)
		}
		return positiveIntFromInt64(integer, key)
	default:
		return nil, fmt.Errorf("%s must be a positive integer", key)
	}
}

func positiveIntFromFloat64(value float64, key string) (*int, error) {
	if !isWholeNumber(value) || value <= 0 || value > float64(maxInt()) {
		return nil, fmt.Errorf("%s must be a positive integer", key)
	}
	integer := int(value)
	return &integer, nil
}

func positiveIntFromInt64(value int64, key string) (*int, error) {
	if value <= 0 || value > int64(maxInt()) {
		return nil, fmt.Errorf("%s must be a positive integer", key)
	}
	integer := int(value)
	return &integer, nil
}

func isWholeNumber(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && math.Trunc(value) == value
}

func maxInt() int {
	return int(^uint(0) >> 1)
}

func intValue(value *float64, fallback int) int {
	if value == nil {
		return fallback
	}
	return int(*value)
}

func floatValue(value *float64, fallback float64) float64 {
	if value == nil {
		return fallback
	}
	return *value
}

func defaultString(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func parseWindowPlacement(value string) (string, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return "keep", nil
	}
	for _, candidate := range windowPlacementValues {
		if normalized == candidate {
			return normalized, nil
		}
	}
	return "", fmt.Errorf("Invalid window_placement %q. Expected one of: %s", value, strings.Join(windowPlacementValues, ", "))
}

func parseKeyMethod(value string) (string, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return "auto", nil
	}
	for _, candidate := range keyMethodValues {
		if normalized == candidate {
			return normalized, nil
		}
	}
	return "", fmt.Errorf("Invalid key_method %q. Expected one of: %s", value, strings.Join(keyMethodValues, ", "))
}

func parseClickMethod(value string) (string, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return "auto", nil
	}
	for _, candidate := range clickMethodValues {
		if normalized == candidate {
			return normalized, nil
		}
	}
	return "", fmt.Errorf("Invalid click_method %q. Expected one of: %s", value, strings.Join(clickMethodValues, ", "))
}

func globalPointerFallbacksEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func toolDefinitions() []toolDefinition {
	return []toolDefinition{
		{
			Name:        "click",
			Description: "Click an element by index or pixel coordinates from screenshot. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("App name or bundle identifier"),
				"element_index": stringProperty("Element index to click"),
				"x":             numberProperty("X coordinate in screenshot pixel coordinates"),
				"y":             numberProperty("Y coordinate in screenshot pixel coordinates"),
				"click_count":   integerProperty("Number of clicks. Defaults to 1"),
				"mouse_button":  enumStringProperty("Mouse button to click. Defaults to left.", []string{"left", "right", "middle"}),
				"click_method":  enumStringProperty("Click implementation: auto (default), accessibility, app_post, sky_click, or global. Accessibility requires element_index. Linux supports global AT-SPI mouse synthesis and does not currently support app_post or sky_click.", clickMethodValues),
			}, []string{"app"}),
		},
		{
			Name:        "drag",
			Description: "Drag from one point to another using pixel coordinates. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":    stringProperty("App name or bundle identifier"),
				"from_x": numberProperty("Start X coordinate"),
				"from_y": numberProperty("Start Y coordinate"),
				"to_x":   numberProperty("End X coordinate"),
				"to_y":   numberProperty("End Y coordinate"),
			}, []string{"app", "from_x", "from_y", "to_x", "to_y"}),
		},
		{
			Name:        "get_app_state",
			Description: "Get the state of an already running app's key window. By default returns a screenshot and accessibility tree; include_ax/include_screenshot can opt out of either collection. This must be called once per assistant turn before interacting with the app. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":              stringProperty("App name or bundle identifier"),
				"text_limit":       textLimitProperty("Maximum text characters to return. Use \"max\" for full text. Defaults to 500."),
				"max_tree_nodes":   positiveIntegerProperty("Maximum accessibility tree nodes to render. Defaults to 1200."),
				"max_tree_depth":   positiveIntegerProperty("Maximum accessibility tree depth to render. Defaults to 64."),
				"window_placement": enumStringProperty("keep (default) leaves the window where it is. agent_display and restore are macOS-only and not supported on Linux.", windowPlacementValues),

				"include_ax":         map[string]any{"type": "boolean", "default": true, "description": "Include accessibility tree, focus and selection. False skips AX collection and invalidates prior element indexes; coordinate actions remain available."},
				"include_screenshot": map[string]any{"type": "boolean", "default": true, "description": "Capture and return a screenshot. False skips capture and PNG encoding."},
			}, []string{"app"}),
		},
		{
			Name:        "list_apps",
			Description: "List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{}, nil),
		},
		{
			Name:        "perform_secondary_action",
			Description: "Invoke a secondary accessibility action exposed by an element. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("App name or bundle identifier"),
				"element_index": stringProperty("Element identifier"),
				"action":        stringProperty("Secondary accessibility action name"),
			}, []string{"app", "element_index", "action"}),
		},
		{
			Name:        "press_key",
			Description: "Press a key or key-combination on the keyboard, including modifier and navigation keys.\n  - This supports xdotool's `key` syntax.\n  - Examples: \"a\", \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\" (for the numpad 0). This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":        stringProperty("App name or bundle identifier"),
				"key":        stringProperty("Key or key-combination to press"),
				"key_method": enumStringProperty("Keyboard delivery: auto (default) or sky_key. sky_key is the macOS SkyLight background-window path and is not supported on Linux.", keyMethodValues),
			}, []string{"app", "key"}),
		},
		{
			Name:        "scroll",
			Description: "Scroll an element in a direction by a number of pages. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("App name or bundle identifier"),
				"direction":     stringProperty("Scroll direction: up, down, left, or right"),
				"element_index": stringProperty("Element identifier"),
				"pages":         numberProperty("Number of pages to scroll. Fractional values are supported. Defaults to 1"),
			}, []string{"app", "element_index", "direction"}),
		},
		{
			Name:        "set_value",
			Description: "Set the value of a settable accessibility element. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("App name or bundle identifier"),
				"element_index": stringProperty("Element identifier"),
				"value":         stringProperty("Value to assign"),
			}, []string{"app", "element_index", "value"}),
		},
		{
			Name:        "type_text",
			Description: "Type literal text using keyboard input. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":        stringProperty("App name or bundle identifier"),
				"text":       stringProperty("Literal text to type"),
				"key_method": enumStringProperty("Keyboard delivery: auto (default) or sky_key. sky_key is the macOS SkyLight background-window path and is not supported on Linux.", keyMethodValues),
			}, []string{"app", "text"}),
		},
	}
}

func objectSchema(properties map[string]any, required []string) map[string]any {
	schema := map[string]any{
		"type":                 "object",
		"properties":           properties,
		"additionalProperties": false,
	}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

func defaultAnnotations() map[string]any {
	return map[string]any{"destructiveHint": false, "openWorldHint": false}
}

func readOnlyAnnotations() map[string]any {
	return map[string]any{"destructiveHint": false, "idempotentHint": true, "openWorldHint": false, "readOnlyHint": true}
}

func stringProperty(description string) map[string]any {
	return map[string]any{"type": "string", "description": description}
}

func enumStringProperty(description string, values []string) map[string]any {
	property := stringProperty(description)
	property["enum"] = values
	return property
}

func numberProperty(description string) map[string]any {
	return map[string]any{"type": "number", "description": description}
}

func integerProperty(description string) map[string]any {
	return map[string]any{"type": "integer", "description": description}
}

func positiveIntegerProperty(description string) map[string]any {
	return map[string]any{"type": "integer", "minimum": 1, "description": description}
}

func textLimitProperty(description string) map[string]any {
	return map[string]any{
		"anyOf": []any{
			map[string]any{"type": "integer", "minimum": 1},
			map[string]any{"type": "string", "enum": []string{"max"}},
		},
		"description": description,
	}
}

func main() {
	if err := runCLI(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runCLI(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(stdout, helpText(""))
		return nil
	}

	switch args[0] {
	case "-h", "--help", "help":
		topic := ""
		if len(args) > 1 {
			topic = args[1]
		}
		fmt.Fprint(stdout, helpText(topic))
		return nil
	case "-v", "--version", "version":
		fmt.Fprintln(stdout, version)
		return nil
	case "mcp":
		return runMCP(os.Stdin, stdout)
	case "doctor":
		if len(args) > 1 && args[1] == "--json" {
			return errors.New("doctor --json permission diagnostics are only supported on macOS")
		}
		fmt.Fprintln(stdout, "Linux runtime: AT-SPI2 and GDK run against the signed-in desktop user's accessibility session. When Codex starts without XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS, or display variables, open-computer-use tries to discover the same user's session from /run/user/<uid> and desktop processes.")
		return nil
	case "list-apps":
		result := newService().callTool("list_apps", map[string]any{})
		if result.IsError {
			return errors.New(result.Content[0].Text)
		}
		fmt.Fprintln(stdout, result.Content[0].Text)
		return nil
	case "snapshot":
		snapshotArgs, observation, err := parseSnapshotObservationArgs(args[1:])
		if err != nil {
			return err
		}
		app, textLimit, maxTreeNodes, maxTreeDepth, err := parseSnapshotArgs(snapshotArgs)
		if err != nil {
			return err
		}
		toolArgs := observation
		toolArgs["app"] = app
		if textLimit != nil {
			toolArgs["text_limit"] = textLimit.runtimeValue()
		}
		if maxTreeNodes != nil {
			toolArgs["max_tree_nodes"] = *maxTreeNodes
		}
		if maxTreeDepth != nil {
			toolArgs["max_tree_depth"] = *maxTreeDepth
		}
		result := newService().callTool("get_app_state", toolArgs)
		if result.IsError {
			return errors.New(result.Content[0].Text)
		}
		fmt.Fprintln(stdout, result.Content[0].Text)
		return nil
	case "call":
		output, hasError, err := runCallCommand(args[1:], newService())
		if err != nil {
			return err
		}
		encoded, err := json.MarshalIndent(output, "", "  ")
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, string(encoded))
		if hasError {
			return errors.New("tool call returned isError=true")
		}
		return nil
	default:
		return fmt.Errorf("unknown command: %s\n\n%s", args[0], helpText(""))
	}
}

func parseSnapshotObservationArgs(args []string) ([]string, map[string]any, error) {
	remaining := []string{}
	options := map[string]any{}
	for index := 0; index < len(args); index++ {
		option := args[index]
		if option != "--include-ax" && option != "--include-screenshot" {
			remaining = append(remaining, option)
			continue
		}
		index++
		if index >= len(args) {
			return nil, nil, fmt.Errorf("%s requires true or false", option)
		}
		var value bool
		switch strings.ToLower(args[index]) {
		case "true":
			value = true
		case "false":
			value = false
		default:
			return nil, nil, fmt.Errorf("%s requires true or false", option)
		}
		key := strings.ReplaceAll(strings.TrimPrefix(option, "--"), "-", "_")
		options[key] = value
	}
	if options["include_ax"] == false && options["include_screenshot"] == false {
		return nil, nil, errors.New("At least one of include_ax or include_screenshot must be true")
	}
	return remaining, options, nil
}

func parseSnapshotArgs(args []string) (string, *textLimit, *int, *int, error) {
	var app string
	var textLimit *textLimit
	var maxTreeNodes *int
	var maxTreeDepth *int
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "--text-limit":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--text-limit requires a positive integer or max value")
			}
			value, err := parseTextLimitOption(args[index], "--text-limit")
			if err != nil {
				return "", nil, nil, nil, err
			}
			textLimit = value
		case "--max-tree-nodes":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--max-tree-nodes requires a positive integer value")
			}
			value, err := parsePositiveIntegerOption(args[index], "--max-tree-nodes")
			if err != nil {
				return "", nil, nil, nil, err
			}
			maxTreeNodes = &value
		case "--max-tree-depth":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--max-tree-depth requires a positive integer value")
			}
			value, err := parsePositiveIntegerOption(args[index], "--max-tree-depth")
			if err != nil {
				return "", nil, nil, nil, err
			}
			maxTreeDepth = &value
		default:
			if strings.HasPrefix(arg, "-") {
				return "", nil, nil, nil, fmt.Errorf("unknown snapshot option: %s", arg)
			}
			if app != "" {
				return "", nil, nil, nil, errors.New("snapshot accepts exactly one app name, process name, window title, or pid")
			}
			app = arg
		}
	}
	if app == "" {
		return "", nil, nil, nil, errors.New("snapshot requires an app name, process name, window title, or pid")
	}
	return app, textLimit, maxTreeNodes, maxTreeDepth, nil
}

func parseTextLimitOption(value, option string) (*textLimit, error) {
	if strings.EqualFold(value, "max") {
		return &textLimit{max: true}, nil
	}
	integer, err := strconv.Atoi(value)
	if err != nil || integer <= 0 {
		return nil, fmt.Errorf("%s must be a positive integer or max", option)
	}
	return &textLimit{count: integer}, nil
}

func parsePositiveIntegerOption(value, option string) (int, error) {
	integer, err := strconv.Atoi(value)
	if err != nil || integer <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", option)
	}
	return integer, nil
}

func runCallCommand(args []string, svc *service) (any, bool, error) {
	if len(args) == 0 {
		return nil, false, errors.New("call requires a tool name or --calls/--calls-file")
	}

	var toolName, argsJSON, argsFile, callsJSON, callsFile string
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "--args":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--args requires a value")
			}
			argsJSON = args[index]
		case "--args-file":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--args-file requires a value")
			}
			argsFile = args[index]
		case "--calls":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--calls requires a value")
			}
			callsJSON = args[index]
		case "--calls-file":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--calls-file requires a value")
			}
			callsFile = args[index]
		default:
			if strings.HasPrefix(arg, "-") {
				return nil, false, fmt.Errorf("unknown call option: %s", arg)
			}
			if toolName != "" {
				return nil, false, errors.New("call accepts at most one tool name")
			}
			toolName = arg
		}
	}

	if callsJSON != "" || callsFile != "" {
		if toolName != "" || argsJSON != "" || argsFile != "" {
			return nil, false, errors.New("call sequence does not accept a tool name, --args, or --args-file")
		}
		calls, err := readCallSequence(callsJSON, callsFile)
		if err != nil {
			return nil, false, err
		}
		var outputs []map[string]any
		hasError := false
		for _, call := range calls {
			result := svc.callTool(call.Tool, call.Args)
			outputs = append(outputs, map[string]any{"tool": call.Tool, "result": result})
			if result.IsError {
				hasError = true
				break
			}
		}
		return outputs, hasError, nil
	}

	if toolName == "" {
		return nil, false, errors.New("call requires a tool name or --calls/--calls-file")
	}
	arguments, err := readArguments(argsJSON, argsFile)
	if err != nil {
		return nil, false, err
	}
	result := svc.callTool(toolName, arguments)
	return result, result.IsError, nil
}

type callSpec struct {
	Tool string
	Args map[string]any
}

func readArguments(inline, file string) (map[string]any, error) {
	if inline != "" && file != "" {
		return nil, errors.New("Use either inline JSON or a JSON file, not both")
	}
	if inline == "" && file == "" {
		return map[string]any{}, nil
	}
	source, err := readJSONSource(inline, file)
	if err != nil {
		return nil, err
	}
	var args map[string]any
	decoder := json.NewDecoder(strings.NewReader(source))
	decoder.UseNumber()
	if err := decoder.Decode(&args); err != nil {
		return nil, fmt.Errorf("Invalid JSON input: %w", err)
	}
	if args == nil {
		return nil, errors.New("--args must be a JSON object")
	}
	return args, nil
}

func readCallSequence(inline, file string) ([]callSpec, error) {
	if inline != "" && file != "" {
		return nil, errors.New("Use either --calls or --calls-file, not both")
	}
	source, err := readJSONSource(inline, file)
	if err != nil {
		return nil, err
	}
	var raw []map[string]any
	decoder := json.NewDecoder(strings.NewReader(source))
	decoder.UseNumber()
	if err := decoder.Decode(&raw); err != nil {
		return nil, fmt.Errorf("Invalid JSON input: %w", err)
	}
	calls := make([]callSpec, 0, len(raw))
	for index, item := range raw {
		name, _ := item["tool"].(string)
		if name == "" {
			name, _ = item["name"].(string)
		}
		if name == "" {
			return nil, fmt.Errorf("call sequence item #%d requires a non-empty tool", index+1)
		}
		args, _ := item["args"].(map[string]any)
		if args == nil {
			args, _ = item["arguments"].(map[string]any)
		}
		if args == nil {
			args = map[string]any{}
		}
		calls = append(calls, callSpec{Tool: name, Args: args})
	}
	return calls, nil
}

func readJSONSource(inline, file string) (string, error) {
	if inline != "" {
		return inline, nil
	}
	if file == "" {
		return "", errors.New("JSON input is required")
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func runMCP(stdin io.Reader, stdout io.Writer) error {
	svc := newService()
	decoder := json.NewDecoder(stdin)
	encoder := json.NewEncoder(stdout)
	for {
		var request map[string]any
		if err := decoder.Decode(&request); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			_ = encoder.Encode(jsonRPCError(nil, -32700, "Invalid JSON-RPC payload"))
			continue
		}
		response := handleMCPRequest(request, svc)
		if response != nil {
			if err := encoder.Encode(response); err != nil {
				return err
			}
		}
	}
}

func handleMCPRequest(request map[string]any, svc *service) map[string]any {
	id := request["id"]
	method, _ := request["method"].(string)
	params, _ := request["params"].(map[string]any)
	switch method {
	case "initialize":
		return jsonRPCResult(id, map[string]any{
			"protocolVersion": "2025-03-26",
			"serverInfo": map[string]any{
				"name":    "open-computer-use",
				"version": version,
			},
			"capabilities": map[string]any{"tools": map[string]any{"listChanged": false}},
			"instructions": serverInstructions,
		})
	case "notifications/initialized", "notifications/turn-ended":
		return nil
	case "ping":
		return jsonRPCResult(id, map[string]any{})
	case "tools/list":
		return jsonRPCResult(id, map[string]any{"tools": toolDefinitions()})
	case "tools/call":
		name, _ := params["name"].(string)
		arguments, _ := params["arguments"].(map[string]any)
		if arguments == nil {
			arguments = map[string]any{}
		}
		return jsonRPCResult(id, svc.callTool(name, arguments))
	default:
		if method == "" {
			return nil
		}
		return jsonRPCError(id, -32601, "Method not found: "+method)
	}
}

func jsonRPCResult(id any, result any) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": id, "result": result}
}

func jsonRPCError(id any, code int, message string) map[string]any {
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error":   map[string]any{"code": code, "message": message},
	}
}

func helpText(command string) string {
	switch command {
	case "mcp":
		return "Usage:\n  open-computer-use mcp\n\nStart the stdio MCP server.\n"
	case "call":
		return "Usage:\n  open-computer-use call <tool> [--args '<json-object>']\n  open-computer-use call --calls '<json-array>'\n\nThe JSON array form keeps all calls in one process so element_index state can be reused.\n"
	case "snapshot":
		return "Usage:\n  open-computer-use snapshot [--include-ax true|false] [--include-screenshot true|false] [--text-limit <positive-int|max>] [--max-tree-nodes <positive-int>] [--max-tree-depth <positive-int>] <app>\n\nPrint the current Linux AT-SPI snapshot for the target app.\n"
	default:
		return `Open Computer Use for Linux

Usage:
  open-computer-use [command] [options]

Commands:
  mcp                  Start the stdio MCP server.
  doctor               Print Linux runtime notes.
  list-apps            Print running apps with top-level windows.
  snapshot <app>       Print the current AT-SPI snapshot for an app.
  call <tool>           Call one tool, or run a JSON array of tool calls.
  help [command]       Show general or command-specific help.
  version              Print the CLI version.

Notes:
  The Linux runtime uses AT-SPI2 semantic actions first, then best-effort
  coordinate/key synthesis. Run it in the signed-in desktop session.
`
	}
}
