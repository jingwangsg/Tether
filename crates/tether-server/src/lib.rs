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

        assert!(mutex.lock().is_err(), "mutex should be poisoned");

        // lock_or_recover recovers the inner value instead of panicking or skipping
        let guard = lock_or_recover(&mutex);
        assert_eq!(*guard, 42);
    }
}
