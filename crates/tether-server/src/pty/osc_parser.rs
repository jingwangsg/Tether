/// Stateful streaming parser that extracts window titles from OSC escape sequences.
///
/// Terminal applications set window titles via `\x1b]0;title\x07` (or `\x1b]2;title\x07`).
/// These sequences pass transparently through SSH, enabling detection of remote
/// foreground processes (e.g. Claude Code running on a remote machine).

const MAX_TITLE_LEN: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Normal,
    EscapeSeen,
    ParamAccum,
    TitleAccum,
    StPending, // saw \x1b while accumulating title, expecting '\\' for ST
}

pub struct OscParser {
    state: State,
    param: u8,
    buf: Vec<u8>,
}

impl OscParser {
    pub fn new() -> Self {
        Self {
            state: State::Normal,
            param: 0,
            buf: Vec::with_capacity(64),
        }
    }

    /// Feed a chunk of PTY output. Returns the last complete OSC title found
    /// in this chunk, or None if no title sequence was completed.
    pub fn feed(&mut self, data: &[u8]) -> Option<String> {
        let mut latest: Option<String> = None;
        for &b in data {
            match self.state {
                State::Normal => {
                    if b == 0x1b {
                        self.state = State::EscapeSeen;
                    }
                }
                State::EscapeSeen => {
                    if b == b']' {
                        self.state = State::ParamAccum;
                        self.param = 0;
                        self.buf.clear();
                    } else {
                        self.state = State::Normal;
                    }
                }
                State::ParamAccum => {
                    if b == b';' {
                        if self.param == 0 || self.param == 2 {
                            self.state = State::TitleAccum;
                        } else {
                            self.state = State::Normal;
                        }
                    } else if b.is_ascii_digit() {
                        self.param = self.param.saturating_mul(10).saturating_add(b - b'0');
                    } else {
                        self.state = State::Normal;
                    }
                }
                State::TitleAccum => {
                    if b == 0x07 {
                        // BEL terminator
                        latest = Some(String::from_utf8_lossy(&self.buf).into_owned());
                        self.buf.clear();
                        self.state = State::Normal;
                    } else if b == 0x1b {
                        // Potential ST terminator (\x1b\\)
                        self.state = State::StPending;
                    } else if self.buf.len() < MAX_TITLE_LEN {
                        self.buf.push(b);
                    }
                }
                State::StPending => {
                    if b == b'\\' {
                        // ST terminator complete
                        latest = Some(String::from_utf8_lossy(&self.buf).into_owned());
                        self.buf.clear();
                        self.state = State::Normal;
                    } else {
                        // Not ST — the \x1b starts a new escape sequence
                        self.buf.clear();
                        if b == b']' {
                            // New OSC sequence starting
                            self.state = State::ParamAccum;
                            self.param = 0;
                        } else {
                            self.state = State::Normal;
                        }
                    }
                }
            }
        }
        latest
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bel_terminator() {
        let mut p = OscParser::new();
        assert_eq!(
            p.feed(b"\x1b]0;Claude Code\x07"),
            Some("Claude Code".into())
        );
    }

    #[test]
    fn st_terminator() {
        let mut p = OscParser::new();
        assert_eq!(
            p.feed(b"\x1b]2;Claude Code\x1b\\"),
            Some("Claude Code".into())
        );
    }

    #[test]
    fn cross_buffer_split() {
        let mut p = OscParser::new();
        assert_eq!(p.feed(b"\x1b]0;clau"), None);
        assert_eq!(p.feed(b"de\x07"), Some("claude".into()));
    }

    #[test]
    fn irrelevant_param() {
        let mut p = OscParser::new();
        assert_eq!(p.feed(b"\x1b]1;something\x07"), None);
        // Ps=7 (CWD) should also be ignored
        assert_eq!(p.feed(b"\x1b]7;file:///tmp\x07"), None);
    }

    #[test]
    fn multiple_titles_last_wins() {
        let mut p = OscParser::new();
        let result = p.feed(b"\x1b]0;first\x07some output\x1b]0;second\x07");
        assert_eq!(result, Some("second".into()));
    }

    #[test]
    fn empty_title() {
        let mut p = OscParser::new();
        assert_eq!(p.feed(b"\x1b]0;\x07"), Some("".into()));
    }

    #[test]
    fn title_with_special_chars() {
        let mut p = OscParser::new();
        assert_eq!(
            p.feed("\\x1b]0;Claude Code (main) \u{1f680}\x07".as_bytes()),
            None, // The literal \\x1b is not ESC
        );
        // Real ESC byte:
        let mut input = vec![0x1b, b']', b'0', b';'];
        input.extend_from_slice("hello world (main)".as_bytes());
        input.push(0x07);
        assert_eq!(p.feed(&input), Some("hello world (main)".into()));
    }

    #[test]
    fn no_osc_in_normal_output() {
        let mut p = OscParser::new();
        assert_eq!(p.feed(b"\x1b[32mgreen text\x1b[0m normal text\r\n"), None);
    }

    #[test]
    fn truncation_at_max_len() {
        let mut p = OscParser::new();
        let mut input = vec![0x1b, b']', b'0', b';'];
        input.extend_from_slice(&[b'A'; MAX_TITLE_LEN + 50]);
        input.push(0x07);
        let result = p.feed(&input).unwrap();
        assert_eq!(result.len(), MAX_TITLE_LEN);
    }

    #[test]
    fn interleaved_with_normal_output() {
        let mut p = OscParser::new();
        let mut input = Vec::new();
        input.extend_from_slice(b"some terminal output\r\n");
        input.extend_from_slice(b"\x1b]0;codex\x07");
        input.extend_from_slice(b"more output\r\n");
        assert_eq!(p.feed(&input), Some("codex".into()));
    }

    #[test]
    fn split_at_esc_boundary() {
        // ESC at end of one chunk, ] at start of next
        let mut p = OscParser::new();
        assert_eq!(p.feed(b"output\x1b"), None);
        assert_eq!(p.feed(b"]0;Claude Code\x07"), Some("Claude Code".into()));
    }

    #[test]
    fn split_at_st_boundary() {
        // ESC of ST terminator at end of one chunk, backslash at start of next
        let mut p = OscParser::new();
        assert_eq!(p.feed(b"\x1b]2;codex\x1b"), None);
        assert_eq!(p.feed(b"\\more output"), Some("codex".into()));
    }

    #[test]
    fn consecutive_sequences() {
        // Parser state resets correctly between sequences
        let mut p = OscParser::new();
        assert_eq!(p.feed(b"\x1b]0;first\x07"), Some("first".into()));
        assert_eq!(p.feed(b"\x1b]0;second\x07"), Some("second".into()));
        assert_eq!(p.feed(b"no osc here"), None);
        assert_eq!(p.feed(b"\x1b]2;third\x1b\\"), Some("third".into()));
    }

    #[test]
    fn aborted_sequence_then_valid() {
        // Invalid byte in param resets, then a valid sequence follows
        let mut p = OscParser::new();
        // \x1b]X is invalid (X is not a digit or ;), resets to Normal
        // Then a valid sequence follows
        let result = p.feed(b"\x1b]X\x1b]0;recovered\x07");
        assert_eq!(result, Some("recovered".into()));
    }

    #[test]
    fn param_2_works() {
        let mut p = OscParser::new();
        assert_eq!(
            p.feed(b"\x1b]2;Window Title\x07"),
            Some("Window Title".into())
        );
    }

    #[test]
    fn ansi_csi_does_not_trigger() {
        // CSI sequences (\x1b[...) should not interfere with OSC detection
        let mut p = OscParser::new();
        assert_eq!(p.feed(b"\x1b[0;32mhello\x1b[0m"), None);
        // Parser should still work after CSI sequences
        assert_eq!(p.feed(b"\x1b]0;after csi\x07"), Some("after csi".into()));
    }
}
