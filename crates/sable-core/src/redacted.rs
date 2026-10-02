//! MSC2815: a moderator may read the content of a redacted event.
//!
//! The endpoint is the ordinary `GET /rooms/{roomId}/event/{eventId}` with one
//! extra query parameter, `fi.mau.msc2815.include_unredacted_content=true`.
//! Ruma's `get_room_event` cannot express a query parameter on someone else's
//! endpoint, so the request is hand-rolled into the [`OutgoingRequest`] shape,
//! the way [`crate::webpush`] does for MSC4174.
//!
//! Four answers are possible and all of them have to be survivable:
//!
//! * 200 with the unredacted event — the only good answer.
//! * 403, either because the caller is below the room's `redact` level or
//!   because the server has the flag off and refuses the unknown parameter.
//! * 404 with `FI.MAU.MSC2815_UNREDACTED_CONTENT_DELETED`, which is not a
//!   missing event: the server keeps the unredacted copy only until
//!   `redaction_retention_period` elapses.
//! * 200 with the event still redacted, which is what a server without the
//!   feature does with an unknown query parameter. The status code alone
//!   cannot distinguish that from a real answer, so the content is checked too.

use http::Method;
use matrix_sdk::ruma::{
    OwnedEventId, OwnedRoomId, UserId,
    api::{
        EmptyBody, IncomingResponse, MatrixVersion, Metadata, OutgoingRequest, auth_scheme,
        error::{DeserializationError, IntoHttpError},
        path_builder::{PathBuilder, StablePathSelector, VersionHistory},
    },
    events::room::power_levels::RoomPowerLevels,
    serde::Raw,
};
use tracing::warn;

use crate::Core;
use crate::protocol::{CommandErr, RedactedContentView};

/// The unstable feature a homeserver advertises in `/versions`.
///
/// Synapse's name is retained because the query parameter and the error code
/// carry it; a stable name does not exist.
pub(crate) const UNSTABLE_FEATURE: &str = "fi.mau.msc2815";

/// The query parameter that switches the endpoint on.
const QUERY_PARAMETER: &str = "fi.mau.msc2815.include_unredacted_content";

/// The errcode for "the unredacted copy is gone", which arrives as a 404 that is
/// about retention rather than about a missing event.
const CONTENT_DELETED: &str = "FI.MAU.MSC2815_UNREDACTED_CONTENT_DELETED";

/// MSC2815's gate is the room's `redact` level: the same threshold that lets a
/// user redact other people's messages lets them read what those messages said.
///
/// Sable does not send the parameter for anyone below it, so the server's 403
/// stays a backstop for a power level that changed underneath us.
#[must_use]
pub fn may_view_redacted(power_levels: &RoomPowerLevels, user_id: &UserId) -> bool {
    power_levels.for_user(user_id) >= power_levels.redact
}

/// Why an unredacted read did not produce content.
///
/// Each variant is a distinct sentence for the UI. `Unsupported` means the
/// homeserver never had this feature, so the affordance can go away for good;
/// the others describe this one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RedactedContentError {
    /// 403: the caller is below the room's `redact` level.
    NotPermitted,
    /// 404 with the MSC2815 code: the server already erased the unredacted copy.
    ContentDeleted,
    /// 404 without it: no such event, or no such endpoint.
    EventNotFound,
    /// 403 on a server that advertises no such feature: the parameter was
    /// refused as unknown, so there is no endpoint here.
    Unsupported,
    /// 5xx, or a request the client could not complete.
    Unavailable,
}

impl RedactedContentError {
    /// Maps one MSC2815 failure onto the protocol's error vocabulary.
    ///
    /// This is a named function rather than a `From` impl on purpose: an extra
    /// `From<X> for CommandErr` makes `Ok(value)` ambiguous wherever the error
    /// type is still to be inferred, which breaks unrelated code.
    ///
    /// `NotPermitted` becomes `Denied` and a server without the feature becomes
    /// `Unsupported`: the UI shows the first as "you may not" and hides the
    /// affordance for the second, so the two must not collapse together.
    /// `ContentDeleted` and `EventNotFound` also become `Unsupported` — both are
    /// permanent, and neither would ever produce content on a retry.
    #[must_use]
    pub const fn into_command_err(self) -> CommandErr {
        match self {
            Self::NotPermitted => CommandErr::Denied,
            Self::Unsupported | Self::ContentDeleted | Self::EventNotFound => {
                CommandErr::Unsupported
            }
            Self::Unavailable => CommandErr::Unavailable,
        }
    }

