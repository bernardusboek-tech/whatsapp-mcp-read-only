package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// forbiddenSelectors are application calls that would send a user-visible
// message, mark it read, or publish available presence. The pinned library
// still contains these methods. This test only checks the application files.
var forbiddenSelectors = map[string]bool{
	"SendMessage":                    true,
	"Upload":                         true,
	"MarkRead":                       true,
	"SendPresence":                   true,
	"SetForceActiveDeliveryReceipts": true,
	"SendChatPresence":               true,
	"PairPhone":                      true,
	"Logout":                         true,
	"BuildHistorySyncRequest":        true,
	"BuildEdit":                      true,
	"BuildReaction":                  true,
	"BuildRevoke":                    true,
	"SendAppState":                   true,
	"ListenAndServe":                 true,
}

func TestApplicationDoesNotCallSendAPIs(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		file, err := parser.ParseFile(fset, name, src, 0)
		if err != nil {
			t.Fatal(err)
		}
		if name != "waadapter.go" && strings.Contains(string(src), "whatsmeow.NewClient") {
			t.Errorf("%s constructs a whatsmeow client", name)
		}
		ast.Inspect(file, func(n ast.Node) bool {
			switch v := n.(type) {
			case *ast.SelectorExpr:
				if forbiddenSelectors[v.Sel.Name] {
					t.Errorf("%s references %s", name, v.Sel.Name)
				}
			case *ast.BasicLit:
				if v.Kind != token.STRING {
					return true
				}
				text, err := strconv.Unquote(v.Value)
				if err != nil {
					return true
				}
				if text == "/api/send" || text == "tcp" || text == "tcp4" || text == "tcp6" || strings.Contains(text, "pkill") || strings.Contains(text, "killall") {
					t.Errorf("%s contains %q", name, text)
				}
			case *ast.CallExpr:
				sel, ok := v.Fun.(*ast.SelectorExpr)
				if !ok || sel.Sel.Name != "Listen" || len(v.Args) == 0 {
					return true
				}
				lit, ok := v.Args[0].(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					return true
				}
				network, err := strconv.Unquote(lit.Value)
				if err == nil && strings.HasPrefix(network, "tcp") {
					t.Errorf("%s listens on %s", name, network)
				}
			}
			return true
		})
	}
	scriptHits := 0
	filepath.Walk("..", func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			if info.Name() == ".git" || info.Name() == ".venv" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".sh") {
			return nil
		}
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(body), "pkill") || strings.Contains(string(body), "killall") {
			t.Errorf("%s contains a broad process match", path)
			scriptHits++
		}
		return nil
	})
	if scriptHits != 0 {
		t.Fatalf("%d scripts failed the process-match check", scriptHits)
	}
}
