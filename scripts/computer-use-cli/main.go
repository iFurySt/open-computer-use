package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	cliName                  = "computer-use-cli"
	cliVersion               = "1.1.4"
	defaultTimeout           = 60 * time.Second
	pluginRootEnvVar         = "COMPUTER_USE_PLUGIN_ROOT"
	pluginVersionEnvVar      = "COMPUTER_USE_PLUGIN_VERSION"
	serverBinEnvVar          = "COMPUTER_USE_SERVER_BIN"
	defaultLegacyPluginRoot  = ".codex/plugins/computer-use"
	defaultPluginVersionsDir = ".codex/plugins/cache/openai-bundled/computer-use"
	defaultPluginManifest    = ".codex-plugin/plugin.json"
	defaultServerRelativeBin = "Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
	defaultTestPluginVersion = "1.0.750"
)

type commonFlags struct {
	transport      string
	pluginRoot     string
	pluginVersion  string
	serverBin      string
	appServerBin   string
	serverName     string
	cwd            string
	approvalPolicy string
	sandbox        string
	timeout        time.Duration
	pretty         bool
}

type resolvedTarget struct {
	PluginRoot string `json:"pluginRoot"`
	ServerBin  string `json:"serverBin"`
}

type toolCallSpec struct {
	Tool string         `json:"tool"`
	Args map[string]any `json:"args,omitempty"`
}

type toolCallOutput struct {
	Tool   string              `json:"tool"`
	Result *mcp.CallToolResult `json:"result"`
}

type pluginManifest struct {
	Version string `json:"version"`
}

type rpcSession struct {
	conn   mcp.Connection
	nextID int64
}

type initializeParams struct {
	Capabilities    initializeClientCapabilities `json:"capabilities"`
	ClientInfo      *mcp.Implementation          `json:"clientInfo"`
	ProtocolVersion string                       `json:"protocolVersion"`
}

type initializeClientCapabilities struct {
	Experimental map[string]any               `json:"experimental,omitempty"`
	Sampling     *mcp.SamplingCapabilities    `json:"sampling,omitempty"`
	Elicitation  *mcp.ElicitationCapabilities `json:"elicitation,omitempty"`
}

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout, os.Stderr); err != nil {
		if !errors.Is(err, flag.ErrHelp) {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
		}
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout io.Writer, stderr io.Writer) error {
	if len(args) == 0 {
		printRootUsage(stderr)
		return flag.ErrHelp
	}

	switch args[0] {
	case "resolve-server":
		return runResolveServer(ctx, args[1:], stdout, stderr)
	case "list-tools":
		return runListTools(ctx, args[1:], stdout, stderr)
	case "call":
		return runCall(ctx, args[1:], stdout, stderr)
	case "call-seq":
		return runCallSeq(ctx, args[1:], stdout, stderr)
	case "help", "-h", "--help":
		printRootUsage(stderr)
		return nil
	default:
		printRootUsage(stderr)
		return fmt.Errorf("unknown subcommand %q", args[0])
	}
}

func runResolveServer(_ context.Context, args []string, stdout io.Writer, stderr io.Writer) error {
	var flags commonFlags

	fs := flag.NewFlagSet("resolve-server", flag.ContinueOnError)
	fs.SetOutput(stderr)
	addCommonFlags(fs, &flags)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("resolve-server does not accept positional arguments")
	}

	target, err := resolveTarget(flags)
	if err != nil {
		return err
	}
	return writeJSON(stdout, target, flags.pretty)
}

func runListTools(ctx context.Context, args []string, stdout io.Writer, stderr io.Writer) error {
	var flags commonFlags

	fs := flag.NewFlagSet("list-tools", flag.ContinueOnError)
	fs.SetOutput(stderr)
	addCommonFlags(fs, &flags)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("list-tools does not accept positional arguments")
	}

	transport, err := resolveTransport(flags)
	if err != nil {
		return err
	}

	switch transport {
	case transportDirect:
		session, err := connect(ctx, flags)
		if err != nil {
			return err
		}
		defer session.Close()

		opCtx, cancel := context.WithTimeout(ctx, flags.timeout)
		defer cancel()

		result, err := session.listTools(opCtx)
		if err != nil {
			return fmt.Errorf("list tools: %w", err)
		}
		return writeJSON(stdout, result, flags.pretty)
	case transportAppServer:
		session, err := connectAppServer(ctx, flags)
		if err != nil {
			return err
		}
		defer session.Close()

		opCtx, cancel := context.WithTimeout(ctx, flags.timeout)
		defer cancel()

		result, err := session.listToolsViaAppServer(opCtx, flags.serverName)
		if err != nil {
			return fmt.Errorf("list tools via app-server: %w", err)
		}
		return writeJSON(stdout, result, flags.pretty)
	default:
		return fmt.Errorf("unsupported transport %q", transport)
	}
}

