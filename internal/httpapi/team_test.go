package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
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
				"runtime": "codex", "model": "gpt-5.5", "machineId": "machine-id",
				"status": "active", "activity": "online",
			}})
		case "/api/servers/server-id/machines":
			writeJSON(w, http.StatusOK, map[string]any{"machines": []map[string]any{{
				"id": "machine-id", "name": "Mac mini", "status": "online",
				"runtimes": []string{"claude", "codex"},
			}}})
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

func TestTeamSessionsCreateIndependentOpenTagChannelsAndListThem(t *testing.T) {
	const descriptionPrefix = "mimitag-team:v1:"
	var channels []map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/api/agents":
			writeJSON(w, http.StatusOK, []map[string]any{
				{"id": "codex-id", "name": "codex", "displayName": "Codex", "runtime": "codex"},
				{"id": "claude-id", "name": "claude", "displayName": "Claude", "runtime": "claude"},
			})
		case "/api/channels":
			if req.Method == http.MethodGet {
				writeJSON(w, http.StatusOK, channels)
				return
			}
			var payload map[string]any
			if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			description, _ := payload["description"].(string)
			if !strings.HasPrefix(description, descriptionPrefix) {
				t.Fatalf("团队频道缺少会话元数据：%+v", payload)
			}
			channel := map[string]any{
				"id":            "channel-1",
				"name":          payload["name"],
				"type":          "channel",
				"description":   description,
				"createdAt":     "2026-07-28T15:00:00Z",
				"lastMessageAt": "2026-07-28T15:00:00Z",
			}
			channels = append(channels, channel)
			// OpenTag 的真实创建接口不会回传 description/timestamp。
			writeJSON(w, http.StatusCreated, map[string]any{
				"id": channel["id"], "name": channel["name"], "type": channel["type"],
			})
		default:
			http.NotFound(w, req)
		}
	}))
	t.Cleanup(upstream.Close)
	server := newTeamTestServer(t, upstream.URL)

	raw, _ := json.Marshal(map[string]any{
		"title":         "Demo · 团队协作",
		"workspaceId":   "demo-id",
		"workspaceName": "Demo",
		"workspacePath": "/tmp/demo",
		"agentIds":      []string{"codex-id", "claude-id"},
	})
	createReq := httptest.NewRequest(http.MethodPost, "/api/team/sessions", bytes.NewReader(raw))
	createReq.Header.Set("Authorization", "Bearer "+testToken)
	createReq.Header.Set("Content-Type", "application/json")
	createRec := httptest.NewRecorder()
	server.handler.ServeHTTP(createRec, createReq)
	if createRec.Code != http.StatusCreated {
		t.Fatalf("创建团队会话失败：status=%d body=%s", createRec.Code, createRec.Body.String())
	}
	var created teamSession
	if err := json.Unmarshal(createRec.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.ID != "channel-1" || created.WorkspaceID != "demo-id" || created.CreatedAt == nil {
		t.Fatalf("创建响应未形成可恢复会话：%+v", created)
	}

	listReq := httptest.NewRequest(http.MethodGet, "/api/team/sessions", nil)
	listReq.Header.Set("Authorization", "Bearer "+testToken)
	listRec := httptest.NewRecorder()
	server.handler.ServeHTTP(listRec, listReq)
	if listRec.Code != http.StatusOK ||
		!strings.Contains(listRec.Body.String(), `"id":"channel-1"`) ||
		!strings.Contains(listRec.Body.String(), `"workspaceId":"demo-id"`) {
		t.Fatalf("团队会话列表异常：status=%d body=%s", listRec.Code, listRec.Body.String())
	}
}

func TestTeamSessionMessagesAreScopedToSelectedChannel(t *testing.T) {
	description := teamSessionDescriptionPrefix + `{"workspaceId":"demo","workspaceName":"Demo","workspacePath":"/tmp/demo","title":"Demo · 团队协作","agentIds":["codex-id"]}`
	var requestedChannel string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/api/channels":
			writeJSON(w, http.StatusOK, []map[string]any{
				{"id": "old-channel", "name": "old", "type": "channel", "description": description},
				{"id": "new-channel", "name": "new", "type": "channel", "description": description},
			})
		case "/api/messages/channel/new-channel":
			requestedChannel = "new-channel"
			writeJSON(w, http.StatusOK, map[string]any{
				"messages": []map[string]any{
					{"id": "new-message", "seq": 2, "channelId": "new-channel", "senderType": "user", "content": "新会话"},
				},
			})
		case "/api/messages/channel/old-channel":
			t.Fatal("读取新会话时不应访问旧频道")
		default:
			http.NotFound(w, req)
		}
	}))
	t.Cleanup(upstream.Close)
	server := newTeamTestServer(t, upstream.URL)

	req := httptest.NewRequest(http.MethodGet, "/api/team/messages?session_id=new-channel", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || requestedChannel != "new-channel" ||
		!strings.Contains(rec.Body.String(), "新会话") {
		t.Fatalf("团队会话消息未隔离：status=%d channel=%q body=%s", rec.Code, requestedChannel, rec.Body.String())
	}
}

