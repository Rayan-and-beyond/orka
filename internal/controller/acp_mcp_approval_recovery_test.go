package controller

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	coordinationv1 "k8s.io/api/coordination/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	corev1alpha1 "github.com/orka-agents/orka/api/v1alpha1"
	"github.com/orka-agents/orka/internal/approvals"
	"github.com/orka-agents/orka/internal/events"
	harnessv2 "github.com/orka-agents/orka/internal/harness/v2"
	"github.com/orka-agents/orka/internal/store"
	storekube "github.com/orka-agents/orka/internal/store/kube"
)

type mcpApprovalRecoveryFixture struct {
	*mcpApprovalFixture
	ctx         context.Context
	kube        client.Client
	control     *storekube.Store
	dispatcher  *ACPDispatcher
	task        *corev1alpha1.Task
	fence       store.ControllerEpochFence
	stopEpoch   func()
	exactReads  atomic.Int32
	secretReads atomic.Int32
}

func newMCPApprovalRecoveryFixture(t *testing.T) *mcpApprovalRecoveryFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	t.Cleanup(cancel)
	f := &mcpApprovalRecoveryFixture{mcpApprovalFixture: newMCPApprovalFixture(t), ctx: ctx}
	scheme := runtime.NewScheme()
	require.NoError(t, corev1.AddToScheme(scheme))
	require.NoError(t, coordinationv1.AddToScheme(scheme))
	require.NoError(t, corev1alpha1.AddToScheme(scheme))
	f.task = &corev1alpha1.Task{
		ObjectMeta: metav1.ObjectMeta{Namespace: f.request.Namespace, Name: "approval-task", UID: types.UID(f.request.Metadata.TaskUID)},
		Spec:       corev1alpha1.TaskSpec{Type: corev1alpha1.TaskTypeAgent},
	}
	f.kube = withControllerEpochLeaseUIDs(t, fake.NewClientBuilder().WithScheme(scheme).WithObjects(f.task).
		WithStatusSubresource(&corev1alpha1.ControllerEpoch{}, &corev1alpha1.PromptAttempt{}, &corev1alpha1.ExternalEffect{}).
		WithInterceptorFuncs(interceptor.Funcs{
			Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, object client.Object, opts ...client.GetOption) error {
				switch object.(type) {
				case *corev1alpha1.ExternalEffect:
					f.exactReads.Add(1)
				case *corev1.Secret:
					f.secretReads.Add(1)
				}
				return c.Get(ctx, key, object, opts...)
			},
			List: func(ctx context.Context, c client.WithWatch, list client.ObjectList, opts ...client.ListOption) error {
				if _, ok := list.(*corev1.SecretList); ok {
					f.secretReads.Add(1)
				}
				return c.List(ctx, list, opts...)
			},
		}).Build())
	var err error
	f.control, err = storekube.NewComposite(f.kube, "orka-system", f.events, storekube.WithAPIReader(f.kube))
	require.NoError(t, err)
	epochs, stop := startArchivedRecoveryEpoch(t, ctx, f.control, nil, "controller-a")
	f.stopEpoch = stop
	f.fence, err = epochs.CurrentFence(ctx)
	require.NoError(t, err)
	f.dispatcher = &ACPDispatcher{Client: f.kube, APIReader: f.kube, Store: f.control, EventStore: f.events, Epochs: epochs}
	f.broker.Effects, f.broker.EpochMutations = f.control, f.control
	f.broker.Prompts = DurableACPMCPPromptAuthorizer{Attempts: f.control, PromptLeases: &ACPMCPPromptLeaseRegistry{}}
	f.createRunningAttempt(t)
	return f
}

