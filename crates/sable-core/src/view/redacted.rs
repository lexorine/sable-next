use matrix_sdk::deserialized_responses::TimelineEvent;
use matrix_sdk::room::Room;
use matrix_sdk::ruma::events::AnySyncTimelineEvent;
use matrix_sdk::ruma::serde::Raw;
use matrix_sdk_ui::timeline::{MsgLikeKind, TimelineItemContent};

use crate::redacted::RedactedContentView;

use super::content::content;
use super::profile::per_message_profile;
use super::raw::RawFields;

/// `None` unless the event is an unredacted message.
pub async fn redacted_content_view(
    room: &Room,
    event: Raw<AnySyncTimelineEvent>,
) -> Option<RedactedContentView> {
    let raw = event
        .deserialize_as_unchecked::<RawFields>()
        .unwrap_or_default();
    let item_content =
        TimelineItemContent::from_event(room, TimelineEvent::from_plaintext(event)).await?;
    let TimelineItemContent::MsgLike(message) = &item_content else {
        return None;
    };
    if matches!(message.kind, MsgLikeKind::Redacted) {
        return None;
    }
    let profile = per_message_profile(raw.content.as_ref());
    Some(RedactedContentView {
        content: Some(content(&item_content, profile.as_ref(), &raw, None)),
        per_message_profile: profile,
    })
}
