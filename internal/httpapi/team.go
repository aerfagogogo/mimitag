package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	teamMessageMaxBytes            = 16 << 10
	teamResponseMaxBytes           = 2 << 20
	teamAttachmentResponseMaxBytes = 4 << 20
	teamSessionDescriptionPrefix   = "mimitag-team:v1:"
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
	ID            string  `json:"id"`
	Name          string  `json:"name"`
	Description   *string `json:"description"`
	Type          string  `json:"type"`
	CreatedAt     *string `json:"createdAt"`
	LastMessageAt *string `json:"lastMessageAt"`
}

type teamSessionMetadata struct {
	WorkspaceID   string   `json:"workspaceId"`
	WorkspaceName string   `json:"workspaceName"`
	WorkspacePath string   `json:"workspacePath"`
	Title         string   `json:"title"`
	AgentIDs      []string `json:"agentIds"`
}

type teamSession struct {
	ID            string   `json:"id"`
	ChannelID     string   `json:"channelId"`
	Title         string   `json:"title"`
	WorkspaceID   string   `json:"workspaceId"`
	WorkspaceName string   `json:"workspaceName"`
	WorkspacePath string   `json:"workspacePath"`
	AgentIDs      []string `json:"agentIds"`
	CreatedAt     *string  `json:"createdAt"`
	UpdatedAt     *string  `json:"updatedAt"`
}

type teamSessionCreateRequest struct {
	Title         string   `json:"title"`
	WorkspaceID   string   `json:"workspaceId"`
	WorkspaceName string   `json:"workspaceName"`
	WorkspacePath string   `json:"workspacePath"`
	AgentIDs      []string `json:"agentIds"`
}

type teamAgent struct {
	ID                string  `json:"id"`
	Name              string  `json:"name"`
	DisplayName       string  `json:"displayName"`
	Runtime           string  `json:"runtime"`
	Model             *string `json:"model"`
	MachineID         *string `json:"machineId"`
	Status            string  `json:"status"`
	Activity          *string `json:"activity"`
	AvatarURL         *string `json:"avatarUrl"`
	Reachable         bool    `json:"reachable"`
	UnavailableReason *string `json:"unavailableReason,omitempty"`
}

type teamMachine struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Hostname *string  `json:"hostname"`
	Status   string   `json:"status"`
	Runtimes []string `json:"runtimes"`
}

type teamMachinesResponse struct {
	Machines []teamMachine `json:"machines"`
}

type teamAttachment struct {
	ID        string `json:"id"`
	Filename  string `json:"filename"`
	MIMEType  string `json:"mimeType"`
	SizeBytes int64  `json:"sizeBytes"`
}

type teamMessage struct {
	ID          string           `json:"id"`
	Seq         int64            `json:"seq"`
	ChannelID   string           `json:"channelId"`
	SenderType  string           `json:"senderType"`
	SenderName  *string          `json:"senderName"`
	Content     string           `json:"content"`
	CreatedAt   *string          `json:"createdAt"`
	Attachments []teamAttachment `json:"attachments,omitempty"`
}

type teamMessagesResponse struct {
	Messages []teamMessage `json:"messages"`
	MaxSeq   int64         `json:"maxSeq"`
	HasMore  bool          `json:"hasMore,omitempty"`
}

type teamSendRequest struct {
	SessionID     string   `json:"sessionId"`
	Content       string   `json:"content"`
	AgentIDs      []string `json:"agentIds,omitempty"`
	AttachmentIDs []string `json:"attachmentIds,omitempty"`
	AsTask        bool     `json:"asTask,omitempty"`
}

type teamAttachmentUploadRequest struct {
	SessionID  string `json:"sessionId"`
	Filename   string `json:"filename"`
	MIMEType   string `json:"mimeType"`
	DataBase64 string `json:"dataBase64"`
}