func (f *mcpApprovalRecoveryFixture) createRunningAttempt(t *testing.T) {
	t.Helper()
	attempt, err := f.control.CreatePromptAttempt(f.ctx, &store.PromptAttempt{
		Key:        mcpPromptLeaseKey(f.request.Namespace, f.request.Metadata),
		SessionUID: string(f.request.Authorization.RuntimeSessionUID), RuntimeInstanceID: string(f.request.Metadata.Fence.RuntimeInstanceID),
		RequestDigest: testControllerMCPDigest("prompt"), BindingDigest: testControllerMCPDigest("binding"), SnapshotDigest: testControllerMCPDigest("snapshot"),
	}, f.fence)
	require.NoError(t, err)
	for _, state := range []store.PromptExecutionState{
		store.PromptExecutionReserved, store.PromptExecutionSessionStarting, store.PromptExecutionPlanned,
		store.PromptExecutionSubmitting, store.PromptExecutionAccepted, store.PromptExecutionRunning,
	} {
		attempt, err = f.control.TransitionPromptAttemptExecution(f.ctx, store.PromptAttemptExecutionTransition{
			ID: attempt.ID, Fence: f.fence, ExpectedVersion: attempt.Version, ExpectedState: attempt.ExecutionState,
			NewState: state, OperationID: string(state), OperationDigest: testControllerMCPDigest(string(state)),
		})
		require.NoError(t, err)
	}
}

func (f *mcpApprovalRecoveryFixture) restart(t *testing.T) {
	t.Helper()
	f.stopEpoch()
	epochs, stop := startArchivedRecoveryEpoch(t, f.ctx, f.control, nil, "controller-b")
	f.stopEpoch = stop
	f.dispatcher.Epochs = epochs
	var err error
	f.fence, err = epochs.CurrentFence(f.ctx)
	require.NoError(t, err)
	require.Greater(t, uint64(f.fence.Epoch), f.request.Metadata.Fence.ControllerEpoch)
	// Recovery has no executable Secret client and no remembered prompt lease.
	f.broker.ApprovalSecrets = nil
	f.broker.Prompts = DurableACPMCPPromptAuthorizer{Attempts: f.control, PromptLeases: &ACPMCPPromptLeaseRegistry{}}
}

func (f *mcpApprovalRecoveryFixture) seed(t *testing.T, state store.ExternalEffectState, prior string, executed bool, result json.RawMessage) (*acpMCPApprovalCall, *store.ExternalEffect) {
	t.Helper()
	descriptor, err := f.request.ValidateAt(time.Now().UTC())
	require.NoError(t, err)
	credentials, err := f.broker.Credentials.ResolveACPMCPBrokerCredentials(f.ctx, f.request)
	require.NoError(t, err)
	credentials.Task.SessionName, credentials.Task.AgentName = "approval-session", "approval-agent"
	call, _, err := f.broker.persistApprovalCall(f.ctx, f.request, descriptor, credentials.Task)
	require.NoError(t, err)
	effect, err := f.control.ReserveExternalEffect(f.ctx, store.ReserveExternalEffectRequest{
		Identity: store.ExternalEffectIdentity{
			Kind: acpMCPToolEffectKind, Namespace: f.request.Namespace,
			AggregateID: string(f.request.Authorization.RuntimeSessionUID), OperationID: string(f.request.Metadata.OperationID),
		},
		RequestDigest: call.RequestDigest, Fence: f.fence, CreatedAt: call.CreatedAt,
	})
	require.NoError(t, err)
	require.NoError(t, f.broker.requestToolApproval(f.ctx, call))
	decision := events.ExecutionEventTypeApprovalApproved
	if state == store.ExternalEffectFailed {
		decision = events.ExecutionEventTypeApprovalDeclined
		result = acpApprovalError(call.ID, "approval_declined")
	}
	f.decide(call.ID, decision)
	if state == store.ExternalEffectPending {
		return call, effect
	}
	expires := time.Now().UTC().Add(5 * time.Minute)
	effect, err = f.control.TransitionExternalEffect(f.ctx, store.ExternalEffectTransition{
		ID: effect.ID, Fence: f.fence, ExpectedVersion: effect.Version,
		ExpectedState: store.ExternalEffectPending, NewState: store.ExternalEffectInFlight,
		RequestDigest: call.RequestDigest, LeaseOwner: "original-call-owner", LeaseExpiresAt: &expires,
	})
	require.NoError(t, err)
	if prior != "" {
		require.NoError(t, f.broker.approvalOutcome(f.ctx, call, prior, "Approved action started", nil))
	}
	if executed {
		_, err = f.broker.Executor.ExecuteACPMCPTool(f.ctx, f.request, descriptor)
		require.NoError(t, err)
	}
	if state == store.ExternalEffectInFlight {
		return call, effect
	}
	digest := ""
	if len(result) > 0 {
		result, err = canonicalMCPApprovalResult(result)
		require.NoError(t, err)
		digest = store.CanonicalBytesDigest(result)
	}
	effect, err = f.control.TransitionExternalEffect(f.ctx, store.ExternalEffectTransition{
		ID: effect.ID, Fence: f.fence, ExpectedVersion: effect.Version,
		ExpectedState: store.ExternalEffectInFlight, NewState: state, RequestDigest: call.RequestDigest,
		ExpectedLeaseOwner: effect.LeaseOwner, Response: result, ResponseDigest: digest,
	})
	require.NoError(t, err)
	return call, effect
}

