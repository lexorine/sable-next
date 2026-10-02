// @vitest-environment happy-dom

import { render, screen } from '@testing-library/svelte';
import { userEvent } from '@testing-library/user-event';
import { tick } from 'svelte';
import { afterEach, expect, test, vi } from 'vitest';

import type { TimelineItemContentView, TimelineItemView } from '#src/generated/protocol';

vi.mock('#lib/core/context.js');

import { core } from '#lib/core/__mocks__/context.js';

vi.mock('#lib/rooms/room-list.svelte.js', () => ({
  useRoomList: () => ({ rooms: [] }),
}));

import MessageBody from './MessageBody.svelte';

const redacted = vi.fn<(...args: never[]) => Promise<unknown>>();

afterEach(() => {
  redacted.mockReset();
  Object.assign(core.commands, { redactedContent: redacted });
});

function tombstoned(): TimelineItemView {
  return {
    id: 'item',
    event_id: '$redacted',
    transaction_id: null,
    send_state: null,
    sender: '@alice:example.org',
    sender_name: 'Alice',
    sender_avatar: null,
    timestamp: 0,
    content: { kind: 'redacted', reason: 'spam' },
    in_reply_to: null,
    thread_root: null,
    thread_summary: null,
    reactions: [],
    is_own: false,
    read_by: [],
    per_message_profile: null,
    bundled_link_previews: [],
    link_previews_removed: null,
    mention: 'none',
    forwarded: null,
  };
}

function message(body: string): TimelineItemContentView {
  return {
    kind: 'message',
    body,
    html: `<p>${body}</p>`,
    formatted: false,
    edited: false,
    source: null,
    in_reply_to: null,
    thread_root: null,
    thread_summary: null,
    reply_to: null,
  };
}

/** Renders the tombstone with the affordance either offered or withheld. */
function renderTombstone(canRedactOthers: boolean) {
  return render(MessageBody, {
    item: tombstoned(),
    canRedactOthers,
    roomId: '!room:example.org',
  });
}

test('a user without the redact level is never offered the original content', async () => {
  renderTombstone(false);
  await tick();

  expect(screen.getByText(/spam/)).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /deleted content/i })).not.toBeInTheDocument();
  expect(redacted).not.toHaveBeenCalled();
});

test('a moderator is offered the original content and gets it on click', async () => {
  redacted.mockResolvedValue({ content: message('the secret'), per_message_profile: null });
  const user = userEvent.setup();
  renderTombstone(true);
  await tick();

  const button = screen.getByRole('button', { name: /deleted content/i });
  await user.click(button);
  await tick();

  expect(redacted).toHaveBeenCalledWith('!room:example.org', '$redacted');
  expect(await screen.findByText('the secret')).toBeInTheDocument();
  // The tombstone stays: the point is to see what was deleted, not to un-delete
  // it in the timeline.
  expect(screen.getByText(/spam/)).toBeInTheDocument();
});

test('a homeserver with no such endpoint stops offering it', async () => {
  // A server that ignores the query parameter answers with nothing to show,
  // which is the same end state as a permanent refusal.
  redacted.mockResolvedValue({ content: null, per_message_profile: null });
  const user = userEvent.setup();
  renderTombstone(true);
  await tick();

  await user.click(screen.getByRole('button', { name: /deleted content/i }));
  await tick();

  expect(await screen.findByText(/cannot show deleted content/i)).toBeInTheDocument();
  expect(screen.queryByText('the secret')).not.toBeInTheDocument();
});

test('a refusal ends the affordance rather than inviting a retry', async () => {
  redacted.mockRejectedValue({ detail: { code: 'denied' } });
  const user = userEvent.setup();
  renderTombstone(true);
  await tick();

  await user.click(screen.getByRole('button', { name: /deleted content/i }));
  await tick();

  expect(await screen.findByText(/don't have permission/i)).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /deleted content/i })).not.toBeInTheDocument();
});

test('erased content is reported as permanent, not retryable', async () => {
  redacted.mockRejectedValue({ detail: { code: 'unsupported' } });
  const user = userEvent.setup();
  renderTombstone(true);
  await tick();

  await user.click(screen.getByRole('button', { name: /deleted content/i }));
  await tick();

  expect(await screen.findByText(/cannot show deleted content/i)).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /deleted content/i })).not.toBeInTheDocument();
});

test('an unrecognised failure is retryable, since something else may be wrong', async () => {
  redacted.mockRejectedValue({ detail: { code: 'something_new' } });
  const user = userEvent.setup();
  renderTombstone(true);
  await tick();

  await user.click(screen.getByRole('button', { name: /deleted content/i }));
  await tick();

  expect(screen.getByRole('button', { name: /deleted content/i })).toBeInTheDocument();
});

test('a homeserver outage keeps the button so the read can be retried', async () => {
  redacted.mockRejectedValue({ detail: { code: 'unavailable' } });
  const user = userEvent.setup();
  renderTombstone(true);
  await tick();

  await user.click(screen.getByRole('button', { name: /deleted content/i }));
  await tick();

  expect(screen.getByRole('button', { name: /deleted content/i })).toBeInTheDocument();
});

test('one failure does not send a second request', async () => {
  redacted.mockResolvedValue({ content: null, per_message_profile: null });
  const user = userEvent.setup();
  renderTombstone(true);
  await tick();

  await user.click(screen.getByRole('button', { name: /deleted content/i }));
  await tick();

  expect(redacted).toHaveBeenCalledTimes(1);
});

test('no affordance without a room, since there is nothing to address the request to', async () => {
  render(MessageBody, { item: tombstoned(), canRedactOthers: true, roomId: '' });
  await tick();

  expect(screen.getByText(/spam/)).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /deleted content/i })).not.toBeInTheDocument();
});
