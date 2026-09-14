package controller

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"

	corev1alpha1 "github.com/orka-agents/orka/api/v1alpha1"
	"github.com/orka-agents/orka/internal/approvals"
	"github.com/orka-agents/orka/internal/events"
	harnessv2 "github.com/orka-agents/orka/internal/harness/v2"
	"github.com/orka-agents/orka/internal/store"
)

const acpMCPApprovalUnknownReason = "The action may have run. Do not repeat it automatically."

// acpMCPApprovalReceiptOutcome interprets a saved tool response without granting
// permission to repeat the call. Failed records are definitive pre-execution
// denials; a completed tool that returned an error has a Succeeded effect.
func acpMCPApprovalReceiptOutcome(effect *store.ExternalEffect, approvalID string) (string, string, json.RawMessage, error) {
	if effect == nil {
		return "", "", nil, errors.New("approval receipt is invalid")
	}
	result, err := canonicalMCPApprovalResult(effect.Response)
	if err != nil || effect.ResponseDigest != store.CanonicalBytesDigest(result) {
		return "", "", nil, errors.New("approval receipt is invalid")
	}
	switch effect.State {
	case store.ExternalEffectSucceeded:
		outcome := "succeeded"
		if mcpToolResultIsError(result) {
			outcome = acpApprovalOutcomeFailed
		}
		return outcome, "Recorded tool result", result, nil
	case store.ExternalEffectFailed:
		var denial struct {
			Code       string `json:"code"`
			ApprovalID string `json:"approvalID"`
		}
		if json.Unmarshal(result, &denial) != nil || approvalID == "" || denial.ApprovalID != approvalID ||
			!mcpToolResultIsError(result) {
			return "", "", nil, errors.New("approval denial receipt is invalid")
		}
		switch denial.Code {
		case acpApprovalCodeDeclined, acpApprovalCodeExpired, acpApprovalCodeCancelled, acpApprovalCodeStale:
			return "not_started", denial.Code, result, nil
		default:
			return "", "", nil, errors.New("approval denial receipt is invalid")
		}
	default:
		return "", "", nil, errors.New("approval effect has no terminal receipt")
	}
}

func mcpApprovalEffectSnapshot(effect *corev1alpha1.ExternalEffect) store.ExternalEffect {
	result := store.ExternalEffect{
		ID: effect.Spec.ID,
		Identity: store.ExternalEffectIdentity{
			Kind: effect.Spec.Kind, Namespace: effect.Spec.IdentityNamespace,
			AggregateID: effect.Spec.AggregateID, OperationID: effect.Spec.OperationID,
		},
		RequestDigest: effect.Spec.RequestDigest, State: store.ExternalEffectState(effect.Status.State),
		ResponseDigest: effect.Status.ResponseDigest, LeaseOwner: effect.Status.LeaseOwner,
		ControllerEpochName: effect.Status.ControllerEpochName, ControllerEpoch: effect.Status.ControllerEpoch,
		Version: effect.Status.Version,
	}
	if effect.Status.Response != nil {
		result.Response = effect.Status.Response.Raw
	}
	if effect.Status.LeaseExpiresAt != nil {
		result.LeaseExpiresAt = &effect.Status.LeaseExpiresAt.Time
	}
	return result
}

// Recovery joins already-listed effects with safe approval bindings. It never
// loads executable Secret contents or asks a stale runtime to redeliver a call.
func (d *ACPDispatcher) reconcileMCPApprovalExecutions(
	ctx context.Context,
	fence store.ControllerEpochFence,
	tasks []corev1alpha1.Task,
	effects map[string]store.ExternalEffect,
) error {
	if len(effects) == 0 || d.EventStore == nil {
		return nil
	}
	namespaces := make(map[string]bool)
	for _, effect := range effects {
		namespaces[effect.Identity.Namespace] = true
	}
	for i := range tasks {
		task := &tasks[i]
		if task.Spec.Type != corev1alpha1.TaskTypeAgent || task.UID == "" || !namespaces[task.Namespace] {
			continue
		}
		listed, err := approvals.ListEvents(ctx, d.EventStore, task.Namespace, task.Name)
		if err != nil {
			return err
		}
		for _, approval := range approvals.Derive(approvals.FilterEventsForTaskUID(listed, string(task.UID)), time.Time{}) {
			identity, ok := mcpApprovalRecoveryIdentity(task, approval)
			if !ok {
				continue
			}
			id, err := identity.CanonicalID()
			if err != nil {
				return err
			}
			effect, exists := effects[id]
			if !exists || effect.Identity != identity || effect.RequestDigest != approval.Binding.RequestDigest {
				continue
			}
			if err := d.reconcileMCPApprovalExecution(ctx, fence, task, approval, &effect); err != nil {
				return err
			}
		}
	}
	return nil
}

