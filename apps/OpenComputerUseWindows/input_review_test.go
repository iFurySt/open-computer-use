package main

import (
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
