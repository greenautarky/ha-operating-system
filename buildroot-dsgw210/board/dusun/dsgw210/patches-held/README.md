# Held kernel patches (not applied)

Nothing in this directory is built: it is not part of `BR2_GLOBAL_PATCH_DIR`.

| Patch | Why held | Lands when |
|---|---|---|
| `linux/0005-dw_mmc-rockchip-clear-gmac-m1-routes-on-sdio.patch` | It clears two pin-route bits on the WLAN SDIO host, so it changes the radio path. The image has run without it since 2026-10-18 and WLAN works. | Dusun has confirmed the change and a radio measurement on the DSGW-210 is done (decision 2026-11-26). Then move it back to `../patches/linux/`. |

The device tree keeps `rockchip,clear-gmac-m1-routes` on the SDIO node; without this patch no driver reads it.