func mcpApprovalRecoveryIdentity(task *corev1alpha1.Task, approval approvals.Approval) (store.ExternalEffectIdentity, bool) {
	binding := approval.Binding
	if binding == nil || approval.TaskUID != string(task.UID) || binding.TaskAttempt == 0 || binding.PromptID == "" ||
		approval.ToolCallID == "" || store.ValidateCanonicalDigest("approval request digest", binding.RequestDigest) != nil {
		return store.ExternalEffectIdentity{}, false
	}
	expected := acpMCPApprovalIdentity(harnessv2.MCPBrokerCallRequest{
		Namespace: task.Namespace,
		Metadata: harnessv2.MutationMetadata{
			TaskUID: harnessv2.TaskUID(task.UID), TaskAttempt: binding.TaskAttempt, PromptID: harnessv2.PromptID(binding.PromptID),
		},
		Call: harnessv2.MCPToolCall{CallID: approval.ToolCallID},
	})
	return store.ExternalEffectIdentity{
		Kind: acpMCPToolEffectKind, Namespace: task.Namespace,
		AggregateID: binding.RuntimeSessionUID, OperationID: binding.OperationID,
	}, approval.ID == expected
}

func mcpApprovalEffectOrphaned(effect *store.ExternalEffect, fence store.ControllerEpochFence, now time.Time) bool {
	if effect.State != store.ExternalEffectInFlight || effect.ControllerEpochName != fence.Name ||
		effect.ControllerEpoch <= 0 || effect.ControllerEpoch > fence.Epoch {
		return false
	}
	return effect.ControllerEpoch < fence.Epoch || effect.LeaseExpiresAt == nil ||
		!now.Before(effect.LeaseExpiresAt.Add(acpExternalEffectReconcileGrace))
}

func mcpApprovalRecoveredOutcome(effect *store.ExternalEffect, approvalID string) (outcome, reason string, result json.RawMessage) {
	switch effect.State {
	case store.ExternalEffectSucceeded, store.ExternalEffectFailed:
		outcome, reason, result, err := acpMCPApprovalReceiptOutcome(effect, approvalID)
		if err == nil {
			return outcome, reason, result
		}
		return acpApprovalOutcomeUnknown, "The saved action result could not be verified. Do not repeat it automatically.", nil
	case store.ExternalEffectOutcomeUnknown:
		return acpApprovalOutcomeUnknown, acpMCPApprovalUnknownReason, nil
	default:
		return "", "", nil
	}
}

func (d *ACPDispatcher) reconcileMCPApprovalExecution(
	ctx context.Context,
	fence store.ControllerEpochFence,
	task *corev1alpha1.Task,
	approval approvals.Approval,
	effect *store.ExternalEffect,
) error {
	if mcpApprovalEffectOrphaned(effect, fence, time.Now().UTC()) {
		// An old epoch cannot commit a result. Seal the uncertain outcome with
		// the exact lease CAS; a crash here is repaired by the next scan.
		updated, err := d.Store.TransitionExternalEffect(ctx, store.ExternalEffectTransition{
			ID: effect.ID, Fence: fence, ExpectedVersion: effect.Version,
			ExpectedState: store.ExternalEffectInFlight, NewState: store.ExternalEffectOutcomeUnknown,
			RequestDigest: effect.RequestDigest, ExpectedLeaseOwner: effect.LeaseOwner, UpdatedAt: time.Now().UTC(),
		})
		if err != nil {
			if errors.Is(err, store.ErrConflict) {
				return nil // A concurrent settlement wins; reread it on the next scan.
			}
			return err
		}
		effect = updated
	}
	outcome, reason, _ := mcpApprovalRecoveredOutcome(effect, approval.ID)
	if outcome == "" || (approval.ExecutionOutcome == outcome && approval.ExecutionReason == reason) {
		return nil
	}
	guard, ok := d.Store.(store.ControllerEpochMutationStore)
	if !ok {
		return errors.New("approval recovery requires the controller epoch mutation guard")
	}
	return guard.WithControllerEpochMutation(ctx, fence, func(guardCtx context.Context) error {
		return d.projectMCPApprovalExecution(guardCtx, task, approval, effect.Identity)
	})
}