func (f *mcpApprovalRecoveryFixture) reconcile(t *testing.T) error {
	t.Helper()
	var tasks corev1alpha1.TaskList
	require.NoError(t, f.kube.List(f.ctx, &tasks))
	return f.dispatcher.reconcileExpiredExternalEffects(f.ctx, tasks.Items)
}

func (f *mcpApprovalRecoveryFixture) approval(t *testing.T) (approvals.Approval, []store.ExecutionEvent) {
	t.Helper()
	listed, err := approvals.ListEvents(f.ctx, f.events, f.task.Namespace, f.task.Name)
	require.NoError(t, err)
	// This is the same Task-UID-filtered derivation used by ListTaskApprovals.
	listed = approvals.FilterEventsForTaskUID(listed, string(f.task.UID))
	values := approvals.Derive(listed, time.Time{})
	require.Len(t, values, 1)
	return values[0], listed
}

func TestMCPApprovalRecoveryProjectsPersistedExecutionAfterRestart(t *testing.T) {
	for _, tc := range []struct {
		name     string
		state    store.ExternalEffectState
		prior    string
		executed bool
		result   json.RawMessage
		want     string
	}{
		{"claimed_before_start_event", store.ExternalEffectInFlight, "", false, nil, "unknown"},
		{"started_without_receipt", store.ExternalEffectInFlight, "running", true, nil, "unknown"},
		{"completed_before_outcome_event", store.ExternalEffectSucceeded, "running", true, json.RawMessage(`{"workOrder":"simulated-1"}`), "succeeded"},
		{"completed_nested_numbers", store.ExternalEffectSucceeded, "running", true, json.RawMessage(`{"z":[1.0,1e2,1e-7,9007199254740993,{"b":"<&>","a":2.5}],"isError":false}`), "succeeded"},
		{"completed_tool_error", store.ExternalEffectSucceeded, "running", true, json.RawMessage(`{"isError":true,"error":"simulated failure"}`), "failed"},
		{"denied_before_outcome_event", store.ExternalEffectFailed, "", false, nil, "not_started"},
		{"unknown_before_outcome_event", store.ExternalEffectOutcomeUnknown, "running", true, nil, "unknown"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newMCPApprovalRecoveryFixture(t)
			call, effect := f.seed(t, tc.state, tc.prior, tc.executed, tc.result)
			f.restart(t)
			count := f.count.Load()
			// Real stale-epoch credential resolution and empty local lease state
			// both reject redelivery before it can replay the persisted receipt.
			resolver := KubernetesACPMCPBrokerCredentialResolver{Reader: f.kube, Epochs: f.dispatcher.Epochs}
			_, err := resolver.ResolveACPMCPBrokerCredentials(f.ctx, f.request)
			require.EqualError(t, err, "MCP request uses a stale controller epoch")
			require.ErrorIs(t, f.broker.Prompts.AuthorizeACPMCPPrompt(f.ctx, f.request), errACPMCPPromptLeaseInactive)
			replay := performMCPBrokerCall(t, f.broker, f.request, strings.Repeat("b", 32), []byte(strings.Repeat("c", 32)))
			require.Equal(t, http.StatusForbidden, replay.Code)
			require.NoError(t, f.reconcile(t))
			approval, listed := f.approval(t)
			require.Equal(t, tc.want, approval.ExecutionOutcome)
			require.Equal(t, call.RequestDigest, approval.Binding.RequestDigest)
			require.Equal(t, "approval-session", listed[len(listed)-1].SessionName)
			require.Equal(t, "approval-agent", listed[len(listed)-1].AgentName)
			require.NotContains(t, string(listed[len(listed)-1].Content), "workOrder")
			persisted, err := f.control.GetExternalEffectByIdentity(f.ctx, effect.Identity)
			require.NoError(t, err)
			if tc.state == store.ExternalEffectInFlight {
				require.Equal(t, store.ExternalEffectOutcomeUnknown, persisted.State)
				require.Equal(t, effect.Version+1, persisted.Version)
			} else {
				require.Equal(t, effect.State, persisted.State)
				require.Equal(t, effect.Version, persisted.Version)
			}
			exactReads := f.exactReads.Load()
			require.NoError(t, f.reconcile(t))
			_, again := f.approval(t)
			require.Len(t, again, len(listed), "repeated recovery must not append duplicate outcomes")
			require.Equal(t, exactReads, f.exactReads.Load(), "correct projections need no exact effect read")
			require.Zero(t, f.secretReads.Load())
			require.Equal(t, count, f.count.Load(), "recovery must never execute or repeat the action")
		})
	}
}

