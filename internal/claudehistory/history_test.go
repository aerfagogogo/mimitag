package claudehistory

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// makeSession 在 t.TempDir 下伪造一个 <projects>/<dirName>/<sessionID>.jsonl
// 会话文件，并把提供的每一行 JSONL 直接写入。返回文件绝对路径。
func makeSession(t *testing.T, projects, dirName, sessionID string, lines []string, mtime time.Time) string {
	t.Helper()
	subdir := filepath.Join(projects, dirName)
	if err := os.MkdirAll(subdir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", subdir, err)
	}
	path := filepath.Join(subdir, sessionID+".jsonl")
	body := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	if !mtime.IsZero() {
		if err := os.Chtimes(path, mtime, mtime); err != nil {
			t.Fatalf("chtimes %s: %v", path, err)
		}
	}
	return path
}

func TestDecodeDirNameReplacesDashes(t *testing.T) {
	got := DecodeDirName("-Users-me-code-foo")
	want := "/Users/me/code/foo"
	if got != want {
		t.Fatalf("DecodeDirName = %q, want %q", got, want)
	}
	if DecodeDirName("") != "" {
		t.Fatalf("DecodeDirName(empty) should be empty")
	}
}

func TestExtractMessageContentString(t *testing.T) {
	got := extractMessageContent([]byte(`"hello"`))
	if got != "hello" {
		t.Fatalf("string form: got %q", got)
	}
}

func TestExtractMessageContentObjectStringContent(t *testing.T) {
	// user message: message = {"role":"user","content":"hi"}
	got := extractMessageContent([]byte(`{"role":"user","content":"hi"}`))
	if got != "hi" {
		t.Fatalf("object/string content: got %q", got)
	}
}

func TestExtractMessageContentBlocksJoinsTextOnly(t *testing.T) {
	// assistant message with thinking + text + tool_use blocks
	raw := []byte(`{"role":"assistant","content":[` +
		`{"type":"thinking","thinking":"..."},` +
		`{"type":"text","text":"part one"},` +
		`{"type":"tool_use","name":"Read"},` +
		`{"type":"text","text":"part two"}` +
		`]}`)
	got := extractMessageContent(raw)
	want := "part one\n\npart two"
	if got != want {
		t.Fatalf("blocks join: got %q want %q", got, want)
	}
}

func TestMessagesFromReaderSkipsMetaAndParsesUserAssistant(t *testing.T) {
	body := strings.Join([]string{
		`{"type":"permission-mode","permissionMode":"auto","sessionId":"s"}`,
		`{"type":"file-history-snapshot","messageId":"x"}`,
		`{"type":"user","message":{"role":"user","content":"hello"},"uuid":"u1","timestamp":"2026-07-29T02:09:37.725Z","cwd":"/tmp/foo"}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi back"}]},"uuid":"a1","parentUuid":"u1","timestamp":"2026-07-29T02:09:40Z"}`,
		`{"type":"attachment"}`,
	}, "\n") + "\n"

	messages, err := MessagesFromReader(bytes.NewReader([]byte(body)))
	if err != nil {
		t.Fatalf("MessagesFromReader err: %v", err)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 visible messages, got %d: %+v", len(messages), messages)
	}
	if messages[0].Role != "user" || messages[0].Content != "hello" || messages[0].UUID != "u1" {
		t.Fatalf("first message unexpected: %+v", messages[0])
	}
	if messages[1].Role != "assistant" || messages[1].Content != "hi back" || messages[1].ParentUUID != "u1" {
		t.Fatalf("second message unexpected: %+v", messages[1])
	}
	if messages[0].CreatedAt.IsZero() || messages[1].CreatedAt.IsZero() {
		t.Fatalf("timestamps not parsed")
	}
}

