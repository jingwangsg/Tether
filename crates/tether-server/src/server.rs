use crate::api;
use crate::auth;
use crate::state::AppState;
use crate::ws;
use axum::middleware;
use axum::routing::{delete, get, patch, post};
use axum::Router;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

pub async fn run(state: AppState, no_ssh_scan: bool) -> anyhow::Result<()> {
    // Delete all sessions on startup (PTY processes can't survive a restart)
    state.inner.db.delete_all_sessions()?;
    // Clean up scrollback dirs
    let sessions_dir = format!("{}/sessions", state.inner.config.data_dir());
    if std::path::Path::new(&sessions_dir).exists() {
        std::fs::remove_dir_all(&sessions_dir).ok();
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
        .route("/api/groups/reorder", post(api::groups::batch_reorder_groups))
        .route("/api/sessions", get(api::sessions::list_sessions))
        .route("/api/sessions", post(api::sessions::create_session))
        .route("/api/sessions/{id}", patch(api::sessions::update_session))
        .route("/api/sessions/{id}", delete(api::sessions::delete_session))
        .route(
            "/api/sessions/{id}/scrollback",
            get(api::sessions::get_scrollback),
        )
        .route("/api/sessions/reorder", post(api::sessions::batch_reorder_sessions))
        .route("/api/completions", get(api::completions::complete_path))
        .route("/api/completions/remote", get(api::completions::complete_remote_path))
        .route("/api/ssh/hosts", get(api::ssh::list_ssh_hosts))
        .route("/api/remote/hosts", get(api::remote::list_remote_hosts))
        .layer(middleware::from_fn_with_state(state.clone(), auth::auth_middleware));

    let app = Router::new()
        // Public: server info (needed for hub discovery)
        .route("/api/info", get(api::server_info::get_info))
        .merge(api_routes)
        // WebSocket (has its own auth check via query param)
        .route("/ws/session/{id}", get(ws::handler::ws_handler))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state.clone());

    tracing::info!("Tether server listening on {}", addr);

    // Start background process monitor
    tokio::spawn(crate::pty::process_monitor::run_process_monitor(
        state.clone(),
    ));

    // Start remote SSH host scanner (disabled when running as a remote daemon)
    if !no_ssh_scan {
        // Subscribe before spawning scanner so no Ready events are missed.
        let mut ready_rx = state.inner.remote_manager.ready_tx.subscribe();
        let inner_for_sync = state.inner.clone();
        tokio::spawn(async move {
            use tokio::sync::broadcast::error::RecvError;
            loop {
                match ready_rx.recv().await {
                    Ok((host_alias, tunnel_port, _remote_group_id)) => {
                        let local_groups = match inner_for_sync.db.get_groups_by_ssh_host(&host_alias) {
                            Ok(g) => g,
                            Err(e) => {
                                tracing::warn!("session sync: DB error for {}: {}", host_alias, e);
                                continue;
                            }
                        };
                        for group in local_groups {
                            match crate::remote::sync::sync_remote_sessions(
                                &inner_for_sync.db, &host_alias, tunnel_port, &group.id,
                                &inner_for_sync.ssh_fg,
                            ).await {
                                Ok(n) if n > 0 => tracing::info!(
                                    "session sync: restored {} sessions for {}", n, host_alias
                                ),
                                Err(e) => tracing::warn!(
                                    "session sync: failed for {}: {}", host_alias, e
                                ),
                                _ => {}
                            }
                        }
                    }
                    Err(RecvError::Lagged(n)) => {
                        tracing::warn!("session sync: lagged by {} Ready events, continuing", n);
                    }
                    Err(RecvError::Closed) => break,
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
                let mut sigterm = tokio::signal::unix::signal(
                    tokio::signal::unix::SignalKind::terminate(),
                )
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
