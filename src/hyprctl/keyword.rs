use std::future::Future;

use anyhow::Result;

use super::Hyprctl;

pub trait Keyword {
    type Output<'a>: Future<Output = Result<String>>
    where
        Self: 'a;
    fn monitor_resolution(
        &self,
        name: String,
        resolution: String,
        position: String,
        factor: u32,
    ) -> Self::Output<'_>;
}

impl Keyword for Hyprctl {
    type Output<'a> = impl Future<Output = Result<String>>;
    fn monitor_resolution(
        &self,
        name: String,
        resolution: String,
        position: String,
        factor: u32,
    ) -> Self::Output<'_> {
        async move {
            let args = format!("/keyword monitor {name},{resolution},{position},{factor}");
            let data = self.write(args).await?;
            Ok(data)
        }
    }
}

mod test {
    #[tokio::test]
    async fn test_monitor_resolution() -> Result<(), anyhow::Error> {
        use crate::hyprctl::{Hyprctl, Keyword};
        use std::env::{self, temp_dir};

        tracing_subscriber::fmt::init();
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
