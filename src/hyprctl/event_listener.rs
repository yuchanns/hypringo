use anyhow::{anyhow, Result};
use std::future::Future;
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    net::UnixStream,
};
use tracing::debug;

use crate::hyprctl::{Keyword, Monitor, Monitors};

use super::Hyprctl;

pub trait EventListener {
    type Output<'a>: Future<Output = Result<()>>
    where
        Self: 'a;
    fn listen(&self) -> Self::Output<'_>;
}

impl EventListener for Hyprctl {
    type Output<'a> = impl Future<Output = Result<()>>;

    fn listen(&self) -> Self::Output<'_> {
        async move {
            let stream = UnixStream::connect(self.bind_path.join(".socket2.sock")).await?;
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
                tokio::spawn(async move { process(event).await });
            }
        }
    }
}

#[derive(Debug)]
pub struct Event {
    pub name: String,
    pub data: String,
}

async fn process(event: Event) -> Result<()> {
    let hyprctl = Hyprctl::default();
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