type approvalLostOutcomeEventStore struct {
	store.DeduplicatingExecutionEventStore
	lost atomic.Bool
}

func (s *approvalLostOutcomeEventStore) AppendExecutionEventIfAbsent(ctx context.Context, event *store.ExecutionEvent, key string) (*store.ExecutionEvent, bool, error) {
	var payload struct {
		ExecutionOutcome string `json:"executionOutcome"`
	}
	if event.Type == events.ExecutionEventTypeApprovalExecutionUpdated && json.Unmarshal(event.Content, &payload) == nil &&
		payload.ExecutionOutcome != "" && payload.ExecutionOutcome != "running" && !s.lost.Swap(true) {
		return nil, false, errors.New("injected crash after receipt commit")
	}
	return s.DeduplicatingExecutionEventStore.AppendExecutionEventIfAbsent(ctx, event, key)
}

func TestMCPApprovalRecoveryAfterBrokerReceiptCommit(t *testing.T) {
	for _, tc := range []struct {
		name     string
		decision string
		state    store.ExternalEffectState
		outcome  string
		count    int32
	}{
		{"tool_error", events.ExecutionEventTypeApprovalApproved, store.ExternalEffectSucceeded, "failed", 1},
		{"denial", events.ExecutionEventTypeApprovalDeclined, store.ExternalEffectFailed, "not_started", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newMCPApprovalRecoveryFixture(t)
			authorizer := f.broker.Prompts.(DurableACPMCPPromptAuthorizer)
			registerApprovalLease(t, authorizer.PromptLeases, f.ctx, f.request)
			original := f.broker.Executor
			f.broker.Executor = ACPMCPToolExecutorFunc(func(ctx context.Context, request harnessv2.MCPBrokerCallRequest, descriptor harnessv2.MCPToolDescriptor) (json.RawMessage, error) {
				_, err := original.ExecuteACPMCPTool(ctx, request, descriptor)
				return json.RawMessage(`{ "isError":true, "z":1e-7, "error":"simulated failure" }`), err
			})
			lost := &approvalLostOutcomeEventStore{DeduplicatingExecutionEventStore: f.events}
			f.broker.ApprovalEvents = lost
			done := f.start(f.request)
			pending := f.pending()
			f.decide(pending.ID, tc.decision)
			select {
			case response := <-done:
				require.Equal(t, http.StatusServiceUnavailable, response.Code)
			case <-f.ctx.Done():
				t.Fatal("broker did not return after losing the final outcome event")
			}
			require.True(t, lost.lost.Load())
			require.Equal(t, tc.count, f.count.Load())
			identity := store.ExternalEffectIdentity{
				Kind: acpMCPToolEffectKind, Namespace: f.request.Namespace,
				AggregateID: string(f.request.Authorization.RuntimeSessionUID), OperationID: string(f.request.Metadata.OperationID),
			}
			effect, err := f.control.GetExternalEffectByIdentity(f.ctx, identity)
			require.NoError(t, err)
			require.Equal(t, tc.state, effect.State)
			outcome, _, _, err := acpMCPApprovalReceiptOutcome(effect, pending.ID)
			require.NoError(t, err, "the broker's committed receipt must survive the Kubernetes JSON round-trip")
			require.Equal(t, tc.outcome, outcome)
			f.restart(t)
			require.NoError(t, f.reconcile(t))
			approval, _ := f.approval(t)
			require.Equal(t, tc.outcome, approval.ExecutionOutcome)
			require.NotEmpty(t, approval.ExecutionReason)
			require.Equal(t, tc.count, f.count.Load())
		})
	}
}

