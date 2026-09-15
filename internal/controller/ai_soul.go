package controller

import (
	"context"
	"fmt"
	"reflect"
	"strings"

	"k8s.io/client-go/util/retry"
	"sigs.k8s.io/controller-runtime/pkg/client"

	corev1alpha1 "github.com/orka-agents/orka/api/v1alpha1"
	"github.com/orka-agents/orka/internal/agentcontext"
	"github.com/orka-agents/orka/internal/store"
)

// resolvedAISoul is a prepared input, not a worker-controlled environment value.
type resolvedAISoul struct {
	Prompt     string
	UserPrompt string
	Binding    corev1alpha1.TaskSoulBinding
}

func resolveAISoul(ctx context.Context, reader client.Reader, task *corev1alpha1.Task, agent *corev1alpha1.Agent) (*resolvedAISoul, error) {
	if task == nil || task.Spec.Type != corev1alpha1.TaskTypeAI || agent == nil || agent.Spec.Soul == nil {
		if task != nil && task.Status.SoulBinding != nil {
			return nil, fmt.Errorf("AI soul configuration was removed after binding")
		}
		return nil, nil
	}
	if err := validateSoulRuntime(agent); err != nil {
		return nil, err
	}
	if task.UID == "" || agent.UID == "" || agent.Generation < 1 || task.Generation < 1 {
		return nil, fmt.Errorf("AI soul binding requires persistent Task and Agent identities")
	}
	soul, err := agentcontext.ResolveSoul(ctx, reader, agent)
	if err != nil {
		return nil, err
	}
	role := ""
	if task.Spec.AI != nil {
		role = task.Spec.AI.SystemPrompt
	}
	if role == "" {
		role, err = resolveACPSystemPrompt(ctx, reader, agent)
		if err != nil {
			return nil, err
		}
	}
	prompt := agentcontext.Compose(role, soul)
	userPrompt := effectiveAISoulTaskPrompt(task)
	if len(literalKubernetesPrompt(userPrompt)) > maxContainerDeliveredPromptBytes {
		return nil, fmt.Errorf("AI Task prompt exceeds the safe literal environment limit")
	}

	// Kubernetes expands EnvVar.Value. Count the actual escaped envelope before
	// persisting a binding; the worker receives the original literal bytes.
	if len(literalKubernetesPrompt(prompt)) > maxContainerDeliveredPromptBytes {
		return nil, fmt.Errorf("composed AI soul prompt exceeds the safe environment limit")
	}
	binding := corev1alpha1.TaskSoulBinding{
		TaskGeneration: task.Generation, AgentUID: string(agent.UID), AgentGeneration: agent.Generation,
		SoulDigest: soul.Digest, PromptDigest: agentcontext.Digest(prompt),
	}
	if task.Status.SoulBinding != nil && *task.Status.SoulBinding != binding {
		return nil, fmt.Errorf("AI prompt configuration changed after binding; create a new Task")
	}
	return &resolvedAISoul{Prompt: prompt, UserPrompt: userPrompt, Binding: binding}, nil
}

func literalKubernetesPrompt(value string) string {
	return strings.ReplaceAll(value, "$", "$$")
}

