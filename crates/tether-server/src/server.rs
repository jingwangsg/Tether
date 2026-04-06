use crate::api;
use crate::auth;
use crate::state::AppState;
use crate::ws;
use axum::middleware;
use axum::routing::{delete, get, patch, post};
use axum::Router;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::trace::TraceLayer;

pub async fn run(state: AppState, no_ssh_scan: bool) -> anyhow::Result<()> {
    if state
        .inner
        .db
        .migrate_legacy_shared_remote_model_if_needed()?
    {
        tracing::info!(
            "Cleared legacy SSH-backed local mirrors; remote-authoritative sync will rebuild them"
        );
    }

    // Local PTYs do not survive a local server restart. Remove their DB rows and
    // persisted scrollback so the client never tries to revive them.
    let deleted_local_session_ids = state.inner.db.delete_local_sessions()?;
    for session_id in deleted_local_session_ids {
        let session_dir = format!("{}/sessions/{}", state.inner.config.data_dir(), session_id);
        let _ = std::fs::remove_dir_all(&session_dir);
    }

    let addr = format!(
        "{}:{}",
        state.inner.config.server.bind, state.inner.config.server.port
    );

    // Protected API routes (auth middleware applied)
    let api_routes = Router::new()
        .route("/api/groups", get(api::groups::list_groups))
        .route("/api/groups", post(api::groups::create_group))
        .route("/api/groups/{id}", patch(api::groups::update_group))
        .route("/api/groups/{id}", delete(api::groups::delete_group))
        .route(
            "/api/groups/reorder",
            post(api::groups::batch_reorder_groups),
        )
        .route("/api/sessions", get(api::sessions::list_sessions))
        .route("/api/sessions", post(api::sessions::create_session))
        .route("/api/sessions/{id}", patch(api::sessions::update_session))
        .route("/api/sessions/{id}", delete(api::sessions::delete_session))
        .route(
            "/api/sessions/{id}/clipboard-image",
            post(api::sessions::upload_clipboard_image),
        )
        .route(
            "/api/sessions/{id}/scrollback",
            get(api::sessions::get_scrollback),
        )
        .route(
            "/api/sessions/reorder",
            post(api::sessions::batch_reorder_sessions),
        )
        .route("/api/completions", get(api::completions::complete_path))
        .route(
            "/api/completions/remote",
            get(api::completions::complete_remote_path),
        )
        .route("/api/ssh/hosts", get(api::ssh::list_ssh_hosts))
        .route("/api/remote/hosts", get(api::remote::list_remote_hosts))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth::auth_middleware,
        ));

    let app = Router::new()
        // Public: server info (needed for hub discovery)
        .route("/api/info", get(api::server_info::get_info))
        .merge(api_routes)
        // WebSocket (has its own auth check via query param)
        .route("/ws/session/{id}", get(ws::handler::ws_handler))
        .layer(
            CorsLayer::new()
                .allow_origin(AllowOrigin::predicate(|origin, _| {
                    // Accept only origins whose host is exactly "localhost" or "127.0.0.1"
                    // (with any port or none). Prefix matching is insufficient —
                    // "http://localhost.evil.com" would pass a starts_with check.
                    let s = origin.to_str().unwrap_or("");
                    let host_part = s.strip_prefix("http://").unwrap_or("");
                    let host = host_part.split(':').next().unwrap_or(host_part);
                    host == "localhost" || host == "127.0.0.1"
                }))
                .allow_methods(tower_http::cors::Any)
                .allow_headers(tower_http::cors::Any),
        )
        .layer(TraceLayer::new_for_http())
        .with_state(state.clone());

    tracing::info!("Tether server listening on {}", addr);

    // Start background process monitor
    let semantic_event_rx = state
        .inner
        .semantic_event_rx
        .lock()
        .unwrap()
        .take()
        .expect("semantic_event_rx already taken");
    tokio::spawn(crate::pty::process_monitor::run_process_monitor(
        state.clone(),
        semantic_event_rx,
    ));
    // Start remote SSH host scanner (disabled when running as a remote daemon)
    if !no_ssh_scan {
        // Subscribe before spawning scanner so no Ready events are missed.
        let mut ready_rx = state.inner.remote_manager.ready_tx.subscribe();
        let inner_for_sync = state.inner.clone();
        let state_for_sync = state.clone();
        tokio::spawn(async move {
            use tokio::sync::broadcast::error::RecvError;
            loop {
                match ready_rx.recv().await {
                    Ok((host_alias, tunnel_port)) => {
                        if let Err(e) = crate::remote::sync::sync_remote_host(
                            &inner_for_sync.db,
                            &host_alias,
                            tunnel_port,
                            &inner_for_sync.ssh_fg,
                            &inner_for_sync.ssh_live_sessions,
                            Some(&state_for_sync),
                        )
                        .await
                        {
                            tracing::warn!("remote sync: failed for {}: {}", host_alias, e);
                        }
                    }
                    Err(RecvError::Lagged(n)) => {
                        tracing::warn!("remote sync: lagged by {} Ready events, continuing", n);
                    }
                    Err(RecvError::Closed) => break,
                }
            }
        });

        let manager_for_sync = state.inner.remote_manager.clone();
        let inner_for_periodic_sync = state.inner.clone();
        let state_for_periodic_sync = state.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
            interval.tick().await;
            loop {
                interval.tick().await;
                for (host_alias, tunnel_port) in manager_for_sync.list_ready_hosts() {
                    if let Err(e) = crate::remote::sync::sync_remote_host(
                        &inner_for_periodic_sync.db,
                        &host_alias,
                        tunnel_port,
                        &inner_for_periodic_sync.ssh_fg,
                        &inner_for_periodic_sync.ssh_live_sessions,
                        Some(&state_for_periodic_sync),
                    )
                    .await
                    {
                        tracing::warn!(
                            "remote sync: periodic sync failed for {}: {}",
                            host_alias,
                            e
                        );
                    }
                }
            }
        });

        tokio::spawn(crate::remote::manager::run_scanner(
            state.inner.remote_manager.clone(),
        ));
    }

    let listener = tokio::net::TcpListener::bind(&addr).await?;

    // Graceful shutdown
    let shutdown_tx = state.inner.shutdown_tx.clone();
    let state_for_shutdown = state.clone();

    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            #[cfg(unix)]
            {
                let mut sigterm =
                    tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                        .unwrap();
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {}
                    _ = sigterm.recv() => {}
                }
            }
            #[cfg(not(unix))]
            tokio::signal::ctrl_c().await.ok();

            tracing::info!("Shutting down...");
            let _ = shutdown_tx.send(());

            // Flush all scrollback buffers
            for entry in state_for_shutdown.inner.sessions.iter() {
                entry.value().flush_scrollback();
            }
        })
        .await?;

    Ok(())
}
