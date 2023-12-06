use std::env::{self, temp_dir};

use anyhow::Result;
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    net::UnixStream,
};
use tracing::debug;

#[derive(Debug)]
pub struct Event {
    pub name: String,
    pub data: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let bind_path = temp_dir().join(format!(
        "hypr/{}/.socket2.sock",
        env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_else(|_| {
            panic!(
                "Unable to retrieve the env var HYPRLAND_INSTANCE_SIGNATURE, is Hyprland running?"
            )
        })
    ));
    debug!("hyprland socket2 path: {:?}", bind_path);
    let stream = UnixStream::connect(bind_path.clone())
        .await
        .unwrap_or_else(|_| {
            panic!(
                "Unable to establish the connection at {:?}, is Hyprland running?",
                bind_path
            )
        });
    let mut reader = BufReader::new(stream);
    loop {
        let mut data = Vec::new();
        // IPC events list: https://wiki.hyprland.org/hyprland-wiki/pages/IPC/
        reader.read_until(b'\n', &mut data).await?;
        data.pop();
        let data = String::from_utf8(data)?;
        let parts: Vec<&str> = data.splitn(2, ">>").collect();
        let event = Event {
            name: parts[0].to_string(),
            data: parts[1].to_string(),
        };
        debug!("{:?}", event);
    }
    // Ok(())
}
