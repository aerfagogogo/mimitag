// Package claudehistory 读取本机 Claude Code CLI 的会话 transcript（~/.claude/projects/**/*.jsonl），
// 将其暴露为只读会话历史，供 agentd 上层 API 展示给 iOS 端。它与 internal/codexhistory 平行，
// 但只处理文件系统上的 append-only JSONL，不涉及 SQLite。
package claudehistory

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	// defaultProjectsSubdir 是 Claude Code CLI 写入 transcript 的默认目录（相对 $HOME）。
	defaultProjectsSubdir = ".claude/projects"

	// maxLineBytes 是允许解析的最大 JSONL 单行大小。tool_use payload 里嵌大文件时会超过它；
	// 超过就跳过这一行而不是让整段会话失败，等价于 codexhistory 里 maxMessageIndexBytes 的保护。
	maxLineBytes = 1 << 20

	// cacheTTL 决定 List/Read 的短缓存有效期。设小一点让 iOS 端能观察到活跃会话追加。
	cacheTTL = 30 * time.Second

	// previewLimit 是 Session.Preview 存的字符上限。
	previewLimit = 200

	defaultReadLimit = 500
	maxReadLimit     = 5000
)

// Source 是 sessionStore 中 Claude CLI 观测会话统一使用的 runtime source 标记。
const Source = "claude-cli"

// Session 描述一个 Claude Code CLI 会话（一个 .jsonl 文件）的摘要视图。
type Session struct {
	ID           string    `json:"id"`
	ProjectPath  string    `json:"project_path"`
	Title        string    `json:"title"`
	Preview      string    `json:"preview"`
	LastModified time.Time `json:"last_modified"`
	MessageCount int       `json:"message_count"`
	GitBranch    string    `json:"git_branch,omitempty"`
	Version      string    `json:"version,omitempty"`
	Source       string    `json:"source"`
}

// Message 是 Claude Code CLI 会话里对 UI 可展示的一条消息。工具调用、file-history-snapshot、
// attachment、permission-mode 等元事件不进入这里，但会被 List 的 MessageCount 计入。
type Message struct {
	ID         string    `json:"id"`
	Role       string    `json:"role"`
	Content    string    `json:"content"`
	CreatedAt  time.Time `json:"created_at"`
	UUID       string    `json:"uuid,omitempty"`
	ParentUUID string    `json:"parent_uuid,omitempty"`
	Type       string    `json:"type,omitempty"`
}

// Store 封装读取 Claude CLI transcript 目录的能力。
// 零值不可用；请通过 NewStore 构造。
type Store struct {
	projectsDir string
	now         func() time.Time // 便于测试注入
	sessions    sessionsCache
	messages    messagesCache
}

type sessionsCache struct {
	mu        sync.Mutex
	entries   []Session
	fetchedAt time.Time
}

type messagesCache struct {
	mu    sync.Mutex
	items map[string]messagesCacheEntry
}

type messagesCacheEntry struct {
	fetchedAt time.Time
	size      int64
	modTime   time.Time
	messages  []Message
}

// NewStore 返回一个 Store。projectsDir 为空时默认 ~/.claude/projects；
// 支持形如 "~/.claude/projects" 的家目录展开。
func NewStore(projectsDir string) *Store {
	return &Store{
		projectsDir: projectsDir,
		now:         time.Now,
		messages:    messagesCache{items: map[string]messagesCacheEntry{}},
	}
}

// Resolve 返回实际扫描的 projects 目录（展开 ~ 之后的绝对路径）。
func (s *Store) Resolve() (string, error) {
	dir := strings.TrimSpace(s.projectsDir)
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, defaultProjectsSubdir), nil
	}
	if strings.HasPrefix(dir, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, dir[2:]), nil
	}
	return dir, nil
}

// List 返回所有会话摘要，按 LastModified 降序排列。
// 目录不存在时返回空切片和 nil error——空目录不是错误。
func (s *Store) List() ([]Session, error) {
	dir, err := s.Resolve()
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
		return []Session{}, nil
	} else if err != nil {
		return nil, err
	}

	// 短缓存：iOS 会话列表可能高频刷新，重复扫上百个文件浪费 IO。
	s.sessions.mu.Lock()
	if s.sessions.entries != nil && s.now().Sub(s.sessions.fetchedAt) < cacheTTL {
		out := make([]Session, len(s.sessions.entries))
		copy(out, s.sessions.entries)
		s.sessions.mu.Unlock()
		return out, nil
	}
	s.sessions.mu.Unlock()

	sessions, err := s.scan(dir)
	if err != nil {
		return nil, err
	}

	s.sessions.mu.Lock()
	s.sessions.entries = append(s.sessions.entries[:0], sessions...)
	s.sessions.fetchedAt = s.now()
	s.sessions.mu.Unlock()

	out := make([]Session, len(sessions))
	copy(out, sessions)
	return out, nil
}

