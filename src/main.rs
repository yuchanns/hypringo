mod hyprctl;

use std::{
    env::{self, temp_dir},
    path::PathBuf,
};

use anyhow::{anyhow, Result};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    net::UnixStream,
};
use tracing::{debug, error};

use crate::hyprctl::{Hyprctl, Keyword, Monitor, Monitors};

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
    let bind_path = temp_dir().join(format!("hypr/{sig}/.socket2.sock"));
    debug!("hyprland socket2 path: {bind_path:?}");
    let stream = UnixStream::connect(bind_path.clone())
        .await
        .unwrap_or_else(|_| {
            panic!("Unable to establish the connection at {bind_path:?}, is Hyprland running?",)
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
        debug!("event: {event:?}");
        let sig = sig.clone();
        tokio::spawn(async move {
            let bind_path = temp_dir().join(format!("hypr/{sig}/.socket.sock"));
            debug!("hyprland socket path: {bind_path:?}");
            match process(bind_path, event).await {
                Ok(_) => {}
                Err(e) => {
                    error!("Unable to process event: {e:?}");
                }
            }
        });
    }
}

async fn process(bind_path: PathBuf, event: Event) -> Result<()> {
    let hyprctl = Hyprctl::new(bind_path).await?;
    if event.name == "monitoradded" {
        let monitor_name = event.data;
        debug!("monitor name: {monitor_name:?}");
        let monitors = hyprctl.get_monitors().await?;
        let Monitor {
            width,
            height,
            name,
            ..
        } = monitors
            .iter()
            .find(|&monitor| monitor.name == monitor_name)
            .ok_or_else(|| anyhow!("Unable to find monitor: {monitor_name:?}"))?;
        let resolution = format!("{width}x{height}");
        if resolution == "1920x1080" {
            let _ = hyprctl
                .monitor_resolution(name.clone(), "preferred".into(), "0x-1080".into(), 1)
                .await?;
        } else if resolution == "3840x2160" {
            let _ = hyprctl
                .monitor_resolution(name.clone(), "preferred".into(), "0x-1080".into(), 2)
                .await?;
        }
    }

    Ok(())
}