func (r *Router) teamBootstrapHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !r.requireTeamEnabled(w) {
		return
	}

	channel, err := r.resolveTeamChannel(req.Context(), req.URL.Query().Get("session_id"))
	if err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	var agents []teamAgent
	if err := r.teamRequest(req.Context(), http.MethodGet, "/api/agents", nil, &agents); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	var machines teamMachinesResponse
	machinesPath := "/api/servers/" + url.PathEscape(r.cfg.Team.ServerID) + "/machines"
	if err := r.teamRequest(req.Context(), http.MethodGet, machinesPath, nil, &machines); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	machinesByID := make(map[string]teamMachine, len(machines.Machines))
	for _, machine := range machines.Machines {
		machinesByID[machine.ID] = machine
	}
	for index := range agents {
		reachable, reason := teamAgentReachability(agents[index], machinesByID)
		agents[index].Reachable = reachable
		agents[index].UnavailableReason = reason
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"enabled":  true,
		"channel":  channel,
		"agents":   agents,
		"machines": machines.Machines,
	})
}

func (r *Router) teamSessionsHandler(w http.ResponseWriter, req *http.Request) {
	if !r.requireTeamEnabled(w) {
		return
	}
	switch req.Method {
	case http.MethodGet:
		sessions, err := r.listTeamSessions(req.Context())
		if err != nil {
			writeTeamUpstreamError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions})
	case http.MethodPost:
		r.teamSessionCreate(w, req)
	default:
		methodNotAllowed(w)
	}
}

