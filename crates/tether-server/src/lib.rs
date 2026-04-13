pub mod api;
pub mod auth;
pub mod config;
pub mod persistence;
pub mod pty;
pub mod remote;
pub mod server;
pub mod ssh_config;
pub mod state;
#[cfg(test)]
pub mod test_support;
pub mod ws;

/// Lock a mutex, recovering from poison by logging and using `into_inner()`.
/// This prevents silent skipping (if let Ok) and panics (.unwrap()) on poison.
pub fn lock_or_recover<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| {
        tracing::warn!("mutex was poisoned, recovering inner value");
        poisoned.into_inner()
    })
}

#[cfg(test)]
mod lock_tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// Poisoning a mutex with .lock().unwrap() causes a panic; with if-let-Ok
    /// the lock is silently skipped; lock_or_recover recovers the inner value.
    #[test]
    fn lock_or_recover_handles_poisoned_mutex() {
        let mutex = Arc::new(Mutex::new(42i32));
        let mutex_clone = mutex.clone();

        // Poison the mutex by panicking while holding the lock
        let _ = std::thread::spawn(move || {
            let _guard = mutex_clone.lock().unwrap();
            panic!("intentional panic to poison mutex");
        })
        .join();

        // Verify the mutex is poisoned
        assert!(mutex.lock().is_err(), "mutex should be poisoned");

        // Old behavior: if let Ok(guard) = mutex.lock() silently skips
        let was_skipped = if let Ok(_guard) = mutex.lock() {
            false
        } else {
            true // silently skipped
        };
        assert!(was_skipped, "poisoned mutex is silently skipped by if-let-Ok");

        // Fixed behavior: lock_or_recover recovers the value
        let guard = lock_or_recover(&mutex);
        assert_eq!(*guard, 42, "lock_or_recover should recover the inner value");
    }
}
