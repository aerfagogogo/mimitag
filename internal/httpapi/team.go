package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	teamMessageMaxBytes  = 16 << 10
	teamResponseMaxBytes = 2 << 20
)

func newTeamHTTPClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// loopback 请求不得继承 HTTP_PROXY/HTTPS_PROXY，否则 OpenTag Token 可能离开本机。
	transport.Proxy = nil
	return &http.Client{
		Transport: transport,
		Timeout:   15 * time.Second,
		// OpenTag 仅允许配置为 loopback；禁止跟随重定向，避免本机服务把代理带到外部地址。
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

type teamChannel struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Type string `json:"type"`
}

type teamAgent struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	DisplayName string  `json:"displayName"`
	Runtime     string  `json:"runtime"`
	Status      string  `json:"status"`
	Activity    *string `json:"activity"`
	AvatarURL   *string `json:"avatarUrl"`
}

type teamMessage struct {
	ID         string  `json:"id"`
	Seq        int64   `json:"seq"`
	ChannelID  string  `json:"channelId"`
	SenderType string  `json:"senderType"`
	SenderName *string `json:"senderName"`
	Content    string  `json:"content"`
	CreatedAt  *string `json:"createdAt"`
}

type teamMessagesResponse struct {
	Messages []teamMessage `json:"messages"`
	MaxSeq   int64         `json:"maxSeq"`
	HasMore  bool          `json:"hasMore,omitempty"`
}

type teamSendRequest struct {
	Content string `json:"content"`
}

func (r *Router) teamBootstrapHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !r.requireTeamEnabled(w) {
		return
	}

	channel, err := r.resolveTeamChannel(req.Context())
	if err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	var agents []teamAgent
	if err := r.teamRequest(req.Context(), http.MethodGet, "/api/agents", nil, &agents); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"enabled": true,
		"channel": channel,
		"agents":  agents,
	})
}

func (r *Router) teamMessagesHandler(w http.ResponseWriter, req *http.Request) {
	if !r.requireTeamEnabled(w) {
		return
	}
	switch req.Method {
	case http.MethodGet:
		r.teamMessagesGet(w, req)
	case http.MethodPost:
		r.teamMessagesPost(w, req)
	default:
		methodNotAllowed(w)
	}
}

func (r *Router) teamMessagesGet(w http.ResponseWriter, req *http.Request) {
	since := int64(0)
	if raw := strings.TrimSpace(req.URL.Query().Get("since")); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 0 {
			writeError(w, http.StatusBadRequest, "since 必须是非负整数")
			return
		}
		since = parsed
	}

	channel, err := r.resolveTeamChannel(req.Context())
	if err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	if since == 0 {
		var history struct {
			Messages []teamMessage `json:"messages"`
			HasMore  bool          `json:"hasMore"`
		}
		path := "/api/messages/channel/" + url.PathEscape(channel.ID) + "?limit=100"
		if err := r.teamRequest(req.Context(), http.MethodGet, path, nil, &history); err != nil {
			writeTeamUpstreamError(w, err)
			return
		}
		maxSeq := int64(0)
		for _, message := range history.Messages {
			if message.Seq > maxSeq {
				maxSeq = message.Seq
			}
		}
		writeJSON(w, http.StatusOK, teamMessagesResponse{
			Messages: history.Messages,
			MaxSeq:   maxSeq,
			HasMore:  history.HasMore,
		})
		return
	}

	var delta teamMessagesResponse
	path := "/api/messages/sync?since=" + strconv.FormatInt(since, 10)
	if err := r.teamRequest(req.Context(), http.MethodGet, path, nil, &delta); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	filtered := delta.Messages[:0]
	for _, message := range delta.Messages {
		if message.ChannelID == channel.ID {
			filtered = append(filtered, message)
		}
	}
	delta.Messages = filtered
	writeJSON(w, http.StatusOK, delta)
}

