package tools

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"unicode"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/orka-agents/orka/internal/agentcontext"
	"github.com/orka-agents/orka/internal/executionmode"
)

func TestSoulSchemasEnforceSourceExclusivity(t *testing.T) {
	ref := map[string]any{"name": "persona", "key": "SOUL.md"}
	digest := agentcontext.Digest("persona")
	for _, tool := range []struct {
		name string
		tool Tool
	}{
		{"native create", NewCreateAgentTool(nil, executionmode.HarnessV2)},
		{"chat create", &ChatCreateAgentTool{}},
		{"update", &UpdateAgentTool{}},
	} {
		t.Run(tool.name, func(t *testing.T) {
			var schema jsonschema.Schema
			if err := json.Unmarshal(tool.tool.Parameters(), &schema); err != nil {
				t.Fatal(err)
			}
			source := schema.Properties["soul"]
			if source == nil {
				t.Fatal("tool does not expose the soul schema")
			}
			resolved, err := source.Resolve(nil)
			if err != nil {
				t.Fatal(err)
			}
			for _, tc := range []struct {
				name  string
				value map[string]any
				valid bool
			}{
				{"inline", map[string]any{"inline": "persona"}, true},
				{"inline with digest", map[string]any{"inline": "persona", "digest": digest}, true},
				{"pinned configmap", map[string]any{"configMapRef": ref, "digest": digest}, true},
				{"empty", map[string]any{}, false},
				{"empty inline", map[string]any{"inline": ""}, false},
				{"digest without source", map[string]any{"digest": digest}, false},
				{"unpinned configmap", map[string]any{"configMapRef": ref}, false},
				{"both sources without digest", map[string]any{"inline": "persona", "configMapRef": ref}, false},
				{"both sources with digest", map[string]any{"inline": "persona", "configMapRef": ref, "digest": digest}, false},
				{"configmap with empty inline", map[string]any{"inline": "", "configMapRef": ref, "digest": digest}, false},
			} {
				t.Run(tc.name, func(t *testing.T) {
					if err := resolved.Validate(tc.value); (err == nil) != tc.valid {
						t.Fatalf("schema valid=%v, error=%v", tc.valid, err)
					}
				})
			}
		})
	}
}

func TestSoulRuntimeValidationRejectsMixedSources(t *testing.T) {
	for _, withDigest := range []bool{false, true} {
		value := map[string]any{
			"inline":       "persona",
			"configMapRef": map[string]any{"name": "persona", "key": "SOUL.md"},
		}
		if withDigest {
			value["digest"] = agentcontext.Digest("persona")
		}
		if _, err := soulArgument(value); err == nil {
			t.Fatalf("runtime accepted mixed sources: withDigest=%v", withDigest)
		}
	}
}

func TestSoulSchemasEnforceNonWhitespace(t *testing.T) {
	values := []string{"", " \t\n\v\f\r", "persona", "\tpersona\u3000", "\u200b", "\ufeff", "\u180e", "\x1c"}
	// Enumerate Go's whitespace set rather than duplicating the schema's class.
	for r := rune(0); r <= unicode.MaxRune; r++ {
		if unicode.IsSpace(r) {
			values = append(values, string(r))
		}
	}
	for _, tool := range []struct {
		name string
		tool Tool
	}{
		{"native create", NewCreateAgentTool(nil, executionmode.HarnessV2)},
		{"chat create", &ChatCreateAgentTool{}},
		{"update", &UpdateAgentTool{}},
	} {
		t.Run(tool.name, func(t *testing.T) {
			var schema jsonschema.Schema
			if err := json.Unmarshal(tool.tool.Parameters(), &schema); err != nil {
				t.Fatal(err)
			}
			source := schema.Properties["soul"]
			if source == nil {
				t.Fatal("tool does not expose the soul schema")
			}
			resolved, err := source.Resolve(nil)
			if err != nil {
				t.Fatal(err)
			}
			for _, value := range values {
				t.Run(fmt.Sprintf("%q", value), func(t *testing.T) {
					for _, field := range []struct {
						name  string
						value map[string]any
					}{
						{"inline", map[string]any{"inline": value}},
						{"name", map[string]any{"configMapRef": map[string]any{"name": value, "key": "SOUL.md"}, "digest": agentcontext.Digest("persona")}},
						{"key", map[string]any{"configMapRef": map[string]any{"name": "persona", "key": value}, "digest": agentcontext.Digest("persona")}},
					} {
						t.Run(field.name, func(t *testing.T) {
							wantValid := strings.TrimSpace(value) != ""
							if err := resolved.Validate(field.value); (err == nil) != wantValid {
								t.Errorf("schema valid=%v, error=%v", wantValid, err)
							}
							if _, err := soulArgument(field.value); (err == nil) != wantValid {
								t.Errorf("runtime valid=%v, error=%v", wantValid, err)
							}
						})
					}
				})
			}
		})
	}
}