func (r *Router) teamSessionCreate(w http.ResponseWriter, req *http.Request) {
	var payload teamSessionCreateRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	payload.Title = strings.TrimSpace(payload.Title)
	payload.WorkspaceID = strings.TrimSpace(payload.WorkspaceID)
	payload.WorkspaceName = strings.TrimSpace(payload.WorkspaceName)
	payload.WorkspacePath = strings.TrimSpace(payload.WorkspacePath)
	if payload.WorkspaceID == "" || payload.WorkspaceName == "" || payload.WorkspacePath == "" {
		writeError(w, http.StatusBadRequest, "workspaceId、workspaceName 和 workspacePath 均不能为空")
		return
	}
	if payload.Title == "" {
		payload.Title = payload.WorkspaceName + " · 团队协作"
	}
	if len(payload.Title) > 160 || len(payload.WorkspacePath) > 4096 {
		writeError(w, http.StatusBadRequest, "团队会话信息过长")
		return
	}

	var agents []teamAgent
	if err := r.teamRequest(req.Context(), http.MethodGet, "/api/agents", nil, &agents); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	validAgentIDs := make(map[string]struct{}, len(agents))
	for _, agent := range agents {
		validAgentIDs[agent.ID] = struct{}{}
	}
	agentIDs := make([]string, 0, len(payload.AgentIDs))
	seen := make(map[string]struct{}, len(payload.AgentIDs))
	for _, agentID := range payload.AgentIDs {
		agentID = strings.TrimSpace(agentID)
		if _, ok := validAgentIDs[agentID]; !ok {
			writeError(w, http.StatusBadRequest, "选择了 OpenTag 中不存在的 Agent")
			return
		}
		if _, ok := seen[agentID]; ok {
			continue
		}
		seen[agentID] = struct{}{}
		agentIDs = append(agentIDs, agentID)
	}
	if len(agentIDs) == 0 {
		for _, agent := range agents {
			if runtime := strings.ToLower(strings.TrimSpace(agent.Runtime)); runtime == "claude" || runtime == "codex" {
				agentIDs = append(agentIDs, agent.ID)
			}
		}
	}
	if len(agentIDs) == 0 {
		writeError(w, http.StatusBadRequest, "没有可加入团队会话的 Agent")
		return
	}

	metadata := teamSessionMetadata{
		WorkspaceID:   payload.WorkspaceID,
		WorkspaceName: payload.WorkspaceName,
		WorkspacePath: payload.WorkspacePath,
		Title:         payload.Title,
		AgentIDs:      agentIDs,
	}
	rawMetadata, err := json.Marshal(metadata)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "创建团队会话失败")
		return
	}
	suffix := make([]byte, 4)
	if _, err := rand.Read(suffix); err != nil {
		writeError(w, http.StatusInternalServerError, "创建团队会话失败")
		return
	}
	channelName := fmt.Sprintf("mimitag-team-%d-%s", time.Now().UnixMilli(), hex.EncodeToString(suffix))
	description := teamSessionDescriptionPrefix + string(rawMetadata)
	var channel teamChannel
	if err := r.teamRequest(req.Context(), http.MethodPost, "/api/channels", map[string]any{
		"name":        channelName,
		"description": description,
		"visibility":  "private",
		"agentIds":    agentIDs,
	}, &channel); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	// OpenTag 的创建接口只返回频道基本字段；补回创建请求中的元数据，
	// 让客户端无需再做一次列表请求即可打开刚创建的独立会话。
	now := time.Now().UTC().Format(time.RFC3339Nano)
	channel.Description = &description
	channel.CreatedAt = &now
	channel.LastMessageAt = &now
	session, ok := teamSessionFromChannel(channel)
	if !ok {
		writeError(w, http.StatusBadGateway, "OpenTag 创建了无法识别的团队频道")
		return
	}
	writeJSON(w, http.StatusCreated, session)
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

	channel, err := r.resolveTeamChannel(req.Context(), req.URL.Query().Get("session_id"))
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
	if payload.Content == "" && len(payload.AttachmentIDs) == 0 {
		writeError(w, http.StatusBadRequest, "content 和 attachmentIds 不能同时为空")
		return
	}
	if len([]byte(payload.Content)) > teamMessageMaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "团队消息最多 16 KiB")
		return
	}

	channel, err := r.resolveTeamChannel(req.Context(), payload.SessionID)
	if err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	if len(payload.AgentIDs) > 0 {
		var agents []teamAgent
		if err := r.teamRequest(req.Context(), http.MethodGet, "/api/agents", nil, &agents); err != nil {
			writeTeamUpstreamError(w, err)
			return
		}
		agentsByID := make(map[string]teamAgent, len(agents))
		for _, agent := range agents {
			agentsByID[agent.ID] = agent
		}
		mentions := make([]string, 0, len(payload.AgentIDs))
		for _, agentID := range payload.AgentIDs {
			agent, ok := agentsByID[agentID]
			if !ok {
				writeError(w, http.StatusBadRequest, "选择了 OpenTag 中不存在的 Agent")
				return
			}
			mention := "@" + agent.Name
			if !containsTeamMention(payload.Content, agent.Name) {
				mentions = append(mentions, mention)
			}
		}
		if len(mentions) > 0 {
			payload.Content = strings.TrimSpace(strings.Join(mentions, " ") + " " + payload.Content)
		}
	}
	var result map[string]any
	if err := r.teamRequest(req.Context(), http.MethodPost, "/api/messages", map[string]any{
		"channelId":     channel.ID,
		"content":       payload.Content,
		"attachmentIds": payload.AttachmentIDs,
		"asTask":        payload.AsTask,
	}, &result); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (r *Router) teamAttachmentsHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method == http.MethodGet {
		r.teamAttachmentGet(w, req)
		return
	}
	if req.Method != http.MethodPost || req.URL.Path != "/api/team/attachments" {
		methodNotAllowed(w)
		return
	}
	if !r.requireTeamEnabled(w) {
		return
	}
	var payload teamAttachmentUploadRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	payload.Filename = strings.TrimSpace(payload.Filename)
	payload.MIMEType = strings.TrimSpace(payload.MIMEType)
	if payload.Filename == "" || payload.MIMEType == "" || payload.DataBase64 == "" {
		writeError(w, http.StatusBadRequest, "filename、mimeType 和 dataBase64 均不能为空")
		return
	}
	data, err := base64.StdEncoding.DecodeString(payload.DataBase64)
	if err != nil || len(data) == 0 {
		writeError(w, http.StatusBadRequest, "dataBase64 不是合法文件内容")
		return
	}
	if len(data) > 3<<20 {
		writeError(w, http.StatusRequestEntityTooLarge, "单个团队附件最大 3 MiB")
		return
	}
	channel, err := r.resolveTeamChannel(req.Context(), payload.SessionID)
	if err != nil {
		writeTeamUpstreamError(w, err)
		return
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("channelId", channel.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "构造附件请求失败")
		return
	}
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", fmt.Sprintf(`form-data; name="files"; filename=%q`, payload.Filename))
	header.Set("Content-Type", payload.MIMEType)
	part, err := writer.CreatePart(header)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "构造附件请求失败")
		return
	}
	if _, err := part.Write(data); err != nil {
		writeError(w, http.StatusInternalServerError, "构造附件请求失败")
		return
	}
	if err := writer.Close(); err != nil {
		writeError(w, http.StatusInternalServerError, "构造附件请求失败")
		return
	}

	var response struct {
		Attachments []teamAttachment `json:"attachments"`
	}
	if err := r.teamMultipartRequest(
		req.Context(),
		"/api/attachments/upload",
		writer.FormDataContentType(),
		&body,
		&response,
	); err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	if len(response.Attachments) == 0 {
		writeError(w, http.StatusBadGateway, "OpenTag 未返回附件")
		return
	}
	writeJSON(w, http.StatusOK, response.Attachments[0])
}