func TestMessagesFromReaderSkipsHugeLines(t *testing.T) {
	var buf bytes.Buffer
	// 一条有效 user 消息
	buf.WriteString(`{"type":"user","message":{"role":"user","content":"before"},"uuid":"u1","timestamp":"2026-07-29T02:00:00Z"}` + "\n")
	// 一条超大行（模拟嵌大文件的 tool_use payload）
	buf.WriteString(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":"`)
	buf.WriteString(strings.Repeat("x", maxLineBytes+10))
	buf.WriteString(`"}]}}` + "\n")
	// 一条有效 assistant 消息
	buf.WriteString(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"after"}]},"uuid":"a1","timestamp":"2026-07-29T02:00:10Z"}` + "\n")

	messages, err := MessagesFromReader(&buf)
	if err != nil {
		t.Fatalf("超大行不应该让解析整体失败：%v", err)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 messages after skipping huge line, got %d", len(messages))
	}
	if messages[0].Content != "before" || messages[1].Content != "after" {
		t.Fatalf("unexpected content: %+v", messages)
	}
}

func TestListReturnsEmptyForMissingDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "does-not-exist")
	store := NewStore(dir)
	sessions, err := store.List()
	if err != nil {
		t.Fatalf("missing dir should not error: %v", err)
	}
	if len(sessions) != 0 {
		t.Fatalf("expected 0 sessions, got %d", len(sessions))
	}
}

func TestListSortsByLastModifiedDesc(t *testing.T) {
	projects := t.TempDir()
	older := time.Date(2026, 7, 20, 10, 0, 0, 0, time.UTC)
	newer := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)

	makeSession(t, projects, "-Users-me-code-foo", "sess-older",
		[]string{`{"type":"user","message":{"role":"user","content":"a"},"uuid":"u","timestamp":"2026-07-20T10:00:00Z","cwd":"/Users/me/code/foo"}`},
		older,
	)
	makeSession(t, projects, "-Users-me-code-bar", "sess-newer",
		[]string{`{"type":"user","message":{"role":"user","content":"b"},"uuid":"u","timestamp":"2026-07-29T10:00:00Z","cwd":"/Users/me/code/bar"}`},
		newer,
	)

	store := NewStore(projects)
	sessions, err := store.List()
	if err != nil {
		t.Fatalf("List err: %v", err)
	}
	if len(sessions) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(sessions))
	}
	if sessions[0].ID != "sess-newer" {
		t.Fatalf("expected newer first, got %+v", sessions)
	}
	if sessions[0].ProjectPath != "/Users/me/code/bar" {
		t.Fatalf("cwd from message should win, got %q", sessions[0].ProjectPath)
	}
	if sessions[0].Source != Source {
		t.Fatalf("source should be %q", Source)
	}
}

func TestListUsesFirstUserMessageAsPreview(t *testing.T) {
	projects := t.TempDir()
	longContent := strings.Repeat("重要内容 ", 200) // 会超过 previewLimit
	makeSession(t, projects, "-Users-me-code-foo", "s1",
		[]string{
			`{"type":"permission-mode","permissionMode":"auto"}`,
			`{"type":"user","message":{"role":"user","content":"` + longContent + `"},"uuid":"u1","timestamp":"2026-07-29T10:00:00Z","cwd":"/Users/me/code/foo","gitBranch":"main","version":"2.1.150"}`,
			`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]},"uuid":"a1","timestamp":"2026-07-29T10:00:05Z"}`,
		},
		time.Now(),
	)

	store := NewStore(projects)
	sessions, err := store.List()
	if err != nil {
		t.Fatalf("List err: %v", err)
	}
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}
	sess := sessions[0]
	if !strings.HasPrefix(sess.Preview, "重要内容") {
		t.Fatalf("preview should start with first user message, got %q", sess.Preview)
	}
	if len([]rune(sess.Preview)) > previewLimit+3 { // +3 是省略号
		t.Fatalf("preview should be truncated to previewLimit, got %d runes", len([]rune(sess.Preview)))
	}
	if sess.MessageCount != 2 {
		t.Fatalf("expected 2 visible messages, got %d", sess.MessageCount)
	}
	if sess.GitBranch != "main" {
		t.Fatalf("git branch not captured, got %q", sess.GitBranch)
	}
	if sess.Version != "2.1.150" {
		t.Fatalf("version not captured, got %q", sess.Version)
	}
}

func TestListFallsBackToDirNameDecodeWhenCWDMissing(t *testing.T) {
	projects := t.TempDir()
	// 消息里故意不提供 cwd 字段
	makeSession(t, projects, "-Users-me-code-nowhere", "sess-x",
		[]string{`{"type":"user","message":{"role":"user","content":"noop"},"uuid":"u","timestamp":"2026-07-29T10:00:00Z"}`},
		time.Now(),
	)

	store := NewStore(projects)
	sessions, err := store.List()
	if err != nil {
		t.Fatalf("List err: %v", err)
	}
	if len(sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(sessions))
	}
	if sessions[0].ProjectPath != "/Users/me/code/nowhere" {
		t.Fatalf("should fall back to dir-name decode, got %q", sessions[0].ProjectPath)
	}
}

func TestReadPaginatesMessages(t *testing.T) {
	projects := t.TempDir()
	lines := []string{`{"type":"permission-mode","permissionMode":"auto"}`}
	for i := 0; i < 10; i++ {
		lines = append(lines,
			`{"type":"user","message":{"role":"user","content":"msg-`+itoa(i)+`"},"uuid":"u`+itoa(i)+`","timestamp":"2026-07-29T10:00:00Z","cwd":"/tmp/foo"}`,
		)
	}
	makeSession(t, projects, "-tmp-foo", "sess-page", lines, time.Now())

	store := NewStore(projects)
	// 全量
	all, err := store.Read("sess-page", 0, 0)
	if err != nil {
		t.Fatalf("Read all err: %v", err)
	}
	if len(all) != 10 {
		t.Fatalf("expected 10 msgs, got %d", len(all))
	}
	if all[0].Content != "msg-0" || all[9].Content != "msg-9" {
		t.Fatalf("order wrong: %+v", all)
	}
	// 分页
	page, err := store.Read("sess-page", 3, 4)
	if err != nil {
		t.Fatalf("Read page err: %v", err)
	}
	if len(page) != 4 {
		t.Fatalf("expected 4 msgs, got %d", len(page))
	}
	if page[0].Content != "msg-3" || page[3].Content != "msg-6" {
		t.Fatalf("page window wrong: %+v", page)
	}
	// offset 超过总量
	empty, err := store.Read("sess-page", 100, 10)
	if err != nil {
		t.Fatalf("Read overflow err: %v", err)
	}
	if len(empty) != 0 {
		t.Fatalf("expected empty, got %d", len(empty))
	}
}

func TestReadReturnsNotExistForUnknownID(t *testing.T) {
	projects := t.TempDir()
	if err := os.MkdirAll(projects, 0o755); err != nil {
		t.Fatal(err)
	}
	store := NewStore(projects)
	_, err := store.Read("does-not-exist", 0, 10)
	if !os.IsNotExist(err) {
		t.Fatalf("expected os.ErrNotExist, got %v", err)
	}
}

func TestReadRejectsSuspiciousSessionID(t *testing.T) {
	projects := t.TempDir()
	store := NewStore(projects)
	for _, id := range []string{"../etc/passwd", "foo/bar", "with\x00null"} {
		if _, err := store.Read(id, 0, 10); !os.IsNotExist(err) {
			t.Fatalf("id %q should be treated as not found, got %v", id, err)
		}
	}
}

func TestListCachesResultsForShortWindow(t *testing.T) {
	projects := t.TempDir()
	makeSession(t, projects, "-tmp-foo", "s1",
		[]string{`{"type":"user","message":{"role":"user","content":"x"},"uuid":"u","timestamp":"2026-07-29T10:00:00Z","cwd":"/tmp/foo"}`},
		time.Now(),
	)
	store := NewStore(projects)

	fixed := time.Now()
	store.now = func() time.Time { return fixed }

	first, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 1 {
		t.Fatalf("expected 1 session, got %d", len(first))
	}

	// 加一个新 session；因为缓存未过期，List 不应立即看到。
	makeSession(t, projects, "-tmp-bar", "s2",
		[]string{`{"type":"user","message":{"role":"user","content":"y"},"uuid":"u","timestamp":"2026-07-29T10:00:00Z","cwd":"/tmp/bar"}`},
		time.Now(),
	)
	second, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(second) != 1 {
		t.Fatalf("缓存内应仍是 1 session，got %d", len(second))
	}

	// 推进 now 超过 TTL，应该重新扫到新 session
	store.now = func() time.Time { return fixed.Add(2 * cacheTTL) }
	third, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(third) != 2 {
		t.Fatalf("过 TTL 后应重新扫到 2 sessions，got %d", len(third))
	}
}

// itoa 用来在无 fmt 的地方拼数字，避免拉入 fmt 包。
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
