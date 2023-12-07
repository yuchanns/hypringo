use std::{
    env::{self, temp_dir},
    path::PathBuf,
};

use anyhow::Result;
use tokio::{
    io::{split, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, BufWriter},
    net::UnixStream,
};
use tracing::{debug, error};

#[derive(Debug)]
pub struct Event {
    pub name: String,
    pub data: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_else(|_| {
        panic!("Unable to retrieve the env var HYPRLAND_INSTANCE_SIGNATURE, is Hyprland running?")
    });
    let bind_path = temp_dir().join(format!("hypr/{}/.socket2.sock", sig));
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
        let mut data = String::new();
        // IPC events list: https://wiki.hyprland.org/hyprland-wiki/pages/IPC/
        reader.read_line(&mut data).await?;
        data.pop();
        let parts: Vec<&str> = data.splitn(2, ">>").collect();
        let event = Event {
            name: parts[0].to_string(),
            data: parts[1].to_string(),
        };
        debug!("event: {:?}", event);
        let sig = sig.clone();
        tokio::spawn(async move {
            let bind_path = temp_dir().join(format!("hypr/{}/.socket.sock", sig));
            debug!("hyprland socket path: {:?}", bind_path);
            match process(bind_path, event).await {
                Ok(_) => {}
                Err(e) => {
                    error!("Unable to process event: {:?}", e);
                }
            }
        });
    }
}

async fn process(bind_path: PathBuf, event: Event) -> Result<()> {
    let stream = UnixStream::connect(bind_path.clone()).await?;
    let (reader, writer) = split(stream);
    let mut writer = BufWriter::new(writer);
    let mut reader = BufReader::new(reader);
    if event.name == "monitoradded" {
        let monitor_name = event.data;
        debug!("monitor name: {:?}", monitor_name);
        // TODO: create a hyprctl package to dispatch all commands
        // example:
        // ```rust
        // let ctl = Hyprctl::new();
        // let monitors = ctl.get_monitors().await?;
        // ````
        writer.write_all(b"[-j]/monitors").await?;
        writer.flush().await?;
        let mut resp = String::new();
        reader.read_to_string(&mut resp).await?;
        debug!("response: {:?}", resp);
    }

    Ok(())
}
