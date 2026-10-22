<!-- MSC2815: the original content of a redacted message, revealed from the menu or automatically. -->
<script lang="ts">
  import type { Attachment } from 'svelte/attachments';
  import type { TimelineItemView } from '#src/generated/protocol';
  import type { MatrixLink } from '#lib/rooms/matrix-link.js';

  import { useCoreClient } from '#lib/core/context.js';
  import { i18n } from '#lib/i18n.js';
  import { preferences } from '#lib/settings/preferences.svelte.js';

  import FormattedBody from './FormattedBody.svelte';
  import MessageBody from './MessageBody.svelte';
  import { redactedReveal, revealRedacted, type RevealFailure } from './redacted-reveals.svelte.js';

  interface Props {
    roomId: string;
    eventId: string;
    item: TimelineItemView;
    senderTimezone?: string | null;
    onMatrixLink?: (link: MatrixLink, anchor: HTMLAnchorElement) => void;
  }

  let { roomId, eventId, item, senderTimezone = null, onMatrixLink }: Props = $props();

  const core = useCoreClient();
  const reveal = $derived(redactedReveal(roomId, eventId));

  const FAILURES: Record<RevealFailure, string> = {
    denied: 'timeline.redactedDenied',
    unsupported: 'timeline.redactedUnsupported',
    gone: 'timeline.redactedGone',
    unavailable: 'timeline.redactedUnavailable',
    failed: 'timeline.redactedFailed',
  };

  const autoReveal: Attachment<HTMLElement> = (node) => {
    if (!preferences.autoRevealRedacted || typeof IntersectionObserver === 'undefined') return;
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      void revealRedacted(core.rpc, roomId, eventId, true);
    });
    observer.observe(node);
    return () => observer.disconnect();
  };
</script>

<div class="redacted-content" {@attach autoReveal}>
  {#if reveal?.kind === 'shown'}
    <div class="unredacted">
      <span class="note">{i18n.t('timeline.redactedShown')}</span>
      <!-- MessageBody has no text branch; TimelineItem renders text itself. -->
      {#if reveal.content.kind === 'message'}
        <FormattedBody html={reveal.content.html} {senderTimezone} {onMatrixLink} />
      {:else}
        <MessageBody
          item={{
            ...item,
            id: `${item.id}:unredacted`,
            content: reveal.content,
            reactions: [],
            read_by: [],
            thread_summary: null,
          }}
          canRedactOthers={false}
          {senderTimezone}
          {onMatrixLink}
        />
      {/if}
    </div>
  {:else if reveal?.kind === 'loading'}
    <span class="note">{i18n.t('timeline.redactedLoading')}</span>
  {:else if reveal?.kind === 'failed'}
    <span class="note">{i18n.t(FAILURES[reveal.reason])}</span>
  {/if}
</div>

<style>
  .unredacted {
    border-inline-start: var(--border-width) solid var(--primary-main);
    display: flex;
    flex-direction: column;
    gap: var(--space-100);
    margin-block-start: var(--space-100);
    padding-inline-start: var(--space-200);
  }

  .note {
    color: var(--surface-var-on-container);
    display: block;
    font-size: var(--font-size-small);
  }
</style>
