use anyhow::Result;

use super::Hyprctl;

pub trait Keyword {
    async fn monitor_resolution(
        &self,
        name: String,
        resolution: String,
        position: String,
        factor: u32,
    ) -> Result<String>;
}

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
    use tracing_test::traced_test;

    #[traced_test]
    #[tokio::test]
    async fn test_monitor_resolution() -> Result<(), anyhow::Error> {
        use crate::hyprctl::{Hyprctl, Keyword};

        let hyprctl = Hyprctl::default();
        hyprctl
            .monitor_resolution("HDMI-A-1".into(), "preferred".into(), "0x-1080".into(), 1)
            .await?;
        Ok(())
    }
}