func runCall(ctx context.Context, args []string, stdout io.Writer, stderr io.Writer) error {
	var flags commonFlags
	var argsJSON string
	var argsFile string
	var toolName string

	parseArgs := args
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		toolName = args[0]
		parseArgs = args[1:]
	}

	fs := flag.NewFlagSet("call", flag.ContinueOnError)
	fs.SetOutput(stderr)
	addCommonFlags(fs, &flags)
	fs.StringVar(&argsJSON, "args", "", "JSON object arguments for tools/call")
	fs.StringVar(&argsFile, "args-file", "", "Path to a file containing JSON object arguments")
	if err := fs.Parse(parseArgs); err != nil {
		return err
	}

	if argsJSON != "" && argsFile != "" {
		return fmt.Errorf("use only one of --args or --args-file")
	}
	if toolName == "" {
		if fs.NArg() != 1 {
			return fmt.Errorf("usage: %s call [flags] <tool-name>", cliName)
		}
		toolName = fs.Arg(0)
	} else if fs.NArg() != 0 {
		return fmt.Errorf("usage: %s call [flags] <tool-name>", cliName)
	}
	toolArgs, err := readToolArgs(argsJSON, argsFile)
	if err != nil {
		return err
	}

	transport, err := resolveTransport(flags)
	if err != nil {
		return err
	}

	switch transport {
	case transportDirect:
		session, err := connect(ctx, flags)
		if err != nil {
			return err
		}
		defer session.Close()

		opCtx, cancel := context.WithTimeout(ctx, flags.timeout)
		defer cancel()

		result, err := session.callTool(opCtx, toolName, toolArgs)
		if err != nil {
			return fmt.Errorf("call tool %q: %w", toolName, err)
		}
		return writeJSON(stdout, result, flags.pretty)
	case transportAppServer:
		session, err := connectAppServer(ctx, flags)
		if err != nil {
			return err
		}
		defer session.Close()

		opCtx, cancel := context.WithTimeout(ctx, flags.timeout)
		defer cancel()

		result, err := session.callToolViaAppServer(opCtx, flags, toolName, toolArgs)
		if err != nil {
			return fmt.Errorf("call tool %q via app-server: %w", toolName, err)
		}
		return writeJSON(stdout, result, flags.pretty)
	default:
		return fmt.Errorf("unsupported transport %q", transport)
	}
}

func runCallSeq(ctx context.Context, args []string, stdout io.Writer, stderr io.Writer) error {
	var flags commonFlags
	var callsJSON string
	var callsFile string

	fs := flag.NewFlagSet("call-seq", flag.ContinueOnError)
	fs.SetOutput(stderr)
	addCommonFlags(fs, &flags)
	fs.StringVar(&callsJSON, "calls", "", "JSON array of sequential tool calls")
	fs.StringVar(&callsFile, "calls-file", "", "Path to a file containing a JSON array of sequential tool calls")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("usage: %s call-seq [flags]", cliName)
	}
	if callsJSON != "" && callsFile != "" {
		return fmt.Errorf("use only one of --calls or --calls-file")
	}

	calls, err := readToolCallSequence(callsJSON, callsFile)
	if err != nil {
		return err
	}

	transport, err := resolveTransport(flags)
	if err != nil {
		return err
	}

	switch transport {
	case transportDirect:
		session, err := connect(ctx, flags)
		if err != nil {
			return err
		}
		defer session.Close()

		results, err := callToolSequenceDirect(ctx, session, flags.timeout, calls)
		if err != nil {
			return err
		}
		return writeJSON(stdout, results, flags.pretty)
	case transportAppServer:
		session, err := connectAppServer(ctx, flags)
		if err != nil {
			return err
		}
		defer session.Close()

		results, err := callToolSequenceViaAppServer(ctx, session, flags, calls)
		if err != nil {
			return err
		}
		return writeJSON(stdout, results, flags.pretty)
	default:
		return fmt.Errorf("unsupported transport %q", transport)
	}
}

