mod hyprctl;

use anyhow::Result;

use crate::hyprctl::Hyprctl;

use self::hyprctl::EventListener;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let hyprctl = Hyprctl::default();
    hyprctl.listen().await?;
    Ok(())
}
