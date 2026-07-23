package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestTeamBootstrapKeepsOpenTagCredentialsOnAgentd(t *testing.T) {
	var receivedAuthorization string
	var receivedServerID string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		receivedAuthorization = req.Header.Get("Authorization")
		receivedServerID = req.Header.Get("x-server-id")
		switch req.URL.Path {
		case "/api/channels":
			writeJSON(w, http.StatusOK, []map[string]any{{
				"id": "channel-id", "name": "all", "type": "channel",
			}})
		case "/api/agents":
			writeJSON(w, http.StatusOK, []map[string]any{{
				"id": "agent-id", "name": "codex", "displayName": "Codex",
				"runtime": "codex", "status": "active", "activity": "online",
			}})
		default:
			http.NotFound(w, req)
		}
	}))
	t.Cleanup(upstream.Close)

	server := newTeamTestServer(t, upstream.URL)
	req := httptest.NewRequest(http.MethodGet, "/api/team/bootstrap", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("bootstrap 失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	if receivedAuthorization != "Bearer opentag-token" || receivedServerID != "server-id" {
		t.Fatalf("OpenTag 鉴权头异常：authorization=%q server=%q", receivedAuthorization, receivedServerID)
	}
	if strings.Contains(rec.Body.String(), "opentag-token") || strings.Contains(rec.Body.String(), "server-id") {
		t.Fatal("移动端响应不得泄露 OpenTag 凭据")
	}
}

func TestTeamMessagesFiltersChannelAndSendsWorkspaceContext(t *testing.T) {
	var sent map[string]string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/api/channels":
			writeJSON(w, http.StatusOK, []map[string]any{{
				"id": "channel-id", "name": "all", "type": "channel",
			}})
		case "/api/messages/sync":
			writeJSON(w, http.StatusOK, map[string]any{
				"maxSeq": 12,
				"messages": []map[string]any{
					{"id": "keep", "seq": 11, "channelId": "channel-id", "senderType": "agent", "senderName": "codex", "content": "done"},
					{"id": "drop", "seq": 12, "channelId": "other", "senderType": "agent", "senderName": "claude", "content": "private"},
				},
			})
		case "/api/messages":
			if err := json.NewDecoder(req.Body).Decode(&sent); err != nil {
				t.Fatal(err)
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": "message-id", "seq": 13})
		default:
			http.NotFound(w, req)
		}
	}))
	t.Cleanup(upstream.Close)
	server := newTeamTestServer(t, upstream.URL)

	getReq := httptest.NewRequest(http.MethodGet, "/api/team/messages?since=10", nil)
	getReq.Header.Set("Authorization", "Bearer "+testToken)
	getRec := httptest.NewRecorder()
	server.handler.ServeHTTP(getRec, getReq)
	if getRec.Code != http.StatusOK || strings.Contains(getRec.Body.String(), "private") {
		t.Fatalf("增量消息过滤失败：status=%d body=%s", getRec.Code, getRec.Body.String())
	}

	content := "[Mimi 工作区：demo — /tmp/demo]\n请检查测试"
	raw, _ := json.Marshal(map[string]string{"content": content})
	postReq := httptest.NewRequest(http.MethodPost, "/api/team/messages", bytes.NewReader(raw))
	postReq.Header.Set("Authorization", "Bearer "+testToken)
	postReq.Header.Set("Content-Type", "application/json")
	postRec := httptest.NewRecorder()
	server.handler.ServeHTTP(postRec, postReq)
	if postRec.Code != http.StatusOK {
		t.Fatalf("发送消息失败：status=%d body=%s", postRec.Code, postRec.Body.String())
	}
	if sent["channelId"] != "channel-id" || sent["content"] != content {
		t.Fatalf("发送给 OpenTag 的消息异常：%+v", sent)
	}
}

func TestTeamEndpointIsOptionalAndAuthenticated(t *testing.T) {
	server := newTestServer(t)

	unauthenticated := httptest.NewRecorder()
	server.handler.ServeHTTP(
		unauthenticated,
		httptest.NewRequest(http.MethodGet, "/api/team/bootstrap", nil),
	)
	if unauthenticated.Code != http.StatusUnauthorized {
		t.Fatalf("未鉴权请求应被拒绝，实际 %d", unauthenticated.Code)
	}

	disabledReq := httptest.NewRequest(http.MethodGet, "/api/team/bootstrap", nil)
	disabledReq.Header.Set("Authorization", "Bearer "+testToken)
	disabled := httptest.NewRecorder()
	server.handler.ServeHTTP(disabled, disabledReq)
	if disabled.Code != http.StatusNotFound {
		t.Fatalf("未启用团队协作时应返回 404，实际 %d", disabled.Code)
	}
}

func newTeamTestServer(t *testing.T, baseURL string) testServer {
	t.Helper()
	return newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Team = config.TeamConfig{
			Enabled:  true,
			BaseURL:  baseURL,
			Token:    "opentag-token",
			ServerID: "server-id",
			Channel:  "all",
		}
	})
}
