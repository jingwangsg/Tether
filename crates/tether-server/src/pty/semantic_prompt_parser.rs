const MAX_PAYLOAD_LEN: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SemanticPromptKind {
    FreshLineNewPrompt,
    PromptStart,
    EndPromptStartInput,
    EndPromptStartInputTerminateEol,
    EndInputStartOutput,
    EndCommand { exit_code: Option<i32> },
    FreshLine,
    NewCommand,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Normal,
    EscapeSeen,
    ParamAccum,
    PayloadAccum,
    StPending,
}

pub struct SemanticPromptParser {
    state: State,
    param: Vec<u8>,
    payload: Vec<u8>,
}

impl SemanticPromptParser {
    pub fn new() -> Self {
        Self {
            state: State::Normal,
            param: Vec::with_capacity(8),
            payload: Vec::with_capacity(32),
        }
    }

    pub fn feed(&mut self, data: &[u8]) -> Vec<SemanticPromptKind> {
        let mut events = Vec::new();
        for &b in data {
            match self.state {
                State::Normal => {
                    if b == 0x1b {
                        self.state = State::EscapeSeen;
                    }
                }
                State::EscapeSeen => {
                    if b == b']' {
                        self.param.clear();
                        self.payload.clear();
                        self.state = State::ParamAccum;
                    } else {
                        self.state = State::Normal;
                    }
                }
                State::ParamAccum => {
                    if b == b';' {
                        if self.param.as_slice() == b"133" {
                            self.state = State::PayloadAccum;
                        } else {
                            self.state = State::Normal;
                        }
                    } else if b.is_ascii_digit() && self.param.len() < 8 {
                        self.param.push(b);
                    } else {
                        self.state = State::Normal;
                    }
                }
                State::PayloadAccum => {
                    if b == 0x07 {
                        if let Some(event) = parse_payload(&self.payload) {
                            events.push(event);
                        }
                        self.payload.clear();
                        self.state = State::Normal;
                    } else if b == 0x1b {
                        self.state = State::StPending;
                    } else if self.payload.len() < MAX_PAYLOAD_LEN {
                        self.payload.push(b);
                    }
                }
                State::StPending => {
                    if b == b'\\' {
                        if let Some(event) = parse_payload(&self.payload) {
                            events.push(event);
                        }
                        self.payload.clear();
                        self.state = State::Normal;
                    } else {
                        self.payload.clear();
                        if b == b']' {
                            self.param.clear();
                            self.state = State::ParamAccum;
                        } else {
                            self.state = State::Normal;
                        }
                    }
                }
            }
        }
        events
    }
}

fn parse_payload(payload: &[u8]) -> Option<SemanticPromptKind> {
    let action = *payload.first()?;
    match action {
        b'A' => Some(SemanticPromptKind::FreshLineNewPrompt),
        b'B' => Some(SemanticPromptKind::EndPromptStartInput),
        b'C' => Some(SemanticPromptKind::EndInputStartOutput),
        b'D' => {
            // D may carry an exit code: "D;0", "D;1", or just "D"
            let exit_code = if payload.len() > 2 && payload[1] == b';' {
                std::str::from_utf8(&payload[2..])
                    .ok()
                    .and_then(|s| s.parse::<i32>().ok())
            } else {
                None
            };
            Some(SemanticPromptKind::EndCommand { exit_code })
        }
        b'I' => Some(SemanticPromptKind::EndPromptStartInputTerminateEol),
        b'L' if payload.len() == 1 => Some(SemanticPromptKind::FreshLine),
        b'N' => Some(SemanticPromptKind::NewCommand),
        b'P' => Some(SemanticPromptKind::PromptStart),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bel_terminated_sequences() {
        let mut parser = SemanticPromptParser::new();
        let events = parser.feed(b"\x1b]133;A;cl=line\x07\x1b]133;C\x07");
        assert_eq!(
            events,
            vec![
                SemanticPromptKind::FreshLineNewPrompt,
                SemanticPromptKind::EndInputStartOutput,
            ]
        );
    }

    #[test]
    fn parses_st_terminated_sequence_across_chunks() {
        let mut parser = SemanticPromptParser::new();
        assert!(parser.feed(b"\x1b]133;D;0\x1b").is_empty());
        let events = parser.feed(b"\\");
        assert_eq!(
            events,
            vec![SemanticPromptKind::EndCommand {
                exit_code: Some(0)
            }]
        );
    }

    #[test]
    fn parses_d_without_exit_code() {
        let mut parser = SemanticPromptParser::new();
        let events = parser.feed(b"\x1b]133;D\x07");
        assert_eq!(
            events,
            vec![SemanticPromptKind::EndCommand { exit_code: None }]
        );
    }

    #[test]
    fn parses_d_with_nonzero_exit_code() {
        let mut parser = SemanticPromptParser::new();
        let events = parser.feed(b"\x1b]133;D;127\x07");
        assert_eq!(
            events,
            vec![SemanticPromptKind::EndCommand {
                exit_code: Some(127)
            }]
        );
    }

    #[test]
    fn ignores_other_osc_params() {
        let mut parser = SemanticPromptParser::new();
        let events = parser.feed(b"\x1b]0;title\x07\x1b]7;file:///tmp\x07");
        assert!(events.is_empty());
    }
}
