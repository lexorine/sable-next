//! MSC2815: room moderators read the original content of redacted events.

use std::sync::Arc;

use http::Method;
use matrix_sdk::ruma::{
    OwnedEventId, OwnedRoomId, UserId,
    api::{
        EmptyBody, IncomingResponse, MatrixVersion, Metadata, OutgoingRequest, auth_scheme,
        error::{DeserializationError, IntoHttpError},
        path_builder::{PathBuilder, StablePathSelector, VersionHistory},
    },
    events::{AnySyncTimelineEvent, room::power_levels::RoomPowerLevels},
    serde::Raw,
};
use serde::{Deserialize, Serialize};

use crate::Core;
use crate::api::Handler;
use crate::protocol::{PerMessageProfileView, RpcError, TimelineItemContentView};

const UNSTABLE_FEATURE: &str = "fi.mau.msc2815";
const QUERY_PARAMETER: &str = "fi.mau.msc2815.include_unredacted_content";

/// `content` is null when the server returned the event still redacted.
#[derive(Debug, Clone, Default, Serialize)]
#[cfg_attr(feature = "typegen", derive(specta::Type))]
pub struct RedactedContentView {
    pub content: Option<TimelineItemContentView>,
    pub per_message_profile: Option<PerMessageProfileView>,
}

#[derive(Debug, Deserialize)]
#[cfg_attr(feature = "typegen", derive(specta::Type), specta(inline))]
pub struct RedactedContentParams {
    #[cfg_attr(feature = "typegen", specta(type = String))]
    pub room_id: OwnedRoomId,
    #[cfg_attr(feature = "typegen", specta(type = String))]
    pub event_id: OwnedEventId,
}

impl Handler for RedactedContentParams {
    type Ok = RedactedContentView;

    async fn run(self, core: &Arc<Core>) -> Result<RedactedContentView, RpcError> {
        let room = core.room(&self.room_id).await?;
        let client = room.client();
        let user_id = client.user_id().ok_or(RpcError::NotLoggedIn)?.to_owned();
        if !may_view_redacted(&room.power_levels_or_default().await, &user_id) {
            return Err(RpcError::Denied);
        }

        let advertised = client
            .unstable_features()
            .await
            .is_ok_and(|features| features.contains(&UNSTABLE_FEATURE.into()));
        let request = ReadUnredacted {
            room_id: self.room_id,
            event_id: self.event_id,
        };
        match client.send(request).await {
            Ok(response) => Ok(crate::view::redacted_content_view(&room, response.0)
                .await
                .unwrap_or_default()),
            Err(error) => failure(&error, advertised),
        }
    }
}

#[must_use]
pub fn may_view_redacted(power_levels: &RoomPowerLevels, user_id: &UserId) -> bool {
    power_levels.for_user(user_id) >= power_levels.redact
}

/// A server without the feature also answers 403/404, so those only mean "refused"/"gone" when it advertises MSC2815.
fn failure(error: &matrix_sdk::HttpError, advertised: bool) -> Result<RedactedContentView, RpcError> {
    let status = error
        .as_client_api_error()
        .map_or(0, |api_error| api_error.status_code.as_u16());
    match (status, advertised) {
        (403, true) => Err(RpcError::Denied),
        (404, true) => Ok(RedactedContentView::default()),
        (400 | 403 | 404 | 405 | 501, _) => Err(RpcError::Unsupported),
        _ => Err(RpcError::Unavailable),
    }
}

/// `GET /rooms/{roomId}/event/{eventId}` with the MSC2815 query parameter, which Ruma cannot express.
#[derive(Clone, Debug)]
struct ReadUnredacted {
    room_id: OwnedRoomId,
    event_id: OwnedEventId,
}

impl Metadata for ReadUnredacted {
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

impl OutgoingRequest for ReadUnredacted {
    type Body = EmptyBody;
    type EndpointError = matrix_sdk::ruma::api::error::Error;
    type IncomingResponse = UnredactedEvent;

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

#[derive(Debug)]
struct UnredactedEvent(Raw<AnySyncTimelineEvent>);

impl IncomingResponse for UnredactedEvent {
    type EndpointError = matrix_sdk::ruma::api::error::Error;