type approvalCancelDuringEffectReadStore struct {
	store.ExternalEffectStore
	cancel      context.CancelFunc
	interrupted atomic.Bool
}

func (s *approvalCancelDuringEffectReadStore) GetExternalEffect(ctx context.Context, id string) (*store.ExternalEffect, error) {
	if !s.interrupted.Swap(true) {
		// The first broker effect read follows its pending decision poll.
		// Cancel at that storage boundary, before it has a replacement value.
		s.cancel()
		return nil, ctx.Err()
	}
	return s.ExternalEffectStore.GetExternalEffect(ctx, id)
}

func TestMCPApprovalPostPollCancellationPersistsUnstartedReceipt(t *testing.T) {
	f := newMCPApprovalRecoveryFixture(t)
	leaseCtx, cancelLease := context.WithCancel(f.ctx)
	t.Cleanup(cancelLease)
	ctx, cancelRequest := context.WithCancel(f.ctx)
	t.Cleanup(cancelRequest)
	authorizer := f.broker.Prompts.(DurableACPMCPPromptAuthorizer)
	registerApprovalLease(t, authorizer.PromptLeases, leaseCtx, f.request)
	storage := &approvalCancelDuringEffectReadStore{ExternalEffectStore: f.control, cancel: func() {
		cancelLease()
		cancelRequest()
	}}
	f.broker.Effects = storage
	result := awaitMCPApprovalResult(t, f.startContext(ctx, f.request))
	require.True(t, storage.interrupted.Load())
	require.True(t, result.IsError)
	require.Contains(t, string(result.Result), `"code":"approval_stale"`)
	require.ErrorIs(t, ctx.Err(), context.Canceled)
	require.Zero(t, f.count.Load())
	approval, _ := f.approval(t)
	require.Equal(t, approvals.StatusCancelled, approval.Status)
	require.Equal(t, "not_started", approval.ExecutionOutcome)
	require.Equal(t, acpApprovalCodeStale, approval.ExecutionReason)
	effect, err := f.control.GetExternalEffectByIdentity(f.ctx, store.ExternalEffectIdentity{
		Kind: acpMCPToolEffectKind, Namespace: f.request.Namespace,
		AggregateID: string(f.request.Authorization.RuntimeSessionUID), OperationID: string(f.request.Metadata.OperationID),
	})
	require.NoError(t, err)
	require.Equal(t, store.ExternalEffectFailed, effect.State)
	outcome, reason, saved, err := acpMCPApprovalReceiptOutcome(effect, approval.ID)
	require.NoError(t, err)
	require.Equal(t, "not_started", outcome)
	require.Equal(t, acpApprovalCodeStale, reason)
	require.Equal(t, result.Result, saved)
}

type approvalRecoveryEventStore struct {
	store.DeduplicatingExecutionEventStore
	lists    atomic.Int32
	appends  atomic.Int32
	failNext atomic.Bool
}

func (s *approvalRecoveryEventStore) ListExecutionEvents(ctx context.Context, filter store.ExecutionEventFilter) ([]store.ExecutionEvent, error) {
	s.lists.Add(1)
	return s.DeduplicatingExecutionEventStore.ListExecutionEvents(ctx, filter)
}

func (s *approvalRecoveryEventStore) AppendExecutionEventIfAbsent(ctx context.Context, event *store.ExecutionEvent, key string) (*store.ExecutionEvent, bool, error) {
	s.appends.Add(1)
	if s.failNext.Swap(false) {
		return nil, false, errors.New("injected approval projection outage")
	}
	return s.DeduplicatingExecutionEventStore.AppendExecutionEventIfAbsent(ctx, event, key)
}

