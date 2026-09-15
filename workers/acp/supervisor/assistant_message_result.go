package supervisor

import (
	"encoding/json"
	"errors"
	"strings"

	"github.com/orka-agents/orka/internal/acp"
)

const (
	maxAssistantResultMessageIDs     = 256
	maxAssistantResultMessageIDBytes = 512
)

// assistantMessageResult keeps the newest distinct, named assistant message as
// the terminal answer. OpenCode emits a messageId for both ordinary replies and
// compaction summaries; concatenating all messages exposes a compaction/work note
// as part of the answer. This uses native identity, never a text/heading heuristic.
// Earlier messages still travel through the normal execution-event stream.
//
// First observation determines message order. A late chunk for a previously seen
// older message must not make that message current again. State is bounded and
// belongs to one prompt, so repeated native IDs in other prompts are independent.
// Callers serialize access with the supervisor mutex.
type assistantMessageResult struct {
	messageID string
	seen      map[string]struct{}
	text      strings.Builder
	overflow  bool
	failure   error
}

func (r *assistantMessageResult) append(messageID, text string, limit int) error {
	if r.failure != nil {
		return r.failure
	}
	if messageID == "" {
		if r.messageID != "" {
			return r.invalidate(errors.New("identified OpenCode assistant stream lost its message identity"))
		}
		// Retain the existing aggregation for entirely anonymous legacy streams.
		// Once named messages appear, a missing identity must fail closed rather
		// than silently merging unknown content into a selected final answer.
		return nil
	}
	if len(messageID) > maxAssistantResultMessageIDBytes {
		return r.invalidate(errors.New("OpenCode assistant message identity exceeds the supported limit"))
	}
	if _, seen := r.seen[messageID]; !seen {
		if len(r.seen) >= maxAssistantResultMessageIDs {
			return r.invalidate(errors.New("OpenCode assistant message identity count exceeds the supported limit"))
		}
		if r.seen == nil {
			r.seen = make(map[string]struct{})
		}
		r.seen[messageID] = struct{}{}
		r.messageID = messageID
		r.text.Reset()
		r.overflow = false
	}
	if messageID == r.messageID {
		appendBoundedPromptText(&r.text, &r.overflow, text, limit)
	}
	return nil
}

// Keep identity failures sticky through settlement and duplicate admission. The
// native provider can race cancellation with end_turn; rejecting the wire stream
// alone must not leave a replayable successful result for the invalid prompt.
func (r *assistantMessageResult) invalidate(err error) error {
	if r.failure == nil {
		r.failure = err
	}
	return r.failure
}

// openCodeAssistantMessageIdentity observes only identity metadata. Thought
// content stays ignored: a newer reasoning-only assistant must invalidate an
// older text candidate, but its reasoning must never become a visible answer.
func openCodeAssistantMessageIdentity(notification *acp.SessionNotification) (string, bool, error) {
	if notification == nil {
		return "", false, nil
	}
	var envelope struct {
		SessionUpdate string          `json:"sessionUpdate"`
		MessageID     json.RawMessage `json:"messageId"`
	}
	if err := json.Unmarshal(notification.Update, &envelope); err != nil {
		return "", false, errors.New("invalid OpenCode assistant identity envelope")
	}
	if envelope.SessionUpdate != acpUpdateAgentMessageChunk && envelope.SessionUpdate != acpUpdateAgentThoughtChunk {
		return "", false, nil
	}
	var messageID string
	if len(envelope.MessageID) != 0 {
		if err := json.Unmarshal(envelope.MessageID, &messageID); err != nil {
			return "", false, errors.New("invalid OpenCode assistant message identity")
		}
	}
	return messageID, true, nil
}