    /// Whether asking again could plausibly produce content.
    ///
    /// Only `Unavailable` can change into an answer: nothing later adds back
    /// erased content, and a power level or a feature flag does not appear
    /// mid-session. Retrying the others just spends another request.
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        !matches!(self, Self::Unavailable)
    }

    /// The wire name, so the error is greppable in a bug report.
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::NotPermitted => "not_permitted",
            Self::ContentDeleted => "content_deleted",
            Self::EventNotFound => "event_not_found",
            Self::Unsupported => "unsupported",
            Self::Unavailable => "unavailable",
        }
    }
}

/// Reads one redacted event's original content.
///
/// The `room` is needed to render the event: the SDK's content parser resolves
/// relations and per-message profiles through it, so an unredacted message goes
/// through exactly the same path as a live one.
pub(crate) async fn fetch(
    client: &matrix_sdk::Client,
    room: &matrix_sdk::Room,
    room_id: &OwnedRoomId,
    event_id: &OwnedEventId,
) -> Result<RedactedContentView, RedactedContentError> {
    // Read once so an unsupported server is reported as unsupported instead of
    // as a mystery refusal. The result does not gate the request: the server
    // decides, and a server that implements the endpoint without advertising it
    // should still answer.
    let advertised = client
        .unstable_features()
        .await
        .is_ok_and(|features| features.contains(&UNSTABLE_FEATURE.into()));

    let event = client
        .send(ReadRedactedEvent {
            room_id: room_id.clone(),
            event_id: event_id.clone(),
        })
        .await
        .map_err(|error| classify(&error, advertised))?;

    // A server without the feature answers 200 with the event still redacted,
    // which arrives here as an empty view rather than as an error.
    Ok(into_view(room, event).await)
}

/// Turns the bare event into a view, logging rather than failing when it cannot.
async fn into_view(room: &matrix_sdk::Room, event: RedactedEvent) -> RedactedContentView {
    crate::view::redacted_content_view(room, &event.event)
        .await
        .unwrap_or_else(|| {
            warn!(
                "the homeserver answered an unredacted read with nothing to show: either it \
ignored the query parameter or the event carries no message content"
            );
            RedactedContentView::empty()
        })
}

impl Core {
    /// MSC2815: reads a redacted event's original content.
    ///
    /// The power-level check is the client-side half of the MSC2815 gate, and it
    /// is what decides whether the affordance is offered at all. The server
    /// refuses a request below the `redact` level anyway, but a refused request
    /// is a worse experience than an absent button.
    pub(crate) async fn redacted_content(
        &self,
        room_id: &OwnedRoomId,
        event_id: &OwnedEventId,
    ) -> Result<RedactedContentView, CommandErr> {
        let room = self.room(room_id).await?;
        let user_id = room
            .client()
            .user_id()
            .ok_or(CommandErr::NotLoggedIn)?
            .to_owned();

        // An invited room carries only stripped state, so the levels are often
        // absent; the spec default of 50 then applies, as it does elsewhere.
        let power_levels = room.power_levels_or_default().await;
        if !may_view_redacted(&power_levels, &user_id) {
            tracing::debug!(
                context = "redacted_content",
                category = "denied",
                "the user is below the room's redact level"
            );
            return Err(CommandErr::Denied);
        }

        fetch(&room.client(), &room, room_id, event_id)
            .await
            .map_err(RedactedContentError::into_command_err)
    }
}