func TestTeamMessagesFiltersChannelAndSendsWorkspaceContext(t *testing.T) {
	var sent map[string]any
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
		case "/api/agents":
			writeJSON(w, http.StatusOK, []map[string]any{{
				"id": "agent-id", "name": "codex", "displayName": "Codex",
				"runtime": "codex", "status": "inactive", "activity": "offline",
			}})
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
	raw, _ := json.Marshal(map[string]any{"content": content, "agentIds": []string{"agent-id"}})
	postReq := httptest.NewRequest(http.MethodPost, "/api/team/messages", bytes.NewReader(raw))
	postReq.Header.Set("Authorization", "Bearer "+testToken)
	postReq.Header.Set("Content-Type", "application/json")
	postRec := httptest.NewRecorder()
	server.handler.ServeHTTP(postRec, postReq)
	if postRec.Code != http.StatusOK {
		t.Fatalf("发送消息失败：status=%d body=%s", postRec.Code, postRec.Body.String())
	}
	if sent["channelId"] != "channel-id" || sent["content"] != "@codex "+content {
		t.Fatalf("发送给 OpenTag 的消息异常：%+v", sent)
	}
}

func TestTeamAttachmentUsesOpenTagMultipartUpload(t *testing.T) {
	var gotChannelID string
	var gotFilename string
	var gotMIMEType string
	var gotData string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/api/channels":
			writeJSON(w, http.StatusOK, []map[string]any{{
				"id": "channel-id", "name": "all", "type": "channel",
			}})
		case "/api/attachments/upload":
			if err := req.ParseMultipartForm(4 << 20); err != nil {
				t.Fatal(err)
			}
			gotChannelID = req.FormValue("channelId")
			file, header, err := req.FormFile("files")
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			raw, err := io.ReadAll(file)
			if err != nil {
				t.Fatal(err)
			}
			gotFilename = header.Filename
			gotMIMEType = header.Header.Get("Content-Type")
			gotData = string(raw)
			writeJSON(w, http.StatusOK, map[string]any{"attachments": []map[string]any{{
				"id": "attachment-id", "filename": "photo.jpg",
				"mimeType": "image/jpeg", "sizeBytes": len(raw),
			}}})
		default:
			http.NotFound(w, req)
		}
	}))
	t.Cleanup(upstream.Close)
	server := newTeamTestServer(t, upstream.URL)

	raw, _ := json.Marshal(map[string]string{
		"filename": "photo.jpg", "mimeType": "image/jpeg",
		"dataBase64": base64.StdEncoding.EncodeToString([]byte("image-data")),
	})
	req := httptest.NewRequest(http.MethodPost, "/api/team/attachments", bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+testToken)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("附件上传失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	if gotChannelID != "channel-id" || gotFilename != "photo.jpg" ||
		gotMIMEType != "image/jpeg" || gotData != "image-data" {
		t.Fatalf(
			"OpenTag multipart 不匹配：channel=%q filename=%q mime=%q data=%q",
			gotChannelID, gotFilename, gotMIMEType, gotData,
		)
	}
}

func TestTeamAttachmentDownloadProxiesAuthenticatedOpenTagImage(t *testing.T) {
	var gotAuthorization string
	var gotServerID string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/api/attachments/attachment-id" {
			http.NotFound(w, req)
			return
		}
		gotAuthorization = req.Header.Get("Authorization")
		gotServerID = req.Header.Get("x-server-id")
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("png-data"))
	}))
	t.Cleanup(upstream.Close)
	server := newTeamTestServer(t, upstream.URL)

	req := httptest.NewRequest(http.MethodGet, "/api/team/attachments/attachment-id", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("附件下载失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Content-Type") != "image/png" || rec.Body.String() != "png-data" {
		t.Fatalf("附件响应不匹配：contentType=%q body=%q", rec.Header().Get("Content-Type"), rec.Body.String())
	}
	if gotAuthorization != "Bearer opentag-token" || gotServerID != "server-id" {
		t.Fatalf("OpenTag 附件鉴权头异常：authorization=%q server=%q", gotAuthorization, gotServerID)
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
