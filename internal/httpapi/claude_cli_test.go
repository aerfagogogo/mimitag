package httpapi

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func writeClaudeCLIFile(t *testing.T, dir, sessionID, cwd, firstMessage string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, sessionID+".jsonl")
	body := `{"type":"user","message":{"role":"user","content":"` + firstMessage + `"},"uuid":"u-` + sessionID + `","timestamp":"2026-07-29T10:00:00Z","cwd":"` + cwd + `","gitBranch":"main","version":"2.1.150"}` + "\n"
	body += `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]},"uuid":"a-` + sessionID + `","parentUuid":"u-` + sessionID + `","timestamp":"2026-07-29T10:00:05Z"}` + "\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	_ = os.Chtimes(path, now, now)
	return path
}

func TestClaudeCLIListReturnsSessions(t *testing.T) {
	projectsDir := t.TempDir()
	writeClaudeCLIFile(t, filepath.Join(projectsDir, "-Users-me-code-foo"), "sess-1", "/Users/me/code/foo", "hello world")

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.ClaudeCLI = config.ClaudeCLIConfig{Enabled: true, ProjectsDir: projectsDir}
	})

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/claude-cli/sessions", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	sessions, ok := body["sessions"].([]any)
	if !ok {
		t.Fatalf("sessions field missing or wrong type: %+v", body)
	}
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}
	first := sessions[0].(map[string]any)
	if first["id"] != "sess-1" {
		t.Fatalf("id wrong: %v", first["id"])
	}
	if first["project_path"] != "/Users/me/code/foo" {
		t.Fatalf("project_path wrong: %v", first["project_path"])
	}
	if first["source"] != "claude-cli" {
		t.Fatalf("source wrong: %v", first["source"])
	}
	if !strings.Contains(first["preview"].(string), "hello world") {
		t.Fatalf("preview wrong: %v", first["preview"])
	}
}

func TestClaudeCLIMessagesReturnsPagination(t *testing.T) {
	projectsDir := t.TempDir()
	writeClaudeCLIFile(t, filepath.Join(projectsDir, "-Users-me-code-foo"), "sess-1", "/Users/me/code/foo", "hi")

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.ClaudeCLI = config.ClaudeCLIConfig{Enabled: true, ProjectsDir: projectsDir}
	})

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/claude-cli/sessions/sess-1/messages?limit=10", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["session_id"] != "sess-1" {
		t.Fatalf("session_id echo wrong: %v", body["session_id"])
	}
	messages, ok := body["messages"].([]any)
	if !ok {
		t.Fatalf("messages field missing: %+v", body)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(messages))
	}
	firstMsg := messages[0].(map[string]any)
	if firstMsg["role"] != "user" || firstMsg["content"] != "hi" {
		t.Fatalf("first message wrong: %+v", firstMsg)
	}
}

func TestClaudeCLIMessagesReturns404ForUnknownSession(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.ClaudeCLI = config.ClaudeCLIConfig{Enabled: true, ProjectsDir: t.TempDir()}
	})

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/claude-cli/sessions/missing/messages", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestClaudeCLIRoutesRequireAuth(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.ClaudeCLI = config.ClaudeCLIConfig{Enabled: true, ProjectsDir: t.TempDir()}
	})

	unauth := httptest.NewRecorder()
	server.handler.ServeHTTP(unauth, httptest.NewRequest(http.MethodGet, "/api/claude-cli/sessions", nil))
	if unauth.Code == http.StatusOK {
		t.Fatalf("未鉴权请求不应返回 200，got=%d", unauth.Code)
	}

	unauthMsg := httptest.NewRecorder()
	server.handler.ServeHTTP(unauthMsg, httptest.NewRequest(http.MethodGet, "/api/claude-cli/sessions/any/messages", nil))
	if unauthMsg.Code == http.StatusOK {
		t.Fatalf("未鉴权 messages 请求不应返回 200，got=%d", unauthMsg.Code)
	}
}

func TestClaudeCLIReturnsNotFoundWhenDisabled(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.ClaudeCLI = config.ClaudeCLIConfig{Enabled: false}
	})

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/claude-cli/sessions", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("disabled → 404，got=%d body=%s", rec.Code, rec.Body.String())
	}

	msgRec := httptest.NewRecorder()
	server.handler.ServeHTTP(msgRec, authedRequest(t, http.MethodGet, "/api/claude-cli/sessions/whatever/messages", nil))
	if msgRec.Code != http.StatusNotFound {
		t.Fatalf("disabled messages → 404，got=%d body=%s", msgRec.Code, msgRec.Body.String())
	}
}

func TestClaudeCLIMessagesRejectsBadLimit(t *testing.T) {
	projectsDir := t.TempDir()
	writeClaudeCLIFile(t, filepath.Join(projectsDir, "-tmp"), "sess-1", "/tmp", "hi")
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.ClaudeCLI = config.ClaudeCLIConfig{Enabled: true, ProjectsDir: projectsDir}
	})

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/claude-cli/sessions/sess-1/messages?limit=-3", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("negative limit → 400, got=%d", rec.Code)
	}
}