func TestMCPApprovalRecoveryRetriesFailedAndSupersededProjection(t *testing.T) {
	f := newMCPApprovalRecoveryFixture(t)
	call, effect := f.seed(t, store.ExternalEffectInFlight, "", true, nil)
	f.restart(t)
	observed := &approvalRecoveryEventStore{DeduplicatingExecutionEventStore: f.events}
	observed.failNext.Store(true)
	f.dispatcher.EventStore = observed
	require.EqualError(t, f.reconcile(t), "injected approval projection outage")
	persisted, err := f.control.GetExternalEffectByIdentity(f.ctx, effect.Identity)
	require.NoError(t, err)
	require.Equal(t, store.ExternalEffectOutcomeUnknown, persisted.State)
	before, _ := f.approval(t)
	require.Equal(t, "not_started", before.ExecutionOutcome)
	require.NoError(t, f.reconcile(t), "retry must release and reacquire the production epoch guard")
	approval, listed := f.approval(t)
	require.Equal(t, "unknown", approval.ExecutionOutcome)
	require.EqualValues(t, 2, observed.appends.Load())
	require.NoError(t, f.reconcile(t))
	require.EqualValues(t, 2, observed.appends.Load())

	// Model a delayed start-event append from before the crash. The same
	// effect version must still be able to repair this newer stale projection.
	require.NoError(t, f.broker.approvalOutcome(f.ctx, call, "running", "Approved action started", nil))
	late, _ := f.approval(t)
	require.Equal(t, "running", late.ExecutionOutcome)
	require.NoError(t, f.reconcile(t))
	repaired, repairedEvents := f.approval(t)
	require.Equal(t, "unknown", repaired.ExecutionOutcome)
	require.Len(t, repairedEvents, len(listed)+2)
	require.EqualValues(t, 3, observed.appends.Load())
	require.NoError(t, f.reconcile(t))
	require.EqualValues(t, 3, observed.appends.Load())
	require.EqualValues(t, 1, f.count.Load())
}

func TestMCPApprovalRecoveryPreservesCurrentLeaseAndPendingCalls(t *testing.T) {
	for _, state := range []store.ExternalEffectState{store.ExternalEffectPending, store.ExternalEffectInFlight} {
		t.Run(string(state), func(t *testing.T) {
			f := newMCPApprovalRecoveryFixture(t)
			_, effect := f.seed(t, state, "", false, nil)
			_, before := f.approval(t)
			reads := f.exactReads.Load()
			require.NoError(t, f.reconcile(t))
			require.Equal(t, reads, f.exactReads.Load())
			_, after := f.approval(t)
			require.Equal(t, before, after)
			persisted, err := f.control.GetExternalEffectByIdentity(f.ctx, effect.Identity)
			require.NoError(t, err)
			require.Equal(t, effect.State, persisted.State)
			require.Equal(t, effect.Version, persisted.Version)
			require.Zero(t, f.count.Load())
		})
	}
}

func TestMCPApprovalRecoveryDoesNotAttachEvidenceToReusedTaskName(t *testing.T) {
	f := newMCPApprovalRecoveryFixture(t)
	_, _ = f.seed(t, store.ExternalEffectSucceeded, "running", true, json.RawMessage(`{"workOrder":"simulated-1"}`))
	f.restart(t)
	_, before := f.approval(t)
	require.NoError(t, f.kube.Delete(f.ctx, f.task))
	replacement := f.task.DeepCopy()
	replacement.UID, replacement.ResourceVersion = "replacement-task-uid", ""
	require.NoError(t, f.kube.Create(f.ctx, replacement))
	require.NoError(t, f.reconcile(t))
	listed, err := approvals.ListEvents(f.ctx, f.events, replacement.Namespace, replacement.Name)
	require.NoError(t, err)
	require.Len(t, listed, len(before))
	require.Empty(t, approvals.Derive(approvals.FilterEventsForTaskUID(listed, string(replacement.UID)), time.Time{}))
}

func TestMCPApprovalRecoverySkipsMismatchedEffectsAndEmptyNamespaces(t *testing.T) {
	for _, mismatch := range []string{"no_effects", "other_namespace", "other_request", "other_operation"} {
		t.Run(mismatch, func(t *testing.T) {
			f := newMCPApprovalRecoveryFixture(t)
			_, effect := f.seed(t, store.ExternalEffectSucceeded, "running", true, json.RawMessage(`{"workOrder":"simulated-1"}`))
			observed := &approvalRecoveryEventStore{DeduplicatingExecutionEventStore: f.events}
			f.dispatcher.EventStore = observed
			effects := map[string]store.ExternalEffect{effect.ID: *effect}
			switch mismatch {
			case "no_effects":
				clear(effects)
			case "other_namespace":
				effect.Identity.Namespace = "other"
				effects[effect.ID] = *effect
			case "other_request":
				effect.RequestDigest = testControllerMCPDigest("other request")
				effects[effect.ID] = *effect
			case "other_operation":
				effect.Identity.OperationID = "other-operation"
				effects[effect.ID] = *effect
			}
			require.NoError(t, f.dispatcher.reconcileMCPApprovalExecutions(f.ctx, f.fence, []corev1alpha1.Task{*f.task}, effects))
			require.Zero(t, observed.appends.Load())
			if mismatch == "no_effects" || mismatch == "other_namespace" {
				require.Zero(t, observed.lists.Load(), "no candidate effects means no per-Task event reads")
			}
		})
	}
}