func (r *Router) teamAttachmentGet(w http.ResponseWriter, req *http.Request) {
	if !r.requireTeamEnabled(w) {
		return
	}
	const prefix = "/api/team/attachments/"
	attachmentID := strings.TrimSpace(strings.TrimPrefix(req.URL.Path, prefix))
	if attachmentID == "" || strings.Contains(attachmentID, "/") {
		http.NotFound(w, req)
		return
	}

	baseURL, err := url.Parse(strings.TrimRight(r.cfg.Team.BaseURL, "/"))
	if err != nil {
		writeTeamUpstreamError(w, teamUpstreamError{status: http.StatusBadGateway, message: "OpenTag 地址无效"})
		return
	}
	path := "/api/attachments/" + url.PathEscape(attachmentID)
	upstreamReq, err := http.NewRequestWithContext(
		req.Context(),
		http.MethodGet,
		baseURL.ResolveReference(&url.URL{Path: path}).String(),
		nil,
	)
	if err != nil {
		writeTeamUpstreamError(w, err)
		return
	}
	upstreamReq.Header.Set("Authorization", "Bearer "+r.cfg.Team.Token)
	upstreamReq.Header.Set("x-server-id", r.cfg.Team.ServerID)
	response, err := r.teamClient.Do(upstreamReq)
	if err != nil {
		writeTeamUpstreamError(w, teamUpstreamError{status: http.StatusBadGateway, message: "无法连接本机 OpenTag 服务"})
		return
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(response.Body, teamResponseMaxBytes+1))
		var payload struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &payload)
		message := strings.TrimSpace(payload.Error)
		if message == "" {
			message = fmt.Sprintf("OpenTag 返回 HTTP %d", response.StatusCode)
		}
		writeTeamUpstreamError(w, teamUpstreamError{status: http.StatusBadGateway, message: message})
		return
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, teamAttachmentResponseMaxBytes+1))
	if err != nil {
		writeTeamUpstreamError(w, teamUpstreamError{status: http.StatusBadGateway, message: "读取 OpenTag 附件失败"})
		return
	}
	if len(raw) > teamAttachmentResponseMaxBytes {
		writeError(w, http.StatusBadGateway, "OpenTag 附件过大")
		return
	}
	contentType := response.Header.Get("Content-Type")
	if !strings.HasPrefix(strings.ToLower(contentType), "image/") {
		contentType = "application/octet-stream"
		w.Header().Set("Content-Disposition", "attachment")
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=300")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

func teamAgentReachability(agent teamAgent, machines map[string]teamMachine) (bool, *string) {
	if agent.MachineID == nil || strings.TrimSpace(*agent.MachineID) == "" {
		reason := "Agent 未绑定电脑"
		return false, &reason
	}
	machine, ok := machines[*agent.MachineID]
	if !ok {
		reason := "Agent 绑定的电脑不存在"
		return false, &reason
	}
	if !strings.EqualFold(machine.Status, "online") {
		reason := "电脑离线"
		return false, &reason
	}
	for _, runtime := range machine.Runtimes {
		if strings.EqualFold(runtime, agent.Runtime) {
			return true, nil
		}
	}
	reason := fmt.Sprintf("电脑未安装 %s runtime", agent.Runtime)
	return false, &reason
}

func containsTeamMention(content, name string) bool {
	target := "@" + strings.ToLower(name)
	for _, field := range strings.Fields(strings.ToLower(content)) {
		trimmed := strings.Trim(field, "，。！？；：,.!?;:()[]{}")
		if trimmed == target {
			return true
		}
	}
	return false
}

func (r *Router) requireTeamEnabled(w http.ResponseWriter) bool {
	if r.cfg.Team.Enabled {
		return true
	}
	writeError(w, http.StatusNotFound, "团队协作未启用")
	return false
}

func (r *Router) resolveTeamChannel(ctx context.Context, sessionID string) (teamChannel, error) {
	var channels []teamChannel
	if err := r.teamRequest(ctx, http.MethodGet, "/api/channels", nil, &channels); err != nil {
		return teamChannel{}, err
	}
	sessionID = strings.TrimSpace(sessionID)
	if sessionID != "" {
		for _, channel := range channels {
			if channel.ID != sessionID {
				continue
			}
			if _, ok := teamSessionFromChannel(channel); !ok {
				break
			}
			return channel, nil
		}
		return teamChannel{}, teamUpstreamError{
			status:  http.StatusNotFound,
			message: "找不到指定的团队会话",
		}
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

func (r *Router) listTeamSessions(ctx context.Context) ([]teamSession, error) {
	var channels []teamChannel
	if err := r.teamRequest(ctx, http.MethodGet, "/api/channels?archived=include", nil, &channels); err != nil {
		return nil, err
	}
	sessions := make([]teamSession, 0, len(channels))
	for _, channel := range channels {
		if session, ok := teamSessionFromChannel(channel); ok {
			sessions = append(sessions, session)
		}
	}
	sort.SliceStable(sessions, func(i, j int) bool {
		return teamSessionOrderingTime(sessions[i]).After(teamSessionOrderingTime(sessions[j]))
	})
	return sessions, nil
}

func teamSessionOrderingTime(session teamSession) time.Time {
	for _, raw := range []*string{session.UpdatedAt, session.CreatedAt} {
		if raw == nil {
			continue
		}
		if parsed, err := time.Parse(time.RFC3339Nano, *raw); err == nil {
			return parsed
		}
	}
	return time.Time{}
}

func teamSessionFromChannel(channel teamChannel) (teamSession, bool) {
	if channel.Description == nil || !strings.HasPrefix(*channel.Description, teamSessionDescriptionPrefix) {
		return teamSession{}, false
	}
	var metadata teamSessionMetadata
	if err := json.Unmarshal([]byte(strings.TrimPrefix(*channel.Description, teamSessionDescriptionPrefix)), &metadata); err != nil {
		return teamSession{}, false
	}
	if metadata.WorkspaceID == "" || metadata.WorkspaceName == "" || metadata.WorkspacePath == "" {
		return teamSession{}, false
	}
	updatedAt := channel.LastMessageAt
	if updatedAt == nil {
		updatedAt = channel.CreatedAt
	}
	return teamSession{
		ID:            channel.ID,
		ChannelID:     channel.ID,
		Title:         metadata.Title,
		WorkspaceID:   metadata.WorkspaceID,
		WorkspaceName: metadata.WorkspaceName,
		WorkspacePath: metadata.WorkspacePath,
		AgentIDs:      metadata.AgentIDs,
		CreatedAt:     channel.CreatedAt,
		UpdatedAt:     updatedAt,
	}, true
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
	return r.doTeamRequest(upstreamReq, target)
}

func (r *Router) doTeamRequest(upstreamReq *http.Request, target any) error {
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

func (r *Router) teamMultipartRequest(
	ctx context.Context,
	path string,
	contentType string,
	body io.Reader,
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
	upstreamReq, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL.ResolveReference(relative).String(), body)
	if err != nil {
		return err
	}
	upstreamReq.Header.Set("Authorization", "Bearer "+r.cfg.Team.Token)
	upstreamReq.Header.Set("x-server-id", r.cfg.Team.ServerID)
	upstreamReq.Header.Set("Accept", "application/json")
	upstreamReq.Header.Set("Content-Type", contentType)
	return r.doTeamRequest(upstreamReq, target)
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
