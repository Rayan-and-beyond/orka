package controller

import (
	"context"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	corev1alpha1 "github.com/orka-agents/orka/api/v1alpha1"
	"github.com/orka-agents/orka/internal/agentcontext"
	"github.com/orka-agents/orka/internal/store"
	"github.com/orka-agents/orka/internal/workerenv"
)

func TestAISoulBindingAndLiteralDelivery(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := corev1alpha1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	agent := &corev1alpha1.Agent{ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "a", UID: "agent-uid", Generation: 1}, Spec: corev1alpha1.AgentSpec{SystemPrompt: &corev1alpha1.PromptSource{Inline: "agent role"}, Soul: &corev1alpha1.SoulSource{Inline: "Literal $(VOICE_NOTE), $$ and 語."}}}
	task := &corev1alpha1.Task{ObjectMeta: metav1.ObjectMeta{Namespace: "team", Name: "t", UID: "task-uid", Generation: 1}, Spec: corev1alpha1.TaskSpec{Type: corev1alpha1.TaskTypeAI, AI: &corev1alpha1.AISpec{SystemPrompt: "Task role"}, Env: []corev1.EnvVar{{Name: "VOICE_NOTE", Value: "untrusted"}}}}
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&corev1alpha1.Task{}).WithObjects(task, agent).Build()
	r := &TaskReconciler{Client: c, APIReader: c}
	prepared, err := r.prepareAISoul(context.Background(), task, agent)
	if err != nil {
		t.Fatal(err)
	}
	if task.Status.SoulBinding == nil || !strings.HasPrefix(prepared.Prompt, "Task role") || strings.Contains(prepared.Prompt, "agent role") {
		t.Fatal("role precedence or binding failed")
	}
	if err := validatePreparedAISoul(task, agent, prepared); err != nil {
		t.Fatal(err)
	}
	env := NewJobBuilder(c).buildEnvVarsWithOptions(context.Background(), task, agent, nil, JobBuildOptions{AISoul: prepared})
	found := false
	for _, v := range env {
		if v.Name == workerenv.AISystemPrompt {
			found = true
			if v.Value != literalKubernetesPrompt(prepared.Prompt) || !strings.Contains(v.Value, "$$(VOICE_NOTE), $$$$") {
				t.Fatal("prompt is not literal-safe")
			}
		}
	}
	if !found {
		t.Fatal("missing prompt environment")
	}
	agent.Spec.Soul.Inline = "replacement"
	if _, err := r.prepareAISoul(context.Background(), task, agent); err == nil {
		t.Fatal("retry accepted soul drift")
	}
	agent.Spec.Soul = nil
	if _, err := r.prepareAISoul(context.Background(), task, agent); err == nil {
		t.Fatal("retry accepted removal")
	}
	if task.Status.SoulBinding.PromptDigest != agentcontext.Digest(prepared.Prompt) {
		t.Fatal("stored prompt identity changed")
	}
}

type soulStateStore struct {
	store.SessionStore
	state store.SessionSoulState
}

func (s soulStateStore) ReadSessionSoul(context.Context, string, string, string, string) (store.SessionSoulState, error) {
	return s.state, nil
}

func TestAISoulSessionRevisionContract(t *testing.T) {
	binding := &corev1alpha1.TaskSoulBinding{TaskGeneration: 1, AgentUID: "agent", AgentGeneration: 1, SoulDigest: agentcontext.Digest("soul"), PromptDigest: agentcontext.Digest("role and soul")}
	digest := agentcontext.SessionDigest(binding)
	for _, test := range []struct {
		name      string
		state     store.SessionSoulState
		binding   *corev1alpha1.TaskSoulBinding
		append    bool
		wantError bool
	}{
		{name: "new canonical conversation", binding: binding, append: true},
		{name: "read-only cannot establish identity", binding: binding, wantError: true},
		{name: "same revision", state: store.SessionSoulState{Established: true, Digest: digest}, binding: binding},
		{name: "changed revision", state: store.SessionSoulState{Established: true, Digest: agentcontext.Digest("other")}, binding: binding, wantError: true},
		{name: "removal", state: store.SessionSoulState{Established: true, Digest: digest}, wantError: true},
		{name: "legacy cannot acquire soul", state: store.SessionSoulState{Established: true, MessageCount: 2}, binding: binding, wantError: true},
		{name: "legacy no-soul unchanged", state: store.SessionSoulState{Established: true, MessageCount: 2}},
	} {
		t.Run(test.name, func(t *testing.T) {
			manager := NewSessionManager(soulStateStore{state: test.state})
			task := &corev1alpha1.Task{Spec: corev1alpha1.TaskSpec{SessionRef: &corev1alpha1.SessionReference{Name: "s", Append: test.append}}}
			err := manager.validateSoulContext(context.Background(), task, test.binding)
			if (err != nil) != test.wantError {
				t.Fatalf("want error=%v, got %v", test.wantError, err)
			}
		})
	}
}