func TestMCPApprovalReceiptOutcomeValidatesDenialAndCompletedReceipts(t *testing.T) {
	const approvalID = "approval-under-test"
	for _, code := range []string{"approval_declined", "approval_expired", "approval_cancelled", "approval_stale"} {
		t.Run(code, func(t *testing.T) {
			response := acpApprovalError(approvalID, code)
			effect := &store.ExternalEffect{State: store.ExternalEffectFailed, Response: response, ResponseDigest: store.CanonicalBytesDigest(response)}
			outcome, reason, result, err := acpMCPApprovalReceiptOutcome(effect, approvalID)
			require.NoError(t, err)
			require.Equal(t, "not_started", outcome)
			require.Equal(t, code, reason)
			require.JSONEq(t, string(response), string(result))
			_, _, _, err = acpMCPApprovalReceiptOutcome(effect, "another-approval")
			require.Error(t, err)
			// A tool may itself return an error with a denial-shaped code. Its
			// Succeeded ledger state proves execution, not a broker denial.
			effect.State = store.ExternalEffectSucceeded
			outcome, _, _, err = acpMCPApprovalReceiptOutcome(effect, approvalID)
			require.NoError(t, err)
			require.Equal(t, "failed", outcome)
		})
	}
}

func TestMCPApprovalReceiptOutcomeCanonicalizesStoredJSON(t *testing.T) {
	canonical := json.RawMessage(`{"a":[1,100,9007199254740993],"isError":false,"z":0.0000001}`)
	for _, stored := range []json.RawMessage{
		canonical,
		json.RawMessage(`{ "z":1e-7, "isError":false, "a":[1.0,1e2,9007199254740993] }`),
	} {
		effect := &store.ExternalEffect{
			State: store.ExternalEffectSucceeded, Response: stored, ResponseDigest: store.CanonicalBytesDigest(canonical),
		}
		outcome, _, result, err := acpMCPApprovalReceiptOutcome(effect, "approval-under-test")
		require.NoError(t, err)
		require.Equal(t, "succeeded", outcome)
		require.Equal(t, canonical, result)
	}

	// A digest for a different JSON value never validates just because both
	// encodings are well formed or have the same fields.
	changed := &store.ExternalEffect{
		State: store.ExternalEffectSucceeded, Response: json.RawMessage(`{"a":[1,100,9007199254740992],"isError":false,"z":1e-7}`),
		ResponseDigest: store.CanonicalBytesDigest(canonical),
	}
	_, _, result, err := acpMCPApprovalReceiptOutcome(changed, "approval-under-test")
	require.Error(t, err)
	require.Empty(t, result)
}

func TestMCPApprovalRecoveryRejectsUnverifiableReceipt(t *testing.T) {
	for _, response := range []json.RawMessage{
		nil, json.RawMessage(`{`), json.RawMessage(`{"code":"approval_declined","approvalID":"approval-under-test"}`),
		acpApprovalError("another-approval", "approval_declined"), acpApprovalError("approval-under-test", "tool_outcome_unknown"),
	} {
		effect := &store.ExternalEffect{
			State: store.ExternalEffectFailed, Response: response, ResponseDigest: store.CanonicalBytesDigest(response),
		}
		outcome, _, result := mcpApprovalRecoveredOutcome(effect, "approval-under-test")
		require.Equal(t, "unknown", outcome)
		require.Empty(t, result)
	}
	response := json.RawMessage(`{"workOrder":"simulated-1"}`)
	effect := &store.ExternalEffect{State: store.ExternalEffectSucceeded, Response: response, ResponseDigest: testControllerMCPDigest("wrong receipt")}
	outcome, _, result := mcpApprovalRecoveredOutcome(effect, "approval-under-test")
	require.Equal(t, "unknown", outcome)
	require.Empty(t, result)
}