/// Classifies a failed request into the sentence the UI shows.
fn classify(error: &matrix_sdk::HttpError, advertised: bool) -> RedactedContentError {
    let status = error
        .as_client_api_error()
        .map_or(0, |api_error| api_error.status_code.as_u16());
    let errcode = error.as_client_api_error().and_then(|api_error| {
        let kind = api_error.error_kind()?;
        let code = kind.errcode();
        Some(code.as_str().to_owned())
    });

    match status {
        403 if !advertised => RedactedContentError::Unsupported,
        403 => RedactedContentError::NotPermitted,
        404 if errcode.as_deref() == Some(CONTENT_DELETED) => RedactedContentError::ContentDeleted,
        404 => RedactedContentError::EventNotFound,
        // A server that does not know the path answers 400/405/501 rather than
        // 403, depending on its router.
        400 | 405 | 501 => RedactedContentError::Unsupported,
        _ => RedactedContentError::Unavailable,
    }
}

/// `GET /rooms/{roomId}/event/{eventId}` plus the MSC2815 query parameter.
///
/// `VersionHistory` is reused so the `r0`/`v3` split keeps working: the
/// parameter rides on whichever path version negotiation picks.
#[derive(Clone, Debug)]
struct ReadRedactedEvent {
    room_id: OwnedRoomId,
    event_id: OwnedEventId,
}

impl Metadata for ReadRedactedEvent {
    const METHOD: Method = Method::GET;
    const RATE_LIMITED: bool = false;
    type Authentication = auth_scheme::AccessToken;
    type PathBuilder = VersionHistory;
    const PATH_BUILDER: VersionHistory = VersionHistory::new(
        &[],
        &[
            (
                StablePathSelector::Version(MatrixVersion::V1_0),
                "/_matrix/client/r0/rooms/{room_id}/event/{event_id}",
            ),
            (
                StablePathSelector::Version(MatrixVersion::V1_1),
                "/_matrix/client/v3/rooms/{room_id}/event/{event_id}",
            ),
        ],
        None,
        None,
    );
}

impl OutgoingRequest for ReadRedactedEvent {
    type Body = EmptyBody;
    type EndpointError = matrix_sdk::ruma::api::error::Error;
    type IncomingResponse = RedactedEvent;

    fn try_into_http_request_inner(
        self,
        base_url: &str,
        path_builder_input: <VersionHistory as PathBuilder>::Input<'_>,
    ) -> Result<http::Request<Self::Body>, IntoHttpError> {
        http::Request::builder()
            .method(Self::METHOD)
            .uri(Self::make_endpoint_url(
                path_builder_input,
                base_url,
                &[&self.room_id, &self.event_id],
                &format!("{QUERY_PARAMETER}=true"),
            )?)
            .body(EmptyBody)
            .map_err(Into::into)
    }
}

/// The endpoint returns a bare event rather than an envelope.
#[derive(Debug)]
struct RedactedEvent {
    event: Raw<matrix_sdk::ruma::events::AnySyncTimelineEvent>,
}

impl IncomingResponse for RedactedEvent {
    type EndpointError = matrix_sdk::ruma::api::error::Error;

    fn try_from_http_response_inner(
        response: http::Response<&[u8]>,
    ) -> Result<Self, DeserializationError> {
        let event = serde_json::from_slice::<Raw<matrix_sdk::ruma::events::AnySyncTimelineEvent>>(
            response.body(),
        )?;
        Ok(Self { event })
    }
}

#[cfg(test)]
mod tests {
    use std::borrow::Cow;
    use std::collections::BTreeSet;

    use matrix_sdk::ruma::api::{
        MatrixVersion as Version, OutgoingRequestExt, SupportedVersions,
        auth_scheme::SendAccessToken,
    };
    use matrix_sdk::ruma::events::room::power_levels::{
        RoomPowerLevelsEventContent, UserPowerLevel,
    };
    use matrix_sdk::ruma::room_version_rules::AuthorizationRules;
    use matrix_sdk::ruma::{Int, OwnedUserId, owned_event_id, owned_room_id, owned_user_id};
    use serde_json::json;

    use super::*;