    fn try_from_http_response_inner(
        response: http::Response<&[u8]>,
    ) -> Result<Self, DeserializationError> {
        Ok(Self(serde_json::from_slice(response.body())?))
    }
}

#[cfg(test)]
#[expect(clippy::expect_used, reason = "test code")]
mod tests {
    use std::borrow::Cow;
    use std::collections::BTreeSet;

    use matrix_sdk::ruma::api::{OutgoingRequestExt, SupportedVersions, auth_scheme::SendAccessToken};
    use matrix_sdk::ruma::{owned_event_id, owned_room_id};

    use super::*;

    fn request(event_id: OwnedEventId, version: MatrixVersion) -> http::Request<Vec<u8>> {
        ReadUnredacted {
            room_id: owned_room_id!("!room:example.org"),
            event_id,
        }
        .try_into_http_request(
            "https://homeserver.example",
            SendAccessToken::IfRequired("token"),
            Cow::Owned(SupportedVersions {
                versions: BTreeSet::from([version]),
                features: BTreeSet::new(),
            }),
        )
        .expect("the request is expressible")
    }

    #[test]
    fn the_read_carries_the_query_parameter() {
        let request = request(owned_event_id!("$event"), MatrixVersion::V1_11);
        assert_eq!(request.method(), Method::GET);
        assert_eq!(
            request.uri().path(),
            "/_matrix/client/v3/rooms/!room:example.org/event/$event"
        );
        assert_eq!(
            request.uri().query(),
            Some("fi.mau.msc2815.include_unredacted_content=true")
        );
        assert_eq!(
            request.headers().get("Authorization").map(|value| value.as_bytes()),
            Some(&b"Bearer token"[..])
        );
    }

    #[test]
    fn an_old_homeserver_gets_the_r0_path() {
        let request = request(owned_event_id!("$event"), MatrixVersion::V1_0);
        assert_eq!(
            request.uri().path(),
            "/_matrix/client/r0/rooms/!room:example.org/event/$event"
        );
    }

    #[test]
    fn the_event_id_stays_one_path_segment() {
        let request = request(owned_event_id!("$a/b?c#d"), MatrixVersion::V1_11);
        assert_eq!(request.uri().path().matches('/').count(), 7);
        assert_eq!(
            request.uri().query(),
            Some("fi.mau.msc2815.include_unredacted_content=true")
        );
    }
}

#[cfg(all(test, not(target_family = "wasm")))]
#[expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "test code"
)]
mod sdk_tests {
    use std::sync::Arc;