func (r *Router) teamMessagesPost(w http.ResponseWriter, req *http.Request) {
	var payload teamSendRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	payload.Content = strings.TrimSpace(payload.Content)
	if payload.Content == "" {
		writeError(w, http.StatusBadRequest, "content 不能为空")
		return
	}
	if len([]byte(payload.Content)) > teamMessageMaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "团队消息最多 16 KiB")
		return
	}

	channel, err := r.resolveTeamChannel(req.Context())
	if err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	var result map[string]any
	if err := r.teamRequest(req.Context(), http.MethodPost, "/api/messages", map[string]string{
		"channelId": channel.ID,
		"content":   payload.Content,
	}, &result); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (r *Router) requireTeamEnabled(w http.ResponseWriter) bool {
	if r.cfg.Team.Enabled {
		return true
	}
	writeError(w, http.StatusNotFound, "团队协作未启用")
	return false
}

func (r *Router) resolveTeamChannel(ctx context.Context) (teamChannel, error) {
	var channels []teamChannel
	if err := r.teamRequest(ctx, http.MethodGet, "/api/channels", nil, &channels); err != nil {
		return teamChannel{}, err
	}
	target := strings.TrimSpace(r.cfg.Team.Channel)
	for _, channel := range channels {
		if channel.ID == target || strings.EqualFold(channel.Name, target) {
			return channel, nil
		}
	}
	return teamChannel{}, teamUpstreamError{
		status:  http.StatusBadGateway,
		message: fmt.Sprintf("OpenTag 中找不到团队频道 %q", target),
	}
}

func (r *Router) teamRequest(
	ctx context.Context,
	method string,
	path string,
	body any,
	target any,
) error {
	baseURL, err := url.Parse(strings.TrimRight(r.cfg.Team.BaseURL, "/"))
	if err != nil {
		return teamUpstreamError{status: http.StatusBadGateway, message: "OpenTag 地址无效"}
	}
	relative, err := url.Parse(path)
	if err != nil {
		return teamUpstreamError{status: http.StatusBadGateway, message: "OpenTag 请求路径无效"}
	}
	endpoint := baseURL.ResolveReference(relative)

	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(encoded)
	}
	upstreamReq, err := http.NewRequestWithContext(ctx, method, endpoint.String(), reader)
	if err != nil {
		return err
	}
	upstreamReq.Header.Set("Authorization", "Bearer "+r.cfg.Team.Token)
	upstreamReq.Header.Set("x-server-id", r.cfg.Team.ServerID)
	upstreamReq.Header.Set("Accept", "application/json")
	if body != nil {
		upstreamReq.Header.Set("Content-Type", "application/json")
	}

	response, err := r.teamClient.Do(upstreamReq)
	if err != nil {
		return teamUpstreamError{status: http.StatusBadGateway, message: "无法连接本机 OpenTag 服务"}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, teamResponseMaxBytes+1))
	if err != nil {
		return teamUpstreamError{status: http.StatusBadGateway, message: "读取 OpenTag 响应失败"}
	}
	if len(raw) > teamResponseMaxBytes {
		return teamUpstreamError{status: http.StatusBadGateway, message: "OpenTag 响应过大"}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var payload struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &payload)
		message := strings.TrimSpace(payload.Error)
		if message == "" {
			message = fmt.Sprintf("OpenTag 返回 HTTP %d", response.StatusCode)
		}
		return teamUpstreamError{status: http.StatusBadGateway, message: message}
	}
	if target == nil || len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return teamUpstreamError{status: http.StatusBadGateway, message: "OpenTag 返回了无法识别的数据"}
	}
	return nil
}

type teamUpstreamError struct {
	status  int
	message string
}

func (e teamUpstreamError) Error() string {
	return e.message
}

func writeTeamUpstreamError(w http.ResponseWriter, err error) {
	if upstream, ok := err.(teamUpstreamError); ok {
		writeError(w, upstream.status, upstream.message)
		return
	}
	writeError(w, http.StatusBadGateway, "团队服务暂时不可用")
}
