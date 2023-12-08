use anyhow::Result;
use std::path::PathBuf;
use tracing::debug;

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
};

mod dispatch;
mod keyword;
mod monitors;

pub use dispatch::*;
pub use keyword::*;
pub use monitors::*;

pub struct Hyprctl {
    bind_path: PathBuf,
}

impl Hyprctl {
    pub async fn new(bind_path: PathBuf) -> Result<Self> {
        Ok(Hyprctl { bind_path })
    }
    pub async fn connect(&self) -> Result<UnixStream> {
        Ok(UnixStream::connect(self.bind_path.clone()).await?)
    }
    pub async fn write(&self, src: String) -> Result<String> {
        debug!("write: {:?}", src);
        let mut stream = self.connect().await?;
        stream.write_all(src.as_bytes()).await?;
        stream.flush().await?;
        let mut data = String::new();
        stream.read_to_string(&mut data).await?;
        debug!("read: {data}");
        Ok(data)
    }
}
