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
mod keyword;
mod monitors;

// pub use dispatch::*;
pub use keyword::*;
pub use monitors::*;

pub struct Hyprctl {
    bind_path: PathBuf,
}

impl Hyprctl {
    pub fn new(bind_path: PathBuf) -> Self {
        Hyprctl { bind_path }
    }
    pub async fn connect(&self) -> Result<UnixStream> {
        Ok(UnixStream::connect(self.bind_path.clone()).await?)
    }
    pub async fn write(&self, src: String) -> Result<String> {
        debug!("write: {src}");
        let mut stream = self.connect().await?;
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
        let bind_path = temp_dir().join(format!("hypr/{sig}/.socket.sock"));
        debug!("hyprland socket path: {bind_path:?}");
        Self::new(bind_path)
    }
}
