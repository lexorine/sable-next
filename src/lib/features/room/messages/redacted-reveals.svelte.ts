import { SvelteMap } from 'svelte/reactivity';

import type { Rpc, TimelineItemContentView } from '#src/generated/protocol';
import { CoreError } from '#src/transport';

export type RevealFailure = 'denied' | 'unsupported' | 'gone' | 'unavailable' | 'failed';

export type Reveal =
  | { kind: 'loading' }
  | { kind: 'shown'; content: TimelineItemContentView }
  | { kind: 'failed'; reason: RevealFailure };

const FINAL: ReadonlySet<RevealFailure> = new Set(['denied', 'unsupported', 'gone']);

const reveals = new SvelteMap<string, Reveal>();
let serverUnsupported = false;

const key = (roomId: string, eventId: string) => `${roomId} ${eventId}`;

export function redactedReveal(roomId: string, eventId: string): Reveal | undefined {
  return reveals.get(key(roomId, eventId));
}

/** Fetches at most once per event; `auto` never retries and stops once the server lacks MSC2815. */
export async function revealRedacted(
  rpc: Rpc,
  roomId: string,
  eventId: string,
  auto = false
): Promise<Reveal> {
  const id = key(roomId, eventId);
  const current = reveals.get(id);
  if (current && (auto || current.kind !== 'failed' || FINAL.has(current.reason))) return current;
  if (auto && serverUnsupported) return { kind: 'failed', reason: 'unsupported' };

  reveals.set(id, { kind: 'loading' });
  let next: Reveal;
  try {
    const { content } = await rpc.messages.redactedContent({ room_id: roomId, event_id: eventId });
    next = content ? { kind: 'shown', content } : { kind: 'failed', reason: 'gone' };
  } catch (cause) {
    const code = cause instanceof CoreError ? cause.detail.code : null;
    next = {
      kind: 'failed',
      reason: code === 'denied' || code === 'unsupported' || code === 'unavailable' ? code : 'failed',
    };
    if (code === 'unsupported') serverUnsupported = true;
  }
  reveals.set(id, next);
  return next;
}

export function resetRedactedReveals(): void {
  reveals.clear();
  serverUnsupported = false;
}