func (r *TaskReconciler) prepareAISoul(ctx context.Context, task *corev1alpha1.Task, agent *corev1alpha1.Agent) (*resolvedAISoul, error) {
	if task.Spec.Type != corev1alpha1.TaskTypeAI {
		return nil, nil
	}
	reader := r.APIReader
	if reader == nil {
		reader = r.Client
	}
	resolved, err := resolveAISoul(ctx, reader, task, agent)
	if err != nil {
		return nil, err
	}
	var binding *corev1alpha1.TaskSoulBinding
	if resolved != nil {
		binding = &resolved.Binding
	}
	if task.Spec.SessionRef != nil {
		if r.SessionManager == nil {
			if binding != nil {
				return nil, fmt.Errorf("session manager is required for an AI soul")
			}
		} else if err := r.SessionManager.validateSoulContext(ctx, task, binding); err != nil {
			return nil, err
		}
	}
	if binding == nil || task.Status.SoulBinding != nil {
		return resolved, nil
	}
	err = retry.RetryOnConflict(retry.DefaultBackoff, func() error {
		current := &corev1alpha1.Task{}
		if err := reader.Get(ctx, client.ObjectKeyFromObject(task), current); err != nil {
			return err
		}
		if current.UID != task.UID || current.Generation != task.Generation || !current.DeletionTimestamp.IsZero() {
			return fmt.Errorf("task identity changed before AI soul binding")
		}
		if current.Status.SoulBinding != nil {
			if *current.Status.SoulBinding != *binding {
				return fmt.Errorf("AI soul was bound to a different prompt configuration")
			}
			task.Status = current.Status
			return nil
		}
		base := current.DeepCopy()
		current.Status.SoulBinding = binding
		if err := r.Status().Patch(ctx, current, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil {
			return err
		}
		task.Status = current.Status
		return nil
	})
	return resolved, err
}

func (m *SessionManager) validateSoulContext(ctx context.Context, task *corev1alpha1.Task, binding *corev1alpha1.TaskSoulBinding) error {
	reader, ok := m.store.(store.SessionSoulReader)
	if !ok {
		if binding == nil {
			return nil // Preserve no-soul behavior for legacy Session store adapters.
		}
		return fmt.Errorf("session store does not support soul revision metadata")
	}
	state, err := reader.ReadSessionSoul(ctx, task.Namespace, task.Spec.SessionRef.Name, task.Name, string(task.UID))
	if err != nil {
		return err
	}
	digest := agentcontext.SessionDigest(binding)
	if state.Established {
		if state.Digest != digest {
			return fmt.Errorf("session soul configuration does not match; create a new Session")
		}
		return nil
	}
	if digest == "" {
		return nil
	}
	if state.MessageCount == 0 {
		if !task.Spec.SessionRef.Append {
			return fmt.Errorf("a new AI soul Session must append its initial turn")
		}
		return nil
	}
	if event, gateway, err := m.gatewayEventForTask(ctx, task); err != nil {
		return err
	} else if gateway && state.FirstMessageID == store.GatewayUserMessageID(event.ID) {
		return nil
	}
	return fmt.Errorf("existing Session has no pinned soul revision; create a new Session")
}

func validatePreparedAISoul(task *corev1alpha1.Task, agent *corev1alpha1.Agent, prepared *resolvedAISoul) error {
	if agent == nil || agent.Spec.Soul == nil {
		if prepared != nil || task.Status.SoulBinding != nil {
			return fmt.Errorf("AI soul configuration is missing")
		}
		return nil
	}
	if prepared == nil || task.Status.SoulBinding == nil || !reflect.DeepEqual(task.Status.SoulBinding, &prepared.Binding) ||
		prepared.Binding.TaskGeneration != task.Generation || prepared.Binding.AgentUID != string(agent.UID) ||
		prepared.Binding.AgentGeneration != agent.Generation || prepared.Binding.PromptDigest != agentcontext.Digest(prepared.Prompt) || prepared.UserPrompt != effectiveAISoulTaskPrompt(task) {
		return fmt.Errorf("AI Job requires the exact controller-bound soul prompt")
	}
	return nil
}

func validateSoulRuntime(agent *corev1alpha1.Agent) error {
	if agent == nil || agent.Spec.Soul == nil || agent.Spec.Runtime == nil {
		return nil
	}
	runtime := agent.Spec.Runtime
	if runtime.RuntimeRef != nil || !isBuiltInACPProviderRuntime(runtime.Type) || runtime.ContractVersion == nil || *runtime.ContractVersion != corev1alpha1.AgentRuntimeContractHarnessV2 {
		return fmt.Errorf("Agent.spec.soul requires an AI worker or a built-in harness v2 runtime")
	}
	return nil
}

func effectiveAISoulTaskPrompt(task *corev1alpha1.Task) string {
	if task.Spec.AI != nil && task.Spec.AI.Prompt != "" {
		return task.Spec.AI.Prompt
	}
	return task.Spec.Prompt
}
