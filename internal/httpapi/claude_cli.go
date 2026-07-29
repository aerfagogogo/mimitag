package httpapi

import (
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"

	"github.com/gaixianggeng/mimi-remote/internal/claudehistory"
)

// claudeCLIStore 惰性构造，且服务开关关闭时不建。请通过 Router.claudeCLI() 访问。
type claudeCLIStoreHolder struct {
	once sync.Once
	inst *claudehistory.Store
}

// claudeCLI 返回当前 Router 关联的 Claude CLI 只读会话观测 Store。
// 如果 config.ClaudeCLI.Enabled 为 false，返回 nil，handler 一律 404，
// 让开关既控制端点可见性也保证不会启动任何后台文件扫描。
func (r *Router) claudeCLI() *claudehistory.Store {
	if !r.cfg.ClaudeCLI.Enabled {
		return nil
	}
	r.claudeCLIHolder.once.Do(func() {
		r.claudeCLIHolder.inst = claudehistory.NewStore(strings.TrimSpace(r.cfg.ClaudeCLI.ProjectsDir))
	})
	return r.claudeCLIHolder.inst
}

func (r *Router) claudeCLISessionsHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	store := r.claudeCLI()
	if store == nil {
		writeError(w, http.StatusNotFound, "Claude CLI 观测未启用")
		return
	}
	sessions, err := store.List()
	if err != nil {
		writeError(w, http.StatusBadGateway, "读取 Claude CLI 会话列表失败")
		return
	}
	// 兜底避免 nil 序列化成 null；iOS 端更好处理空数组。
	if sessions == nil {
		sessions = []claudehistory.Session{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions})
}

func (r *Router) claudeCLIMessagesHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	store := r.claudeCLI()
	if store == nil {
		writeError(w, http.StatusNotFound, "Claude CLI 观测未启用")
		return
	}
	sessionID := strings.TrimSpace(req.URL.Path)
	const prefix = "/api/claude-cli/sessions/"
	const suffix = "/messages"
	if !strings.HasPrefix(sessionID, prefix) || !strings.HasSuffix(sessionID, suffix) {
		http.NotFound(w, req)
		return
	}
	sessionID = strings.TrimSuffix(strings.TrimPrefix(sessionID, prefix), suffix)
	if sessionID == "" || strings.ContainsAny(sessionID, "/\x00") {
		http.NotFound(w, req)
		return
	}

	offset, err := parseNonNegativeQueryInt(req, "offset", 0)
	if err != nil {
		writeError(w, http.StatusBadRequest, "offset 必须是非负整数")
		return
	}
	limit, err := parseNonNegativeQueryInt(req, "limit", 0)
	if err != nil {
		writeError(w, http.StatusBadRequest, "limit 必须是非负整数")
		return
	}

	messages, err := store.Read(sessionID, offset, limit)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, req)
			return
		}
		writeError(w, http.StatusBadGateway, "读取 Claude CLI 会话历史失败")
		return
	}
	if messages == nil {
		messages = []claudehistory.Message{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session_id": sessionID,
		"offset":     offset,
		"limit":      limit,
		"messages":   messages,
	})
}

func parseNonNegativeQueryInt(req *http.Request, name string, def int) (int, error) {
	raw := strings.TrimSpace(req.URL.Query().Get(name))
	if raw == "" {
		return def, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return 0, errBadQueryInt
	}
	return value, nil
}

var errBadQueryInt = &httpQueryError{message: "invalid int"}

type httpQueryError struct{ message string }

func (e *httpQueryError) Error() string { return e.message }

