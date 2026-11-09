package main

import (
	"errors"
	"strings"
	"testing"
)

func TestActionPinsObservedWindowAndForwardsKeyboardMethod(t *testing.T) {
	for _, method := range []string{"auto", "global"} {
		t.Run(method, func(t *testing.T) {
			t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "1")
			svc := newService()
			svc.rememberSnapshot("fixture", &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, WindowHandle: 1234})
			var request psRequest
			svc.runBridge = func(r psRequest) (*psResponse, error) {
				request = r
				return &psResponse{OK: true, Snapshot: &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, WindowHandle: 1234}}, nil
			}
			result := svc.callTool("press_key", map[string]any{"app": "fixture", "key": "ctrl+a", "key_method": method})
			if result.IsError || request.ExpectedPID != 42 || request.WindowHandle != 1234 || request.KeyMethod != method {
				t.Fatalf("action lost observed identity or explicit method: %#v, %#v", request, result)
			}
		})
	}
}

func TestGlobalClickNeedsImageEvenWhenElementIndexExists(t *testing.T) {
	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "1")
	svc := newService()
	svc.rememberSnapshot("fixture", &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, ScreenshotOmitted: true, Elements: []elementRecord{{Index: 0}}})
	svc.runBridge = func(psRequest) (*psResponse, error) {
		t.Fatal("image-less global click reached bridge")
		return nil, nil
	}
	result := svc.callTool("click", map[string]any{"app": "fixture", "element_index": "0", "click_method": "global"})
	if !result.IsError || !strings.Contains(result.Content[0].Text, "screenshot") {
		t.Fatalf("%#v", result)
	}
}

func TestDeliveredActionWithFailedObservationIsNotAnError(t *testing.T) {
	svc := newService()
	svc.rememberSnapshot("fixture", &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, WindowHandle: 1234, Elements: []elementRecord{{Index: 0}}})
	svc.runBridge = func(psRequest) (*psResponse, error) {
		return &psResponse{OK: true, ObservationError: `appNotFound("fixture")`}, nil
	}
	result := svc.callTool("click", map[string]any{"app": "fixture", "element_index": "0"})
	if result.IsError || !strings.Contains(result.Content[0].Text, "click action was delivered") || !strings.Contains(result.Content[0].Text, `appNotFound("fixture")`) {
		t.Fatalf("delivered click reported as failed or without its observation error: %#v", result)
	}
	if svc.currentSnapshot("fixture") != nil || svc.currentSnapshot("42") != nil {
		t.Fatal("indexes from before the action survived a failed observation")
	}
	next := svc.callTool("click", map[string]any{"app": "fixture", "element_index": "0"})
	if !next.IsError || !strings.Contains(next.Content[0].Text, "Run get_app_state") {
		t.Fatalf("stale index accepted after a failed observation: %#v", next)
	}
}

func TestUncertainActionInvalidatesAllAliases(t *testing.T) {
	for _, failure := range []string{"timeout", "broken response", "missing snapshot", "action error"} {
		t.Run(failure, func(t *testing.T) {
			svc := newService()
			old := &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, Elements: []elementRecord{{Index: 0}}}
			svc.rememberSnapshot("custom", old)
			svc.rememberSnapshot("alias", &appSnapshot{App: old.App})
			other := &appSnapshot{App: appDescriptor{Name: "other", PID: 43}}
			svc.rememberSnapshot("other", other)
			calls := 0
			svc.runBridge = func(psRequest) (*psResponse, error) {
				calls++
				switch failure {
				case "timeout":
					return nil, errors.New("timed out")
				case "broken response":
					return nil, errors.New("invalid JSON")
				case "action error":
					return &psResponse{Error: "delivery failed"}, nil
				default:
					return &psResponse{OK: true}, nil
				}
			}
			result := svc.callTool("click", map[string]any{"app": "custom", "element_index": "0"})
			if !result.IsError {
				t.Fatalf("uncertain action reported success: %#v", result)
			}
			if failure == "timeout" || failure == "broken response" {
				if !strings.Contains(result.Content[0].Text, "outcome is unknown") {
					t.Fatal(result)
				}
			}
			for _, alias := range []string{"custom", "fixture", "42", "alias"} {
				if svc.currentSnapshot(alias) != nil {
					t.Fatalf("stale alias survived: %s", alias)
				}
			}
			if svc.currentSnapshot("other") != other {
				t.Fatal("unrelated app invalidated")
			}
			next := svc.callTool("click", map[string]any{"app": "42", "element_index": "0"})
			if !next.IsError || calls != 1 {
				t.Fatal("stale action reached bridge")
			}
		})
	}
}

func TestObservationWarningCannotTurnGetStateIntoSuccess(t *testing.T) {
	svc := newService()
	svc.rememberSnapshot("fixture", &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}})
	svc.runBridge = func(psRequest) (*psResponse, error) {
		return &psResponse{OK: true, ObservationError: "window closed"}, nil
	}
	result := svc.callTool("get_app_state", map[string]any{"app": "fixture"})
	if !result.IsError || svc.currentSnapshot("42") != nil {
		t.Fatalf("failed observation accepted: %#v", result)
	}
}