func (d *ACPDispatcher) projectMCPApprovalExecution(
	ctx context.Context,
	task *corev1alpha1.Task,
	expected approvals.Approval,
	identity store.ExternalEffectIdentity,
) error {
	reader := d.APIReader
	if reader == nil {
		reader = d.Client
	}
	current := &corev1alpha1.Task{}
	if err := reader.Get(ctx, client.ObjectKeyFromObject(task), current); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}
	if current.UID != task.UID {
		return nil
	}
	effectReader, ok := d.Store.(store.ExternalEffectIdentityReader)
	if !ok {
		return errors.New("approval recovery requires exact effect reads")
	}
	effect, err := effectReader.GetExternalEffectByIdentity(ctx, identity)
	if err != nil {
		return err
	}
	if effect.Identity != identity || effect.RequestDigest != expected.Binding.RequestDigest {
		return store.ErrConflict
	}
	listed, err := approvals.ListEvents(ctx, d.EventStore, task.Namespace, task.Name)
	if err != nil {
		return err
	}
	listed = approvals.FilterEventsForTaskUID(listed, string(task.UID))
	for _, approval := range approvals.Derive(listed, time.Time{}) {
		if approval.ID != expected.ID || approval.TaskUID != string(task.UID) || approval.Binding == nil ||
			*approval.Binding != *expected.Binding {
			continue
		}
		outcome, reason, result := mcpApprovalRecoveredOutcome(effect, approval.ID)
		if outcome == "" || (approval.ExecutionOutcome == outcome && approval.ExecutionReason == reason) {
			return nil
		}
		return d.appendMCPApprovalRecoveryOutcome(ctx, task, approval, effect.Version, listed, outcome, reason, result)
	}
	return nil
}

func (d *ACPDispatcher) appendMCPApprovalRecoveryOutcome(
	ctx context.Context,
	task *corev1alpha1.Task,
	approval approvals.Approval,
	version int64,
	listed []store.ExecutionEvent,
	outcome, reason string,
	result json.RawMessage,
) error {
	var source store.ExecutionEvent
	var lastSeq int64
	for _, event := range listed {
		if store.ApprovalIDFromExecutionEvent(event) != approval.ID {
			continue
		}
		if event.Type == events.ExecutionEventTypeApprovalRequested && source.ID == "" {
			source = event
		}
		lastSeq = max(lastSeq, event.Seq)
	}
	payload := struct {
		ApprovalID       string `json:"approvalID"`
		TaskUID          string `json:"taskUID"`
		ExecutionOutcome string `json:"executionOutcome"`
		Reason           string `json:"reason"`
		ResultDigest     string `json:"resultDigest,omitempty"`
	}{ApprovalID: approval.ID, TaskUID: string(task.UID), ExecutionOutcome: outcome, Reason: reason}
	if len(result) > 0 {
		payload.ResultDigest = store.CanonicalBytesDigest(result)
	}
	content, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	eventStore, ok := d.EventStore.(store.DeduplicatingExecutionEventStore)
	if !ok {
		return errors.New("approval recovery requires deduplicating execution events")
	}
	// Include the observed history position so a late stale writer cannot make
	// an earlier dedupe key prevent the next scan from repairing its projection.
	key := fmt.Sprintf("acp-approval:%s:recovery:%d:%d", approval.ID, version, lastSeq)
	_, _, err = eventStore.AppendExecutionEventIfAbsent(ctx, &store.ExecutionEvent{
		Namespace: task.Namespace, StreamType: events.ExecutionEventStreamTypeTask, StreamID: task.Name,
		TaskName: task.Name, SessionName: source.SessionName, AgentName: source.AgentName,
		Type: events.ExecutionEventTypeApprovalExecutionUpdated, Severity: events.ExecutionEventSeverityInfo,
		ToolName: approval.TargetTool, ToolCallID: approval.ID, Summary: "Approved tool execution " + outcome, Content: content,
	}, key)
	return err
}