func (s *Store) scan(dir string) ([]Session, error) {
	subdirs, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var sessions []Session
	for _, entry := range subdirs {
		if !entry.IsDir() {
			continue
		}
		subdir := filepath.Join(dir, entry.Name())
		files, err := os.ReadDir(subdir)
		if err != nil {
			// 单个项目目录读失败不影响其他项目。
			continue
		}
		for _, file := range files {
			if file.IsDir() || !strings.HasSuffix(file.Name(), ".jsonl") {
				continue
			}
			path := filepath.Join(subdir, file.Name())
			session, ok := s.summarize(path, entry.Name())
			if !ok {
				continue
			}
			sessions = append(sessions, session)
		}
	}
	sort.SliceStable(sessions, func(i, j int) bool {
		return sessions[i].LastModified.After(sessions[j].LastModified)
	})
	return sessions, nil
}

func (s *Store) summarize(path, dirName string) (Session, bool) {
	info, err := os.Stat(path)
	if err != nil {
		return Session{}, false
	}
	sessionID := strings.TrimSuffix(filepath.Base(path), ".jsonl")
	if sessionID == "" {
		return Session{}, false
	}
	file, err := os.Open(path)
	if err != nil {
		return Session{}, false
	}
	defer file.Close()

	var (
		firstUser   string
		gitBranch   string
		version     string
		cwd         string
		visibleMsgs int
	)
	reader := bufio.NewReaderSize(file, 256*1024)
	for {
		line, readErr := reader.ReadBytes('\n')
		if len(line) > 0 && len(line) <= maxLineBytes {
			if parsed, ok := parseLine(line); ok {
				if cwd == "" && parsed.cwd != "" {
					cwd = parsed.cwd
				}
				if gitBranch == "" && parsed.gitBranch != "" {
					gitBranch = parsed.gitBranch
				}
				if version == "" && parsed.version != "" {
					version = parsed.version
				}
				if parsed.role == "user" || parsed.role == "assistant" {
					if strings.TrimSpace(parsed.content) != "" {
						visibleMsgs++
						if firstUser == "" && parsed.role == "user" {
							firstUser = truncate(strings.TrimSpace(parsed.content), previewLimit)
						}
					}
				}
			}
		}
		if readErr != nil {
			if !errors.Is(readErr, io.EOF) {
				return Session{}, false
			}
			break
		}
	}
	if visibleMsgs == 0 {
		return Session{}, false
	}
	projectPath := cwd
	if projectPath == "" {
		projectPath = decodeDirName(dirName)
	}
	return Session{
		ID:           sessionID,
		ProjectPath:  projectPath,
		Title:        titleFromPreview(firstUser),
		Preview:      firstUser,
		LastModified: info.ModTime(),
		MessageCount: visibleMsgs,
		GitBranch:    gitBranch,
		Version:      version,
		Source:       Source,
	}, true
}

// Read 返回指定 sessionID 的可视消息分页。
// offset < 0 归零；limit <= 0 使用 defaultReadLimit；超过 maxReadLimit 会被截断。
// 找不到会话时返回 os.ErrNotExist。
func (s *Store) Read(sessionID string, offset, limit int) ([]Message, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return nil, errors.New("sessionID 不能为空")
	}
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 {
		limit = defaultReadLimit
	}
	if limit > maxReadLimit {
		limit = maxReadLimit
	}
	path, err := s.findSessionPath(sessionID)
	if err != nil {
		return nil, err
	}
	messages, err := s.loadMessages(path)
	if err != nil {
		return nil, err
	}
	if offset >= len(messages) {
		return []Message{}, nil
	}
	end := offset + limit
	if end > len(messages) {
		end = len(messages)
	}
	out := make([]Message, end-offset)
	copy(out, messages[offset:end])
	return out, nil
}

func (s *Store) findSessionPath(sessionID string) (string, error) {
	dir, err := s.Resolve()
	if err != nil {
		return "", err
	}
	// SessionID 里理论上不含路径分隔符（是 UUID），但仍然做基本清洗防止越界。
	if strings.ContainsAny(sessionID, "/\\\x00") {
		return "", os.ErrNotExist
	}
	subdirs, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	target := sessionID + ".jsonl"
	for _, entry := range subdirs {
		if !entry.IsDir() {
			continue
		}
		candidate := filepath.Join(dir, entry.Name(), target)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", os.ErrNotExist
}

func (s *Store) loadMessages(path string) ([]Message, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}

	s.messages.mu.Lock()
	if entry, ok := s.messages.items[path]; ok {
		fresh := s.now().Sub(entry.fetchedAt) < cacheTTL
		stable := entry.size == info.Size() && entry.modTime.Equal(info.ModTime())
		if fresh && stable {
			out := make([]Message, len(entry.messages))
			copy(out, entry.messages)
			s.messages.mu.Unlock()
			return out, nil
		}
		delete(s.messages.items, path)
	}
	s.messages.mu.Unlock()

	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	messages, err := MessagesFromReader(file)
	if err != nil {
		return nil, err
	}

	s.messages.mu.Lock()
	s.messages.items[path] = messagesCacheEntry{
		fetchedAt: s.now(),
		size:      info.Size(),
		modTime:   info.ModTime(),
		messages:  messages,
	}
	s.messages.mu.Unlock()

	out := make([]Message, len(messages))
	copy(out, messages)
	return out, nil
}

