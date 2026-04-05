use crate::attention::SessionAttentionState;
use crate::pty::session::ToolState;
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    #[serde(rename = "input")]
    Input { data: String },
    #[serde(rename = "resize")]
    Resize { cols: u16, rows: u16 },
    #[serde(rename = "pause")]
    Pause,
    #[serde(rename = "resume")]
    Resume,
    #[serde(rename = "ping")]
    Ping,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum ServerMessage {
    #[serde(rename = "output")]
    Output { data: String },
    #[serde(rename = "scrollback")]
    Scrollback { data: String },
    #[serde(rename = "session_event")]
    SessionEvent {
        event: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
    },
    #[serde(rename = "pong")]
    Pong,
    #[serde(rename = "foreground_changed")]
    ForegroundChanged {
        process: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool_state: Option<ToolState>,
        #[serde(flatten)]
        attention: SessionAttentionState,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- ClientMessage deserialization ---

    #[test]
    fn deserialize_client_input() {
        let json = r#"{"type":"input","data":"hello"}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        match msg {
            ClientMessage::Input { data } => assert_eq!(data, "hello"),
            _ => panic!("expected Input"),
        }
    }

    #[test]
    fn deserialize_client_resize() {
        let json = r#"{"type":"resize","cols":120,"rows":40}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        match msg {
            ClientMessage::Resize { cols, rows } => {
                assert_eq!(cols, 120);
                assert_eq!(rows, 40);
            }
            _ => panic!("expected Resize"),
        }
    }

    #[test]
    fn deserialize_client_pause() {
        let json = r#"{"type":"pause"}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        assert!(matches!(msg, ClientMessage::Pause));
    }

    #[test]
    fn deserialize_client_resume() {
        let json = r#"{"type":"resume"}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        assert!(matches!(msg, ClientMessage::Resume));
    }

    #[test]
    fn deserialize_client_ping() {
        let json = r#"{"type":"ping"}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        assert!(matches!(msg, ClientMessage::Ping));
    }

    // --- ServerMessage serialization ---

    #[test]
    fn serialize_server_output() {
        let msg = ServerMessage::Output {
            data: "world".to_string(),
        };
        let json: serde_json::Value = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["type"], "output");
        assert_eq!(json["data"], "world");
    }

    #[test]
    fn serialize_server_scrollback() {
        let msg = ServerMessage::Scrollback {
            data: "history".to_string(),
        };
        let json: serde_json::Value = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["type"], "scrollback");
        assert_eq!(json["data"], "history");
    }

    #[test]
    fn serialize_server_session_event_with_exit_code() {
        let msg = ServerMessage::SessionEvent {
            event: "exited".to_string(),
            exit_code: Some(0),
        };
        let json: serde_json::Value = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["type"], "session_event");
        assert_eq!(json["event"], "exited");
        assert_eq!(json["exit_code"], 0);
    }

    #[test]
    fn serialize_server_session_event_without_exit_code() {
        let msg = ServerMessage::SessionEvent {
            event: "started".to_string(),
            exit_code: None,
        };
        let json: serde_json::Value = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["type"], "session_event");
        assert_eq!(json["event"], "started");
        // exit_code should be omitted entirely when None
        assert!(json.get("exit_code").is_none());
    }

    #[test]
    fn serialize_server_pong() {
        let msg = ServerMessage::Pong;
        let json: serde_json::Value = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["type"], "pong");
    }

    // --- Tag value verification ---

    #[test]
    fn type_tags_are_correct() {
        // Client messages
        let input: ClientMessage = serde_json::from_str(r#"{"type":"input","data":""}"#).unwrap();
        assert!(matches!(input, ClientMessage::Input { .. }));

        let resize: ClientMessage =
            serde_json::from_str(r#"{"type":"resize","cols":1,"rows":1}"#).unwrap();
        assert!(matches!(resize, ClientMessage::Resize { .. }));

        let pause: ClientMessage = serde_json::from_str(r#"{"type":"pause"}"#).unwrap();
        assert!(matches!(pause, ClientMessage::Pause));

        let resume: ClientMessage = serde_json::from_str(r#"{"type":"resume"}"#).unwrap();
        assert!(matches!(resume, ClientMessage::Resume));

        let ping: ClientMessage = serde_json::from_str(r#"{"type":"ping"}"#).unwrap();
        assert!(matches!(ping, ClientMessage::Ping));

        // Server messages
        let output = serde_json::to_value(ServerMessage::Output {
            data: String::new(),
        })
        .unwrap();
        assert_eq!(output["type"], "output");

        let scrollback = serde_json::to_value(ServerMessage::Scrollback {
            data: String::new(),
        })
        .unwrap();
        assert_eq!(scrollback["type"], "scrollback");

        let session_event = serde_json::to_value(ServerMessage::SessionEvent {
            event: String::new(),
            exit_code: None,
        })
        .unwrap();
        assert_eq!(session_event["type"], "session_event");

        let pong = serde_json::to_value(ServerMessage::Pong).unwrap();
        assert_eq!(pong["type"], "pong");
    }
}
