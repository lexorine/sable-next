// @vitest-environment happy-dom

import { render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';

import type { Rpc, TimelineItemView } from '#src/generated/protocol';
import { CoreError } from '#src/transport';

vi.mock('#lib/core/context.js');

import { core } from '#lib/core/__mocks__/context.js';

vi.mock('#lib/rooms/room-list.svelte.js', () => ({
  useRoomList: () => ({ rooms: [] }),
}));

import { setPreference } from '#lib/settings/preferences.svelte.js';
import { withRowFields } from '#lib/features/room/timeline/row-fixtures.js';
import MessageBody from './MessageBody.svelte';
import { resetRedactedReveals, revealRedacted } from './redacted-reveals.svelte.js';

const ROOM = '!room:example.org';
const EVENT = '$redacted';
const redactedContent = core.rpc.messages.redactedContent;
const rpc = core.rpc as unknown as Rpc;
const observerBackup = globalThis.IntersectionObserver;

const secret = {
  content: {
    kind: 'message' as const,
    body: 'the secret',
    html: '<p>the secret</p>',
    emote: false,
    notice: false,
    edited: false,
    jumbo: null,
  },
  per_message_profile: null,
};

beforeEach(() => {
  resetRedactedReveals();
});

afterEach(() => {
  redactedContent.mockReset();
  setPreference('autoRevealRedacted', false);
  globalThis.IntersectionObserver = observerBackup;
});

function tombstone(): TimelineItemView {
  return withRowFields({
    id: 'item',
    event_id: EVENT,
    transaction_id: null,
    send_state: null,
    sender: '@alice:example.org',
    sender_name: 'Alice',
    sender_avatar: null,
    timestamp: 0,
    content: { kind: 'redacted', reason: 'spam', redacted_by: null },
    in_reply_to: null,
    thread_root: null,
    thread_summary: null,
    reactions: [],
    is_own: false,
    read_by: [],
    read_timestamps: {},
    per_message_profile: null,
    bundled_link_previews: [],
    link_previews_removed: null,
    mention: 'none',
    forwarded: null,
    forum_title: null,
  });
}

async function renderTombstone(canRedactOthers = true) {
  const view = render(MessageBody, { item: tombstone(), canRedactOthers, roomId: ROOM });
  await tick();
  return view;
}

function visibleImmediately() {
  globalThis.IntersectionObserver = class {
    readonly callback: IntersectionObserverCallback;
    constructor(callback: IntersectionObserverCallback) {
      this.callback = callback;
    }
    observe() {
      this.callback(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        this as unknown as IntersectionObserver
      );
    }
    disconnect() {}
  } as unknown as typeof IntersectionObserver;
}

test('stays collapsed until revealed', async () => {
  visibleImmediately();
  await renderTombstone();

  expect(screen.getByText(/spam/)).toBeInTheDocument();
  expect(redactedContent).not.toHaveBeenCalled();
});

test('a reveal shows the original under the trash-icon tombstone', async () => {
  redactedContent.mockResolvedValue(secret);
  await renderTombstone();
  await revealRedacted(rpc, ROOM, EVENT);
  await tick();

  expect(redactedContent).toHaveBeenCalledWith({ room_id: ROOM, event_id: EVENT });
  expect(screen.getByText('the secret')).toBeInTheDocument();
  expect(screen.getByText(/spam/)).toBeInTheDocument();
});

test('auto mode fetches once per event while visible, even without moderator power', async () => {
  setPreference('autoRevealRedacted', true);
  visibleImmediately();
  redactedContent.mockResolvedValue(secret);

  // No canRedactOthers gate any more: the UI mounts for everyone and lets the
  // homeserver decide. Two mounts of the same event still share one fetch.
  await renderTombstone(false);
  await renderTombstone();
  await vi.waitFor(() => expect(screen.getAllByText('the secret')).toHaveLength(2));
  expect(redactedContent).toHaveBeenCalledTimes(1);
});

test('auto mode stops asking once the server lacks MSC2815', async () => {
  setPreference('autoRevealRedacted', true);
  visibleImmediately();
  redactedContent.mockRejectedValue(new CoreError({ code: 'unsupported' }));

  await renderTombstone();
  await vi.waitFor(() => expect(screen.getByText(/cannot show deleted/i)).toBeInTheDocument());
  await revealRedacted(rpc, ROOM, '$other', true);

  expect(redactedContent).toHaveBeenCalledTimes(1);
});

test('a manual reveal retries an outage but not a refusal', async () => {
  redactedContent.mockRejectedValue(new CoreError({ code: 'unavailable' }));
  await revealRedacted(rpc, ROOM, EVENT);
  await revealRedacted(rpc, ROOM, EVENT, true);
  expect(redactedContent).toHaveBeenCalledTimes(1);

  redactedContent.mockRejectedValue(new CoreError({ code: 'denied' }));
  await revealRedacted(rpc, ROOM, EVENT);
  await revealRedacted(rpc, ROOM, EVENT);
  expect(redactedContent).toHaveBeenCalledTimes(2);

  await renderTombstone();
  expect(screen.getByText(/don’t have permission/i)).toBeInTheDocument();
});