// MessagesFromReader 从 JSONL Reader 中解析出可视消息序列。
// 跳过超大行（>maxLineBytes）和非 user/assistant 类型（例如 permission-mode、attachment、tool_use raw event）。
// 该函数是包内解析入口，测试可以直接用它绕过 Store。
func MessagesFromReader(r io.Reader) ([]Message, error) {
	reader := bufio.NewReaderSize(r, 256*1024)
	var messages []Message
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 && len(line) <= maxLineBytes {
			if bytes.TrimSpace(line) != nil {
				if msg, ok := parseVisibleMessage(line); ok {
					messages = append(messages, msg)
				}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return messages, nil
			}
			return messages, err
		}
	}
}

type parsedLine struct {
	typ        string
	role       string
	content    string
	cwd        string
	gitBranch  string
	version    string
	uuid       string
	parentUUID string
	timestamp  string
}

func parseLine(line []byte) (parsedLine, bool) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return parsedLine{}, false
	}
	var raw struct {
		Type       string          `json:"type"`
		Message    json.RawMessage `json:"message"`
		UUID       string          `json:"uuid"`
		ParentUUID string          `json:"parentUuid"`
		Timestamp  string          `json:"timestamp"`
		CWD        string          `json:"cwd"`
		GitBranch  string          `json:"gitBranch"`
		Version    string          `json:"version"`
	}
	if err := json.Unmarshal(line, &raw); err != nil {
		return parsedLine{}, false
	}
	out := parsedLine{
		typ:        raw.Type,
		cwd:        raw.CWD,
		gitBranch:  raw.GitBranch,
		version:    raw.Version,
		uuid:       raw.UUID,
		parentUUID: raw.ParentUUID,
		timestamp:  raw.Timestamp,
	}
	switch raw.Type {
	case "user", "assistant":
		out.role = raw.Type
		out.content = extractMessageContent(raw.Message)
	}
	return out, true
}

func parseVisibleMessage(line []byte) (Message, bool) {
	p, ok := parseLine(line)
	if !ok {
		return Message{}, false
	}
	if p.role != "user" && p.role != "assistant" {
		return Message{}, false
	}
	if strings.TrimSpace(p.content) == "" {
		return Message{}, false
	}
	id := p.uuid
	if id == "" {
		// UUID 缺失时用 timestamp 兜底，避免同一批消息在 iOS 端 ForEach 里 id 冲突。
		id = Source + ":" + p.timestamp
	}
	return Message{
		ID:         id,
		Role:       p.role,
		Content:    p.content,
		CreatedAt:  parseTime(p.timestamp),
		UUID:       p.uuid,
		ParentUUID: p.parentUUID,
		Type:       p.typ,
	}, true
}

// extractMessageContent 从 Claude JSONL 的 message 字段抽取用户可见文本。
// user 事件里 message 是字符串（或 {role,content} 对象且 content 为字符串），
// assistant 事件里 message 是完整 Anthropic API 响应对象，content 为 block 数组。
func extractMessageContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	// message 直接是字符串（罕见但历史里出现过）
	var asStr string
	if err := json.Unmarshal(raw, &asStr); err == nil {
		return asStr
	}
	// message 是 {role, content, ...}
	var asObj struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(raw, &asObj); err != nil {
		return ""
	}
	return extractContent(asObj.Content)
}

func extractContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	// content 为字符串
	var asStr string
	if err := json.Unmarshal(raw, &asStr); err == nil {
		return asStr
	}
	// content 为 block 数组：只挑 text block，thinking/tool_use/tool_result 暂不展示，
	// 这些将来会有专门的 UI 表示。
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return ""
	}
	var parts []string
	for _, block := range blocks {
		if block.Type == "text" && strings.TrimSpace(block.Text) != "" {
			parts = append(parts, block.Text)
		}
	}
	return strings.Join(parts, "\n\n")
}

// DecodeDirName 是可导出版的目录名解码，仅当 jsonl 里未出现 cwd 字段时兜底使用。
// Claude Code CLI 的编码规则是把原路径的 "/" 替换成 "-"，因此解码是有损的
// （无法区分原本就含 "-" 的路径），只用于最坏情况的显示。
func DecodeDirName(name string) string { return decodeDirName(name) }

func decodeDirName(name string) string {
	if name == "" {
		return ""
	}
	return strings.ReplaceAll(name, "-", "/")
}

func titleFromPreview(preview string) string {
	if preview == "" {
		return "Claude Code CLI 会话"
	}
	return truncate(preview, 48)
}

func parseTime(raw string) time.Time {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339Nano, raw); err == nil {
		return t
	}
	if t, err := time.Parse(time.RFC3339, raw); err == nil {
		return t
	}
	return time.Time{}
}

func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n]) + "..."
}
