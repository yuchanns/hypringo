use std::future::Future;

use anyhow::Result;
use serde_derive::Deserialize;

use super::Hyprctl;

pub trait Monitors {
    type Output<'a>: Future<Output = Result<Vec<Monitor>>>
    where
        Self: 'a;
    fn get_monitors(&self) -> Self::Output<'_>;
}

impl Monitors for Hyprctl {
    type Output<'a> = impl Future<Output = Result<Vec<Monitor>>>;
    fn get_monitors(&self) -> Self::Output<'_> {
        async move {
            let data = self.write("j/monitors".to_string()).await?;
            let monitors: Vec<Monitor> = serde_json::from_str(data.as_str())?;
            Ok(monitors)
        }
    }
}

#[derive(Deserialize, Debug)]
pub struct Monitor {
    pub id: i32,
    pub name: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub make: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub serial: Option<String>,
    pub width: u32,
    pub height: u32,
    #[serde(rename = "refreshRate")]
    pub refresh_rate: f64,
    pub x: i32,
    pub y: i32,
    #[serde(rename = "activeWorkspace")]
    pub active_workspace: Workspace,
    #[serde(rename = "specialWorkspace")]
    pub special_workspace: Workspace,
    pub reserved: [i32; 4],
    pub scale: f64,
    pub transform: i32,
    pub focused: bool,
    #[serde(rename = "dpmsStatus")]
    pub dpms_status: bool,
    pub vrr: bool,
    #[serde(rename = "activelyTearing")]
    pub actively_tearing: bool,
}

#[derive(Deserialize, Debug)]
pub struct Workspace {
    pub id: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

mod test {

    #[tokio::test]
    async fn test_get_monitors() -> Result<(), anyhow::Error> {
        use crate::hyprctl::{Hyprctl, Monitors};
        use std::env::{self, temp_dir};
        use tracing::debug;

        tracing_subscriber::fmt::init();
        let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_else(|_| {
            panic!(
                "Unable to retrieve the env var HYPRLAND_INSTANCE_SIGNATURE, is Hyprland running?"
            )
        });
        let bind_path = temp_dir().join(format!("hypr/{}/.socket.sock", sig));
        let hyprctl = Hyprctl::new(bind_path).await?;
        let monitors = hyprctl.get_monitors().await?;
        debug!("{monitors:?}");
        Ok(())
    }
}
