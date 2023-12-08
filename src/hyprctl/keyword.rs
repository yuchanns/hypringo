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
