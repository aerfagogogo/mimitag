package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadWithEnvOverrides(t *testing.T) {
	clearAgentdEnv(t)
	t.Setenv("AGENTD_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("AGENTD_PROJECTS", filepath.Join(t.TempDir(), "demo"))
	projectDir := os.Getenv("AGENTD_PROJECTS")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Auth.Token == "" {
		t.Fatal("期望从环境变量读取 token")
	}
	if len(cfg.Projects) != 1 || cfg.Projects[0].ID != "demo" {
		t.Fatalf("项目解析异常：%+v", cfg.Projects)
	}
	if cfg.Voice.CodexTranscriptionBaseURL != "https://chatgpt.com/backend-api" {
		t.Fatalf("默认语音转写必须使用 Codex 登录态后端，实际 %q", cfg.Voice.CodexTranscriptionBaseURL)
	}
}

func TestValidateRejectsEmptyToken(t *testing.T) {
	cfg := defaults()
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
	if err := cfg.Validate(); err == nil {
		t.Fatal("期望空 token 被拒绝")
	}
}

func TestLoadTeamConfigFromEnvironment(t *testing.T) {
	clearAgentdEnv(t)
	projectDir := t.TempDir()
	t.Setenv("AGENTD_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("AGENTD_PROJECTS", projectDir)
	t.Setenv("AGENTD_TEAM_ENABLED", "true")
	t.Setenv("AGENTD_TEAM_BASE_URL", "http://127.0.0.1:7777/")
	t.Setenv("AGENTD_TEAM_TOKEN", "opentag-token")
	t.Setenv("AGENTD_TEAM_SERVER_ID", "server-id")
	t.Setenv("AGENTD_TEAM_CHANNEL", "all")

	cfg, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Team.Enabled ||
		cfg.Team.BaseURL != "http://127.0.0.1:7777" ||
		cfg.Team.Token != "opentag-token" ||
		cfg.Team.ServerID != "server-id" ||
		cfg.Team.Channel != "all" {
		t.Fatalf("团队协作环境变量解析异常：%+v", cfg.Team)
	}
}

func TestValidateTeamRequiresLoopbackOpenTag(t *testing.T) {
	cfg := defaults()
	cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
	cfg.Team = TeamConfig{
		Enabled:  true,
		BaseURL:  "https://team.example.com",
		Token:    "opentag-token",
		ServerID: "server-id",
		Channel:  "all",
	}
	if err := cfg.Validate(); err == nil {
		t.Fatal("期望拒绝非 loopback OpenTag 地址")
	}
}

func TestPlatformDefaultPathIgnoresAgentdConfig(t *testing.T) {
	customPath := filepath.Join(t.TempDir(), "custom-config.json")
	t.Setenv("AGENTD_CONFIG", customPath)

	if got := DefaultPath(); got != customPath {
		t.Fatalf("普通前台命令仍应接受 AGENTD_CONFIG：got=%q want=%q", got, customPath)
	}
	platformDefault := PlatformDefaultPath()
	if platformDefault == customPath {
		t.Fatalf("Homebrew 平台默认路径不能受 AGENTD_CONFIG 影响：%q", platformDefault)
	}
	wantDir, err := UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	if platformDefault != filepath.Join(wantDir, "config.json") {
		t.Fatalf("平台默认配置路径异常：got=%q want=%q", platformDefault, filepath.Join(wantDir, "config.json"))
	}
}
