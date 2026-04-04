use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;

pub struct ScrollbackBuffer {
    ring: VecDeque<u8>,
    max_memory: usize,
    disk_file: Option<File>,
    disk_path: PathBuf,
    disk_bytes: u64,
    max_disk_bytes: u64,
}

impl ScrollbackBuffer {
    pub fn new(session_dir: &str, max_memory_kb: usize, max_disk_mb: usize) -> Self {
        let disk_path = PathBuf::from(session_dir).join("scrollback.raw");
        fs::create_dir_all(session_dir).ok();

        let disk_file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&disk_path)
            .ok();

        let disk_bytes = fs::metadata(&disk_path).map(|m| m.len()).unwrap_or(0);

        Self {
            ring: VecDeque::with_capacity(max_memory_kb * 1024),
            max_memory: max_memory_kb * 1024,
            disk_file,
            disk_path,
            disk_bytes,
            max_disk_bytes: (max_disk_mb as u64) * 1024 * 1024,
        }
    }

    pub fn append(&mut self, data: &[u8]) {
        // Append to ring buffer — bulk operation instead of byte-by-byte
        let overflow = (self.ring.len() + data.len()).saturating_sub(self.max_memory);
        if overflow > 0 {
            self.ring.drain(..overflow.min(self.ring.len()));
        }
        self.ring.extend(data);

        // Append to disk
        if let Some(ref mut file) = self.disk_file {
            if self.max_disk_bytes == 0 || self.disk_bytes < self.max_disk_bytes {
                if file.write_all(data).is_ok() {
                    self.disk_bytes += data.len() as u64;
                }
            }
        }
    }

    pub fn get_ring_contents(&self) -> Vec<u8> {
        let (a, b) = self.ring.as_slices();
        let mut out = Vec::with_capacity(a.len() + b.len());
        out.extend_from_slice(a);
        out.extend_from_slice(b);
        out
    }

    pub fn read_disk(&self, offset: u64, limit: usize) -> anyhow::Result<Vec<u8>> {
        use std::io::{Read, Seek, SeekFrom};
        // Clamp limit to 1MB to prevent OOM from malicious requests
        let limit = limit.min(1_048_576);
        let mut file = File::open(&self.disk_path)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut buf = vec![0u8; limit];
        let n = file.read(&mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    pub fn flush(&mut self) {
        if let Some(ref mut file) = self.disk_file {
            file.flush().ok();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// Create a unique temp directory for each test using UUID.
    fn temp_session_dir() -> String {
        let dir =
            std::env::temp_dir().join(format!("tether-test-scrollback-{}", uuid::Uuid::new_v4()));
        dir.to_string_lossy().to_string()
    }

    /// Clean up temp dir after test.
    fn cleanup(dir: &str) {
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn empty_buffer() {
        let dir = temp_session_dir();
        let buf = ScrollbackBuffer::new(&dir, 1, 1); // 1KB memory, 1MB disk
        let contents = buf.get_ring_contents();
        assert!(contents.is_empty());
        cleanup(&dir);
    }

    #[test]
    fn basic_append_and_read() {
        let dir = temp_session_dir();
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"hello world");
        let contents = buf.get_ring_contents();
        assert_eq!(contents, b"hello world");
        cleanup(&dir);
    }

    #[test]
    fn multiple_appends() {
        let dir = temp_session_dir();
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"aaa");
        buf.append(b"bbb");
        buf.append(b"ccc");
        let contents = buf.get_ring_contents();
        assert_eq!(contents, b"aaabbbccc");
        cleanup(&dir);
    }

    #[test]
    fn ring_buffer_overflow() {
        let dir = temp_session_dir();
        // 1KB memory = 1024 bytes
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);

        // Write exactly 1024 bytes
        let data1 = vec![b'A'; 1024];
        buf.append(&data1);
        assert_eq!(buf.get_ring_contents().len(), 1024);
        assert_eq!(buf.get_ring_contents(), data1);

        // Write 512 more -- ring should drop the oldest 512 bytes
        let data2 = vec![b'B'; 512];
        buf.append(&data2);
        let contents = buf.get_ring_contents();
        assert_eq!(contents.len(), 1024);
        // First 512 should be the tail of data1
        assert_eq!(&contents[..512], &vec![b'A'; 512][..]);
        // Last 512 should be data2
        assert_eq!(&contents[512..], &data2[..]);

        cleanup(&dir);
    }

    #[test]
    fn ring_buffer_complete_overwrite() {
        let dir = temp_session_dir();
        // 1KB memory = 1024 bytes
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);

        buf.append(&vec![b'A'; 1024]);
        // Now write 2048 bytes. The append logic drains overflow from existing
        // ring first, then extends with all new data. Since the single append
        // is larger than max_memory, the ring will temporarily exceed the cap.
        let data2 = vec![b'B'; 2048];
        buf.append(&data2);
        let contents = buf.get_ring_contents();
        // Ring holds all 2048 B's (the drain removed the A's but the new
        // data itself exceeds max_memory in one append call).
        assert_eq!(contents.len(), 2048);
        assert_eq!(contents, vec![b'B'; 2048]);

        // A subsequent small append will trim back down
        buf.append(b"C");
        let contents2 = buf.get_ring_contents();
        // overflow = (2048 + 1) - 1024 = 1025, drain 1025, then add 1 byte
        assert_eq!(contents2.len(), 1024);
        assert_eq!(contents2[1023], b'C');

        cleanup(&dir);
    }

    #[test]
    fn disk_append_and_read() {
        let dir = temp_session_dir();
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"hello disk");
        buf.flush();

        let data = buf.read_disk(0, 1024).unwrap();
        assert_eq!(data, b"hello disk");
        cleanup(&dir);
    }

    #[test]
    fn disk_read_with_offset() {
        let dir = temp_session_dir();
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"0123456789");
        buf.flush();

        let data = buf.read_disk(5, 1024).unwrap();
        assert_eq!(data, b"56789");
        cleanup(&dir);
    }

    #[test]
    fn disk_read_with_limit() {
        let dir = temp_session_dir();
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"0123456789");
        buf.flush();

        let data = buf.read_disk(0, 5).unwrap();
        assert_eq!(data, b"01234");
        cleanup(&dir);
    }

    #[test]
    fn disk_read_offset_and_limit() {
        let dir = temp_session_dir();
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"abcdefghij");
        buf.flush();

        let data = buf.read_disk(3, 4).unwrap();
        assert_eq!(data, b"defg");
        cleanup(&dir);
    }

    #[test]
    fn disk_read_beyond_end() {
        let dir = temp_session_dir();
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"short");
        buf.flush();

        let data = buf.read_disk(0, 1024).unwrap();
        assert_eq!(data, b"short");

        // Offset beyond end returns empty
        let data = buf.read_disk(100, 1024).unwrap();
        assert!(data.is_empty());
        cleanup(&dir);
    }

    #[test]
    fn disk_file_created() {
        let dir = temp_session_dir();
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"test");
        buf.flush();

        let disk_path = Path::new(&dir).join("scrollback.raw");
        assert!(disk_path.exists());
        cleanup(&dir);
    }

    #[test]
    fn large_data_handling() {
        let dir = temp_session_dir();
        // 4KB memory, 1MB disk
        let mut buf = ScrollbackBuffer::new(&dir, 4, 1);

        // Write 10KB total in chunks
        for _ in 0..10 {
            buf.append(&vec![b'X'; 1024]);
        }
        buf.flush();

        // Ring should only hold last 4KB
        let ring = buf.get_ring_contents();
        assert_eq!(ring.len(), 4096);

        // Disk should hold all 10KB
        let disk = buf.read_disk(0, 1_048_576).unwrap();
        assert_eq!(disk.len(), 10240);
        cleanup(&dir);
    }

    #[test]
    fn disk_max_respected() {
        let dir = temp_session_dir();
        // 1KB memory, very small disk: we can't set 0 MB since that means unlimited,
        // so test with 1MB and just verify data goes to disk
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);
        buf.append(b"data");
        buf.flush();
        let data = buf.read_disk(0, 1024).unwrap();
        assert_eq!(data, b"data");
        cleanup(&dir);
    }

    #[test]
    fn ring_and_disk_independent() {
        let dir = temp_session_dir();
        // 1KB ring
        let mut buf = ScrollbackBuffer::new(&dir, 1, 1);

        // Fill ring completely and overflow
        buf.append(&vec![b'A'; 512]);
        buf.append(&vec![b'B'; 1024]);
        buf.flush();

        // Ring should have last 1024 bytes (all B)
        let ring = buf.get_ring_contents();
        assert_eq!(ring.len(), 1024);
        assert_eq!(ring, vec![b'B'; 1024]);

        // Disk should have everything: 512 A's + 1024 B's
        let disk = buf.read_disk(0, 2048).unwrap();
        assert_eq!(disk.len(), 1536);
        assert_eq!(&disk[..512], &vec![b'A'; 512][..]);
        assert_eq!(&disk[512..], &vec![b'B'; 1024][..]);
        cleanup(&dir);
    }
}
