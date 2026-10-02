<!--
  MSC2815: the "view deleted content" affordance on a tombstoned message.

  It is rendered only when the user holds the room's `redact` power level, which
  is the same gate the server applies. The recovered content is handed to
  `MessageBody` as a synthetic timeline item, so an unredacted message renders
  through exactly the same components as a live one — images, polls, stickers,
  per-message-profile fallbacks and all — instead of a second rendering path
  that could drift from the first.

  The outcomes are distinguished because they mean different things to the
  person who clicked:

  * content arrives: shown, with a label saying it is the original
  * the core answers with no content: a homeserver without the feature ignored
    the query parameter, and the affordance retires rather than repeating
  * `unsupported` or `denied`: both are permanent for this event, so the button
    becomes the reason and stops inviting another attempt
  * anything else is retryable, so the button stays
-->
<script lang="ts">
  import type { TimelineItemContentView, TimelineItemView } from '#src/generated/protocol';
  import type { MatrixLink } from '#lib/rooms/matrix-link.js';

  import { useCoreClient } from '#lib/core/context.js';
  import { i18n } from '#lib/i18n.js';
  import { toasts } from '#lib/ui/toasts.svelte.js';
  import Button from '#lib/ui/primitives/Button.svelte';

  import MessageBody from './MessageBody.svelte';

  interface Props {
    roomId: string;
    /** The tombstoned item; only its identity is needed to build the request. */
    item: TimelineItemView;
    senderTimezone?: string | null;
    onMatrixLink?: (link: MatrixLink, anchor: HTMLAnchorElement) => void;
  }

  let { roomId, item, senderTimezone = null, onMatrixLink }: Props = $props();

  const core = useCoreClient();

  type Phase =
    | { kind: 'idle' }
    | { kind: 'loading' }
    | { kind: 'shown'; item: TimelineItemView }
    | { kind: 'failed'; message: string; retryable: boolean };

  let phase = $state<Phase>({ kind: 'idle' });

  /**
   * A recovered message rendered as the item it would have been, so
   * `MessageBody` needs no knowledge that the event was redacted.
   */
  function recovered(content: TimelineItemContentView, eventId: string): TimelineItemView {
    return {
      ...item,
      id: `${item.id}:unredacted`,
      event_id: eventId,
      content,
      // The original content supersedes whatever the redaction left behind.
      reactions: [],
      read_by: [],
      thread_summary: null,
    };
  }

  /**
   * The core collapses `unsupported`, `content deleted` and `not found` into one
   * permanent answer, because from the user's side all three mean the same
   * thing: asking again will not produce content. Only an unreachable server is
   * worth another attempt.
   */
  function failure(cause: unknown): { message: string; retryable: boolean } {
    const code = (cause as { detail?: { code?: string } } | undefined)?.detail?.code;
    switch (code) {
      case 'denied':
        return { message: $i18n.t('timeline.redactedDenied'), retryable: false };
      case 'unavailable':
        return { message: $i18n.t('timeline.redactedUnavailable'), retryable: true };
      default:
        return { message: $i18n.t('timeline.redactedFailed'), retryable: true };
    }
  }

  async function reveal(): Promise<void> {
    const eventId = item.event_id;
    if (!eventId || phase.kind === 'loading') return;
    phase = { kind: 'loading' };

    try {
      const { content } = await core.commands.redactedContent(roomId, eventId);
      phase = content
        ? { kind: 'shown', item: recovered(content, eventId) }
        : {
            kind: 'failed',
            message: $i18n.t('timeline.redactedUnsupported'),
            retryable: false,
          };
    } catch (cause) {
      const { message, retryable } = failure(cause);
      phase = { kind: 'failed', message, retryable };
      toasts.error(message);
    }
  }
</script>

{#if phase.kind === 'shown'}
  <div class="unredacted">
    <span class="unredacted-label">{$i18n.t('timeline.redactedShown')}</span>
    <MessageBody
      item={phase.item}
      canRedactOthers={false}
      {senderTimezone}
      {onMatrixLink}
    />
  </div>
{:else}
  <Button
    class="unredacted-reveal"
    size="small"
    variant="ghost"
    loading={phase.kind === 'loading'}
    onclick={() => {
      void reveal();
    }}
  >
    {#if phase.kind === 'loading'}
      {$i18n.t('timeline.redactedLoading')}
    {:else if phase.kind === 'failed' && !phase.retryable}
      {phase.message}
    {:else}
      {$i18n.t('timeline.viewRedacted')}
    {/if}
  </Button>
{/if}