    use matrix_sdk::ruma::{event_id, room_id, serde::Raw};
    use matrix_sdk::test_utils::mocks::MatrixMockServer;
    use matrix_sdk_test::{ALICE, JoinedRoomBuilder, event_factory::EventFactory};
    use matrix_sdk_ui::sync_service::SyncService;
    use serde_json::{Value, json};
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, ResponseTemplate};

    use super::{RedactedContentParams, RedactedContentView};
    use crate::Core;
    use crate::protocol::{RpcError, TimelineItemContentView};
    use crate::session::Session;
    use crate::store::MemorySessionStore;

    const ROOM: &str = "!msc2815:example.org";
    const EVENT: &str = "$redacted";

    struct Fixture {
        server: MatrixMockServer,
        core: Arc<Core>,
    }

    async fn fixture(power_level: u32, advertised: bool) -> Fixture {
        let server = MatrixMockServer::new().await;
        Mock::given(method("GET"))
            .and(path("/_matrix/client/versions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "versions": ["v1.11"],
                "unstable_features": { "fi.mau.msc2815": advertised },
            })))
            .mount(server.server())
            .await;
        let client = server.client_builder().build().await;
        // The mock client starts with cached versions that advertise nothing.
        client.reset_supported_versions().await.unwrap();

        let room_id = room_id!("!msc2815:example.org");
        let own = client.user_id().unwrap().to_owned();
        let factory = EventFactory::new().room(room_id).sender(&own);
        let levels = json!({
            "type": "m.room.power_levels", "state_key": "", "sender": own,
            "event_id": "$levels", "origin_server_ts": 1,
            "content": { "users": { own.as_str(): power_level } },
        });
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(room_id)
                    .add_state_bulk(vec![factory.member(&own).into_raw()])
                    .add_state_event(factory.create(&own, "10".try_into().unwrap()))
                    .add_state_event(Raw::new(&levels).unwrap().cast_unchecked()),
            )
            .await;
        server.mock_room_state_encryption().plain().mount().await;

        let sync_service = Arc::new(SyncService::builder(client.clone()).build().await.unwrap());
        let (core, _events) = Core::new("test", Box::new(MemorySessionStore::default()));
        *core.session.write().await = Some(Session {
            account_id: "test".to_owned(),
            client,
            sync_service,
            homeserver: server.server().uri(),
            oauth: false,
        });
        Fixture { server, core }
    }

    async fn answer(fixture: &Fixture, status: u16, body: Value) {
        Mock::given(method("GET"))
            .and(path(format!("/_matrix/client/v3/rooms/{ROOM}/event/{EVENT}")))
            .and(query_param("fi.mau.msc2815.include_unredacted_content", "true"))
            .respond_with(ResponseTemplate::new(status).set_body_json(body))
            .mount(fixture.server.server())
            .await;
    }

    async fn read(fixture: &Fixture) -> Result<RedactedContentView, RpcError> {
        fixture
            .core
            .run(RedactedContentParams {
                room_id: room_id!("!msc2815:example.org").to_owned(),
                event_id: event_id!("$redacted").to_owned(),
            })
            .await
    }

    fn event(content: Value, unsigned: Value) -> Value {
        json!({
            "type": "m.room.message",
            "event_id": EVENT,
            "sender": ALICE.to_string(),
            "origin_server_ts": 1,
            "room_id": ROOM,
            "content": content,
            "unsigned": unsigned,
        })
    }

    #[tokio::test]
    async fn a_moderator_reads_the_original_content() {
        let fixture = fixture(50, true).await;
        let original = json!({ "msgtype": "m.text", "body": "the secret" });
        answer(&fixture, 200, event(original, json!({}))).await;

        match read(&fixture).await.expect("a moderator may read it").content {
            Some(TimelineItemContentView::Message { body, .. }) => assert_eq!(body, "the secret"),
            other => panic!("expected the original message, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_user_below_the_redact_level_is_denied_locally() {
        let fixture = fixture(0, true).await;
        assert!(matches!(read(&fixture).await, Err(RpcError::Denied)));
    }

    #[tokio::test]
    async fn a_still_redacted_answer_is_empty() {
        let fixture = fixture(50, true).await;
        let unsigned = json!({ "redacted_because": { "content": { "reason": "spam" } } });
        answer(&fixture, 200, event(json!({}), unsigned)).await;

        assert!(read(&fixture).await.expect("the request succeeded").content.is_none());
    }

    #[tokio::test]
    async fn erased_content_is_empty_rather_than_an_error() {
        let fixture = fixture(50, true).await;
        let body = json!({ "errcode": "FI.MAU.MSC2815_UNREDACTED_CONTENT_DELETED", "error": "gone" });
        answer(&fixture, 404, body).await;

        assert!(read(&fixture).await.expect("nothing to show").content.is_none());
    }

    #[tokio::test]
    async fn server_answers_map_to_rpc_errors() {
        for (advertised, status, errcode, expected) in [
            (true, 403, "M_FORBIDDEN", RpcError::Denied),
            (false, 403, "M_FORBIDDEN", RpcError::Unsupported),
            (false, 404, "M_NOT_FOUND", RpcError::Unsupported),
            (false, 405, "M_UNRECOGNIZED", RpcError::Unsupported),
            (true, 502, "M_UNKNOWN", RpcError::Unavailable),
        ] {
            let fixture = fixture(50, advertised).await;
            answer(&fixture, status, json!({ "errcode": errcode, "error": "refused" })).await;
            assert_eq!(
                format!("{:?}", read(&fixture).await),
                format!("Err({expected:?})"),
                "{status} {errcode} advertised={advertised}"
            );
        }
    }
}