func addCommonFlags(fs *flag.FlagSet, flags *commonFlags) {
	fs.StringVar(&flags.transport, "transport", transportAuto, "Connection mode: auto, direct, or app-server")
	fs.StringVar(&flags.pluginRoot, "plugin-root", "", "Path to the installed computer-use plugin root")
	fs.StringVar(&flags.pluginVersion, "plugin-version", "", "Installed bundled computer-use version to select when auto-discovering; use latest for newest installed or host to leave app-server config untouched")
	fs.StringVar(&flags.serverBin, "server-bin", "", "Path to the SkyComputerUseClient executable")
	fs.StringVar(&flags.appServerBin, "app-server-bin", "", "Path to the Codex binary used for app-server proxy mode")
	fs.StringVar(&flags.serverName, "server-name", defaultAppServerServerName, "Server name to target in app-server mode")
	fs.StringVar(&flags.cwd, "cwd", "", "Working directory used for the ephemeral thread in app-server mode")
	fs.StringVar(&flags.approvalPolicy, "approval-policy", defaultAppServerApprovalPolicy, "Approval policy used in app-server mode")
	fs.StringVar(&flags.sandbox, "sandbox", defaultAppServerSandbox, "Sandbox mode used in app-server mode")
	fs.DurationVar(&flags.timeout, "timeout", defaultTimeout, "Timeout for connect and RPC operations")
	fs.BoolVar(&flags.pretty, "pretty", true, "Pretty-print JSON output")
}

func connect(ctx context.Context, flags commonFlags) (*rpcSession, error) {
	target, err := resolveTarget(flags)
	if err != nil {
		return nil, err
	}

	commandPath := target.ServerBin
	if relativePath, err := filepath.Rel(target.PluginRoot, target.ServerBin); err == nil && !strings.HasPrefix(relativePath, "..") {
		commandPath = relativePath
		if !strings.HasPrefix(commandPath, ".") {
			commandPath = "." + string(filepath.Separator) + commandPath
		}
	}

	cmd := exec.Command(commandPath, "mcp")
	cmd.Dir = target.PluginRoot
	cmd.Env = mcpServerEnv()
	cmd.Stderr = os.Stderr

	transport := &mcp.CommandTransport{Command: cmd}
	connectCtx, cancel := context.WithTimeout(ctx, flags.timeout)
	defer cancel()

	conn, err := transport.Connect(connectCtx)
	if err != nil {
		return nil, fmt.Errorf("connect to %q: %w", target.ServerBin, err)
	}
	session := &rpcSession{conn: conn}
	if err := session.initialize(connectCtx); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("initialize session: %w", err)
	}
	return session, nil
}

func (s *rpcSession) Close() error {
	return s.conn.Close()
}

func (s *rpcSession) initialize(ctx context.Context) error {
	var result mcp.InitializeResult
	if err := s.request(ctx, "initialize", initializeParams{
		Capabilities: initializeClientCapabilities{},
		ClientInfo: &mcp.Implementation{
			Name:    cliName,
			Version: cliVersion,
			Title:   cliName,
		},
		ProtocolVersion: "2025-06-18",
	}, &result); err != nil {
		return err
	}

	return s.notify(ctx, "notifications/initialized", &mcp.InitializedParams{})
}

