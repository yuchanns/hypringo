use anyhow::Result;
use std::{
    env::{self, temp_dir},
    path::PathBuf,
};
use tracing::debug;

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
};

mod dispatch;
mod event_listener;
mod keyword;
mod monitors;

// pub use dispatch::*;
pub use event_listener::*;
pub use keyword::*;
pub use monitors::*;

pub struct Hyprctl {
    bind_path: PathBuf,
}

impl Hyprctl {
    pub fn new(bind_path: PathBuf) -> Self {
        Hyprctl { bind_path }
    }
    pub async fn write(&self, src: String) -> Result<String> {
        debug!("write: {src}");
        let mut stream = UnixStream::connect(self.bind_path.join(".socket.sock")).await?;
        stream.write_all(src.as_bytes()).await?;
        stream.flush().await?;
        let mut data = String::new();
        stream.read_to_string(&mut data).await?;
        debug!("read: {data}");
        Ok(data)
    }
}

impl Default for Hyprctl {
    fn default() -> Self {
        let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_else(|_| {
            panic!(
                "Unable to retrieve the env var HYPRLAND_INSTANCE_SIGNATURE, is Hyprland running?"
            )
        });
        let dir = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| {
            panic!("Unable to retrieve the env var XDG_RUNTIME_DIR, is Hyprland running?")
        });
        let bind_path = PathBuf::from(format!("{dir}/hypr/{sig}"));
        debug!("hyprland socket path: {bind_path:?}");
        Self::new(bind_path)
    }
}
