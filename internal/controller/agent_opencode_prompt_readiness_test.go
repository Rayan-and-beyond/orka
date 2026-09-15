package controller

import (
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	corev1alpha1 "github.com/orka-agents/orka/api/v1alpha1"
	"github.com/orka-agents/orka/internal/acp"
)

func TestAgentReconcileValidatesOpenCodeConfigMapPromptBeforeReady(t *testing.T) {
	for _, test := range []struct {
		name, prompt string
		ready        bool
	}{
		{"literal", "Cite the source URLs.", true},
		{"empty", "", true},
		{"whitespace", " \t\n ", true},
		{"environment substitution", "{env:READINESS_TEST_PLACEHOLDER}", false},
		{"file substitution", "{file:/readiness-test-placeholder}", false},
		{"encoded limit", strings.Repeat("<", (acp.MaxOpenCodeSystemPromptEncodedBytes-2)/6+1), false},
	} {
		t.Run(test.name, func(t *testing.T) {
			cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "research-prompt", Namespace: testNS}, Data: map[string]string{"prompt": test.prompt}}
			agent := baseAgent("opencode-readiness")
			agent.Spec.Model = testOpenCodeModelConfig()
			agent.Spec.Runtime = &corev1alpha1.AgentCLIRuntime{Type: corev1alpha1.AgentRuntimeOpencode, ContractVersion: new(corev1alpha1.AgentRuntimeContractHarnessV2)}
			agent.Spec.SystemPrompt = &corev1alpha1.PromptSource{ConfigMapRef: &corev1alpha1.ConfigMapKeySelector{Name: cm.Name, Key: "prompt"}}
			scheme := runtime.NewScheme()
			if err := corev1.AddToScheme(scheme); err != nil {
				t.Fatal(err)
			}
			if err := corev1alpha1.AddToScheme(scheme); err != nil {
				t.Fatal(err)
			}
			c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(agent, cm).WithStatusSubresource(agent).Build()
			r := &AgentReconciler{Client: c, Scheme: scheme}
			key := client.ObjectKeyFromObject(agent)
			if _, err := r.Reconcile(t.Context(), ctrl.Request{NamespacedName: key}); err != nil {
				t.Fatal(err)
			}
			var stored corev1alpha1.Agent
			if err := c.Get(t.Context(), key, &stored); err != nil {
				t.Fatal(err)
			}
			if stored.Status.Ready != test.ready {
				t.Fatalf("Agent Ready = %t, want %t", stored.Status.Ready, test.ready)
			}
			if !test.ready {
				// Reconciliation must also recover after the referenced prompt is
				// corrected, without changing the Agent's runtime or reference.
				if err := c.Get(t.Context(), client.ObjectKeyFromObject(cm), cm); err != nil {
					t.Fatal(err)
				}
				cm.Data["prompt"] = "Use public sources."
				if err := c.Update(t.Context(), cm); err != nil {
					t.Fatal(err)
				}
				if _, err := r.Reconcile(t.Context(), ctrl.Request{NamespacedName: key}); err != nil {
					t.Fatal(err)
				}
				if err := c.Get(t.Context(), key, &stored); err != nil || !stored.Status.Ready {
					t.Fatalf("corrected prompt did not become ready: %v", err)
				}
			}
		})
	}
}

func TestConfigMapPromptValidationPreservesOtherRuntimeContracts(t *testing.T) {
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "legacy-prompt", Namespace: testNS}, Data: map[string]string{"prompt": "{env:READINESS_TEST_PLACEHOLDER}"}}
	for _, contract := range []*corev1alpha1.AgentRuntimeContractVersion{nil, new(corev1alpha1.AgentRuntimeContractHarnessV1)} {
		agent := baseAgent("legacy")
		agent.Spec.Runtime = &corev1alpha1.AgentCLIRuntime{Type: corev1alpha1.AgentRuntimeOpencode, ContractVersion: contract}
		agent.Spec.SystemPrompt = &corev1alpha1.PromptSource{ConfigMapRef: &corev1alpha1.ConfigMapKeySelector{Name: cm.Name, Key: "prompt"}}
		if err := setupAgentReconciler(cm).validateSystemPromptConfigMap(t.Context(), agent); err != nil {
			t.Fatal("OpenCode v2 prompt rules must not change a legacy contract")
		}
	}
	agent := baseAgent("other-runtime")
	agent.Spec.Runtime = &corev1alpha1.AgentCLIRuntime{Type: corev1alpha1.AgentRuntimeCodex, ContractVersion: new(corev1alpha1.AgentRuntimeContractHarnessV2)}
	agent.Spec.SystemPrompt = &corev1alpha1.PromptSource{ConfigMapRef: &corev1alpha1.ConfigMapKeySelector{Name: cm.Name, Key: "prompt"}}
	if err := setupAgentReconciler(cm).validateSystemPromptConfigMap(t.Context(), agent); err != nil {
		t.Fatal("OpenCode prompt rules must not restrict other runtimes")
	}
}