func (s *rpcSession) listTools(ctx context.Context) (*mcp.ListToolsResult, error) {
	var result mcp.ListToolsResult
	if err := s.request(ctx, "tools/list", &mcp.ListToolsParams{}, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func callToolSequenceDirect(
	ctx context.Context,
	session *rpcSession,
	timeout time.Duration,
	calls []toolCallSpec,
) ([]toolCallOutput, error) {
	results := make([]toolCallOutput, 0, len(calls))
	for i, call := range calls {
		callCtx, cancel := context.WithTimeout(ctx, timeout)
		result, err := session.callTool(callCtx, call.Tool, call.Args)
		cancel()
		if err != nil {
			return nil, fmt.Errorf("call #%d %q: %w", i+1, call.Tool, err)
		}
		results = append(results, toolCallOutput{
			Tool:   call.Tool,
			Result: result,
		})
	}
	return results, nil
}

func (s *rpcSession) callTool(
	ctx context.Context,
	toolName string,
	toolArgs map[string]any,
) (*mcp.CallToolResult, error) {
	var result mcp.CallToolResult
	if err := s.request(ctx, "tools/call", &mcp.CallToolParams{
		Name:      toolName,
		Arguments: toolArgs,
	}, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func (s *rpcSession) request(ctx context.Context, method string, params any, out any) error {
	requestID := fmt.Sprintf("req-%d", atomic.AddInt64(&s.nextID, 1))
	id, err := jsonrpc.MakeID(requestID)
	if err != nil {
		return fmt.Errorf("build request id: %w", err)
	}

	paramsRaw, err := marshalParams(params)
	if err != nil {
		return fmt.Errorf("marshal params for %q: %w", method, err)
	}

	if err := s.conn.Write(ctx, &jsonrpc.Request{
		ID:     id,
		Method: method,
		Params: paramsRaw,
	}); err != nil {
		return fmt.Errorf("write %q request: %w", method, err)
	}

	for {
		message, err := s.conn.Read(ctx)
		if err != nil {
			return fmt.Errorf("read %q response: %w", method, err)
		}

		switch message := message.(type) {
		case *jsonrpc.Response:
			if fmt.Sprint(message.ID.Raw()) != requestID {
				continue
			}
			if message.Error != nil {
				return fmt.Errorf("%q failed: %w", method, message.Error)
			}
			if out == nil || len(message.Result) == 0 {
				return nil
			}
			if err := json.Unmarshal(message.Result, out); err != nil {
				return fmt.Errorf("decode %q response: %w", method, err)
			}
			return nil
		case *jsonrpc.Request:
			if message.ID.IsValid() {
				return fmt.Errorf("server sent unexpected request %q while waiting for %q", message.Method, method)
			}
		default:
			return fmt.Errorf("received unexpected JSON-RPC message type %T while waiting for %q", message, method)
		}
	}
}

func (s *rpcSession) notify(ctx context.Context, method string, params any) error {
	paramsRaw, err := marshalParams(params)
	if err != nil {
		return fmt.Errorf("marshal params for %q notification: %w", method, err)
	}

	if err := s.conn.Write(ctx, &jsonrpc.Request{
		Method: method,
		Params: paramsRaw,
	}); err != nil {
		return fmt.Errorf("write %q notification: %w", method, err)
	}
	return nil
}

func marshalParams(params any) (json.RawMessage, error) {
	if params == nil {
		return nil, nil
	}
	raw, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	return raw, nil
}

func mcpServerEnv() []string {
	allowed := []string{
		"HOME",
		"LOGNAME",
		"PATH",
		"SHELL",
		"USER",
		"__CF_USER_TEXT_ENCODING",
		"LANG",
		"LC_ALL",
		"TERM",
		"TMPDIR",
		"TZ",
	}

	env := make([]string, 0, len(allowed))
	for _, key := range allowed {
		if value, ok := os.LookupEnv(key); ok {
			env = append(env, key+"="+value)
		}
	}
	return env
}

func resolveTarget(flags commonFlags) (resolvedTarget, error) {
	serverBin := firstNonEmpty(flags.serverBin, os.Getenv(serverBinEnvVar))
	pluginRoot := firstNonEmpty(flags.pluginRoot, os.Getenv(pluginRootEnvVar))

	if serverBin != "" {
		resolvedServerBin, err := normalizePath(serverBin)
		if err != nil {
			return resolvedTarget{}, err
		}
		resolvedPluginRoot, err := derivePluginRoot(pluginRoot, resolvedServerBin)
		if err != nil {
			return resolvedTarget{}, err
		}
		return validateTarget(resolvedTarget{
			PluginRoot: resolvedPluginRoot,
			ServerBin:  resolvedServerBin,
		})
	}

	if pluginRoot == "" {
		pluginVersion, requirePluginVersion, err := resolvePluginVersionSelector(flags.pluginVersion)
		if err != nil {
			return resolvedTarget{}, err
		}

		pluginRoot, err = discoverPluginRoot(pluginVersion, requirePluginVersion)
		if err != nil {
			return resolvedTarget{}, err
		}
	}

	resolvedPluginRoot, err := normalizePath(pluginRoot)
	if err != nil {
		return resolvedTarget{}, err
	}

	return validateTarget(resolvedTarget{
		PluginRoot: resolvedPluginRoot,
		ServerBin:  filepath.Join(resolvedPluginRoot, defaultServerRelativeBin),
	})
}

func derivePluginRoot(pluginRoot, serverBin string) (string, error) {
	if pluginRoot != "" {
		return normalizePath(pluginRoot)
	}

	parts := strings.Split(filepath.Clean(serverBin), string(filepath.Separator))
	want := strings.Split(filepath.Clean(defaultServerRelativeBin), string(filepath.Separator))
	if len(parts) <= len(want) {
		return filepath.Dir(serverBin), nil
	}

	rootParts := parts[:len(parts)-len(want)]
	root := filepath.Join(rootParts...)
	if filepath.Join(root, defaultServerRelativeBin) == filepath.Clean(serverBin) {
		return root, nil
	}

	return filepath.Dir(serverBin), nil
}

func validateTarget(target resolvedTarget) (resolvedTarget, error) {
	if target.PluginRoot == "" {
		return resolvedTarget{}, fmt.Errorf("plugin root is empty")
	}
	if target.ServerBin == "" {
		return resolvedTarget{}, fmt.Errorf("server binary path is empty")
	}

	info, err := os.Stat(target.ServerBin)
	if err != nil {
		return resolvedTarget{}, fmt.Errorf("stat server binary %q: %w", target.ServerBin, err)
	}
	if info.IsDir() {
		return resolvedTarget{}, fmt.Errorf("server binary %q is a directory", target.ServerBin)
	}

	rootInfo, err := os.Stat(target.PluginRoot)
	if err != nil {
		return resolvedTarget{}, fmt.Errorf("stat plugin root %q: %w", target.PluginRoot, err)
	}
	if !rootInfo.IsDir() {
		return resolvedTarget{}, fmt.Errorf("plugin root %q is not a directory", target.PluginRoot)
	}

	return target, nil
}

func resolvePluginVersionSelector(flagValue string) (string, bool, error) {
	explicit := firstNonEmpty(flagValue, os.Getenv(pluginVersionEnvVar))
	if explicit == "" {
		return defaultTestPluginVersion, false, nil
	}

	switch strings.ToLower(strings.TrimSpace(explicit)) {
	case "latest", "newest", "auto", "host":
		return "", false, nil
	}

	cleanVersion := filepath.Clean(explicit)
	if strings.Contains(cleanVersion, string(filepath.Separator)) || cleanVersion == "." || cleanVersion == ".." {
		return "", false, fmt.Errorf("invalid plugin version %q: pass a version directory name, not a path", explicit)
	}

	return cleanVersion, true, nil
}

func discoverPluginRoot(preferredVersion string, requirePreferred bool) (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}

	parent := filepath.Join(homeDir, defaultPluginVersionsDir)
	if preferredVersion != "" {
		legacyPath, ok, err := discoverLegacyPluginRoot(homeDir, preferredVersion)
		if err != nil {
			return "", err
		}
		if ok {
			return legacyPath, nil
		}

		preferredPath := filepath.Join(parent, preferredVersion)
		if _, err := os.Stat(filepath.Join(preferredPath, defaultServerRelativeBin)); err == nil {
			return preferredPath, nil
		} else if requirePreferred {
			return "", fmt.Errorf(
				"requested computer-use plugin version %q was not found under %q; pass --plugin-version latest to use newest installed",
				preferredVersion,
				parent,
			)
		}
	}

	entries, err := os.ReadDir(parent)
	if err != nil {
		return "", fmt.Errorf("read %q: %w", parent, err)
	}

	type candidate struct {
		path    string
		modTime time.Time
		name    string
	}

	var candidates []candidate
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		path := filepath.Join(parent, entry.Name())
		serverBin := filepath.Join(path, defaultServerRelativeBin)
		if _, err := os.Stat(serverBin); err != nil {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			return "", fmt.Errorf("stat plugin candidate %q: %w", path, err)
		}

		candidates = append(candidates, candidate{
			path:    path,
			modTime: info.ModTime(),
			name:    entry.Name(),
		})
	}

	if len(candidates) == 0 {
		return "", fmt.Errorf(
			"no installed computer-use plugin found under %q; set %s or pass --plugin-root/--server-bin",
			parent,
			pluginRootEnvVar,
		)
	}

	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].modTime.Equal(candidates[j].modTime) {
			return candidates[i].name > candidates[j].name
		}
		return candidates[i].modTime.After(candidates[j].modTime)
	})

	return candidates[0].path, nil
}