    fn versions(values: &[Version]) -> Cow<'_, SupportedVersions> {
        Cow::Owned(SupportedVersions {
            versions: values.iter().copied().collect(),
            features: BTreeSet::new(),
        })
    }

    fn request() -> ReadRedactedEvent {
        ReadRedactedEvent {
            room_id: owned_room_id!("!room:example.org"),
            event_id: owned_event_id!("$event"),
        }
    }

    #[test]
    fn the_unredacted_read_carries_the_msc2815_parameter() {
        let http_request: http::Request<Vec<u8>> = request()
            .try_into_http_request(
                "https://homeserver.example",
                SendAccessToken::IfRequired("token"),
                versions(&[Version::V1_11]),
            )
            .expect("the request is expressible");

        assert_eq!(http_request.method(), &Method::GET);
        assert_eq!(
            http_request.uri().path(),
            "/_matrix/client/v3/rooms/!room:example.org/event/$event"
        );
        assert_eq!(
            http_request.uri().query(),
            Some("fi.mau.msc2815.include_unredacted_content=true"),
            "the endpoint is switched on by a query parameter, not a header"
        );
        assert_eq!(
            http_request.headers().get("Authorization").unwrap(),
            "Bearer token"
        );
    }

    #[test]
    fn an_old_homeserver_still_gets_the_r0_path_with_the_parameter() {
        let http_request: http::Request<Vec<u8>> = request()
            .try_into_http_request(
                "https://homeserver.example",
                SendAccessToken::IfRequired("token"),
                versions(&[Version::V1_0]),
            )
            .expect("the request is expressible");

        assert_eq!(
            http_request.uri().path(),
            "/_matrix/client/r0/rooms/!room:example.org/event/$event"
        );
        assert_eq!(
            http_request.uri().query(),
            Some("fi.mau.msc2815.include_unredacted_content=true")
        );
    }

    #[test]
    fn the_path_variables_cannot_smuggle_a_segment() {
        let http_request: http::Request<Vec<u8>> = ReadRedactedEvent {
            room_id: owned_room_id!("!room:example.org"),
            event_id: owned_event_id!("$a/b?c#d"),
        }
        .try_into_http_request(
            "https://homeserver.example",
            SendAccessToken::IfRequired("token"),
            versions(&[Version::V1_11]),
        )
        .expect("the request is expressible");

        let path = http_request.uri().path();
        assert_eq!(
            path.matches('/').count(),
            7,
            "the event id must stay one segment: {path}"
        );
        assert!(
            http_request
                .uri()
                .query()
                .is_some_and(|query| query.ends_with("=true") && query.contains('=')),
            "the smuggled '?' must not have become the query string"
        );
    }

    fn power_levels(users: &[(&str, u32)], redact: u32) -> RoomPowerLevels {
        let mut content = RoomPowerLevelsEventContent::new(&AuthorizationRules::V1);
        content.redact = Int::from(redact);
        for (user, level) in users {
            content
                .users
                .insert(OwnedUserId::try_from(*user).unwrap(), Int::from(*level));
        }
        RoomPowerLevels::new(
            content.into(),
            &matrix_sdk::ruma::room_version_rules::AuthorizationRules::V1,
            [],
        )
    }

    #[test]
    fn only_the_redact_level_may_read_unredacted_content() {
        let levels = power_levels(&[("@mod:example.org", 50), ("@plain:example.org", 0)], 50);

        assert!(may_view_redacted(
            &levels,
            &owned_user_id!("@mod:example.org")
        ));
        assert!(!may_view_redacted(
            &levels,
            &owned_user_id!("@plain:example.org")
        ));
    }

    #[test]
    fn the_default_redact_level_of_fifty_is_enough() {
        // A room with no `m.room.power_levels` gets the spec defaults, and 50
        // is well above the 0 a plain member has.
        let levels = power_levels(&[("@plain:example.org", 0)], 50);

        assert_eq!(levels.redact, UserPowerLevel::Int(Int::from(50u32)));
        assert!(!may_view_redacted(
            &levels,
            &owned_user_id!("@plain:example.org")
        ));
        assert!(may_view_redacted(
            &power_levels(&[("@mod:example.org", 50)], 50),
            &owned_user_id!("@mod:example.org")
        ));
    }

    #[test]
    fn only_an_outage_is_worth_retrying() {
        for error in [
            RedactedContentError::NotPermitted,
            RedactedContentError::ContentDeleted,
            RedactedContentError::EventNotFound,
            RedactedContentError::Unsupported,
        ] {
            assert!(error.is_terminal(), "{error:?}");
        }
        assert!(!RedactedContentError::Unavailable.is_terminal());
    }

    /// Sends a request against a mock homeserver that answers with `status` and
    /// `body`, and classifies the resulting SDK error.
    async fn classify_against(
        status: u16,
        errcode: &str,
        advertised: bool,
    ) -> RedactedContentError {
        use matrix_sdk::test_utils::client::MockClientBuilder;
        use matrix_sdk::test_utils::mocks::MatrixMockServer;
        use wiremock::matchers::method;
        use wiremock::{Mock, ResponseTemplate};

        let server = MatrixMockServer::new().await;
        Mock::given(method("GET"))
            .and(wiremock::matchers::path(
                "/_matrix/client/v3/rooms/!room:example.org/event/$event",
            ))
            .respond_with(
                ResponseTemplate::new(status)
                    .set_body_json(json!({ "errcode": errcode, "error": "refused" })),
            )
            .mount(server.server())
            .await;
        Mock::given(method("GET"))
            .and(wiremock::matchers::path("/_matrix/client/versions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "versions": ["v1.11"],
                "unstable_features": if advertised { json!({ "fi.mau.msc2815": true }) } else { json!({}) },
            })))
            .mount(server.server())
            .await;

        let client = MockClientBuilder::new(Some(&server.uri()))
            .logged_in_with_token(
                "token".to_owned(),
                owned_user_id!("@mod:example.org"),
                matrix_sdk::ruma::owned_device_id!("DEVICE"),
            )
            .build()
            .await;

        let error = client
            .send(request())
            .await
            .expect_err("the mock refuses every request");
        classify(&error, advertised)
    }

    #[tokio::test]
    async fn a_403_from_a_supporting_server_is_a_refusal() {
        assert_eq!(
            classify_against(403, "M_FORBIDDEN", true).await,
            RedactedContentError::NotPermitted
        );
    }

    #[tokio::test]
    async fn a_403_from_a_server_that_advertises_nothing_is_unsupported() {
        // Synapse answers 403 for the unknown parameter when the flag is off.
        assert_eq!(
            classify_against(403, "M_FORBIDDEN", false).await,
            RedactedContentError::Unsupported
        );
    }

    #[tokio::test]
    async fn a_404_reads_the_retention_code_when_it_is_there() {
        assert_eq!(
            classify_against(404, "M_NOT_FOUND", true).await,
            RedactedContentError::EventNotFound
        );
        assert_eq!(
            classify_against(404, CONTENT_DELETED, true).await,
            RedactedContentError::ContentDeleted
        );
    }

    #[tokio::test]
    async fn an_unimplemented_path_is_unsupported() {
        for status in [400u16, 405, 501] {
            assert_eq!(
                classify_against(status, "M_UNRECOGNIZED", false).await,
                RedactedContentError::Unsupported,
                "status {status}"
            );
        }
    }

    #[tokio::test]
    async fn a_server_fault_is_the_only_retryable_answer() {
        assert_eq!(
            classify_against(502, "M_UNKNOWN", true).await,
            RedactedContentError::Unavailable
        );
        assert_eq!(
            classify_against(429, "M_LIMIT_EXCEEDED", true).await,
            RedactedContentError::Unavailable
        );
    }

    #[test]
    fn every_error_names_itself_for_the_wire() {
        let codes = [
            RedactedContentError::NotPermitted,
            RedactedContentError::ContentDeleted,
            RedactedContentError::EventNotFound,
            RedactedContentError::Unsupported,
            RedactedContentError::Unavailable,
        ]
        .map(RedactedContentError::code);

        let unique: std::collections::BTreeSet<_> = codes.iter().collect();
        assert_eq!(unique.len(), codes.len(), "codes must be distinguishable");
        assert!(codes.iter().all(|code| !code.is_empty()));
    }
}
