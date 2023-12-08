use anyhow::Result;
use async_trait::async_trait;

use super::Hyprctl;

#[async_trait]
pub trait Keyword {
    async fn monitor_resolution(
        &self,
        name: String,
        resolution: String,
        position: String,
        factor: u32,
    ) -> Result<String>;
}

#[async_trait]
impl Keyword for Hyprctl {
    async fn monitor_resolution(
        &self,
        name: String,
        resolution: String,
        position: String,
        factor: u32,
    ) -> Result<String> {
        let args = format!("/keyword monitor {name},{resolution},{position},{factor}");
        let data = self.write(args).await?;
        Ok(data)
    }
}

mod test {
    #[tokio::test]
    async fn test_monitor_resolution() -> Result<(), anyhow::Error> {
        tracing_subscriber::fmt::init();
        use std::env::{self, temp_dir};

        use crate::hyprctl::{Hyprctl, Keyword};
        let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_else(|_| {
            panic!(
                "Unable to retrieve the env var HYPRLAND_INSTANCE_SIGNATURE, is Hyprland running?"
            )
        });
        let bind_path = temp_dir().join(format!("hypr/{}/.socket.sock", sig));
        let hyprctl = Hyprctl::new(bind_path).await?;
        hyprctl
            .monitor_resolution("HDMI-A-1".into(), "preferred".into(), "0x-1080".into(), 1)
            .await?;
        Ok(())
    }
}