func discoverLegacyPluginRoot(homeDir string, preferredVersion string) (string, bool, error) {
	if preferredVersion == "" {
		return "", false, nil
	}

	root := filepath.Join(homeDir, defaultLegacyPluginRoot)
	if _, err := os.Stat(filepath.Join(root, defaultServerRelativeBin)); err != nil {
		return "", false, nil
	}

	version, ok, err := readPluginManifestVersion(root)
	if err != nil {
		return "", false, err
	}
	if !ok || version != preferredVersion {
		return "", false, nil
	}

	return root, true, nil
}

func readPluginManifestVersion(pluginRoot string) (string, bool, error) {
	manifestPath := filepath.Join(pluginRoot, defaultPluginManifest)
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		if os.IsNotExist(err) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("read plugin manifest %q: %w", manifestPath, err)
	}

	var manifest pluginManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return "", false, fmt.Errorf("decode plugin manifest %q: %w", manifestPath, err)
	}
	if strings.TrimSpace(manifest.Version) == "" {
		return "", false, nil
	}
	return strings.TrimSpace(manifest.Version), true, nil
}

func readToolArgs(argsJSON, argsFile string) (map[string]any, error) {
	if argsFile != "" {
		data, err := os.ReadFile(argsFile)
		if err != nil {
			return nil, fmt.Errorf("read args file %q: %w", argsFile, err)
		}
		argsJSON = string(data)
	}

	if strings.TrimSpace(argsJSON) == "" {
		return nil, nil
	}

	decoder := json.NewDecoder(strings.NewReader(argsJSON))
	decoder.UseNumber()

	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, fmt.Errorf("decode tool args JSON: %w", err)
	}
	if decoder.More() {
		return nil, fmt.Errorf("tool args JSON must contain exactly one object")
	}

	object, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("tool args must be a JSON object")
	}
	return object, nil
}

