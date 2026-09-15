package tools

import (
	"context"
	"encoding/json"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	corev1alpha1 "github.com/orka-agents/orka/api/v1alpha1"
	"github.com/orka-agents/orka/internal/executionmode"
)

func TestOpenCodeCreateToolsPersistLiteralSystemPrompt(t *testing.T) {
	const prompt = "Research public sources and cite every article."
	t.Run("create_agent", func(t *testing.T) {
		t.Setenv(envOrkaTaskName, parentTaskName)
		t.Setenv(envOrkaTaskNamespace, defaultNamespace)
		fc := newFakeClient(parentTask())
		result, err := NewCreateAgentTool(fc, executionmode.HarnessV2).Execute(context.Background(), json.RawMessage(`{"role":"coder","systemPrompt":"`+prompt+`","model":{"name":"openai/gpt-5.4","contextWindow":32768,"maxTokens":4096},"runtime":{"type":"opencode","defaultAllowedTools":["web_fetch"],"defaultAllowBash":false}}`))
		if err != nil {
			t.Fatal(err)
		}
		var response CreateAgentResult
		if err := json.Unmarshal([]byte(result), &response); err != nil {
			t.Fatal(err)
		}
		var agent corev1alpha1.Agent
		if err := fc.Get(context.Background(), types.NamespacedName{Name: response.AgentName, Namespace: response.Namespace}, &agent); err != nil {
			t.Fatal(err)
		}
		if agent.Spec.SystemPrompt == nil || agent.Spec.SystemPrompt.Inline != prompt || agent.Spec.Runtime.DefaultAllowBash == nil || *agent.Spec.Runtime.DefaultAllowBash {
			t.Fatal("literal prompt or no-Bash policy was not preserved")
		}
	})
	t.Run("chat_create_agent", func(t *testing.T) {
		fc := newFakeClient()
		ctx := WithToolContext(context.Background(), &ToolContext{Client: fc, Namespace: defaultNamespace, ExecutionMode: executionmode.HarnessV2})
		result, err := (&ChatCreateAgentTool{}).Execute(ctx, json.RawMessage(`{"name":"research-literal","systemPrompt":"`+prompt+`","model":{"name":"openai/gpt-5.4","contextWindow":32768,"maxTokens":4096},"runtime":{"type":"opencode","defaultAllowedTools":["web_fetch"],"defaultAllowBash":false}}`))
		if err != nil {
			t.Fatal(err)
		}
		var response ChatToolResult
		if err := json.Unmarshal([]byte(result), &response); err != nil || !response.Success {
			t.Fatal("literal prompt create did not succeed")
		}
		var agent corev1alpha1.Agent
		if err := fc.Get(context.Background(), client.ObjectKey{Name: "research-literal", Namespace: defaultNamespace}, &agent); err != nil {
			t.Fatal(err)
		}
		if agent.Spec.SystemPrompt == nil || agent.Spec.SystemPrompt.Inline != prompt {
			t.Fatal("literal prompt was not stored")
		}
	})
}

func TestOpenCodeUpdateToolPreservesLiteralPromptAndPolicy(t *testing.T) {
	window, output, noBash := int32(32768), int32(4096), false
	agent := &corev1alpha1.Agent{ObjectMeta: metav1.ObjectMeta{Name: testMyAgentName, Namespace: defaultNamespace}, Spec: corev1alpha1.AgentSpec{Model: &corev1alpha1.ModelConfig{Name: "openai/gpt-5.4", ContextWindow: &window, MaxTokens: &output}, Runtime: &corev1alpha1.AgentCLIRuntime{Type: corev1alpha1.AgentRuntimeOpencode, DefaultAllowBash: &noBash, DefaultAllowedTools: []string{"web_fetch"}}}}
	fc := newFakeClient(agent)
	ctx := WithToolContext(context.Background(), &ToolContext{Client: fc, Namespace: defaultNamespace})
	result, err := (&UpdateAgentTool{}).Execute(ctx, json.RawMessage(`{"name":"my-agent","systemPrompt":"Cite actual source URLs."}`))
	if err != nil {
		t.Fatal(err)
	}
	var response ChatToolResult
	if err := json.Unmarshal([]byte(result), &response); err != nil || !response.Success {
		t.Fatal("literal prompt update did not succeed")
	}
	var updated corev1alpha1.Agent
	if err := fc.Get(context.Background(), client.ObjectKey{Name: testMyAgentName, Namespace: defaultNamespace}, &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Spec.SystemPrompt == nil || updated.Spec.SystemPrompt.Inline != "Cite actual source URLs." || updated.Spec.Runtime.DefaultAllowBash == nil || *updated.Spec.Runtime.DefaultAllowBash || len(updated.Spec.Runtime.DefaultAllowedTools) != 1 || updated.Spec.Runtime.DefaultAllowedTools[0] != "web_fetch" {
		t.Fatal("literal prompt update changed the existing tool authority")
	}
}