func readToolCallSequence(callsJSON, callsFile string) ([]toolCallSpec, error) {
	if callsFile != "" {
		data, err := os.ReadFile(callsFile)
		if err != nil {
			return nil, fmt.Errorf("read calls file %q: %w", callsFile, err)
		}
		callsJSON = string(data)
	}

	if strings.TrimSpace(callsJSON) == "" {
		return nil, fmt.Errorf("missing --calls or --calls-file")
	}

	decoder := json.NewDecoder(strings.NewReader(callsJSON))
	decoder.UseNumber()

	var calls []toolCallSpec
	if err := decoder.Decode(&calls); err != nil {
		return nil, fmt.Errorf("decode tool call sequence JSON: %w", err)
	}
	if decoder.More() {
		return nil, fmt.Errorf("tool call sequence JSON must contain exactly one array")
	}
	if len(calls) == 0 {
		return nil, fmt.Errorf("tool call sequence must contain at least one call")
	}
	for i, call := range calls {
		if strings.TrimSpace(call.Tool) == "" {
			return nil, fmt.Errorf("call #%d is missing a non-empty tool name", i+1)
		}
	}
	return calls, nil
}

func writeJSON(w io.Writer, value any, pretty bool) error {
	var (
		data []byte
		err  error
	)

	if pretty {
		data, err = json.MarshalIndent(value, "", "  ")
	} else {
		data, err = json.Marshal(value)
	}
	if err != nil {
		return fmt.Errorf("marshal JSON output: %w", err)
	}

	if _, err := fmt.Fprintln(w, string(data)); err != nil {
		return fmt.Errorf("write output: %w", err)
	}
	return nil
}

func normalizePath(path string) (string, error) {
	if path == "" {
		return "", nil
	}

	if strings.HasPrefix(path, "~") {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve home directory: %w", err)
		}
		switch path {
		case "~":
			path = homeDir
		case "~/":
			path = homeDir
		default:
			path = filepath.Join(homeDir, strings.TrimPrefix(path, "~/"))
		}
	}

	absPath, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve absolute path for %q: %w", path, err)
	}
	return absPath, nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func printRootUsage(w io.Writer) {
	fmt.Fprintf(w, `%s talks to local computer-use tooling either directly over stdio MCP or via Codex app-server proxy mode.

Usage:
  %s resolve-server [flags]
  %s list-tools [flags]
  %s call [flags] <tool-name>
  %s call-seq [flags]

Examples:
  %s resolve-server
  %s list-tools
  %s call list_apps
  %s call list_apps --transport app-server
  %s call list_apps --transport direct --server-bin /path/to/open-computer-use
  %s call get_app_state --args '{"app":"TextEdit"}'
  %s call-seq --transport app-server --calls-file /tmp/calls.json

Environment:
  %s  Override the installed plugin root.
  %s Override the installed bundled plugin version; use "latest" for newest installed or "host" for app-server host config.
  %s   Override the SkyComputerUseClient executable path.
  %s      Override the Codex binary used for app-server mode.
`, cliName, cliName, cliName, cliName, cliName, cliName, cliName, cliName, cliName, cliName, cliName, cliName, pluginRootEnvVar, pluginVersionEnvVar, serverBinEnvVar, appServerBinEnvVar)
}
